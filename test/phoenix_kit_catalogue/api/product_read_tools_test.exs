defmodule PhoenixKitCatalogue.API.ProductReadToolsTest do
  @moduledoc """
  `catalogue.list_products` and `catalogue.get_products`.
  """

  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase,
    only: [fixture_catalogue: 1, fixture_category: 2, fixture_item: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Schemas.Item
  alias PhoenixKitCatalogue.Test.ApiCase

  @list "catalogue.list_products"
  @get "catalogue.get_products"
  @shop_scopes ["catalogue.products:read", "ecommerce.prices:read"]

  setup do
    %{catalogue: fixture_catalogue(%{name: "Read Tools Cat"})}
  end

  defp item(catalogue, name, extra \\ %{}),
    do: fixture_item(Map.merge(%{name: name, catalogue_uuid: catalogue.uuid}, extra))

  defp stamp!(item, iso) do
    {:ok, at, _} = DateTime.from_iso8601(iso)
    {1, _} = Repo.update_all(from(i in Item, where: i.uuid == ^item.uuid), set: [updated_at: at])
    item
  end

  describe "catalogue.list_products" do
    test "lists the default fields and an exact count", %{catalogue: catalogue} do
      category = fixture_category(catalogue, %{name: "Shelf"})

      a =
        item(catalogue, "Alpha", %{
          sku: "SKU-A",
          category_uuid: category.uuid,
          data: %{"api" => %{"external_id" => "E-A"}}
        })

      assert {:ok, body} = ApiCase.call(@list, %{"catalogue_id" => catalogue.uuid})

      assert body["count"] == 1
      assert body["next_cursor"] == nil
      assert [row] = body["items"]
      assert row["id"] == a.uuid
      assert row["external_id"] == "E-A"
      assert row["sku"] == "SKU-A"
      assert row["name"] == "Alpha"
      assert row["status"] == "active"
      assert row["category_id"] == category.uuid
      assert is_binary(row["updated_at"])
      refute Map.has_key?(row, "description")
      refute Map.has_key?(body, "warnings")
    end

    test "pages through every item exactly once with next_cursor", %{catalogue: catalogue} do
      for n <- 1..5, do: item(catalogue, "Item #{n}")
      input = %{"catalogue_id" => catalogue.uuid, "limit" => 2, "fields" => ["id", "name"]}

      assert {:ok, page1} = ApiCase.call(@list, input)
      assert length(page1["items"]) == 2
      assert page1["count"] == 5

      assert {:ok, page2} = ApiCase.call(@list, Map.put(input, "cursor", page1["next_cursor"]))
      assert {:ok, page3} = ApiCase.call(@list, Map.put(input, "cursor", page2["next_cursor"]))
      assert page3["next_cursor"] == nil

      ids =
        Enum.flat_map([page1, page2, page3], fn page -> Enum.map(page["items"], & &1["id"]) end)

      assert length(ids) == 5
      assert length(Enum.uniq(ids)) == 5
    end

    test "fields picks exactly what is asked", %{catalogue: catalogue} do
      item(catalogue, "Alpha", %{sku: "S"})

      assert {:ok, %{"items" => [row]}} =
               ApiCase.call(@list, %{
                 "catalogue_id" => catalogue.uuid,
                 "fields" => ["name", "sku"]
               })

      assert row == %{"name" => "Alpha", "sku" => "S"}
    end

    test "filters: status, category, text and updated_since; trashed items are not listed",
         %{catalogue: catalogue} do
      category = fixture_category(catalogue, %{name: "Shelf"})

      item(catalogue, "Oak panel", %{category_uuid: category.uuid})
      |> stamp!("2026-01-01T00:00:00Z")

      item(catalogue, "Pine panel", %{status: "inactive"}) |> stamp!("2026-02-01T00:00:00Z")
      item(catalogue, "Birch plank", %{status: "discontinued"}) |> stamp!("2026-03-01T00:00:00Z")
      gone = item(catalogue, "Gone panel")
      {:ok, _} = Catalogue.trash_item(gone)

      call = fn extra ->
        {:ok, body} =
          ApiCase.call(
            @list,
            Map.merge(%{"catalogue_id" => catalogue.uuid, "fields" => ["name"]}, extra)
          )

        body["items"] |> Enum.map(& &1["name"]) |> Enum.sort()
      end

      assert call.(%{}) == ["Birch plank", "Oak panel", "Pine panel"]
      assert call.(%{"status" => "inactive"}) == ["Pine panel"]
      assert call.(%{"category_id" => category.uuid}) == ["Oak panel"]
      assert call.(%{"q" => "panel"}) == ["Oak panel", "Pine panel"]

      assert call.(%{"include_deleted" => true}) == [
               "Birch plank",
               "Gone panel",
               "Oak panel",
               "Pine panel"
             ]

      assert call.(%{"updated_since" => "2026-02-01T00:00:00Z"}) == ["Birch plank", "Pine panel"]

      assert call.(%{"updated_since" => "2026-02-01T02:00:00+02:00"}) == [
               "Birch plank",
               "Pine panel"
             ]
    end

    test "q never reads shop fields back: a value only in data[\"ecommerce\"] is not found, with or without the scope",
         %{catalogue: catalogue} do
      item(catalogue, "Plain panel", %{
        data: %{
          "ecommerce" => %{
            "cost_per_item" => "12.34",
            "vendor" => "Acme",
            "tags" => ["secret-tag"]
          }
        }
      })

      for scopes <- [
            ["catalogue.products:read"],
            ApiCase.all_scopes() ++ ["ecommerce.prices:read"]
          ],
          q <- ["12.34", "12", "Acme", "secret-tag"] do
        assert {:ok, %{"items" => [], "count" => 0}} =
                 ApiCase.call(@list, %{"catalogue_id" => catalogue.uuid, "q" => q}, %{
                   scopes: scopes
                 }),
               "q=#{q} with #{inspect(scopes)} found a shop-field value"
      end

      assert {:ok, %{"count" => 1}} =
               ApiCase.call(@list, %{"catalogue_id" => catalogue.uuid, "q" => "plain"})
    end

    test "a limit over 100 is trimmed with a warning, not refused", %{catalogue: catalogue} do
      for n <- 1..3, do: item(catalogue, "L#{n}")

      assert {:ok, body} =
               ApiCase.call(@list, %{"catalogue_id" => catalogue.uuid, "limit" => 5000})

      assert length(body["items"]) == 3
      assert [%{"code" => "limit_trimmed", "limit" => 100}] = body["warnings"]
    end

    test "garbage input is a validation error that names the path", %{catalogue: catalogue} do
      base = %{"catalogue_id" => catalogue.uuid}

      cases = [
        {%{"cursor" => "garbage"}, "cursor"},
        {%{"updated_since" => "yesterday"}, "updated_since"},
        {%{"updated_since" => "2026-10-01"}, "updated_since"},
        {%{"category_id" => "nope"}, "category_id"},
        {%{"category_id" => String.duplicate("x", 36)}, "category_id"},
        {%{"limit" => 0}, "limit"},
        {%{"limit" => -3}, "limit"},
        {%{"limit" => "ten"}, "limit"},
        {%{"fields" => ["id", "bogus"]}, "fields[1]"},
        {%{"status" => "deleted"}, "status"},
        {%{"catalogue_id" => "nope"}, "catalogue_id"},
        {%{"base_price" => 1}, "base_price"}
      ]

      for {extra, path} <- cases do
        assert {:error, :validation_failed, _message, %{errors: errors}} =
                 ApiCase.call(@list, Map.merge(base, extra)),
               "#{inspect(extra)} was accepted"

        assert Enum.any?(errors, &(&1.path == path)),
               "#{inspect(extra)}: no error at #{path}, got #{inspect(errors)}"
      end
    end

    test "an unknown catalogue is not_found" do
      assert {:error, :not_found, _, _} =
               ApiCase.call(@list, %{"catalogue_id" => Ecto.UUID.generate()})
    end

    test "catalogue_id is required once two catalogues are active", %{catalogue: _first} do
      _second = fixture_catalogue(%{name: "Second"})

      assert {:error, :validation_failed, message, %{errors: [error]}} = ApiCase.call(@list, %{})
      assert message =~ "catalogue_id is required"
      assert length(error.allowed) >= 2
    end

    test "shop fields are left out without the scope, and the request is told so",
         %{catalogue: catalogue} do
      item(catalogue, "Priced", %{data: %{"ecommerce" => %{"compare_at_price" => "5"}}})
      input = %{"catalogue_id" => catalogue.uuid, "fields" => ["name", "shop"]}

      assert {:ok, body} = ApiCase.call(@list, input)
      assert [%{"name" => "Priced"} = row] = body["items"]
      refute Map.has_key?(row, "shop")
      assert [%{"code" => "fields_not_available", "fields" => ["shop"]}] = body["warnings"]

      assert {:ok, body} = ApiCase.call(@list, input, %{scopes: @shop_scopes})
      assert [%{"shop" => %{"compare_at_price" => "5"}}] = body["items"]
      refute Map.has_key?(body, "warnings")
    end
  end

  describe "catalogue.get_products" do
    test "reads by id, sku and external_id with every field", %{catalogue: catalogue} do
      category = fixture_category(catalogue, %{name: "Shelf"})

      a =
        item(catalogue, "Alpha", %{
          sku: "SKU-A",
          description: "First",
          category_uuid: category.uuid,
          unit: "set",
          slug: %{"en-US" => "alpha"}
        })

      b = item(catalogue, "Beta", %{data: %{"api" => %{"external_id" => "E-B"}}})

      input = %{
        "catalogue_id" => catalogue.uuid,
        "refs" => [%{"id" => a.uuid}, %{"sku" => "SKU-A"}, %{"external_id" => "E-B"}]
      }

      assert {:ok, %{"results" => [one, two, three], "summary" => %{"found" => 3}}} =
               ApiCase.call(@get, input)

      assert one["action"] == "found"
      assert one["ref"] == %{"id" => a.uuid}
      assert one["id"] == a.uuid
      assert two["id"] == a.uuid
      assert three["id"] == b.uuid

      card = one["item"]
      assert card["id"] == a.uuid
      assert card["catalogue_id"] == catalogue.uuid
      assert card["category_id"] == category.uuid
      assert card["category"] == %{"id" => category.uuid, "name" => "Shelf"}
      assert card["sku"] == "SKU-A"
      assert card["name"] == "Alpha"
      assert card["description"] == "First"
      assert card["status"] == "active"
      assert card["unit"] == "set"
      assert card["slug"] == %{"en-US" => "alpha"}
      assert card["attributes"] == []
      assert card["images"] == []
      assert is_binary(card["created_at"]) and is_binary(card["updated_at"])
      refute Map.has_key?(card, "shop")
      assert three["item"]["external_id"] == "E-B"
    end

    test "never returns cost_per_item, hides shop without the scope, shows the rest with it",
         %{catalogue: catalogue} do
      a =
        item(catalogue, "Priced", %{
          data: %{
            "ecommerce" => %{
              "compare_at_price" => "5",
              "shop_status" => "active",
              "cost_per_item" => "2",
              "shopify" => %{"product_id" => "99"},
              "translation_fingerprints" => %{"de-DE" => %{}}
            }
          }
        })

      input = %{"catalogue_id" => catalogue.uuid, "refs" => [%{"id" => a.uuid}]}

      assert {:ok, %{"results" => [%{"item" => card}]} = without} = ApiCase.call(@get, input)
      refute Map.has_key?(card, "shop")
      refute Map.has_key?(without, "warnings")
      refute inspect(card) =~ "cost_per_item"

      assert {:ok, %{"results" => [%{"item" => card}]}} =
               ApiCase.call(@get, input, %{scopes: @shop_scopes})

      assert card["shop"] == %{"compare_at_price" => "5", "shop_status" => "active"}
      refute inspect(card) =~ "cost_per_item"
    end

    test "translations carry the primary language from the columns and the buckets of the others",
         %{catalogue: catalogue} do
      a =
        item(catalogue, "Oak", %{
          description: "Wood",
          slug: %{"en-US" => "oak", "de-DE" => "eiche"},
          data: %{
            "_primary_language" => "en-US",
            "en-US" => %{"_name" => "Oak"},
            "de-DE" => %{
              "_name" => "Eiche",
              "_description" => "Holz",
              "_seo_title" => "Eiche kaufen"
            },
            "api" => %{"external_id" => "E-1"}
          }
        })

      assert {:ok, %{"results" => [%{"item" => card}]}} =
               ApiCase.call(@get, %{
                 "catalogue_id" => catalogue.uuid,
                 "refs" => [%{"id" => a.uuid}],
                 "fields" => ["translations"]
               })

      assert card["translations"] == %{
               "en-US" => %{"name" => "Oak", "description" => "Wood", "slug" => "oak"},
               "de-DE" => %{
                 "name" => "Eiche",
                 "description" => "Holz",
                 "seo_title" => "Eiche kaufen",
                 "slug" => "eiche"
               }
             }
    end

    test "every bad reference is its own error row, the others are read", %{catalogue: catalogue} do
      a = item(catalogue, "Alpha", %{sku: "OK"})
      item(catalogue, "Twin 1", %{sku: "TWIN"})
      item(catalogue, "Twin 2", %{sku: "TWIN"})

      input = %{
        "catalogue_id" => catalogue.uuid,
        "refs" => [
          %{"sku" => "OK"},
          %{"id" => "not-a-uuid"},
          %{"sku" => "TWIN"},
          %{"sku" => "NOPE"},
          %{},
          %{"id" => a.uuid, "sku" => "OK"}
        ]
      }

      assert {:ok, %{"results" => rows, "summary" => summary}} = ApiCase.call(@get, input)

      assert Enum.map(rows, & &1["action"]) == [
               "found",
               "error",
               "error",
               "error",
               "error",
               "error"
             ]

      assert Enum.map(rows, &get_in(&1, ["error", "code"])) ==
               [
                 nil,
                 "not_found",
                 "ambiguous_ref",
                 "not_found",
                 "validation_failed",
                 "validation_failed"
               ]

      assert summary == %{"found" => 1, "error" => 5}
      assert length(Enum.at(rows, 2)["error"]["context"]["candidates"]) == 2
    end

    test "an item of another catalogue is not found", %{catalogue: catalogue} do
      other = fixture_catalogue(%{name: "Elsewhere"})
      foreign = item(other, "Foreign")

      assert {:ok, %{"results" => [%{"action" => "error", "error" => %{"code" => "not_found"}}]}} =
               ApiCase.call(@get, %{
                 "catalogue_id" => catalogue.uuid,
                 "refs" => [%{"id" => foreign.uuid}]
               })
    end

    test "more than 50 references are refused up front", %{catalogue: catalogue} do
      refs = for n <- 1..51, do: %{"sku" => "S#{n}"}

      assert {:error, :validation_failed, _, %{errors: [%{limit: 50}]}} =
               ApiCase.call(@get, %{"catalogue_id" => catalogue.uuid, "refs" => refs})
    end

    test "an empty reference list is refused", %{catalogue: catalogue} do
      assert {:error, :validation_failed, _, %{errors: errors}} =
               ApiCase.call(@get, %{"catalogue_id" => catalogue.uuid, "refs" => []})

      assert Enum.any?(errors, &(&1.path == "refs"))
    end
  end
end
