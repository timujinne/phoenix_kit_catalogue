defmodule PhoenixKitCatalogue.Catalogue.TrashEdgesTest do
  @moduledoc """
  Edges of the trash found in the 2026-09-15 review: Delete Forever on a
  trashed category removes only the trashed part of its subtree (a
  subcategory restored on its own survives), the Deleted-tab variants
  (`only_trashed: true`) refuse a row restored in the meantime,
  `permanent_delete_scope/1` reports what a delete removes, the
  catalogue-wide item list can skip items inside trashed categories,
  trash search ignores status filters, and a copy never carries a stamp.
  """
  use PhoenixKitCatalogue.DataCase, async: false

  import Ecto.Query

  import PhoenixKitCatalogue.LiveCase,
    only: [fixture_catalogue: 1, fixture_category: 2, fixture_item: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Schemas.Item
  alias PhoenixKitCatalogue.Test.Repo

  defp fresh_category(uuid), do: Catalogue.get_category(uuid)

  describe "permanently_delete_category/2" do
    test "a trashed category keeps a subcategory restored on its own, with what is under it" do
      cat = fixture_catalogue(%{name: "Keep live"})
      parent = fixture_category(cat, %{name: "Parent"})
      child = fixture_category(cat, %{name: "Child", parent_uuid: parent.uuid})
      grandchild = fixture_category(cat, %{name: "Grandchild", parent_uuid: child.uuid})
      in_parent = fixture_item(%{name: "In parent", category_uuid: parent.uuid})
      in_child = fixture_item(%{name: "In child", category_uuid: child.uuid})

      {:ok, _} = Catalogue.trash_category(parent, items: :cascade)
      {:ok, _} = Catalogue.restore_category(fresh_category(child.uuid))

      assert {:ok, _} = Catalogue.permanently_delete_category(fresh_category(parent.uuid))

      assert is_nil(Catalogue.get_category(parent.uuid))
      assert is_nil(Catalogue.get_item(in_parent.uuid))

      kept = Catalogue.get_category(child.uuid)
      assert kept.status == "active"
      assert is_nil(kept.parent_uuid)
      assert Catalogue.get_category(grandchild.uuid).status == "deleted"
      assert Catalogue.get_item(in_child.uuid)
    end

    # PR #118 release review: the rows under a kept subcategory that the
    # removed category's trash took still named it as their root, so no
    # Restore brought them back together.
    test "rows under a kept subcategory get a trash root that still exists" do
      cat = fixture_catalogue(%{name: "Restamp"})
      sibling = fixture_category(cat, %{name: "Sibling"})
      parent = fixture_category(cat, %{name: "Parent"})
      child = fixture_category(cat, %{name: "Child", parent_uuid: parent.uuid})
      grandchild = fixture_category(cat, %{name: "Grandchild", parent_uuid: child.uuid})
      great = fixture_category(cat, %{name: "Great", parent_uuid: grandchild.uuid})
      in_child = fixture_item(%{name: "In child", category_uuid: child.uuid})
      in_grandchild = fixture_item(%{name: "In grandchild", category_uuid: grandchild.uuid})
      in_great = fixture_item(%{name: "In great", category_uuid: great.uuid})

      {:ok, _} = Catalogue.trash_category(parent, items: :cascade)
      {:ok, _} = Catalogue.restore_category(fresh_category(child.uuid))
      {:ok, _} = Catalogue.permanently_delete_category(fresh_category(parent.uuid))

      assert fresh_category(child.uuid).position > fresh_category(sibling.uuid).position

      # An item left in the live subcategory is trashed on its own now.
      stamp = Repo.get!(Item, in_child.uuid).data["_trash"]
      assert %{"via" => "self", "from_status" => _} = stamp
      assert stamp["root"] == in_child.uuid

      # The topmost trashed category below it owns what the trash took.
      assert %{"via" => "self"} = fresh_category(grandchild.uuid).data["_trash"]
      assert fresh_category(great.uuid).data["_trash"]["root"] == grandchild.uuid

      {:ok, _} = Catalogue.restore_category(fresh_category(grandchild.uuid))

      assert fresh_category(grandchild.uuid).status != "deleted"
      assert fresh_category(great.uuid).status != "deleted"
      assert Catalogue.get_item(in_grandchild.uuid).status != "deleted"
      assert Catalogue.get_item(in_great.uuid).status != "deleted"
      assert Catalogue.get_item(in_child.uuid).status == "deleted"
    end

    test "a live category still takes its whole subtree" do
      cat = fixture_catalogue(%{name: "Whole"})
      parent = fixture_category(cat, %{name: "Parent"})
      child = fixture_category(cat, %{name: "Child", parent_uuid: parent.uuid})
      item = fixture_item(%{name: "Deep", category_uuid: child.uuid})

      assert {:ok, _} = Catalogue.permanently_delete_category(parent)

      assert is_nil(Catalogue.get_category(child.uuid))
      assert is_nil(Catalogue.get_item(item.uuid))
    end

    test "only_trashed refuses a category restored since the page showed it" do
      cat = fixture_catalogue(%{name: "Raced"})
      category = fixture_category(cat, %{name: "Came back"})
      {:ok, _} = Catalogue.trash_category(category)
      stale = fresh_category(category.uuid)
      {:ok, _} = Catalogue.restore_category(stale)

      assert {:error, :not_in_trash} =
               Catalogue.permanently_delete_category(stale, only_trashed: true)

      assert Catalogue.get_category(category.uuid).status == "active"
    end

    test "permanent_delete_scope counts what a delete removes, rows trashed first included" do
      cat = fixture_catalogue(%{name: "Scope"})
      shelf = fixture_category(cat, %{name: "Shelf"})
      sub = fixture_category(cat, %{name: "Sub", parent_uuid: shelf.uuid})
      fixture_item(%{name: "On shelf", category_uuid: shelf.uuid})
      early = fixture_item(%{name: "Early", category_uuid: sub.uuid})
      {:ok, _} = Catalogue.trash_item(early)
      {:ok, _} = Catalogue.trash_category(shelf, items: :cascade)

      assert Catalogue.permanent_delete_scope(fresh_category(shelf.uuid)) ==
               %{subcategories: 1, items: 2}
    end
  end

  describe "permanent item deletes" do
    test "only_trashed refuses a live item, and the bulk delete skips live items" do
      cat = fixture_catalogue(%{name: "Items raced"})
      live = fixture_item(%{name: "Live", catalogue_uuid: cat.uuid})
      gone = fixture_item(%{name: "Gone", catalogue_uuid: cat.uuid})
      {:ok, _} = Catalogue.trash_item(gone)

      assert {:error, :not_in_trash} = Catalogue.permanently_delete_item(live, only_trashed: true)
      assert Catalogue.get_item(live.uuid)

      assert {1, nil} =
               Catalogue.bulk_permanently_delete_items([live.uuid, gone.uuid],
                 catalogue_uuid: cat.uuid,
                 only_trashed: true
               )

      assert Catalogue.get_item(live.uuid)
      assert is_nil(Catalogue.get_item(gone.uuid))
    end
  end

  describe "trash listings" do
    test "the catalogue-wide item list can skip items inside a trashed category" do
      cat = fixture_catalogue(%{name: "Loose only"})
      shelf = fixture_category(cat, %{name: "Shelf"})
      inside = fixture_item(%{name: "Inside", category_uuid: shelf.uuid})
      loose = fixture_item(%{name: "Loose", catalogue_uuid: cat.uuid})
      {:ok, _} = Catalogue.trash_item(loose)
      {:ok, _} = Catalogue.trash_category(shelf, items: :cascade)

      opts = [status: "deleted", outside_trashed_categories: true]

      assert Enum.map(Catalogue.list_catalogue_items_paged(cat.uuid, opts), & &1.uuid) == [
               loose.uuid
             ]

      assert Catalogue.count_items_for_catalogue(cat.uuid, opts) == 1

      all = Catalogue.list_catalogue_items_paged(cat.uuid, status: "deleted")
      assert Enum.sort(Enum.map(all, & &1.uuid)) == Enum.sort([inside.uuid, loose.uuid])
    end

    test "search_items trashed: true ignores the status filter" do
      cat = fixture_catalogue(%{name: "Search trash"})
      gone = fixture_item(%{name: "Findable gone", catalogue_uuid: cat.uuid})
      {:ok, _} = Catalogue.trash_item(gone)

      found =
        Catalogue.search_items("findable",
          catalogue_uuids: [cat.uuid],
          trashed: true,
          statuses: ["active"]
        )

      assert Enum.map(found, & &1.uuid) == [gone.uuid]
    end

    test "a duplicated item never carries a trash stamp" do
      cat = fixture_catalogue(%{name: "Stamp"})
      item = fixture_item(%{name: "Stamped", catalogue_uuid: cat.uuid})

      from(i in Item, where: i.uuid == ^item.uuid)
      |> Repo.update_all(set: [data: %{"_trash" => %{"via" => "self", "root" => item.uuid}}])

      {:ok, copy} = Catalogue.duplicate_item(Catalogue.get_item(item.uuid))
      refute Map.has_key?(copy.data || %{}, "_trash")
    end
  end
end
