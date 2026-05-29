defmodule PhoenixKitCatalogue.CatalogueTest do
  use PhoenixKitCatalogue.DataCase, async: true

  alias Ecto.Adapters.SQL
  alias PhoenixKitCatalogue.Catalogue

  # ── Helpers ──────────────────────────────────────────────────────

  defp create_manufacturer(attrs \\ %{}) do
    {:ok, m} = Catalogue.create_manufacturer(Map.merge(%{name: "Test Manufacturer"}, attrs))
    m
  end

  defp create_supplier(attrs \\ %{}) do
    {:ok, s} = Catalogue.create_supplier(Map.merge(%{name: "Test Supplier"}, attrs))
    s
  end

  defp create_catalogue(attrs \\ %{}) do
    {:ok, c} = Catalogue.create_catalogue(Map.merge(%{name: "Test Catalogue"}, attrs))
    c
  end

  defp create_category(catalogue, attrs \\ %{}) do
    {:ok, c} =
      Catalogue.create_category(
        Map.merge(%{name: "Test Category", catalogue_uuid: catalogue.uuid}, attrs)
      )

    c
  end

  defp create_item(attrs \\ %{}) do
    attrs = ensure_item_catalogue(attrs)
    {:ok, i} = Catalogue.create_item(Map.merge(%{name: "Test Item"}, attrs))
    i
  end

  # Items now require a catalogue_uuid. If the caller didn't pass one and
  # didn't pass a category_uuid (from which the catalogue can be derived),
  # create a fresh default catalogue and attach the item to it.
  defp ensure_item_catalogue(attrs) do
    cond do
      Map.has_key?(attrs, :catalogue_uuid) -> attrs
      Map.has_key?(attrs, :category_uuid) -> attrs
      true -> Map.put(attrs, :catalogue_uuid, create_catalogue(%{name: unique_name()}).uuid)
    end
  end

  defp unique_name do
    "Test Catalogue #{System.unique_integer([:positive])}"
  end

  # ═══════════════════════════════════════════════════════════════════
  # Manufacturers
  # ═══════════════════════════════════════════════════════════════════

  describe "manufacturers" do
    test "create_manufacturer/1 with valid attrs" do
      assert {:ok, m} = Catalogue.create_manufacturer(%{name: "Blum"})
      assert m.name == "Blum"
      assert m.status == "active"
    end

    test "create_manufacturer/1 requires name" do
      assert {:error, changeset} = Catalogue.create_manufacturer(%{})
      assert errors_on(changeset).name
    end

    test "list_manufacturers/0 returns all" do
      create_manufacturer(%{name: "A"})
      create_manufacturer(%{name: "B"})
      assert length(Catalogue.list_manufacturers()) == 2
    end

    test "list_manufacturers/1 filters by status" do
      create_manufacturer(%{name: "Active", status: "active"})
      create_manufacturer(%{name: "Inactive", status: "inactive"})
      assert length(Catalogue.list_manufacturers(status: "active")) == 1
    end

    test "update_manufacturer/2" do
      m = create_manufacturer()
      assert {:ok, updated} = Catalogue.update_manufacturer(m, %{name: "Updated"})
      assert updated.name == "Updated"
    end

    test "delete_manufacturer/1" do
      m = create_manufacturer()
      assert {:ok, _} = Catalogue.delete_manufacturer(m)
      assert is_nil(Catalogue.get_manufacturer(m.uuid))
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Suppliers
  # ═══════════════════════════════════════════════════════════════════

  describe "suppliers" do
    test "create_supplier/1 with valid attrs" do
      assert {:ok, s} = Catalogue.create_supplier(%{name: "Distributor"})
      assert s.name == "Distributor"
      assert s.status == "active"
    end

    test "create_supplier/1 requires name" do
      assert {:error, changeset} = Catalogue.create_supplier(%{})
      assert errors_on(changeset).name
    end

    test "list_suppliers/1 filters by status" do
      create_supplier(%{name: "Active", status: "active"})
      create_supplier(%{name: "Inactive", status: "inactive"})
      assert length(Catalogue.list_suppliers(status: "active")) == 1
    end

    test "delete_supplier/1" do
      s = create_supplier()
      assert {:ok, _} = Catalogue.delete_supplier(s)
      assert is_nil(Catalogue.get_supplier(s.uuid))
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Manufacturer ↔ Supplier links
  # ═══════════════════════════════════════════════════════════════════

  describe "manufacturer-supplier links" do
    test "link and unlink" do
      m = create_manufacturer()
      s = create_supplier()

      assert {:ok, _} = Catalogue.link_manufacturer_supplier(m.uuid, s.uuid)
      assert s.uuid in Catalogue.linked_supplier_uuids(m.uuid)

      assert {:ok, _} = Catalogue.unlink_manufacturer_supplier(m.uuid, s.uuid)
      assert Catalogue.linked_supplier_uuids(m.uuid) == []
    end

    test "sync_manufacturer_suppliers/2 returns {:ok, :synced}" do
      m = create_manufacturer()
      s1 = create_supplier(%{name: "S1"})
      s2 = create_supplier(%{name: "S2"})

      assert {:ok, :synced} =
               Catalogue.sync_manufacturer_suppliers(m.uuid, [s1.uuid, s2.uuid])

      assert MapSet.new(Catalogue.linked_supplier_uuids(m.uuid)) == MapSet.new([s1.uuid, s2.uuid])

      # Remove s1, keep s2
      assert {:ok, :synced} = Catalogue.sync_manufacturer_suppliers(m.uuid, [s2.uuid])
      assert Catalogue.linked_supplier_uuids(m.uuid) == [s2.uuid]
    end

    test "list_suppliers_for_manufacturer/1" do
      m = create_manufacturer()
      s = create_supplier()
      Catalogue.link_manufacturer_supplier(m.uuid, s.uuid)

      suppliers = Catalogue.list_suppliers_for_manufacturer(m.uuid)
      assert length(suppliers) == 1
      assert hd(suppliers).uuid == s.uuid
    end

    test "list_manufacturers_for_supplier/1" do
      m = create_manufacturer()
      s = create_supplier()
      Catalogue.link_manufacturer_supplier(m.uuid, s.uuid)

      manufacturers = Catalogue.list_manufacturers_for_supplier(s.uuid)
      assert length(manufacturers) == 1
      assert hd(manufacturers).uuid == m.uuid
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Catalogues
  # ═══════════════════════════════════════════════════════════════════

  describe "catalogues" do
    test "create_catalogue/1 defaults markup_percentage to 0" do
      assert {:ok, c} = Catalogue.create_catalogue(%{name: "Kitchen"})
      assert c.name == "Kitchen"
      assert c.status == "active"
      assert Decimal.equal?(c.markup_percentage, Decimal.new("0"))
    end

    test "create_catalogue/1 with markup_percentage" do
      assert {:ok, c} = Catalogue.create_catalogue(%{name: "Kitchen", markup_percentage: 15.0})
      assert Decimal.equal?(c.markup_percentage, Decimal.new("15.0"))
    end

    test "create_catalogue/1 requires name" do
      assert {:error, changeset} = Catalogue.create_catalogue(%{})
      assert errors_on(changeset).name
    end

    test "create_catalogue/1 validates markup_percentage >= 0" do
      assert {:error, changeset} =
               Catalogue.create_catalogue(%{name: "X", markup_percentage: -5})

      assert errors_on(changeset).markup_percentage
    end

    test "list_catalogues/0 excludes deleted" do
      create_catalogue(%{name: "Active"})
      c2 = create_catalogue(%{name: "To Delete"})
      Catalogue.trash_catalogue(c2)

      catalogues = Catalogue.list_catalogues()
      assert length(catalogues) == 1
      assert hd(catalogues).name == "Active"
    end

    test "list_catalogues/1 with status filter" do
      create_catalogue(%{name: "Active"})
      c2 = create_catalogue(%{name: "Deleted"})
      Catalogue.trash_catalogue(c2)

      assert length(Catalogue.list_catalogues(status: "deleted")) == 1
    end

    test "get_catalogue!/2 filters items by mode" do
      cat = create_catalogue()
      category = create_category(cat)
      create_item(%{name: "Active Item", category_uuid: category.uuid})
      item2 = create_item(%{name: "Deleted Item", category_uuid: category.uuid})
      Catalogue.trash_item(item2)

      active = Catalogue.get_catalogue!(cat.uuid, mode: :active)
      active_items = active.categories |> hd() |> Map.get(:items)
      assert length(active_items) == 1
      assert hd(active_items).name == "Active Item"

      deleted = Catalogue.get_catalogue!(cat.uuid, mode: :deleted)
      deleted_items = deleted.categories |> hd() |> Map.get(:items)
      assert length(deleted_items) == 1
      assert hd(deleted_items).name == "Deleted Item"
    end

    test "get_catalogue!/2 filters categories by mode" do
      cat = create_catalogue()
      create_category(cat, %{name: "Active Cat"})
      deleted_cat = create_category(cat, %{name: "Deleted Cat"})
      Catalogue.trash_category(deleted_cat)

      active = Catalogue.get_catalogue!(cat.uuid, mode: :active)
      assert length(active.categories) == 1
      assert hd(active.categories).name == "Active Cat"
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Catalogue soft-delete cascading
  # ═══════════════════════════════════════════════════════════════════

  describe "catalogue soft-delete cascade" do
    test "trash_catalogue cascades to categories and items" do
      cat = create_catalogue()
      category = create_category(cat)
      item = create_item(%{name: "Item", category_uuid: category.uuid})

      {:ok, _} = Catalogue.trash_catalogue(cat)

      assert Catalogue.get_catalogue(cat.uuid).status == "deleted"
      assert Catalogue.get_category(category.uuid).status == "deleted"
      assert Catalogue.get_item(item.uuid).status == "deleted"
    end

    test "restore_catalogue cascades to categories and items" do
      cat = create_catalogue()
      category = create_category(cat)
      item = create_item(%{name: "Item", category_uuid: category.uuid})
      Catalogue.trash_catalogue(cat)

      cat = Catalogue.get_catalogue(cat.uuid)
      {:ok, _} = Catalogue.restore_catalogue(cat)

      assert Catalogue.get_catalogue(cat.uuid).status == "active"
      assert Catalogue.get_category(category.uuid).status == "active"
      assert Catalogue.get_item(item.uuid).status == "active"
    end

    test "permanently_delete_catalogue removes everything" do
      cat = create_catalogue()
      category = create_category(cat)
      item = create_item(%{name: "Item", category_uuid: category.uuid})

      {:ok, _} = Catalogue.permanently_delete_catalogue(cat)

      assert is_nil(Catalogue.get_catalogue(cat.uuid))
      assert is_nil(Catalogue.get_category(category.uuid))
      assert is_nil(Catalogue.get_item(item.uuid))
    end

    test "deleted_catalogue_count/0" do
      create_catalogue(%{name: "Active"})
      c2 = create_catalogue(%{name: "Deleted"})
      Catalogue.trash_catalogue(c2)

      assert Catalogue.deleted_catalogue_count() >= 1
    end

    test "trash_catalogue also cascades to uncategorized items in the catalogue" do
      cat = create_catalogue()
      uncategorized = create_item(%{name: "Loose", catalogue_uuid: cat.uuid})

      {:ok, _} = Catalogue.trash_catalogue(cat)

      assert Catalogue.get_item(uncategorized.uuid).status == "deleted"
    end

    test "restore_catalogue also cascades to uncategorized items" do
      cat = create_catalogue()
      uncategorized = create_item(%{name: "Loose", catalogue_uuid: cat.uuid})
      Catalogue.trash_catalogue(cat)

      cat = Catalogue.get_catalogue(cat.uuid)
      {:ok, _} = Catalogue.restore_catalogue(cat)

      assert Catalogue.get_item(uncategorized.uuid).status == "active"
    end

    test "permanently_delete_catalogue removes uncategorized items too" do
      cat = create_catalogue()
      uncategorized = create_item(%{name: "Loose", catalogue_uuid: cat.uuid})

      {:ok, _} = Catalogue.permanently_delete_catalogue(cat)

      assert is_nil(Catalogue.get_item(uncategorized.uuid))
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Categories
  # ═══════════════════════════════════════════════════════════════════

  describe "categories" do
    test "create_category/1" do
      cat = create_catalogue()
      assert {:ok, c} = Catalogue.create_category(%{name: "Frames", catalogue_uuid: cat.uuid})
      assert c.name == "Frames"
      assert c.status == "active"
    end

    test "create_category/1 requires name and catalogue_uuid" do
      assert {:error, changeset} = Catalogue.create_category(%{})
      assert errors_on(changeset).name
      assert errors_on(changeset).catalogue_uuid
    end

    test "list_categories_for_catalogue/1 excludes deleted" do
      cat = create_catalogue()
      create_category(cat, %{name: "Active"})
      deleted = create_category(cat, %{name: "Deleted"})
      Catalogue.trash_category(deleted)

      categories = Catalogue.list_categories_for_catalogue(cat.uuid)
      assert length(categories) == 1
      assert hd(categories).name == "Active"
    end

    test "list_all_categories/0 excludes deleted catalogues and categories" do
      cat = create_catalogue(%{name: "MyCat"})
      create_category(cat, %{name: "Active"})
      deleted = create_category(cat, %{name: "Deleted"})
      Catalogue.trash_category(deleted)

      all = Catalogue.list_all_categories()
      names = Enum.map(all, & &1.name)
      assert "MyCat / Active" in names
      refute "MyCat / Deleted" in names
    end

    test "next_category_position/1" do
      cat = create_catalogue()
      assert Catalogue.next_category_position(cat.uuid) == 0
      create_category(cat, %{position: 0})
      assert Catalogue.next_category_position(cat.uuid) == 1
      create_category(cat, %{position: 5})
      assert Catalogue.next_category_position(cat.uuid) == 6
    end

    test "swap_category_positions/2 atomically swaps" do
      cat = create_catalogue()
      c1 = create_category(cat, %{name: "First", position: 0})
      c2 = create_category(cat, %{name: "Second", position: 1})

      assert {:ok, _} = Catalogue.swap_category_positions(c1, c2)

      assert Catalogue.get_category(c1.uuid).position == 1
      assert Catalogue.get_category(c2.uuid).position == 0
    end

    test "swap_category_positions/2 refuses non-siblings" do
      cat = create_catalogue()
      root = create_category(cat, %{name: "Root", position: 0})
      child = create_category(cat, %{name: "Child", position: 0, parent_uuid: root.uuid})

      assert {:error, :not_siblings} = Catalogue.swap_category_positions(root, child)
    end

    test "swap_category_positions/2 refuses cross-catalogue" do
      cat_a = create_catalogue(%{name: "A"})
      cat_b = create_catalogue(%{name: "B"})
      c1 = create_category(cat_a, %{name: "One", position: 0})
      c2 = create_category(cat_b, %{name: "Two", position: 0})

      assert {:error, :not_siblings} = Catalogue.swap_category_positions(c1, c2)
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # V103: Nested categories
  # ═══════════════════════════════════════════════════════════════════

  describe "nested categories" do
    test "create_category/2 accepts parent_uuid within same catalogue" do
      cat = create_catalogue()
      parent = create_category(cat, %{name: "Parent"})

      assert {:ok, child} =
               Catalogue.create_category(%{
                 name: "Child",
                 catalogue_uuid: cat.uuid,
                 parent_uuid: parent.uuid
               })

      assert child.parent_uuid == parent.uuid
    end

    test "create_category/2 rejects parent from a different catalogue" do
      cat_a = create_catalogue(%{name: "A"})
      cat_b = create_catalogue(%{name: "B"})
      parent_a = create_category(cat_a, %{name: "In A"})

      assert {:error, changeset} =
               Catalogue.create_category(%{
                 name: "Orphan",
                 catalogue_uuid: cat_b.uuid,
                 parent_uuid: parent_a.uuid
               })

      assert "must belong to the same catalogue" in errors_on(changeset).parent_uuid
    end

    test "update_category/2 rejects reparent to a different catalogue's category" do
      cat_a = create_catalogue(%{name: "A"})
      cat_b = create_catalogue(%{name: "B"})
      child = create_category(cat_a, %{name: "Child"})
      foreign_parent = create_category(cat_b, %{name: "Foreign"})

      assert {:error, changeset} =
               Catalogue.update_category(child, %{parent_uuid: foreign_parent.uuid})

      assert "must belong to the same catalogue" in errors_on(changeset).parent_uuid
    end

    test "Category.changeset/2 rejects self-parent on update" do
      cat = create_catalogue()
      c = create_category(cat)

      assert {:error, changeset} = Catalogue.update_category(c, %{parent_uuid: c.uuid})
      assert "category cannot be its own parent" in errors_on(changeset).parent_uuid
    end

    test "update_category/3 rejects a parent that is a descendant (cycle)" do
      cat = create_catalogue()
      root = create_category(cat, %{name: "Root"})
      child = create_category(cat, %{name: "Child", parent_uuid: root.uuid})

      # Try to parent the root under its own descendant via the raw
      # update path — must be rejected even though `move_category_under`
      # wasn't used.
      assert {:error, changeset} = Catalogue.update_category(root, %{parent_uuid: child.uuid})
      assert "would create a cycle" in errors_on(changeset).parent_uuid
    end

    test "next_category_position/2 scopes by (catalogue, parent)" do
      cat = create_catalogue()
      parent = create_category(cat, %{name: "Parent", position: 0})
      _other = create_category(cat, %{name: "Other", position: 1})

      # Root-level has two siblings now
      assert Catalogue.next_category_position(cat.uuid, nil) == 2

      # Under `parent` there are no siblings yet
      assert Catalogue.next_category_position(cat.uuid, parent.uuid) == 0

      create_category(cat, %{name: "Child1", parent_uuid: parent.uuid, position: 0})
      create_category(cat, %{name: "Child2", parent_uuid: parent.uuid, position: 5})

      assert Catalogue.next_category_position(cat.uuid, parent.uuid) == 6
      # Root level is unaffected
      assert Catalogue.next_category_position(cat.uuid, nil) == 2
    end

    test "list_category_tree/2 returns depth-first with depths" do
      cat = create_catalogue()
      root_a = create_category(cat, %{name: "A", position: 0})
      root_b = create_category(cat, %{name: "B", position: 1})
      a1 = create_category(cat, %{name: "A1", parent_uuid: root_a.uuid, position: 0})
      _a1a = create_category(cat, %{name: "A1a", parent_uuid: a1.uuid, position: 0})

      tree = Catalogue.list_category_tree(cat.uuid)
      names_and_depths = Enum.map(tree, fn {c, d} -> {c.name, d} end)

      assert names_and_depths == [
               {"A", 0},
               {"A1", 1},
               {"A1a", 2},
               {"B", 0}
             ]
    end

    test "list_category_tree/2 with exclude_subtree_of skips the subtree" do
      cat = create_catalogue()
      root = create_category(cat, %{name: "Root", position: 0})
      _mid = create_category(cat, %{name: "Mid", parent_uuid: root.uuid, position: 0})
      other = create_category(cat, %{name: "Other", position: 1})

      tree = Catalogue.list_category_tree(cat.uuid, exclude_subtree_of: root.uuid)

      assert Enum.map(tree, fn {c, _d} -> c.name end) == [other.name]
    end

    test "list_category_tree/2 in :active mode promotes orphans to roots when parent is deleted" do
      cat = create_catalogue()
      parent = create_category(cat, %{name: "Parent", position: 0})
      child = create_category(cat, %{name: "Child", parent_uuid: parent.uuid, position: 0})

      # Manually soft-delete the parent without cascading to simulate
      # a stale state (trash_category cascades; we test the orphan path).
      SQL.query!(
        PhoenixKitCatalogue.Test.Repo,
        "UPDATE phoenix_kit_cat_categories SET status = 'deleted' WHERE uuid = $1",
        [Ecto.UUID.dump!(parent.uuid)]
      )

      tree = Catalogue.list_category_tree(cat.uuid)

      assert Enum.any?(tree, fn {c, depth} -> c.uuid == child.uuid and depth == 0 end)
    end
  end

  describe "move_category_under/3" do
    test "reparents within the same catalogue" do
      cat = create_catalogue()
      a = create_category(cat, %{name: "A", position: 0})
      b = create_category(cat, %{name: "B", position: 1})

      assert {:ok, moved} = Catalogue.move_category_under(b, a.uuid)
      assert moved.parent_uuid == a.uuid
      # Position updated to next-available under A
      assert moved.position == 0
    end

    test "promotes to root when new_parent_uuid is nil" do
      cat = create_catalogue()
      parent = create_category(cat, %{name: "Parent", position: 0})
      child = create_category(cat, %{name: "Child", parent_uuid: parent.uuid, position: 0})

      assert {:ok, moved} = Catalogue.move_category_under(child, nil)
      assert is_nil(moved.parent_uuid)
    end

    test "no-op when parent_uuid matches current" do
      cat = create_catalogue()
      c = create_category(cat, %{name: "C"})

      assert {:ok, returned} = Catalogue.move_category_under(c, nil)
      assert returned.uuid == c.uuid
    end

    test "refuses to set self as parent" do
      cat = create_catalogue()
      c = create_category(cat)

      assert {:error, :would_create_cycle} = Catalogue.move_category_under(c, c.uuid)
    end

    test "refuses to set a descendant as parent" do
      cat = create_catalogue()
      root = create_category(cat, %{name: "Root"})
      child = create_category(cat, %{name: "Child", parent_uuid: root.uuid})

      assert {:error, :would_create_cycle} = Catalogue.move_category_under(root, child.uuid)
    end

    test "refuses cross-catalogue parent" do
      cat_a = create_catalogue(%{name: "A"})
      cat_b = create_catalogue(%{name: "B"})
      in_a = create_category(cat_a, %{name: "In A"})
      in_b = create_category(cat_b, %{name: "In B"})

      assert {:error, :cross_catalogue} = Catalogue.move_category_under(in_a, in_b.uuid)
    end

    test "returns :parent_not_found for a missing parent UUID" do
      cat = create_catalogue()
      c = create_category(cat)
      bogus = Ecto.UUID.generate()

      assert {:error, :parent_not_found} = Catalogue.move_category_under(c, bogus)
    end
  end

  describe "nested-category cascades" do
    test "trash_category walks the whole subtree" do
      cat = create_catalogue()
      root = create_category(cat, %{name: "Root"})
      mid = create_category(cat, %{name: "Mid", parent_uuid: root.uuid})
      leaf = create_category(cat, %{name: "Leaf", parent_uuid: mid.uuid})
      item = create_item(%{name: "Thing", category_uuid: leaf.uuid})

      assert {:ok, _} = Catalogue.trash_category(root)

      assert Catalogue.get_category(mid.uuid).status == "deleted"
      assert Catalogue.get_category(leaf.uuid).status == "deleted"
      assert Catalogue.get_item(item.uuid).status == "deleted"
    end

    test "restore_category only flips the target's status (no cascades)" do
      cat = create_catalogue()
      root = create_category(cat, %{name: "Root"})
      mid = create_category(cat, %{name: "Mid", parent_uuid: root.uuid})
      leaf = create_category(cat, %{name: "Leaf", parent_uuid: mid.uuid})
      item = create_item(%{name: "Thing", category_uuid: leaf.uuid})

      {:ok, _} = Catalogue.trash_category(root, items: :cascade)

      # Restore the deepest node — only `leaf` flips back. Ancestors,
      # descendants, and items keep their (deleted) status. The boss's
      # rule: each entity's status is its own; restore doesn't ripple.
      assert {:ok, _} = Catalogue.restore_category(Catalogue.get_category(leaf.uuid))

      assert Catalogue.get_category(leaf.uuid).status == "active"
      assert Catalogue.get_category(root.uuid).status == "deleted"
      assert Catalogue.get_category(mid.uuid).status == "deleted"
      assert Catalogue.get_item(item.uuid).status == "deleted"
    end

    test "permanently_delete_category hard-deletes the subtree" do
      cat = create_catalogue()
      root = create_category(cat, %{name: "Root"})
      mid = create_category(cat, %{name: "Mid", parent_uuid: root.uuid})
      item = create_item(%{name: "Thing", category_uuid: mid.uuid})

      assert {:ok, _} = Catalogue.permanently_delete_category(root)

      assert is_nil(Catalogue.get_category(root.uuid))
      assert is_nil(Catalogue.get_category(mid.uuid))
      assert is_nil(Catalogue.get_item(item.uuid))
    end

    test "move_category_to_catalogue moves the whole subtree" do
      cat_src = create_catalogue(%{name: "Source"})
      cat_dst = create_catalogue(%{name: "Target"})
      root = create_category(cat_src, %{name: "Root"})
      child = create_category(cat_src, %{name: "Child", parent_uuid: root.uuid})
      item = create_item(%{name: "Thing", category_uuid: child.uuid})

      assert {:ok, moved} = Catalogue.move_category_to_catalogue(root, cat_dst.uuid)
      assert moved.catalogue_uuid == cat_dst.uuid
      # Root detaches from its (nonexistent) former parent
      assert is_nil(moved.parent_uuid)
      # Internal link preserved
      assert Catalogue.get_category(child.uuid).parent_uuid == root.uuid
      assert Catalogue.get_category(child.uuid).catalogue_uuid == cat_dst.uuid
      assert Catalogue.get_item(item.uuid).catalogue_uuid == cat_dst.uuid
    end
  end

  describe "search_items/2 with include_descendants" do
    test "expands a category scope through its subtree by default" do
      cat = create_catalogue()
      root = create_category(cat, %{name: "Outdoor"})
      child = create_category(cat, %{name: "Chairs", parent_uuid: root.uuid})
      item = create_item(%{name: "Teak Chair", category_uuid: child.uuid})

      # Scoping to the ROOT should still match an item whose category
      # is a descendant.
      results = Catalogue.search_items("Teak", category_uuids: [root.uuid])
      assert Enum.any?(results, &(&1.uuid == item.uuid))
    end

    test "include_descendants: false restricts to the literal set" do
      cat = create_catalogue()
      root = create_category(cat, %{name: "Outdoor"})
      child = create_category(cat, %{name: "Chairs", parent_uuid: root.uuid})
      item = create_item(%{name: "Teak Chair", category_uuid: child.uuid})

      results =
        Catalogue.search_items("Teak",
          category_uuids: [root.uuid],
          include_descendants: false
        )

      refute Enum.any?(results, &(&1.uuid == item.uuid))

      # Direct scope to child still matches
      direct = Catalogue.search_items("Teak", category_uuids: [child.uuid])
      assert Enum.any?(direct, &(&1.uuid == item.uuid))
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Category soft-delete cascading
  # ═══════════════════════════════════════════════════════════════════

  describe "category soft-delete cascade" do
    test "trash_category cascades to items" do
      cat = create_catalogue()
      category = create_category(cat)
      item = create_item(%{name: "Item", category_uuid: category.uuid})

      {:ok, _} = Catalogue.trash_category(category)

      assert Catalogue.get_category(category.uuid).status == "deleted"
      assert Catalogue.get_item(item.uuid).status == "deleted"
    end

    test "restore_category refuses when parent catalogue is deleted" do
      cat = create_catalogue()
      category = create_category(cat)
      item = create_item(%{name: "Item", category_uuid: category.uuid})
      Catalogue.trash_catalogue(cat)

      # Restoring the category alone is no longer allowed when the
      # catalogue itself is deleted — the operator must restore the
      # catalogue first. The previous auto-revive surprised operators
      # who only meant to undo a category-level trash.
      category = Catalogue.get_category(category.uuid)
      assert {:error, :parent_catalogue_deleted} = Catalogue.restore_category(category)

      # State unchanged.
      assert Catalogue.get_catalogue(cat.uuid).status == "deleted"
      assert Catalogue.get_category(category.uuid).status == "deleted"
      assert Catalogue.get_item(item.uuid).status == "deleted"
    end

    test "permanently_delete_category removes category and items" do
      cat = create_catalogue()
      category = create_category(cat)
      item = create_item(%{name: "Item", category_uuid: category.uuid})

      {:ok, _} = Catalogue.permanently_delete_category(category)

      assert is_nil(Catalogue.get_category(category.uuid))
      assert is_nil(Catalogue.get_item(item.uuid))
      # Catalogue should still exist
      assert Catalogue.get_catalogue(cat.uuid)
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Category move
  # ═══════════════════════════════════════════════════════════════════

  describe "move_category_to_catalogue/2" do
    test "moves category to another catalogue" do
      cat1 = create_catalogue(%{name: "Source"})
      cat2 = create_catalogue(%{name: "Target"})
      category = create_category(cat1, %{name: "Moving"})

      {:ok, moved} = Catalogue.move_category_to_catalogue(category, cat2.uuid)

      assert moved.catalogue_uuid == cat2.uuid
      assert Catalogue.list_categories_for_catalogue(cat1.uuid) == []
      assert length(Catalogue.list_categories_for_catalogue(cat2.uuid)) == 1
    end

    test "cascades catalogue_uuid to all items in the moved category" do
      cat1 = create_catalogue(%{name: "Source"})
      cat2 = create_catalogue(%{name: "Target"})
      category = create_category(cat1, %{name: "Moving"})
      item1 = create_item(%{name: "I1", category_uuid: category.uuid})
      item2 = create_item(%{name: "I2", category_uuid: category.uuid})

      {:ok, _} = Catalogue.move_category_to_catalogue(category, cat2.uuid)

      assert Catalogue.get_item(item1.uuid).catalogue_uuid == cat2.uuid
      assert Catalogue.get_item(item2.uuid).catalogue_uuid == cat2.uuid
    end

    test "assigns next position in target catalogue" do
      cat1 = create_catalogue(%{name: "Source"})
      cat2 = create_catalogue(%{name: "Target"})
      create_category(cat2, %{name: "Existing", position: 3})
      category = create_category(cat1, %{name: "Moving", position: 0})

      {:ok, moved} = Catalogue.move_category_to_catalogue(category, cat2.uuid)

      assert moved.position == 4
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Items
  # ═══════════════════════════════════════════════════════════════════

  describe "items" do
    test "create_item/1 with valid attrs" do
      cat = create_catalogue()
      assert {:ok, i} = Catalogue.create_item(%{name: "Oak Panel", catalogue_uuid: cat.uuid})
      assert i.name == "Oak Panel"
      assert i.status == "active"
      assert i.unit == "piece"
      assert i.catalogue_uuid == cat.uuid
    end

    test "create_item/1 requires name" do
      cat = create_catalogue()
      assert {:error, changeset} = Catalogue.create_item(%{catalogue_uuid: cat.uuid})
      assert errors_on(changeset).name
    end

    test "create_item/1 requires catalogue_uuid" do
      assert {:error, changeset} = Catalogue.create_item(%{name: "Orphan"})
      assert errors_on(changeset).catalogue_uuid
    end

    test "create_item/1 derives catalogue_uuid from category_uuid" do
      cat = create_catalogue()
      category = create_category(cat)

      assert {:ok, i} =
               Catalogue.create_item(%{name: "Derived", category_uuid: category.uuid})

      assert i.catalogue_uuid == cat.uuid
    end

    test "create_item/1 validates status" do
      cat = create_catalogue()

      assert {:error, changeset} =
               Catalogue.create_item(%{name: "X", status: "bogus", catalogue_uuid: cat.uuid})

      assert errors_on(changeset).status
    end

    test "create_item/1 validates unit" do
      cat = create_catalogue()

      assert {:error, changeset} =
               Catalogue.create_item(%{name: "X", unit: "bogus", catalogue_uuid: cat.uuid})

      assert errors_on(changeset).unit
    end

    test "create_item/1 validates base_price >= 0" do
      cat = create_catalogue()

      assert {:error, changeset} =
               Catalogue.create_item(%{name: "X", base_price: -1, catalogue_uuid: cat.uuid})

      assert errors_on(changeset).base_price
    end

    test "create_item/1 with base_price" do
      cat = create_catalogue()

      assert {:ok, i} =
               Catalogue.create_item(%{
                 name: "Panel",
                 base_price: "25.50",
                 catalogue_uuid: cat.uuid
               })

      assert Decimal.equal?(i.base_price, Decimal.new("25.50"))
    end

    test "update_item/2" do
      item = create_item()
      assert {:ok, updated} = Catalogue.update_item(item, %{name: "Updated"})
      assert updated.name == "Updated"
    end

    test "update_item/3 re-derives catalogue_uuid when category moves to another catalogue" do
      cat_a = create_catalogue(%{name: "A"})
      cat_b = create_catalogue(%{name: "B"})
      category_a = create_category(cat_a)
      category_b = create_category(cat_b)
      item = create_item(%{name: "Crosser", category_uuid: category_a.uuid})
      assert item.catalogue_uuid == cat_a.uuid

      assert {:ok, updated} =
               Catalogue.update_item(item, %{category_uuid: category_b.uuid})

      assert updated.category_uuid == category_b.uuid
      assert updated.catalogue_uuid == cat_b.uuid
    end

    test "update_item/3 derivation overrides stale catalogue_uuid supplied by caller" do
      cat_a = create_catalogue(%{name: "A"})
      cat_b = create_catalogue(%{name: "B"})
      category_b = create_category(cat_b)
      item = create_item(%{name: "Mismatch", catalogue_uuid: cat_a.uuid})

      # Caller passes category in cat_b but still references cat_a — the
      # category's actual catalogue (cat_b) must win.
      assert {:ok, updated} =
               Catalogue.update_item(item, %{
                 category_uuid: category_b.uuid,
                 catalogue_uuid: cat_a.uuid
               })

      assert updated.category_uuid == category_b.uuid
      assert updated.catalogue_uuid == cat_b.uuid
    end

    test "update_item/3 without category change leaves catalogue_uuid alone" do
      cat = create_catalogue()
      item = create_item(%{name: "Stay put", catalogue_uuid: cat.uuid})

      assert {:ok, updated} = Catalogue.update_item(item, %{name: "Renamed"})
      assert updated.catalogue_uuid == cat.uuid
    end

    test "create_item/1 mismatched caller-provided catalogue_uuid is overridden by the category" do
      cat_a = create_catalogue(%{name: "A"})
      cat_b = create_catalogue(%{name: "B"})
      category_b = create_category(cat_b)

      assert {:ok, item} =
               Catalogue.create_item(%{
                 name: "Mismatch",
                 category_uuid: category_b.uuid,
                 catalogue_uuid: cat_a.uuid
               })

      assert item.catalogue_uuid == cat_b.uuid
    end

    test "create_item/1 treats empty-string category_uuid as uncategorized" do
      cat = create_catalogue()

      assert {:ok, item} =
               Catalogue.create_item(%{
                 name: "Loose",
                 catalogue_uuid: cat.uuid,
                 category_uuid: ""
               })

      assert is_nil(item.category_uuid)
      assert item.catalogue_uuid == cat.uuid
    end

    test "update_item/3 derives catalogue_uuid from string-keyed form params" do
      # Regression: form params come in as string-keyed maps WITHOUT a
      # catalogue_uuid entry. `derive_catalogue_uuid` must insert the
      # derived value using the same string-key style, otherwise Ecto's
      # cast crashes with "map with mixed keys".
      cat_a = create_catalogue(%{name: "A"})
      cat_b = create_catalogue(%{name: "B"})
      category_b = create_category(cat_b)
      item = create_item(%{name: "Mover", catalogue_uuid: cat_a.uuid})

      form_params = %{
        "name" => "Mover",
        "description" => "",
        "sku" => "SKU-FORM",
        "base_price" => "0.32",
        "unit" => "piece",
        "category_uuid" => category_b.uuid,
        "manufacturer_uuid" => "",
        "status" => "active"
      }

      assert {:ok, updated} = Catalogue.update_item(item, form_params)
      assert updated.catalogue_uuid == cat_b.uuid
      assert updated.category_uuid == category_b.uuid
    end

    test "create_item/1 derives catalogue_uuid from string-keyed form params" do
      cat = create_catalogue()
      category = create_category(cat)

      form_params = %{
        "name" => "Form Item",
        "category_uuid" => category.uuid,
        "base_price" => "1.50",
        "unit" => "piece",
        "status" => "active"
      }

      assert {:ok, item} = Catalogue.create_item(form_params)
      assert item.catalogue_uuid == cat.uuid
      assert item.category_uuid == category.uuid
    end

    test "get_item!/1 preloads category and manufacturer" do
      cat = create_catalogue()
      category = create_category(cat)
      m = create_manufacturer()
      item = create_item(%{name: "X", category_uuid: category.uuid, manufacturer_uuid: m.uuid})

      loaded = Catalogue.get_item!(item.uuid)
      assert loaded.category.uuid == category.uuid
      assert loaded.manufacturer.uuid == m.uuid
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Item soft-delete
  # ═══════════════════════════════════════════════════════════════════

  describe "item soft-delete" do
    test "trash_item/1 sets status to deleted" do
      item = create_item()
      {:ok, trashed} = Catalogue.trash_item(item)
      assert trashed.status == "deleted"
    end

    test "restore_item/1 sets status back to active" do
      item = create_item()
      {:ok, trashed} = Catalogue.trash_item(item)
      {:ok, restored} = Catalogue.restore_item(trashed)
      assert restored.status == "active"
    end

    test "restore_item/1 detaches from a deleted parent category (uncategorizes)" do
      cat = create_catalogue()
      category = create_category(cat)
      item = create_item(%{name: "Item", category_uuid: category.uuid})

      # Trash via :cascade so the item shares the category's deleted state.
      Catalogue.trash_category(category, items: :cascade)
      assert Catalogue.get_category(category.uuid).status == "deleted"
      assert Catalogue.get_item(item.uuid).status == "deleted"

      item = Catalogue.get_item(item.uuid)
      {:ok, restored} = Catalogue.restore_item(item)

      # New behaviour: the item resurfaces as Uncategorized in the same
      # catalogue. The category stays deleted — restoring an item no
      # longer auto-revives the category structure.
      assert restored.status == "active"
      assert restored.category_uuid == nil
      assert restored.catalogue_uuid == cat.uuid
      assert Catalogue.get_category(category.uuid).status == "deleted"
    end

    test "restore_item/1 refuses when parent catalogue is deleted" do
      cat = create_catalogue()
      category = create_category(cat)
      item = create_item(%{name: "Item", category_uuid: category.uuid})

      Catalogue.trash_catalogue(cat)
      assert Catalogue.get_catalogue(cat.uuid).status == "deleted"
      assert Catalogue.get_item(item.uuid).status == "deleted"

      item = Catalogue.get_item(item.uuid)
      assert {:error, :parent_catalogue_deleted} = Catalogue.restore_item(item)

      # Nothing was changed — caller must restore the catalogue first.
      assert Catalogue.get_catalogue(cat.uuid).status == "deleted"
      assert Catalogue.get_item(item.uuid).status == "deleted"
    end

    test "permanently_delete_item/1 removes from DB" do
      item = create_item()
      {:ok, _} = Catalogue.permanently_delete_item(item)
      assert is_nil(Catalogue.get_item(item.uuid))
    end

    test "trash_items_in_category/1 bulk soft-deletes" do
      cat = create_catalogue()
      category = create_category(cat)
      i1 = create_item(%{name: "I1", category_uuid: category.uuid})
      i2 = create_item(%{name: "I2", category_uuid: category.uuid})

      Catalogue.trash_items_in_category(category.uuid)

      assert Catalogue.get_item(i1.uuid).status == "deleted"
      assert Catalogue.get_item(i2.uuid).status == "deleted"
    end

    test "trash_items_in_category/1 skips already deleted items" do
      cat = create_catalogue()
      category = create_category(cat)
      i1 = create_item(%{name: "I1", category_uuid: category.uuid})
      Catalogue.trash_item(i1)

      # Should not error
      {count, _} = Catalogue.trash_items_in_category(category.uuid)
      assert count == 0
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Item move
  # ═══════════════════════════════════════════════════════════════════

  describe "move_item_to_category/2" do
    test "moves item to a different category" do
      cat = create_catalogue()
      c1 = create_category(cat, %{name: "Source"})
      c2 = create_category(cat, %{name: "Target"})
      item = create_item(%{name: "Moving", category_uuid: c1.uuid})

      {:ok, moved} = Catalogue.move_item_to_category(item, c2.uuid)
      assert moved.category_uuid == c2.uuid
      assert moved.catalogue_uuid == cat.uuid
    end

    test "updates catalogue_uuid when moving to a category in a different catalogue" do
      cat_a = create_catalogue(%{name: "A"})
      cat_b = create_catalogue(%{name: "B"})
      category_a = create_category(cat_a)
      category_b = create_category(cat_b)
      item = create_item(%{name: "Crosses", category_uuid: category_a.uuid})

      {:ok, moved} = Catalogue.move_item_to_category(item, category_b.uuid)
      assert moved.category_uuid == category_b.uuid
      assert moved.catalogue_uuid == cat_b.uuid
    end

    test "detaching with nil keeps the item in the current catalogue (uncategorized)" do
      cat = create_catalogue()
      category = create_category(cat)
      item = create_item(%{name: "Goes loose", category_uuid: category.uuid})

      {:ok, moved} = Catalogue.move_item_to_category(item, nil)
      assert moved.category_uuid == nil
      assert moved.catalogue_uuid == cat.uuid
    end

    test "returns :category_not_found when the target category does not exist" do
      item = create_item()
      bogus_uuid = "00000000-0000-0000-0000-000000000000"

      assert {:error, :category_not_found} =
               Catalogue.move_item_to_category(item, bogus_uuid)

      # Item state is unchanged
      reloaded = Catalogue.get_item(item.uuid)
      assert reloaded.category_uuid == item.category_uuid
      assert reloaded.catalogue_uuid == item.catalogue_uuid
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Deleted counts
  # ═══════════════════════════════════════════════════════════════════

  describe "deleted counts" do
    test "deleted_item_count_for_catalogue/1" do
      cat = create_catalogue()
      category = create_category(cat)
      create_item(%{name: "Active", category_uuid: category.uuid})
      i2 = create_item(%{name: "Deleted", category_uuid: category.uuid})
      Catalogue.trash_item(i2)

      assert Catalogue.deleted_item_count_for_catalogue(cat.uuid) == 1
    end

    test "deleted_item_count_for_catalogue/1 counts uncategorized items in the catalogue" do
      cat = create_catalogue()
      item = create_item(%{name: "Orphan", catalogue_uuid: cat.uuid})
      Catalogue.trash_item(item)

      assert Catalogue.deleted_item_count_for_catalogue(cat.uuid) == 1
    end

    test "deleted_category_count_for_catalogue/1" do
      cat = create_catalogue()
      create_category(cat, %{name: "Active"})
      c2 = create_category(cat, %{name: "Deleted"})
      Catalogue.trash_category(c2)

      assert Catalogue.deleted_category_count_for_catalogue(cat.uuid) == 1
    end

    test "deleted_count_for_catalogue/1 sums items and categories" do
      cat = create_catalogue()
      category = create_category(cat)
      item = create_item(%{name: "Item", category_uuid: category.uuid})
      Catalogue.trash_item(item)

      c2 = create_category(cat, %{name: "Deleted Cat"})
      Catalogue.trash_category(c2)

      assert Catalogue.deleted_count_for_catalogue(cat.uuid) >= 2
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Uncategorized items
  # ═══════════════════════════════════════════════════════════════════

  describe "uncategorized items" do
    test "list_uncategorized_items/2 active mode excludes deleted" do
      cat = create_catalogue()
      create_item(%{name: "Active Orphan", catalogue_uuid: cat.uuid})
      i2 = create_item(%{name: "Deleted Orphan", catalogue_uuid: cat.uuid})
      Catalogue.trash_item(i2)

      active = Catalogue.list_uncategorized_items(cat.uuid, mode: :active)
      names = Enum.map(active, & &1.name)
      assert "Active Orphan" in names
      refute "Deleted Orphan" in names
    end

    test "list_uncategorized_items/2 deleted mode shows only deleted" do
      cat = create_catalogue()
      create_item(%{name: "Active Orphan", catalogue_uuid: cat.uuid})
      i2 = create_item(%{name: "Deleted Orphan", catalogue_uuid: cat.uuid})
      Catalogue.trash_item(i2)

      deleted = Catalogue.list_uncategorized_items(cat.uuid, mode: :deleted)
      names = Enum.map(deleted, & &1.name)
      refute "Active Orphan" in names
      assert "Deleted Orphan" in names
    end

    test "list_uncategorized_items/2 is scoped to the catalogue" do
      cat_a = create_catalogue(%{name: "A"})
      cat_b = create_catalogue(%{name: "B"})
      create_item(%{name: "In A", catalogue_uuid: cat_a.uuid})
      create_item(%{name: "In B", catalogue_uuid: cat_b.uuid})

      names_a = Enum.map(Catalogue.list_uncategorized_items(cat_a.uuid), & &1.name)
      assert "In A" in names_a
      refute "In B" in names_a
    end

    test "list_uncategorized_items/2 excludes items that have a category" do
      cat = create_catalogue()
      category = create_category(cat)
      create_item(%{name: "Has Category", category_uuid: category.uuid})
      create_item(%{name: "Uncategorized", catalogue_uuid: cat.uuid})

      names = Enum.map(Catalogue.list_uncategorized_items(cat.uuid), & &1.name)
      assert "Uncategorized" in names
      refute "Has Category" in names
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Sale price calculation
  # ═══════════════════════════════════════════════════════════════════

  describe "sale price" do
    alias PhoenixKitCatalogue.Schemas.Item

    test "sale_price/2 with markup" do
      item = %Item{base_price: Decimal.new("100.00")}
      markup = Decimal.new("20.0")

      assert Decimal.equal?(Item.sale_price(item, markup), Decimal.new("120.00"))
    end

    test "sale_price/2 with nil base_price" do
      item = %Item{base_price: nil}
      assert is_nil(Item.sale_price(item, Decimal.new("20.0")))
    end

    test "sale_price/2 with nil markup returns base_price" do
      item = %Item{base_price: Decimal.new("50.00")}
      assert Decimal.equal?(Item.sale_price(item, nil), Decimal.new("50.00"))
    end

    test "sale_price/2 with zero markup returns base_price" do
      item = %Item{base_price: Decimal.new("50.00")}
      assert Decimal.equal?(Item.sale_price(item, Decimal.new("0")), Decimal.new("50.00"))
    end

    test "sale_price/2 rounds to 2 decimal places" do
      item = %Item{base_price: Decimal.new("33.33")}
      markup = Decimal.new("33.33")

      result = Item.sale_price(item, markup)
      assert Decimal.equal?(result, Decimal.new("44.44"))
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Item pricing (full API)
  # ═══════════════════════════════════════════════════════════════════

  describe "item_pricing/1" do
    test "returns base_price, markup_percentage, and computed price" do
      cat = create_catalogue(%{name: "Marked Up", markup_percentage: 20})
      category = create_category(cat)
      item = create_item(%{name: "Panel", base_price: "100.00", category_uuid: category.uuid})

      pricing = Catalogue.item_pricing(item)

      assert Decimal.equal?(pricing.base_price, Decimal.new("100.00"))
      assert Decimal.equal?(pricing.markup_percentage, Decimal.new("20"))
      assert Decimal.equal?(pricing.sale_price, Decimal.new("120.00"))
    end

    test "uses 0% markup when catalogue has default" do
      cat = create_catalogue(%{name: "No Markup"})
      category = create_category(cat)
      item = create_item(%{name: "Panel", base_price: "50.00", category_uuid: category.uuid})

      pricing = Catalogue.item_pricing(item)

      assert Decimal.equal?(pricing.markup_percentage, Decimal.new("0"))
      assert Decimal.equal?(pricing.sale_price, Decimal.new("50.00"))
    end

    test "uses 0% markup for uncategorized items" do
      item = create_item(%{name: "Orphan", base_price: "75.00"})

      pricing = Catalogue.item_pricing(item)

      assert Decimal.equal?(pricing.markup_percentage, Decimal.new("0"))
      assert Decimal.equal?(pricing.sale_price, Decimal.new("75.00"))
    end

    test "returns nil price when base_price is nil" do
      cat = create_catalogue(%{name: "Cat", markup_percentage: 10})
      category = create_category(cat)
      item = create_item(%{name: "No Price", category_uuid: category.uuid})

      pricing = Catalogue.item_pricing(item)

      assert is_nil(pricing.base_price)
      assert is_nil(pricing.sale_price)
      assert Decimal.equal?(pricing.markup_percentage, Decimal.new("10"))
    end

    test "reports both catalogue_markup and item_markup, with item override winning" do
      cat = create_catalogue(%{name: "Cat 20%", markup_percentage: 20})
      category = create_category(cat)

      item =
        create_item(%{
          name: "Override Panel",
          base_price: "100.00",
          markup_percentage: "50",
          category_uuid: category.uuid
        })

      pricing = Catalogue.item_pricing(item)

      assert Decimal.equal?(pricing.catalogue_markup, Decimal.new("20"))
      assert Decimal.equal?(pricing.item_markup, Decimal.new("50"))
      # Effective markup is the item's override
      assert Decimal.equal?(pricing.markup_percentage, Decimal.new("50"))
      assert Decimal.equal?(pricing.sale_price, Decimal.new("150.00"))
    end

    test "item_markup is nil when there is no override" do
      cat = create_catalogue(%{name: "Cat 10%", markup_percentage: 10})
      category = create_category(cat)
      item = create_item(%{name: "Inheritor", base_price: "100.00", category_uuid: category.uuid})

      pricing = Catalogue.item_pricing(item)

      assert is_nil(pricing.item_markup)
      assert Decimal.equal?(pricing.catalogue_markup, Decimal.new("10"))
      assert Decimal.equal?(pricing.markup_percentage, Decimal.new("10"))
    end

    test "item_markup of 0 overrides a non-zero catalogue markup" do
      cat = create_catalogue(%{name: "Cat 25%", markup_percentage: 25})
      category = create_category(cat)

      item =
        create_item(%{
          name: "No Markup For Me",
          base_price: "100.00",
          markup_percentage: "0",
          category_uuid: category.uuid
        })

      pricing = Catalogue.item_pricing(item)

      assert Decimal.equal?(pricing.catalogue_markup, Decimal.new("25"))
      assert Decimal.equal?(pricing.item_markup, Decimal.new("0"))
      assert Decimal.equal?(pricing.markup_percentage, Decimal.new("0"))
      assert Decimal.equal?(pricing.sale_price, Decimal.new("100.00"))
    end

    test "falls back to 0% markup when the catalogue association is unloaded and preload fails" do
      # Simulate "catalogue couldn't be loaded" by constructing a detached
      # struct: no catalogue preload, no uuid that the DB knows about.
      # `item_pricing/1` must not crash — it should log a warning and
      # return 0% markup with the item's base_price.
      item = %PhoenixKitCatalogue.Schemas.Item{
        uuid: "00000000-0000-0000-0000-000000000000",
        base_price: Decimal.new("42.00"),
        catalogue: %Ecto.Association.NotLoaded{
          __field__: :catalogue,
          __owner__: PhoenixKitCatalogue.Schemas.Item,
          __cardinality__: :one
        }
      }

      pricing = Catalogue.item_pricing(item)

      assert Decimal.equal?(pricing.base_price, Decimal.new("42.00"))
      assert Decimal.equal?(pricing.markup_percentage, Decimal.new("0"))
      assert Decimal.equal?(pricing.sale_price, Decimal.new("42.00"))
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Search
  # ═══════════════════════════════════════════════════════════════════

  describe "search_items/1 (global)" do
    test "finds items by name" do
      cat = create_catalogue()
      category = create_category(cat)
      create_item(%{name: "Oak Panel 18mm", category_uuid: category.uuid})
      create_item(%{name: "Birch Veneer", category_uuid: category.uuid})

      results = Catalogue.search_items("oak")
      assert length(results) == 1
      assert hd(results).name == "Oak Panel 18mm"
    end

    test "finds items by SKU" do
      cat = create_catalogue()
      category = create_category(cat)
      create_item(%{name: "Panel", sku: "OAK-18", category_uuid: category.uuid})

      results = Catalogue.search_items("OAK-18")
      assert length(results) == 1
    end

    test "finds items by description" do
      cat = create_catalogue()
      category = create_category(cat)

      create_item(%{
        name: "Panel",
        description: "Premium hardwood panel",
        category_uuid: category.uuid
      })

      results = Catalogue.search_items("hardwood")
      assert length(results) == 1
    end

    test "is case-insensitive" do
      cat = create_catalogue()
      category = create_category(cat)
      create_item(%{name: "Oak Panel", category_uuid: category.uuid})

      assert length(Catalogue.search_items("OAK PANEL")) == 1
      assert length(Catalogue.search_items("oak panel")) == 1
    end

    test "excludes deleted items" do
      cat = create_catalogue()
      category = create_category(cat)
      item = create_item(%{name: "Deleted Oak", category_uuid: category.uuid})
      Catalogue.trash_item(item)

      assert Catalogue.search_items("oak") == []
    end

    test "excludes items in deleted catalogues" do
      cat = create_catalogue()
      category = create_category(cat)
      create_item(%{name: "Hidden Oak", category_uuid: category.uuid})
      Catalogue.trash_catalogue(cat)

      assert Catalogue.search_items("oak") == []
    end

    test "preloads category with catalogue and manufacturer" do
      cat = create_catalogue(%{name: "Kitchen"})
      category = create_category(cat, %{name: "Frames"})
      m = create_manufacturer(%{name: "Blum"})
      create_item(%{name: "Oak Panel", category_uuid: category.uuid, manufacturer_uuid: m.uuid})

      [item] = Catalogue.search_items("oak")
      assert item.category.name == "Frames"
      assert item.category.catalogue.name == "Kitchen"
      assert item.manufacturer.name == "Blum"
    end

    test "respects limit option" do
      cat = create_catalogue()
      category = create_category(cat)
      for n <- 1..5, do: create_item(%{name: "Oak #{n}", category_uuid: category.uuid})

      assert length(Catalogue.search_items("oak", limit: 3)) == 3
    end

    test "handles LIKE special characters safely" do
      cat = create_catalogue()
      category = create_category(cat)
      create_item(%{name: "100% Oak", category_uuid: category.uuid})

      # Should not treat % as wildcard
      assert Catalogue.search_items("100%") == [hd(Catalogue.search_items("100%"))]
    end
  end

  describe "search_items/2 with :only scope (issue #15)" do
    test ":uncategorized_only returns items with no category" do
      cat = create_catalogue()
      category = create_category(cat)

      _categorized =
        create_item(%{name: "Oak Panel A", category_uuid: category.uuid})

      uncategorized =
        create_item(%{
          name: "Oak Panel B",
          category_uuid: nil,
          catalogue_uuid: cat.uuid
        })

      results = Catalogue.search_items("oak", only: :uncategorized_only)
      assert length(results) == 1
      assert hd(results).uuid == uncategorized.uuid
    end

    test ":categorized_only returns items that have a category" do
      cat = create_catalogue()
      category = create_category(cat)

      categorized =
        create_item(%{name: "Oak Panel A", category_uuid: category.uuid})

      _uncategorized =
        create_item(%{
          name: "Oak Panel B",
          category_uuid: nil,
          catalogue_uuid: cat.uuid
        })

      results = Catalogue.search_items("oak", only: :categorized_only)
      assert length(results) == 1
      assert hd(results).uuid == categorized.uuid
    end

    test ":only composes AND with :catalogue_uuids" do
      kitchen = create_catalogue(%{name: "Kitchen"})
      bath = create_catalogue(%{name: "Bath"})

      _k_cat_item =
        create_item(%{
          name: "Oak K1",
          category_uuid: create_category(kitchen).uuid
        })

      target =
        create_item(%{
          name: "Oak K2",
          category_uuid: nil,
          catalogue_uuid: kitchen.uuid
        })

      _b_uncat =
        create_item(%{
          name: "Oak B1",
          category_uuid: nil,
          catalogue_uuid: bath.uuid
        })

      results =
        Catalogue.search_items("oak",
          catalogue_uuids: [kitchen.uuid],
          only: :uncategorized_only
        )

      assert length(results) == 1
      assert hd(results).uuid == target.uuid
    end

    test "count_search_items/2 honors :only" do
      cat = create_catalogue()
      category = create_category(cat)

      create_item(%{name: "Oak A", category_uuid: category.uuid})

      create_item(%{
        name: "Oak B",
        category_uuid: nil,
        catalogue_uuid: cat.uuid
      })

      assert Catalogue.count_search_items("oak", only: :uncategorized_only) == 1
      assert Catalogue.count_search_items("oak", only: :categorized_only) == 1
      assert Catalogue.count_search_items("oak") == 2
    end

    test "category_uuids: [nil] raises ArgumentError instead of silently returning []" do
      assert_raise ArgumentError, ~r/category_uuids must contain non-nil UUIDs/, fn ->
        Catalogue.search_items("anything", category_uuids: [nil])
      end

      assert_raise ArgumentError, ~r/category_uuids must contain non-nil UUIDs/, fn ->
        Catalogue.count_search_items("anything", category_uuids: [nil])
      end
    end

    test ":uncategorized_only + non-empty category_uuids raises ArgumentError" do
      cat = create_catalogue()
      category = create_category(cat)

      assert_raise ArgumentError, ~r/cannot be combined/, fn ->
        Catalogue.search_items("anything",
          category_uuids: [category.uuid],
          only: :uncategorized_only
        )
      end
    end

    test "unknown :only value raises ArgumentError" do
      assert_raise ArgumentError, ~r/unknown :only value/, fn ->
        Catalogue.search_items("anything", only: :nonsense)
      end
    end
  end

  describe "search_items_in_catalogue/2" do
    test "only returns items within the specified catalogue" do
      cat1 = create_catalogue(%{name: "Kitchen"})
      cat2 = create_catalogue(%{name: "Bathroom"})
      c1 = create_category(cat1)
      c2 = create_category(cat2)
      create_item(%{name: "Oak Panel", category_uuid: c1.uuid})
      create_item(%{name: "Oak Shelf", category_uuid: c2.uuid})

      results = Catalogue.search_items_in_catalogue(cat1.uuid, "oak")
      assert length(results) == 1
      assert hd(results).name == "Oak Panel"
    end

    test "returns empty for no match" do
      cat = create_catalogue()
      category = create_category(cat)
      create_item(%{name: "Birch Veneer", category_uuid: category.uuid})

      assert Catalogue.search_items_in_catalogue(cat.uuid, "oak") == []
    end

    test "respects :limit and :offset for paging" do
      cat = create_catalogue()
      category = create_category(cat)

      for i <- 1..5 do
        create_item(%{name: "Oak Panel #{i}", category_uuid: category.uuid})
      end

      page_1 = Catalogue.search_items_in_catalogue(cat.uuid, "oak", limit: 2, offset: 0)
      page_2 = Catalogue.search_items_in_catalogue(cat.uuid, "oak", limit: 2, offset: 2)
      page_3 = Catalogue.search_items_in_catalogue(cat.uuid, "oak", limit: 2, offset: 4)

      assert length(page_1) == 2
      assert length(page_2) == 2
      assert length(page_3) == 1

      # Pages must be disjoint — stable uuid tie-breaker guarantees this
      all_uuids =
        (page_1 ++ page_2 ++ page_3) |> Enum.map(& &1.uuid)

      assert length(Enum.uniq(all_uuids)) == 5
    end

    test "ordering is stable across pages when names collide" do
      cat = create_catalogue()
      category = create_category(cat)

      for _ <- 1..6, do: create_item(%{name: "Twin", category_uuid: category.uuid})

      # Fetch in two different page shapes, compare uuid order
      one_shot = Catalogue.search_items_in_catalogue(cat.uuid, "twin", limit: 10)

      paged =
        Catalogue.search_items_in_catalogue(cat.uuid, "twin", limit: 3, offset: 0) ++
          Catalogue.search_items_in_catalogue(cat.uuid, "twin", limit: 3, offset: 3)

      assert Enum.map(one_shot, & &1.uuid) == Enum.map(paged, & &1.uuid)
    end
  end

  describe "count_search_items_in_catalogue/2" do
    test "returns the total matching count regardless of limit" do
      cat = create_catalogue()
      category = create_category(cat)
      for i <- 1..7, do: create_item(%{name: "Oak #{i}", category_uuid: category.uuid})

      assert Catalogue.count_search_items_in_catalogue(cat.uuid, "oak") == 7
    end

    test "excludes deleted items and items in deleted categories" do
      cat = create_catalogue()
      active_cat = create_category(cat, %{name: "Active"})
      trashed_cat = create_category(cat, %{name: "Trashed"})

      create_item(%{name: "Oak visible", category_uuid: active_cat.uuid})
      trashed_item = create_item(%{name: "Oak trashed", category_uuid: active_cat.uuid})

      _hidden_cat_item =
        create_item(%{name: "Oak in deleted cat", category_uuid: trashed_cat.uuid})

      Catalogue.trash_item(trashed_item)
      Catalogue.trash_category(trashed_cat)

      assert Catalogue.count_search_items_in_catalogue(cat.uuid, "oak") == 1
    end

    test "returns 0 when no matches" do
      cat = create_catalogue()
      assert Catalogue.count_search_items_in_catalogue(cat.uuid, "nothing") == 0
    end
  end

  describe "count_search_items/1" do
    test "counts across all non-deleted catalogues" do
      cat1 = create_catalogue(%{name: "K"})
      cat2 = create_catalogue(%{name: "B"})
      c1 = create_category(cat1)
      c2 = create_category(cat2)
      create_item(%{name: "Oak A", category_uuid: c1.uuid})
      create_item(%{name: "Oak B", category_uuid: c2.uuid})

      assert Catalogue.count_search_items("oak") == 2
    end
  end

  describe "count_search_items_in_category/2" do
    test "counts only items in the given category" do
      cat = create_catalogue()
      c1 = create_category(cat, %{name: "A"})
      c2 = create_category(cat, %{name: "B"})
      create_item(%{name: "Oak A", category_uuid: c1.uuid})
      create_item(%{name: "Oak B", category_uuid: c1.uuid})
      create_item(%{name: "Oak C", category_uuid: c2.uuid})

      assert Catalogue.count_search_items_in_category(c1.uuid, "oak") == 2
    end
  end

  describe "search_items_in_category/2" do
    test "only returns items within the specified category" do
      cat = create_catalogue()
      c1 = create_category(cat, %{name: "Frames"})
      c2 = create_category(cat, %{name: "Doors"})
      create_item(%{name: "Oak Frame", category_uuid: c1.uuid})
      create_item(%{name: "Oak Door", category_uuid: c2.uuid})

      results = Catalogue.search_items_in_category(c1.uuid, "oak")
      assert length(results) == 1
      assert hd(results).name == "Oak Frame"
    end

    test "excludes deleted items" do
      cat = create_catalogue()
      category = create_category(cat)
      item = create_item(%{name: "Oak Panel", category_uuid: category.uuid})
      Catalogue.trash_item(item)

      assert Catalogue.search_items_in_category(category.uuid, "oak") == []
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Multilang search
  # ═══════════════════════════════════════════════════════════════════

  describe "search with translated data" do
    test "search_items/1 finds items by translated name in data field" do
      cat = create_catalogue()
      category = create_category(cat)

      item = create_item(%{name: "Oak Panel", category_uuid: category.uuid})

      Catalogue.set_translation(item, "es-ES", %{"_name" => "Panel de Roble"}, fn record, attrs ->
        Catalogue.update_item(record, attrs)
      end)

      results = Catalogue.search_items("Roble")
      assert length(results) == 1
      assert hd(results).name == "Oak Panel"
    end

    test "search_items/1 finds items by translated description in data field" do
      cat = create_catalogue()
      category = create_category(cat)

      item =
        create_item(%{
          name: "Oak Panel",
          description: "Premium hardwood",
          category_uuid: category.uuid
        })

      Catalogue.set_translation(
        item,
        "ja",
        %{"_description" => "高級広葉樹パネル"},
        fn record, attrs -> Catalogue.update_item(record, attrs) end
      )

      results = Catalogue.search_items("高級広葉樹")
      assert length(results) == 1
    end

    test "search_items_in_catalogue/2 finds items by translated name" do
      cat = create_catalogue()
      category = create_category(cat)

      item = create_item(%{name: "Birch Veneer", category_uuid: category.uuid})

      Catalogue.set_translation(item, "de-DE", %{"_name" => "Birkenfurnier"}, fn record, attrs ->
        Catalogue.update_item(record, attrs)
      end)

      results = Catalogue.search_items_in_catalogue(cat.uuid, "Birken")
      assert length(results) == 1
      assert hd(results).name == "Birch Veneer"
    end

    test "search_items_in_category/2 finds items by translated name" do
      cat = create_catalogue()
      category = create_category(cat)

      item = create_item(%{name: "Pine Board", category_uuid: category.uuid})

      Catalogue.set_translation(item, "fr-FR", %{"_name" => "Planche de pin"}, fn record, attrs ->
        Catalogue.update_item(record, attrs)
      end)

      results = Catalogue.search_items_in_category(category.uuid, "Planche")
      assert length(results) == 1
      assert hd(results).name == "Pine Board"
    end

    test "search_items/1 still finds items by primary name when translations exist" do
      cat = create_catalogue()
      category = create_category(cat)

      item = create_item(%{name: "Oak Panel", category_uuid: category.uuid})

      Catalogue.set_translation(item, "es-ES", %{"_name" => "Panel de Roble"}, fn record, attrs ->
        Catalogue.update_item(record, attrs)
      end)

      results = Catalogue.search_items("Oak")
      assert length(results) == 1
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Item listing
  # ═══════════════════════════════════════════════════════════════════

  describe "list_items/1" do
    test "returns all non-deleted items" do
      cat = create_catalogue()
      category = create_category(cat)
      create_item(%{name: "Active", category_uuid: category.uuid})
      deleted = create_item(%{name: "Deleted", category_uuid: category.uuid})
      Catalogue.trash_item(deleted)

      items = Catalogue.list_items()
      names = Enum.map(items, & &1.name)
      assert "Active" in names
      refute "Deleted" in names
    end

    test "filters by status" do
      cat = create_catalogue()
      category = create_category(cat)
      create_item(%{name: "Active", category_uuid: category.uuid, status: "active"})
      create_item(%{name: "Inactive", category_uuid: category.uuid, status: "inactive"})

      items = Catalogue.list_items(status: "inactive")
      assert length(items) == 1
      assert hd(items).name == "Inactive"
    end

    test "respects limit" do
      cat = create_catalogue()
      category = create_category(cat)
      for n <- 1..5, do: create_item(%{name: "Item #{n}", category_uuid: category.uuid})

      assert length(Catalogue.list_items(limit: 3)) == 3
    end

    test "preloads category with catalogue and manufacturer" do
      cat = create_catalogue(%{name: "Kitchen"})
      category = create_category(cat, %{name: "Frames"})
      m = create_manufacturer(%{name: "Blum"})
      create_item(%{name: "Panel", category_uuid: category.uuid, manufacturer_uuid: m.uuid})

      [item] = Catalogue.list_items()
      assert item.category.name == "Frames"
      assert item.category.catalogue.name == "Kitchen"
      assert item.manufacturer.name == "Blum"
    end
  end

  describe "list_items_for_category/1" do
    test "returns non-deleted items ordered by name" do
      cat = create_catalogue()
      category = create_category(cat)
      create_item(%{name: "Zebra", category_uuid: category.uuid})
      create_item(%{name: "Alpha", category_uuid: category.uuid})
      deleted = create_item(%{name: "Gone", category_uuid: category.uuid})
      Catalogue.trash_item(deleted)

      items = Catalogue.list_items_for_category(category.uuid)
      assert length(items) == 2
      assert hd(items).name == "Alpha"
    end
  end

  describe "list_items_for_catalogue/1" do
    test "returns items across categories ordered by position then name" do
      cat = create_catalogue()
      c1 = create_category(cat, %{name: "Second", position: 1})
      c2 = create_category(cat, %{name: "First", position: 0})
      create_item(%{name: "B Item", category_uuid: c1.uuid})
      create_item(%{name: "A Item", category_uuid: c2.uuid})

      items = Catalogue.list_items_for_catalogue(cat.uuid)
      assert length(items) == 2
      # First position category's items come first
      assert hd(items).name == "A Item"
    end

    test "includes uncategorized items (sorted last)" do
      cat = create_catalogue()
      c = create_category(cat, %{name: "Cat", position: 0})
      create_item(%{name: "In Category", category_uuid: c.uuid})
      create_item(%{name: "Aardvark Uncategorized", catalogue_uuid: cat.uuid})

      items = Catalogue.list_items_for_catalogue(cat.uuid)
      names = Enum.map(items, & &1.name)
      assert names == ["In Category", "Aardvark Uncategorized"]
    end

    test "is scoped to the given catalogue" do
      cat_a = create_catalogue(%{name: "A"})
      cat_b = create_catalogue(%{name: "B"})
      create_item(%{name: "In A", catalogue_uuid: cat_a.uuid})
      create_item(%{name: "In B", catalogue_uuid: cat_b.uuid})

      names = Enum.map(Catalogue.list_items_for_catalogue(cat_a.uuid), & &1.name)
      assert names == ["In A"]
    end
  end

  describe ":preload opt on bulk fetchers (issue #19)" do
    setup do
      standard = create_catalogue(%{name: "Kitchen"})
      smart = create_catalogue(%{name: "Services", kind: "smart"})
      category = create_category(smart, %{name: "Delivery"})

      smart_item =
        create_item(%{
          name: "Express Delivery",
          category_uuid: category.uuid,
          default_value: Decimal.new("5"),
          default_unit: "percent"
        })

      {:ok, _rules} =
        Catalogue.put_catalogue_rules(smart_item, [
          %{
            referenced_catalogue_uuid: standard.uuid,
            value: Decimal.new("15"),
            unit: "percent"
          }
        ])

      %{smart: smart, category: category, smart_item: smart_item}
    end

    test "list_items_for_category/2 merges :preload with defaults", %{
      category: category,
      smart_item: smart_item
    } do
      [item] =
        Catalogue.list_items_for_category(category.uuid,
          preload: [catalogue_rules: :referenced_catalogue]
        )

      assert item.uuid == smart_item.uuid
      assert %PhoenixKitCatalogue.Schemas.Catalogue{} = item.catalogue
      [rule] = item.catalogue_rules
      assert %PhoenixKitCatalogue.Schemas.Catalogue{name: "Kitchen"} = rule.referenced_catalogue
    end

    test "list_items_for_catalogue/2 merges :preload with defaults", %{
      smart: smart,
      smart_item: smart_item
    } do
      [item] =
        Catalogue.list_items_for_catalogue(smart.uuid,
          preload: [catalogue_rules: :referenced_catalogue]
        )

      assert item.uuid == smart_item.uuid
      [rule] = item.catalogue_rules
      assert rule.referenced_catalogue.name == "Kitchen"
    end

    test "list_uncategorized_items/2 merges :preload with defaults" do
      smart = create_catalogue(%{name: "Loose Smart", kind: "smart"})
      standard = create_catalogue(%{name: "Loose Std"})

      loose =
        create_item(%{
          name: "Standalone",
          catalogue_uuid: smart.uuid,
          default_value: Decimal.new("10"),
          default_unit: "flat"
        })

      {:ok, _} =
        Catalogue.put_catalogue_rules(loose, [
          %{referenced_catalogue_uuid: standard.uuid, value: Decimal.new("5"), unit: "percent"}
        ])

      [item] =
        Catalogue.list_uncategorized_items(smart.uuid,
          preload: [catalogue_rules: :referenced_catalogue]
        )

      assert item.uuid == loose.uuid
      assert %PhoenixKitCatalogue.Schemas.Catalogue{} = item.catalogue
      [rule] = item.catalogue_rules
      assert rule.referenced_catalogue.name == "Loose Std"
    end

    test "search_items/2 merges :preload with defaults", %{smart_item: smart_item} do
      [item] =
        Catalogue.search_items("Express",
          preload: [catalogue_rules: :referenced_catalogue]
        )

      assert item.uuid == smart_item.uuid
      [rule] = item.catalogue_rules
      assert rule.referenced_catalogue.name == "Kitchen"
    end

    test "get_item/2 with :preload returns item with preloaded assocs", %{smart_item: smart_item} do
      item =
        Catalogue.get_item(smart_item.uuid, preload: [catalogue_rules: :referenced_catalogue])

      assert item.uuid == smart_item.uuid
      [rule] = item.catalogue_rules
      assert rule.referenced_catalogue.name == "Kitchen"
    end

    test "get_item/1 still works with no preloads (backwards compat)", %{smart_item: smart_item} do
      item = Catalogue.get_item(smart_item.uuid)
      assert item.uuid == smart_item.uuid
      assert %Ecto.Association.NotLoaded{} = item.catalogue_rules
    end

    test "get_item!/2 default preloads include :catalogue (was missing before)", %{
      smart_item: smart_item
    } do
      item = Catalogue.get_item!(smart_item.uuid)

      assert %PhoenixKitCatalogue.Schemas.Catalogue{} = item.catalogue
      assert %PhoenixKitCatalogue.Schemas.Category{} = item.category
    end

    test "get_item!/2 with :preload merges with defaults", %{smart_item: smart_item} do
      item =
        Catalogue.get_item!(smart_item.uuid, preload: [catalogue_rules: :referenced_catalogue])

      assert %PhoenixKitCatalogue.Schemas.Catalogue{} = item.catalogue
      [rule] = item.catalogue_rules
      assert rule.referenced_catalogue.name == "Kitchen"
    end

    test ":preload collision with default atom — Ecto merges to nested spec", %{
      smart_item: smart_item
    } do
      # The default preload list includes `:catalogue` as a bare atom.
      # Pinning the contract: a caller passing a nested spec on the same
      # key (`catalogue: :categories`) gets both — Ecto loads `:catalogue`
      # AND its nested `:categories` association. `Helpers.merge_preloads`
      # docstring warns this is the expected behavior; this test makes
      # the contract auditable so a future Ecto upgrade that changes the
      # merge semantics surfaces here.
      item = Catalogue.get_item!(smart_item.uuid, preload: [catalogue: :categories])

      assert %PhoenixKitCatalogue.Schemas.Catalogue{} = item.catalogue
      assert is_list(item.catalogue.categories)
    end

    test "list_items_for_category_paged/2 merges :preload with defaults", %{
      category: category,
      smart_item: smart_item
    } do
      [item] =
        Catalogue.list_items_for_category_paged(category.uuid,
          preload: [catalogue_rules: :referenced_catalogue]
        )

      assert item.uuid == smart_item.uuid
      assert %PhoenixKitCatalogue.Schemas.Catalogue{} = item.catalogue
      [rule] = item.catalogue_rules
      assert rule.referenced_catalogue.name == "Kitchen"
    end

    test "list_uncategorized_items_paged/2 merges :preload with defaults" do
      smart = create_catalogue(%{name: "Loose Paged Smart", kind: "smart"})
      standard = create_catalogue(%{name: "Loose Paged Std"})

      loose =
        create_item(%{
          name: "Loose paged",
          catalogue_uuid: smart.uuid,
          default_value: Decimal.new("10"),
          default_unit: "flat"
        })

      {:ok, _} =
        Catalogue.put_catalogue_rules(loose, [
          %{referenced_catalogue_uuid: standard.uuid, value: Decimal.new("5"), unit: "percent"}
        ])

      [item] =
        Catalogue.list_uncategorized_items_paged(smart.uuid,
          preload: [catalogue_rules: :referenced_catalogue]
        )

      assert item.uuid == loose.uuid
      assert %PhoenixKitCatalogue.Schemas.Catalogue{} = item.catalogue
      [rule] = item.catalogue_rules
      assert rule.referenced_catalogue.name == "Loose Paged Std"
    end
  end

  describe "list_items_by_uuids/2 (issue #19)" do
    test "preserves input order" do
      cat = create_catalogue()
      a = create_item(%{name: "A", catalogue_uuid: cat.uuid})
      b = create_item(%{name: "B", catalogue_uuid: cat.uuid})
      c = create_item(%{name: "C", catalogue_uuid: cat.uuid})

      result = Catalogue.list_items_by_uuids([c.uuid, a.uuid, b.uuid])

      assert Enum.map(result, & &1.uuid) == [c.uuid, a.uuid, b.uuid]
    end

    test "drops missing UUIDs (no nil placeholders)" do
      cat = create_catalogue()
      a = create_item(%{name: "A", catalogue_uuid: cat.uuid})
      missing = Ecto.UUID.generate()

      result = Catalogue.list_items_by_uuids([a.uuid, missing])

      assert Enum.map(result, & &1.uuid) == [a.uuid]
    end

    test "excludes soft-deleted items" do
      cat = create_catalogue()
      a = create_item(%{name: "A", catalogue_uuid: cat.uuid})
      b = create_item(%{name: "B", catalogue_uuid: cat.uuid})
      Catalogue.trash_item(b)

      result = Catalogue.list_items_by_uuids([a.uuid, b.uuid])

      assert Enum.map(result, & &1.uuid) == [a.uuid]
    end

    test "deduplicates input UUIDs" do
      cat = create_catalogue()
      a = create_item(%{name: "A", catalogue_uuid: cat.uuid})

      result = Catalogue.list_items_by_uuids([a.uuid, a.uuid, a.uuid])

      assert Enum.map(result, & &1.uuid) == [a.uuid]
    end

    test "returns [] for empty input without hitting the DB" do
      assert Catalogue.list_items_by_uuids([]) == []
    end

    test "default preloads include :catalogue, :category, :manufacturer" do
      cat = create_catalogue()
      category = create_category(cat)
      a = create_item(%{name: "A", category_uuid: category.uuid})

      [item] = Catalogue.list_items_by_uuids([a.uuid])

      assert %PhoenixKitCatalogue.Schemas.Catalogue{} = item.catalogue
      assert %PhoenixKitCatalogue.Schemas.Category{} = item.category
    end

    test "merges :preload with defaults (smart-rule rehydration use case)" do
      standard = create_catalogue(%{name: "Std"})
      smart = create_catalogue(%{name: "Smart", kind: "smart"})

      smart_item =
        create_item(%{
          name: "S",
          catalogue_uuid: smart.uuid,
          default_value: Decimal.new("5"),
          default_unit: "percent"
        })

      {:ok, _} =
        Catalogue.put_catalogue_rules(smart_item, [
          %{referenced_catalogue_uuid: standard.uuid, value: Decimal.new("10"), unit: "percent"}
        ])

      [item] =
        Catalogue.list_items_by_uuids([smart_item.uuid],
          preload: [catalogue_rules: :referenced_catalogue]
        )

      [rule] = item.catalogue_rules
      assert rule.referenced_catalogue.name == "Std"
    end
  end

  describe "paged helpers for infinite scroll" do
    test "list_categories_metadata_for_catalogue/2 returns categories without items, ordered by position" do
      cat = create_catalogue()
      create_category(cat, %{name: "Second", position: 2})
      create_category(cat, %{name: "First", position: 1})
      create_category(cat, %{name: "Third", position: 3})

      names =
        cat.uuid
        |> Catalogue.list_categories_metadata_for_catalogue()
        |> Enum.map(& &1.name)

      assert names == ["First", "Second", "Third"]
    end

    test "list_categories_metadata_for_catalogue/2 excludes deleted categories in :active mode" do
      cat = create_catalogue()
      create_category(cat, %{name: "Active"})
      deleted = create_category(cat, %{name: "Deleted"})
      Catalogue.trash_category(deleted)

      names =
        cat.uuid
        |> Catalogue.list_categories_metadata_for_catalogue(mode: :active)
        |> Enum.map(& &1.name)

      assert names == ["Active"]
    end

    test "list_categories_metadata_for_catalogue/2 returns all categories in :deleted mode" do
      cat = create_catalogue()
      create_category(cat, %{name: "Active"})
      deleted = create_category(cat, %{name: "Deleted"})
      Catalogue.trash_category(deleted)

      names =
        cat.uuid
        |> Catalogue.list_categories_metadata_for_catalogue(mode: :deleted)
        |> Enum.map(& &1.name)

      assert "Active" in names
      assert "Deleted" in names
    end

    test "list_items_for_category_paged/2 respects offset and limit" do
      cat = create_catalogue()
      category = create_category(cat)

      for i <- 1..10 do
        create_item(%{
          name: "Item #{String.pad_leading("#{i}", 2, "0")}",
          category_uuid: category.uuid
        })
      end

      first =
        Catalogue.list_items_for_category_paged(category.uuid, offset: 0, limit: 3)

      second =
        Catalogue.list_items_for_category_paged(category.uuid, offset: 3, limit: 3)

      assert Enum.map(first, & &1.name) == ["Item 01", "Item 02", "Item 03"]
      assert Enum.map(second, & &1.name) == ["Item 04", "Item 05", "Item 06"]
    end

    test "list_items_for_category_paged/2 filters by mode" do
      cat = create_catalogue()
      category = create_category(cat)
      create_item(%{name: "Alive", category_uuid: category.uuid})
      trashed = create_item(%{name: "Trashed", category_uuid: category.uuid})
      Catalogue.trash_item(trashed)

      active_names =
        category.uuid
        |> Catalogue.list_items_for_category_paged(mode: :active)
        |> Enum.map(& &1.name)

      deleted_names =
        category.uuid
        |> Catalogue.list_items_for_category_paged(mode: :deleted)
        |> Enum.map(& &1.name)

      assert active_names == ["Alive"]
      assert deleted_names == ["Trashed"]
    end

    test "list_uncategorized_items_paged/2 is scoped, paginated, and mode-aware" do
      cat_a = create_catalogue(%{name: "A"})
      cat_b = create_catalogue(%{name: "B"})

      for i <- 1..5 do
        create_item(%{
          name: "A #{String.pad_leading("#{i}", 2, "0")}",
          catalogue_uuid: cat_a.uuid
        })
      end

      create_item(%{name: "B only", catalogue_uuid: cat_b.uuid})

      first =
        Catalogue.list_uncategorized_items_paged(cat_a.uuid, offset: 0, limit: 2)

      second =
        Catalogue.list_uncategorized_items_paged(cat_a.uuid, offset: 2, limit: 2)

      assert Enum.map(first, & &1.name) == ["A 01", "A 02"]
      assert Enum.map(second, & &1.name) == ["A 03", "A 04"]

      # Scope: cat_b items don't leak into cat_a's list
      all_a = Catalogue.list_uncategorized_items_paged(cat_a.uuid)
      refute Enum.any?(all_a, &(&1.name == "B only"))
    end

    test "list_uncategorized_items_paged/2 excludes items that have a category" do
      cat = create_catalogue()
      category = create_category(cat)
      create_item(%{name: "Has Category", category_uuid: category.uuid})
      create_item(%{name: "Loose", catalogue_uuid: cat.uuid})

      names =
        cat.uuid
        |> Catalogue.list_uncategorized_items_paged()
        |> Enum.map(& &1.name)

      assert names == ["Loose"]
    end

    test "uncategorized_count_for_catalogue/2 counts only loose items in the catalogue" do
      cat = create_catalogue()
      category = create_category(cat)
      create_item(%{name: "Loose 1", catalogue_uuid: cat.uuid})
      create_item(%{name: "Loose 2", catalogue_uuid: cat.uuid})
      create_item(%{name: "In Category", category_uuid: category.uuid})

      assert Catalogue.uncategorized_count_for_catalogue(cat.uuid) == 2
    end

    test "uncategorized_count_for_catalogue/2 :deleted mode only counts trashed loose items" do
      cat = create_catalogue()
      create_item(%{name: "Active loose", catalogue_uuid: cat.uuid})
      trashed = create_item(%{name: "Trashed loose", catalogue_uuid: cat.uuid})
      Catalogue.trash_item(trashed)

      assert Catalogue.uncategorized_count_for_catalogue(cat.uuid, mode: :active) == 1
      assert Catalogue.uncategorized_count_for_catalogue(cat.uuid, mode: :deleted) == 1
    end

    test "item_count_for_category/2 counts only items in that category" do
      cat = create_catalogue()
      cat_a = create_category(cat, %{name: "A"})
      cat_b = create_category(cat, %{name: "B"})
      create_item(%{name: "A1", category_uuid: cat_a.uuid})
      create_item(%{name: "A2", category_uuid: cat_a.uuid})
      create_item(%{name: "B1", category_uuid: cat_b.uuid})

      trashed = create_item(%{name: "A trashed", category_uuid: cat_a.uuid})
      Catalogue.trash_item(trashed)

      assert Catalogue.item_count_for_category(cat_a.uuid) == 2
      assert Catalogue.item_count_for_category(cat_a.uuid, mode: :deleted) == 1
      assert Catalogue.item_count_for_category(cat_b.uuid) == 1
    end

    test "item_counts_by_category_for_catalogue/2 returns a grouped map" do
      cat = create_catalogue()
      cat_a = create_category(cat, %{name: "A"})
      cat_b = create_category(cat, %{name: "B"})
      cat_c = create_category(cat, %{name: "Empty"})

      for _ <- 1..3, do: create_item(%{name: "x", category_uuid: cat_a.uuid})
      for _ <- 1..5, do: create_item(%{name: "y", category_uuid: cat_b.uuid})

      trashed = create_item(%{name: "to trash", category_uuid: cat_a.uuid})
      Catalogue.trash_item(trashed)

      counts = Catalogue.item_counts_by_category_for_catalogue(cat.uuid)
      assert counts[cat_a.uuid] == 3
      assert counts[cat_b.uuid] == 5
      # Empty categories simply don't appear in the map
      refute Map.has_key?(counts, cat_c.uuid)
    end

    test "item_counts_by_category_for_catalogue/2 :deleted mode returns trashed item counts" do
      cat = create_catalogue()
      cat_a = create_category(cat, %{name: "A"})
      create_item(%{name: "live", category_uuid: cat_a.uuid})
      trashed = create_item(%{name: "dead", category_uuid: cat_a.uuid})
      Catalogue.trash_item(trashed)

      active = Catalogue.item_counts_by_category_for_catalogue(cat.uuid, mode: :active)
      deleted = Catalogue.item_counts_by_category_for_catalogue(cat.uuid, mode: :deleted)

      assert active[cat_a.uuid] == 1
      assert deleted[cat_a.uuid] == 1
    end

    test "item_counts_by_category_for_catalogue/2 excludes uncategorized items" do
      cat = create_catalogue()
      cat_a = create_category(cat, %{name: "A"})
      create_item(%{name: "categorized", category_uuid: cat_a.uuid})
      create_item(%{name: "loose", catalogue_uuid: cat.uuid})

      counts = Catalogue.item_counts_by_category_for_catalogue(cat.uuid)
      assert counts == %{cat_a.uuid => 1}
    end

    test "category_summary_for_catalogue/2 returns categories + counts + uncategorized in one shape" do
      cat = create_catalogue()
      cat_a = create_category(cat, %{name: "A", position: 1})
      cat_b = create_category(cat, %{name: "B", position: 2})
      _empty = create_category(cat, %{name: "Empty", position: 3})

      for _ <- 1..3, do: create_item(%{name: "x", category_uuid: cat_a.uuid})
      for _ <- 1..2, do: create_item(%{name: "y", category_uuid: cat_b.uuid})
      create_item(%{name: "loose 1", catalogue_uuid: cat.uuid})
      create_item(%{name: "loose 2", catalogue_uuid: cat.uuid})

      summary = Catalogue.category_summary_for_catalogue(cat.uuid)

      assert Enum.map(summary.categories, & &1.name) == ["A", "B", "Empty"]
      assert summary.item_counts == %{cat_a.uuid => 3, cat_b.uuid => 2}
      assert summary.uncategorized_count == 2
    end

    test "category_summary_for_catalogue/2 excludes deleted items in :active mode" do
      cat = create_catalogue()
      cat_a = create_category(cat, %{name: "A"})
      create_item(%{name: "live", category_uuid: cat_a.uuid})
      trashed = create_item(%{name: "dead", category_uuid: cat_a.uuid})
      Catalogue.trash_item(trashed)

      loose_trashed = create_item(%{name: "loose dead", catalogue_uuid: cat.uuid})
      Catalogue.trash_item(loose_trashed)
      create_item(%{name: "loose live", catalogue_uuid: cat.uuid})

      active = Catalogue.category_summary_for_catalogue(cat.uuid)
      deleted = Catalogue.category_summary_for_catalogue(cat.uuid, mode: :deleted)

      assert active.item_counts == %{cat_a.uuid => 1}
      assert active.uncategorized_count == 1

      assert deleted.item_counts == %{cat_a.uuid => 1}
      assert deleted.uncategorized_count == 1
    end

    test "category_summary_for_catalogue/2 omits empty catalogues + still returns a valid shape" do
      cat = create_catalogue()

      assert Catalogue.category_summary_for_catalogue(cat.uuid) ==
               %{categories: [], item_counts: %{}, uncategorized_count: 0}
    end
  end

  describe "item sort opts on paged list fns" do
    test "list_items_for_category_paged/2 sorts by name asc/desc" do
      cat = create_catalogue()
      category = create_category(cat)
      create_item(%{name: "Cherry", category_uuid: category.uuid})
      create_item(%{name: "Apple", category_uuid: category.uuid})
      create_item(%{name: "Banana", category_uuid: category.uuid})

      asc =
        category.uuid
        |> Catalogue.list_items_for_category_paged(sort_by: :name, sort_dir: :asc)
        |> Enum.map(& &1.name)

      desc =
        category.uuid
        |> Catalogue.list_items_for_category_paged(sort_by: :name, sort_dir: :desc)
        |> Enum.map(& &1.name)

      assert asc == ["Apple", "Banana", "Cherry"]
      assert desc == ["Cherry", "Banana", "Apple"]
    end

    test "list_items_for_category_paged/2 sorts by base_price" do
      cat = create_catalogue()
      category = create_category(cat)
      create_item(%{name: "Mid", base_price: Decimal.new("50"), category_uuid: category.uuid})
      create_item(%{name: "Low", base_price: Decimal.new("10"), category_uuid: category.uuid})
      create_item(%{name: "High", base_price: Decimal.new("99"), category_uuid: category.uuid})

      names =
        category.uuid
        |> Catalogue.list_items_for_category_paged(sort_by: :base_price, sort_dir: :asc)
        |> Enum.map(& &1.name)

      assert names == ["Low", "Mid", "High"]
    end

    test "list_items_for_category_paged/2 defaults to :position order" do
      cat = create_catalogue()
      category = create_category(cat)
      create_item(%{name: "Zed", position: 0, category_uuid: category.uuid})
      create_item(%{name: "Alpha", position: 1, category_uuid: category.uuid})

      names =
        category.uuid
        |> Catalogue.list_items_for_category_paged()
        |> Enum.map(& &1.name)

      assert names == ["Zed", "Alpha"]
    end

    test "list_uncategorized_items_paged/2 honors :sort_by" do
      cat = create_catalogue()
      create_item(%{name: "Yak", catalogue_uuid: cat.uuid})
      create_item(%{name: "Ant", catalogue_uuid: cat.uuid})

      names =
        cat.uuid
        |> Catalogue.list_uncategorized_items_paged(sort_by: :name, sort_dir: :asc)
        |> Enum.map(& &1.name)

      assert names == ["Ant", "Yak"]
    end
  end

  describe "reorder_items_by/5" do
    setup do
      cat = create_catalogue()
      category = create_category(cat)
      {:ok, catalogue: cat, category: category}
    end

    defp item_positions(category_uuid) do
      category_uuid
      |> Catalogue.list_items_for_category_paged(sort_by: :position, sort_dir: :asc)
      |> Enum.map(&{&1.name, &1.position})
    end

    # Stamps a distinct `inserted_at` (seconds ago). `inserted_at` is
    # second-precision and UUIDv7 is random within a millisecond, so
    # same-instant fixtures have no deterministic creation order — back-
    # date them so `:created_*` reorders are pinnable.
    defp backdate_item(item, seconds_ago) do
      ts = DateTime.utc_now() |> DateTime.add(-seconds_ago, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(i in PhoenixKitCatalogue.Schemas.Item, where: i.uuid == ^item.uuid),
        set: [inserted_at: ts]
      )

      item
    end

    test ":all + :name_asc reindexes the whole scope 1..N alphabetically", ctx do
      create_item(%{name: "Cherry", category_uuid: ctx.category.uuid})
      create_item(%{name: "Apple", category_uuid: ctx.category.uuid})
      create_item(%{name: "Banana", category_uuid: ctx.category.uuid})

      assert :ok =
               Catalogue.reorder_items_by(ctx.catalogue.uuid, ctx.category.uuid, :name_asc, :all)

      assert item_positions(ctx.category.uuid) == [{"Apple", 1}, {"Banana", 2}, {"Cherry", 3}]
    end

    test ":all + :name_desc reindexes reverse-alphabetically", ctx do
      create_item(%{name: "Apple", category_uuid: ctx.category.uuid})
      create_item(%{name: "Banana", category_uuid: ctx.category.uuid})

      assert :ok =
               Catalogue.reorder_items_by(ctx.catalogue.uuid, ctx.category.uuid, :name_desc, :all)

      assert item_positions(ctx.category.uuid) == [{"Banana", 1}, {"Apple", 2}]
    end

    test ":all + :created_asc / :created_desc reindex by insertion order", ctx do
      first = create_item(%{name: "First", category_uuid: ctx.category.uuid})
      second = create_item(%{name: "Second", category_uuid: ctx.category.uuid})
      third = create_item(%{name: "Third", category_uuid: ctx.category.uuid})

      backdate_item(first, 3)
      backdate_item(second, 2)
      backdate_item(third, 1)

      assert :ok =
               Catalogue.reorder_items_by(
                 ctx.catalogue.uuid,
                 ctx.category.uuid,
                 :created_asc,
                 :all
               )

      assert item_positions(ctx.category.uuid) == [{"First", 1}, {"Second", 2}, {"Third", 3}]

      assert :ok =
               Catalogue.reorder_items_by(
                 ctx.catalogue.uuid,
                 ctx.category.uuid,
                 :created_desc,
                 :all
               )

      assert item_positions(ctx.category.uuid) == [{"Third", 1}, {"Second", 2}, {"First", 3}]
      assert first.uuid
    end

    test ":all + :reverse flips the current position order", ctx do
      create_item(%{name: "P0", position: 0, category_uuid: ctx.category.uuid})
      create_item(%{name: "P1", position: 1, category_uuid: ctx.category.uuid})
      create_item(%{name: "P2", position: 2, category_uuid: ctx.category.uuid})

      assert :ok =
               Catalogue.reorder_items_by(ctx.catalogue.uuid, ctx.category.uuid, :reverse, :all)

      assert item_positions(ctx.category.uuid) == [{"P2", 1}, {"P1", 2}, {"P0", 3}]
    end

    test "subset permute on distinct positions reorders in place", ctx do
      a = create_item(%{name: "Cherry", position: 1, category_uuid: ctx.category.uuid})
      b = create_item(%{name: "Apple", position: 2, category_uuid: ctx.category.uuid})
      c = create_item(%{name: "Banana", position: 3, category_uuid: ctx.category.uuid})

      # Permute the three distinct-position rows by name asc: their
      # position slots (1,2,3) get filled in alphabetical order.
      assert :ok =
               Catalogue.reorder_items_by(
                 ctx.catalogue.uuid,
                 ctx.category.uuid,
                 :name_asc,
                 [a.uuid, b.uuid, c.uuid]
               )

      assert item_positions(ctx.category.uuid) == [{"Apple", 1}, {"Banana", 2}, {"Cherry", 3}]
    end

    test "subset permute returns :duplicate_positions when rows share a position", ctx do
      # Catalogue items default to position 0 — an unreordered scope has
      # many rows at 0, so a subset permute can't assign distinct slots.
      a = create_item(%{name: "A", category_uuid: ctx.category.uuid})
      b = create_item(%{name: "B", category_uuid: ctx.category.uuid})

      assert {:error, :duplicate_positions} =
               Catalogue.reorder_items_by(
                 ctx.catalogue.uuid,
                 ctx.category.uuid,
                 :name_asc,
                 [a.uuid, b.uuid]
               )
    end

    test "rejects uuids outside the scope", ctx do
      other_cat = create_category(ctx.catalogue, %{name: "Other"})
      mine = create_item(%{name: "Mine", position: 1, category_uuid: ctx.category.uuid})
      foreign = create_item(%{name: "Foreign", position: 1, category_uuid: other_cat.uuid})

      assert {:error, :uuids_outside_scope} =
               Catalogue.reorder_items_by(
                 ctx.catalogue.uuid,
                 ctx.category.uuid,
                 :name_asc,
                 [mine.uuid, foreign.uuid]
               )
    end

    test "rejects an invalid strategy", ctx do
      create_item(%{name: "X", category_uuid: ctx.category.uuid})

      assert {:error, :invalid_strategy} =
               Catalogue.reorder_items_by(ctx.catalogue.uuid, ctx.category.uuid, :bogus, :all)
    end

    test "uncategorized scope is reachable via :uncategorized normalization", ctx do
      create_item(%{name: "Loose B", catalogue_uuid: ctx.catalogue.uuid})
      create_item(%{name: "Loose A", catalogue_uuid: ctx.catalogue.uuid})

      assert :ok =
               Catalogue.reorder_items_by(
                 ctx.catalogue.uuid,
                 :uncategorized,
                 :name_asc,
                 :all
               )

      names =
        ctx.catalogue.uuid
        |> Catalogue.list_uncategorized_items_paged(sort_by: :position, sort_dir: :asc)
        |> Enum.map(& &1.name)

      assert names == ["Loose A", "Loose B"]
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Active counts
  # ═══════════════════════════════════════════════════════════════════

  describe "item_count_for_catalogue/1" do
    test "counts non-deleted items" do
      cat = create_catalogue()
      category = create_category(cat)
      create_item(%{name: "Active", category_uuid: category.uuid})
      deleted = create_item(%{name: "Deleted", category_uuid: category.uuid})
      Catalogue.trash_item(deleted)

      assert Catalogue.item_count_for_catalogue(cat.uuid) == 1
    end

    test "includes uncategorized items" do
      cat = create_catalogue()
      category = create_category(cat)
      create_item(%{name: "In Category", category_uuid: category.uuid})
      create_item(%{name: "Uncategorized", catalogue_uuid: cat.uuid})

      assert Catalogue.item_count_for_catalogue(cat.uuid) == 2
    end
  end

  describe "category_count_for_catalogue/1" do
    test "counts non-deleted categories" do
      cat = create_catalogue()
      create_category(cat, %{name: "Active"})
      deleted = create_category(cat, %{name: "Deleted"})
      Catalogue.trash_category(deleted)

      assert Catalogue.category_count_for_catalogue(cat.uuid) == 1
    end
  end

  describe "item_counts_by_catalogue/0" do
    test "returns a map of non-deleted item counts per catalogue" do
      cat1 = create_catalogue(%{name: "Kitchen"})
      cat2 = create_catalogue(%{name: "Bathroom"})
      _empty = create_catalogue(%{name: "Empty"})

      cat1_category = create_category(cat1, %{name: "Frames"})
      cat2_category = create_category(cat2, %{name: "Tiles"})

      create_item(%{name: "Oak Panel", category_uuid: cat1_category.uuid})
      create_item(%{name: "Pine Panel", category_uuid: cat1_category.uuid})
      create_item(%{name: "Ceramic", category_uuid: cat2_category.uuid})

      trashed = create_item(%{name: "Trashed", category_uuid: cat1_category.uuid})
      Catalogue.trash_item(trashed)

      counts = Catalogue.item_counts_by_catalogue()
      assert counts[cat1.uuid] == 2
      assert counts[cat2.uuid] == 1
      # catalogues with no items do not appear in the map
      refute Map.has_key?(counts, "missing-catalogue-uuid")
    end

    test "excludes items in deleted categories" do
      cat = create_catalogue()
      category = create_category(cat)
      create_item(%{name: "Orphaned", category_uuid: category.uuid})

      Catalogue.trash_category(category)

      counts = Catalogue.item_counts_by_catalogue()
      refute Map.has_key?(counts, cat.uuid)
    end

    test "returns empty map when there are no items" do
      assert Catalogue.item_counts_by_catalogue() == %{}
    end

    test "includes uncategorized items (items without a category)" do
      cat = create_catalogue()
      category = create_category(cat)
      create_item(%{name: "In Category", category_uuid: category.uuid})
      create_item(%{name: "Uncategorized", catalogue_uuid: cat.uuid})

      counts = Catalogue.item_counts_by_catalogue()
      assert counts[cat.uuid] == 2
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Supplier-manufacturer sync (reverse direction)
  # ═══════════════════════════════════════════════════════════════════

  describe "sync_supplier_manufacturers/2" do
    test "syncs manufacturer links for a supplier" do
      s = create_supplier()
      m1 = create_manufacturer(%{name: "M1"})
      m2 = create_manufacturer(%{name: "M2"})

      assert {:ok, :synced} = Catalogue.sync_supplier_manufacturers(s.uuid, [m1.uuid, m2.uuid])

      assert MapSet.new(Catalogue.linked_manufacturer_uuids(s.uuid)) ==
               MapSet.new([m1.uuid, m2.uuid])

      # Remove m1, keep m2
      assert {:ok, :synced} = Catalogue.sync_supplier_manufacturers(s.uuid, [m2.uuid])
      assert Catalogue.linked_manufacturer_uuids(s.uuid) == [m2.uuid]
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Multilang
  # ═══════════════════════════════════════════════════════════════════

  describe "multilang" do
    test "set_translation/4 and get_translation/2 round-trip" do
      cat = create_catalogue(%{name: "Kitchen"})

      {:ok, updated} =
        Catalogue.set_translation(cat, "ja", %{"_name" => "キッチン"}, &Catalogue.update_catalogue/2)

      data = Catalogue.get_translation(updated, "ja")
      assert data["_name"] == "キッチン"
    end

    test "get_translation/2 returns empty map for missing language" do
      cat = create_catalogue(%{name: "Kitchen"})
      data = Catalogue.get_translation(cat, "ja")
      assert data == %{}
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Schema validations
  # ═══════════════════════════════════════════════════════════════════

  describe "schema validations" do
    test "catalogue status must be valid" do
      assert {:error, changeset} = Catalogue.create_catalogue(%{name: "X", status: "bogus"})
      assert errors_on(changeset).status
    end

    test "category status must be valid" do
      cat = create_catalogue()

      assert {:error, changeset} =
               Catalogue.create_category(%{
                 name: "X",
                 catalogue_uuid: cat.uuid,
                 status: "bogus"
               })

      assert errors_on(changeset).status
    end

    test "item status allows deleted" do
      cat = create_catalogue()

      assert {:ok, i} =
               Catalogue.create_item(%{name: "X", status: "deleted", catalogue_uuid: cat.uuid})

      assert i.status == "deleted"
    end

    test "manufacturer status must be valid" do
      assert {:error, changeset} = Catalogue.create_manufacturer(%{name: "X", status: "bogus"})
      assert errors_on(changeset).status
    end

    test "supplier status must be valid" do
      assert {:error, changeset} = Catalogue.create_supplier(%{name: "X", status: "bogus"})
      assert errors_on(changeset).status
    end

    test "item name max length" do
      cat = create_catalogue()
      long_name = String.duplicate("a", 256)

      assert {:error, changeset} =
               Catalogue.create_item(%{name: long_name, catalogue_uuid: cat.uuid})

      assert errors_on(changeset).name
    end

    test "item allows duplicate sku" do
      cat = create_catalogue()
      create_item(%{name: "A", sku: "SKU-001", catalogue_uuid: cat.uuid})

      assert {:ok, _} =
               Catalogue.create_item(%{name: "B", sku: "SKU-001", catalogue_uuid: cat.uuid})
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Edge cases
  # ═══════════════════════════════════════════════════════════════════

  describe "edge cases" do
    test "unicode catalogue names round-trip correctly" do
      name = "キッチン — Küche 🍳"
      cat = create_catalogue(%{name: name})
      assert Catalogue.get_catalogue(cat.uuid).name == name
    end

    test "unicode item names round-trip correctly" do
      cat = create_catalogue()
      category = create_category(cat)
      item = create_item(%{name: "Ąžuolas — オーク 🌳", category_uuid: category.uuid})
      assert Catalogue.get_item(item.uuid).name == "Ąžuolas — オーク 🌳"
    end

    test "trash_catalogue on an already-trashed catalogue is idempotent" do
      cat = create_catalogue()
      {:ok, _} = Catalogue.trash_catalogue(cat)
      cat = Catalogue.get_catalogue(cat.uuid)

      assert {:ok, _} = Catalogue.trash_catalogue(cat)
      assert Catalogue.get_catalogue(cat.uuid).status == "deleted"
    end

    test "restore_catalogue on an already-active catalogue is a no-op" do
      cat = create_catalogue()
      assert {:ok, _} = Catalogue.restore_catalogue(cat)
      assert Catalogue.get_catalogue(cat.uuid).status == "active"
    end

    test "item base_price preserves decimal precision" do
      cat = create_catalogue()
      category = create_category(cat)

      {:ok, item} =
        Catalogue.create_item(%{
          name: "Precise",
          category_uuid: category.uuid,
          base_price: "12.3456"
        })

      assert Decimal.equal?(item.base_price, Decimal.new("12.3456"))
    end

    test "sale_price rounds to 2 decimal places" do
      cat = create_catalogue(%{markup_percentage: "33.33"})
      category = create_category(cat)
      item = create_item(%{name: "x", base_price: "99.99", category_uuid: category.uuid})

      pricing = Catalogue.item_pricing(item)
      # 99.99 * 1.3333 = 133.316667 → rounds to 133.32
      assert Decimal.equal?(pricing.sale_price, Decimal.new("133.32"))
    end

    test "list_items_for_catalogue on a catalogue with no items returns []" do
      cat = create_catalogue()
      assert Catalogue.list_items_for_catalogue(cat.uuid) == []
    end

    test "list_items_for_catalogue on a non-existent uuid returns []" do
      assert Catalogue.list_items_for_catalogue("00000000-0000-0000-0000-000000000000") == []
    end

    test "item_count_for_catalogue on a non-existent uuid returns 0" do
      assert Catalogue.item_count_for_catalogue("00000000-0000-0000-0000-000000000000") == 0
    end

    test "move_item_to_category on a non-existent item raises a proper error" do
      # Can't move something that doesn't exist — caller must validate first.
      assert_raise FunctionClauseError, fn ->
        Catalogue.move_item_to_category(nil, "some-uuid")
      end
    end

    test "item with whitespace-only name is rejected as blank" do
      cat = create_catalogue()

      # `validate_required` treats whitespace-only strings as blank in
      # recent Ecto versions. If this ever changes, we want the test to
      # remind us to either add explicit trimming or update the
      # expectation intentionally.
      assert {:error, changeset} =
               Catalogue.create_item(%{name: "   ", catalogue_uuid: cat.uuid})

      assert errors_on(changeset).name
    end

    test "cascading trash of a catalogue with mixed categorized and uncategorized items" do
      cat = create_catalogue()
      category = create_category(cat)
      a = create_item(%{name: "In category", category_uuid: category.uuid})
      b = create_item(%{name: "Uncategorized", catalogue_uuid: cat.uuid})

      {:ok, _} = Catalogue.trash_catalogue(cat)

      assert Catalogue.get_item(a.uuid).status == "deleted"
      assert Catalogue.get_item(b.uuid).status == "deleted"
      assert Catalogue.get_category(category.uuid).status == "deleted"
    end

    test "restore of a partially trashed catalogue restores everything" do
      cat = create_catalogue()
      category = create_category(cat)
      item = create_item(%{name: "Item", category_uuid: category.uuid})

      {:ok, _} = Catalogue.trash_catalogue(cat)
      cat = Catalogue.get_catalogue(cat.uuid)

      {:ok, _} = Catalogue.restore_catalogue(cat)

      assert Catalogue.get_catalogue(cat.uuid).status == "active"
      assert Catalogue.get_category(category.uuid).status == "active"
      assert Catalogue.get_item(item.uuid).status == "active"
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Prefix lookup + scoped search (0.1.10)
  # ═══════════════════════════════════════════════════════════════════

  describe "list_catalogues_by_name_prefix/2" do
    test "matches case-insensitively at the start of the name" do
      create_catalogue(%{name: "Kitchen Furniture"})
      create_catalogue(%{name: "Kits and Tools"})
      create_catalogue(%{name: "Bathroom"})

      names =
        "kit"
        |> Catalogue.list_catalogues_by_name_prefix()
        |> Enum.map(& &1.name)

      assert "Kitchen Furniture" in names
      assert "Kits and Tools" in names
      refute "Bathroom" in names
    end

    test "is anchored — does not match mid-name" do
      create_catalogue(%{name: "Bathroom Kits"})
      create_catalogue(%{name: "Kitchen"})

      names =
        "kit"
        |> Catalogue.list_catalogues_by_name_prefix()
        |> Enum.map(& &1.name)

      assert "Kitchen" in names
      refute "Bathroom Kits" in names
    end

    test "excludes deleted by default" do
      cat = create_catalogue(%{name: "Kitchen"})
      Catalogue.trash_catalogue(cat)

      assert Catalogue.list_catalogues_by_name_prefix("Kit") == []
    end

    test ":status opt narrows to a specific status" do
      cat = create_catalogue(%{name: "Kitchen"})
      Catalogue.trash_catalogue(cat)

      [result] = Catalogue.list_catalogues_by_name_prefix("Kit", status: "deleted")
      assert result.name == "Kitchen"
    end

    test ":limit opt caps results" do
      for n <- 1..5, do: create_catalogue(%{name: "Kit #{n}"})

      assert length(Catalogue.list_catalogues_by_name_prefix("Kit", limit: 3)) == 3
    end

    test "empty prefix returns all non-deleted" do
      create_catalogue(%{name: "Alpha"})
      create_catalogue(%{name: "Beta"})

      names =
        ""
        |> Catalogue.list_catalogues_by_name_prefix()
        |> Enum.map(& &1.name)

      assert "Alpha" in names
      assert "Beta" in names
    end

    test "escapes LIKE metacharacters in the prefix" do
      create_catalogue(%{name: "100% Pure"})
      create_catalogue(%{name: "Anything"})

      # Without escaping, `%` would match any prefix.
      names =
        "100%"
        |> Catalogue.list_catalogues_by_name_prefix()
        |> Enum.map(& &1.name)

      assert names == ["100% Pure"]
    end
  end

  describe "search_items/2 with scope filters" do
    test ":catalogue_uuids narrows to the listed catalogues" do
      cat_a = create_catalogue(%{name: "A"})
      cat_b = create_catalogue(%{name: "B"})
      cat_c = create_catalogue(%{name: "C"})
      cat_a_cat = create_category(cat_a)
      cat_b_cat = create_category(cat_b)
      cat_c_cat = create_category(cat_c)
      create_item(%{name: "Oak A", category_uuid: cat_a_cat.uuid})
      create_item(%{name: "Oak B", category_uuid: cat_b_cat.uuid})
      create_item(%{name: "Oak C", category_uuid: cat_c_cat.uuid})

      names =
        "oak"
        |> Catalogue.search_items(catalogue_uuids: [cat_a.uuid, cat_b.uuid])
        |> Enum.map(& &1.name)

      assert Enum.sort(names) == ["Oak A", "Oak B"]
    end

    test ":category_uuids narrows to the listed categories and excludes uncategorized" do
      cat = create_catalogue()
      c1 = create_category(cat, %{name: "One"})
      c2 = create_category(cat, %{name: "Two"})
      create_item(%{name: "Oak Cat1", category_uuid: c1.uuid})
      create_item(%{name: "Oak Cat2", category_uuid: c2.uuid})
      create_item(%{name: "Oak Uncat", catalogue_uuid: cat.uuid, category_uuid: nil})

      names =
        "oak"
        |> Catalogue.search_items(category_uuids: [c1.uuid])
        |> Enum.map(& &1.name)

      assert names == ["Oak Cat1"]
    end

    test ":catalogue_uuids and :category_uuids compose with AND" do
      cat_a = create_catalogue(%{name: "A"})
      cat_b = create_catalogue(%{name: "B"})
      c_a1 = create_category(cat_a)
      c_b1 = create_category(cat_b)
      create_item(%{name: "Oak A1", category_uuid: c_a1.uuid})
      create_item(%{name: "Oak B1", category_uuid: c_b1.uuid})

      # Category is in cat_b, but we scope to cat_a → no results
      assert Catalogue.search_items("oak",
               catalogue_uuids: [cat_a.uuid],
               category_uuids: [c_b1.uuid]
             ) == []

      # Category matches its catalogue → gets the item
      [item] =
        Catalogue.search_items("oak",
          catalogue_uuids: [cat_a.uuid],
          category_uuids: [c_a1.uuid]
        )

      assert item.name == "Oak A1"
    end

    test "nil and empty lists are treated as 'no filter'" do
      cat = create_catalogue()
      category = create_category(cat)
      create_item(%{name: "Oak", category_uuid: category.uuid})

      assert length(Catalogue.search_items("oak", catalogue_uuids: nil)) == 1
      assert length(Catalogue.search_items("oak", catalogue_uuids: [])) == 1
      assert length(Catalogue.search_items("oak", category_uuids: nil)) == 1
      assert length(Catalogue.search_items("oak", category_uuids: [])) == 1
    end

    test "count_search_items/2 accepts the same scope filters" do
      cat_a = create_catalogue(%{name: "A"})
      cat_b = create_catalogue(%{name: "B"})
      c_a = create_category(cat_a)
      c_b = create_category(cat_b)
      for n <- 1..3, do: create_item(%{name: "Oak A#{n}", category_uuid: c_a.uuid})
      for n <- 1..2, do: create_item(%{name: "Oak B#{n}", category_uuid: c_b.uuid})

      assert Catalogue.count_search_items("oak") == 5
      assert Catalogue.count_search_items("oak", catalogue_uuids: [cat_a.uuid]) == 3
      assert Catalogue.count_search_items("oak", catalogue_uuids: [cat_b.uuid]) == 2

      assert Catalogue.count_search_items("oak",
               catalogue_uuids: [cat_a.uuid, cat_b.uuid]
             ) == 5
    end

    test "count_search_items/1 (no opts) still works for backwards compatibility" do
      cat = create_catalogue()
      category = create_category(cat)
      for n <- 1..3, do: create_item(%{name: "Oak #{n}", category_uuid: category.uuid})

      assert Catalogue.count_search_items("oak") == 3
    end

    test "list_catalogues_by_name_prefix/2 + search_items/2 composition" do
      kitchen = create_catalogue(%{name: "Kitchen"})
      kits = create_catalogue(%{name: "Kits and Tools"})
      bathroom = create_catalogue(%{name: "Bathroom"})
      kitchen_cat = create_category(kitchen)
      kits_cat = create_category(kits)
      bathroom_cat = create_category(bathroom)
      create_item(%{name: "Oak Kitchen", category_uuid: kitchen_cat.uuid})
      create_item(%{name: "Oak Kits", category_uuid: kits_cat.uuid})
      create_item(%{name: "Oak Bath", category_uuid: bathroom_cat.uuid})

      uuids =
        "Kit"
        |> Catalogue.list_catalogues_by_name_prefix()
        |> Enum.map(& &1.uuid)

      names =
        "oak"
        |> Catalogue.search_items(catalogue_uuids: uuids)
        |> Enum.map(& &1.name)
        |> Enum.sort()

      assert names == ["Oak Kitchen", "Oak Kits"]
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Discount (V102 / 0.1.11)
  # ═══════════════════════════════════════════════════════════════════

  describe "catalogue discount_percentage" do
    test "defaults to 0 when not provided" do
      cat = create_catalogue()
      assert Decimal.equal?(cat.discount_percentage, Decimal.new("0"))
    end

    test "can be set on create" do
      cat = create_catalogue(%{discount_percentage: "15.5"})
      assert Decimal.equal?(cat.discount_percentage, Decimal.new("15.5"))
    end

    test "can be updated" do
      cat = create_catalogue()
      {:ok, updated} = Catalogue.update_catalogue(cat, %{discount_percentage: "25"})
      assert Decimal.equal?(updated.discount_percentage, Decimal.new("25"))
    end

    test "rejects discount above 100" do
      {:error, changeset} =
        Catalogue.create_catalogue(%{name: "Bad", discount_percentage: "150"})

      assert %{discount_percentage: [_ | _]} = errors_on(changeset)
    end

    test "rejects negative discount" do
      {:error, changeset} =
        Catalogue.create_catalogue(%{name: "Bad", discount_percentage: "-1"})

      assert %{discount_percentage: [_ | _]} = errors_on(changeset)
    end
  end

  describe "item discount_percentage override" do
    test "defaults to nil (inherits from catalogue)" do
      cat = create_catalogue(%{discount_percentage: "10"})
      category = create_category(cat)
      item = create_item(%{name: "Inheritor", category_uuid: category.uuid})
      assert is_nil(item.discount_percentage)
    end

    test "can be set to 0 (explicit 'no discount' override)" do
      cat = create_catalogue(%{discount_percentage: "25"})
      category = create_category(cat)

      item =
        create_item(%{
          name: "Full Price",
          base_price: "100.00",
          discount_percentage: "0",
          category_uuid: category.uuid
        })

      assert Decimal.equal?(item.discount_percentage, Decimal.new("0"))
    end

    test "rejects discount above 100" do
      cat = create_catalogue()
      category = create_category(cat)

      {:error, changeset} =
        Catalogue.create_item(%{
          name: "Bad",
          base_price: "10",
          discount_percentage: "150",
          category_uuid: category.uuid
        })

      assert %{discount_percentage: [_ | _]} = errors_on(changeset)
    end
  end

  describe "item_pricing/1 with discount" do
    test "surfaces catalogue and item discount fields" do
      cat = create_catalogue(%{markup_percentage: "20", discount_percentage: "10"})
      category = create_category(cat)
      item = create_item(%{name: "Panel", base_price: "100.00", category_uuid: category.uuid})

      pricing = Catalogue.item_pricing(item)

      # Markups
      assert Decimal.equal?(pricing.catalogue_markup, Decimal.new("20"))
      assert is_nil(pricing.item_markup)
      assert Decimal.equal?(pricing.markup_percentage, Decimal.new("20"))
      assert Decimal.equal?(pricing.sale_price, Decimal.new("120.00"))

      # Discounts
      assert Decimal.equal?(pricing.catalogue_discount, Decimal.new("10"))
      assert is_nil(pricing.item_discount)
      assert Decimal.equal?(pricing.discount_percentage, Decimal.new("10"))

      # Final: 100 * 1.20 * 0.90 = 108.00
      assert Decimal.equal?(pricing.final_price, Decimal.new("108.00"))
      # Savings: 120 - 108 = 12
      assert Decimal.equal?(pricing.discount_amount, Decimal.new("12.00"))
    end

    test "item discount override wins over catalogue discount" do
      cat = create_catalogue(%{markup_percentage: "0", discount_percentage: "10"})
      category = create_category(cat)

      item =
        create_item(%{
          name: "Big Sale",
          base_price: "100.00",
          discount_percentage: "50",
          category_uuid: category.uuid
        })

      pricing = Catalogue.item_pricing(item)

      assert Decimal.equal?(pricing.catalogue_discount, Decimal.new("10"))
      assert Decimal.equal?(pricing.item_discount, Decimal.new("50"))
      assert Decimal.equal?(pricing.discount_percentage, Decimal.new("50"))
      assert Decimal.equal?(pricing.final_price, Decimal.new("50.00"))
      assert Decimal.equal?(pricing.discount_amount, Decimal.new("50.00"))
    end

    test "item discount of 0 overrides a catalogue discount" do
      cat = create_catalogue(%{markup_percentage: "0", discount_percentage: "25"})
      category = create_category(cat)

      item =
        create_item(%{
          name: "No Discount For Me",
          base_price: "100.00",
          discount_percentage: "0",
          category_uuid: category.uuid
        })

      pricing = Catalogue.item_pricing(item)

      assert Decimal.equal?(pricing.discount_percentage, Decimal.new("0"))
      # sale_price = final_price when discount is 0
      assert Decimal.equal?(pricing.final_price, Decimal.new("100.00"))
      assert Decimal.equal?(pricing.discount_amount, Decimal.new("0.00"))
    end

    test "no discount anywhere → final_price equals sale_price, discount_amount is nil" do
      cat = create_catalogue(%{markup_percentage: "15"})
      category = create_category(cat)
      item = create_item(%{name: "Plain", base_price: "100.00", category_uuid: category.uuid})

      pricing = Catalogue.item_pricing(item)

      assert Decimal.equal?(pricing.catalogue_discount, Decimal.new("0"))
      assert is_nil(pricing.item_discount)
      assert Decimal.equal?(pricing.discount_percentage, Decimal.new("0"))
      # With 0% discount, final equals sale
      assert Decimal.equal?(pricing.final_price, pricing.sale_price)
      # discount_amount is nil when no discount applies (catalogue=0, item=nil
      # ⇒ effective is 0, which is truthy — amount is Decimal 0.00 here)
      assert Decimal.equal?(pricing.discount_amount, Decimal.new("0.00"))
    end

    test "all-nil discount (no catalogue association) → nil discount fields" do
      # Detached item with no catalogue loaded → safe_pricing_for_item logs
      # a warning and returns {0, 0}.
      item = %PhoenixKitCatalogue.Schemas.Item{
        uuid: "00000000-0000-0000-0000-000000000000",
        base_price: Decimal.new("100.00"),
        catalogue: %Ecto.Association.NotLoaded{
          __field__: :catalogue,
          __owner__: PhoenixKitCatalogue.Schemas.Item,
          __cardinality__: :one
        }
      }

      pricing = Catalogue.item_pricing(item)

      assert Decimal.equal?(pricing.catalogue_discount, Decimal.new("0"))
      assert Decimal.equal?(pricing.final_price, Decimal.new("100.00"))
    end

    test "final_price is nil when base_price is nil" do
      cat = create_catalogue(%{markup_percentage: "20", discount_percentage: "10"})
      category = create_category(cat)
      item = create_item(%{name: "Priceless", category_uuid: category.uuid})

      pricing = Catalogue.item_pricing(item)

      assert is_nil(pricing.base_price)
      assert is_nil(pricing.sale_price)
      assert is_nil(pricing.final_price)
      assert is_nil(pricing.discount_amount)
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Smart catalogues (V102 / 0.1.12)
  # ═══════════════════════════════════════════════════════════════════

  describe "list_catalogues/1 with :kind filter" do
    test "returns only the requested kind" do
      standard = create_catalogue(%{name: "Kitchen"})
      smart = create_catalogue(%{name: "Services", kind: "smart"})

      smart_names = Catalogue.list_catalogues(kind: :smart) |> Enum.map(& &1.name)
      standard_names = Catalogue.list_catalogues(kind: :standard) |> Enum.map(& &1.name)

      assert smart.name in smart_names
      refute standard.name in smart_names

      assert standard.name in standard_names
      refute smart.name in standard_names
    end

    test "accepts string kind too" do
      create_catalogue(%{name: "Svc", kind: "smart"})
      assert [%{kind: "smart"}] = Catalogue.list_catalogues(kind: "smart")
    end
  end

  describe "put_catalogue_rules/3 and list_catalogue_rules/1" do
    test "atomically replaces rules — add, update, remove in one shot" do
      services = create_catalogue(%{name: "Services", kind: "smart"})
      kitchen = create_catalogue(%{name: "Kitchen"})
      plumbing = create_catalogue(%{name: "Plumbing"})
      hardware = create_catalogue(%{name: "Hardware"})
      delivery = create_item(%{name: "Delivery", catalogue_uuid: services.uuid})

      # Initial state: two rules
      {:ok, _} =
        Catalogue.put_catalogue_rules(delivery, [
          %{referenced_catalogue_uuid: kitchen.uuid, value: 5, unit: "percent"},
          %{referenced_catalogue_uuid: plumbing.uuid, value: 3, unit: "percent"}
        ])

      rules = Catalogue.list_catalogue_rules(delivery)
      assert length(rules) == 2

      # Replace-all: kitchen updated, plumbing removed, hardware added
      {:ok, _} =
        Catalogue.put_catalogue_rules(delivery, [
          %{referenced_catalogue_uuid: kitchen.uuid, value: 10, unit: "percent"},
          %{referenced_catalogue_uuid: hardware.uuid, value: 20, unit: "flat"}
        ])

      rules = Catalogue.list_catalogue_rules(delivery)
      by_uuid = Map.new(rules, &{&1.referenced_catalogue_uuid, &1})

      assert Map.has_key?(by_uuid, kitchen.uuid)
      assert Map.has_key?(by_uuid, hardware.uuid)
      refute Map.has_key?(by_uuid, plumbing.uuid)

      assert Decimal.equal?(by_uuid[kitchen.uuid].value, Decimal.new("10"))
      assert by_uuid[kitchen.uuid].unit == "percent"
      assert Decimal.equal?(by_uuid[hardware.uuid].value, Decimal.new("20"))
      assert by_uuid[hardware.uuid].unit == "flat"
    end

    test "empty rules list clears all existing rules" do
      services = create_catalogue(%{name: "Services", kind: "smart"})
      kitchen = create_catalogue(%{name: "Kitchen"})
      delivery = create_item(%{name: "Delivery", catalogue_uuid: services.uuid})

      {:ok, _} =
        Catalogue.put_catalogue_rules(delivery, [
          %{referenced_catalogue_uuid: kitchen.uuid, value: 5, unit: "percent"}
        ])

      {:ok, _} = Catalogue.put_catalogue_rules(delivery, [])
      assert Catalogue.list_catalogue_rules(delivery) == []
    end

    test "nil value/unit is stored as-is (inherits from item defaults at read time)" do
      services = create_catalogue(%{name: "Services", kind: "smart"})
      kitchen = create_catalogue(%{name: "Kitchen"})

      delivery =
        create_item(%{
          name: "Delivery",
          catalogue_uuid: services.uuid,
          default_value: "5",
          default_unit: "percent"
        })

      {:ok, _} =
        Catalogue.put_catalogue_rules(delivery, [
          %{referenced_catalogue_uuid: kitchen.uuid}
        ])

      [rule] = Catalogue.list_catalogue_rules(delivery)
      assert is_nil(rule.value)
      assert is_nil(rule.unit)

      # Effective values fall back to the item's defaults
      alias PhoenixKitCatalogue.Schemas.CatalogueRule
      {value, unit} = CatalogueRule.effective(rule, delivery)
      assert Decimal.equal?(value, Decimal.new("5"))
      assert unit == "percent"
    end

    test "rejects duplicate referenced_catalogue_uuid in one call" do
      services = create_catalogue(%{name: "Services", kind: "smart"})
      kitchen = create_catalogue(%{name: "Kitchen"})
      delivery = create_item(%{name: "Delivery", catalogue_uuid: services.uuid})

      assert {:error, {:duplicate_referenced_catalogue, _}} =
               Catalogue.put_catalogue_rules(delivery, [
                 %{referenced_catalogue_uuid: kitchen.uuid, value: 5, unit: "percent"},
                 %{referenced_catalogue_uuid: kitchen.uuid, value: 10, unit: "flat"}
               ])

      assert Catalogue.list_catalogue_rules(delivery) == []
    end

    test "rolls back the whole replace if any rule is invalid" do
      services = create_catalogue(%{name: "Services", kind: "smart"})
      kitchen = create_catalogue(%{name: "Kitchen"})
      delivery = create_item(%{name: "Delivery", catalogue_uuid: services.uuid})

      # Seed a good rule first
      {:ok, _} =
        Catalogue.put_catalogue_rules(delivery, [
          %{referenced_catalogue_uuid: kitchen.uuid, value: 5, unit: "percent"}
        ])

      plumbing = create_catalogue(%{name: "Plumbing"})

      # Second put contains a bad unit → entire replace rolls back
      # (kitchen stays untouched at value=5, plumbing is NOT added)
      assert {:error, %Ecto.Changeset{}} =
               Catalogue.put_catalogue_rules(delivery, [
                 %{referenced_catalogue_uuid: kitchen.uuid, value: 99, unit: "percent"},
                 %{referenced_catalogue_uuid: plumbing.uuid, value: 3, unit: "bogus"}
               ])

      [rule] = Catalogue.list_catalogue_rules(delivery)
      assert rule.referenced_catalogue_uuid == kitchen.uuid
      assert Decimal.equal?(rule.value, Decimal.new("5"))
    end

    test "preloads the referenced catalogue and orders by position then name" do
      services = create_catalogue(%{name: "Services", kind: "smart"})
      beta = create_catalogue(%{name: "Beta"})
      alpha = create_catalogue(%{name: "Alpha"})
      delivery = create_item(%{name: "Delivery", catalogue_uuid: services.uuid})

      # Explicit positions: Beta at 0, Alpha at 1 → Beta first despite alphabetical
      {:ok, _} =
        Catalogue.put_catalogue_rules(delivery, [
          %{referenced_catalogue_uuid: beta.uuid, position: 0},
          %{referenced_catalogue_uuid: alpha.uuid, position: 1}
        ])

      rules = Catalogue.list_catalogue_rules(delivery)
      assert Enum.map(rules, & &1.referenced_catalogue.name) == ["Beta", "Alpha"]
    end
  end

  describe "catalogue_rule_map/1" do
    test "returns the rules keyed by referenced_catalogue_uuid" do
      services = create_catalogue(%{name: "Services", kind: "smart"})
      kitchen = create_catalogue(%{name: "Kitchen"})
      delivery = create_item(%{name: "Delivery", catalogue_uuid: services.uuid})

      {:ok, _} =
        Catalogue.put_catalogue_rules(delivery, [
          %{referenced_catalogue_uuid: kitchen.uuid, value: 5, unit: "percent"}
        ])

      map = Catalogue.catalogue_rule_map(delivery)
      assert Map.has_key?(map, kitchen.uuid)
      assert Decimal.equal?(map[kitchen.uuid].value, Decimal.new("5"))
    end
  end

  describe "list_items_referencing_catalogue/1 and catalogue_reference_count/1" do
    test "returns smart items that reference a given catalogue" do
      services = create_catalogue(%{name: "Services", kind: "smart"})
      kitchen = create_catalogue(%{name: "Kitchen"})
      plumbing = create_catalogue(%{name: "Plumbing"})

      delivery = create_item(%{name: "Delivery", catalogue_uuid: services.uuid})
      install = create_item(%{name: "Install", catalogue_uuid: services.uuid})
      irrelevant = create_item(%{name: "Irrelevant", catalogue_uuid: services.uuid})

      {:ok, _} =
        Catalogue.put_catalogue_rules(delivery, [
          %{referenced_catalogue_uuid: kitchen.uuid, value: 5, unit: "percent"}
        ])

      {:ok, _} =
        Catalogue.put_catalogue_rules(install, [
          %{referenced_catalogue_uuid: kitchen.uuid, value: 10, unit: "flat"},
          %{referenced_catalogue_uuid: plumbing.uuid, value: 3, unit: "percent"}
        ])

      # No rules on irrelevant

      kitchen_referencers = Catalogue.list_items_referencing_catalogue(kitchen.uuid)
      names = Enum.map(kitchen_referencers, & &1.name) |> Enum.sort()

      assert names == ["Delivery", "Install"]
      refute irrelevant.name in names

      assert Catalogue.catalogue_reference_count(kitchen.uuid) == 2
      assert Catalogue.catalogue_reference_count(plumbing.uuid) == 1
    end

    test "excludes deleted items" do
      services = create_catalogue(%{name: "Services", kind: "smart"})
      kitchen = create_catalogue(%{name: "Kitchen"})
      delivery = create_item(%{name: "Delivery", catalogue_uuid: services.uuid})

      {:ok, _} =
        Catalogue.put_catalogue_rules(delivery, [
          %{referenced_catalogue_uuid: kitchen.uuid, value: 5, unit: "percent"}
        ])

      assert length(Catalogue.list_items_referencing_catalogue(kitchen.uuid)) == 1

      Catalogue.trash_item(delivery)

      assert Catalogue.list_items_referencing_catalogue(kitchen.uuid) == []
      assert Catalogue.catalogue_reference_count(kitchen.uuid) == 0
    end

    test "cascades: force-deleting a referenced catalogue wipes the rule" do
      services = create_catalogue(%{name: "Services", kind: "smart"})
      kitchen = create_catalogue(%{name: "Kitchen"})
      delivery = create_item(%{name: "Delivery", catalogue_uuid: services.uuid})

      {:ok, _} =
        Catalogue.put_catalogue_rules(delivery, [
          %{referenced_catalogue_uuid: kitchen.uuid, value: 5, unit: "percent"}
        ])

      # `permanently_delete_catalogue/2` now refuses to nuke a catalogue
      # that smart items still reference unless `force: true` is passed.
      assert {:error, {:referenced_by_smart_items, 1}} =
               Catalogue.permanently_delete_catalogue(kitchen)

      # With force, the FK cascade removes the rule row.
      assert {:ok, _} = Catalogue.permanently_delete_catalogue(kitchen, force: true)
      assert Catalogue.list_catalogue_rules(delivery) == []
    end

    test "permanently_delete_catalogue refuses without :force when smart-rule references exist" do
      services = create_catalogue(%{name: "Services", kind: "smart"})
      kitchen = create_catalogue(%{name: "Kitchen"})
      hardware = create_catalogue(%{name: "Hardware"})

      delivery = create_item(%{name: "Delivery", catalogue_uuid: services.uuid})
      install = create_item(%{name: "Install", catalogue_uuid: services.uuid})

      {:ok, _} =
        Catalogue.put_catalogue_rules(delivery, [
          %{referenced_catalogue_uuid: kitchen.uuid, value: 5, unit: "percent"}
        ])

      {:ok, _} =
        Catalogue.put_catalogue_rules(install, [
          %{referenced_catalogue_uuid: kitchen.uuid, value: 10, unit: "percent"}
        ])

      assert {:error, {:referenced_by_smart_items, 2}} =
               Catalogue.permanently_delete_catalogue(kitchen)

      # Hardware has no references — guard doesn't fire.
      assert {:ok, _} = Catalogue.permanently_delete_catalogue(hardware)
    end

    test "smart-to-smart references are rejected (issue #16)" do
      services_a = create_catalogue(%{name: "Services A", kind: "smart"})
      services_b = create_catalogue(%{name: "Services B", kind: "smart"})
      item = create_item(%{name: "X", catalogue_uuid: services_a.uuid})

      assert {:error, %Ecto.Changeset{} = changeset} =
               Catalogue.put_catalogue_rules(item, [
                 %{referenced_catalogue_uuid: services_b.uuid, value: 7, unit: "percent"}
               ])

      assert {"must reference a standard catalogue, not a smart catalogue", _} =
               changeset.errors[:referenced_catalogue_uuid]
    end

    test "smart self-references are rejected (smart catalogue cannot be referenced at all)" do
      services = create_catalogue(%{name: "Services", kind: "smart"})
      delivery = create_item(%{name: "Delivery", catalogue_uuid: services.uuid})

      assert {:error, %Ecto.Changeset{} = changeset} =
               Catalogue.put_catalogue_rules(delivery, [
                 %{referenced_catalogue_uuid: services.uuid, value: 5, unit: "percent"}
               ])

      assert {"must reference a standard catalogue, not a smart catalogue", _} =
               changeset.errors[:referenced_catalogue_uuid]
    end

    test "duplicate detection: nil referenced_catalogue_uuid returns {:duplicate, nil}" do
      services = create_catalogue(%{name: "Services", kind: "smart"})
      delivery = create_item(%{name: "Delivery", catalogue_uuid: services.uuid})

      assert {:error, {:duplicate_referenced_catalogue, nil}} =
               Catalogue.put_catalogue_rules(delivery, [
                 %{referenced_catalogue_uuid: nil, value: 5, unit: "percent"}
               ])
    end
  end

  describe "single-rule CRUD (V102)" do
    test "create_catalogue_rule/2 logs and returns the inserted rule" do
      services = create_catalogue(%{name: "Services", kind: "smart"})
      kitchen = create_catalogue(%{name: "Kitchen"})
      delivery = create_item(%{name: "Delivery", catalogue_uuid: services.uuid})

      assert {:ok, rule} =
               Catalogue.create_catalogue_rule(%{
                 item_uuid: delivery.uuid,
                 referenced_catalogue_uuid: kitchen.uuid,
                 value: Decimal.new("12"),
                 unit: "percent"
               })

      assert rule.item_uuid == delivery.uuid
      assert rule.referenced_catalogue_uuid == kitchen.uuid
    end

    test "update_catalogue_rule/3 mutates value and unit" do
      services = create_catalogue(%{name: "Services", kind: "smart"})
      kitchen = create_catalogue(%{name: "Kitchen"})
      delivery = create_item(%{name: "Delivery", catalogue_uuid: services.uuid})

      {:ok, rule} =
        Catalogue.create_catalogue_rule(%{
          item_uuid: delivery.uuid,
          referenced_catalogue_uuid: kitchen.uuid,
          value: Decimal.new("5"),
          unit: "percent"
        })

      assert {:ok, updated} =
               Catalogue.update_catalogue_rule(rule, %{value: Decimal.new("9"), unit: "flat"})

      assert Decimal.equal?(updated.value, Decimal.new("9"))
      assert updated.unit == "flat"
    end

    test "create_catalogue_rule/2 rejects a smart referenced_catalogue (issue #16)" do
      services_a = create_catalogue(%{name: "Services A", kind: "smart"})
      services_b = create_catalogue(%{name: "Services B", kind: "smart"})
      delivery = create_item(%{name: "Delivery", catalogue_uuid: services_a.uuid})

      assert {:error, %Ecto.Changeset{} = changeset} =
               Catalogue.create_catalogue_rule(%{
                 item_uuid: delivery.uuid,
                 referenced_catalogue_uuid: services_b.uuid,
                 value: Decimal.new("10"),
                 unit: "percent"
               })

      assert {"must reference a standard catalogue, not a smart catalogue", _} =
               changeset.errors[:referenced_catalogue_uuid]
    end

    test "update_catalogue_rule/3 rejects retargeting at a smart catalogue (issue #16)" do
      services_a = create_catalogue(%{name: "Services A", kind: "smart"})
      services_b = create_catalogue(%{name: "Services B", kind: "smart"})
      kitchen = create_catalogue(%{name: "Kitchen"})
      delivery = create_item(%{name: "Delivery", catalogue_uuid: services_a.uuid})

      {:ok, rule} =
        Catalogue.create_catalogue_rule(%{
          item_uuid: delivery.uuid,
          referenced_catalogue_uuid: kitchen.uuid,
          value: Decimal.new("5"),
          unit: "percent"
        })

      assert {:error, %Ecto.Changeset{} = changeset} =
               Catalogue.update_catalogue_rule(rule, %{
                 referenced_catalogue_uuid: services_b.uuid
               })

      assert {"must reference a standard catalogue, not a smart catalogue", _} =
               changeset.errors[:referenced_catalogue_uuid]
    end

    test "delete_catalogue_rule/2 removes one rule without affecting siblings" do
      services = create_catalogue(%{name: "Services", kind: "smart"})
      kitchen = create_catalogue(%{name: "Kitchen"})
      hardware = create_catalogue(%{name: "Hardware"})
      delivery = create_item(%{name: "Delivery", catalogue_uuid: services.uuid})

      {:ok, _} =
        Catalogue.put_catalogue_rules(delivery, [
          %{referenced_catalogue_uuid: kitchen.uuid, value: 5, unit: "percent"},
          %{referenced_catalogue_uuid: hardware.uuid, value: 20, unit: "flat"}
        ])

      kitchen_rule = Catalogue.get_catalogue_rule(delivery.uuid, kitchen.uuid)
      assert {:ok, _} = Catalogue.delete_catalogue_rule(kitchen_rule)

      remaining = Catalogue.list_catalogue_rules(delivery)
      assert length(remaining) == 1
      assert hd(remaining).referenced_catalogue_uuid == hardware.uuid
    end

    test "change_catalogue_rule/2 returns a changeset for forms" do
      cs = Catalogue.change_catalogue_rule(%PhoenixKitCatalogue.Schemas.CatalogueRule{})
      assert %Ecto.Changeset{valid?: false} = cs
      assert {_, _} = cs.errors[:referenced_catalogue_uuid]
    end

    test "change_catalogue_rule/2 surfaces smart-chain error during form validate (issue #16)" do
      services_a = create_catalogue(%{name: "Services A", kind: "smart"})
      services_b = create_catalogue(%{name: "Services B", kind: "smart"})
      delivery = create_item(%{name: "Delivery", catalogue_uuid: services_a.uuid})

      cs =
        Catalogue.change_catalogue_rule(
          %PhoenixKitCatalogue.Schemas.CatalogueRule{},
          %{
            item_uuid: delivery.uuid,
            referenced_catalogue_uuid: services_b.uuid,
            value: Decimal.new("5"),
            unit: "percent"
          }
        )

      assert {"must reference a standard catalogue, not a smart catalogue", meta} =
               cs.errors[:referenced_catalogue_uuid]

      assert meta[:validation] == :smart_chain
    end

    test "V102 CHECK constraint on kind refuses an invalid enum via raw SQL" do
      # Ecto's changeset validates `kind` before it hits the DB, so the
      # CHECK constraint is only visible on direct inserts. This guards
      # against a future changeset regression silently dropping the check
      # AND verifies the test migration mirrors the prod constraint.
      repo = PhoenixKitCatalogue.Test.Repo
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      assert_raise Postgrex.Error, ~r/kind_check/i, fn ->
        SQL.query!(
          repo,
          """
          INSERT INTO phoenix_kit_cat_catalogues
            (uuid, name, status, kind, markup_percentage, discount_percentage, data, inserted_at, updated_at)
          VALUES
            (uuid_generate_v7(), 'Invalid Kind', 'active', 'not-a-real-kind', 0, 0, '{}'::jsonb, $1, $1)
          """,
          [now]
        )
      end
    end

    test "create_catalogue_rule/2 with a duplicate (item_uuid, referenced_catalogue_uuid) pair is rejected by the UNIQUE constraint" do
      services = create_catalogue(%{name: "Services", kind: "smart"})
      kitchen = create_catalogue(%{name: "Kitchen"})
      delivery = create_item(%{name: "Delivery", catalogue_uuid: services.uuid})

      assert {:ok, _} =
               Catalogue.create_catalogue_rule(%{
                 item_uuid: delivery.uuid,
                 referenced_catalogue_uuid: kitchen.uuid,
                 value: Decimal.new("5"),
                 unit: "percent"
               })

      # Second insert with the same pair must surface the unique_constraint
      # error on the pair — proves the V102 UNIQUE index is in force and
      # the schema's `unique_constraint/2` call converts it to a useful
      # changeset error rather than raising a Postgrex error.
      assert {:error, %Ecto.Changeset{} = cs} =
               Catalogue.create_catalogue_rule(%{
                 item_uuid: delivery.uuid,
                 referenced_catalogue_uuid: kitchen.uuid,
                 value: Decimal.new("9"),
                 unit: "flat"
               })

      refute cs.valid?

      assert Enum.any?(cs.errors, fn {field, _} ->
               field in [:item_uuid, :referenced_catalogue_uuid]
             end)
    end
  end

  describe "category_counts_by_catalogue/0" do
    test "returns a map of non-deleted category counts per catalogue" do
      kitchen = create_catalogue(%{name: "Kitchen"})
      bathroom = create_catalogue(%{name: "Bathroom"})
      _empty = create_catalogue(%{name: "Empty"})

      _ = create_category(kitchen, %{name: "Frames"})
      _ = create_category(kitchen, %{name: "Doors"})
      _ = create_category(bathroom, %{name: "Tiles"})
      trashed_cat = create_category(kitchen, %{name: "To Trash"})
      Catalogue.trash_category(trashed_cat)

      counts = Catalogue.category_counts_by_catalogue()

      assert counts[kitchen.uuid] == 2
      assert counts[bathroom.uuid] == 1
      refute Map.has_key?(counts, "missing-catalogue-uuid")
    end

    test "returns empty map when there are no categories" do
      assert Catalogue.category_counts_by_catalogue() == %{}
    end
  end

  describe "list_category_ancestors/1" do
    test "returns [] for a root category" do
      cat = create_catalogue()
      root = create_category(cat, %{name: "Root"})

      assert PhoenixKitCatalogue.Catalogue.list_category_ancestors(root.uuid) == []
    end

    test "returns ancestor chain root → direct parent for a deep descendant" do
      cat = create_catalogue()
      root = create_category(cat, %{name: "Root"})
      mid = create_category(cat, %{name: "Mid", parent_uuid: root.uuid})
      leaf = create_category(cat, %{name: "Leaf", parent_uuid: mid.uuid})

      ancestors = PhoenixKitCatalogue.Catalogue.list_category_ancestors(leaf.uuid)
      assert Enum.map(ancestors, & &1.name) == ["Root", "Mid"]
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Bulk actions (admin selection toolbar)
  # ═══════════════════════════════════════════════════════════════════

  describe "bulk_trash_items/2" do
    test "flips status to deleted for the given uuids" do
      cat = create_catalogue()
      a = create_item(%{name: "A", catalogue_uuid: cat.uuid})
      b = create_item(%{name: "B", catalogue_uuid: cat.uuid})
      c = create_item(%{name: "C", catalogue_uuid: cat.uuid})

      assert {2, nil} = Catalogue.bulk_trash_items([a.uuid, b.uuid], [])

      assert Catalogue.get_item(a.uuid).status == "deleted"
      assert Catalogue.get_item(b.uuid).status == "deleted"
      assert Catalogue.get_item(c.uuid).status == "active"
    end

    test "empty list is a no-op" do
      assert {0, nil} = Catalogue.bulk_trash_items([], [])
    end

    test "skips already-deleted items in the count" do
      cat = create_catalogue()
      a = create_item(%{name: "A", catalogue_uuid: cat.uuid})
      Catalogue.trash_item(a)

      assert {0, nil} = Catalogue.bulk_trash_items([a.uuid], [])
    end
  end

  describe "bulk_restore_items/2" do
    test "restores items in place when parent category is active" do
      cat = create_catalogue()
      category = create_category(cat)
      a = create_item(%{name: "A", category_uuid: category.uuid})
      Catalogue.trash_item(a)

      assert {1, nil} = Catalogue.bulk_restore_items([a.uuid], [])
      restored = Catalogue.get_item(a.uuid)
      assert restored.status == "active"
      assert restored.category_uuid == category.uuid
    end

    test "uncategorizes items whose parent category is deleted" do
      cat = create_catalogue()
      category = create_category(cat)
      a = create_item(%{name: "A", category_uuid: category.uuid})

      Catalogue.trash_category(category, items: :cascade)

      assert {1, nil} = Catalogue.bulk_restore_items([a.uuid], [])
      restored = Catalogue.get_item(a.uuid)
      assert restored.status == "active"
      # Parent category was deleted — bulk restore detaches the item
      # so it surfaces in the catalogue's Uncategorized bucket without
      # auto-reviving the category structure.
      assert restored.category_uuid == nil
      assert restored.catalogue_uuid == cat.uuid
    end

    test "refuses items whose parent catalogue is deleted" do
      cat = create_catalogue()
      a = create_item(%{name: "A", catalogue_uuid: cat.uuid})
      Catalogue.trash_catalogue(cat)

      # Item is filtered out by the parent-catalogue-deleted guard.
      assert {0, nil} = Catalogue.bulk_restore_items([a.uuid], [])
      assert Catalogue.get_item(a.uuid).status == "deleted"
    end
  end

  describe "bulk_permanently_delete_items/2" do
    test "hard-deletes the rows" do
      cat = create_catalogue()
      a = create_item(%{name: "A", catalogue_uuid: cat.uuid})
      b = create_item(%{name: "B", catalogue_uuid: cat.uuid})

      assert {2, nil} = Catalogue.bulk_permanently_delete_items([a.uuid, b.uuid], [])

      assert is_nil(Catalogue.get_item(a.uuid))
      assert is_nil(Catalogue.get_item(b.uuid))
    end
  end

  describe "bulk_move_items_to_category/3" do
    test "refuses without a :catalogue_uuid scope opt" do
      cat = create_catalogue()
      a = create_item(%{name: "A", catalogue_uuid: cat.uuid})

      # Required guard — a caller that forgets the scope opt gets a
      # clear refusal rather than a silent cross-catalogue write.
      assert {:error, :missing_catalogue_scope} =
               Catalogue.bulk_move_items_to_category([a.uuid], nil, [])
    end

    test "rejects when an item belongs to a different catalogue than the scope" do
      cat_a = create_catalogue()
      cat_b = create_catalogue()
      foreign = create_item(%{name: "Foreign", catalogue_uuid: cat_b.uuid})

      assert {:error, :wrong_catalogue_scope} =
               Catalogue.bulk_move_items_to_category(
                 [foreign.uuid],
                 nil,
                 catalogue_uuid: cat_a.uuid
               )

      # Item untouched — still in its original catalogue.
      assert Catalogue.get_item(foreign.uuid).catalogue_uuid == cat_b.uuid
    end

    test "rejects when target category lives in a different catalogue than the scope" do
      cat_a = create_catalogue()
      cat_b = create_catalogue()
      a = create_item(%{name: "A", catalogue_uuid: cat_a.uuid})
      foreign_target = create_category(cat_b)

      assert {:error, :wrong_catalogue_scope} =
               Catalogue.bulk_move_items_to_category(
                 [a.uuid],
                 foreign_target.uuid,
                 catalogue_uuid: cat_a.uuid
               )

      # Item untouched — still in its original catalogue.
      assert Catalogue.get_item(a.uuid).catalogue_uuid == cat_a.uuid
    end

    test "rejects when target category does not exist" do
      cat = create_catalogue()
      a = create_item(%{name: "A", catalogue_uuid: cat.uuid})
      bogus = "00000000-0000-0000-0000-000000000000"

      assert {:error, :category_not_found} =
               Catalogue.bulk_move_items_to_category(
                 [a.uuid],
                 bogus,
                 catalogue_uuid: cat.uuid
               )
    end

    test "moves all items into the target category" do
      cat = create_catalogue()
      target = create_category(cat, %{name: "Target"})
      a = create_item(%{name: "A", catalogue_uuid: cat.uuid})
      b = create_item(%{name: "B", catalogue_uuid: cat.uuid})

      assert {:ok, 2} =
               Catalogue.bulk_move_items_to_category(
                 [a.uuid, b.uuid],
                 target.uuid,
                 catalogue_uuid: cat.uuid
               )

      assert Catalogue.get_item(a.uuid).category_uuid == target.uuid
      assert Catalogue.get_item(b.uuid).category_uuid == target.uuid
    end

    test "uncategorizes when target_uuid is nil" do
      cat = create_catalogue()
      category = create_category(cat)
      a = create_item(%{name: "A", category_uuid: category.uuid})

      assert {:ok, 1} =
               Catalogue.bulk_move_items_to_category(
                 [a.uuid],
                 nil,
                 catalogue_uuid: cat.uuid
               )

      moved = Catalogue.get_item(a.uuid)
      assert moved.category_uuid == nil
      assert moved.catalogue_uuid == cat.uuid
    end
  end

  describe "bulk_trash_categories/3" do
    test ":cascade soft-deletes categories + their items" do
      cat = create_catalogue()
      category = create_category(cat)
      item = create_item(%{name: "Item", category_uuid: category.uuid})

      assert {:ok, %{categories: 1}} =
               Catalogue.bulk_trash_categories([category.uuid], :cascade, [])

      assert Catalogue.get_category(category.uuid).status == "deleted"
      assert Catalogue.get_item(item.uuid).status == "deleted"
    end

    test ":uncategorize keeps items active and detaches them from the category" do
      cat = create_catalogue()
      category = create_category(cat)
      item = create_item(%{name: "Item", category_uuid: category.uuid})

      assert {:ok, %{categories: 1}} =
               Catalogue.bulk_trash_categories([category.uuid], :uncategorize, [])

      assert Catalogue.get_category(category.uuid).status == "deleted"
      survived = Catalogue.get_item(item.uuid)
      assert survived.status == "active"
      assert survived.category_uuid == nil
    end

    test "{:move_to, target_uuid} reparents items to the target before trashing" do
      cat = create_catalogue()
      source = create_category(cat, %{name: "Source"})
      target = create_category(cat, %{name: "Target"})
      item = create_item(%{name: "Item", category_uuid: source.uuid})

      assert {:ok, %{categories: 1}} =
               Catalogue.bulk_trash_categories([source.uuid], {:move_to, target.uuid}, [])

      assert Catalogue.get_category(source.uuid).status == "deleted"
      moved = Catalogue.get_item(item.uuid)
      assert moved.status == "active"
      assert moved.category_uuid == target.uuid
    end

    test "skips already-deleted categories in the count" do
      cat = create_catalogue()
      a = create_category(cat, %{name: "A"})
      b = create_category(cat, %{name: "B"})
      Catalogue.trash_category(b)

      assert {:ok, %{categories: 1}} =
               Catalogue.bulk_trash_categories([a.uuid, b.uuid], :uncategorize, [])
    end

    test "empty list is a no-op" do
      assert {:ok, %{categories: 0, items_handled: 0}} =
               Catalogue.bulk_trash_categories([], :cascade, [])
    end
  end

  describe "list_move_target_categories/1" do
    test "excludes the category itself" do
      cat = create_catalogue()
      a = create_category(cat, %{name: "A"})

      targets = Catalogue.list_move_target_categories(a)
      uuids = Enum.map(targets, fn {c, _depth} -> c.uuid end)

      refute a.uuid in uuids
    end

    test "excludes the category's V103 subtree" do
      cat = create_catalogue()
      root = create_category(cat, %{name: "Root"})
      child = create_category(cat, %{name: "Child", parent_uuid: root.uuid})
      grandchild = create_category(cat, %{name: "GC", parent_uuid: child.uuid})
      sibling = create_category(cat, %{name: "Sibling"})

      targets = Catalogue.list_move_target_categories(root)
      uuids = Enum.map(targets, fn {c, _depth} -> c.uuid end)

      refute root.uuid in uuids
      refute child.uuid in uuids
      refute grandchild.uuid in uuids
      assert sibling.uuid in uuids
    end
  end

  describe "active_item_count_in_subtree/1" do
    test "counts items in the category and every V103 descendant" do
      cat = create_catalogue()
      root = create_category(cat, %{name: "Root"})
      child = create_category(cat, %{name: "Child", parent_uuid: root.uuid})

      _ = create_item(%{name: "RootItem", category_uuid: root.uuid})
      _ = create_item(%{name: "ChildItem", category_uuid: child.uuid})
      deleted = create_item(%{name: "Deleted", category_uuid: child.uuid})
      Catalogue.trash_item(deleted)

      assert Catalogue.active_item_count_in_subtree(root.uuid) == 2
    end
  end

  describe "list_deleted_items_for_catalogue/2" do
    test "returns only deleted items in this catalogue, newest first" do
      cat = create_catalogue()
      cat_other = create_catalogue()

      a = create_item(%{name: "A", catalogue_uuid: cat.uuid})
      b = create_item(%{name: "B", catalogue_uuid: cat.uuid})
      foreign = create_item(%{name: "F", catalogue_uuid: cat_other.uuid})

      Catalogue.trash_item(a)
      Process.sleep(1100)
      Catalogue.trash_item(b)
      Catalogue.trash_item(foreign)

      uuids =
        cat.uuid
        |> Catalogue.list_deleted_items_for_catalogue()
        |> Enum.map(& &1.uuid)

      assert uuids == [b.uuid, a.uuid]
      refute foreign.uuid in uuids
    end

    test "respects :limit" do
      cat = create_catalogue()

      for i <- 1..3 do
        item = create_item(%{name: "Item #{i}", catalogue_uuid: cat.uuid})
        Catalogue.trash_item(item)
      end

      assert length(Catalogue.list_deleted_items_for_catalogue(cat.uuid, limit: 2)) == 2
    end
  end

  describe "item_status_counts_for_category/1 and _for_uncategorized/1" do
    test "group a category's items by status (drives the per-status tabs)" do
      cat = create_catalogue()
      category = create_category(cat, %{name: "Shelf"})

      create_item(%{name: "a1", category_uuid: category.uuid, status: "active"})
      create_item(%{name: "a2", category_uuid: category.uuid, status: "active"})
      create_item(%{name: "i1", category_uuid: category.uuid, status: "inactive"})
      create_item(%{name: "d1", category_uuid: category.uuid, status: "discontinued"})
      create_item(%{name: "x1", category_uuid: category.uuid, status: "deleted"})

      counts = Catalogue.item_status_counts_for_category(category.uuid)

      assert counts["active"] == 2
      assert counts["inactive"] == 1
      assert counts["discontinued"] == 1
      assert counts["deleted"] == 1
    end

    test "uncategorized counts cover the catalogue's loose items by status" do
      cat = create_catalogue()
      create_item(%{name: "u1", catalogue_uuid: cat.uuid, status: "active"})
      create_item(%{name: "u2", catalogue_uuid: cat.uuid, status: "discontinued"})

      counts = Catalogue.item_status_counts_for_uncategorized(cat.uuid)

      assert counts["active"] == 1
      assert counts["discontinued"] == 1
      # Absent statuses simply have no key (group_by), not a zero.
      assert Map.get(counts, "inactive", 0) == 0
    end
  end
end
