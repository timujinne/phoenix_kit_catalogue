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

  use PhoenixKitWeb.Live.UrlState,
    params: [
      current_category_uuid: [default: nil, url_key: "category"],
      search_query: [default: "", url_key: "q"],
      # What the page LISTS: "" = the document outline (categories +
      # this level's items, the default), "items" = every item in the
      # current scope as one flat, searchable list — the index's
      # Catalogues/Items switcher one level down (Max, 2026-08-29:
      # "what if a person has 100 [categories] and wants to search them
      # or the items in the catalogue").
      # Drilled levels only: "" lists the category's OWN items,
      # "subtree" includes every item under its subcategories too — the
      # "include subcategory items" toggle (Max, 2026-08-29).
      items_scope: [default: "", url_key: "items"],
      # What the search returns: "" = everything (categories above items,
      # the default), "categories" or "items" to narrow (Max, 2026-08-29).
      search_type: [default: "", url_key: "type"],
      # Comma-joined attribute VALUE slugs ("blue,oak"). In the URL so a
      # filtered view is a link you can send someone.
      attribute_filter: [default: "", url_key: "attr"]
    ]

  use Gettext, backend: PhoenixKitCatalogue.Gettext

  require Logger

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
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
  import PhoenixKitCatalogue.Web.TableToolbar, only: [column_sections_modal: 1]
  import PhoenixKitWeb.Components.Core.TableRowMenu
  import PhoenixKitWeb.Components.Core.ReorderModal, only: [reorder_modal: 1]
  import PhoenixKitWeb.Components.Core.SortSelector, only: [sort_selector: 1]

  import PhoenixKitWeb.Components.Core.TableDefault,
    only: [
      table_default: 1,
      table_default_header: 1,
      table_default_body: 1,
      table_default_row: 1,
      table_default_header_cell: 1,
      table_default_cell: 1,
      sort_header_cell: 1,
      drag_handle_cell: 1,
      drag_handle_header_cell: 1
    ]

  import PhoenixKitCatalogue.Web.Components

  import PhoenixKitCatalogue.Web.Helpers,
    only: [trim_param: 1, actor_opts: 1, actor_uuid: 1, log_operation_error: 3]

  alias PhoenixKit.Utils.Values
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.PubSub
  alias PhoenixKitCatalogue.Errors
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Schemas.Category
  alias PhoenixKitCatalogue.Schemas.Item
  alias PhoenixKitCatalogue.Web.Components.ProductCard
  alias PhoenixKitCatalogue.Web.LevelSwitchers
  alias PhoenixKitCatalogue.Web.Settings, as: CatalogueSettings
  alias PhoenixKitCatalogue.Web.TableConfig
  alias PhoenixKitCatalogue.Web.ViewConfig

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

  # PhoenixKit auto-applies its admin chrome layout to external module admin
  # views via socket.private[:live_layout]. Opt out here so this view can
  # self-wrap with LayoutWrapper.app_layout and push its title/subtitle into
  # the global admin header (same pattern as /admin/media and orders/index).
  on_mount({__MODULE__, :self_wrapped_layout})

  def on_mount(:self_wrapped_layout, _params, _session, socket) do
    {:cont, put_in(socket.private[:live_layout], {PhoenixKitWeb.Layouts, :app})}
  end

  @impl true
  def mount(%{"uuid" => uuid}, _session, socket) do
    socket =
      assign(socket,
        page_title: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Loading…"),
        # One settings read per mount, threaded down to the rows and cards.
        row_context_menu: CatalogueSettings.context_menu_enabled?(),
        catalogue_uuid: uuid,
        catalogue: nil,
        # ── Drill-down position ──
        # current_category_uuid is managed by UrlState (?category=).
        # nil = root level, "uncategorized" = the uncategorized bucket,
        # or a real category UUID. current_category is the resolved value:
        # nil | :uncategorized | %Category{}.
        # prior_category_uuid: tracks the last-loaded category so
        # handle_url_state can detect node changes without needing to diff
        # the assigns on a struct that includes mutable association maps.
        prior_category_uuid: :__unset__,
        current_category: nil,
        # Trimmed active-ancestor chain above the current node (root and
        # current node excluded). Drives the breadcrumb.
        breadcrumb: [],
        # Direct child categories shown as drill cards at this level.
        child_categories: [],
        child_counts: %{},
        children_with_subs: MapSet.new(),
        child_subcat_counts: %{},
        # Root-active only: the Uncategorized drill card.
        uncategorized_active_count: 0,
        # ── Current node's own direct items (single paged list) ──
        items: [],
        items_total: 0,
        items_offset: 0,
        items_has_more: false,
        show_items_section: false,
        category_tree_children: %{},
        # The header's level switchers (`LevelSwitchers`): every catalogue,
        # and the catalogue's live categories grouped by parent.
        switch_catalogues: [],
        switch_siblings: %{},
        expanded_categories: MapSet.new(),
        # Per-status item counts for the current node — drive the four
        # per-status tab labels (active / inactive / discontinued / deleted).
        level_status_counts: %{},
        # `[{status, label, count}]` for the tabs to actually render — only
        # populated statuses; the strip hides itself when there's ≤1.
        status_tabs: [],
        # %{resource_uuid => attached-document count} for every row this LV
        # has loaded (level items, search results, child categories) —
        # drives the paperclip indicator. Merged per page load; per-uuid
        # entries are overwritten on reload, so staleness is bounded.
        file_counts: %{},
        supplier_costs: %{},
        # Edit links carry the current level as return_to; recomputed on
        # every level load. The bare path fn is only the pre-load default.
        edit_path_fn: &Paths.item_edit/1,
        # ── Product-view card (opened by clicking a featured thumb) ──
        card_open: false,
        card_name: nil,
        card_images: [],
        card_fields: [],
        card_files: [],
        card_edit_path: nil,
        confirm_delete: nil,
        confirm_delete_scope: nil,
        trash_modal: nil,
        bulk_move_modal: nil,
        bulk_move_categories_modal: nil,
        bulk_duplicate_modal: nil,
        bulk_confirm: nil,
        attribute_map: %{},
        selected_categories: MapSet.new(),
        # Categories captured by "Reorder N selected" (core toolkit); [] = all.
        categories_reorder_captured: [],
        # ── Active item list sort + strategy reorder ──
        # The active list uses the core List-UI toolkit: a sort dropdown,
        # client-side bulk-select, DnD reorder (manual mode only), and a
        # strategy "Reorder" modal. `reorder_captured_uuids` holds the
        # uuids the BulkSelectScope hook captured for the open modal
        # (empty == "reorder all").
        categories_sort_by: :position,
        categories_sort_dir: :asc,
        items_sort_by: :position,
        items_sort_dir: :asc,
        items_columns:
          ViewConfig.load(socket.assigns[:phoenix_kit_current_user], :detail_items).columns,
        categories_columns:
          ViewConfig.load(socket.assigns[:phoenix_kit_current_user], :detail_categories).columns,
        show_columns_modal: false,
        show_items_reorder: false,
        show_categories_reorder: false,
        reorder_captured_uuids: [],
        view_mode: "active",
        # `view_mode` here is the ACTIVE/DELETED bucket; this is the
        # card/comfy/table preference, shared module-wide per user.
        view_mode_pref: ViewConfig.load_view(socket.assigns[:phoenix_kit_current_user]),
        # The node the current view_mode was chosen FOR (load_level) — the
        # auto-pick of a populated tab happens only when this changes.
        view_mode_node: :unset,
        attribute_filter_options: [],
        attribute_value_counts: %{},
        prior_attribute_filter: "",
        items_scope: "",
        prior_items_scope: "",
        search_type: "",
        search_results: nil,
        search_categories: [],
        category_trails: %{},
        search_offset: 0,
        search_total: 0,
        search_has_more: false,
        search_loading: false,
        # True between a cross-tab `{:catalogue_bulk_change, …}` and its
        # deferred `:bulk_change_apply`: the plain data-changed refresh is
        # held back so the leaving-rows flash can play before the reload.
        bulk_change_pending: false
      )

    # Subscribe BEFORE the first load so a write landing between connect
    # and load doesn't leave the UI stale. The actual level load happens
    # in handle_params/3, which runs after mount and on every `?category=`
    # drill patch.
    if connected?(socket), do: PubSub.subscribe()

    socket = apply_global_detail_sorts(socket)

    {:ok, socket}
  end

  # `?category=` and `?q=` are managed by UrlState. This stub satisfies
  # Phoenix's handle_params/3 callback (required because @impl is used).
  # UrlState attaches its own hook via on_mount, which composes alongside.
  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # Called by UrlState after mount and on every URL state change. Detects
  # node changes via `prior_category_uuid` (set to :__unset__ in mount so
  # the very first call always triggers a level load). On a node change we
  # reset selections and reload the level; on a search-only change we run
  # or clear the search without touching the level data.
  @impl true
  def handle_url_state(state, socket) do
    # Normalize the key so that nil and "" both mean "root level" — the
    # same guard that the old handle_params used via normalize_category_key.
    cat_key = normalize_category_key(state.current_category_uuid)
    prev_cat = socket.assigns.prior_category_uuid
    cat_changed? = cat_key != prev_cat

    # Write the normalized key back over the raw one UrlState decoded, so the
    # assign the template reads is the same value the rest of this module
    # branches on. `?category=` (empty) otherwise leaves `""` in the assign:
    # the DOM ids built from `@current_category_uuid || "root"` come out as
    # `items-body-` instead of `items-body-root`, and because push_url_state
    # reads its merge base back from the assigns, the next search patch
    # re-writes the empty `?category=` into the URL. UrlState documents a
    # plain assign on a declared param as the supported way to do this.
    socket = assign(socket, :current_category_uuid, cat_key)

    socket =
      if cat_changed? do
        socket
        |> assign(:prior_category_uuid, cat_key)
        |> assign(:selected_categories, MapSet.new())
        # A View card belongs to the level it was opened from: leaving that
        # level closes it. Without this the card outlives the drill — and
        # since only `card_close` ever cleared the flag, a dismissal the
        # server never heard about (see core's `modal/1`) came back as
        # another level's item, carrying an Edit link to it.
        |> assign(:card_open, false)
      else
        socket
      end

    # An attribute filter change re-fetches the level exactly as a
    # category change does: the items, their total, and any active search
    # all narrow by it (2026-08-28).
    filter_changed? = state.attribute_filter != socket.assigns[:prior_attribute_filter]
    socket = assign(socket, :prior_attribute_filter, state.attribute_filter)

    # The Categories/Items page mode. Client-forgeable URL state —
    # anything unknown means the default outline view. A mode change
    # re-fetches the level: whether the item list loads at all depends
    # on it (`show_items_section`). Compared against a PRIOR tracker,
    # not the param assign — UrlState auto-assigns declared params
    # before this callback runs, so the param assign always reads as
    # "unchanged" (the same reason prior_category_uuid and
    # prior_attribute_filter exist).
    {socket, toggles_changed?} = track_url_toggles(socket, state, cat_key)
    socket = assign(socket, :search_type, normalize_search_type(state.search_type, cat_key))

    socket =
      cond do
        not connected?(socket) ->
          socket

        cat_changed? ->
          load_url_state_level(socket, cat_key, state.search_query)

        filter_changed? or toggles_changed? ->
          socket |> handle_url_state_search(state.search_query) |> reset_and_load()

        true ->
          handle_url_state_search(socket, state.search_query)
      end

    # Publish the FULL current URL (query included) as url_path: the layout
    # hands it to core's language switcher as current_path, and a bare path
    # meant switching languages threw you out of the drilled category
    # (boss, 2026-08-31). Core's tab matching strips queries, and UrlState
    # keeps its own bare-path base, so nothing else shifts.
    assign(socket, :url_path, url_state_path(socket, %{}))
  end

  # Resolves the category UUID from URL state, loads the level, then
  # handles any search query present in the URL. Bounces back to root on
  # an invalid / foreign category UUID; navigates to index if the
  # catalogue itself is gone.
  defp load_url_state_level(socket, cat_key, search_query) do
    case resolve_node(socket.assigns.catalogue_uuid, cat_key) do
      {:ok, current} ->
        socket
        |> assign(:current_category, Catalogue.localize_one(current, loc(socket)))
        |> reset_and_load()
        |> maybe_auto_flip_to_active()
        # AFTER the level settles: the search stamp bakes in the view
        # mode, and the tab auto-pick above can change it — stamping
        # first dropped the search's own reply and left the spinner on
        # (panel finding).
        |> handle_url_state_search(search_query)

      :invalid ->
        socket
        |> put_flash(
          :error,
          Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category not found.")
        )
        |> push_patch(to: Paths.catalogue_detail(socket.assigns.catalogue_uuid))
    end
  rescue
    Ecto.NoResultsError ->
      Logger.warning("Catalogue not found: #{socket.assigns.catalogue_uuid}")

      socket
      |> put_flash(:error, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue not found."))
      |> push_navigate(to: Paths.index())
  end

  defp handle_url_state_search(socket, ""), do: clear_search(socket)
  defp handle_url_state_search(socket, query), do: run_search(socket, query)

  # The ROOT's items page mode: every item in the catalogue through the
  # full management surface. Root-only since 2026-08-29 — a drilled
  # category's page always shows both its subcategories and its items
  # (Max: "we already see items and categories at the same time"), so
  # the Categories/Items question only exists at the top. Inert in the
  # Deleted view (`?mode=` rides the URL for the trip back).
  # NOT flipped by the 2026-08-31 items-default change (unlike the
  # index): the root's default search ALREADY returns items — matches in
  # categories and items render as two lists — so the auto default here
  # keeps that richer surface, and "items" stays the explicit
  # item-management list.
  # The drilled page's one real question: the category's own items, or
  # everything under its subcategories too.
  defp subtree_items?(assigns) do
    assigns.items_scope == "subtree" and match?(%Category{}, assigns.current_category)
  end

  # What the search actually asks for: the `?type=` chips' choice. The trash
  # shows no chips and finds no categories, so it always searches everything.
  defp effective_search_type(%{view_mode: "deleted"}), do: ""
  defp effective_search_type(assigns), do: assigns.search_type

  # The result-type chips (All / Categories / Items). Client-forgeable
  # URL state, so anything unknown means the default. A type change only
  # re-asks the SEARCH — the catch-all branch above already does that on
  # every patch — while the level under the results is untouched.
  #
  # The uncategorized bucket always searches as All: it holds no
  # categories to find and hides the chips, so a "categories" type
  # carried in from elsewhere would turn every search into "Nothing
  # matches your search." with no visible control to escape (panel
  # finding, 2026-08-29). Normalizing to "" also makes the next
  # push_url_state drop the stale ?type= — the merge base is read back
  # from the assign.
  # The items-scope ("include subcategory items", drilled) toggle,
  # normalized and change-tracked against a prior_* assign — UrlState
  # auto-assigns declared params before the callback, so comparing
  # against the param assign itself never fires (the third-time trap).
  # A change re-fetches the level: what the item list even CONTAINS
  # depends on it. (The root Categories/Items page mode lived here too
  # until 2026-08-31 — retired with its switcher.)
  defp track_url_toggles(socket, state, cat_key) do
    # "subtree" only means something on a drilled category — normalized
    # away at root/bucket so URL-state merges cannot carry it into the
    # next drilled page by surprise (panel finding).
    scope =
      if state.items_scope == "subtree" and not is_nil(cat_key) and cat_key != "uncategorized",
        do: "subtree",
        else: ""

    changed? = scope != socket.assigns[:prior_items_scope]

    socket =
      socket
      |> assign(:items_scope, scope)
      |> assign(:prior_items_scope, scope)

    {socket, changed?}
  end

  # Only the ROOT keeps the type chips: a drilled category's page shows
  # sections and content side by side, so its search covers both
  # automatically — matches in both simply render as two lists (Max,
  # 2026-08-29). The bucket holds no categories either way.
  defp normalize_search_type(type, nil) when type in ["categories", "items"], do: type
  defp normalize_search_type(_type, _cat_key), do: ""

  defp normalize_category_key(nil), do: nil
  defp normalize_category_key(""), do: nil
  defp normalize_category_key("uncategorized"), do: "uncategorized"
  defp normalize_category_key(uuid) when is_binary(uuid), do: uuid

  # Resolves a `?category=` key to the current node. A UUID that doesn't
  # exist, belongs to another catalogue or names a trashed category is
  # `:invalid` (caller bounces to root).
  defp resolve_node(_catalogue_uuid, nil), do: {:ok, nil}
  defp resolve_node(_catalogue_uuid, "uncategorized"), do: {:ok, :uncategorized}

  # A trashed category is a closed unit in the Deleted tab and cannot be
  # opened: its URL bounces like an unknown one.
  defp resolve_node(catalogue_uuid, uuid) do
    case Catalogue.get_category(uuid) do
      %Category{catalogue_uuid: ^catalogue_uuid, status: status} = cat when status != "deleted" ->
        {:ok, cat}

      _ ->
        :invalid
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

  # Attribute sets are global (not catalogue-scoped, no `parent`) — a
  # value rename/extra-field edit elsewhere must still refresh any open
  # detail page resolving items that attach the set.
  def handle_info({:catalogue_data_changed, :attribute_set, _uuid, _parent}, socket) do
    handle_catalogue_data_changed(socket)
  end

  # Supplier rows broadcast with the item's catalogue as parent (nil only
  # for a row whose item is gone); only this catalogue's "Supplier price"
  # column depends on them — every other detail page ignores the event
  # instead of re-running the cost aggregate.
  def handle_info(
        {:catalogue_data_changed, :item_supplier_info, _uuid, parent},
        %{assigns: %{catalogue_uuid: catalogue_uuid}} = socket
      )
      when parent == catalogue_uuid or is_nil(parent) do
    {:noreply, refresh_supplier_costs(socket)}
  end

  def handle_info({:catalogue_data_changed, :item_supplier_info, _uuid, _parent}, socket),
    do: {:noreply, socket}

  # Another admin changed a shared detail sort (global-sort scopes) —
  # apply it without re-persisting or re-broadcasting.
  def handle_info({:catalogue_view_sort_changed, :detail_items, by, dir, from}, socket) do
    if from == self() do
      {:noreply, socket}
    else
      dir = if dir == :desc, do: :desc, else: :asc
      {:noreply, apply_items_sort(socket, detail_items_sort_field(by), dir)}
    end
  end

  def handle_info({:catalogue_view_sort_changed, :detail_categories, by, dir, from}, socket) do
    if from == self() do
      {:noreply, socket}
    else
      dir = if dir == :desc, do: :desc, else: :asc
      field = detail_categories_sort_field(by)

      socket = assign(socket, categories_sort_by: field, categories_sort_dir: dir)

      {:noreply,
       assign(
         socket,
         :child_categories,
         sort_categories(socket.assigns.child_categories, socket.assigns.child_counts, field, dir)
       )}
    end
  end

  def handle_info({:catalogue_view_sort_changed, _scope, _by, _dir, _from}, socket),
    do: {:noreply, socket}

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

  # Another catalogue's traffic on the shared topic: nothing to do, and
  # not worth a debug line per event.
  def handle_info({:catalogue_card_refresh, _, _, _, _, _}, socket), do: {:noreply, socket}

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

  def handle_info({:catalogue_category_reorder, _, _, _, _}, socket), do: {:noreply, socket}

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

    {:noreply, assign(socket, :bulk_change_pending, true)}
  end

  # Originator's own bulk-change broadcast — already updated locally.
  def handle_info({:catalogue_bulk_change, _, _, _, from}, socket) when from == self(),
    do: {:noreply, socket}

  def handle_info({:catalogue_bulk_change, _, _, _, _}, socket), do: {:noreply, socket}

  # Tail of the cross-tab bulk animation — applies the actual state
  # refresh and the arriving-side green flash (for moves / restores).
  # `reset_and_load/1` already loads the level (no second `refresh_counts`);
  # an active search is re-run too, since the batch `:item` event that
  # would have done it was held back by `bulk_change_pending`. The
  # catalogue may have been deleted during the flash delay — same bounce
  # as a plain refresh.
  def handle_info({:bulk_change_apply, kind, uuids}, socket) do
    socket =
      socket
      |> assign(:bulk_change_pending, false)
      |> reset_and_load()
      |> rerun_active_search()

    socket =
      if kind in [:restored, :moved],
        do: Enum.reduce(uuids, socket, &flash_reorder(&2, &1, :ok)),
        else: socket

    {:noreply, socket}
  rescue
    Ecto.NoResultsError -> {:noreply, catalogue_gone(socket)}
  end

  def handle_info(msg, socket) do
    Logger.debug("CatalogueDetailLive ignored unhandled message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # A batch `:item` event from a bulk op that this page is already
  # animating (`bulk_change_pending`) is skipped — the scheduled
  # `:bulk_change_apply` reloads everything once the flash has played.
  defp handle_catalogue_data_changed(%{assigns: %{bulk_change_pending: true}} = socket),
    do: {:noreply, socket}

  defp handle_catalogue_data_changed(socket) do
    {:noreply, refresh_in_place(socket)}
  rescue
    Ecto.NoResultsError -> {:noreply, catalogue_gone(socket)}
  end

  # The catalogue we're viewing was deleted in another session.
  defp catalogue_gone(socket) do
    socket
    |> put_flash(
      :info,
      Gettext.gettext(PhoenixKitCatalogue.Gettext, "This catalogue was just deleted.")
    )
    |> push_navigate(to: Paths.index())
  end

  # ── Event handlers ──────────────────────────────────────────────

  @impl true
  def handle_event("switch_view", %{"mode" => mode}, socket)
      when mode in ~w(active inactive discontinued deleted) do
    # Search is Active-only (the context search excludes deleted rows), so
    # a tab switch drops it — otherwise the page kept rendering the old
    # results grid instead of the tab it just switched to. The `?q=` goes
    # too, or the next URL patch would re-run it.
    had_search? = socket.assigns.search_query != ""

    socket =
      socket
      |> assign(:view_mode, mode)
      |> assign(:confirm_delete, nil)
      |> assign(:selected_categories, MapSet.new())
      |> clear_search()
      |> reset_and_load()

    if had_search?,
      do: {:noreply, push_url_state(socket, [search_query: ""], replace: true)},
      else: {:noreply, socket}
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
    query = trim_param(query)
    {:noreply, push_url_state(socket, [search_query: query], replace: true)}
  end

  def handle_event("set_view", %{"mode" => v}, socket) when v in ["table", "card", "comfy"] do
    {:noreply, socket |> ViewConfig.save_view_on(v) |> assign(:view_mode_pref, v)}
  end

  def handle_event("set_view", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_attribute_filter", %{"slug" => slug}, socket) when is_binary(slug) do
    current = attribute_filter_slugs(socket)

    next =
      if slug in current,
        do: List.delete(current, slug),
        else: current ++ [slug]

    {:noreply, push_url_state(socket, attribute_filter: Enum.join(next, ","))}
  end

  def handle_event("toggle_attribute_filter", _params, socket), do: {:noreply, socket}

  def handle_event("clear_attribute_filter", _params, socket) do
    {:noreply, push_url_state(socket, attribute_filter: "")}
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply, push_url_state(socket, search_query: "")}
  end

  # The All / Categories / Items chips on the search results.
  def handle_event("set_search_type", %{"type" => type}, socket)
      when type in ["", "categories", "items"] do
    {:noreply, push_url_state(socket, search_type: type)}
  end

  def handle_event("set_search_type", _params, socket), do: {:noreply, socket}

  # The drilled "include subcategory items" toggle.

  def handle_event("toggle_items_scope", _params, socket) do
    next = if subtree_items?(socket.assigns), do: "", else: "subtree"
    {:noreply, push_url_state(socket, items_scope: next)}
  end

  # ── Product-view card (opened by clicking a featured-image thumb) ──
  # Host-side mirror of ItemPicker's card handlers: no phx-target on the
  # thumbs/table events here, so they arrive at this LiveView. All payloads
  # are client-forgeable — every clause has a catch-all or validates the
  # uuid against the card's own state.

  def handle_event("show_product_card", %{"uuid" => uuid}, socket) do
    # Scoped like every other item event on this page: the card now carries
    # operator details and an Edit link, so a crafted uuid must not show an
    # item from another catalogue here — with this page's return path on it.
    case item_in_catalogue(socket, uuid) do
      %Item{} = item ->
        locale = socket.assigns[:current_locale] || "en"

        {:noreply,
         assign(socket,
           card_open: true,
           card_name: ProductCard.resolve_name(item, locale),
           card_images: ProductCard.resolve_images(item),
           # This card is the ADMIN view of the item (the View action), so it
           # carries the operator rows a client-facing embed must not show.
           card_fields: ProductCard.build_fields(item, locale, admin: true),
           card_files: ProductCard.resolve_files(item),
           # A deleted item has no edit page to offer — the Deleted tab's
           # own menu hides Edit for the same reason.
           card_edit_path: item.status != "deleted" && socket.assigns.edit_path_fn.(item.uuid)
         )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("show_product_card", _params, socket), do: {:noreply, socket}

  # The same card for the row ABOVE the items (boss via Max, 2026-09-20:
  # catalogues and categories want a View too). It fills the SAME assigns —
  # one dialog on the page, so closing it stays one path — and is scoped
  # through `category_in_catalogue` for the reason the item event is.
  def handle_event("show_category_card", %{"uuid" => uuid}, socket) do
    case category_in_catalogue(socket, uuid) do
      %Category{} = category ->
        locale = socket.assigns[:current_locale] || "en"

        {:noreply,
         assign(socket,
           card_open: true,
           card_name: ProductCard.resolve_name(category, locale),
           card_images: ProductCard.resolve_images(category),
           card_fields: ProductCard.build_category_fields(category, locale, admin: true),
           # The category form takes a featured image but no file folder,
           # so there is never a file list to show here.
           card_files: [],
           card_edit_path:
             category.status != "deleted" &&
               with_return_to(
                 Paths.category_edit(category.uuid),
                 current_level_path(socket.assigns)
               )
         )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("show_category_card", _params, socket), do: {:noreply, socket}

  # The catalogue's own card, from its picture at the top of the page —
  # always the page's catalogue, so nothing is read from the payload.
  def handle_event("show_catalogue_card", _params, socket) do
    case Catalogue.get_catalogue(socket.assigns.catalogue_uuid) do
      %{} = catalogue ->
        locale = socket.assigns[:current_locale] || "en"

        {:noreply,
         assign(socket,
           card_open: true,
           card_name: ProductCard.resolve_name(catalogue, locale),
           card_images: ProductCard.resolve_images(catalogue),
           card_fields: ProductCard.build_catalogue_fields(catalogue, locale, admin: true),
           card_files: ProductCard.resolve_files(catalogue),
           card_edit_path: catalogue.status != "deleted" && Paths.catalogue_edit(catalogue.uuid)
         )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("card_close", _params, socket) do
    {:noreply, assign(socket, :card_open, false)}
  end

  def handle_event("delete_item", %{"uuid" => uuid}, socket) do
    with %{} = item <- item_in_catalogue(socket, uuid),
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
    with %{} = item <- item_in_catalogue(socket, uuid),
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
    {:noreply,
     socket
     |> assign(:confirm_delete, {type, uuid})
     |> assign(:confirm_delete_scope, delete_scope(type, socket, uuid))}
  end

  def handle_event("permanently_delete_item", _params, socket) do
    case socket.assigns.confirm_delete do
      {"item", uuid} ->
        with %{} = item <- item_in_catalogue(socket, uuid),
             {:ok, _} <-
               Catalogue.permanently_delete_item(item, [only_trashed: true] ++ actor_opts(socket)) do
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

          {:error, :not_in_trash} ->
            {:noreply, not_in_trash(socket)}

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
      %Category{catalogue_uuid: cat_uuid} = category
      when cat_uuid == socket.assigns.catalogue_uuid ->
        item_count = Catalogue.active_item_count_in_subtree(uuid)

        if item_count == 0 do
          do_trash_category(socket, category, items: :cascade)
        else
          {:noreply,
           assign(
             socket,
             :trash_modal,
             build_trash_modal_state(category, item_count, loc(socket))
           )}
        end

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category not found.")
         )}
    end
  end

  # A modal event after the modal closed (double click, second tab,
  # stale client) is a no-op, not a KeyError on `%{}`.
  def handle_event("set_trash_disposition", _params, %{assigns: %{trash_modal: nil}} = socket),
    do: {:noreply, socket}

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

  # A modal event after the modal closed (double click, second tab,
  # stale client) is a no-op, not a KeyError on `%{}`.
  def handle_event("select_trash_target", _params, %{assigns: %{trash_modal: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("select_trash_target", %{"category_uuid" => uuid}, socket) do
    modal = socket.assigns.trash_modal
    target = accepted_picker_target(modal.targets, uuid)
    {:noreply, assign(socket, :trash_modal, %{modal | target_uuid: target})}
  end

  def handle_event("confirm_trash_category", _params, socket) do
    case socket.assigns.trash_modal do
      %{bulk: true} = modal ->
        confirm_bulk_trash(socket, modal)

      %{category: category, disposition: :uncategorize} ->
        socket
        |> assign(:trash_modal, nil)
        |> do_trash_category(category, items: :uncategorize)

      %{category: category, disposition: :move_to, target_uuid: target, targets: targets}
      when not is_nil(target) ->
        confirm_trash_move_to(socket, category, target, targets)

      %{category: category, disposition: :cascade} ->
        socket
        |> assign(:trash_modal, nil)
        |> do_trash_category(category, items: :cascade)

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_trash_category", _params, socket) do
    {:noreply, assign(socket, :trash_modal, nil)}
  end

  # ── Bulk selection + actions ────────────────────────────────────

  # Bulk delete items — opens a confirm modal stamped with the selection
  # and the operation type. Both tabs supply the uuids client-side (core's
  # BulkSelectScope) as `%{"uuids" => [...]}`.
  # Confirmation routes through `confirm_bulk_action` below.
  def handle_event("request_bulk_delete_items", params, socket) do
    uuids = sanitize_uuids(params)

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
    uuids = sanitize_uuids(params)
    if uuids == [], do: {:noreply, socket}, else: do_bulk_restore_items(socket, uuids)
  end

  def handle_event("request_bulk_move_items", params, socket) do
    uuids = sanitize_uuids(params)

    if uuids == [] do
      {:noreply, socket}
    else
      {:noreply,
       assign(socket, :bulk_move_modal, %{
         count: length(uuids),
         uuids: uuids,
         catalogues: move_catalogue_choices(socket),
         target_catalogue_uuid: socket.assigns.catalogue_uuid,
         targets: item_move_targets(socket, socket.assigns.catalogue_uuid),
         disposition: :uncategorize,
         target_uuid: nil
       })}
    end
  end

  # A modal event after the modal closed (double click, second tab,
  # stale client) is a no-op, not a KeyError on `%{}`.
  def handle_event(
        "set_bulk_move_disposition",
        _params,
        %{assigns: %{bulk_move_modal: nil}} = socket
      ),
      do: {:noreply, socket}

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

  # A modal event after the modal closed (double click, second tab,
  # stale client) is a no-op, not a KeyError on `%{}`.
  def handle_event(
        "select_bulk_move_target",
        _params,
        %{assigns: %{bulk_move_modal: nil}} = socket
      ),
      do: {:noreply, socket}

  def handle_event("select_bulk_move_target", %{"category_uuid" => uuid}, socket) do
    modal = socket.assigns.bulk_move_modal
    target = accepted_picker_target(modal.targets, uuid)
    {:noreply, assign(socket, :bulk_move_modal, %{modal | target_uuid: target})}
  end

  def handle_event(
        "select_bulk_move_catalogue",
        _params,
        %{assigns: %{bulk_move_modal: nil}} = socket
      ),
      do: {:noreply, socket}

  # Another catalogue re-lists its categories and forgets the category
  # picked in the previous one; only a catalogue the modal offered counts.
  def handle_event("select_bulk_move_catalogue", %{"catalogue_uuid" => uuid}, socket)
      when is_binary(uuid) do
    modal = socket.assigns.bulk_move_modal

    if offered_catalogue?(modal.catalogues, uuid) do
      {:noreply,
       assign(socket, :bulk_move_modal, %{
         modal
         | target_catalogue_uuid: uuid,
           targets: item_move_targets(socket, uuid),
           target_uuid: nil
       })}
    else
      {:noreply, socket}
    end
  end

  # A picker event without a catalogue (a stale or forged client) changes
  # nothing.
  def handle_event("select_bulk_move_catalogue", _params, socket), do: {:noreply, socket}

  def handle_event("confirm_bulk_move_items", _params, socket) do
    case socket.assigns.bulk_move_modal do
      %{disposition: :uncategorize, uuids: uuids, target_catalogue_uuid: catalogue_uuid} ->
        do_bulk_move_items(socket, uuids, {:catalogue, catalogue_uuid})

      %{disposition: :move_to, target_uuid: target_uuid, uuids: uuids, targets: targets}
      when not is_nil(target_uuid) ->
        if picker_has_target?(targets, target_uuid),
          do: do_bulk_move_items(socket, uuids, {:category, target_uuid}),
          else: {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_bulk_move", _params, socket) do
    {:noreply, assign(socket, :bulk_move_modal, nil)}
  end

  # ── Bulk move categories (re-parent / promote to top level) ──────
  # The selection arrives with the action (core BulkSelectScope). Targets
  # are the catalogue's active categories minus every selected category's
  # own subtree — a category cannot go under itself or a descendant — so
  # the picker never offers a cycle; the context re-checks under a lock.
  def handle_event("request_bulk_move_categories", params, socket) do
    uuids = sanitize_uuids(params)

    if uuids == [] do
      {:noreply, socket}
    else
      {:noreply,
       assign(socket, :bulk_move_categories_modal, %{
         count: length(uuids),
         uuids: uuids,
         catalogues: move_catalogue_choices(socket),
         target_catalogue_uuid: socket.assigns.catalogue_uuid,
         targets: category_targets_in(socket, uuids, socket.assigns.catalogue_uuid),
         disposition: :top_level,
         target_uuid: nil
       })}
    end
  end

  # A modal event after the modal closed (double click, second tab,
  # stale client) is a no-op, not a KeyError on `%{}`.
  def handle_event(
        "set_bulk_move_categories_disposition",
        _params,
        %{assigns: %{bulk_move_categories_modal: nil}} = socket
      ),
      do: {:noreply, socket}

  def handle_event("set_bulk_move_categories_disposition", %{"disposition" => disp}, socket) do
    modal = socket.assigns.bulk_move_categories_modal || %{}

    new_modal =
      case disp do
        "top_level" -> %{modal | disposition: :top_level, target_uuid: nil}
        "move_under" -> %{modal | disposition: :move_under}
        _ -> modal
      end

    {:noreply, assign(socket, :bulk_move_categories_modal, new_modal)}
  end

  # A modal event after the modal closed (double click, second tab,
  # stale client) is a no-op, not a KeyError on `%{}`.
  def handle_event(
        "select_bulk_move_categories_target",
        _params,
        %{assigns: %{bulk_move_categories_modal: nil}} = socket
      ),
      do: {:noreply, socket}

  def handle_event("select_bulk_move_categories_target", %{"category_uuid" => uuid}, socket) do
    modal = socket.assigns.bulk_move_categories_modal
    target = accepted_picker_target(modal.targets, uuid)

    {:noreply, assign(socket, :bulk_move_categories_modal, %{modal | target_uuid: target})}
  end

  def handle_event(
        "select_bulk_move_categories_catalogue",
        _params,
        %{assigns: %{bulk_move_categories_modal: nil}} = socket
      ),
      do: {:noreply, socket}

  def handle_event("select_bulk_move_categories_catalogue", %{"catalogue_uuid" => uuid}, socket)
      when is_binary(uuid) do
    modal = socket.assigns.bulk_move_categories_modal

    if offered_catalogue?(modal.catalogues, uuid) do
      {:noreply,
       assign(socket, :bulk_move_categories_modal, %{
         modal
         | target_catalogue_uuid: uuid,
           targets: category_targets_in(socket, modal.uuids, uuid),
           target_uuid: nil
       })}
    else
      {:noreply, socket}
    end
  end

  def handle_event("select_bulk_move_categories_catalogue", _params, socket),
    do: {:noreply, socket}

  def handle_event("confirm_bulk_move_categories", _params, socket) do
    case socket.assigns.bulk_move_categories_modal do
      %{disposition: :top_level, uuids: uuids, target_catalogue_uuid: catalogue_uuid} ->
        do_bulk_move_categories(socket, uuids, catalogue_uuid, nil)

      %{
        disposition: :move_under,
        target_uuid: target,
        uuids: uuids,
        targets: targets,
        target_catalogue_uuid: catalogue_uuid
      }
      when is_binary(target) ->
        confirm_bulk_move_categories_under(socket, uuids, catalogue_uuid, target, targets)

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_bulk_move_categories", _params, socket) do
    {:noreply, assign(socket, :bulk_move_categories_modal, nil)}
  end

  # ── Bulk duplicate (items and categories share one confirm modal) ──
  def handle_event("request_bulk_duplicate_items", params, socket),
    do: {:noreply, open_bulk_duplicate_modal(socket, :items, sanitize_uuids(params))}

  def handle_event("request_bulk_duplicate_categories", params, socket),
    do: {:noreply, open_bulk_duplicate_modal(socket, :categories, sanitize_uuids(params))}

  def handle_event("confirm_bulk_duplicate", _params, socket) do
    case socket.assigns.bulk_duplicate_modal do
      %{kind: :items, uuids: uuids} -> do_bulk_duplicate_items(socket, uuids)
      %{kind: :categories, uuids: uuids} -> do_bulk_duplicate_categories(socket, uuids)
      _ -> {:noreply, socket}
    end
  end

  def handle_event("cancel_bulk_duplicate", _params, socket) do
    {:noreply, assign(socket, :bulk_duplicate_modal, nil)}
  end

  def handle_event("confirm_bulk_action", _params, socket) do
    case socket.assigns.bulk_confirm do
      %{kind: :items, mode: :trash, uuids: uuids} ->
        do_bulk_trash_items(socket, uuids)

      %{kind: :items, mode: :permanent, uuids: uuids} ->
        do_bulk_permanent_delete_items(socket, uuids)

      %{kind: :categories, mode: :permanent, uuids: uuids} ->
        do_bulk_permanent_delete_categories(socket, uuids)

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
  # The selection lives in the browser (core BulkSelectScope, the same
  # toolkit the item list uses) and arrives as `%{"uuids" => [...]}`; it
  # is snapshotted into `@selected_categories` so the confirm path and
  # the post-op reset keep working unchanged.
  def handle_event("request_bulk_delete_categories", params, socket) do
    uuids = sanitize_uuids(params)
    socket = assign(socket, :selected_categories, MapSet.new(uuids))

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
             targets:
               localize_targets(Catalogue.list_move_target_categories(category), loc(socket)),
             disposition: :cascade,
             target_uuid: nil,
             bulk: true,
             bulk_uuids: uuids
           })}
      end
    end
  end

  # The Deleted tab's selection arrives client-side as `%{"uuids" => [...]}`.
  def handle_event("request_bulk_restore_categories", params, socket) do
    case sanitize_uuids(params) do
      [] -> {:noreply, socket}
      uuids -> do_bulk_restore_categories(socket, uuids)
    end
  end

  # Bulk Delete forever from the Deleted tab — confirmed first, like the
  # items' bulk permanent delete.
  def handle_event("request_bulk_permanent_delete_categories", params, socket) do
    case sanitize_uuids(params) do
      [] ->
        {:noreply, socket}

      uuids ->
        {:noreply,
         assign(socket, :bulk_confirm, %{
           kind: :categories,
           mode: :permanent,
           count: length(uuids),
           uuids: uuids
         })}
    end
  end

  def handle_event("restore_category", %{"uuid" => uuid}, socket) do
    with %Category{catalogue_uuid: cat_uuid} = category <- Catalogue.get_category(uuid),
         true <- cat_uuid == socket.assigns.catalogue_uuid,
         {:ok, _} <- Catalogue.restore_category(category, actor_opts(socket)) do
      {:noreply,
       socket
       |> put_flash(:info, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category restored."))
       |> reset_and_load()}
    else
      unmatched when unmatched in [nil, false] ->
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
        with %{} = category <- category_in_catalogue(socket, uuid),
             {:ok, _} <-
               Catalogue.permanently_delete_category(
                 category,
                 [only_trashed: true] ++ actor_opts(socket)
               ) do
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

          {:error, :not_in_trash} ->
            {:noreply, not_in_trash(socket)}

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

  # ── Category tree browser (the index's folder tree, one level down) ──

  def handle_event("toggle_category_expand", %{"uuid" => uuid}, socket) when is_binary(uuid) do
    socket =
      update(socket, :expanded_categories, fn expanded ->
        if MapSet.member?(expanded, uuid),
          do: MapSet.delete(expanded, uuid),
          else: MapSet.put(expanded, uuid)
      end)

    {:noreply, remember_expanded(socket)}
  end

  # The browser's remembered open set for this catalogue's tree, sent by
  # the hook on mount. Only parents that exist here are taken (the list
  # is client data); unioned so a click that raced the restore survives.
  def handle_event("restore_expanded_categories", %{"uuids" => uuids}, socket)
      when is_list(uuids) do
    known = socket.assigns.category_tree_children

    restored =
      uuids
      |> Enum.filter(&(is_binary(&1) and Map.has_key?(known, &1)))
      |> MapSet.new()

    {:noreply, update(socket, :expanded_categories, &MapSet.union(&1, restored))}
  end

  def handle_event("restore_expanded_categories", _params, socket), do: {:noreply, socket}

  # A middle drop on a row: nest the dragged category under it (or lift
  # it to this level via the root zone). Cycle / cross-catalogue guards
  # live in `Catalogue.move_category_under/3`.
  def handle_event(
        "move_to_folder",
        %{"type" => "category", "uuid" => uuid, "target" => target},
        socket
      )
      when is_binary(uuid) do
    # Nesting, not ordering: under any sort the moved category lands where
    # the sort puts it, which is what nesting means. Reachable under a sort
    # only by a drag that started in Manual order before someone changed the
    # shared sort — and the index files a catalogue the same way (its
    # `move_to_folder` is also the row menu's Move), so the two pages agree
    # (codex, 2026-09-21). Edge drops (`drop_row`) write sibling order and
    # stay Manual-only.
    with true <- categories_tree_mode?(socket.assigns),
         {:ok, _} <- Ecto.UUID.cast(uuid),
         {:ok, target_uuid} <- resolve_tree_target(socket, target) do
      {:noreply,
       socket
       |> apply_category_move(uuid, target_uuid, nil)
       |> reset_and_load()}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("move_to_folder", _params, socket), do: {:noreply, socket}

  # An edge drop: re-parent if the level changed, then write the level's
  # order — the dragged row spliced in where it landed.
  def handle_event(
        "drop_row",
        %{"type" => "category", "uuid" => uuid, "parent" => parent, "entries" => entries},
        socket
      )
      when is_binary(uuid) and is_list(entries) do
    with true <- categories_reorderable?(socket.assigns),
         {:ok, _} <- Ecto.UUID.cast(uuid),
         {:ok, target_uuid} <- resolve_tree_target(socket, parent),
         {:ok, ordered_uuids} <- parse_category_entries(entries),
         true <- uuid in ordered_uuids and ordered_uuids == Enum.uniq(ordered_uuids) do
      {:noreply,
       socket
       |> apply_category_move(uuid, target_uuid, ordered_uuids)
       |> reset_and_load()}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("drop_row", _params, socket), do: {:noreply, socket}

  def handle_event("reorder_categories", %{"ordered_ids" => ordered_ids} = params, socket)
      when is_list(ordered_ids) do
    # Manual-order mode only. A hook push is a client message that can
    # arrive under any sort (or be forged); applying the Name-sorted
    # visual order would overwrite the stored manual positions.
    if socket.assigns.categories_sort_by == :position do
      apply_category_reorder(socket, ordered_ids, params["moved_id"])
    else
      {:noreply, socket}
    end
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

    {:noreply, socket |> apply_items_sort(field, dir) |> persist_detail_sort(:detail_items)}
  end

  # Categories sort — same SortSelector contract as items/catalogues
  # (select sends only sort_by, the arrow only sort_dir). Hardcoded
  # whitelist; drag + Reorder-all only make sense in manual mode.
  def handle_event("sort_categories", params, socket) do
    field =
      case params["sort_by"] do
        "position" -> :position
        "name" -> :name
        "items" -> :items
        "updated" -> :updated
        _ -> socket.assigns.categories_sort_by
      end

    dir =
      case params["sort_dir"] do
        "desc" -> :desc
        "asc" -> :asc
        _ -> socket.assigns.categories_sort_dir
      end

    {:noreply, apply_categories_sort(socket, field, dir)}
  end

  # Sortable column header click — toggles direction on the active field,
  # otherwise switches field (ascending).
  # ── Columns configuration (per-user, ViewConfig) — ONE modal for the
  # whole page, a section per visible table (a drilled page shows
  # subcategories and items at once, and two side-by-side "Columns"
  # buttons read as a mistake). Events carry the section's scope, and
  # every change applies + persists immediately (footer is Reset +
  # Close, Reset covers every section shown). ──

  def handle_event("show_column_modal", _p, socket),
    do: {:noreply, assign(socket, :show_columns_modal, true)}

  def handle_event("hide_column_modal", _p, socket),
    do: {:noreply, assign(socket, :show_columns_modal, false)}

  def handle_event("add_column", %{"column_id" => id, "scope" => scope_str}, socket)
      when scope_str in ~w(detail_items detail_categories) do
    scope = String.to_existing_atom(scope_str)
    {:noreply, live_update_detail_columns(socket, scope, &(&1 ++ [id]))}
  end

  def handle_event("remove_column", %{"column_id" => id, "scope" => scope_str}, socket)
      when scope_str in ~w(detail_items detail_categories) do
    scope = String.to_existing_atom(scope_str)
    {:noreply, live_update_detail_columns(socket, scope, &Enum.reject(&1, fn c -> c == id end))}
  end

  # Per-section reorder events: the SortableGrid payload is only
  # `%{ordered_ids}`, so the section rides in the event name.
  def handle_event("reorder_columns_" <> scope_str, %{"ordered_ids" => ids}, socket)
      when scope_str in ~w(detail_items detail_categories) and is_list(ids) do
    scope = String.to_existing_atom(scope_str)
    {:noreply, live_update_detail_columns(socket, scope, fn _ -> ids end)}
  end

  def handle_event("reset_columns", _p, socket) do
    socket =
      Enum.reduce(detail_column_scopes(socket.assigns), socket, fn scope, acc ->
        live_update_detail_columns(acc, scope, fn _ -> TableConfig.default_columns(scope) end)
      end)

    {:noreply, socket}
  end

  # A header click; like the categories' below, a push naming Manual order
  # is ignored — headers never offer it.
  def handle_event("toggle_sort_items", %{"by" => field_str}, socket)
      when field_str in @items_sort_field_strs and field_str != "position" do
    field = String.to_existing_atom(field_str)

    dir =
      if field == socket.assigns.items_sort_by do
        if socket.assigns.items_sort_dir == :asc, do: :desc, else: :asc
      else
        :asc
      end

    {:noreply, socket |> apply_items_sort(field, dir) |> persist_detail_sort(:detail_items)}
  end

  def handle_event("toggle_sort_items", _params, socket), do: {:noreply, socket}

  # A category column header: the same field flips the direction, another
  # field starts ascending. Headers only sort once the list is out of Manual
  # order (`header_sort/2`), so a click never lands here from Manual — and a
  # push naming :position (or anything unknown) is ignored rather than
  # quietly putting the list back into drag mode.
  def handle_event("toggle_sort_categories", %{"by" => by}, socket)
      when by in ~w(name items updated) do
    field = String.to_existing_atom(by)

    dir =
      if field == socket.assigns.categories_sort_by and
           socket.assigns.categories_sort_dir == :asc,
         do: :desc,
         else: :asc

    {:noreply, apply_categories_sort(socket, field, dir)}
  end

  def handle_event("toggle_sort_categories", _params, socket), do: {:noreply, socket}

  # Open the strategy-reorder modal. Captures the client-side selection
  # (via the BulkSelectScope hook payload). A 0–1 selection collapses to
  # "reorder all" (stored as `[]`) — a single-row reorder is a no-op.
  # "Reorder all" (page control row, no payload) or "Reorder N selected"
  # (bulk toolbar, uuids in the payload). A 0–1 selection is "all": a
  # one-row reorder is a no-op.
  def handle_event("open_categories_reorder_modal", params, socket) do
    captured =
      case sanitize_uuids(params) do
        list when length(list) < 2 -> []
        list -> list
      end

    {:noreply,
     assign(socket, show_categories_reorder: true, categories_reorder_captured: captured)}
  end

  def handle_event("close_categories_reorder_modal", _params, socket) do
    {:noreply, assign(socket, show_categories_reorder: false, categories_reorder_captured: [])}
  end

  # Strategy reorder for the current level's sibling categories ("Reorder
  # all" next to the category list). `@child_categories` is the full,
  # unpaginated sibling set, so re-indexing it can't collide with unseen
  # rows; `Catalogue.reorder_categories/4` re-asserts siblinghood anyway.
  def handle_event("apply_categories_reorder", %{"strategy" => strategy_str}, socket)
      when is_map_key(@items_reorder_strategy_map, strategy_str) do
    strategy = Map.fetch!(@items_reorder_strategy_map, strategy_str)

    # A captured selection is re-sequenced within the slots those rows
    # already occupy — the same "reorder N selected" meaning the item
    # list has — so unselected siblings keep their places.
    ordered =
      socket.assigns.child_categories
      |> reorder_within_slots(socket.assigns.categories_reorder_captured, strategy)
      |> Enum.map(& &1.uuid)

    parent_uuid =
      case socket.assigns.current_category do
        %Category{uuid: uuid} -> uuid
        _ -> nil
      end

    case Catalogue.reorder_categories(
           socket.assigns.catalogue_uuid,
           parent_uuid,
           ordered,
           actor_opts(socket)
         ) do
      :ok ->
        {:noreply,
         socket
         |> assign(show_categories_reorder: false, categories_reorder_captured: [])
         |> clear_bulk_selection()
         |> put_flash(
           :info,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Categories reordered.")
         )
         |> reset_and_load()}

      {:error, reason} ->
        log_operation_error(socket, "apply_categories_reorder", %{reason: reason})

        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to reorder.")
         )}
    end
  end

  def handle_event("apply_categories_reorder", _params, socket), do: {:noreply, socket}

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
         |> clear_bulk_selection()
         |> reset_and_load()}

      {:error, :duplicate_positions} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(
             PhoenixKitCatalogue.Gettext,
             "Selected items share positions. Apply “Reorder all” first to normalise."
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

  # Client-captured uuids: anything that is not a uuid is dropped here,
  # before it can reach a `Repo.get` and raise a query cast error. Only
  # the canonical form passes — the context's bulk moves refuse an
  # upper-case or raw 16-byte uuid with `:invalid_uuid`.
  defp sanitize_uuids(%{"uuids" => uuids}) when is_list(uuids),
    do: Enum.filter(uuids, &(is_binary(&1) and Ecto.UUID.cast(&1) == {:ok, &1}))

  defp sanitize_uuids(_), do: []

  # Clears the client-side BulkSelectScope selection after a bulk item op.
  defp clear_item_selection(socket), do: clear_bulk_selection(socket)

  # Rows the page acts on by a client-sent uuid must belong to this
  # catalogue; anything else reads as not found.
  defp item_in_catalogue(socket, uuid) do
    catalogue_uuid = socket.assigns.catalogue_uuid

    case Catalogue.get_item(uuid) do
      %{catalogue_uuid: ^catalogue_uuid} = item -> item
      _ -> nil
    end
  end

  defp category_in_catalogue(socket, uuid) do
    catalogue_uuid = socket.assigns.catalogue_uuid

    case Catalogue.get_category(uuid) do
      %Category{catalogue_uuid: ^catalogue_uuid} = category -> category
      _ -> nil
    end
  end

  # What a category's Delete Forever really removes, for its confirmation.
  defp delete_scope("category", socket, uuid) do
    case category_in_catalogue(socket, uuid) do
      %Category{} = category -> Catalogue.permanent_delete_scope(category)
      nil -> nil
    end
  end

  defp delete_scope(_type, _socket, _uuid), do: nil

  # A Delete Forever that found its row restored in the meantime.
  defp not_in_trash(socket) do
    socket
    |> assign(:confirm_delete, nil)
    |> put_flash(:error, Errors.message(:not_in_trash))
    |> reset_and_load()
  end

  # Clears the client-side BulkSelectScope selection, which rows that
  # survive an op (the originals after Duplicate) would otherwise keep.
  # Core's hook has no handler for this push, so the module's own JS
  # answers it by pressing each scope's Clear button. Never clear by
  # changing a scope's id: the remounted hook skips checkboxes the old
  # hook already wired, and LiveView carries the id-keyed table (with
  # those checkboxes) into the new scope, so its toolbar never shows.
  defp clear_bulk_selection(socket) do
    push_event(socket, "bulk_select:clear", %{})
  end

  # Sort change resets the item offset to 0 and reloads page 1 — else
  # infinite-scroll would stitch the new order onto a stale prefix.
  defp apply_items_sort(socket, field, dir) do
    socket
    |> assign(items_sort_by: field, items_sort_dir: dir, items_offset: 0)
    |> reset_and_load()
  end

  # ── Shared (all-user) detail sorts — same mechanism as the catalogues
  # index: the setting is the source of truth, changes broadcast so open
  # sessions follow live, and mount reads it back. ──────────────────

  # Applies a columns transformation to one table's scope and persists
  # it per-user. Removing the last column leaves Name alone — it used to
  # snap back to the defaults, which read as the editor resetting itself.
  defp live_update_detail_columns(socket, scope, fun) do
    ids = TableConfig.validate_columns(scope, fun.(current_scope_columns(socket, scope)))

    user = socket.assigns[:phoenix_kit_current_user]
    cfg = %{ViewConfig.load(user, scope) | columns: ids}

    socket =
      case ViewConfig.save(user, scope, cfg) do
        {:ok, updated_user} -> assign(socket, :phoenix_kit_current_user, updated_user)
        _ -> socket
      end

    assigns_key = if scope == :detail_items, do: :items_columns, else: :categories_columns
    socket = assign(socket, assigns_key, ids)

    # Toggling "attributes" in/out of the Items columns changes which shape
    # `build_attribute_map/3` should be filling — refresh it now rather than
    # waiting for the next scroll/reload to pick it up.
    if scope == :detail_items, do: refresh_attribute_map(socket), else: socket
  end

  defp detail_column_section_title(:detail_categories),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Categories")

  defp detail_column_section_title(:detail_items),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Items")

  # Which tables' column editors the page offers right now — one modal
  # section per visible table.
  defp detail_column_scopes(assigns) do
    cats? = assigns.child_categories != []
    items? = assigns.show_items_section

    Enum.filter([cats? && :detail_categories, items? && :detail_items], & &1)
  end

  # Accepts the socket (event handlers) or the assigns map (templates).
  defp current_scope_columns(%Phoenix.LiveView.Socket{} = socket, scope),
    do: current_scope_columns(socket.assigns, scope)

  defp current_scope_columns(assigns, :detail_items), do: assigns.items_columns
  defp current_scope_columns(assigns, :detail_categories), do: assigns.categories_columns

  defp persist_detail_sort(socket, :detail_items) do
    by = Atom.to_string(socket.assigns.items_sort_by)
    dir = socket.assigns.items_sort_dir
    ViewConfig.save_global_sort(:detail_items, by, dir)
    PubSub.broadcast_view_sort_changed(:detail_items, by, dir)
    socket
  end

  defp persist_detail_sort(socket, :detail_categories) do
    by = Atom.to_string(socket.assigns.categories_sort_by)
    dir = socket.assigns.categories_sort_dir
    ViewConfig.save_global_sort(:detail_categories, by, dir)
    PubSub.broadcast_view_sort_changed(:detail_categories, by, dir)
    socket
  end

  defp apply_global_detail_sorts(socket) do
    {items_by, items_dir} = ViewConfig.load_global_sort(:detail_items)
    {cats_by, cats_dir} = ViewConfig.load_global_sort(:detail_categories)

    assign(socket,
      items_sort_by: detail_items_sort_field(items_by),
      items_sort_dir: items_dir,
      categories_sort_by: detail_categories_sort_field(cats_by),
      categories_sort_dir: cats_dir
    )
  end

  # Stored ids are validated by ViewConfig against TableConfig's
  # sortable columns for the scope, so these total maps only ever see
  # known ids — the fallbacks are for defense, not routing.
  defp detail_items_sort_field(by)
       when by in ~w(position name sku base_price status),
       do: String.to_existing_atom(by)

  defp detail_items_sort_field(_), do: :position

  defp detail_categories_sort_field(by)
       when by in ~w(position name items updated),
       do: String.to_existing_atom(by)

  defp detail_categories_sort_field(_), do: :position

  defp disposition_to_items_opt(:uncategorize, _), do: :uncategorize
  defp disposition_to_items_opt(:cascade, _), do: :cascade
  defp disposition_to_items_opt(:move_to, target) when not is_nil(target), do: {:move_to, target}
  defp disposition_to_items_opt(_, _), do: nil

  defp bulk_subtree_item_count(uuids) do
    Enum.reduce(uuids, 0, fn uuid, acc ->
      acc + Catalogue.active_item_count_in_subtree(uuid)
    end)
  end

  defp muted_actor_opts(socket), do: Keyword.put(actor_opts(socket), :broadcast, false)

  # Bulk category ops take the page's catalogue as a scope: a uuid from
  # another catalogue in a client-captured selection is refused per entry.
  defp scoped_actor_opts(socket),
    do: Keyword.put(actor_opts(socket), :catalogue_uuid, socket.assigns.catalogue_uuid)

  defp scoped_muted_actor_opts(socket),
    do: Keyword.put(muted_actor_opts(socket), :catalogue_uuid, socket.assigns.catalogue_uuid)

  defp broadcast_item_batch(socket),
    do: PubSub.broadcast(:item, nil, socket.assigns.catalogue_uuid)

  # Bulk item ops read the client-captured uuids, and push
  # `bulk_select:clear` afterwards so a stale checkmark can't persist on a
  # row that survived the op.
  # The context's batch `:item` event is muted here and re-emitted by
  # `broadcast_item_batch/1` AFTER the bulk-change message, so another
  # open detail page receives the flash instruction before the reload
  # trigger (mailbox order) and can hold the reload until the flash has
  # played. The catalogues index only listens to the `:item` event.
  defp do_bulk_trash_items(socket, uuids) do
    {count, _} = Catalogue.bulk_trash_items(uuids, scoped_muted_actor_opts(socket))
    PubSub.broadcast_bulk_change(socket.assigns.catalogue_uuid, :trashed, uuids)
    broadcast_item_batch(socket)

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
    {count, _} =
      Catalogue.bulk_permanently_delete_items(
        uuids,
        Keyword.put(scoped_muted_actor_opts(socket), :only_trashed, true)
      )

    PubSub.broadcast_bulk_change(socket.assigns.catalogue_uuid, :permanent_delete, uuids)
    broadcast_item_batch(socket)

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
    {count, _} = Catalogue.bulk_restore_items(uuids, scoped_muted_actor_opts(socket))
    PubSub.broadcast_bulk_change(socket.assigns.catalogue_uuid, :restored, uuids)
    broadcast_item_batch(socket)

    socket
    |> clear_item_selection()
    |> put_flash(
      :info,
      Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restored %{count} items.", count: count)
    )
    |> reset_and_load()
    |> then(&{:noreply, &1})
  end

  defp do_bulk_move_items(socket, uuids, destination) do
    opts =
      muted_actor_opts(socket) |> Keyword.put(:catalogue_uuid, socket.assigns.catalogue_uuid)

    case Catalogue.bulk_move_items(uuids, destination, opts) do
      {:ok, count} ->
        # `:moved` triggers the receiver's full red-fade → refresh →
        # green-fade sequence on every other open tab.
        PubSub.broadcast_bulk_change(socket.assigns.catalogue_uuid, :moved, uuids)
        broadcast_item_batch(socket)

        # Pages open on the destination catalogue gained the items.
        other = get_in(socket.assigns, [:bulk_move_modal, :target_catalogue_uuid])

        if other && other != socket.assigns.catalogue_uuid,
          do: PubSub.broadcast(:item, nil, other)

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
        log_operation_error(socket, "bulk_move_items", %{reason: :category_not_found})

        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Target category not found.")
         )}

      {:error, reason} when reason in [:catalogue_not_found, :kind_mismatch, :catalogue_moved] ->
        log_operation_error(socket, "bulk_move_items", %{reason: reason})
        {:noreply, put_flash(socket, :error, Errors.message(reason))}

      {:error, scope_err} when scope_err in [:wrong_catalogue_scope, :missing_catalogue_scope] ->
        log_operation_error(socket, "bulk_move_items", %{reason: scope_err})

        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(
             PhoenixKitCatalogue.Gettext,
             "Some selected items are no longer in this catalogue. Reload the page and try again."
           )
         )}

      {:error, reason} ->
        log_operation_error(socket, "bulk_move_items", %{reason: reason})
        {:noreply, put_flash(socket, :error, Errors.message(reason))}
    end
  end

  # The target must be one the picker offered: a forged uuid from inside
  # the selection would be a cycle, from elsewhere a scope leak.
  defp confirm_bulk_move_categories_under(socket, uuids, catalogue_uuid, target, targets) do
    if picker_has_target?(targets, target),
      do: do_bulk_move_categories(socket, uuids, catalogue_uuid, target),
      else: {:noreply, socket}
  end

  # Catalogues a move may land in: every live one of this catalogue's
  # kind (items and categories never cross kinds), this one first.
  defp move_catalogue_choices(socket) do
    current = socket.assigns.catalogue_uuid

    [kind: socket.assigns.catalogue.kind]
    |> Catalogue.list_catalogues()
    |> Catalogue.localize(loc(socket))
    |> Enum.sort_by(&(&1.uuid != current))
  end

  defp offered_catalogue?(catalogues, uuid),
    do: Enum.any?(catalogues, &(&1.uuid == uuid))

  defp item_move_targets(socket, catalogue_uuid) do
    catalogue_uuid
    |> Catalogue.list_category_tree(mode: :active)
    |> localize_targets(loc(socket))
  end

  # In this catalogue a selected category cannot go under its own
  # subtree; in another catalogue every live category can take them.
  defp category_targets_in(socket, uuids, catalogue_uuid) do
    if catalogue_uuid == socket.assigns.catalogue_uuid,
      do: localize_targets(category_move_targets(uuids, catalogue_uuid), loc(socket)),
      else: item_move_targets(socket, catalogue_uuid)
  end

  # The three modal pickers store `{category, depth}` pairs. Empty string
  # (the "-- Select --" option) and a uuid the picker did not offer both
  # become nil, so confirm never acts on a forged target.
  defp accepted_picker_target(targets, uuid) do
    uuid = Values.blank_to_nil(uuid)
    if picker_has_target?(targets, uuid), do: uuid, else: nil
  end

  defp picker_has_target?(targets, uuid) when is_list(targets) and is_binary(uuid) do
    Enum.any?(targets, fn
      {%{uuid: ^uuid}, _depth} -> true
      _ -> false
    end)
  end

  defp picker_has_target?(_, _), do: false

  defp confirm_bulk_trash(socket, %{
         bulk_uuids: uuids,
         disposition: disp,
         target_uuid: target,
         targets: targets
       }) do
    items_opt = disposition_to_items_opt(disp, target)

    if trash_disposition_allowed?(items_opt, targets, target) do
      socket
      |> assign(:trash_modal, nil)
      |> do_bulk_trash_categories_with(uuids, items_opt)
    else
      {:noreply, socket}
    end
  end

  defp trash_disposition_allowed?(nil, _targets, _target), do: false

  defp trash_disposition_allowed?({:move_to, _}, targets, target),
    do: picker_has_target?(targets, target)

  defp trash_disposition_allowed?(_items_opt, _targets, _target), do: true

  defp confirm_trash_move_to(socket, category, target, targets) do
    if picker_has_target?(targets, target) do
      socket
      |> assign(:trash_modal, nil)
      |> do_trash_category(category, items: {:move_to, target})
    else
      {:noreply, socket}
    end
  end

  # The category picker the three modals share (trash → move items to…,
  # move items, move categories). A form around the select is what makes
  # `phx-change` reach the server (LiveView refuses bare inputs).
  attr(:event, :string, required: true)

  attr(:id, :string,
    default: nil,
    doc: "form id — changes with the listed catalogue so the select re-renders fresh"
  )

  attr(:targets, :list, required: true, doc: "`{category, depth}` pairs")
  attr(:target_uuid, :string, default: nil)
  attr(:disabled, :boolean, default: false)
  attr(:class, :string, default: "")

  defp move_target_picker(assigns) do
    ~H"""
    <form id={@id || "move-target-#{@event}"} phx-change={@event}>
      <select
        name="category_uuid"
        disabled={@disabled}
        class={["select select-sm w-full", @class]}
      >
        <option value="">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "— Select category —")}</option>
        <%= for {cat, depth} <- @targets do %>
          <option value={cat.uuid} selected={@target_uuid == cat.uuid}>
            {String.duplicate("— ", depth)}{cat.name}
          </option>
        <% end %>
      </select>
    </form>
    """
  end

  # The destination catalogue for the bulk move modals. Hidden when this
  # catalogue is the only one a move could reach.
  attr(:event, :string, required: true)
  attr(:catalogues, :list, required: true)
  attr(:current_uuid, :string, required: true)
  attr(:selected_uuid, :string, required: true)

  defp move_catalogue_picker(assigns) do
    ~H"""
    <form
      :if={length(@catalogues) > 1}
      id={"move-catalogue-#{@event}"}
      phx-change={@event}
      class="mt-4"
    >
      <label class="text-xs font-medium text-base-content/70" for={"move-catalogue-#{@event}-select"}>
        {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue")}
      </label>
      <select
        id={"move-catalogue-#{@event}-select"}
        name="catalogue_uuid"
        class="select select-sm w-full mt-1"
      >
        <option :for={cat <- @catalogues} value={cat.uuid} selected={cat.uuid == @selected_uuid}>
          {if cat.uuid == @current_uuid,
            do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "%{name} (this catalogue)", name: cat.name),
            else: cat.name}
        </option>
      </select>
    </form>
    """
  end

  defp open_bulk_duplicate_modal(socket, _kind, []), do: socket

  defp open_bulk_duplicate_modal(socket, kind, uuids) do
    assign(socket, :bulk_duplicate_modal, %{kind: kind, count: length(uuids), uuids: uuids})
  end

  defp do_bulk_duplicate_items(socket, uuids) do
    {:ok, %{created: created, errors: errors}} =
      Catalogue.bulk_duplicate_items(
        uuids,
        Keyword.put(muted_actor_opts(socket), :catalogue_uuid, socket.assigns.catalogue_uuid)
      )

    if created > 0, do: broadcast_item_batch(socket)

    socket
    |> assign(:bulk_duplicate_modal, nil)
    |> clear_item_selection()
    |> flash_bulk_result(
      created,
      Gettext.gettext(PhoenixKitCatalogue.Gettext, "Duplicated %{count} items.", count: created),
      errors,
      "bulk_duplicate_items",
      Gettext.gettext(
        PhoenixKitCatalogue.Gettext,
        "%{count} items could not be duplicated.",
        count: length(errors)
      )
    )
    |> reset_and_load()
    |> then(&{:noreply, &1})
  end

  defp do_bulk_duplicate_categories(socket, uuids) do
    {:ok, %{created: created, errors: errors}} =
      Catalogue.bulk_duplicate_categories(uuids, scoped_actor_opts(socket))

    socket
    |> assign(:bulk_duplicate_modal, nil)
    |> assign(:selected_categories, MapSet.new())
    |> clear_bulk_selection()
    |> flash_bulk_result(
      created,
      Gettext.gettext(
        PhoenixKitCatalogue.Gettext,
        "Duplicated %{count} categories.",
        count: created
      ),
      errors,
      "bulk_duplicate_categories",
      Gettext.gettext(
        PhoenixKitCatalogue.Gettext,
        "%{count} categories could not be duplicated.",
        count: length(errors)
      )
    )
    |> reset_and_load()
    |> then(&{:noreply, &1})
  end

  # Bulk ops report both halves: a success flash when anything happened
  # and an error flash (plus an operation log) for the entries refused.
  defp flash_bulk_result(socket, done, ok_msg, errors, op, err_msg) do
    socket
    |> then(&if(done > 0, do: put_flash(&1, :info, ok_msg), else: &1))
    |> then(fn socket ->
      if errors == [] do
        socket
      else
        log_operation_error(socket, op, %{reason: :partial_failure, errors: errors})
        put_flash(socket, :error, err_msg)
      end
    end)
  end

  # Same-catalogue active categories that every selected category may go
  # under: the intersection of each one's own target list (which excludes
  # its subtree). Unknown uuids — and uuids from another catalogue, which
  # a forged event could carry — contribute nothing and drop out.
  defp category_move_targets(uuids, catalogue_uuid) do
    uuids
    |> Enum.map(&Catalogue.get_category/1)
    |> Enum.reject(&(is_nil(&1) or &1.catalogue_uuid != catalogue_uuid))
    |> Enum.map(&Catalogue.list_move_target_categories/1)
    |> case do
      [] ->
        []

      [first | rest] ->
        allowed =
          Enum.reduce(rest, MapSet.new(first, fn {c, _} -> c.uuid end), fn list, acc ->
            MapSet.intersection(acc, MapSet.new(list, fn {c, _} -> c.uuid end))
          end)

        Enum.filter(first, fn {c, _} -> MapSet.member?(allowed, c.uuid) end)
    end
  end

  defp do_bulk_move_categories(socket, uuids, catalogue_uuid, target_uuid) do
    {:ok, %{moved: moved, errors: errors}} =
      Catalogue.bulk_move_categories_to_catalogue(
        uuids,
        catalogue_uuid,
        target_uuid,
        scoped_actor_opts(socket)
      )

    socket
    |> assign(:bulk_move_categories_modal, nil)
    |> assign(:selected_categories, MapSet.new())
    |> clear_bulk_selection()
    |> flash_bulk_result(
      moved,
      Gettext.gettext(PhoenixKitCatalogue.Gettext, "Moved %{count} categories.", count: moved),
      errors,
      "bulk_move_categories_to_catalogue",
      Gettext.gettext(
        PhoenixKitCatalogue.Gettext,
        "%{count} categories could not be moved.",
        count: length(errors)
      )
    )
    |> reset_and_load()
    |> then(&{:noreply, &1})
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
    case Catalogue.bulk_trash_categories(uuids, items_opt, scoped_actor_opts(socket)) do
      {:ok, %{categories: count}} ->
        socket
        |> assign(:bulk_confirm, nil)
        |> assign(:selected_categories, MapSet.new())
        |> clear_bulk_selection()
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
    catalogue_uuid = socket.assigns.catalogue_uuid

    {ok, errors} =
      Enum.reduce(uuids, {0, []}, fn uuid, {ok, errs} ->
        # Only a category of THIS catalogue that is in the trash counts as
        # restored (the uuids are client-captured).
        with %{status: "deleted", catalogue_uuid: ^catalogue_uuid} = category <-
               Catalogue.get_category(uuid),
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
      |> clear_bulk_selection()
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

  defp do_bulk_permanent_delete_categories(socket, uuids) do
    catalogue_uuid = socket.assigns.catalogue_uuid
    count = Enum.count(uuids, &permanently_delete_trashed_category(&1, catalogue_uuid, socket))

    socket
    |> assign(:bulk_confirm, nil)
    |> assign(:selected_categories, MapSet.new())
    |> clear_bulk_selection()
    |> put_flash(
      :info,
      Gettext.gettext(PhoenixKitCatalogue.Gettext, "Permanently deleted %{count} categories.",
        count: count
      )
    )
    |> reset_and_load()
    |> then(&{:noreply, &1})
  end

  # Only a trashed category of THIS catalogue (the uuids are client-captured).
  # One whose ancestor went earlier in the same batch is already gone.
  defp permanently_delete_trashed_category(uuid, catalogue_uuid, socket) do
    case Catalogue.get_category(uuid) do
      %Category{status: "deleted", catalogue_uuid: ^catalogue_uuid} = category ->
        match?(
          {:ok, _},
          Catalogue.permanently_delete_category(
            category,
            [only_trashed: true] ++ actor_opts(socket)
          )
        )

      _ ->
        false
    end
  end

  defp build_trash_modal_state(%Category{} = category, item_count, locale) do
    %{
      category: category,
      item_count: item_count,
      targets: localize_targets(Catalogue.list_move_target_categories(category), locale),
      # Trash the items with the category: the one choice a restore undoes.
      disposition: :cascade,
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
    # Dropped back in the same place — the order is unchanged, so skip the
    # DB write, PubSub broadcast, and flash entirely.
    if ordered_ids == Enum.map(socket.assigns.items, & &1.uuid) do
      {:noreply, socket}
    else
      do_in_scope_item_reorder(socket, catalogue_uuid, category_uuid, ordered_ids, moved_id)
    end
  end

  defp do_in_scope_item_reorder(socket, catalogue_uuid, category_uuid, ordered_ids, moved_id) do
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

    # Only the sets this catalogue actually uses; the counts stay
    # catalogue-scoped, so unused values sit greyed out rather than
    # vanishing the button.
    socket =
      assign(
        socket,
        :attribute_filter_options,
        Catalogue.attribute_filter_options(uuid, lang: loc(socket))
      )

    # Per-status item counts for the current node — drive the tab labels
    # and the default-tab pick below.
    status_counts = node_status_counts(current, uuid)

    # `status` is the exact item status shown. The root is a pure navigation
    # step (always Active, no tabs). ENTERING a node auto-selects a populated
    # tab — a category with only deleted items opens straight on Deleted
    # instead of an empty Active. A reload of the SAME node keeps the tab the
    # user is on: deleting the last active item must not dump the admin into
    # the Deleted view (and, because the auto-pick used to run on every
    # reload, clicking back to Active while it was empty flipped straight
    # back — the user was stuck in the trash). `cat_mode` is the
    # active/deleted bucket for the (status-less) subcategory cards.
    node_key = level_node_key(current)

    # The tabs count what each tab LISTS: the node's own items plus its
    # categories — live ones on Active, trashed ones on Deleted. Counting
    # items alone opened a catalogue whose categories were all empty, with
    # one trashed item, on Deleted with the Active tab dropped: the live
    # categories were unreachable, and a refresh picked the same.
    # The root reads its category tree (every status) once: the tab counts,
    # the trash's category cards and their totals all come from it.
    root_tree = root_category_rows(uuid, current)
    children_counts = level_children_counts(uuid, current)

    tab_status_counts =
      level_tab_counts(status_counts, uuid, current, root_tree, children_counts)

    status =
      pick_view_mode(socket, current, node_key, pick_counts(status_counts, tab_status_counts))

    # Counts AFTER the status is settled, not before: entering a category
    # with nothing active auto-flips the tab, and counts taken first
    # answered for the tab the user just left — values greyed out that the
    # list then showed, or the filter vanishing on a level that has one.
    socket =
      socket
      |> assign(view_mode: status, view_mode_node: node_key)
      |> assign_attribute_counts(uuid)

    cat_mode = view_mode_to_atom(status)

    # Every tab shows the node's categories (the tabs slice ITEM status;
    # a drilled page always shows its sections — panel finding: a
    # category auto-landing on Inactive hid its subcategories and the
    # subtree toggle entirely).
    {child_categories, children_with_subs} = load_level_children(uuid, current, cat_mode)

    child_categories = root_trash_categories(root_tree, current, cat_mode, child_categories)

    {counts_map, subcat_counts} =
      uuid
      |> level_count_maps(current, cat_mode, children_counts)
      |> trash_unit_counts(uuid, root_tree, cat_mode, child_categories)

    uncat_active = Catalogue.uncategorized_count_for_catalogue(uuid, mode: :active)

    node_total = node_total(socket, status_counts, status, current, uuid)

    # The Active tab's root is a pure CATEGORY BROWSER since 2026-08-29
    # (Max: "we just won't show the items in the categories") — items
    # live one drill down or behind search. The flat Items page mode
    # that used to list them at the root retired 2026-08-31 with its
    # switcher; a CATEGORY-LESS root simply lists the items instead
    # (the popup's rule). The uncategorized bucket and the non-active
    # status tabs (the trash must show trashed items) keep their lists
    # regardless.
    show_items_section =
      status != "active" or current == :uncategorized or
        match?(%Category{}, current) or child_categories == []

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
          )
          |> Catalogue.localize(loc(socket)),
        else: []

    catalogue = Catalogue.localize_one(catalogue, loc(socket))
    child_categories = Catalogue.localize(child_categories, loc(socket))

    category_tree_children = load_category_tree_children(uuid, status, loc(socket))

    socket
    |> assign(:category_tree_children, category_tree_children)
    |> assign_level_switchers(uuid, current, status, category_tree_children)
    |> assign(
      page_title: if(current, do: current_node_label(current), else: catalogue.name),
      catalogue: catalogue,
      breadcrumb: build_breadcrumb(current, cat_mode) |> Catalogue.localize(loc(socket)),
      child_categories:
        sort_categories(
          child_categories,
          counts_map,
          socket.assigns.categories_sort_by,
          socket.assigns.categories_sort_dir
        ),
      child_counts: counts_map,
      children_with_subs: children_with_subs,
      child_subcat_counts: subcat_counts,
      uncategorized_active_count: uncat_active,
      items: items,
      edit_path_fn:
        item_edit_with_return(%{current_category: current, catalogue_uuid: catalogue.uuid}),
      items_total: node_total,
      items_offset: length(items),
      items_has_more: length(items) < node_total,
      show_items_section: show_items_section,
      level_status_counts: status_counts,
      status_tabs: visible_status_tabs(status, tab_status_counts)
    )
    |> merge_row_indicators(
      items,
      child_categories ++ List.flatten(Map.values(category_tree_children))
    )
  end

  # What the header's level switchers list. The siblings are the live
  # categories whatever tab is showing — the tree already loaded them on
  # Active; the other tabs load them only when a trail needs them.
  defp assign_level_switchers(socket, uuid, current, status, tree_children) do
    siblings =
      cond do
        is_nil(current) -> %{}
        status == "active" -> tree_children
        true -> load_category_tree_children(uuid, "active", loc(socket))
      end

    assign(socket,
      switch_catalogues: Catalogue.list_catalogues() |> Catalogue.localize(loc(socket)),
      switch_siblings: siblings
    )
  end

  defp switcher_context(assigns) do
    %{
      catalogues: assigns.switch_catalogues,
      siblings: assigns.switch_siblings,
      uncategorized?: assigns.uncategorized_active_count > 0
    }
  end

  # Spread into the layout rather than written as an attribute: a core
  # without the switcher does not declare `page_title_switcher`, and a
  # spread map is not checked at compile time, so the page still compiles
  # there and the header simply has no ▾.
  defp title_switcher_attr(assigns) do
    %{
      page_title_switcher:
        LevelSwitchers.title(
          assigns.catalogue,
          assigns.current_category,
          switcher_context(assigns)
        )
    }
  end

  # The trash is catalogue-wide at root (there is no drilling to reach a
  # deleted SUBcategory): it lists each top-level trashed category — one
  # whose parent is not trashed — as a closed unit, the way the catalogue
  # list shows a trashed catalogue. Its trashed subcategories and items stay
  # inside it and are not listed on their own (Max, 2026-09-15).
  defp root_trash_categories(root_tree, nil, :deleted, _level_categories),
    do: top_level_trashed(root_tree)

  defp root_trash_categories(_root_tree, _current, _cat_mode, level_categories),
    do: level_categories

  defp root_category_rows(uuid, nil), do: all_category_rows(uuid)

  defp root_category_rows(_uuid, _current), do: nil

  defp top_level_trashed(categories), do: top_level(categories, :trashed)

  # The categories a root tab lists: a top-level trashed category has no
  # trashed parent; a top-level live one has no live parent (a live child of
  # a trashed parent is promoted to the root).
  defp top_level(categories, group) do
    in_group? = fn status -> status == "deleted" == (group == :trashed) end
    statuses = Map.new(categories, &{&1.uuid, &1.status})

    Enum.filter(categories, fn category ->
      in_group?.(category.status) and
        case Map.fetch(statuses, category.parent_uuid) do
          {:ok, parent_status} -> not in_group?.(parent_status)
          :error -> true
        end
    end)
  end

  # Every category of the catalogue, in every status.
  defp all_category_rows(uuid) do
    uuid |> Catalogue.list_category_tree(mode: :deleted) |> Enum.map(fn {c, _depth} -> c end)
  end

  # A trashed category card counts what its Restore brings back, at the root
  # and inside a live category alike, mirroring `restore_category/2`: the
  # subcategories anywhere in its subtree stamped with it, and the items
  # stamped with it whose category is live once those come back (a
  # subcategory restored on its own in between does not hide them). Rows
  # trashed on their own before it stay in the trash when it is restored, so
  # they are not counted (Max, 2026-09-15).
  defp trash_unit_counts(counts, uuid, root_tree, :deleted, cards) do
    case Enum.filter(cards, &(&1.status == "deleted")) do
      [] ->
        counts

      trashed_cards ->
        children = Enum.group_by(root_tree || all_category_rows(uuid), & &1.parent_uuid)
        by_root = Catalogue.trashed_item_counts_by_root(uuid)
        Enum.reduce(trashed_cards, counts, &card_restore_counts(&1, &2, children, by_root))
    end
  end

  defp trash_unit_counts(counts, _uuid, _root_tree, _cat_mode, _cards), do: counts

  defp card_restore_counts(category, {items, subs}, children, by_root) do
    root = category.uuid
    below = subtree_below(root, children)
    revived = Enum.filter(below, &(&1.status == "deleted" and trash_root(&1) == root))
    live_after = MapSet.new([root | Enum.map(live_or_revived(below, revived), & &1.uuid)])

    {Map.put(items, root, restorable_items(by_root, root, live_after)),
     Map.put(subs, root, length(revived))}
  end

  defp subtree_below(uuid, children) do
    children
    |> Map.get(uuid, [])
    |> Enum.flat_map(&[&1 | subtree_below(&1.uuid, children)])
  end

  defp live_or_revived(below, revived),
    do: Enum.reject(below, &(&1.status == "deleted")) ++ revived

  defp restorable_items(by_root, root, live_after) do
    for {{category_uuid, ^root}, n} <- by_root,
        MapSet.member?(live_after, category_uuid),
        reduce: 0,
        do: (sum -> sum + n)
  end

  defp trash_root(%{data: %{"_trash" => %{"root" => root}}}), do: root
  defp trash_root(_category), do: nil

  # Categories count into the tabs that list them — tab counts and the
  # opening-tab pick only: node_total must keep counting ITEMS, or the item
  # list's has-more math answers for rows that aren't items. Each tab counts
  # what it lists at the level: at the root, Active lists its top-level live
  # categories plus the items with no category (an item inside a category is
  # counted through that category, not again on its own), and Deleted its
  # top-level trashed categories plus the loose trashed items; a drilled
  # category lists its own direct children and direct items on each.
  defp level_tab_counts(status_counts, uuid, nil, root_tree, _children_counts) do
    listed_active =
      Catalogue.uncategorized_count_for_catalogue(uuid, status: "active") +
        length(top_level(root_tree, :live))

    status_counts
    |> Map.put("active", listed_active)
    |> add_tab_count("deleted", length(top_level_trashed(root_tree)))
  end

  defp level_tab_counts(status_counts, _uuid, %Category{uuid: parent_uuid}, _root_tree, counts) do
    live = Map.get(counts.active, parent_uuid, 0)
    trashed = Map.get(counts.deleted, parent_uuid, 0)
    add_category_counts(status_counts, live, trashed)
  end

  defp level_tab_counts(status_counts, _uuid, _current, _root_tree, _counts), do: status_counts

  # A drilled level's child-category counts in both modes, read once: the tab
  # counts need both, and the listing reuses the one for its tab.
  defp level_children_counts(uuid, %Category{}) do
    %{
      active: Catalogue.category_children_counts(uuid, mode: :active),
      deleted: Catalogue.category_children_counts(uuid, mode: :deleted)
    }
  end

  defp level_children_counts(_uuid, _current), do: nil

  # What the opening-tab pick weighs: the node's item counts, except that
  # with no live item at all the tab counts decide — live categories make
  # Active the tab to open, and otherwise trashed categories make Deleted
  # populated. Live categories show on Active, Inactive and Discontinued
  # alike, so they never outrank a populated Inactive; only Deleted hides
  # them.
  defp pick_counts(item_counts, tab_counts) do
    if Enum.any?(~w(active inactive discontinued), &(Map.get(item_counts, &1, 0) > 0)),
      do: item_counts,
      else: Map.merge(item_counts, Map.take(tab_counts, ["active", "deleted"]))
  end

  defp add_category_counts(counts, live, trashed) do
    counts
    |> add_tab_count("active", live)
    |> add_tab_count("deleted", trashed)
  end

  defp add_tab_count(counts, _status, 0), do: counts
  defp add_tab_count(counts, status, n), do: Map.update(counts, status, n, &(&1 + n))

  # The whole catalogue's active category tree in ONE query, grouped by
  # parent for the browser's collapsible walk. Orphan rows arrive
  # parent-normalized to nil, so the grouping and the level view agree
  # on what's a root.
  defp load_category_tree_children(uuid, "active", locale) do
    Catalogue.list_category_tree(uuid, mode: :active)
    |> Enum.map(fn {c, _depth} -> c end)
    |> Catalogue.localize(locale)
    |> Enum.group_by(& &1.parent_uuid)
  end

  defp load_category_tree_children(_uuid, _status, _locale), do: %{}

  # Re-derives the paperclip (`file_counts`) and attribute-swatch
  # (`attribute_map`) entries for the rows just loaded. Both maps
  # accumulate across pages — a deep scroll keeps its earlier rows'
  # entries — but the source queries omit zero rows, so a plain merge
  # could never CLEAR an entry: an item whose last document was removed,
  # or whose only attached set was detached, kept its indicator until
  # reload. Dropping the reloaded rows' keys first makes the merge
  # authoritative for exactly those rows and leaves every other page's
  # entries alone.
  defp merge_row_indicators(socket, items, categories \\ []) do
    item_uuids = Enum.map(items, & &1.uuid)
    row_uuids = item_uuids ++ Enum.map(categories, & &1.uuid)

    assign(socket,
      file_counts:
        socket.assigns.file_counts
        |> Map.drop(row_uuids)
        |> Map.merge(Catalogue.attached_file_counts(items))
        |> Map.merge(Catalogue.attached_file_counts(categories)),
      attribute_map:
        socket.assigns.attribute_map
        |> Map.drop(item_uuids)
        |> Map.merge(build_attribute_map(item_uuids, loc(socket), socket.assigns.items_columns)),
      supplier_costs:
        socket.assigns.supplier_costs
        |> Map.drop(item_uuids)
        |> Map.merge(Catalogue.supplier_cost_ranges(item_uuids))
    )
  end

  # `attribute_map` primarily comes from the entities-backed attribute
  # SETS. The "Attributes" list column needs each attached set's display
  # name plus its currently SELECTED values' labels (empty selection =
  # "whole set applies", the label list is left empty and
  # `Components.attribute_cell_text/1` falls back to the set's name) —
  # that costs a `resolve_attribute_sets/2` read per distinct set, so it
  # only runs when the column is actually configured to show. Otherwise
  # the swatch indicator beside the name only needs presence, which
  # `Catalogue.attribute_set_presence/1` answers with one query and no
  # resolve; those entries carry `true` rather than a label list, and the
  # "attributes" column render branch never runs for them so
  # `attribute_cell_text/1` is never called on the marker.
  #
  # The legacy `item_attribute_group_map/1` (`phoenix_kit_cat_item_
  # attribute_groups`) is NOT entities-gated — `attribute_group_form_live`
  # still lets a deployment with entities off attach a group via
  # `set_item_attribute_group/2` — so it's folded in too, for every item
  # that has no resolved/present set. One batched query per branch, no
  # per-row lookups; an entities set wins over a legacy group when an
  # item somehow carries both.
  defp build_attribute_map(item_uuids, locale, columns) do
    if "attributes" in columns do
      from_sets =
        item_uuids
        |> Catalogue.resolve_attribute_sets(lang: locale)
        |> Map.new(fn {item_uuid, %{sets: sets}} -> {item_uuid, attribute_map_sets(sets)} end)
        |> Map.reject(fn {_item_uuid, sets} -> sets == [] end)

      (item_uuids -- Map.keys(from_sets))
      |> legacy_attribute_map_labels()
      |> Map.merge(from_sets)
    else
      from_sets =
        item_uuids
        |> Catalogue.attribute_set_presence()
        |> Map.new(&{&1, true})

      legacy =
        (item_uuids -- Map.keys(from_sets))
        |> Catalogue.item_attribute_group_map()
        |> Map.new(fn {item_uuid, _group_uuid} -> {item_uuid, true} end)

      Map.merge(legacy, from_sets)
    end
  end

  defp legacy_attribute_map_labels([]), do: %{}

  defp legacy_attribute_map_labels(item_uuids) do
    item_group_uuids = Catalogue.item_attribute_group_map(item_uuids)
    group_names = Catalogue.attribute_group_names(Map.values(item_group_uuids) |> Enum.uniq())

    item_group_uuids
    |> Map.new(fn {item_uuid, group_uuid} ->
      {item_uuid, [%{name: Map.get(group_names, group_uuid), labels: []}]}
    end)
    |> Map.reject(fn {_item_uuid, [%{name: name}]} -> is_nil(name) end)
  end

  # Rebuilds JUST the attribute-swatch/-column map for the rows currently on
  # screen (level items and any active search results) after the "attributes"
  # column is toggled — `live_update_detail_columns/3` changes
  # `items_columns` but doesn't reload rows, so without this the map would
  # keep whichever shape (`true` or a full label list) it had before the
  # toggle until the next scroll/reload.
  defp refresh_attribute_map(socket) do
    item_uuids =
      Enum.map(socket.assigns.items, & &1.uuid) ++
        Enum.map(socket.assigns[:search_results] || [], & &1.uuid)

    assign(
      socket,
      :attribute_map,
      socket.assigns.attribute_map
      |> Map.drop(item_uuids)
      |> Map.merge(build_attribute_map(item_uuids, loc(socket), socket.assigns.items_columns))
    )
  end

  # Labels come from `values ++ hidden_values`: `:selected` keeps a value
  # archived/trashed after it was picked (§3c), and an active-only lookup
  # would drop its label — a fully hidden selection would then render the
  # set's name, reading as "whole set applies", a mode flip the resolve
  # itself refuses. Only a value deleted for good ghosts out of `:selected`.
  defp attribute_map_sets(sets) do
    Enum.map(sets, fn set ->
      labels_by_key =
        Map.new(set.values ++ Map.get(set, :hidden_values, []), &{&1.key, &1.label})

      labels =
        set.selected
        |> Enum.map(&Map.get(labels_by_key, &1))
        |> Enum.reject(&is_nil/1)

      %{name: set.name, labels: labels}
    end)
  end

  # A supplier row changed somewhere (the item form's Suppliers tab, an
  # import): re-derive just the "Supplier price" entries for the rows on
  # this page instead of reloading the level.
  defp refresh_supplier_costs(socket) do
    item_uuids = Enum.map(socket.assigns.items, & &1.uuid)

    assign(
      socket,
      :supplier_costs,
      socket.assigns.supplier_costs
      |> Map.drop(item_uuids)
      |> Map.merge(Catalogue.supplier_cost_ranges(item_uuids))
    )
  end

  # The child categories shown at this level (in the current `mode` only)
  # plus the set of those with their own sub-children. The uncategorized
  # bucket has none. `mode` is always `:active`/`:deleted` here (the caller
  # only loads children on those tabs). Active mode reuses orphan
  # promotion; deleted mode is strict (see `list_child_categories/3`).
  # `@child_counts` / `@child_subcat_counts` are read only inside the
  # category rows, which are empty unless categories show — skip both
  # whole-catalogue GROUP BYs on the inactive/discontinued tabs.
  # At the root's Deleted tab every listed category is a trashed card whose
  # counts `trash_unit_counts/5` fills in, so the per-category maps go unread.
  defp level_count_maps(_uuid, nil, :deleted, _children_counts), do: {%{}, %{}}

  defp level_count_maps(uuid, _current, cat_mode, children_counts) do
    subcat_counts =
      case children_counts do
        %{^cat_mode => counts} -> counts
        _ -> Catalogue.category_children_counts(uuid, mode: cat_mode)
      end

    {Catalogue.item_counts_by_category_for_catalogue(uuid, mode: cat_mode), subcat_counts}
  end

  defp load_level_children(_uuid, :uncategorized, _mode), do: {[], MapSet.new()}

  # The root's Deleted tab lists its trashed cards from the category tree
  # (`root_trash_categories/4`), so the level listing itself is not read.
  defp load_level_children(uuid, nil, :deleted),
    do: {[], Catalogue.category_uuids_with_children(uuid, mode: :deleted)}

  defp load_level_children(uuid, current, mode) do
    parent_uuid = node_parent_uuid(current)
    shown = Catalogue.list_child_categories(uuid, parent_uuid, mode: mode)
    subs = Catalogue.category_uuids_with_children(uuid, mode: mode)
    {shown, subs}
  end

  # The current node's own direct-item counts in both modes. Root and the
  # uncategorized bucket count the uncategorized items; a category counts
  # its own direct items.
  # `%{status => count}` for the current node's own direct items — drives
  # the four per-status tabs. Root and the Uncategorized bucket both count
  # the catalogue's uncategorized items.
  defp node_status_counts(%Category{uuid: u}, _catalogue_uuid),
    do: Catalogue.item_status_counts_for_category(u)

  defp node_status_counts(:uncategorized, catalogue_uuid),
    do: Catalogue.item_status_counts_for_uncategorized(catalogue_uuid)

  # The root's Deleted count is the items its trash lists on their own: an
  # item inside a trashed category is counted on that category's card.
  defp node_status_counts(nil, catalogue_uuid) do
    counts = Catalogue.item_status_counts_for_catalogue(catalogue_uuid)

    if Map.get(counts, "deleted", 0) > 0 do
      loose =
        Catalogue.count_items_for_catalogue(catalogue_uuid,
          status: "deleted",
          outside_trashed_categories: true
        )

      Map.put(counts, "deleted", loose)
    else
      counts
    end
  end

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
    page = Catalogue.localize(page, loc(socket))

    socket
    |> assign(
      items: socket.assigns.items ++ page,
      items_offset: new_offset,
      items_has_more: page != [] and new_offset < socket.assigns.items_total
    )
    |> merge_row_indicators(page)
  end

  # Parent scope of a node for the child-categories query.
  defp node_parent_uuid(nil), do: nil
  defp node_parent_uuid(:uncategorized), do: nil
  defp node_parent_uuid(%Category{uuid: uuid}), do: uuid

  # The item-fetch scope of a node: a category UUID, or `:uncategorized`
  # for the root (whose own items are the uncategorized ones) and the
  # uncategorized bucket.
  # With category drilling removed (Max, 2026-08-29) the root is the
  # only level, so its item scope is the WHOLE catalogue — items mode,
  # the non-active tabs, and the trash all answer for everything.
  defp node_scope(nil), do: :catalogue
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

  # When a mutation (restore / trash / permanent-delete) empties the
  # current non-Active status tab, flip the view back to Active so the
  # user isn't stranded on an empty tab. Runs only after `load_level` has
  # refreshed `items_total` (items of the current status) and
  # `child_categories` (the deleted subcategories shown in the Deleted
  # tab), so a tab that still lists deleted subcategories — even with no
  # items of its own — correctly stays put.
  defp maybe_auto_flip_to_active(%{assigns: %{view_mode: "active"}} = socket), do: socket

  defp maybe_auto_flip_to_active(socket) do
    if socket.assigns.items_total == 0 and socket.assigns.child_categories == [] do
      socket
      |> assign(:view_mode, "active")
      |> load_level(@per_page)
    else
      socket
    end
  end

  # PubSub-driven refresh. Reloads the current level preserving scroll
  # depth so a cross-tab broadcast (another admin, the import wizard)
  # doesn't collapse a deep item scroll. The `Ecto.NoResultsError` rescue
  # in the caller handles the catalogue-was-deleted-elsewhere edge case.
  # With a search active the page renders the results grid instead of
  # the level, so the search is re-run too (async; `handle_async(:search)`
  # swaps the results in and re-derives their indicators).
  defp refresh_in_place(socket) do
    socket |> refresh_counts() |> rerun_active_search()
  end

  defp rerun_active_search(socket) do
    if socket.assigns.search_query != "",
      do: run_search(socket, socket.assigns.search_query),
      else: socket
  end

  # Runs a fresh search query asynchronously. If a prior search is still
  # in flight, `start_async/3` cancels it — so fast typing (type-pause-
  # type-pause) doesn't flash stale intermediate results as each old
  # request lands out of order. The actual assign happens in
  # `handle_async(:search, ...)`, guarded by a query equality check.
  defp run_search(socket, query) do
    uuid = socket.assigns.catalogue_uuid
    current = socket.assigns.current_category
    slugs = active_attribute_slugs(socket)
    type = effective_search_type(socket.assigns)
    subtree? = subtree_items?(socket.assigns)
    # The Deleted tab searches the trash (trashed items of this catalogue).
    trashed? = socket.assigns.view_mode == "deleted"
    mode_opts = [trashed: trashed?]

    socket = assign(socket, search_query: query, search_loading: true)
    stamp = search_stamp(socket, 0)

    socket
    # The facets answer for the list as it will be, search included —
    # a value still offered as live while the search has narrowed it
    # away is the empty list this filter exists to prevent. In a
    # categories-type search the item side is neither queried nor shown
    # and the filter control is hidden, so the count query is skipped
    # with it (panel finding, 2026-08-29); the next type flip re-runs
    # this whole function and refreshes them.
    |> then(fn s ->
      if type == "categories", do: s, else: assign_attribute_counts(s, uuid)
    end)
    |> start_async(:search, fn ->
      # The type chips narrow what is ASKED, not just what is shown —
      # a Categories search skips the item listing and count queries.
      {results, total} =
        if type == "categories",
          do: {[], 0},
          else:
            {search_in_scope(uuid, current, query, @per_page, 0, slugs, subtree?, mode_opts),
             search_count_in_scope(uuid, current, query, slugs, subtree?, mode_opts)}

      categories =
        if type == "items" or trashed?, do: [], else: categories_in_scope(uuid, current, query)

      {stamp, results, total, categories}
    end)
  end

  # Everything a search result depends on, in one comparable value: the
  # query, how far down the list it is, the level, the attribute filter
  # and the result type it ran under. The guards below drop a reply
  # whose stamp no longer matches the socket.
  #
  # Query and offset alone are not enough. Toggle an attribute while page
  # two is in flight and the replacement search resets the offset to the
  # value the old page was fetched at — so the old page passes the guard
  # and its rows, from the previous filter, are appended to the new list.
  defp search_stamp(socket, offset) do
    {socket.assigns.search_query, offset, active_attribute_slugs(socket),
     level_node_key(socket.assigns.current_category), effective_search_type(socket.assigns),
     subtree_items?(socket.assigns)}
  end

  # Search scope follows the drill level: catalogue-wide at root, the
  # drilled category's OWN items — or its whole subtree with "include
  # subcategory items" on (the toggle is a SEARCH refinement only; the
  # browse list always shows direct items) — and uncategorized-only in
  # the uncategorized bucket. Search is Active-mode only (the context
  # search excludes deleted rows), so the input is hidden in Deleted view.
  # Categories always search the drilled node's subtree (that is how a
  # deep subcategory is found by name), the whole catalogue at root, and
  # none in the uncategorized bucket (which holds no categories).
  # "Doors / Fronts" for each hit, so two subcategories with the same
  # name are told apart. One ancestor query per hit — the result set is
  # capped at 25, and only a search runs this.
  defp category_trails(categories, locale) do
    Map.new(categories, fn category ->
      trail =
        category.uuid
        |> Catalogue.list_category_ancestors()
        |> Enum.map_join(" / ", &(Catalogue.localize_one(&1, locale) || &1).name)

      {category.uuid, if(trail == "", do: nil, else: trail)}
    end)
  end

  defp categories_in_scope(uuid, nil, query),
    do: Catalogue.search_categories(uuid, query)

  defp categories_in_scope(_uuid, :uncategorized, _query), do: []

  defp categories_in_scope(uuid, %Category{uuid: cuuid}, query),
    do: Catalogue.search_categories(uuid, query, parent_uuid: cuuid)

  defp search_in_scope(uuid, nil, query, limit, offset, slugs, _subtree?, mode_opts),
    do:
      Catalogue.search_items_in_catalogue(
        uuid,
        query,
        [limit: limit, offset: offset, value_slugs: slugs] ++ mode_opts
      )

  defp search_in_scope(uuid, :uncategorized, query, limit, offset, slugs, _subtree?, mode_opts),
    do:
      Catalogue.search_items(
        query,
        [
          catalogue_uuids: [uuid],
          only: :uncategorized_only,
          limit: limit,
          offset: offset,
          value_slugs: slugs
        ] ++ mode_opts
      )

  defp search_in_scope(
         _uuid,
         %Category{uuid: cuuid},
         query,
         limit,
         offset,
         slugs,
         subtree?,
         mode_opts
       ),
       do:
         Catalogue.search_items_in_category(
           cuuid,
           query,
           [limit: limit, offset: offset, value_slugs: slugs, include_descendants: subtree?] ++
             mode_opts
         )

  defp search_count_in_scope(uuid, nil, query, slugs, _subtree?, mode_opts),
    do:
      Catalogue.count_search_items(
        query,
        [catalogue_uuids: [uuid], value_slugs: slugs] ++ mode_opts
      )

  defp search_count_in_scope(uuid, :uncategorized, query, slugs, _subtree?, mode_opts),
    do:
      Catalogue.count_search_items(
        query,
        [catalogue_uuids: [uuid], only: :uncategorized_only, value_slugs: slugs] ++ mode_opts
      )

  defp search_count_in_scope(_uuid, %Category{uuid: cuuid}, query, slugs, subtree?, mode_opts),
    do:
      Catalogue.count_search_items(
        query,
        [category_uuids: [cuuid], value_slugs: slugs, include_descendants: subtree?] ++ mode_opts
      )

  @impl true
  def handle_async(:search, {:ok, {stamp, results, total, categories}}, socket) do
    # Only apply if the socket is still asking the same question. A late
    # response the user has already superseded gets dropped.
    if search_stamp(socket, 0) == stamp do
      results = Catalogue.localize(results, loc(socket))

      {:noreply,
       socket
       |> assign(
         search_results: results,
         search_categories: Catalogue.localize(categories, loc(socket)),
         category_trails: category_trails(categories, loc(socket)),
         search_offset: length(results),
         search_total: total,
         search_has_more: length(results) < total,
         search_loading: false
       )
       |> merge_row_indicators(results)}
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

  def handle_async(:search_page, {:ok, {stamp, offset, page}}, socket) do
    # Same guard as `:search`, and it has to include the offset the
    # socket is actually expecting — a parallel page (shouldn't happen,
    # `load_more` checks `search_loading`) would otherwise append twice.
    if search_stamp(socket, offset) == stamp and socket.assigns.search_offset == offset do
      new_offset = offset + length(page)
      # `page == []` protects against stale `search_total` (items
      # concurrently deleted) keeping `search_has_more` true forever.
      has_more = page != [] and new_offset < socket.assigns.search_total

      page = Catalogue.localize(page, loc(socket))

      {:noreply,
       socket
       |> assign(
         search_results: (socket.assigns.search_results || []) ++ page,
         search_offset: new_offset,
         search_has_more: has_more,
         search_loading: false
       )
       |> merge_row_indicators(page)}
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

    slugs = active_attribute_slugs(socket)
    subtree? = subtree_items?(socket.assigns)
    stamp = search_stamp(socket, offset)
    # Later pages search the same place as the first (the trash in the
    # Deleted tab).
    mode_opts = [trashed: socket.assigns.view_mode == "deleted"]

    socket
    |> assign(:search_loading, true)
    |> start_async(:search_page, fn ->
      page = search_in_scope(uuid, current, query, @per_page, offset, slugs, subtree?, mode_opts)
      {stamp, offset, page}
    end)
  end

  defp clear_search(socket) do
    assign(socket,
      search_query: "",
      search_results: nil,
      search_categories: [],
      category_trails: %{},
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
    socket
    |> assign(:items, Enum.reject(socket.assigns.items, &(&1.uuid == item_uuid)))
    |> drop_from_search(item_uuid)
  end

  # A row restored or deleted from the search grid leaves it too; the total
  # and the next page's offset shrink with it, so the next page skips nothing.
  defp drop_from_search(%{assigns: %{search_results: [_ | _] = results}} = socket, item_uuid) do
    case Enum.split_with(results, &(&1.uuid == item_uuid)) do
      {[], _kept} ->
        socket

      {_gone, kept} ->
        assign(socket,
          search_results: kept,
          search_total: max(socket.assigns.search_total - 1, 0),
          search_offset: max(socket.assigns.search_offset - 1, 0)
        )
    end
  end

  defp drop_from_search(socket, _item_uuid), do: socket

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

      fresh =
        fetch_card_items(
          scope,
          catalogue_uuid,
          status,
          limit,
          0,
          items_sort_opts(socket)
        )
        |> Catalogue.localize(loc(socket))

      total = card_total(scope, catalogue_uuid, status, active_attribute_slugs(socket))

      socket
      |> assign(
        items: fresh,
        items_total: total,
        items_offset: length(fresh),
        items_has_more: length(fresh) < total
      )
      |> merge_row_indicators(fresh)
    else
      socket
    end
  end

  # What each value would still match HERE: this catalogue, the status
  # tab on screen, and the filters already on. Values that match nothing
  # are then offered disabled rather than as a route to an empty list.
  defp assign_attribute_counts(socket, catalogue_uuid) do
    search = String.trim(socket.assigns[:search_query] || "")

    assign(
      socket,
      :attribute_value_counts,
      Catalogue.attribute_value_match_counts(
        [
          catalogue_uuid: catalogue_uuid,
          statuses: [socket.assigns[:view_mode] || "active"],
          search: search,
          value_slugs: active_attribute_slugs(socket.assigns)
        ] ++
          counts_scope(
            socket.assigns[:current_category],
            search != "" and subtree_items?(socket.assigns)
          )
      )
    )
  end

  # Mirrors the scope the LIST is under. A drilled category shows and
  # searches its OWN items unless a search is running WITH "include
  # subcategory items" on — only then do the facet counts answer for the
  # subtree, or a value living one level down looks dead on a page that
  # would have shown it.
  defp counts_scope(%Category{uuid: uuid}, false = _widen), do: [category_uuids: [uuid]]

  defp counts_scope(%Category{uuid: uuid}, _widen),
    do: [category_uuids: Catalogue.category_subtree_uuids([uuid])]

  defp counts_scope(:uncategorized, _search), do: [only: :uncategorized_only]
  defp counts_scope(_root, _search), do: []

  # The status TABS stay unfiltered — a tab reading 0 because of an
  # attribute filter would look broken — but the item section's own total
  # has to match what the filter actually returns (2026-08-28).
  defp node_total(socket, status_counts, status, current, uuid) do
    case active_attribute_slugs(socket) do
      [] ->
        Map.get(status_counts, status, 0)

      slugs ->
        card_total(node_scope(current), uuid, status, slugs)
    end
  end

  # `status` is the exact item status of the current tab
  # ("active" | "inactive" | "discontinued" | "deleted").
  defp card_total(:catalogue, catalogue_uuid, status, slugs) do
    Catalogue.count_items_for_catalogue(
      catalogue_uuid,
      [status: status, value_slugs: slugs] ++ trash_scope(status)
    )
  end

  defp card_total(:uncategorized, catalogue_uuid, status, slugs) do
    Catalogue.uncategorized_count_for_catalogue(catalogue_uuid,
      status: status,
      value_slugs: slugs
    )
  end

  defp card_total(category_uuid, _catalogue_uuid, status, slugs)
       when is_binary(category_uuid) do
    Catalogue.item_count_for_category(category_uuid, status: status, value_slugs: slugs)
  end

  # The catalogue-wide trash lists only items outside a trashed category.
  defp trash_scope("deleted"), do: [outside_trashed_categories: true]
  defp trash_scope(_status), do: []

  defp fetch_card_items(:catalogue, catalogue_uuid, status, limit, offset, sort_opts) do
    Catalogue.list_catalogue_items_paged(
      catalogue_uuid,
      [status: status, offset: offset, limit: limit] ++ trash_scope(status) ++ sort_opts
    )
  end

  defp fetch_card_items(:uncategorized, catalogue_uuid, status, limit, offset, sort_opts) do
    Catalogue.list_uncategorized_items_paged(
      catalogue_uuid,
      [status: status, offset: offset, limit: limit] ++ sort_opts
    )
  end

  # The level's OWN items. The "include subcategory items" toggle refines
  # the SEARCH only (Max, 2026-08-30) — the browse list underneath always
  # shows the category you are standing in, so there is no subtree
  # variant to pick between here.
  defp fetch_card_items(category_uuid, _catalogue_uuid, status, limit, offset, sort_opts)
       when is_binary(category_uuid) do
    Catalogue.list_items_for_category_paged(
      category_uuid,
      [status: status, offset: offset, limit: limit] ++ sort_opts
    )
  end

  # Sort opts threaded into the paged item fetches. Every tab, the Deleted
  # tab included, renders the core toolkit table with its sort headers.
  defp items_sort_opts(socket) do
    [
      sort_by: socket.assigns.items_sort_by,
      sort_dir: socket.assigns.items_sort_dir,
      value_slugs: active_attribute_slugs(socket)
    ]
  end

  # The attribute filter is a question about live items, and the trash is
  # a different one: the counting queries exclude deleted items, so every
  # value scores 0 there and the control hides itself — leaving a filter
  # that still empties the Deleted tab with nothing on screen to switch
  # off. So it does not apply in the trash, and is not offered there.
  # `?attr=` stays in the URL and comes back with the Active tab.
  defp active_attribute_slugs(%{assigns: assigns}), do: active_attribute_slugs(assigns)
  defp active_attribute_slugs(%{view_mode: "deleted"}), do: []
  defp active_attribute_slugs(assigns), do: attribute_filter_slugs(assigns)

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

  defp status_tab_variant("deleted"), do: :error
  defp status_tab_variant(_), do: :primary

  # The level identity the current view_mode was chosen for. `current` is a
  # %Category{}, the :uncategorized sentinel (the Uncategorized drill), or
  # nil at the root.
  defp level_node_key(nil), do: nil
  defp level_node_key(:uncategorized), do: "uncategorized"
  defp level_node_key(%{uuid: uuid}), do: to_string(uuid)

  # Root always shows Active; RE-loading the node the user is already on
  # keeps their tab (deleting the last active item must not dump them into
  # Deleted — and re-running the auto-pick on every reload made an empty
  # Active unselectable: instant flip back, stuck in the trash); ENTERING
  # a node auto-picks a populated tab (deliberate: an all-deleted category
  # opens on Deleted, not an empty Active).
  defp pick_view_mode(socket, _current, node_key, status_counts) do
    # The root is a node like any other since the tabs went
    # catalogue-wide (2026-08-29, panel finding: they rendered but every
    # click bounced back to Active).
    if socket.assigns.view_mode_node == node_key do
      socket.assigns.view_mode
    else
      effective_view_mode(socket.assigns.view_mode, status_counts)
    end
  end

  # The status to actually show for a node: keep the selected `view_mode` if it
  # is populated (see `pick_counts/2`), otherwise fall to the first populated
  # status (active → inactive →
  # discontinued → deleted), or "active" when the node is empty in every status.
  defp effective_view_mode(view_mode, counts) do
    if Map.get(counts, view_mode, 0) > 0 do
      view_mode
    else
      item_status_tabs()
      |> Enum.map(&elem(&1, 0))
      |> Enum.find(&(Map.get(counts, &1, 0) > 0))
      |> case do
        nil -> "active"
        populated -> populated
      end
    end
  end

  # `[{status, label, count}]` for the tabs to render — populated statuses,
  # the current one (the tab the user is standing on never vanishes from
  # under them), and ALWAYS Active: the Add buttons live there, so a level
  # whose only content is in the trash must still offer the way back (a
  # catalogue holding nothing but a trashed item opened on Deleted with no
  # tabs and no way to add anything). The strip is hidden whenever there's
  # ≤1 tab (see render).
  defp visible_status_tabs(view_mode, counts) do
    item_status_tabs()
    |> Enum.map(fn {status, label} -> {status, label, Map.get(counts, status, 0)} end)
    |> Enum.filter(fn {status, _label, count} -> count > 0 or status in [view_mode, "active"] end)
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

  # The viewer's locale for content localization (nil outside locale
  # routes — then records pass through untouched).
  defp loc(socket), do: socket.assigns[:current_locale]

  # Move-target lists are {category, depth} tuples.
  defp localize_targets(targets, locale) do
    Enum.map(targets, fn {cat, depth} -> {Catalogue.localize_one(cat, locale), depth} end)
  end

  # ── Render ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={@page_title}
      page_section={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogues")}
      page_section_path={Paths.index()}
      page_crumbs={
        LevelSwitchers.crumbs(@catalogue, @current_category, @breadcrumb, switcher_context(assigns))
      }
      {title_switcher_attr(assigns)}
      current_path={assigns[:url_path] || Paths.index()}
      current_locale={assigns[:current_locale]}
    >
      <div class="flex flex-col w-full px-4 py-6 gap-6">
        <%!-- Loading state --%>
        <div :if={is_nil(@catalogue)} class="flex justify-center py-12">
          <span class="loading loading-spinner loading-lg"></span>
        </div>

        <div :if={@catalogue} class="flex flex-col gap-6">
          <%!-- In-body header, one row: the scoped search sits top-left
               (where the old in-page breadcrumb was — the trail now lives
               in the admin header), the level actions right. The search
               input stays up whenever a search is on screen even outside
               Active: `?q=` survives the level load, so a deep link into a
               node whose Active tab is empty lands in the Deleted view
               with results rendered — hiding it would leave no way to
               clear. The level's DESCRIPTION (the catalogue's at root, the
               category's when drilled) is a small muted line at the very
               top, clamped to ONE line so its cost is fixed no matter how
               long the field is — the full text is in the hover tooltip. --%>
          <% level_desc = level_description(@current_category, @catalogue) %>
          <% level_img = level_image(@current_category, @catalogue) %>
          <% show_search_input = @view_mode in ["active", "deleted"] or @search_results != nil or @search_loading %>
          <div :if={show_search_input || level_desc || level_img} class="flex flex-col gap-3 mb-3">
            <%!-- The place's own picture beside its description. Inside a
                 category there was no way to see the image attached to it
                 (boss via Max, 2026-09-21); the catalogue's top level shows
                 the catalogue's the same way. Either opens its View card,
                 which holds every picture it has. --%>
            <div :if={level_img || level_desc} class="flex items-center gap-3 min-w-0">
              <button
                :if={level_img}
                type="button"
                id="level-image"
                phx-click={
                  if match?(%Category{}, level_img),
                    do: "show_category_card",
                    else: "show_catalogue_card"
                }
                phx-value-uuid={level_img.uuid}
                class="shrink-0 cursor-pointer"
                title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "View")}
              >
                <.featured_thumb resource={level_img} class="w-16 h-16" comfy_scale={false} />
              </button>
              <p :if={level_desc} class="text-sm text-base-content/60 truncate" title={level_desc}>
                {level_desc}
              </p>
            </div>
            <%!-- flex-wrap, not flex-col: on narrow screens the search takes
                 the line (grow + wide basis) and the actions wrap under it,
                 still right-aligned via ml-auto — same edge the controls row
                 below aligns to. --%>
            <div class="flex flex-wrap items-center gap-3">
              <.search_input
                :if={show_search_input}
                id="catalogue-level-search"
                class={search_width_class()}
                query={@search_query}
                placeholder={search_placeholder(@current_category)}
              />
              <%!-- A SEARCH refinement only (Max, 2026-08-30: "should
                    only do something when searching") — the browse list
                    always shows the category's own items; the toggle
                    pre-arms the next search. Always offered next to the
                    search box (Max, 2026-08-30: "should alwasy be
                    there"), but no control at all without subcategories
                    (Max, 2026-08-29). --%>
              <label
                :if={
                  show_search_input and match?(%Category{}, @current_category) and
                    @child_categories != []
                }
                class="flex items-center gap-2 text-sm cursor-pointer select-none"
              >
                <input
                  type="checkbox"
                  class="toggle toggle-sm"
                  checked={subtree_items?(assigns)}
                  phx-click="toggle_items_scope"
                />
                {gettext("Include subcategory items")}
              </label>
              <%!-- Attribute filter: "show me the blue doors" (Max,
                    2026-08-28). Only the sets this catalogue actually
                    uses are offered, so it stays empty and out of the way
                    where attributes aren't used at all. Hidden while a
                    categories-type search is showing: the filter is
                    item-level, and an active control whose toggles
                    provably change nothing on screen is a lie (panel
                    finding, 2026-08-29). --%>
              <.attribute_filter
                :if={
                  @attribute_filter_options != [] and
                    not (effective_search_type(assigns) == "categories" and
                           (@search_results != nil or @search_loading))
                }
                options={@attribute_filter_options}
                selected={active_attribute_slugs(assigns)}
                counts={@attribute_value_counts}
                always_visible
              />
              <div :if={@view_mode == "active"} class="ml-auto flex flex-wrap items-center gap-2">
                <%!-- On every level (boss's call, 2026-08-18 — subcategories
                     are a first-class flow): at root it creates a root
                     category, drilled it creates a SUBCATEGORY of the
                     current one — new_category_path pre-seeds parent_uuid
                     from @current_category, so there's no ambiguity. --%>
                <.link navigate={new_category_path(assigns)} class="btn btn-outline btn-sm">
                  <.icon name="hero-folder-plus" class="w-4 h-4" /> {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Add category")}
                </.link>
                <.link navigate={new_item_path(assigns)} class="btn btn-primary btn-sm">
                  <.icon name="hero-plus" class="w-4 h-4" /> {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Add item")}
                </.link>
                <%!-- Edits the place you are standing in: the category when
                     drilled into one, the catalogue otherwise. It always
                     edited the catalogue, which is not what "Edit" on a
                     category's page reads as (boss via Max, 2026-09-21).
                     The label names which, so the two cannot be confused. --%>
                <.link
                  id="level-edit-button"
                  navigate={level_edit_path(assigns)}
                  class="btn btn-ghost btn-sm"
                >
                  {level_edit_label(@current_category)}
                </.link>
              </div>
            </div>
          </div>

        <%!-- Search results (Active mode; unchanged machinery) --%>
        <div :if={@search_results != nil or @search_loading} class="flex flex-col gap-4">
          <div class="flex flex-wrap items-center gap-2">
            <%!-- What the search returns (Max, 2026-08-29). Hidden in the
                  uncategorized bucket, which holds no categories to find,
                  and in items mode, where the page mode already answers
                  the question. Same switcher idiom as the index's. --%>
            <%!-- Root-only: a drilled page's search covers sections and
                  content automatically (Max, 2026-08-29). --%>
            <div
              :if={is_nil(@current_category) and @view_mode != "deleted"}
              class="join"
              role="group"
              aria-label={gettext("Search for")}
            >
              <button
                :for={
                  {value, label} <- [
                    {"", Gettext.gettext(PhoenixKitCatalogue.Gettext, "All")},
                    {"categories", Gettext.gettext(PhoenixKitCatalogue.Gettext, "Categories")},
                    {"items", Gettext.gettext(PhoenixKitCatalogue.Gettext, "Items")}
                  ]
                }
                type="button"
                phx-click="set_search_type"
                phx-value-type={value}
                class={["btn btn-xs join-item", @search_type == value && "btn-active"]}
              >
                {label}
              </button>
            </div>
            <%= if @search_loading and is_nil(@search_results) do %>
              <span class="text-sm text-base-content/60">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Searching for “%{query}”…", query: @search_query)}
              </span>
            <% else %>
              <%!-- The summary counts ITEMS. Suppress it when a search
                    matched only categories — or asked only for them —
                    or the line reads "0 results" directly above the
                    category it just found. --%>
              <.search_results_summary
                :if={
                  @search_results != nil and
                    effective_search_type(assigns) != "categories" and
                    (@search_total > 0 or @search_categories == [])
                }
                count={@search_total}
                query={@search_query}
                loaded={length(@search_results)}
              />
            <% end %>
            <span :if={@search_loading} class="loading loading-spinner loading-xs text-base-content/40"></span>
            <div :if={@search_results not in [nil, []]} class="ml-auto">
              <.view_toggle_instant view={@view_mode_pref} id="detail-view-pref" />
            </div>
          </div>

          <%!-- Matching CATEGORIES, above the items: searching a
                catalogue for a category it contains used to return
                nothing at all (Max, 2026-08-28). Each one navigates
                into that category; the muted trail is its ancestors, so
                two subcategories of the same name stay distinguishable. --%>
          <div :if={@search_categories != []} class="flex flex-col gap-2">
            <h3 class="text-sm font-semibold text-base-content/70">
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Categories")}
              <span class="text-xs font-normal text-base-content/40">
                ({length(@search_categories)})
              </span>
            </h3>
            <div class="flex flex-wrap gap-2">
              <%!-- No drilling any more: a hit clears the search and
                    REVEALS the category — the tree opens down to it. --%>
              <%!-- A hit opens the chapter's content: that category's
                    item list, search cleared. No folder icon —
                    categories are chapters, not folders (Max,
                    2026-08-29). --%>
              <.link
                :for={category <- @search_categories}
                patch={
                  url_state_path(assigns,
                    current_category_uuid: category.uuid,
                    search_query: ""
                  )
                }
                class="btn btn-sm btn-ghost gap-2 justify-start"
              >
                <span class="font-medium">{category.name}</span>
                <span :if={@category_trails[category.uuid]} class="text-xs text-base-content/40">
                  {@category_trails[category.uuid]}
                </span>
              </.link>
            </div>
          </div>

          <.empty_state
            :if={@search_results == [] and @search_categories == [] and not @search_loading}
            variant="card"
            title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Nothing matches your search.")}
          />

          <div :if={@search_results not in [nil, []]} class={["transition-opacity", @search_loading && "opacity-50"]}>
            <.item_table
              context_menu={@row_context_menu}
              photo_click="show_product_card"
              file_counts={@file_counts}
              attribute_map={@attribute_map}
              items={@search_results}
              columns={[:name, :sku, :price, :unit, :status]}
              markup_percentage={@catalogue.markup_percentage}
              edit_path={if @view_mode != "deleted", do: @edit_path_fn}
              preview_event="show_product_card"
              on_restore={if @view_mode == "deleted", do: "restore_item"}
              on_permanent_delete={if @view_mode == "deleted", do: "show_delete_confirm"}
              permanent_delete_type="item"
              cards={true}
              show_toggle={false}
              storage_key={view_storage_key()}
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
          <%!-- One control row: category Reorder-all (manual/drag order is
               the only category order, so the shortcut is always offered
               with >1 sibling) next to the view toggle — not two stacked
               right-aligned rows. --%>
          <%!-- The bulk action bars REPLACE this row rather than stacking
               above the tables: revealing a bar without hiding something
               pushed every row down 52px, and the next click then landed on
               the wrong checkbox (boss via Max, 2026-09-20). Sort, the
               status tabs, columns and the view toggle are all unusable
               while a selection is open anyway. Both scopes below name this
               id, and it stays hidden while either holds a selection. --%>
          <.list_controls_row
            :if={
              @child_categories != [] or length(@status_tabs) > 1 or
                (@show_items_section and
                   (@items != [] or @search_results not in [nil, []]))
            }
            id="detail-level-controls"
          >
            <%!-- One tab per populated status — sharing the row with the
                 sort/columns/view controls (no dedicated tab row). The
                 tabs stay even though the Active tab is now a pure
                 category browser: they are also the way into the
                 inactive/discontinued views and the trash. --%>
            <%!-- A lone tab is not a choice — one populated status means the
                 row carries its controls alone. `:if` on the slot ENTRY
                 drops it from the slot list, so the wrapper div does not
                 render empty either. --%>
            <:tabs :if={length(@status_tabs) > 1}>
              <.status_tab
                :for={{status, label, count} <- @status_tabs}
                label={label}
                count={count}
                active={@view_mode == status}
                variant={status_tab_variant(status)}
                phx-click="switch_view"
                phx-value-mode={status}
              />
            </:tabs>
            <:controls>
            <.sort_selector
              :if={@child_categories != []}
              sort_by={@categories_sort_by}
              sort_dir={@categories_sort_dir}
              options={category_sort_options()}
              manual_field={:position}
              event="sort_categories"
              id="categories-sort-selector"
              label
            />
            <%!-- Item-only levels put the items sort here too — same row,
                 same order as the catalogues index. Mixed levels keep the
                 items controls in their own section to avoid two identical
                 unlabeled sort dropdowns side by side. --%>
            <.sort_selector
              :if={@child_categories == [] and @show_items_section and @items != [] and @view_mode == "active"}
              sort_by={@items_sort_by}
              sort_dir={@items_sort_dir}
              options={item_sort_options()}
              manual_field={:position}
              event="sort_items"
              id="items-header-sort-selector"
              label
            />
            <button
              :if={
                @child_categories == [] and @show_items_section and @items_total > 1 and
                  @items_sort_by == :position and @view_mode == "active"
              }
              type="button"
              phx-click="open_items_reorder_modal"
              class="btn btn-outline btn-sm"
            >
              <.icon name="hero-arrows-up-down" class="w-4 h-4" />
              <span class="hidden sm:inline">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Reorder all")}
              </span>
            </button>
            <button
              :if={
                @view_mode == "active" and length(@child_categories) > 1 and
                  @categories_sort_by == :position
              }
              type="button"
              phx-click="open_categories_reorder_modal"
              class="btn btn-outline btn-sm"
            >
              <.icon name="hero-arrows-up-down" class="w-4 h-4" />
              <span class="hidden sm:inline">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Reorder all")}
              </span>
            </button>
            <button
              :if={detail_column_scopes(assigns) != []}
              type="button"
              phx-click="show_column_modal"
              class="btn btn-outline btn-sm"
            >
              <.icon name="hero-adjustments-horizontal" class="w-4 h-4" />
              <span class="hidden sm:inline">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Columns")}
              </span>
            </button>
              <.view_toggle_instant view={@view_mode_pref} id="detail-view-pref" />
            </:controls>
          </.list_controls_row>

          <.reorder_modal
            id="categories-reorder-modal"
            show={@show_categories_reorder}
            on_close="close_categories_reorder_modal"
            on_apply="apply_categories_reorder"
            selected_count={length(@categories_reorder_captured)}
            total_count={length(@child_categories)}
            strategies={item_reorder_strategies()}
            noun_singular={Gettext.gettext(PhoenixKitCatalogue.Gettext, "category")}
            noun_plural={Gettext.gettext(PhoenixKitCatalogue.Gettext, "categories")}
          />

          <%!-- Categories in the level's chosen view. The page-level
               card/table toggle drives this via the shared TableCardView
               storage key: "table" = the one-per-line rows, "card" = the
               tile grid. The Deleted tab renders both branches too, from
               the same components, so the trash looks like the rest of the
               page (Max, 2026-09-15). Both branches carry their own
               SortableGrid on the same reorder event. --%>
          <%!-- Category selection rides the same core BulkSelectScope
               toolkit as the item list, so both levels of the page select
               and act the same way: checkboxes are client-side, the
               toolbar stays hidden until something is selected, and the
               uuids travel with the action. "Reorder all" lives in the
               page control row; the toolbar's Reorder only appears for a
               2+ selection ("Reorder N selected"). --%>
          <.bulk_select_scope
            :if={@child_categories != []}
            id="categories-bulk"
            total_count={length(@child_categories)}
            swap="#detail-level-controls"
            class="flex flex-col gap-2"
          >
            <%!-- Reorder rewrites the manual order, which a sort hides — so,
                 like the item list's, it is offered only in Manual order
                 (codex, 2026-09-21; the item bar uses the same rule). --%>
            <div
              :if={@view_mode == "active"}
              data-bulk-show="has-selection"
              style="display: none;"
              class={
                @categories_sort_by != :position && "[&_[data-bulk-action*=reorder]]:!hidden"
              }
            >
              <.bulk_actions_toolbar
                on_open_reorder="open_categories_reorder_modal"
                reorder_dialog_id="categories-reorder-modal"
                reorder_gate={:multi}
                on_bulk_delete="request_bulk_delete_categories"
                noun_singular={Gettext.gettext(PhoenixKitCatalogue.Gettext, "category")}
                noun_plural={Gettext.gettext(PhoenixKitCatalogue.Gettext, "categories")}
              >
                <:leading>
                  <%!-- Categories nest: Move re-parents the selection (or
                       promotes it to the top level). Same client-side button
                       shape as the item list's Move. --%>
                  <button
                    type="button"
                    class="btn btn-sm btn-ghost"
                    data-bulk-action="request_bulk_move_categories"
                    data-bulk-show="has-selection"
                    style="display: none;"
                  >
                    <.icon name="hero-arrows-right-left" class="w-4 h-4" />
                    {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move")}
                  </button>
                  <button
                    type="button"
                    class="btn btn-sm btn-ghost"
                    data-bulk-action="request_bulk_duplicate_categories"
                    data-bulk-show="has-selection"
                    style="display: none;"
                  >
                    <.icon name="hero-document-duplicate" class="w-4 h-4" />
                    {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Duplicate")}
                  </button>
                </:leading>
              </.bulk_actions_toolbar>
            </div>
            <%!-- The Deleted tab's selection acts on the trash: Restore and
                 Delete forever, on the same core toolbar (its reorder
                 button hidden — a trash has no order). --%>
            <div
              :if={@view_mode == "deleted"}
              data-bulk-show="has-selection"
              style="display: none;"
              class="[&_[data-bulk-action*=reorder]]:!hidden"
            >
              <.bulk_actions_toolbar
                on_open_reorder="open_categories_reorder_modal"
                reorder_gate={:multi}
                noun_singular={Gettext.gettext(PhoenixKitCatalogue.Gettext, "category")}
                noun_plural={Gettext.gettext(PhoenixKitCatalogue.Gettext, "categories")}
              >
                <:leading>
                  <.trash_bulk_buttons
                    restore_event="request_bulk_restore_categories"
                    delete_event="request_bulk_permanent_delete_categories"
                  />
                </:leading>
              </.bulk_actions_toolbar>
            </div>

          <%!-- The CATEGORIES surface reads the same key as everything
               else: it kept its own until now, so a level holding child
               categories switched its items to cards and left the
               categories above them as a table. --%>
          <div
            id="catalogue-categories-views"
            phx-hook="TableCardView"
            data-storage-key={view_storage_key()}
          >
            <div data-table-view class="hidden md:block">
              <%!-- The active categories are always the collapsible tree
                   (the index's folder browser one level down — Max,
                   2026-08-29); a sort orders each sibling group inside it
                   and takes the drag handles away. The flat table is for
                   the other status tabs, which keep no tree. --%>
              <.categories_tree_table
                context_menu={@row_context_menu}
                sort={header_sort(@categories_sort_by, @categories_sort_dir)}
                :if={categories_tree_mode?(assigns)}
                rows={
                  category_tree_rows(
                    sorted_tree_children(@category_tree_children, assigns),
                    normalize_category_key(@current_category_uuid),
                    @expanded_categories
                  )
                }
                reorderable={categories_reorderable?(assigns)}
                catalogue={@catalogue}
                current_uuid={normalize_category_key(@current_category_uuid)}
                return_to={current_level_path(assigns)}
                categories_columns={@categories_columns}
                child_counts={@child_counts}
                child_subcat_counts={@child_subcat_counts}
                file_counts={@file_counts}
                view_mode={@view_mode}
                show_uncat={show_uncat_entry?(assigns)}
                uncategorized_active_count={@uncategorized_active_count}
              />
              <.categories_table
                context_menu={@row_context_menu}
                sort={header_sort(@categories_sort_by, @categories_sort_dir)}
                :if={not categories_tree_mode?(assigns)}
                categories_sort_by={@categories_sort_by}
                categories_columns={tab_columns(@categories_columns, @view_mode)}
                child_subcat_counts={@child_subcat_counts}
                catalogue={@catalogue}
                child_categories={@child_categories}
                child_counts={@child_counts}
                children_with_subs={@children_with_subs}
                return_to={current_level_path(assigns)}
                view_mode={@view_mode}
                file_counts={@file_counts}
                show_uncat={show_uncat_entry?(assigns)}
                uncategorized_active_count={@uncategorized_active_count}
              />
            </div>

            <div data-card-view class="md:hidden">
              <%!-- Card twin of the tree (Max, 2026-08-29: "how about
                   the nesting?"): a category with children renders as a
                   BOX containing its subcategory cards, all the way
                   down — the index's card-level idiom. Same
                   CatalogueTreeDnD contract as the tree table. --%>
              <.categories_card_level
                context_menu={@row_context_menu}
                catalogue={@catalogue}
                tree_children={card_tree_children(assigns)}
                root_uuid={normalize_category_key(@current_category_uuid)}
                return_to={current_level_path(assigns)}
                child_counts={@child_counts}
                child_subcat_counts={@child_subcat_counts}
                file_counts={@file_counts}
                categories_columns={tab_columns(@categories_columns, @view_mode)}
                view_mode={@view_mode}
                reorderable={@view_mode == "active" and @categories_sort_by == :position}
                show_uncat={show_uncat_entry?(assigns)}
                uncategorized_active_count={@uncategorized_active_count}
              />
            </div>
          </div>
          </.bulk_select_scope>


          <%!-- Card/table view toggle. One toggle, one storage key
               ("catalogue-detail-items") — it drives every item table on
               this page live (search results, active level items, deleted
               list) via the TableCardView sync event. It used to render
               for the deleted list only, on the grounds that the active
               list's cards lack select-all / drag-reorder; that caution
               was overridden by a deliberate product call (2026-08-14):
               card view is wanted everywhere, and card-side reorder is
               tracked as its own follow-up. --%>

          <%!-- The current node's own direct items --%>
          <.level_items
                context_menu={@row_context_menu}
            view_mode_pref={@view_mode_pref}
            attribute_map={@attribute_map}
            supplier_costs={@supplier_costs}
            items_columns={tab_columns(@items_columns, @view_mode)}
            controls_in_page_header={@child_categories == []}
            reorder_allowed={@current_category != nil or @child_categories == []}
            :if={@show_items_section}
            items={@items}
            file_counts={@file_counts}
            edit_path_fn={@edit_path_fn}
            view_mode={@view_mode}
            catalogue={@catalogue}
            current_category={@current_category}
            current_category_uuid={@current_category_uuid}
            items_total={@items_total}
            items_offset={@items_offset}
            items_sort_by={@items_sort_by}
            items_sort_dir={@items_sort_dir}
            show_items_reorder={@show_items_reorder}
            reorder_captured_uuids={@reorder_captured_uuids}
          />

          <%!-- A truly empty level: no sections, nothing to list. A
               category-less level WITH items lists them instead
               (show_items_section). --%>
          <.empty_state
            :if={@child_categories == [] and @items_total == 0}
            variant="card"
            title={
              Gettext.gettext(PhoenixKitCatalogue.Gettext, "No categories or items yet. Add a category or item to get started.")
            }
          />

          <%!-- Bottom navigation (client request 2026-08-19): on small
               screens a long level means lots of scrolling, so the way
               up lives at the bottom too. `navigate`, not `patch` — a
               patch preserves scroll position, which would strand the
               reader at the bottom of the level they just left; the
               remount lands them at the top. Buttons render only when
               they differ from the one before: a category shows Up (+
               All categories when deeper) + All catalogues; the
               catalogue root shows just All catalogues. --%>
          <div class="flex flex-wrap justify-center gap-2 pt-2">
            <.link
              :if={@current_category}
              navigate={up_level_path(assigns)}
              class="btn btn-outline btn-sm"
            >
              <.icon name="hero-arrow-up" class="w-4 h-4" />
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Up one level")}
            </.link>
            <.link
              :if={@current_category && @breadcrumb != []}
              navigate={Paths.catalogue_detail(@catalogue.uuid)}
              class="btn btn-outline btn-sm"
            >
              <.icon name="hero-squares-2x2" class="w-4 h-4" />
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "All categories")}
            </.link>
            <.link navigate={Paths.index()} class="btn btn-outline btn-sm">
              <.icon name="hero-rectangle-stack" class="w-4 h-4" />
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "All catalogues")}
            </.link>
          </div>
        </div>
      </div>

      <.column_sections_modal
        :if={@show_columns_modal}
        show={@show_columns_modal}
        sections={
          for scope <- detail_column_scopes(assigns) do
            %{
              scope: scope,
              title: detail_column_section_title(scope),
              selected: current_scope_columns(assigns, scope)
            }
          end
        }
      />

      <.confirm_modal
        show={match?({"item", _}, @confirm_delete)}
        on_confirm="permanently_delete_item"
        on_cancel="cancel_delete"
        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Permanently delete item")}
        title_icon="hero-trash"
        messages={[{:warning, Gettext.gettext(PhoenixKitCatalogue.Gettext, "This item will be permanently deleted. This cannot be undone.")}]}
        confirm_text={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete forever")}
        danger={true}
      />

      <.confirm_modal
        show={match?({"category", _}, @confirm_delete)}
        on_confirm="permanently_delete_category"
        on_cancel="cancel_delete"
        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Permanently delete category")}
        title_icon="hero-trash"
        messages={[{:warning, category_delete_warning(@confirm_delete_scope)}]}
        confirm_text={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete forever")}
        danger={true}
      />

      <%!-- "What about the items?" modal — opens when the operator
           clicks Delete on a category that still has active items in
           its subtree. Delete is a trash: the category goes to the
           Deleted view and can be restored, so the popup says so, and
           the default sends the items there with it, because restoring
           the category brings them back (Max, 2026-09-14). It used to
           default to uncategorizing, which a restore cannot undo. --%>
      <.confirm_modal
        :if={@trash_modal}
        show={true}
        on_confirm="confirm_trash_category"
        on_cancel="cancel_trash_category"
        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move category to Deleted — what about its items?")}
        title_icon="hero-folder-minus"
        confirm_text={
          if @trash_modal[:disposition] == :cascade,
            do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move category and items to Deleted"),
            else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move category to Deleted")
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
            "and its subtree contain %{count} active items. The category moves to the Deleted view, where it can be restored. Choose what happens to its items.",
            count: @trash_modal[:item_count]
          )}
        </p>

        <div class="space-y-3 mt-4">
          <%!-- Option 1 (default): the items go to the Deleted view with
               the category and come back when it is restored. --%>
          <label class="flex items-start gap-3 p-3 rounded-lg border border-base-300 cursor-pointer hover:bg-base-200/50">
            <input
              type="radio"
              name="trash_disposition"
              value="cascade"
              checked={@trash_modal[:disposition] == :cascade}
              phx-click="set_trash_disposition"
              phx-value-disposition="cascade"
              class="radio radio-sm radio-primary mt-0.5"
            />
            <div class="flex-1 min-w-0">
              <p class="font-medium text-sm">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move items to Deleted with the category")}
              </p>
              <p class="text-xs text-base-content/60">
                {Gettext.gettext(
                  PhoenixKitCatalogue.Gettext,
                  "Restoring the category brings them back with it."
                )}
              </p>
            </div>
          </label>

          <%!-- Option 2: uncategorize. The items stay live; a restore of
               the category does not put them back. --%>
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
                  "Items stay in this catalogue without a category. Restoring the category later does not put them back."
                )}
              </p>
            </div>
          </label>

          <%!-- Option 3: move to another category in the same catalogue.
               Only meaningful when there's a sibling/elsewhere to move to;
               we still render the radio when the list is empty so the UI
               is symmetric, but the dropdown shows an empty-state hint. A
               restore of the category does not move the items back. --%>
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
                  "Pick a target category in this catalogue; the category being moved to Deleted and its subtree are excluded. Restoring the category later does not move them back."
                )}
              </p>
              <%= if @trash_modal[:targets] == [] do %>
                <p class="text-xs text-warning">
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No other categories available — use Uncategorized instead.")}
                </p>
              <% else %>
                <.move_target_picker
                  event="select_trash_target"
                  targets={@trash_modal[:targets]}
                  target_uuid={@trash_modal[:target_uuid]}
                  disabled={@trash_modal[:disposition] != :move_to}
                  class=""
                />
              <% end %>
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
        title={bulk_confirm_title(@bulk_confirm)}
        title_icon="hero-trash"
        confirm_text={bulk_confirm_button(@bulk_confirm)}
        danger={true}
        messages={bulk_confirm_messages(@bulk_confirm)}
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

        <.move_catalogue_picker
          event="select_bulk_move_catalogue"
          catalogues={@bulk_move_modal[:catalogues]}
          current_uuid={@catalogue_uuid}
          selected_uuid={@bulk_move_modal[:target_catalogue_uuid]}
        />

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
                {if @bulk_move_modal[:target_catalogue_uuid] == @catalogue_uuid,
                  do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Items keep their catalogue but lose their category."),
                  else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Items go to the chosen catalogue without a category.")}
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
                {if @bulk_move_modal[:target_catalogue_uuid] == @catalogue_uuid,
                  do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move items to another category"),
                  else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Put items in a category there")}
              </p>
              <%= if @bulk_move_modal[:targets] == [] do %>
                <p class="text-xs text-warning">
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No categories available — use Uncategorized instead.")}
                </p>
              <% else %>
                <.move_target_picker
                  id={"select_bulk_move_target-#{@bulk_move_modal[:target_catalogue_uuid]}"}
                  event="select_bulk_move_target"
                  targets={@bulk_move_modal[:targets]}
                  target_uuid={@bulk_move_modal[:target_uuid]}
                  disabled={@bulk_move_modal[:disposition] != :move_to}
                  class="mt-2"
                />
              <% end %>
            </div>
          </label>
        </div>
      </.confirm_modal>

      <%!-- Bulk-move modal for categories: promote the selection to the top
           level, or nest it under another category of this catalogue (the
           picker already leaves out each selected category's own subtree). --%>
      <.confirm_modal
        :if={@bulk_move_categories_modal}
        show={true}
        on_confirm="confirm_bulk_move_categories"
        on_cancel="cancel_bulk_move_categories"
        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move selected categories")}
        title_icon="hero-arrows-right-left"
        confirm_text={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move categories")}
        confirm_disabled={
          @bulk_move_categories_modal[:disposition] == :move_under and
            is_nil(@bulk_move_categories_modal[:target_uuid])
        }
      >
        <p class="text-sm text-base-content/70">
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Pick where %{count} categories should go. Each one brings its subcategories and items along.", count: @bulk_move_categories_modal[:count])}
        </p>

        <.move_catalogue_picker
          event="select_bulk_move_categories_catalogue"
          catalogues={@bulk_move_categories_modal[:catalogues]}
          current_uuid={@catalogue_uuid}
          selected_uuid={@bulk_move_categories_modal[:target_catalogue_uuid]}
        />

        <div class="space-y-3 mt-4">
          <label class="flex items-start gap-3 p-3 rounded-lg border border-base-300 cursor-pointer hover:bg-base-200/50">
            <input
              type="radio"
              name="bulk_move_categories_disposition"
              value="top_level"
              checked={@bulk_move_categories_modal[:disposition] == :top_level}
              phx-click="set_bulk_move_categories_disposition"
              phx-value-disposition="top_level"
              class="radio radio-sm radio-primary mt-0.5"
            />
            <div class="flex-1 min-w-0">
              <p class="font-medium text-sm">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Make them top-level categories")}
              </p>
              <p class="text-xs text-base-content/60">
                {if @bulk_move_categories_modal[:target_catalogue_uuid] == @catalogue_uuid,
                  do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "They leave their parent and sit at the root of this catalogue."),
                  else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "They sit at the root of the chosen catalogue.")}
              </p>
            </div>
          </label>

          <label class="flex items-start gap-3 p-3 rounded-lg border border-base-300 cursor-pointer hover:bg-base-200/50">
            <input
              type="radio"
              name="bulk_move_categories_disposition"
              value="move_under"
              checked={@bulk_move_categories_modal[:disposition] == :move_under}
              phx-click="set_bulk_move_categories_disposition"
              phx-value-disposition="move_under"
              class="radio radio-sm radio-primary mt-0.5"
            />
            <div class="flex-1 min-w-0">
              <p class="font-medium text-sm">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Nest them under another category")}
              </p>
              <%= if @bulk_move_categories_modal[:targets] == [] do %>
                <p class="text-xs text-warning">
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No category can take them — only the top level is left.")}
                </p>
              <% else %>
                <.move_target_picker
                  id={"select_bulk_move_categories_target-#{@bulk_move_categories_modal[:target_catalogue_uuid]}"}
                  event="select_bulk_move_categories_target"
                  targets={@bulk_move_categories_modal[:targets]}
                  target_uuid={@bulk_move_categories_modal[:target_uuid]}
                  disabled={@bulk_move_categories_modal[:disposition] != :move_under}
                  class="mt-2"
                />
              <% end %>
            </div>
          </label>
        </div>
      </.confirm_modal>

      <.confirm_modal
        :if={@bulk_duplicate_modal}
        show={true}
        on_confirm="confirm_bulk_duplicate"
        on_cancel="cancel_bulk_duplicate"
        title={
          if @bulk_duplicate_modal.kind == :items,
            do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Duplicate selected items"),
            else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Duplicate selected categories")
        }
        title_icon="hero-document-duplicate"
        confirm_text={
          if @bulk_duplicate_modal.kind == :items,
            do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Duplicate items"),
            else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Duplicate categories")
        }
      >
        <p class="text-sm text-base-content/70">
          <%= if @bulk_duplicate_modal.kind == :items do %>
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "%{count} items will be copied with their files, attribute sets, supplier rows and catalogue rules. Comments are not copied.", count: @bulk_duplicate_modal.count)}
          <% else %>
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "%{count} categories will be copied with their subcategories and items.", count: @bulk_duplicate_modal.count)}
          <% end %>
        </p>
        <p class="text-sm text-base-content/70 mt-2">
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Each copy is named after its original with “(copy)” added and placed right after it.")}
        </p>
      </.confirm_modal>

      <ProductCard.product_card
        id="catalogue-detail-product"
        show={@card_open}
        item_name={@card_name}
        images={@card_images}
        fields={@card_fields}
        files={@card_files}
        target={nil}
        on_close="card_close"
      >
        <:extra_actions>
          <.link
            :if={@card_edit_path}
            id="catalogue-detail-product-edit"
            navigate={@card_edit_path}
            class="btn btn-primary"
          >
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit")}
          </.link>
        </:extra_actions>
      </ProductCard.product_card>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  # ── Drill-down level components ──────────────────────────────────

  # The level's categories as a REAL table — same anatomy as the item and
  # catalogue tables (drag column, checkbox, photo column, Name, count,
  # Actions) so the three levels read as one product ("uniform experience",
  # boss call 2026-08-15). This is the table branch of the level's
  # card/table toggle; the tile grid below is the card branch.
  attr(:catalogue, :map, required: true)
  attr(:child_categories, :list, required: true)
  attr(:child_counts, :map, required: true)
  attr(:children_with_subs, :any, required: true)
  attr(:view_mode, :string, required: true)
  attr(:categories_sort_by, :atom, default: :position)
  attr(:file_counts, :map, required: true)
  attr(:show_uncat, :boolean, default: false)
  attr(:uncategorized_active_count, :integer, default: 0)
  attr(:categories_columns, :list, default: ["items"])
  attr(:child_subcat_counts, :map, default: %{})

  attr(:return_to, :string, default: nil)

  # Threaded from the page, not read per row: one setting, and a hundred
  # rows would otherwise be a hundred settings reads per render.
  attr(:context_menu, :boolean, default: false)

  attr(:sort, :map,
    default: nil,
    doc: "`header_sort/2` of the categories' sort — nil in Manual order (plain headers)."
  )

  defp categories_table(assigns) do
    assigns =
      assigns
      |> assign(
        :draggable?,
        assigns.view_mode == "active" and length(assigns.child_categories) > 1 and
          assigns.categories_sort_by == :position
      )
      |> assign(
        :photo_col?,
        # The managed "Image" column (opt-in via the Columns modal) and
        # this automatic one show the same `featured_image_uuid` — with
        # both on, a row gets the same picture twice. The managed
        # column wins once it's turned on; this one is the fallback for
        # everyone who hasn't opted in (owner's call, 2026-09-09).
        # Always there when there are rows (boss via Max, 2026-09-21: a
        # preview column that comes and goes with whether some row has a
        # picture left names jumping level to level) — a row without one
        # gets the picker's letter tile.
        assigns.child_categories != [] and
          "image" not in assigns.categories_columns
      )
      |> assign(:extension_columns, TableConfig.extension_columns(:detail_categories))

    ~H"""
    <%!-- Plain table (no `items`): the level's OWN card/table wrapper
         drives visibility and the pk-comfy marker; passing items here
         would spawn table_default's nested view machinery with its own
         storage key, drifting out of sync with the page toggle. --%>
    <.table_default
      id="catalogue-categories-table"
      size="sm"
      wrapper_class="overflow-x-auto shadow-none rounded-none"
    >
      <.table_default_header>
        <.table_default_row>
          <.drag_handle_header_cell :if={@draggable?} />
          <.bulk_select_header_cell
            :if={@view_mode in ["active", "deleted"]}
            id="categories-select-all"
            aria_label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Select all categories")}
          />
          <.table_default_header_cell :if={@view_mode not in ["active", "deleted"]} class="w-8"></.table_default_header_cell>
          <.table_default_header_cell :if={@photo_col?} class="w-12 !pr-0 !py-1 [.pk-comfy_&]:w-22 [.pk-comfy_&]:!py-1.5"></.table_default_header_cell>
          <.sort_header_cell field={:name} sort={@sort} event="toggle_sort_categories">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Name")}
          </.sort_header_cell>
          <.category_header_cells
            columns={@categories_columns}
            extension_columns={@extension_columns}
            sort={@sort}
          />
          <.actions_header_cell />
        </.table_default_row>
      </.table_default_header>
      <.sortable_tbody
        id="catalogue-child-categories"
        enabled={@draggable?}
        event="reorder_categories"
      >
        <.sortable_row
          :for={cat <- @child_categories}
          item_id={cat.uuid}
          data-row-menu-context={@context_menu}
        >
          <.drag_handle_cell :if={@draggable? and cat.status == "active"} />
          <td :if={@draggable? and cat.status != "active"} class="w-8"></td>
          <.table_default_cell class="w-8">
            <input
              :if={selectable_category?(@view_mode, cat)}
              type="checkbox"
              class="checkbox checkbox-xs"
              data-bulk-role="row"
              data-uuid={cat.uuid}
            />
          </.table_default_cell>
          <.table_default_cell :if={@photo_col?} class="w-12 !pr-0 !py-1 [.pk-comfy_&]:w-22 [.pk-comfy_&]:!py-1.5">
            <%!-- The image enters the category exactly like the name
            (boss, 2026-08-31); a deleted row keeps the bare thumb like
            its name stays unlinked. --%>
            <.link :if={cat.status != "deleted"} patch={Paths.category_browse(@catalogue.uuid, cat.uuid)}>
              <.featured_thumb resource={cat} has_files={Map.get(@file_counts, cat.uuid, 0) > 0} letter />
            </.link>
            <.featured_thumb
              :if={cat.status == "deleted"}
              resource={cat}
              has_files={Map.get(@file_counts, cat.uuid, 0) > 0}
              letter
            />
          </.table_default_cell>
          <.table_default_cell class={name_cell_class()}>
            <div class="flex items-center gap-2 min-w-0">
              <.link
                :if={cat.status != "deleted"}
                patch={Paths.category_browse(@catalogue.uuid, cat.uuid)}
                class="link link-hover font-medium"
              >
                {cat.name}
              </.link>
              <span :if={cat.status == "deleted"} class="font-medium">
                {cat.name}
              </span>
              <%!-- Same words as the tree's toggle, but no toggle: this table
                   only renders for the status tabs (the trash among them),
                   which keep no tree to open. It used to render for every
                   non-manual sort too, where these words looked like the
                   tree's button and did nothing (boss via Max, 2026-09-21). --%>
              <span
                :if={MapSet.member?(@children_with_subs, cat.uuid)}
                class="badge badge-ghost badge-sm font-normal whitespace-nowrap"
              >
                {subcategories_label(Map.get(@child_subcat_counts, cat.uuid, 0))}
              </span>
            </div>
          </.table_default_cell>
          <.category_body_cells
            columns={@categories_columns}
            cat={cat}
            child_counts={@child_counts}
            child_subcat_counts={@child_subcat_counts}
            file_counts={@file_counts}
            extension_columns={@extension_columns}
          />
          <.table_default_cell class="text-right whitespace-nowrap">
            <.category_row_menu
              cat={cat}
              catalogue={@catalogue}
              view_mode={@view_mode}
              return_to={@return_to}
            />
          </.table_default_cell>
        </.sortable_row>
        <tr :if={@show_uncat} data-row-menu-context={@context_menu}>
          <td :if={@draggable?} class="w-8"></td>
          <td class="w-8"></td>
          <td :if={@photo_col?} class="w-12 !pr-0 !py-1 [.pk-comfy_&]:w-22 [.pk-comfy_&]:!py-1.5">
            <.thumb_icon_tile icon="hero-folder-open" />
          </td>
          <td class={name_cell_class()}>
            <.link patch={Paths.uncategorized_browse(@catalogue.uuid)} class="link link-hover">
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Uncategorized")}
            </.link>
          </td>
          <.uncategorized_category_cells
            columns={@categories_columns}
            count={@uncategorized_active_count}
            extension_columns={@extension_columns}
          />
          <td class="text-right">
            <.table_row_menu mode="auto" id="category-menu-uncategorized">
              <.table_row_menu_link
                patch={Paths.uncategorized_browse(@catalogue.uuid)}
                icon="hero-folder-open"
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Open")}
              />
            </.table_row_menu>
          </td>
        </tr>
      </.sortable_tbody>
    </.table_default>
    """
  end

  # ── Shared category cells ─────────────────────────────────────────
  # `category_header_cells/1` + `category_body_cells/1` moved to
  # `Components` (2026-08-31): the flat table, the tree table and the
  # item-selector popup's level table draw them from one definition.

  attr(:cat, :map, required: true)
  attr(:catalogue, :map, required: true)
  attr(:view_mode, :string, required: true)

  attr(:return_to, :string, default: nil)

  defp category_row_menu(assigns) do
    ~H"""
    <.table_row_menu
      :if={@view_mode == "active" and @cat.status == "active"}
      mode="auto"
      id={"category-menu-#{@cat.uuid}"}
    >
      <.table_row_menu_button
        phx-click="show_category_card"
        phx-value-uuid={@cat.uuid}
        icon="hero-eye"
        label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "View")}
      />
      <.table_row_menu_divider />
      <.table_row_menu_link
        navigate={with_return_to(Paths.category_edit(@cat.uuid), @return_to)}
        icon="hero-pencil"
        label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit")}
      />
      <.table_row_menu_link
        navigate={new_subcategory_path(@catalogue.uuid, @cat.uuid, @return_to)}
        icon="hero-folder-plus"
        label={gettext("New subcategory")}
      />
      <.table_row_menu_divider />
      <.table_row_menu_button
        phx-click="request_trash_category"
        phx-value-uuid={@cat.uuid}
        icon="hero-trash"
        label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")}
        variant="error"
      />
    </.table_row_menu>
    <.table_row_menu
      :if={@view_mode == "deleted" and @cat.status == "deleted"}
      mode="auto"
      id={"category-del-menu-#{@cat.uuid}"}
    >
      <.table_row_menu_button
        phx-click="restore_category"
        phx-value-uuid={@cat.uuid}
        phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restoring…")}
        icon="hero-arrow-path"
        label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restore")}
        variant="success"
      />
      <.table_row_menu_divider />
      <.table_row_menu_button
        phx-click="show_delete_confirm"
        phx-value-uuid={@cat.uuid}
        phx-value-type="category"
        icon="hero-trash"
        label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete forever")}
        variant="error"
      />
    </.table_row_menu>
    """
  end

  # ── Category tree table (the folder browser one level down) ──────
  #
  # The index's collapsible folder tree brought over to categories (Max,
  # 2026-08-29: "bring over all the folder stuff… it will just be a
  # category browser"): every level of the drilled node's subtree as
  # collapsible rows, name click drills (re-roots via ?category=),
  # chevron expands in place, and the CatalogueTreeDnD hook gives drag
  # to reorder among siblings, nest into a row, or lift to this level.
  attr(:rows, :list, required: true, doc: "[{cat, depth, child_count, expanded?}]")
  attr(:catalogue, :map, required: true)
  attr(:current_uuid, :any, required: true)
  attr(:categories_columns, :list, required: true)
  attr(:child_counts, :map, required: true)
  attr(:child_subcat_counts, :map, required: true)
  attr(:file_counts, :map, required: true)
  attr(:view_mode, :string, required: true)
  attr(:show_uncat, :boolean, required: true)
  attr(:uncategorized_active_count, :integer, required: true)

  attr(:return_to, :string, default: nil)

  # Threaded from the page, not read per row: one setting, and a hundred
  # rows would otherwise be a hundred settings reads per render.
  attr(:context_menu, :boolean, default: false)

  attr(:reorderable, :boolean,
    default: true,
    doc:
      "Manual order: drag handles on. Off under any other sort, where a drop " <>
        "would land wherever the sort puts it and write a position nobody chose."
  )

  attr(:sort, :map,
    default: nil,
    doc: "`header_sort/2` of the categories' sort — nil in Manual order (plain headers)."
  )

  defp categories_tree_table(assigns) do
    cats = Enum.map(assigns.rows, fn {cat, _d, _h, _e} -> cat end)

    assigns =
      assigns
      |> assign(
        :photo_col?,
        # See the matching comment on `categories_table/1` above — same
        # managed-"Image"-column-suppresses-the-automatic-one rule.
        (cats != [] or assigns.show_uncat) and
          "image" not in assigns.categories_columns
      )
      |> assign(:extension_columns, TableConfig.extension_columns(:detail_categories))

    ~H"""
    <div :if={@rows == []} class="card bg-base-100 shadow">
      <div class="card-body items-center text-center py-12">
        <p class="text-base-content/60">
          {gettext("No categories here yet.")}
        </p>
      </div>
    </div>
    <div
      :if={@rows != [] or @show_uncat}
      id="catalogue-categories-tree"
      phx-hook="CatalogueTreeDnD"
      data-tree-memory-key={"pk-catalogue-tree-open:" <> @catalogue.uuid}
      class="relative overflow-x-auto"
    >
      <%!-- "Lift to this level" target — hidden until a drag starts,
           overlaid over the header so revealing it never shifts the
           rows under the cursor mid-drag (same trick as the index). --%>
      <div
        data-tree-rootzone="1"
        data-tree-drop="root"
        class="hidden absolute top-0 left-0 right-0 z-10 rounded-lg border-2 border-dashed border-primary/50 bg-base-100 py-2.5 text-center text-sm text-base-content/60"
      >
        <.icon name="hero-arrow-up-tray" class="w-4 h-4 inline-block mr-1 align-text-bottom" />
        {gettext("Drop here to move to this level")}
      </div>
      <.table_default
        id="catalogue-categories-tree-table"
        size="sm"
        wrapper_class="overflow-x-auto shadow-none rounded-none"
      >
        <.table_default_header>
          <.table_default_row>
            <.table_default_header_cell class="w-8"></.table_default_header_cell>
            <.bulk_select_header_cell
              id="categories-select-all"
              aria_label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Select all categories")}
            />
            <.table_default_header_cell :if={@photo_col?} class="w-12 !pr-0 !py-1 [.pk-comfy_&]:w-22 [.pk-comfy_&]:!py-1.5"></.table_default_header_cell>
            <.sort_header_cell field={:name} sort={@sort} event="toggle_sort_categories">
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Name")}
            </.sort_header_cell>
            <.category_header_cells
              columns={@categories_columns}
              extension_columns={@extension_columns}
              sort={@sort}
            />
            <.actions_header_cell />
          </.table_default_row>
        </.table_default_header>
        <.table_default_body>
          <%!-- The row id lets morphdom insert opened children where they
               belong (not re-purpose the rows below), which is also what
               lets them fade in: the fade is what shows the click caused
               them. No tint on an open branch: a blue row reads as a
               selected row in this module (Max, 2026-09-19) — the guide
               rails carry the grouping. --%>
          <.table_default_row
            :for={{cat, depth, child_count, expanded?} <- @rows}
            id={"category-tree-row-" <> cat.uuid}
            data-row-menu-context={@context_menu}
            phx-mounted={
              depth > 0 &&
                Phoenix.LiveView.JS.transition({"ease-out duration-150", "opacity-0", "opacity-100"})
            }
            data-tree-uuid={cat.uuid}
            data-tree-type="category"
            data-tree-parent={tree_parent_key(cat, @current_uuid)}
            data-tree-drop={cat.uuid}
          >
            <%!-- The cell stays under any sort so the columns do not shift;
                 only the handle goes. It is the drag source, so without it
                 nothing in this row can be dragged. --%>
            <.table_default_cell class="w-8 !pr-0">
              <span
                :if={@reorderable}
                data-tree-item={"category:" <> cat.uuid}
                class="pk-drag-handle cursor-grab text-base-content/30 hover:text-base-content/60"
                title={gettext("Drag to reorder or nest")}
              >
                <.icon name="hero-bars-3" class="w-4 h-4" />
              </span>
            </.table_default_cell>
            <.table_default_cell class="w-8">
              <input
                type="checkbox"
                class="checkbox checkbox-xs"
                data-bulk-role="row"
                data-uuid={cat.uuid}
              />
            </.table_default_cell>
            <.table_default_cell :if={@photo_col?} class="w-12 !pr-0 !py-1 [.pk-comfy_&]:w-22 [.pk-comfy_&]:!py-1.5">
              <.link patch={Paths.category_browse(@catalogue.uuid, cat.uuid)}>
                <.featured_thumb resource={cat} has_files={Map.get(@file_counts, cat.uuid, 0) > 0} letter />
              </.link>
            </.table_default_cell>
            <.category_tree_name_cell
              cat={cat}
              catalogue={@catalogue}
              depth={depth}
              child_count={child_count}
              expanded={expanded?}
            />
            <.category_body_cells
              columns={@categories_columns}
              cat={cat}
              child_counts={@child_counts}
              child_subcat_counts={@child_subcat_counts}
              file_counts={@file_counts}
              extension_columns={@extension_columns}
            />
            <.table_default_cell class="text-right whitespace-nowrap">
              <.category_row_menu
              cat={cat}
              catalogue={@catalogue}
              view_mode={@view_mode}
              return_to={@return_to}
            />
            </.table_default_cell>
          </.table_default_row>
          <tr :if={@show_uncat} data-row-menu-context={@context_menu}>
            <td class="w-8"></td>
            <td class="w-8"></td>
            <td :if={@photo_col?} class="w-12 !pr-0 !py-1 [.pk-comfy_&]:w-22 [.pk-comfy_&]:!py-1.5">
              <.thumb_icon_tile icon="hero-folder-open" />
            </td>
            <td class={name_cell_class()}>
              <.link patch={Paths.uncategorized_browse(@catalogue.uuid)} class="link link-hover">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Uncategorized")}
              </.link>
            </td>
            <.uncategorized_category_cells
              columns={@categories_columns}
              count={@uncategorized_active_count}
              extension_columns={@extension_columns}
            />
            <td class="text-right">
              <.table_row_menu mode="auto" id="category-menu-uncategorized-tree">
                <.table_row_menu_link
                  patch={Paths.uncategorized_browse(@catalogue.uuid)}
                  icon="hero-folder-open"
                  label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Open")}
                />
              </.table_row_menu>
            </td>
          </tr>
        </.table_default_body>
      </.table_default>
    </div>
    """
  end

  # A tree row's name cell. The NAME opens the chapter's content — that
  # category's own page ("how else are people supposed to get to the
  # items" — Max, 2026-08-29); the button after it unfolds the outline in
  # place and says so in words. It replaced a bare `›` chevron before the
  # name (boss, 2026-09-19): a right chevron reads as "go there", which
  # the name already does, and the space it reserved on childless rows
  # read as a missing icon. No folder icon: categories are chapters, not
  # folders.
  #
  # Rows opened under a parent hang off guide rails, one per level, drawn
  # the full height of the cell so they join into continuous lines.
  #
  # The button looks the same open or closed — only its triangle turns. A
  # filled "on" state read as selected (Max, 2026-09-19); the tinted branch
  # below it already says it is open.
  attr(:cat, :map, required: true)
  attr(:catalogue, :map, required: true)
  attr(:depth, :integer, required: true)
  attr(:child_count, :integer, required: true)
  attr(:expanded, :boolean, required: true)

  defp category_tree_name_cell(assigns) do
    ~H"""
    <td class={"relative " <> name_cell_class()}>
      <span
        :for={level <- 1..@depth//1}
        aria-hidden="true"
        class="absolute inset-y-0 border-l-2 border-base-content/20"
        style={"left: calc(0.75rem + #{level - 1} * 1.25rem)"}
      >
      </span>
      <div
        class="flex items-center gap-2 min-w-0"
        style={@depth > 0 && "padding-left: calc(#{@depth} * 1.25rem)"}
      >
        <.link
          patch={Paths.category_browse(@catalogue.uuid, @cat.uuid)}
          class="link link-hover font-medium truncate"
        >
          {@cat.name}
        </.link>
        <button
          :if={@child_count > 0}
          type="button"
          phx-click="toggle_category_expand"
          phx-value-uuid={@cat.uuid}
          aria-expanded={to_string(@expanded)}
          class="btn btn-xs btn-outline rounded-full font-normal gap-1 shrink-0 whitespace-nowrap border-base-content/20 text-base-content/70"
        >
          <.icon
            name="hero-play-solid"
            class={"w-2.5 h-2.5 transition-transform" <> if(@expanded, do: " rotate-90", else: "")}
          />
          {subcategories_label(@child_count)}
        </button>
      </div>
    </td>
    """
  end

  # The hook gathers a level by this key: "root" is the level the view
  # is standing in (the drilled node, or the catalogue's top level).
  defp tree_parent_key(%{parent_uuid: parent}, current_uuid)
       when parent == current_uuid or is_nil(parent),
       do: "root"

  defp tree_parent_key(%{parent_uuid: parent}, _current_uuid), do: parent

  # The active categories are ALWAYS the tree. A sort orders each sibling
  # group within it; it never swaps the structure for a flat table. It used
  # to: any sort but Manual order dropped the subcategories and left a
  # "2 subcategories" badge that looked like the tree's toggle and did
  # nothing — and since the sort is one shared setting pushed live, one
  # person's "Name" flattened everyone's tree (boss via Max, 2026-09-21:
  # "sometimes it's just a flat list, or you can't even open the
  # subcategories"). The flat table is the trash's now, and only the trash's.
  defp categories_tree_mode?(assigns) do
    assigns.view_mode == "active"
  end

  # Dragging writes manual positions, so it exists only in Manual order.
  # Under any other sort a drop would put a row where the SORT, not the user,
  # decides — and write a position nobody chose. The drop handlers check
  # this server-side: a hook push can arrive under any sort, or be forged.
  defp categories_reorderable?(assigns) do
    categories_tree_mode?(assigns) and assigns.categories_sort_by == :position
  end

  # The tree's sibling groups, each ordered by the current sort. One index
  # serves the tree table and the card boxes, so the two views cannot order
  # the same level differently (card view used to ignore the sort). Items
  # sorts by the same `child_counts` the Items column shows, so the column
  # always reads as sorted.
  defp sorted_tree_children(index, assigns) do
    Map.new(index, fn {parent, siblings} ->
      {parent,
       sort_categories(
         siblings,
         assigns.child_counts,
         assigns.categories_sort_by,
         assigns.categories_sort_dir
       )}
    end)
  end

  # The root's loose items presented like any subcategory (Max,
  # 2026-08-31: "show them, just like if we were inside a category and
  # there were sub categories") — the category browser gets an
  # Uncategorized entry when the bucket holds anything. Root only (the
  # bucket is catalogue-level) and active mode only (the trash lists
  # items, not buckets).
  defp show_uncat_entry?(assigns) do
    assigns.view_mode == "active" and is_nil(assigns.current_category) and
      assigns.uncategorized_active_count > 0
  end

  # The hook's "root" is the level the view stands in: the drilled
  # category, or nil at the catalogue's top. The uncategorized bucket
  # renders no tree, so a forged "root" there means the top level too.
  defp resolve_tree_target(socket, "root") do
    case socket.assigns.current_category_uuid do
      "uncategorized" -> {:ok, nil}
      other -> {:ok, other}
    end
  end

  # Forgeable client input: anything that is not "root" or a well-formed
  # uuid is rejected outright — normalizing it to nil would silently
  # reparent the category to the catalogue root (panel finding).
  defp resolve_tree_target(_socket, target) when is_binary(target) do
    case Ecto.UUID.cast(target) do
      {:ok, _} -> {:ok, target}
      :error -> :error
    end
  end

  defp resolve_tree_target(_socket, _target), do: :error

  # "category:uuid" strings from the hook → validated uuid list. Any
  # malformed entry rejects the whole payload (forgeable client input).
  defp parse_category_entries(entries) do
    parsed =
      Enum.map(entries, fn entry ->
        with true <- is_binary(entry),
             ["category", uuid] <- String.split(entry, ":", parts: 2),
             {:ok, _} <- Ecto.UUID.cast(uuid) do
          uuid
        else
          _ -> :invalid
        end
      end)

    if :invalid in parsed, do: :error, else: {:ok, parsed}
  end

  # Move (a no-op when the parent is unchanged), then write the level's
  # order when an edge drop supplied one. A failed move skips the
  # reorder — the flash carries the reason. The drop target stays
  # expanded so the moved row remains visible.
  defp apply_category_move(socket, uuid, target_uuid, ordered_uuids) do
    catalogue_uuid = socket.assigns.catalogue_uuid

    with %Category{catalogue_uuid: ^catalogue_uuid} = category <- Catalogue.get_category(uuid),
         {:ok, _} <- Catalogue.move_category_under(category, target_uuid, actor_opts(socket)),
         :ok <- maybe_reorder_level(socket, target_uuid, ordered_uuids) do
      socket
      |> maybe_expand_tree_target(target_uuid)
      |> put_flash(:info, moved_flash(socket, target_uuid))
    else
      {:error, reason} ->
        put_flash(socket, :error, category_move_error(reason))

      _ ->
        put_flash(
          socket,
          :error,
          Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to move category.")
        )
    end
  end

  defp maybe_reorder_level(_socket, _target, nil), do: :ok

  # Best-effort, and only against the authoritative level: the move has
  # already committed, so a reorder that cannot apply (forged/partial
  # entry list, orphan-promoted roots whose stored parent differs) is
  # SKIPPED rather than reported as a failed move (panel findings). The
  # sibling set comes from the server, not the payload.
  defp maybe_reorder_level(socket, target_uuid, ordered_uuids) do
    catalogue_uuid = socket.assigns.catalogue_uuid

    server_level =
      catalogue_uuid
      |> Catalogue.list_child_categories(target_uuid)
      |> MapSet.new(& &1.uuid)

    if MapSet.equal?(MapSet.new(ordered_uuids), server_level) do
      case Catalogue.reorder_categories(
             catalogue_uuid,
             target_uuid,
             ordered_uuids,
             actor_opts(socket)
           ) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Category drop reorder skipped: reason=#{inspect(reason)} catalogue=#{catalogue_uuid} parent=#{inspect(target_uuid)}"
          )

          :ok
      end
    else
      :ok
    end
  end

  defp maybe_expand_tree_target(socket, nil), do: socket

  defp maybe_expand_tree_target(socket, uuid) do
    socket
    |> update(:expanded_categories, &MapSet.put(&1, uuid))
    |> remember_expanded()
  end

  # Hands the open set to the tree's hook, which keeps it in the browser.
  defp remember_expanded(socket) do
    push_event(socket, "category_tree_open", %{
      uuids: MapSet.to_list(socket.assigns.expanded_categories)
    })
  end

  # "Category moved." said nothing about where. Naming the destination is
  # what the client needed on 2026-08-31: hers went into a collapsed
  # parent and, back on the level, looked gone.
  defp moved_flash(_socket, nil),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category moved to the top level.")

  defp moved_flash(socket, target_uuid) do
    case Catalogue.get_category(target_uuid) do
      nil ->
        Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category moved.")

      target ->
        Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category moved into %{name}.",
          name: Catalogue.localize_one(target, loc(socket)).name
        )
    end
  end

  defp category_move_error(:would_create_cycle),
    do: gettext("A category cannot move into its own subtree.")

  defp category_move_error(:parent_not_found),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Target category not found.")

  defp category_move_error(:cross_catalogue),
    do: gettext("Categories can only move within their own catalogue.")

  defp category_move_error(_),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to move category.")

  # Depth-first rows of the drilled node's subtree, skipping the
  # children of collapsed rows: `{cat, depth, child_count, expanded?}`.
  defp category_tree_rows(children_index, root_uuid, expanded) do
    walk_category_level(children_index, root_uuid, 0, expanded)
  end

  defp walk_category_level(index, parent_uuid, depth, expanded) do
    index
    |> Map.get(parent_uuid, [])
    |> Enum.flat_map(fn cat ->
      child_count = index |> Map.get(cat.uuid, []) |> length()
      expanded? = child_count > 0 and MapSet.member?(expanded, cat.uuid)
      row = {cat, depth, child_count, expanded?}

      if expanded? do
        [row | walk_category_level(index, cat.uuid, depth + 1, expanded)]
      else
        [row]
      end
    end)
  end

  # ── Nested card level (the index's card-level idiom, for chapters) ──

  attr(:catalogue, :map, required: true)
  attr(:tree_children, :map, required: true)
  attr(:root_uuid, :any, required: true)
  attr(:child_counts, :map, required: true)
  attr(:child_subcat_counts, :map, required: true)
  attr(:file_counts, :map, required: true)
  attr(:categories_columns, :list, required: true)
  attr(:view_mode, :string, required: true)
  attr(:reorderable, :boolean, required: true)
  attr(:show_uncat, :boolean, default: false)
  attr(:uncategorized_active_count, :integer, default: 0)

  attr(:return_to, :string, default: nil)
  attr(:context_menu, :boolean, default: false)

  defp categories_card_level(assigns) do
    assigns =
      assigns
      |> assign(:roots, Map.get(assigns.tree_children, assigns.root_uuid, []))
      # Same "fetch once per page render, pass down" discipline as
      # `categories_table/1` / `categories_tree_table/1` — this is the
      # card view's own entry point into a `categories_columns` render
      # pass, so it owns the fetch here.
      |> assign(:extension_columns, TableConfig.extension_columns(:detail_categories))

    ~H"""
    <div
      :if={@roots != [] or @show_uncat}
      id="catalogue-categories-cards"
      phx-hook="CatalogueTreeDnD"
      class="relative"
    >
      <div
        data-tree-rootzone="1"
        data-tree-drop="root"
        class="hidden absolute -top-1 left-0 right-0 z-10 rounded-lg border-2 border-dashed border-primary/50 bg-base-100 py-2.5 text-center text-sm text-base-content/60"
      >
        <.icon name="hero-arrow-up-tray" class="w-4 h-4 inline-block mr-1 align-text-bottom" />
        {gettext("Drop here to move to this level")}
      </div>
      <.category_card_entries
        context_menu={@context_menu}
        entries={@roots}
        parent_key="root"
        catalogue={@catalogue}
        return_to={@return_to}
        tree_children={@tree_children}
        child_counts={@child_counts}
        child_subcat_counts={@child_subcat_counts}
        file_counts={@file_counts}
        categories_columns={@categories_columns}
        extension_columns={@extension_columns}
        view_mode={@view_mode}
        reorderable={@reorderable}
      >
        <:trailing>
          <.uncategorized_card
            :if={@show_uncat}
            count={@uncategorized_active_count}
            patch={Paths.uncategorized_browse(@catalogue.uuid)}
          />
        </:trailing>
      </.category_card_entries>
    </div>
    """
  end

  attr(:entries, :list, required: true)
  attr(:parent_key, :string, required: true)
  attr(:catalogue, :map, required: true)
  attr(:tree_children, :map, required: true)
  attr(:child_counts, :map, required: true)
  attr(:child_subcat_counts, :map, required: true)
  attr(:file_counts, :map, required: true)
  attr(:categories_columns, :list, required: true)
  attr(:extension_columns, :map, default: %{})
  attr(:view_mode, :string, required: true)
  attr(:reorderable, :boolean, required: true)

  slot(:trailing,
    doc:
      "Rendered inside the grid after the level's cards — the root level " <>
        "appends the Uncategorized tile here."
  )

  # One level's cards: leaves as tiles, parents as full-width BOXES with
  # their children's grid inside, recursively — so the whole outline is
  # visible in card view too (Max, 2026-08-29). Boxes and tiles share
  # the tree-DnD contract: middle drop nests, edges reorder, the root
  # strip lifts.
  attr(:return_to, :string, default: nil)

  # Threaded from the page, not read per row: one setting, and a hundred
  # rows would otherwise be a hundred settings reads per render.
  attr(:context_menu, :boolean, default: false)

  defp category_card_entries(assigns) do
    ~H"""
    <div class="grid grid-cols-2 sm:grid-cols-3 gap-3">
      <%= for cat <- @entries do %>
        <%= if Map.get(@tree_children, cat.uuid, []) == [] do %>
          <.category_tile
            catalogue_uuid={@catalogue.uuid}
            return_to={@return_to}
            category={cat}
            reorderable={@reorderable}
            tree_parent={@parent_key}
            count={Map.get(@child_counts, cat.uuid, 0)}
            categories_columns={@categories_columns}
            extension_columns={@extension_columns}
            subcat_count={Map.get(@child_subcat_counts, cat.uuid, 0)}
            file_count={Map.get(@file_counts, cat.uuid, 0)}
            has_subs={false}
            view_mode={@view_mode}
            sibling_count={length(@entries)}
            has_files={Map.get(@file_counts, cat.uuid, 0) > 0}
          />
        <% else %>
          <div
            data-tree-uuid={cat.uuid}
            data-tree-type="category"
            data-tree-parent={@parent_key}
            data-tree-drop={cat.uuid}
            data-row-menu-context={@context_menu}
            class="col-span-full rounded-lg border border-base-300 bg-base-200/40 p-3 flex flex-col gap-2"
          >
            <div class="flex items-center gap-2 min-w-0">
              <span
                :if={@reorderable}
                data-tree-item={"category:" <> cat.uuid}
                class="pk-drag-handle cursor-grab active:cursor-grabbing text-base-content/40 hover:text-base-content/70"
                title={gettext("Drag to reorder or nest")}
              >
                <.icon name="hero-bars-3" class="w-4 h-4" />
              </span>
              <input
                type="checkbox"
                class="checkbox checkbox-xs"
                data-bulk-role="row"
                data-uuid={cat.uuid}
              />
              <.link
                patch={Paths.category_browse(@catalogue.uuid, cat.uuid)}
                class={"truncate hover:text-primary " <> name_cell_class()}
              >
                {cat.name}
              </.link>
              <span class="badge badge-ghost badge-sm tabular-nums">
                {Map.get(@child_counts, cat.uuid, 0)}
              </span>
              <div class="ml-auto">
                <.table_row_menu mode="auto" id={"category-box-menu-#{cat.uuid}"}>
                  <.table_row_menu_button
                    phx-click="show_category_card"
                    phx-value-uuid={cat.uuid}
                    icon="hero-eye"
                    label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "View")}
                  />
                  <.table_row_menu_divider />
                  <.table_row_menu_link
                    navigate={with_return_to(Paths.category_edit(cat.uuid), @return_to)}
                    icon="hero-pencil"
                    label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit")}
                  />
                  <.table_row_menu_link
                    navigate={new_subcategory_path(@catalogue.uuid, cat.uuid, @return_to)}
                    icon="hero-folder-plus"
                    label={gettext("New subcategory")}
                  />
                  <.table_row_menu_divider />
                  <.table_row_menu_button
                    phx-click="request_trash_category"
                    phx-value-uuid={cat.uuid}
                    icon="hero-trash"
                    label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")}
                    variant="error"
                  />
                </.table_row_menu>
              </div>
            </div>
            <.category_card_entries
              context_menu={@context_menu}
              entries={Map.get(@tree_children, cat.uuid, [])}
              parent_key={cat.uuid}
              catalogue={@catalogue}
              return_to={@return_to}
              tree_children={@tree_children}
              child_counts={@child_counts}
              child_subcat_counts={@child_subcat_counts}
              file_counts={@file_counts}
              categories_columns={@categories_columns}
              extension_columns={@extension_columns}
              view_mode={@view_mode}
              reorderable={@reorderable}
            />
          </div>
        <% end %>
      <% end %>
      {render_slot(@trailing)}
    </div>
    """
  end

  # Tile form of the category card — the "card view" branch of the level's
  # categories. Same affordances as the row (drill, select, drag among
  # siblings, edit); the file indicator moves into the badge row because a
  # corner emblem would clip against the tile's figure.
  attr(:catalogue_uuid, :string, required: true)
  attr(:category, :map, required: true)
  attr(:count, :integer, required: true)
  attr(:has_subs, :boolean, default: false)
  attr(:view_mode, :string, required: true)
  attr(:sibling_count, :integer, required: true)
  attr(:has_files, :boolean, default: false)
  attr(:categories_columns, :list, default: ["items"])
  attr(:extension_columns, :map, default: %{})
  attr(:subcat_count, :integer, default: 0)
  attr(:file_count, :integer, default: 0)
  attr(:reorderable, :boolean, default: true)
  attr(:tree_parent, :string, default: "root")

  # Renders through the shared `Components.category_card/1` (the popup's
  # subcategory tiles use the same definition, 2026-08-31); this wrapper
  # keeps the admin-only chrome — bulk checkbox, drag handle, row menu,
  # tree-DnD data attributes — in the page that owns those behaviours.
  attr(:return_to, :string, default: nil)

  defp category_tile(assigns) do
    assigns =
      assign(
        assigns,
        :tree_active,
        assigns.view_mode == "active" and assigns.category.status == "active"
      )

    ~H"""
    <.category_card
      category={@category}
      columns={@categories_columns}
      extension_columns={@extension_columns}
      count={@count}
      subcat_count={@subcat_count}
      file_count={@file_count}
      has_subs={@has_subs}
      has_files={@has_files}
      patch={
        if @category.status == "deleted",
          do: nil,
          else: Paths.category_browse(@catalogue_uuid, @category.uuid)
      }
      data-tree-uuid={@tree_active && @category.uuid}
      data-tree-type={@tree_active && "category"}
      data-tree-parent={@tree_active && @tree_parent}
    >
      <:overlay>
        <input
          :if={@tree_active or selectable_category?(@view_mode, @category)}
          type="checkbox"
          class="checkbox checkbox-xs absolute top-1.5 left-1.5 bg-base-100/80"
          data-bulk-role="row"
          data-uuid={@category.uuid}
        />
        <span
          :if={@tree_active and @reorderable}
          data-tree-item={"category:" <> @category.uuid}
          class="pk-drag-handle cursor-grab active:cursor-grabbing absolute top-1.5 right-1.5 rounded bg-base-100/80 p-0.5 text-base-content/50 hover:text-base-content/80"
          title={gettext("Drag to reorder or nest")}
        >
          <.icon name="hero-bars-3" class="w-4 h-4" />
        </span>
      </:overlay>
      <:menu>
        <.table_row_menu
          :if={@category.status != "deleted"}
          mode="auto"
          id={"category-tile-menu-#{@category.uuid}"}
        >
          <.table_row_menu_button
            phx-click="show_category_card"
            phx-value-uuid={@category.uuid}
            icon="hero-eye"
            label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "View")}
          />
          <.table_row_menu_divider />
          <.table_row_menu_link
            navigate={with_return_to(Paths.category_edit(@category.uuid), @return_to)}
            icon="hero-pencil"
            label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit")}
          />
          <.table_row_menu_link
            navigate={new_subcategory_path(@catalogue_uuid, @category.uuid, @return_to)}
            icon="hero-folder-plus"
            label={gettext("New subcategory")}
          />
          <.table_row_menu_divider />
          <.table_row_menu_button
            phx-click="request_trash_category"
            phx-value-uuid={@category.uuid}
            icon="hero-trash"
            label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")}
            variant="error"
          />
        </.table_row_menu>
        <.trash_row_menu
          :if={@category.status == "deleted"}
          id={"category-tile-del-menu-#{@category.uuid}"}
          uuid={@category.uuid}
          restore_event="restore_category"
          delete_type="category"
          preview_event="show_category_card"
        />
      </:menu>
    </.category_card>
    """
  end

  # Tile form of the Uncategorized drill (root, active mode).

  # The current node's own direct items.
  #
  # Active mode: the core List-UI toolkit — a sort dropdown, client-side
  # bulk-select with a floating actions toolbar, node-scoped DnD reorder
  # (manual mode only), and a strategy "Reorder" modal. The Deleted tab
  # renders the same table, with Restore / Delete forever as its row and
  # card menus and bulk actions. One InfiniteScroll sentinel pages the list.
  attr(:items, :list, required: true)
  attr(:view_mode, :string, required: true)
  attr(:catalogue, :any, required: true)
  attr(:current_category, :any, required: true)
  attr(:current_category_uuid, :any, required: true)
  attr(:items_total, :integer, required: true)
  attr(:items_offset, :integer, required: true)
  attr(:items_sort_by, :atom, required: true)
  attr(:items_sort_dir, :atom, required: true)
  attr(:show_items_reorder, :boolean, required: true)
  attr(:reorder_captured_uuids, :list, required: true)
  attr(:file_counts, :map, default: %{})
  attr(:attribute_map, :map, default: %{})
  attr(:supplier_costs, :map, default: %{})

  attr(:edit_path_fn, :any, required: true)
  attr(:items_columns, :list, default: ["sku", "price", "unit", "status"])
  attr(:view_mode_pref, :string, required: true)

  attr(:controls_in_page_header, :boolean,
    default: false,
    doc:
      "Item-only levels render the sort selector + Reorder-all in the page " <>
        "control row; the in-section toolbar then only offers selection-scoped " <>
        "reorder and bulk actions."
  )

  attr(:reorder_allowed, :boolean,
    default: true,
    doc:
      "False when the list spans more than one position scope (the " <>
        "catalogue-wide root list): positions are per category, so a " <>
        "drag there would interleave unrelated sequences."
  )

  # Threaded from the page, not read per row: one setting, and a hundred
  # rows would otherwise be a hundred settings reads per render.
  attr(:context_menu, :boolean, default: false)

  defp level_items(assigns) do
    # `draggable?` controls the handle *column* (manual sort, not the deleted
    # list); `reorderable?` controls the actual grip + DnD, which needs ≥2
    # items. The column is kept even at a single item — rendered as an empty
    # spacer cell — so deleting down to one row doesn't shift the layout.
    draggable? =
      assigns.items_sort_by == :position and assigns.view_mode != "deleted" and
        assigns.reorder_allowed

    assigns =
      assigns
      |> assign(:draggable?, draggable?)
      |> assign(:reorderable?, draggable? and assigns.items_total > 1)
      # Hoisted, exactly as `categories_table/1` above already does for its
      # own grid. `any_media_thumb?/2` scans the WHOLE item list, and it was
      # being called once per row inside the loop as well as once for the
      # header — so a full page of 100 items ran 101 full-list scans per
      # render, on a page that re-renders on every PubSub event, sort and
      # scroll page.
      # The managed "Image" column (opt-in via the Columns modal) shows
      # the same `featured_image_uuid` as this automatic column — with
      # both on, a row got the same picture twice. The managed column
      # wins once it's turned on (owner's call, 2026-09-09).
      |> assign(
        :photo_col?,
        assigns.items != [] and
          "image" not in assigns.items_columns
      )
      |> assign(:extension_columns, TableConfig.extension_columns(:detail_items))

    ~H"""
    <div class="flex flex-col gap-2">
      <%!-- ── Active list: core List-UI toolkit ── --%>
      <%!-- Swap only when this list's controls live in the page row. With
           its own toolbar (a mixed level) the row is on screen already and
           the action buttons appear INSIDE it, so nothing moves and there
           is nothing to replace. --%>
      <.bulk_select_scope
        :if={@items != []}
        id="items-bulk"
        total_count={@items_total}
        swap={if @controls_in_page_header, do: "#detail-level-controls"}
        class="flex flex-col gap-2"
      >
        <%!-- With the sort selector + Reorder-all promoted to the page
             control row, the toolbar has nothing to show until rows are
             selected — hide the empty bar (hook re-shows it on selection). --%>
        <div
          :if={@view_mode != "deleted"}
          data-bulk-show={if @controls_in_page_header, do: "has-selection"}
          style={if @controls_in_page_header, do: "display: none;"}
          class={
            !@reorder_allowed && "[&_[data-bulk-action*=reorder]]:!hidden"
          }
        >
          <.bulk_actions_toolbar
            on_open_reorder="open_items_reorder_modal"
          reorder_dialog_id="items-reorder-modal"
          reorder_gate={
            if not @controls_in_page_header and @items_total > 1 and
                 @items_sort_by == :position,
               do: :always,
               else: :multi
          }
          on_bulk_delete="request_bulk_delete_items"
          noun_singular={Gettext.gettext(PhoenixKitCatalogue.Gettext, "item")}
          noun_plural={Gettext.gettext(PhoenixKitCatalogue.Gettext, "items")}
        >
          <:leading>
            <.sort_selector
              :if={!@controls_in_page_header}
              sort_by={@items_sort_by}
              sort_dir={@items_sort_dir}
              options={item_sort_options()}
              manual_field={:position}
              event="sort_items"
              label
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
            <button
              type="button"
              class="btn btn-sm btn-ghost"
              data-bulk-action="request_bulk_duplicate_items"
              data-bulk-show="has-selection"
              style="display: none;"
            >
              <.icon name="hero-document-duplicate" class="w-4 h-4" />
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Duplicate")}
            </button>
          </:leading>
          </.bulk_actions_toolbar>
        </div>
        <div
          :if={@view_mode == "deleted"}
          data-bulk-show="has-selection"
          style="display: none;"
          class="[&_[data-bulk-action*=reorder]]:!hidden"
        >
          <.bulk_actions_toolbar
            on_open_reorder="open_items_reorder_modal"
            reorder_gate={:multi}
            noun_singular={Gettext.gettext(PhoenixKitCatalogue.Gettext, "item")}
            noun_plural={Gettext.gettext(PhoenixKitCatalogue.Gettext, "items")}
          >
            <:leading>
              <.trash_bulk_buttons
                restore_event="request_bulk_restore_items"
                delete_event="request_bulk_delete_items"
              />
            </:leading>
          </.bulk_actions_toolbar>
        </div>


        <.table_default
          id="level-items-active"
          size="sm"
          wrapper_class="overflow-x-auto shadow-none rounded-none"
          toggleable={true}
          show_toggle={false}
          items={@items}
          storage_key={view_storage_key()}
          card_context_menu={@context_menu}
          on_reorder={if @reorderable?, do: "reorder_items"}
          {card_media_frame()}
        >
          <%!-- The picture leads the card and the selection checkbox rides
                in its corner, exactly as the categories grid above does it
                (boss via Max, 2026-08-28). --%>
          <:card_media :let={item}>
            <%!-- Band inside the slot — the pinned core ignores
                 card_media_class, so the frame never applied. --%>
            <figure class={card_media_band()}>
              <.card_media
                resource={item}
                has_files={Map.get(@file_counts, item.uuid, 0) > 0}
                on_click="show_product_card"
              >
                <:overlay>
                  <input
                    type="checkbox"
                    class="checkbox checkbox-xs absolute top-1.5 left-1.5 bg-base-100/80"
                    data-bulk-role="row"
                    data-uuid={item.uuid}
                  />
                </:overlay>
              </.card_media>
            </figure>
          </:card_media>
          <:card_body :let={item}>
            <div class="flex items-center gap-2 font-medium text-sm">
              <.link
                :if={item.uuid && @view_mode != "deleted"}
                navigate={@edit_path_fn.(item.uuid)}
                class="link link-hover min-w-0 truncate"
              >
                {item.name || "—"}
              </.link>
              <span :if={item.uuid && @view_mode == "deleted"} class="min-w-0 truncate">
                {item.name || "—"}
              </span>
              <span
                :if={Map.has_key?(@attribute_map, item.uuid)}
                class="shrink-0"
                title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Has attribute set")}
              >
                <.icon name="hero-swatch" class="w-3.5 h-3.5 text-primary/60" />
              </span>
            </div>
            <div class="grid grid-cols-2 gap-x-4 gap-y-1 text-sm flex-1">
              <%= for col <- @items_columns do %>
                <%= case col do %>
                  <% "sku" -> %>
                    <div class="text-base-content/60">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "SKU")}</div>
                    <div class="font-mono text-base-content/60">{item.sku || "—"}</div>
                  <% "image" -> %>
                    <%!-- No-op here, deliberately: this card's media band
                         above (`<.card_media>`) already shows this same
                         `featured_image_uuid` unconditionally, so repeating
                         it as a fact would show the same picture twice in
                         one card — unlike the table, which has no such
                         band and needs the managed column to show a
                         picture at all. --%>
                  <% "price" -> %>
                    <div class="text-base-content/60">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Price")}</div>
                    <div class="font-semibold">
                      {if sale_price = Catalogue.item_pricing(item).sale_price,
                        do: Decimal.to_string(sale_price, :normal),
                        else: "—"}
                    </div>
                  <% "supplier_price" -> %>
                    <div class="text-base-content/60">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Supplier price")}</div>
                    <div>{format_supplier_costs(Map.get(@supplier_costs, item.uuid, []))}</div>
                  <% "unit" -> %>
                    <div class="text-base-content/60">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Unit")}</div>
                    <div>{Item.unit_label(item.unit)}</div>
                  <% "status" -> %>
                    <div class="text-base-content/60">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Status")}</div>
                    <div><.status_badge status={item.status || "unknown"} size={:xs} /></div>
                  <% "attributes" -> %>
                    <div class="text-base-content/60">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Attributes")}</div>
                    <div>{attribute_cell_text(Map.get(@attribute_map, item.uuid)) || "—"}</div>
                  <% "files" -> %>
                    <div class="text-base-content/60">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Files")}</div>
                    <div class="tabular-nums">{Map.get(@file_counts, item.uuid, 0)}</div>
                  <% "description" -> %>
                    <div class="text-base-content/60">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Description")}</div>
                    <div class="line-clamp-2">{item.description || "—"}</div>
                  <% "updated" -> %>
                    <div class="text-base-content/60">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Updated")}</div>
                    <div>{Calendar.strftime(item.updated_at, "%Y-%m-%d %H:%M")}</div>
                  <% "created" -> %>
                    <div class="text-base-content/60">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Created")}</div>
                    <div>{Calendar.strftime(item.inserted_at, "%Y-%m-%d %H:%M")}</div>
                  <% other -> %>
                    <%= if ext = Map.get(@extension_columns, other) do %>
                      <div class="text-base-content/60">{ext.label.()}</div>
                      <div>{ext.render.(item)}</div>
                    <% end %>
                <% end %>
              <% end %>
            </div>
          </:card_body>
          <:card_actions :let={item}>
            <.item_card_menu
              :if={item.uuid && @view_mode != "deleted"}
              item={item}
              edit_path={@edit_path_fn}
              preview_event="show_product_card"
              on_delete="delete_item"
            />
            <.trash_row_menu
              :if={item.uuid && @view_mode == "deleted"}
              id={"item-card-del-menu-#{item.uuid}"}
              uuid={item.uuid}
              restore_event="restore_item"
              delete_type="item"
              preview_event="show_product_card"
            />
          </:card_actions>
          <%!-- Desktop table view: sort headers, bulk-select, DnD unchanged --%>
          <.table_default_header>
            <.table_default_row>
              <.drag_handle_header_cell :if={@draggable?} />
              <.bulk_select_header_cell
                id="level-items-select-all"
                aria_label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Select all items")}
              />
              <%!-- Featured images get their own slim column (inline-left
                   of the name made rows jagged); only when some row on
                   this level actually has one. --%>
              <.table_default_header_cell :if={@photo_col?} class="w-12 !pr-0 !py-1 [.pk-comfy_&]:w-22 [.pk-comfy_&]:!py-1.5"></.table_default_header_cell>
              <.sort_header_cell field={:name} sort={header_sort(@items_sort_by, @items_sort_dir)} event="toggle_sort_items">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Name")}
              </.sort_header_cell>
              <%= for col <- @items_columns do %>
                <%= case col do %>
                  <% "sku" -> %>
                    <.sort_header_cell field={:sku} sort={header_sort(@items_sort_by, @items_sort_dir)} event="toggle_sort_items" class="w-px whitespace-nowrap">
                      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "SKU")}
                    </.sort_header_cell>
                  <% "image" -> %>
                    <.table_default_header_cell class="w-px whitespace-nowrap">
                      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Image")}
                    </.table_default_header_cell>
                  <% "price" -> %>
                    <.sort_header_cell field={:base_price} sort={header_sort(@items_sort_by, @items_sort_dir)} event="toggle_sort_items" class="w-px whitespace-nowrap">
                      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Price")}
                    </.sort_header_cell>
                  <% "supplier_price" -> %>
                    <.table_default_header_cell class="w-px whitespace-nowrap">
                      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Supplier price")}
                    </.table_default_header_cell>
                  <% "unit" -> %>
                    <.table_default_header_cell class="w-px whitespace-nowrap">
                      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Unit")}
                    </.table_default_header_cell>
                  <% "status" -> %>
                    <.sort_header_cell field={:status} sort={header_sort(@items_sort_by, @items_sort_dir)} event="toggle_sort_items" class="w-px whitespace-nowrap">
                      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Status")}
                    </.sort_header_cell>
                  <% "attributes" -> %>
                    <.table_default_header_cell class="w-px">
                      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Attributes")}
                    </.table_default_header_cell>
                  <% "files" -> %>
                    <.table_default_header_cell class="w-px whitespace-nowrap">
                      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Files")}
                    </.table_default_header_cell>
                  <% "description" -> %>
                    <.table_default_header_cell class="w-px">
                      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Description")}
                    </.table_default_header_cell>
                  <% "updated" -> %>
                    <.table_default_header_cell class="w-px whitespace-nowrap">
                      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Updated")}
                    </.table_default_header_cell>
                  <% "created" -> %>
                    <.table_default_header_cell class="w-px whitespace-nowrap">
                      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Created")}
                    </.table_default_header_cell>
                  <% other -> %>
                    <%= if ext = Map.get(@extension_columns, other) do %>
                      <.table_default_header_cell class="w-px whitespace-nowrap">{ext.label.()}</.table_default_header_cell>
                    <% end %>
                <% end %>
              <% end %>
              <.actions_header_cell />
            </.table_default_row>
          </.table_default_header>
          <.sortable_tbody
            id={"items-body-" <> (@current_category_uuid || "root")}
            enabled={@reorderable?}
            event="reorder_items"
          >
            <.sortable_row
              :for={item <- @items}
              item_id={item.uuid}
              data-row-menu-context={@context_menu}
            >
              <.drag_handle_cell :if={@reorderable?} />
              <%!-- Single-item list: keep the column width so the layout
                   doesn't jump when a delete drops the list to one row. --%>
              <td :if={@draggable? and not @reorderable?} class="w-8"></td>
              <.bulk_select_cell value={item.uuid} />
              <.table_default_cell :if={@photo_col?} class="w-12 !pr-0 !py-1 [.pk-comfy_&]:w-22 [.pk-comfy_&]:!py-1.5">
                <.featured_thumb
                  resource={item}
                  on_click="show_product_card"
                  has_files={Map.get(@file_counts, item.uuid, 0) > 0}
                  letter
                />
              </.table_default_cell>
              <.item_pricing_cell
                item={item}
                edit_path={if @view_mode != "deleted", do: @edit_path_fn}
                has_attributes={Map.has_key?(@attribute_map, item.uuid)}
                attribute_text={
                  if "attributes" in @items_columns,
                    do: attribute_cell_text(Map.get(@attribute_map, item.uuid))
                }
                file_count={Map.get(@file_counts, item.uuid, 0)}
                columns={@items_columns}
                extension_columns={@extension_columns}
                supplier_costs={Map.get(@supplier_costs, item.uuid, [])}
              />
              <.item_row_menu
                :if={@view_mode != "deleted"}
                item={item}
                edit_path={@edit_path_fn}
                preview_event="show_product_card"
                on_delete="delete_item"
              />
              <.table_default_cell :if={@view_mode == "deleted"} class="text-right whitespace-nowrap">
                <.trash_row_menu
                  id={"item-row-del-menu-#{item.uuid}"}
                  uuid={item.uuid}
                  restore_event="restore_item"
                  delete_type="item"
                  preview_event="show_product_card"
                />
              </.table_default_cell>
            </.sortable_row>
          </.sortable_tbody>
        </.table_default>
      </.bulk_select_scope>


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

  # One level up from the current category: its parent (the trail's
  # last entry — @breadcrumb excludes the current node), or the
  # catalogue root when the category is top-level.
  defp up_level_path(assigns) do
    case List.last(assigns.breadcrumb) do
      %{uuid: uuid} -> Paths.category_browse(assigns.catalogue.uuid, uuid)
      _ -> Paths.catalogue_detail(assigns.catalogue.uuid)
    end
  end

  # Orders sibling categories for a reorder strategy; "reverse" reverses
  # the manual order (position, name-tiebroken), matching the drag order.
  # `[]` reorders every sibling; a captured subset is sorted by the
  # strategy and written back into the slots it occupied.
  defp reorder_within_slots(cats, [], strategy), do: order_categories_for_strategy(cats, strategy)

  defp reorder_within_slots(cats, captured, strategy) do
    selected? = &(&1.uuid in captured)
    resequenced = cats |> Enum.filter(selected?) |> order_categories_for_strategy(strategy)

    {ordered, []} =
      Enum.map_reduce(cats, resequenced, fn cat, queue ->
        if selected?.(cat), do: {hd(queue), tl(queue)}, else: {cat, queue}
      end)

    ordered
  end

  defp order_categories_for_strategy(cats, :name_asc),
    do: Enum.sort_by(cats, &String.downcase(&1.name || ""))

  defp order_categories_for_strategy(cats, :name_desc),
    do: Enum.sort_by(cats, &String.downcase(&1.name || ""), :desc)

  defp order_categories_for_strategy(cats, :created_desc),
    do: Enum.sort_by(cats, & &1.inserted_at, {:desc, DateTime})

  defp order_categories_for_strategy(cats, :created_asc),
    do: Enum.sort_by(cats, & &1.inserted_at, {:asc, DateTime})

  defp order_categories_for_strategy(cats, :reverse) do
    cats
    |> Enum.sort_by(&{&1.position, String.downcase(&1.name || "")})
    |> Enum.reverse()
  end

  # Active-list sort dropdown options. `:position` is "Manual order" (the
  # DnD mode) — the same wording the index's dropdown uses for the same
  # thing; these two said "Manual" and "Manual order" side by side.
  # gettext via the module backend so labels localize.
  # One path for the dropdown and the headers: set, persist (it is the
  # shared sort, so this also tells every other open page), re-sort the flat
  # list; the tree re-sorts itself at render.
  defp apply_categories_sort(socket, field, dir) do
    socket
    |> assign(categories_sort_by: field, categories_sort_dir: dir)
    |> persist_detail_sort(:detail_categories)
    |> then(fn s ->
      assign(
        s,
        :child_categories,
        sort_categories(s.assigns.child_categories, s.assigns.child_counts, field, dir)
      )
    end)
  end

  # In-memory categories sort — the list is small and already loaded.
  # Manual (:position) mirrors the DB order and is what enables drag.
  defp sort_categories(categories, counts, sort_by, dir) do
    sorted =
      case sort_by do
        :position -> Enum.sort_by(categories, &{&1.position, String.downcase(&1.name || "")})
        :name -> Enum.sort_by(categories, &String.downcase(&1.name || ""))
        :items -> Enum.sort_by(categories, &Map.get(counts, &1.uuid, 0))
        # The DateTime sorter, not term order — structurally, DateTime
        # structs compare field-alphabetically (day before month).
        :updated -> Enum.sort_by(categories, & &1.updated_at, DateTime)
      end

    if sort_by != :position and dir == :desc, do: Enum.reverse(sorted), else: sorted
  end

  defp category_sort_options do
    [
      {:position, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Manual order")},
      {:name, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Name")},
      {:items, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Items")},
      {:updated, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Updated")}
    ]
  end

  defp item_sort_options do
    [
      {:position, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Manual order")},
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

  # ── Origin-aware navigation ──────────────────────────────────────
  # "Add Item should be aware where it's clicked": the level you're on
  # travels with you — the new-item/new-category forms prefill the
  # category/parent, and return_to brings save/cancel back HERE instead
  # of dumping everyone at the catalogue root.

  # Where the level's Edit button goes: the drilled category's form (back to
  # this level after saving), else the catalogue's. The Uncategorized bucket
  # is the catalogue's own, so it edits the catalogue.
  defp level_edit_path(%{current_category: %Category{uuid: uuid}} = assigns),
    do: with_return_to(Paths.category_edit(uuid), current_level_path(assigns))

  defp level_edit_path(assigns), do: Paths.catalogue_edit(assigns.catalogue_uuid)

  defp level_edit_label(%Category{}), do: gettext("Edit category")
  defp level_edit_label(_), do: gettext("Edit catalogue")

  defp current_level_path(assigns) do
    case assigns.current_category do
      %Category{uuid: uuid} -> Paths.category_browse(assigns.catalogue_uuid, uuid)
      :uncategorized -> Paths.uncategorized_browse(assigns.catalogue_uuid)
      _ -> Paths.catalogue_detail(assigns.catalogue_uuid)
    end
  end

  defp new_item_path(assigns) do
    query =
      case assigns.current_category do
        %Category{uuid: uuid} -> [{"category", uuid}]
        _ -> []
      end ++ [{"return_to", current_level_path(assigns)}]

    Paths.item_new(assigns.catalogue_uuid) <> "?" <> URI.encode_query(query)
  end

  defp new_category_path(assigns) do
    query =
      case assigns.current_category do
        %Category{uuid: uuid} -> [{"parent_uuid", uuid}]
        _ -> []
      end ++ [{"return_to", current_level_path(assigns)}]

    Paths.category_new(assigns.catalogue_uuid) <> "?" <> URI.encode_query(query)
  end

  # Card view's categories: the active tree, or — in the Deleted tab — the
  # trashed categories this level lists, flat (the trash keeps no tree).
  defp card_tree_children(%{view_mode: "deleted"} = assigns),
    do: %{normalize_category_key(assigns.current_category_uuid) => assigns.child_categories}

  defp card_tree_children(assigns),
    do: sorted_tree_children(assigns.category_tree_children, assigns)

  # The Deleted tab always shows the Status column — it is what says a row
  # is in the trash now that the tab has no red styling of its own.
  defp tab_columns(columns, "deleted"),
    do: if("status" in columns, do: columns, else: columns ++ ["status"])

  defp tab_columns(columns, _view_mode), do: columns

  # A row carries a selection checkbox in the tab whose rows it belongs to.
  defp selectable_category?("active", %{status: "active"}), do: true
  defp selectable_category?("deleted", %{status: "deleted"}), do: true
  defp selectable_category?(_view_mode, _category), do: false

  defp bulk_confirm_title(%{kind: :categories, mode: :permanent}),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Permanently delete selected categories?")

  defp bulk_confirm_title(%{mode: :permanent}),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Permanently delete selected items?")

  defp bulk_confirm_title(_confirm),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete selected items?")

  defp bulk_confirm_button(%{mode: :permanent}),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete forever")

  defp bulk_confirm_button(_confirm), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")

  defp bulk_confirm_messages(%{kind: :categories, mode: :permanent, count: count}) do
    [
      {:warning,
       Gettext.gettext(
         PhoenixKitCatalogue.Gettext,
         "%{count} categories and everything in them will be permanently deleted. This cannot be undone.",
         count: count
       )}
    ]
  end

  defp bulk_confirm_messages(%{mode: :permanent, count: count}) do
    [
      {:warning,
       Gettext.gettext(
         PhoenixKitCatalogue.Gettext,
         "%{count} items will be permanently deleted. This cannot be undone.",
         count: count
       )}
    ]
  end

  defp bulk_confirm_messages(%{count: count}) do
    [
      {:warning,
       Gettext.gettext(
         PhoenixKitCatalogue.Gettext,
         "%{count} items will be moved to the Deleted view. They can be restored later.",
         count: count
       )}
    ]
  end

  # The Deleted tab's two bulk buttons, for a core toolbar's leading slot.
  attr(:restore_event, :string, required: true)
  attr(:delete_event, :string, required: true)

  defp trash_bulk_buttons(assigns) do
    ~H"""
    <button
      type="button"
      class="btn btn-sm btn-ghost"
      data-bulk-action={@restore_event}
      data-bulk-show="has-selection"
      style="display: none;"
    >
      <.icon name="hero-arrow-path" class="w-4 h-4" />
      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restore")}
    </button>
    <button
      type="button"
      class="btn btn-sm btn-ghost text-error"
      data-bulk-action={@delete_event}
      data-bulk-show="has-selection"
      style="display: none;"
    >
      <.icon name="hero-trash" class="w-4 h-4" />
      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete forever")}
    </button>
    """
  end

  # The Deleted tab's row menu: View (items) / Restore / Delete forever.
  attr(:id, :string, required: true)
  attr(:uuid, :string, required: true)
  attr(:restore_event, :string, required: true)
  attr(:delete_type, :string, required: true)

  attr(:preview_event, :string,
    default: nil,
    doc:
      "The event that opens this row's read-only card — `show_product_card` " <>
        "for an item, `show_category_card` for a category. Both fill the one " <>
        "card on the page, which offers no Edit for a deleted row."
  )

  defp trash_row_menu(assigns) do
    ~H"""
    <.table_row_menu mode="auto" id={@id}>
      <.table_row_menu_button
        :if={@preview_event}
        phx-click={@preview_event}
        phx-value-uuid={@uuid}
        icon="hero-eye"
        label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "View")}
      />
      <.table_row_menu_divider :if={@preview_event} />
      <.table_row_menu_button
        phx-click={@restore_event}
        phx-value-uuid={@uuid}
        phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restoring…")}
        icon="hero-arrow-path"
        label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restore")}
        variant="success"
      />
      <.table_row_menu_divider />
      <.table_row_menu_button
        phx-click="show_delete_confirm"
        phx-value-uuid={@uuid}
        phx-value-type={@delete_type}
        icon="hero-trash"
        label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete forever")}
        variant="error"
      />
    </.table_row_menu>
    """
  end

  # A category's Delete Forever warning names what is really removed: a
  # trashed card counts only what its Restore brings back, so rows trashed on
  # their own inside it would otherwise go without a word.
  defp category_delete_warning(%{subcategories: subs, items: items}) when subs > 0 or items > 0,
    do:
      Gettext.gettext(
        PhoenixKitCatalogue.Gettext,
        "This category, %{subcategories} subcategories and %{items} items inside it will be permanently deleted. This cannot be undone.",
        subcategories: subs,
        items: items
      )

  defp category_delete_warning(_scope),
    do:
      Gettext.gettext(
        PhoenixKitCatalogue.Gettext,
        "This category and all its items will be permanently deleted. This cannot be undone."
      )

  # A category's Edit and New Subcategory links carry the level they were
  # clicked from, so the category form's Cancel comes back to it.
  defp with_return_to(path, nil), do: path

  defp with_return_to(path, return_to),
    do: path <> "?" <> URI.encode_query([{"return_to", return_to}])

  defp new_subcategory_path(catalogue_uuid, parent_uuid, return_to) do
    return = if return_to, do: [{"return_to", return_to}], else: []

    Paths.category_new(catalogue_uuid) <>
      "?" <> URI.encode_query([{"parent_uuid", parent_uuid} | return])
  end

  # 1-arity closure for the item tables' edit_path attrs — every edit
  # link from this page carries the level to return to.
  defp item_edit_with_return(assigns) do
    query = "?" <> URI.encode_query([{"return_to", current_level_path(assigns)}])
    fn uuid -> Paths.item_edit(uuid) <> query end
  end

  defp current_node_label(:uncategorized),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Uncategorized")

  defp current_node_label(%Category{} = cat), do: cat.name
  defp current_node_label(_), do: ""

  # Shown under the admin header: the catalogue's description at root, the
  # current category's when drilled. The :uncategorized pseudo node has none;
  # blank strings count as absent.
  # The level's own picture: the drilled category's, or the catalogue's at the
  # top. nil when it has none, or in the Uncategorized bucket, which is not a
  # thing with a picture.
  defp level_image(%Category{} = category, _catalogue),
    do: if(featured_image_uuid(category), do: category)

  defp level_image(nil, catalogue), do: if(featured_image_uuid(catalogue), do: catalogue)
  defp level_image(_uncategorized, _catalogue), do: nil

  defp level_description(%Category{description: desc}, _catalogue), do: presence(desc)
  defp level_description(nil, catalogue), do: presence(catalogue.description)
  defp level_description(_uncategorized, _catalogue), do: nil

  defp presence(nil), do: nil
  defp presence(desc), do: if(String.trim(desc) == "", do: nil, else: desc)

  defp search_placeholder(nil),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search items by name, description, or SKU…")

  defp search_placeholder(:uncategorized),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search uncategorized items…")

  defp search_placeholder(%Category{}),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search within this category…")

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
end
