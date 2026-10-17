defmodule PhoenixKitCatalogue.ExternalIdRestoreTest do
  @moduledoc """
  A trashed row frees its `external_id`; bringing it back while a live row
  holds the same id must fail cleanly (`{:error, :external_id_taken}`), with
  nothing half-restored. Copies never inherit the id.
  """

  # async: false — each test provokes a unique violation inside its
  # sandboxed connection.
  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase, only: [fixture_catalogue: 1, fixture_category: 2]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Errors

  defp attrs(catalogue, external_id, extra \\ %{}) do
    Map.merge(
      %{
        name: "Item #{external_id}",
        catalogue_uuid: catalogue.uuid,
        data: %{"api" => %{"external_id" => external_id}}
      },
      extra
    )
  end

  setup do
    %{catalogue: fixture_catalogue(%{name: "Restore Catalogue"})}
  end

  test "restore_item/2 reports :external_id_taken and restores nothing", %{catalogue: catalogue} do
    {:ok, old} = Catalogue.create_item(attrs(catalogue, "X-1"))
    {:ok, _} = Catalogue.trash_item(old)
    {:ok, _live} = Catalogue.create_item(attrs(catalogue, "X-1"))

    assert {:error, :external_id_taken} = Catalogue.restore_item(old)
    assert Catalogue.get_item(old.uuid).status == "deleted"
  end

  test "inside a caller's own transaction the collision raises instead of poisoning it", %{
    catalogue: catalogue
  } do
    {:ok, old} = Catalogue.create_item(attrs(catalogue, "X-6"))
    {:ok, _} = Catalogue.trash_item(old)
    {:ok, _live} = Catalogue.create_item(attrs(catalogue, "X-6"))

    # A tuple answer here would leave the caller's transaction aborted
    # (25P02 on its next statement); the exception unwinds it instead.
    assert_raise Postgrex.Error, fn ->
      Repo.transaction(fn -> Catalogue.restore_item(old) end)
    end

    assert Catalogue.get_item(old.uuid).status == "deleted"
  end

  test "restore_item/2 still works when the id is free", %{catalogue: catalogue} do
    {:ok, old} = Catalogue.create_item(attrs(catalogue, "X-1"))
    {:ok, _} = Catalogue.trash_item(old)

    assert {:ok, restored} = Catalogue.restore_item(old)
    assert restored.status == "active"
  end

  test "restore_category/2 reports :external_id_taken and leaves the category trashed",
       %{catalogue: catalogue} do
    category = fixture_category(catalogue, %{name: "Shelf"})
    {:ok, old} = Catalogue.create_item(attrs(catalogue, "X-2", %{category_uuid: category.uuid}))
    {:ok, _} = Catalogue.trash_category(category)
    {:ok, _live} = Catalogue.create_item(attrs(catalogue, "X-2"))

    assert {:error, :external_id_taken} = Catalogue.restore_category(category)
    assert Catalogue.get_category(category.uuid).status == "deleted"
    assert Catalogue.get_item(old.uuid).status == "deleted"
  end

  test "restore_catalogue/2 reports :external_id_taken and restores nothing", %{
    catalogue: catalogue
  } do
    {:ok, old} = Catalogue.create_item(attrs(catalogue, "X-3"))

    # A row trashed before trash provenance existed has no stamp, and a
    # catalogue restore revives such rows together with what the catalogue's
    # own trash took: here the live item below.
    {1, _} =
      Repo.update_all(
        from(i in PhoenixKitCatalogue.Schemas.Item, where: i.uuid == ^old.uuid),
        set: [status: "deleted"]
      )

    {:ok, _live} = Catalogue.create_item(attrs(catalogue, "X-3"))
    {:ok, trashed} = Catalogue.trash_catalogue(catalogue)

    assert {:error, :external_id_taken} = Catalogue.restore_catalogue(trashed)
    assert Catalogue.get_catalogue(catalogue.uuid).status == "deleted"
  end

  test "bulk_restore_items/2 writes no audit entry for a refused batch", %{catalogue: catalogue} do
    {:ok, old} = Catalogue.create_item(attrs(catalogue, "X-7"))
    {:ok, _} = Catalogue.trash_item(old)
    {:ok, _live} = Catalogue.create_item(attrs(catalogue, "X-7"))

    assert {:error, :external_id_taken} = Catalogue.bulk_restore_items([old.uuid], [])
    refute_activity_logged("item.bulk_restored")
  end

  test "inside a caller's own transaction a bulk restore collision raises", %{
    catalogue: catalogue
  } do
    {:ok, old} = Catalogue.create_item(attrs(catalogue, "X-8"))
    {:ok, _} = Catalogue.trash_item(old)
    {:ok, _live} = Catalogue.create_item(attrs(catalogue, "X-8"))

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(fn -> Catalogue.bulk_restore_items([old.uuid], []) end)
    end

    assert Catalogue.get_item(old.uuid).status == "deleted"
  end

  test "inside a caller's own transaction a catalogue restore collision raises", %{
    catalogue: catalogue
  } do
    {:ok, old} = Catalogue.create_item(attrs(catalogue, "X-9"))

    {1, _} =
      Repo.update_all(
        from(i in PhoenixKitCatalogue.Schemas.Item, where: i.uuid == ^old.uuid),
        set: [status: "deleted"]
      )

    {:ok, _live} = Catalogue.create_item(attrs(catalogue, "X-9"))
    {:ok, trashed} = Catalogue.trash_catalogue(catalogue)

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(fn -> Catalogue.restore_catalogue(trashed) end)
    end

    assert Catalogue.get_catalogue(catalogue.uuid).status == "deleted"
  end

  test "bulk_restore_items/2 restores none of a conflicting batch", %{catalogue: catalogue} do
    {:ok, old} = Catalogue.create_item(attrs(catalogue, "X-4"))
    {:ok, other} = Catalogue.create_item(attrs(catalogue, "X-5"))
    {:ok, _} = Catalogue.trash_item(old)
    {:ok, _} = Catalogue.trash_item(other)
    {:ok, _live} = Catalogue.create_item(attrs(catalogue, "X-4"))

    assert {:error, :external_id_taken} =
             Catalogue.bulk_restore_items([old.uuid, other.uuid], [])

    assert Catalogue.get_item(old.uuid).status == "deleted"
    assert Catalogue.get_item(other.uuid).status == "deleted"
  end

  describe "moves between catalogues" do
    setup %{catalogue: catalogue} do
      %{target: fixture_catalogue(%{name: "Move target"}), source: catalogue}
    end

    test "move_category_to_catalogue/2 refuses when an item of the subtree collides, and moves nothing",
         %{source: source, target: target} do
      category = fixture_category(source, %{name: "Moving shelf"})
      {:ok, mover} = Catalogue.create_item(attrs(source, "M-1", %{category_uuid: category.uuid}))
      {:ok, _live_in_target} = Catalogue.create_item(attrs(target, "M-1"))

      assert {:error, :external_id_taken} =
               Catalogue.move_category_to_catalogue(category, target.uuid)

      assert Catalogue.get_category(category.uuid).catalogue_uuid == source.uuid
      assert Catalogue.get_item(mover.uuid).catalogue_uuid == source.uuid
    end

    test "move_category_to_catalogue/2 refuses when the category's own id collides",
         %{source: source, target: target} do
      {:ok, category} =
        Catalogue.create_category(%{
          name: "Dup shelf",
          catalogue_uuid: source.uuid,
          data: %{"api" => %{"external_id" => "MC-1"}}
        })

      {:ok, _} =
        Catalogue.create_category(%{
          name: "Other shelf",
          catalogue_uuid: target.uuid,
          data: %{"api" => %{"external_id" => "MC-1"}}
        })

      assert {:error, :external_id_taken} =
               Catalogue.move_category_to_catalogue(category, target.uuid)

      assert Catalogue.get_category(category.uuid).catalogue_uuid == source.uuid
    end

    test "move_item_to_catalogue/3 answers :external_id_taken, not a changeset, and moves nothing",
         %{source: source, target: target} do
      {:ok, clash} = Catalogue.create_item(attrs(source, "M-5"))
      {:ok, _} = Catalogue.create_item(attrs(target, "M-5"))

      assert {:error, :external_id_taken} = Catalogue.move_item_to_catalogue(clash, target.uuid)
      assert Catalogue.get_item(clash.uuid).catalogue_uuid == source.uuid
    end

    test "bulk_move_items/3 moves none of a colliding batch", %{source: source, target: target} do
      {:ok, fine} = Catalogue.create_item(attrs(source, "M-2"))
      {:ok, clash} = Catalogue.create_item(attrs(source, "M-3"))
      {:ok, _} = Catalogue.create_item(attrs(target, "M-3"))

      assert {:error, :external_id_taken} =
               Catalogue.bulk_move_items([fine.uuid, clash.uuid], {:catalogue, target.uuid},
                 catalogue_uuid: source.uuid
               )

      assert Catalogue.get_item(fine.uuid).catalogue_uuid == source.uuid
      assert Catalogue.get_item(clash.uuid).catalogue_uuid == source.uuid
    end

    test "bulk_move_categories_to_catalogue/4 refuses a colliding subtree", %{
      source: source,
      target: target
    } do
      category = fixture_category(source, %{name: "Bulk shelf"})
      {:ok, _} = Catalogue.create_item(attrs(source, "M-4", %{category_uuid: category.uuid}))
      {:ok, _} = Catalogue.create_item(attrs(target, "M-4"))

      # per-row results: the colliding category is reported as an error, the call itself is {:ok, _}
      assert {:ok, %{moved: 0, errors: [{uuid, :external_id_taken}]}} =
               Catalogue.bulk_move_categories_to_catalogue([category.uuid], target.uuid, nil,
                 catalogue_uuid: source.uuid
               )

      assert uuid == category.uuid

      assert Catalogue.get_category(category.uuid).catalogue_uuid == source.uuid
    end
  end

  test "Errors.message/1 has a sentence for it" do
    assert Errors.message(:external_id_taken) ==
             "Another active row already uses the same external id."
  end

  describe "copies drop the external id" do
    test "duplicate_item/2", %{catalogue: catalogue} do
      {:ok, item} =
        Catalogue.create_item(
          attrs(catalogue, "X-6", %{data: %{"api" => %{"external_id" => "X-6", "note" => "keep"}}})
        )

      assert {:ok, copy} = Catalogue.duplicate_item(item)
      assert copy.data["api"] == %{"note" => "keep"}
    end

    test "an item whose api map held only the id comes out without an api key",
         %{catalogue: catalogue} do
      {:ok, item} = Catalogue.create_item(attrs(catalogue, "X-7"))

      assert {:ok, copy} = Catalogue.duplicate_item(item)
      refute Map.has_key?(copy.data, "api")
      assert Catalogue.get_item(item.uuid).data["api"]["external_id"] == "X-7"
    end

    test "duplicate_category/2 copies its items without their ids", %{catalogue: catalogue} do
      category = fixture_category(catalogue, %{name: "Source shelf"})

      {:ok, source} =
        Catalogue.create_item(attrs(catalogue, "X-8", %{category_uuid: category.uuid}))

      assert {:ok, %{category: copy, items: 1}} = Catalogue.duplicate_category(category)
      assert [copied] = Catalogue.list_items_for_category(copy.uuid)
      refute Map.has_key?(copied.data, "api")
      assert Catalogue.get_item!(source.uuid).data["api"]["external_id"] == "X-8"
    end
  end
end
