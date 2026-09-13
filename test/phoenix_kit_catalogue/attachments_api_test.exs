defmodule PhoenixKitCatalogue.AttachmentsApiTest do
  @moduledoc """
  `Attachments.attach_files/3` — the non-LiveView entry point that links
  already-uploaded Storage files to an item without a mounted form. Uses
  the item's same deterministic folder-name rule as the LiveView path
  (`Attachments.mount_attachments/2`), covered separately in
  `test/web/attachments_lv_test.exs` and `test/catalogue/duplication_test.exs`.
  """

  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase, only: [fixture_catalogue: 1, fixture_item: 1]

  alias Ecto.Adapters.SQL
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKitCatalogue.Attachments
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Test.Repo

  setup do
    cat = fixture_catalogue(%{name: "Attach API"})
    item = fixture_item(%{catalogue_uuid: cat.uuid, name: "Vase"})
    user_uuid = insert_user!()
    %{item: item, user_uuid: user_uuid}
  end

  describe "attach_files/3" do
    test "links each file to the item's folder, sets featured image and media order",
         %{item: item, user_uuid: user_uuid} do
      a = insert_file!(user_uuid, nil, "a.jpg")
      b = insert_file!(user_uuid, nil, "b.jpg")

      assert {:ok, updated} = Attachments.attach_files(item, [a, b], featured: b)

      assert updated.data["featured_image_uuid"] == b
      assert updated.data["media_order"] == [a, b]

      folder_uuid = updated.data["files_folder_uuid"]
      assert is_binary(folder_uuid)
      assert Storage.get_folder(folder_uuid).name == "catalogue-item-#{item.uuid}"

      assert Repo.get!(StorageFile, a).folder_uuid == folder_uuid
      assert Repo.get!(StorageFile, b).folder_uuid == folder_uuid
    end

    test "forwards opts[:actor_uuid] to the activity log", %{item: item, user_uuid: user_uuid} do
      a = insert_file!(user_uuid, nil, "a.jpg")

      assert {:ok, updated} = Attachments.attach_files(item, [a], actor_uuid: user_uuid)

      assert_activity_logged("item.updated", resource_uuid: updated.uuid, actor_uuid: user_uuid)
    end

    test "with no opts, featured defaults to the first uuid and order to the given list",
         %{item: item, user_uuid: user_uuid} do
      a = insert_file!(user_uuid, nil, "a.jpg")
      b = insert_file!(user_uuid, nil, "b.jpg")

      assert {:ok, updated} = Attachments.attach_files(item, [a, b], [])

      assert updated.data["featured_image_uuid"] == a
      assert updated.data["media_order"] == [a, b]
    end

    test "reuses the item's existing folder rather than creating a second one",
         %{item: item, user_uuid: user_uuid} do
      a = insert_file!(user_uuid, nil, "a.jpg")
      b = insert_file!(user_uuid, nil, "b.jpg")

      {:ok, updated} = Attachments.attach_files(item, [a])
      {:ok, updated} = Attachments.attach_files(updated, [b], featured: b)

      assert updated.data["media_order"] == [b]
      assert Repo.get!(StorageFile, a).folder_uuid == updated.data["files_folder_uuid"]
      assert Repo.get!(StorageFile, b).folder_uuid == updated.data["files_folder_uuid"]

      folder_name = "catalogue-item-#{item.uuid}"

      assert Repo.aggregate(
               from(f in PhoenixKit.Modules.Storage.Folder, where: f.name == ^folder_name),
               :count
             ) == 1
    end

    test "a file already owned by another folder gets a FolderLink instead of being moved",
         %{item: item, user_uuid: user_uuid} do
      {:ok, other_folder} = Storage.create_folder(%{name: "Other Folder #{item.uuid}"})
      a = insert_file!(user_uuid, other_folder.uuid, "a.jpg")

      assert {:ok, updated} = Attachments.attach_files(item, [a])

      item_folder_uuid = updated.data["files_folder_uuid"]
      assert item_folder_uuid != other_folder.uuid

      # The file's home folder is untouched — it appears in the item's
      # folder only via a `FolderLink` shortcut.
      assert Repo.get!(StorageFile, a).folder_uuid == other_folder.uuid

      assert Repo.exists?(
               from(fl in PhoenixKit.Modules.Storage.FolderLink,
                 where: fl.file_uuid == ^a and fl.folder_uuid == ^item_folder_uuid
               )
             )
    end

    test "persist_folder_pointer/2 writes the pointer at first upload and keeps other data keys",
         %{item: item} do
      # Client, 2026-09-12: "uploaded, did not press Save" — the files were
      # in the folder but nothing outside the form could find them,
      # because the pointer only landed at save. A key another process
      # wrote meanwhile (a translation fingerprint) must survive the
      # owned-key write.
      {:ok, item} =
        Catalogue.update_item(item, %{data: %{"_translation_fingerprints" => %{"en" => "x"}}})

      refute item.data["files_folder_uuid"]
      {:ok, folder} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})

      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, attachments_resource: item}}
      socket = Attachments.persist_folder_pointer(socket, folder.uuid)

      reloaded = Catalogue.get_item!(item.uuid)
      assert reloaded.data["files_folder_uuid"] == folder.uuid
      assert reloaded.data["_translation_fingerprints"] == %{"en" => "x"}
      assert socket.assigns.attachments_resource.data["files_folder_uuid"] == folder.uuid

      # A resource with no uuid (a :new form) is left alone.
      fresh = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, attachments_resource: %PhoenixKitCatalogue.Schemas.Item{}}
      }

      assert Attachments.persist_folder_pointer(fresh, folder.uuid) == fresh
    end

    test "a content-duplicate upload is attached from elsewhere but reported when already here",
         %{item: item, user_uuid: user_uuid} do
      # Client, 2026-09-12: "uploaded three PDFs, two show". Storage
      # de-duplicates per user by content and returns the EXISTING record;
      # what happens next depends on where that record lives.
      {:ok, updated} = Attachments.attach_files(item, [insert_file!(user_uuid, nil, "seed.pdf")])
      folder = updated.data["files_folder_uuid"]
      {:ok, elsewhere} = Storage.create_folder(%{name: "Elsewhere #{item.uuid}"})

      # Lives in another folder → linked in, listed here from now on.
      shared = Repo.get!(StorageFile, insert_file!(user_uuid, elsewhere.uuid, "shared.pdf"))
      assert {:ok, ^shared} = Attachments.file_stored({:ok, shared, :duplicate}, folder)
      assert shared.uuid in Enum.map(Attachments.list_folder_files(folder), & &1.uuid)

      # Already home here → nothing to add, and the uploader is told so.
      here = Repo.get!(StorageFile, insert_file!(user_uuid, folder, "here.pdf"))
      assert {:already_attached, ^here} = Attachments.file_stored({:ok, here, :duplicate}, folder)

      assert Attachments.duplicate_notice("again.pdf", here) ==
               "again.pdf is identical to here.pdf, which is already attached — nothing was added."

      # Already LINKED in (a picker pick, a Duplication copy) is as
      # attached as a home row — the link insert's on_conflict: :nothing
      # must not read as a fresh success.
      assert {:already_attached, ^shared} =
               Attachments.file_stored({:ok, shared, :duplicate}, folder)

      # A trashed duplicate was removed on purpose; re-uploading restores it.
      gone = Repo.get!(StorageFile, insert_file!(user_uuid, folder, "gone.pdf"))
      {:ok, gone} = Storage.trash_file(gone)
      assert {:ok, back} = Attachments.file_stored({:ok, gone, :duplicate}, folder)
      assert back.status == "active"

      # An assignment failure is surfaced, not swallowed (the folder was
      # deleted between ensure_folder and store: the FK refuses the adopt).
      loose = Repo.get!(StorageFile, insert_file!(user_uuid, nil, "loose.pdf"))
      assert {:error, _} = Attachments.file_stored({:ok, loose}, Ecto.UUID.generate())

      # A fresh file is home-adopted; an error passes through.
      fresh = Repo.get!(StorageFile, insert_file!(user_uuid, nil, "fresh.pdf"))
      assert {:ok, _} = Attachments.file_stored({:ok, fresh}, folder)
      assert Repo.get!(StorageFile, fresh.uuid).folder_uuid == folder
      assert Attachments.file_stored({:error, :boom}, folder) == {:error, :boom}
    end

    test "update_catalogue/3 honours :data_owned_keys like update_item/3 does" do
      catalogue = fixture_catalogue(%{name: "Owned Keys"})
      {:ok, catalogue} = Catalogue.update_catalogue(catalogue, %{data: %{"other" => "kept"}})
      stale = catalogue

      # Another writer moves `data` after our snapshot…
      {:ok, _} = Catalogue.update_catalogue(catalogue, %{data: %{"other" => "moved"}})

      # …and an owned-key write from the stale snapshot must not undo it.
      {:ok, updated} =
        Catalogue.update_catalogue(stale, %{data: %{"files_folder_uuid" => "f-1"}},
          data_owned_keys: ["files_folder_uuid"]
        )

      assert updated.data == %{"other" => "moved", "files_folder_uuid" => "f-1"}
    end

    test "a drag reorder is persisted at once and survives the grid's refresh",
         %{item: item, user_uuid: user_uuid} do
      # Client, 2026-09-12: "I reorder the photos and they come back".
      # Every refresh of the grid (an upload landing, a broadcast for
      # this item, the picker closing) rebuilt the list from the folder
      # WITHOUT the editor's order, and a Save then persisted the snapped
      # list. Now the refresh re-applies the order, and the drop itself
      # is written — no Save needed.
      a = insert_file!(user_uuid, nil, "a.jpg")
      b = insert_file!(user_uuid, nil, "b.jpg")
      {:ok, item} = Attachments.attach_files(item, [a, b])

      socket =
        %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, phoenix_kit_current_user: nil}}
        |> Attachments.mount_attachments(item)

      assert Enum.map(socket.assigns.files_state.files, & &1.uuid) == [a, b]

      socket = Attachments.handle_reorder_files(socket, [b, a])
      assert Enum.map(socket.assigns.files_state.files, & &1.uuid) == [b, a]
      assert Catalogue.get_item!(item.uuid).data["media_order"] == [b, a]

      # The refresh path keeps the editor's order.
      refreshed = Attachments.refresh_files(socket)
      assert Enum.map(refreshed.assigns.files_state.files, & &1.uuid) == [b, a]

      # A fresh mount reads the persisted order back.
      remounted =
        %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, phoenix_kit_current_user: nil}}
        |> Attachments.mount_attachments(Catalogue.get_item!(item.uuid))

      assert Enum.map(remounted.assigns.files_state.files, & &1.uuid) == [b, a]
    end

    test "an unknown uuid errors and persists nothing", %{item: item, user_uuid: user_uuid} do
      a = insert_file!(user_uuid, nil, "a.jpg")
      bogus = Ecto.UUID.generate()

      assert {:error, {:file_not_found, ^bogus}} = Attachments.attach_files(item, [a, bogus])

      reloaded = Catalogue.get_item!(item.uuid)
      assert reloaded.data == %{}

      # Neither the file nor the folder was touched.
      assert Repo.get!(StorageFile, a).folder_uuid == nil

      folder_name = "catalogue-item-#{item.uuid}"

      assert Repo.aggregate(
               from(f in PhoenixKit.Modules.Storage.Folder, where: f.name == ^folder_name),
               :count
             ) == 0
    end
  end

  # Files carry a CHECK (user_uuid OR parent_file_uuid); give them an owner.
  describe "attach_files/3 leaves pointers it has nothing to say about alone (PR review 2026-09-13)" do
    test "an empty list and `featured: nil` do not delete an existing featured image or order",
         %{item: item, user_uuid: user_uuid} do
      a = insert_file!(user_uuid, nil, "a.jpg")
      b = insert_file!(user_uuid, nil, "b.jpg")
      {:ok, item} = Attachments.attach_files(item, [a, b], order: [b, a])
      assert item.data["featured_image_uuid"] == a
      assert item.data["media_order"] == [b, a]

      {:ok, after_empty} = Attachments.attach_files(item, [])
      assert after_empty.data["featured_image_uuid"] == a
      assert after_empty.data["media_order"] == [b, a]

      {:ok, after_nil} = Attachments.attach_files(item, [b], featured: nil)
      assert after_nil.data["featured_image_uuid"] == a
      assert after_nil.data["media_order"] == [b]
    end
  end

  describe "the editor's grid (review round, 2026-09-12)" do
    test "a trashed featured image does not come back as a ghost at the head of the grid",
         %{item: item, user_uuid: user_uuid} do
      a = insert_file!(user_uuid, nil, "a.jpg")
      ghost = insert_file!(user_uuid, nil, "ghost.jpg", %{status: "trashed"})
      {:ok, item} = Attachments.attach_files(item, [a], featured: ghost)

      socket = Attachments.mount_attachments(bare_socket(), item)

      assert uuids(socket) == [a]
      assert socket.assigns.featured_image_uuid == nil
    end

    test "system-managed rows stay out of the grid, as they are off the card",
         %{item: item, user_uuid: user_uuid} do
      a = insert_file!(user_uuid, nil, "a.jpg")
      {:ok, item} = Attachments.attach_files(item, [a])
      folder = item.data["files_folder_uuid"]
      _tile = insert_file!(user_uuid, folder, "tile.jpg", %{system_managed: true})

      assert uuids(Attachments.mount_attachments(bare_socket(), item)) == [a]
    end

    test "a failed folder read keeps the last list instead of showing an empty grid",
         %{item: item, user_uuid: user_uuid} do
      a = insert_file!(user_uuid, nil, "a.jpg")
      # No featured image: the grid must come from the folder read alone.
      {:ok, item} = Attachments.attach_files(item, [a], featured: nil)
      socket = Attachments.mount_attachments(bare_socket(), item)
      assert uuids(socket) == [a]

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          refreshed =
            socket
            |> Phoenix.Component.assign(:files_folder_uuid, "not-a-uuid")
            |> Attachments.refresh_files()

          assert uuids(refreshed) == [a]
        end)

      assert log =~ "list_folder_files failed"
    end

    test "attach_files/3 keeps the data keys it does not own", %{item: item, user_uuid: user_uuid} do
      a = insert_file!(user_uuid, nil, "a.jpg")

      {:ok, _} =
        Catalogue.update_item(item, %{data: Map.put(item.data || %{}, "fingerprint", "z")})

      # The caller's struct is stale; the row's other keys must survive.
      {:ok, updated} = Attachments.attach_files(item, [a])

      assert updated.data["fingerprint"] == "z"
      assert updated.data["media_order"] == [a]
      assert Catalogue.get_item!(item.uuid).data["fingerprint"] == "z"
    end
  end

  defp bare_socket,
    do: %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, phoenix_kit_current_user: nil}}

  defp uuids(socket), do: Enum.map(socket.assigns.files_state.files, & &1.uuid)

  defp insert_user! do
    user_uuid = UUIDv7.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO phoenix_kit_users
        (uuid, email, hashed_password, account_type, is_active, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'person', true, NOW(), NOW())
      """,
      [
        Ecto.UUID.dump!(user_uuid),
        "attach-api-#{System.unique_integer([:positive])}@example.com",
        "$2b$12$0000000000000000000000000000000000000000000000000000."
      ]
    )

    user_uuid
  end

  defp insert_file!(user_uuid, folder_uuid, name, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    uuid = UUIDv7.generate()

    Repo.insert!(
      %StorageFile{
        uuid: uuid,
        original_file_name: name,
        file_name: name,
        mime_type: "image/jpeg",
        file_type: "image",
        ext: "jpg",
        file_checksum: "chk-#{uuid}",
        user_file_checksum: "uchk-#{uuid}",
        size: 1,
        status: "active",
        system_managed: false,
        user_uuid: user_uuid,
        folder_uuid: folder_uuid,
        inserted_at: now,
        updated_at: now
      }
      |> struct!(attrs)
    )

    uuid
  end
end
