defmodule PhoenixKitCatalogue.Web.CataloguesLive do
  @moduledoc """
  Landing page for the Catalogue module.

  Handles three actions via tabs:
  - `:index` — list of catalogues
  """

  use Phoenix.LiveView

  use PhoenixKitWeb.Live.UrlState,
    params: [
      search_query: [default: "", url_key: "q"],
      # The drilled folder is URL state (?folder=<uuid>), mirroring the
      # detail page's ?category= — shareable, Back-friendly, reload-safe.
      # "" (absent) = top level.
      current_folder: [default: "", url_key: "folder"]
    ]

  use Gettext, backend: PhoenixKitCatalogue.Gettext

  require Logger

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Modal, only: [confirm_modal: 1, modal: 1]
  import PhoenixKitWeb.Components.Core.ReorderModal, only: [reorder_modal: 1]
  import PhoenixKitWeb.Components.Core.TableDefault
  import PhoenixKitWeb.Components.Core.TableRowMenu
  import PhoenixKitWeb.Components.Core.Sortable, only: [sortable_tbody: 1, sortable_row: 1]
  import PhoenixKitWeb.Components.Core.TreeTable, only: [tree_name_cell: 1]
  import PhoenixKitCatalogue.Web.Components
  import PhoenixKitCatalogue.Web.TableToolbar

  import PhoenixKitCatalogue.Web.Helpers,
    only: [actor_opts: 1, actor_uuid: 1, log_operation_error: 3, status_label: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.PubSub
  alias PhoenixKitCatalogue.Errors
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Web.{TableConfig, TableQuery, ViewConfig}

  # PhoenixKit auto-applies its admin chrome layout to external module admin
  # views via socket.private[:live_layout]. Opt out here so this view can
  # self-wrap with LayoutWrapper.app_layout and push its title/subtitle into
  # the global admin header (same pattern as /admin/media and orders/index).
  on_mount({__MODULE__, :self_wrapped_layout})

  def on_mount(:self_wrapped_layout, _params, _session, socket) do
    {:cont, put_in(socket.private[:live_layout], {PhoenixKitWeb.Layouts, :app})}
  end

  # Hardcoded string→atom whitelist for the catalogues reorder-modal
  # strategies — NEVER String.to_existing_atom on the submitted value
  # (same rule as the detail page's items map).
  @catalogues_reorder_strategy_map %{
    "name_asc" => :name_asc,
    "name_desc" => :name_desc,
    "created_desc" => :created_desc,
    "created_asc" => :created_asc,
    "reverse" => :reverse
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: PubSub.subscribe()

    {:ok,
     assign(socket,
       page_title: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue"),
       catalogue_rows: [],
       attribute_group_rows: [],
       attribute_set_rows: [],
       sets_enabled: false,
       confirm_delete: nil,
       catalogue_view_mode: "active",
       deleted_catalogue_count: 0,
       deleted_folder_count: 0,
       folder_tree: [],
       folder_tree_deleted: [],
       folder_lookup: %{},
       expanded_folders: MapSet.new(),
       renaming_folder: nil,
       move_dialog: nil,
       folder_options: [],
       view_configs: load_view_configs(socket),
       catalogue_file_counts: %{},
       show_catalogues_reorder: false,
       show_column_modal: false,
       temp_columns: nil
     )}
  end

  # PubSub: re-load whichever tab is active when relevant data changes
  # in another LV process. Catch-all is required since the topic is
  # shared across all catalogue resources — we ignore events we don't
  # care about for the current tab.
  @impl true
  def handle_info({:catalogue_data_changed, kind, _uuid, _parent}, socket) do
    tab = socket.assigns.active_tab

    if reload_on?(tab, kind) do
      {:noreply, load_data(socket, tab)}
    else
      {:noreply, socket}
    end
  end

  # Another admin changed the shared sort for a global-sort scope (see
  # ViewConfig.global_sort?/1). Apply it to assigns only — the setting was
  # already written by the originator, and writing the per-user copy here
  # would trample this user's OTHER per-user prefs mid-render. Rows re-sort
  # at render time (derive_rows), so no data reload is needed; when the sort
  # lands on "position" the drag handles appear on the next render the same
  # way they do for the admin who switched.
  def handle_info({:catalogue_view_sort_changed, scope, sort_by, sort_dir, from}, socket) do
    cfg = socket.assigns.view_configs[scope]

    if from == self() or is_nil(cfg) do
      {:noreply, socket}
    else
      updated = %{cfg | sort_by: sort_by, sort_dir: sort_dir}

      {:noreply,
       assign(socket, :view_configs, Map.put(socket.assigns.view_configs, scope, updated))}
    end
  end

  # Backstop legacy migration, deferred off the render path by
  # maybe_auto_migrate_legacy/1 (which has already flipped the
  # once-per-process flag, so the reload below cannot loop).
  def handle_info(:auto_migrate_legacy, socket) do
    Catalogue.auto_migrate_attribute_groups()
    {:noreply, load_data(socket, :attribute_groups)}
  end

  def handle_info(msg, socket) do
    Logger.debug("CataloguesLive ignored unhandled message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # Which mutation kinds warrant a reload for each tab. :item matters to
  # the attributes tab too — assignment changes ride the :item kind and
  # move the "Items" usage counts.
  defp reload_on?(:index, kind), do: kind in [:catalogue, :item, :category, :folder]
  defp reload_on?(:attribute_groups, kind), do: kind in [:attribute_group, :attribute_set, :item]
  defp reload_on?(_tab, _kind), do: false

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # Called by UrlState after mount and on every URL state change.
  #
  # Tab identity lives in live_action (set by the router), not a URL
  # query param — the scope IS already in the URL via the route path.
  # A single ?q= is unambiguous because it always belongs to the active scope.
  # Search stays transient per tab visit: the sidebar tab links don't carry
  # ?q=, so arriving on a tab always starts from an empty search.
  #
  # `tab_changed?` keeps a search patch from re-running the tab's queries —
  # ?q= filters `catalogue_rows` / `manufacturers` / `suppliers` client-side
  # in derive_rows, so the rows themselves never need re-fetching. It is
  # sound only because the three tabs are separate routes reached with
  # `<.link navigate=…>` (PhoenixKit's tab_item), which re-mounts: prev_tab
  # is therefore nil on the one call that matters. Were they ever switched to
  # `patch`, UrlState's reload? would skip the callback entirely whenever ?q=
  # is empty on both sides, and the new tab would render the old tab's data —
  # see the round-trip tests in test/web/catalogues_live_test.exs.
  @impl true
  def handle_url_state(state, socket) do
    action = socket.assigns.live_action || :index
    prev_tab = socket.assigns[:active_tab]
    tab_changed? = action != prev_tab

    scope = active_scope(%{active_tab: action})
    cfg = Map.put(Map.fetch!(socket.assigns.view_configs, scope), :search, state.search_query)

    # The drilled folder rides the URL; thread it into the catalogues
    # cfg (in-memory only — ViewConfig.save never persists it) so every
    # existing read site (tree mode, walk, filter select) keeps working.
    cfg =
      if scope == :catalogues do
        folder = state.current_folder

        filters =
          if folder in [nil, ""],
            do: Map.delete(cfg.filters, "folder"),
            else: Map.put(cfg.filters, "folder", folder)

        %{cfg | filters: filters}
      else
        cfg
      end

    # Back can restore a ?folder= entry recorded in the ACTIVE view while
    # the deleted-view assign is still set (the deleted switch clears the
    # folder with replace, but earlier history entries keep theirs). The
    # history entry was created in active mode, so returning to it means
    # returning to active mode — otherwise the trash list is silently
    # filtered by a folder its select can't even show. (Panel finding.)
    socket =
      if scope == :catalogues and state.current_folder not in [nil, ""] and
           socket.assigns[:catalogue_view_mode] == "deleted" do
        assign(socket, :catalogue_view_mode, "active")
      else
        socket
      end

    socket =
      socket
      |> assign(:active_tab, action)
      |> assign(:page_title, tab_title(action))
      |> assign(:view_configs, Map.put(socket.assigns.view_configs, scope, cfg))

    socket =
      if tab_changed? do
        load_data(socket, action)
      else
        socket
      end

    # Expansion AFTER load_data: on a deep link the first call is also
    # the one that populates folder_lookup — expanding before it would
    # no-op and leave the ancestor chain collapsed when the user goes Up.
    maybe_expand_url_folder(socket, scope, state.current_folder)
  end

  # Maps the active UI tab to a TableConfig/ViewConfig scope.
  defp active_scope(%{assigns: a}), do: active_scope(a)
  defp active_scope(%{active_tab: :index}), do: :catalogues
  defp active_scope(%{active_tab: :attribute_groups}), do: :attribute_groups

  defp load_view_configs(socket) do
    user = socket.assigns[:phoenix_kit_current_user]

    Map.new([:catalogues, :attribute_groups], fn scope ->
      {scope, ViewConfig.load(user, scope)}
    end)
  end

  defp current_cfg(assigns), do: Map.fetch!(assigns.view_configs, active_scope(assigns))

  # Applies a columns transformation to the active scope's cfg and
  # persists it (put_cfg). Invalid/empty results fall back to defaults;
  # the active sort survives whenever it is still a sortable column —
  # "name" and "position" are managed?: false so never in `ids`, and
  # sorting doesn't require the column to be displayed.
  defp live_update_columns(socket, fun) do
    scope = active_scope(socket.assigns)
    cfg = current_cfg(socket.assigns)

    ids = TableConfig.validate_columns(scope, fun.(cfg.columns))
    ids = if ids == [], do: TableConfig.default_columns(scope), else: ids

    cfg = %{cfg | columns: ids}

    cfg =
      if MapSet.member?(known_sortable_ids(scope), cfg.sort_by),
        do: cfg,
        else: %{cfg | sort_by: List.first(ids)}

    put_cfg(socket, scope, cfg)
  end

  # Update one scope's cfg in assigns AND persist to the user row.
  #
  # `ViewConfig.save/3` writes the WHOLE `custom_fields` column (Ecto cast,
  # not a DB-level JSONB merge) from whatever `user.custom_fields` the caller
  # passes in. If we didn't refresh `phoenix_kit_current_user` with the
  # returned row, the next `put_cfg` call (any scope) would build its write
  # from the stale pre-save snapshot and silently revert this save.
  defp put_cfg(socket, scope, cfg) do
    user = socket.assigns[:phoenix_kit_current_user]
    prev = Map.fetch!(socket.assigns.view_configs, scope)

    socket =
      case ViewConfig.save(user, scope, cfg) do
        {:ok, updated_user} -> assign(socket, :phoenix_kit_current_user, updated_user)
        _ -> socket
      end

    # Global-sort scopes share their ordering: persist the new sort as a
    # module setting and tell every other open index to switch live. Keyed
    # off an actual sort change so column/filter/view edits (which also
    # travel through put_cfg) don't rewrite the setting or spam the topic.
    if ViewConfig.global_sort?(scope) and
         {cfg.sort_by, cfg.sort_dir} != {prev.sort_by, prev.sort_dir} do
      ViewConfig.save_global_sort(scope, cfg.sort_by, cfg.sort_dir)
      PubSub.broadcast_view_sort_changed(scope, cfg.sort_by, cfg.sort_dir)
    end

    assign(socket, :view_configs, Map.put(socket.assigns.view_configs, scope, cfg))
  end

  defp tab_title(:index), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogues")

  defp tab_title(:attribute_groups),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Attributes")

  defp tab_path(:index), do: Paths.index()
  defp tab_path(:attribute_groups), do: Paths.attribute_groups()

  # Graceful handler for a delete event that fires while `confirm_delete`
  # is nil (e.g. someone pushed the event without first opening the
  # modal). Clears the state, flashes a warning, and logs a warning
  # instead of crashing the LV.
  defp unexpected_confirm_event(socket, event_name) do
    Logger.warning(
      "CataloguesLive: #{event_name} fired without confirm_delete — assigns=#{inspect(socket.assigns.confirm_delete)} actor_uuid=#{inspect(actor_uuid(socket))}"
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

  defp load_data(socket, :index) do
    if connected?(socket) do
      requested = socket.assigns.catalogue_view_mode
      deleted_cat_count = Catalogue.deleted_catalogue_count()
      deleted_folder_tree = Catalogue.list_folder_tree(mode: :deleted)
      deleted_folder_count = length(deleted_folder_tree)

      # Auto-switch to active when nothing is deleted in either dimension.
      mode =
        if requested == "deleted" and deleted_cat_count == 0 and deleted_folder_count == 0,
          do: "active",
          else: requested

      active_tree = Catalogue.list_folder_tree(mode: :active)
      folder_lookup = Map.new(active_tree, fn {f, _depth} -> {f.uuid, f} end)
      item_counts = Catalogue.item_counts_by_catalogue()

      catalogues =
        if mode == "deleted" do
          Catalogue.list_catalogues(status: "deleted")
        else
          Catalogue.catalogues_by_folder() |> Map.values() |> List.flatten()
        end
        |> Catalogue.localize(socket.assigns[:current_locale])

      catalogue_rows = build_catalogue_rows(catalogues, folder_lookup, item_counts)

      socket
      |> assign(
        catalogue_rows: catalogue_rows,
        catalogue_file_counts: Catalogue.attached_file_counts(catalogue_rows),
        deleted_catalogue_count: deleted_cat_count,
        deleted_folder_count: deleted_folder_count,
        catalogue_view_mode: mode,
        folder_tree: active_tree,
        folder_tree_deleted: deleted_folder_tree,
        folder_lookup: folder_lookup,
        folder_options: folder_options(active_tree)
      )
      |> drop_stale_folder_filter(folder_lookup)
    else
      socket
    end
  end

  defp load_data(socket, :attribute_groups) do
    if connected?(socket) do
      groups =
        Catalogue.list_attribute_groups()
        |> Catalogue.localize(socket.assigns[:current_locale])

      uuids = Enum.map(groups, & &1.uuid)
      attr_counts = Catalogue.attribute_counts(uuids)
      item_counts = Catalogue.assignment_counts(uuids)

      rows =
        Enum.map(groups, fn g ->
          g
          |> Map.from_struct()
          |> Map.put(:attribute_count, Map.get(attr_counts, g.uuid, 0))
          |> Map.put(:item_count, Map.get(item_counts, g.uuid, 0))
        end)

      socket
      |> assign(:attribute_group_rows, rows)
      |> load_attribute_sets()
    else
      socket
    end
  end

  defp set_kind_label("fixed"), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Fixed value")

  defp set_kind_label(_multi),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Multiple values")

  # The SETS half of the attributes tab (2026-08-18 rework). With sets
  # live there is NO legacy UI — any remaining legacy groups are
  # auto-migrated here (backstopping the boot-time run; idempotent and
  # non-raising), then only sets render. A handful of sets on an admin
  # page, so the per-set value listing is fine.
  defp load_attribute_sets(socket) do
    if Catalogue.attribute_sets_enabled?() do
      socket = maybe_auto_migrate_legacy(socket)
      sets = Catalogue.list_attribute_sets(lang: socket.assigns[:current_locale])
      counts = Catalogue.attribute_set_attachment_counts(Enum.map(sets, & &1.uuid))

      rows =
        Enum.map(sets, fn s ->
          %{
            uuid: s.uuid,
            name: s.display_name,
            key: s.name,
            kind: Catalogue.attribute_set_kind(s),
            value_count: length(Catalogue.list_attribute_set_values(s)),
            item_count: Map.get(counts, s.uuid, 0)
          }
        end)

      assign(socket, sets_enabled: true, attribute_set_rows: rows)
    else
      assign(socket, sets_enabled: false, attribute_set_rows: [])
    end
  end

  # Once per LV process — reloads (PubSub, tab switches) don't rescan.
  # The scan runs OFF the render path via send-to-self: a large legacy
  # dataset migrating synchronously in the connected mount would blank
  # the tab past the client's connect timeout, remount, and rescan in a
  # loop (panel finding, 2026-08-19 review). The handler below reloads
  # the tab once the backstop migration has run.
  defp maybe_auto_migrate_legacy(socket) do
    if socket.assigns[:legacy_migration_ran] do
      socket
    else
      send(self(), :auto_migrate_legacy)
      assign(socket, :legacy_migration_ran, true)
    end
  end

  # Each catalogue enriched into a plain atom-key map for the flat table:
  # `:folder_name` from the lookup, `:item_count` from item_counts.
  defp build_catalogue_rows(catalogues, folder_lookup, item_counts) do
    Enum.map(catalogues, fn c ->
      folder = c.folder_uuid && folder_lookup[c.folder_uuid]

      c
      |> Map.from_struct()
      # A lookup miss means the folder is trashed — orphan-promote the row
      # so it reads as unfiled everywhere: dash in the Folder column,
      # matched by "Unfiled (root)", and no ghost entry (a nameless option
      # holding a trashed folder's uuid) in the filter dropdown.
      |> Map.put(:folder_uuid, folder && c.folder_uuid)
      |> Map.put(:folder_name, folder && folder.name)
      |> Map.put(:item_count, Map.get(item_counts, c.uuid, 0))
    end)
  end

  # Depth-indented `{value, label}` options for the "Move to folder"
  # picker — active folders only; root is the empty-string sentinel.
  defp folder_options(active_tree) do
    nested =
      Enum.map(active_tree, fn {folder, depth} ->
        {folder.uuid, String.duplicate("  ", depth) <> folder.name}
      end)

    [{"", Gettext.gettext(PhoenixKitCatalogue.Gettext, "— Root (unfiled) —")} | nested]
  end

  defp clear_folder_filter(socket) do
    cfg = Map.fetch!(socket.assigns.view_configs, :catalogues)

    if Map.has_key?(cfg.filters, "folder") do
      # In-memory clear for the current render + a replace-mode URL
      # clear so a reload doesn't resurrect the dead location.
      socket
      |> assign(
        :view_configs,
        Map.put(socket.assigns.view_configs, :catalogues, %{
          cfg
          | filters: Map.delete(cfg.filters, "folder")
        })
      )
      |> push_url_state([current_folder: ""], replace: true)
    else
      socket
    end
  end

  # A PubSub reload or empty-folder delete can leave `filters["folder"]`
  # pointing at a uuid that is no longer in the active tree — the
  # structure view then hides and the flat filter matches nothing.
  defp drop_stale_folder_filter(socket, folder_lookup) do
    folder = get_in(socket.assigns.view_configs, [:catalogues, :filters, "folder"])

    if is_binary(folder) and folder != "" and not Map.has_key?(folder_lookup, folder) do
      clear_folder_filter(socket)
    else
      socket
    end
  end

  # ── Inline catalogues folder tree ───────────────────────────────
  #
  # File-explorer view of the catalogues index: folders as collapsible
  # rows with catalogues nested under them (Core.TreeTable name cells
  # inside table_default). Shown in Manual order with no search/status
  # filter — any other sort or an active filter falls back to the flat
  # sortable table. The folder filter sets the tree's root; the
  # "Unfiled (root)" sentinel stays a flat filtered list.

  # The folder struct for the tree's current root, or nil at top level
  # (no filter / the unfiled sentinel — not in the lookup).
  defp current_tree_folder(cfg, lookup), do: lookup[cfg.filters["folder"]]

  defp catalogues_tree_mode?(cfg, view_mode, lookup) do
    cfg.view != "card" and catalogues_structure_mode?(cfg, view_mode, lookup)
  end

  # Card-view twin of the tree: same structure state, level-at-a-time grid.
  defp catalogues_card_level_mode?(cfg, view_mode, lookup) do
    cfg.view == "card" and catalogues_structure_mode?(cfg, view_mode, lookup)
  end

  defp catalogues_structure_mode?(cfg, view_mode, lookup) do
    folder_filter = cfg.filters["folder"]

    view_mode == "active" and cfg.sort_by == "position" and
      (cfg[:search] || "") == "" and Map.delete(cfg.filters, "folder") == %{} and
      (folder_filter == nil or Map.has_key?(lookup, folder_filter))
  end

  # Folder is URL state, not a persisted preference; "all"/"" and the
  # unfiled sentinel clear it (same visible behavior as before). Every
  # other filter persists through the view config as usual.
  defp apply_filter_change(socket, :catalogues, "folder", val, _cfg, _filters) do
    value = if val in [nil, "", "all"], do: "", else: val
    {:noreply, push_url_state(socket, current_folder: value)}
  end

  defp apply_filter_change(socket, scope, _id, _val, cfg, filters) do
    {:noreply, put_cfg(socket, scope, %{cfg | filters: filters})}
  end

  # URL-driven expansion: whenever ?folder= names a real folder, keep
  # its branch visibly open (tree click, select, deep link — one path).
  defp maybe_expand_url_folder(socket, :catalogues, folder)
       when is_binary(folder) and folder != "" do
    expand_folder_path(socket, folder)
  end

  defp maybe_expand_url_folder(socket, _scope, _folder), do: socket

  # Keep the branch to the drilled folder visibly open, whichever
  # control changed the filter (tree click or the select).
  defp expand_folder_path(socket, uuid) do
    case socket.assigns.folder_lookup[uuid] do
      nil ->
        socket

      folder ->
        update(socket, :expanded_folders, fn expanded ->
          MapSet.union(
            expanded,
            MapSet.new(folder_ancestor_chain(socket.assigns.folder_lookup, folder, []))
          )
        end)
    end
  end

  defp folder_ancestor_chain(_lookup, nil, acc), do: acc

  defp folder_ancestor_chain(lookup, folder, acc) do
    # Parent chains are acyclic (context cycle guard); the accumulator
    # check is a defensive stop all the same.
    if folder.uuid in acc,
      do: acc,
      else: folder_ancestor_chain(lookup, lookup[folder.parent_uuid], [folder.uuid | acc])
  end

  # Depth-first display order, skipping children of collapsed folders:
  # child folders first, then the catalogues filed at that level.
  # `catalogue_rows` are the enriched (orphan-promoted) row maps, so a
  # catalogue in a trashed folder surfaces at the root.
  defp build_catalogue_tree_rows(folder_tree, catalogue_rows, expanded, current) do
    folders = Enum.map(folder_tree, fn {f, _depth} -> f end)
    folders_by_parent = Enum.group_by(folders, & &1.parent_uuid)
    cats_by_folder = Enum.group_by(catalogue_rows, & &1[:folder_uuid])

    with_children =
      folders |> Enum.map(& &1.parent_uuid) |> Enum.reject(&is_nil/1) |> MapSet.new()

    walk_catalogue_level(
      current && current.uuid,
      0,
      folders_by_parent,
      cats_by_folder,
      with_children,
      expanded
    )
  end

  defp walk_catalogue_level(parent, depth, folders_by_parent, cats, with_children, expanded) do
    # `parent_key` identifies the sibling group for drag-reorder ("root"
    # at the top level). Both folders and the catalogues filed here share
    # this level's parent.
    parent_key = parent || "root"

    # One merged manual order per level: both types sort together by
    # `position` (drop_row writes one interleaved sequence), so a
    # catalogue dropped between two folders STAYS between them. Ties
    # (e.g. legacy per-type sequences) put folders first, then name.
    level =
      (Map.get(folders_by_parent, parent, []) |> Enum.map(&{:folder, &1})) ++
        (Map.get(cats, parent, []) |> Enum.map(&{:catalogue, &1}))

    level
    |> Enum.sort_by(fn
      {:folder, f} -> {f.position, 0, String.downcase(f.name || "")}
      {:catalogue, c} -> {c[:position], 1, String.downcase(c[:name] || "")}
    end)
    |> Enum.flat_map(fn
      {:folder, folder} ->
        count = length(Map.get(cats, folder.uuid, []))
        has_children = MapSet.member?(with_children, folder.uuid) or count > 0
        expanded? = MapSet.member?(expanded, folder.uuid)

        meta = %{expanded: expanded?, has_children: has_children, count: count}
        row = {:folder, folder, depth, meta, parent_key}

        if expanded? do
          [
            row
            | walk_catalogue_level(
                folder.uuid,
                depth + 1,
                folders_by_parent,
                cats,
                with_children,
                expanded
              )
          ]
        else
          [row]
        end

      {:catalogue, c_row} ->
        [{:catalogue, c_row, depth, parent_key}]
    end)
  end

  attr(:folder_tree, :list, required: true)
  attr(:catalogue_rows, :list, required: true)
  attr(:cfg, :map, required: true)
  attr(:current, :any, default: nil)
  attr(:renaming_folder, :any, default: nil)
  attr(:file_counts, :map, default: %{})

  # Card-view counterpart of the tree table, as GROUPS: each folder is a
  # visible box containing its catalogue cards (and nested folder boxes),
  # so the whole structure reads at a glance without drilling. Sibling
  # order is preserved by chunking — consecutive catalogue cards between
  # folder boxes render as grid runs in the interleaved manual order.
  # The same CatalogueTreeDnD hook drives drag: a folder box's own
  # surface is its "into" target (children stopPropagation their drops),
  # edges reorder among siblings, the root zone unfiles.
  defp catalogues_card_level(assigns) do
    folders = Enum.map(assigns.folder_tree, fn {f, _depth} -> f end)

    ctx = %{
      folders_by_parent: Enum.group_by(folders, & &1.parent_uuid),
      cats_by_folder: Enum.group_by(assigns.catalogue_rows, & &1[:folder_uuid]),
      cfg: assigns.cfg,
      renaming_folder: assigns.renaming_folder,
      file_counts: assigns.file_counts
    }

    root = assigns.current && assigns.current.uuid

    assigns =
      assigns
      |> assign(:ctx, ctx)
      |> assign(:entries, merged_level_entries(ctx, root))

    ~H"""
    <div class="flex items-center gap-2">
      <button
        :if={@current}
        type="button"
        phx-click="navigate_folder"
        phx-value-uuid={@current.parent_uuid || ""}
        class="btn btn-ghost btn-sm gap-1"
      >
        <.icon name="hero-arrow-uturn-left" class="w-4 h-4" />
        {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Up")}
      </button>
      <span :if={@current} class="flex items-center gap-1.5 text-sm font-medium min-w-0">
        <.icon name="hero-folder-open" class="w-4 h-4 text-warning shrink-0" />
        <span class="truncate">{@current.name}</span>
      </span>
    </div>

    <div :if={@entries == []} class="card bg-base-100 shadow">
      <div class="card-body items-center text-center py-12">
        <p class="text-base-content/60">
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No catalogues yet.")}
        </p>
      </div>
    </div>
    <div
      :if={@entries != []}
      id="catalogues-card-level"
      phx-hook="CatalogueTreeDnD"
      class="relative"
    >
      <div
        data-tree-rootzone="1"
        data-tree-drop="root"
        class="hidden absolute -top-1 left-0 right-0 z-10 rounded-lg border-2 border-dashed border-primary/50 bg-base-100 py-2.5 text-center text-sm text-base-content/60"
      >
        <.icon name="hero-arrow-up-tray" class="w-4 h-4 inline-block mr-1 align-text-bottom" />
        {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Drop here to move to root (unfiled)")}
      </div>
      <.card_entries entries={@entries} parent_key={(@current && @current.uuid) || "root"} ctx={@ctx} />
    </div>
    """
  end

  # One level's display order as {:folder, f} | {:catalogue, c} —
  # the same merged-by-position sort the tree walk uses.
  defp merged_level_entries(ctx, parent_uuid) do
    level =
      (Map.get(ctx.folders_by_parent, parent_uuid, []) |> Enum.map(&{:folder, &1})) ++
        (Map.get(ctx.cats_by_folder, parent_uuid, []) |> Enum.map(&{:catalogue, &1}))

    Enum.sort_by(level, fn
      {:folder, f} -> {f.position, 0, String.downcase(f.name || "")}
      {:catalogue, c} -> {c[:position], 1, String.downcase(c[:name] || "")}
    end)
  end

  attr(:entries, :list, required: true)
  attr(:parent_key, :string, required: true)
  attr(:ctx, :map, required: true)

  defp card_entries(assigns) do
    chunks =
      Enum.chunk_by(assigns.entries, fn
        {:folder, _} -> :folder
        {:catalogue, _} -> :catalogue
      end)

    assigns = assign(assigns, :chunks, chunks)

    ~H"""
    <div class="flex flex-col gap-4">
      <%= for chunk <- @chunks do %>
        <%= case chunk do %>
          <% [{:catalogue, _} | _] = cards -> %>
            <div class="grid gap-4 md:grid-cols-2 lg:grid-cols-3 2xl:grid-cols-4">
              <.catalogue_card
                :for={{:catalogue, c_row} <- cards}
                c_row={c_row}
                parent_key={@parent_key}
                ctx={@ctx}
              />
            </div>
          <% folder_chunk -> %>
            <.card_folder_group
              :for={{:folder, folder} <- folder_chunk}
              folder={folder}
              parent_key={@parent_key}
              ctx={@ctx}
            />
        <% end %>
      <% end %>
    </div>
    """
  end

  attr(:folder, :any, required: true)
  attr(:parent_key, :string, required: true)
  attr(:ctx, :map, required: true)

  defp card_folder_group(assigns) do
    assigns =
      assign(assigns, :children, merged_level_entries(assigns.ctx, assigns.folder.uuid))

    ~H"""
    <div
      data-tree-uuid={@folder.uuid}
      data-tree-type="folder"
      data-tree-parent={@parent_key}
      data-tree-drop={@folder.uuid}
      class="rounded-lg border border-base-300 bg-base-100 p-3"
    >
      <div class="flex items-center gap-2 min-w-0">
        <span
          data-tree-item={"folder:" <> @folder.uuid}
          class="cursor-grab active:cursor-grabbing text-base-content/40 shrink-0"
          title={
            Gettext.gettext(PhoenixKitCatalogue.Gettext, "Drag to reorder or move into a folder")
          }
        >
          <.icon name="hero-bars-3" class="w-4 h-4" />
        </span>
        <.icon name="hero-folder-open" class="w-5 h-5 text-warning shrink-0" />
        <%= if @ctx.renaming_folder == @folder.uuid do %>
          <form
            id={"card-rename-#{@folder.uuid}"}
            phx-submit="rename_folder"
            phx-value-uuid={@folder.uuid}
            class="flex-1 min-w-0"
          >
            <input
              type="text"
              name="name"
              value={@folder.name}
              phx-mounted={Phoenix.LiveView.JS.focus()}
              phx-blur="rename_folder"
              phx-value-uuid={@folder.uuid}
              class="input input-sm w-full max-w-60"
            />
          </form>
        <% else %>
          <button
            type="button"
            draggable="false"
            phx-click="navigate_folder"
            phx-value-uuid={@folder.uuid}
            class="font-medium text-left truncate cursor-pointer hover:text-primary transition-colors"
          >
            {@folder.name}
          </button>
        <% end %>
        <span class="text-xs text-base-content/40 tabular-nums">
          {length(Map.get(@ctx.cats_by_folder, @folder.uuid, []))}
        </span>
        <div class="ml-auto">
          <.table_row_menu mode="auto" id={"card-folder-menu-#{@folder.uuid}"}>
            <.table_row_menu_button
              phx-click="navigate_folder"
              phx-value-uuid={@folder.uuid}
              icon="hero-folder-open"
              label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Open")}
            />
            <.table_row_menu_button
              phx-click="start_rename_folder"
              phx-value-uuid={@folder.uuid}
              icon="hero-pencil"
              label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Rename")}
            />
            <.table_row_menu_button
              phx-click="new_subfolder"
              phx-value-uuid={@folder.uuid}
              phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Creating...")}
              icon="hero-folder-plus"
              label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "New subfolder")}
            />
            <.table_row_menu_button
              phx-click="open_move"
              phx-value-type="folder"
              phx-value-uuid={@folder.uuid}
              icon="hero-folder-arrow-down"
              label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move to folder")}
            />
            <.table_row_menu_divider />
            <.table_row_menu_button
              phx-click="show_delete_confirm"
              phx-value-uuid={@folder.uuid}
              phx-value-type="folder"
              icon="hero-trash"
              label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")}
              variant="error"
            />
          </.table_row_menu>
        </div>
      </div>
      <div
        :if={@children != []}
        class="mt-3 pl-3 border-l-2 border-warning/30"
      >
        <.card_entries entries={@children} parent_key={@folder.uuid} ctx={@ctx} />
      </div>
      <p :if={@children == []} class="mt-2 pl-8 text-xs text-base-content/40">
        {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Empty folder")}
      </p>
    </div>
    """
  end

  attr(:c_row, :map, required: true)
  attr(:parent_key, :string, required: true)
  attr(:ctx, :map, required: true)

  defp catalogue_card(assigns) do
    ~H"""
    <div
      data-tree-uuid={@c_row.uuid}
      data-tree-type="catalogue"
      data-tree-parent={@parent_key}
      class="card card-sm bg-base-200 shadow-sm"
    >
      <div class="card-body gap-2">
        <div class="flex items-center gap-2 min-w-0">
          <span
            data-tree-item={"catalogue:" <> @c_row.uuid}
            class="cursor-grab active:cursor-grabbing text-base-content/40 shrink-0"
            title={
              Gettext.gettext(PhoenixKitCatalogue.Gettext, "Drag to reorder or move into a folder")
            }
          >
            <.icon name="hero-bars-3" class="w-4 h-4" />
          </span>
          <.featured_thumb
            resource={@c_row}
            has_files={Map.get(@ctx.file_counts, @c_row.uuid, 0) > 0}
          />
          <.link
            navigate={Paths.catalogue_detail(@c_row.uuid)}
            draggable="false"
            class="link link-hover font-medium truncate flex-1 min-w-0"
          >
            {@c_row.name}
          </.link>
        </div>
        <div class="grid grid-cols-2 gap-x-4 gap-y-1 text-sm flex-1">
          <%= for col <- visible_columns(:catalogues, @ctx.cfg), col.id not in ["name", "folder"] do %>
            <div class="text-base-content/50">{col.label.()}</div>
            <div>{render_card_value(:catalogues, col.id, @c_row)}</div>
          <% end %>
        </div>
        <div class="flex justify-end">
          <.table_row_menu mode="auto" id={"card-level-cat-menu-#{@c_row.uuid}"}>
            <.table_row_menu_link
              navigate={Paths.catalogue_edit(@c_row.uuid)}
              icon="hero-pencil"
              label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit")}
            />
            <.table_row_menu_link
              navigate={Paths.catalogue_detail(@c_row.uuid)}
              icon="hero-eye"
              label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "View")}
            />
            <.table_row_menu_button
              phx-click="open_move"
              phx-value-type="catalogue"
              phx-value-uuid={@c_row.uuid}
              icon="hero-folder-arrow-down"
              label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move to folder")}
            />
            <.table_row_menu_divider />
            <.table_row_menu_button
              phx-click="trash_catalogue"
              phx-value-uuid={@c_row.uuid}
              phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Deleting...")}
              icon="hero-trash"
              label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")}
              variant="error"
            />
          </.table_row_menu>
        </div>
      </div>
    </div>
    """
  end

  attr(:view, :string, required: true)
  attr(:class, :any, default: nil)

  # Same three-way switcher table_default renders, for surfaces that
  # aren't inside a table_default (the card-level grid).
  defp catalogues_view_toggle(assigns) do
    ~H"""
    <div class={["join inline-flex", @class]}>
      <button
        type="button"
        phx-click="set_view"
        phx-value-mode="card"
        class={["btn btn-sm join-item", @view == "card" && "btn-active"]}
        title={gettext("Card view")}
      >
        <.icon name="hero-squares-2x2" class="w-4 h-4" />
      </button>
      <button
        type="button"
        phx-click="set_view"
        phx-value-mode="comfy"
        class={["btn btn-sm join-item", @view == "comfy" && "btn-active"]}
        title={gettext("Comfortable view")}
      >
        <.icon name="hero-bars-3" class="w-4 h-4" />
      </button>
      <button
        type="button"
        phx-click="set_view"
        phx-value-mode="table"
        class={["btn btn-sm join-item", @view == "table" && "btn-active"]}
        title={gettext("Compact view")}
      >
        <.icon name="hero-bars-4" class="w-4 h-4" />
      </button>
    </div>
    """
  end

  attr(:rows, :list, required: true)
  attr(:cfg, :map, required: true)
  attr(:current, :any, default: nil)
  attr(:renaming_folder, :any, default: nil)
  attr(:file_counts, :map, default: %{})

  defp catalogues_tree_table(assigns) do
    assigns =
      assign(
        assigns,
        :cols,
        for(c <- visible_columns(:catalogues, assigns.cfg), c.id not in ["name", "folder"], do: c)
      )

    catalogue_rows = for {:catalogue, c_row, _depth, _parent} <- assigns.rows, do: c_row

    assigns =
      assign(assigns, :photo_col?, any_media_thumb?(catalogue_rows, assigns.file_counts))

    ~H"""
    <%!-- Location row: Up + current folder name, only when drilled in.
         Without a sidebar this is the way back out of a folder. --%>
    <div :if={@current} class="flex items-center gap-2">
      <button
        type="button"
        phx-click="navigate_folder"
        phx-value-uuid={@current.parent_uuid || ""}
        class="btn btn-ghost btn-sm gap-1"
      >
        <.icon name="hero-arrow-uturn-left" class="w-4 h-4" />
        {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Up")}
      </button>
      <span class="flex items-center gap-1.5 text-sm font-medium min-w-0">
        <.icon name="hero-folder-open" class="w-4 h-4 text-warning shrink-0" />
        <span class="truncate">{@current.name}</span>
      </span>
    </div>

    <div :if={@rows == []} class="card bg-base-100 shadow">
      <div class="card-body items-center text-center py-12">
        <p class="text-base-content/60">
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No catalogues yet.")}
        </p>
      </div>
    </div>
    <div
      :if={@rows != []}
      id="catalogues-tree-table"
      phx-hook="CatalogueTreeDnD"
      class="relative overflow-x-auto"
    >
      <%!-- "Move to root" target — hidden until a drag starts, overlaid
           absolutely over the header area so revealing it never shifts
           the rows under the cursor mid-drag. --%>
      <div
        data-tree-rootzone="1"
        data-tree-drop="root"
        class="hidden absolute top-0 left-0 right-0 z-10 rounded-lg border-2 border-dashed border-primary/50 bg-base-100 py-2.5 text-center text-sm text-base-content/60"
      >
        <.icon name="hero-arrow-up-tray" class="w-4 h-4 inline-block mr-1 align-text-bottom" />
        {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Drop here to move to root (unfiled)")}
      </div>
      <.table_default variant="zebra" size="sm" view_mode={@cfg.view}>
        <.table_default_header>
          <.table_default_row>
            <.table_default_header_cell class="w-8"></.table_default_header_cell>
            <.table_default_header_cell
              :if={@photo_col?}
              class="w-12 !pr-0 !py-1 [.pk-comfy_&]:w-22 [.pk-comfy_&]:!py-1.5"
            >
            </.table_default_header_cell>
            <.table_default_header_cell>
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Name")}
            </.table_default_header_cell>
            <.table_default_header_cell :for={c <- @cols} class={c.align == :right && "text-right"}>
              {c.label.()}
            </.table_default_header_cell>
            <.table_default_header_cell class="text-right">
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Actions")}
            </.table_default_header_cell>
          </.table_default_row>
        </.table_default_header>
        <.table_default_body>
          <%= for row <- @rows do %>
            <%= case row do %>
              <% {:folder, folder, depth, meta, parent_key} -> %>
                <.table_default_row
                  data-tree-uuid={folder.uuid}
                  data-tree-type="folder"
                  data-tree-parent={parent_key}
                  data-tree-drop={folder.uuid}
                >
                  <td
                    data-tree-item={"folder:" <> folder.uuid}
                    class="w-8 cursor-grab active:cursor-grabbing text-base-content/40"
                    title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Drag to reorder or move into a folder")}
                  >
                    <.icon name="hero-bars-3" class="w-4 h-4" />
                  </td>
                  <.table_default_cell
                    :if={@photo_col?}
                    class="w-12 !pr-0 !py-1 [.pk-comfy_&]:w-22 [.pk-comfy_&]:!py-1.5"
                  >
                  </.table_default_cell>
                  <.tree_name_cell
                    depth={depth}
                    indent="1rem"
                    expandable={meta.has_children}
                    expanded={meta.expanded}
                    toggle_event="toggle_folder_expand"
                    value={folder.uuid}
                    icon={if meta.expanded, do: "hero-folder-open", else: "hero-folder"}
                    icon_class="w-4 h-4 text-warning shrink-0"
                    toggle_label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Toggle folder")}
                  >
                    <%= if @renaming_folder == folder.uuid do %>
                      <form
                        id={"tree-rename-#{folder.uuid}"}
                        phx-submit="rename_folder"
                        phx-value-uuid={folder.uuid}
                        class="flex-1 min-w-0"
                      >
                        <input
                          type="text"
                          name="name"
                          value={folder.name}
                          phx-mounted={Phoenix.LiveView.JS.focus()}
                          phx-blur="rename_folder"
                          phx-value-uuid={folder.uuid}
                          class="input input-sm w-full max-w-60"
                        />
                      </form>
                    <% else %>
                      <button
                        type="button"
                        draggable="false"
                        phx-click="navigate_folder"
                        phx-value-uuid={folder.uuid}
                        class="font-medium text-left truncate cursor-pointer hover:text-primary transition-colors"
                      >
                        {folder.name}
                      </button>
                    <% end %>
                  </.tree_name_cell>
                  <.table_default_cell :for={c <- @cols} class={c.align == :right && "text-right"}>
                    {render_folder_cell(c.id, folder, meta)}
                  </.table_default_cell>
                  <.table_default_cell class="text-right whitespace-nowrap">
                    <.table_row_menu mode="auto" id={"tree-folder-menu-#{folder.uuid}"}>
                      <.table_row_menu_button
                        phx-click="navigate_folder"
                        phx-value-uuid={folder.uuid}
                        icon="hero-folder-open"
                        label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Open")}
                      />
                      <.table_row_menu_button
                        phx-click="start_rename_folder"
                        phx-value-uuid={folder.uuid}
                        icon="hero-pencil"
                        label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Rename")}
                      />
                      <.table_row_menu_button
                        phx-click="new_subfolder"
                        phx-value-uuid={folder.uuid}
                        phx-disable-with={
                          Gettext.gettext(PhoenixKitCatalogue.Gettext, "Creating...")
                        }
                        icon="hero-folder-plus"
                        label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "New subfolder")}
                      />
                      <.table_row_menu_button
                        phx-click="open_move"
                        phx-value-type="folder"
                        phx-value-uuid={folder.uuid}
                        icon="hero-folder-arrow-down"
                        label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move to folder")}
                      />
                      <.table_row_menu_divider />
                      <.table_row_menu_button
                        phx-click="show_delete_confirm"
                        phx-value-uuid={folder.uuid}
                        phx-value-type="folder"
                        icon="hero-trash"
                        label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")}
                        variant="error"
                      />
                    </.table_row_menu>
                  </.table_default_cell>
                </.table_default_row>
              <% {:catalogue, c_row, depth, parent_key} -> %>
                <.table_default_row
                  data-tree-uuid={c_row.uuid}
                  data-tree-type="catalogue"
                  data-tree-parent={parent_key}
                >
                  <td
                    data-tree-item={"catalogue:" <> c_row.uuid}
                    class="w-8 cursor-grab active:cursor-grabbing text-base-content/40"
                    title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Drag to reorder or move into a folder")}
                  >
                    <.icon name="hero-bars-3" class="w-4 h-4" />
                  </td>
                  <.table_default_cell
                    :if={@photo_col?}
                    class="w-12 !pr-0 !py-1 [.pk-comfy_&]:w-22 [.pk-comfy_&]:!py-1.5"
                  >
                    <.featured_thumb
                      resource={c_row}
                      has_files={Map.get(@file_counts, c_row.uuid, 0) > 0}
                    />
                  </.table_default_cell>
                  <.tree_name_cell
                    depth={depth}
                    indent="1rem"
                    icon="hero-document-text"
                    icon_class="w-4 h-4 text-base-content/40 shrink-0"
                  >
                    <.link
                      navigate={Paths.catalogue_detail(c_row.uuid)}
                      draggable="false"
                      class="link link-hover font-medium truncate"
                    >
                      {c_row.name}
                    </.link>
                  </.tree_name_cell>
                  <.table_default_cell :for={c <- @cols} class={c.align == :right && "text-right"}>
                    {render_cell(:catalogues, c.id, c_row)}
                  </.table_default_cell>
                  <.table_default_cell class="text-right whitespace-nowrap">
                    <.table_row_menu mode="auto" id={"tree-cat-menu-#{c_row.uuid}"}>
                      <.table_row_menu_link
                        navigate={Paths.catalogue_edit(c_row.uuid)}
                        icon="hero-pencil"
                        label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit")}
                      />
                      <.table_row_menu_link
                        navigate={Paths.catalogue_detail(c_row.uuid)}
                        icon="hero-eye"
                        label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "View")}
                      />
                      <.table_row_menu_button
                        phx-click="open_move"
                        phx-value-type="catalogue"
                        phx-value-uuid={c_row.uuid}
                        icon="hero-folder-arrow-down"
                        label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move to folder")}
                      />
                      <.table_row_menu_divider />
                      <.table_row_menu_button
                        phx-click="trash_catalogue"
                        phx-value-uuid={c_row.uuid}
                        phx-disable-with={
                          Gettext.gettext(PhoenixKitCatalogue.Gettext, "Deleting...")
                        }
                        icon="hero-trash"
                        label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")}
                        variant="error"
                      />
                    </.table_row_menu>
                  </.table_default_cell>
                </.table_default_row>
            <% end %>
          <% end %>
        </.table_default_body>
      </.table_default>
    </div>

    """
  end

  attr(:tree, :list, required: true)

  # LEGACY-only: folders trashed before the folder-trash flow was
  # removed. There is no restore (folders are just titles) — the one
  # exit is Delete Forever with the old promote-contents semantics.
  # Nothing feeds this list anymore, so it retires itself once the
  # last legacy row is purged.
  defp deleted_folders_list(assigns) do
    ~H"""
    <div class="bg-base-100 border border-base-200 rounded-lg divide-y divide-base-200">
      <div :for={{folder, _depth} <- @tree} class="flex items-center gap-2 px-3 py-2 min-w-0">
        <.icon name="hero-folder" class="w-4 h-4 text-warning shrink-0" />
        <span class="flex-1 min-w-0 truncate text-sm font-medium text-base-content/50">
          {folder.name}
        </span>
        <button
          type="button"
          phx-click="show_delete_confirm"
          phx-value-uuid={folder.uuid}
          phx-value-type="legacy_folder"
          class="btn btn-ghost btn-xs text-error gap-1"
        >
          <.icon name="hero-trash" class="w-3.5 h-3.5" />
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete Forever")}
        </button>
      </div>
    </div>
    """
  end

  # Folder rows reuse the configured catalogue columns: values that make
  # sense for a folder render (count / status / updated), the rest dash.
  defp render_folder_cell("items", _folder, meta) do
    assigns = %{count: meta.count}
    ~H"<span class='text-right tabular-nums text-base-content/60'>{@count}</span>"
  end

  defp render_folder_cell("status", folder, _meta), do: status_badge_cell(folder.status)
  defp render_folder_cell("updated", folder, _meta), do: ts(folder.updated_at)

  defp render_folder_cell(_id, _folder, _meta) do
    assigns = %{}
    ~H"<span class='text-base-content/40'>—</span>"
  end

  defp default_folder_name, do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "New folder")

  # Move (no-op when the parent is unchanged) then write the level's
  # same-type order. A failed move skips the reorder — the flash carries
  # the reason (cycle, trashed target, ...).
  # "type:uuid" strings from the hook → validated tuples. Any malformed
  # entry rejects the whole payload (it is forgeable client input).
  defp parse_level_entries(entries) do
    parsed =
      Enum.map(entries, fn entry ->
        with true <- is_binary(entry),
             [type, uuid] when type in ~w(folder catalogue) <-
               String.split(entry, ":", parts: 2),
             {:ok, _} <- Ecto.UUID.cast(uuid) do
          {type, uuid}
        else
          _ -> :invalid
        end
      end)

    if :invalid in parsed, do: :error, else: {:ok, parsed}
  end

  defp apply_drop_row(socket, "catalogue", uuid, target, entries) do
    with %{} = catalogue <- Catalogue.get_catalogue(uuid),
         {:ok, _} <- Catalogue.move_catalogue_to_folder(catalogue, target, actor_opts(socket)),
         :ok <- Catalogue.place_level_rows(entries, actor_opts(socket)) do
      put_flash(socket, :info, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue moved."))
    else
      {:error, reason} ->
        put_flash(socket, :error, move_error_message(reason))

      _ ->
        put_flash(
          socket,
          :error,
          Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to move catalogue.")
        )
    end
  end

  defp apply_drop_row(socket, "folder", uuid, target, entries) do
    with %{} = folder <- Catalogue.get_folder(uuid),
         {:ok, _} <- Catalogue.move_folder(folder, target, actor_opts(socket)),
         :ok <- Catalogue.place_level_rows(entries, actor_opts(socket)) do
      put_flash(socket, :info, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Folder moved."))
    else
      {:error, reason} ->
        put_flash(socket, :error, move_error_message(reason))

      _ ->
        put_flash(
          socket,
          :error,
          Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to move folder.")
        )
    end
  end

  defp do_move_catalogue(socket, uuid, target) do
    with %{} = catalogue <- Catalogue.get_catalogue(uuid),
         {:ok, _} <- Catalogue.move_catalogue_to_folder(catalogue, target, actor_opts(socket)) do
      put_flash(socket, :info, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue moved."))
    else
      {:error, reason} ->
        put_flash(socket, :error, move_error_message(reason))

      _ ->
        put_flash(
          socket,
          :error,
          Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to move catalogue.")
        )
    end
  end

  defp do_move_folder(socket, uuid, target) do
    with %{} = folder <- Catalogue.get_folder(uuid),
         {:ok, _} <- Catalogue.move_folder(folder, target, actor_opts(socket)) do
      put_flash(socket, :info, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Folder moved."))
    else
      {:error, reason} ->
        put_flash(socket, :error, move_error_message(reason))

      _ ->
        put_flash(
          socket,
          :error,
          Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to move folder.")
        )
    end
  end

  defp move_error_message(reason)
       when reason in [:cycle, :folder_trashed, :folder_not_found, :not_empty, :not_siblings],
       do: Errors.message(reason)

  defp move_error_message(_), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to move.")

  # ── Event handlers ──────────────────────────────────────────────

  @impl true
  def handle_event("switch_catalogue_view", %{"mode" => mode}, socket)
      when mode in ~w(active deleted) do
    # Deleted view: drop the folder filter — trash is global, and a stale
    # folder filter (deleted catalogues rebuild the options from their own
    # rows) silently empties the list with the select showing "All folders".
    socket = if mode == "deleted", do: clear_folder_filter(socket), else: socket

    {:noreply,
     socket
     |> assign(:catalogue_view_mode, mode)
     |> assign(:confirm_delete, nil)
     |> assign(:renaming_folder, nil)
     |> load_data(:index)}
  end

  # ── Folder handlers ─────────────────────────────────────────────

  # `parent` comes from the toolbar button when the tree is drilled into
  # a folder — the new folder is created at the level the user is looking
  # at. Validated against the active lookup so a forged value can't
  # parent under an arbitrary/trashed uuid.
  def handle_event("new_folder", params, socket) do
    attrs =
      case params["parent"] do
        parent when is_binary(parent) and parent != "" ->
          if Map.has_key?(socket.assigns.folder_lookup, parent),
            do: %{name: default_folder_name(), parent_uuid: parent},
            else: %{name: default_folder_name()}

        _ ->
          %{name: default_folder_name()}
      end

    case Catalogue.create_folder(attrs, actor_opts(socket)) do
      {:ok, folder} ->
        {:noreply, socket |> assign(:renaming_folder, folder.uuid) |> load_data(:index)}

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to create folder.")
         )}
    end
  end

  def handle_event("new_subfolder", %{"uuid" => parent_uuid}, socket) do
    # Same lookup guard as `new_folder`: a forged uuid must not parent
    # under a missing/trashed folder.
    if Map.has_key?(socket.assigns.folder_lookup, parent_uuid) do
      case Catalogue.create_folder(
             %{name: default_folder_name(), parent_uuid: parent_uuid},
             actor_opts(socket)
           ) do
        {:ok, folder} ->
          {:noreply,
           socket
           |> assign(:renaming_folder, folder.uuid)
           |> update(:expanded_folders, &MapSet.put(&1, parent_uuid))
           |> load_data(:index)}

        {:error, _} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to create folder.")
           )}
      end
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to create folder.")
       )}
    end
  end

  def handle_event("start_rename_folder", %{"uuid" => uuid}, socket) do
    {:noreply, assign(socket, :renaming_folder, uuid)}
  end

  def handle_event("cancel_rename", _params, socket) do
    {:noreply, assign(socket, :renaming_folder, nil)}
  end

  # Commits the inline rename and closes the field. Fired by Enter
  # (form submit → "name") and by clicking off (phx-blur → "value").
  # A blank name is treated as "no change" — the folder keeps its name.
  def handle_event("rename_folder", %{"uuid" => uuid} = params, socket) do
    name = (params["name"] || params["value"] || "") |> String.trim()

    socket =
      with true <- name != "",
           %{} = folder <- Catalogue.get_folder(uuid),
           {:ok, _} <- Catalogue.update_folder(folder, %{name: name}, actor_opts(socket)) do
        socket
      else
        _ -> socket
      end

    {:noreply, socket |> assign(:renaming_folder, nil) |> load_data(:index)}
  end

  def handle_event("open_move", %{"type" => type, "uuid" => uuid}, socket)
      when type in ~w(folder catalogue) do
    target_type = if type == "folder", do: :folder, else: :catalogue
    {:noreply, assign(socket, move_dialog: {target_type, uuid})}
  end

  def handle_event("cancel_move", _params, socket) do
    {:noreply, assign(socket, :move_dialog, nil)}
  end

  def handle_event("confirm_move", %{"folder_uuid" => target}, socket) do
    target = if target == "", do: nil, else: target

    socket =
      case socket.assigns.move_dialog do
        {:catalogue, uuid} -> do_move_catalogue(socket, uuid, target)
        {:folder, uuid} -> do_move_folder(socket, uuid, target)
        _ -> socket
      end

    {:noreply, socket |> assign(:move_dialog, nil) |> load_data(:index)}
  end

  # Used by "Move to folder" row menu and the move dialog.
  # `target` is the destination folder uuid (or "root" → nil → unfiled).
  def handle_event(
        "move_to_folder",
        %{"type" => type, "uuid" => uuid, "target" => target},
        socket
      )
      when type in ~w(folder catalogue) do
    target = if target == "root", do: nil, else: target

    socket =
      case type do
        "catalogue" -> do_move_catalogue(socket, uuid, target)
        "folder" -> do_move_folder(socket, uuid, target)
      end

    {:noreply, load_data(socket, :index)}
  end

  # DnD reorder of the catalogues index (manual-order mode only — see
  # `manual_order_draggable?/2`). `ordered_ids` is exactly the rendered
  # row order (post search/filter), which `manual_order_draggable?/2`
  # guarantees is the full unfiltered set whenever handles are shown, so
  # re-indexing it into 1..N can't clash with rows outside the view.
  #
  # That guarantee is about RENDERING, so it has to be re-asserted here
  # before acting on it. A `phx-hook` event is a client message: it can be
  # pushed from a console at any time, and it can legitimately arrive late —
  # a drag begun in manual order lands after the user has typed in the search
  # box or switched to the deleted view. `reorder_catalogues/2` re-indexes
  # whatever list it is handed into 1..N with no scope check, so acting on a
  # filtered subset renumbers just those rows and collides with every row
  # outside the view. That is the duplicate-`position` corruption this
  # feature's own comments describe as how the column got into that state the
  # first time; gating only the handles would have left the same door open.
  def handle_event("open_catalogues_reorder_modal", _params, socket) do
    if socket.assigns.folder_tree == [] do
      {:noreply, assign(socket, :show_catalogues_reorder, true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_catalogues_reorder_modal", _params, socket) do
    {:noreply, assign(socket, :show_catalogues_reorder, false)}
  end

  # Strategy reorder for the whole catalogues list ("Reorder all" in manual
  # mode). Operates on the FULL loaded set — the index isn't paginated — so
  # re-indexing into 1..N can't collide with unseen rows.
  def handle_event("apply_catalogues_reorder", %{"strategy" => strategy_str}, socket)
      when is_map_key(@catalogues_reorder_strategy_map, strategy_str) do
    if socket.assigns.folder_tree != [] do
      {:noreply, socket}
    else
      strategy = Map.fetch!(@catalogues_reorder_strategy_map, strategy_str)

      ordered =
        socket.assigns.catalogue_rows
        |> order_rows_for_strategy(strategy)
        |> Enum.map(& &1.uuid)

      case Catalogue.reorder_catalogues(ordered, actor_opts(socket)) do
        :ok ->
          {:noreply,
           socket
           |> assign(:show_catalogues_reorder, false)
           |> put_flash(:info, gettext("Catalogues reordered."))
           |> load_data(:index)}

        {:error, reason} ->
          log_operation_error(socket, "apply_catalogues_reorder", %{reason: reason})
          {:noreply, put_flash(socket, :error, gettext("Failed to reorder."))}
      end
    end
  end

  def handle_event("apply_catalogues_reorder", _params, socket), do: {:noreply, socket}

  def handle_event("reorder_catalogues", %{"ordered_ids" => ordered_ids}, socket)
      when is_list(ordered_ids) do
    cfg = current_cfg(socket.assigns)

    # `reorder_catalogues` writes a global 1..N. That is only safe when
    # there are no folders — otherwise it smashes the interleaved
    # per-level order. Structure mode with an empty tree is the same
    # as a flat catalogue list.
    if manual_order_draggable?(socket.assigns.catalogue_view_mode, cfg) and
         socket.assigns.folder_tree == [] do
      case Catalogue.reorder_catalogues(ordered_ids, actor_opts(socket)) do
        :ok ->
          {:noreply, load_data(socket, :index)}

        {:error, reason} ->
          log_operation_error(socket, "reorder_catalogues", %{reason: reason})

          {:noreply, put_flash(socket, :error, gettext("Failed to save the new order."))}
      end
    else
      log_operation_error(socket, "reorder_catalogues", %{reason: :not_in_manual_order})

      {:noreply,
       socket
       |> put_flash(:error, gettext("Clear search and filters to drag-and-drop reorder."))
       |> load_data(:index)}
    end
  end

  def handle_event("trash_catalogue", %{"uuid" => uuid}, socket) do
    with %{} = catalogue <- Catalogue.get_catalogue(uuid),
         {:ok, _} <- Catalogue.trash_catalogue(catalogue, actor_opts(socket)) do
      {:noreply,
       socket
       |> put_flash(
         :info,
         Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue moved to deleted.")
       )
       |> assign(:confirm_delete, nil)
       |> load_data(:index)}
    else
      nil ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue not found.")
         )
         |> load_data(:index)}

      {:error, reason} ->
        log_operation_error(socket, "trash_catalogue", %{
          entity_type: "catalogue",
          entity_uuid: uuid,
          reason: reason
        })

        {:noreply,
         socket
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to delete catalogue.")
         )
         |> load_data(:index)}
    end
  end

  def handle_event("restore_catalogue", %{"uuid" => uuid}, socket) do
    with %{} = catalogue <- Catalogue.get_catalogue(uuid),
         {:ok, _} <- Catalogue.restore_catalogue(catalogue, actor_opts(socket)) do
      {:noreply,
       socket
       |> put_flash(:info, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue restored."))
       |> assign(:confirm_delete, nil)
       |> load_data(:index)}
    else
      nil ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue not found.")
         )
         |> load_data(:index)}

      {:error, reason} ->
        log_operation_error(socket, "restore_catalogue", %{
          entity_type: "catalogue",
          entity_uuid: uuid,
          reason: reason
        })

        {:noreply,
         socket
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to restore catalogue.")
         )
         |> load_data(:index)}
    end
  end

  def handle_event("show_delete_confirm", %{"uuid" => uuid, "type" => type}, socket) do
    {:noreply, assign(socket, confirm_delete: {type, uuid})}
  end

  def handle_event("permanently_delete_catalogue", _params, socket) do
    case socket.assigns.confirm_delete do
      {"catalogue", uuid} ->
        with %{} = catalogue <- Catalogue.get_catalogue(uuid),
             {:ok, _} <-
               Catalogue.permanently_delete_catalogue(catalogue, actor_opts(socket)) do
          {:noreply,
           socket
           |> put_flash(
             :info,
             Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue permanently deleted.")
           )
           |> assign(:confirm_delete, nil)
           |> load_data(:index)}
        else
          nil ->
            {:noreply,
             socket
             |> assign(:confirm_delete, nil)
             |> put_flash(
               :error,
               Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue not found.")
             )
             |> load_data(:index)}

          {:error, reason} ->
            log_operation_error(socket, "permanently_delete_catalogue", %{
              entity_type: "catalogue",
              entity_uuid: uuid,
              reason: reason
            })

            {:noreply,
             socket
             |> assign(:confirm_delete, nil)
             |> put_flash(
               :error,
               Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to delete catalogue.")
             )
             |> load_data(:index)}
        end

      _ ->
        unexpected_confirm_event(socket, "permanently_delete_catalogue")
    end
  end

  def handle_event("permanently_delete_folder", _params, socket) do
    case socket.assigns.confirm_delete do
      {"folder", uuid} ->
        with %{} = folder <- Catalogue.get_folder(uuid),
             {:ok, _} <- Catalogue.delete_empty_folder(folder, actor_opts(socket)) do
          {:noreply,
           socket
           |> put_flash(
             :info,
             Gettext.gettext(PhoenixKitCatalogue.Gettext, "Folder permanently deleted.")
           )
           |> assign(:confirm_delete, nil)
           |> load_data(:index)}
        else
          {:error, :not_empty} ->
            {:noreply,
             socket
             |> assign(:confirm_delete, nil)
             |> put_flash(:error, Errors.message(:not_empty))}

          _ ->
            {:noreply,
             socket
             |> assign(:confirm_delete, nil)
             |> put_flash(
               :error,
               Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to delete folder.")
             )
             |> load_data(:index)}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # Legacy escape hatch: folders trashed before the trash flow was
  # removed may be NON-empty (their catalogues orphan-display at root),
  # so their delete keeps the old promote-contents semantics. Never
  # reachable for newly-deleted folders — nothing enters the folder
  # trash anymore.
  def handle_event("permanently_delete_legacy_folder", _params, socket) do
    case socket.assigns.confirm_delete do
      {"legacy_folder", uuid} ->
        with %{} = folder <- Catalogue.get_folder(uuid),
             {:ok, _} <- Catalogue.permanently_delete_folder(folder, actor_opts(socket)) do
          {:noreply,
           socket
           |> put_flash(
             :info,
             Gettext.gettext(PhoenixKitCatalogue.Gettext, "Folder permanently deleted.")
           )
           |> assign(:confirm_delete, nil)
           |> load_data(:index)}
        else
          _ ->
            {:noreply,
             socket
             |> assign(:confirm_delete, nil)
             |> put_flash(
               :error,
               Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to delete folder.")
             )
             |> load_data(:index)}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_attribute_group", _params, socket) do
    case socket.assigns.confirm_delete do
      {"attribute_group", uuid} ->
        with %{} = group <- Catalogue.get_attribute_group(uuid),
             {:ok, _} <- Catalogue.delete_attribute_group(group, actor_opts(socket)) do
          {:noreply,
           socket
           |> put_flash(
             :info,
             Gettext.gettext(PhoenixKitCatalogue.Gettext, "Attribute group deleted.")
           )
           |> assign(:confirm_delete, nil)
           |> load_data(:attribute_groups)}
        else
          nil ->
            {:noreply, assign(socket, :confirm_delete, nil)}

          {:error, :in_use} ->
            {:noreply,
             socket
             |> put_flash(
               :error,
               Gettext.gettext(
                 PhoenixKitCatalogue.Gettext,
                 "This group is used by items — archive it instead."
               )
             )
             |> assign(:confirm_delete, nil)}

          {:error, reason} ->
            log_operation_error(socket, "delete_attribute_group", %{
              entity_type: "attribute_group",
              entity_uuid: uuid,
              reason: reason
            })

            {:noreply,
             socket
             |> put_flash(
               :error,
               Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to delete attribute group.")
             )
             |> assign(:confirm_delete, nil)}
        end

      _ ->
        unexpected_confirm_event(socket, "delete_attribute_group")
    end
  end

  def handle_event("delete_attribute_set", _params, socket) do
    case socket.assigns.confirm_delete do
      {"attribute_set", uuid} ->
        with %{} = set <- Catalogue.get_attribute_set(uuid),
             {:ok, _} <- Catalogue.delete_attribute_set(set, actor_opts(socket)) do
          {:noreply,
           socket
           |> put_flash(
             :info,
             Gettext.gettext(PhoenixKitCatalogue.Gettext, "Attribute set deleted.")
           )
           |> assign(:confirm_delete, nil)
           |> load_data(:attribute_groups)}
        else
          nil ->
            {:noreply, assign(socket, :confirm_delete, nil)}

          {:error, :set_in_use} ->
            {:noreply,
             socket
             |> put_flash(
               :error,
               Gettext.gettext(
                 PhoenixKitCatalogue.Gettext,
                 "This set is attached to items — detach it everywhere first."
               )
             )
             |> assign(:confirm_delete, nil)}

          {:error, reason} ->
            log_operation_error(socket, "delete_attribute_set", %{
              entity_type: "attribute_set",
              entity_uuid: uuid,
              reason: reason
            })

            {:noreply,
             socket
             |> put_flash(
               :error,
               Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to delete attribute set.")
             )
             |> assign(:confirm_delete, nil)}
        end

      _ ->
        unexpected_confirm_event(socket, "delete_attribute_set")
    end
  end

  # Archive / restore straight from the row menu — reversible, no confirm.
  def handle_event("set_attribute_group_status", %{"uuid" => uuid, "status" => status}, socket)
      when status in ["active", "archived"] do
    with %{} = group <- Catalogue.get_attribute_group(uuid),
         {:ok, _} <-
           Catalogue.update_attribute_group(group, %{status: status}, actor_opts(socket)) do
      {:noreply, load_data(socket, :attribute_groups)}
    else
      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to update attribute group.")
         )}
    end
  end

  # Forged/stale payloads: ignore rather than crash.
  def handle_event("set_attribute_group_status", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :confirm_delete, nil)}
  end

  # ── Column / sort / filter / view handlers ──────────────────────

  def handle_event("show_column_modal", _p, socket) do
    {:noreply, assign(socket, :show_column_modal, true)}
  end

  def handle_event("hide_column_modal", _p, socket),
    do: {:noreply, assign(socket, :show_column_modal, false)}

  # LIVE columns editor: every change applies (and persists) immediately;
  # the modal's footer is just Reset + Close.
  def handle_event("add_column", %{"column_id" => id}, socket) do
    {:noreply, live_update_columns(socket, &(&1 ++ [id]))}
  end

  def handle_event("remove_column", %{"column_id" => id}, socket) do
    {:noreply, live_update_columns(socket, &Enum.reject(&1, fn c -> c == id end))}
  end

  def handle_event("reorder_columns", params, socket) do
    case parse_order(params) do
      ids when is_list(ids) -> {:noreply, live_update_columns(socket, fn _ -> ids end)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("reset_columns", _p, socket) do
    scope = active_scope(socket.assigns)
    {:noreply, live_update_columns(socket, fn _ -> TableConfig.default_columns(scope) end)}
  end

  def handle_event("set_sort", %{"sort_by" => by}, socket) do
    scope = active_scope(socket.assigns)

    if MapSet.member?(known_sortable_ids(scope), by) do
      cfg = current_cfg(socket.assigns)

      {:noreply,
       put_cfg(socket, scope, %{cfg | sort_by: by, sort_dir: sort_dir_for(by, cfg.sort_dir)})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("flip_sort_dir", _p, socket) do
    scope = active_scope(socket.assigns)
    cfg = current_cfg(socket.assigns)
    {:noreply, put_cfg(socket, scope, %{cfg | sort_dir: flip(cfg.sort_dir)})}
  end

  def handle_event("toggle_sort", %{"by" => by}, socket) do
    scope = active_scope(socket.assigns)

    if MapSet.member?(known_sortable_ids(scope), by) do
      cfg = current_cfg(socket.assigns)
      dir = if cfg.sort_by == by, do: flip(cfg.sort_dir), else: :asc
      {:noreply, put_cfg(socket, scope, %{cfg | sort_by: by, sort_dir: sort_dir_for(by, dir)})}
    else
      {:noreply, socket}
    end
  end

  # ── Inline folder tree events ─────────────────────────────────

  def handle_event("toggle_folder_expand", %{"uuid" => uuid}, socket) do
    expanded = socket.assigns.expanded_folders

    expanded =
      if MapSet.member?(expanded, uuid),
        do: MapSet.delete(expanded, uuid),
        else: MapSet.put(expanded, uuid)

    {:noreply, assign(socket, :expanded_folders, expanded)}
  end

  # Drill: clicking a folder name re-roots the tree there by driving the
  # existing "folder" filter, so the tree, the filter select, and the
  # table stay in agreement. "" walks back up to the root.
  def handle_event("navigate_folder", %{"uuid" => uuid}, socket) do
    if uuid == "" or Map.has_key?(socket.assigns.folder_lookup, uuid) do
      {:noreply, push_url_state(socket, current_folder: uuid)}
    else
      {:noreply, socket}
    end
  end

  # Native drag-to-file (CatalogueTreeDnD hook): a row dropped onto a
  # folder row's middle, or the root zone. `target` is the destination
  # folder uuid (or "root"); do_move_* validate + flash.
  def handle_event(
        "move_to_folder",
        %{"type" => type, "uuid" => uuid, "target" => target},
        socket
      )
      when type in ~w(folder catalogue) do
    target = if target == "root", do: nil, else: target

    socket =
      case type do
        "catalogue" -> do_move_catalogue(socket, uuid, target)
        "folder" -> do_move_folder(socket, uuid, target)
      end

    {:noreply, load_data(socket, :index)}
  end

  # Edge drop anywhere in the tree: insert the dragged row at the target
  # row's level — reparent (validated: cycle/trashed guards) plus the
  # level's full MERGED order ("type:uuid" strings, folders and
  # catalogues interleaved), in one event.
  def handle_event(
        "drop_row",
        %{"type" => type, "uuid" => uuid, "parent" => parent, "entries" => entries},
        socket
      )
      when type in ~w(folder catalogue) and is_list(entries) do
    cfg = current_cfg(socket.assigns)

    target =
      cond do
        parent == "root" -> {:ok, nil}
        match?({:ok, _}, Ecto.UUID.cast(parent)) -> {:ok, parent}
        true -> :error
      end

    with {:ok, target} <- target,
         true <-
           catalogues_structure_mode?(
             cfg,
             socket.assigns.catalogue_view_mode,
             socket.assigns.folder_lookup
           ),
         {:ok, parsed} <- parse_level_entries(entries) do
      {:noreply, socket |> apply_drop_row(type, uuid, target, parsed) |> load_data(:index)}
    else
      _ -> {:noreply, socket}
    end
  end

  # Sibling reorder from the tree hook — a same-parent subset in the new
  # order; the context writes positions for just those uuids, which is
  # sufficient since ordering only ever compares siblings.
  def handle_event("reorder_folders", %{"ordered_ids" => ordered_ids}, socket)
      when is_list(ordered_ids) do
    cfg = current_cfg(socket.assigns)

    if catalogues_structure_mode?(
         cfg,
         socket.assigns.catalogue_view_mode,
         socket.assigns.folder_lookup
       ) do
      case Catalogue.reorder_folders(ordered_ids, actor_opts(socket)) do
        :ok ->
          {:noreply, load_data(socket, :index)}

        {:error, reason} ->
          log_operation_error(socket, "reorder_folders", %{reason: reason})
          {:noreply, put_flash(socket, :error, gettext("Failed to save the new order."))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("set_filter", %{"column_id" => id, "value" => val}, socket) do
    scope = active_scope(socket.assigns)

    if MapSet.member?(filterable_ids(scope), id) do
      cfg = current_cfg(socket.assigns)

      filters =
        if val in [nil, "", "all"],
          do: Map.delete(cfg.filters, id),
          else: Map.put(cfg.filters, id, val)

      apply_filter_change(socket, scope, id, val, cfg, filters)
    else
      {:noreply, socket}
    end
  end

  def handle_event("clear_filter", %{"column_id" => id}, socket) do
    scope = active_scope(socket.assigns)

    if MapSet.member?(filterable_ids(scope), id) do
      cfg = current_cfg(socket.assigns)
      {:noreply, put_cfg(socket, scope, %{cfg | filters: Map.delete(cfg.filters, id)})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("set_view", %{"mode" => v}, socket) when v in ["table", "card", "comfy"] do
    scope = active_scope(socket.assigns)
    {:noreply, put_cfg(socket, scope, %{current_cfg(socket.assigns) | view: v})}
  end

  # Transient per-scope text search — NOT persisted via put_cfg. The URL
  # carries the active scope via the route path, so a single ?q= is
  # unambiguous. UrlState calls handle_url_state which syncs q into
  # view_configs[scope].search for derive_rows.
  def handle_event("table_search", %{"query" => q}, socket) do
    {:noreply, push_url_state(socket, [search_query: q], replace: true)}
  end

  # ── View-config helpers ──────────────────────────────────────────

  # Visible columns (col maps) for a scope per the user's cfg, in order.
  # "name" is always first (it is never managed/hidden).
  defp visible_columns(scope, cfg) do
    map = TableConfig.column_map(scope)
    (["name"] ++ cfg.columns) |> Enum.uniq() |> Enum.map(&map[&1]) |> Enum.reject(&is_nil/1)
  end

  # Apply search/filter/sort to a raw list for a scope.
  defp derive_rows(rows, scope, cfg) do
    TableQuery.apply(rows, scope, %{
      search: cfg[:search] || "",
      filters: cfg.filters,
      sort_by: cfg.sort_by,
      sort_dir: cfg.sort_dir
    })
  end

  defp catalogue_reorder_strategies do
    [
      {"name_asc", gettext("A → Z by name")},
      {"name_desc", gettext("Z → A by name")},
      {"created_desc", gettext("Newest first")},
      {"created_asc", gettext("Oldest first")},
      {"reverse", gettext("Reverse current order")}
    ]
  end

  # Orders the full row set for a reorder strategy. "Reverse current order"
  # reverses the MANUAL order (position, name-tiebroken — the order the
  # strategies overwrite), not whatever transient sort the viewer has.
  defp order_rows_for_strategy(rows, :name_asc),
    do: Enum.sort_by(rows, &String.downcase(&1.name || ""))

  defp order_rows_for_strategy(rows, :name_desc),
    do: Enum.sort_by(rows, &String.downcase(&1.name || ""), :desc)

  defp order_rows_for_strategy(rows, :created_desc),
    do: Enum.sort_by(rows, & &1.inserted_at, {:desc, DateTime})

  defp order_rows_for_strategy(rows, :created_asc),
    do: Enum.sort_by(rows, & &1.inserted_at, {:asc, DateTime})

  defp order_rows_for_strategy(rows, :reverse) do
    rows
    |> Enum.sort_by(&{&1.position, String.downcase(&1.name || "")})
    |> Enum.reverse()
  end

  defp flip(:asc), do: :desc
  defp flip(_), do: :asc

  # Manual/drag order (`sort_by == "position"`) has no direction — the flip
  # button is hidden while it's active (`sort_controls/1`'s `manual_active?`
  # guard, keyed off `manual_value="position"`), so a stale `:desc` carried
  # over from whatever column was sorted before would silently invert every
  # drag with no way back to `:asc` from the UI. Force `:asc` on the way in,
  # from both `set_sort` (picking "Manual order" from the dropdown) and
  # `toggle_sort` (defensive — "position" isn't a real header, so this path
  # isn't reachable from the current UI, but the guard costs nothing).
  #
  # `def`, not `defp`, and `@doc false`: exposed purely so it's unit-tested
  # directly. `ViewConfig.save/3` needs a real `%PhoenixKit.Users.Auth.User{}`
  # in `phoenix_kit_current_user` to not raise, which the test harness can't
  # provide (see the "manual order — DnD reorder" describe block in
  # catalogues_live_test.exs) — so a `handle_event` round-trip can't drive
  # this in a LiveView test.
  @doc false
  @spec sort_dir_for(String.t(), :asc | :desc) :: :asc | :desc
  def sort_dir_for("position", _dir), do: :asc
  def sort_dir_for(_by, dir), do: dir

  # Drag handles + DnD render only for the unfiltered, unsearched "active"
  # manual-order view. `Catalogue.reorder_catalogues/2` re-indexes exactly
  # the uuids it's given into 1..N with no sibling/scope check (catalogue
  # position is a single flat sequence, unlike categories/items) — dragging
  # a filtered subset would renumber just those rows and silently clash
  # with untouched rows outside the filter. That is exactly how `position`
  # ended up with duplicate values in the first place (each folder's rows
  # renumbered independently by the old per-folder tree DnD).
  #
  # `def`/`@doc false` for the same reason as `sort_dir_for/2` above — direct
  # unit coverage instead of an unreachable LiveView round-trip.
  @doc false
  @spec manual_order_draggable?(String.t(), map()) :: boolean()
  def manual_order_draggable?(view_mode, cfg) do
    view_mode == "active" and cfg.sort_by == "position" and cfg.filters == %{} and
      (cfg[:search] || "") == ""
  end

  # SortableGrid sends "ordered_ids"/"order" (list) or "column_order" (csv).
  defp parse_order(%{"ordered_ids" => ids}) when is_list(ids), do: ids
  defp parse_order(%{"order" => ids}) when is_list(ids), do: ids

  defp parse_order(%{"column_order" => csv}) when is_binary(csv),
    do: String.split(csv, ",", trim: true)

  defp parse_order(_), do: nil

  # Guard helpers: prevent client-supplied ids from flowing into
  # String.to_existing_atom (filterable) or persisting junk sort keys.
  defp filterable_ids(scope) do
    scope
    |> TableConfig.columns()
    |> Enum.filter(& &1.filterable?)
    |> MapSet.new(& &1.id)
  end

  # "All folders" / "Unfiled (root)" / each folder, per the design doc — the
  # unfiled sentinel isn't derivable from TableQuery.enum_options/3 alone
  # since it needs a localized label, so it's prepended here.
  defp folder_filter_options(rows) do
    base = TableQuery.enum_options(rows, :catalogues, "folder")

    if Enum.any?(rows, &is_nil(&1[:folder_uuid])) do
      [
        {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Unfiled (root)"),
         TableQuery.unfiled_folder_value()}
        | base
      ]
    else
      base
    end
  end

  defp known_sortable_ids(scope) do
    scope
    |> TableConfig.columns()
    |> Enum.filter(& &1.sortable?)
    |> MapSet.new(& &1.id)
  end

  # ── Render ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={tab_title(@active_tab)}
      current_path={assigns[:url_path] || tab_path(@active_tab)}
      current_locale={assigns[:current_locale]}
    >
      <div class="flex flex-col w-full px-4 py-6 gap-6">
        <%!-- Catalogue tab content --%>
        <div :if={@active_tab == :index} class="flex flex-col gap-4">
          <% cfg = @view_configs.catalogues %>
          <.table_toolbar
            scope={:catalogues}
            cfg={cfg}
            allow_flat_reorder={@folder_tree == []}
          >
            <:view_toggle>
              <.catalogues_view_toggle view={cfg.view} />
            </:view_toggle>
            <:filters>
              <.enum_filter
                id="folder"
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Folder")}
                value={cfg.filters["folder"]}
                prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "All folders")}
                options={folder_filter_options(@catalogue_rows)}
              />
              <.enum_filter
                id="status"
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Status")}
                value={cfg.filters["status"]}
                prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "All statuses")}
                options={TableQuery.enum_options(@catalogue_rows, :catalogues, "status")}
              />
            </:filters>
            <:actions>
              <button
                :if={@catalogue_view_mode == "active"}
                type="button"
                phx-click="new_folder"
                phx-value-parent={
                  current_tree_folder(cfg, @folder_lookup) &&
                    current_tree_folder(cfg, @folder_lookup).uuid
                }
                phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Creating...")}
                class="btn btn-ghost btn-sm gap-1"
              >
                <.icon name="hero-folder-plus" class="w-4 h-4" />
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "New Folder")}
              </button>
              <.link :if={@catalogue_view_mode == "active"} navigate={Paths.catalogue_new()} class="btn btn-primary btn-sm">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "New Catalogue")}
              </.link>
            </:actions>
          </.table_toolbar>
          <% tree? = catalogues_tree_mode?(cfg, @catalogue_view_mode, @folder_lookup) %>
          <% card_level? = catalogues_card_level_mode?(cfg, @catalogue_view_mode, @folder_lookup) %>
          <p
            :if={
              @catalogue_view_mode == "active" and cfg.sort_by == "position" and
                cfg.view != "card" and not tree?
            }
            class="text-xs text-base-content/50"
          >
            {gettext("Clear search and filters to see the folder tree.")}
          </p>
          <.deleted_folders_list
            :if={@catalogue_view_mode == "deleted" and @folder_tree_deleted != []}
            tree={@folder_tree_deleted}
          />
          <%!-- Active/Deleted tabs (only when the trash holds anything).
               The view-mode toggle moved into the toolbar's view-tools
               cluster above, next to Columns — it's a filter/menu-panel
               control, not a trash-visibility one. --%>
          <div
            :if={@deleted_catalogue_count + @deleted_folder_count > 0}
            class="flex items-center gap-0.5"
          >
            <button
              type="button"
              phx-click="switch_catalogue_view"
              phx-value-mode="active"
              class={[
                "px-3 py-1.5 text-xs font-medium border-b-2 transition-colors cursor-pointer",
                if(@catalogue_view_mode == "active",
                  do: "border-primary text-primary",
                  else: "border-transparent text-base-content/50 hover:text-base-content"
                )
              ]}
            >
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Active")}
            </button>
            <button
              type="button"
              phx-click="switch_catalogue_view"
              phx-value-mode="deleted"
              class={[
                "px-3 py-1.5 text-xs font-medium border-b-2 transition-colors cursor-pointer",
                if(@catalogue_view_mode == "deleted",
                  do: "border-error text-error",
                  else: "border-transparent text-base-content/50 hover:text-base-content"
                )
              ]}
            >
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Deleted")} ({@deleted_catalogue_count +
                @deleted_folder_count})
            </button>
          </div>
          <.catalogues_tree_table
            :if={tree?}
            file_counts={@catalogue_file_counts}
            rows={
              build_catalogue_tree_rows(
                @folder_tree,
                @catalogue_rows,
                @expanded_folders,
                current_tree_folder(cfg, @folder_lookup)
              )
            }
            cfg={cfg}
            current={current_tree_folder(cfg, @folder_lookup)}
            renaming_folder={@renaming_folder}
          />
          <.catalogues_card_level
            :if={card_level?}
            folder_tree={@folder_tree}
            catalogue_rows={@catalogue_rows}
            cfg={cfg}
            current={current_tree_folder(cfg, @folder_lookup)}
            renaming_folder={@renaming_folder}
            file_counts={@catalogue_file_counts}
          />
          <.simple_table
            :if={!tree? and !card_level?}
            scope={:catalogues}
            cfg={cfg}
            show_view_toggle={false}
            file_counts={@catalogue_file_counts}
            rows={derive_rows(@catalogue_rows, :catalogues, cfg)}
            total={length(@catalogue_rows)}
            empty={Gettext.gettext(PhoenixKitCatalogue.Gettext, "No catalogues yet.")}
            draggable={manual_order_draggable?(@catalogue_view_mode, cfg)}
          >
            <:row_actions :let={c}>
              <.table_row_menu :if={@catalogue_view_mode == "active"} mode="auto" id={"cat-menu-#{c.uuid}"}>
                <%!-- Edit leads: it is what most people open this menu
                     for (product call, 2026-08-15). Entries stay neutral —
                     the daisyUI "secondary" tint made routine actions look
                     flagged; only destructive actions keep a color. --%>
                <.table_row_menu_link
                  navigate={Paths.catalogue_edit(c.uuid)}
                  icon="hero-pencil"
                  label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit")}
                />
                <.table_row_menu_link
                  navigate={Paths.catalogue_detail(c.uuid)}
                  icon="hero-eye"
                  label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "View")}
                />
                <.table_row_menu_button
                  phx-click="open_move"
                  phx-value-type="catalogue"
                  phx-value-uuid={c.uuid}
                  icon="hero-folder-arrow-down"
                  label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move to folder")}
                />
                <.table_row_menu_divider />
                <.table_row_menu_button
                  phx-click="trash_catalogue"
                  phx-value-uuid={c.uuid}
                  phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Deleting...")}
                  icon="hero-trash"
                  label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")}
                  variant="error"
                />
              </.table_row_menu>
              <.table_row_menu :if={@catalogue_view_mode == "deleted"} mode="auto" id={"cat-del-menu-#{c.uuid}"}>
                <.table_row_menu_button
                  phx-click="restore_catalogue"
                  phx-value-uuid={c.uuid}
                  phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restoring...")}
                  icon="hero-arrow-path"
                  label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restore")}
                  variant="success"
                />
                <.table_row_menu_divider />
                <.table_row_menu_button
                  phx-click="show_delete_confirm"
                  phx-value-uuid={c.uuid}
                  phx-value-type="catalogue"
                  icon="hero-trash"
                  label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete Forever")}
                  variant="error"
                />
              </.table_row_menu>
            </:row_actions>
            <:card_actions :let={c}>
              <.table_row_menu :if={@catalogue_view_mode == "active"} mode="auto" id={"card-cat-menu-#{c.uuid}"}>
                <.table_row_menu_link
                  navigate={Paths.catalogue_edit(c.uuid)}
                  icon="hero-pencil"
                  label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit")}
                />
                <.table_row_menu_link
                  navigate={Paths.catalogue_detail(c.uuid)}
                  icon="hero-eye"
                  label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "View")}
                />
                <.table_row_menu_button
                  phx-click="open_move"
                  phx-value-type="catalogue"
                  phx-value-uuid={c.uuid}
                  icon="hero-folder-arrow-down"
                  label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move to folder")}
                />
                <.table_row_menu_divider />
                <.table_row_menu_button
                  phx-click="trash_catalogue"
                  phx-value-uuid={c.uuid}
                  phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Deleting...")}
                  icon="hero-trash"
                  label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")}
                  variant="error"
                />
              </.table_row_menu>
              <.table_row_menu :if={@catalogue_view_mode == "deleted"} mode="auto" id={"card-cat-del-menu-#{c.uuid}"}>
                <.table_row_menu_button
                  phx-click="restore_catalogue"
                  phx-value-uuid={c.uuid}
                  phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restoring...")}
                  icon="hero-arrow-path"
                  label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restore")}
                  variant="success"
                />
                <.table_row_menu_divider />
                <.table_row_menu_button
                  phx-click="show_delete_confirm"
                  phx-value-uuid={c.uuid}
                  phx-value-type="catalogue"
                  icon="hero-trash"
                  label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete Forever")}
                  variant="error"
                />
              </.table_row_menu>
            </:card_actions>
          </.simple_table>

    <%!-- The CatalogueTreeDnD hook ships via js_sources/0 (prebuilt
         bundle in priv/static/assets), folded into the host LiveSocket
         at construction — a template <script> only works on hard loads
         and dies on LiveView navigation ("unknown hook found"). --%>
        </div>



      <div :if={@active_tab == :attribute_groups} class="flex flex-col gap-4">
        <%!-- SETS (2026-08-18 rework) — the primary system once entities
             is enabled. One dimension from one vendor per set; managed
             blueprints under the hood. --%>
        <div :if={@sets_enabled} class="flex flex-col gap-3">
          <div class="flex items-center justify-between gap-4">
            <div class="flex flex-col gap-0.5 min-w-0">
              <h3 class="font-semibold text-base flex items-center gap-2">
                <.icon name="hero-swatch" class="w-4 h-4 text-base-content/60" />
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Attribute sets")}
              </h3>
              <p class="text-xs text-base-content/50">
                {Gettext.gettext(
                  PhoenixKitCatalogue.Gettext,
                  "One dimension from one vendor — Ikea colors, HomeDepot trims. Items attach any number of sets."
                )}
              </p>
            </div>
            <.link navigate={Paths.attribute_set_new()} class="btn btn-primary btn-sm shrink-0">
              <.icon name="hero-plus" class="w-4 h-4" />
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "New Set")}
            </.link>
          </div>

          <p :if={@attribute_set_rows == []} class="text-sm text-base-content/60 py-4 text-center border border-dashed border-base-content/20 rounded-lg">
            {Gettext.gettext(
              PhoenixKitCatalogue.Gettext,
              "No sets yet. Create one to define the options items can attach."
            )}
          </p>

          <div :if={@attribute_set_rows != []} class="overflow-x-auto rounded-lg border border-base-content/10">
            <table class="table table-sm bg-base-100">
              <thead>
                <tr>
                  <th>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Name")}</th>
                  <th>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Kind")}</th>
                  <th class="text-right">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Values")}</th>
                  <th class="text-right">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Items")}</th>
                  <th class="w-10"></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={s <- @attribute_set_rows} class="hover">
                  <td>
                    <.link navigate={Paths.attribute_set_edit(s.uuid)} class="link link-hover font-medium">
                      {s.name}
                    </.link>
                  </td>
                  <td class="text-base-content/70">{set_kind_label(s.kind)}</td>
                  <td class="text-right tabular-nums">{s.value_count}</td>
                  <td class="text-right tabular-nums">{s.item_count}</td>
                  <td>
                    <.table_row_menu mode="auto" id={"attr-set-menu-#{s.uuid}"}>
                      <.table_row_menu_link
                        navigate={Paths.attribute_set_edit(s.uuid)}
                        icon="hero-pencil"
                        label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit")}
                      />
                      <.table_row_menu_divider />
                      <.table_row_menu_button
                        phx-click="show_delete_confirm"
                        phx-value-uuid={s.uuid}
                        phx-value-type="attribute_set"
                        icon="hero-trash"
                        label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")}
                        variant="error"
                      />
                    </.table_row_menu>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <%!-- LEGACY groups — only rendered on hosts WITHOUT the entities
             module. With sets live there is no legacy UI at all: any
             remaining groups auto-migrate on load ("it should just
             migrate", boss direction 2026-08-18) and the old rows sit
             untouched in the DB until the cutover drop migration. --%>
        <div :if={!@sets_enabled} class="flex flex-col gap-4">
        <% cfg = @view_configs.attribute_groups %>
        <.table_toolbar scope={:attribute_groups} cfg={cfg}>
          <:filters>
            <.enum_filter
              id="status"
              label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Status")}
              value={cfg.filters["status"]}
              prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "All statuses")}
              options={TableQuery.enum_options(@attribute_group_rows, :attribute_groups, "status")}
            />
          </:filters>
          <:actions>
            <.link navigate={Paths.attribute_group_new()} class="btn btn-primary btn-sm">
              <.icon name="hero-plus" class="w-4 h-4" />
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "New Attribute Group")}
            </.link>
          </:actions>
        </.table_toolbar>
        <.simple_table
          scope={:attribute_groups}
          cfg={cfg}
          rows={derive_rows(@attribute_group_rows, :attribute_groups, cfg)}
          total={length(@attribute_group_rows)}
          empty={
            Gettext.gettext(
              PhoenixKitCatalogue.Gettext,
              "No attribute groups yet. Create one to define reusable options like colors and finishes."
            )
          }
        >
          <:row_actions :let={g}>
            <.table_row_menu mode="auto" id={"attr-group-menu-#{g.uuid}"}>
              <.table_row_menu_link
                navigate={Paths.attribute_group_edit(g.uuid)}
                icon="hero-pencil"
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit")}
              />
              <.table_row_menu_button
                :if={g.status == "active"}
                phx-click="set_attribute_group_status"
                phx-value-uuid={g.uuid}
                phx-value-status="archived"
                icon="hero-archive-box"
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Archive")}
              />
              <.table_row_menu_button
                :if={g.status == "archived"}
                phx-click="set_attribute_group_status"
                phx-value-uuid={g.uuid}
                phx-value-status="active"
                icon="hero-arrow-uturn-left"
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restore")}
              />
              <.table_row_menu_divider />
              <.table_row_menu_button
                phx-click="show_delete_confirm"
                phx-value-uuid={g.uuid}
                phx-value-type="attribute_group"
                icon="hero-trash"
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")}
                variant="error"
              />
            </.table_row_menu>
          </:row_actions>
          <:card_actions :let={g}>
            <.table_row_menu mode="auto" id={"card-attr-group-menu-#{g.uuid}"}>
              <.table_row_menu_link
                navigate={Paths.attribute_group_edit(g.uuid)}
                icon="hero-pencil"
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit")}
              />
              <.table_row_menu_button
                :if={g.status == "active"}
                phx-click="set_attribute_group_status"
                phx-value-uuid={g.uuid}
                phx-value-status="archived"
                icon="hero-archive-box"
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Archive")}
              />
              <.table_row_menu_button
                :if={g.status == "archived"}
                phx-click="set_attribute_group_status"
                phx-value-uuid={g.uuid}
                phx-value-status="active"
                icon="hero-arrow-uturn-left"
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restore")}
              />
              <.table_row_menu_divider />
              <.table_row_menu_button
                phx-click="show_delete_confirm"
                phx-value-uuid={g.uuid}
                phx-value-type="attribute_group"
                icon="hero-trash"
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")}
                variant="error"
              />
            </.table_row_menu>
          </:card_actions>
        </.simple_table>
        </div>
      </div>

      <.confirm_modal
        show={match?({"attribute_set", _}, @confirm_delete)}
        on_confirm="delete_attribute_set"
        on_cancel="cancel_delete"
        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete Attribute Set")}
        title_icon="hero-trash"
        messages={[{:warning, Gettext.gettext(PhoenixKitCatalogue.Gettext, "This deletes the set and all its values. Sets attached to items cannot be deleted.")}]}
        confirm_text={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")}
        danger={true}
      />

      <.confirm_modal
        show={match?({"catalogue", _}, @confirm_delete)}
        on_confirm="permanently_delete_catalogue"
        on_cancel="cancel_delete"
        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Permanently Delete Catalogue")}
        title_icon="hero-trash"
        messages={[{:warning, Gettext.gettext(PhoenixKitCatalogue.Gettext, "This will permanently delete this catalogue, all its categories, and all items. This cannot be undone.")}]}
        confirm_text={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete Forever")}
        danger={true}
      />

      <.confirm_modal
        show={match?({"folder", _}, @confirm_delete)}
        on_confirm="permanently_delete_folder"
        on_cancel="cancel_delete"
        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Permanently Delete Folder")}
        title_icon="hero-trash"
        messages={[{:warning, Gettext.gettext(PhoenixKitCatalogue.Gettext, "This will permanently delete this folder. Only empty folders can be deleted. This cannot be undone.")}]}
        confirm_text={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete Forever")}
        danger={true}
      />

      <.confirm_modal
        show={match?({"legacy_folder", _}, @confirm_delete)}
        on_confirm="permanently_delete_legacy_folder"
        on_cancel="cancel_delete"
        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Permanently Delete Folder")}
        title_icon="hero-trash"
        messages={[{:warning, Gettext.gettext(PhoenixKitCatalogue.Gettext, "This will permanently delete this folder. Subfolders are moved to root and catalogues filed here are unfiled — neither is deleted. This cannot be undone.")}]}
        confirm_text={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete Forever")}
        danger={true}
      />

      <.confirm_modal
        show={match?({"attribute_group", _}, @confirm_delete)}
        on_confirm="delete_attribute_group"
        on_cancel="cancel_delete"
        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete Attribute Group")}
        title_icon="hero-trash"
        messages={[{:warning, Gettext.gettext(PhoenixKitCatalogue.Gettext, "This will permanently delete this group with all its attributes and values. Groups used by items cannot be deleted — archive them instead.")}]}
        confirm_text={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")}
        danger={true}
      />

      <.modal :if={@move_dialog != nil} id="move-to-folder-modal" show on_close="cancel_move">
        <form phx-submit="confirm_move" class="flex flex-col gap-4">
          <h3 class="text-lg font-semibold">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move to folder")}
          </h3>
          <p class="text-sm text-base-content/60">{move_dialog_label(@move_dialog)}</p>
          <select name="folder_uuid" class="select w-full">
            <option :for={{value, label} <- @folder_options} value={value}>{label}</option>
          </select>
          <div class="flex justify-end gap-2">
            <button type="button" phx-click="cancel_move" class="btn btn-ghost btn-sm">
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Cancel")}
            </button>
            <button type="submit" phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Moving...")} class="btn btn-primary btn-sm">
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move")}
            </button>
          </div>
        </form>
      </.modal>


      <.reorder_modal
        :if={@active_tab == :index}
        id="catalogues-reorder-modal"
        show={@show_catalogues_reorder}
        on_close="close_catalogues_reorder_modal"
        on_apply="apply_catalogues_reorder"
        selected_count={0}
        total_count={length(@catalogue_rows)}
        strategies={catalogue_reorder_strategies()}
        noun_singular={gettext("catalogue")}
        noun_plural={gettext("catalogues")}
      />
      <.column_settings_modal
        show={@show_column_modal}
        scope={active_scope(assigns)}
        selected={current_cfg(assigns).columns}
      />
      </div>

    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  defp move_dialog_label({:folder, _uuid}),
    do:
      Gettext.gettext(PhoenixKitCatalogue.Gettext, "Choose a destination folder for this folder.")

  defp move_dialog_label({:catalogue, _uuid}),
    do:
      Gettext.gettext(
        PhoenixKitCatalogue.Gettext,
        "Choose a destination folder for this catalogue."
      )

  defp move_dialog_label(_), do: ""

  # ── Toolbar private component ────────────────────────────────────

  attr(:scope, :atom, required: true)
  attr(:cfg, :map, required: true)
  attr(:allow_flat_reorder, :boolean, default: true)
  slot(:filters)
  slot(:actions)
  slot(:view_toggle)

  defp table_toolbar(assigns) do
    ~H"""
    <%!-- Two coherent groups instead of one flat flex-wrap: search+filters
         left, view tools + create actions right. A flat wrap broke lines
         between arbitrary neighbors (a stray "New Folder" alone on row 1,
         the primary action stranded bottom-left…); grouped, a narrow
         screen drops the whole right group under the left one as a unit,
         so every width renders an intentional-looking toolbar. --%>
    <div class="flex flex-wrap items-center justify-between gap-x-4 gap-y-2 mb-3">
      <div class="flex flex-wrap items-center gap-2">
        <form phx-change="table_search" phx-submit="table_search" class="contents">
          <label class="input input-sm w-full sm:w-64">
            <.icon name="hero-magnifying-glass" class="h-4 w-4 opacity-50" />
            <input
              type="search"
              name="query"
              value={@cfg[:search] || ""}
              phx-debounce="300"
              placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search...")}
              class="grow"
            />
          </label>
        </form>
        {render_slot(@filters)}
      </div>

      <div class="flex flex-wrap items-center gap-2">
        <%!-- Two wrap-as-a-unit clusters: view tools and create/folder
             actions. At widths where both can't share a row, the actions
             cluster drops to its OWN row instead of its buttons scattering
             between rows. The inner flex-wrap is the ultra-narrow fallback. --%>
        <div class="flex items-center gap-2">
          <.sort_controls
            scope={@scope}
            selected={["position", "name" | @cfg.columns]}
            sort_by={@cfg.sort_by}
            sort_dir={@cfg.sort_dir}
            manual_value="position"
          />
          <button
            :if={@scope == :catalogues and @cfg.sort_by == "position" and @allow_flat_reorder}
            type="button"
            phx-click="open_catalogues_reorder_modal"
            class="btn btn-outline btn-sm"
          >
            <.icon name="hero-arrows-up-down" class="w-4 h-4" />
            <span class="hidden sm:inline">{gettext("Reorder all")}</span>
          </button>
          <button type="button" phx-click="show_column_modal" class="btn btn-outline btn-sm">
            <.icon name="hero-adjustments-horizontal" class="w-4 h-4" />
            <span class="hidden sm:inline">
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Columns")}
            </span>
          </button>
          {render_slot(@view_toggle)}
        </div>
        <div :if={@actions != []} class="w-px h-6 bg-base-300 mx-1 hidden md:block"></div>
        <div :if={@actions != []} class="flex flex-wrap items-center gap-2 w-full md:w-auto">
          {render_slot(@actions)}
        </div>
      </div>
    </div>
    """
  end

  # ── Generic table + card view ────────────────────────────────────

  attr(:scope, :atom, required: true)
  attr(:cfg, :map, required: true)
  attr(:rows, :list, required: true)
  attr(:total, :integer, required: true)
  attr(:empty, :string, required: true)

  attr(:draggable, :boolean,
    default: false,
    doc: "Manual-order mode: render drag handles and DnD-enable the table body."
  )

  attr(:file_counts, :map, default: %{})
  attr(:show_view_toggle, :boolean, default: true)

  slot(:row_actions, required: true)
  slot(:card_actions, required: true)

  defp simple_table(assigns) do
    assigns =
      assigns
      |> assign(:cols, visible_columns(assigns.scope, assigns.cfg))
      |> assign(:reorderable?, assigns.draggable and length(assigns.rows) > 1)
      # Featured images get their own slim column (inline-left of the name
      # made rows jagged). Catalogues only — manufacturers/suppliers don't
      # carry featured images — and only when some visible row has one.
      |> then(
        &assign(
          &1,
          :photo_col?,
          &1.scope == :catalogues and any_media_thumb?(&1.rows, &1.file_counts)
        )
      )

    ~H"""
    <div :if={@rows == []} class="card bg-base-100 shadow">
      <div class="card-body items-center text-center py-12">
        <p class="text-base-content/60">
          <%= if @total > 0 do %>
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No results found.")}
          <% else %>
            {@empty}
          <% end %>
        </p>
      </div>
    </div>

    <.table_default
      :if={@rows != []}
      id={"#{@scope}-table"}
      variant="zebra"
      size="sm"
      toggleable
      show_toggle={@show_view_toggle}
      view_mode={@cfg.view}
      view_event="set_view"
      items={@rows}
      card_fields={fn row ->
        for c <- @cols, c.id != "name" do
          %{label: c.label.(), value: render_card_value(@scope, c.id, row)}
        end
      end}
    >
      <.table_default_header>
        <.table_default_row>
          <.drag_handle_header_cell :if={@draggable} />
          <.table_default_header_cell :if={@photo_col?} class="w-12 !pr-0 !py-1 [.pk-comfy_&]:w-22 [.pk-comfy_&]:!py-1.5"></.table_default_header_cell>
          <.table_default_header_cell
            :for={c <- @cols}
            class={c.align == :right && "text-right"}
          >
            <.sort_header
              :if={c.sortable?}
              by={c.id}
              label={c.label.()}
              sort_by={@cfg.sort_by}
              sort_dir={@cfg.sort_dir}
              align={c.align}
            />
            <span :if={!c.sortable?}>{c.label.()}</span>
          </.table_default_header_cell>
          <.table_default_header_cell class="text-right">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Actions")}
          </.table_default_header_cell>
        </.table_default_row>
      </.table_default_header>
      <.sortable_tbody :if={@draggable} id={"#{@scope}-table-body"} enabled={@reorderable?} event="reorder_catalogues">
        <.sortable_row :for={row <- @rows} item_id={row.uuid}>
          <.drag_handle_cell :if={@reorderable?} />
          <td :if={!@reorderable?} class="w-8"></td>
          <.table_default_cell :if={@photo_col?} class="w-12 !pr-0 !py-1 [.pk-comfy_&]:w-22 [.pk-comfy_&]:!py-1.5">
            <.featured_thumb resource={row} has_files={Map.get(@file_counts, row.uuid, 0) > 0} />
          </.table_default_cell>
          <.table_default_cell :for={c <- @cols} class={c.align == :right && "text-right"}>
            {render_cell(@scope, c.id, row)}
          </.table_default_cell>
          <.table_default_cell class="text-right whitespace-nowrap">
            {render_slot(@row_actions, row)}
          </.table_default_cell>
        </.sortable_row>
      </.sortable_tbody>
      <.table_default_body :if={!@draggable}>
        <.table_default_row :for={row <- @rows}>
          <.table_default_cell :if={@photo_col?} class="w-12 !pr-0 !py-1 [.pk-comfy_&]:w-22 [.pk-comfy_&]:!py-1.5">
            <.featured_thumb resource={row} has_files={Map.get(@file_counts, row.uuid, 0) > 0} />
          </.table_default_cell>
          <.table_default_cell :for={c <- @cols} class={c.align == :right && "text-right"}>
            {render_cell(@scope, c.id, row)}
          </.table_default_cell>
          <.table_default_cell class="text-right whitespace-nowrap">
            {render_slot(@row_actions, row)}
          </.table_default_cell>
        </.table_default_row>
      </.table_default_body>
      <:card_header :let={row}>
        <div class="flex items-center gap-2 min-w-0">
          <.featured_thumb
            :if={@scope == :catalogues}
            resource={row}
            class="w-12 h-12"
            has_files={Map.get(@file_counts, row.uuid, 0) > 0}
          />
          {render_cell(@scope, "name", row)}
        </div>
      </:card_header>
      <:card_actions :let={row}>{render_slot(@card_actions, row)}</:card_actions>
    </.table_default>
    """
  end

  # ── Sort header button ───────────────────────────────────────────

  attr(:by, :string, required: true)
  attr(:label, :string, required: true)
  attr(:sort_by, :string, required: true)
  attr(:sort_dir, :atom, required: true)
  attr(:align, :atom, default: :left)

  defp sort_header(assigns) do
    assigns = assign(assigns, :active?, assigns.sort_by == assigns.by)

    ~H"""
    <button
      type="button"
      phx-click="toggle_sort"
      phx-value-by={@by}
      class={[
        "inline-flex items-center gap-1 cursor-pointer select-none",
        @align == :right && "justify-end w-full"
      ]}
    >
      <span>{@label}</span>
      <.icon
        :if={@active?}
        name={if @sort_dir == :asc, do: "hero-chevron-up-mini", else: "hero-chevron-down-mini"}
        class="w-3.5 h-3.5"
      />
    </button>
    """
  end

  # ── Cell renderers ───────────────────────────────────────────────

  defp render_cell(:catalogues, "name", row) do
    assigns = %{row: row}

    ~H"""
    <.link :if={@row.status != "deleted"} navigate={Paths.catalogue_detail(@row.uuid)} class="link link-hover font-medium">{@row.name}</.link>
    <span :if={@row.status == "deleted"} class="font-medium text-base-content/50">{@row.name}</span>
    """
  end

  defp render_cell(:catalogues, "folder", row), do: text_or_dash(row[:folder_name])

  defp render_cell(:catalogues, "items", row) do
    assigns = %{n: row[:item_count] || 0}
    ~H"<span class='tabular-nums'>{@n}</span>"
  end

  defp render_cell(:catalogues, "kind", row), do: text_or_dash(row[:kind])
  defp render_cell(:catalogues, "markup", row), do: pct(row[:markup_percentage])
  defp render_cell(:catalogues, "discount", row), do: pct(row[:discount_percentage])
  defp render_cell(:catalogues, "created", row), do: ts(row[:inserted_at])

  defp render_cell(:attribute_groups, "name", row) do
    assigns = %{row: row}

    ~H"""
    <.link navigate={Paths.attribute_group_edit(@row.uuid)} class="link link-hover font-medium">{@row.name}</.link>
    """
  end

  defp render_cell(:attribute_groups, "attributes", row) do
    assigns = %{n: row[:attribute_count] || 0}
    ~H"<span class='tabular-nums'>{@n}</span>"
  end

  defp render_cell(:attribute_groups, "items", row) do
    assigns = %{n: row[:item_count] || 0}
    ~H"<span class='tabular-nums'>{@n}</span>"
  end

  defp render_cell(_scope, "website", row), do: website_cell(row.website)
  defp render_cell(_scope, "contact_info", row), do: text_or_dash(row.contact_info)
  defp render_cell(_scope, "status", row), do: status_badge_cell(row.status)
  defp render_cell(_scope, "updated", row), do: ts(row.updated_at)

  defp render_card_value(:catalogues, "folder", row), do: row[:folder_name] || "—"
  defp render_card_value(:catalogues, "items", row), do: to_string(row[:item_count] || 0)
  defp render_card_value(:catalogues, "kind", row), do: row[:kind] || "—"
  defp render_card_value(:catalogues, "markup", row), do: pct_str(row[:markup_percentage])
  defp render_card_value(:catalogues, "discount", row), do: pct_str(row[:discount_percentage])
  defp render_card_value(:catalogues, "created", row), do: ts_str(row[:inserted_at])

  defp render_card_value(:attribute_groups, "attributes", row),
    do: to_string(row[:attribute_count] || 0)

  defp render_card_value(:attribute_groups, "items", row), do: to_string(row[:item_count] || 0)
  defp render_card_value(_scope, "website", row), do: row.website || "—"
  defp render_card_value(_scope, "status", row), do: status_label(row.status)
  defp render_card_value(_scope, "contact_info", row), do: row.contact_info || "—"
  defp render_card_value(_scope, "updated", row), do: ts_str(row.updated_at)
  defp render_card_value(_scope, _id, _row), do: "—"

  # ── Small render helpers ─────────────────────────────────────────

  defp website_cell(nil), do: ""

  defp website_cell(url) do
    assigns = %{url: url}
    ~H"<span class='text-sm text-base-content/60'>{@url}</span>"
  end

  defp text_or_dash(nil) do
    assigns = %{}
    ~H"<span class='text-base-content/40'>—</span>"
  end

  defp text_or_dash(v) do
    assigns = %{v: v}
    ~H"<span class='text-sm'>{@v}</span>"
  end

  defp status_badge_cell(status) do
    assigns = %{status: status}
    ~H"<.status_badge status={@status} size={:sm} />"
  end

  defp ts(nil) do
    assigns = %{}
    ~H"<span class='text-base-content/40'>—</span>"
  end

  defp ts(dt) do
    assigns = %{s: ts_str(dt)}
    ~H"<span class='text-sm text-base-content/60'>{@s}</span>"
  end

  defp ts_str(nil), do: "—"
  defp ts_str(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  defp pct(nil) do
    assigns = %{}
    ~H"<span class='text-base-content/40'>—</span>"
  end

  defp pct(d) do
    assigns = %{s: pct_str(d)}
    ~H"<span class='tabular-nums'>{@s}</span>"
  end

  defp pct_str(nil), do: "—"
  defp pct_str(d), do: Decimal.to_string(d) <> "%"
end
