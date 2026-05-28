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
  import PhoenixKitWeb.Components.Core.EmptyState, only: [empty_state: 1]
  import PhoenixKitWeb.Components.Core.Pagination, only: [load_more: 1]

  import PhoenixKitWeb.Components.Core.BulkSelect,
    only: [
      bulk_select_scope: 1,
      bulk_select_header_cell: 1,
      bulk_select_cell: 1,
      bulk_actions_toolbar: 1
    ]

  import PhoenixKitWeb.Components.Core.Sortable, only: [sortable_tbody: 1, sortable_row: 1]
  import PhoenixKitWeb.Components.Core.ReorderModal, only: [reorder_modal: 1]
  import PhoenixKitWeb.Components.Core.SortSelector, only: [sort_selector: 1]

  import PhoenixKitWeb.Components.Core.TableDefault,
    only: [
      table_default: 1,
      table_default_header: 1,
      table_default_row: 1,
      table_default_header_cell: 1,
      sort_header_cell: 1,
      drag_handle_cell: 1,
      drag_handle_header_cell: 1
    ]

  import PhoenixKitCatalogue.Web.Components

  import PhoenixKitCatalogue.Web.Helpers,
    only: [actor_opts: 1, actor_uuid: 1, log_operation_error: 3]

  alias PhoenixKit.Utils.Values
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.PubSub
  alias PhoenixKitCatalogue.Errors
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Schemas.Category
  alias PhoenixKitCatalogue.Web.Components.PdfSearchModal

  @per_page 100
  # Cross-tab bulk-change red-flash → state-refresh delay. Long enough
  # that the receiver sees the leaving rows pulse red before they
  # vanish on the refresh, short enough not to feel laggy.
  @bulk_change_apply_delay_ms 800

  # Active-list sortable fields. Whitelist guards the sort events — the
  # context validates atoms too, but the LV must not coerce attacker
  # input into atoms. `:position` is the manual-order default.
  @items_sort_fields ~w(position name sku base_price status)a
  @items_sort_field_strs Enum.map(@items_sort_fields, &Atom.to_string/1)

  # Hardcoded string→atom whitelist for the reorder modal strategies —
  # NEVER String.to_existing_atom on the submitted value.
  @items_reorder_strategy_map %{
    "name_asc" => :name_asc,
    "name_desc" => :name_desc,
    "created_desc" => :created_desc,
    "created_asc" => :created_asc,
    "reverse" => :reverse
  }

  @impl true
  def mount(%{"uuid" => uuid}, _session, socket) do
    socket =
      assign(socket,
        page_title: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Loading..."),
        catalogue_uuid: uuid,
        catalogue: nil,
        # ── Drill-down position ──
        # current_category_uuid: nil = root level, "uncategorized" = the
        # uncategorized bucket, or a real category UUID. current_category
        # is the resolved value: nil | :uncategorized | %Category{}.
        current_category_uuid: nil,
        current_category: nil,
        # Trimmed active-ancestor chain above the current node (root and
        # current node excluded). Drives the breadcrumb.
        breadcrumb: [],
        # Direct child categories shown as drill cards at this level.
        child_categories: [],
        child_counts: %{},
        children_with_subs: MapSet.new(),
        # Root-active only: the Uncategorized drill card.
        uncategorized_active_count: 0,
        # ── Current node's own direct items (single paged list) ──
        items: [],
        items_total: 0,
        items_offset: 0,
        items_has_more: false,
        show_items_section: false,
        # Per-status item counts for the current node — drive the four
        # per-status tab labels (active / inactive / discontinued / deleted).
        level_status_counts: %{},
        confirm_delete: nil,
        trash_modal: nil,
        bulk_move_modal: nil,
        bulk_confirm: nil,
        selected_items: MapSet.new(),
        selected_categories: MapSet.new(),
        # ── Active item list sort + strategy reorder ──
        # The active list uses the core List-UI toolkit: a sort dropdown,
        # client-side bulk-select, DnD reorder (manual mode only), and a
        # strategy "Reorder" modal. `reorder_captured_uuids` holds the
        # uuids the BulkSelectScope hook captured for the open modal
        # (empty == "reorder all").
        items_sort_by: :position,
        items_sort_dir: :asc,
        show_items_reorder: false,
        reorder_captured_uuids: [],
        view_mode: "active",
        search_query: "",
        search_results: nil,
        search_offset: 0,
        search_total: 0,
        search_has_more: false,
        search_loading: false,
        show_pdf_search: false,
        pdf_search_item: nil
      )

    # Subscribe BEFORE the first load so a write landing between connect
    # and load doesn't leave the UI stale. The actual level load happens
    # in handle_params/3, which runs after mount and on every `?category=`
    # drill patch.
    if connected?(socket), do: PubSub.subscribe()

    {:ok, socket}
  end

  # The drilled-into category lives in `?category=` — `nil` = root,
  # "uncategorized" = the uncategorized bucket, or a category UUID. This
  # runs after mount and on every drill patch.
  #
  # On a *node change* we drop selections and fully reset search (so a
  # stale async result from the previous scope can't land). The level is
  # loaded only when connected — the disconnected first render stays a
  # cheap loading shell, and the connected mount does the single DB load.
  # An invalid / foreign category UUID bounces back to the root level.
  @impl true
  def handle_params(params, _uri, socket) do
    new_key = normalize_category_key(params["category"])

    socket =
      if new_key == socket.assigns.current_category_uuid do
        socket
      else
        socket
        |> assign(:current_category_uuid, new_key)
        |> assign(:selected_items, MapSet.new())
        |> assign(:selected_categories, MapSet.new())
        |> clear_search()
      end

    if connected?(socket) do
      load_params_level(socket, new_key)
    else
      {:noreply, socket}
    end
  end

  defp load_params_level(socket, key) do
    case resolve_node(socket.assigns.catalogue_uuid, key) do
      {:ok, current} ->
        {:noreply,
         socket
         |> assign(:current_category, current)
         |> reset_and_load()
         |> maybe_auto_flip_to_active()}

      :invalid ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category not found.")
         )
         |> push_patch(to: Paths.catalogue_detail(socket.assigns.catalogue_uuid))}
    end
  rescue
    Ecto.NoResultsError ->
      Logger.warning("Catalogue not found: #{socket.assigns.catalogue_uuid}")

      {:noreply,
       socket
       |> put_flash(:error, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue not found."))
       |> push_navigate(to: Paths.index())}
  end

  defp normalize_category_key(nil), do: nil
  defp normalize_category_key(""), do: nil
  defp normalize_category_key("uncategorized"), do: "uncategorized"
  defp normalize_category_key(uuid) when is_binary(uuid), do: uuid

  # Resolves a `?category=` key to the current node. A UUID that doesn't
  # exist or belongs to another catalogue is `:invalid` (caller bounces
  # to root). Works in `:active` and `:deleted` view alike — drilling
  # into a trashed category to inspect its deleted subtree is valid.
  defp resolve_node(_catalogue_uuid, nil), do: {:ok, nil}
  defp resolve_node(_catalogue_uuid, "uncategorized"), do: {:ok, :uncategorized}

  defp resolve_node(catalogue_uuid, uuid) do
    case Catalogue.get_category(uuid) do
      %Category{catalogue_uuid: ^catalogue_uuid} = cat -> {:ok, cat}
      _ -> :invalid
    end
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

  def handle_info(msg, socket) do
    Logger.debug("CatalogueDetailLive ignored unhandled message: #{inspect(msg)}")
    {:noreply, socket}
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
  def handle_event("switch_view", %{"mode" => mode}, socket)
      when mode in ~w(active inactive discontinued deleted) do
    {:noreply,
     socket
     |> assign(:view_mode, mode)
     |> assign(:confirm_delete, nil)
     |> assign(:selected_items, MapSet.new())
     |> assign(:selected_categories, MapSet.new())
     |> reset_and_load()}
  end

  # One bottom sentinel drives both search-result paging and the current
  # node's item list. While a search is active it pages the results;
  # otherwise it pages the level's own items.
  def handle_event("load_more", _params, socket) do
    cond do
      socket.assigns.search_results != nil ->
        if socket.assigns.search_has_more and not socket.assigns.search_loading,
          do: {:noreply, start_search_page(socket)},
          else: {:noreply, socket}

      socket.assigns.items_has_more ->
        {:noreply, load_next_items_page(socket)}

      true ->
        {:noreply, socket}
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
    {:noreply, assign(socket, :trash_modal, %{modal | target_uuid: Values.blank_to_nil(uuid)})}
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
  # and the operation type. The active list (core toolkit) supplies the
  # uuids client-side via `%{"uuids" => [...]}`; the deleted list (still
  # server-side select) falls back to the `@selected_items` MapSet.
  # Confirmation routes through `confirm_bulk_action` below.
  def handle_event("request_bulk_delete_items", params, socket) do
    uuids = resolve_bulk_uuids(params, socket)

    if uuids == [] do
      {:noreply, socket}
    else
      mode =
        if socket.assigns.view_mode == "deleted",
          do: :permanent,
          else: :trash

      {:noreply,
       assign(socket, :bulk_confirm, %{
         kind: :items,
         mode: mode,
         count: length(uuids),
         uuids: uuids
       })}
    end
  end

  def handle_event("request_bulk_restore_items", params, socket) do
    uuids = resolve_bulk_uuids(params, socket)
    if uuids == [], do: {:noreply, socket}, else: do_bulk_restore_items(socket, uuids)
  end

  def handle_event("request_bulk_move_items", params, socket) do
    uuids = resolve_bulk_uuids(params, socket)

    if uuids == [] do
      {:noreply, socket}
    else
      targets =
        socket.assigns.catalogue_uuid
        |> Catalogue.list_category_tree(mode: :active)

      {:noreply,
       assign(socket, :bulk_move_modal, %{
         count: length(uuids),
         uuids: uuids,
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

    {:noreply,
     assign(socket, :bulk_move_modal, %{modal | target_uuid: Values.blank_to_nil(uuid)})}
  end

  def handle_event("confirm_bulk_move_items", _params, socket) do
    case socket.assigns.bulk_move_modal do
      %{disposition: :uncategorize, uuids: uuids} ->
        do_bulk_move_items(socket, uuids, nil)

      %{disposition: :move_to, target_uuid: target_uuid, uuids: uuids}
      when not is_nil(target_uuid) ->
        do_bulk_move_items(socket, uuids, target_uuid)

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_bulk_move", _params, socket) do
    {:noreply, assign(socket, :bulk_move_modal, nil)}
  end

  def handle_event("confirm_bulk_action", _params, socket) do
    case socket.assigns.bulk_confirm do
      %{kind: :items, mode: :trash, uuids: uuids} ->
        do_bulk_trash_items(socket, uuids)

      %{kind: :items, mode: :permanent, uuids: uuids} ->
        do_bulk_permanent_delete_items(socket, uuids)

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

  # DnD reorder of the active item list. The drill view is always one
  # node, so scope comes from socket assigns (the current node), NOT
  # from DOM attrs — core `<.sortable_tbody>` doesn't carry the
  # catalogue's `data-sortable-scope-*` attrs.
  def handle_event("reorder_items", %{"ordered_ids" => ordered_ids} = params, socket)
      when is_list(ordered_ids) do
    catalogue_uuid = socket.assigns.catalogue_uuid
    category_uuid = Catalogue.normalize_category_uuid(socket.assigns.current_category)
    moved_id = params["moved_id"]

    apply_in_scope_item_reorder(socket, catalogue_uuid, category_uuid, ordered_ids, moved_id)
  end

  # ── Active item list: sort + strategy reorder ────────────────────

  # Sort selector (field <select> + direction arrow). The select sends
  # `%{"sort_by" => ...}`, the arrow `%{"sort_dir" => ...}` — derive the
  # missing half from assigns (race-free, see SortSelector docs). Field
  # is whitelist-validated; direction is only `:asc`/`:desc`.
  def handle_event("sort_items", params, socket) do
    field =
      case params["sort_by"] do
        f when f in @items_sort_field_strs -> String.to_existing_atom(f)
        _ -> socket.assigns.items_sort_by
      end

    dir =
      case params["sort_dir"] do
        "desc" -> :desc
        "asc" -> :asc
        _ -> socket.assigns.items_sort_dir
      end

    {:noreply, apply_items_sort(socket, field, dir)}
  end

  # Sortable column header click — toggles direction on the active field,
  # otherwise switches field (ascending).
  def handle_event("toggle_sort_items", %{"by" => field_str}, socket)
      when field_str in @items_sort_field_strs do
    field = String.to_existing_atom(field_str)

    dir =
      if field == socket.assigns.items_sort_by do
        if socket.assigns.items_sort_dir == :asc, do: :desc, else: :asc
      else
        :asc
      end

    {:noreply, apply_items_sort(socket, field, dir)}
  end

  def handle_event("toggle_sort_items", _params, socket), do: {:noreply, socket}

  # Open the strategy-reorder modal. Captures the client-side selection
  # (via the BulkSelectScope hook payload). A 0–1 selection collapses to
  # "reorder all" (stored as `[]`) — a single-row reorder is a no-op.
  def handle_event("open_items_reorder_modal", params, socket) do
    captured =
      case sanitize_uuids(params) do
        list when length(list) < 2 -> []
        list -> list
      end

    {:noreply, assign(socket, show_items_reorder: true, reorder_captured_uuids: captured)}
  end

  def handle_event("close_items_reorder_modal", _params, socket) do
    {:noreply, assign(socket, show_items_reorder: false, reorder_captured_uuids: [])}
  end

  def handle_event("apply_items_reorder", %{"strategy" => strategy_str}, socket)
      when is_map_key(@items_reorder_strategy_map, strategy_str) do
    strategy = Map.fetch!(@items_reorder_strategy_map, strategy_str)

    scope =
      case socket.assigns.reorder_captured_uuids do
        [] -> :all
        uuids -> uuids
      end

    catalogue_uuid = socket.assigns.catalogue_uuid
    category_uuid = Catalogue.normalize_category_uuid(socket.assigns.current_category)

    case Catalogue.reorder_items_by(
           catalogue_uuid,
           category_uuid,
           strategy,
           scope,
           actor_opts(socket)
         ) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Items reordered."))
         |> assign(show_items_reorder: false, reorder_captured_uuids: [])
         |> push_event("bulk_select:clear", %{})
         |> reset_and_load()}

      {:error, :duplicate_positions} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(
             PhoenixKitCatalogue.Gettext,
             "Selected items share positions. Apply \"Reorder all\" first to normalise."
           )
         )}

      {:error, reason} ->
        log_operation_error(socket, "reorder_items_by", %{reason: reason})

        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to reorder items.")
         )}
    end
  end

  def handle_event("apply_items_reorder", _params, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       Gettext.gettext(PhoenixKitCatalogue.Gettext, "Pick a strategy before applying.")
     )}
  end

  # ── Bulk-action helpers ──────────────────────────────────────────

  defp toggle(set, uuid) do
    if MapSet.member?(set, uuid), do: MapSet.delete(set, uuid), else: MapSet.put(set, uuid)
  end

  # Resolves the target uuids for a bulk op. The active list (core
  # toolkit) supplies them client-side via `%{"uuids" => [...]}`; the
  # deleted list (still server-side select) falls back to the
  # `@selected_items` MapSet.
  defp resolve_bulk_uuids(%{"uuids" => _} = params, _socket), do: sanitize_uuids(params)
  defp resolve_bulk_uuids(_params, socket), do: MapSet.to_list(socket.assigns.selected_items)

  defp sanitize_uuids(%{"uuids" => uuids}) when is_list(uuids),
    do: Enum.filter(uuids, &is_binary/1)

  defp sanitize_uuids(_), do: []

  # Clears both selection models after a bulk op: the server-side MapSet
  # (deleted list) and the client-side BulkSelectScope (active list).
  defp clear_item_selection(socket) do
    socket
    |> assign(:selected_items, MapSet.new())
    |> push_event("bulk_select:clear", %{})
  end

  # Sort change resets the item offset to 0 and reloads page 1 — else
  # infinite-scroll would stitch the new order onto a stale prefix.
  defp apply_items_sort(socket, field, dir) do
    socket
    |> assign(items_sort_by: field, items_sort_dir: dir, items_offset: 0)
    |> reset_and_load()
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

  # Active-list bulk ops read the client-captured uuids; deleted-list
  # bulk ops pass `@selected_items`. After each op we clear BOTH the
  # server-side MapSet (deleted list) AND push `bulk_select:clear` so a
  # stale client-side checkmark can't persist on the active list.
  defp do_bulk_trash_items(socket, uuids) do
    {count, _} = Catalogue.bulk_trash_items(uuids, actor_opts(socket))
    PubSub.broadcast_bulk_change(socket.assigns.catalogue_uuid, :trashed, uuids)

    socket
    |> assign(:bulk_confirm, nil)
    |> clear_item_selection()
    |> put_flash(
      :info,
      Gettext.gettext(PhoenixKitCatalogue.Gettext, "Deleted %{count} items.", count: count)
    )
    |> reset_and_load()
    |> then(&{:noreply, &1})
  end

  defp do_bulk_permanent_delete_items(socket, uuids) do
    {count, _} = Catalogue.bulk_permanently_delete_items(uuids, actor_opts(socket))
    PubSub.broadcast_bulk_change(socket.assigns.catalogue_uuid, :permanent_delete, uuids)

    socket
    |> assign(:bulk_confirm, nil)
    |> clear_item_selection()
    |> put_flash(
      :info,
      Gettext.gettext(PhoenixKitCatalogue.Gettext, "Permanently deleted %{count} items.",
        count: count
      )
    )
    |> reset_and_load()
    |> then(&{:noreply, &1})
  end

  defp do_bulk_restore_items(socket, uuids) do
    {count, _} = Catalogue.bulk_restore_items(uuids, actor_opts(socket))
    PubSub.broadcast_bulk_change(socket.assigns.catalogue_uuid, :restored, uuids)

    socket
    |> clear_item_selection()
    |> put_flash(
      :info,
      Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restored %{count} items.", count: count)
    )
    |> reset_and_load()
    |> then(&{:noreply, &1})
  end

  defp do_bulk_move_items(socket, uuids, target_uuid) do
    opts =
      actor_opts(socket) |> Keyword.put(:catalogue_uuid, socket.assigns.catalogue_uuid)

    case Catalogue.bulk_move_items_to_category(uuids, target_uuid, opts) do
      {:ok, count} ->
        # `:moved` triggers the receiver's full red-fade → refresh →
        # green-fade sequence on every other open tab.
        PubSub.broadcast_bulk_change(socket.assigns.catalogue_uuid, :moved, uuids)

        socket
        |> assign(:bulk_move_modal, nil)
        |> clear_item_selection()
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

  # Reloads the whole drill level from scratch (item list back to page 1).
  # Called after any structural change — drilling, view switch, trash /
  # restore / reorder.
  defp reset_and_load(socket) do
    socket
    |> load_level(@per_page)
    |> maybe_auto_flip_to_active()
  end

  # Loads everything the current level renders for the active view_mode:
  # catalogue + breadcrumb, the direct child categories (drill cards) with
  # their item counts and has-subcategories flags, the root-only
  # Uncategorized card count, the current node's own direct items (first
  # `item_limit`), and the per-level Active/Deleted counts that drive the
  # toggle labels + auto-flip. `item_limit` lets a PubSub refresh preserve
  # the user's scroll depth instead of snapping back to page 1.
  defp load_level(socket, item_limit) do
    uuid = socket.assigns.catalogue_uuid
    catalogue = Catalogue.fetch_catalogue!(uuid)
    current = socket.assigns.current_category
    # `status` is the exact item status of the current tab; `cat_mode` is the
    # active/deleted bucket for the (status-less) subcategory cards.
    status = socket.assigns.view_mode
    cat_mode = view_mode_to_atom(status)
    show_categories? = status in ["active", "deleted"]

    {child_categories, children_with_subs, _active_child_count, _deleted_child_count} =
      if show_categories?,
        do: load_level_children(uuid, current, cat_mode),
        else: {[], MapSet.new(), 0, 0}

    counts_map = Catalogue.item_counts_by_category_for_catalogue(uuid, mode: cat_mode)
    uncat_active = Catalogue.uncategorized_count_for_catalogue(uuid, mode: :active)

    # Per-status item counts for the current node — drive the four tab labels.
    status_counts = node_status_counts(current, uuid)
    node_total = Map.get(status_counts, status, 0)

    # Active root with categories shows only cards (its uncategorized items
    # are reached via the Uncategorized card). Every other case — a drilled
    # node, or any non-active tab, or an empty active root with loose items —
    # shows the node's own item list.
    show_items_section =
      current != nil or status != "active" or
        (child_categories == [] and node_total > 0)

    items =
      if show_items_section and node_total > 0,
        do:
          fetch_card_items(
            node_scope(current),
            uuid,
            status,
            item_limit,
            0,
            items_sort_opts(socket)
          ),
        else: []

    assign(socket,
      page_title: catalogue.name,
      catalogue: catalogue,
      breadcrumb: build_breadcrumb(current, cat_mode),
      child_categories: child_categories,
      child_counts: counts_map,
      children_with_subs: children_with_subs,
      uncategorized_active_count: uncat_active,
      items: items,
      items_total: node_total,
      items_offset: length(items),
      items_has_more: length(items) < node_total,
      show_items_section: show_items_section,
      level_status_counts: status_counts
    )
  end

  # The child categories shown at this level + counts in both modes (for
  # the toggle). The uncategorized bucket has none. Active mode reuses
  # orphan promotion; deleted mode is strict (see `list_child_categories/3`).
  defp load_level_children(_uuid, :uncategorized, _mode), do: {[], MapSet.new(), 0, 0}

  defp load_level_children(uuid, current, mode) do
    parent_uuid = node_parent_uuid(current)
    active = Catalogue.list_child_categories(uuid, parent_uuid, mode: :active)
    deleted = Catalogue.list_child_categories(uuid, parent_uuid, mode: :deleted)
    subs = Catalogue.category_uuids_with_children(uuid, mode: mode)
    shown = if mode == :deleted, do: deleted, else: active
    {shown, subs, length(active), length(deleted)}
  end

  # The current node's own direct-item counts in both modes. Root and the
  # uncategorized bucket count the uncategorized items; a category counts
  # its own direct items.
  # `%{status => count}` for the current node's own direct items — drives
  # the four per-status tabs. Root and the Uncategorized bucket both count
  # the catalogue's uncategorized items.
  defp node_status_counts(%Category{uuid: u}, _catalogue_uuid),
    do: Catalogue.item_status_counts_for_category(u)

  defp node_status_counts(_current, catalogue_uuid),
    do: Catalogue.item_status_counts_for_uncategorized(catalogue_uuid)

  # Loads the next page of the current node's own items (the bottom
  # sentinel during normal browsing — search paging is separate).
  defp load_next_items_page(socket) do
    current = socket.assigns.current_category
    status = socket.assigns.view_mode
    offset = socket.assigns.items_offset

    page =
      fetch_card_items(
        node_scope(current),
        socket.assigns.catalogue_uuid,
        status,
        @per_page,
        offset,
        items_sort_opts(socket)
      )

    new_offset = offset + length(page)

    assign(socket,
      items: socket.assigns.items ++ page,
      items_offset: new_offset,
      items_has_more: page != [] and new_offset < socket.assigns.items_total
    )
  end

  # Parent scope of a node for the child-categories query.
  defp node_parent_uuid(nil), do: nil
  defp node_parent_uuid(:uncategorized), do: nil
  defp node_parent_uuid(%Category{uuid: uuid}), do: uuid

  # The item-fetch scope of a node: a category UUID, or `:uncategorized`
  # for the root (whose own items are the uncategorized ones) and the
  # uncategorized bucket.
  defp node_scope(nil), do: :uncategorized
  defp node_scope(:uncategorized), do: :uncategorized
  defp node_scope(%Category{uuid: uuid}), do: uuid

  # Breadcrumb ancestors above the current node (root + current excluded).
  # In Active mode the chain is trimmed to its contiguous active suffix:
  # an orphan promoted to root (its parent trashed) gets an empty chain,
  # so it renders as `Catalogue ▸ <current>` — never a dead link to a
  # deleted ancestor. In Deleted mode the full chain shows (each crumb
  # drills within deleted mode).
  defp build_breadcrumb(%Category{} = cat, :active) do
    cat.uuid
    |> Catalogue.list_category_ancestors()
    |> Enum.reverse()
    |> Enum.take_while(&(&1.status == "active"))
    |> Enum.reverse()
  end

  defp build_breadcrumb(%Category{} = cat, :deleted),
    do: Catalogue.list_category_ancestors(cat.uuid)

  defp build_breadcrumb(_current, _mode), do: []

  # Reloads the current level after a mutation but keeps the user's
  # scroll depth — re-fetches at least as many items as are currently
  # loaded instead of snapping back to page 1 — then runs the auto-flip.
  defp refresh_counts(socket) do
    socket
    |> load_level(max(socket.assigns.items_offset, @per_page))
    |> maybe_auto_flip_to_active()
  end

  # No-op: with a tab shown for every status (including empty ones), an
  # empty Deleted view is a valid, navigable place — we no longer bounce
  # the user back to Active. Kept as a named pass-through so the reset/
  # reload call sites read clearly.
  defp maybe_auto_flip_to_active(socket), do: socket

  # PubSub-driven refresh. Reloads the current level preserving scroll
  # depth so a cross-tab broadcast (another admin, the import wizard)
  # doesn't collapse a deep item scroll. The `Ecto.NoResultsError` rescue
  # in the caller handles the catalogue-was-deleted-elsewhere edge case.
  defp refresh_in_place(socket), do: refresh_counts(socket)

  # Runs a fresh search query asynchronously. If a prior search is still
  # in flight, `start_async/3` cancels it — so fast typing (type-pause-
  # type-pause) doesn't flash stale intermediate results as each old
  # request lands out of order. The actual assign happens in
  # `handle_async(:search, ...)`, guarded by a query equality check.
  defp run_search(socket, query) do
    uuid = socket.assigns.catalogue_uuid
    current = socket.assigns.current_category

    socket
    |> assign(search_query: query, search_loading: true)
    |> start_async(:search, fn ->
      results = search_in_scope(uuid, current, query, @per_page, 0)
      total = search_count_in_scope(uuid, current, query)
      {query, results, total}
    end)
  end

  # Search scope follows the drill level: catalogue-wide at root, the
  # category's subtree when drilled in (`search_items_in_category/3`
  # defaults to `include_descendants: true`), and uncategorized-only in
  # the uncategorized bucket. Search is Active-mode only (the context
  # search excludes deleted rows), so the input is hidden in Deleted view.
  defp search_in_scope(uuid, nil, query, limit, offset),
    do: Catalogue.search_items_in_catalogue(uuid, query, limit: limit, offset: offset)

  defp search_in_scope(uuid, :uncategorized, query, limit, offset),
    do:
      Catalogue.search_items(query,
        catalogue_uuids: [uuid],
        only: :uncategorized_only,
        limit: limit,
        offset: offset
      )

  defp search_in_scope(_uuid, %Category{uuid: cuuid}, query, limit, offset),
    do: Catalogue.search_items_in_category(cuuid, query, limit: limit, offset: offset)

  defp search_count_in_scope(uuid, nil, query),
    do: Catalogue.count_search_items_in_catalogue(uuid, query)

  defp search_count_in_scope(uuid, :uncategorized, query),
    do: Catalogue.count_search_items(query, catalogue_uuids: [uuid], only: :uncategorized_only)

  defp search_count_in_scope(_uuid, %Category{uuid: cuuid}, query),
    do: Catalogue.count_search_items_in_category(cuuid, query)

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
    %{catalogue_uuid: uuid, current_category: current, search_query: query, search_offset: offset} =
      socket.assigns

    socket
    |> assign(:search_loading, true)
    |> start_async(:search_page, fn ->
      page = search_in_scope(uuid, current, query, @per_page, offset)
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

  # Removes a trashed/restored/deleted item from the current node's item
  # list in place. No DB reload, so scroll position is preserved (the
  # following `refresh_counts` reconciles totals).
  defp remove_item_locally(socket, item_uuid) do
    assign(socket, :items, Enum.reject(socket.assigns.items, &(&1.uuid == item_uuid)))
  end

  # Re-fetches the current node's items after an in-place change (DnD
  # reorder, or a cross-tab reorder broadcast). `scope` identifies which
  # node changed; we only reload when it's the node currently on screen,
  # preserving the loaded slice depth. `delta` is accepted for call-site
  # compatibility but unused — there is one item list now, no cross-card
  # count drift to correct.
  defp refresh_card_items(socket, scope, _delta \\ 0) do
    if scope == node_scope(socket.assigns.current_category) do
      catalogue_uuid = socket.assigns.catalogue_uuid
      status = socket.assigns.view_mode
      limit = max(socket.assigns.items_offset, @per_page)
      fresh = fetch_card_items(scope, catalogue_uuid, status, limit, 0, items_sort_opts(socket))
      total = card_total(scope, catalogue_uuid, status)

      assign(socket,
        items: fresh,
        items_total: total,
        items_offset: length(fresh),
        items_has_more: length(fresh) < total
      )
    else
      socket
    end
  end

  # `status` is the exact item status of the current tab
  # ("active" | "inactive" | "discontinued" | "deleted").
  defp card_total(:uncategorized, catalogue_uuid, status) do
    Catalogue.uncategorized_count_for_catalogue(catalogue_uuid, status: status)
  end

  defp card_total(category_uuid, _catalogue_uuid, status) when is_binary(category_uuid) do
    Catalogue.item_count_for_category(category_uuid, status: status)
  end

  defp fetch_card_items(:uncategorized, catalogue_uuid, status, limit, offset, sort_opts) do
    Catalogue.list_uncategorized_items_paged(
      catalogue_uuid,
      [status: status, offset: offset, limit: limit] ++ sort_opts
    )
  end

  defp fetch_card_items(category_uuid, _catalogue_uuid, status, limit, offset, sort_opts)
       when is_binary(category_uuid) do
    Catalogue.list_items_for_category_paged(
      category_uuid,
      [status: status, offset: offset, limit: limit] ++ sort_opts
    )
  end

  # Sort opts threaded into the active-list paged fetches. Deleted mode
  # keeps the position-default order (the deleted list still renders via
  # the plain item_table without a sort control).
  # The deleted list renders without a sort control; every other status
  # (active/inactive/discontinued) uses the core toolkit table with sorting.
  defp items_sort_opts(%{assigns: %{view_mode: "deleted"}}), do: []

  defp items_sort_opts(socket),
    do: [sort_by: socket.assigns.items_sort_by, sort_dir: socket.assigns.items_sort_dir]

  # Re-fetches the current level's child categories in their new order
  # after a sibling DnD reorder. Items are untouched (reorder of the
  # subcategory cards doesn't affect the node's own item scroll).
  defp refresh_categories_in_place(socket) do
    uuid = socket.assigns.catalogue_uuid
    mode = view_mode_to_atom(socket.assigns.view_mode)

    child_categories =
      if socket.assigns.current_category == :uncategorized,
        do: [],
        else:
          Catalogue.list_child_categories(uuid, node_parent_uuid(socket.assigns.current_category),
            mode: mode
          )

    assign(socket, :child_categories, child_categories)
  end

  # The category bucket for the current view. Categories only have
  # active/deleted, so the inactive/discontinued item tabs reuse the active
  # category set (those tabs hide the category cards anyway).
  defp view_mode_to_atom("deleted"), do: :deleted
  defp view_mode_to_atom(_), do: :active

  # The four item-status tabs (status value + label), in display order.
  defp item_status_tabs do
    [
      {"active", Gettext.gettext(PhoenixKitCatalogue.Gettext, "Active")},
      {"inactive", Gettext.gettext(PhoenixKitCatalogue.Gettext, "Inactive")},
      {"discontinued", Gettext.gettext(PhoenixKitCatalogue.Gettext, "Discontinued")},
      {"deleted", Gettext.gettext(PhoenixKitCatalogue.Gettext, "Deleted")}
    ]
  end

  defp status_tab_active_class("deleted"), do: "border-error text-error"
  defp status_tab_active_class(_), do: "border-primary text-primary"

  # `[{status, label, count}]` for the tabs to render. Empty statuses are
  # dropped, except Active (always the home tab) and the current tab (so the
  # user never lands on an invisible tab).
  defp visible_status_tabs(view_mode, counts) do
    item_status_tabs()
    |> Enum.map(fn {status, label} -> {status, label, Map.get(counts, status, 0)} end)
    |> Enum.filter(fn {status, _label, count} ->
      status == "active" or status == view_mode or count > 0
    end)
  end

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
    by_uuid = Map.new(socket.assigns.child_categories, fn %Category{} = c -> {c.uuid, c} end)

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

  # ── Render ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col w-full px-4 py-6 gap-6">
      <%!-- Loading state --%>
      <div :if={is_nil(@catalogue)} class="flex justify-center py-12">
        <span class="loading loading-spinner loading-lg"></span>
      </div>

      <div :if={@catalogue} class="flex flex-col gap-6">
        <%!-- Header --%>
        <%!-- The title doubles as the breadcrumb trail: at root it's just
             the catalogue name; drilled in it's `Catalogue › … › Current`
             with the ancestors as muted patch links and the current node
             as the bold end. `@breadcrumb` is trimmed to the active
             ancestor chain in Active mode, so an orphan never links to a
             deleted ancestor. --%>
        <.admin_page_header>
          <h1 class="text-xl sm:text-2xl lg:text-3xl font-bold text-base-content flex flex-wrap items-center gap-x-2 gap-y-1">
            <%= if @current_category == nil do %>
              {@catalogue.name}
            <% else %>
              <.link
                patch={Paths.catalogue_detail(@catalogue.uuid)}
                class="font-normal text-base-content/50 hover:text-primary"
              >
                {@catalogue.name}
              </.link>
              <%= for cat <- @breadcrumb do %>
                <.icon name="hero-chevron-right" class="w-5 h-5 text-base-content/30 shrink-0" />
                <.link
                  patch={Paths.category_browse(@catalogue.uuid, cat.uuid)}
                  class="font-normal text-base-content/50 hover:text-primary"
                >
                  {cat.name}
                </.link>
              <% end %>
              <.icon name="hero-chevron-right" class="w-5 h-5 text-base-content/30 shrink-0" />
              <span class="truncate">{current_node_label(@current_category)}</span>
            <% end %>
          </h1>
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

        <%!-- Toolbar: scoped search (Active mode only — context search
             excludes deleted rows) + per-level Active/Deleted toggle. --%>
        <div class="flex items-end justify-between gap-4 flex-wrap border-b border-base-200 pb-2">
          <.search_input
            :if={@view_mode == "active"}
            class="grow"
            query={@search_query}
            placeholder={search_placeholder(@current_category)}
          />
          <div :if={@view_mode != "active"}></div>

          <%!-- One tab per item status; each shows only that status's items
               so e.g. discontinued isn't mixed in with active. Empty statuses
               are hidden — except Active (the home tab) and the current tab. --%>
          <div
            :if={is_nil(@search_results) and not @search_loading}
            class="flex items-center gap-0.5 pb-1 flex-wrap"
          >
            <button
              :for={{status, label, count} <- visible_status_tabs(@view_mode, @level_status_counts)}
              type="button"
              phx-click="switch_view"
              phx-value-mode={status}
              class={[
                "px-3 py-1.5 text-xs font-medium border-b-2 transition-colors cursor-pointer whitespace-nowrap",
                if(@view_mode == status,
                  do: status_tab_active_class(status),
                  else: "border-transparent text-base-content/50 hover:text-base-content"
                )
              ]}
            >
              {label} ({count})
            </button>
          </div>
        </div>

        <%!-- Search results (Active mode; unchanged machinery) --%>
        <div :if={@search_results != nil or @search_loading} class="flex flex-col gap-4">
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

          <.empty_state :if={@search_results == [] and not @search_loading} variant="card" title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "No items match your search.")} />

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

          <.load_more
            :if={@search_results not in [nil, []]}
            id="search-load-more"
            loaded={length(@search_results)}
            total={@search_total}
            noun_plural={Gettext.gettext(PhoenixKitCatalogue.Gettext, "items")}
            infinite={not @search_loading}
            cursor={"search-#{@search_offset}"}
          />
        </div>

        <%!-- ── Browse view (no active search) ──────────────────────── --%>
        <div :if={is_nil(@search_results) and not @search_loading} class="flex flex-col gap-6">
          <%!-- The Uncategorized drill card only appears when there are
               categories to drill past. With no categories, the items
               render inline (see `show_items_section`), so the card would
               be a redundant extra click. --%>
          <% show_uncat_card =
            is_nil(@current_category) and @view_mode == "active" and
              @uncategorized_active_count > 0 and @child_categories != [] %>

          <%!-- Category bulk-action bar (when subcategories selected) --%>
          <.categories_bulk_bar
            :if={MapSet.size(@selected_categories) > 0}
            count={MapSet.size(@selected_categories)}
            view_mode={@view_mode}
          />

          <%!-- Subcategory rows (+ Uncategorized row at root/active),
               one per line. Sibling reorder via SortableGrid in active mode. --%>
          <div
            :if={@child_categories != [] or show_uncat_card}
            id="catalogue-child-categories"
            class="flex flex-col gap-2"
            data-sortable="true"
            data-sortable-event="reorder_categories"
            data-sortable-items=".sortable-item"
            data-sortable-hide-source="false"
            data-sortable-group="catalogue-child-categories"
            data-sortable-handle=".pk-drag-handle"
            phx-hook={if @view_mode == "active", do: "SortableGrid"}
          >
            <%= for cat <- @child_categories do %>
              <.category_drill_card
                catalogue_uuid={@catalogue.uuid}
                category={cat}
                count={Map.get(@child_counts, cat.uuid, 0)}
                has_subs={MapSet.member?(@children_with_subs, cat.uuid)}
                view_mode={@view_mode}
                sibling_count={length(@child_categories)}
                selected={MapSet.member?(@selected_categories, cat.uuid)}
              />
            <% end %>
            <.uncategorized_drill_card
              :if={show_uncat_card}
              catalogue_uuid={@catalogue.uuid}
              count={@uncategorized_active_count}
              sibling_count={length(@child_categories)}
            />
          </div>

          <%!-- Deleted-list bulk-action bar (server-side select). The
               active list owns its selection client-side via the core
               BulkSelectScope toolkit inside `level_items`. --%>
          <div
            :if={@view_mode == "deleted" and MapSet.size(@selected_items) > 0}
            class="sticky top-[72px] z-40 -mx-1 px-3 py-2 rounded-lg bg-base-100/95 border border-primary/40 shadow-md backdrop-blur flex items-center"
          >
            <.items_bulk_actions count={MapSet.size(@selected_items)} view_mode={@view_mode} />
          </div>

          <%!-- Card/table view toggle — deleted list only (it still
               renders via `item_table` with a card view). The active
               list is the core-toolkit table (table-only). --%>
          <div :if={@view_mode == "deleted" and @show_items_section and @items != []} class="flex justify-end">
            <.view_mode_toggle storage_key="catalogue-detail-items" />
          </div>

          <%!-- The current node's own direct items --%>
          <.level_items
            :if={@show_items_section}
            items={@items}
            view_mode={@view_mode}
            catalogue={@catalogue}
            current_category={@current_category}
            current_category_uuid={@current_category_uuid}
            selected_items={@selected_items}
            items_total={@items_total}
            items_offset={@items_offset}
            items_sort_by={@items_sort_by}
            items_sort_dir={@items_sort_dir}
            show_items_reorder={@show_items_reorder}
            reorder_captured_uuids={@reorder_captured_uuids}
          />

          <%!-- Level is completely empty (root/active with no categories
               and no uncategorized items). The items section renders its
               own empty message for drilled-in nodes. --%>
          <.empty_state
            :if={@child_categories == [] and not show_uncat_card and not @show_items_section}
            variant="card"
            title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "No categories or items yet. Add a category or item to get started.")}
          />
        </div>
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
    """
  end

  # ── Drill-down level components ──────────────────────────────────

  # A subcategory shown at the current level. The name + chevron are the
  # drill link into the category; checkbox + drag handle + edit pencil are
  # separate controls so they don't fire the drill. Deleted mode swaps in
  # Restore / Delete-forever (the name still drills, to inspect the
  # deleted subtree). A folder badge marks categories with subcategories.
  attr(:catalogue_uuid, :string, required: true)
  attr(:category, :map, required: true)
  attr(:count, :integer, required: true)
  attr(:has_subs, :boolean, default: false)
  attr(:view_mode, :string, required: true)
  attr(:sibling_count, :integer, required: true)
  attr(:selected, :boolean, default: false)

  defp category_drill_card(assigns) do
    ~H"""
    <div
      class={[
        "group card card-sm bg-base-100 shadow",
        @view_mode == "active" and @category.status == "active" && "sortable-item"
      ]}
      data-id={@view_mode == "active" and @category.status == "active" && @category.uuid}
    >
      <div class="card-body py-3 flex-row items-center justify-between gap-3">
        <div class="flex items-center gap-2 min-w-0">
          <div :if={@view_mode == "active" and @category.status == "active"} class="flex items-center gap-1.5 shrink-0">
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

          <.link
            patch={Paths.category_browse(@catalogue_uuid, @category.uuid)}
            class={["font-medium truncate hover:text-primary", @category.status == "deleted" && "text-error/70"]}
          >
            {@category.name}
          </.link>

          <span
            :if={@has_subs}
            class="badge badge-ghost badge-xs"
            title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Has subcategories")}
          >
            <.icon name="hero-rectangle-stack" class="w-3 h-3" />
          </span>
          <span :if={@category.status == "deleted"} class="badge badge-error badge-xs">deleted</span>
          <span :if={@category.status == "active"} class="badge badge-ghost badge-sm shrink-0">
            {@count} {Gettext.gettext(PhoenixKitCatalogue.Gettext, "items")}
          </span>
        </div>

        <div class="flex items-center gap-1 shrink-0">
          <.link
            :if={@view_mode == "active" and @category.status == "active"}
            navigate={Paths.category_edit(@category.uuid)}
            class="text-base-content/40 hover:text-primary"
            title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit category")}
          >
            <.icon name="hero-pencil" class="w-4 h-4" />
          </.link>

          <button
            :if={@view_mode == "deleted" and @category.status == "deleted"}
            phx-click="restore_category"
            phx-value-uuid={@category.uuid}
            phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restoring...")}
            class="inline-flex items-center gap-1.5 px-2.5 h-[2.5em] rounded-lg border border-success/30 bg-success/10 hover:bg-success/20 text-success text-xs font-medium transition-colors cursor-pointer"
          >
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restore")}
          </button>
          <button
            :if={@view_mode == "deleted" and @category.status == "deleted"}
            phx-click="show_delete_confirm"
            phx-value-uuid={@category.uuid}
            phx-value-type="category"
            class="inline-flex items-center gap-1.5 px-2.5 h-[2.5em] rounded-lg border border-error/30 bg-error/10 hover:bg-error/20 text-error text-xs font-medium transition-colors cursor-pointer"
          >
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete Forever")}
          </button>

          <.link
            patch={Paths.category_browse(@catalogue_uuid, @category.uuid)}
            class="text-base-content/30 group-hover:text-base-content/60"
            title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Open")}
          >
            <.icon name="hero-chevron-right" class="w-4 h-4" />
          </.link>
        </div>
      </div>
    </div>
    """
  end

  # The root-level "Uncategorized" drill card (Active mode only). The
  # whole card drills into the uncategorized bucket.
  attr(:catalogue_uuid, :string, required: true)
  attr(:count, :integer, required: true)
  attr(:sibling_count, :integer, default: 0)

  defp uncategorized_drill_card(assigns) do
    ~H"""
    <.link
      patch={Paths.uncategorized_browse(@catalogue_uuid)}
      class="card card-sm bg-base-100 shadow hover:shadow-md transition-shadow"
    >
      <div class="card-body py-3 flex-row items-center justify-between gap-2">
        <div class="flex items-center gap-2 min-w-0">
          <%!-- Mirror the category cards' handle + checkbox cluster so the
               "Uncategorized" name lines up with the category names. The
               inbox sits in the (always-present) checkbox slot; the drag
               handle slot is an invisible spacer, gated the same way. --%>
          <div class="flex items-center gap-1.5 shrink-0">
            <span :if={@sibling_count > 1} class="w-4 h-4" aria-hidden="true"></span>
            <.icon name="hero-inbox" class="w-4 h-4 text-base-content/40" />
          </div>
          <span class="font-medium truncate text-base-content/70">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Uncategorized")}
          </span>
          <span class="badge badge-ghost badge-sm shrink-0">{@count}</span>
        </div>
        <.icon name="hero-chevron-right" class="w-4 h-4 text-base-content/30" />
      </div>
    </.link>
    """
  end

  # The current node's own direct items.
  #
  # Active mode: the core List-UI toolkit — a sort dropdown, client-side
  # bulk-select with a floating actions toolbar, node-scoped DnD reorder
  # (manual mode only), and a strategy "Reorder" modal. Deleted mode:
  # the existing `<.item_table>` (Restore / Delete-forever per row +
  # server-side selection). One InfiniteScroll sentinel pages the list.
  attr(:items, :list, required: true)
  attr(:view_mode, :string, required: true)
  attr(:catalogue, :any, required: true)
  attr(:current_category, :any, required: true)
  attr(:current_category_uuid, :any, required: true)
  attr(:selected_items, :any, required: true)
  attr(:items_total, :integer, required: true)
  attr(:items_offset, :integer, required: true)
  attr(:items_sort_by, :atom, required: true)
  attr(:items_sort_dir, :atom, required: true)
  attr(:show_items_reorder, :boolean, required: true)
  attr(:reorder_captured_uuids, :list, required: true)

  defp level_items(assigns) do
    assigns =
      assign(
        assigns,
        :draggable?,
        assigns.items_sort_by == :position and assigns.view_mode != "deleted"
      )

    ~H"""
    <div class="flex flex-col gap-2">
      <%!-- ── Active list: core List-UI toolkit ── --%>
      <.bulk_select_scope
        :if={@items != [] and @view_mode != "deleted"}
        id={"items-bulk-" <> (@current_category_uuid || "root")}
        total_count={@items_total}
        class="flex flex-col gap-2"
      >
        <.bulk_actions_toolbar
          on_open_reorder="open_items_reorder_modal"
          reorder_dialog_id="items-reorder-modal"
          reorder_gate={if @items_sort_by == :position, do: :always, else: :multi}
          on_bulk_delete="request_bulk_delete_items"
          noun_singular={Gettext.gettext(PhoenixKitCatalogue.Gettext, "item")}
          noun_plural={Gettext.gettext(PhoenixKitCatalogue.Gettext, "items")}
        >
          <:leading>
            <.sort_selector
              sort_by={@items_sort_by}
              sort_dir={@items_sort_dir}
              options={item_sort_options()}
              manual_field={:position}
              event="sort_items"
            />
            <%!-- Move isn't a built-in toolbar action (core ships
                 Reorder/Delete/Clear), so it's a custom client-side
                 button: `data-bulk-action` makes the BulkSelectScope
                 hook push the captured uuids as `%{"uuids" => [...]}`.
                 Shown only when ≥1 row is selected. --%>
            <button
              type="button"
              class="btn btn-sm btn-ghost"
              data-bulk-action="request_bulk_move_items"
              data-bulk-show="has-selection"
              style="display: none;"
            >
              <.icon name="hero-arrows-right-left" class="w-4 h-4" />
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move")}
            </button>
          </:leading>
        </.bulk_actions_toolbar>

        <.table_default id="level-items-active" size="sm" wrapper_class="overflow-x-auto shadow-none rounded-none">
          <.table_default_header>
            <.table_default_row>
              <.drag_handle_header_cell :if={@draggable?} />
              <.bulk_select_header_cell
                id="level-items-select-all"
                aria_label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Select all items")}
              />
              <.sort_header_cell field={:name} sort={%{by: @items_sort_by, dir: @items_sort_dir}} event="toggle_sort_items">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Name")}
              </.sort_header_cell>
              <.sort_header_cell field={:sku} sort={%{by: @items_sort_by, dir: @items_sort_dir}} event="toggle_sort_items">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "SKU")}
              </.sort_header_cell>
              <.sort_header_cell field={:base_price} sort={%{by: @items_sort_by, dir: @items_sort_dir}} event="toggle_sort_items">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Price")}
              </.sort_header_cell>
              <.table_default_header_cell>
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Unit")}
              </.table_default_header_cell>
              <.sort_header_cell field={:status} sort={%{by: @items_sort_by, dir: @items_sort_dir}} event="toggle_sort_items">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Status")}
              </.sort_header_cell>
              <.table_default_header_cell class="text-right whitespace-nowrap">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Actions")}
              </.table_default_header_cell>
            </.table_default_row>
          </.table_default_header>
          <.sortable_tbody
            id={"items-body-" <> (@current_category_uuid || "root")}
            enabled={@draggable?}
            event="reorder_items"
          >
            <.sortable_row :for={item <- @items} item_id={item.uuid}>
              <.drag_handle_cell :if={@draggable?} />
              <.bulk_select_cell value={item.uuid} />
              <.item_pricing_cell item={item} edit_path={&Paths.item_edit/1} />
              <.item_row_menu
                item={item}
                edit_path={&Paths.item_edit/1}
                on_delete="delete_item"
                pdf_search_event="show_pdf_search"
              />
            </.sortable_row>
          </.sortable_tbody>
        </.table_default>
      </.bulk_select_scope>

      <%!-- ── Deleted list: existing item_table (read-only-ish) ── --%>
      <.item_table
        :if={@items != [] and @view_mode == "deleted"}
        items={@items}
        columns={[:name, :sku, :unit, :status]}
        on_restore="restore_item"
        on_permanent_delete="show_delete_confirm"
        permanent_delete_type="item"
        cards={true}
        show_toggle={false}
        storage_key="catalogue-detail-items"
        id="level-items-deleted"
        wrapper_class="overflow-x-auto shadow-none rounded-none"
        selectable={true}
        selected_uuids={@selected_items}
        on_toggle_select="toggle_select_item"
      />

      <p :if={@items == []} class="text-sm text-base-content/40 text-center py-8">
        {level_items_empty(@current_category, @view_mode)}
      </p>

      <%!-- Core load-more footer: "Showing N of M" + a manual button,
           and (via `infinite`) auto-loads on scroll through core's
           InfiniteScroll hook. --%>
      <.load_more
        :if={@items != []}
        id="level-items-load-more"
        loaded={length(@items)}
        total={@items_total}
        noun_plural={Gettext.gettext(PhoenixKitCatalogue.Gettext, "items")}
        infinite
        cursor={"items-#{@items_offset}"}
      />

      <%!-- Strategy reorder modal (non-deleted lists). Kept-in-DOM so the
           toolbar's `data-bulk-opens-dialog` opens it instantly. --%>
      <.reorder_modal
        :if={@view_mode != "deleted"}
        id="items-reorder-modal"
        show={@show_items_reorder}
        on_close="close_items_reorder_modal"
        on_apply="apply_items_reorder"
        selected_count={length(@reorder_captured_uuids)}
        total_count={@items_total}
        strategies={item_reorder_strategies()}
        noun_singular={Gettext.gettext(PhoenixKitCatalogue.Gettext, "item")}
        noun_plural={Gettext.gettext(PhoenixKitCatalogue.Gettext, "items")}
      />
    </div>
    """
  end

  # Active-list sort dropdown options. `:position` is "Manual" (the DnD
  # mode). gettext via the module backend so labels localize.
  defp item_sort_options do
    [
      {:position, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Manual")},
      {:name, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Name")},
      {:sku, Gettext.gettext(PhoenixKitCatalogue.Gettext, "SKU")},
      {:base_price, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Price")},
      {:status, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Status")}
    ]
  end

  # Strategy-reorder modal options. Values must match the keys in
  # `@items_reorder_strategy_map`.
  defp item_reorder_strategies do
    [
      {"name_asc", Gettext.gettext(PhoenixKitCatalogue.Gettext, "A → Z by name")},
      {"name_desc", Gettext.gettext(PhoenixKitCatalogue.Gettext, "Z → A by name")},
      {"created_desc", Gettext.gettext(PhoenixKitCatalogue.Gettext, "Newest first")},
      {"created_asc", Gettext.gettext(PhoenixKitCatalogue.Gettext, "Oldest first")},
      {"reverse", Gettext.gettext(PhoenixKitCatalogue.Gettext, "Reverse current order")}
    ]
  end

  # ── Drill-level label helpers ────────────────────────────────────

  defp current_node_label(:uncategorized),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Uncategorized")

  defp current_node_label(%Category{} = cat), do: cat.name
  defp current_node_label(_), do: ""

  defp search_placeholder(nil),
    do:
      Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search items by name, description, or SKU...")

  defp search_placeholder(:uncategorized),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search uncategorized items...")

  defp search_placeholder(%Category{}),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search within this category...")

  defp level_items_empty(_current, "deleted"),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Nothing deleted here.")

  defp level_items_empty(_current, "inactive"),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "No inactive items here.")

  defp level_items_empty(_current, "discontinued"),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "No discontinued items here.")

  defp level_items_empty(:uncategorized, _),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "No uncategorized items.")

  defp level_items_empty(_current, _),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "No items in this category.")

  # ── Bulk-action bars ─────────────────────────────────────────────

  attr(:count, :integer, required: true)
  attr(:view_mode, :string, required: true)

  # Inline bulk-actions content for the DELETED items list (Restore /
  # Delete forever / Clear). The active list owns its own client-side
  # toolbar via the core BulkSelectScope toolkit, so this bar only
  # serves the server-side `@selected_items` selection in Deleted mode.
  defp items_bulk_actions(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-3 grow">
      <span class="text-sm font-medium">
        {Gettext.gettext(PhoenixKitCatalogue.Gettext, "%{count} selected", count: @count)}
      </span>
      <div class="flex items-center gap-2">
        <button phx-click="request_bulk_restore_items" class="btn btn-sm btn-outline btn-success">
          <.icon name="hero-arrow-path" class="w-4 h-4" />
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restore")}
        </button>
        <button phx-click="request_bulk_delete_items" class="btn btn-sm btn-outline btn-error">
          <.icon name="hero-trash" class="w-4 h-4" />
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete forever")}
        </button>
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
end
