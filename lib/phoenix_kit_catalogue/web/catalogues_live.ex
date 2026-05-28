defmodule PhoenixKitCatalogue.Web.CataloguesLive do
  @moduledoc """
  Landing page for the Catalogue module.

  Handles three actions via tabs:
  - `:index` — list of catalogues
  - `:manufacturers` — list of manufacturers
  - `:suppliers` — list of suppliers
  """

  use Phoenix.LiveView

  require Logger

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Modal, only: [confirm_modal: 1, modal: 1]
  import PhoenixKitWeb.Components.Core.TableDefault
  import PhoenixKitWeb.Components.Core.TableRowMenu
  import PhoenixKitWeb.Components.Core.EmptyState, only: [empty_state: 1]

  import PhoenixKitCatalogue.Web.Components

  import PhoenixKitCatalogue.Web.Helpers,
    only: [actor_opts: 1, actor_uuid: 1, log_operation_error: 3, status_label: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.PubSub
  alias PhoenixKitCatalogue.Paths

  @per_page 100

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: PubSub.subscribe()

    {:ok,
     assign(socket,
       page_title: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue"),
       catalogues: [],
       item_counts: %{},
       manufacturers: [],
       suppliers: [],
       confirm_delete: nil,
       catalogue_view_mode: "active",
       deleted_catalogue_count: 0,
       deleted_folder_count: 0,
       rows: [],
       expanded_folders: MapSet.new(),
       renaming_folder: nil,
       move_dialog: nil,
       folder_options: [],
       search_query: "",
       search_results: nil,
       search_offset: 0,
       search_total: 0,
       search_has_more: false,
       search_loading: false
     )}
  end

  # PubSub: re-load whichever tab is active when relevant data changes
  # in another LV process. Catch-all is required since the topic is
  # shared across all catalogue resources — we ignore events we don't
  # care about for the current tab.
  @impl true
  def handle_info({:catalogue_data_changed, kind, _uuid, _parent}, socket) do
    cond do
      socket.assigns.active_tab == :index and kind in [:catalogue, :item, :category] ->
        {:noreply, load_data(socket, :index)}

      socket.assigns.active_tab == :manufacturers and kind in [:manufacturer, :links] ->
        {:noreply, load_data(socket, :manufacturers)}

      socket.assigns.active_tab == :suppliers and kind in [:supplier, :links] ->
        {:noreply, load_data(socket, :suppliers)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info(msg, socket) do
    Logger.debug("CataloguesLive ignored unhandled message: #{inspect(msg)}")
    {:noreply, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    action = socket.assigns.live_action || :index

    socket =
      socket
      |> assign(:active_tab, action)
      |> assign(:page_title, tab_title(action))
      |> clear_search()
      |> load_data(action)

    {:noreply, socket}
  end

  defp tab_title(:index), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogues")

  defp tab_title(:manufacturers),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Manufacturers")

  defp tab_title(:suppliers), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Suppliers")

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
      deleted_folders = Catalogue.list_folder_tree(mode: :deleted)
      deleted_folder_count = length(deleted_folders)

      # Auto-switch to active when nothing is deleted in either dimension.
      mode =
        if requested == "deleted" and deleted_cat_count == 0 and deleted_folder_count == 0,
          do: "active",
          else: requested

      rows =
        if mode == "deleted" do
          build_deleted_rows(deleted_folders, Catalogue.list_catalogues(status: "deleted"))
        else
          build_active_rows(socket.assigns.expanded_folders)
        end

      assign(socket,
        rows: rows,
        item_counts: Catalogue.item_counts_by_catalogue(),
        deleted_catalogue_count: deleted_cat_count,
        deleted_folder_count: deleted_folder_count,
        catalogue_view_mode: mode,
        folder_options: folder_options()
      )
    else
      socket
    end
  end

  defp load_data(socket, :manufacturers) do
    if connected?(socket),
      do: assign(socket, :manufacturers, Catalogue.list_manufacturers()),
      else: socket
  end

  defp load_data(socket, :suppliers) do
    if connected?(socket),
      do: assign(socket, :suppliers, Catalogue.list_suppliers()),
      else: socket
  end

  # ── Tree-row assembly ────────────────────────────────────────────
  #
  # The active view is a single flattened list of `{:folder, …}` /
  # `{:catalogue, …}` rows in depth-first display order: at each level
  # child folders come first (each recursing only when expanded), then
  # the catalogues filed at that level; the root level ends with the
  # unfiled catalogues. Orphan promotion (a child of a trashed folder, or
  # a catalogue whose folder is trashed) is already handled by the
  # context — promoted rows arrive with `parent_uuid`/folder = nil.
  defp build_active_rows(expanded) do
    folders = Catalogue.list_folder_tree(mode: :active) |> Enum.map(fn {f, _depth} -> f end)
    folders_by_parent = Enum.group_by(folders, & &1.parent_uuid)
    cats_by_folder = Catalogue.catalogues_by_folder()
    counts = Catalogue.folder_catalogue_counts()
    with_child_folders = Catalogue.folder_uuids_with_children(mode: :active)

    walk_level(nil, 0, folders_by_parent, cats_by_folder, counts, with_child_folders, expanded)
  end

  defp walk_level(parent_uuid, depth, folders_by_parent, cats, counts, with_children, expanded) do
    # `parent_key` identifies the sibling group for drag-reorder ("root"
    # at the top level). Both folders and the catalogues filed here share
    # this level's parent.
    parent_key = parent_uuid || "root"

    folder_rows =
      folders_by_parent
      |> Map.get(parent_uuid, [])
      |> Enum.flat_map(fn folder ->
        cat_count = Map.get(counts, folder.uuid, 0)
        has_children = MapSet.member?(with_children, folder.uuid) or cat_count > 0
        is_expanded = MapSet.member?(expanded, folder.uuid)

        meta = %{expanded: is_expanded, has_children: has_children, count: cat_count}
        row = {:folder, folder, depth, meta, parent_key}

        if is_expanded do
          [
            row
            | walk_level(
                folder.uuid,
                depth + 1,
                folders_by_parent,
                cats,
                counts,
                with_children,
                expanded
              )
          ]
        else
          [row]
        end
      end)

    catalogue_rows =
      cats |> Map.get(parent_uuid, []) |> Enum.map(&{:catalogue, &1, depth, parent_key})

    folder_rows ++ catalogue_rows
  end

  # Deleted view is a flat recovery list: deleted folders first, then
  # deleted catalogues. No nesting, no expand/collapse, no DnD.
  defp build_deleted_rows(deleted_folder_tree, deleted_catalogues) do
    folder_rows =
      Enum.map(deleted_folder_tree, fn {folder, _depth} ->
        {:folder, folder, 0, %{expanded: false, has_children: false, count: 0}, "root"}
      end)

    folder_rows ++ Enum.map(deleted_catalogues, &{:catalogue, &1, 0, "root"})
  end

  # Depth-indented `{value, label}` options for the "Move to folder"
  # picker — active folders only; root is the empty-string sentinel.
  defp folder_options do
    nested =
      Catalogue.list_folder_tree(mode: :active)
      |> Enum.map(fn {folder, depth} ->
        {folder.uuid, String.duplicate("  ", depth) <> folder.name}
      end)

    [{"", Gettext.gettext(PhoenixKitCatalogue.Gettext, "— Root (unfiled) —")} | nested]
  end

  defp default_folder_name, do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "New folder")

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

  defp move_error_message(:cycle),
    do:
      Gettext.gettext(
        PhoenixKitCatalogue.Gettext,
        "Can't move a folder into itself or one of its subfolders."
      )

  defp move_error_message(:folder_trashed),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "That folder is in the trash.")

  defp move_error_message(:folder_not_found),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "That folder no longer exists.")

  defp move_error_message(_), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to move.")

  # ── Event handlers ──────────────────────────────────────────────

  @impl true
  def handle_event("switch_catalogue_view", %{"mode" => mode}, socket)
      when mode in ~w(active deleted) do
    {:noreply,
     socket
     |> assign(:catalogue_view_mode, mode)
     |> assign(:confirm_delete, nil)
     |> assign(:renaming_folder, nil)
     |> load_data(:index)}
  end

  # ── Folder handlers ─────────────────────────────────────────────

  def handle_event("toggle_folder", %{"uuid" => uuid}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded_folders, uuid),
        do: MapSet.delete(socket.assigns.expanded_folders, uuid),
        else: MapSet.put(socket.assigns.expanded_folders, uuid)

    {:noreply, socket |> assign(:expanded_folders, expanded) |> load_data(:index)}
  end

  def handle_event("new_folder", _params, socket) do
    case Catalogue.create_folder(%{name: default_folder_name()}, actor_opts(socket)) do
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
    case Catalogue.create_folder(
           %{name: default_folder_name(), parent_uuid: parent_uuid},
           actor_opts(socket)
         ) do
      {:ok, folder} ->
        expanded = MapSet.put(socket.assigns.expanded_folders, parent_uuid)

        {:noreply,
         socket
         |> assign(expanded_folders: expanded, renaming_folder: folder.uuid)
         |> load_data(:index)}

      {:error, _} ->
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

  def handle_event("trash_folder", %{"uuid" => uuid}, socket) do
    with %{} = folder <- Catalogue.get_folder(uuid),
         {:ok, _} <- Catalogue.trash_folder(folder, actor_opts(socket)) do
      {:noreply,
       socket
       |> put_flash(
         :info,
         Gettext.gettext(PhoenixKitCatalogue.Gettext, "Folder moved to deleted.")
       )
       |> load_data(:index)}
    else
      _ ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to delete folder.")
         )
         |> load_data(:index)}
    end
  end

  def handle_event("restore_folder", %{"uuid" => uuid}, socket) do
    with %{} = folder <- Catalogue.get_folder(uuid),
         {:ok, _} <- Catalogue.restore_folder(folder, actor_opts(socket)) do
      {:noreply,
       socket
       |> put_flash(:info, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Folder restored."))
       |> load_data(:index)}
    else
      _ ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to restore folder.")
         )
         |> load_data(:index)}
    end
  end

  def handle_event("open_move", %{"type" => type, "uuid" => uuid}, socket)
      when type in ~w(folder catalogue) do
    target_type = if type == "folder", do: :folder, else: :catalogue
    {:noreply, assign(socket, :move_dialog, {target_type, uuid})}
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

  # Native drag-to-file (CatalogueTreeDnD hook): a row dropped onto a
  # folder row. `target` is the destination folder uuid (or "root").
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

  def handle_event("reorder_catalogues", %{"ordered_ids" => ordered_ids}, socket)
      when is_list(ordered_ids) do
    case Catalogue.reorder_catalogues(ordered_ids, actor_opts(socket)) do
      :ok ->
        {:noreply, load_data(socket, :index)}

      {:error, reason} ->
        log_operation_error(socket, "reorder_catalogues", %{reason: reason})

        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to save the new order.")
         )}
    end
  end

  def handle_event("reorder_folders", %{"ordered_ids" => ordered_ids}, socket)
      when is_list(ordered_ids) do
    case Catalogue.reorder_folders(ordered_ids, actor_opts(socket)) do
      :ok ->
        {:noreply, load_data(socket, :index)}

      {:error, reason} ->
        log_operation_error(socket, "reorder_folders", %{reason: reason})

        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to save the new order.")
         )}
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
    {:noreply, assign(socket, :confirm_delete, {type, uuid})}
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

  def handle_event("delete_manufacturer", _params, socket) do
    case socket.assigns.confirm_delete do
      {"manufacturer", uuid} ->
        with %{} = manufacturer <- Catalogue.get_manufacturer(uuid),
             {:ok, _} <- Catalogue.delete_manufacturer(manufacturer, actor_opts(socket)) do
          {:noreply,
           assign(socket, manufacturers: Catalogue.list_manufacturers(), confirm_delete: nil)}
        else
          nil ->
            {:noreply, assign(socket, :confirm_delete, nil)}

          {:error, reason} ->
            log_operation_error(socket, "delete_manufacturer", %{
              entity_type: "manufacturer",
              entity_uuid: uuid,
              reason: reason
            })

            {:noreply,
             socket
             |> put_flash(
               :error,
               Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to delete manufacturer.")
             )
             |> assign(:confirm_delete, nil)}
        end

      _ ->
        unexpected_confirm_event(socket, "delete_manufacturer")
    end
  end

  def handle_event("delete_supplier", _params, socket) do
    case socket.assigns.confirm_delete do
      {"supplier", uuid} ->
        with %{} = supplier <- Catalogue.get_supplier(uuid),
             {:ok, _} <- Catalogue.delete_supplier(supplier, actor_opts(socket)) do
          {:noreply, assign(socket, suppliers: Catalogue.list_suppliers(), confirm_delete: nil)}
        else
          nil ->
            {:noreply, assign(socket, :confirm_delete, nil)}

          {:error, reason} ->
            log_operation_error(socket, "delete_supplier", %{
              entity_type: "supplier",
              entity_uuid: uuid,
              reason: reason
            })

            {:noreply,
             socket
             |> put_flash(
               :error,
               Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to delete supplier.")
             )
             |> assign(:confirm_delete, nil)}
        end

      _ ->
        unexpected_confirm_event(socket, "delete_supplier")
    end
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :confirm_delete, nil)}
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

  def handle_event("load_more", _params, socket) do
    if socket.assigns.search_results != nil and socket.assigns.search_has_more and
         not socket.assigns.search_loading do
      {:noreply, start_search_page(socket)}
    else
      {:noreply, socket}
    end
  end

  # ── Search helpers ──────────────────────────────────────────────

  # Runs a fresh search query asynchronously. If a prior search is still
  # in flight, `start_async/3` cancels it — so fast typing (type-pause-
  # type-pause) doesn't flash stale intermediate results as each old
  # request lands out of order. The actual assign happens in
  # `handle_async(:search, ...)`, guarded by a query equality check.
  defp run_search(socket, query) do
    socket
    |> assign(search_query: query, search_loading: true)
    |> start_async(:search, fn ->
      results = Catalogue.search_items(query, limit: @per_page, offset: 0)
      total = Catalogue.count_search_items(query)
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
          "CataloguesLive search task exited unexpectedly: reason=#{inspect(other)} query=#{inspect(socket.assigns.search_query)} actor_uuid=#{inspect(actor_uuid(socket))}"
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
    if socket.assigns.search_query == query and socket.assigns.search_offset == offset do
      new_offset = offset + length(page)
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
          "CataloguesLive search_page task exited unexpectedly: reason=#{inspect(other)} query=#{inspect(socket.assigns.search_query)} offset=#{socket.assigns.search_offset} actor_uuid=#{inspect(actor_uuid(socket))}"
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

  # Global-search paging runs off-process for the same reason the
  # per-catalogue detail view does: the ILIKE-against-jsonb-as-text
  # query doesn't hit an index and can take hundreds of ms on large
  # datasets. `handle_async(:search_page, …)` guards on `{query, offset}`
  # so a superseding new search or a stale page can't double-append.
  defp start_search_page(socket) do
    %{search_query: query, search_offset: offset} = socket.assigns

    socket
    |> assign(:search_loading, true)
    |> start_async(:search_page, fn ->
      page = Catalogue.search_items(query, limit: @per_page, offset: offset)
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

  # ── Render ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-5xl px-4 py-6 gap-6">
      <%!-- Tab navigation --%>
      <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3">
        <div role="tablist" class="tabs tabs-bordered">
          <.link
            patch={Paths.index()}
            class={["tab", @active_tab == :index && "tab-active"]}
          >
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogues")}
          </.link>
          <.link
            patch={Paths.manufacturers()}
            class={["tab", @active_tab == :manufacturers && "tab-active"]}
          >
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Manufacturers")}
          </.link>
          <.link
            patch={Paths.suppliers()}
            class={["tab", @active_tab == :suppliers && "tab-active"]}
          >
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Suppliers")}
          </.link>
        </div>

        <div class="self-end sm:self-auto flex items-center gap-2">
          <button
            :if={@active_tab == :index && @catalogue_view_mode == "active"}
            type="button"
            phx-click="new_folder"
            class="btn btn-ghost btn-sm gap-1"
          >
            <.icon name="hero-folder-plus" class="w-4 h-4" />
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "New Folder")}
          </button>
          <.link :if={@active_tab == :index && @catalogue_view_mode == "active"} navigate={Paths.catalogue_new()} class="btn btn-primary btn-sm">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "New Catalogue")}
          </.link>
          <.link :if={@active_tab == :manufacturers} navigate={Paths.manufacturer_new()} class="btn btn-primary btn-sm">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "New Manufacturer")}
          </.link>
          <.link :if={@active_tab == :suppliers} navigate={Paths.supplier_new()} class="btn btn-primary btn-sm">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "New Supplier")}
          </.link>
        </div>
      </div>

      <%!-- Global search (only on catalogues tab). While a tree row is being
           dragged, the CatalogueTreeDnD hook swaps the search bar for the
           "move to root" drop target in-place, so the layout doesn't jump. --%>
      <div :if={@active_tab == :index} class="relative">
        <.search_input query={@search_query} placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search items across all catalogues...")} />
        <%!-- Overlaid on the search bar's exact box while dragging (absolute, so
             it adds no height) → the "move to root" target appears with no jump. --%>
        <div
          data-tree-rootzone="1"
          data-tree-drop="root"
          class="hidden absolute inset-0 z-10 flex items-center justify-center gap-1 rounded-lg border-2 border-dashed border-primary/50 bg-base-100 text-sm text-base-content/60"
        >
          <.icon name="hero-arrow-up-tray" class="w-4 h-4" />
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Drop here to move to root (unfiled)")}
        </div>
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

        <.empty_state :if={@search_results == [] and not @search_loading} variant="card" title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "No items match your search.")} />

        <%!-- Stale results are dimmed while a newer query is in flight to
             signal that the list is about to update. --%>
        <div :if={@search_results not in [nil, []]} class={["transition-opacity", @search_loading && "opacity-50"]}>
          <.item_table
            items={@search_results}
            columns={[:name, :sku, :base_price, :catalogue, :category, :manufacturer, :status]}
            variant="zebra"
            edit_path={&Paths.item_edit/1}
            catalogue_path={&Paths.catalogue_detail/1}
            cards={true}
            id="global-search-items"
          />
        </div>

        <%!-- Infinite-scroll sentinel for global search --%>
        <div
          :if={@search_has_more and not @search_loading}
          id="catalogues-search-load-more-sentinel"
          phx-hook="InfiniteScroll"
          data-cursor={"global-search-#{@search_offset}"}
          class="py-4"
        >
          <div class="flex justify-center">
            <span class="loading loading-spinner loading-sm text-base-content/30"></span>
          </div>
        </div>
      </div>

      <%!-- Catalogue tab content --%>
      <div :if={@active_tab == :index and is_nil(@search_results) and not @search_loading} class="flex flex-col gap-4">
        <%!-- Status sub-tabs for catalogues --%>
        <div :if={@deleted_catalogue_count > 0} class="flex items-center gap-0.5 border-b border-base-200">
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
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Deleted")} ({@deleted_catalogue_count})
          </button>
        </div>

        <.folder_tree_table
          rows={@rows}
          item_counts={@item_counts}
          view_mode={@catalogue_view_mode}
          renaming_folder={@renaming_folder}
        />
      </div>

      <div :if={@active_tab == :manufacturers and is_nil(@search_results)}>
        <.manufacturers_table manufacturers={@manufacturers} />
      </div>

      <div :if={@active_tab == :suppliers and is_nil(@search_results)}>
        <.suppliers_table suppliers={@suppliers} />
      </div>

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
        show={match?({"manufacturer", _}, @confirm_delete)}
        on_confirm="delete_manufacturer"
        on_cancel="cancel_delete"
        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete Manufacturer")}
        title_icon="hero-trash"
        messages={[{:warning, Gettext.gettext(PhoenixKitCatalogue.Gettext, "This will permanently delete this manufacturer. Items referencing it will lose the association.")}]}
        confirm_text={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")}
        danger={true}
      />

      <.confirm_modal
        show={match?({"supplier", _}, @confirm_delete)}
        on_confirm="delete_supplier"
        on_cancel="cancel_delete"
        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete Supplier")}
        title_icon="hero-trash"
        messages={[{:warning, Gettext.gettext(PhoenixKitCatalogue.Gettext, "This will permanently delete this supplier. Manufacturer links will be removed.")}]}
        confirm_text={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")}
        danger={true}
      />

      <.modal :if={@move_dialog != nil} id="move-to-folder-modal" show on_close="cancel_move">
        <form phx-submit="confirm_move" class="flex flex-col gap-4">
          <h3 class="text-lg font-semibold">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move to folder")}
          </h3>
          <p class="text-sm text-base-content/60">{move_dialog_label(@move_dialog)}</p>
          <select name="folder_uuid" class="select select-bordered w-full">
            <option :for={{value, label} <- @folder_options} value={value}>{label}</option>
          </select>
          <div class="flex justify-end gap-2">
            <button type="button" phx-click="cancel_move" class="btn btn-ghost btn-sm">
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Cancel")}
            </button>
            <button type="submit" class="btn btn-primary btn-sm">
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move")}
            </button>
          </div>
        </form>
      </.modal>
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

      // Native HTML5 DnD for the catalogue folder tree-table — one system,
      // no SortableJS, so nothing collides. Grab a row's handle, then drop:
      //   • on a folder's MIDDLE → file into that folder
      //   • on a row's TOP/BOTTOM edge → reorder among same-parent siblings
      //   • on a "move to root" zone → unfile to root
      // The context enforces the cycle / trashed-target guards server-side.
      window.PhoenixKitHooks.CatalogueTreeDnD = window.PhoenixKitHooks.CatalogueTreeDnD || {
        mounted() { this.setupTreeDnD(); },
        updated() { this.setupTreeDnD(); },
        setupTreeDnD() {
          var hook = this;

          // Drag sources: the grip handles.
          this.el.querySelectorAll("[data-tree-item]").forEach(function(handle) {
            handle.setAttribute("draggable", "true");
            handle.ondragstart = function(e) {
              var row = handle.closest("tr");
              hook._drag = row && {
                uuid: row.dataset.treeUuid,
                type: row.dataset.treeType,
                parent: row.dataset.treeParent
              };
              e.dataTransfer.setData("text/plain", handle.dataset.treeItem);
              e.dataTransfer.effectAllowed = "move";
              if (row) {
                try { e.dataTransfer.setDragImage(row, 12, 12); } catch (err) {}
                row.classList.add("opacity-50");
                hook._dragRowEl = row;
              }
              // Reveal the "move to root" target, overlaid on the search bar's
              // box (absolute → no layout shift).
              document.querySelectorAll("[data-tree-rootzone]").forEach(function(z) {
                z.classList.remove("hidden");
              });
            };
            handle.ondragend = function() { hook.endDrag(); };
          });

          // Row targets: file-into (folder middle) or reorder (top/bottom edge).
          this.el.querySelectorAll("[data-tree-uuid]").forEach(function(row) {
            row.ondragover = function(e) {
              var intent = hook.dropIntent(row, e);
              if (!intent) return;
              e.preventDefault();
              e.dataTransfer.dropEffect = "move";
              hook.showIndicator(row, intent);
            };
            row.ondragleave = function() { hook.clearRow(row); };
            row.ondrop = function(e) {
              var intent = hook.dropIntent(row, e);
              hook.clearRow(row);
              if (!intent || !hook._drag) return;
              e.preventDefault();
              var drag = hook._drag;
              if (intent === "into") {
                hook.pushEvent("move_to_folder", { type: drag.type, uuid: drag.uuid, target: row.dataset.treeDrop });
              } else {
                hook.reorder(drag, row, intent);
              }
            };
          });

          // Root drop zone lives in the search-bar slot (outside this.el),
          // so query the whole document to bind + toggle it.
          document.querySelectorAll("[data-tree-rootzone]").forEach(function(zone) {
            zone.ondragover = function(e) {
              if (!hook._drag) return;
              e.preventDefault();
              e.dataTransfer.dropEffect = "move";
              zone.classList.add("bg-primary/10");
            };
            zone.ondragleave = function() { zone.classList.remove("bg-primary/10"); };
            zone.ondrop = function(e) {
              e.preventDefault();
              zone.classList.remove("bg-primary/10");
              if (hook._drag) {
                hook.pushEvent("move_to_folder", { type: hook._drag.type, uuid: hook._drag.uuid, target: "root" });
              }
            };
          });
        },

        // "into" | "before" | "after" | null for the pointer over `row`.
        dropIntent(row, e) {
          var drag = this._drag;
          if (!drag || drag.uuid === row.dataset.treeUuid) return null;
          var rect = row.getBoundingClientRect();
          var ratio = (e.clientY - rect.top) / rect.height;
          var isFolder = row.hasAttribute("data-tree-drop");
          if (isFolder && ratio > 0.25 && ratio < 0.75) return "into";
          if (drag.parent === row.dataset.treeParent && drag.type === row.dataset.treeType) {
            return ratio < 0.5 ? "before" : "after";
          }
          // Over a folder but not a sibling → fall back to filing into it.
          return isFolder ? "into" : null;
        },

        reorder(drag, row, intent) {
          // Same-parent, same-type siblings in current DOM order.
          var order = [];
          this.el.querySelectorAll("[data-tree-uuid]").forEach(function(r) {
            if (r.dataset.treeParent === drag.parent &&
                r.dataset.treeType === drag.type &&
                r.dataset.treeUuid !== drag.uuid) {
              order.push(r.dataset.treeUuid);
            }
          });
          var idx = order.indexOf(row.dataset.treeUuid);
          if (idx < 0) return;
          order.splice(intent === "before" ? idx : idx + 1, 0, drag.uuid);
          this.pushEvent(drag.type === "folder" ? "reorder_folders" : "reorder_catalogues", { ordered_ids: order });
        },

        showIndicator(row, intent) {
          this.clearAll();
          if (intent === "into") {
            // Inline style (not a class) so the highlight wins over the
            // table-zebra row background, which otherwise hides it.
            row.style.backgroundColor = "rgba(59, 130, 246, 0.18)";
          } else {
            row.style.boxShadow = intent === "before"
              ? "inset 0 3px 0 0 rgb(59 130 246)"
              : "inset 0 -3px 0 0 rgb(59 130 246)";
          }
        },

        clearRow(row) {
          row.style.backgroundColor = "";
          row.style.boxShadow = "";
        },

        clearAll() {
          var self = this;
          this.el.querySelectorAll("[data-tree-uuid]").forEach(function(r) { self.clearRow(r); });
        },

        endDrag() {
          if (this._dragRowEl) { this._dragRowEl.classList.remove("opacity-50"); this._dragRowEl = null; }
          this._drag = null;
          document.querySelectorAll("[data-tree-rootzone]").forEach(function(z) {
            z.classList.add("hidden");
            z.classList.remove("bg-primary/10");
          });
          this.clearAll();
        }
      };
    </script>
    """
  end

  defp folder_tree_table(assigns) do
    ~H"""
    <div :if={@rows == []} class="card bg-base-100 shadow">
      <div class="card-body items-center text-center py-12">
        <p class="text-base-content/60">
          {if @view_mode == "deleted", do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Nothing in the trash."), else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "No catalogues yet.")}
        </p>
      </div>
    </div>

    <div :if={@rows != []} id={"cat-tree-#{@view_mode}"} phx-hook="CatalogueTreeDnD" class="overflow-x-auto">
      <table class="table table-zebra table-sm">
        <thead>
          <tr>
            <th :if={@view_mode == "active"} class="w-8"></th>
            <th>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Name")}</th>
            <th class="text-right">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Items")}</th>
            <th>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Status")}</th>
            <th>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Updated")}</th>
            <th class="text-right whitespace-nowrap">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Actions")}</th>
          </tr>
        </thead>
        <tbody>
          <%= for row <- @rows do %>
            <%= case row do %>
              <% {:folder, folder, depth, meta, parent_key} -> %>
                <tr
                  class={["group/row hover"]}
                  data-tree-uuid={@view_mode == "active" && folder.uuid}
                  data-tree-type={@view_mode == "active" && "folder"}
                  data-tree-parent={@view_mode == "active" && parent_key}
                  data-tree-drop={@view_mode == "active" && folder.uuid}
                >
                  <td
                    :if={@view_mode == "active"}
                    data-tree-item={"folder:" <> folder.uuid}
                    class="w-8 pk-tree-handle cursor-grab active:cursor-grabbing text-base-content/40 opacity-0 group-hover/row:opacity-100 transition-opacity"
                    title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Drag to move into a folder")}
                  >
                    <.icon name="hero-bars-3" class="w-4 h-4" />
                  </td>
                  <td>
                    <div class="flex items-center gap-1.5" style={"padding-left: #{depth * 1.5}rem"}>
                      <button
                        :if={meta.has_children}
                        type="button"
                        phx-click="toggle_folder"
                        phx-value-uuid={folder.uuid}
                        class="btn btn-ghost btn-xs p-0 min-h-0 h-5 w-5"
                        aria-label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Toggle folder")}
                      >
                        <.icon name={if meta.expanded, do: "hero-chevron-down-mini", else: "hero-chevron-right-mini"} class="w-4 h-4 text-base-content/50" />
                      </button>
                      <span :if={not meta.has_children} class="w-5"></span>
                      <.icon name="hero-folder" class="w-4 h-4 text-warning shrink-0" />
                      <%= cond do %>
                        <% @renaming_folder == folder.uuid -> %>
                          <form phx-submit="rename_folder" phx-value-uuid={folder.uuid}>
                            <input
                              type="text"
                              name="name"
                              value={folder.name}
                              phx-mounted={Phoenix.LiveView.JS.focus()}
                              phx-blur="rename_folder"
                              phx-value-uuid={folder.uuid}
                              class="input input-bordered input-xs"
                            />
                          </form>
                        <% @view_mode == "active" -> %>
                          <button
                            type="button"
                            phx-click="start_rename_folder"
                            phx-value-uuid={folder.uuid}
                            class="font-medium text-left cursor-pointer hover:underline decoration-dotted underline-offset-2"
                            title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Click to rename")}
                          >
                            {folder.name}
                          </button>
                        <% true -> %>
                          <span class="font-medium text-base-content/50">{folder.name}</span>
                      <% end %>
                    </div>
                  </td>
                  <td class="text-right tabular-nums text-base-content/60">{meta.count}</td>
                  <td><.status_badge status={folder.status} size={:sm} /></td>
                  <td class="text-sm text-base-content/60">{Calendar.strftime(folder.updated_at, "%Y-%m-%d %H:%M")}</td>
                  <td class="text-right whitespace-nowrap">
                    <.table_row_menu :if={@view_mode == "active"} mode="auto" id={"folder-menu-#{folder.uuid}"}>
                      <.table_row_menu_button phx-click="new_subfolder" phx-value-uuid={folder.uuid} icon="hero-folder-plus" label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "New subfolder")} />
                      <.table_row_menu_button phx-click="start_rename_folder" phx-value-uuid={folder.uuid} icon="hero-pencil" label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Rename")} variant="secondary" />
                      <.table_row_menu_button phx-click="open_move" phx-value-type="folder" phx-value-uuid={folder.uuid} icon="hero-folder-arrow-down" label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move to folder")} variant="secondary" />
                      <.table_row_menu_divider />
                      <.table_row_menu_button phx-click="trash_folder" phx-value-uuid={folder.uuid} icon="hero-trash" label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")} variant="error" />
                    </.table_row_menu>
                    <.table_row_menu :if={@view_mode == "deleted"} mode="auto" id={"folder-del-menu-#{folder.uuid}"}>
                      <.table_row_menu_button phx-click="restore_folder" phx-value-uuid={folder.uuid} icon="hero-arrow-path" label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restore")} variant="success" />
                    </.table_row_menu>
                  </td>
                </tr>
              <% {:catalogue, catalogue, depth, parent_key} -> %>
                <tr
                  class={["group/row hover"]}
                  data-tree-uuid={@view_mode == "active" && catalogue.uuid}
                  data-tree-type={@view_mode == "active" && "catalogue"}
                  data-tree-parent={@view_mode == "active" && parent_key}
                >
                  <td
                    :if={@view_mode == "active"}
                    data-tree-item={"catalogue:" <> catalogue.uuid}
                    class="w-8 pk-tree-handle cursor-grab active:cursor-grabbing text-base-content/40 opacity-0 group-hover/row:opacity-100 transition-opacity"
                    title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Drag to move into a folder")}
                  >
                    <.icon name="hero-bars-3" class="w-4 h-4" />
                  </td>
                  <td>
                    <div class="flex items-center gap-1.5" style={"padding-left: #{depth * 1.5 + 1.5}rem"}>
                      <.icon name="hero-document-text" class="w-4 h-4 text-base-content/40 shrink-0" />
                      <.link :if={@view_mode == "active"} navigate={Paths.catalogue_detail(catalogue.uuid)} class="link link-hover font-medium">
                        {catalogue.name}
                      </.link>
                      <span :if={@view_mode == "deleted"} class="font-medium text-base-content/50">{catalogue.name}</span>
                    </div>
                  </td>
                  <td class="text-right tabular-nums">{Map.get(@item_counts, catalogue.uuid, 0)}</td>
                  <td><.status_badge status={catalogue.status} size={:sm} /></td>
                  <td class="text-sm text-base-content/60">{Calendar.strftime(catalogue.updated_at, "%Y-%m-%d %H:%M")}</td>
                  <td class="text-right whitespace-nowrap">
                    <.table_row_menu :if={@view_mode == "active"} mode="auto" id={"cat-menu-#{catalogue.uuid}"}>
                      <.table_row_menu_link navigate={Paths.catalogue_detail(catalogue.uuid)} icon="hero-eye" label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "View")} />
                      <.table_row_menu_link navigate={Paths.catalogue_edit(catalogue.uuid)} icon="hero-pencil" label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit")} variant="secondary" />
                      <.table_row_menu_button phx-click="open_move" phx-value-type="catalogue" phx-value-uuid={catalogue.uuid} icon="hero-folder-arrow-down" label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move to folder")} variant="secondary" />
                      <.table_row_menu_divider />
                      <.table_row_menu_button phx-click="trash_catalogue" phx-value-uuid={catalogue.uuid} phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Deleting...")} icon="hero-trash" label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")} variant="error" />
                    </.table_row_menu>
                    <.table_row_menu :if={@view_mode == "deleted"} mode="auto" id={"cat-del-menu-#{catalogue.uuid}"}>
                      <.table_row_menu_button phx-click="restore_catalogue" phx-value-uuid={catalogue.uuid} phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restoring...")} icon="hero-arrow-path" label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restore")} variant="success" />
                      <.table_row_menu_divider />
                      <.table_row_menu_button phx-click="show_delete_confirm" phx-value-uuid={catalogue.uuid} phx-value-type="catalogue" icon="hero-trash" label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete Forever")} variant="error" />
                    </.table_row_menu>
                  </td>
                </tr>
            <% end %>
          <% end %>
        </tbody>
      </table>
      <%!-- "Move to root" target below the list (revealed only while dragging).
           Below the table, so appearing here doesn't shift the rows above. --%>
      <div
        :if={@view_mode == "active"}
        data-tree-rootzone="1"
        data-tree-drop="root"
        class="hidden mt-2 rounded-lg border-2 border-dashed border-primary/50 py-3 text-center text-sm text-base-content/60"
      >
        <.icon name="hero-arrow-up-tray" class="w-4 h-4 inline-block mr-1 align-text-bottom" />
        {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Drop here to move to root (unfiled)")}
      </div>
    </div>
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

  defp manufacturers_table(assigns) do
    ~H"""
    <div :if={@manufacturers == []} class="card bg-base-100 shadow">
      <div class="card-body items-center text-center py-12">
        <p class="text-base-content/60">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "No manufacturers yet.")}</p>
      </div>
    </div>

    <div :if={@manufacturers != []}>
      <.table_default
        variant="zebra" size="sm" toggleable={true}
        id="manufacturers-list" items={@manufacturers}
        card_fields={fn m -> [
          %{label: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Website"), value: m.website || "—"},
          %{label: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Status"), value: status_label(m.status)}
        ] end}
      >
        <.table_default_header>
          <.table_default_row>
            <.table_default_header_cell>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Name")}</.table_default_header_cell>
            <.table_default_header_cell>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Website")}</.table_default_header_cell>
            <.table_default_header_cell>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Status")}</.table_default_header_cell>
            <.table_default_header_cell class="text-right whitespace-nowrap">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Actions")}</.table_default_header_cell>
          </.table_default_row>
        </.table_default_header>
        <.table_default_body>
          <.table_default_row :for={m <- @manufacturers}>
            <.table_default_cell class="font-medium">
              <.link navigate={Paths.manufacturer_edit(m.uuid)} class="link link-hover">
                {m.name}
              </.link>
            </.table_default_cell>
            <.table_default_cell class="text-sm text-base-content/60">{m.website}</.table_default_cell>
            <.table_default_cell><.status_badge status={m.status} size={:sm} /></.table_default_cell>
            <.table_default_cell class="text-right whitespace-nowrap">
              <.table_row_menu mode="auto" id={"mfg-menu-#{m.uuid}"}>
                <.table_row_menu_link navigate={Paths.manufacturer_edit(m.uuid)} icon="hero-pencil" label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit")} />
                <.table_row_menu_divider />
                <.table_row_menu_button phx-click="show_delete_confirm" phx-value-uuid={m.uuid} phx-value-type="manufacturer" icon="hero-trash" label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")} variant="error" />
              </.table_row_menu>
            </.table_default_cell>
          </.table_default_row>
        </.table_default_body>
        <:card_header :let={m}>
          <.link navigate={Paths.manufacturer_edit(m.uuid)} class="font-medium text-sm link link-hover">{m.name}</.link>
        </:card_header>
        <:card_actions :let={m}>
          <.link navigate={Paths.manufacturer_edit(m.uuid)} class="btn btn-ghost btn-xs">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit")}</.link>
          <button phx-click="show_delete_confirm" phx-value-uuid={m.uuid} phx-value-type="manufacturer" class="btn btn-ghost btn-xs text-error">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")}</button>
        </:card_actions>
      </.table_default>
    </div>
    """
  end

  defp suppliers_table(assigns) do
    ~H"""
    <div :if={@suppliers == []} class="card bg-base-100 shadow">
      <div class="card-body items-center text-center py-12">
        <p class="text-base-content/60">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "No suppliers yet.")}</p>
      </div>
    </div>

    <div :if={@suppliers != []}>
      <.table_default
        variant="zebra" size="sm" toggleable={true}
        id="suppliers-list" items={@suppliers}
        card_fields={fn s -> [
          %{label: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Website"), value: s.website || "—"},
          %{label: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Status"), value: status_label(s.status)}
        ] end}
      >
        <.table_default_header>
          <.table_default_row>
            <.table_default_header_cell>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Name")}</.table_default_header_cell>
            <.table_default_header_cell>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Website")}</.table_default_header_cell>
            <.table_default_header_cell>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Status")}</.table_default_header_cell>
            <.table_default_header_cell class="text-right whitespace-nowrap">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Actions")}</.table_default_header_cell>
          </.table_default_row>
        </.table_default_header>
        <.table_default_body>
          <.table_default_row :for={s <- @suppliers}>
            <.table_default_cell class="font-medium">
              <.link navigate={Paths.supplier_edit(s.uuid)} class="link link-hover">
                {s.name}
              </.link>
            </.table_default_cell>
            <.table_default_cell class="text-sm text-base-content/60">{s.website}</.table_default_cell>
            <.table_default_cell><.status_badge status={s.status} size={:sm} /></.table_default_cell>
            <.table_default_cell class="text-right whitespace-nowrap">
              <.table_row_menu mode="auto" id={"supplier-menu-#{s.uuid}"}>
                <.table_row_menu_link navigate={Paths.supplier_edit(s.uuid)} icon="hero-pencil" label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit")} variant="secondary" />
                <.table_row_menu_divider />
                <.table_row_menu_button phx-click="show_delete_confirm" phx-value-uuid={s.uuid} phx-value-type="supplier" icon="hero-trash" label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")} variant="error" />
              </.table_row_menu>
            </.table_default_cell>
          </.table_default_row>
        </.table_default_body>
        <:card_header :let={s}>
          <.link navigate={Paths.supplier_edit(s.uuid)} class="font-medium text-sm link link-hover">{s.name}</.link>
        </:card_header>
        <:card_actions :let={s}>
          <.link navigate={Paths.supplier_edit(s.uuid)} class="btn btn-ghost btn-xs">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit")}</.link>
          <button phx-click="show_delete_confirm" phx-value-uuid={s.uuid} phx-value-type="supplier" class="btn btn-ghost btn-xs text-error">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")}</button>
        </:card_actions>
      </.table_default>
    </div>
    """
  end
end
