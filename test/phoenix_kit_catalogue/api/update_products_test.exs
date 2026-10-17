defmodule PhoenixKitCatalogue.API.UpdateProductsTest do
  @moduledoc "`catalogue.update_products`."

  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase,
    only: [fixture_catalogue: 1, fixture_category: 2, fixture_item: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.PubSub
  alias PhoenixKitCatalogue.Test.{ApiCase, QueryHook}

  @tool "catalogue.update_products"

  setup do
    %{catalogue: fixture_catalogue(%{name: "Update Cat"})}
  end

  defp item(catalogue, name, extra \\ %{}),
    do: fixture_item(Map.merge(%{name: name, catalogue_uuid: catalogue.uuid}, extra))

  defp run_update(catalogue, entries, overrides \\ %{}),
    do: ApiCase.call(@tool, %{"catalogue_id" => catalogue.uuid, "items" => entries}, overrides)

  defp entry(ref, changes), do: %{"ref" => ref, "changes" => changes}

  defp rows({:ok, %{"results" => rows}}), do: rows

  test "renames by id, sku and external_id and logs who did it and what moved", %{
    catalogue: catalogue
  } do
    a = item(catalogue, "Alpha")
    b = item(catalogue, "Beta", %{sku: "SKU-B"})
    c = item(catalogue, "Gamma", %{data: %{"api" => %{"external_id" => "E-C"}}})

    result =
      run_update(catalogue, [
        entry(%{"id" => a.uuid}, %{"name" => "Alpha 2"}),
        entry(%{"sku" => "SKU-B"}, %{"name" => "Beta 2"}),
        entry(%{"external_id" => "E-C"}, %{"name" => "Gamma 2"})
      ])

    assert {:ok, %{"summary" => %{"updated" => 3}}} = result
    assert Enum.map(rows(result), & &1["id"]) == [a.uuid, b.uuid, c.uuid]
    assert Catalogue.get_item!(a.uuid).name == "Alpha 2"
    assert Catalogue.get_item!(b.uuid).name == "Beta 2"
    assert Catalogue.get_item!(c.uuid).name == "Gamma 2"

    log =
      assert_activity_logged("item.updated",
        resource_uuid: a.uuid,
        actor_uuid: ApiCase.user_uuid()
      )

    assert log.mode == "auto"
    assert log.metadata["via"] == "api"
    assert log.metadata["tool"] == "catalogue.update_products"
    assert log.metadata["key_prefix"] == "abcd1234"
    assert log.metadata["request_id"] == "req-test"
    assert log.metadata["changes"]["name"] == %{"from" => "Alpha", "to" => "Alpha 2"}
  end

  test "a name is stored trimmed", %{catalogue: catalogue} do
    a = item(catalogue, "Alpha")

    assert {:ok, %{"summary" => %{"updated" => 1}}} =
             run_update(catalogue, [entry(%{"id" => a.uuid}, %{"name" => "  Alpha 2  "})])

    assert Catalogue.get_item!(a.uuid).name == "Alpha 2"
  end

  test "a rename leaves the slug where it is", %{catalogue: catalogue} do
    a = item(catalogue, "Oak panel", %{slug: %{"en-US" => "oak-panel"}})

    assert {:ok, %{"summary" => %{"updated" => 1}}} =
             run_update(catalogue, [entry(%{"id" => a.uuid}, %{"name" => "Oak panel XL"})])

    assert Catalogue.get_item!(a.uuid).slug == %{"en-US" => "oak-panel"}
  end

  test "keys of data the tool does not own are untouched", %{catalogue: catalogue} do
    data = %{
      "ecommerce" => %{"shopify" => %{"product_id" => "1"}, "compare_at_price" => "3"},
      "meta" => %{"color" => "red"},
      "_primary_language" => "en-US",
      "en-US" => %{"_name" => "Alpha"}
    }

    a = item(catalogue, "Alpha", %{data: data})

    assert {:ok, %{"summary" => %{"updated" => 1}}} =
             run_update(catalogue, [
               entry(%{"id" => a.uuid}, %{"name" => "Alpha 2", "external_id" => "E-1"})
             ])

    assert Catalogue.get_item!(a.uuid).data == Map.put(data, "api", %{"external_id" => "E-1"})

    log = assert_activity_logged("item.updated", resource_uuid: a.uuid)
    assert log.metadata["changes"]["data.api.external_id"] == %{"from" => "", "to" => "E-1"}
  end

  test "external_id can be changed and cleared", %{catalogue: catalogue} do
    a =
      item(catalogue, "Alpha", %{
        data: %{"api" => %{"external_id" => "E-1"}, "meta" => %{"k" => "v"}}
      })

    assert {:ok, %{"summary" => %{"updated" => 1}}} =
             run_update(catalogue, [entry(%{"id" => a.uuid}, %{"external_id" => "E-2"})])

    assert Catalogue.get_item!(a.uuid).data["api"] == %{"external_id" => "E-2"}

    assert {:ok, %{"summary" => %{"updated" => 1}}} =
             run_update(catalogue, [entry(%{"external_id" => "E-2"}, %{"external_id" => nil})])

    data = Catalogue.get_item!(a.uuid).data
    refute Map.has_key?(data, "api")
    assert data["meta"] == %{"k" => "v"}
  end

  test "an external_id another live item holds is a row error with the holder's id; the rest apply",
       %{catalogue: catalogue} do
    holder = item(catalogue, "Holder", %{data: %{"api" => %{"external_id" => "TAKEN"}}})
    a = item(catalogue, "Alpha")
    b = item(catalogue, "Beta")

    result =
      run_update(catalogue, [
        entry(%{"id" => a.uuid}, %{"name" => "Alpha 2"}),
        entry(%{"id" => b.uuid}, %{"external_id" => "TAKEN", "name" => "Beta 2"}),
        entry(%{"id" => a.uuid}, %{"name" => "Again"})
      ])

    assert [one, two, three] = rows(result)
    assert one["action"] == "updated"
    assert two["action"] == "error"
    assert two["error"]["code"] == "already_exists"
    assert two["error"]["context"]["existing_id"] == holder.uuid
    assert three["action"] == "error"
    assert three["error"]["code"] == "validation_failed"

    assert Catalogue.get_item!(a.uuid).name == "Alpha 2"
    assert Catalogue.get_item!(b.uuid).name == "Beta"
  end

  test "category: move, uncategorize, and a foreign category is refused", %{catalogue: catalogue} do
    shelf = fixture_category(catalogue, %{name: "Shelf"})
    foreign = fixture_category(fixture_catalogue(%{name: "Elsewhere"}), %{name: "Foreign"})
    a = item(catalogue, "Alpha")

    assert {:ok, %{"summary" => %{"updated" => 1}}} =
             run_update(catalogue, [entry(%{"id" => a.uuid}, %{"category_id" => shelf.uuid})])

    assert Catalogue.get_item!(a.uuid).category_uuid == shelf.uuid

    moved =
      assert_activity_logged("item.moved", resource_uuid: a.uuid, actor_uuid: ApiCase.user_uuid())

    assert moved.metadata["via"] == "api"
    assert moved.metadata["tool"] == "catalogue.update_products"
    assert moved.mode == "auto"

    assert {:ok, %{"summary" => %{"unchanged" => 1}}} =
             run_update(catalogue, [entry(%{"id" => a.uuid}, %{"category_id" => shelf.uuid})])

    assert {:ok, %{"summary" => %{"updated" => 1}}} =
             run_update(catalogue, [entry(%{"id" => a.uuid}, %{"category_id" => nil})])

    assert Catalogue.get_item!(a.uuid).category_uuid == nil

    assert [%{"action" => "error", "error" => %{"context" => %{"errors" => [error]}}}] =
             rows(
               run_update(catalogue, [entry(%{"id" => a.uuid}, %{"category_id" => foreign.uuid})])
             )

    assert error["path"] == "changes.category_id"
  end

  test "status, unit, sku and description (including null) are written", %{catalogue: catalogue} do
    a = item(catalogue, "Alpha", %{sku: "OLD", description: "Old text"})

    assert {:ok, %{"summary" => %{"updated" => 1}}} =
             run_update(catalogue, [
               entry(%{"id" => a.uuid}, %{
                 "status" => "discontinued",
                 "unit" => "pack",
                 "sku" => nil,
                 "description" => nil
               })
             ])

    reread = Catalogue.get_item!(a.uuid)

    assert {reread.status, reread.unit, reread.sku, reread.description} ==
             {"discontinued", "pack", nil, nil}
  end

  test "an update that changes nothing is unchanged and writes no entry", %{catalogue: catalogue} do
    a = item(catalogue, "Alpha")

    assert {:ok, %{"summary" => %{"unchanged" => 1}}} =
             run_update(catalogue, [entry(%{"id" => a.uuid}, %{"name" => "Alpha"})])

    refute_activity_logged("item.updated", resource_uuid: a.uuid)
  end

  test "bad rows are reported at their position and never poison the others", %{
    catalogue: catalogue
  } do
    a = item(catalogue, "Alpha")
    item(catalogue, "Twin 1", %{sku: "TWIN"})
    item(catalogue, "Twin 2", %{sku: "TWIN"})
    b = item(catalogue, "Beta")

    result =
      run_update(catalogue, [
        entry(%{"id" => a.uuid}, %{"name" => "Alpha 2"}),
        entry(%{"sku" => "TWIN"}, %{"name" => "Which?"}),
        entry(%{"id" => "not-a-uuid"}, %{"name" => "X"}),
        entry(%{"sku" => "NOPE"}, %{"name" => "X"}),
        entry(%{}, %{"name" => "X"}),
        entry(%{"id" => b.uuid}, %{}),
        entry(%{"id" => b.uuid}, %{"name" => "   "}),
        entry(%{"id" => b.uuid}, %{"name" => "Beta 2"})
      ])

    rows = rows(result)

    assert Enum.map(rows, & &1["action"]) ==
             ["updated", "error", "error", "error", "error", "error", "error", "updated"]

    assert Enum.map(rows, &get_in(&1, ["error", "code"])) ==
             [
               nil,
               "ambiguous_ref",
               "not_found",
               "not_found",
               "validation_failed",
               "validation_failed",
               "validation_failed",
               nil
             ]

    assert Catalogue.get_item!(a.uuid).name == "Alpha 2"
    assert Catalogue.get_item!(b.uuid).name == "Beta 2"
    assert {:ok, %{"summary" => %{"updated" => 2, "error" => 6}}} = result
  end

  test "a malformed category_id, a blank sku ref and a blank name fail their own row only", %{
    catalogue: catalogue
  } do
    # None of these may be a whole-request 422: row-level strings have no length floor in the schema.
    a = item(catalogue, "Alpha")
    b = item(catalogue, "Beta")

    result =
      run_update(catalogue, [
        entry(%{"id" => a.uuid}, %{"name" => "Alpha 2"}),
        entry(%{"id" => b.uuid}, %{"category_id" => "short"}),
        entry(%{"sku" => ""}, %{"name" => "X"}),
        entry(%{"id" => b.uuid}, %{"name" => ""}),
        entry(%{"id" => b.uuid}, %{"name" => "Beta 2"})
      ])

    assert {:ok, %{"results" => rows, "summary" => %{"updated" => 2, "error" => 3}}} = result
    assert Enum.map(rows, & &1["action"]) == ["updated", "error", "error", "error", "updated"]
    assert Enum.all?(Enum.slice(rows, 1, 3), &(&1["error"]["code"] == "validation_failed"))
    assert Catalogue.get_item!(a.uuid).name == "Alpha 2"
    assert Catalogue.get_item!(b.uuid).name == "Beta 2"
  end

  test "a blank external_id in changes is a row error and writes nothing", %{catalogue: catalogue} do
    a = item(catalogue, "Alpha", %{data: %{"meta" => %{"k" => "v"}}})

    assert [%{"action" => "error", "error" => %{"code" => "validation_failed"}}] =
             rows(
               run_update(catalogue, [
                 entry(%{"id" => a.uuid}, %{"external_id" => "  ", "name" => "X"})
               ])
             )

    reread = Catalogue.get_item!(a.uuid)
    assert reread.name == "Alpha"
    assert reread.data == a.data
  end

  test "an item of another catalogue is not found", %{catalogue: catalogue} do
    foreign = item(fixture_catalogue(%{name: "Elsewhere"}), "Foreign")

    assert [%{"action" => "error", "error" => %{"code" => "not_found"}}] =
             rows(
               run_update(catalogue, [entry(%{"id" => foreign.uuid}, %{"name" => "Hijacked"})])
             )

    assert Catalogue.get_item!(foreign.uuid).name == "Foreign"
  end

  test "the schema refuses price, markup, discount and raw data at any depth", %{
    catalogue: catalogue
  } do
    a = item(catalogue, "Alpha")

    for field <- ~w(base_price markup_percentage discount_percentage data cost_per_item) do
      assert {:error, :validation_failed, _, %{errors: errors}} =
               run_update(catalogue, [entry(%{"id" => a.uuid}, %{field => 1})]),
             "#{field} was accepted"

      assert Enum.any?(errors, &(&1.path == "items[0].changes.#{field}")),
             "#{field}: #{inspect(errors)}"
    end

    assert {:error, :validation_failed, _, %{errors: errors}} =
             run_update(catalogue, [entry(%{"id" => a.uuid, "base_price" => 1}, %{"name" => "x"})])

    assert Enum.any?(errors, &(&1.path == "items[0].ref.base_price"))

    assert {:error, :validation_failed, _, %{errors: errors}} =
             run_update(catalogue, [entry(%{"id" => a.uuid}, %{"status" => "deleted"})])

    assert Enum.any?(errors, &(&1.path == "items[0].changes.status"))
  end

  test "a batch announces one bulk event", %{catalogue: catalogue} do
    a = item(catalogue, "Alpha")
    b = item(catalogue, "Beta")
    :ok = PubSub.subscribe()
    flush()

    {:ok, _} =
      run_update(catalogue, [
        entry(%{"id" => a.uuid}, %{"name" => "A2"}),
        entry(%{"id" => b.uuid}, %{"name" => "B2"})
      ])

    cat_uuid = catalogue.uuid
    assert_receive {:catalogue_bulk_change, ^cat_uuid, :updated, uuids, _from}
    assert Enum.sort(uuids) == Enum.sort([a.uuid, b.uuid])
    refute_receive {:catalogue_bulk_change, _, _, _, _}, 50
    assert_receive {:catalogue_data_changed, :item, nil, ^cat_uuid}
    refute_receive {:catalogue_data_changed, _, _, _}, 50
  end

  test "recategorising many items is one bulk event and one data-changed event; each move logs item.moved",
       %{catalogue: catalogue} do
    shelf = fixture_category(catalogue, %{name: "Move target"})
    items = for n <- 1..3, do: item(catalogue, "Mover #{n}")
    :ok = PubSub.subscribe()
    flush()

    entries = for i <- items, do: entry(%{"id" => i.uuid}, %{"category_id" => shelf.uuid})
    assert {:ok, %{"summary" => %{"updated" => 3}}} = run_update(catalogue, entries)

    cat_uuid = catalogue.uuid
    assert_receive {:catalogue_bulk_change, ^cat_uuid, :updated, uuids, _from}
    assert Enum.sort(uuids) == items |> Enum.map(& &1.uuid) |> Enum.sort()
    refute_receive {:catalogue_bulk_change, _, _, _, _}, 50
    assert_receive {:catalogue_data_changed, :item, nil, ^cat_uuid}
    refute_receive {:catalogue_data_changed, _, _, _}, 50

    # The documented exception to "one log insert": a move keeps the context's own
    # `item.moved` entry (readable from/to), so N moves are N entries, not N broadcasts.
    moved = Enum.filter(list_activities(), &(&1.action == "item.moved"))
    assert length(moved) == 3

    assert Enum.all?(
             moved,
             &(&1.metadata["via"] == "api" and &1.metadata["tool"] == "catalogue.update_products")
           )
  end

  test "501 rows and an empty list are refused", %{catalogue: catalogue} do
    entries = for n <- 1..501, do: entry(%{"sku" => "S#{n}"}, %{"name" => "N"})

    assert {:error, :validation_failed, _, %{errors: [%{limit: 500}]}} =
             run_update(catalogue, entries)

    assert {:error, :validation_failed, _, _} = run_update(catalogue, [])
  end

  test "an upper-case category id moves, compares and previews like the lower-case one", %{
    catalogue: catalogue
  } do
    shelf = fixture_category(catalogue, %{name: "Shelf"})
    other = fixture_category(catalogue, %{name: "Other"})
    upper = String.upcase(shelf.uuid)
    a = item(catalogue, "Alpha")

    # a move, with another column changed in the same row
    assert [%{"action" => "updated"}] =
             rows(
               run_update(catalogue, [
                 entry(%{"id" => a.uuid}, %{"name" => "Alpha 2", "category_id" => upper})
               ])
             )

    reread = Catalogue.get_item!(a.uuid)
    assert {reread.name, reread.category_uuid} == {"Alpha 2", shelf.uuid}

    # the same category in the other case: nothing to do, not an error
    assert [%{"action" => "unchanged"}] =
             rows(run_update(catalogue, [entry(%{"id" => a.uuid}, %{"category_id" => upper})]))

    # the preview names the canonical ids
    assert {:preview, %{"rows" => [same]}, _} =
             run_update(catalogue, [entry(%{"id" => a.uuid}, %{"category_id" => upper})], %{
               dry_run?: true
             })

    assert same["action"] == "unchanged"

    assert {:preview, %{"rows" => [row]}, _} =
             run_update(
               catalogue,
               [entry(%{"id" => a.uuid}, %{"category_id" => String.upcase(other.uuid)})],
               %{dry_run?: true}
             )

    assert row["changes"]["category_id"] == %{"from" => shelf.uuid, "to" => other.uuid}
  end

  test "an archived catalogue is refused and nothing is written" do
    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "Archived to update"})
    a = item(catalogue, "Alpha")
    {:ok, archived} = Catalogue.update_catalogue(catalogue, %{status: "archived"})

    assert {:error, :validation_failed, message, %{errors: [%{path: "catalogue_id"}]}} =
             run_update(archived, [entry(%{"id" => a.uuid}, %{"name" => "Alpha 2"})])

    assert message =~ "archived"
    assert Catalogue.get_item!(a.uuid).name == "Alpha"
    refute_activity_logged("item.updated", resource_uuid: a.uuid)
  end

  test "a blank sku in changes is a row error and writes nothing; null clears it", %{
    catalogue: catalogue
  } do
    a = item(catalogue, "Alpha", %{sku: "KEEP"})

    assert [%{"action" => "error", "error" => %{"code" => "validation_failed"}}] =
             rows(
               run_update(catalogue, [entry(%{"id" => a.uuid}, %{"sku" => "   ", "name" => "X"})])
             )

    reread = Catalogue.get_item!(a.uuid)
    assert {reread.name, reread.sku} == {"Alpha", "KEEP"}

    assert [%{"action" => "updated"}] =
             rows(run_update(catalogue, [entry(%{"id" => a.uuid}, %{"sku" => nil})]))

    assert Catalogue.get_item!(a.uuid).sku == nil
  end

  test "when every row is rejected at planning, nothing is written and no transaction is opened",
       %{
         catalogue: catalogue
       } do
    {result, sql} =
      QueryHook.queries(fn ->
        run_update(catalogue, [entry(%{"sku" => "NOPE"}, %{"name" => "X"})])
      end)

    assert {:ok, %{"summary" => %{"error" => 1}}} = result
    refute Enum.any?(sql, &(&1 =~ ~r/^(begin|savepoint)/i)), inspect(sql)
  end

  describe "a world that changes between planning and writing" do
    test "an item trashed meanwhile is a not_found row that says whether its columns were stored",
         %{catalogue: catalogue} do
      a = item(catalogue, "Alpha")
      b = item(catalogue, "Beta")
      :ok = PubSub.subscribe()
      flush()

      result =
        QueryHook.after_query(
          ~s(SELECT p0."category_uuid" FROM "phoenix_kit_cat_items"),
          fn -> {:ok, _} = Catalogue.trash_item(Catalogue.get_item!(a.uuid)) end,
          fn ->
            run_update(catalogue, [
              entry(%{"id" => a.uuid}, %{"name" => "Alpha 2"}),
              entry(%{"id" => b.uuid}, %{"name" => "Beta 2"})
            ])
          end
        )

      assert [trashed, ok] = rows(result)
      assert trashed["action"] == "error"
      assert trashed["error"]["code"] == "not_found"
      assert trashed["id"] == a.uuid
      assert ok["action"] == "updated"
      assert {:ok, %{"summary" => %{"error" => 1, "updated" => 1}}} = result

      # The row stays in the trash. The column write is the one `update_item/3` makes
      # on a trashed row (it stores the fields, keeps the status): the row says so.
      reread = Catalogue.get_item!(a.uuid)
      assert {reread.status, reread.name} == {"deleted", "Alpha 2"}
      assert trashed["error"]["context"] == %{"saved" => true}

      cat_uuid = catalogue.uuid
      assert_receive {:catalogue_bulk_change, ^cat_uuid, :updated, uuids, _from}
      assert Enum.sort(uuids) == Enum.sort([a.uuid, b.uuid])
    end

    test "a category trashed after planning fails the move, keeps the saved columns and announces the item",
         %{catalogue: catalogue} do
      shelf = fixture_category(catalogue, %{name: "Doomed shelf"})
      a = item(catalogue, "Alpha")
      :ok = PubSub.subscribe()
      flush()

      result =
        QueryHook.after_query(
          ~s(UPDATE "phoenix_kit_cat_items"),
          fn -> {:ok, _} = Catalogue.trash_category(Catalogue.get_category(shelf.uuid)) end,
          fn ->
            run_update(catalogue, [
              entry(%{"id" => a.uuid}, %{"name" => "Alpha 2", "category_id" => shelf.uuid})
            ])
          end
        )

      assert [row] = rows(result)
      assert row["action"] == "error"
      assert row["id"] == a.uuid
      assert row["error"]["code"] == "validation_failed"
      assert row["error"]["context"] == %{"saved" => true, "reason" => "category_not_found"}
      assert row["error"]["message"] =~ "category was not changed"
      refute row["error"]["message"] =~ ":category_not_found"

      reread = Catalogue.get_item!(a.uuid)
      assert {reread.name, reread.category_uuid} == {"Alpha 2", nil}

      cat_uuid = catalogue.uuid
      assert_receive {:catalogue_bulk_change, ^cat_uuid, :updated, [uuid], _from}
      assert uuid == a.uuid
    end

    test "a move that finds nothing saved before it reports saved false and announces nothing",
         %{catalogue: catalogue} do
      shelf = fixture_category(catalogue, %{name: "Doomed shelf"})
      a = item(catalogue, "Alpha")
      :ok = PubSub.subscribe()
      flush()

      result =
        QueryHook.after_query(
          ~s(SELECT p0."category_uuid" FROM "phoenix_kit_cat_items"),
          fn -> {:ok, _} = Catalogue.trash_category(Catalogue.get_category(shelf.uuid)) end,
          fn ->
            run_update(catalogue, [entry(%{"id" => a.uuid}, %{"category_id" => shelf.uuid})])
          end
        )

      assert [%{"action" => "error", "error" => %{"context" => %{"saved" => false}}}] =
               rows(result)

      refute_receive {:catalogue_bulk_change, _, _, _, _}, 50
    end

    test "a category re-homed to another catalogue after planning is reported, not silent", %{
      catalogue: catalogue
    } do
      other = fixture_catalogue(%{name: "Other home"})
      shelf = fixture_category(catalogue, %{name: "Wandering shelf"})
      a = item(catalogue, "Alpha")
      :ok = PubSub.subscribe()
      flush()

      result =
        QueryHook.after_query(
          ~s(UPDATE "phoenix_kit_cat_items"),
          fn ->
            {:ok, _} =
              Catalogue.move_category_to_catalogue(Catalogue.get_category(shelf.uuid), other.uuid)
          end,
          fn ->
            run_update(catalogue, [
              entry(%{"id" => a.uuid}, %{"name" => "Alpha 2", "category_id" => shelf.uuid})
            ])
          end
        )

      assert [row] = rows(result)
      assert row["action"] == "error"
      assert row["error"]["context"] == %{"saved" => true, "reason" => "catalogue_changed"}
      assert row["error"]["message"] =~ "another catalogue"

      # both catalogues are told, the old one by the batch announcement
      cat_uuid = catalogue.uuid
      other_uuid = other.uuid
      assert_receive {:catalogue_bulk_change, ^other_uuid, :updated, [_], _from}
      assert_receive {:catalogue_bulk_change, ^cat_uuid, :updated, [_], _from}
    end
  end

  describe "a sku another live item of the catalogue holds" do
    test "is a sku_taken row with the holder's id; the rest apply, the row writes nothing", %{
      catalogue: catalogue
    } do
      holder = item(catalogue, "Holder", %{sku: "TAKEN"})
      a = item(catalogue, "Alpha", %{sku: "A-OLD"})
      b = item(catalogue, "Beta")

      result =
        run_update(catalogue, [
          entry(%{"id" => a.uuid}, %{"sku" => "TAKEN", "name" => "Alpha 2"}),
          entry(%{"id" => b.uuid}, %{"sku" => "B-NEW"})
        ])

      assert [taken, fine] = rows(result)
      assert taken["action"] == "error"
      assert taken["error"]["code"] == "sku_taken"
      assert taken["error"]["context"]["existing_id"] == holder.uuid
      assert fine["action"] == "updated"

      reread = Catalogue.get_item!(a.uuid)
      assert {reread.sku, reread.name} == {"A-OLD", "Alpha"}
      assert Catalogue.get_item!(b.uuid).sku == "B-NEW"
    end

    test "is no conflict when the item keeps its own sku, even if a twin already shares it", %{
      catalogue: catalogue
    } do
      a = item(catalogue, "Alpha", %{sku: "TWIN"})
      item(catalogue, "Twin", %{sku: "TWIN"})

      assert [row] =
               rows(
                 run_update(catalogue, [
                   entry(%{"id" => a.uuid}, %{"sku" => "TWIN", "name" => "A2"})
                 ])
               )

      assert row["action"] == "updated"
      assert Catalogue.get_item!(a.uuid).name == "A2"
    end

    test "does not count a trashed item or an item of another catalogue as a holder", %{
      catalogue: catalogue
    } do
      {:ok, _} = catalogue |> item("Trashed", %{sku: "T-1"}) |> Catalogue.trash_item()
      item(fixture_catalogue(%{name: "Elsewhere"}), "Foreign", %{sku: "F-1"})
      a = item(catalogue, "Alpha")
      b = item(catalogue, "Beta")

      result =
        run_update(catalogue, [
          entry(%{"id" => a.uuid}, %{"sku" => "T-1"}),
          entry(%{"id" => b.uuid}, %{"sku" => "F-1"})
        ])

      assert Enum.map(rows(result), & &1["action"]) == ["updated", "updated"]
    end

    test "is checked row by row: a released sku can be taken, a claimed one cannot", %{
      catalogue: catalogue
    } do
      a = item(catalogue, "Alpha", %{sku: "S-A"})
      b = item(catalogue, "Beta")
      c = item(catalogue, "Gamma")
      d = item(catalogue, "Delta")

      entries = [
        # a lets go of S-A and takes S-NEW
        entry(%{"id" => a.uuid}, %{"sku" => "S-NEW"}),
        # so b may take S-A
        entry(%{"id" => b.uuid}, %{"sku" => "S-A"}),
        # but c may not take S-NEW (a holds it now)
        entry(%{"id" => c.uuid}, %{"sku" => "S-NEW"}),
        # and d may not take S-A (b holds it now)
        entry(%{"id" => d.uuid}, %{"sku" => "S-A"})
      ]

      assert {:preview, %{"rows" => preview_rows}, _} =
               run_update(catalogue, entries, %{dry_run?: true})

      executed = rows(run_update(catalogue, entries))

      for answered <- [preview_rows, executed] do
        assert Enum.map(answered, & &1["action"]) == ["updated", "updated", "error", "error"]

        assert Enum.map(
                 Enum.drop(answered, 2),
                 &{&1["error"]["code"], &1["error"]["context"]["existing_id"]}
               ) ==
                 [{"sku_taken", a.uuid}, {"sku_taken", b.uuid}]
      end

      assert {Catalogue.get_item!(a.uuid).sku, Catalogue.get_item!(b.uuid).sku} ==
               {"S-NEW", "S-A"}

      assert Catalogue.get_item!(c.uuid).sku == nil
    end

    test "a sku one row clears can be taken by a later row", %{catalogue: catalogue} do
      a = item(catalogue, "Alpha", %{sku: "S-CLEAR"})
      b = item(catalogue, "Beta")

      entries = [
        entry(%{"id" => a.uuid}, %{"sku" => nil}),
        entry(%{"id" => b.uuid}, %{"sku" => "S-CLEAR"})
      ]

      assert {:preview, %{"rows" => preview_rows}, _} =
               run_update(catalogue, entries, %{dry_run?: true})

      executed = rows(run_update(catalogue, entries))

      for answered <- [preview_rows, executed],
          do: assert(Enum.map(answered, & &1["action"]) == ["updated", "updated"])

      assert {Catalogue.get_item!(a.uuid).sku, Catalogue.get_item!(b.uuid).sku} ==
               {nil, "S-CLEAR"}
    end

    test "answers the same in the preview as in the write", %{catalogue: catalogue} do
      holder = item(catalogue, "Holder", %{sku: "TAKEN"})
      a = item(catalogue, "Alpha")
      entries = [entry(%{"id" => a.uuid}, %{"sku" => "TAKEN"})]

      assert {:preview, %{"rows" => [taken], "summary" => %{"error" => 1}}, _} =
               run_update(catalogue, entries, %{dry_run?: true})

      assert taken["error"]["code"] == "sku_taken"
      assert taken["error"]["context"]["existing_id"] == holder.uuid
      assert Catalogue.get_item!(a.uuid).sku == nil
    end
  end

  describe "dry run" do
    test "previews the changes, writes nothing, and the fingerprint follows the state", %{
      catalogue: catalogue
    } do
      a = item(catalogue, "Alpha")

      entries = [
        entry(%{"id" => a.uuid}, %{"name" => "Alpha 2", "external_id" => "E-9"}),
        entry(%{"sku" => "NOPE"}, %{"name" => "X"})
      ]

      assert {:preview, %{"rows" => [row, missing], "summary" => %{"updated" => 1, "error" => 1}},
              fingerprint} =
               run_update(catalogue, entries, %{dry_run?: true})

      assert row["id"] == a.uuid

      assert row["changes"] == %{
               "name" => %{"from" => "Alpha", "to" => "Alpha 2"},
               "data.api.external_id" => %{"from" => "", "to" => "E-9"}
             }

      assert missing["error"]["code"] == "not_found"
      assert Catalogue.get_item!(a.uuid).name == "Alpha"
      refute_activity_logged("item.updated", resource_uuid: a.uuid)

      assert {:preview, _, ^fingerprint} = run_update(catalogue, entries, %{dry_run?: true})

      {:ok, _} = Catalogue.update_item(Catalogue.get_item!(a.uuid), %{name: "Changed meanwhile"})
      assert {:preview, _, other} = run_update(catalogue, entries, %{dry_run?: true})
      assert other != fingerprint
    end

    test "shows a category move; naming the same item twice is refused in the preview too", %{
      catalogue: catalogue
    } do
      shelf = fixture_category(catalogue, %{name: "Shelf"})
      a = item(catalogue, "Alpha")

      assert {:preview, %{"rows" => [moved, same]}, _} =
               run_update(
                 catalogue,
                 [
                   entry(%{"id" => a.uuid}, %{"category_id" => shelf.uuid}),
                   entry(%{"id" => a.uuid}, %{"name" => "Alpha"})
                 ],
                 %{dry_run?: true}
               )

      assert moved["changes"]["category_id"] == %{"from" => "", "to" => shelf.uuid}
      # the second row names the same item again: the plan refuses it
      assert same["action"] == "error"
      assert same["error"]["code"] == "validation_failed"
    end

    test "an external_id another live item holds is an already_exists row, like the write will say",
         %{catalogue: catalogue} do
      holder = item(catalogue, "Holder", %{data: %{"api" => %{"external_id" => "TAKEN"}}})
      a = item(catalogue, "Alpha")
      b = item(catalogue, "Beta", %{data: %{"api" => %{"external_id" => "MINE"}}})

      entries = [
        entry(%{"id" => a.uuid}, %{"external_id" => "TAKEN"}),
        # b keeps its own id: not a conflict
        entry(%{"id" => b.uuid}, %{"external_id" => "MINE", "name" => "Beta 2"})
      ]

      assert {:preview, %{"rows" => [taken, mine], "summary" => %{"error" => 1, "updated" => 1}},
              _} =
               run_update(catalogue, entries, %{dry_run?: true})

      assert taken["action"] == "error"
      assert taken["error"]["code"] == "already_exists"
      assert taken["error"]["context"]["existing_id"] == holder.uuid
      assert mine["action"] == "updated"

      # ... and the real write gives the same answer for the same rows
      assert [executed_taken, _] = rows(run_update(catalogue, entries))
      assert executed_taken["error"]["code"] == taken["error"]["code"]
      assert executed_taken["error"]["context"]["existing_id"] == holder.uuid
    end

    test "the preview walks the rows in order: a released id can be taken, a claimed one cannot",
         %{catalogue: catalogue} do
      a = item(catalogue, "Alpha", %{data: %{"api" => %{"external_id" => "E-A"}}})
      b = item(catalogue, "Beta")
      c = item(catalogue, "Gamma")
      d = item(catalogue, "Delta")

      entries = [
        # a lets go of E-A and takes E-NEW
        entry(%{"id" => a.uuid}, %{"external_id" => "E-NEW"}),
        # so b may take E-A
        entry(%{"id" => b.uuid}, %{"external_id" => "E-A"}),
        # but c may not take E-NEW (a holds it now)
        entry(%{"id" => c.uuid}, %{"external_id" => "E-NEW"}),
        # and d may not take E-A (b holds it now)
        entry(%{"id" => d.uuid}, %{"external_id" => "E-A"})
      ]

      assert {:preview, %{"rows" => preview_rows}, _} =
               run_update(catalogue, entries, %{dry_run?: true})

      assert Enum.map(preview_rows, & &1["action"]) == ["updated", "updated", "error", "error"]

      assert Enum.map(Enum.drop(preview_rows, 2), & &1["error"]["code"]) == [
               "already_exists",
               "already_exists"
             ]

      assert Enum.map(Enum.drop(preview_rows, 2), & &1["error"]["context"]["existing_id"]) == [
               a.uuid,
               b.uuid
             ]

      # the real write ends the same way
      executed = rows(run_update(catalogue, entries))
      assert Enum.map(executed, & &1["action"]) == Enum.map(preview_rows, & &1["action"])
    end
  end

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end
end
