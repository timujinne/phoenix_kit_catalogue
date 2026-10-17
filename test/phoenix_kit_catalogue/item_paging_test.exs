defmodule PhoenixKitCatalogue.ItemPagingTest do
  @moduledoc """
  Keyset paging of items for incremental export (shop API `catalogue.list_products`):
  stable `(updated_at, uuid)` order, an opaque cursor, exact count.
  """

  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase,
    only: [fixture_catalogue: 1, fixture_category: 2, fixture_item: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Schemas.Item

  defp stamp!(item, iso) do
    {:ok, at, _} = DateTime.from_iso8601(iso)
    {1, _} = Repo.update_all(from(i in Item, where: i.uuid == ^item.uuid), set: [updated_at: at])
    item
  end

  defp names(%{items: items}), do: Enum.map(items, & &1.name)

  setup do
    catalogue = fixture_catalogue(%{name: "Paging Cat"})
    %{catalogue: catalogue}
  end

  test "orders by updated_at then uuid and pages through everything exactly once",
       %{catalogue: catalogue} do
    items =
      for n <- 1..7 do
        fixture_item(%{name: "P#{n}", catalogue_uuid: catalogue.uuid})
        |> stamp!("2026-03-0#{rem(n, 3) + 1}T10:00:00Z")
      end

    base = [catalogue_uuid: catalogue.uuid, limit: 3]

    page1 = Catalogue.list_items_keyset(base)
    assert length(page1.items) == 3
    assert is_binary(page1.next_cursor)

    {:ok, cursor1} = Catalogue.decode_items_cursor(page1.next_cursor)
    page2 = Catalogue.list_items_keyset(base ++ [cursor: cursor1])

    {:ok, cursor2} = Catalogue.decode_items_cursor(page2.next_cursor)
    page3 = Catalogue.list_items_keyset(base ++ [cursor: cursor2])

    assert page3.next_cursor == nil
    seen = Enum.flat_map([page1, page2, page3], & &1.items)

    assert length(seen) == 7

    assert seen |> Enum.map(& &1.uuid) |> Enum.sort() ==
             items |> Enum.map(& &1.uuid) |> Enum.sort()

    stamps = Enum.map(seen, &DateTime.to_unix(&1.updated_at))
    assert stamps == Enum.sort(stamps)

    # inside one timestamp the uuid breaks the tie, ascending
    for {_at, group} <- Enum.group_by(seen, & &1.updated_at) do
      uuids = Enum.map(group, & &1.uuid)
      assert uuids == Enum.sort(uuids)
    end
  end

  test "the cursor survives rows sharing one timestamp", %{catalogue: catalogue} do
    for n <- 1..5 do
      fixture_item(%{name: "Same#{n}", catalogue_uuid: catalogue.uuid})
      |> stamp!("2026-04-01T00:00:00Z")
    end

    base = [catalogue_uuid: catalogue.uuid, limit: 2]
    first = Catalogue.list_items_keyset(base)
    {:ok, c1} = Catalogue.decode_items_cursor(first.next_cursor)
    second = Catalogue.list_items_keyset(base ++ [cursor: c1])
    {:ok, c2} = Catalogue.decode_items_cursor(second.next_cursor)
    third = Catalogue.list_items_keyset(base ++ [cursor: c2])

    all = Enum.flat_map([first, second, third], & &1.items)
    assert length(all) == 5
    assert length(Enum.uniq_by(all, & &1.uuid)) == 5
  end

  test "updated_since is inclusive", %{catalogue: catalogue} do
    fixture_item(%{name: "Old", catalogue_uuid: catalogue.uuid}) |> stamp!("2026-01-01T00:00:00Z")

    fixture_item(%{name: "Edge", catalogue_uuid: catalogue.uuid})
    |> stamp!("2026-02-01T00:00:00Z")

    fixture_item(%{name: "New", catalogue_uuid: catalogue.uuid}) |> stamp!("2026-03-01T00:00:00Z")

    {:ok, since, _} = DateTime.from_iso8601("2026-02-01T00:00:00Z")
    result = Catalogue.list_items_keyset(catalogue_uuid: catalogue.uuid, updated_since: since)

    assert names(result) == ["Edge", "New"]
  end

  test "filters: status, category, text; trashed rows only with include_deleted", %{
    catalogue: catalogue
  } do
    category = fixture_category(catalogue, %{name: "Shelf"})

    fixture_item(%{
      name: "Oak panel",
      catalogue_uuid: catalogue.uuid,
      category_uuid: category.uuid
    })

    fixture_item(%{name: "Pine panel", catalogue_uuid: catalogue.uuid, status: "inactive"})
    fixture_item(%{name: "Birch plank", catalogue_uuid: catalogue.uuid, status: "discontinued"})
    gone = fixture_item(%{name: "Gone panel", catalogue_uuid: catalogue.uuid})
    {:ok, _} = Catalogue.trash_item(gone)

    base = [catalogue_uuid: catalogue.uuid]

    assert base |> Catalogue.list_items_keyset() |> names() |> Enum.sort() ==
             ["Birch plank", "Oak panel", "Pine panel"]

    assert names(Catalogue.list_items_keyset(base ++ [status: "inactive"])) == ["Pine panel"]

    # An export can ask for the trashed rows too; an explicit status still wins
    assert base
           |> Kernel.++(include_deleted: true)
           |> Catalogue.list_items_keyset()
           |> names()
           |> Enum.sort() ==
             ["Birch plank", "Gone panel", "Oak panel", "Pine panel"]

    assert names(Catalogue.list_items_keyset(base ++ [include_deleted: true, status: "inactive"])) ==
             ["Pine panel"]

    # an explicit "deleted" status never lists trashed rows unless include_deleted says so
    assert Catalogue.list_items_keyset(base ++ [status: "deleted"]) == %{
             items: [],
             next_cursor: nil
           }

    assert Catalogue.count_items_matching(base ++ [status: "deleted"]) == 0

    assert names(Catalogue.list_items_keyset(base ++ [status: "deleted", include_deleted: true])) ==
             ["Gone panel"]

    assert Catalogue.count_items_matching(base ++ [include_deleted: true]) == 4
    assert Catalogue.count_items_matching(base) == 3

    assert names(Catalogue.list_items_keyset(base ++ [category_uuid: category.uuid])) == [
             "Oak panel"
           ]

    assert base
           |> Kernel.++(q: "panel")
           |> Catalogue.list_items_keyset()
           |> names()
           |> Enum.sort() ==
             ["Oak panel", "Pine panel"]
  end

  test "q matches name, description and sku, and NEVER the data column", %{catalogue: catalogue} do
    fixture_item(%{
      name: "Plain",
      description: "Solid oak",
      sku: "SKU-77",
      catalogue_uuid: catalogue.uuid,
      data: %{
        "ecommerce" => %{"cost_per_item" => "12.34", "vendor" => "Acme", "tags" => ["secret-tag"]},
        "de-DE" => %{"_name" => "Schlicht"}
      }
    })

    count = fn q -> Catalogue.count_items_matching(catalogue_uuid: catalogue.uuid, q: q) end

    listed = fn q ->
      length(Catalogue.list_items_keyset(catalogue_uuid: catalogue.uuid, q: q).items)
    end

    for q <- ["plain", "SOLID OAK", "sku-77"] do
      assert {count.(q), listed.(q)} == {1, 1}, "#{q} should match a column"
    end

    # Values that exist only inside `data` are not an oracle (they are shop fields).
    for q <- ["12.34", "12", "Acme", "secret-tag", "Schlicht"] do
      assert {count.(q), listed.(q)} == {0, 0}, "#{q} matched the data column"
    end
  end

  test "a q with a NUL character matches nothing and never raises", %{catalogue: catalogue} do
    fixture_item(%{name: "ab", catalogue_uuid: catalogue.uuid})

    for q <- ["\u0000", "a\u0000b", " \u0000 ", <<0>>] do
      opts = [catalogue_uuid: catalogue.uuid, q: q]

      assert Catalogue.list_items_keyset(opts) == %{items: [], next_cursor: nil},
             "listed for #{inspect(q)}"

      assert Catalogue.count_items_matching(opts) == 0, "counted for #{inspect(q)}"
    end
  end

  test "other catalogues are never mixed in", %{catalogue: catalogue} do
    other = fixture_catalogue(%{name: "Other Paging Cat"})
    fixture_item(%{name: "Mine", catalogue_uuid: catalogue.uuid})
    fixture_item(%{name: "Theirs", catalogue_uuid: other.uuid})

    assert names(Catalogue.list_items_keyset(catalogue_uuid: catalogue.uuid)) == ["Mine"]
  end

  test "count_items_matching/1 is exact and ignores the cursor and the limit",
       %{catalogue: catalogue} do
    for n <- 1..6, do: fixture_item(%{name: "C#{n}", catalogue_uuid: catalogue.uuid})

    {:ok, cursor} =
      Catalogue.decode_items_cursor(
        Catalogue.list_items_keyset(catalogue_uuid: catalogue.uuid, limit: 2).next_cursor
      )

    assert Catalogue.count_items_matching(
             catalogue_uuid: catalogue.uuid,
             limit: 2,
             cursor: cursor
           ) == 6

    assert Catalogue.count_items_matching(catalogue_uuid: catalogue.uuid, q: "C1") == 1
  end

  test "the limit is clamped to 1..100", %{catalogue: catalogue} do
    for n <- 1..3, do: fixture_item(%{name: "L#{n}", catalogue_uuid: catalogue.uuid})

    assert length(Catalogue.list_items_keyset(catalogue_uuid: catalogue.uuid, limit: 0).items) ==
             1

    assert length(Catalogue.list_items_keyset(catalogue_uuid: catalogue.uuid, limit: -5).items) ==
             1

    assert length(Catalogue.list_items_keyset(catalogue_uuid: catalogue.uuid, limit: 5000).items) ==
             3

    assert length(Catalogue.list_items_keyset(catalogue_uuid: catalogue.uuid).items) == 3
  end

  test "the upper limit is 100 rows per page", %{catalogue: catalogue} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      for n <- 1..101 do
        %{
          uuid: Ecto.UUID.generate(),
          name: "Bulk#{n}",
          status: "active",
          unit: "piece",
          data: %{},
          catalogue_uuid: catalogue.uuid,
          inserted_at: now,
          updated_at: now
        }
      end

    {101, _} = Repo.insert_all(Item, rows)

    page = Catalogue.list_items_keyset(catalogue_uuid: catalogue.uuid, limit: 5000)
    assert length(page.items) == 100
    assert is_binary(page.next_cursor)

    {:ok, cursor} = Catalogue.decode_items_cursor(page.next_cursor)

    rest =
      Catalogue.list_items_keyset(catalogue_uuid: catalogue.uuid, limit: 5000, cursor: cursor)

    assert length(rest.items) == 1
    assert rest.next_cursor == nil
  end

  test "q treats LIKE wildcards literally and a blank q lists everything",
       %{catalogue: catalogue} do
    for name <- ["A100%", "Axyz", "B_1"],
        do: fixture_item(%{name: name, catalogue_uuid: catalogue.uuid})

    found = fn q -> names(Catalogue.list_items_keyset(catalogue_uuid: catalogue.uuid, q: q)) end

    assert found.("%") == ["A100%"]
    assert found.("_") == ["B_1"]
    assert found.("\\") == []
    assert found.("  ") |> Enum.sort() == ["A100%", "Axyz", "B_1"]

    assert Catalogue.count_items_matching(catalogue_uuid: catalogue.uuid, q: "%") == 1
    assert Catalogue.count_items_matching(catalogue_uuid: catalogue.uuid, q: "_") == 1
  end

  test "a category that is not a UUID matches nothing and never raises", %{catalogue: catalogue} do
    fixture_item(%{name: "Somewhere", catalogue_uuid: catalogue.uuid})

    for bad <- ["nope", "", 123, :atom, %{}] do
      opts = [catalogue_uuid: catalogue.uuid, category_uuid: bad]

      assert Catalogue.list_items_keyset(opts) == %{items: [], next_cursor: nil},
             "listed for #{inspect(bad)}"

      assert Catalogue.count_items_matching(opts) == 0, "counted for #{inspect(bad)}"
    end
  end

  test "items come back with the category preloaded", %{catalogue: catalogue} do
    category = fixture_category(catalogue, %{name: "Shelf"})

    fixture_item(%{name: "In", catalogue_uuid: catalogue.uuid, category_uuid: category.uuid})
    fixture_item(%{name: "Out", catalogue_uuid: catalogue.uuid})

    %{items: items} = Catalogue.list_items_keyset(catalogue_uuid: catalogue.uuid)

    by_name = Map.new(items, &{&1.name, &1})
    refute match?(%Ecto.Association.NotLoaded{}, by_name["In"].category)
    refute match?(%Ecto.Association.NotLoaded{}, by_name["Out"].category)
    assert by_name["In"].category.uuid == category.uuid
    assert by_name["Out"].category == nil
  end

  test "a bound before year 1 is no bound and does not raise", %{catalogue: catalogue} do
    for n <- 1..2, do: fixture_item(%{name: "Old#{n}", catalogue_uuid: catalogue.uuid})
    ancient = DateTime.new!(Date.new!(-9999, 1, 1), ~T[00:00:00], "Etc/UTC")

    opts = [catalogue_uuid: catalogue.uuid, updated_since: ancient]
    assert length(Catalogue.list_items_keyset(opts).items) == 2
    assert Catalogue.count_items_matching(opts) == 2
  end

  describe "decode_items_cursor/1" do
    test "round-trips what a page issued", %{catalogue: catalogue} do
      for n <- 1..3, do: fixture_item(%{name: "R#{n}", catalogue_uuid: catalogue.uuid})
      page = Catalogue.list_items_keyset(catalogue_uuid: catalogue.uuid, limit: 1)
      last = List.last(page.items)

      assert {:ok, {at, uuid}} = Catalogue.decode_items_cursor(page.next_cursor)
      assert uuid == last.uuid
      assert at == last.updated_at
    end

    test "a well-formed cursor with a year the database cannot take is :error" do
      for year <- ["-9999", "-4713", "0000"] do
        forged =
          Base.url_encode64(
            Jason.encode!(["#{year}-01-01T00:00:00Z", Ecto.UUID.generate()]),
            padding: false
          )

        assert Catalogue.decode_items_cursor(forged) == :error, "accepted year #{year}"
      end
    end

    test "a year above 9999 is :error" do
      for iso <- ["10000-01-01T00:00:00Z", "9999-12-31T23:59:59-01:00"] do
        forged = Base.url_encode64(Jason.encode!([iso, Ecto.UUID.generate()]), padding: false)

        assert Catalogue.decode_items_cursor(forged) == :error, "accepted #{iso}"
      end
    end

    test "garbage is :error, never a raise" do
      for bad <- [
            "",
            "!!!",
            "abc",
            Base.url_encode64("not json", padding: false),
            Base.url_encode64(~s(["2026-01-01T00:00:00Z"]), padding: false),
            Base.url_encode64(~s(["yesterday","not-a-uuid"]), padding: false),
            Base.url_encode64(~s(["2026-01-01T00:00:00Z","not-a-uuid"]), padding: false),
            Base.url_encode64(~s(["yesterday","#{Ecto.UUID.generate()}"]), padding: false),
            Base.url_encode64(~s({"a":1}), padding: false),
            Base.url_encode64("42", padding: false),
            Base.url_encode64("[1,2]", padding: false),
            Base.url_encode64(~s(["2026-01-01T00:00:00Z",5]), padding: false),
            nil,
            42
          ] do
        assert Catalogue.decode_items_cursor(bad) == :error, "accepted #{inspect(bad)}"
      end
    end
  end
end
