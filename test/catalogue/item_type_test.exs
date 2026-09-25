defmodule PhoenixKitCatalogue.Catalogue.ItemTypeTest do
  @moduledoc """
  The goods/service item type through the context: `effective_item_type/1`
  (never raises, loads what is missing), the `item_types:` filter by the
  EFFECTIVE type across every item list and counter, duplication, the
  activity log, and the import/export round trip.
  """
  use PhoenixKitCatalogue.DataCase, async: true

  import PhoenixKitCatalogue.LiveCase,
    only: [fixture_catalogue: 1, fixture_category: 2, fixture_item: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Export.UniversalJson
  alias PhoenixKitCatalogue.Import.Mapper
  alias PhoenixKitCatalogue.Import.Source.Universal, as: UniversalSource
  alias PhoenixKitCatalogue.Schemas.Item

  # A mixed catalogue (goods by default) and a service catalogue, each
  # with an inheriting item and an overriding one, split across a category
  # and the uncategorized level.
  setup do
    goods_cat = fixture_catalogue(%{name: "Taust #{System.unique_integer([:positive])}"})

    services_cat =
      fixture_catalogue(%{
        name: "Teenused #{System.unique_integer([:positive])}",
        item_type: "service"
      })

    shelf = fixture_category(goods_cat, %{name: "Shelf"})
    visits = fixture_category(services_cat, %{name: "Visits"})

    panel =
      fixture_item(%{name: "Panel", catalogue_uuid: goods_cat.uuid, category_uuid: shelf.uuid})

    install =
      fixture_item(%{
        name: "Paigaldus",
        catalogue_uuid: goods_cat.uuid,
        category_uuid: shelf.uuid,
        item_type: "service"
      })

    loose_goods = fixture_item(%{name: "Loose", catalogue_uuid: goods_cat.uuid})

    transport =
      fixture_item(%{
        name: "Transport",
        catalogue_uuid: services_cat.uuid,
        category_uuid: visits.uuid
      })

    template =
      fixture_item(%{
        name: "Template",
        catalogue_uuid: services_cat.uuid,
        category_uuid: visits.uuid,
        item_type: "goods"
      })

    %{
      goods_cat: goods_cat,
      services_cat: services_cat,
      shelf: shelf,
      visits: visits,
      panel: panel,
      install: install,
      loose_goods: loose_goods,
      transport: transport,
      template: template
    }
  end

  defp names(items), do: items |> Enum.map(& &1.name) |> Enum.sort()

  describe "effective_item_type/1" do
    test "loads the catalogue when it is not preloaded", ctx do
      bare = Catalogue.get_item(ctx.transport.uuid)
      assert %Ecto.Association.NotLoaded{} = bare.catalogue

      assert Catalogue.effective_item_type(bare) == "service"
      assert Catalogue.effective_item_type(Catalogue.get_item(ctx.panel.uuid)) == "goods"
    end

    test "the item's own type wins", ctx do
      assert Catalogue.effective_item_type(Catalogue.get_item(ctx.install.uuid)) == "service"
      assert Catalogue.effective_item_type(Catalogue.get_item(ctx.template.uuid)) == "goods"
    end

    test "uses a preloaded catalogue as is", ctx do
      item = Catalogue.get_item!(ctx.transport.uuid)
      assert Catalogue.effective_item_type(item) == "service"
    end

    test "an item without a catalogue reads as goods, never raises" do
      assert Catalogue.effective_item_type(%Item{catalogue_uuid: nil}) == "goods"

      assert Catalogue.effective_item_type(%Item{catalogue_uuid: nil, item_type: "service"}) ==
               "service"
    end

    test "an item whose catalogue row is gone reads as goods" do
      assert Catalogue.effective_item_type(%Item{catalogue_uuid: UUIDv7.generate()}) == "goods"
    end
  end

  describe "list_items_by_uuids/2 preloads enough for Item.effective_type/1" do
    test "no ArgumentError on the preloaded rows", ctx do
      items = Catalogue.list_items_by_uuids([ctx.transport.uuid, ctx.panel.uuid])
      types = Map.new(items, &{&1.name, Item.effective_type(&1)})
      assert types == %{"Transport" => "service", "Panel" => "goods"}
    end
  end

  describe "item_types: filter (by effective type)" do
    test "search_items/2 and count_search_items/2", ctx do
      scope = [catalogue_uuids: [ctx.goods_cat.uuid, ctx.services_cat.uuid]]

      assert names(Catalogue.search_items("", scope ++ [item_types: ["service"]])) ==
               ["Paigaldus", "Transport"]

      assert names(Catalogue.search_items("", scope ++ [item_types: ["goods"]])) ==
               ["Loose", "Panel", "Template"]

      assert Catalogue.count_search_items("", scope ++ [item_types: ["service"]]) == 2
      assert Catalogue.count_search_items("", scope ++ [item_types: [:goods]]) == 3

      # nil / [] = no filter
      assert Catalogue.count_search_items("", scope ++ [item_types: []]) == 5
      assert Catalogue.count_search_items("", scope) == 5
    end

    test "list_items/1", ctx do
      ours = [ctx.goods_cat.uuid, ctx.services_cat.uuid]

      pick = fn opts ->
        opts |> Catalogue.list_items() |> Enum.filter(&(&1.catalogue_uuid in ours)) |> names()
      end

      assert pick.(item_types: ["service"]) == ["Paigaldus", "Transport"]
      assert pick.(item_types: ["goods"]) == ["Loose", "Panel", "Template"]
      assert pick.([]) == ["Loose", "Paigaldus", "Panel", "Template", "Transport"]
    end

    test "list_catalogue_items_paged/2 and count_items_for_catalogue/2", ctx do
      assert names(
               Catalogue.list_catalogue_items_paged(ctx.goods_cat.uuid, item_types: ["goods"])
             ) ==
               ["Loose", "Panel"]

      assert names(
               Catalogue.list_catalogue_items_paged(ctx.services_cat.uuid,
                 item_types: ["service"]
               )
             ) == ["Transport"]

      assert Catalogue.count_items_for_catalogue(ctx.goods_cat.uuid, item_types: ["goods"]) == 2
      assert Catalogue.count_items_for_catalogue(ctx.goods_cat.uuid, item_types: ["service"]) == 1
      assert Catalogue.count_items_for_catalogue(ctx.goods_cat.uuid) == 3
    end

    test "list_items_for_category_paged/2 and item_count_for_category/2", ctx do
      assert names(Catalogue.list_items_for_category_paged(ctx.shelf.uuid, item_types: ["goods"])) ==
               ["Panel"]

      assert names(
               Catalogue.list_items_for_category_paged(ctx.visits.uuid, item_types: ["goods"])
             ) ==
               ["Template"]

      assert Catalogue.item_count_for_category(ctx.visits.uuid, item_types: ["service"]) == 1
      assert Catalogue.item_count_for_category(ctx.visits.uuid) == 2
    end

    test "the per-category and uncategorized counters", ctx do
      counts =
        Catalogue.item_counts_by_category_for_catalogue(ctx.goods_cat.uuid, item_types: ["goods"])

      assert Map.new(counts, fn {k, v} -> {to_string(k), v} end) == %{
               to_string(ctx.shelf.uuid) => 1
             }

      # A category holding only services does not count as non-empty.
      service_only = fixture_category(ctx.goods_cat, %{name: "Only services"})

      fixture_item(%{
        name: "Mõõdistus",
        catalogue_uuid: ctx.goods_cat.uuid,
        category_uuid: service_only.uuid,
        item_type: "service"
      })

      counts =
        Catalogue.item_counts_by_category_for_catalogue(ctx.goods_cat.uuid, item_types: ["goods"])

      refute Map.has_key?(Map.new(counts, fn {k, v} -> {to_string(k), v} end), service_only.uuid)

      assert Catalogue.uncategorized_count_for_catalogue(ctx.goods_cat.uuid,
               item_types: ["goods"]
             ) ==
               1

      assert Catalogue.uncategorized_count_for_catalogue(ctx.goods_cat.uuid,
               item_types: ["service"]
             ) == 0
    end

    test "changing the catalogue's type moves its inheriting items, not its overrides", ctx do
      {:ok, _} = Catalogue.update_catalogue(ctx.services_cat, %{item_type: "goods"})

      assert names(
               Catalogue.search_items("",
                 catalogue_uuids: [ctx.services_cat.uuid],
                 item_types: ["goods"]
               )
             ) == ["Template", "Transport"]

      {:ok, _} = Catalogue.update_item(ctx.template, %{item_type: "service"})

      assert names(
               Catalogue.search_items("",
                 catalogue_uuids: [ctx.services_cat.uuid],
                 item_types: ["service"]
               )
             ) == ["Template"]
    end
  end

  describe "duplication" do
    test "an item copy keeps its own item_type (and nil stays nil)", ctx do
      {:ok, copy} = Catalogue.duplicate_item(ctx.install)
      assert copy.item_type == "service"

      {:ok, copy} = Catalogue.duplicate_item(ctx.panel)
      assert is_nil(copy.item_type)
    end

    test "a catalogue copy keeps its default item type", ctx do
      {:ok, %{catalogue: copy}} = Catalogue.duplicate_catalogue(ctx.services_cat)
      assert Catalogue.get_catalogue(copy.uuid).item_type == "service"
    end
  end

  describe "activity log" do
    test "an item type change is logged with labels, not raw values", ctx do
      Gettext.put_locale(PhoenixKitCatalogue.Gettext, "en")
      {:ok, _} = Catalogue.update_item(ctx.panel, %{item_type: "service"})

      row = assert_activity_logged("item.updated", resource_uuid: ctx.panel.uuid)
      assert row.metadata["changes"]["item_type"] == %{"from" => "", "to" => "Service"}
    end

    test "a catalogue default type change is logged with labels", ctx do
      Gettext.put_locale(PhoenixKitCatalogue.Gettext, "en")
      {:ok, _} = Catalogue.update_catalogue(ctx.goods_cat, %{item_type: "service"})

      row = assert_activity_logged("catalogue.updated", resource_uuid: ctx.goods_cat.uuid)
      assert row.metadata["changes"]["item_type"] == %{"from" => "Goods", "to" => "Service"}
    end
  end

  describe "export / import round trip" do
    test "the universal JSON writes the item's own item_type (nil → empty)", ctx do
      items = Catalogue.list_items_by_uuids([ctx.install.uuid, ctx.panel.uuid])

      {_name, json, _mime} =
        UniversalJson.render(%{items: items, index: 1, catalogues: [ctx.goods_cat]})

      by_name = json |> Jason.decode!() |> Map.fetch!("items") |> Map.new(&{&1["name"], &1})
      assert by_name["Paigaldus"]["item_type"] == "service"
      assert by_name["Panel"]["item_type"] == ""
    end

    test "the JSON source maps item_type back onto the import target", ctx do
      items = Catalogue.list_items_by_uuids([ctx.install.uuid, ctx.panel.uuid])

      {_name, json, _mime} =
        UniversalJson.render(%{items: items, index: 1, catalogues: [ctx.goods_cat]})

      {:ok, parsed} = UniversalSource.parse(json, "x.json", :json)
      mappings = Mapper.auto_detect_mappings(parsed.headers)
      assert Enum.find(mappings, &(&1.header == "item_type")).target == :item_type

      plan = Mapper.build_import_plan(mappings, parsed.rows)
      by_name = Map.new(plan.items, &{&1.name, &1})
      assert by_name["Paigaldus"][:item_type] == "service"
      refute Map.has_key?(by_name["Panel"], :item_type)
    end
  end
end
