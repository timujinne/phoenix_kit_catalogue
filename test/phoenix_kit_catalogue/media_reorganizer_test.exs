defmodule PhoenixKitCatalogue.MediaReorganizerTest do
  use PhoenixKitCatalogue.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias PhoenixKit.Modules.Storage
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.MediaReorganizer
  alias PhoenixKitCatalogue.Schemas.{Category, Item, Pdf}

  defmodule Hook do
    def parent(:item, _actor, %Item{}), do: {:ok, Process.get(:target_folder)}
    def parent(:category, _actor, %Category{}), do: {:ok, Process.get(:target_folder)}
    def parent(:catalogue, _actor, %{}), do: {:ok, Process.get(:target_folder)}
    def parent(_, _, _), do: nil
    def name(_resource, _actor), do: {:ok, Process.get(:target_name) || nil}
  end

  defmodule PdfHook do
    def parent(:pdf, _actor, :pdf), do: {:ok, Process.get(:pdf_folder)}
    def parent(_, _, _), do: nil
  end

  defmodule RaisingHook do
    def parent(:item, _actor, %Item{}), do: raise("boom")
    def parent(_, _, _), do: nil
  end

  defmodule ErrorHook do
    def parent(:item, _actor, %Item{}), do: {:error, :timeout}
    def parent(_, _, _), do: nil
  end

  defmodule EmptyStringHook do
    def parent(:item, _actor, %Item{}), do: {:ok, ""}
    def parent(_, _, _), do: nil
  end

  defmodule JunkUuidHook do
    def parent(:item, _actor, %Item{}), do: {:ok, "junk"}
    def parent(_, _, _), do: nil
  end

  defmodule UppercaseParentHook do
    def parent(:item, _actor, %Item{}), do: {:ok, Process.get(:target_folder) |> String.upcase()}
    def parent(_, _, _), do: nil
  end

  defmodule RaisingPdfHook do
    def parent(:pdf, _actor, :pdf), do: raise("pdf boom")
    def parent(_, _, _), do: nil
  end

  defmodule ErrorPdfHook do
    def parent(:pdf, _actor, :pdf), do: {:error, :boom}
    def parent(_, _, _), do: nil
  end

  defmodule JunkUuidPdfHook do
    def parent(:pdf, _actor, :pdf), do: {:ok, "junk"}
    def parent(_, _, _), do: nil
  end

  # Mimics a host hook that treats a resource as top-level whenever its
  # own `parent_uuid` is unset — a nested category's parent hook must see
  # its REAL `parent_uuid`, never a light/partial struct where that
  # column was never selected (which reads as `nil` for every record,
  # nested or not).
  defmodule NestedCategoryHook do
    def parent(:category, _actor, %Category{parent_uuid: nil}),
      do: {:ok, Process.get(:root_folder)}

    def parent(:category, _actor, %Category{parent_uuid: parent_uuid})
        when is_binary(parent_uuid),
        do: {:ok, Process.get(:nested_parent_folder)}

    def parent(_, _, _), do: nil
  end

  # Raises when the ONE category this test cares about arrives with
  # `parent_uuid` unpopulated — catching a regression where the reorganizer
  # hands the host hook a partial/light struct instead of the full row.
  defmodule StrictCategoryHook do
    def parent(:category, _actor, %Category{uuid: uuid} = category) do
      if uuid == Process.get(:strict_child_uuid) do
        parent_uuid = category.parent_uuid || raise "parent_uuid missing on #{uuid}"
        {:ok, parent_uuid}
      else
        {:ok, nil}
      end
    end

    def parent(_, _, _), do: nil
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:phoenix_kit_catalogue, :attachments_parent_folder)
      Application.delete_env(:phoenix_kit_catalogue, :attachments_folder_name)
    end)

    {:ok, user_uuid: fixture_user_uuid()}
  end

  # A minimal `phoenix_kit_users` row so `Storage.create_file/1`'s
  # `user_uuid` FK has something to reference — same pattern as
  # `LiveCase.build_admin_scope/0`.
  defp fixture_user_uuid do
    uuid = UUIDv7.generate()
    email = "reorg-test-#{System.unique_integer([:positive])}@example.com"

    SQL.query!(
      Repo,
      """
      INSERT INTO phoenix_kit_users
        (uuid, email, hashed_password, account_type, is_active, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'person', true, NOW(), NOW())
      """,
      [
        Ecto.UUID.dump!(uuid),
        email,
        "$2b$12$0000000000000000000000000000000000000000000000000000."
      ]
    )

    uuid
  end

  defp new_catalogue(attrs \\ %{}) do
    {:ok, catalogue} = Catalogue.create_catalogue(Map.merge(%{name: "Cat"}, attrs))
    catalogue
  end

  defp new_item(catalogue, attrs \\ %{}) do
    {:ok, item} =
      Catalogue.create_item(Map.merge(%{name: "Widget", catalogue_uuid: catalogue.uuid}, attrs))

    item
  end

  test "no hooks configured, legacy folder at root, pointer set → nothing planned" do
    catalogue = new_catalogue()
    item = new_item(catalogue)

    {:ok, folder} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})
    {:ok, item} = Catalogue.update_item(item, %{data: %{"files_folder_uuid" => folder.uuid}})

    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.kind == :item and &1.label == item.name))
  end

  test "no hooks configured, legacy folder at root, pointer missing → not even a back-fill is planned" do
    catalogue = new_catalogue()
    item = new_item(catalogue)

    {:ok, _folder} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})

    # D1: a host without a configured parent hook is untouched — no move,
    # no pointer back-fill either, even though one would otherwise apply.
    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.kind == :item and &1.label == item.name))
  end

  test "invalid pointer values ('' and 'abc') are treated as absent, never raise" do
    catalogue = new_catalogue()
    item = new_item(catalogue, %{data: %{"files_folder_uuid" => "abc"}})
    catalogue2 = new_catalogue(%{name: "Cat2"})
    item2 = new_item(catalogue2, %{name: "Widget2", data: %{"files_folder_uuid" => ""}})

    {:ok, folder} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})
    {:ok, folder2} = Storage.create_folder(%{name: "catalogue-item-#{item2.uuid}"})

    Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})

    actions = MediaReorganizer.plan(nil, [])

    action = Enum.find(actions, &(&1.kind == :item and &1.label == item.name))
    action2 = Enum.find(actions, &(&1.kind == :item and &1.label == item2.name))

    refute is_nil(action)
    refute is_nil(action2)
    assert action.folder.uuid == folder.uuid
    assert action2.folder.uuid == folder2.uuid
  end

  test "hooks configured, pointer folder still has the legacy name → gets renamed (E2)" do
    catalogue = new_catalogue()
    item = new_item(catalogue, %{name: "Käepide"})

    {:ok, target} = Storage.create_folder(%{name: "Items"})
    {:ok, folder} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})
    {:ok, item} = Catalogue.update_item(item, %{data: %{"files_folder_uuid" => folder.uuid}})

    Process.put(:target_folder, target.uuid)
    Process.put(:target_name, "Nice")
    Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})
    Application.put_env(:phoenix_kit_catalogue, :attachments_folder_name, {Hook, :name})

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :item))

    assert action.source == "catalogue"
    assert action.op == :move
    assert action.folder.uuid == folder.uuid
    assert action.parent_uuid == target.uuid
    # E2: the pointer folder still literally reads the legacy name, so it
    # gets the host name like any other candidate.
    assert action.name == "Nice"
    assert action.on_conflict == :suffix
    assert action.counts == {0, 0}
    assert action.label == item.name
    # pointer already correct → no back-fill needed
    assert is_nil(action.after_move)
  end

  test "hooks configured, pointer folder already renamed by the owner → kept as-is (D6)" do
    catalogue = new_catalogue()
    item = new_item(catalogue, %{name: "Käepide"})

    {:ok, target} = Storage.create_folder(%{name: "Items"})
    {:ok, folder} = Storage.create_folder(%{name: "Owner renamed this", parent_uuid: target.uuid})
    {:ok, item} = Catalogue.update_item(item, %{data: %{"files_folder_uuid" => folder.uuid}})

    Process.put(:target_folder, target.uuid)
    Process.put(:target_name, "Nice")
    Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})
    Application.put_env(:phoenix_kit_catalogue, :attachments_folder_name, {Hook, :name})

    actions = MediaReorganizer.plan(nil, [])

    # Already at the right parent and the pointer is correct — the name
    # hook is never called (R8) and nothing is planned.
    refute Enum.any?(actions, &(&1.kind == :item and &1.label == item.name))
  end

  test "counts include a trashed file — the engine re-measures the same way at apply time", %{
    user_uuid: user_uuid
  } do
    catalogue = new_catalogue()
    item = new_item(catalogue, %{name: "Käepide"})

    {:ok, target} = Storage.create_folder(%{name: "Items"})
    {:ok, folder} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})
    {:ok, _item} = Catalogue.update_item(item, %{data: %{"files_folder_uuid" => folder.uuid}})

    {:ok, _trashed_file} =
      Storage.create_file(%{
        original_file_name: "old.pdf",
        file_name: "old.pdf",
        mime_type: "application/pdf",
        file_type: "document",
        ext: "pdf",
        file_checksum: "checksum-trashed",
        user_file_checksum: "user-checksum-trashed",
        size: 10,
        status: "trashed",
        folder_uuid: folder.uuid,
        user_uuid: user_uuid
      })

    Process.put(:target_folder, target.uuid)
    Process.put(:target_name, "Nice")
    Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})
    Application.put_env(:phoenix_kit_catalogue, :attachments_folder_name, {Hook, :name})

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :item))

    assert action.counts == {1, 0}
  end

  test "pointer missing (folder found by legacy name) → after_move back-fills it" do
    catalogue = new_catalogue()
    item = new_item(catalogue, %{name: "Käepide"})

    {:ok, target} = Storage.create_folder(%{name: "Items"})
    {:ok, folder} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})

    Process.put(:target_folder, target.uuid)
    Process.put(:target_name, "Nice")
    Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})
    Application.put_env(:phoenix_kit_catalogue, :attachments_folder_name, {Hook, :name})

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :item))

    assert action.folder.uuid == folder.uuid
    assert is_function(action.after_move, 0)

    assert :ok = action.after_move.()

    reloaded = Catalogue.get_item!(item.uuid)
    assert reloaded.data["files_folder_uuid"] == folder.uuid
  end

  test "pointer points at a trashed folder while a live legacy folder exists at root → the live one is used" do
    catalogue = new_catalogue()
    item = new_item(catalogue)

    {:ok, trashed} = Storage.create_folder(%{name: "old-pointer-target"})
    {:ok, trashed} = Storage.trash_folder(trashed)
    {:ok, live} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})
    {:ok, item} = Catalogue.update_item(item, %{data: %{"files_folder_uuid" => trashed.uuid}})

    # D1: a hook must be configured (even one that resolves to root) for
    # the Source to plan anything at all.
    Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :item and &1.label == item.name))

    refute is_nil(action)
    assert action.folder.uuid == live.uuid
  end

  test "folder already at the right parent/name but pointer missing → move action with after_move" do
    catalogue = new_catalogue()
    item = new_item(catalogue, %{name: "Käepide"})

    {:ok, target} = Storage.create_folder(%{name: "Items"})

    {:ok, folder} =
      Storage.create_folder(%{name: "catalogue-item-#{item.uuid}", parent_uuid: target.uuid})

    Process.put(:target_folder, target.uuid)
    Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :item and &1.label == item.name))

    refute is_nil(action)
    assert action.op == :move
    assert action.folder.uuid == folder.uuid
    assert action.parent_uuid == target.uuid
    assert action.name == folder.name
    assert is_function(action.after_move, 0)
  end

  test "folder already at the right parent/name and pointer already correct → nothing planned" do
    catalogue = new_catalogue()
    item = new_item(catalogue, %{name: "Käepide"})

    {:ok, target} = Storage.create_folder(%{name: "Items"})

    {:ok, folder} =
      Storage.create_folder(%{name: "catalogue-item-#{item.uuid}", parent_uuid: target.uuid})

    {:ok, _item} = Catalogue.update_item(item, %{data: %{"files_folder_uuid" => folder.uuid}})

    Process.put(:target_folder, target.uuid)
    Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})

    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.kind == :item and &1.label == item.name))
  end

  test "categories and catalogues get actions too" do
    catalogue = new_catalogue(%{name: "Root cat"})
    {:ok, category} = Catalogue.create_category(%{name: "Cards", catalogue_uuid: catalogue.uuid})

    {:ok, cat_folder} = Storage.create_folder(%{name: "catalogue-#{catalogue.uuid}"})

    {:ok, catalogue} =
      Catalogue.update_catalogue(catalogue, %{data: %{"files_folder_uuid" => cat_folder.uuid}})

    {:ok, cat_folder2} = Storage.create_folder(%{name: "catalogue-category-#{category.uuid}"})

    {:ok, category} =
      Catalogue.update_category(category, %{data: %{"files_folder_uuid" => cat_folder2.uuid}})

    Process.put(:target_folder, cat_folder.uuid)
    Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})

    actions = MediaReorganizer.plan(nil, [])

    assert Enum.any?(actions, &(&1.kind == :catalogue and &1.label == catalogue.name))
    assert Enum.any?(actions, &(&1.kind == :category and &1.label == category.name))
  end

  test "trashed folder sharing the legacy name at root does not hide the live folder under the resolved parent" do
    catalogue = new_catalogue()
    item = new_item(catalogue)

    {:ok, target} = Storage.create_folder(%{name: "Items"})

    {:ok, trashed_at_root} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})
    {:ok, _trashed_at_root} = Storage.trash_folder(trashed_at_root)

    {:ok, live} =
      Storage.create_folder(%{name: "catalogue-item-#{item.uuid}", parent_uuid: target.uuid})

    Process.put(:target_folder, target.uuid)
    Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :item and &1.label == item.name))

    refute Enum.any?(actions, &(&1.kind == :duplicate))
    refute is_nil(action)
    assert action.folder.uuid == live.uuid
  end

  describe "duplicate folders (X4/X5/X11)" do
    test "legacy folder live at both root and under the resolved parent → one duplicate report, no move" do
      catalogue = new_catalogue()
      item = new_item(catalogue)

      {:ok, target} = Storage.create_folder(%{name: "Items"})
      {:ok, at_root} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})

      {:ok, _under_parent} =
        Storage.create_folder(%{name: "catalogue-item-#{item.uuid}", parent_uuid: target.uuid})

      Process.put(:target_folder, target.uuid)
      Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :item and &1.op == :move))
      dup = Enum.find(actions, &(&1.kind == :duplicate and &1.label == item.name))
      refute is_nil(dup)
      assert dup.op == :report
      assert dup.reason =~ at_root.uuid
    end

    test "two records whose current folder resolves to the same live folder → one duplicate report, no move" do
      catalogue = new_catalogue()
      item1 = new_item(catalogue, %{name: "First"})
      item2 = new_item(catalogue, %{name: "Second"})

      {:ok, shared} = Storage.create_folder(%{name: "shared-folder"})
      {:ok, item1} = Catalogue.update_item(item1, %{data: %{"files_folder_uuid" => shared.uuid}})
      {:ok, item2} = Catalogue.update_item(item2, %{data: %{"files_folder_uuid" => shared.uuid}})

      Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :item and &1.op == :move))
      dup = Enum.find(actions, &(&1.kind == :duplicate and &1.label == shared.name))
      refute is_nil(dup)
      assert dup.op == :report
      assert dup.reason =~ item1.name
      assert dup.reason =~ item2.name
    end
  end

  describe "pending folders" do
    test "empty pending folder older than pending_days, hook configured → op: :trash" do
      {:ok, folder} =
        Storage.create_folder(%{name: "catalogue-attachment-pending-#{Ecto.UUID.generate()}"})

      old_time =
        DateTime.utc_now() |> DateTime.add(-10 * 86_400, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(f in Storage.Folder, where: f.uuid == ^folder.uuid),
        set: [inserted_at: old_time]
      )

      Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, pending_days: 7)
      action = Enum.find(actions, &(&1.kind == :pending and &1.folder.uuid == folder.uuid))

      assert action.op == :trash
    end

    test "empty pending folder older than pending_days, no hook configured → op: :report (E1)" do
      {:ok, folder} =
        Storage.create_folder(%{name: "catalogue-attachment-pending-#{Ecto.UUID.generate()}"})

      old_time =
        DateTime.utc_now() |> DateTime.add(-10 * 86_400, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(f in Storage.Folder, where: f.uuid == ^folder.uuid),
        set: [inserted_at: old_time]
      )

      actions = MediaReorganizer.plan(nil, pending_days: 7)
      action = Enum.find(actions, &(&1.kind == :pending and &1.folder.uuid == folder.uuid))

      refute is_nil(action)
      assert action.op == :report
    end

    test "non-empty pending folder → op: :report with the file name in the reason", %{
      user_uuid: user_uuid
    } do
      {:ok, folder} =
        Storage.create_folder(%{name: "catalogue-attachment-pending-#{Ecto.UUID.generate()}"})

      {:ok, _file} =
        Storage.create_file(%{
          original_file_name: "leftover.pdf",
          file_name: "leftover.pdf",
          mime_type: "application/pdf",
          file_type: "document",
          ext: "pdf",
          file_checksum: "checksum-1",
          user_file_checksum: "user-checksum-1",
          size: 10,
          status: "active",
          folder_uuid: folder.uuid,
          user_uuid: user_uuid
        })

      actions = MediaReorganizer.plan(nil, pending_days: 7)
      action = Enum.find(actions, &(&1.kind == :pending and &1.folder.uuid == folder.uuid))

      assert action.op == :report
      assert action.reason =~ "leftover.pdf"
    end

    test "pending folder younger than pending_days → no action" do
      {:ok, folder} =
        Storage.create_folder(%{name: "catalogue-attachment-pending-#{Ecto.UUID.generate()}"})

      actions = MediaReorganizer.plan(nil, pending_days: 7)
      refute Enum.any?(actions, &(&1.kind == :pending and &1.folder.uuid == folder.uuid))
    end

    test "pending folder a live record currently points at is never independently reported/trashed (X4)" do
      catalogue = new_catalogue()
      item = new_item(catalogue)

      {:ok, folder} =
        Storage.create_folder(%{name: "catalogue-attachment-pending-#{Ecto.UUID.generate()}"})

      {:ok, _item} = Catalogue.update_item(item, %{data: %{"files_folder_uuid" => folder.uuid}})

      old_time =
        DateTime.utc_now() |> DateTime.add(-10 * 86_400, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(f in Storage.Folder, where: f.uuid == ^folder.uuid),
        set: [inserted_at: old_time]
      )

      Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, pending_days: 7)

      refute Enum.any?(actions, &(&1.kind == :pending and &1.folder.uuid == folder.uuid))
    end
  end

  describe "orphan folders" do
    test "legacy folder with no matching record → orphan report with counts", %{
      user_uuid: user_uuid
    } do
      {:ok, folder} = Storage.create_folder(%{name: "catalogue-item-#{Ecto.UUID.generate()}"})

      {:ok, _file} =
        Storage.create_file(%{
          original_file_name: "stray.pdf",
          file_name: "stray.pdf",
          mime_type: "application/pdf",
          file_type: "document",
          ext: "pdf",
          file_checksum: "checksum-orphan",
          user_file_checksum: "user-checksum-orphan",
          size: 5,
          status: "active",
          folder_uuid: folder.uuid,
          user_uuid: user_uuid
        })

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))

      refute is_nil(action)
      assert action.source == "catalogue"
      assert action.op == :report
      assert action.counts == {1, 0}
      assert action.reason =~ "missing"
      assert action.reason =~ "1 file"
    end

    test "legacy folder of a deleted item → report names the record's status" do
      catalogue = new_catalogue()
      item = new_item(catalogue)
      {:ok, folder} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})
      {:ok, _item} = Catalogue.trash_item(item)

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))

      refute is_nil(action)
      assert action.op == :report
      assert action.reason =~ "deleted"
    end

    test "legacy folder of a live item → not reported as orphan" do
      catalogue = new_catalogue()
      item = new_item(catalogue)
      {:ok, folder} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})

      actions = MediaReorganizer.plan(nil, [])
      refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))
    end
  end

  describe "PDF library report" do
    test "PDFs at root with a configured library folder → one report action", %{
      user_uuid: user_uuid
    } do
      {:ok, pdf_folder} = Storage.create_folder(%{name: "PDF library"})
      Process.put(:pdf_folder, pdf_folder.uuid)
      Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {PdfHook, :parent})

      {:ok, file} =
        Storage.create_file(%{
          original_file_name: "manual.pdf",
          file_name: "manual.pdf",
          mime_type: "application/pdf",
          file_type: "document",
          ext: "pdf",
          file_checksum: "checksum-2",
          user_file_checksum: "user-checksum-2",
          size: 20,
          status: "active",
          user_uuid: user_uuid
        })

      {:ok, _pdf} =
        %Pdf{}
        |> Pdf.changeset(%{
          file_uuid: file.uuid,
          original_filename: "manual.pdf",
          byte_size: 20,
          status: "active"
        })
        |> Repo.insert()

      actions = MediaReorganizer.plan(nil, [])
      pdf_action = Enum.find(actions, &(&1.kind == :pdf))

      refute is_nil(pdf_action)
      assert pdf_action.op == :report
      assert {1, 0} = pdf_action.counts
    end

    test "no PDFs at root → no report action" do
      {:ok, pdf_folder} = Storage.create_folder(%{name: "PDF library"})
      Process.put(:pdf_folder, pdf_folder.uuid)
      Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {PdfHook, :parent})

      actions = MediaReorganizer.plan(nil, [])
      refute Enum.any?(actions, &(&1.kind == :pdf))
    end
  end

  describe "claims are hook-independent (R1)" do
    test "pending folder a live record's pointer names is never trashed, even with no hook configured" do
      catalogue = new_catalogue()
      item = new_item(catalogue)

      {:ok, folder} =
        Storage.create_folder(%{name: "catalogue-attachment-pending-#{Ecto.UUID.generate()}"})

      {:ok, _item} = Catalogue.update_item(item, %{data: %{"files_folder_uuid" => folder.uuid}})

      old_time =
        DateTime.utc_now() |> DateTime.add(-10 * 86_400, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(f in Storage.Folder, where: f.uuid == ^folder.uuid),
        set: [inserted_at: old_time]
      )

      # No hook configured at all — D1 leaves resource_plan empty, but R1
      # claims still come from the record's live pointer directly.
      actions = MediaReorganizer.plan(nil, pending_days: 7)

      refute Enum.any?(actions, &(&1.kind == :pending and &1.folder.uuid == folder.uuid))
    end
  end

  describe "hook failure (R2)" do
    test "hook raises → record skipped, one hook_error report with the count, never planned as root" do
      catalogue = new_catalogue()
      item = new_item(catalogue)

      {:ok, target} = Storage.create_folder(%{name: "Items"})

      {:ok, folder} =
        Storage.create_folder(%{name: "catalogue-item-#{item.uuid}", parent_uuid: target.uuid})

      {:ok, _item} = Catalogue.update_item(item, %{data: %{"files_folder_uuid" => folder.uuid}})

      Application.put_env(
        :phoenix_kit_catalogue,
        :attachments_parent_folder,
        {RaisingHook, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :item))
      error = Enum.find(actions, &(&1.kind == :hook_error))
      refute is_nil(error)
      assert error.op == :report
      assert error.reason =~ "1 record"
    end

    test "hook returns {:error, _} → same as raising, never treated as root" do
      catalogue = new_catalogue()
      item = new_item(catalogue)

      {:ok, folder} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})
      {:ok, _item} = Catalogue.update_item(item, %{data: %{"files_folder_uuid" => folder.uuid}})

      Application.put_env(
        :phoenix_kit_catalogue,
        :attachments_parent_folder,
        {ErrorHook, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :item and &1.op == :move))
      assert Enum.any?(actions, &(&1.kind == :hook_error))
    end

    test "hook returns {:ok, \"\"} → hook_error, never a CastError (T1)" do
      catalogue = new_catalogue()
      item = new_item(catalogue)

      {:ok, folder} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})
      {:ok, _item} = Catalogue.update_item(item, %{data: %{"files_folder_uuid" => folder.uuid}})

      Application.put_env(
        :phoenix_kit_catalogue,
        :attachments_parent_folder,
        {EmptyStringHook, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :item and &1.op == :move))
      assert Enum.any?(actions, &(&1.kind == :hook_error))
    end

    test "hook returns {:ok, \"junk\"} → hook_error, never a CastError (T1)" do
      catalogue = new_catalogue()
      item = new_item(catalogue)

      {:ok, folder} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})
      {:ok, _item} = Catalogue.update_item(item, %{data: %{"files_folder_uuid" => folder.uuid}})

      Application.put_env(
        :phoenix_kit_catalogue,
        :attachments_parent_folder,
        {JunkUuidHook, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :item and &1.op == :move))
      assert Enum.any?(actions, &(&1.kind == :hook_error))
    end

    test "hook parent answer is upper-cased but a valid uuid → cast+downcased, resolved normally" do
      catalogue = new_catalogue()
      item = new_item(catalogue, %{name: "Käepide"})

      {:ok, target} = Storage.create_folder(%{name: "Items"})
      {:ok, folder} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})

      Process.put(:target_folder, target.uuid)

      Application.put_env(
        :phoenix_kit_catalogue,
        :attachments_parent_folder,
        {UppercaseParentHook, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :item and &1.label == item.name))

      refute is_nil(action)
      assert action.folder.uuid == folder.uuid
      assert action.parent_uuid == target.uuid
      refute Enum.any?(actions, &(&1.kind == :hook_error))
    end
  end

  describe "uncallable configured hook (T3)" do
    test "hook module/function does not exist → hook_error 'not callable', no moves" do
      catalogue = new_catalogue()
      item = new_item(catalogue)

      {:ok, _folder} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})

      Application.put_env(
        :phoenix_kit_catalogue,
        :attachments_parent_folder,
        {PhoenixKitCatalogue.MediaReorganizerTest.NoSuchModule, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :item and &1.op == :move))
      error = Enum.find(actions, &(&1.kind == :hook_error))
      refute is_nil(error)
      assert error.reason =~ "not callable"
    end

    test "name hook module/function does not exist → hook_error, record skipped, parity with the parent hook" do
      catalogue = new_catalogue()
      item = new_item(catalogue, %{name: "Käepide"})

      {:ok, target} = Storage.create_folder(%{name: "Items"})
      {:ok, folder} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})
      {:ok, _item} = Catalogue.update_item(item, %{data: %{"files_folder_uuid" => folder.uuid}})

      Process.put(:target_folder, target.uuid)
      Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})

      Application.put_env(
        :phoenix_kit_catalogue,
        :attachments_folder_name,
        {PhoenixKitCatalogue.MediaReorganizerTest.NoSuchModule, :name}
      )

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :item))
      error = Enum.find(actions, &(&1.kind == :hook_error))
      refute is_nil(error)
    end
  end

  describe "host-named folder under parent (R3)" do
    test "unclaimed host-named folder under the resolved parent is the current folder → noop move, back-fill only" do
      catalogue = new_catalogue()
      item = new_item(catalogue, %{name: "Käepide"})

      {:ok, target} = Storage.create_folder(%{name: "Items"})
      {:ok, host_folder} = Storage.create_folder(%{name: "Nice", parent_uuid: target.uuid})

      # The legacy folder lives under a THIRD, unrelated parent (not root,
      # not the resolved parent) — that's what makes the record a
      # candidate at all; it is unreachable by the module's own lookup
      # order, so the host-named folder under the resolved parent is
      # unambiguously the current folder.
      {:ok, elsewhere} = Storage.create_folder(%{name: "Somewhere else entirely"})

      {:ok, legacy} =
        Storage.create_folder(%{name: "catalogue-item-#{item.uuid}", parent_uuid: elsewhere.uuid})

      Process.put(:target_folder, target.uuid)
      Process.put(:target_name, "Nice")
      Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})
      Application.put_env(:phoenix_kit_catalogue, :attachments_folder_name, {Hook, :name})

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :item and &1.label == item.name))

      refute is_nil(action)
      assert action.folder.uuid == host_folder.uuid
      assert action.parent_uuid == target.uuid
      assert is_function(action.after_move, 0)
      refute Enum.any?(actions, &(&1.kind == :duplicate))

      # The stray legacy twin under the third-party parent is never
      # adopted, but it must not go unreported either.
      relocated = Enum.find(actions, &(&1.kind == :relocated and &1.label == item.name))
      refute is_nil(relocated)
      assert relocated.folder.uuid == legacy.uuid
    end

    test "host-named folder AND a live legacy folder both under the resolved parent → duplicate, no move" do
      catalogue = new_catalogue()
      item = new_item(catalogue, %{name: "Käepide"})

      {:ok, target} = Storage.create_folder(%{name: "Items"})
      {:ok, _host_folder} = Storage.create_folder(%{name: "Nice", parent_uuid: target.uuid})

      {:ok, _legacy} =
        Storage.create_folder(%{name: "catalogue-item-#{item.uuid}", parent_uuid: target.uuid})

      Process.put(:target_folder, target.uuid)
      Process.put(:target_name, "Nice")
      Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})
      Application.put_env(:phoenix_kit_catalogue, :attachments_folder_name, {Hook, :name})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :item and &1.op == :move))
      dup = Enum.find(actions, &(&1.kind == :duplicate and &1.label == item.name))
      refute is_nil(dup)
    end
  end

  describe "orphans exclude claimed folders (R4)" do
    test "a legacy folder a live record currently points at is never also reported as an orphan" do
      catalogue = new_catalogue()
      item = new_item(catalogue)

      {:ok, folder} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})
      {:ok, _item} = Catalogue.update_item(item, %{data: %{"files_folder_uuid" => folder.uuid}})

      Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))
    end
  end

  describe "pointer normalisation (R5)" do
    test "an upper-case pointer still resolves to its (lower-case) live folder" do
      catalogue = new_catalogue()
      item = new_item(catalogue, %{name: "Käepide"})

      {:ok, target} = Storage.create_folder(%{name: "Items"})
      {:ok, folder} = Storage.create_folder(%{name: "Somewhere"})
      upcased = String.upcase(folder.uuid)
      {:ok, _item} = Catalogue.update_item(item, %{data: %{"files_folder_uuid" => upcased}})

      Process.put(:target_folder, target.uuid)
      Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :item and &1.label == item.name))

      refute is_nil(action)
      assert action.folder.uuid == folder.uuid
      assert action.parent_uuid == target.uuid
      # pointer already matches (after normalisation) → no back-fill needed
      assert is_nil(action.after_move)
    end

    test "an upper-case pointer to a pending folder claims it — never trashed" do
      catalogue = new_catalogue()
      item = new_item(catalogue)

      {:ok, folder} =
        Storage.create_folder(%{name: "catalogue-attachment-pending-#{Ecto.UUID.generate()}"})

      upcased = String.upcase(folder.uuid)
      {:ok, _item} = Catalogue.update_item(item, %{data: %{"files_folder_uuid" => upcased}})

      old_time =
        DateTime.utc_now() |> DateTime.add(-10 * 86_400, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(f in Storage.Folder, where: f.uuid == ^folder.uuid),
        set: [inserted_at: old_time]
      )

      actions = MediaReorganizer.plan(nil, pending_days: 7)
      refute Enum.any?(actions, &(&1.kind == :pending and &1.folder.uuid == folder.uuid))
    end
  end

  describe "pending file names batched, trashed-only reason (R6)" do
    test "pending folder whose only file is trashed → reason says N trashed file(s), never empty",
         %{
           user_uuid: user_uuid
         } do
      {:ok, folder} =
        Storage.create_folder(%{name: "catalogue-attachment-pending-#{Ecto.UUID.generate()}"})

      {:ok, _file} =
        Storage.create_file(%{
          original_file_name: "gone.pdf",
          file_name: "gone.pdf",
          mime_type: "application/pdf",
          file_type: "document",
          ext: "pdf",
          file_checksum: "checksum-trashed-pending",
          user_file_checksum: "user-checksum-trashed-pending",
          size: 10,
          status: "trashed",
          folder_uuid: folder.uuid,
          user_uuid: user_uuid
        })

      actions = MediaReorganizer.plan(nil, pending_days: 7)
      action = Enum.find(actions, &(&1.kind == :pending and &1.folder.uuid == folder.uuid))

      refute is_nil(action)
      assert action.op == :report
      assert action.reason =~ "1 trashed file"
    end
  end

  describe "converging targets (R7/E3)" do
    test "two records with different current folders that would both move to the same destination → duplicate, no moves" do
      catalogue = new_catalogue()
      item1 = new_item(catalogue, %{name: "First"})
      item2 = new_item(catalogue, %{name: "Second"})

      {:ok, target} = Storage.create_folder(%{name: "Items"})
      {:ok, folder1} = Storage.create_folder(%{name: "catalogue-item-#{item1.uuid}"})
      {:ok, folder2} = Storage.create_folder(%{name: "catalogue-item-#{item2.uuid}"})

      Process.put(:target_folder, target.uuid)
      Process.put(:target_name, "Same name")
      Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})
      Application.put_env(:phoenix_kit_catalogue, :attachments_folder_name, {Hook, :name})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :item and &1.op == :move))

      dup =
        Enum.find(
          actions,
          &(&1.kind == :duplicate and &1.label =~ "First" and &1.label =~ "Second")
        )

      refute is_nil(dup)
      refute Enum.any?([folder1, folder2], fn f -> is_nil(f) end)
    end

    test "an already-in-place (noop) record does not block a real mover targeting the same destination (U2/F6)" do
      catalogue = new_catalogue()
      item1 = new_item(catalogue, %{name: "First"})
      item2 = new_item(catalogue, %{name: "Second"})

      {:ok, target} = Storage.create_folder(%{name: "Items"})

      {:ok, already_placed} =
        Storage.create_folder(%{name: "Same name", parent_uuid: target.uuid})

      {:ok, _item1} =
        Catalogue.update_item(item1, %{data: %{"files_folder_uuid" => already_placed.uuid}})

      {:ok, folder2} = Storage.create_folder(%{name: "catalogue-item-#{item2.uuid}"})

      # item2 is on the POINTER track too (never triggers the host-named-
      # under-parent lookup at all) — isolates convergence detection from
      # the (unrelated, correct) ambiguity path a live host-named folder
      # would otherwise trigger for a NAME-track record.
      {:ok, _item2} =
        Catalogue.update_item(item2, %{data: %{"files_folder_uuid" => folder2.uuid}})

      Process.put(:target_folder, target.uuid)
      Process.put(:target_name, "Same name")
      Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})
      Application.put_env(:phoenix_kit_catalogue, :attachments_folder_name, {Hook, :name})

      actions = MediaReorganizer.plan(nil, [])

      # item1 is already correctly placed — nothing to plan, never a
      # duplicate.
      refute Enum.any?(actions, &(&1.kind == :item and &1.label == "First"))
      refute Enum.any?(actions, &(&1.kind == :duplicate))

      # item2 is a REAL move to the very same destination — a noop record
      # already sitting there must never drag it into `:duplicate`.
      move = Enum.find(actions, &(&1.kind == :item and &1.op == :move and &1.label == "Second"))
      refute is_nil(move)
      assert move.parent_uuid == target.uuid
      assert move.name == "Same name"
    end
  end

  describe "explicit nil from a hook never moves a non-root folder to root (F1)" do
    test "record's pointer already names a folder under a parent, hook answers nil → no move, only back-fill + hook_nil report" do
      catalogue = new_catalogue()
      item = new_item(catalogue, %{name: "Käepide"})

      {:ok, target} = Storage.create_folder(%{name: "Items"})
      {:ok, folder} = Storage.create_folder(%{name: "Real folder", parent_uuid: target.uuid})
      {:ok, _item} = Catalogue.update_item(item, %{data: %{"files_folder_uuid" => folder.uuid}})

      # Pointer already names the live folder under `target` — the current
      # folder is unambiguous regardless of what the parent hook says.
      # `Hook.parent/3`'s default clause answers `nil` (root) here because
      # `:target_folder` is never set for this record.
      Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :item and &1.op == :move and &1.parent_uuid == nil))

      hook_nil = Enum.find(actions, &(&1.kind == :hook_nil))
      refute is_nil(hook_nil)
      assert hook_nil.op == :report
      assert hook_nil.reason =~ "1 record"

      # Pointer already matches `folder` — nothing left to plan for the
      # item itself once the false move-to-root is suppressed.
      refute Enum.any?(actions, &(&1.kind == :item))
    end

    test "the hook_nil report aggregates a count across every affected record" do
      catalogue = new_catalogue()
      item1 = new_item(catalogue, %{name: "First"})
      item2 = new_item(catalogue, %{name: "Second"})

      {:ok, target} = Storage.create_folder(%{name: "Items"})
      {:ok, folder1} = Storage.create_folder(%{name: "Real folder 1", parent_uuid: target.uuid})
      {:ok, folder2} = Storage.create_folder(%{name: "Real folder 2", parent_uuid: target.uuid})

      {:ok, _item1} =
        Catalogue.update_item(item1, %{data: %{"files_folder_uuid" => folder1.uuid}})

      {:ok, _item2} =
        Catalogue.update_item(item2, %{data: %{"files_folder_uuid" => folder2.uuid}})

      Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      hook_nil = Enum.find(actions, &(&1.kind == :hook_nil))
      refute is_nil(hook_nil)
      assert hook_nil.reason =~ "2 record"
    end
  end

  describe "legacy folder relocated elsewhere (catalogue-specific)" do
    test "legacy folder live under an ACTUAL parent, hook resolves elsewhere → reported :relocated, not adopted" do
      catalogue = new_catalogue()
      item = new_item(catalogue)

      {:ok, target} = Storage.create_folder(%{name: "Items"})
      {:ok, elsewhere} = Storage.create_folder(%{name: "Some other container"})

      {:ok, _legacy} =
        Storage.create_folder(%{name: "catalogue-item-#{item.uuid}", parent_uuid: elsewhere.uuid})

      Process.put(:target_folder, target.uuid)
      Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :item and &1.op == :move))
      relocated = Enum.find(actions, &(&1.kind == :relocated and &1.label == item.name))
      refute is_nil(relocated)
    end

    test "F1 name-track: no pointer, legacy folder under a real parent, hook answers root → adopted, back-fill only, hook_nil (U1)" do
      catalogue = new_catalogue()
      item = new_item(catalogue)

      {:ok, elsewhere} = Storage.create_folder(%{name: "Some other container"})

      {:ok, legacy} =
        Storage.create_folder(%{name: "catalogue-item-#{item.uuid}", parent_uuid: elsewhere.uuid})

      # `Hook.parent/3`'s default clause answers `nil` (root) here because
      # `:target_folder` is never set for this record.
      Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      # No move to root, no `:relocated` — the legacy folder under
      # `elsewhere` IS treated as the current folder.
      refute Enum.any?(actions, &(&1.kind == :item and &1.op == :move and &1.parent_uuid == nil))
      refute Enum.any?(actions, &(&1.kind == :relocated and &1.label == item.name))

      hook_nil = Enum.find(actions, &(&1.kind == :hook_nil))
      refute is_nil(hook_nil)
      assert hook_nil.reason =~ "1 record"
      assert hook_nil.reason =~ item.name

      # The only action planned for the record is the (no-op location,
      # back-fill-only) move that repairs its pointer.
      action = Enum.find(actions, &(&1.kind == :item and &1.label == item.name))
      refute is_nil(action)
      assert action.folder.uuid == legacy.uuid
      assert action.parent_uuid == elsewhere.uuid
      assert is_nil(action.name)
      assert is_function(action.after_move, 0)

      assert :ok = action.after_move.()

      reloaded = Catalogue.get_item!(item.uuid)
      assert reloaded.data["files_folder_uuid"] == legacy.uuid
    end

    test "F1 name-track: TWO live legacy copies under different real parents, hook answers root → no adoption, no hook_nil, both :relocated (U1)" do
      catalogue = new_catalogue()
      item = new_item(catalogue)

      {:ok, elsewhere1} = Storage.create_folder(%{name: "Container one"})
      {:ok, elsewhere2} = Storage.create_folder(%{name: "Container two"})

      {:ok, copy1} =
        Storage.create_folder(%{
          name: "catalogue-item-#{item.uuid}",
          parent_uuid: elsewhere1.uuid
        })

      {:ok, copy2} =
        Storage.create_folder(%{
          name: "catalogue-item-#{item.uuid}",
          parent_uuid: elsewhere2.uuid
        })

      # `Hook.parent/3`'s default clause answers `nil` (root) here because
      # `:target_folder` is never set for this record.
      Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      # Two live copies under real (but different) parents is NOT the
      # single-copy F1 case — the module cannot pick one, so it stays
      # unresolved: no adoption, no back-fill, no `:hook_nil`.
      refute Enum.any?(actions, &(&1.kind == :item and &1.label == item.name))
      refute Enum.any?(actions, &(&1.kind == :hook_nil))

      relocated_uuids =
        actions
        |> Enum.filter(&(&1.kind == :relocated and &1.label == item.name))
        |> Enum.map(& &1.folder.uuid)

      assert Enum.sort(relocated_uuids) == Enum.sort([copy1.uuid, copy2.uuid])
    end

    test "pointer already correct AND TWO live legacy-named twins exist elsewhere → both are reported :relocated (F5)" do
      catalogue = new_catalogue()
      item = new_item(catalogue, %{name: "Käepide"})

      {:ok, real_folder} = Storage.create_folder(%{name: "Somewhere real"})
      {:ok, elsewhere1} = Storage.create_folder(%{name: "Container one"})
      {:ok, elsewhere2} = Storage.create_folder(%{name: "Container two"})

      {:ok, twin1} =
        Storage.create_folder(%{
          name: "catalogue-item-#{item.uuid}",
          parent_uuid: elsewhere1.uuid
        })

      {:ok, twin2} =
        Storage.create_folder(%{
          name: "catalogue-item-#{item.uuid}",
          parent_uuid: elsewhere2.uuid
        })

      {:ok, _item} =
        Catalogue.update_item(item, %{data: %{"files_folder_uuid" => real_folder.uuid}})

      Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :item and &1.op == :move))

      relocated_uuids =
        actions
        |> Enum.filter(&(&1.kind == :relocated and &1.label == item.name))
        |> Enum.map(& &1.folder.uuid)

      assert Enum.sort(relocated_uuids) == Enum.sort([twin1.uuid, twin2.uuid])
    end

    test "resolved via legacy name at root, TWO extra legacy-named twins under third-party parents → both reported :relocated (F5)" do
      catalogue = new_catalogue()
      item = new_item(catalogue)

      {:ok, at_root} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})
      {:ok, elsewhere1} = Storage.create_folder(%{name: "Container one"})
      {:ok, elsewhere2} = Storage.create_folder(%{name: "Container two"})

      {:ok, twin1} =
        Storage.create_folder(%{
          name: "catalogue-item-#{item.uuid}",
          parent_uuid: elsewhere1.uuid
        })

      {:ok, twin2} =
        Storage.create_folder(%{
          name: "catalogue-item-#{item.uuid}",
          parent_uuid: elsewhere2.uuid
        })

      Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      action = Enum.find(actions, &(&1.kind == :item and &1.label == item.name))
      refute is_nil(action)
      assert action.folder.uuid == at_root.uuid

      relocated_uuids =
        actions
        |> Enum.filter(&(&1.kind == :relocated and &1.label == item.name))
        |> Enum.map(& &1.folder.uuid)

      assert Enum.sort(relocated_uuids) == Enum.sort([twin1.uuid, twin2.uuid])
    end

    test "pointer already correct AND a live legacy-named twin exists elsewhere → the twin is reported :relocated" do
      catalogue = new_catalogue()
      item = new_item(catalogue, %{name: "Käepide"})

      {:ok, real_folder} = Storage.create_folder(%{name: "Somewhere real"})
      {:ok, twin} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})

      {:ok, _item} =
        Catalogue.update_item(item, %{data: %{"files_folder_uuid" => real_folder.uuid}})

      Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      # The record's actual (pointer) folder is untouched...
      refute Enum.any?(actions, &(&1.kind == :item and &1.op == :move))
      # ...but the stray legacy-named twin is neither silently dropped
      # nor mistaken for an orphan (the record is alive).
      refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == twin.uuid))
      relocated = Enum.find(actions, &(&1.kind == :relocated and &1.label == item.name))
      refute is_nil(relocated)
      assert relocated.folder.uuid == twin.uuid
    end

    test "reason names the actual place: at root vs under the record's own target parent (R3-4)" do
      catalogue = new_catalogue()
      item = new_item(catalogue, %{name: "Käepide"})

      {:ok, target} = Storage.create_folder(%{name: "Items"})
      {:ok, real_folder} = Storage.create_folder(%{name: "Real", parent_uuid: target.uuid})
      {:ok, twin_root} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})

      {:ok, twin_under_target} =
        Storage.create_folder(%{name: "catalogue-item-#{item.uuid}", parent_uuid: target.uuid})

      {:ok, _item} =
        Catalogue.update_item(item, %{data: %{"files_folder_uuid" => real_folder.uuid}})

      Process.put(:target_folder, target.uuid)
      Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      root_relocated =
        Enum.find(actions, &(&1.kind == :relocated and &1.folder.uuid == twin_root.uuid))

      refute is_nil(root_relocated)
      assert root_relocated.reason =~ "media root"

      under_target_relocated =
        Enum.find(actions, &(&1.kind == :relocated and &1.folder.uuid == twin_under_target.uuid))

      refute is_nil(under_target_relocated)
      assert under_target_relocated.reason =~ "target parent"
      assert under_target_relocated.reason =~ "(N)"
    end

    test "reason names the third-party parent by name when it is neither root nor the target (R3-4)" do
      catalogue = new_catalogue()
      item = new_item(catalogue, %{name: "Käepide"})

      {:ok, target} = Storage.create_folder(%{name: "Items"})
      {:ok, real_folder} = Storage.create_folder(%{name: "Real", parent_uuid: target.uuid})
      {:ok, elsewhere} = Storage.create_folder(%{name: "Old Container"})

      {:ok, twin_elsewhere} =
        Storage.create_folder(%{name: "catalogue-item-#{item.uuid}", parent_uuid: elsewhere.uuid})

      {:ok, _item} =
        Catalogue.update_item(item, %{data: %{"files_folder_uuid" => real_folder.uuid}})

      Process.put(:target_folder, target.uuid)
      Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      relocated =
        Enum.find(actions, &(&1.kind == :relocated and &1.folder.uuid == twin_elsewhere.uuid))

      refute is_nil(relocated)
      assert relocated.reason =~ "Old Container"
    end
  end

  describe "light selects never pull the jsonb data column (T8)" do
    test "candidate-detection queries select the pointer via a jsonb fragment, not the raw data column" do
      catalogue = new_catalogue()
      _item = new_item(catalogue)

      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        {__MODULE__, ref},
        [:phoenix_kit_catalogue, :test, :repo, :query],
        fn _event, _measurements, %{query: query}, _config ->
          send(test_pid, {:query, ref, query})
        end,
        nil
      )

      try do
        MediaReorganizer.plan(nil, [])
      after
        :telemetry.detach({__MODULE__, ref})
      end

      queries = collect_queries(ref)

      # The three light candidate-detection queries share this clause and
      # nothing else in the plan does.
      light_queries = Enum.filter(queries, &(&1 =~ "!= 'deleted'"))

      refute Enum.empty?(light_queries)
      assert Enum.any?(light_queries, &(&1 =~ "->>"))
      refute Enum.any?(light_queries, &Regex.match?(~r/"data"(?!->)/, &1))
    end
  end

  defp collect_queries(ref) do
    receive do
      {:query, ^ref, query} -> [query | collect_queries(ref)]
    after
      0 -> []
    end
  end

  describe "batched queries: count is constant regardless of candidate count (X1/R6)" do
    test "the plan issues the same number of queries for 1 candidate as for 10" do
      catalogue = new_catalogue()
      {:ok, target} = Storage.create_folder(%{name: "Items"})

      Process.put(:target_folder, target.uuid)
      Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})

      create_legacy_items(catalogue, 1)
      count_with_1 = count_plan_queries()

      create_legacy_items(catalogue, 9)
      count_with_10 = count_plan_queries()

      assert count_with_1 == count_with_10
    end
  end

  defp create_legacy_items(catalogue, n) do
    for i <- 1..n do
      item = new_item(catalogue, %{name: "Bulk #{System.unique_integer([:positive])}-#{i}"})
      {:ok, _folder} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})
      item
    end
  end

  defp count_plan_queries do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:phoenix_kit_catalogue, :test, :repo, :query],
      fn _event, _measurements, %{query: query}, _config ->
        send(test_pid, {:query, ref, query})
      end,
      nil
    )

    try do
      MediaReorganizer.plan(nil, [])
    after
      :telemetry.detach({__MODULE__, ref})
    end

    length(collect_queries(ref))
  end

  describe "R10 deterministic order (T6)" do
    test "move actions are ordered catalogues, then categories, then items, each by inserted_at" do
      catalogue = new_catalogue(%{name: "Root cat"})

      {:ok, category} =
        Catalogue.create_category(%{name: "Cat A", catalogue_uuid: catalogue.uuid})

      item = new_item(catalogue, %{name: "Item A"})

      {:ok, target} = Storage.create_folder(%{name: "Items"})

      # An item resolved via its live pointer (pointer-track) and a
      # category resolved via its legacy name (name-track) — mixing both
      # resolution tracks is exactly what scrambled the order before the
      # fix (pointer_entries ++ name_entries).
      {:ok, item_folder} = Storage.create_folder(%{name: "somewhere-item"})

      {:ok, _item} =
        Catalogue.update_item(item, %{data: %{"files_folder_uuid" => item_folder.uuid}})

      {:ok, cat_folder} = Storage.create_folder(%{name: "catalogue-#{catalogue.uuid}"})

      {:ok, category_folder} =
        Storage.create_folder(%{name: "catalogue-category-#{category.uuid}"})

      Process.put(:target_folder, target.uuid)
      Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      kinds_in_order =
        actions
        |> Enum.filter(&(&1.op == :move))
        |> Enum.map(& &1.kind)

      assert kinds_in_order == [:catalogue, :category, :item]
      assert Enum.any?(actions, &(&1.folder && &1.folder.uuid == cat_folder.uuid))
      assert Enum.any?(actions, &(&1.folder && &1.folder.uuid == category_folder.uuid))
    end
  end

  describe "records passed to host hooks are full rows, never light/partial structs" do
    test "a nested category's parent hook sees its real parent_uuid, not treated as top-level" do
      catalogue = new_catalogue()

      {:ok, parent_category} =
        Catalogue.create_category(%{name: "Parent", catalogue_uuid: catalogue.uuid})

      {:ok, child_category} =
        Catalogue.create_category(%{
          name: "Child",
          catalogue_uuid: catalogue.uuid,
          parent_uuid: parent_category.uuid
        })

      {:ok, root_folder} = Storage.create_folder(%{name: "Catalogue"})
      {:ok, nested_parent_folder} = Storage.create_folder(%{name: "Parent's own folder"})

      {:ok, _child_folder} =
        Storage.create_folder(%{name: "catalogue-category-#{child_category.uuid}"})

      Process.put(:root_folder, root_folder.uuid)
      Process.put(:nested_parent_folder, nested_parent_folder.uuid)

      Application.put_env(
        :phoenix_kit_catalogue,
        :attachments_parent_folder,
        {NestedCategoryHook, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])

      child_action = Enum.find(actions, &(&1.kind == :category and &1.label == "Child"))

      refute is_nil(child_action)
      refute child_action.parent_uuid == root_folder.uuid
      assert child_action.parent_uuid == nested_parent_folder.uuid
    end

    test "the parent hook receives the category's full row, parent_uuid populated" do
      catalogue = new_catalogue()

      {:ok, parent_category} =
        Catalogue.create_category(%{name: "Parent", catalogue_uuid: catalogue.uuid})

      {:ok, child_category} =
        Catalogue.create_category(%{
          name: "Child",
          catalogue_uuid: catalogue.uuid,
          parent_uuid: parent_category.uuid
        })

      {:ok, _child_folder} =
        Storage.create_folder(%{name: "catalogue-category-#{child_category.uuid}"})

      Process.put(:strict_child_uuid, child_category.uuid)

      Application.put_env(
        :phoenix_kit_catalogue,
        :attachments_parent_folder,
        {StrictCategoryHook, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :hook_error))
      assert Enum.any?(actions, &(&1.kind == :category and &1.label == "Child"))
    end
  end

  describe "orphan scope from ANY successful hook answer (U4/V2)" do
    test "a candidate that ends up ambiguous still adds its resolved parent to the orphan scope" do
      catalogue = new_catalogue()
      item = new_item(catalogue, %{name: "Ambiguous item"})

      {:ok, target} = Storage.create_folder(%{name: "Items"})
      {:ok, _host_folder} = Storage.create_folder(%{name: "Nice", parent_uuid: target.uuid})

      {:ok, _legacy} =
        Storage.create_folder(%{name: "catalogue-item-#{item.uuid}", parent_uuid: target.uuid})

      {:ok, orphan_folder} =
        Storage.create_folder(%{
          name: "catalogue-item-#{Ecto.UUID.generate()}",
          parent_uuid: target.uuid
        })

      Process.put(:target_folder, target.uuid)
      Process.put(:target_name, "Nice")
      Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})
      Application.put_env(:phoenix_kit_catalogue, :attachments_folder_name, {Hook, :name})

      actions = MediaReorganizer.plan(nil, [])

      # The record itself never resolves to a current folder (ambiguous)…
      assert Enum.any?(actions, &(&1.kind == :duplicate and &1.label == item.name))

      # …but its hook call still successfully answered `target`, so an
      # unrelated orphan legacy folder living under `target` is found —
      # never derived from where a folder happens to sit.
      orphan = Enum.find(actions, &(&1.kind == :orphan and &1.folder.uuid == orphan_folder.uuid))
      refute is_nil(orphan)
    end
  end

  describe "orphan and pending folders are ordered (U5)" do
    test "orphan folders are returned in inserted_at order, not physical/query order" do
      {:ok, folder_a} = Storage.create_folder(%{name: "catalogue-item-#{Ecto.UUID.generate()}"})
      {:ok, folder_b} = Storage.create_folder(%{name: "catalogue-item-#{Ecto.UUID.generate()}"})
      {:ok, folder_c} = Storage.create_folder(%{name: "catalogue-item-#{Ecto.UUID.generate()}"})

      [{folder_c, -30}, {folder_a, -20}, {folder_b, -10}]
      |> Enum.each(fn {folder, offset} ->
        time = DateTime.utc_now() |> DateTime.add(offset, :second) |> DateTime.truncate(:second)

        Repo.update_all(
          from(f in Storage.Folder, where: f.uuid == ^folder.uuid),
          set: [inserted_at: time]
        )
      end)

      actions = MediaReorganizer.plan(nil, [])

      orphan_uuids =
        actions |> Enum.filter(&(&1.kind == :orphan)) |> Enum.map(& &1.folder.uuid)

      assert orphan_uuids == [folder_c.uuid, folder_a.uuid, folder_b.uuid]
    end

    test "pending folders are returned in inserted_at order", %{user_uuid: user_uuid} do
      {:ok, folder_a} =
        Storage.create_folder(%{name: "catalogue-attachment-pending-#{Ecto.UUID.generate()}"})

      {:ok, folder_b} =
        Storage.create_folder(%{name: "catalogue-attachment-pending-#{Ecto.UUID.generate()}"})

      # A non-empty pending folder is always reported regardless of age —
      # only its (query) ORDER is under test here.
      for {folder, offset, name} <- [{folder_b, -20, "b.pdf"}, {folder_a, -10, "a.pdf"}] do
        time = DateTime.utc_now() |> DateTime.add(offset, :second) |> DateTime.truncate(:second)

        Repo.update_all(
          from(f in Storage.Folder, where: f.uuid == ^folder.uuid),
          set: [inserted_at: time]
        )

        {:ok, _file} =
          Storage.create_file(%{
            original_file_name: name,
            file_name: name,
            mime_type: "application/pdf",
            file_type: "document",
            ext: "pdf",
            file_checksum: "checksum-order-#{name}",
            user_file_checksum: "user-checksum-order-#{name}",
            size: 5,
            status: "active",
            folder_uuid: folder.uuid,
            user_uuid: user_uuid
          })
      end

      actions = MediaReorganizer.plan(nil, pending_days: 7)

      pending_uuids =
        actions |> Enum.filter(&(&1.kind == :pending)) |> Enum.map(& &1.folder.uuid)

      assert pending_uuids == [folder_b.uuid, folder_a.uuid]
    end
  end

  describe "hook log lines name {mod, fun} and the resource kind (U6)" do
    import ExUnit.CaptureLog

    test "a bad hook return value is logged, not only a raise/exit" do
      catalogue = new_catalogue()
      item = new_item(catalogue)
      {:ok, folder} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})
      {:ok, _item} = Catalogue.update_item(item, %{data: %{"files_folder_uuid" => folder.uuid}})

      Application.put_env(
        :phoenix_kit_catalogue,
        :attachments_parent_folder,
        {JunkUuidHook, :parent}
      )

      log = capture_log(fn -> MediaReorganizer.plan(nil, []) end)

      assert log =~ "JunkUuidHook, :parent}"
      assert log =~ "kind: :item"
    end
  end

  describe "hook config validation is uniform for parent AND name hooks (U7/V3)" do
    test "a garbage (non-tuple) parent hook config → hook_error, never silently 'no hook'" do
      catalogue = new_catalogue()
      item = new_item(catalogue)
      {:ok, _folder} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})

      Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, :not_a_tuple)

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :item and &1.op == :move))
      error = Enum.find(actions, &(&1.kind == :hook_error))
      refute is_nil(error)
      assert error.reason =~ "not a {module, function} tuple"
    end

    test "a garbage (non-tuple) name hook config → hook_error, record skipped" do
      catalogue = new_catalogue()
      item = new_item(catalogue, %{name: "Käepide"})

      {:ok, target} = Storage.create_folder(%{name: "Items"})
      {:ok, folder} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})
      {:ok, _item} = Catalogue.update_item(item, %{data: %{"files_folder_uuid" => folder.uuid}})

      Process.put(:target_folder, target.uuid)
      Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})
      Application.put_env(:phoenix_kit_catalogue, :attachments_folder_name, :not_a_tuple)

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :item))
      error = Enum.find(actions, &(&1.kind == :hook_error))
      refute is_nil(error)
    end
  end

  describe "hook_error/hook_nil reports list record labels (U8)" do
    test "hook_error report lists the failed records' labels" do
      catalogue = new_catalogue()
      item1 = new_item(catalogue, %{name: "First"})
      item2 = new_item(catalogue, %{name: "Second"})
      {:ok, folder1} = Storage.create_folder(%{name: "catalogue-item-#{item1.uuid}"})
      {:ok, folder2} = Storage.create_folder(%{name: "catalogue-item-#{item2.uuid}"})

      {:ok, _item1} =
        Catalogue.update_item(item1, %{data: %{"files_folder_uuid" => folder1.uuid}})

      {:ok, _item2} =
        Catalogue.update_item(item2, %{data: %{"files_folder_uuid" => folder2.uuid}})

      Application.put_env(
        :phoenix_kit_catalogue,
        :attachments_parent_folder,
        {ErrorHook, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])
      error = Enum.find(actions, &(&1.kind == :hook_error))

      refute is_nil(error)
      assert error.reason =~ "First"
      assert error.reason =~ "Second"
    end

    test "hook_error report truncates to 10 labels with a '… and N more' tail" do
      catalogue = new_catalogue()

      items =
        for n <- 1..12 do
          item = new_item(catalogue, %{name: "Item #{n}"})
          {:ok, folder} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})

          {:ok, item} =
            Catalogue.update_item(item, %{data: %{"files_folder_uuid" => folder.uuid}})

          item
        end

      Application.put_env(
        :phoenix_kit_catalogue,
        :attachments_parent_folder,
        {ErrorHook, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])
      error = Enum.find(actions, &(&1.kind == :hook_error))

      refute is_nil(error)
      assert error.reason =~ "12 record(s)"
      assert error.reason =~ "and 2 more"
      refute error.reason =~ Enum.at(items, 11).name
    end
  end

  describe "ambiguous entries still report every extra live copy (U9)" do
    test "host-named + legacy-under-target ambiguity still reports a THIRD live copy as :relocated" do
      catalogue = new_catalogue()
      item = new_item(catalogue, %{name: "Käepide"})

      {:ok, target} = Storage.create_folder(%{name: "Items"})
      {:ok, _host_folder} = Storage.create_folder(%{name: "Nice", parent_uuid: target.uuid})

      {:ok, _legacy_under_target} =
        Storage.create_folder(%{name: "catalogue-item-#{item.uuid}", parent_uuid: target.uuid})

      {:ok, elsewhere} = Storage.create_folder(%{name: "Somewhere else"})

      {:ok, third_copy} =
        Storage.create_folder(%{name: "catalogue-item-#{item.uuid}", parent_uuid: elsewhere.uuid})

      Process.put(:target_folder, target.uuid)
      Process.put(:target_name, "Nice")
      Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})
      Application.put_env(:phoenix_kit_catalogue, :attachments_folder_name, {Hook, :name})

      actions = MediaReorganizer.plan(nil, [])

      dup = Enum.find(actions, &(&1.kind == :duplicate and &1.label == item.name))
      refute is_nil(dup)

      relocated =
        Enum.find(actions, &(&1.kind == :relocated and &1.folder.uuid == third_copy.uuid))

      refute is_nil(relocated)
    end

    test "legacy-under-target + legacy-at-root ambiguity still reports a THIRD live copy as :relocated" do
      catalogue = new_catalogue()
      item = new_item(catalogue)

      {:ok, target} = Storage.create_folder(%{name: "Items"})

      {:ok, _under_target} =
        Storage.create_folder(%{name: "catalogue-item-#{item.uuid}", parent_uuid: target.uuid})

      {:ok, _at_root} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})

      {:ok, elsewhere} = Storage.create_folder(%{name: "Somewhere else"})

      {:ok, third_copy} =
        Storage.create_folder(%{name: "catalogue-item-#{item.uuid}", parent_uuid: elsewhere.uuid})

      Process.put(:target_folder, target.uuid)
      Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      dup = Enum.find(actions, &(&1.kind == :duplicate and &1.label == item.name))
      refute is_nil(dup)

      relocated =
        Enum.find(actions, &(&1.kind == :relocated and &1.folder.uuid == third_copy.uuid))

      refute is_nil(relocated)
    end
  end

  describe "a raising :pdf hook is guarded (V6)" do
    test "raise in the configured :pdf hook → hook_error report, plan does not crash", %{
      user_uuid: user_uuid
    } do
      Application.put_env(
        :phoenix_kit_catalogue,
        :attachments_parent_folder,
        {RaisingPdfHook, :parent}
      )

      {:ok, file} =
        Storage.create_file(%{
          original_file_name: "manual.pdf",
          file_name: "manual.pdf",
          mime_type: "application/pdf",
          file_type: "document",
          ext: "pdf",
          file_checksum: "checksum-v6",
          user_file_checksum: "user-checksum-v6",
          size: 20,
          status: "active",
          user_uuid: user_uuid
        })

      {:ok, _pdf} =
        %Pdf{}
        |> Pdf.changeset(%{
          file_uuid: file.uuid,
          original_filename: "manual.pdf",
          byte_size: 20,
          status: "active"
        })
        |> Repo.insert()

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :pdf))
      error = Enum.find(actions, &(&1.kind == :hook_error and &1.label =~ "pdf"))
      refute is_nil(error)
    end
  end

  describe "a :pdf hook returning something other than {:ok, uuid}/nil is a hook failure, not silence" do
    test "hook returns {:error, _} → hook_error report, never silently 'no library'", %{
      user_uuid: user_uuid
    } do
      Application.put_env(
        :phoenix_kit_catalogue,
        :attachments_parent_folder,
        {ErrorPdfHook, :parent}
      )

      {:ok, file} =
        Storage.create_file(%{
          original_file_name: "manual.pdf",
          file_name: "manual.pdf",
          mime_type: "application/pdf",
          file_type: "document",
          ext: "pdf",
          file_checksum: "checksum-pdf-error",
          user_file_checksum: "user-checksum-pdf-error",
          size: 20,
          status: "active",
          user_uuid: user_uuid
        })

      {:ok, _pdf} =
        %Pdf{}
        |> Pdf.changeset(%{
          file_uuid: file.uuid,
          original_filename: "manual.pdf",
          byte_size: 20,
          status: "active"
        })
        |> Repo.insert()

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :pdf))
      error = Enum.find(actions, &(&1.kind == :hook_error and &1.label =~ "pdf"))
      refute is_nil(error)
    end

    test "hook returns {:ok, \"junk\"} (non-uuid) → hook_error report, never a CastError", %{
      user_uuid: user_uuid
    } do
      Application.put_env(
        :phoenix_kit_catalogue,
        :attachments_parent_folder,
        {JunkUuidPdfHook, :parent}
      )

      {:ok, file} =
        Storage.create_file(%{
          original_file_name: "manual.pdf",
          file_name: "manual.pdf",
          mime_type: "application/pdf",
          file_type: "document",
          ext: "pdf",
          file_checksum: "checksum-pdf-junk",
          user_file_checksum: "user-checksum-pdf-junk",
          size: 20,
          status: "active",
          user_uuid: user_uuid
        })

      {:ok, _pdf} =
        %Pdf{}
        |> Pdf.changeset(%{
          file_uuid: file.uuid,
          original_filename: "manual.pdf",
          byte_size: 20,
          status: "active"
        })
        |> Repo.insert()

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :pdf))
      error = Enum.find(actions, &(&1.kind == :hook_error and &1.label =~ "pdf"))
      refute is_nil(error)
    end
  end

  # Every other test here inspects `plan/2`'s raw maps. This one hands the
  # source to core's real engine (shipped in phoenix_kit 2.24.0; the pin
  # floor is older, hence the guard): the maps must pass `Action.new!/1`,
  # the move and pointer back-fill must apply, and a second run must find
  # nothing left to do.
  describe "end to end through core's Reorganizer engine" do
    @engine PhoenixKit.Modules.Storage.Reorganizer

    unless Code.ensure_loaded?(@engine) do
      @tag skip: "phoenix_kit without Storage.Reorganizer"
    end

    test "a legacy root folder is moved, renamed, back-filled, and a rerun is a no-op" do
      catalogue = new_catalogue()
      item = new_item(catalogue, %{name: "Handle"})

      {:ok, target} = Storage.create_folder(%{name: "Items"})
      {:ok, legacy} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})

      Process.put(:target_folder, target.uuid)
      Process.put(:target_name, "Handle media")
      Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})
      Application.put_env(:phoenix_kit_catalogue, :attachments_folder_name, {Hook, :name})

      {:ok, report} = @engine.run(nil, apply?: true, sources: [MediaReorganizer])

      action = Enum.find(report.actions, &(&1.kind == :item and &1.label == "Handle"))
      refute is_nil(action)
      assert action.outcome not in [:failed, :conflict], inspect(action)

      moved = Repo.get!(PhoenixKit.Modules.Storage.Folder, legacy.uuid)
      assert moved.parent_uuid == target.uuid
      assert moved.name == "Handle media"
      assert Repo.get!(Item, item.uuid).data["files_folder_uuid"] == legacy.uuid

      {:ok, rerun} = @engine.run(nil, apply?: false, sources: [MediaReorganizer])
      refute Enum.any?(rerun.actions, &(&1.kind == :item))
    end
  end
end
