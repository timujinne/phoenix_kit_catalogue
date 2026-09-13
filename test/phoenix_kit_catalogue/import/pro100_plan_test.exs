defmodule PhoenixKitCatalogue.Import.Pro100PlanTest do
  use ExUnit.Case, async: true
  alias PhoenixKitCatalogue.Import.{Matcher, Pro100Plan}
  alias PhoenixKitCatalogue.Schemas.Item

  defp item(attrs), do: struct(%Item{uuid: "u", sku: "76.0026.12", unit: "piece"}, attrs)

  defp row(attrs) do
    Map.merge(
      %{
        line_no: 2,
        raw_line: "raw",
        id: "76002612",
        name: "X",
        base_price: Decimal.new("100.00"),
        unit: nil,
        service: %{"c3" => "0", "c5" => "1.0", "c6" => "222.00", "c7" => "2.0"},
        format: :furniture
      },
      attrs
    )
  end

  test "matched row with a new price yields an :update with a price change + pro100 data" do
    idx = Matcher.index([item(base_price: Decimal.new("80.00"))])
    plan = Pro100Plan.build([row(%{})], idx, nil)
    assert [change] = plan.updates
    assert change.status == :update
    {old, new} = change.changes.base_price
    assert Decimal.equal?(old, Decimal.new("80.00"))
    assert Decimal.equal?(new, Decimal.new("100.00"))

    assert change.data["pro100"] == %{
             "format" => "furniture",
             "c3" => "0",
             "c5" => "1.0",
             "c6" => "222.00",
             "c7" => "2.0"
           }
  end

  test "identical price yields :nochange (still carries pro100 data)" do
    idx = Matcher.index([item(base_price: Decimal.new("100.00"))])
    plan = Pro100Plan.build([row(%{})], idx, nil)
    assert [change] = plan.updates
    assert change.status == :nochange
  end

  # L026 invariant: re-importing the same file must not drop a photo the
  # operator attached to an already-imported item. build_data/3 seeds from the
  # existing item.data and only refreshes the "pro100" key, so the photo
  # pointers survive. This would fail if that merge were ever changed to
  # replace `data` wholesale.
  test "reimport update preserves the item's featured_image_uuid + files_folder_uuid" do
    idx =
      Matcher.index([
        item(
          base_price: Decimal.new("80.00"),
          data: %{
            "featured_image_uuid" => "photo-uuid-123",
            "files_folder_uuid" => "folder-uuid-9",
            "pro100" => %{"stale" => "prev"}
          }
        )
      ])

    plan = Pro100Plan.build([row(%{})], idx, nil)

    assert [change] = plan.updates
    assert change.status == :update
    # Operator's photo pointers survive the pro100 data merge untouched…
    assert change.data["featured_image_uuid"] == "photo-uuid-123"
    assert change.data["files_folder_uuid"] == "folder-uuid-9"
    # …while the pro100 round-trip blob is refreshed from the new row.
    assert change.data["pro100"]["format"] == "furniture"
  end

  test "reimport with no field changes still carries the photo pointer forward" do
    idx =
      Matcher.index([
        item(
          base_price: Decimal.new("100.00"),
          data: %{"featured_image_uuid" => "photo-uuid-123"}
        )
      ])

    plan = Pro100Plan.build([row(%{})], idx, nil)

    assert [change] = plan.updates
    assert change.status == :nochange
    assert change.data["featured_image_uuid"] == "photo-uuid-123"
  end

  test "materials unknown unit flags unit_unrecognized and keeps current unit" do
    mat_item = item(unit: "piece")
    idx = Matcher.index([mat_item])

    r =
      row(%{
        format: :materials,
        unit: "m³",
        base_price: Decimal.new("100.00"),
        service: %{"c3" => "0", "c5" => "1.0"}
      })

    plan = Pro100Plan.build([r], idx, nil)
    assert [change] = plan.updates
    assert :unit_unrecognized in change.flags
    refute Map.has_key?(change.changes, :unit)
    assert change.data["original_unit"] == "m³"
  end

  test "an unmatched row with a usable id and name becomes a create, not a skip" do
    idx = Matcher.index([])
    plan = Pro100Plan.build([row(%{})], idx, nil)
    assert plan.skipped == []
    assert [create] = plan.creates
    assert plan.stats.create == 1
    assert create.attrs.sku == "76002612"
    assert create.attrs.name == "X"
  end

  test "an unmatched row without an id is skipped as :no_id" do
    idx = Matcher.index([])
    plan = Pro100Plan.build([row(%{id: ""})], idx, nil)
    assert [%{reason: :no_id}] = plan.skipped
    assert plan.creates == []
    assert plan.stats.no_id == 1
  end

  test "an unmatched row without a name is skipped as :no_name" do
    idx = Matcher.index([])
    plan = Pro100Plan.build([row(%{name: "   "})], idx, nil)
    assert [%{reason: :no_name}] = plan.skipped
    assert plan.creates == []
    assert plan.stats.no_name == 1
  end

  test "ambiguous rows are never created, even with a usable id and name" do
    dupes = [item(uuid: "a", sku: "76002612"), item(uuid: "b", sku: "76.0026.12")]
    plan = Pro100Plan.build([row(%{})], Matcher.index(dupes), nil)
    assert [%{reason: :ambiguous}] = plan.skipped
    assert plan.creates == []
    assert plan.stats.ambiguous == 1
  end

  describe "name/category split" do
    test "splits the group prefix off the name; with no catalogue name it becomes a category" do
      plan =
        Pro100Plan.build(
          [row(%{name: "Andi Karkass  / MP U741 ST9 16mm"})],
          Matcher.index([]),
          nil
        )

      assert [create] = plan.creates
      assert create.category == "Andi Karkass"
      assert create.attrs.name == "MP U741 ST9 16mm"
      assert create.attrs[:_category_name] == "Andi Karkass"
    end

    # The group prefix only ever survives the foreign-group guard when it IS the
    # selected catalogue's name, so making a category out of it would file every
    # created row under a category duplicating the catalogue — while the
    # unprefixed rows of the very same export land at the catalogue root.
    test "a group matching the selected catalogue yields no category" do
      plan =
        Pro100Plan.build(
          [row(%{name: "Andi Karkass / MP U741 ST9 16mm"})],
          Matcher.index([]),
          "Andi Karkass"
        )

      assert [create] = plan.creates
      assert create.attrs.name == "MP U741 ST9 16mm"
      assert create.category == nil
      refute Map.has_key?(create.attrs, :_category_name)
      assert Pro100Plan.to_executor_plan(plan.creates).categories_to_create == []
    end

    # A bare slash inside an article code must not be mistaken for a group
    # separator — "MP U767 PM/ST9" would otherwise split into category
    # "MP U767 PM" and name "ST9 18mm".
    test "ignores a slash that is not whitespace-padded" do
      plan = Pro100Plan.build([row(%{name: "MP U767 PM/ST9 18mm"})], Matcher.index([]), nil)
      assert [create] = plan.creates
      assert create.category == nil
      assert create.attrs.name == "MP U767 PM/ST9 18mm"
      refute Map.has_key?(create.attrs, :_category_name)
    end

    test "keeps the padded separator when a bare slash also appears" do
      plan =
        Pro100Plan.build(
          [row(%{name: "Andi Karkass / MP U767 PM/ST9 18mm"})],
          Matcher.index([]),
          nil
        )

      assert [create] = plan.creates
      assert create.category == "Andi Karkass"
      assert create.attrs.name == "MP U767 PM/ST9 18mm"
    end

    test "a blank part on either side falls back to no category" do
      for name <- [" / Foo", "Group / ", " / "] do
        plan = Pro100Plan.build([row(%{name: name})], Matcher.index([]), nil)

        case plan.creates do
          [create] -> assert create.category == nil
          [] -> assert [%{reason: :no_name}] = plan.skipped
        end
      end
    end

    test "trims a name with no separator" do
      plan = Pro100Plan.build([row(%{name: "  Loose Name  "})], Matcher.index([]), nil)
      assert [create] = plan.creates
      assert create.attrs.name == "Loose Name"
    end
  end

  describe "create attrs" do
    # The schema default "piece" only applies to ABSENT keys; an explicit nil
    # writes NULL. The parser hands us unit: nil for every furniture row.
    test "omits :unit entirely for furniture rows" do
      plan = Pro100Plan.build([row(%{})], Matcher.index([]), nil)
      assert [create] = plan.creates
      refute Map.has_key?(create.attrs, :unit)
    end

    test "sets :unit for materials rows with a recognized unit" do
      r = row(%{format: :materials, unit: "tk", service: %{"c3" => "0", "c5" => "1.0"}})
      plan = Pro100Plan.build([r], Matcher.index([]), nil)
      assert [create] = plan.creates
      assert create.attrs.unit == "piece"
    end

    test "omits :unit but stashes original_unit for an unrecognized materials unit" do
      r = row(%{format: :materials, unit: "m³", service: %{"c3" => "0", "c5" => "1.0"}})
      plan = Pro100Plan.build([r], Matcher.index([]), nil)
      assert [create] = plan.creates
      refute Map.has_key?(create.attrs, :unit)
      assert create.attrs.data["original_unit"] == "m³"
      assert :unit_unrecognized in create.flags
    end

    test "never sets catalogue_uuid, category_uuid, status or position" do
      plan = Pro100Plan.build([row(%{name: "Group / Thing"})], Matcher.index([]), nil)
      assert [create] = plan.creates

      for key <- [:catalogue_uuid, :category_uuid, :status, :position] do
        refute Map.has_key?(create.attrs, key)
      end
    end

    test "carries the pro100 service blob" do
      plan = Pro100Plan.build([row(%{})], Matcher.index([]), nil)
      assert [create] = plan.creates

      assert create.attrs.data["pro100"] == %{
               "format" => "furniture",
               "c3" => "0",
               "c5" => "1.0",
               "c6" => "222.00",
               "c7" => "2.0"
             }
    end

    test "an unparseable price omits base_price and flags the row" do
      plan = Pro100Plan.build([row(%{base_price: nil})], Matcher.index([]), nil)
      assert [create] = plan.creates
      refute Map.has_key?(create.attrs, :base_price)
      assert :price_unparseable in create.flags
    end
  end

  test "two unmatched rows with the same id create one item, last row wins" do
    rows = [
      row(%{id: "76002612", name: "First", base_price: Decimal.new("90.00")}),
      row(%{id: "76002612", name: "Second", base_price: Decimal.new("100.00")})
    ]

    plan = Pro100Plan.build(rows, Matcher.index([]), nil)
    assert [create] = plan.creates
    assert create.attrs.name == "Second"
    assert Decimal.equal?(create.attrs.base_price, Decimal.new("100.00"))
  end

  describe "to_executor_plan/1" do
    test "maps attrs and collects distinct category names" do
      rows = [
        row(%{id: "1", name: "Andi Karkass / A"}),
        row(%{id: "2", name: "Andi Karkass / B"}),
        row(%{id: "3", name: "Other Group / C"}),
        row(%{id: "4", name: "No Group"})
      ]

      plan = Pro100Plan.build(rows, Matcher.index([]), nil)
      exec = Pro100Plan.to_executor_plan(plan.creates)

      assert length(exec.items) == 4
      assert exec.categories_to_create == ["Andi Karkass", "Other Group"]
    end

    # A `_category_name` absent from categories_to_create is dropped silently by
    # the executor, leaving items uncategorized with no error — the two must
    # stay derived from the same source.
    test "every item's :_category_name appears in categories_to_create" do
      rows = [row(%{id: "1", name: "G1 / A"}), row(%{id: "2", name: "G2 / B"})]

      exec =
        Pro100Plan.build(rows, Matcher.index([]), nil)
        |> Map.fetch!(:creates)
        |> Pro100Plan.to_executor_plan()

      for item <- exec.items, name = item[:_category_name], not is_nil(name) do
        assert name in exec.categories_to_create
      end
    end

    test "returns empty lists for an empty bucket" do
      assert Pro100Plan.to_executor_plan([]) == %{items: [], categories_to_create: []}
    end
  end

  # Regression: two PRO100 rows whose digits-only ids both resolve to the same
  # catalogue item must produce exactly ONE change entry (not two). Previously
  # build/2 emitted two independent entries each built from the item's
  # pre-import snapshot; on apply the second write silently discarded the first
  # row's persisted data["pro100"] payload (silent data loss).
  test "two rows resolving to the same item are folded into one change (last-row-wins)" do
    # Both ids differ only in non-digit characters → same digits-only key "76002612"
    item = item(base_price: Decimal.new("80.00"), uuid: "uuid-collision-test")
    idx = Matcher.index([item])

    row1 = row(%{id: "76002612", base_price: Decimal.new("90.00"), service: %{"c3" => "first"}})
    row2 = row(%{id: "76002612", base_price: Decimal.new("100.00"), service: %{"c3" => "second"}})

    plan = Pro100Plan.build([row1, row2], idx, nil)

    # Must produce exactly one change for that item, not two.
    assert length(plan.updates) == 1
    assert plan.stats.update == 1

    [change] = plan.updates

    # The newer row's price wins.
    assert {_old, new_price} = change.changes.base_price
    assert Decimal.equal?(new_price, Decimal.new("100.00"))

    # The newer row's pro100 data wins (data-loss regression guard).
    assert change.data["pro100"]["c3"] == "second"
  end

  # Regression: when the LAST of two colliding rows reasserts the item's
  # original (pre-import) price, the field must be treated as unchanged —
  # not silently left at an earlier colliding row's stale price. The bug:
  # each row's diff was computed independently against the pristine item, so
  # a row matching the original value produced an EMPTY diff and couldn't
  # override an earlier row's real change via Map.merge.
  test "last row reverting to the item's original price wins over an earlier row's change" do
    item = item(base_price: Decimal.new("80.00"), uuid: "uuid-revert-test")
    idx = Matcher.index([item])

    row1 = row(%{id: "76002612", base_price: Decimal.new("100.00"), service: %{"c3" => "first"}})
    row2 = row(%{id: "76002612", base_price: Decimal.new("80.00"), service: %{"c3" => "second"}})

    plan = Pro100Plan.build([row1, row2], idx, nil)

    assert [change] = plan.updates
    refute Map.has_key?(change.changes, :base_price)
    assert change.data["pro100"]["c3"] == "second"
  end

  test "ambiguous rows carry the colliding items for the report" do
    item_a = item(uuid: "a")
    item_b = item(uuid: "b")
    idx = Matcher.index([item_a, item_b])

    plan = Pro100Plan.build([row(%{})], idx, nil)

    assert [%{reason: :ambiguous, items: items}] = plan.skipped
    assert length(items) == 2
  end

  describe "name-aware matching" do
    test "a shared code is disambiguated by the row name instead of going ambiguous" do
      plain = item(uuid: "plain", sku: "73.U767.18", name: "MP U767 ST9 18mm")
      pm = item(uuid: "pm", sku: "73.U767.PM.18", name: "MP U767 PM/ST9 18mm")
      idx = Matcher.index([plain, pm])

      plan = Pro100Plan.build([row(%{id: "7376718", name: "MP U767 PM/ST9 18mm"})], idx, nil)

      assert [change] = plan.updates
      assert change.item.uuid == "pm"
      assert plan.stats.ambiguous == 0
    end
  end

  describe "foreign-group guard" do
    test "a row from another group is skipped, never created" do
      plan =
        Pro100Plan.build(
          [row(%{name: "Andi Töötasapind / Акрил Crystal"})],
          Matcher.index([]),
          "Andi Karkass"
        )

      assert [%{reason: :foreign_group, group: "Andi Töötasapind"}] = plan.skipped
      assert plan.creates == []
      assert plan.stats.foreign_group == 1
    end

    test "the catalogue name is compared trimmed" do
      # The live catalogue is stored as "Andi Karkass " — with a trailing space —
      # while the file writes "Andi Karkass".
      plan =
        Pro100Plan.build(
          [row(%{name: "Andi Karkass / MP U741"})],
          Matcher.index([]),
          "Andi Karkass "
        )

      assert plan.skipped == []
      assert [_] = plan.creates
    end

    test "a row with no group prefix belongs to the selected catalogue" do
      # Per-catalogue PRO100 exports carry no prefix at all.
      plan =
        Pro100Plan.build(
          [row(%{name: "Акрил Crystal V2778"})],
          Matcher.index([]),
          "Andi Töötasapind"
        )

      assert plan.skipped == []
      assert [create] = plan.creates
      assert create.category == nil
    end

    test "with no catalogue name the guard is off" do
      plan = Pro100Plan.build([row(%{name: "Whatever / Thing"})], Matcher.index([]), nil)

      assert plan.skipped == []
      assert [_] = plan.creates
    end

    # THE placement regression. If the foreign check runs after Matcher.resolve
    # instead of before it, a foreign row whose lossy digits also exist in the
    # target catalogue resolves to a local item and silently updates it — a
    # cross-catalogue price overwrite. No real export triggers this today, so
    # only this synthetic case can catch the ordering.
    test "a foreign row whose code matches a local item is skipped, not matched" do
      local = item(uuid: "local", sku: "76.0026.12", base_price: Decimal.new("80.00"))
      idx = Matcher.index([local])

      plan =
        Pro100Plan.build(
          [
            row(%{
              id: "76002612",
              name: "Andi Töötasapind / X",
              base_price: Decimal.new("999.00")
            })
          ],
          idx,
          "Andi Karkass"
        )

      assert [%{reason: :foreign_group}] = plan.skipped
      assert plan.updates == []
      assert plan.stats.update == 0
    end

    test "buckets partition the input" do
      rows = [
        row(%{id: "76002612", name: "Andi Karkass / Own"}),
        row(%{id: "999", name: "Andi Töötasapind / Foreign"}),
        row(%{id: "", name: "Andi Karkass / No Id"})
      ]

      plan = Pro100Plan.build(rows, Matcher.index([]), "Andi Karkass")
      s = plan.stats

      assert s.update + s.nochange + s.create + s.ambiguous + s.no_id + s.no_name +
               s.foreign_group == length(rows)
    end
  end

  describe "data_owned_keys/1" do
    test "names only the keys the plan changed against its snapshot" do
      item = %Item{data: %{"pro100" => %{"v" => 1}, "media_order" => ["a"], "x" => 1}}

      change = %{
        item: item,
        data: %{
          "pro100" => %{"v" => 2},
          "media_order" => ["a"],
          "x" => 1,
          "original_unit" => "tk"
        }
      }

      assert Enum.sort(Pro100Plan.data_owned_keys(change)) == ["original_unit", "pro100"]
      assert Pro100Plan.data_owned_keys(%{item: item, data: item.data}) == []
      assert Pro100Plan.data_owned_keys(%{item: nil, data: %{"pro100" => 1}}) == ["pro100"]
    end
  end
end
