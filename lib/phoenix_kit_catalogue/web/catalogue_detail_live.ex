defmodule PhoenixKitCatalogue.Web.CatalogueDetailLive do
  @moduledoc """
  Detail view for a single catalogue, with infinite-scroll paging over
  its categories and items.

  A single `InfiniteScroll` sentinel at the page bottom drives loading.
  The cursor walks categories in display order: it fills the current
  category's card up to `@per_page` items at a time, then advances to
  the next category, then finally pages through uncategorized items.
  Each `load_more` event loads exactly one batch — the user can keep
  scrolling to stream through catalogues with thousands of items
  without a single blocking query.
  """

  use Phoenix.LiveView

  require Logger

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.AdminPageHeader, only: [admin_page_header: 1]
  import PhoenixKitWeb.Components.Core.Modal, only: [confirm_modal: 1]
  import PhoenixKitCatalogue.Web.Components

  import PhoenixKitCatalogue.Web.Helpers,
    only: [actor_opts: 1, actor_uuid: 1, log_operation_error: 3]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.PubSub
  alias PhoenixKitCatalogue.Errors
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Schemas.{Category, Item}
  alias PhoenixKitCatalogue.Web.Components.PdfSearchModal

  @per_page 100
  @per_card 25
  # Show-more button timeout — if the deferred :apply_expand doesn't
  # complete within this window the button restores so the user can
  # retry. Calibrated for "user lost network mid-click" not "the DB is
  # slow" — the inline query itself rarely takes more than 50ms.
  @expand_timeout_ms 8_000
  # Cross-tab bulk-change red-flash → state-refresh delay. Long enough
  # that the receiver sees the leaving rows pulse red before they
  # vanish on the refresh, short enough not to feel laggy.
  @bulk_change_apply_delay_ms 800

  @impl true
  def mount(%{"uuid" => uuid}, _session, socket) do
    socket =
      assign(socket,
        page_title: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Loading..."),
        catalogue_uuid: uuid,
        catalogue: nil,
        category_list: [],
        category_depths: %{},
        category_counts: %{},
        uncategorized_total: 0,
        loaded_cards: [],
        expanding_cards: MapSet.new(),
        confirm_delete: nil,
        trash_modal: nil,
        bulk_move_modal: nil,
        bulk_confirm: nil,
        selected_items: MapSet.new(),
        selected_categories: MapSet.new(),
        view_mode: "active",
        deleted_count: 0,
        active_item_count: 0,
        deleted_item_count: 0,
        active_category_count: 0,
        deleted_category_count: 0,
        deleted_items: [],
        search_query: "",
        search_results: nil,
        search_offset: 0,
        search_total: 0,
        search_has_more: false,
        search_loading: false,
        show_pdf_search: false,
        pdf_search_item: nil,
        tab: "items"
      )

    if connected?(socket) do
      # Subscribe BEFORE the initial load so a write that lands between
      # the load and a connect doesn't leave the UI stale forever — the
      # broadcast triggers a re-load via handle_info/2.
      PubSub.subscribe()

      try do
        {:ok, reset_and_load(socket)}
      rescue
        Ecto.NoResultsError ->
          Logger.warning("Catalogue not found: #{uuid}")

          {:ok,
           socket
           |> put_flash(
             :error,
             Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue not found.")
           )
           |> push_navigate(to: Paths.index())}
      end
    else
      {:ok, socket}
    end
  end

  # `?tab=items|categories` is reflected into socket assigns on every
  # patch. The default is "items"; any unknown value falls back to
  # "items" so a stale link can't push the LV into an undefined tab.
  #
  # After updating the tab, run the per-tab auto-flip — if the user
  # switches into a tab whose Deleted bucket is empty, flip them back
  # to Active rather than land them in an empty Deleted view.
  @impl true
  def handle_params(params, _uri, socket) do
    tab =
      case params["tab"] do
        "categories" -> "categories"
        _ -> "items"
      end

    socket =
      if tab == socket.assigns[:tab] do
        socket
      else
        # Tab change: drop both selection sets — selection is per-tab
        # in the UI, but they share the same modal/action-bar pipes,
        # so a stale set across tabs would mis-target bulk actions.
        socket
        |> assign(:selected_items, MapSet.new())
        |> assign(:selected_categories, MapSet.new())
      end

    {:noreply, socket |> assign(:tab, tab) |> maybe_auto_flip_to_active()}
  end

  # PubSub: another LV touched a category/item/catalogue/smart-rule.
  # Filter on `parent_catalogue_uuid` so a write in another catalogue
  # doesn't reset *this* page — without that filter, every item edit
  # anywhere in the system wipes the user's scroll state, and a busy
  # admin or background importer can trap the LV in a permanent
  # spinner as the mailbox queues up faster than `refresh_in_place`
  # can drain it.
  #
  # `:catalogue` events match when the affected uuid is *this*
  # catalogue. `:category` / `:item` / `:smart_rule` match when the
  # mutated resource belongs to this catalogue (parent_catalogue_uuid
  # is threaded through the broadcast). `nil` parent is treated as
  # "unknown scope, refresh defensively" — the same way pre-filter
  # behaviour worked, so older callers that haven't been updated still
  # propagate.
  @impl true
  def handle_info(
        {:catalogue_data_changed, :catalogue, uuid, _parent},
        %{assigns: %{catalogue_uuid: catalogue_uuid}} = socket
      )
      when uuid == catalogue_uuid do
    handle_catalogue_data_changed(socket)
  end

  def handle_info(
        {:catalogue_data_changed, kind, _uuid, parent},
        %{assigns: %{catalogue_uuid: catalogue_uuid}} = socket
      )
      when kind in [:category, :item, :smart_rule] and
             (parent == catalogue_uuid or is_nil(parent)) do
    handle_catalogue_data_changed(socket)
  end

  def handle_info({:pdf_search_modal_closed}, socket) do
    {:noreply, assign(socket, show_pdf_search: false, pdf_search_item: nil)}
  end

  # Cross-tab live reorder: another open detail page just reordered
  # items inside a card on the same catalogue. Refresh just that card's
  # items (preserves scroll) and fire the same flash the originator
  # saw. `from == self()` is the originating LV — already updated
  # locally, skip to avoid double-flashing.
  def handle_info(
        {:catalogue_card_refresh, cat_uuid, scope, flash_uuid, flash_status, from},
        %{assigns: %{catalogue_uuid: catalogue_uuid}} = socket
      )
      when cat_uuid == catalogue_uuid and from != self() do
    socket = refresh_card_items(socket, scope)

    socket =
      if is_binary(flash_uuid),
        do: flash_reorder(socket, flash_uuid, flash_status),
        else: socket

    {:noreply, socket}
  end

  # Sender's own broadcast — already handled locally; ignore.
  def handle_info({:catalogue_card_refresh, _, _, _, _, from}, socket) when from == self(),
    do: {:noreply, socket}

  # Cross-tab live reorder for categories: order positions changed,
  # which affects how every streamed card is laid out. Heavier
  # reset_and_load — same trade-off the local reorder makes.
  def handle_info(
        {:catalogue_category_reorder, cat_uuid, moved_id, status, from},
        %{assigns: %{catalogue_uuid: catalogue_uuid}} = socket
      )
      when cat_uuid == catalogue_uuid and from != self() do
    socket = reset_and_load(socket)

    socket =
      if is_binary(moved_id),
        do: flash_reorder(socket, moved_id, status),
        else: socket

    {:noreply, socket}
  end

  def handle_info({:catalogue_category_reorder, _, _, _, from}, socket) when from == self(),
    do: {:noreply, socket}

  # Cross-tab live bulk change: another open detail page just bulk-
  # trashed / restored / moved / hard-deleted items. Two-step animation
  # for receivers — flash the "leaving" colour on every affected DOM
  # row immediately, schedule the actual state refresh after the flash
  # plays out (~800ms), then on refresh fire green flash for the
  # arriving rows when the kind is :restored or :moved.
  def handle_info(
        {:catalogue_bulk_change, cat_uuid, kind, uuids, from},
        %{assigns: %{catalogue_uuid: catalogue_uuid}} = socket
      )
      when cat_uuid == catalogue_uuid and from != self() do
    leaving_status =
      case kind do
        # Restored items aren't currently visible — nothing to flash red.
        :restored -> nil
        # Trashed / moved / permanent-deleted: they're on this tab now,
        # so red-flash them as they're about to leave.
        _ -> :error
      end

    socket =
      if leaving_status,
        do: Enum.reduce(uuids, socket, &flash_reorder(&2, &1, leaving_status)),
        else: socket

    Process.send_after(self(), {:bulk_change_apply, kind, uuids}, @bulk_change_apply_delay_ms)

    {:noreply, socket}
  end

  # Originator's own bulk-change broadcast — already updated locally.
  def handle_info({:catalogue_bulk_change, _, _, _, from}, socket) when from == self(),
    do: {:noreply, socket}

  # Tail of the cross-tab bulk animation — applies the actual state
  # refresh and the arriving-side green flash (for moves / restores).
  def handle_info({:bulk_change_apply, kind, uuids}, socket) do
    socket = socket |> reset_and_load() |> refresh_counts()

    socket =
      if kind in [:restored, :moved],
        do: Enum.reduce(uuids, socket, &flash_reorder(&2, &1, :ok)),
        else: socket

    {:noreply, socket}
  end

  # Deferred apply for the show-more click. The handler that scheduled
  # this might have been outraced by `:expand_timeout` (operator on a
  # bad connection) — in that case the scope is no longer in
  # `expanding_cards` and we no-op.
  def handle_info({:apply_expand, scope}, socket) do
    if MapSet.member?(socket.assigns.expanding_cards, scope) do
      {:noreply, do_apply_expand(socket, scope)}
    else
      {:noreply, socket}
    end
  end

  # Smart-fail: if the apply hasn't landed within @expand_timeout_ms
  # (network hiccup, BEAM stuck), restore the button and surface a
  # flash so the operator can retry.
  def handle_info({:expand_timeout, scope}, socket) do
    if MapSet.member?(socket.assigns.expanding_cards, scope) do
      {:noreply,
       socket
       |> assign(:expanding_cards, MapSet.delete(socket.assigns.expanding_cards, scope))
       |> put_flash(
         :error,
         Gettext.gettext(
           PhoenixKitCatalogue.Gettext,
           "Loading more items took too long. Please try again."
         )
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_info(msg, socket) do
    Logger.debug("CatalogueDetailLive ignored unhandled message: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp do_apply_expand(socket, scope) do
    mode = view_mode_to_atom(socket.assigns.view_mode)
    catalogue_uuid = socket.assigns.catalogue_uuid

    cards =
      Enum.map(socket.assigns.loaded_cards, &expand_one_card(&1, scope, catalogue_uuid, mode))

    socket
    |> assign(:loaded_cards, cards)
    |> assign(:expanding_cards, MapSet.delete(socket.assigns.expanding_cards, scope))
  end

  defp expand_one_card(card, scope, catalogue_uuid, mode) do
    if scope_matches_card?(scope, card) do
      more =
        fetch_card_items(card_scope(card), catalogue_uuid, mode, @per_card, length(card.items))

      %{card | items: card.items ++ more}
    else
      card
    end
  end

  defp handle_catalogue_data_changed(socket) do
    {:noreply, refresh_in_place(socket)}
  rescue
    Ecto.NoResultsError ->
      # The catalogue we're viewing was deleted in another session.
      {:noreply,
       socket
       |> put_flash(
         :info,
         Gettext.gettext(PhoenixKitCatalogue.Gettext, "This catalogue was just deleted.")
       )
       |> push_navigate(to: Paths.index())}
  end

  # ── Event handlers ──────────────────────────────────────────────

  @impl true
  def handle_event("switch_view", %{"mode" => mode}, socket) when mode in ~w(active deleted) do
    {:noreply,
     socket
     |> assign(:view_mode, mode)
     |> assign(:confirm_delete, nil)
     |> assign(:selected_items, MapSet.new())
     |> assign(:selected_categories, MapSet.new())
     |> reset_and_load()}
  end

  # Items/Categories tab switch. URL is patched so the choice survives
  # back-button + reload + share-link. handle_params/3 echoes the param
  # into the :tab assign, so we don't update assigns here directly.
  def handle_event("switch_tab", %{"tab" => tab}, socket) when tab in ~w(items categories) do
    target =
      case tab do
        "items" -> Paths.catalogue_detail(socket.assigns.catalogue_uuid)
        "categories" -> Paths.catalogue_detail(socket.assigns.catalogue_uuid) <> "?tab=categories"
      end

    {:noreply, push_patch(socket, to: target)}
  end

  # `load_more` is now only used by the search results pagination —
  # the category cards expand on-demand via `expand_card` instead of
  # via a global bottom sentinel.
  def handle_event("load_more", _params, socket) do
    if socket.assigns.search_results != nil and socket.assigns.search_has_more and
         not socket.assigns.search_loading do
      {:noreply, start_search_page(socket)}
    else
      {:noreply, socket}
    end
  end

  # Per-card "Show N more" button. `scope` is either a category UUID
  # or the literal string "uncategorized".
  #
  # Deferred apply pattern: the event handler returns immediately after
  # marking the card as expanding (so the LV re-renders the disabled
  # "Loading…" button), then `:apply_expand` does the actual fetch on
  # the next mailbox tick. Without this defer the LV would block in
  # one go and the user would never see the loading state.
  #
  # Smart-fail: if the apply doesn't land within @expand_timeout_ms
  # (default 8s), `:expand_timeout` clears the expanding flag and
  # surfaces a flash so the user can retry. The query itself runs
  # inline (not async) so the timeout fires only when the BEAM /
  # socket is genuinely stuck, not when the DB is just slow — but
  # that's the failure mode worth recovering from.
  def handle_event("expand_card", %{"scope" => scope}, socket) do
    if MapSet.member?(socket.assigns.expanding_cards, scope) do
      {:noreply, socket}
    else
      send(self(), {:apply_expand, scope})
      Process.send_after(self(), {:expand_timeout, scope}, @expand_timeout_ms)

      {:noreply,
       assign(socket, :expanding_cards, MapSet.put(socket.assigns.expanding_cards, scope))}
    end
  end

  def handle_event("search", %{"query" => query}, socket) do
    query = String.trim(query)

    if query == "" do
      {:noreply, clear_search(socket)}
    else
      {:noreply, run_search(socket, query)}
    end
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply, clear_search(socket)}
  end

  def handle_event("show_pdf_search", %{"uuid" => uuid}, socket) do
    case Catalogue.get_item(uuid) do
      nil ->
        {:noreply, socket}

      item ->
        {:noreply,
         socket
         |> assign(:pdf_search_item, item)
         |> assign(:show_pdf_search, true)}
    end
  end

  def handle_event("delete_item", %{"uuid" => uuid}, socket) do
    with %{} = item <- Catalogue.get_item(uuid),
         {:ok, _} <- Catalogue.trash_item(item, actor_opts(socket)) do
      {:noreply,
       socket
       |> put_flash(:info, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Item moved to deleted."))
       |> remove_item_locally(uuid)
       |> refresh_counts()}
    else
      nil ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Item not found.")
         )}

      {:error, reason} ->
        log_operation_error(socket, "trash_item", %{
          entity_type: "item",
          entity_uuid: uuid,
          reason: reason
        })

        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to delete item.")
         )}
    end
  end

  def handle_event("restore_item", %{"uuid" => uuid}, socket) do
    with %{} = item <- Catalogue.get_item(uuid),
         {:ok, _} <- Catalogue.restore_item(item, actor_opts(socket)) do
      {:noreply,
       socket
       |> put_flash(:info, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Item restored."))
       |> remove_item_locally(uuid)
       |> refresh_counts()}
    else
      nil ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Item not found.")
         )}

      {:error, :parent_catalogue_deleted} ->
        {:noreply, put_flash(socket, :error, Errors.message(:parent_catalogue_deleted))}

      {:error, reason} ->
        log_operation_error(socket, "restore_item", %{
          entity_type: "item",
          entity_uuid: uuid,
          reason: reason
        })

        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to restore item.")
         )}
    end
  end

  def handle_event("show_delete_confirm", %{"uuid" => uuid, "type" => type}, socket) do
    {:noreply, assign(socket, :confirm_delete, {type, uuid})}
  end

  def handle_event("permanently_delete_item", _params, socket) do
    case socket.assigns.confirm_delete do
      {"item", uuid} ->
        with %{} = item <- Catalogue.get_item(uuid),
             {:ok, _} <- Catalogue.permanently_delete_item(item, actor_opts(socket)) do
          {:noreply,
           socket
           |> assign(:confirm_delete, nil)
           |> put_flash(
             :info,
             Gettext.gettext(PhoenixKitCatalogue.Gettext, "Item permanently deleted.")
           )
           |> remove_item_locally(uuid)
           |> refresh_counts()}
        else
          nil ->
            {:noreply,
             socket
             |> assign(:confirm_delete, nil)
             |> put_flash(:error, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Item not found."))}

          {:error, reason} ->
            log_operation_error(socket, "permanently_delete_item", %{
              entity_type: "item",
              entity_uuid: uuid,
              reason: reason
            })

            {:noreply,
             socket
             |> assign(:confirm_delete, nil)
             |> put_flash(
               :error,
               Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to delete item.")
             )}
        end

      _ ->
        unexpected_confirm_event(socket, "permanently_delete_item")
    end
  end

  # Entry point from the Items / Categories tab Delete buttons. When the
  # category subtree has zero active items, trashes directly. Otherwise
  # opens a modal so the operator chooses what happens to the items
  # (move them to another category, or detach them as uncategorized in
  # the same catalogue) before the category trash fires.
  def handle_event("request_trash_category", %{"uuid" => uuid}, socket) do
    case Catalogue.get_category(uuid) do
      nil ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category not found.")
         )}

      category ->
        item_count = Catalogue.active_item_count_in_subtree(uuid)

        if item_count == 0 do
          do_trash_category(socket, category, items: :cascade)
        else
          {:noreply, assign(socket, :trash_modal, build_trash_modal_state(category, item_count))}
        end
    end
  end

  def handle_event("set_trash_disposition", %{"disposition" => disp}, socket) do
    modal = socket.assigns.trash_modal || %{}

    new_modal =
      case disp do
        "uncategorize" -> %{modal | disposition: :uncategorize, target_uuid: nil}
        "move_to" -> %{modal | disposition: :move_to}
        "cascade" -> %{modal | disposition: :cascade, target_uuid: nil}
        _ -> modal
      end

    {:noreply, assign(socket, :trash_modal, new_modal)}
  end

  def handle_event("select_trash_target", %{"category_uuid" => uuid}, socket) do
    modal = socket.assigns.trash_modal || %{}
    {:noreply, assign(socket, :trash_modal, %{modal | target_uuid: blank_to_nil(uuid)})}
  end

  def handle_event("confirm_trash_category", _params, socket) do
    case socket.assigns.trash_modal do
      %{bulk: true, bulk_uuids: uuids, disposition: disp, target_uuid: target_uuid} ->
        items_opt = disposition_to_items_opt(disp, target_uuid)

        if is_nil(items_opt) do
          {:noreply, socket}
        else
          socket
          |> assign(:trash_modal, nil)
          |> do_bulk_trash_categories_with(uuids, items_opt)
        end

      %{category: category, disposition: :uncategorize} ->
        socket
        |> assign(:trash_modal, nil)
        |> do_trash_category(category, items: :uncategorize)

      %{category: category, disposition: :move_to, target_uuid: target_uuid}
      when not is_nil(target_uuid) ->
        socket
        |> assign(:trash_modal, nil)
        |> do_trash_category(category, items: {:move_to, target_uuid})

      %{category: category, disposition: :cascade} ->
        socket
        |> assign(:trash_modal, nil)
        |> do_trash_category(category, items: :cascade)

      _ ->
        # Confirm should be disabled in this state; defensive no-op.
        {:noreply, socket}
    end
  end

  def handle_event("cancel_trash_category", _params, socket) do
    {:noreply, assign(socket, :trash_modal, nil)}
  end

  # ── Bulk selection + actions ────────────────────────────────────

  def handle_event("toggle_select_item", %{"uuid" => uuid}, socket) do
    {:noreply, assign(socket, :selected_items, toggle(socket.assigns.selected_items, uuid))}
  end

  def handle_event("toggle_select_category", %{"uuid" => uuid}, socket) do
    {:noreply,
     assign(socket, :selected_categories, toggle(socket.assigns.selected_categories, uuid))}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply,
     assign(socket,
       selected_items: MapSet.new(),
       selected_categories: MapSet.new()
     )}
  end

  # Bulk delete items — opens a confirm modal stamped with the selection
  # count and the operation type. Confirmation routes through
  # `confirm_bulk_action` below.
  def handle_event("request_bulk_delete_items", _params, socket) do
    count = MapSet.size(socket.assigns.selected_items)

    if count == 0 do
      {:noreply, socket}
    else
      mode =
        if socket.assigns.view_mode == "deleted",
          do: :permanent,
          else: :trash

      {:noreply, assign(socket, :bulk_confirm, %{kind: :items, mode: mode, count: count})}
    end
  end

  def handle_event("request_bulk_restore_items", _params, socket) do
    count = MapSet.size(socket.assigns.selected_items)
    if count == 0, do: {:noreply, socket}, else: do_bulk_restore_items(socket)
  end

  def handle_event("request_bulk_move_items", _params, socket) do
    count = MapSet.size(socket.assigns.selected_items)

    if count == 0 do
      {:noreply, socket}
    else
      targets =
        socket.assigns.catalogue_uuid
        |> Catalogue.list_category_tree(mode: :active)

      {:noreply,
       assign(socket, :bulk_move_modal, %{
         count: count,
         targets: targets,
         disposition: :uncategorize,
         target_uuid: nil
       })}
    end
  end

  def handle_event("set_bulk_move_disposition", %{"disposition" => disp}, socket) do
    modal = socket.assigns.bulk_move_modal || %{}

    new_modal =
      case disp do
        "uncategorize" -> %{modal | disposition: :uncategorize, target_uuid: nil}
        "move_to" -> %{modal | disposition: :move_to}
        _ -> modal
      end

    {:noreply, assign(socket, :bulk_move_modal, new_modal)}
  end

  def handle_event("select_bulk_move_target", %{"category_uuid" => uuid}, socket) do
    modal = socket.assigns.bulk_move_modal || %{}
    {:noreply, assign(socket, :bulk_move_modal, %{modal | target_uuid: blank_to_nil(uuid)})}
  end

  def handle_event("confirm_bulk_move_items", _params, socket) do
    case socket.assigns.bulk_move_modal do
      %{disposition: :uncategorize} ->
        do_bulk_move_items(socket, nil)

      %{disposition: :move_to, target_uuid: target_uuid} when not is_nil(target_uuid) ->
        do_bulk_move_items(socket, target_uuid)

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_bulk_move", _params, socket) do
    {:noreply, assign(socket, :bulk_move_modal, nil)}
  end

  def handle_event("confirm_bulk_action", _params, socket) do
    case socket.assigns.bulk_confirm do
      %{kind: :items, mode: :trash} ->
        do_bulk_trash_items(socket)

      %{kind: :items, mode: :permanent} ->
        do_bulk_permanent_delete_items(socket)

      %{kind: :categories} ->
        do_bulk_trash_categories(socket)

      _ ->
        {:noreply, assign(socket, :bulk_confirm, nil)}
    end
  end

  def handle_event("cancel_bulk_action", _params, socket) do
    {:noreply, assign(socket, :bulk_confirm, nil)}
  end

  # Bulk delete categories: routes through trash_modal with bulk: true
  # so the disposition picker is shared with the single-category flow.
  def handle_event("request_bulk_delete_categories", _params, socket) do
    uuids = socket.assigns.selected_categories |> MapSet.to_list()

    if uuids == [] do
      {:noreply, socket}
    else
      # The bulk modal needs at least one category struct for the
      # name preview + same-catalogue target list. Pull one and use
      # it as the surface.
      case Catalogue.get_category(hd(uuids)) do
        nil ->
          {:noreply, socket}

        category ->
          {:noreply,
           assign(socket, :trash_modal, %{
             category: category,
             item_count: bulk_subtree_item_count(uuids),
             targets: Catalogue.list_move_target_categories(category),
             disposition: :uncategorize,
             target_uuid: nil,
             bulk: true,
             bulk_uuids: uuids
           })}
      end
    end
  end

  def handle_event("request_bulk_restore_categories", _params, socket) do
    uuids = socket.assigns.selected_categories |> MapSet.to_list()
    if uuids == [], do: {:noreply, socket}, else: do_bulk_restore_categories(socket, uuids)
  end

  def handle_event("restore_category", %{"uuid" => uuid}, socket) do
    with %{} = category <- Catalogue.get_category(uuid),
         {:ok, _} <- Catalogue.restore_category(category, actor_opts(socket)) do
      {:noreply,
       socket
       |> put_flash(:info, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category restored."))
       |> reset_and_load()}
    else
      nil ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category not found.")
         )}

      {:error, :parent_catalogue_deleted} ->
        {:noreply, put_flash(socket, :error, Errors.message(:parent_catalogue_deleted))}

      {:error, reason} ->
        log_operation_error(socket, "restore_category", %{
          entity_type: "category",
          entity_uuid: uuid,
          reason: reason
        })

        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to restore category.")
         )}
    end
  end

  def handle_event("permanently_delete_category", _params, socket) do
    case socket.assigns.confirm_delete do
      {"category", uuid} ->
        with %{} = category <- Catalogue.get_category(uuid),
             {:ok, _} <- Catalogue.permanently_delete_category(category, actor_opts(socket)) do
          {:noreply,
           socket
           |> assign(:confirm_delete, nil)
           |> put_flash(
             :info,
             Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category permanently deleted.")
           )
           |> reset_and_load()}
        else
          nil ->
            {:noreply,
             socket
             |> assign(:confirm_delete, nil)
             |> put_flash(
               :error,
               Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category not found.")
             )}

          {:error, reason} ->
            log_operation_error(socket, "permanently_delete_category", %{
              entity_type: "category",
              entity_uuid: uuid,
              reason: reason
            })

            {:noreply,
             socket
             |> assign(:confirm_delete, nil)
             |> put_flash(
               :error,
               Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to delete category.")
             )}
        end

      _ ->
        unexpected_confirm_event(socket, "permanently_delete_category")
    end
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :confirm_delete, nil)}
  end

  def handle_event("reorder_categories", %{"ordered_ids" => ordered_ids} = params, socket)
      when is_list(ordered_ids) do
    apply_category_reorder(socket, ordered_ids, params["moved_id"])
  end

  # Cross-category drop: SortableJS sent the source category in `from*`
  # keys alongside the destination's scope. We move the item, then
  # reorder the destination to match the visual order the user dropped
  # it into. The source's remaining order is preserved implicitly —
  # its position values stay valid since they're per-scope.
  #
  # Pattern-matches on `fromCatalogueUuid` (only present on cross-
  # container drops) rather than `moved_id` (now sent for every drop
  # so the LV can flash the moved row regardless).
  def handle_event(
        "reorder_items",
        %{"ordered_ids" => ordered_ids, "moved_id" => moved_id, "fromCatalogueUuid" => _} =
          params,
        socket
      )
      when is_list(ordered_ids) and is_binary(moved_id) do
    to_catalogue_uuid = params["catalogueUuid"]
    to_category_uuid = blank_to_nil(params["categoryUuid"])
    from_catalogue_uuid = params["fromCatalogueUuid"]

    cond do
      to_catalogue_uuid != socket.assigns.catalogue_uuid ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Wrong catalogue scope.")
         )}

      from_catalogue_uuid != to_catalogue_uuid ->
        # Items can't change catalogue via DnD (Item.catalogue_uuid is
        # the strong root scope; cross-catalogue moves go through the
        # explicit "Move to catalogue" form). Reload to snap the DOM
        # back to the persisted state.
        {:noreply,
         socket
         |> put_flash(
           :error,
           Gettext.gettext(
             PhoenixKitCatalogue.Gettext,
             "Items can only be moved within the same catalogue."
           )
         )
         |> reset_and_load()}

      true ->
        # `move_item_and_reorder_destination/4` wraps the move + reorder
        # in a single transaction so a reorder failure rolls back the
        # category flip — no in-between half-state where the item has
        # the new category_uuid but the wrong position.
        with %Item{} = item <- Catalogue.get_item(moved_id),
             from_category_uuid = item.category_uuid,
             {:ok, _moved} <-
               Catalogue.move_item_and_reorder_destination(
                 item,
                 to_category_uuid,
                 ordered_ids,
                 actor_opts(socket)
               ) do
          from_scope = from_category_uuid || :uncategorized
          to_scope = to_category_uuid || :uncategorized
          # Source loses an item, destination gains one — broadcast both
          # so other open tabs refresh both cards. Flash only on the
          # destination scope (where the row landed).
          PubSub.broadcast_card_refresh(to_catalogue_uuid, from_scope, nil, :ok)
          PubSub.broadcast_card_refresh(to_catalogue_uuid, to_scope, moved_id, :ok)

          {:noreply,
           socket
           |> refresh_card_items(from_scope, -1)
           |> refresh_card_items(to_scope, +1)
           |> refresh_counts()
           |> flash_reorder(moved_id, :ok)}
        else
          nil ->
            {:noreply,
             socket
             |> put_flash(:error, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Item not found."))
             |> flash_reorder(moved_id, :error)}

          {:error, reason} ->
            log_operation_error(socket, "move_item_via_dnd", %{
              item_uuid: moved_id,
              to_category_uuid: to_category_uuid,
              reason: reason
            })

            {:noreply,
             socket
             |> put_flash(
               :error,
               Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to move item.")
             )
             |> reset_and_load()
             |> flash_reorder(moved_id, :error)}
        end
    end
  end

  def handle_event("reorder_items", %{"ordered_ids" => ordered_ids} = params, socket)
      when is_list(ordered_ids) do
    catalogue_uuid = params["catalogueUuid"]
    category_uuid = blank_to_nil(params["categoryUuid"])
    moved_id = params["moved_id"]

    if catalogue_uuid != socket.assigns.catalogue_uuid do
      {:noreply,
       put_flash(
         socket,
         :error,
         Gettext.gettext(PhoenixKitCatalogue.Gettext, "Wrong catalogue scope.")
       )}
    else
      apply_in_scope_item_reorder(socket, catalogue_uuid, category_uuid, ordered_ids, moved_id)
    end
  end

  # ── Per-card expand helpers ──────────────────────────────────────

  # Template helper: turns a card map into the scope key used by
  # `expanding_cards` / `expand_card` events.
  defp scope_key(%{kind: :uncategorized}), do: "uncategorized"
  defp scope_key(%{kind: :category, category: %{uuid: uuid}}), do: uuid

  defp scope_matches_card?("uncategorized", %{kind: :uncategorized}), do: true

  defp scope_matches_card?(uuid, %{kind: :category, category: %{uuid: cat_uuid}})
       when is_binary(uuid),
       do: uuid == cat_uuid

  defp scope_matches_card?(_, _), do: false

  defp card_scope(%{kind: :uncategorized}), do: :uncategorized
  defp card_scope(%{kind: :category, category: %{uuid: uuid}}), do: uuid

  # ── Bulk-action helpers ──────────────────────────────────────────

  defp toggle(set, uuid) do
    if MapSet.member?(set, uuid), do: MapSet.delete(set, uuid), else: MapSet.put(set, uuid)
  end

  defp disposition_to_items_opt(:uncategorize, _), do: :uncategorize
  defp disposition_to_items_opt(:cascade, _), do: :cascade
  defp disposition_to_items_opt(:move_to, target) when not is_nil(target), do: {:move_to, target}
  defp disposition_to_items_opt(_, _), do: nil

  defp bulk_subtree_item_count(uuids) do
    Enum.reduce(uuids, 0, fn uuid, acc ->
      acc + Catalogue.active_item_count_in_subtree(uuid)
    end)
  end

  defp do_bulk_trash_items(socket) do
    uuids = socket.assigns.selected_items |> MapSet.to_list()
    {count, _} = Catalogue.bulk_trash_items(uuids, actor_opts(socket))
    PubSub.broadcast_bulk_change(socket.assigns.catalogue_uuid, :trashed, uuids)

    socket
    |> assign(:bulk_confirm, nil)
    |> assign(:selected_items, MapSet.new())
    |> put_flash(
      :info,
      Gettext.gettext(PhoenixKitCatalogue.Gettext, "Deleted %{count} items.", count: count)
    )
    |> reset_and_load()
    |> then(&{:noreply, &1})
  end

  defp do_bulk_permanent_delete_items(socket) do
    uuids = socket.assigns.selected_items |> MapSet.to_list()
    {count, _} = Catalogue.bulk_permanently_delete_items(uuids, actor_opts(socket))
    PubSub.broadcast_bulk_change(socket.assigns.catalogue_uuid, :permanent_delete, uuids)

    socket
    |> assign(:bulk_confirm, nil)
    |> assign(:selected_items, MapSet.new())
    |> put_flash(
      :info,
      Gettext.gettext(PhoenixKitCatalogue.Gettext, "Permanently deleted %{count} items.",
        count: count
      )
    )
    |> reset_and_load()
    |> then(&{:noreply, &1})
  end

  defp do_bulk_restore_items(socket) do
    uuids = socket.assigns.selected_items |> MapSet.to_list()
    {count, _} = Catalogue.bulk_restore_items(uuids, actor_opts(socket))
    PubSub.broadcast_bulk_change(socket.assigns.catalogue_uuid, :restored, uuids)

    socket
    |> assign(:selected_items, MapSet.new())
    |> put_flash(
      :info,
      Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restored %{count} items.", count: count)
    )
    |> reset_and_load()
    |> then(&{:noreply, &1})
  end

  defp do_bulk_move_items(socket, target_uuid) do
    uuids = socket.assigns.selected_items |> MapSet.to_list()

    opts =
      actor_opts(socket) |> Keyword.put(:catalogue_uuid, socket.assigns.catalogue_uuid)

    case Catalogue.bulk_move_items_to_category(uuids, target_uuid, opts) do
      {:ok, count} ->
        # `:moved` triggers the receiver's full red-fade → refresh →
        # green-fade sequence on every other open tab.
        PubSub.broadcast_bulk_change(socket.assigns.catalogue_uuid, :moved, uuids)

        socket
        |> assign(:bulk_move_modal, nil)
        |> assign(:selected_items, MapSet.new())
        |> put_flash(
          :info,
          Gettext.gettext(PhoenixKitCatalogue.Gettext, "Moved %{count} items.", count: count)
        )
        |> reset_and_load()
        |> then(&{:noreply, &1})

      {:error, :category_not_found} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Target category not found.")
         )}

      {:error, scope_err} when scope_err in [:wrong_catalogue_scope, :missing_catalogue_scope] ->
        log_operation_error(socket, "bulk_move_items_to_category", %{reason: scope_err})

        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(
             PhoenixKitCatalogue.Gettext,
             "Items can only be moved within this catalogue."
           )
         )}
    end
  end

  defp do_bulk_trash_categories(socket) do
    # Without a disposition picker, default cascade. The bulk modal
    # path goes through confirm_trash_category instead.
    do_bulk_trash_categories_with(
      socket,
      socket.assigns.selected_categories |> MapSet.to_list(),
      :cascade
    )
  end

  defp do_bulk_trash_categories_with(socket, uuids, items_opt) do
    case Catalogue.bulk_trash_categories(uuids, items_opt, actor_opts(socket)) do
      {:ok, %{categories: count}} ->
        socket
        |> assign(:bulk_confirm, nil)
        |> assign(:selected_categories, MapSet.new())
        |> put_flash(
          :info,
          Gettext.gettext(PhoenixKitCatalogue.Gettext, "Deleted %{count} categories.",
            count: count
          )
        )
        |> reset_and_load()
        |> then(&{:noreply, &1})

      {:error, reason} ->
        log_operation_error(socket, "bulk_trash_categories", %{reason: reason})

        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to delete categories.")
         )}
    end
  end

  defp do_bulk_restore_categories(socket, uuids) do
    {ok, errors} =
      Enum.reduce(uuids, {0, []}, fn uuid, {ok, errs} ->
        with %{} = category <- Catalogue.get_category(uuid),
             {:ok, _} <- Catalogue.restore_category(category, actor_opts(socket)) do
          {ok + 1, errs}
        else
          {:error, reason} -> {ok, [reason | errs]}
          _ -> {ok, errs}
        end
      end)

    socket =
      socket
      |> assign(:selected_categories, MapSet.new())
      |> put_flash(
        :info,
        Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restored %{count} categories.", count: ok)
      )
      |> reset_and_load()

    if errors == [] do
      {:noreply, socket}
    else
      log_operation_error(socket, "bulk_restore_categories_partial", %{reasons: errors})

      {:noreply,
       put_flash(
         socket,
         :error,
         Gettext.gettext(
           PhoenixKitCatalogue.Gettext,
           "Some categories couldn't be restored. The catalogue may be deleted — restore it first."
         )
       )}
    end
  end

  defp build_trash_modal_state(%Category{} = category, item_count) do
    %{
      category: category,
      item_count: item_count,
      targets: Catalogue.list_move_target_categories(category),
      disposition: :uncategorize,
      target_uuid: nil
    }
  end

  defp do_trash_category(socket, category, opts) do
    full_opts = Keyword.merge(opts, actor_opts(socket))

    case Catalogue.trash_category(category, full_opts) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category moved to deleted.")
         )
         |> reset_and_load()}

      {:error, reason} ->
        log_operation_error(socket, "trash_category", %{
          entity_type: "category",
          entity_uuid: category.uuid,
          reason: reason
        })

        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to delete category.")
         )}
    end
  end

  defp apply_in_scope_item_reorder(socket, catalogue_uuid, category_uuid, ordered_ids, moved_id) do
    case Catalogue.reorder_items(
           catalogue_uuid,
           category_uuid,
           ordered_ids,
           actor_opts(socket)
         ) do
      :ok ->
        scope = category_uuid || :uncategorized
        # Tell other open detail tabs to refresh this card + flash.
        PubSub.broadcast_card_refresh(catalogue_uuid, scope, moved_id, :ok)

        {:noreply,
         socket
         |> refresh_card_items(scope)
         |> flash_reorder(moved_id, :ok)}

      {:error, reason} ->
        log_operation_error(socket, "reorder_items", %{reason: reason})

        {:noreply,
         socket
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to reorder items.")
         )
         |> reset_and_load()
         |> flash_reorder(moved_id, :error)}
    end
  end

  # Pushes the `sortable:flash` event the SortableGrid hook listens for.
  # `moved_id` may be nil if a stale client missed the JS-side update;
  # we no-op in that case so the success/error flash isn't required.
  defp flash_reorder(socket, nil, _status), do: socket

  defp flash_reorder(socket, moved_id, status) when is_binary(moved_id) do
    push_event(socket, "sortable:flash", %{uuid: moved_id, status: to_string(status)})
  end

  # ── Helpers ─────────────────────────────────────────────────────

  # Graceful handler for an unreachable UI state: a delete event fires
  # while `confirm_delete` is nil (e.g. someone pushed the event without
  # first opening the modal). Clears the state, flashes a warning, and
  # logs a warning so we can see it in production without crashing the
  # LV and dropping the user's unrelated in-flight state.
  defp unexpected_confirm_event(socket, event_name) do
    Logger.warning(
      "Catalogue detail LV: #{event_name} fired without confirm_delete — assigns=#{inspect(socket.assigns.confirm_delete)} actor_uuid=#{inspect(actor_uuid(socket))}"
    )

    {:noreply,
     socket
     |> assign(:confirm_delete, nil)
     |> put_flash(
       :error,
       Gettext.gettext(PhoenixKitCatalogue.Gettext, "Unexpected request. Please try again.")
     )}
  end

  # actor_opts/1, actor_uuid/1, and log_operation_error/3 imported from
  # PhoenixKitCatalogue.Web.Helpers.

  # Resets paging state and loads the first batch. Called on mount, when
  # the user switches active/deleted tabs, and after any structural
  # change (category trash/restore/permanent-delete/reorder) because
  # those can affect which cards render and in what order.
  defp reset_and_load(socket) do
    uuid = socket.assigns.catalogue_uuid

    deleted_item_count = Catalogue.deleted_item_count_for_catalogue(uuid)
    deleted_category_count = Catalogue.deleted_category_count_for_catalogue(uuid)
    deleted_count = deleted_item_count + deleted_category_count

    relevant_count =
      case socket.assigns.tab do
        "categories" -> deleted_category_count
        _ -> deleted_item_count
      end

    view_mode =
      if relevant_count == 0 and socket.assigns.view_mode == "deleted",
        do: "active",
        else: socket.assigns.view_mode

    mode = view_mode_to_atom(view_mode)
    catalogue = Catalogue.fetch_catalogue!(uuid)
    tree = Catalogue.list_category_tree(uuid, mode: mode)
    category_list = Enum.map(tree, fn {cat, _depth} -> cat end)
    category_depths = Map.new(tree, fn {cat, depth} -> {cat.uuid, depth} end)
    category_counts = Catalogue.item_counts_by_category_for_catalogue(uuid, mode: mode)
    uncategorized_total = Catalogue.uncategorized_count_for_catalogue(uuid, mode: mode)

    items_tab_deleted? = view_mode == "deleted" and socket.assigns.tab == "items"

    deleted_items =
      if items_tab_deleted?,
        do: Catalogue.list_deleted_items_for_catalogue(uuid),
        else: []

    # Per-card preview build. Each category gets its first @per_card
    # items + a total; uncategorized too. The "Show N more" button on
    # each card requests the next slice via `expand_card`. Replaces the
    # global cursor walk + bottom-sentinel infinite scroll.
    loaded_cards =
      if items_tab_deleted? do
        []
      else
        build_loaded_cards(uuid, category_list, category_counts, uncategorized_total, mode)
      end

    socket
    |> assign(
      page_title: catalogue.name,
      catalogue: catalogue,
      category_list: category_list,
      category_depths: category_depths,
      category_counts: category_counts,
      uncategorized_total: uncategorized_total,
      loaded_cards: loaded_cards,
      deleted_count: deleted_count,
      active_item_count: Catalogue.item_count_for_catalogue(uuid),
      deleted_item_count: deleted_item_count,
      active_category_count: Catalogue.category_count_for_catalogue(uuid),
      deleted_category_count: deleted_category_count,
      view_mode: view_mode,
      deleted_items: deleted_items
    )
  end

  # Builds the full set of cards eagerly — one per category in display
  # order, then an Uncategorized card if applicable. Each card holds
  # its first @per_card items plus the total count so the template can
  # render a "Show N more" button when more items exist.
  defp build_loaded_cards(uuid, category_list, category_counts, uncategorized_total, mode) do
    category_cards =
      Enum.map(category_list, fn category ->
        total = Map.get(category_counts, category.uuid, 0)

        items =
          if total > 0,
            do:
              Catalogue.list_items_for_category_paged(category.uuid,
                mode: mode,
                offset: 0,
                limit: @per_card
              ),
            else: []

        %{kind: :category, category: category, items: items, total: total}
      end)

    if uncategorized_total > 0 do
      uncat_items =
        Catalogue.list_uncategorized_items_paged(uuid,
          mode: mode,
          offset: 0,
          limit: @per_card
        )

      category_cards ++
        [%{kind: :uncategorized, items: uncat_items, total: uncategorized_total}]
    else
      category_cards
    end
  end

  # Refreshes the header counts (Active / Deleted tabs) and the
  # per-category + uncategorized totals after an item mutation, without
  # reloading the card list. Preserves scroll position.
  #
  # Special case: when restoring/deleting drains the Deleted view to
  # zero, we have to flip back to Active and reset_and_load — otherwise
  # the loaded_cards (which were progressively drained by
  # `remove_item_locally`) keep rendering empty content for items that
  # are now active in another view. Symptom: badges show correct active
  # counts but the cards are blank.
  defp refresh_counts(socket) do
    uuid = socket.assigns.catalogue_uuid
    mode = view_mode_to_atom(socket.assigns.view_mode)
    items_tab_deleted? = socket.assigns.view_mode == "deleted" and socket.assigns.tab == "items"

    deleted_items =
      if items_tab_deleted?,
        do: Catalogue.list_deleted_items_for_catalogue(uuid),
        else: socket.assigns[:deleted_items] || []

    category_counts = Catalogue.item_counts_by_category_for_catalogue(uuid, mode: mode)
    uncategorized_total = Catalogue.uncategorized_count_for_catalogue(uuid, mode: mode)

    refreshed_cards =
      Enum.map(socket.assigns.loaded_cards, fn card ->
        case card do
          %{kind: :category, category: %{uuid: cat_uuid}} ->
            %{card | total: Map.get(category_counts, cat_uuid, 0)}

          %{kind: :uncategorized} ->
            %{card | total: uncategorized_total}
        end
      end)

    socket =
      assign(socket,
        deleted_count: Catalogue.deleted_count_for_catalogue(uuid),
        active_item_count: Catalogue.item_count_for_catalogue(uuid),
        deleted_item_count: Catalogue.deleted_item_count_for_catalogue(uuid),
        active_category_count: Catalogue.category_count_for_catalogue(uuid),
        deleted_category_count: Catalogue.deleted_category_count_for_catalogue(uuid),
        category_counts: category_counts,
        uncategorized_total: uncategorized_total,
        deleted_items: deleted_items,
        loaded_cards: refreshed_cards
      )

    maybe_auto_flip_to_active(socket)
  end

  # Per-tab auto-flip: Items tab uses deleted_item_count, Categories tab
  # uses deleted_category_count. Without tab awareness the user would
  # land in an empty Deleted view of one tab while the other tab still
  # had deleted entries (since `deleted_count` is the combined total).
  defp maybe_auto_flip_to_active(socket) do
    relevant_count =
      case socket.assigns.tab do
        "categories" -> socket.assigns.deleted_category_count
        _ -> socket.assigns.deleted_item_count
      end

    if relevant_count == 0 and socket.assigns.view_mode == "deleted" do
      socket
      |> assign(:view_mode, "active")
      |> reset_and_load()
    else
      socket
    end
  end

  # PubSub-driven refresh. Updates counts, the catalogue struct, and the
  # category list (so newly-created or renamed categories show up in the
  # tree without the user reloading), but **deliberately leaves**
  # `loaded_cards` and `cursor` alone. A full `reset_and_load` would wipe
  # the user's scroll state on every broadcast — combined with the
  # global PubSub topic, that turns into a perpetual spinner whenever
  # another admin (or the import wizard) is busy.
  #
  # Trade-off: an item that was deleted elsewhere may briefly remain
  # visible in `loaded_cards` until the user navigates or refreshes; the
  # counts will be correct, so the discrepancy is self-explanatory. The
  # `Ecto.NoResultsError` rescue in the caller handles the edge case
  # where this catalogue itself was deleted (caller redirects to index).
  defp refresh_in_place(socket) do
    uuid = socket.assigns.catalogue_uuid
    catalogue = Catalogue.fetch_catalogue!(uuid)
    mode = view_mode_to_atom(socket.assigns.view_mode)
    tree = Catalogue.list_category_tree(uuid, mode: mode)
    category_list = Enum.map(tree, fn {cat, _depth} -> cat end)
    category_depths = Map.new(tree, fn {cat, depth} -> {cat.uuid, depth} end)
    category_counts = Catalogue.item_counts_by_category_for_catalogue(uuid, mode: mode)
    uncategorized_total = Catalogue.uncategorized_count_for_catalogue(uuid, mode: mode)

    # Re-sync each card's `total` from the fresh counts so the
    # "Show N more (k)" button reflects current reality after a
    # cross-tab mutation. Loaded `items` lists are intentionally left
    # alone to preserve the user's expanded slice.
    refreshed_cards =
      Enum.map(socket.assigns.loaded_cards, fn card ->
        case card do
          %{kind: :category, category: %{uuid: cat_uuid}} ->
            %{card | total: Map.get(category_counts, cat_uuid, 0)}

          %{kind: :uncategorized} ->
            %{card | total: uncategorized_total}
        end
      end)

    socket
    |> assign(
      page_title: catalogue.name,
      catalogue: catalogue,
      category_list: category_list,
      category_depths: category_depths,
      category_counts: category_counts,
      uncategorized_total: uncategorized_total,
      loaded_cards: refreshed_cards,
      deleted_count: Catalogue.deleted_count_for_catalogue(uuid),
      active_item_count: Catalogue.item_count_for_catalogue(uuid),
      deleted_item_count: Catalogue.deleted_item_count_for_catalogue(uuid),
      active_category_count: Catalogue.category_count_for_catalogue(uuid),
      deleted_category_count: Catalogue.deleted_category_count_for_catalogue(uuid)
    )
    |> maybe_auto_flip_to_active()
  end

  # Runs a fresh search query asynchronously. If a prior search is still
  # in flight, `start_async/3` cancels it — so fast typing (type-pause-
  # type-pause) doesn't flash stale intermediate results as each old
  # request lands out of order. The actual assign happens in
  # `handle_async(:search, ...)`, guarded by a query equality check.
  defp run_search(socket, query) do
    uuid = socket.assigns.catalogue_uuid

    socket
    |> assign(search_query: query, search_loading: true)
    |> start_async(:search, fn ->
      results =
        Catalogue.search_items_in_catalogue(uuid, query, limit: @per_page, offset: 0)

      total = Catalogue.count_search_items_in_catalogue(uuid, query)
      {query, results, total}
    end)
  end

  @impl true
  def handle_async(:search, {:ok, {query, results, total}}, socket) do
    # Only apply if the user is still asking for this query. A late
    # response for a query the user has already superseded gets dropped.
    if socket.assigns.search_query == query do
      {:noreply,
       assign(socket,
         search_results: results,
         search_offset: length(results),
         search_total: total,
         search_has_more: length(results) < total,
         search_loading: false
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:search, {:exit, reason}, socket) do
    # Cancellations (reason `:shutdown` / `:killed` / `{:shutdown, _}`) are
    # expected when a newer query supersedes a pending one — the newer
    # handler owns `search_loading`, so leave the socket alone. For any
    # other exit (crashed DB query, timeout, raise in the task fn) clear
    # loading and flash the user so they don't stare at a perpetual
    # spinner, and log so we can debug without reproducing.
    case reason do
      r when r in [:shutdown, :killed] ->
        {:noreply, socket}

      {:shutdown, _} ->
        {:noreply, socket}

      other ->
        Logger.warning(
          "Catalogue detail LV search task exited unexpectedly: reason=#{inspect(other)} query=#{inspect(socket.assigns.search_query)} catalogue_uuid=#{inspect(socket.assigns.catalogue_uuid)} actor_uuid=#{inspect(actor_uuid(socket))}"
        )

        {:noreply,
         socket
         |> assign(:search_loading, false)
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search failed. Please try again.")
         )}
    end
  end

  def handle_async(:search_page, {:ok, {query, offset, page}}, socket) do
    # Same-shape guard as `:search`: only apply if the socket is still on
    # the query we paged for AND still expecting this offset. If the user
    # typed a new search mid-flight, `search_query` moved on; if they
    # somehow triggered a parallel page (shouldn't happen — `load_more`
    # checks `search_loading`), `search_offset` moved on.
    if socket.assigns.search_query == query and socket.assigns.search_offset == offset do
      new_offset = offset + length(page)
      # `page == []` protects against stale `search_total` (items
      # concurrently deleted) keeping `search_has_more` true forever.
      has_more = page != [] and new_offset < socket.assigns.search_total

      {:noreply,
       assign(socket,
         search_results: (socket.assigns.search_results || []) ++ page,
         search_offset: new_offset,
         search_has_more: has_more,
         search_loading: false
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:search_page, {:exit, reason}, socket) do
    case reason do
      r when r in [:shutdown, :killed] ->
        {:noreply, socket}

      {:shutdown, _} ->
        {:noreply, socket}

      other ->
        Logger.warning(
          "Catalogue detail LV search_page task exited unexpectedly: reason=#{inspect(other)} query=#{inspect(socket.assigns.search_query)} offset=#{socket.assigns.search_offset} catalogue_uuid=#{inspect(socket.assigns.catalogue_uuid)} actor_uuid=#{inspect(actor_uuid(socket))}"
        )

        {:noreply,
         socket
         |> assign(:search_loading, false)
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search failed. Please try again.")
         )}
    end
  end

  # Fires the next-page query off the LV process so scrolling a 50k-item
  # catalogue doesn't freeze the socket on every batch (ILIKE-against-
  # jsonb-as-text is not a fast query). Appending happens in
  # `handle_async(:search_page, …)` guarded by `{query, offset}` so a
  # superseding new search or a double-scroll can't double-append.
  defp start_search_page(socket) do
    %{catalogue_uuid: uuid, search_query: query, search_offset: offset} = socket.assigns

    socket
    |> assign(:search_loading, true)
    |> start_async(:search_page, fn ->
      page = Catalogue.search_items_in_catalogue(uuid, query, limit: @per_page, offset: offset)
      {query, offset, page}
    end)
  end

  defp clear_search(socket) do
    assign(socket,
      search_query: "",
      search_results: nil,
      search_offset: 0,
      search_total: 0,
      search_has_more: false,
      search_loading: false
    )
  end

  # Removes a trashed/restored/deleted item from its card's items list
  # in place. No DB reload, so scroll position is preserved.
  defp remove_item_locally(socket, item_uuid) do
    cards =
      Enum.map(socket.assigns.loaded_cards, fn card ->
        Map.update!(card, :items, fn items ->
          Enum.reject(items, &(&1.uuid == item_uuid))
        end)
      end)

    assign(socket, :loaded_cards, cards)
  end

  # Re-fetches the items inside a single loaded card after an in-place
  # change (DnD reorder, cross-category move). `scope` is the
  # category UUID, or `:uncategorized` for the no-category bucket.
  # Cards that don't match the scope pass through untouched. Cursor /
  # has_more / loading are all left alone — scroll state is preserved.
  #
  # `delta` adjusts the loaded count for the affected card:
  #   * `0` — in-scope reorder (count unchanged)
  #   * `+1` — destination card after a cross-category drop
  #   * `-1` — source card after a cross-category drop
  # Without this, every refresh used to pad +1 unconditionally and the
  # loaded set crept up by one per reorder.
  defp refresh_card_items(socket, scope, delta \\ 0) do
    catalogue_uuid = socket.assigns.catalogue_uuid
    mode = view_mode_to_atom(socket.assigns.view_mode)

    fresh_total = card_total(scope, catalogue_uuid, mode)

    cards =
      Enum.map(socket.assigns.loaded_cards, fn card ->
        if card_matches_scope?(card, scope) do
          # Keep the same loaded slice (clamped to the new total) so a
          # reorder/move doesn't collapse a card the user expanded.
          limit = max(length(card.items) + delta, @per_card)
          fresh = fetch_card_items(scope, catalogue_uuid, mode, limit)
          %{card | items: fresh, total: fresh_total}
        else
          card
        end
      end)

    assign(socket, :loaded_cards, cards)
  end

  defp card_total(:uncategorized, catalogue_uuid, mode) do
    Catalogue.uncategorized_count_for_catalogue(catalogue_uuid, mode: mode)
  end

  defp card_total(category_uuid, catalogue_uuid, mode) when is_binary(category_uuid) do
    Catalogue.item_counts_by_category_for_catalogue(catalogue_uuid, mode: mode)
    |> Map.get(category_uuid, 0)
  end

  defp card_matches_scope?(%{kind: :category, category: %{uuid: uuid}}, scope)
       when is_binary(scope),
       do: uuid == scope

  defp card_matches_scope?(%{kind: :uncategorized}, :uncategorized), do: true
  defp card_matches_scope?(_, _), do: false

  defp fetch_card_items(scope, catalogue_uuid, mode, limit, offset \\ 0)

  defp fetch_card_items(:uncategorized, catalogue_uuid, mode, limit, offset) do
    Catalogue.list_uncategorized_items_paged(catalogue_uuid,
      mode: mode,
      offset: offset,
      limit: limit
    )
  end

  defp fetch_card_items(category_uuid, _catalogue_uuid, mode, limit, offset)
       when is_binary(category_uuid) do
    Catalogue.list_items_for_category_paged(category_uuid,
      mode: mode,
      offset: offset,
      limit: limit
    )
  end

  # Reloads the category tree (positions changed) and re-sorts
  # `loaded_cards` to match — without touching the cursor. Used after
  # category DnD so the user's scroll state is preserved.
  defp refresh_categories_in_place(socket) do
    uuid = socket.assigns.catalogue_uuid
    mode = view_mode_to_atom(socket.assigns.view_mode)
    tree = Catalogue.list_category_tree(uuid, mode: mode)
    category_list = Enum.map(tree, fn {cat, _depth} -> cat end)
    category_depths = Map.new(tree, fn {cat, depth} -> {cat.uuid, depth} end)

    # Build a position index so we can re-sort `loaded_cards` to match
    # the new tree order. The Uncategorized card stays at the end.
    tree_index =
      tree
      |> Enum.with_index()
      |> Map.new(fn {{cat, _depth}, idx} -> {cat.uuid, idx} end)

    sorted_cards =
      socket.assigns.loaded_cards
      |> Enum.sort_by(fn
        %{kind: :category, category: %{uuid: uuid}} ->
          Map.get(tree_index, uuid, :infinity)

        %{kind: :uncategorized} ->
          :end_of_list
      end)

    assign(socket,
      category_list: category_list,
      category_depths: category_depths,
      loaded_cards: sorted_cards
    )
  end

  defp view_mode_to_atom("active"), do: :active
  defp view_mode_to_atom("deleted"), do: :deleted

  # Processes a flat list of category UUIDs that came back from the
  # detail-view DnD. Categories live in a parent-scoped tree, but the
  # client sees them as one ordered list. We group the dropped order by
  # `parent_uuid`, preserve the relative order inside each group, and
  # hand the whole batch to `Catalogue.reorder_categories_groups/3` —
  # one outer transaction so partial failure can't leave the tree in
  # a half-reordered state. UUIDs whose parent changed are silently
  # kept under their original parent — DnD here is for sibling-only
  # reorder, not reparenting.
  defp apply_category_reorder(socket, ordered_ids, moved_id) do
    by_uuid = Map.new(socket.assigns.category_list, fn %Category{} = c -> {c.uuid, c} end)

    groups =
      ordered_ids
      |> Enum.flat_map(fn id ->
        case Map.fetch(by_uuid, id) do
          {:ok, c} -> [{c.parent_uuid, id}]
          :error -> []
        end
      end)
      |> Enum.group_by(fn {parent_uuid, _id} -> parent_uuid end, fn {_parent, id} -> id end)
      |> Enum.into([])

    result =
      Catalogue.reorder_categories_groups(
        socket.assigns.catalogue_uuid,
        groups,
        actor_opts(socket)
      )

    socket = refresh_categories_in_place(socket)

    case result do
      :ok ->
        # Other open tabs need a full reset_and_load to pick up the new
        # category order — affects how every streamed card renders.
        PubSub.broadcast_category_reorder(socket.assigns.catalogue_uuid, moved_id, :ok)
        {:noreply, flash_reorder(socket, moved_id, :ok)}

      {:error, reason} ->
        log_operation_error(socket, "reorder_categories", %{reason: reason})

        {:noreply,
         socket
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to reorder categories.")
         )
         |> reset_and_load()
         |> flash_reorder(moved_id, :error)}
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value) when is_binary(value), do: value

  # ── Render ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-5xl px-4 py-6 gap-6">
      <%!-- Loading state --%>
      <div :if={is_nil(@catalogue)} class="flex justify-center py-12">
        <span class="loading loading-spinner loading-lg"></span>
      </div>

      <div :if={@catalogue} class="flex flex-col gap-6">
        <%!-- Header --%>
        <.admin_page_header back={Paths.index()} title={@catalogue.name}>
          <:actions :if={@view_mode == "active"}>
            <.link navigate={Paths.category_new(@catalogue.uuid)} class="btn btn-outline btn-sm">
              <.icon name="hero-folder-plus" class="w-4 h-4" /> {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Add Category")}
            </.link>
            <.link navigate={Paths.item_new(@catalogue.uuid)} class="btn btn-primary btn-sm">
              <.icon name="hero-plus" class="w-4 h-4" /> {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Add Item")}
            </.link>
            <.link navigate={Paths.catalogue_edit(@catalogue.uuid)} class="btn btn-ghost btn-sm">
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit")}
            </.link>
          </:actions>
        </.admin_page_header>

        <div :if={@catalogue.description} class="-mt-4">
          <p class="text-base-content/60">
            {@catalogue.description}
          </p>
        </div>

        <%!-- Items / Categories tab bar + per-tab Active/Deleted mode
             switcher on the same row. The switcher's counts and
             visibility track the current tab. --%>
        <div class="flex items-end justify-between border-b border-base-200 gap-4">
          <div role="tablist" class="tabs tabs-bordered border-none">
            <button
              type="button"
              role="tab"
              phx-click="switch_tab"
              phx-value-tab="items"
              class={["tab", @tab == "items" && "tab-active"]}
            >
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Items")}
            </button>
            <button
              type="button"
              role="tab"
              phx-click="switch_tab"
              phx-value-tab="categories"
              class={["tab", @tab == "categories" && "tab-active"]}
            >
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Categories")} ({length(@category_list)})
            </button>
          </div>

          <%!-- Inline mode switcher. Visibility per-tab: Items tab
               shows it when deleted_item_count > 0 (or already in
               deleted view); Categories tab uses the category count.
               Hidden during a live search. --%>
          <div
            :if={
              is_nil(@search_results) and not @search_loading and
                ((@tab == "items" and (@deleted_item_count > 0 or @view_mode == "deleted")) or
                   (@tab == "categories" and
                      (@deleted_category_count > 0 or @view_mode == "deleted")))
            }
            class="flex items-center gap-0.5 pb-1"
          >
            <button
              type="button"
              phx-click="switch_view"
              phx-value-mode="active"
              class={[
                "px-3 py-1.5 text-xs font-medium border-b-2 transition-colors cursor-pointer",
                if(@view_mode == "active",
                  do: "border-primary text-primary",
                  else: "border-transparent text-base-content/50 hover:text-base-content"
                )
              ]}
            >
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Active")} ({if @tab == "categories",
                do: @active_category_count,
                else: @active_item_count})
            </button>
            <button
              type="button"
              phx-click="switch_view"
              phx-value-mode="deleted"
              class={[
                "px-3 py-1.5 text-xs font-medium border-b-2 transition-colors cursor-pointer",
                if(@view_mode == "deleted",
                  do: "border-error text-error",
                  else: "border-transparent text-base-content/50 hover:text-base-content"
                )
              ]}
            >
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Deleted")} ({if @tab == "categories",
                do: @deleted_category_count,
                else: @deleted_item_count})
            </button>
          </div>
        </div>

        <%!-- ── Items tab ────────────────────────────────────────── --%>
        <div :if={@tab == "items"} class="flex flex-col gap-6">
          <%!-- Search (Items tab only — Categories tab has no search yet) --%>
          <.search_input :if={@view_mode == "active"} query={@search_query} placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search items by name, description, or SKU...")} />

          <%!-- Combined row: bulk-action contents on the left (when
               items are selected), card/table view toggle on the right.
               Becomes sticky + styled when bulk is active so the
               actions stay reachable while the user scrolls. --%>
          <div
            :if={MapSet.size(@selected_items) > 0 or @category_list != []}
            class={[
              "flex items-center justify-between gap-3",
              MapSet.size(@selected_items) > 0 &&
                "sticky top-[72px] z-40 -mx-1 px-3 py-2 rounded-lg bg-base-100/95 border border-primary/40 shadow-md backdrop-blur"
            ]}
          >
            <.items_bulk_actions
              :if={MapSet.size(@selected_items) > 0}
              count={MapSet.size(@selected_items)}
              view_mode={@view_mode}
            />
            <%!-- Spacer keeps justify-between pushing the toggle right
                 when nothing is selected. --%>
            <div :if={MapSet.size(@selected_items) == 0}></div>
            <.view_mode_toggle :if={@category_list != []} storage_key="catalogue-detail-items" />
          </div>

        <%!-- Search results (visible when the user has typed a query) --%>
        <div :if={@search_results != nil or @search_loading} class="flex flex-col gap-4">
          <%!-- Status line: spinner while loading, "X of Y results" when settled --%>
          <div class="flex items-center gap-2">
            <%= if @search_loading and is_nil(@search_results) do %>
              <span class="text-sm text-base-content/60">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Searching for \"%{query}\"...", query: @search_query)}
              </span>
            <% else %>
              <.search_results_summary :if={@search_results != nil} count={@search_total} query={@search_query} loaded={length(@search_results)} />
            <% end %>
            <span :if={@search_loading} class="loading loading-spinner loading-xs text-base-content/40"></span>
          </div>

          <.empty_state :if={@search_results == [] and not @search_loading} message={Gettext.gettext(PhoenixKitCatalogue.Gettext, "No items match your search.")} />

          <%!-- Stale results are dimmed while a newer query is in flight to
               signal that the list is about to update. --%>
          <div :if={@search_results not in [nil, []]} class={["transition-opacity", @search_loading && "opacity-50"]}>
            <.item_table
              items={@search_results}
              columns={[:name, :sku, :price, :unit, :status]}
              markup_percentage={@catalogue.markup_percentage}
              edit_path={&Paths.item_edit/1}
              pdf_search_event="show_pdf_search"
              cards={true}
              show_toggle={false}
              storage_key="catalogue-detail-items"
              id="catalogue-search-items"
            />
          </div>

          <%!-- Infinite-scroll sentinel for search results --%>
          <div
            :if={@search_has_more and not @search_loading}
            id="search-load-more-sentinel"
            phx-hook="InfiniteScroll"
            data-cursor={"search-#{@search_offset}"}
            class="py-4"
          >
            <div class="flex justify-center">
              <span class="loading loading-spinner loading-sm text-base-content/30"></span>
            </div>
          </div>
        </div>

        <%!-- Status switcher moved to the tabs row above. --%>

        <%!-- Empty states --%>
        <div :if={is_nil(@search_results) and not @search_loading and @loaded_cards == [] and @view_mode == "active"} class="card bg-base-100 shadow">
          <div class="card-body items-center text-center py-12">
            <p class="text-base-content/60">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "No categories or items yet. Add a category or item to get started.")}</p>
          </div>
        </div>

        <div :if={is_nil(@search_results) and not @search_loading and @deleted_items == [] and @view_mode == "deleted"} class="card bg-base-100 shadow">
          <div class="card-body items-center text-center py-12">
            <p class="text-base-content/60">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "No deleted items.")}</p>
          </div>
        </div>

        <%!-- Active view: every category card eagerly rendered with a
             25-item preview. Each card has its own "Show N more"
             button (PdfSearchModal-style per-group expand) so the user
             can scan the catalogue's structure at a glance and drill
             into the categories they care about. --%>
        <div
          :if={is_nil(@search_results) and not @search_loading and @view_mode == "active" and @loaded_cards != []}
          id="catalogue-detail-cards"
          class="flex flex-col gap-6"
        >
          <%= for {card, card_idx} <- Enum.with_index(@loaded_cards) do %>
            <div>
              <.detail_card
                card={card}
                card_idx={card_idx}
                view_mode={@view_mode}
                category_total={length(@category_list)}
                category_counts={@category_counts}
                category_depths={@category_depths}
                category_list={@category_list}
                uncategorized_total={@uncategorized_total}
                catalogue={@catalogue}
                selected_items={@selected_items}
                expanding={MapSet.member?(@expanding_cards, scope_key(card))}
              />
            </div>
          <% end %>
        </div>

        <%!-- Deleted view: flat list ordered by deletion date. No
             category grouping — the boss wants a recency-ordered audit
             list, not a tree. --%>
        <div
          :if={is_nil(@search_results) and not @search_loading and @view_mode == "deleted" and @deleted_items != []}
          id="catalogue-detail-deleted-items"
        >
          <.item_table
            items={@deleted_items}
            columns={[:name, :sku, :unit, :status]}
            on_restore="restore_item"
            on_permanent_delete="show_delete_confirm"
            permanent_delete_type="item"
            cards={true}
            show_toggle={false}
            storage_key="catalogue-detail-items"
            id="catalogue-deleted-items"
            selectable={true}
            selected_uuids={@selected_items}
            on_toggle_select="toggle_select_item"
          />
        </div>
        </div>
        <%!-- ── /Items tab ───────────────────────────────────────── --%>

        <%!-- ── Categories tab ───────────────────────────────────── --%>
        <div :if={@tab == "categories"} class="flex flex-col gap-4">
          <%!-- Bulk-action bar for categories. Active view: Delete (opens
               disposition modal in bulk mode). Deleted view: Restore.
               Selection cleared on tab/view-mode switch. --%>
          <.categories_bulk_bar
            :if={MapSet.size(@selected_categories) > 0}
            count={MapSet.size(@selected_categories)}
            view_mode={@view_mode}
          />

          <%!-- Status switcher moved to the tabs row above. --%>

          <% visible_category_count =
            if @view_mode == "deleted", do: @deleted_category_count, else: @active_category_count %>

          <div :if={visible_category_count == 0} class="card bg-base-100 shadow">
            <div class="card-body items-center text-center py-12">
              <p class="text-base-content/60">
                {if @view_mode == "deleted",
                  do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "No deleted categories."),
                  else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "No categories yet. Add one to start organizing items.")}
              </p>
              <.link :if={@view_mode == "active"} navigate={Paths.category_new(@catalogue.uuid)} class="btn btn-primary btn-sm mt-2">
                <.icon name="hero-folder-plus" class="w-4 h-4" /> {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Add Category")}
              </.link>
            </div>
          </div>

          <%!-- Flat list of categories with depth indent. Same DnD wiring
               as the Items tab so reorder works identically. --%>
          <div
            :if={visible_category_count > 0}
            id="catalogue-categories-list"
            class="flex flex-col gap-2"
            data-sortable="true"
            data-sortable-event="reorder_categories"
            data-sortable-items=".sortable-item"
            data-sortable-hide-source="false"
            data-sortable-group="catalogue-categories-tab"
            data-sortable-handle=".pk-drag-handle"
            phx-hook={if @view_mode == "active", do: "SortableGrid"}
          >
            <%= for cat <- @category_list do %>
              <.category_row
                category={cat}
                depth={Map.get(@category_depths, cat.uuid, 0)}
                count={Map.get(@category_counts, cat.uuid, 0)}
                view_mode={@view_mode}
                sibling_count={Enum.count(@category_list, &(&1.parent_uuid == cat.parent_uuid))}
                selected={MapSet.member?(@selected_categories, cat.uuid)}
              />
            <% end %>
          </div>
        </div>
        <%!-- ── /Categories tab ──────────────────────────────────── --%>
      </div>

      <.confirm_modal
        show={match?({"item", _}, @confirm_delete)}
        on_confirm="permanently_delete_item"
        on_cancel="cancel_delete"
        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Permanently Delete Item")}
        title_icon="hero-trash"
        messages={[{:warning, Gettext.gettext(PhoenixKitCatalogue.Gettext, "This item will be permanently deleted. This cannot be undone.")}]}
        confirm_text={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete Forever")}
        danger={true}
      />

      <.confirm_modal
        show={match?({"category", _}, @confirm_delete)}
        on_confirm="permanently_delete_category"
        on_cancel="cancel_delete"
        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Permanently Delete Category")}
        title_icon="hero-trash"
        messages={[{:warning, Gettext.gettext(PhoenixKitCatalogue.Gettext, "This category and all its items will be permanently deleted. This cannot be undone.")}]}
        confirm_text={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete Forever")}
        danger={true}
      />

      <%!-- "What about the items?" modal — opens when the operator
           clicks Delete on a category that still has active items in
           its V103 subtree. The boss's rule: deleting the category
           shouldn't drag the items down with it; the operator picks
           a destination first. --%>
      <.confirm_modal
        :if={@trash_modal}
        show={true}
        on_confirm="confirm_trash_category"
        on_cancel="cancel_trash_category"
        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete category — what about the items?")}
        title_icon="hero-folder-minus"
        confirm_text={
          if @trash_modal[:disposition] == :cascade,
            do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete category and items"),
            else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move items and delete category")
        }
        confirm_disabled={
          @trash_modal[:disposition] == :move_to and is_nil(@trash_modal[:target_uuid])
        }
        danger={true}
      >
        <p class="text-sm text-base-content/70">
          <strong>{@trash_modal[:category].name}</strong>
          {Gettext.gettext(
            PhoenixKitCatalogue.Gettext,
            "and its subtree contain %{count} active items. Choose where they should go before the category is deleted.",
            count: @trash_modal[:item_count]
          )}
        </p>

        <div class="space-y-3 mt-4">
          <%!-- Option 1: uncategorize (no further input needed) --%>
          <label class="flex items-start gap-3 p-3 rounded-lg border border-base-300 cursor-pointer hover:bg-base-200/50">
            <input
              type="radio"
              name="trash_disposition"
              value="uncategorize"
              checked={@trash_modal[:disposition] == :uncategorize}
              phx-click="set_trash_disposition"
              phx-value-disposition="uncategorize"
              class="radio radio-sm radio-primary mt-0.5"
            />
            <div class="flex-1 min-w-0">
              <p class="font-medium text-sm">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Make items uncategorized")}
              </p>
              <p class="text-xs text-base-content/60">
                {Gettext.gettext(
                  PhoenixKitCatalogue.Gettext,
                  "Items stay in this catalogue but are no longer attached to any category."
                )}
              </p>
            </div>
          </label>

          <%!-- Option 2: move to another category in the same catalogue.
               Only meaningful when there's a sibling/elsewhere to move to;
               we still render the radio when the list is empty so the UI
               is symmetric, but the dropdown shows an empty-state hint. --%>
          <label class="flex items-start gap-3 p-3 rounded-lg border border-base-300 cursor-pointer hover:bg-base-200/50">
            <input
              type="radio"
              name="trash_disposition"
              value="move_to"
              checked={@trash_modal[:disposition] == :move_to}
              phx-click="set_trash_disposition"
              phx-value-disposition="move_to"
              class="radio radio-sm radio-primary mt-0.5"
            />
            <div class="flex-1 min-w-0">
              <p class="font-medium text-sm">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move items to another category")}
              </p>
              <p class="text-xs text-base-content/60 mb-2">
                {Gettext.gettext(
                  PhoenixKitCatalogue.Gettext,
                  "Pick a target category in this catalogue. The category being deleted and its subtree are excluded."
                )}
              </p>
              <%= if @trash_modal[:targets] == [] do %>
                <p class="text-xs text-warning">
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No other categories available — use Uncategorized instead.")}
                </p>
              <% else %>
                <select
                  name="category_uuid"
                  phx-change="select_trash_target"
                  disabled={@trash_modal[:disposition] != :move_to}
                  class="select select-sm select-bordered w-full"
                >
                  <option value="">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "-- Select category --")}</option>
                  <%= for {cat, depth} <- @trash_modal[:targets] do %>
                    <option value={cat.uuid} selected={@trash_modal[:target_uuid] == cat.uuid}>
                      {String.duplicate("— ", depth)}{cat.name}
                    </option>
                  <% end %>
                </select>
              <% end %>
            </div>
          </label>

          <%!-- Option 3: cascade — items follow the category to the
               Deleted view. Soft-delete, restorable. The "I want everything
               gone" path; not the default since the boss specifically
               disliked this being implicit. --%>
          <label class="flex items-start gap-3 p-3 rounded-lg border border-error/30 cursor-pointer hover:bg-error/5">
            <input
              type="radio"
              name="trash_disposition"
              value="cascade"
              checked={@trash_modal[:disposition] == :cascade}
              phx-click="set_trash_disposition"
              phx-value-disposition="cascade"
              class="radio radio-sm radio-error mt-0.5"
            />
            <div class="flex-1 min-w-0">
              <p class="font-medium text-sm text-error">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete items along with the category")}
              </p>
              <p class="text-xs text-base-content/60">
                {Gettext.gettext(
                  PhoenixKitCatalogue.Gettext,
                  "Items move to the Deleted view alongside the category. Both can be restored later."
                )}
              </p>
            </div>
          </label>
        </div>
      </.confirm_modal>

      <%!-- Bulk-action confirm modal (for items: trash or permanent
           delete; categories use the trash_modal in bulk mode for the
           item-disposition picker). --%>
      <.confirm_modal
        :if={@bulk_confirm}
        show={true}
        on_confirm="confirm_bulk_action"
        on_cancel="cancel_bulk_action"
        title={
          case @bulk_confirm[:mode] do
            :permanent -> Gettext.gettext(PhoenixKitCatalogue.Gettext, "Permanently delete selected items?")
            _ -> Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete selected items?")
          end
        }
        title_icon="hero-trash"
        confirm_text={
          case @bulk_confirm[:mode] do
            :permanent -> Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete forever")
            _ -> Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")
          end
        }
        danger={true}
        messages={
          case @bulk_confirm[:mode] do
            :permanent ->
              [
                {:warning,
                 Gettext.gettext(PhoenixKitCatalogue.Gettext, "%{count} items will be permanently deleted. This cannot be undone.", count: @bulk_confirm[:count])}
              ]

            _ ->
              [
                {:warning,
                 Gettext.gettext(PhoenixKitCatalogue.Gettext, "%{count} items will be moved to the Deleted view. They can be restored later.", count: @bulk_confirm[:count])}
              ]
          end
        }
      />

      <%!-- Bulk-move modal for items — same shape as the trash modal's
           Move-to-another-category branch but applied to all selected
           items. --%>
      <.confirm_modal
        :if={@bulk_move_modal}
        show={true}
        on_confirm="confirm_bulk_move_items"
        on_cancel="cancel_bulk_move"
        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move selected items")}
        title_icon="hero-arrows-right-left"
        confirm_text={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move items")}
        confirm_disabled={
          @bulk_move_modal[:disposition] == :move_to and is_nil(@bulk_move_modal[:target_uuid])
        }
      >
        <p class="text-sm text-base-content/70">
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Pick where %{count} items should go.", count: @bulk_move_modal[:count])}
        </p>

        <div class="space-y-3 mt-4">
          <label class="flex items-start gap-3 p-3 rounded-lg border border-base-300 cursor-pointer hover:bg-base-200/50">
            <input
              type="radio"
              name="bulk_move_disposition"
              value="uncategorize"
              checked={@bulk_move_modal[:disposition] == :uncategorize}
              phx-click="set_bulk_move_disposition"
              phx-value-disposition="uncategorize"
              class="radio radio-sm radio-primary mt-0.5"
            />
            <div class="flex-1 min-w-0">
              <p class="font-medium text-sm">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Make items uncategorized")}
              </p>
              <p class="text-xs text-base-content/60">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Items keep their catalogue but lose their category.")}
              </p>
            </div>
          </label>

          <label class="flex items-start gap-3 p-3 rounded-lg border border-base-300 cursor-pointer hover:bg-base-200/50">
            <input
              type="radio"
              name="bulk_move_disposition"
              value="move_to"
              checked={@bulk_move_modal[:disposition] == :move_to}
              phx-click="set_bulk_move_disposition"
              phx-value-disposition="move_to"
              class="radio radio-sm radio-primary mt-0.5"
            />
            <div class="flex-1 min-w-0">
              <p class="font-medium text-sm">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move items to another category")}
              </p>
              <%= if @bulk_move_modal[:targets] == [] do %>
                <p class="text-xs text-warning">
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No categories available — use Uncategorized instead.")}
                </p>
              <% else %>
                <select
                  name="category_uuid"
                  phx-change="select_bulk_move_target"
                  disabled={@bulk_move_modal[:disposition] != :move_to}
                  class="select select-sm select-bordered w-full mt-2"
                >
                  <option value="">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "-- Select category --")}</option>
                  <%= for {cat, depth} <- @bulk_move_modal[:targets] do %>
                    <option value={cat.uuid} selected={@bulk_move_modal[:target_uuid] == cat.uuid}>
                      {String.duplicate("— ", depth)}{cat.name}
                    </option>
                  <% end %>
                </select>
              <% end %>
            </div>
          </label>
        </div>
      </.confirm_modal>

      <.live_component
        :if={@pdf_search_item}
        module={PdfSearchModal}
        id="catalogue-detail-pdf-search"
        item={@pdf_search_item}
        show={@show_pdf_search}
      />
    </div>

    <script>
      window.PhoenixKitHooks = window.PhoenixKitHooks || {};
      window.PhoenixKitHooks.InfiniteScroll = window.PhoenixKitHooks.InfiniteScroll || {
        mounted() {
          this.intersecting = false;
          this.observer = new IntersectionObserver((entries) => {
            this.intersecting = entries[0].isIntersecting;
            if (this.intersecting) {
              this.pushEvent("load_more", {});
            }
          }, { rootMargin: "200px" });
          this.observer.observe(this.el);
        },
        updated() {
          // IntersectionObserver only fires on state transitions. When the
          // viewport is tall or the user jumped via Page Down / resize, the
          // sentinel stays continuously in view across batches — so the
          // observer goes silent after the first fire. Re-trigger explicitly
          // whenever the server patches us while we're still on-screen.
          // The server's `loading` guard dedupes duplicate events.
          if (this.intersecting) {
            this.pushEvent("load_more", {});
          }
        },
        destroyed() {
          this.observer.disconnect();
        }
      };
    </script>
    """
  end

  # Renders one card in the detail view: a category with its
  # progressively-loaded items, or the Uncategorized bucket.
  attr(:card, :map, required: true)
  attr(:card_idx, :integer, required: true)
  attr(:view_mode, :string, required: true)
  attr(:category_total, :integer, required: true)
  attr(:category_counts, :map, required: true)
  attr(:category_depths, :map, default: %{})
  attr(:category_list, :list, default: [])
  attr(:uncategorized_total, :integer, required: true)
  attr(:catalogue, :any, required: true)
  attr(:selected_items, :any, default: nil)
  attr(:expanding, :boolean, default: false)

  defp detail_card(%{card: %{kind: :category}} = assigns) do
    %{uuid: uuid} = assigns.card.category

    assigns =
      assigns
      |> assign(:total, assigns.card[:total] || Map.get(assigns.category_counts, uuid, 0))
      |> assign(:depth, Map.get(assigns.category_depths, uuid, 0))
      |> assign(:loaded, length(assigns.card.items))

    ~H"""
    <div
      :if={@view_mode == "active" or @card.category.status == "deleted" or @total > 0}
      class="card bg-base-100 shadow"
      style={"margin-left: #{@depth * 1.5}rem"}
    >
      <div class="card-body">
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-2">
            <h3
              class={["card-title text-lg", @card.category.status == "deleted" && "text-error/70"]}
            >
              {@card.category.name}
            </h3>
            <%!-- Active categories: hover-revealed pencil icon to edit
                 (replaces the old Edit button, per the boss). Delete
                 moves into the bulk-action bar via row checkboxes. --%>
            <.link
              :if={@view_mode == "active" and @card.category.status == "active"}
              navigate={Paths.category_edit(@card.category.uuid)}
              class="text-base-content/40 hover:text-primary"
              title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit category")}
            >
              <.icon name="hero-pencil" class="w-4 h-4" />
            </.link>
            <span :if={@card.category.status == "deleted"} class="badge badge-error badge-xs">deleted</span>
            <span class="badge badge-ghost badge-sm">{@total} {Gettext.gettext(PhoenixKitCatalogue.Gettext, "items")}</span>
          </div>

          <%!-- Active mode: no per-card buttons. The Items tab is
               read-only structure; deletion happens via item-level
               selection or via the Categories tab. --%>

          <%!-- Deleted mode: Restore + Permanent Delete (for deleted categories) --%>
          <div :if={@view_mode == "deleted" && @card.category.status == "deleted"} class="flex gap-1">
            <button
              phx-click="restore_category"
              phx-value-uuid={@card.category.uuid}
              phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restoring...")}
              class="inline-flex items-center gap-1.5 px-2.5 h-[2.5em] rounded-lg border border-success/30 bg-success/10 hover:bg-success/20 text-success text-xs font-medium transition-colors cursor-pointer"
            >
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restore")}
            </button>
            <button
              phx-click="show_delete_confirm"
              phx-value-uuid={@card.category.uuid}
              phx-value-type="category"
              class="inline-flex items-center gap-1.5 px-2.5 h-[2.5em] rounded-lg border border-error/30 bg-error/10 hover:bg-error/20 text-error text-xs font-medium transition-colors cursor-pointer"
            >
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete Forever")}
            </button>
          </div>
        </div>

        <p :if={@card.category.description && @view_mode == "active"} class="text-sm text-base-content/60">
          {@card.category.description}
        </p>

        <%!-- Items table: active mode --%>
        <div :if={@card.items != [] and @view_mode == "active"} class="mt-2">
          <.item_table
            items={@card.items}
            columns={[:name, :sku, :price, :unit, :status]}
            markup_percentage={@catalogue.markup_percentage}
            edit_path={&Paths.item_edit/1}
            on_delete="delete_item"
            pdf_search_event="show_pdf_search"
            cards={true}
            show_toggle={false}
            storage_key="catalogue-detail-items"
            id={"cat-items-active-#{@card.category.uuid}"}
            wrapper_class="overflow-x-auto shadow-none rounded-none"
            on_reorder="reorder_items"
            reorder_group="catalogue-items"
            reorder_scope={%{
              catalogue_uuid: @catalogue.uuid,
              category_uuid: @card.category.uuid
            }}
            selectable={true}
            selected_uuids={@selected_items}
            on_toggle_select="toggle_select_item"
          />
          <%!-- Per-category "Show N more" — same expand-on-demand
               pattern as the PDF search modal. --%>
          <div :if={@loaded < @total} class="flex justify-center pt-2">
            <button
              type="button"
              phx-click="expand_card"
              phx-value-scope={@card.category.uuid}
              disabled={@expanding}
              class="btn btn-ghost btn-xs"
            >
              <%= if @expanding do %>
                <span class="loading loading-spinner loading-xs"></span>
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Loading…")}
              <% else %>
                <.icon name="hero-chevron-down" class="w-3 h-3" />
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Show %{n} more", n: @total - @loaded)}
              <% end %>
            </button>
          </div>
        </div>
        <%!-- Items table: deleted mode --%>
        <div :if={@card.items != [] and @view_mode == "deleted"} class="mt-2">
          <.item_table
            items={@card.items}
            columns={[:name, :sku, :price, :unit, :status]}
            markup_percentage={@catalogue.markup_percentage}
            on_restore="restore_item"
            on_permanent_delete="show_delete_confirm"
            permanent_delete_type="item"
            cards={true}
            show_toggle={false}
            storage_key="catalogue-detail-items"
            id={"cat-items-deleted-#{@card.category.uuid}"}
            wrapper_class="overflow-x-auto shadow-none rounded-none"
          />
        </div>

        <p :if={@card.items == [] and @view_mode == "active"} class="text-sm text-base-content/40 text-center py-4">
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No items in this category.")}
        </p>
      </div>
    </div>
    """
  end

  defp detail_card(%{card: %{kind: :uncategorized}} = assigns) do
    assigns = assign(assigns, :loaded, length(assigns.card.items))

    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body">
        <div :if={@category_total > 0} class="flex items-center gap-2">
          <h3 class="card-title text-lg text-base-content/70">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Uncategorized")}</h3>
          <span class="badge badge-ghost badge-sm">{@uncategorized_total} {Gettext.gettext(PhoenixKitCatalogue.Gettext, "items")}</span>
        </div>

        <div class={if @category_total > 0, do: "mt-2", else: ""}>
          <.item_table
            items={@card.items}
            columns={[:name, :sku, :unit, :status]}
            edit_path={if @view_mode == "active", do: &Paths.item_edit/1}
            on_delete={if @view_mode == "active", do: "delete_item"}
            on_restore={if @view_mode == "deleted", do: "restore_item"}
            on_permanent_delete={if @view_mode == "deleted", do: "show_delete_confirm"}
            permanent_delete_type="item"
            pdf_search_event={if @view_mode == "active", do: "show_pdf_search"}
            cards={true}
            show_toggle={false}
            storage_key="catalogue-detail-items"
            id={"uncategorized-items-#{@card_idx}"}
            on_reorder={if @view_mode == "active", do: "reorder_items"}
            reorder_group="catalogue-items"
            reorder_scope={%{
              catalogue_uuid: @catalogue.uuid,
              category_uuid: nil
            }}
            selectable={@view_mode == "active"}
            selected_uuids={@selected_items}
            on_toggle_select="toggle_select_item"
          />
          <div :if={@loaded < @uncategorized_total and @view_mode == "active"} class="flex justify-center pt-2">
            <button
              type="button"
              phx-click="expand_card"
              phx-value-scope="uncategorized"
              disabled={@expanding}
              class="btn btn-ghost btn-xs"
            >
              <%= if @expanding do %>
                <span class="loading loading-spinner loading-xs"></span>
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Loading…")}
              <% else %>
                <.icon name="hero-chevron-down" class="w-3 h-3" />
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Show %{n} more", n: @uncategorized_total - @loaded)}
              <% end %>
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # One row in the Categories tab — a compact card with depth indent,
  # drag handle (active mode only, when there are siblings to swap with),
  # name (linked to edit), item count, and per-mode actions.
  # ── Bulk-action bars ─────────────────────────────────────────────

  attr(:count, :integer, required: true)
  attr(:view_mode, :string, required: true)

  # Inline bulk-actions content for the Items tab. Renders as a flex
  # cluster (count + buttons) without an outer box — the parent row
  # supplies the sticky/styled container so the toggle and the bulk
  # actions share one row.
  defp items_bulk_actions(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-3 grow">
      <span class="text-sm font-medium">
        {Gettext.gettext(PhoenixKitCatalogue.Gettext, "%{count} selected", count: @count)}
      </span>
      <div class="flex items-center gap-2">
        <%= if @view_mode == "active" do %>
          <button phx-click="request_bulk_move_items" class="btn btn-sm btn-outline">
            <.icon name="hero-arrows-right-left" class="w-4 h-4" />
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move")}
          </button>
          <button phx-click="request_bulk_delete_items" class="btn btn-sm btn-outline btn-error">
            <.icon name="hero-trash" class="w-4 h-4" />
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")}
          </button>
        <% else %>
          <button phx-click="request_bulk_restore_items" class="btn btn-sm btn-outline btn-success">
            <.icon name="hero-arrow-path" class="w-4 h-4" />
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restore")}
          </button>
          <button phx-click="request_bulk_delete_items" class="btn btn-sm btn-outline btn-error">
            <.icon name="hero-trash" class="w-4 h-4" />
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete forever")}
          </button>
        <% end %>
        <button phx-click="clear_selection" class="btn btn-sm btn-ghost">
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Clear")}
        </button>
      </div>
    </div>
    """
  end

  attr(:count, :integer, required: true)
  attr(:view_mode, :string, required: true)

  defp categories_bulk_bar(assigns) do
    ~H"""
    <div class="sticky top-[72px] z-40 -mx-1 px-3 py-2 rounded-lg bg-base-100/95 border border-primary/40 shadow-md backdrop-blur flex flex-wrap items-center gap-3">
      <span class="text-sm font-medium">
        {Gettext.gettext(PhoenixKitCatalogue.Gettext, "%{count} selected", count: @count)}
      </span>
      <div class="flex items-center gap-2 ml-auto">
        <%= if @view_mode == "active" do %>
          <button phx-click="request_bulk_delete_categories" class="btn btn-sm btn-outline btn-error">
            <.icon name="hero-trash" class="w-4 h-4" />
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")}
          </button>
        <% else %>
          <button phx-click="request_bulk_restore_categories" class="btn btn-sm btn-outline btn-success">
            <.icon name="hero-arrow-path" class="w-4 h-4" />
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restore")}
          </button>
        <% end %>
        <button phx-click="clear_selection" class="btn btn-sm btn-ghost">
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Clear")}
        </button>
      </div>
    </div>
    """
  end

  attr(:category, :map, required: true)
  attr(:depth, :integer, required: true)
  attr(:count, :integer, required: true)
  attr(:view_mode, :string, required: true)
  attr(:sibling_count, :integer, required: true)
  attr(:selected, :boolean, default: false)

  defp category_row(assigns) do
    ~H"""
    <div
      :if={@view_mode == "active" or @category.status == "deleted"}
      class={[
        "group",
        cond do
          @view_mode == "active" and @category.status == "active" -> "sortable-item"
          true -> "sortable-ignore"
        end
      ]}
      data-id={@category.status == "active" && @category.uuid}
      style={"margin-left: #{@depth * 1.5}rem"}
    >
      <div class="card card-sm bg-base-100 shadow">
        <div class="card-body py-3 flex-row items-center justify-between gap-3">
          <div class="flex items-center gap-2 min-w-0">
            <%!-- Active mode: combined checkbox + hover-only drag handle.
                 Checkbox is always visible; the bars-3 grip only shows on
                 row hover so it doesn't compete with the row content. --%>
            <div
              :if={@view_mode == "active" and @category.status == "active"}
              class="flex items-center gap-1.5"
            >
              <span
                :if={@sibling_count > 1}
                class="pk-drag-handle cursor-grab active:cursor-grabbing text-base-content/30 opacity-0 group-hover:opacity-100 transition-opacity"
                title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Drag to reorder (among siblings)")}
              >
                <.icon name="hero-bars-3" class="w-4 h-4" />
              </span>
              <input
                type="checkbox"
                class="checkbox checkbox-xs"
                checked={@selected}
                phx-click="toggle_select_category"
                phx-value-uuid={@category.uuid}
              />
            </div>

            <span
              :if={@view_mode != "active" or @category.status != "active"}
              class={["font-medium truncate", @category.status == "deleted" && "text-error/70"]}
            >
              {@category.name}
            </span>

            <%!-- Active row name + inline pencil edit icon. The edit
                 button used to live on the right; removed by the boss
                 to declutter the row in favour of the bulk-action bar.
                 The pencil keeps a one-click path to the edit form. --%>
            <span
              :if={@view_mode == "active" and @category.status == "active"}
              class="font-medium truncate"
            >
              {@category.name}
            </span>
            <.link
              :if={@view_mode == "active" and @category.status == "active"}
              navigate={Paths.category_edit(@category.uuid)}
              class="text-base-content/40 hover:text-primary"
              title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit category")}
            >
              <.icon name="hero-pencil" class="w-4 h-4" />
            </.link>

            <span :if={@category.status == "deleted"} class="badge badge-error badge-xs">deleted</span>
            <%!-- Item count only for active categories. Once a category
                 is deleted, its items are managed separately (Items tab
                 Deleted view) — the count here would be confusing under
                 the "separate status" rule. --%>
            <span :if={@category.status == "active"} class="badge badge-ghost badge-sm">{@count} {Gettext.gettext(PhoenixKitCatalogue.Gettext, "items")}</span>
          </div>

          <%!-- Deleted mode: Restore + Permanent Delete (per-row; bulk
               actions live in the action bar). Active mode has no
               per-row buttons — selection drives bulk actions. --%>
          <div :if={@view_mode == "deleted" and @category.status == "deleted"} class="flex gap-1 shrink-0">
            <button
              phx-click="restore_category"
              phx-value-uuid={@category.uuid}
              phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restoring...")}
              class="inline-flex items-center gap-1.5 px-2.5 h-[2.5em] rounded-lg border border-success/30 bg-success/10 hover:bg-success/20 text-success text-xs font-medium transition-colors cursor-pointer"
            >
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restore")}
            </button>
            <button
              phx-click="show_delete_confirm"
              phx-value-uuid={@category.uuid}
              phx-value-type="category"
              class="inline-flex items-center gap-1.5 px-2.5 h-[2.5em] rounded-lg border border-error/30 bg-error/10 hover:bg-error/20 text-error text-xs font-medium transition-colors cursor-pointer"
            >
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete Forever")}
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
