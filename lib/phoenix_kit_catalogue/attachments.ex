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

  ## Parent folder

  By default resource folders are created at the storage root. A host can
  group them under per-type containers:

      config :phoenix_kit_catalogue, :attachments_parent_folder, {MyApp.Media, :for_catalogue}

  Called as `for_catalogue(:item | :category | :catalogue | :pdf, actor_uuid, resource)`
  (3-arity, receiving the resource struct itself) when exported, else as
  `for_catalogue(kind, actor_uuid)` (2-arity, the original contract).
  Either arity returns `{:ok, parent_folder_uuid}` or `nil` (root). Lookups
  by name check the parent first and the root second, so folders that
  predate the setting are still found. A pending folder (made for a `:new`
  form) moves under the saved record's parent when it is renamed — only
  on a definite answer, never to the root a failed hook fell back to.

  ## Host-named folders

  A host that wants people-facing folder names (following the resource's
  own name, not `catalogue-item-<uuid>`) configures:

      config :phoenix_kit_catalogue, :attachments_folder_name, {MyApp.Media, :name_for}

  called as `name_for(resource, actor_uuid) :: {:ok, name} | nil` — `nil`
  (e.g. for an unsaved resource) falls back to the deterministic name.
  `find_resource_folder/2` looks a resource's folder up in that order: the
  host name under the resolved parent, then the deterministic name under
  the parent, at the root, then anywhere — so a folder the host has
  renamed or moved is still found without a stored pointer. Only live
  folders count; a folder another catalogue resource points at is never
  adopted by host name (a host name carries no uuid, and two items can
  share one), and when the host name is taken the folder gets the
  deterministic name. An unsaved resource never adopts a folder. The
  convention is core's `PhoenixKit.Modules.Storage.ResourceFolders`.
  """

  require Logger

  import Phoenix.Component, only: [assign: 2, assign: 3]

  import Phoenix.LiveView,
    only: [
      cancel_upload: 3,
      consume_uploaded_entry: 3,
      put_flash: 3
    ]

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{File, ResourceFolders}
  alias PhoenixKit.Utils.Format
  alias PhoenixKitCatalogue.Catalogue.PubSub
  alias PhoenixKitCatalogue.Schemas.{Catalogue, Category, Item, Pdf}
  alias PhoenixKitCatalogue.Web.Helpers, as: WebHelpers
  alias PhoenixKitWeb.Actor
  alias PhoenixKitWeb.Attachments, as: CoreAttachments

  @upload_name :attachment_files
  @app :phoenix_kit_catalogue
  @pending_prefix "catalogue-attachment-pending-"
  @doc "Returns the upload ref name used for the inline files dropzone."
  @spec upload_name() :: atom()
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
  @spec mount_attachments(Phoenix.LiveView.Socket.t(), struct(), keyword()) ::
          Phoenix.LiveView.Socket.t()
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
      # What the record held when this form opened: a clear marker is
      # written only for something the form knew about.
      |> assign(:media_order_at_mount, read_list(resource_data(resource), "media_order"))
      |> assign(
        :featured_image_at_mount,
        read_string(resource_data(resource), "featured_image_uuid")
      )
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
  @spec allow_attachment_upload(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def allow_attachment_upload(socket),
    do: CoreAttachments.allow(socket, @upload_name, &handle_progress/3)

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
  @spec apply_media_order([map()], [String.t()] | nil) :: [map()]
  defdelegate apply_media_order(files, order), to: CoreAttachments, as: :apply_order

  @doc """
  The `"reorder_files"` event handler body, shared by the three form
  LiveViews: reorders the files grid to the client's `ordered_ids` and
  remembers the order for `inject_attachment_data/2` to persist at
  save. Crafted ids are harmless — unknown ids are dropped, known files
  the payload missed keep their place at the tail, so the list can
  never lose or invent a file.
  """
  @spec handle_reorder_files(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
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

    CoreAttachments.with_featured(folder_files, socket.assigns[:featured_image_file])
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
  @spec open_featured_image_picker(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
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
        Logger.warning(
          "Failed to ensure attachments folder: #{ResourceFolders.describe_failure(reason)}"
        )

        {:noreply, put_flash(socket, :error, CoreAttachments.folder_error_message())}
    end
  end

  @doc """
  Clears the media-selector assigns and re-reads the files grid; returns
  the plain socket. The core `MediaSelectorModal` stores its uploads into
  this resource's folder as they land — closing without confirming still
  leaves them there, so the grid (and, if the folder's contents changed,
  every other surface counting them) must catch up on close.
  """
  @spec close_media_selector(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
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
  @spec cancel_attachment_upload(Phoenix.LiveView.Socket.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def cancel_attachment_upload(socket, ref) do
    {:noreply, cancel_upload(socket, @upload_name, ref)}
  end

  @doc "Nulls the featured image pointer in socket state (save persists)."
  @spec clear_featured_image(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
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
  @spec trash_file(Phoenix.LiveView.Socket.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
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

      case write_owned_data(resource, data, Actor.uuid(socket)) do
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

  # Core's removal rule (`ResourceFolders.detach/2`): a link is dropped; a
  # file homed here moves to a live folder that also links it, or is
  # soft-trashed when nothing else holds it. `:noop` — nothing to detach
  # (no folder yet, an unknown file, or a forged removal of a file this
  # resource never held), so no change is announced for no write; `:ok` —
  # a row was written.
  defp do_detach(file_uuid, folder_uuid) do
    case ResourceFolders.detach(file_uuid, folder_uuid) do
      {:ok, :absent} -> :noop
      {:ok, _outcome} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ── handle_info bodies ───────────────────────────────────────────

  @doc """
  Routes the `:media_selected` reply by `:media_selector_target`.
  Featured-image target promotes the first selected UUID; files
  target is a no-op (modal already set folder_uuid). Both refresh
  the grid from the folder.
  """
  @spec handle_media_selected(Phoenix.LiveView.Socket.t(), [String.t()]) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
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
  @spec refresh_files(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
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
    case find_resource_folder(socket.assigns[:attachments_resource], Actor.uuid(socket)) do
      %{uuid: uuid} -> assign(socket, :files_folder_uuid, uuid)
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
  defdelegate duplicate_notice(client_name, existing), to: CoreAttachments

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
      case write_owned_data(resource, %{"media_order" => media_order}, Actor.uuid(socket)) do
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
  @spec persist_folder_pointer(Phoenix.LiveView.Socket.t(), String.t() | nil) ::
          Phoenix.LiveView.Socket.t()
  def persist_folder_pointer(socket, folder_uuid) when is_binary(folder_uuid) do
    resource = socket.assigns[:attachments_resource]

    if persisted?(resource) and
         read_string(resource_data(resource), "files_folder_uuid") != folder_uuid do
      case write_owned_data(
             resource,
             %{"files_folder_uuid" => folder_uuid},
             Actor.uuid(socket)
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
  — then home-adopts or folder-links each file (core's
  `ResourceFolders.attach/2`), and persists `data["featured_image_uuid"]`
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
         {:ok, folder_uuid} <- ensure_item_folder(item, opts[:actor_uuid]) do
      Enum.each(files, &attach_file(&1, folder_uuid))

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

  defp attach_file(file, folder_uuid) do
    case ResourceFolders.attach(file, folder_uuid) do
      {:ok, _outcome} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Attaching #{file.uuid} to #{folder_uuid} failed: " <>
            ResourceFolders.describe_failure(reason)
        )
    end
  end

  # The stored pointer while its folder is live, else the item's folder
  # resolved or created as the form would.
  defp ensure_item_folder(%Item{} = item, actor_uuid) do
    case ResourceFolders.live_folder(read_string(resource_data(item), "files_folder_uuid")) do
      %{uuid: uuid} ->
        {:ok, uuid}

      nil ->
        case folder_name_for(item) do
          :pending -> {:error, :item_not_persisted}
          {:ok, _} -> item |> ensure_resource_folder(actor_uuid) |> folder_result()
        end
    end
  end

  defp folder_result({:ok, %{uuid: uuid}}), do: {:ok, uuid}
  defp folder_result({:error, reason}), do: {:error, reason}

  # ── Save-time helpers ────────────────────────────────────────────

  @doc """
  Merges `files_folder_uuid` and `featured_image_uuid` into `params["data"]`.
  Call right before passing params to your context's create/update.
  """
  @spec inject_attachment_data(map(), Phoenix.LiveView.Socket.t()) :: map()
  def inject_attachment_data(params, socket) do
    params
    |> inject_files_folder(socket.assigns[:files_folder_uuid])
    |> inject_featured_image(socket.assigns[:featured_image_uuid], socket)
    |> inject_media_order(socket.assigns[:files_state], socket)
  end

  @doc """
  Re-baselines the attachment assigns on a save that keeps the form open.
  `mount_attachments/3` records what the record held when the form
  opened; after a stay-save the record holds what was just saved, so a
  later clear or removal must be judged against that. Without this, an
  image picked and saved here reads as "never known", and clearing it
  on the next save writes no marker — the image stays on the record.
  """
  @spec after_save(Phoenix.LiveView.Socket.t(), struct()) :: Phoenix.LiveView.Socket.t()
  def after_save(socket, resource) do
    data = resource_data(resource)
    order = read_list(data, "media_order")

    socket
    |> assign(:attachments_resource, resource)
    |> assign(:media_order_at_mount, order)
    |> assign(:featured_image_at_mount, read_string(data, "featured_image_uuid"))
    |> assign(:media_order_persisted, order)
  end

  # A clear marker says "the person cleared this here", so it is written
  # only by a form that HAD one to clear: one opened before another tab
  # set an image would otherwise delete it on any save.
  defp knew?(socket, key), do: socket.assigns[key] not in [nil, []]

  @doc """
  After a `:new` save, renames the pending (random-named) folder to
  the deterministic name now that the resource has a UUID. Non-fatal:
  rename failures log and return `:ok` so the save flow isn't blocked.
  """
  @spec maybe_rename_pending_folder(Phoenix.LiveView.Socket.t(), struct()) :: :ok
  def maybe_rename_pending_folder(socket, resource) do
    actor = Actor.uuid(socket)

    with folder_uuid when is_binary(folder_uuid) <- socket.assigns[:files_folder_uuid],
         {:ok, deterministic} <- folder_name_for(resource) do
      ResourceFolders.name_pending(
        folder_uuid,
        @pending_prefix,
        folder_name(resource, actor),
        [fallback_name: deterministic] ++ pending_move(resource, actor)
      )
    else
      _ -> :ok
    end
  end

  # The parent can depend on the saved record (its catalogue, its
  # category), which the pending folder's create could not know, so the
  # folder moves there once the record exists — on a definite answer only:
  # a hook that failed must not send it to the storage root.
  defp pending_move(resource, actor) do
    case ResourceFolders.parent_hook(@app, resource_kind(resource), actor, resource) do
      {:ok, parent_uuid} ->
        [move_to: parent_uuid]

      :unconfigured ->
        []

      {:error, reason} ->
        Logger.warning(
          "Pending folder left in place for #{inspect(resource.__struct__)} #{resource.uuid}: " <>
            ResourceFolders.describe_failure(reason)
        )

        []
    end
  end

  # ── Template helpers ─────────────────────────────────────────────

  @doc "Renders a byte count as a human string (decimal units). Nil-safe."
  @spec format_file_size(integer() | nil) :: String.t()
  def format_file_size(bytes), do: Format.bytes(bytes, base: 1000, unknown: "—")

  @doc "Heroicon name for a file's Storage type / mime (`Format.file_icon/1`)."
  @spec file_icon(map()) :: String.t()
  defdelegate file_icon(file), to: Format

  @doc "Translates LiveView upload error atoms to user-facing text."
  @spec upload_error_message(term()) :: String.t()
  defdelegate upload_error_message(reason), to: CoreAttachments, as: :error_message

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

  @doc false
  # Host-configured parent folder for a resource, see moduledoc "Parent
  # folder". `nil` means the storage root (the default). Prefers the
  # 3-arity hook (receives the resource itself) and falls back to the
  # original 2-arity contract; a failing hook or a non-uuid answer falls
  # back to the root, logged (`ResourceFolders.parent_uuid/4`).
  @spec parent_folder_uuid(term(), String.t() | nil) :: String.t() | nil
  def parent_folder_uuid(resource, actor_uuid),
    do: ResourceFolders.parent_uuid(@app, resource_kind(resource), actor_uuid, resource)

  defp resource_kind(%Item{}), do: :item
  defp resource_kind(%Category{}), do: :category
  defp resource_kind(%Catalogue{}), do: :catalogue
  defp resource_kind(:pdf), do: :pdf
  defp resource_kind(%Pdf{}), do: :pdf
  defp resource_kind(_), do: :unknown

  @doc false
  # Folder name for a resource: the host's (`:attachments_folder_name`) or
  # the deterministic `catalogue-<kind>-<uuid>` (see `folder_name_for/1`).
  @spec folder_name(term(), String.t() | nil) :: String.t()
  def folder_name(resource, actor_uuid) do
    ResourceFolders.host_name(@app, resource, actor_uuid) ||
      case folder_name_for(resource) do
        {:ok, name} -> name
        :pending -> @pending_prefix <> Ecto.UUID.generate()
      end
  end

  @doc false
  # A resource's folder, without creating one: host name under parent
  # (unless another resource points at that folder) → deterministic name
  # under parent → at root → anywhere (the name carries the resource's
  # uuid). Live folders only. An unsaved resource has no folder to find.
  # See moduledoc "Host-named folders".
  @spec find_resource_folder(term(), String.t() | nil) ::
          PhoenixKit.Modules.Storage.Folder.t() | nil
  def find_resource_folder(resource, actor_uuid) do
    case folder_name_for(resource) do
      {:ok, deterministic} ->
        ResourceFolders.resolve(
          parent: parent_folder_uuid(resource, actor_uuid),
          host_name: ResourceFolders.host_name(@app, resource, actor_uuid),
          name: deterministic,
          anywhere: true,
          claimed?: &claimed_by_other?(&1, resource)
        )

      :pending ->
        nil
    end
  end

  # A host name carries no uuid, so another resource — an item of the same
  # name in another catalogue — can own the folder it matches. Adopting it
  # would show and store their files here; the check fails closed.
  defp claimed_by_other?(%{uuid: folder_uuid}, %{uuid: own_uuid}) do
    ResourceFolders.claimed?(folder_uuid, own_uuid, [
      {Item, {:data, "files_folder_uuid"}},
      {Category, {:data, "files_folder_uuid"}},
      {Catalogue, {:data, "files_folder_uuid"}}
    ])
  end

  defp deterministic_name(resource) do
    case folder_name_for(resource) do
      {:ok, name} -> name
      :pending -> nil
    end
  end

  @doc false
  # The deterministic legacy name for a resource ("catalogue-item-<uuid>",
  # "catalogue-category-<uuid>", "catalogue-<uuid>") — `nil` for an unsaved
  # (`:new`) resource. Public so `Catalogue.Duplication` can locate a
  # source's pre-hook-config folder without depending on `folder_name_for/1`.
  @spec legacy_folder_name(term()) :: String.t() | nil
  def legacy_folder_name(resource), do: deterministic_name(resource)

  # The owning folder: the stored one while it is live — a folder trashed
  # in the media browser since would take every upload out of sight — else
  # found or created. For persisted resources the name is the host's or
  # the deterministic one; for `:new` resources a pending random-named
  # folder that `maybe_rename_pending_folder/2` renames once the resource
  # has a UUID.
  defp ensure_folder(socket) do
    case ResourceFolders.live_folder(socket.assigns[:files_folder_uuid]) do
      %{uuid: uuid} ->
        {:ok, uuid, socket}

      nil ->
        resource = socket.assigns[:attachments_resource]

        case ensure_resource_folder(resource, Actor.uuid(socket)) do
          {:ok, %{uuid: uuid}} ->
            {:ok, uuid,
             socket
             |> assign(:files_folder_uuid, uuid)
             |> assign(:attachments_resource, with_pointer(resource, uuid))}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Race-safe find-or-create. A host name taken under the parent by another
  # resource's folder (or refused) gets the uuid-bearing deterministic name
  # instead, which cannot collide. A saved resource's pointer is written in
  # the same locked step (`:claim`): a host name carries no uuid, so until
  # the pointer lands a same-named resource would take the folder for its
  # own.
  defp ensure_resource_folder(resource, actor_uuid) do
    parent_uuid = parent_folder_uuid(resource, actor_uuid)

    case folder_name_for(resource) do
      {:ok, deterministic} ->
        ResourceFolders.ensure(folder_name(resource, actor_uuid), parent_uuid, actor_uuid,
          lookup: fn -> find_resource_folder(resource, actor_uuid) end,
          fallback_name: deterministic,
          claim: &claim_folder(resource, &1)
        )

      :pending ->
        ResourceFolders.ensure(@pending_prefix <> Ecto.UUID.generate(), parent_uuid, actor_uuid)
    end
  end

  defp claim_folder(%schema{uuid: uuid}, folder),
    do: ResourceFolders.write_pointer(schema, uuid, {:data, "files_folder_uuid"}, folder.uuid)

  # The pointer `claim_folder/2` wrote, on the resource the form holds —
  # so `persist_folder_pointer/2` has nothing left to write.
  defp with_pointer(%{uuid: uuid} = resource, folder_uuid) when is_binary(uuid),
    do: %{resource | data: Map.put(resource_data(resource), "files_folder_uuid", folder_uuid)}

  defp with_pointer(resource, _folder_uuid), do: resource

  # Upload cap is 20 files per submit; the inline grid is not paginated
  # and renders every row. Anything over this is almost certainly data
  # left by an earlier workflow — we hard-cap the query so a folder
  # with thousands of files doesn't freeze the form on mount.
  @files_grid_limit 200

  @doc """
  The files attached to a resource's folder — THE one set every surface
  reads: the folder's home files plus anything linked in via
  `FolderLink`, live (not trashed, not system-managed), oldest first,
  capped at #{@files_grid_limit} (`ResourceFolders.list_files/2`).

  A file lands in a folder as a LINK, not a home row, whenever it
  already exists elsewhere: Storage de-duplicates uploads per user by
  content, so a second upload of a byte-identical file — under any name,
  to any resource — returns the file record the first upload created,
  and this module links it in rather than moving it. Readers that build
  their own query miss those files; they call this instead.

  Options:

    * `:only` — `:images`, `:non_images`, `{:type, file_type}`,
      `{:not_type, file_type}` or `:all` (default), in SQL, so the cap
      cannot eat the rows a caller wanted (the card's documents).
    * `:file_type` / `:exclude_file_type` — the older spelling of
      `{:type, t}` / `{:not_type, t}`, still honoured. System-managed files
      are always left out, so the older `:exclude_system_managed` is no
      longer needed.
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

  defp folder_files!(folder_uuid, opts) do
    ResourceFolders.list_files(folder_uuid,
      only: only_option(opts),
      order: :oldest,
      limit: @files_grid_limit
    )
  end

  defp only_option(opts) do
    cond do
      only = opts[:only] -> only
      type = opts[:file_type] -> {:type, type}
      type = opts[:exclude_file_type] -> {:not_type, type}
      true -> :all
    end
  end

  @doc """
  The query behind `list_folder_files/2`, unordered and uncapped: core's
  `ResourceFolders.files_query/1`. Kept for callers that count or order
  the set themselves.
  """
  @spec folder_files_query(String.t()) :: Ecto.Query.t()
  def folder_files_query(folder_uuid), do: ResourceFolders.files_query(folder_uuid)

  # The editor's own listing. System-managed rows (tiles, chunks) are
  # hidden here as they are on the card and in core's media browser, so
  # the grid never orders a file the card will not show. A failed read
  # is reported, not disguised as an empty folder.
  defp list_files_in_folder(folder_uuid) do
    {:ok, folder_files!(folder_uuid, [])}
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

  defp store_upload(%{path: path}, entry, socket, folder_uuid),
    do: {:ok, CoreAttachments.store(path, entry, Actor.uuid(socket), folder_uuid)}

  defp put_upload_error(socket, entry, reason) do
    Logger.warning(
      "Attachment upload failed for #{Path.basename(to_string(entry.client_name))}: " <>
        ResourceFolders.describe_failure(reason)
    )

    put_flash(socket, :error, CoreAttachments.failed_message(entry.client_name, reason))
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
  defp inject_featured_image(params, nil, socket) do
    if knew?(socket, :featured_image_at_mount) do
      data = ensure_data_map(params)
      Map.put(params, "data", Map.put(data, "featured_image_uuid", nil))
    else
      params
    end
  end

  defp inject_featured_image(params, uuid, _socket) when is_binary(uuid) do
    data = ensure_data_map(params)
    Map.put(params, "data", Map.put(data, "featured_image_uuid", uuid))
  end

  # The full current grid order, not just the dragged subset — new
  # uploads get persisted positions too, and the save is what makes the
  # order real (same lifecycle as the featured pointer). Only written
  # once the user HAS files: a legacy record without any stays untouched.
  defp inject_media_order(params, %{files: [_ | _] = files}, _socket) do
    data = ensure_data_map(params)
    Map.put(params, "data", Map.put(data, "media_order", Enum.map(files, &to_string(&1.uuid))))
  end

  # `nil` marker, not `Map.delete/2` — see `inject_featured_image/3`'s
  # comment just above; and only from a form that had an order to lose.
  defp inject_media_order(params, _files_state, socket) do
    if knew?(socket, :media_order_at_mount) do
      data = ensure_data_map(params)
      Map.put(params, "data", Map.put(data, "media_order", nil))
    else
      params
    end
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
