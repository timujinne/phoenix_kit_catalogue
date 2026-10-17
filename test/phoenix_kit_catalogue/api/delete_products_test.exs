defmodule PhoenixKitCatalogue.API.DeleteProductsTest do
  @moduledoc "`catalogue.delete_products`."

  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase, only: [fixture_catalogue: 1, fixture_item: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.PubSub
  alias PhoenixKitCatalogue.Test.{ApiCase, QueryHook}

  @tool "catalogue.delete_products"

  setup do
    %{catalogue: fixture_catalogue(%{name: "Delete Cat"})}
  end

  defp item(catalogue, name, extra \\ %{}),
    do: fixture_item(Map.merge(%{name: name, catalogue_uuid: catalogue.uuid}, extra))

  defp delete(catalogue, refs, overrides \\ %{}),
    do: ApiCase.call(@tool, %{"catalogue_id" => catalogue.uuid, "refs" => refs}, overrides)

  defp rows({:ok, %{"results" => rows}}), do: rows
  defp rows_of({:preview, %{"rows" => rows}, _fingerprint}), do: rows
  defp rows_of(result), do: rows(result)

  test "the tool is declared dangerous, destructive and under its own scope" do
    tool = ApiCase.tool!(@tool)

    assert tool.danger == :always
    assert tool.scope == "catalogue.products:delete"
    assert tool.permission == "catalogue"
    assert tool.annotations.destructive
    assert tool.annotations.idempotent
    assert tool.max_items == 500
  end

  test "trashes by id, sku and external_id; restore_item brings them back", %{
    catalogue: catalogue
  } do
    a = item(catalogue, "Alpha")
    b = item(catalogue, "Beta", %{sku: "SKU-B"})
    c = item(catalogue, "Gamma", %{data: %{"api" => %{"external_id" => "E-C"}}})

    result =
      delete(catalogue, [%{"id" => a.uuid}, %{"sku" => "SKU-B"}, %{"external_id" => "E-C"}])

    assert {:ok, %{"summary" => %{"removed" => 3}}} = result
    assert result |> rows() |> Enum.map(& &1["id"]) == [a.uuid, b.uuid, c.uuid]

    for i <- [a, b, c] do
      trashed = Catalogue.get_item!(i.uuid)
      assert trashed.status == "deleted"
      assert trashed.data["_trash"]["via"] == "self"
    end

    assert {:ok, restored} = Catalogue.restore_item(Catalogue.get_item!(a.uuid))
    assert restored.status == "active"

    log =
      assert_activity_logged("item.trashed",
        resource_uuid: b.uuid,
        actor_uuid: ApiCase.user_uuid()
      )

    assert log.mode == "auto"
    assert log.metadata["via"] == "api"
    assert log.metadata["tool"] == "catalogue.delete_products"
  end

  test "nothing is ever hard-deleted", %{catalogue: catalogue} do
    a = item(catalogue, "Alpha")
    assert {:ok, %{"summary" => %{"removed" => 1}}} = delete(catalogue, [%{"id" => a.uuid}])

    assert %{status: "deleted"} = Catalogue.get_item(a.uuid)
    refute_activity_logged("item.permanently_deleted", resource_uuid: a.uuid)
  end

  test "a retry is unchanged for an item already in the trash, whichever reference it uses", %{
    catalogue: catalogue
  } do
    a = item(catalogue, "Alpha", %{sku: "SKU-A", data: %{"api" => %{"external_id" => "E-A"}}})
    {:ok, _} = Catalogue.trash_item(a)

    refs = [%{"id" => a.uuid}, %{"sku" => "SKU-A"}, %{"external_id" => "E-A"}]

    for mode <- [%{}, %{dry_run?: true}] do
      result = delete(catalogue, refs, mode)
      rows = rows_of(result)

      assert Enum.map(rows, & &1["action"]) == ["unchanged", "unchanged", "unchanged"]
      assert Enum.map(rows, & &1["id"]) == [a.uuid, a.uuid, a.uuid]
    end

    assert Catalogue.get_item!(a.uuid).status == "deleted"
  end

  test "a reference that names nothing, live or trashed, is still not found", %{
    catalogue: catalogue
  } do
    other = fixture_catalogue(%{name: "Other Delete Cat"})
    foreign = item(other, "Foreign", %{sku: "SKU-F", data: %{"api" => %{"external_id" => "E-F"}}})
    {:ok, _} = Catalogue.trash_item(foreign)

    refs = [
      %{"id" => foreign.uuid},
      %{"sku" => "SKU-F"},
      %{"external_id" => "E-F"},
      %{"id" => "not-a-uuid"},
      %{"sku" => "NOPE"}
    ]

    assert refs |> then(&delete(catalogue, &1)) |> rows() |> Enum.map(& &1["error"]["code"]) ==
             List.duplicate("not_found", 5)
  end

  test "a sku shared by several trashed items stays not found (nothing says which one)", %{
    catalogue: catalogue
  } do
    for name <- ["One", "Two"] do
      {:ok, _} = catalogue |> item(name, %{sku: "SKU-DUP"}) |> Catalogue.trash_item()
    end

    assert [%{"error" => %{"code" => "not_found"}}] =
             rows(delete(catalogue, [%{"sku" => "SKU-DUP"}]))
  end

  test "an item someone else trashed after the request was planned is unchanged", %{
    catalogue: catalogue
  } do
    a = item(catalogue, "Alpha")
    :ok = PubSub.subscribe()
    flush()

    # The other writer's trash lands between planning and this call's own.
    result =
      QueryHook.after_query(
        ~r/pg_advisory_xact_lock/,
        fn -> {:ok, _} = Catalogue.trash_item(Catalogue.get_item!(a.uuid)) end,
        fn -> delete(catalogue, [%{"id" => a.uuid}]) end
      )

    assert [row] = rows(result)
    assert row["action"] == "unchanged"
    assert row["id"] == a.uuid
    assert Catalogue.get_item!(a.uuid).status == "deleted"
    # One entry: the other writer's, none for this call.
    assert_activity_logged("item.trashed", resource_uuid: a.uuid)
    # Nothing was trashed by the request, so nothing is announced as trashed.
    refute_receive {:catalogue_bulk_change, _, :trashed, _, _}, 50
  end

  test "bad rows are reported at their position and never poison the others", %{
    catalogue: catalogue
  } do
    a = item(catalogue, "Alpha")
    b = item(catalogue, "Beta")
    item(catalogue, "Twin 1", %{sku: "TWIN"})
    item(catalogue, "Twin 2", %{sku: "TWIN"})
    foreign = item(fixture_catalogue(%{name: "Elsewhere"}), "Foreign")

    result =
      delete(catalogue, [
        %{"id" => a.uuid},
        %{"sku" => "TWIN"},
        %{"id" => "not-a-uuid"},
        %{},
        %{"id" => a.uuid},
        %{"id" => foreign.uuid},
        %{"id" => b.uuid}
      ])

    rows = rows(result)

    assert Enum.map(rows, & &1["action"]) ==
             ["removed", "error", "error", "error", "error", "error", "removed"]

    assert Enum.map(rows, &get_in(&1, ["error", "code"])) ==
             [
               nil,
               "ambiguous_ref",
               "not_found",
               "validation_failed",
               "validation_failed",
               "not_found",
               nil
             ]

    assert Catalogue.get_item!(a.uuid).status == "deleted"
    assert Catalogue.get_item!(b.uuid).status == "deleted"
    assert Catalogue.get_item!(foreign.uuid).status == "active"
  end

  test "a batch announces one :trashed event and no per-row events", %{catalogue: catalogue} do
    a = item(catalogue, "Alpha")
    b = item(catalogue, "Beta")
    :ok = PubSub.subscribe()
    flush()

    {:ok, _} = delete(catalogue, [%{"id" => a.uuid}, %{"id" => b.uuid}])

    cat_uuid = catalogue.uuid
    assert_receive {:catalogue_bulk_change, ^cat_uuid, :trashed, uuids, _from}
    assert Enum.sort(uuids) == Enum.sort([a.uuid, b.uuid])
    refute_receive {:catalogue_bulk_change, _, _, _, _}, 50
    assert_receive {:catalogue_data_changed, :item, nil, ^cat_uuid}
    refute_receive {:catalogue_data_changed, _, _, _}, 50
  end

  test "a deleted item frees its external_id; restoring it afterwards is a clean refusal",
       %{catalogue: catalogue} do
    a = item(catalogue, "Alpha", %{data: %{"api" => %{"external_id" => "E-1"}}})

    assert {:ok, %{"summary" => %{"removed" => 1}}} =
             delete(catalogue, [%{"external_id" => "E-1"}])

    assert {:ok, %{"summary" => %{"created" => 1}}} =
             ApiCase.call("catalogue.create_products", %{
               "catalogue_id" => catalogue.uuid,
               "items" => [%{"external_id" => "E-1", "name" => "Alpha again"}]
             })

    assert {:error, :external_id_taken} = Catalogue.restore_item(Catalogue.get_item!(a.uuid))
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

    refs = for n <- 1..501, do: %{"sku" => "S#{n}"}
    assert {:error, :validation_failed, _, %{errors: [%{limit: 500}]}} = delete(catalogue, refs)
  end

  describe "dry run" do
    test "previews what would go, trashes nothing, and the fingerprint follows the state", %{
      catalogue: catalogue
    } do
      a = item(catalogue, "Alpha")
      refs = [%{"id" => a.uuid}, %{"sku" => "NOPE"}]

      assert {:preview,
              %{
                "requires_confirmation" => true,
                "rows" => [row, missing],
                "summary" => %{"removed" => 1, "error" => 1}
              }, fingerprint} =
               delete(catalogue, refs, %{dry_run?: true})

      assert row["id"] == a.uuid
      assert row["name"] == "Alpha"
      assert row["changes"] == %{"status" => %{"from" => "active", "to" => "deleted"}}
      assert missing["error"]["code"] == "not_found"

      assert Catalogue.get_item!(a.uuid).status == "active"
      refute_activity_logged("item.trashed", resource_uuid: a.uuid)

      assert {:preview, _, ^fingerprint} = delete(catalogue, refs, %{dry_run?: true})

      {:ok, _} = Catalogue.update_item(Catalogue.get_item!(a.uuid), %{status: "inactive"})
      assert {:preview, _, other} = delete(catalogue, refs, %{dry_run?: true})
      assert other != fingerprint
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
