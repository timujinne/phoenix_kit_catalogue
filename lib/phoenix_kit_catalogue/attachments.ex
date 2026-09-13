defmodule PhoenixKitCatalogue.Attachments do
  @moduledoc """
  Folder-scoped file attachments + featured image for catalogue
  resources (items and catalogues share the exact same pattern).

  Each resource owns a `phoenix_kit_media_folders` row keyed by a
  deterministic name derived from the resource struct and UUID.
  Files belong to the resource via `phoenix_kit_files.folder_uuid`,
  queried on mount and refreshed after uploads. An optional featured
  image is a single UUID pointer on `resource.data["featured_image_uuid"]`.

  ## Usage

  The owning LiveView calls `mount_attachments/2` in `mount/3` and
  `allow_attachment_upload/1` in the same chain. Its event/info
  clauses delegate to the matching functions here:

      # Mount
      socket
      |> Attachments.mount_attachments(item_or_catalogue)
      |> Attachments.allow_attachment_upload()

      # Events (one-liner bodies)
      def handle_event("open_featured_image_picker", _, s),
        do: Attachments.open_featured_image_picker(s)

      def handle_event("close_media_selector", _, s),
        do: {:noreply, Attachments.close_media_selector(s)}

      def handle_event("cancel_upload", %{"ref" => ref}, s),
        do: Attachments.cancel_attachment_upload(s, ref)

      def handle_event("clear_featured_image", _, s),
        do: Attachments.clear_featured_image(s)

      def handle_event("remove_file", %{"uuid" => uuid}, s),
        do: Attachments.trash_file(s, uuid)

      def handle_info({:media_selected, uuids}, s),
        do: Attachments.handle_media_selected(s, uuids)

      def handle_info({:media_selector_closed}, s),
        do: {:noreply, Attachments.close_media_selector(s)}

  On save, weave attachment state into params:

      params = Attachments.inject_attachment_data(params, socket)

  And after a `:new` save succeeds, rename the pending folder:

      :ok = Attachments.maybe_rename_pending_folder(socket, saved_resource)

  ## Resource shape

  The module pattern-matches on the resource struct to derive the
  folder name prefix. Add a new clause to `folder_name_for/1` to
  support additional resource types.
  """

  require Logger

  import Ecto.Query, warn: false
  import Phoenix.Component, only: [assign: 2, assign: 3]

  import Phoenix.LiveView,
    only: [
      allow_upload: 3,
      cancel_upload: 3,
      consume_uploaded_entry: 3,
      put_flash: 3
    ]

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{File, FolderLink}
  alias PhoenixKit.Users.Auth, as: UsersAuth
  alias PhoenixKitCatalogue.Catalogue.PubSub
  alias PhoenixKitCatalogue.Schemas.{Catalogue, Category, Item}
  alias PhoenixKitCatalogue.Web.Helpers, as: WebHelpers

  @upload_name :attachment_files
  @doc "Returns the upload ref name used for the inline files dropzone."
  def upload_name, do: @upload_name

  # ── Mount ────────────────────────────────────────────────────────

  @doc """
  Populates the attachment-related assigns on the socket. Accepts the
  owning resource (Item or Catalogue or Category). Stashes the resource
  at `:attachments_resource` so later callbacks (progress, events) can
  reach it without plumbing.

  ## Options

    * `:files_grid` (default `true`) — set to `false` to skip the
      `assign_files_state/1` work (and the per-mount DB query that
      enumerates the folder's files). The CategoryFormLive uses this
      because its UI only renders the featured-image card; it has no
      files grid, so the file list query was wasted.
  """
  def mount_attachments(socket, resource, opts \\ []) do
    files_grid? = Keyword.get(opts, :files_grid, true)

    socket =
      socket
      |> assign(:attachments_resource, resource)
      |> assign_files_folder(resource)
      # Featured image and the stored media order must be set before
      # files_state so the list can merge the featured file in AND come
      # out in the user's saved order (boss, 2026-08-31: the client
      # reorders images after adding them).
      |> assign(:media_order, read_list(resource_data(resource), "media_order"))
      # What the row holds — so a same-place drop writes nothing, and a
      # broadcast can tell "someone else reordered" from "our own write".
      |> assign(:media_order_persisted, read_list(resource_data(resource), "media_order"))
      |> assign_featured_image_state(resource)

    socket =
      if files_grid? do
        assign_files_state(socket)
      else
        assign(socket, :files_state, %{files: []})
      end

    assign_media_selector_defaults(socket)
  end

  @doc """
  Registers the file input `:attachment_files` with a 20-file, 100MB
  ceiling and auto-upload. Progress is consumed by `handle_progress/3`
  which this module captures for the caller.
  """
  def allow_attachment_upload(socket) do
    allow_upload(socket, @upload_name,
      accept: :any,
      max_entries: 20,
      max_file_size: 100_000_000,
      auto_upload: true,
      progress: &handle_progress/3
    )
  end

  defp assign_files_folder(socket, resource) do
    assign(socket, :files_folder_uuid, read_string(resource_data(resource), "files_folder_uuid"))
  end

  defp assign_files_state(socket) do
    files =
      socket
      |> compute_files_list()
      |> apply_media_order(socket.assigns[:media_order])

    assign(socket, :files_state, %{files: files})
  end

  @doc """
  Sorts a file list by an ordered-uuid list (the record's
  `data["media_order"]`, written by the editor's drag reorder — boss,
  2026-08-31). Files the order doesn't know keep their relative
  position at the tail (new uploads land after the ordered ones), and a
  nil/empty order is the identity — legacy records sort as before
  (folder `inserted_at`).
  """
  def apply_media_order(files, order) when is_list(order) and order != [] do
    index = order |> Enum.with_index() |> Map.new()
    tail_base = length(order)

    files
    |> Enum.with_index()
    |> Enum.sort_by(fn {file, position} ->
      {Map.get(index, to_string(file.uuid), tail_base), position}
    end)
    |> Enum.map(&elem(&1, 0))
  end

  def apply_media_order(files, _order), do: files

  @doc """
  The `"reorder_files"` event handler body, shared by the three form
  LiveViews: reorders the files grid to the client's `ordered_ids` and
  remembers the order for `inject_attachment_data/2` to persist at
  save. Crafted ids are harmless — unknown ids are dropped, known files
  the payload missed keep their place at the tail, so the list can
  never lose or invent a file.
  """
  def handle_reorder_files(socket, ordered_ids) when is_list(ordered_ids) do
    files = socket.assigns.files_state.files
    # Only strings can be ids; anything else in a crafted payload is
    # ignored rather than crashing the form.
    order = Enum.filter(ordered_ids, &is_binary/1)
    reordered = apply_media_order(files, order)
    media_order = Enum.map(reordered, &to_string(&1.uuid))

    socket
    |> assign(:media_order, media_order)
    |> assign(:files_state, %{files: reordered})
    |> persist_media_order(media_order)
  end

  def handle_reorder_files(socket, _payload), do: socket

  # Files list = everything in the resource's folder + the featured
  # image if it lives elsewhere. Cross-resource duplicate-moves can
  # leave `featured_image_uuid` pointing at a file now in another
  # resource's folder; we still show it here so the grid reflects
  # what the form's pointers actually reference.
  defp compute_files_list(socket) do
    folder_files =
      case socket.assigns[:files_folder_uuid] do
        nil ->
          []

        folder_uuid ->
          case list_files_in_folder(folder_uuid) do
            {:ok, files} ->
              files

            # A failed read must not look like "no files": Save would then
            # write the empty grid's nil marker over the stored order.
            :error ->
              socket.assigns[:files_state][:files] || []
          end
      end

    case socket.assigns[:featured_image_file] do
      nil ->
        folder_files

      %{uuid: featured_uuid} = featured_file ->
        if Enum.any?(folder_files, &(&1.uuid == featured_uuid)) do
          folder_files
        else
          [featured_file | folder_files]
        end
    end
  end

  # A featured image that was trashed since the pointer was written (from
  # this form without a Save, or from the media manager) must not come
  # back as a ghost at the head of the grid — the card ignores it too.
  defp assign_featured_image_state(socket, resource) do
    uuid = read_string(resource_data(resource), "featured_image_uuid")

    file =
      case if(uuid, do: safe_get_file(uuid), else: nil) do
        %File{status: "trashed"} -> nil
        file -> file
      end

    assign(socket,
      featured_image_uuid: if(file, do: uuid, else: nil),
      featured_image_file: file
    )
  end

  defp assign_media_selector_defaults(socket) do
    assign(socket,
      show_media_selector: false,
      media_selector_target: nil,
      media_selection_mode: :single,
      media_filter: :image,
      media_selected_uuids: []
    )
  end

  # ── Event bodies ─────────────────────────────────────────────────

  @doc "Opens the media selector modal scoped to the resource's folder."
  def open_featured_image_picker(socket) do
    case ensure_folder(socket) do
      {:ok, _folder_uuid, socket} ->
        preselected = List.wrap(socket.assigns[:featured_image_uuid])

        {:noreply,
         socket
         |> assign(:media_selector_target, :featured_image)
         |> assign(:media_selection_mode, :single)
         |> assign(:media_filter, :image)
         |> assign(:media_selected_uuids, preselected)
         |> assign(:show_media_selector, true)}

      {:error, reason} ->
        Logger.warning("Failed to ensure attachments folder: #{inspect(reason)}")

        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Could not prepare the files folder.")
         )}
    end
  end

  @doc """
  Clears the media-selector assigns and re-reads the files grid; returns
  the plain socket. The core `MediaSelectorModal` stores its uploads into
  this resource's folder as they land — closing without confirming still
  leaves them there, so the grid (and, if the folder's contents changed,
  every other surface counting them) must catch up on close.
  """
  def close_media_selector(socket) do
    socket
    |> reset_media_selector()
    |> refresh_files_and_notify()
  end

  defp reset_media_selector(socket) do
    assign(socket,
      show_media_selector: false,
      media_selector_target: nil,
      media_selected_uuids: []
    )
  end

  @doc "Cancels an in-flight upload entry by ref."
  def cancel_attachment_upload(socket, ref) do
    {:noreply, cancel_upload(socket, @upload_name, ref)}
  end

  @doc "Nulls the featured image pointer in socket state (save persists)."
  def clear_featured_image(socket) do
    {:noreply,
     socket
     |> assign(:featured_image_uuid, nil)
     |> assign(:featured_image_file, nil)
     |> refresh_files_from_folder()}
  end

  @doc """
  Removes the file from this resource. Three cases:

  1. File's home folder is this resource AND it's only here → trash it
     (single-owner case; same effect as before folder-links).
  2. File's home folder is this resource AND it's also linked elsewhere
     → promote one link to home, delete the promoted link. The file
     stays alive under its new owner.
  3. File was here via a `FolderLink` (home is another resource) →
     delete the link. Other owners keep their reference untouched.

  Also clears the featured pointer if the removed file was featured.
  """
  def trash_file(socket, uuid) do
    folder_uuid = socket.assigns[:files_folder_uuid]

    case do_detach(uuid, folder_uuid) do
      detached when detached in [:ok, :noop] ->
        new_files = Enum.reject(socket.assigns.files_state.files, &(&1.uuid == uuid))
        new_order = Enum.map(new_files, &to_string(&1.uuid))
        # Only a real write is announced — a miss changed nothing.
        if detached == :ok, do: broadcast_resource_changed(socket)

        {:noreply,
         socket
         |> assign(:files_state, %{files: new_files})
         |> assign(:media_order, new_order)
         |> maybe_clear_featured_if_matches(uuid)
         |> persist_removal(uuid, new_order, detached)}

      {:error, reason} ->
        Logger.warning("Failed to remove file #{uuid}: #{inspect(reason)}")

        WebHelpers.log_operation_error(socket, "trash_file", %{
          entity_type: "file",
          entity_uuid: uuid,
          reason: reason
        })

        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Could not remove file.")
         )}
    end
  end

  # A removal is committed the moment it happens, so the row's pointers
  # follow it at once: the order without the file, and no featured
  # pointer at a file that is no longer here. Otherwise a file still live
  # elsewhere (a link, another folder) stayed the card's main image and
  # came back on remount until the editor pressed Save.
  defp persist_removal(socket, uuid, new_order, :ok) do
    resource = socket.assigns[:attachments_resource]

    if persisted?(resource) do
      data =
        if read_string(resource_data(resource), "featured_image_uuid") == uuid,
          do: %{"media_order" => new_order, "featured_image_uuid" => nil},
          else: %{"media_order" => new_order}

      case write_owned_data(resource, data, current_user_uuid(socket)) do
        {:ok, updated} ->
          socket
          |> assign(:attachments_resource, updated)
          |> assign(:media_order_persisted, new_order)

        {:error, reason} ->
          Logger.warning("Removal not persisted for #{resource.uuid}: #{inspect(reason)}")
          socket
      end
    else
      socket
    end
  rescue
    error ->
      Logger.warning("persist_removal failed: #{inspect(error)}")
      socket
  end

  defp persist_removal(socket, _uuid, _new_order, :noop), do: socket

  # `:noop` — nothing to detach (no folder yet / unknown file); `:ok` —
  # a row was written.
  defp do_detach(_uuid, nil), do: :noop

  defp do_detach(file_uuid, folder_uuid) do
    case Storage.get_file(file_uuid) do
      nil -> :noop
      %File{folder_uuid: ^folder_uuid} = file -> detach_home(file)
      %File{} = file -> detach_link(file.uuid, folder_uuid)
    end
  end

  # File's home is this folder; check for other `FolderLink`s to
  # decide between trashing (single-owner) and promoting (shared).
  defp detach_home(file) do
    repo = PhoenixKit.RepoHelper.repo()

    case list_links(file.uuid) do
      [] ->
        case soft_trash_file(file) do
          {:ok, _} -> :ok
          err -> err
        end

      [%FolderLink{} = link | _rest] ->
        repo.transaction(fn ->
          file
          |> Ecto.Changeset.change(%{folder_uuid: link.folder_uuid})
          |> repo.update!()

          repo.delete!(link)
        end)
        |> case do
          {:ok, _} -> :ok
          err -> err
        end
    end
  end

  # Inline soft-trash so we don't depend on `Storage.trash_file/1` being
  # present in the consumer's vendored `phoenix_kit` version. The
  # public core helper was introduced after the hex release this plugin
  # pins against; the write shape is trivial (status + timestamp) so
  # doing it here keeps the plugin decoupled from the core version
  # skew.
  defp soft_trash_file(%File{} = file) do
    file
    |> Ecto.Changeset.change(%{
      status: "trashed",
      trashed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> PhoenixKit.RepoHelper.repo().update()
  end

  # File's home is elsewhere — removing from this resource just means
  # deleting its folder_link for this folder. Other resources keep it.
  # `:noop` when nothing was linked (a forged removal of a file this
  # resource never held), so no change is announced for no write.
  defp detach_link(file_uuid, folder_uuid) do
    from(fl in FolderLink,
      where: fl.file_uuid == ^file_uuid and fl.folder_uuid == ^folder_uuid
    )
    |> PhoenixKit.RepoHelper.repo().delete_all()
    |> case do
      {0, _} -> :noop
      _ -> :ok
    end
  end

  # Links into LIVE folders only — re-homing into a trashed folder would
  # strand the file (listed nowhere, not in the file trash either).
  defp list_links(file_uuid) do
    from(fl in FolderLink,
      join: fo in PhoenixKit.Modules.Storage.Folder,
      on: fo.uuid == fl.folder_uuid,
      where: fl.file_uuid == ^file_uuid and is_nil(fo.trashed_at),
      order_by: [asc: fl.inserted_at]
    )
    |> PhoenixKit.RepoHelper.repo().all()
  end

  # ── handle_info bodies ───────────────────────────────────────────

  @doc """
  Routes the `:media_selected` reply by `:media_selector_target`.
  Featured-image target promotes the first selected UUID; files
  target is a no-op (modal already set folder_uuid). Both refresh
  the grid from the folder.
  """
  def handle_media_selected(socket, file_uuids) do
    socket =
      case socket.assigns[:media_selector_target] do
        :featured_image -> apply_featured_image_selection(socket, file_uuids)
        # Future: :files target for bulk picker. Today only featured_image
        # opens the modal, but routing stays open for extension.
        _ -> socket
      end

    # `close_media_selector/1` does the folder re-read (+ fan-out) once.
    {:noreply, close_media_selector(socket)}
  end

  @doc """
  Re-reads the resource's folder into the files grid. For hosts that hear
  over PubSub that the resource changed in another session (an upload or
  removal there) — the form's own pointers (featured image) are untouched.
  """
  def refresh_files(socket) do
    socket
    |> resolve_files_folder()
    |> adopt_persisted_media_order()
    |> refresh_files_from_folder()
  end

  # A broadcast says the resource changed elsewhere — and since a drop is
  # persisted at once, "elsewhere" can be a reorder in another tab or by
  # another admin. Take the row's order when it is not the one this form
  # last saw persisted; otherwise keep the local one (a drop whose write
  # failed, a trash that trimmed the list ahead of Save). Without this a
  # second open form re-applied its stale order on every refresh and
  # wrote it back on Save — clobbering the reorder it never saw.
  defp adopt_persisted_media_order(socket) do
    resource = socket.assigns[:attachments_resource]

    with true <- persisted?(resource),
         %{} = fresh <- reload_resource(resource) do
      order = read_list(resource_data(fresh), "media_order")

      if order == socket.assigns[:media_order_persisted] do
        socket
      else
        socket
        |> assign(:attachments_resource, fresh)
        |> assign(:media_order, order)
        |> assign(:media_order_persisted, order)
      end
    else
      _ -> socket
    end
  end

  defp reload_resource(%Item{uuid: uuid}), do: PhoenixKitCatalogue.Catalogue.get_item(uuid)

  defp reload_resource(%Category{uuid: uuid}),
    do: PhoenixKitCatalogue.Catalogue.get_category(uuid)

  defp reload_resource(%Catalogue{uuid: uuid}),
    do: PhoenixKitCatalogue.Catalogue.get_catalogue(uuid)

  defp reload_resource(_), do: nil

  # When THIS tab never uploaded, `files_folder_uuid` is still nil even
  # if another tab created the deterministic folder. Resolve it the same
  # way Duplicate finds a source folder that predates the pointer.
  defp resolve_files_folder(socket) do
    case socket.assigns[:files_folder_uuid] do
      uuid when is_binary(uuid) -> socket
      _ -> assign_resolved_folder(socket)
    end
  end

  defp assign_resolved_folder(socket) do
    with {:ok, name} <- folder_name_for(socket.assigns[:attachments_resource]),
         %{uuid: uuid} <- find_folder_by_name(name) do
      assign(socket, :files_folder_uuid, uuid)
    else
      _ -> socket
    end
  end

  # ── Upload progress (captured via &handle_progress/3) ────────────

  @doc false
  def handle_progress(@upload_name, %{done?: false}, socket), do: {:noreply, socket}

  def handle_progress(@upload_name, entry, socket) do
    case ensure_folder(socket) do
      {:ok, folder_uuid, socket} -> consume_and_store(socket, entry, folder_uuid)
      {:error, reason} -> {:noreply, put_upload_error(socket, entry, reason)}
    end
  end

  defp consume_and_store(socket, entry, folder_uuid) do
    case consume_uploaded_entry(socket, entry, &store_upload(&1, entry, socket, folder_uuid)) do
      {:ok, _file} ->
        # auto_upload: the file row + folder link are committed right here,
        # not at form save — so the paperclip counts elsewhere move now.
        socket = persist_folder_pointer(socket, folder_uuid)
        broadcast_resource_changed(socket)
        {:noreply, refresh_files_from_folder(socket)}

      # Storage de-duplicates per user by content: this upload IS a file
      # already in this folder, so nothing new appears and the row keeps
      # the earlier upload's name. Say so — a silent no-op reads as a
      # lost file (client, 2026-09-12: "uploaded three, two show"). The
      # pointer and the grid still refresh: a legacy row whose folder
      # predates the pointer write heals on exactly this retry.
      {:already_attached, existing} ->
        socket =
          socket
          |> persist_folder_pointer(folder_uuid)
          |> refresh_files_from_folder()

        {:noreply, put_duplicate_notice(socket, entry, existing)}

      {:error, reason} ->
        {:noreply, put_upload_error(socket, entry, reason)}
    end
  end

  defp put_duplicate_notice(socket, entry, existing),
    do: put_flash(socket, :info, duplicate_notice(entry.client_name, existing))

  @doc false
  def duplicate_notice(client_name, existing) do
    Gettext.gettext(
      PhoenixKitCatalogue.Gettext,
      "%{name} is identical to %{existing}, which is already attached — nothing was added.",
      name: client_name,
      existing: existing.original_file_name || client_name
    )
  end

  # A drag is an action, not a draft: like an upload it lands at once,
  # so the popup's carousel and a reload agree with the editor without
  # a Save (client, 2026-09-12: reordered, came back to the product,
  # old order). Owned-key write; a `:new` resource keeps it for save.
  # Never fatal — the grid already shows the new order.
  # Skipped when the row already holds this order: the hook fires on every
  # drop, including one that put the file back where it was, and each write
  # is an "item.updated" activity entry plus a broadcast.
  defp persist_media_order(socket, media_order) do
    resource = socket.assigns[:attachments_resource]

    if persisted?(resource) and media_order != socket.assigns[:media_order_persisted] do
      case write_owned_data(resource, %{"media_order" => media_order}, current_user_uuid(socket)) do
        {:ok, updated} ->
          socket
          |> assign(:attachments_resource, updated)
          |> assign(:media_order_persisted, media_order)

        {:error, reason} ->
          Logger.warning("Media order not persisted for #{resource.uuid}: #{inspect(reason)}")
          order_not_saved_flash(socket)
      end
    else
      socket
    end
  rescue
    error ->
      Logger.warning("persist_media_order failed: #{inspect(error)}")
      order_not_saved_flash(socket)
  end

  # The grid keeps the new order, so without this the editor would leave
  # believing it stuck.
  defp order_not_saved_flash(socket) do
    put_flash(
      socket,
      :error,
      Gettext.gettext(
        PhoenixKitCatalogue.Gettext,
        "The photo order could not be saved. Try again."
      )
    )
  end

  @doc false
  # The upload is committed the moment it lands, but the RESOURCE's
  # pointer to its folder (`data["files_folder_uuid"]`) used to be
  # written only when the form was saved. Every reader outside the form
  # — the product card, the popup's details page, the paperclip counts —
  # follows that pointer, so "uploaded, did not press Save" meant files
  # the editor showed (it re-finds the folder by name) and nothing else
  # did (client, 2026-09-12). Persist the pointer with the first upload
  # for a resource that already exists; a `:new` form still gets it at
  # save, when the pending folder is renamed. Owned-key write, so a
  # translation fingerprint or a sync's namespace written meanwhile is
  # kept. Never fatal: the files are attached either way.
  def persist_folder_pointer(socket, folder_uuid) when is_binary(folder_uuid) do
    resource = socket.assigns[:attachments_resource]

    if persisted?(resource) and
         read_string(resource_data(resource), "files_folder_uuid") != folder_uuid do
      case write_owned_data(
             resource,
             %{"files_folder_uuid" => folder_uuid},
             current_user_uuid(socket)
           ) do
        {:ok, updated} ->
          assign(socket, :attachments_resource, updated)

        {:error, reason} ->
          Logger.warning(
            "Attachment folder pointer not persisted for #{inspect(resource.__struct__)} " <>
              "#{resource.uuid}: #{inspect(reason)}"
          )

          socket
      end
    else
      socket
    end
  rescue
    error ->
      Logger.warning("persist_folder_pointer failed: #{inspect(error)}")
      socket
  end

  def persist_folder_pointer(socket, _), do: socket

  defp persisted?(%{uuid: uuid}) when is_binary(uuid), do: true
  defp persisted?(_), do: false

  # One owned-key write per resource kind: only the given `data` keys are
  # taken from us, everything else keeps the row's freshest value.
  defp write_owned_data(%Item{} = item, data, actor_uuid) do
    PhoenixKitCatalogue.Catalogue.update_item(item, %{data: data},
      data_owned_keys: Map.keys(data),
      actor_uuid: actor_uuid
    )
  end

  defp write_owned_data(%Category{} = category, data, actor_uuid) do
    PhoenixKitCatalogue.Catalogue.update_category(category, %{data: data},
      data_owned_keys: Map.keys(data),
      actor_uuid: actor_uuid
    )
  end

  defp write_owned_data(%Catalogue{} = catalogue, data, actor_uuid) do
    PhoenixKitCatalogue.Catalogue.update_catalogue(catalogue, %{data: data},
      data_owned_keys: Map.keys(data),
      actor_uuid: actor_uuid
    )
  end

  # ── Fan-out ──────────────────────────────────────────────────────

  # Attachment writes land outside the resource's own save path, so the
  # catalogue PubSub never hears about them from the context. Announce
  # the OWNING resource (its kind + catalogue parent) — that is what the
  # index / detail / picker surfaces count paperclips by. A resource that
  # has no uuid yet (`:new` form) has no surface to refresh.
  defp broadcast_resource_changed(socket) do
    case socket.assigns[:attachments_resource] do
      %Item{uuid: uuid, catalogue_uuid: parent} when is_binary(uuid) ->
        PubSub.broadcast(:item, uuid, parent)

      %Category{uuid: uuid, catalogue_uuid: parent} when is_binary(uuid) ->
        PubSub.broadcast(:category, uuid, parent)

      %Catalogue{uuid: uuid} when is_binary(uuid) ->
        PubSub.broadcast(:catalogue, uuid, uuid)

      _ ->
        :ok
    end
  end

  # Re-reads the folder and, when its membership actually changed (a
  # modal upload landed, a file was moved away), fans the change out.
  # Cheap: the re-read is the query the grid needs anyway.
  defp refresh_files_and_notify(socket) do
    before = socket.assigns[:files_state][:files] || []

    # A picker upload lands in the folder without passing through
    # `handle_progress/3`, so the pointer write happens here as well.
    socket =
      case socket.assigns[:files_folder_uuid] do
        uuid when is_binary(uuid) -> persist_folder_pointer(socket, uuid)
        _ -> socket
      end

    socket = refresh_files_from_folder(socket)

    if file_uuids(socket.assigns.files_state.files) != file_uuids(before),
      do: broadcast_resource_changed(socket)

    socket
  end

  defp file_uuids(files), do: files |> Enum.map(& &1.uuid) |> Enum.sort()

  # ── Non-LiveView API ─────────────────────────────────────────────

  @doc """
  Links already-uploaded Storage files to `item`'s attachment folder
  without a mounted LiveView. Resolves (or creates) the item's
  deterministic folder — the same name rule `mount_attachments/2` uses
  — then home-adopts or folder-links each file (`assign_file_to_folder/2`
  under the hood), and persists `data["featured_image_uuid"]`
  (`opts[:featured]`, default the first uuid) and `data["media_order"]`
  (`opts[:order]`, default `file_uuids` as given) via
  `PhoenixKitCatalogue.Catalogue.update_item/3`. Pass `opts[:actor_uuid]`
  so the write is attributed in the activity log, same as every other
  mutating context call — this is the one non-LiveView entry point, so
  there is no mount-time actor to fall back on.

  An unknown uuid returns `{:error, {:file_not_found, uuid}}` before any
  write happens — the item and its folder are left untouched.
  """
  @spec attach_files(Item.t(), [String.t()], keyword()) :: {:ok, Item.t()} | {:error, term()}
  def attach_files(%Item{} = item, file_uuids, opts \\ []) when is_list(file_uuids) do
    with {:ok, files} <- resolve_attach_files(file_uuids),
         {:ok, folder_uuid} <- ensure_item_folder(item) do
      Enum.each(files, &assign_file_to_folder(&1, folder_uuid))

      # Owned-key write: the caller's struct may be stale, and the row's
      # other data keys (translation fingerprints, sync namespaces) must
      # survive. An owned key with an explicit nil DELETES it, so a
      # pointer this call has nothing to say about (an empty list, or
      # `featured: nil` meaning "don't touch") is left out of the write
      # rather than written as nil (GLM-5.3, PR review 2026-09-13).
      data =
        %{"files_folder_uuid" => folder_uuid}
        |> put_present(
          "featured_image_uuid",
          Keyword.get(opts, :featured, List.first(file_uuids))
        )
        |> put_present("media_order", Keyword.get(opts, :order, non_empty(file_uuids)))

      PhoenixKitCatalogue.Catalogue.update_item(item, %{data: data},
        data_owned_keys: Map.keys(data),
        actor_uuid: opts[:actor_uuid]
      )
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp non_empty([]), do: nil
  defp non_empty(list), do: list

  defp resolve_attach_files(file_uuids) do
    file_uuids
    |> Enum.reduce_while({:ok, []}, fn uuid, {:ok, acc} ->
      case safe_get_file(uuid) do
        nil -> {:halt, {:error, {:file_not_found, uuid}}}
        file -> {:cont, {:ok, [file | acc]}}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      error -> error
    end
  end

  defp ensure_item_folder(%Item{} = item) do
    case read_string(resource_data(item), "files_folder_uuid") do
      folder_uuid when is_binary(folder_uuid) ->
        {:ok, folder_uuid}

      _ ->
        case folder_name_for(item) do
          {:ok, name} -> find_or_create_named_folder(name)
          :pending -> {:error, :item_not_persisted}
        end
    end
  end

  defp find_or_create_named_folder(name) do
    case find_folder_by_name(name) do
      %{uuid: uuid} ->
        {:ok, uuid}

      nil ->
        case Storage.create_folder(%{name: name}) do
          {:ok, folder} -> {:ok, folder.uuid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # ── Save-time helpers ────────────────────────────────────────────

  @doc """
  Merges `files_folder_uuid` and `featured_image_uuid` into `params["data"]`.
  Call right before passing params to your context's create/update.
  """
  def inject_attachment_data(params, socket) do
    params
    |> inject_files_folder(socket.assigns[:files_folder_uuid])
    |> inject_featured_image(socket.assigns[:featured_image_uuid])
    |> inject_media_order(socket.assigns[:files_state])
  end

  @doc """
  After a `:new` save, renames the pending (random-named) folder to
  the deterministic name now that the resource has a UUID. Non-fatal:
  rename failures log and return `:ok` so the save flow isn't blocked.
  """
  def maybe_rename_pending_folder(socket, resource) do
    with folder_uuid when is_binary(folder_uuid) <- socket.assigns[:files_folder_uuid],
         {:ok, target_name} <- folder_name_for(resource),
         %{} = folder <- Storage.get_folder(folder_uuid) do
      case Storage.update_folder(folder, %{name: target_name}) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Pending folder rename failed for #{inspect(resource.__struct__)} #{resource.uuid}: #{inspect(reason)}"
          )

          :ok
      end
    else
      _ -> :ok
    end
  end

  # ── Template helpers ─────────────────────────────────────────────

  @doc "Renders a byte count as a human string. Nil-safe."
  def format_file_size(nil), do: "—"

  def format_file_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_000_000_000 -> "#{Float.round(bytes / 1_000_000_000, 1)} GB"
      bytes >= 1_000_000 -> "#{Float.round(bytes / 1_000_000, 1)} MB"
      bytes >= 1_000 -> "#{Float.round(bytes / 1_000, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  def format_file_size(_), do: "—"

  @doc "Picks a heroicon name for a file based on its Storage type."
  def file_icon(%{file_type: "image"}), do: "hero-photo"
  def file_icon(%{file_type: "video"}), do: "hero-film"
  def file_icon(%{file_type: "audio"}), do: "hero-musical-note"
  def file_icon(%{file_type: "archive"}), do: "hero-archive-box"
  def file_icon(%{mime_type: "application/pdf"}), do: "hero-document-text"
  def file_icon(_), do: "hero-document"

  @doc "Translates LiveView upload error atoms to user-facing text."
  def upload_error_message(:too_large),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "File is too large.")

  def upload_error_message(:not_accepted),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "File type not accepted.")

  def upload_error_message(:too_many_files),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Too many files.")

  def upload_error_message(other),
    do:
      Gettext.gettext(PhoenixKitCatalogue.Gettext, "Upload error: %{reason}",
        reason: inspect(other)
      )

  # ── Internals ────────────────────────────────────────────────────

  # Naming convention: `catalogue-item-<uuid>` vs `catalogue-category-<uuid>`
  # vs `catalogue-<uuid>`. Different prefixes prevent name collisions at
  # the folder root.
  defp folder_name_for(%Item{uuid: uuid}) when is_binary(uuid),
    do: {:ok, "catalogue-item-#{uuid}"}

  defp folder_name_for(%Category{uuid: uuid}) when is_binary(uuid),
    do: {:ok, "catalogue-category-#{uuid}"}

  defp folder_name_for(%Catalogue{uuid: uuid}) when is_binary(uuid),
    do: {:ok, "catalogue-#{uuid}"}

  defp folder_name_for(_), do: :pending

  # Lazy-creates (or finds) the owning folder. For persisted resources
  # the name is deterministic; for `:new` resources we create a pending
  # random-named folder that `maybe_rename_pending_folder/2` renames
  # once the resource has a UUID.
  defp ensure_folder(socket) do
    case socket.assigns[:files_folder_uuid] do
      uuid when is_binary(uuid) ->
        {:ok, uuid, socket}

      _ ->
        resource = socket.assigns[:attachments_resource]

        case folder_name_for(resource) do
          {:ok, name} -> find_or_create_folder(socket, name)
          :pending -> create_pending_folder(socket)
        end
    end
  end

  defp find_or_create_folder(socket, folder_name) do
    case find_folder_by_name(folder_name) do
      %{uuid: uuid} ->
        {:ok, uuid, assign(socket, :files_folder_uuid, uuid)}

      nil ->
        create_folder(socket, folder_name)
    end
  end

  defp create_pending_folder(socket) do
    create_folder(socket, "catalogue-attachment-pending-#{Ecto.UUID.generate()}")
  end

  defp create_folder(socket, folder_name) do
    user_uuid = current_user_uuid(socket)

    case Storage.create_folder(%{name: folder_name, user_uuid: user_uuid}) do
      {:ok, folder} -> {:ok, folder.uuid, assign(socket, :files_folder_uuid, folder.uuid)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp find_folder_by_name(name) when is_binary(name) do
    from(f in PhoenixKit.Modules.Storage.Folder,
      where: f.name == ^name and is_nil(f.parent_uuid),
      limit: 1
    )
    |> PhoenixKit.RepoHelper.repo().one()
  rescue
    error ->
      Logger.warning("find_folder_by_name failed for #{name}: #{inspect(error)}")
      nil
  end

  # Upload cap is 20 files per submit; the inline grid is not paginated
  # and renders every row. Anything over this is almost certainly data
  # left by an earlier workflow — we hard-cap the query so a folder
  # with thousands of files doesn't freeze the form on mount.
  @files_grid_limit 200

  @doc """
  The files attached to a resource's folder — THE one set every surface
  reads: the folder's home files plus anything linked in via
  `FolderLink`, live (not trashed), oldest first, capped at
  #{@files_grid_limit}.

  A file lands in a folder as a LINK, not a home row, whenever it
  already exists elsewhere: Storage de-duplicates uploads per user by
  content, so a second upload of a byte-identical file — under any name,
  to any resource — returns the file record the first upload created,
  and this module links it in rather than moving it. Until 2026-09-12
  the item form listed home + linked files while the product card and
  the paperclip counts read the home folder only, so such a file showed
  in the editor and nowhere else (client: "uploaded three PDFs, two
  show, one does not"). Readers that used to build their own query call
  this instead.

  Options:

    * `:file_type` — keep only this Storage file type (`"image"`, …).
    * `:exclude_file_type` — drop this Storage file type, in SQL, so the
      cap cannot eat the rows a caller wanted (the card's documents).
    * `:exclude_system_managed` — drop system-managed rows (default
      `false`; the card and the counts pass `true`).
  """
  @spec list_folder_files(String.t() | nil, keyword()) :: [File.t()]
  def list_folder_files(folder_uuid, opts \\ [])

  def list_folder_files(folder_uuid, opts) when is_binary(folder_uuid) do
    folder_files!(folder_uuid, opts)
  rescue
    error ->
      Logger.warning("list_folder_files failed for #{folder_uuid}: #{inspect(error)}")
      []
  end

  def list_folder_files(_, _opts), do: []

  @doc """
  The query behind `list_folder_files/2`, unordered and uncapped: live
  files whose home is `folder_uuid` or that are linked into it. Exposed
  so a batch reader (`Catalogue.Counts.attached_file_counts/1`) can
  count exactly the set the listings show.
  """
  @spec folder_files_query(String.t()) :: Ecto.Query.t()
  def folder_files_query(folder_uuid) when is_binary(folder_uuid) do
    linked_subq =
      from(fl in FolderLink,
        where: fl.folder_uuid == ^folder_uuid,
        select: fl.file_uuid
      )

    from(f in File,
      where:
        (f.folder_uuid == ^folder_uuid or f.uuid in subquery(linked_subq)) and
          f.status != "trashed"
    )
  end

  defp maybe_filter_file_type(query, nil), do: query
  defp maybe_filter_file_type(query, type), do: where(query, [f], f.file_type == ^type)

  defp maybe_exclude_file_type(query, nil), do: query
  defp maybe_exclude_file_type(query, type), do: where(query, [f], f.file_type != ^type)

  defp maybe_exclude_system_managed(query, true), do: where(query, [f], f.system_managed == false)
  defp maybe_exclude_system_managed(query, _), do: query

  defp folder_files!(folder_uuid, opts) do
    folder_uuid
    |> folder_files_query()
    |> maybe_filter_file_type(opts[:file_type])
    |> maybe_exclude_file_type(opts[:exclude_file_type])
    |> maybe_exclude_system_managed(Keyword.get(opts, :exclude_system_managed, false))
    |> order_by([f], asc: f.inserted_at, asc: f.uuid)
    |> limit(@files_grid_limit)
    |> PhoenixKit.RepoHelper.repo().all()
  end

  # The editor's own listing. System-managed rows (tiles, chunks) are
  # hidden here as they are on the card and in core's media browser, so
  # the grid never orders a file the card will not show. A failed read
  # is reported, not disguised as an empty folder.
  defp list_files_in_folder(folder_uuid) do
    {:ok, folder_files!(folder_uuid, exclude_system_managed: true)}
  rescue
    error ->
      Logger.warning("list_folder_files failed for #{folder_uuid}: #{inspect(error)}")
      :error
  end

  defp safe_get_file(uuid) when is_binary(uuid) do
    Storage.get_file(uuid)
  rescue
    error ->
      Logger.warning("Failed to load Storage file #{uuid}: #{inspect(error)}")
      nil
  end

  defp safe_get_file(_), do: nil

  defp current_user_uuid(socket) do
    case socket.assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} -> uuid
      _ -> nil
    end
  end

  # Re-queries the folder and merges the featured image if needed.
  # Use this after any state change that can affect the files list —
  # uploads, featured-image changes, trashing, etc.
  # Re-reads the folder AND re-applies the order the editor holds.
  # Until 2026-09-12 this dropped `media_order` on the floor: every
  # refresh — an upload landing, a PubSub broadcast for this item (the
  # translation sweep, another tab, the pointer write itself), the
  # picker closing — snapped the grid back to folder order, and a Save
  # after that persisted the snapped list. "I reorder the photos and
  # they come back" (client).
  defp refresh_files_from_folder(socket), do: assign_files_state(socket)

  defp apply_featured_image_selection(socket, []) do
    assign(socket, featured_image_uuid: nil, featured_image_file: nil)
  end

  defp apply_featured_image_selection(socket, [uuid | _]) when is_binary(uuid) do
    case safe_get_file(uuid) do
      nil ->
        put_flash(
          socket,
          :error,
          Gettext.gettext(PhoenixKitCatalogue.Gettext, "Selected image could not be loaded.")
        )

      file ->
        # Assign featured first, then refresh — `compute_files_list/1`
        # reads `featured_image_file` to surface the featured file in
        # the grid even when it lives outside the folder.
        socket
        |> assign(featured_image_uuid: uuid, featured_image_file: file)
        |> refresh_files_from_folder()
    end
  end

  defp maybe_clear_featured_if_matches(socket, uuid) do
    if socket.assigns[:featured_image_uuid] == uuid do
      assign(socket, featured_image_uuid: nil, featured_image_file: nil)
    else
      socket
    end
  end

  defp store_upload(%{path: path}, entry, socket, folder_uuid) do
    user_uuid = current_user_uuid(socket)

    if is_nil(user_uuid) do
      {:ok, {:error, :no_user}}
    else
      file_checksum = UsersAuth.calculate_file_hash(path)
      # `client_name` is browser-supplied and only checked against `:accept`,
      # so strip any path before it reaches Storage as a filename. (`ext` was
      # already safe — `Path.extname/1` cannot return a separator.)
      client_name = Path.basename(entry.client_name || "")
      ext = client_name |> Path.extname() |> String.trim_leading(".") |> String.downcase()
      file_type = file_type_from_mime(entry.client_type)

      path
      |> Storage.store_file_in_buckets(file_type, user_uuid, file_checksum, ext, client_name)
      |> then(&{:ok, file_stored(&1, folder_uuid)})
    end
  end

  @doc false
  # What a Storage store result means for THIS folder. A fresh file, or a
  # content-duplicate that lives elsewhere, is attached (home-adopted or
  # linked); a duplicate whose home is already this folder is reported
  # as `:already_attached` so the uploader hears that nothing was added.
  def file_stored({:ok, %File{} = file}, folder_uuid) do
    case assign_file_to_folder(file, folder_uuid) do
      {:error, reason} -> {:error, reason}
      _ -> {:ok, file}
    end
  end

  # A trashed duplicate is not "present" anywhere: the user removed it
  # and is uploading it again, so restore it and attach as if fresh.
  def file_stored({:ok, %File{status: "trashed"} = file, :duplicate}, folder_uuid) do
    case Storage.restore_file(file) do
      {:ok, restored} -> file_stored({:ok, restored}, folder_uuid)
      {:error, reason} -> {:error, reason}
    end
  end

  def file_stored({:ok, %File{folder_uuid: home} = file, :duplicate}, folder_uuid)
      when home == folder_uuid,
      do: {:already_attached, file}

  def file_stored({:ok, %File{} = file, :duplicate}, folder_uuid) do
    # Linked in already (a media-selector pick, an earlier duplicate, a
    # Duplication copy) is as attached as a home row: the link insert's
    # `on_conflict: :nothing` would otherwise read as a fresh success.
    if linked?(file.uuid, folder_uuid) do
      {:already_attached, file}
    else
      case assign_file_to_folder(file, folder_uuid) do
        {:error, reason} -> {:error, reason}
        _ -> {:ok, file}
      end
    end
  end

  def file_stored({:error, reason}, _folder_uuid), do: {:error, reason}

  defp linked?(file_uuid, folder_uuid) do
    PhoenixKit.RepoHelper.repo().exists?(
      from(fl in FolderLink, where: fl.folder_uuid == ^folder_uuid and fl.file_uuid == ^file_uuid)
    )
  end

  # Mirrors the phoenix_kit core `maybe_set_folder/2`: no-op when the
  # file is already in this folder, adopt as home when it has no
  # folder, otherwise add a `FolderLink` so the file appears in
  # multiple resource folders without being yanked from its original
  # owner. Inline dropzone uploads use this path; modal uploads go
  # through the core function of the same shape.
  defp assign_file_to_folder(%{folder_uuid: current}, folder_uuid) when current == folder_uuid,
    do: :ok

  defp assign_file_to_folder(%File{folder_uuid: nil} = file, folder_uuid) do
    file
    |> Ecto.Changeset.change(%{folder_uuid: folder_uuid})
    |> PhoenixKit.RepoHelper.repo().update()
  rescue
    # The folder vanished between ensure_folder and the store (deleted
    # from another session): surface it instead of reporting success.
    e in Ecto.ConstraintError -> {:error, e}
  end

  defp assign_file_to_folder(%File{uuid: file_uuid}, folder_uuid) when is_binary(folder_uuid) do
    %FolderLink{}
    |> FolderLink.changeset(%{folder_uuid: folder_uuid, file_uuid: file_uuid})
    |> PhoenixKit.RepoHelper.repo().insert(
      on_conflict: :nothing,
      conflict_target: [:folder_uuid, :file_uuid]
    )
  rescue
    e in Ecto.ConstraintError -> {:error, e}
  end

  defp put_upload_error(socket, entry, reason) do
    Logger.warning("Attachment upload failed for #{entry.client_name}: #{inspect(reason)}")

    put_flash(
      socket,
      :error,
      Gettext.gettext(PhoenixKitCatalogue.Gettext, "Upload failed for %{name}.",
        name: entry.client_name
      )
    )
  end

  @document_mimes ~w(
    application/pdf
    application/msword
    application/vnd.openxmlformats-officedocument.wordprocessingml.document
    application/vnd.ms-excel
    application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
  )

  # Matches `Storage.determine_file_type/1` for types the browser
  # surfaces; anything we can't bucket falls to "other" (allowed since
  # the phoenix_kit allowlist was widened).
  defp file_type_from_mime(mime) when mime in [nil, ""], do: "other"

  defp file_type_from_mime(mime) when is_binary(mime) do
    file_type_from_prefix(mime) ||
      file_type_from_exact(mime) ||
      file_type_from_keyword(mime) ||
      "other"
  end

  defp file_type_from_prefix("image/" <> _), do: "image"
  defp file_type_from_prefix("video/" <> _), do: "video"
  defp file_type_from_prefix("audio/" <> _), do: "audio"
  defp file_type_from_prefix("text/" <> _), do: "document"
  defp file_type_from_prefix(_), do: nil

  defp file_type_from_exact(mime) when mime in @document_mimes, do: "document"
  defp file_type_from_exact(_), do: nil

  defp file_type_from_keyword(mime) do
    if String.contains?(mime, "zip") or String.contains?(mime, "archive") do
      "archive"
    end
  end

  defp inject_files_folder(params, nil), do: params

  defp inject_files_folder(params, folder_uuid) when is_binary(folder_uuid) do
    data = ensure_data_map(params)
    Map.put(params, "data", Map.put(data, "files_folder_uuid", folder_uuid))
  end

  # `nil`, not `Map.delete/2` — an EXPLICIT "clear this" the caller can
  # act on, as opposed to simply never mentioning the key at all (which
  # `Catalogue.update_item/3` / `update_category/3`'s `:data_owned_keys`
  # splicing reads as "this form didn't touch it, leave the DB row's own
  # value alone" — see that option's doc). Every changeset that ever
  # touches `:data` (`Schemas.Item`/`Schemas.Category`) drops a `nil`
  # top-level entry before it reaches storage, so the stored shape ends
  # up identical to a record that never had the key — not a JSON `null`.
  defp inject_featured_image(params, nil) do
    data = ensure_data_map(params)
    Map.put(params, "data", Map.put(data, "featured_image_uuid", nil))
  end

  defp inject_featured_image(params, uuid) when is_binary(uuid) do
    data = ensure_data_map(params)
    Map.put(params, "data", Map.put(data, "featured_image_uuid", uuid))
  end

  # The full current grid order, not just the dragged subset — new
  # uploads get persisted positions too, and the save is what makes the
  # order real (same lifecycle as the featured pointer). Only written
  # once the user HAS files: a legacy record without any stays untouched.
  defp inject_media_order(params, %{files: [_ | _] = files}) do
    data = ensure_data_map(params)
    Map.put(params, "data", Map.put(data, "media_order", Enum.map(files, &to_string(&1.uuid))))
  end

  # `nil` marker, not `Map.delete/2` — see `inject_featured_image/2`'s
  # comment just above.
  defp inject_media_order(params, _files_state) do
    data = ensure_data_map(params)
    Map.put(params, "data", Map.put(data, "media_order", nil))
  end

  defp ensure_data_map(params) do
    case Map.get(params, "data") do
      %{} = d -> d
      _ -> %{}
    end
  end

  defp resource_data(%{data: data}) when is_map(data), do: data
  defp resource_data(_), do: %{}

  # No non-map fallback: resource_data/1 always yields a map (dialyzer
  # flags the dead clause), and a stored non-list value degrades to [].
  defp read_list(data, key) when is_map(data) do
    case Map.get(data, key) do
      list when is_list(list) -> Enum.map(list, &to_string/1)
      _ -> []
    end
  end

  defp read_string(data, key) when is_map(data) do
    case Map.get(data, key) do
      s when is_binary(s) and s != "" -> s
      _ -> nil
    end
  end
end
