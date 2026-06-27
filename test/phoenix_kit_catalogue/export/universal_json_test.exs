defmodule PhoenixKitCatalogue.Export.UniversalJsonTest do
  @moduledoc """
  Pure formatter tests for the Universal JSON export encoder.

  No database access — all data is constructed inline using the multi-catalogue
  ctx shape: %{items, index, catalogues}.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitCatalogue.Export.UniversalJson

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp catalogue(attrs \\ []) do
    base = %{uuid: "catalogue-uuid-1", name: "Test Catalogue"}
    Map.merge(base, Map.new(attrs))
  end

  defp item(attrs \\ []) do
    base = %{
      name: "Widget Alpha",
      sku: "W-001",
      base_price: Decimal.new("100.00"),
      unit: "piece",
      category: %{uuid: "cat-uuid-1", name: "Category A"},
      catalogue: catalogue()
    }

    Map.merge(base, Map.new(attrs))
  end

  defp ctx(items, catalogues \\ nil) do
    cats = catalogues || [catalogue()]

    %{
      items: items,
      index: 1_111_111_111,
      catalogues: cats
    }
  end

  # ---------------------------------------------------------------------------
  # Single-catalogue export
  # ---------------------------------------------------------------------------

  describe "render/1 with a single catalogue" do
    setup do
      items = [
        item(name: "Chair", sku: "CH-1", base_price: Decimal.new("500"), unit: "piece"),
        item(
          name: "Table",
          sku: "TB-1",
          base_price: nil,
          unit: "m2",
          category: %{uuid: "cat-2", name: "Tables"},
          catalogue: catalogue(uuid: "catalogue-uuid-1", name: "Test Catalogue")
        )
      ]

      {filename, content, mime} = UniversalJson.render(ctx(items))
      {:ok, filename: filename, json: Jason.decode!(IO.iodata_to_binary(content)), mime: mime}
    end

    test "mime is application/json", %{mime: mime} do
      assert mime == "application/json"
    end

    test "filename is <catalogue_name>.json for single catalogue", %{filename: filename} do
      assert filename =~ ~r/\ATest_Catalogue \d{4}-\d{2}-\d{2} \d{2}-\d{2}\.json\z/
    end

    test "top-level catalogues array", %{json: json} do
      assert [%{"uuid" => "catalogue-uuid-1", "name" => "Test Catalogue"}] = json["catalogues"]
    end

    test "exported_at is an ISO 8601 timestamp", %{json: json} do
      assert {:ok, _, _} = DateTime.from_iso8601(json["exported_at"])
    end

    test "index is an integer", %{json: json} do
      assert is_integer(json["index"])
      assert json["index"] == 1_111_111_111
    end

    test "items array has correct length", %{json: json} do
      assert length(json["items"]) == 2
    end

    test "item has name field", %{json: json} do
      chair = Enum.find(json["items"], &(&1["name"] == "Chair"))
      assert chair["name"] == "Chair"
    end

    test "item has sku field", %{json: json} do
      chair = Enum.find(json["items"], &(&1["name"] == "Chair"))
      assert chair["sku"] == "CH-1"
    end

    test "item base_price is 2dp string", %{json: json} do
      chair = Enum.find(json["items"], &(&1["name"] == "Chair"))
      assert chair["base_price"] == "500.00"
    end

    test "item nil base_price becomes 0.00", %{json: json} do
      table = Enum.find(json["items"], &(&1["name"] == "Table"))
      assert table["base_price"] == "0.00"
    end

    test "item unit field is present", %{json: json} do
      chair = Enum.find(json["items"], &(&1["name"] == "Chair"))
      assert chair["unit"] == "piece"
    end

    test "item has catalogue field with catalogue name", %{json: json} do
      chair = Enum.find(json["items"], &(&1["name"] == "Chair"))
      assert chair["catalogue"] == "Test Catalogue"
    end

    test "no category field on items", %{json: json} do
      chair = Enum.find(json["items"], &(&1["name"] == "Chair"))
      refute Map.has_key?(chair, "category")
    end

    test "no top-level catalogue (singular) key", %{json: json} do
      refute Map.has_key?(json, "catalogue")
    end
  end

  # ---------------------------------------------------------------------------
  # Multi-catalogue export
  # ---------------------------------------------------------------------------

  describe "render/1 with multiple catalogues" do
    setup do
      cat1 = catalogue(uuid: "cat-1", name: "Catalogue One")
      cat2 = catalogue(uuid: "cat-2", name: "Catalogue Two")

      items = [
        item(name: "Item A", catalogue: cat1),
        item(name: "Item B", catalogue: cat2)
      ]

      {filename, content, mime} = UniversalJson.render(ctx(items, [cat1, cat2]))
      {:ok, filename: filename, json: Jason.decode!(IO.iodata_to_binary(content)), mime: mime}
    end

    test "filename is Catalogues.json for multiple catalogues", %{filename: filename} do
      assert filename =~ ~r/\ACatalogues \d{4}-\d{2}-\d{2} \d{2}-\d{2}\.json\z/
    end

    test "catalogues array contains both entries", %{json: json} do
      uuids = Enum.map(json["catalogues"], & &1["uuid"])
      assert "cat-1" in uuids
      assert "cat-2" in uuids
    end

    test "items from both catalogues are present", %{json: json} do
      names = Enum.map(json["items"], & &1["name"])
      assert "Item A" in names
      assert "Item B" in names
    end

    test "each item carries its own catalogue name", %{json: json} do
      item_a = Enum.find(json["items"], &(&1["name"] == "Item A"))
      item_b = Enum.find(json["items"], &(&1["name"] == "Item B"))
      assert item_a["catalogue"] == "Catalogue One"
      assert item_b["catalogue"] == "Catalogue Two"
    end
  end

  # ---------------------------------------------------------------------------
  # Edge cases
  # ---------------------------------------------------------------------------

  describe "render/1 edge cases" do
    test "empty items list produces empty items array" do
      {_, content, _} = UniversalJson.render(ctx([]))
      json = Jason.decode!(IO.iodata_to_binary(content))
      assert json["items"] == []
    end

    test "item with nil catalogue association falls back to nil" do
      item_no_cat = item(catalogue: nil)
      {_, content, _} = UniversalJson.render(ctx([item_no_cat]))
      json = Jason.decode!(IO.iodata_to_binary(content))
      assert hd(json["items"])["catalogue"] == nil
    end

    test "nil base_price on item becomes 0.00" do
      {_, content, _} = UniversalJson.render(ctx([item(base_price: nil)]))
      json = Jason.decode!(IO.iodata_to_binary(content))
      assert hd(json["items"])["base_price"] == "0.00"
    end
  end

  # ---------------------------------------------------------------------------
  # Universal destination module
  # ---------------------------------------------------------------------------

  describe "PhoenixKitCatalogue.Export.Universal" do
    alias PhoenixKitCatalogue.Export.Universal

    test "key/0 returns :universal" do
      assert Universal.key() == :universal
    end

    test "label/0 includes Universal" do
      assert String.contains?(Universal.label(), "Universal")
    end

    test "formats/0 includes :json" do
      keys = Universal.formats() |> Enum.map(&elem(&1, 0))
      assert :json in keys
    end

    test "render(:json, ctx) delegates to UniversalJson" do
      items = [item()]
      {filename, content, mime} = Universal.render(:json, ctx(items))
      assert mime == "application/json"
      assert String.ends_with?(filename, ".json")
      json = Jason.decode!(IO.iodata_to_binary(content))
      assert is_list(json["catalogues"])
      assert is_list(json["items"])
    end
  end

  describe "filename sanitization" do
    test "keeps a Cyrillic catalogue name (regression: \\w must be Unicode-aware)" do
      cat = %{uuid: "cyr-1", name: "Кухня"}
      {filename, _content, _mime} = UniversalJson.render(ctx([], [cat]))
      assert filename =~ ~r/\AКухня \d{4}-\d{2}-\d{2} \d{2}-\d{2}\.json\z/
    end
  end
end
