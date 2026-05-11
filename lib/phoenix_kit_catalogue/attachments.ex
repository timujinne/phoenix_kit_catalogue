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
  alias PhoenixKitCatalogue.Schemas.{Catalogue, Category, Item}

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
      # Featured image must be set before files_state so the merge can
      # surface it even if it's in a different folder (e.g. the file was
      # moved to another resource's folder after being featured here).
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
    assign(socket, :files_state, %{files: compute_files_list(socket)})
  end

  # Files list = everything in the resource's folder + the featured
  # image if it lives elsewhere. Cross-resource duplicate-moves can
  # leave `featured_image_uuid` pointing at a file now in another
  # resource's folder; we still show it here so the grid reflects
  # what the form's pointers actually reference.
  defp compute_files_list(socket) do
    folder_files =
      case socket.assigns[:files_folder_uuid] do
        nil -> []
        folder_uuid -> list_files_in_folder(folder_uuid)
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

  defp assign_featured_image_state(socket, resource) do
    uuid = read_string(resource_data(resource), "featured_image_uuid")
    file = if uuid, do: safe_get_file(uuid), else: nil

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

  @doc "Clears the media-selector assigns; returns the plain socket."
  def close_media_selector(socket) do
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
      :ok ->
        new_files = Enum.reject(socket.assigns.files_state.files, &(&1.uuid == uuid))

        {:noreply,
         socket
         |> assign(:files_state, %{files: new_files})
         |> maybe_clear_featured_if_matches(uuid)}

      {:error, reason} ->
        Logger.warning("Failed to remove file #{uuid}: #{inspect(reason)}")

        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Could not remove file.")
         )}
    end
  end

  defp do_detach(_uuid, nil), do: :ok

  defp do_detach(file_uuid, folder_uuid) do
    case Storage.get_file(file_uuid) do
      nil -> :ok
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
  defp detach_link(file_uuid, folder_uuid) do
    from(fl in FolderLink,
      where: fl.file_uuid == ^file_uuid and fl.folder_uuid == ^folder_uuid
    )
    |> PhoenixKit.RepoHelper.repo().delete_all()

    :ok
  end

  defp list_links(file_uuid) do
    from(fl in FolderLink, where: fl.file_uuid == ^file_uuid)
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
        _ -> refresh_files_from_folder(socket)
      end

    {:noreply, close_media_selector(socket)}
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
      {:ok, _file} -> {:noreply, refresh_files_from_folder(socket)}
      {:error, reason} -> {:noreply, put_upload_error(socket, entry, reason)}
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

  # Files visible in this resource's folder: home-folder files plus
  # anything linked in via `FolderLink`. The link path lets the same
  # file be attached to multiple resources without being moved when
  # uploaded a second time.
  defp list_files_in_folder(folder_uuid) do
    linked_subq =
      from(fl in FolderLink,
        where: fl.folder_uuid == ^folder_uuid,
        select: fl.file_uuid
      )

    from(f in File,
      where:
        (f.folder_uuid == ^folder_uuid or f.uuid in subquery(linked_subq)) and
          f.status != "trashed",
      order_by: [asc: f.inserted_at],
      limit: @files_grid_limit
    )
    |> PhoenixKit.RepoHelper.repo().all()
  rescue
    error ->
      Logger.warning("list_files_in_folder failed for #{folder_uuid}: #{inspect(error)}")
      []
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
  defp refresh_files_from_folder(socket) do
    assign(socket, :files_state, %{files: compute_files_list(socket)})
  end

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
      ext = entry.client_name |> Path.extname() |> String.trim_leading(".") |> String.downcase()
      file_type = file_type_from_mime(entry.client_type)

      case Storage.store_file_in_buckets(
             path,
             file_type,
             user_uuid,
             file_checksum,
             ext,
             entry.client_name
           ) do
        {:ok, file} ->
          _ = assign_file_to_folder(file, folder_uuid)
          {:ok, {:ok, file}}

        {:ok, file, :duplicate} ->
          _ = assign_file_to_folder(file, folder_uuid)
          {:ok, {:ok, file}}

        {:error, reason} ->
          {:ok, {:error, reason}}
      end
    end
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
  end

  defp assign_file_to_folder(%File{uuid: file_uuid}, folder_uuid) when is_binary(folder_uuid) do
    %FolderLink{}
    |> FolderLink.changeset(%{folder_uuid: folder_uuid, file_uuid: file_uuid})
    |> PhoenixKit.RepoHelper.repo().insert(
      on_conflict: :nothing,
      conflict_target: [:folder_uuid, :file_uuid]
    )
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

  defp inject_featured_image(params, nil) do
    data = ensure_data_map(params)
    Map.put(params, "data", Map.delete(data, "featured_image_uuid"))
  end

  defp inject_featured_image(params, uuid) when is_binary(uuid) do
    data = ensure_data_map(params)
    Map.put(params, "data", Map.put(data, "featured_image_uuid", uuid))
  end

  defp ensure_data_map(params) do
    case Map.get(params, "data") do
      %{} = d -> d
      _ -> %{}
    end
  end

  defp resource_data(%{data: data}) when is_map(data), do: data
  defp resource_data(_), do: %{}

  defp read_string(data, key) when is_map(data) do
    case Map.get(data, key) do
      s when is_binary(s) and s != "" -> s
      _ -> nil
    end
  end
end
