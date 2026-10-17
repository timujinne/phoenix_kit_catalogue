defmodule PhoenixKitCatalogue.API.CreateProductsTest do
  @moduledoc "`catalogue.create_products`."

  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase, only: [fixture_catalogue: 1, fixture_category: 2]

  alias PhoenixKitCatalogue.API.CreateProducts
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.PubSub
  alias PhoenixKitCatalogue.Test.{ApiCase, QueryHook}

  @tool "catalogue.create_products"

  setup do
    %{catalogue: fixture_catalogue(%{name: "Create Cat"})}
  end

  defp create(catalogue, items, overrides \\ %{}),
    do: ApiCase.call(@tool, %{"catalogue_id" => catalogue.uuid, "items" => items}, overrides)

  defp rows({:ok, %{"results" => rows}}), do: rows

  test "creates an item with no price and no shop data, and logs it as an API write",
       %{catalogue: catalogue} do
    category = fixture_category(catalogue, %{name: "Shelf"})

    result =
      create(catalogue, [
        %{
          "external_id" => "E-1",
          "sku" => "SKU-1",
          "name" => "Oak panel",
          "description" => "Solid oak",
          "category_id" => category.uuid,
          "status" => "inactive",
          "unit" => "sheet"
        }
      ])

    assert {:ok, %{"results" => [row], "summary" => %{"created" => 1}}} = result
    assert row["action"] == "created"
    assert row["ref"] == %{"external_id" => "E-1", "sku" => "SKU-1"}

    item = Catalogue.get_item!(row["id"])
    assert item.name == "Oak panel"
    assert item.sku == "SKU-1"
    assert item.description == "Solid oak"
    assert item.status == "inactive"
    assert item.unit == "sheet"
    assert item.category_uuid == category.uuid
    assert item.catalogue_uuid == catalogue.uuid
    assert item.base_price == nil
    # No price, and an explicit draft so the shop (which reads a missing
    # shop_status as "active") does not list the new item.
    assert item.data == %{
             "api" => %{"external_id" => "E-1"},
             "ecommerce" => %{"shop_status" => "draft"}
           }

    log =
      assert_activity_logged("item.created",
        resource_uuid: item.uuid,
        actor_uuid: ApiCase.user_uuid()
      )

    assert log.mode == "auto"
    assert log.metadata["via"] == "api"
    assert log.metadata["tool"] == "catalogue.create_products"
    assert log.metadata["key_prefix"] == "abcd1234"
  end

  test "every created item is a shop draft, with or without an external_id", %{
    catalogue: catalogue
  } do
    # The shop reads a missing data["ecommerce"]["shop_status"] as "active".
    # With status "active" (the default) the draft marker is the only thing
    # that keeps a price-less new item out of the storefront.
    rows =
      rows(
        create(catalogue, [
          %{"sku" => "D-1", "name" => "Sku only"},
          %{"external_id" => "D-2", "name" => "Eid only", "status" => "active"}
        ])
      )

    for %{"id" => id} <- rows do
      item = Catalogue.get_item!(id)
      assert item.status in ["active", "inactive"]
      assert get_in(item.data, ["ecommerce", "shop_status"]) == "draft"
      assert item.base_price == nil
    end

    assert [sku_only, eid_only] = Enum.map(rows, &Catalogue.get_item!(&1["id"]))
    assert sku_only.data == %{"ecommerce" => %{"shop_status" => "draft"}}
    assert eid_only.data["api"] == %{"external_id" => "D-2"}
    assert eid_only.status == "active"
  end

  test "generates a slug from the name, and the second equal name gets -2", %{
    catalogue: catalogue
  } do
    rows =
      rows(
        create(catalogue, [
          %{"sku" => "A", "name" => "Oak Panel"},
          %{"sku" => "B", "name" => "Oak Panel"}
        ])
      )

    slugs = for %{"id" => id} <- rows, do: Catalogue.get_item!(id).slug |> Map.values() |> hd()
    assert Enum.sort(slugs) == ["oak-panel", "oak-panel-2"]
  end

  describe "slugs for many equal names" do
    # A candidate probe is the only statement that reads the slug projection.
    defp slug_probes(queries), do: Enum.count(queries, &(&1 =~ "item_slugs"))

    defp slug_of(id), do: Catalogue.get_item!(id).slug |> Map.values() |> hd()

    test "a request of equal names probes the slugs about once per row", %{catalogue: catalogue} do
      count = 100
      items = for n <- 1..count, do: %{"sku" => "S-#{n}", "name" => "Oak Panel"}

      {result, queries} = QueryHook.queries(fn -> create(catalogue, items) end)

      rows = rows(result)
      slugs = Enum.map(rows, &slug_of(&1["id"]))
      assert Enum.uniq(slugs) |> length() == count
      assert "oak-panel" in slugs and "oak-panel-#{count}" in slugs
      # One walk per row would be count * (count + 1) / 2 = 5050 probes.
      assert slug_probes(queries) <= 2 * count
    end

    test "slugs already in the database are probed once, not once per row", %{
      catalogue: catalogue
    } do
      existing = 30

      for n <- 1..existing do
        {:ok, _} =
          Catalogue.create_item(%{
            name: "Oak Panel",
            catalogue_uuid: catalogue.uuid,
            slug: %{"en-US" => if(n == 1, do: "oak-panel", else: "oak-panel-#{n}")}
          })
      end

      items = for n <- 1..existing, do: %{"sku" => "S-#{n}", "name" => "Oak Panel"}

      {result, queries} = QueryHook.queries(fn -> create(catalogue, items) end)

      slugs = result |> rows() |> Enum.map(&slug_of(&1["id"]))
      assert Enum.uniq(slugs) |> length() == existing

      assert Enum.all?(
               slugs,
               &(&1 not in ["oak-panel" | for(n <- 2..existing, do: "oak-panel-#{n}")])
             )

      # The walk over the 30 stored slugs happens once; without the request's
      # memory it repeats for every row (30 * 31 probes).
      assert slug_probes(queries) <= 4 * existing
    end
  end

  test "an existing external_id or sku is skipped, never overwritten", %{catalogue: catalogue} do
    {:ok, by_eid} =
      Catalogue.create_item(%{
        name: "Original",
        catalogue_uuid: catalogue.uuid,
        data: %{"api" => %{"external_id" => "E-1"}}
      })

    {:ok, by_sku} =
      Catalogue.create_item(%{name: "Has sku", catalogue_uuid: catalogue.uuid, sku: "S-1"})

    rows =
      rows(
        create(catalogue, [
          %{"external_id" => "E-1", "name" => "Replacement"},
          %{"sku" => "S-1", "name" => "Replacement 2"},
          %{"sku" => "S-NEW", "name" => "Brand new"}
        ])
      )

    assert [skipped_eid, skipped_sku, created] = rows
    assert skipped_eid["action"] == "skipped"
    assert skipped_eid["error"]["code"] == "already_exists"
    assert skipped_eid["error"]["context"]["existing_id"] == by_eid.uuid
    assert skipped_sku["error"]["context"]["existing_id"] == by_sku.uuid
    assert created["action"] == "created"

    assert Catalogue.get_item!(by_eid.uuid).name == "Original"
    assert Catalogue.get_item!(by_sku.uuid).name == "Has sku"
  end

  test "the same identifier twice in one request skips the later row", %{catalogue: catalogue} do
    rows =
      rows(
        create(catalogue, [
          %{"external_id" => "E-2", "name" => "First"},
          %{"external_id" => "E-2", "name" => "Second"},
          %{"sku" => "S-2", "name" => "Third"},
          %{"sku" => "S-2", "name" => "Fourth"}
        ])
      )

    assert Enum.map(rows, & &1["action"]) == ["created", "skipped", "created", "skipped"]
    assert Enum.at(rows, 1)["error"]["code"] == "already_exists"
  end

  test "an id that belongs to a trashed item is free", %{catalogue: catalogue} do
    {:ok, old} =
      Catalogue.create_item(%{
        name: "Old",
        catalogue_uuid: catalogue.uuid,
        data: %{"api" => %{"external_id" => "E-3"}}
      })

    {:ok, _} = Catalogue.trash_item(old)

    assert [%{"action" => "created", "id" => id}] =
             rows(create(catalogue, [%{"external_id" => "E-3", "name" => "New"}]))

    assert id != old.uuid
  end

  test "an id taken between the check and the insert is skipped, not an exception",
       %{catalogue: catalogue} do
    # Plan while the id is free, let a rival write it, then execute the stale plan.
    # This simulates the race deterministically (the sandbox cannot run two real
    # writers against one unique index); two truly simultaneous requests need a
    # live check.
    plan =
      CreateProducts.plan(
        [%{"external_id" => "E-4", "name" => "Late"}],
        catalogue
      )

    assert [{:create, _, _, _}] = plan

    {:ok, rival} =
      Catalogue.create_item(%{
        name: "Rival",
        catalogue_uuid: catalogue.uuid,
        data: %{"api" => %{"external_id" => "E-4"}}
      })

    assert {:ok, %{"results" => [row]}} =
             CreateProducts.execute(plan, catalogue, ApiCase.ctx())

    assert row["action"] == "skipped"
    assert row["error"]["code"] == "already_exists"
    assert row["error"]["context"]["existing_id"] == rival.uuid
    assert Catalogue.get_item!(rival.uuid).name == "Rival"
  end

  test "a row needs a name, and an identifier; bad rows do not stop the others", %{
    catalogue: catalogue
  } do
    category = fixture_category(create_other_catalogue(), %{name: "Foreign shelf"})

    rows =
      rows(
        create(catalogue, [
          %{"sku" => "OK-1", "name" => "Fine"},
          %{"sku" => "BAD-1", "name" => "   "},
          %{"name" => "No identifier"},
          %{"sku" => "BAD-2", "name" => "Wrong category", "category_id" => category.uuid},
          %{
            "sku" => "BAD-3",
            "name" => "Missing category",
            "category_id" => Ecto.UUID.generate()
          },
          %{"sku" => "OK-2", "name" => "Fine too"}
        ])
      )

    assert Enum.map(rows, & &1["action"]) ==
             ["created", "error", "error", "error", "error", "created"]

    assert Enum.all?(Enum.slice(rows, 1, 4), &(&1["error"]["code"] == "validation_failed"))

    paths = rows |> Enum.at(3) |> get_in(["error", "context", "errors"]) |> Enum.map(& &1["path"])
    assert "category_id" in paths

    assert Catalogue.list_items_for_catalogue(catalogue.uuid)
           |> Enum.map(& &1.sku)
           |> Enum.sort() == ["OK-1", "OK-2"]
  end

  test "an upper-case category_id files the item under that category", %{catalogue: catalogue} do
    category = fixture_category(catalogue, %{name: "Upper shelf"})

    assert [%{"action" => "created", "id" => id}] =
             rows(
               create(catalogue, [
                 %{
                   "sku" => "UPPER-1",
                   "name" => "Filed",
                   "category_id" => String.upcase(category.uuid)
                 }
               ])
             )

    assert Catalogue.get_item!(id).category_uuid == category.uuid
  end

  test "a malformed category_id, a short id and blank name/sku/external_id are row errors, not one 422",
       %{catalogue: catalogue} do
    # Row-level fields have no length floor in the schema (`Schemas.row_id/0`,
    # `row_text/1`): each of these reaches the handler and fails THAT row only.
    result =
      create(catalogue, [
        %{"sku" => "G-1", "name" => "Good one"},
        %{"sku" => "G-BAD-CAT", "name" => "Bad category", "category_id" => "short"},
        %{"sku" => "G-BAD-NAME", "name" => ""},
        %{"sku" => "", "name" => "Blank sku"},
        %{"external_id" => "", "name" => "Blank external id"},
        %{"sku" => "G-2", "name" => "Good two"}
      ])

    assert {:ok, %{"results" => rows, "summary" => %{"created" => 2, "error" => 4}}} = result

    assert Enum.map(rows, & &1["action"]) ==
             ["created", "error", "error", "error", "error", "created"]

    assert Enum.all?(Enum.slice(rows, 1, 4), &(&1["error"]["code"] == "validation_failed"))

    assert Catalogue.list_items_for_catalogue(catalogue.uuid)
           |> Enum.map(& &1.sku)
           |> Enum.sort() == ["G-1", "G-2"]
  end

  defp create_other_catalogue, do: fixture_catalogue(%{name: "Other Create Cat"})

  test "schema refuses price, markup, discount and raw data", %{catalogue: catalogue} do
    for field <- ~w(base_price markup_percentage discount_percentage data cost_per_item) do
      assert {:error, :validation_failed, _, %{errors: errors}} =
               create(catalogue, [%{"sku" => "S", "name" => "N", field => 1}]),
             "#{field} was accepted"

      assert Enum.any?(errors, &(&1.path == "items[0].#{field}")), "#{field}: #{inspect(errors)}"
    end
  end

  test "more than 500 rows and an empty list are refused", %{catalogue: catalogue} do
    items = for n <- 1..501, do: %{"sku" => "S#{n}", "name" => "N#{n}"}
    assert {:error, :validation_failed, _, %{errors: [%{limit: 500}]}} = create(catalogue, items)
    assert {:error, :validation_failed, _, _} = create(catalogue, [])
  end

  test "an archived or smart catalogue is refused" do
    {:ok, archived} = Catalogue.create_catalogue(%{name: "Archived"})
    {:ok, archived} = Catalogue.update_catalogue(archived, %{status: "archived"})

    assert {:error, :validation_failed, message, _} =
             create(archived, [%{"sku" => "S", "name" => "N"}])

    assert message =~ "archived"
  end

  test "creating announces one bulk event and no per-row events", %{catalogue: catalogue} do
    :ok = PubSub.subscribe()
    flush()

    result =
      create(catalogue, [%{"sku" => "B-1", "name" => "One"}, %{"sku" => "B-2", "name" => "Two"}])

    created = for %{"id" => id} <- rows(result), do: id

    cat_uuid = catalogue.uuid
    assert_receive {:catalogue_bulk_change, ^cat_uuid, :created, uuids, _from}
    assert Enum.sort(uuids) == Enum.sort(created)
    # one data-changed event for the catalogue index, not one per row
    assert_receive {:catalogue_data_changed, :item, nil, ^cat_uuid}
    refute_receive {:catalogue_data_changed, _, _, _}, 50
  end

  test "a dry run writes nothing and previews creates and skips", %{catalogue: catalogue} do
    {:ok, existing} =
      Catalogue.create_item(%{name: "Present", catalogue_uuid: catalogue.uuid, sku: "S-1"})

    before = length(Catalogue.list_items_for_catalogue(catalogue.uuid))

    items = [%{"sku" => "S-1", "name" => "Dup"}, %{"sku" => "S-2", "name" => "Fresh"}]

    assert {:preview, %{"rows" => [skipped, would_create], "summary" => summary}, fingerprint} =
             create(catalogue, items, %{dry_run?: true})

    assert skipped["action"] == "skipped"
    assert skipped["error"]["context"]["existing_id"] == existing.uuid
    assert would_create["action"] == "created"
    assert would_create["id"] == nil
    assert would_create["fields"]["name"] == "Fresh"
    assert summary == %{"skipped" => 1, "created" => 1}
    assert length(Catalogue.list_items_for_catalogue(catalogue.uuid)) == before

    assert {:preview, _, ^fingerprint} = create(catalogue, items, %{dry_run?: true})

    {:ok, _} =
      Catalogue.create_item(%{name: "Now present", catalogue_uuid: catalogue.uuid, sku: "S-2"})

    assert {:preview, _, other} = create(catalogue, items, %{dry_run?: true})
    assert other != fingerprint
  end

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end
end
