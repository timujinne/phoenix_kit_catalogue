defmodule PhoenixKitCatalogue.ApiActivityTest do
  @moduledoc """
  What the shop API adds to the change log: who wrote it, how, and
  what moved, down to `data` sub-paths and per-language slugs.
  """

  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase,
    only: [fixture_catalogue: 1, fixture_category: 2, fixture_item: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.ActivityLog
  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitCatalogue.Catalogue.PubSub
  alias PhoenixKitCatalogue.Catalogue.Shared
  alias PhoenixKitCatalogue.Schemas.Item
  alias PhoenixKitCatalogue.Test.MediaFixtures

  @actor "00000000-0000-7000-8000-000000000001"
  @meta %{
    "via" => "api",
    "key_prefix" => "abcd1234",
    "request_id" => "req-1",
    "tool" => "catalogue.update_products"
  }

  defp opts(extra \\ []),
    do: Keyword.merge([actor_uuid: @actor, mode: "auto", log_metadata: @meta], extra)

  describe "Shared.log_activity/2 with :log_metadata" do
    test "an entry without metadata of its own gets only the allowed extra keys" do
      resource = Ecto.UUID.generate()

      :ok =
        Shared.log_activity(
          %{
            action: "item.updated",
            mode: "manual",
            resource_type: "item",
            resource_uuid: resource
          },
          log_metadata: %{"via" => "api", "changes" => "forged", "name" => "forged", atom: 1},
          broadcast: false
        )

      row = assert_activity_logged("item.updated", resource_uuid: resource)
      assert row.metadata == %{"via" => "api"}
    end
  end

  describe "ActivityLog.with_changes/5" do
    test "reports a data path that moved, as data.<path>" do
      before = %Item{data: %{"ecommerce" => %{"compare_at_price" => "10", "tags" => ["a"]}}}
      now = %Item{data: %{"ecommerce" => %{"compare_at_price" => "12", "tags" => ["a"]}}}

      paths = [["ecommerce", "compare_at_price"], ["ecommerce", "tags"]]

      assert %{"changes" => changes} = ActivityLog.with_changes(%{}, before, now, [], paths)
      assert changes == %{"data.ecommerce.compare_at_price" => %{"from" => "10", "to" => "12"}}
    end

    test "a path that appears or disappears reads as blank on the missing side" do
      before = %Item{data: %{}}
      now = %Item{data: %{"api" => %{"external_id" => "X-1"}}}

      assert %{"changes" => %{"data.api.external_id" => %{"from" => "", "to" => "X-1"}}} =
               ActivityLog.with_changes(%{}, before, now, [], [["api", "external_id"]])

      assert %{"changes" => %{"data.api.external_id" => %{"from" => "X-1", "to" => ""}}} =
               ActivityLog.with_changes(%{}, now, before, [], [["api", "external_id"]])
    end

    test "a map or list leaf is written as JSON and a long one is clipped" do
      before = %Item{data: %{}}
      long = String.duplicate("x", 800)

      now = %Item{
        data: %{"ecommerce" => %{"price_modifiers" => %{"size" => %{"L" => "5"}}, "note" => long}}
      }

      paths = [["ecommerce", "price_modifiers"], ["ecommerce", "note"]]
      assert %{"changes" => changes} = ActivityLog.with_changes(%{}, before, now, [], paths)

      assert changes["data.ecommerce.price_modifiers"]["to"] == ~s({"size":{"L":"5"}})
      assert String.length(changes["data.ecommerce.note"]["to"]) == 501
      assert String.ends_with?(changes["data.ecommerce.note"]["to"], "…")
    end

    test "a long multi-byte value under 500 characters is not clipped" do
      long = String.duplicate("ж", 300)
      now = %Item{data: %{"ecommerce" => %{"note" => long}}}

      assert %{"changes" => changes} =
               ActivityLog.with_changes(%{}, %Item{data: %{}}, now, [], [["ecommerce", "note"]])

      assert changes["data.ecommerce.note"]["to"] == long
    end

    test "a list leaf that changed is written as JSON" do
      before = %Item{data: %{"ecommerce" => %{"tags" => []}}}
      now = %Item{data: %{"ecommerce" => %{"tags" => ["a", "b"]}}}

      assert %{"changes" => %{"data.ecommerce.tags" => diff}} =
               ActivityLog.with_changes(%{}, before, now, [], [["ecommerce", "tags"]])

      assert diff == %{"from" => "[]", "to" => ~s(["a","b"])}
    end

    test "an untouched data path adds nothing" do
      item = %Item{data: %{"ecommerce" => %{"compare_at_price" => "10"}}}

      assert ActivityLog.with_changes(%{"name" => "n"}, item, item, [], [
               ["ecommerce", "compare_at_price"]
             ]) == %{"name" => "n"}
    end

    test "slug is reported per language" do
      before = %Item{slug: %{"en-US" => "old", "de-DE" => "alt"}}
      now = %Item{slug: %{"en-US" => "new", "de-DE" => "alt", "fr-FR" => "nouveau"}}

      assert %{"changes" => changes} = ActivityLog.with_changes(%{}, before, now, [:slug])

      assert changes == %{
               "slug.en-US" => %{"from" => "old", "to" => "new"},
               "slug.fr-FR" => %{"from" => "", "to" => "nouveau"}
             }
    end
  end

  describe "slug diff" do
    test "a language that goes from missing to blank adds nothing" do
      before = %Item{slug: %{"en-US" => "same"}}
      now = %Item{slug: %{"en-US" => "same", "de-DE" => ""}}

      assert ActivityLog.with_changes(%{}, before, now, [:slug]) == %{}
    end
  end

  describe "ActivityLog.with_extra/2" do
    test "the extra map never supplies the diff or the identity" do
      extra = %{"changes" => %{"x" => 1}, "name" => "evil", "sku" => "S", "via" => "api"}

      assert ActivityLog.with_extra(%{"note" => "n"}, extra) == %{"note" => "n", "via" => "api"}
    end

    test "atom keys of the extra map are not taken" do
      assert ActivityLog.with_extra(%{"a" => 1}, %{via: "api", changes: %{}}) == %{"a" => 1}
    end

    test "the entry's own keys win over the extra ones" do
      assert ActivityLog.with_extra(%{"name" => "real"}, %{"name" => "evil", "via" => "api"}) ==
               %{"name" => "real", "via" => "api"}
    end

    test "nil and an empty map change nothing" do
      assert ActivityLog.with_extra(%{"a" => 1}, nil) == %{"a" => 1}
      assert ActivityLog.with_extra(%{"a" => 1}, %{}) == %{"a" => 1}
    end
  end

  describe "log_metadata reaches the entry" do
    test "update_item/3 carries it and keeps its own keys and diff" do
      item = fixture_item(%{name: "Old"})

      {:ok, updated} =
        Catalogue.update_item(
          item,
          %{name: "New"},
          opts(log_metadata: Map.put(@meta, "name", "evil"))
        )

      row =
        assert_activity_logged("item.updated", resource_uuid: updated.uuid, actor_uuid: @actor)

      assert row.mode == "auto"
      assert row.metadata["via"] == "api"
      assert row.metadata["key_prefix"] == "abcd1234"
      assert row.metadata["tool"] == "catalogue.update_products"
      assert row.metadata["name"] == "New"
      assert row.metadata["changes"]["name"] == %{"from" => "Old", "to" => "New"}
    end

    test "without the option the entry has exactly the keys it had before" do
      item = fixture_item(%{name: "Old"})
      {:ok, updated} = Catalogue.update_item(item, %{name: "New"}, actor_uuid: @actor)

      row = assert_activity_logged("item.updated", resource_uuid: updated.uuid)
      assert row.mode == "manual"
      assert row.metadata |> Map.keys() |> Enum.sort() == ["changes", "name", "sku"]
    end

    test "a slug change leaves the old slug in the diff" do
      item = fixture_item(%{name: "Vase", slug: %{"en-US" => "old-vase"}})
      {:ok, updated} = Catalogue.update_item(item, %{slug: %{"en-US" => "new-vase"}}, opts())

      row = assert_activity_logged("item.updated", resource_uuid: updated.uuid)

      assert row.metadata["changes"]["slug.en-US"] ==
               %{"from" => "old-vase", "to" => "new-vase"}
    end

    test "create_item/2, trash_item/2 and restore_item/2 carry it" do
      catalogue = fixture_catalogue(%{name: "Meta Cat"})

      {:ok, item} =
        Catalogue.create_item(%{name: "Fresh", catalogue_uuid: catalogue.uuid}, opts())

      {:ok, trashed} = Catalogue.trash_item(item, opts())
      {:ok, _} = Catalogue.restore_item(trashed, opts())

      for action <- ~w(item.created item.trashed item.restored) do
        row = assert_activity_logged(action, resource_uuid: item.uuid, actor_uuid: @actor)
        assert row.metadata["via"] == "api", "#{action} lost the metadata"
        assert row.metadata["name"] == "Fresh"
        assert row.mode == "auto", "#{action} lost the mode"
      end
    end

    test "create_category/2 and update_category/3 carry it" do
      catalogue = fixture_catalogue(%{name: "Meta Cat 2"})

      {:ok, category} =
        Catalogue.create_category(%{name: "Shelf", catalogue_uuid: catalogue.uuid}, opts())

      {:ok, _} = Catalogue.update_category(category, %{name: "Shelf 2"}, opts())

      for action <- ~w(category.created category.updated) do
        row = assert_activity_logged(action, resource_uuid: category.uuid)
        assert row.metadata["via"] == "api", "#{action} lost the metadata"
      end
    end

    test "update_category/3 reports a new parent and position in the diff" do
      catalogue = fixture_catalogue(%{name: "Tree Cat"})
      parent = fixture_category(catalogue, %{name: "Parent"})
      child = fixture_category(catalogue, %{name: "Child"})

      {:ok, _} =
        Catalogue.update_category(child, %{parent_uuid: parent.uuid, position: 7}, opts())

      row = assert_activity_logged("category.updated", resource_uuid: child.uuid)
      assert row.metadata["changes"]["parent_uuid"] == %{"from" => "", "to" => parent.uuid}
      assert row.metadata["changes"]["position"]["to"] == "7"
    end

    test "update_category/3 reports a changed slug per language, old one included" do
      catalogue = fixture_catalogue(%{name: "Slug Cat"})
      category = fixture_category(catalogue, %{name: "Slugged", slug: %{"en-US" => "old"}})

      {:ok, _} = Catalogue.update_category(category, %{slug: %{"en-US" => "new"}}, opts())

      row = assert_activity_logged("category.updated", resource_uuid: category.uuid)
      assert row.metadata["changes"] == %{"slug.en-US" => %{"from" => "old", "to" => "new"}}
    end

    test "update_category/3 without a move adds neither parent_uuid nor position" do
      catalogue = fixture_catalogue(%{name: "Still Cat"})
      category = fixture_category(catalogue, %{name: "Still"})

      {:ok, _} = Catalogue.update_category(category, %{name: "Still 2"}, opts())

      row = assert_activity_logged("category.updated", resource_uuid: category.uuid)
      assert Map.keys(row.metadata["changes"]) == ["name"]
    end

    test "move_item_to_category/3 carries it" do
      catalogue = fixture_catalogue(%{name: "Meta Cat 3"})
      category = fixture_category(catalogue, %{name: "Target"})
      item = fixture_item(%{name: "Mover", catalogue_uuid: catalogue.uuid})

      {:ok, _} = Catalogue.move_item_to_category(item, category.uuid, opts())

      row = assert_activity_logged("item.moved", resource_uuid: item.uuid)
      assert row.metadata["via"] == "api"
      assert row.mode == "auto"
    end

    test "trash_item/2 honours broadcast: false" do
      catalogue = fixture_catalogue(%{name: "Quiet Cat"})
      {:ok, item} = Catalogue.create_item(%{name: "Quiet", catalogue_uuid: catalogue.uuid})
      :ok = PubSub.subscribe()
      flush_pubsub()

      {:ok, _} = Catalogue.trash_item(item, broadcast: false)

      refute_receive {:catalogue_data_changed, :item, _, _}, 100
    end

    test "restore_item/2 honours broadcast: false" do
      catalogue = fixture_catalogue(%{name: "Quiet Cat 2"})
      {:ok, item} = Catalogue.create_item(%{name: "Quiet 2", catalogue_uuid: catalogue.uuid})
      {:ok, trashed} = Catalogue.trash_item(item, broadcast: false)
      :ok = PubSub.subscribe()
      flush_pubsub()

      {:ok, _} = Catalogue.restore_item(trashed, broadcast: false)

      refute_receive {:catalogue_data_changed, :item, _, _}, 100
    end
  end

  if Code.ensure_loaded?(PhoenixKitEntities.Managed) do
    describe "attribute writes" do
      setup do
        AttributeSets.register_deletion_guard()
        PhoenixKit.Settings.update_setting("entities_enabled", "true")
        on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)
        :ok
      end

      test "attach_attribute_set/3 carries the log metadata and keeps the entry's own keys" do
        # entities fills a new set's creator from an existing user
        MediaFixtures.insert_user!()

        {:ok, set} = Catalogue.create_attribute_set(%{name: "Meta colors"})
        item = fixture_item(%{name: "Attach me"})

        {:ok, _} =
          Catalogue.attach_attribute_set(
            item.uuid,
            set.uuid,
            opts(log_metadata: Map.put(@meta, "item_uuid", "evil"))
          )

        row = assert_activity_logged("attribute_set.attached", resource_uuid: set.uuid)
        assert row.metadata["via"] == "api"
        assert row.metadata["tool"] == "catalogue.update_products"
        assert row.metadata["item_uuid"] == item.uuid
      end
    end
  end

  describe "ActivityLog.log_many/1" do
    test "stores every entry under the catalogue module" do
      assert :ok =
               ActivityLog.log_many([
                 %{
                   action: "item.updated",
                   mode: "auto",
                   resource_type: "item",
                   metadata: %{"n" => 1}
                 },
                 %{
                   action: "item.updated",
                   mode: "auto",
                   resource_type: "item",
                   metadata: %{"n" => 2}
                 }
               ])

      rows = Enum.filter(list_activities(), &(&1.action == "item.updated"))
      assert length(rows) == 2
      assert Enum.all?(rows, &(&1.module == "catalogue"))
    end

    test "an empty batch is a no-op" do
      before = list_activities()

      assert :ok = ActivityLog.log_many([])
      assert list_activities() == before
    end
  end

  defp flush_pubsub do
    receive do
      {:catalogue_data_changed, _, _, _} -> flush_pubsub()
    after
      0 -> :ok
    end
  end
end
