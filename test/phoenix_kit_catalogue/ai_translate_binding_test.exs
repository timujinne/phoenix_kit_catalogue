defmodule PhoenixKitCatalogue.AITranslateBindingTest do
  @moduledoc """
  Unit coverage for `PhoenixKitCatalogue.AITranslateBinding` — the
  catalogue-specific half of the shared AI-translate glue
  (`PhoenixKitAI.Components.AITranslate.FormBinding`).

  `apply_translation/4` is the focus: it merges a completed translation's
  fields into the LIVE form changeset. Reproduces (as a DB-backed unit
  test) the bug where a translation fingerprint the worker wrote directly
  to the row disappears the next time the open form saves, because the
  live changeset was built before the worker's write landed.
  """

  use PhoenixKitCatalogue.DataCase, async: true

  alias PhoenixKitCatalogue.AITranslatable
  alias PhoenixKitCatalogue.AITranslateBinding
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Schemas.Item

  defp create_item(attrs \\ %{}) do
    {:ok, cat} = Catalogue.create_catalogue(%{name: "Cat"})

    {:ok, item} =
      Catalogue.create_item(Map.merge(%{name: "Widget", catalogue_uuid: cat.uuid}, attrs))

    item
  end

  defp create_category(attrs \\ %{}) do
    {:ok, cat} = Catalogue.create_catalogue(%{name: "Cat"})

    {:ok, category} =
      Catalogue.create_category(Map.merge(%{name: "Cards", catalogue_uuid: cat.uuid}, attrs))

    category
  end

  describe "apply_translation/4" do
    test "merges translated fields into the changeset's data under the language" do
      item = create_item()
      changeset = Catalogue.change_item(item, %{})

      updated =
        AITranslateBinding.apply_translation("catalogue_item", changeset, "fr", %{
          "name" => "Widget FR"
        })

      assert Ecto.Changeset.get_field(updated, :data)["fr"]["_name"] == "Widget FR"
    end

    test "pulls in a fingerprint the worker already wrote to the DB row, which the live changeset predates" do
      item = create_item()
      # The open form's changeset, as it looked BEFORE the worker wrote.
      stale_changeset = Catalogue.change_item(item, %{})

      # The worker's write path: lands straight on the DB row,
      # independent of whatever changeset an open form is holding.
      {:ok, _} = AITranslatable.put_translation(item, "fr", %{"name" => "Widget FR"}, [])
      fresh = Catalogue.get_item(item.uuid)
      assert fresh.data["_translation_fingerprints"]["fr"]["name"]

      updated =
        AITranslateBinding.apply_translation("catalogue_item", stale_changeset, "fr", %{
          "name" => "Widget FR"
        })

      data = Ecto.Changeset.get_field(updated, :data)

      assert data["_translation_fingerprints"]["fr"]["name"] ==
               fresh.data["_translation_fingerprints"]["fr"]["name"]
    end

    test "carries forward fingerprints of OTHER languages already on the row too" do
      item = create_item(%{description: "A thing"})
      {:ok, _} = AITranslatable.put_translation(item, "de", %{"name" => "Widget DE"}, [])
      with_de = Catalogue.get_item(item.uuid)
      stale_changeset = Catalogue.change_item(with_de, %{})

      {:ok, _} = AITranslatable.put_translation(with_de, "fr", %{"name" => "Widget FR"}, [])
      fresh = Catalogue.get_item(item.uuid)

      updated =
        AITranslateBinding.apply_translation("catalogue_item", stale_changeset, "fr", %{
          "name" => "Widget FR"
        })

      data = Ecto.Changeset.get_field(updated, :data)

      assert data["_translation_fingerprints"]["de"] ==
               fresh.data["_translation_fingerprints"]["de"]

      assert data["_translation_fingerprints"]["fr"] ==
               fresh.data["_translation_fingerprints"]["fr"]
    end

    test "an unsaved (:new) resource has no row to re-read — applies fields without crashing" do
      changeset =
        Catalogue.change_item(%Item{}, %{name: "Draft", catalogue_uuid: Ecto.UUID.generate()})

      updated =
        AITranslateBinding.apply_translation("catalogue_item", changeset, "fr", %{
          "name" => "Draft FR"
        })

      data = Ecto.Changeset.get_field(updated, :data)
      assert data["fr"]["_name"] == "Draft FR"
      refute Map.has_key?(data, "_translation_fingerprints")
    end

    test "works the same way for categories" do
      category = create_category()
      stale_changeset = Catalogue.change_category(category, %{})

      {:ok, _} = AITranslatable.put_translation(category, "fr", %{"name" => "Cartes FR"}, [])
      fresh = Catalogue.get_category(category.uuid)

      updated =
        AITranslateBinding.apply_translation("catalogue_category", stale_changeset, "fr", %{
          "name" => "Cartes FR"
        })

      data = Ecto.Changeset.get_field(updated, :data)

      assert data["_translation_fingerprints"]["fr"] ==
               fresh.data["_translation_fingerprints"]["fr"]
    end

    test "resource types with no fingerprint mechanism (e.g. \"catalogue\") are left alone, no crash" do
      {:ok, cat} = Catalogue.create_catalogue(%{name: "Cat"})
      changeset = Catalogue.change_catalogue(cat, %{})

      updated =
        AITranslateBinding.apply_translation("catalogue", changeset, "fr", %{"name" => "Cat FR"})

      data = Ecto.Changeset.get_field(updated, :data)
      assert data["fr"]["_name"] == "Cat FR"
      refute Map.has_key?(data, "_translation_fingerprints")
    end
  end
end
