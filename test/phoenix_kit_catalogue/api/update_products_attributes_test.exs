defmodule PhoenixKitCatalogue.API.UpdateProductsAttributesTest do
  @moduledoc "`update_products` with attribute values: validated before any write."

  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase,
    only: [fixture_catalogue: 1, fixture_category: 2, fixture_item: 1]

  alias PhoenixKitCatalogue.API.Attributes
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitCatalogue.Catalogue.PubSub
  alias PhoenixKitCatalogue.Test.{ApiCase, MediaFixtures, QueryHook}

  @tool "catalogue.update_products"

  if Code.ensure_loaded?(PhoenixKitEntities.Managed) do
    setup do
      AttributeSets.register_deletion_guard()
      PhoenixKit.Settings.update_setting("entities_enabled", "true")
      on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)

      # entities fills a new set's creator from an existing user
      MediaFixtures.insert_user!()

      {:ok, set} = Catalogue.create_attribute_set(%{name: "Update colors"})
      {:ok, red} = Catalogue.create_attribute_set_value(set, %{label: "Red"})
      {:ok, blue} = Catalogue.create_attribute_set_value(set, %{label: "Blue"})
      catalogue = fixture_catalogue(%{name: "Update Attr Cat"})
      item = fixture_item(%{name: "Colourful", catalogue_uuid: catalogue.uuid})
      %{catalogue: catalogue, item: item, set: set, red: red, blue: blue}
    end

    defp run_update(ctx, changes),
      do:
        ApiCase.call(@tool, %{
          "catalogue_id" => ctx.catalogue.uuid,
          "items" => [%{"ref" => %{"id" => ctx.item.uuid}, "changes" => changes}]
        })

    test "attaches the set, replaces the selection, and an attributes-only change counts as updated",
         ctx do
      assert {:ok, %{"results" => [%{"action" => "updated"}]}} =
               run_update(ctx, %{
                 "attributes" => [%{"set_id" => ctx.set.uuid, "values" => [ctx.red.slug]}]
               })

      assert Attributes.selection(ctx.item.uuid, ctx.set.uuid) == [
               ctx.red.slug
             ]

      assert {:ok, %{"results" => [%{"action" => "updated"}]}} =
               run_update(ctx, %{
                 "attributes" => [%{"set_id" => ctx.set.uuid, "values" => [ctx.blue.slug]}]
               })

      assert Attributes.selection(ctx.item.uuid, ctx.set.uuid) == [
               ctx.blue.slug
             ]
    end

    test "re-sending the current selection is unchanged, not updated", ctx do
      input = %{"attributes" => [%{"set_id" => ctx.set.uuid, "values" => [ctx.red.slug]}]}
      assert {:ok, %{"results" => [%{"action" => "updated"}]}} = run_update(ctx, input)

      # the same selection again: nothing changed
      assert {:ok, %{"results" => [%{"action" => "unchanged"}], "summary" => %{"unchanged" => 1}}} =
               run_update(ctx, input)
    end

    test "an unknown value rejects the whole row before anything is written", ctx do
      assert {:ok, %{"results" => [row]}} =
               run_update(ctx, %{
                 "name" => "Renamed",
                 "attributes" => [%{"set_id" => ctx.set.uuid, "values" => ["nope"]}]
               })

      assert row["action"] == "error"
      assert row["error"]["code"] == "validation_failed"
      assert row["error"]["context"]["unknown"] == ["nope"]
      assert Catalogue.get_item!(ctx.item.uuid).name == "Colourful"
      assert Catalogue.list_attribute_set_attachments(ctx.item.uuid) == []
    end

    test "a dry run shows the selection that would change", ctx do
      {:ok, _} = Catalogue.attach_attribute_set(ctx.item.uuid, ctx.set.uuid)
      :ok = Catalogue.set_attribute_set_selection(ctx.item.uuid, ctx.set.uuid, [ctx.red.slug])

      assert {:preview, %{"rows" => [row]}, _} =
               ApiCase.call(
                 @tool,
                 %{
                   "catalogue_id" => ctx.catalogue.uuid,
                   "items" => [
                     %{
                       "ref" => %{"id" => ctx.item.uuid},
                       "changes" => %{
                         "attributes" => [
                           %{"set_id" => ctx.set.uuid, "values" => [ctx.blue.slug]}
                         ]
                       }
                     }
                   ]
                 },
                 %{dry_run?: true}
               )

      assert row["changes"]["attributes." <> ctx.set.uuid] == %{
               "from" => ctx.red.slug,
               "to" => ctx.blue.slug
             }

      assert Attributes.selection(ctx.item.uuid, ctx.set.uuid) == [
               ctx.red.slug
             ]
    end

    test "attribute writes announce no per-item event, only the one bulk event", ctx do
      :ok = PubSub.subscribe()
      flush()

      assert {:ok, %{"results" => [%{"action" => "updated", "id" => id}]}} =
               run_update(ctx, %{
                 "attributes" => [%{"set_id" => ctx.set.uuid, "values" => [ctx.red.slug]}]
               })

      cat_uuid = ctx.catalogue.uuid
      assert_receive {:catalogue_bulk_change, ^cat_uuid, :updated, [^id], _from}
      refute_receive {:catalogue_data_changed, :item, ^id, _}, 100
      assert_receive {:catalogue_data_changed, :item, nil, ^cat_uuid}
    end

    test "attribute writes say who and how: actor, mode, via and tool on both entries", ctx do
      assert {:ok, %{"results" => [%{"action" => "updated"}]}} =
               run_update(ctx, %{
                 "attributes" => [%{"set_id" => ctx.set.uuid, "values" => [ctx.red.slug]}]
               })

      for action <- ["attribute_set.attached", "attribute_set.selection_changed"] do
        entry =
          assert_activity_logged(action,
            resource_uuid: ctx.set.uuid,
            actor_uuid: ApiCase.user_uuid()
          )

        assert entry.mode == "auto"
        assert entry.metadata["via"] == "api"
        assert entry.metadata["tool"] == "catalogue.update_products"
        assert entry.metadata["request_id"] == "req-test"
      end
    end

    test "an item that moved and then failed on its attributes is still announced", ctx do
      shelf = fixture_category(ctx.catalogue, %{name: "Attribute shelf"})
      :ok = PubSub.subscribe()
      flush()

      result =
        QueryHook.after_query(
          ~s(INSERT INTO "phoenix_kit_activities"),
          fn ->
            {:ok, _} = Catalogue.delete_attribute_set(Catalogue.get_attribute_set(ctx.set.uuid))
          end,
          fn ->
            run_update(ctx, %{
              "category_id" => shelf.uuid,
              "attributes" => [%{"set_id" => ctx.set.uuid, "values" => [ctx.red.slug]}]
            })
          end
        )

      assert {:ok, %{"results" => [row]}} = result
      assert row["action"] == "error"
      assert row["id"] == ctx.item.uuid
      assert row["error"]["context"] == %{"saved" => true, "reason" => "set_not_found"}
      assert row["error"]["message"] =~ "attributes were not saved"
      refute row["error"]["message"] =~ ":set_not_found"

      assert Catalogue.get_item!(ctx.item.uuid).category_uuid == shelf.uuid
      cat_uuid = ctx.catalogue.uuid
      item_uuid = ctx.item.uuid
      assert_receive {:catalogue_bulk_change, ^cat_uuid, :updated, [^item_uuid], _from}
    end

    test "a failed attribute write is announced even when nothing else was saved: sets are written one by one",
         ctx do
      :ok = PubSub.subscribe()
      flush()

      result =
        QueryHook.after_query(
          ~s(FROM "phoenix_kit_cat_item_attribute_sets"),
          fn ->
            {:ok, _} = Catalogue.delete_attribute_set(Catalogue.get_attribute_set(ctx.set.uuid))
          end,
          fn ->
            run_update(ctx, %{
              "attributes" => [%{"set_id" => ctx.set.uuid, "values" => [ctx.red.slug]}]
            })
          end
        )

      assert {:ok, %{"results" => [row]}} = result
      assert row["error"]["context"] == %{"saved" => false, "reason" => "set_not_found"}

      cat_uuid = ctx.catalogue.uuid
      item_uuid = ctx.item.uuid
      assert_receive {:catalogue_bulk_change, ^cat_uuid, :updated, [^item_uuid], _from}
    end

    test "a dry run reads each item's attachments once, whatever the number of entries", ctx do
      {:ok, second} = Catalogue.create_attribute_set(%{name: "Update sizes"})
      {:ok, big} = Catalogue.create_attribute_set_value(second, %{label: "Big"})
      other_item = fixture_item(%{name: "Second", catalogue_uuid: ctx.catalogue.uuid})

      entry = fn item ->
        %{
          "ref" => %{"id" => item.uuid},
          "changes" => %{
            "attributes" => [
              %{"set_id" => ctx.set.uuid, "values" => [ctx.red.slug]},
              %{"set_id" => second.uuid, "values" => [big.slug]}
            ]
          }
        }
      end

      {result, sql} =
        QueryHook.queries(fn ->
          ApiCase.call(
            @tool,
            %{
              "catalogue_id" => ctx.catalogue.uuid,
              "items" => [entry.(ctx.item), entry.(other_item)]
            },
            %{dry_run?: true}
          )
        end)

      assert {:preview, %{"rows" => [first, _second]}, _} = result
      assert map_size(first["changes"]) == 2

      attachment_reads = Enum.count(sql, &(&1 =~ "FROM \"phoenix_kit_cat_item_attribute_sets\""))
      assert attachment_reads == 2, "one read per row, got #{attachment_reads}: #{inspect(sql)}"
    end

    test "the same set named by many rows is looked up once", ctx do
      items =
        for n <- 1..3, do: fixture_item(%{name: "Bulk #{n}", catalogue_uuid: ctx.catalogue.uuid})

      input = fn rows ->
        %{
          "catalogue_id" => ctx.catalogue.uuid,
          "items" =>
            for i <- rows do
              %{
                "ref" => %{"id" => i.uuid},
                "changes" => %{
                  "attributes" => [%{"set_id" => ctx.set.uuid, "values" => [ctx.red.slug]}]
                }
              }
            end
        }
      end

      run = fn rows ->
        {_result, sql} =
          QueryHook.queries(fn -> ApiCase.call(@tool, input.(rows), %{dry_run?: true}) end)

        sql
      end

      one = run.(Enum.take(items, 1))
      three = run.(items)

      # the set (entity, values, hidden values) is read from the entities tables
      set_reads = fn sql -> Enum.count(sql, &(&1 =~ "phoenix_kit_entit")) end
      assert set_reads.(one) > 0
      assert set_reads.(three) == set_reads.(one), inspect(three)
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
