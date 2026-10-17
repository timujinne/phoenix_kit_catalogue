defmodule PhoenixKitCatalogue.UpdateItemsTest do
  @moduledoc """
  `Catalogue.update_items/2`: one transaction, rows independent, one log
  insert and one bulk broadcast per batch.
  """

  use PhoenixKitCatalogue.DataCase, async: false

  import ExUnit.CaptureLog

  import PhoenixKitCatalogue.LiveCase,
    only: [fixture_catalogue: 1, fixture_category: 2, fixture_item: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.PubSub
  alias PhoenixKitCatalogue.Test.QueryHook

  @actor "00000000-0000-7000-8000-000000000001"
  @meta %{"via" => "api", "key_prefix" => "abcd1234", "tool" => "catalogue.update_products"}

  defp batch_opts(extra \\ []),
    do: Keyword.merge([actor_uuid: @actor, mode: "auto", log_metadata: @meta], extra)

  # The INSERT statements run on the activities table while `fun` runs.
  defp count_activity_inserts(fun) do
    counter = :counters.new(1, [])
    test_pid = self()
    handler = "update-items-inserts-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:phoenix_kit_catalogue, :test, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == test_pid and metadata.query =~ ~s(INSERT INTO "phoenix_kit_activities") do
          :counters.add(counter, 1, 1)
        end
      end,
      nil
    )

    try do
      result = fun.()
      {result, :counters.get(counter, 1)}
    after
      :telemetry.detach(handler)
    end
  end

  # `{sql, params}` of every statement `fun` runs in this process, in order.
  defp recorded_queries(fun) do
    handler = "update-items-queries-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:phoenix_kit_catalogue, :test, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == test_pid,
          do: send(test_pid, {:recorded_query, metadata.query, metadata.params})
      end,
      nil
    )

    try do
      fun.()
      drain_recorded_queries([])
    after
      :telemetry.detach(handler)
    end
  end

  defp drain_recorded_queries(acc) do
    receive do
      {:recorded_query, query, params} -> drain_recorded_queries([{query, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  setup do
    catalogue = fixture_catalogue(%{name: "Batch Cat"})
    %{catalogue: catalogue}
  end

  test "outcomes come back in input order, one per row", %{catalogue: catalogue} do
    a = fixture_item(%{name: "A", catalogue_uuid: catalogue.uuid})
    b = fixture_item(%{name: "B", catalogue_uuid: catalogue.uuid})
    c = fixture_item(%{name: "C", catalogue_uuid: catalogue.uuid})
    ghost = Ecto.UUID.generate()

    rows = [
      {a.uuid, %{name: "A2"}},
      {b.uuid, %{name: "B"}},
      {a.uuid, %{name: "A3"}},
      {ghost, %{name: "G"}},
      {"not-a-uuid", %{name: "X"}},
      {c.uuid, %{name: ""}}
    ]

    assert {:ok, outcomes} = Catalogue.update_items(rows, batch_opts())

    assert Enum.map(outcomes, &elem(&1, 0)) ==
             [a.uuid, b.uuid, a.uuid, ghost, "not-a-uuid", c.uuid]

    assert [
             {_, {:updated, %{name: "A2"}}},
             {_, {:unchanged, %{name: "B"}}},
             {_, {:error, :duplicate_row}},
             {_, {:error, :not_found}},
             {_, {:error, :not_found}},
             {_, {:error, %Ecto.Changeset{}}}
           ] = outcomes

    assert Catalogue.get_item(a.uuid).name == "A2"
    assert Catalogue.get_item(b.uuid).name == "B"
    assert Catalogue.get_item(c.uuid).name == "C"
  end

  test "an upper-case spelling of a uuid finds the row and counts as the same row", %{
    catalogue: catalogue
  } do
    a = fixture_item(%{name: "A", catalogue_uuid: catalogue.uuid})
    upper = String.upcase(a.uuid)
    assert upper != a.uuid

    rows = [{upper, %{name: "A2"}}, {a.uuid, %{name: "A3"}}]

    assert {:ok, [{^upper, {:updated, %{name: "A2"}}}, {uuid, {:error, :duplicate_row}}]} =
             Catalogue.update_items(rows, batch_opts())

    assert uuid == a.uuid
    assert Catalogue.get_item(a.uuid).name == "A2"
  end

  test "a bad option raises before any query, whatever the rows are" do
    ghost = Ecto.UUID.generate()

    queries =
      recorded_queries(fn ->
        assert_raise ArgumentError, ~r/data_owned_paths/, fn ->
          Catalogue.update_items([{ghost, %{name: "x"}}], batch_opts(data_owned_paths: "nope"))
        end

        assert_raise ArgumentError, ~r/data_owned_paths/, fn ->
          Catalogue.update_items(
            [{ghost, %{name: "x"}, [data_owned_paths: "nope"]}],
            batch_opts()
          )
        end

        assert_raise ArgumentError, ~r/slug_owned_langs/, fn ->
          Catalogue.update_items(
            [{ghost, %{name: "x"}}],
            batch_opts(slug_owned_langs: ["en-US"])
          )
        end
      end)

    assert queries == []
  end

  test "a row that violates a constraint does not stop the others", %{catalogue: catalogue} do
    {:ok, _taken} =
      Catalogue.create_item(%{
        name: "Holder",
        catalogue_uuid: catalogue.uuid,
        data: %{"api" => %{"external_id" => "TAKEN"}}
      })

    first = fixture_item(%{name: "First", catalogue_uuid: catalogue.uuid})
    second = fixture_item(%{name: "Second", catalogue_uuid: catalogue.uuid})
    third = fixture_item(%{name: "Third", catalogue_uuid: catalogue.uuid})
    fourth = fixture_item(%{name: "Fourth", catalogue_uuid: catalogue.uuid})
    :ok = PubSub.subscribe()
    flush_messages()

    paths = [
      data_owned_paths: [["api", "external_id"]],
      logged_data_paths: [["api", "external_id"]]
    ]

    rows = [
      {first.uuid, %{name: "First 2"}},
      {second.uuid, %{data: %{"api" => %{"external_id" => "TAKEN"}}}, paths},
      {third.uuid, %{name: "Third 2"}},
      {fourth.uuid, %{name: "Fourth"}}
    ]

    {result, inserts} =
      count_activity_inserts(fn -> Catalogue.update_items(rows, batch_opts()) end)

    assert {:ok,
            [
              {_, {:updated, _}},
              {_, {:error, %Ecto.Changeset{} = changeset}},
              {_, {:updated, _}},
              {_, {:unchanged, _}}
            ]} = result

    assert %{data: ["external_id is already taken in this catalogue"]} = errors_on(changeset)
    assert Catalogue.get_item(first.uuid).name == "First 2"
    assert Catalogue.get_item(third.uuid).name == "Third 2"
    assert Catalogue.get_item(second.uuid).data == %{}

    # One insert for the two rows that changed; one announcement naming only them.
    assert inserts == 1
    cat_uuid = catalogue.uuid
    assert_receive {:catalogue_bulk_change, ^cat_uuid, :updated, announced, _from}
    assert Enum.sort(announced) == Enum.sort([first.uuid, third.uuid])
    refute_receive {:catalogue_bulk_change, _, _, _, _}, 50
  end

  test "a row the database refuses is answered :database_error and the others are written", %{
    catalogue: catalogue
  } do
    first = fixture_item(%{name: "First", catalogue_uuid: catalogue.uuid})
    middle = fixture_item(%{name: "Middle", catalogue_uuid: catalogue.uuid})
    last = fixture_item(%{name: "Last", catalogue_uuid: catalogue.uuid})

    rows = [
      {first.uuid, %{name: "First 2"}},
      {middle.uuid, %{name: "a" <> <<0>> <> "b"}},
      {last.uuid, %{name: "Last 2"}}
    ]

    log =
      capture_log(fn ->
        assert {:ok, [{_, {:updated, _}}, {_, {:error, :database_error}}, {_, {:updated, _}}]} =
                 Catalogue.update_items(rows, batch_opts())
      end)

    assert Catalogue.get_item(first.uuid).name == "First 2"
    assert Catalogue.get_item(middle.uuid).name == "Middle"
    assert Catalogue.get_item(last.uuid).name == "Last 2"

    # The warning names the row and the structured error fields, never the message.
    assert log =~ middle.uuid
    assert log =~ "pg_code=22021"
    refute log =~ "invalid byte sequence"
  end

  test "a database error in a read around the UPDATE is not swallowed as a row's :database_error",
       %{catalogue: catalogue} do
    first = fixture_item(%{name: "First", catalogue_uuid: catalogue.uuid})
    second = fixture_item(%{name: "Second", catalogue_uuid: catalogue.uuid})

    rows = [{first.uuid, %{name: "First 2"}}, {second.uuid, %{name: "Second 2"}}]
    opts = batch_opts(data_owned_paths: [["api", "external_id"]])

    # Right after the batch has locked its items, the transaction is aborted
    # (a failed statement); the next read, the row's own locked re-read, is
    # then refused by the database. That is the whole batch's failure.
    log =
      capture_log(fn ->
        assert_raise Postgrex.Error, fn ->
          QueryHook.after_query(
            "FOR UPDATE",
            fn -> {:error, _} = Repo.query("SELECT 1 / 0") end,
            fn -> Catalogue.update_items(rows, opts) end
          )
        end
      end)

    refute log =~ "update_items row"
    assert Catalogue.get_item(first.uuid).name == "First"
    assert Catalogue.get_item(second.uuid).name == "Second"
  end

  test "the categories are locked FOR SHARE before the items FOR UPDATE, each in uuid order", %{
    catalogue: catalogue
  } do
    # Created first, so its uuid sorts lowest: the unsorted list would start with it.
    incoming = fixture_category(catalogue, %{name: "Incoming shelf"})
    shelf_a = fixture_category(catalogue, %{name: "Shelf A"})
    shelf_b = fixture_category(catalogue, %{name: "Shelf B"})
    a = fixture_item(%{name: "A", catalogue_uuid: catalogue.uuid, category_uuid: shelf_a.uuid})
    b = fixture_item(%{name: "B", catalogue_uuid: catalogue.uuid, category_uuid: shelf_b.uuid})
    c = fixture_item(%{name: "C", catalogue_uuid: catalogue.uuid})

    # Input order is the reverse of creation order.
    rows = [
      {c.uuid, %{category_uuid: incoming.uuid}},
      {b.uuid, %{name: "B2"}},
      {a.uuid, %{name: "A2"}}
    ]

    queries =
      recorded_queries(fn -> assert {:ok, _} = Catalogue.update_items(rows, batch_opts()) end)

    category_lock =
      Enum.find_index(queries, fn {sql, _} ->
        sql =~ ~r/FROM "phoenix_kit_cat_categories".*ORDER BY \w+\."uuid" FOR SHARE\z/s
      end)

    item_lock =
      Enum.find_index(queries, fn {sql, _} ->
        sql =~ ~r/FROM "phoenix_kit_cat_items".*ORDER BY \w+\."uuid" FOR UPDATE\z/s
      end)

    assert category_lock, "no category read ORDER BY uuid FOR SHARE"
    assert item_lock, "no item read ORDER BY uuid FOR UPDATE"
    assert category_lock < item_lock

    # The category lock covers the current categories and the incoming one, sorted.
    {_sql, [category_params]} = Enum.at(queries, category_lock)
    assert category_params == Enum.sort(category_params)

    assert Enum.sort(category_params) ==
             Enum.sort(Enum.map([incoming, shelf_a, shelf_b], &Ecto.UUID.dump!(&1.uuid)))

    # The item lock covers every row of the batch.
    {_sql, [item_params]} = Enum.at(queries, item_lock)
    assert Enum.sort(item_params) == Enum.sort(Enum.map([a, b, c], &Ecto.UUID.dump!(&1.uuid)))
  end

  test "three changed rows make one activity insert and no per-row broadcast", %{
    catalogue: catalogue
  } do
    items = for n <- 1..3, do: fixture_item(%{name: "I#{n}", catalogue_uuid: catalogue.uuid})
    :ok = PubSub.subscribe()
    flush_messages()

    rows = for {item, n} <- Enum.with_index(items, 1), do: {item.uuid, %{name: "Renamed #{n}"}}

    {{:ok, outcomes}, inserts} =
      count_activity_inserts(fn -> Catalogue.update_items(rows, batch_opts()) end)

    assert length(outcomes) == 3
    assert inserts == 1

    cat_uuid = catalogue.uuid
    uuids = Enum.map(items, & &1.uuid) |> Enum.sort()

    assert_receive {:catalogue_bulk_change, ^cat_uuid, :updated, broadcast_uuids, _from}
    assert Enum.sort(broadcast_uuids) == uuids
    refute_receive {:catalogue_bulk_change, _, _, _, _}, 50

    # One data-changed event for the catalogue (the index's Items count), never one per row.
    assert_receive {:catalogue_data_changed, :item, nil, ^cat_uuid}
    refute_receive {:catalogue_data_changed, _, _, _}, 50
  end

  test "rows of two catalogues broadcast once each", %{catalogue: catalogue} do
    other = fixture_catalogue(%{name: "Other Batch Cat"})
    a = fixture_item(%{name: "A", catalogue_uuid: catalogue.uuid})
    b = fixture_item(%{name: "B", catalogue_uuid: other.uuid})
    :ok = PubSub.subscribe()
    flush_messages()

    {:ok, _} =
      Catalogue.update_items([{a.uuid, %{name: "A2"}}, {b.uuid, %{name: "B2"}}], batch_opts())

    cat1 = catalogue.uuid
    cat2 = other.uuid
    assert_receive {:catalogue_bulk_change, ^cat1, :updated, [_], _}
    assert_receive {:catalogue_bulk_change, ^cat2, :updated, [_], _}
    assert_receive {:catalogue_data_changed, :item, nil, ^cat1}
    assert_receive {:catalogue_data_changed, :item, nil, ^cat2}
    refute_receive {:catalogue_data_changed, _, _, _}, 50
  end

  test "broadcast: false is honoured", %{catalogue: catalogue} do
    a = fixture_item(%{name: "A", catalogue_uuid: catalogue.uuid})
    :ok = PubSub.subscribe()
    flush_messages()

    {:ok, _} = Catalogue.update_items([{a.uuid, %{name: "A2"}}], batch_opts(broadcast: false))

    refute_receive {:catalogue_bulk_change, _, _, _, _}, 100
    refute_receive {:catalogue_data_changed, _, _, _}, 50
  end

  test "each changed row gets its own entry with the actor, the metadata and the diff", %{
    catalogue: catalogue
  } do
    a = fixture_item(%{name: "A", catalogue_uuid: catalogue.uuid, slug: %{"en-US" => "a-slug"}})
    b = fixture_item(%{name: "B", catalogue_uuid: catalogue.uuid})

    row_opts = [
      data_owned_paths: [["ecommerce", "compare_at_price"]],
      logged_data_paths: [["ecommerce", "compare_at_price"]]
    ]

    rows = [
      {a.uuid, %{name: "A2", slug: %{"en-US" => "a-new"}}},
      {b.uuid, %{data: %{"ecommerce" => %{"compare_at_price" => "7"}}}, row_opts}
    ]

    {:ok, _} = Catalogue.update_items(rows, batch_opts())

    row_a = assert_activity_logged("item.updated", resource_uuid: a.uuid, actor_uuid: @actor)
    assert row_a.mode == "auto"
    assert row_a.metadata["via"] == "api"
    assert row_a.metadata["changes"]["name"] == %{"from" => "A", "to" => "A2"}
    assert row_a.metadata["changes"]["slug.en-US"] == %{"from" => "a-slug", "to" => "a-new"}

    row_b = assert_activity_logged("item.updated", resource_uuid: b.uuid, actor_uuid: @actor)

    assert row_b.metadata["changes"] ==
             %{"data.ecommerce.compare_at_price" => %{"from" => "", "to" => "7"}}
  end

  test "an unchanged row writes no entry", %{catalogue: catalogue} do
    a = fixture_item(%{name: "A", catalogue_uuid: catalogue.uuid})

    {{:ok, [{_, {:unchanged, _}}]}, inserts} =
      count_activity_inserts(fn ->
        Catalogue.update_items([{a.uuid, %{name: "A"}}], batch_opts())
      end)

    assert inserts == 0
    refute_activity_logged("item.updated", resource_uuid: a.uuid)
  end

  test "data_owned_paths merge into the stored data and keep its other keys", %{
    catalogue: catalogue
  } do
    a =
      fixture_item(%{
        name: "A",
        catalogue_uuid: catalogue.uuid,
        data: %{"ecommerce" => %{"tags" => ["x"]}}
      })

    {:ok, _} = Catalogue.update_item(a, %{data: %{"ecommerce" => %{"tags" => ["x", "y"]}}})

    attrs = %{data: %{"ecommerce" => %{"compare_at_price" => "3"}}}
    row_opts = [data_owned_paths: [["ecommerce", "compare_at_price"]]]

    {:ok, [{_, {:updated, updated}}]} =
      Catalogue.update_items([{a.uuid, attrs, row_opts}], batch_opts())

    assert updated.data["ecommerce"] == %{"tags" => ["x", "y"], "compare_at_price" => "3"}
  end

  test "a row's own options override the shared ones", %{catalogue: catalogue} do
    a = fixture_item(%{name: "A", catalogue_uuid: catalogue.uuid})

    {:ok, _} =
      Catalogue.update_items(
        [{a.uuid, %{name: "A2"}, [log_metadata: %{"via" => "row"}]}],
        batch_opts()
      )

    row = assert_activity_logged("item.updated", resource_uuid: a.uuid)
    assert row.metadata["via"] == "row"
  end

  test "an empty batch is fine" do
    assert {:ok, []} = Catalogue.update_items([], batch_opts())
  end

  test "more than 500 rows is refused" do
    rows = for _ <- 1..501, do: {Ecto.UUID.generate(), %{name: "x"}}

    assert_raise ArgumentError, ~r/at most 500 rows/, fn ->
      Catalogue.update_items(rows, batch_opts())
    end
  end

  @tag timeout: 180_000
  test "500 rows are one insert and one broadcast", %{catalogue: catalogue} do
    items =
      for n <- 1..500 do
        {:ok, item} =
          Catalogue.create_item(%{name: "Bulk #{n}", catalogue_uuid: catalogue.uuid},
            broadcast: false
          )

        item
      end

    :ok = PubSub.subscribe()
    flush_messages()

    rows =
      for {item, n} <- Enum.with_index(items, 1), do: {item.uuid, %{name: "Bulk renamed #{n}"}}

    {{:ok, outcomes}, inserts} =
      count_activity_inserts(fn -> Catalogue.update_items(rows, batch_opts()) end)

    assert length(outcomes) == 500
    assert Enum.all?(outcomes, &match?({_, {:updated, _}}, &1))
    assert inserts == 1

    cat_uuid = catalogue.uuid
    assert_receive {:catalogue_bulk_change, ^cat_uuid, :updated, uuids, _from}
    assert length(uuids) == 500
    refute_receive {:catalogue_bulk_change, _, _, _, _}, 50
    assert_receive {:catalogue_data_changed, :item, nil, ^cat_uuid}
    refute_receive {:catalogue_data_changed, _, _, _}, 50
  end

  describe "broadcast_item_batch_change/3" do
    test "sends one bulk event of the given kind", %{catalogue: catalogue} do
      :ok = PubSub.subscribe()
      flush_messages()
      uuid = Ecto.UUID.generate()

      assert :ok = Catalogue.broadcast_item_batch_change(catalogue.uuid, :created, [uuid])

      cat_uuid = catalogue.uuid
      assert_receive {:catalogue_bulk_change, ^cat_uuid, :created, [^uuid], _from}
      # ... followed by the single nil-uuid data-changed event the index listens to.
      assert_receive {:catalogue_data_changed, :item, nil, ^cat_uuid}
    end

    test "an empty list sends nothing", %{catalogue: catalogue} do
      :ok = PubSub.subscribe()
      flush_messages()

      assert :ok = Catalogue.broadcast_item_batch_change(catalogue.uuid, :updated, [])
      refute_receive {:catalogue_bulk_change, _, _, _, _}, 50
      refute_receive {:catalogue_data_changed, _, _, _}, 50
    end
  end

  defp flush_messages do
    receive do
      _message -> flush_messages()
    after
      0 -> :ok
    end
  end
end
