defmodule PhoenixKitCatalogue.API.DeleteCategoriesTest do
  @moduledoc "`catalogue.delete_categories`."

  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase,
    only: [fixture_catalogue: 1, fixture_category: 2, fixture_item: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.PubSub
  alias PhoenixKitCatalogue.Test.{ApiCase, QueryHook}

  @tool "catalogue.delete_categories"

  setup do
    %{catalogue: fixture_catalogue(%{name: "Delete Categories Cat"})}
  end

  defp category(catalogue, name, extra \\ %{}),
    do: fixture_category(catalogue, Map.merge(%{name: name}, extra))

  defp item(catalogue, name, extra),
    do: fixture_item(Map.merge(%{name: name, catalogue_uuid: catalogue.uuid}, extra))

  defp eid(id), do: %{"api" => %{"external_id" => id}}

  defp delete(catalogue, refs, overrides \\ %{}),
    do: ApiCase.call(@tool, %{"catalogue_id" => catalogue.uuid, "refs" => refs}, overrides)

  defp rows({:ok, %{"results" => rows}}), do: rows
  defp rows_of({:preview, %{"rows" => rows}, _fingerprint}), do: rows
  defp rows_of(result), do: rows(result)

  defp status(%{uuid: uuid}), do: Catalogue.get_category!(uuid).status

  test "the tool is declared dangerous, destructive and under its own delete scope" do
    tool = ApiCase.tool!(@tool)

    assert tool.danger == :always
    assert tool.scope == "catalogue.categories:delete"
    assert tool.permission == "catalogue"
    assert tool.annotations.destructive
    assert tool.annotations.idempotent
    assert tool.max_items == 500
    assert tool.description =~ "dry_run"
  end

  test "trashes by id and external_id; restore_category brings the category back", %{
    catalogue: catalogue
  } do
    a = category(catalogue, "Alpha")
    b = category(catalogue, "Beta", %{data: eid("C-B")})

    result = delete(catalogue, [%{"id" => a.uuid}, %{"external_id" => "C-B"}])

    assert {:ok, %{"summary" => %{"removed" => 2}}} = result
    assert result |> rows() |> Enum.map(& &1["id"]) == [a.uuid, b.uuid]

    for c <- [a, b] do
      trashed = Catalogue.get_category!(c.uuid)
      assert trashed.status == "deleted"
      assert trashed.data["_trash"]["via"] == "self"
    end

    assert {:ok, restored} = Catalogue.restore_category(Catalogue.get_category!(a.uuid))
    assert restored.status == "active"

    log =
      assert_activity_logged("category.trashed",
        resource_uuid: b.uuid,
        actor_uuid: ApiCase.user_uuid()
      )

    assert log.mode == "auto"
    assert log.metadata["via"] == "api"
    assert log.metadata["tool"] == @tool
  end

  test "nothing is ever hard-deleted", %{catalogue: catalogue} do
    a = category(catalogue, "Alpha")
    assert {:ok, %{"summary" => %{"removed" => 1}}} = delete(catalogue, [%{"id" => a.uuid}])

    assert %{status: "deleted"} = Catalogue.get_category(a.uuid)
    refute_activity_logged("category.permanently_deleted", resource_uuid: a.uuid)
  end

  test "the schema takes id and external_id only: a sku is refused", %{catalogue: catalogue} do
    assert {:error, :validation_failed, _, %{errors: errors}} =
             delete(catalogue, [%{"sku" => "S-1"}])

    assert Enum.any?(errors, &String.ends_with?(&1.path, "sku"))
  end

  describe "what happens to the category's contents (the admin's default: take it all)" do
    test "its subcategories and its items go to the trash with it, and a restore brings them back",
         %{catalogue: catalogue} do
      parent = category(catalogue, "Parent")
      child = category(catalogue, "Child", %{parent_uuid: parent.uuid})
      grandchild = category(catalogue, "Grandchild", %{parent_uuid: child.uuid})
      outside = category(catalogue, "Outside")
      kept = item(catalogue, "Kept", %{category_uuid: outside.uuid})
      in_parent = item(catalogue, "In parent", %{category_uuid: parent.uuid})
      in_grandchild = item(catalogue, "In grandchild", %{category_uuid: grandchild.uuid})
      own = item(catalogue, "Trashed earlier", %{category_uuid: parent.uuid})
      {:ok, _} = Catalogue.trash_item(own)

      assert {:ok, %{"summary" => %{"removed" => 1}}} =
               delete(catalogue, [%{"id" => parent.uuid}])

      for c <- [parent, child, grandchild], do: assert(status(c) == "deleted")
      assert status(outside) == "active"
      assert Catalogue.get_item!(in_parent.uuid).status == "deleted"
      assert Catalogue.get_item!(in_grandchild.uuid).status == "deleted"
      assert Catalogue.get_item!(kept.uuid).status == "active"

      assert {:ok, _} = Catalogue.restore_category(Catalogue.get_category!(parent.uuid))

      for c <- [parent, child, grandchild], do: assert(status(c) == "active")
      assert Catalogue.get_item!(in_parent.uuid).status == "active"
      assert Catalogue.get_item!(in_grandchild.uuid).status == "active"
      # An item trashed on its own before stays where it was put.
      assert Catalogue.get_item!(own.uuid).status == "deleted"
    end

    test "a category listed with its own descendant: the ancestor takes the descendant, whatever the order",
         %{catalogue: catalogue} do
      for order <- [:child_first, :parent_first] do
        parent = category(catalogue, "Parent #{order}")
        child = category(catalogue, "Child #{order}", %{parent_uuid: parent.uuid})
        refs = [%{"id" => parent.uuid}, %{"id" => child.uuid}]
        refs = if order == :child_first, do: Enum.reverse(refs), else: refs

        result = delete(catalogue, refs)
        by_id = result |> rows() |> Map.new(&{&1["id"], &1["action"]})

        assert by_id == %{parent.uuid => "removed", child.uuid => "unchanged"}
        # The descendant was taken BY the ancestor, so restoring the ancestor brings it back.
        assert Catalogue.get_category!(child.uuid).data["_trash"]["via"] == "category"
        assert {:ok, _} = Catalogue.restore_category(Catalogue.get_category!(parent.uuid))
        assert status(child) == "active"

        # The answers stay in the order of the request.
        assert Enum.map(rows(result), & &1["id"]) == Enum.map(refs, & &1["id"])
      end
    end
  end

  test "a retry is unchanged for a category already in the trash, whichever reference it uses",
       %{catalogue: catalogue} do
    a = category(catalogue, "Alpha", %{data: eid("C-A")})
    {:ok, _} = Catalogue.trash_category(a)

    refs = [%{"id" => a.uuid}, %{"external_id" => "C-A"}]

    for mode <- [%{}, %{dry_run?: true}] do
      rows = catalogue |> delete(refs, mode) |> rows_of()

      assert Enum.map(rows, & &1["action"]) == ["unchanged", "unchanged"]
      assert Enum.map(rows, & &1["id"]) == [a.uuid, a.uuid]
    end

    assert status(a) == "deleted"
  end

  test "a reference that names nothing, live or trashed, in this catalogue is not found", %{
    catalogue: catalogue
  } do
    other = fixture_catalogue(%{name: "Other Delete Categories Cat"})
    foreign = category(other, "Foreign", %{data: eid("C-F")})

    refs = [
      %{"id" => foreign.uuid},
      %{"external_id" => "C-F"},
      %{"id" => "not-a-uuid"},
      %{"external_id" => "NOPE"}
    ]

    assert catalogue |> delete(refs) |> rows() |> Enum.map(& &1["error"]["code"]) ==
             List.duplicate("not_found", 4)

    assert status(foreign) == "active"
  end

  test "a category someone else trashed after the request was planned is unchanged", %{
    catalogue: catalogue
  } do
    a = category(catalogue, "Alpha")
    :ok = PubSub.subscribe()
    flush()

    result =
      QueryHook.after_query(
        ~r/pg_advisory_xact_lock/,
        fn -> {:ok, _} = Catalogue.trash_category(Catalogue.get_category!(a.uuid)) end,
        fn -> delete(catalogue, [%{"id" => a.uuid}]) end
      )

    assert [row] = rows(result)
    assert row["action"] == "unchanged"
    assert row["id"] == a.uuid
    assert status(a) == "deleted"
    # One entry: the other writer's, none for this call.
    assert_activity_logged("category.trashed", resource_uuid: a.uuid)

    # One event too: the other writer's. A call that removed nothing announces nothing.
    cat_uuid = catalogue.uuid
    a_uuid = a.uuid
    assert_receive {:catalogue_data_changed, :category, ^a_uuid, ^cat_uuid}
    refute_receive {:catalogue_data_changed, _, _, _}, 50
  end

  test "bad rows are reported at their position and never poison the others", %{
    catalogue: catalogue
  } do
    a = category(catalogue, "Alpha")
    b = category(catalogue, "Beta")
    foreign = category(fixture_catalogue(%{name: "Elsewhere"}), "Foreign")

    result =
      delete(catalogue, [
        %{"id" => a.uuid},
        %{"id" => "not-a-uuid"},
        %{},
        %{"id" => a.uuid},
        %{"id" => foreign.uuid},
        %{"id" => b.uuid}
      ])

    assert Enum.map(rows(result), & &1["action"]) ==
             ["removed", "error", "error", "error", "error", "removed"]

    assert Enum.map(rows(result), &get_in(&1, ["error", "code"])) ==
             [nil, "not_found", "validation_failed", "validation_failed", "not_found", nil]

    assert status(a) == "deleted"
    assert status(b) == "deleted"
    assert status(foreign) == "active"
  end

  test "a batch announces one category event for the catalogue", %{catalogue: catalogue} do
    a = category(catalogue, "Alpha")
    b = category(catalogue, "Beta")
    :ok = PubSub.subscribe()
    flush()

    {:ok, _} = delete(catalogue, [%{"id" => a.uuid}, %{"id" => b.uuid}])

    cat_uuid = catalogue.uuid
    assert_receive {:catalogue_data_changed, :category, nil, ^cat_uuid}
    refute_receive {:catalogue_data_changed, _, _, _}, 50
  end

  test "a deleted category frees its external_id; restoring it afterwards is a clean refusal",
       %{catalogue: catalogue} do
    a = category(catalogue, "Alpha", %{data: eid("C-1")})

    assert {:ok, %{"summary" => %{"removed" => 1}}} =
             delete(catalogue, [%{"external_id" => "C-1"}])

    assert {:ok, %{"summary" => %{"created" => 1}}} =
             ApiCase.call("catalogue.upsert_categories", %{
               "catalogue_id" => catalogue.uuid,
               "items" => [%{"external_id" => "C-1", "name" => "Alpha again"}]
             })

    assert {:error, :external_id_taken} =
             Catalogue.restore_category(Catalogue.get_category!(a.uuid))
  end

  test "the schema refuses unknown fields, an empty list and more than 500 refs", %{
    catalogue: catalogue
  } do
    assert {:error, :validation_failed, _, %{errors: errors}} =
             ApiCase.call(@tool, %{
               "catalogue_id" => catalogue.uuid,
               "refs" => [%{"id" => Ecto.UUID.generate()}],
               "hard" => true
             })

    assert Enum.any?(errors, &(&1.path == "hard"))
    assert {:error, :validation_failed, _, _} = delete(catalogue, [])

    refs = for n <- 1..501, do: %{"external_id" => "C#{n}"}
    assert {:error, :validation_failed, _, %{errors: [%{limit: 500}]}} = delete(catalogue, refs)
  end

  describe "dry run" do
    test "previews what would go with its contents, trashes nothing, and flags the confirmation",
         %{catalogue: catalogue} do
      parent = category(catalogue, "Parent")
      child = category(catalogue, "Child", %{parent_uuid: parent.uuid})
      item(catalogue, "In parent", %{category_uuid: parent.uuid})
      item(catalogue, "In child 1", %{category_uuid: child.uuid})
      item(catalogue, "In child 2", %{category_uuid: child.uuid})
      refs = [%{"id" => parent.uuid}, %{"external_id" => "NOPE"}]

      assert {:preview,
              %{
                "requires_confirmation" => true,
                "rows" => [row, missing],
                "summary" => %{"removed" => 1, "error" => 1}
              }, fingerprint} = delete(catalogue, refs, %{dry_run?: true})

      assert row["id"] == parent.uuid
      assert row["name"] == "Parent"
      assert row["changes"] == %{"status" => %{"from" => "active", "to" => "deleted"}}
      assert row["subcategories"] == 1
      assert row["items"] == 3
      assert missing["error"]["code"] == "not_found"

      assert status(parent) == "active"
      assert status(child) == "active"
      refute_activity_logged("category.trashed", resource_uuid: parent.uuid)

      assert {:preview, _, ^fingerprint} = delete(catalogue, refs, %{dry_run?: true})

      # A new item under the category changes what a confirmation would take.
      item(catalogue, "Late", %{category_uuid: child.uuid})
      assert {:preview, _, other} = delete(catalogue, refs, %{dry_run?: true})
      assert other != fingerprint
    end

    test "a descendant listed with its ancestor previews as unchanged, like the write answers",
         %{catalogue: catalogue} do
      parent = category(catalogue, "Parent")
      child = category(catalogue, "Child", %{parent_uuid: parent.uuid})
      refs = [%{"id" => child.uuid}, %{"id" => parent.uuid}]

      assert {:preview, %{"rows" => preview_rows}, _} = delete(catalogue, refs, %{dry_run?: true})
      assert Enum.map(preview_rows, & &1["action"]) == ["unchanged", "removed"]

      assert Enum.map(rows(delete(catalogue, refs)), & &1["action"]) == ["unchanged", "removed"]
    end
  end

  describe "a live category below a trashed one (restored on its own)" do
    # R (live) > A (trashed) > B (live, restored alone), with items in B.
    setup %{catalogue: catalogue} do
      {r, a, b} = trashed_middle_tree(catalogue, "")

      items = for n <- 1..3, do: item(catalogue, "In B #{n}", %{category_uuid: b.uuid})
      %{r: r, a: a, b: b, items: items}
    end

    defp trashed_middle_tree(catalogue, suffix) do
      r = category(catalogue, "R#{suffix}")
      a = category(catalogue, "A#{suffix}", %{parent_uuid: r.uuid})
      b = category(catalogue, "B#{suffix}", %{parent_uuid: a.uuid})

      {:ok, _} = Catalogue.trash_category(Catalogue.get_category!(a.uuid))
      {:ok, _} = Catalogue.restore_category(Catalogue.get_category!(b.uuid))
      assert status(b) == "active"
      assert status(a) == "deleted"

      {r, a, b}
    end

    test "the dry run counts what the write takes, and a new item below changes the fingerprint",
         %{catalogue: catalogue, r: r, b: b} do
      refs = [%{"id" => r.uuid}]

      assert {:preview, %{"rows" => [row]}, fingerprint} =
               delete(catalogue, refs, %{dry_run?: true})

      # B is the only live subcategory (A is already in the trash); its 3 items go.
      assert row["subcategories"] == 1
      assert row["items"] == 3

      item(catalogue, "Late in B", %{category_uuid: b.uuid})

      assert {:preview, %{"rows" => [after_row]}, other} =
               delete(catalogue, refs, %{dry_run?: true})

      assert after_row["items"] == 4
      assert other != fingerprint

      assert {:ok, %{"results" => [removed]}} = delete(catalogue, refs)
      assert removed["action"] == "removed"
      assert status(b) == "deleted"
      assert Catalogue.get_category!(b.uuid).data["_trash"]["root"] == r.uuid
      assert Catalogue.list_items_for_category(b.uuid) == []
    end

    test "listed with its root, in either order, it is taken by the root", %{catalogue: catalogue} do
      for {suffix, order} <- [{" 1", [:b, :r]}, {" 2", [:r, :b]}] do
        {r, _a, b} = trashed_middle_tree(catalogue, suffix)
        by_key = %{r: r, b: b}
        refs = for key <- order, do: %{"id" => by_key[key].uuid}
        expected = for key <- order, do: if(key == :r, do: "removed", else: "unchanged")

        assert {:preview, %{"rows" => preview_rows}, _} =
                 delete(catalogue, refs, %{dry_run?: true})

        assert Enum.map(preview_rows, & &1["action"]) == expected

        assert {:ok, %{"results" => written}} = delete(catalogue, refs)
        assert Enum.map(written, & &1["action"]) == expected

        stamp = Catalogue.get_category!(b.uuid).data["_trash"]
        assert stamp["via"] == "category"
        assert stamp["root"] == r.uuid
      end
    end
  end

  test "an equal-size swap of the subcategories below a category changes the fingerprint", %{
    catalogue: catalogue
  } do
    parent = category(catalogue, "Parent")
    inside = category(catalogue, "Inside", %{parent_uuid: parent.uuid})
    outside = category(catalogue, "Outside")
    refs = [%{"id" => parent.uuid}]

    assert {:preview, %{"rows" => [row]}, fingerprint} =
             delete(catalogue, refs, %{dry_run?: true})

    assert row["subcategories"] == 1

    {:ok, _} = Catalogue.update_category(inside, %{parent_uuid: nil})
    {:ok, _} = Catalogue.update_category(outside, %{parent_uuid: parent.uuid})

    assert {:preview, %{"rows" => [same_size]}, other} =
             delete(catalogue, refs, %{dry_run?: true})

    assert same_size["subcategories"] == 1
    assert other != fingerprint
  end

  test "an equal-size swap of the items below a category changes the fingerprint", %{
    catalogue: catalogue
  } do
    parent = category(catalogue, "Parent")
    kept = item(catalogue, "Kept", %{category_uuid: parent.uuid})
    gone = item(catalogue, "Gone", %{category_uuid: parent.uuid})
    refs = [%{"id" => parent.uuid}]

    assert {:preview, %{"rows" => [row]}, fingerprint} =
             delete(catalogue, refs, %{dry_run?: true})

    assert row["items"] == 2

    {:ok, _} = Catalogue.trash_item(gone)
    item(catalogue, "Arrived", %{category_uuid: parent.uuid})

    assert {:preview, %{"rows" => [same_size]}, other} =
             delete(catalogue, refs, %{dry_run?: true})

    assert same_size["items"] == 2
    assert other != fingerprint
    assert Catalogue.get_item!(kept.uuid).status == "active"
  end

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end
end
