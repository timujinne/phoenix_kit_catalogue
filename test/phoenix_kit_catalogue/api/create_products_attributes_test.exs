defmodule PhoenixKitCatalogue.API.CreateProductsAttributesTest do
  @moduledoc "`create_products` with attribute values: validated up front, applied after the item."

  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase, only: [fixture_catalogue: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitCatalogue.Catalogue.PubSub
  alias PhoenixKitCatalogue.Test.{ApiCase, MediaFixtures, QueryHook}

  if Code.ensure_loaded?(PhoenixKitEntities.Managed) do
    setup do
      AttributeSets.register_deletion_guard()
      PhoenixKit.Settings.update_setting("entities_enabled", "true")
      on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)

      # entities fills a new set's creator from an existing user
      MediaFixtures.insert_user!()

      {:ok, set} = Catalogue.create_attribute_set(%{name: "Create colors"})
      {:ok, red} = Catalogue.create_attribute_set_value(set, %{label: "Red"})
      %{catalogue: fixture_catalogue(%{name: "Create Attr Cat"}), set: set, red: red}
    end

    test "attaches the set and stores the selection", ctx do
      input = %{
        "catalogue_id" => ctx.catalogue.uuid,
        "items" => [
          %{
            "sku" => "A-1",
            "name" => "Red thing",
            "attributes" => [%{"set_id" => ctx.set.uuid, "values" => [ctx.red.slug]}]
          }
        ]
      }

      assert {:ok, %{"results" => [%{"action" => "created", "id" => id}]}} =
               ApiCase.call("catalogue.create_products", input)

      assert [%{set_uuid: set_uuid, data: %{"selected_value_slugs" => selected}}] =
               Catalogue.list_attribute_set_attachments(id)

      assert set_uuid == ctx.set.uuid
      assert selected == [ctx.red.slug]

      # The attribute writes carry the actor and `via: api` / the tool too.
      for action <- ~w(attribute_set.attached attribute_set.selection_changed) do
        log =
          assert_activity_logged(action,
            resource_uuid: ctx.set.uuid,
            actor_uuid: ApiCase.user_uuid()
          )

        assert log.metadata["via"] == "api", action
        assert log.metadata["tool"] == "catalogue.create_products", action
        assert log.mode == "auto", action
      end
    end

    test "an unknown set or value rejects the row BEFORE the item is created", ctx do
      input = %{
        "catalogue_id" => ctx.catalogue.uuid,
        "items" => [
          %{
            "sku" => "A-2",
            "name" => "Bad value",
            "attributes" => [%{"set_id" => ctx.set.uuid, "values" => ["nope"]}]
          },
          %{
            "sku" => "A-3",
            "name" => "Bad set",
            "attributes" => [%{"set_id" => Ecto.UUID.generate(), "values" => []}]
          }
        ]
      }

      assert {:ok, %{"results" => [one, two]}} = ApiCase.call("catalogue.create_products", input)

      assert one["error"]["code"] == "validation_failed"
      assert one["error"]["context"]["unknown"] == ["nope"]
      assert one["error"]["context"]["allowed"] == [ctx.red.slug]
      assert two["error"]["code"] == "validation_failed"
      assert Catalogue.list_items_for_catalogue(ctx.catalogue.uuid) == []
    end

    test "an attribute write that fails after the item was created answers a fixed sentence and a code",
         ctx do
      input = %{
        "catalogue_id" => ctx.catalogue.uuid,
        "items" => [
          %{
            "sku" => "A-5",
            "name" => "Half done",
            "attributes" => [%{"set_id" => ctx.set.uuid, "values" => [ctx.red.slug]}]
          }
        ]
      }

      # The set goes away between the item's insert and the attribute write.
      assert {:ok, %{"results" => [row]}} =
               QueryHook.after_query(
                 ~s(INSERT INTO "phoenix_kit_activities"),
                 fn ->
                   {:ok, _} =
                     Catalogue.delete_attribute_set(Catalogue.get_attribute_set(ctx.set.uuid))
                 end,
                 fn -> ApiCase.call("catalogue.create_products", input) end
               )

      assert row["action"] == "error"
      assert row["error"]["context"] == %{"created" => true, "reason" => "set_not_found"}
      assert row["error"]["message"] =~ "attributes were not saved"
      refute row["error"]["message"] =~ "set_not_found"
      refute row["error"]["message"] =~ "Ecto"
      assert Catalogue.get_item!(row["id"]).name == "Half done"
    end

    test "attribute writes announce no per-item event, only the one bulk event", ctx do
      :ok = PubSub.subscribe()
      flush()

      input = %{
        "catalogue_id" => ctx.catalogue.uuid,
        "items" => [
          %{
            "sku" => "A-4",
            "name" => "Broadcast thing",
            "attributes" => [%{"set_id" => ctx.set.uuid, "values" => [ctx.red.slug]}]
          }
        ]
      }

      assert {:ok, %{"results" => [%{"action" => "created", "id" => id}]}} =
               ApiCase.call("catalogue.create_products", input)

      cat_uuid = ctx.catalogue.uuid
      assert_receive {:catalogue_bulk_change, ^cat_uuid, :created, [^id], _from}
      refute_receive {:catalogue_data_changed, :item, ^id, _}, 100
      assert_receive {:catalogue_data_changed, :item, nil, ^cat_uuid}
    end

    defp flush do
      receive do
        _ -> flush()
      after
        0 -> :ok
      end
    end
  end
end
