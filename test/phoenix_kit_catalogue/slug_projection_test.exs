defmodule PhoenixKitCatalogue.SlugProjectionTest do
  @moduledoc """
  Block 1, Task 1 (trigger projections) and Task 2 (`get_item_by_slug/3`
  / `get_category_by_slug/3` lookups): the DB-level slug -> uuid
  projections `sync_cat_item_slugs()`/`sync_cat_category_slugs()`
  maintain, and the lookups built on top of them.
  """

  # async: false — one test deliberately triggers a Postgrex.Error
  # (duplicate slug) inside its sandboxed connection; keeping the case
  # serial avoids any cross-test interaction with that aborted
  # transaction.
  use PhoenixKitCatalogue.DataCase, async: false

  alias PhoenixKitCatalogue.Catalogue

  defp create_catalogue(attrs \\ %{}) do
    {:ok, c} = Catalogue.create_catalogue(Map.merge(%{name: unique_name("Catalogue")}, attrs))
    c
  end

  defp create_category(catalogue, attrs \\ %{}) do
    {:ok, c} =
      Catalogue.create_category(
        Map.merge(%{name: unique_name("Category"), catalogue_uuid: catalogue.uuid}, attrs)
      )

    c
  end

  defp create_item(catalogue, attrs \\ %{}) do
    {:ok, i} =
      Catalogue.create_item(
        Map.merge(%{name: unique_name("Item"), catalogue_uuid: catalogue.uuid}, attrs)
      )

    i
  end

  defp unique_name(prefix), do: "#{prefix} #{System.unique_integer([:positive])}"

  # The `slug` schema field doesn't exist until Task 2 — set the DB
  # column directly so this task's trigger projections can be tested in
  # isolation. Postgrex's jsonb extension encodes a plain Elixir map
  # itself, and comparing `uuid::text` sidesteps having to hand-encode
  # the 16-byte binary form of a UUID for a raw parameterized query.
  defp put_slug(table, uuid, slug) do
    Repo.query!("UPDATE #{table} SET slug = $1 WHERE uuid::text = $2", [slug, uuid])
  end

  describe "item slug projection" do
    test "a trigger projects every language of an item's slug" do
      catalogue = create_catalogue()
      item = create_item(catalogue)

      put_slug("phoenix_kit_cat_items", item.uuid, %{
        "en-US" => "red-vase",
        "fr-FR" => "vase-rouge"
      })

      %{rows: rows} =
        Repo.query!(
          "SELECT lang, value FROM phoenix_kit_cat_item_slugs WHERE item_uuid::text = $1 ORDER BY lang",
          [item.uuid]
        )

      assert rows == [["en", "red-vase"], ["fr", "vase-rouge"]]
    end

    test "a duplicate slug in the same language raises the pkey constraint" do
      catalogue = create_catalogue()
      item_a = create_item(catalogue)
      item_b = create_item(catalogue)

      put_slug("phoenix_kit_cat_items", item_a.uuid, %{"en-US" => "red-vase"})

      assert_raise Postgrex.Error, ~r/phoenix_kit_cat_item_slugs_pkey/, fn ->
        put_slug("phoenix_kit_cat_items", item_b.uuid, %{"en-US" => "red-vase"})
      end
    end

    test "updating an item's slug drops the old projected value" do
      catalogue = create_catalogue()
      item = create_item(catalogue)

      put_slug("phoenix_kit_cat_items", item.uuid, %{"en-US" => "red-vase"})
      put_slug("phoenix_kit_cat_items", item.uuid, %{"en-US" => "blue-vase"})

      %{rows: rows} =
        Repo.query!(
          "SELECT value FROM phoenix_kit_cat_item_slugs WHERE item_uuid::text = $1",
          [item.uuid]
        )

      assert rows == [["blue-vase"]]
    end
  end

  describe "category slug projection" do
    test "a trigger projects every language of a category's slug" do
      catalogue = create_catalogue()
      category = create_category(catalogue)

      put_slug("phoenix_kit_cat_categories", category.uuid, %{
        "en-US" => "vases",
        "fr-FR" => "vases-fr"
      })

      %{rows: rows} =
        Repo.query!(
          "SELECT lang, value FROM phoenix_kit_cat_category_slugs WHERE category_uuid::text = $1 ORDER BY lang",
          [category.uuid]
        )

      assert rows == [["en", "vases"], ["fr", "vases-fr"]]
    end

    test "a duplicate category slug in the same language raises the pkey constraint" do
      catalogue = create_catalogue()
      category_a = create_category(catalogue)
      category_b = create_category(catalogue)

      put_slug("phoenix_kit_cat_categories", category_a.uuid, %{"en-US" => "vases"})

      assert_raise Postgrex.Error, ~r/phoenix_kit_cat_category_slugs_pkey/, fn ->
        put_slug("phoenix_kit_cat_categories", category_b.uuid, %{"en-US" => "vases"})
      end
    end
  end

  describe "get_item_by_slug/3" do
    test "finds an item by its exact base-language slug, in either language" do
      catalogue = create_catalogue()

      item =
        create_item(catalogue, %{
          slug: %{"en-US" => "red-vase", "fr-FR" => "vase-rouge"}
        })

      assert {:ok, found_en} = Catalogue.get_item_by_slug("red-vase", "en-US")
      assert found_en.uuid == item.uuid

      assert {:ok, found_fr} = Catalogue.get_item_by_slug("vase-rouge", "fr")
      assert found_fr.uuid == item.uuid
    end

    test "returns {:error, :not_found} for an unknown slug or the wrong language" do
      catalogue = create_catalogue()
      create_item(catalogue, %{slug: %{"fr-FR" => "vase-rouge"}})

      assert Catalogue.get_item_by_slug("no-such-slug", "en-US") == {:error, :not_found}
      # "vase-rouge" exists, but only under "fr" — not under "en".
      assert Catalogue.get_item_by_slug("vase-rouge", "en-US") == {:error, :not_found}
    end

    test "any_lang: true falls back to any language and names the match" do
      catalogue = create_catalogue()
      item = create_item(catalogue, %{slug: %{"fr-FR" => "vase-rouge"}})

      assert {:ok, found, "fr"} =
               Catalogue.get_item_by_slug("vase-rouge", "en-US", any_lang: true)

      assert found.uuid == item.uuid
    end

    test "forwards options other than :any_lang to get_item/2" do
      catalogue = create_catalogue()
      item = create_item(catalogue, %{slug: %{"en-US" => "red-vase"}})

      assert {:ok, found} =
               Catalogue.get_item_by_slug("red-vase", "en-US", preload: [:catalogue])

      assert found.uuid == item.uuid
      assert %PhoenixKitCatalogue.Schemas.Catalogue{} = found.catalogue
    end

    test "any_lang: true names the match even when the base language itself matched" do
      catalogue = create_catalogue()
      item = create_item(catalogue, %{slug: %{"en-US" => "red-vase"}})

      assert {:ok, found, "en"} =
               Catalogue.get_item_by_slug("red-vase", "en-US", any_lang: true)

      assert found.uuid == item.uuid
    end

    test "qualifies the projection table with the configured schema prefix" do
      Application.put_env(:phoenix_kit, :prefix, "nonexistent_pkc_schema")

      on_exit(fn -> Application.delete_env(:phoenix_kit, :prefix) end)

      assert_raise Postgrex.Error, ~r/nonexistent_pkc_schema\.phoenix_kit_cat_item_slugs/, fn ->
        Catalogue.get_item_by_slug("whatever", "en-US")
      end
    end
  end

  describe "item_slug_taken?/3 (the generation probe)" do
    test "sees a live or trashed item's slug, folds the language, and excludes the owner" do
      catalogue = create_catalogue()
      item = create_item(catalogue, %{slug: %{"en-US" => "red-vase"}})

      assert Catalogue.item_slug_taken?("red-vase", "en-US")
      assert Catalogue.item_slug_taken?("red-vase", "en-GB")
      refute Catalogue.item_slug_taken?("red-vase", "fr-FR")
      refute Catalogue.item_slug_taken?("blue-vase", "en-US")
      refute Catalogue.item_slug_taken?("red-vase", "en-US", exclude_uuid: item.uuid)

      # A trashed item keeps its projection row: its slug stays reserved,
      # so a re-created "Red vase" must probe as taken and get a suffix
      # instead of failing the projection's primary key.
      {:ok, _} = Catalogue.trash_item(item)
      assert Catalogue.item_slug_taken?("red-vase", "en-US")
    end

    test "category_slug_taken?/3 mirrors it" do
      catalogue = create_catalogue()
      category = create_category(catalogue, %{slug: %{"fr-FR" => "vases"}})

      assert Catalogue.category_slug_taken?("vases", "fr")
      refute Catalogue.category_slug_taken?("vases", "fr", exclude_uuid: category.uuid)
      refute Catalogue.category_slug_taken?("vases", "en-US")
    end
  end

  describe "get_category_by_slug/3" do
    test "finds a category by its exact base-language slug" do
      catalogue = create_catalogue()
      category = create_category(catalogue, %{slug: %{"en-US" => "vases"}})

      assert {:ok, found} = Catalogue.get_category_by_slug("vases", "en-US")
      assert found.uuid == category.uuid
    end

    test "returns {:error, :not_found} for an unknown slug" do
      catalogue = create_catalogue()
      create_category(catalogue)

      assert Catalogue.get_category_by_slug("no-such-slug", "en-US") == {:error, :not_found}
    end

    test "any_lang: true falls back to any language and names the match" do
      catalogue = create_catalogue()
      category = create_category(catalogue, %{slug: %{"fr-FR" => "vases-fr"}})

      assert {:ok, found, "fr"} =
               Catalogue.get_category_by_slug("vases-fr", "en-US", any_lang: true)

      assert found.uuid == category.uuid
    end
  end
end
