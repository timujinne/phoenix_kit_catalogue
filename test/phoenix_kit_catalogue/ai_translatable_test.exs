defmodule PhoenixKitCatalogue.AITranslatableTest do
  @moduledoc """
  Unit coverage for the catalogue `Translatable` adapter — the storage half
  of the AI-translation pipeline. No live `PhoenixKitAI` needed; these test
  fetch / source-field extraction / persist directly against the DB.
  """

  use PhoenixKitCatalogue.DataCase, async: true

  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitCatalogue.AITranslatable
  alias PhoenixKitCatalogue.Catalogue

  defp primary, do: Multilang.primary_language()

  defp create_item(attrs \\ %{}) do
    {:ok, cat} = Catalogue.create_catalogue(%{name: "Cat"})

    {:ok, item} =
      Catalogue.create_item(Map.merge(%{name: "Widget", catalogue_uuid: cat.uuid}, attrs))

    item
  end

  describe "fetch/2" do
    test "loads a known item by type + uuid" do
      item = create_item()
      assert {:ok, fetched} = AITranslatable.fetch("catalogue_item", item.uuid)
      assert fetched.uuid == item.uuid
    end

    test "missing row → :resource_not_found" do
      assert {:error, :resource_not_found} =
               AITranslatable.fetch("catalogue_item", "00000000-0000-0000-0000-000000000000")
    end

    test "unknown resource type → :unknown_resource_type" do
      assert {:error, {:unknown_resource_type, "bogus"}} = AITranslatable.fetch("bogus", "x")
    end
  end

  describe "source_fields/2" do
    test "falls back to the column when the lang subtree has no override" do
      item = create_item(%{name: "Widget"})
      fields = AITranslatable.source_fields(item, primary())
      assert fields["name"] == "Widget"
    end

    test "blank source fields are omitted" do
      item = create_item(%{name: "Widget"})
      # description not set → not in the source map
      refute Map.has_key?(AITranslatable.source_fields(item, primary()), "description")
    end
  end

  describe "put_translation/4" do
    test "writes the translation under the multilang `_`-prefixed key" do
      item = create_item()
      assert {:ok, _} = AITranslatable.put_translation(item, "es", %{"name" => "Artilugio"}, [])

      reloaded = Catalogue.get_item(item.uuid)
      assert reloaded.data["es"]["_name"] == "Artilugio"
    end

    test "merges into an existing lang subtree (keeps sibling fields)" do
      item = create_item()
      {:ok, _} = AITranslatable.put_translation(item, "es", %{"name" => "Artilugio"}, [])
      item2 = Catalogue.get_item(item.uuid)
      {:ok, _} = AITranslatable.put_translation(item2, "es", %{"description" => "Una cosa"}, [])

      reloaded = Catalogue.get_item(item.uuid)
      assert reloaded.data["es"]["_name"] == "Artilugio"
      assert reloaded.data["es"]["_description"] == "Una cosa"
    end

    test "force-stores a value even when it equals the source (no blank-drop)" do
      item = create_item(%{name: "ABC123"})
      {:ok, _} = AITranslatable.put_translation(item, "es", %{"name" => "ABC123"}, [])

      reloaded = Catalogue.get_item(item.uuid)
      assert reloaded.data["es"]["_name"] == "ABC123"
    end
  end

  describe "force_put_language/3" do
    test "merges rather than wholesale-replacing the lang subtree" do
      data = %{"_primary_language" => "en", "es" => %{"_name" => "Hola", "_keep" => "x"}}
      merged = AITranslatable.force_put_language(data, "es", %{"_description" => "Mundo"})
      assert merged["es"]["_name"] == "Hola"
      assert merged["es"]["_keep"] == "x"
      assert merged["es"]["_description"] == "Mundo"
    end

    test "seeds the multilang marker for a column-only (non-multilang) map" do
      merged = AITranslatable.force_put_language(%{}, "es", %{"_name" => "Hola"})
      assert merged["es"]["_name"] == "Hola"
      assert Map.has_key?(merged, "_primary_language")
    end
  end
end
