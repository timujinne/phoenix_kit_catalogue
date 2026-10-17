defmodule PhoenixKitCatalogue.DataOwnedPathsTest do
  @moduledoc """
  `update_item/3` / `update_category/3` option `:data_owned_paths`: a deep
  merge of named `data` sub-paths into the row as it is now, under a row lock,
  so a concurrent writer of a sibling key loses nothing.
  """

  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase,
    only: [fixture_catalogue: 1, fixture_category: 2, fixture_item: 1]

  alias PhoenixKitCatalogue.Catalogue

  @actor "00000000-0000-7000-8000-000000000001"
  @compare [["ecommerce", "compare_at_price"]]

  # Ecto's telemetry event for every statement the test repo runs.
  @query_event [:phoenix_kit_catalogue, :test, :repo, :query]

  # The text of every SQL statement `fun` runs in this process.
  defp query_texts(fun) do
    handler_id = {:query_texts, self(), System.unique_integer()}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      @query_event,
      fn _event, _measurements, %{query: query}, _config -> send(test_pid, {:query, query}) end,
      nil
    )

    try do
      fun.()
      collect_query_texts([])
    after
      :telemetry.detach(handler_id)
    end
  end

  defp collect_query_texts(acc) do
    receive do
      {:query, query} -> collect_query_texts([query | acc])
    after
      0 -> acc
    end
  end

  defp locking_reads(queries, table) do
    Enum.filter(queries, &(&1 =~ table and &1 =~ "FOR UPDATE"))
  end

  defp logged(action, uuid) do
    list_activities()
    |> Enum.filter(&(&1.action == action and &1.resource_uuid == Ecto.UUID.dump!(uuid)))
  end

  setup do
    catalogue = fixture_catalogue(%{name: "Paths Cat"})

    item =
      fixture_item(%{
        name: "Base",
        catalogue_uuid: catalogue.uuid,
        data: %{
          "ecommerce" => %{"shopify" => %{"id" => "1"}, "tags" => ["a"]},
          "meta" => %{"color" => "red"}
        }
      })

    %{catalogue: catalogue, item: item}
  end

  describe "update_item/3 with :data_owned_paths" do
    test "writes only the named path and keeps every sibling key", %{item: item} do
      attrs = %{data: %{"ecommerce" => %{"compare_at_price" => "9.50"}}}

      assert {:ok, updated} = Catalogue.update_item(item, attrs, data_owned_paths: @compare)

      assert updated.data["ecommerce"] == %{
               "shopify" => %{"id" => "1"},
               "tags" => ["a"],
               "compare_at_price" => "9.50"
             }

      assert updated.data["meta"] == %{"color" => "red"}
      assert Catalogue.get_item(item.uuid).data == updated.data
    end

    test "the row is read FOR UPDATE, so the lock is held until the commit", %{item: item} do
      queries =
        query_texts(fn ->
          assert {:ok, _} =
                   Catalogue.update_item(item, %{name: "Locked"},
                     data_owned_paths: @compare,
                     skip_derive: true
                   )
        end)

      assert [_one] = locking_reads(queries, "phoenix_kit_cat_items")
    end

    test "string-keyed attrs are read like atom-keyed ones", %{item: item} do
      attrs = %{
        "name" => "Stringy",
        "data" => %{"ecommerce" => %{"compare_at_price" => "9.50"}, "meta" => %{"color" => "x"}},
        "slug" => %{"de-DE" => "zeichen"}
      }

      opts = [data_owned_paths: @compare, slug_owned_langs: ["de-DE"]]
      assert {:ok, updated} = Catalogue.update_item(item, attrs, opts)

      assert updated.name == "Stringy"
      assert updated.slug["de-DE"] == "zeichen"

      assert updated.data["ecommerce"] == %{
               "shopify" => %{"id" => "1"},
               "tags" => ["a"],
               "compare_at_price" => "9.50"
             }

      assert updated.data["meta"] == %{"color" => "red"}
    end

    test "a stale copy cannot clobber what another writer stored since", %{item: item} do
      stale = Catalogue.get_item!(item.uuid)

      # the Shopify sync writes its own keys after `stale` was read
      {:ok, _} =
        Catalogue.update_item(item, %{
          data: %{"ecommerce" => %{"shopify" => %{"id" => "2"}, "tags" => ["new"]}}
        })

      attrs = %{data: %{"ecommerce" => %{"compare_at_price" => "9.50"}}}
      assert {:ok, updated} = Catalogue.update_item(stale, attrs, data_owned_paths: @compare)

      assert updated.data["ecommerce"] == %{
               "shopify" => %{"id" => "2"},
               "tags" => ["new"],
               "compare_at_price" => "9.50"
             }
    end

    test "the update is applied to the fresh row, so the logged from-value is the real one",
         %{item: item} do
      stale = Catalogue.get_item!(item.uuid)
      {:ok, _} = Catalogue.update_item(item, %{name: "Renamed by someone else"})

      {:ok, updated} = Catalogue.update_item(stale, %{name: "Mine"}, data_owned_paths: [])

      assert updated.name == "Mine"

      # Two `item.updated` rows exist for this item now (the rename by someone
      # else, then ours), and `assert_activity_logged/2` flunks unless exactly
      # one row matches: select ours by its diff instead.
      ours =
        "item.updated"
        |> logged(item.uuid)
        |> Enum.filter(&(get_in(&1.metadata, ["changes", "name", "to"]) == "Mine"))

      assert [row] = ours

      assert row.metadata["changes"]["name"] == %{
               "from" => "Renamed by someone else",
               "to" => "Mine"
             }
    end

    test "a nil leaf deletes the key and prunes the maps it empties", %{item: item} do
      {:ok, with_id} =
        Catalogue.update_item(item, %{data: %{"api" => %{"external_id" => "X-1"}}},
          data_owned_paths: [["api", "external_id"]]
        )

      assert with_id.data["api"] == %{"external_id" => "X-1"}

      {:ok, cleared} =
        Catalogue.update_item(with_id, %{data: %{"api" => %{"external_id" => nil}}},
          data_owned_paths: [["api", "external_id"]]
        )

      refute Map.has_key?(cleared.data, "api")
      assert cleared.data["ecommerce"]["shopify"] == %{"id" => "1"}
    end

    test "keys outside the owned paths are ignored even when attrs carries them", %{item: item} do
      attrs = %{
        data: %{
          "ecommerce" => %{"compare_at_price" => "5", "shopify" => %{"id" => "evil"}},
          "meta" => %{"color" => "blue"}
        }
      }

      {:ok, updated} = Catalogue.update_item(item, attrs, data_owned_paths: @compare)

      assert updated.data["ecommerce"]["shopify"] == %{"id" => "1"}
      assert updated.data["ecommerce"]["compare_at_price"] == "5"
      assert updated.data["meta"] == %{"color" => "red"}
    end

    test ":slug_owned_langs merges only the named languages into the locked row's slug map",
         %{item: item} do
      {:ok, with_slugs} =
        Catalogue.update_item(item, %{slug: %{"en-US" => "base", "de-DE" => "basis"}})

      stale = Catalogue.get_item!(item.uuid)

      # Another writer (the sweep, the item form, a second API call) stores a slug for a
      # DIFFERENT language after our read.
      {:ok, _} =
        Catalogue.update_item(with_slugs, %{
          slug: %{"en-US" => "base", "de-DE" => "basis", "fr-FR" => "base-fr"}
        })

      opts = [data_owned_paths: [], slug_owned_langs: ["de-DE"]]
      assert {:ok, updated} = Catalogue.update_item(stale, %{slug: %{"de-DE" => "neu"}}, opts)

      # The stale copy knew nothing of "fr-FR"; it survives. Only "de-DE" took our value.
      assert updated.slug == %{"en-US" => "base", "de-DE" => "neu", "fr-FR" => "base-fr"}

      # A blank or absent value for an owned language deletes just that language.
      assert {:ok, cleared} = Catalogue.update_item(updated, %{slug: %{}}, opts)
      assert cleared.slug == %{"en-US" => "base", "fr-FR" => "base-fr"}

      assert [log] =
               "item.updated"
               |> logged(item.uuid)
               |> Enum.filter(&(get_in(&1.metadata, ["changes", "slug.de-DE", "to"]) == ""))

      assert log.metadata["changes"]["slug.de-DE"] == %{"from" => "neu", "to" => ""}
    end

    test ":slug_owned_langs [] merges nothing: a slug map in attrs cannot replace the stored one",
         %{item: item} do
      stored = %{
        "en-US" => "base",
        "de-DE" => "basis",
        "fr-FR" => "base-fr",
        "es-ES" => "base-es"
      }

      {:ok, _} = Catalogue.update_item(item, %{slug: stored})
      stale = Catalogue.get_item!(item.uuid)

      attrs = %{name: "Renamed", slug: %{"en-US" => "base", "de-DE" => "basis"}}
      opts = [data_owned_paths: [], slug_owned_langs: []]

      assert {:ok, updated} = Catalogue.update_item(stale, attrs, opts)
      assert updated.name == "Renamed"
      assert updated.slug == stored
    end

    test ":slug_owned_langs without a :slug in attrs deletes no slug", %{item: item} do
      slugs = %{"en-US" => "base", "de-DE" => "basis"}
      {:ok, with_slugs} = Catalogue.update_item(item, %{slug: slugs})

      opts = [data_owned_paths: [], slug_owned_langs: ["de-DE"]]
      assert {:ok, renamed} = Catalogue.update_item(with_slugs, %{name: "Rename only"}, opts)
      assert renamed.slug == slugs

      # a :slug that is not a map is "nothing sent" too
      assert {:ok, same} = Catalogue.update_item(renamed, %{name: "Again", slug: nil}, opts)
      assert same.slug == slugs
    end

    test ":slug_owned_langs without :data_owned_paths, or with a bad value, raises", %{item: item} do
      assert_raise ArgumentError, ~r/needs :data_owned_paths/, fn ->
        Catalogue.update_item(item, %{slug: %{}}, slug_owned_langs: ["de-DE"])
      end

      for bad <- [["", "de-DE"], [:de], "de-DE"] do
        error =
          assert_raise ArgumentError, ~r/slug_owned_langs/, fn ->
            Catalogue.update_item(item, %{slug: %{}}, data_owned_paths: [], slug_owned_langs: bad)
          end

        # the message names the rule, never the offending value
        refute error.message =~ "de-DE"
      end
    end

    test "an owned path missing from attrs is left alone", %{item: item} do
      assert {:ok, updated} =
               Catalogue.update_item(item, %{description: "only this"},
                 data_owned_paths: @compare
               )

      assert updated.description == "only this"
      assert updated.data == item.data
    end

    test "logged_data_paths and log_metadata land in the entry", %{item: item} do
      meta = %{"via" => "api", "key_prefix" => "abcd1234"}

      {:ok, _} =
        Catalogue.update_item(item, %{data: %{"ecommerce" => %{"compare_at_price" => "9.50"}}},
          data_owned_paths: @compare,
          logged_data_paths: @compare ++ [["ecommerce", "tags"]],
          log_metadata: meta,
          actor_uuid: @actor
        )

      row = assert_activity_logged("item.updated", resource_uuid: item.uuid, actor_uuid: @actor)
      assert row.metadata["via"] == "api"

      # tags did not move, so it is not in the diff
      assert row.metadata["changes"] == %{
               "data.ecommerce.compare_at_price" => %{"from" => "", "to" => "9.50"}
             }
    end

    test "returns :not_found when the row is gone", %{item: item} do
      {:ok, _} = Catalogue.permanently_delete_item(item)

      assert {:error, :not_found} =
               Catalogue.update_item(item, %{name: "Ghost"}, data_owned_paths: [])
    end

    test "refuses :data_owned_keys together with :data_owned_paths", %{item: item} do
      assert_raise ArgumentError, ~r/mutually exclusive/, fn ->
        Catalogue.update_item(item, %{}, data_owned_keys: ["meta"], data_owned_paths: @compare)
      end
    end

    test "refuses malformed paths", %{item: item} do
      for bad <- [[["_trash"]], [[]], [[""]], [["a", 1]], "ecommerce", [["ok"], "no"]] do
        error =
          assert_raise ArgumentError, ~r/data_owned_paths/, fn ->
            Catalogue.update_item(item, %{}, data_owned_paths: bad)
          end

        refute error.message =~ "ecommerce"
      end
    end

    test "without the option data is still replaced wholesale", %{item: item} do
      {:ok, updated} = Catalogue.update_item(item, %{data: %{"only" => "this"}})
      assert updated.data == %{"only" => "this"}
    end
  end

  describe "update_category/3 with :data_owned_paths" do
    test "sets the external id and keeps the other data", %{catalogue: catalogue} do
      category = fixture_category(catalogue, %{name: "Shelf", data: %{"meta" => %{"k" => "v"}}})

      {:ok, updated} =
        Catalogue.update_category(category, %{data: %{"api" => %{"external_id" => "C-1"}}},
          data_owned_paths: [["api", "external_id"]],
          logged_data_paths: [["api", "external_id"]],
          log_metadata: %{"via" => "api"},
          actor_uuid: @actor
        )

      assert updated.data == %{"meta" => %{"k" => "v"}, "api" => %{"external_id" => "C-1"}}

      row = assert_activity_logged("category.updated", resource_uuid: category.uuid)
      assert row.metadata["via"] == "api"

      assert row.metadata["changes"]["data.api.external_id"] ==
               %{"from" => "", "to" => "C-1"}
    end

    test "the category is read FOR UPDATE", %{catalogue: catalogue} do
      category = fixture_category(catalogue, %{name: "Locked shelf"})

      queries =
        query_texts(fn ->
          assert {:ok, _} =
                   Catalogue.update_category(category, %{name: "x"}, data_owned_paths: [])
        end)

      assert [_one] = locking_reads(queries, "phoenix_kit_cat_categories")
    end

    test "the logged from-value is the locked row's, not the stale copy's", %{
      catalogue: catalogue
    } do
      category = fixture_category(catalogue, %{name: "Shelf"})
      stale = Catalogue.get_category!(category.uuid)
      {:ok, _} = Catalogue.update_category(category, %{name: "Renamed elsewhere"})

      assert {:ok, updated} =
               Catalogue.update_category(stale, %{name: "Mine"}, data_owned_paths: [])

      assert updated.name == "Mine"

      assert [row] =
               "category.updated"
               |> logged(category.uuid)
               |> Enum.filter(&(get_in(&1.metadata, ["changes", "name", "to"]) == "Mine"))

      assert row.metadata["changes"]["name"] == %{"from" => "Renamed elsewhere", "to" => "Mine"}
    end

    test "a re-parent diffs against the row as stored, without the new options too", %{
      catalogue: catalogue
    } do
      parent = fixture_category(catalogue, %{name: "Parent"})
      category = fixture_category(catalogue, %{name: "Shelf"})
      stale = Catalogue.get_category!(category.uuid)
      {:ok, _} = Catalogue.update_category(category, %{name: "Renamed elsewhere"})

      assert {:ok, updated} =
               Catalogue.update_category(stale, %{name: "Mine", parent_uuid: parent.uuid})

      assert updated.parent_uuid == parent.uuid

      assert [row] =
               "category.updated"
               |> logged(category.uuid)
               |> Enum.filter(&(get_in(&1.metadata, ["changes", "name", "to"]) == "Mine"))

      assert row.metadata["changes"]["name"] == %{"from" => "Renamed elsewhere", "to" => "Mine"}
    end

    test "refuses :data_owned_keys together with :data_owned_paths", %{catalogue: catalogue} do
      category = fixture_category(catalogue, %{name: "Shelf"})

      assert_raise ArgumentError, ~r/mutually exclusive/, fn ->
        Catalogue.update_category(category, %{},
          data_owned_keys: ["meta"],
          data_owned_paths: @compare
        )
      end
    end

    test "returns :not_found when the category is gone", %{catalogue: catalogue} do
      category = fixture_category(catalogue, %{name: "Gone"})
      {:ok, _} = Catalogue.permanently_delete_category(category)

      assert {:error, :not_found} =
               Catalogue.update_category(category, %{name: "x"}, data_owned_paths: [])
    end
  end

  describe "preview_item_update/3" do
    test "reports the diff and writes nothing", %{item: item} do
      attrs = %{name: "New name", data: %{"ecommerce" => %{"compare_at_price" => "5"}}}

      assert {:ok, changes} =
               Catalogue.preview_item_update(item, attrs,
                 data_owned_paths: @compare,
                 logged_data_paths: @compare
               )

      assert changes == %{
               "name" => %{"from" => "Base", "to" => "New name"},
               "data.ecommerce.compare_at_price" => %{"from" => "", "to" => "5"}
             }

      assert Catalogue.get_item(item.uuid).name == "Base"
      assert list_activities() |> Enum.filter(&(&1.action == "item.updated")) == []
    end

    test "a sibling logged path that did not change stays out of the diff", %{item: item} do
      attrs = %{data: %{"ecommerce" => %{"compare_at_price" => "5"}}}

      assert {:ok, changes} =
               Catalogue.preview_item_update(item, attrs,
                 data_owned_paths: @compare,
                 logged_data_paths: @compare ++ [["ecommerce", "tags"], ["ecommerce", "shopify"]]
               )

      assert changes == %{"data.ecommerce.compare_at_price" => %{"from" => "", "to" => "5"}}
    end

    test "takes attrs[:slug] as the planned whole map and validates the options", %{item: item} do
      {:ok, with_slugs} =
        Catalogue.update_item(item, %{slug: %{"en-US" => "base", "de-DE" => "basis"}})

      assert {:ok, changes} =
               Catalogue.preview_item_update(with_slugs, %{
                 slug: %{"en-US" => "base", "de-DE" => "neu"}
               })

      assert changes == %{"slug.de-DE" => %{"from" => "basis", "to" => "neu"}}

      assert_raise ArgumentError, ~r/needs :data_owned_paths/, fn ->
        Catalogue.preview_item_update(with_slugs, %{}, slug_owned_langs: ["de-DE"])
      end

      assert_raise ArgumentError, ~r/slug_owned_langs/, fn ->
        Catalogue.preview_item_update(with_slugs, %{},
          data_owned_paths: [],
          slug_owned_langs: :de
        )
      end
    end

    test "an update that changes nothing previews as an empty map", %{item: item} do
      assert {:ok, changes} = Catalogue.preview_item_update(item, %{name: "Base"})
      assert changes == %{}
    end

    test "an invalid update returns the changeset", %{item: item} do
      assert {:error, %Ecto.Changeset{valid?: false}} =
               Catalogue.preview_item_update(item, %{name: ""})
    end
  end
end
