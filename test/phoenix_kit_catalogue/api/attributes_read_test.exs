defmodule PhoenixKitCatalogue.API.AttributesReadTest do
  @moduledoc "`get_products` shows an item's attribute sets with the selected value keys."

  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase, only: [fixture_catalogue: 1, fixture_item: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitCatalogue.Test.{ApiCase, MediaFixtures}

  if Code.ensure_loaded?(PhoenixKitEntities.Managed) do
    setup do
      AttributeSets.register_deletion_guard()
      PhoenixKit.Settings.update_setting("entities_enabled", "true")
      on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)

      # entities fills a new set's creator from an existing user
      MediaFixtures.insert_user!()

      {:ok, set} = Catalogue.create_attribute_set(%{name: "API colors"})
      {:ok, red} = Catalogue.create_attribute_set_value(set, %{label: "Red"})
      {:ok, blue} = Catalogue.create_attribute_set_value(set, %{label: "Blue"})
      catalogue = fixture_catalogue(%{name: "Attr Read Cat"})
      item = fixture_item(%{name: "Colourful", catalogue_uuid: catalogue.uuid})

      %{catalogue: catalogue, item: item, set: set, red: red, blue: blue}
    end

    test "attached sets come back with their value keys and the selection", ctx do
      {:ok, _} = Catalogue.attach_attribute_set(ctx.item.uuid, ctx.set.uuid)
      :ok = Catalogue.set_attribute_set_selection(ctx.item.uuid, ctx.set.uuid, [ctx.red.slug])

      assert {:ok, %{"results" => [%{"item" => card}]}} =
               ApiCase.call("catalogue.get_products", %{
                 "catalogue_id" => ctx.catalogue.uuid,
                 "refs" => [%{"id" => ctx.item.uuid}],
                 "fields" => ["attributes"]
               })

      assert [set_card] = card["attributes"]
      assert set_card["set_id"] == ctx.set.uuid
      assert set_card["name"] == "API colors"
      assert Enum.sort(set_card["values"]) == Enum.sort([ctx.red.slug, ctx.blue.slug])
      assert set_card["selected"] == [ctx.red.slug]
    end

    test "an item with no set has an empty list", ctx do
      assert {:ok, %{"results" => [%{"item" => %{"attributes" => []}}]}} =
               ApiCase.call("catalogue.get_products", %{
                 "catalogue_id" => ctx.catalogue.uuid,
                 "refs" => [%{"id" => ctx.item.uuid}],
                 "fields" => ["attributes"]
               })
    end
  end
end
