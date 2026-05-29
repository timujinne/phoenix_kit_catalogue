defmodule PhoenixKitCatalogue.FoldersTest do
  use PhoenixKitCatalogue.DataCase, async: true

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Schemas.Folder

  # ── Helpers ──────────────────────────────────────────────────────

  defp create_folder(attrs) do
    {:ok, f} = Catalogue.create_folder(Map.merge(%{name: "Folder"}, attrs))
    f
  end

  defp create_catalogue(attrs) do
    {:ok, c} = Catalogue.create_catalogue(Map.merge(%{name: "Catalogue"}, attrs))
    c
  end

  defp tree_uuids(opts \\ []),
    do: Catalogue.list_folder_tree(opts) |> Enum.map(fn {f, d} -> {f.uuid, d} end)

  # ═══════════════════════════════════════════════════════════════════
  # Tree + depth
  # ═══════════════════════════════════════════════════════════════════

  describe "list_folder_tree/1" do
    test "returns folders depth-first, newest-first within each level" do
      # `create_folder` front-inserts (see `front_folder_position/1`): a
      # new folder sorts to the top of its level so it's immediately
      # visible. So at the root, b (created after a) comes first; then the
      # DFS descends a's subtree.
      a = create_folder(%{name: "A"})
      b = create_folder(%{name: "B"})
      a1 = create_folder(%{name: "A1", parent_uuid: a.uuid})
      a1x = create_folder(%{name: "A1x", parent_uuid: a1.uuid})

      assert tree_uuids() == [
               {b.uuid, 0},
               {a.uuid, 0},
               {a1.uuid, 1},
               {a1x.uuid, 2}
             ]
    end

    test ":active mode excludes deleted folders" do
      a = create_folder(%{name: "A"})
      {:ok, _} = Catalogue.trash_folder(a)

      assert tree_uuids(mode: :active) == []
    end

    test "child of a trashed parent orphan-promotes to root in active mode" do
      parent = create_folder(%{name: "Parent"})
      child = create_folder(%{name: "Child", parent_uuid: parent.uuid})
      {:ok, _} = Catalogue.trash_folder(parent)

      # Parent is gone from the active set; child surfaces at root (depth 0).
      assert tree_uuids(mode: :active) == [{child.uuid, 0}]
    end

    test ":exclude_subtree_of drops a folder and its descendants" do
      a = create_folder(%{name: "A"})
      a1 = create_folder(%{name: "A1", parent_uuid: a.uuid})
      _a1x = create_folder(%{name: "A1x", parent_uuid: a1.uuid})
      b = create_folder(%{name: "B"})

      uuids =
        Catalogue.list_folder_tree(exclude_subtree_of: a.uuid)
        |> Enum.map(fn {f, _} -> f.uuid end)

      assert uuids == [b.uuid]
    end

    test "folder_uuids_with_children/1 flags only parents" do
      a = create_folder(%{name: "A"})
      _a1 = create_folder(%{name: "A1", parent_uuid: a.uuid})
      b = create_folder(%{name: "B"})

      with_children = Catalogue.folder_uuids_with_children()
      assert MapSet.member?(with_children, a.uuid)
      refute MapSet.member?(with_children, b.uuid)
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Move + cycle guard + position
  # ═══════════════════════════════════════════════════════════════════

  describe "move_folder/3" do
    test "moves a folder under a new parent and appends position" do
      a = create_folder(%{name: "A"})
      b = create_folder(%{name: "B"})
      b1 = create_folder(%{name: "B1", parent_uuid: b.uuid})
      mover = create_folder(%{name: "Mover"})

      {:ok, moved} = Catalogue.move_folder(mover, b.uuid)
      assert moved.parent_uuid == b.uuid
      # Appended after the existing child b1 (position 1) → position 2.
      assert moved.position == b1.position + 1
      refute moved.parent_uuid == a.uuid
    end

    test "rejects a move into the folder's own subtree (cycle)" do
      a = create_folder(%{name: "A"})
      a1 = create_folder(%{name: "A1", parent_uuid: a.uuid})

      assert {:error, :cycle} = Catalogue.move_folder(a, a1.uuid)
      assert {:error, :cycle} = Catalogue.move_folder(a, a.uuid)
    end

    test "rejects a move into a trashed folder" do
      a = create_folder(%{name: "A"})
      dead = create_folder(%{name: "Dead"})
      {:ok, _} = Catalogue.trash_folder(dead)

      assert {:error, :folder_trashed} = Catalogue.move_folder(a, dead.uuid)
    end

    test "rejects a move into a missing folder" do
      a = create_folder(%{name: "A"})
      assert {:error, :folder_not_found} = Catalogue.move_folder(a, Ecto.UUID.generate())
    end

    test "no-op when parent is unchanged" do
      a = create_folder(%{name: "A"})
      assert {:ok, ^a} = Catalogue.move_folder(a, a.parent_uuid)
    end
  end

  describe "reorder_folders/2" do
    test "writes 1..N positions in the given order within a level" do
      a = create_folder(%{name: "A"})
      b = create_folder(%{name: "B"})
      c = create_folder(%{name: "C"})

      assert :ok = Catalogue.reorder_folders([c.uuid, a.uuid, b.uuid])

      assert Catalogue.get_folder(c.uuid).position == 1
      assert Catalogue.get_folder(a.uuid).position == 2
      assert Catalogue.get_folder(b.uuid).position == 3
    end
  end

  describe "restore_folder/2" do
    test "restores under the prior parent when it is still active" do
      parent = create_folder(%{name: "Parent"})
      child = create_folder(%{name: "Child", parent_uuid: parent.uuid})
      {:ok, _} = Catalogue.trash_folder(child)

      {:ok, restored} = Catalogue.restore_folder(Catalogue.get_folder(child.uuid))
      assert restored.status == "active"
      assert restored.parent_uuid == parent.uuid
    end

    test "restores to root when the prior parent is gone/trashed" do
      parent = create_folder(%{name: "Parent"})
      child = create_folder(%{name: "Child", parent_uuid: parent.uuid})
      {:ok, _} = Catalogue.trash_folder(child)
      {:ok, _} = Catalogue.trash_folder(parent)

      {:ok, restored} = Catalogue.restore_folder(Catalogue.get_folder(child.uuid))
      assert restored.status == "active"
      assert restored.parent_uuid == nil
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Catalogue ↔ folder
  # ═══════════════════════════════════════════════════════════════════

  describe "move_catalogue_to_folder/3" do
    test "files a catalogue into a folder and appends position" do
      folder = create_folder(%{name: "F"})
      existing = create_catalogue(%{name: "Existing"})
      {:ok, _} = Catalogue.move_catalogue_to_folder(existing, folder.uuid)
      cat = create_catalogue(%{name: "Cat"})

      {:ok, moved} = Catalogue.move_catalogue_to_folder(cat, folder.uuid)
      assert moved.folder_uuid == folder.uuid
      assert moved.position == Catalogue.get_catalogue(existing.uuid).position + 1
    end

    test ":unfiled / nil files to root" do
      folder = create_folder(%{name: "F"})
      cat = create_catalogue(%{name: "Cat"})
      {:ok, filed} = Catalogue.move_catalogue_to_folder(cat, folder.uuid)

      {:ok, unfiled} = Catalogue.move_catalogue_to_folder(filed, :unfiled)
      assert unfiled.folder_uuid == nil
    end

    test "rejects filing into a trashed folder" do
      dead = create_folder(%{name: "Dead"})
      {:ok, _} = Catalogue.trash_folder(dead)
      cat = create_catalogue(%{name: "Cat"})

      assert {:error, :folder_trashed} = Catalogue.move_catalogue_to_folder(cat, dead.uuid)
    end

    test "no-op (no write) when already in the target folder" do
      folder = create_folder(%{name: "F"})
      cat = create_catalogue(%{name: "Cat"})
      {:ok, filed} = Catalogue.move_catalogue_to_folder(cat, folder.uuid)

      assert {:ok, same} = Catalogue.move_catalogue_to_folder(filed, folder.uuid)
      assert same.updated_at == filed.updated_at
    end
  end

  describe "catalogues_by_folder/1 + list_catalogues(folder_uuid:)" do
    test "groups catalogues by folder; orphans (trashed folder) promote to root" do
      folder = create_folder(%{name: "F"})
      root_cat = create_catalogue(%{name: "Root"})
      filed = create_catalogue(%{name: "Filed"})
      {:ok, filed} = Catalogue.move_catalogue_to_folder(filed, folder.uuid)

      grouped = Catalogue.catalogues_by_folder()
      assert Enum.map(grouped[folder.uuid] || [], & &1.uuid) == [filed.uuid]
      assert root_cat.uuid in Enum.map(grouped[nil] || [], & &1.uuid)

      # Trash the folder → its catalogue orphan-promotes to root.
      {:ok, _} = Catalogue.trash_folder(folder)
      grouped2 = Catalogue.catalogues_by_folder()
      assert grouped2[folder.uuid] == nil
      assert filed.uuid in Enum.map(grouped2[nil] || [], & &1.uuid)
    end

    test "list_catalogues(folder_uuid:) filters strictly (no promotion)" do
      folder = create_folder(%{name: "F"})
      filed = create_catalogue(%{name: "Filed"})
      {:ok, _} = Catalogue.move_catalogue_to_folder(filed, folder.uuid)
      _root = create_catalogue(%{name: "Root"})

      assert Catalogue.list_catalogues(folder_uuid: folder.uuid) |> Enum.map(& &1.uuid) == [
               filed.uuid
             ]

      unfiled = Catalogue.list_catalogues(folder_uuid: :unfiled) |> Enum.map(& &1.name)
      assert "Root" in unfiled
      refute "Filed" in unfiled
    end
  end

  describe "changeset guards" do
    test "rejects a self-parent at the changeset level" do
      folder = create_folder(%{name: "A"})
      cs = Folder.changeset(folder, %{parent_uuid: folder.uuid})
      refute cs.valid?
      assert %{parent_uuid: ["folder cannot be its own parent"]} = errors_on(cs)
    end
  end
end
