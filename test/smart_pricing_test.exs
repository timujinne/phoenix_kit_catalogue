defmodule PhoenixKitCatalogue.SmartPricingTest do
  @moduledoc """
  Unit tests for the public smart-rules evaluator
  (`PhoenixKitCatalogue.Catalogue.evaluate_smart_rules/2`).

  All cases are pure — entries are plain structs/maps, no DB round trip
  — so we can exercise every branch of the algorithm without sandbox
  setup. Integration coverage that smart items hydrated from the DB
  flow through correctly lives in `test/smart_catalogues_guide_test.exs`
  and the `:preload` opt tests in `test/catalogue_test.exs`.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Schemas.Catalogue, as: CatalogueSchema
  alias PhoenixKitCatalogue.Schemas.{CatalogueRule, Item}

  defp standard_catalogue(uuid \\ Ecto.UUID.generate()) do
    %CatalogueSchema{uuid: uuid, kind: "standard", name: "Standard #{uuid}"}
  end

  defp smart_catalogue(uuid \\ Ecto.UUID.generate()) do
    %CatalogueSchema{uuid: uuid, kind: "smart", name: "Smart #{uuid}"}
  end

  defp standard_item(catalogue, attrs \\ %{}) do
    base = %Item{
      uuid: Ecto.UUID.generate(),
      name: "Std Item",
      base_price: Decimal.new("100"),
      catalogue_uuid: catalogue.uuid,
      catalogue: catalogue,
      catalogue_rules: []
    }

    Map.merge(base, attrs)
  end

  defp smart_item(catalogue, rules, attrs \\ %{}) do
    base = %Item{
      uuid: Ecto.UUID.generate(),
      name: "Smart Item",
      catalogue_uuid: catalogue.uuid,
      catalogue: catalogue,
      catalogue_rules: rules
    }

    Map.merge(base, attrs)
  end

  defp percent_rule(referenced_catalogue_uuid, value) do
    %CatalogueRule{
      uuid: Ecto.UUID.generate(),
      referenced_catalogue_uuid: referenced_catalogue_uuid,
      value: Decimal.new(value),
      unit: "percent",
      position: 0
    }
  end

  defp flat_rule(referenced_catalogue_uuid, value) do
    %CatalogueRule{
      uuid: Ecto.UUID.generate(),
      referenced_catalogue_uuid: referenced_catalogue_uuid,
      value: Decimal.new(value),
      unit: "flat",
      position: 0
    }
  end

  describe "evaluate_smart_rules/2 — pass-through" do
    test "returns standard entries unchanged" do
      kitchen = standard_catalogue()
      panel = standard_item(kitchen)
      entry = %{item: panel, qty: 2}

      assert [^entry] = Catalogue.evaluate_smart_rules([entry])
    end

    test "empty input returns empty list" do
      assert Catalogue.evaluate_smart_rules([]) == []
    end

    test "returns standard entries unchanged even when smart entries exist alongside" do
      kitchen = standard_catalogue()
      services = smart_catalogue()
      panel = standard_item(kitchen)
      delivery = smart_item(services, [percent_rule(kitchen.uuid, "10")])

      [out_panel, out_delivery] =
        Catalogue.evaluate_smart_rules([
          %{item: panel, qty: 1},
          %{item: delivery, qty: 1}
        ])

      assert out_panel == %{item: panel, qty: 1}
      refute Map.has_key?(out_panel, :smart_price)
      assert out_delivery.smart_price == Decimal.new("10.00")
    end
  end

  describe "evaluate_smart_rules/2 — percent rules" do
    test "writes computed price for one rule" do
      kitchen = standard_catalogue()
      services = smart_catalogue()
      panel = standard_item(kitchen, %{base_price: Decimal.new("200")})
      delivery = smart_item(services, [percent_rule(kitchen.uuid, "15")])

      [_, out_delivery] =
        Catalogue.evaluate_smart_rules([
          %{item: panel, qty: 1},
          %{item: delivery, qty: 1}
        ])

      # 15% of 200 = 30.00
      assert out_delivery.smart_price == Decimal.new("30.00")
    end

    test "sums multiple rules from the same smart item" do
      kitchen = standard_catalogue()
      plumbing = standard_catalogue()
      services = smart_catalogue()
      panel = standard_item(kitchen, %{base_price: Decimal.new("100")})
      pipe = standard_item(plumbing, %{base_price: Decimal.new("50")})

      delivery =
        smart_item(services, [
          percent_rule(kitchen.uuid, "15"),
          percent_rule(plumbing.uuid, "5")
        ])

      [_, _, out_delivery] =
        Catalogue.evaluate_smart_rules([
          %{item: panel, qty: 1},
          %{item: pipe, qty: 1},
          %{item: delivery, qty: 1}
        ])

      # 15% of 100 + 5% of 50 = 15.00 + 2.50 = 17.50
      assert out_delivery.smart_price == Decimal.new("17.50")
    end

    test "ref_sum aggregates qty across same-catalogue entries" do
      kitchen = standard_catalogue()
      services = smart_catalogue()
      panel = standard_item(kitchen, %{base_price: Decimal.new("100")})
      delivery = smart_item(services, [percent_rule(kitchen.uuid, "10")])

      [_, _, out_delivery] =
        Catalogue.evaluate_smart_rules([
          %{item: panel, qty: 2},
          %{item: panel, qty: 3},
          %{item: delivery, qty: 1}
        ])

      # ref_sum for kitchen = (100 × 2) + (100 × 3) = 500
      # 10% of 500 = 50.00
      assert out_delivery.smart_price == Decimal.new("50.00")
    end
  end

  describe "evaluate_smart_rules/2 — flat rules" do
    test "writes the flat value regardless of ref_sum" do
      kitchen = standard_catalogue()
      services = smart_catalogue()
      panel = standard_item(kitchen, %{base_price: Decimal.new("999")})
      delivery = smart_item(services, [flat_rule(kitchen.uuid, "20")])

      [_, out_delivery] =
        Catalogue.evaluate_smart_rules([
          %{item: panel, qty: 5},
          %{item: delivery, qty: 1}
        ])

      assert out_delivery.smart_price == Decimal.new("20.00")
    end

    test "mixed flat + percent rules sum correctly" do
      kitchen = standard_catalogue()
      services = smart_catalogue()
      panel = standard_item(kitchen, %{base_price: Decimal.new("100")})

      delivery =
        smart_item(services, [
          flat_rule(kitchen.uuid, "20"),
          percent_rule(kitchen.uuid, "5")
        ])

      [_, out_delivery] =
        Catalogue.evaluate_smart_rules([
          %{item: panel, qty: 1},
          %{item: delivery, qty: 1}
        ])

      # 20 (flat) + 5% of 100 = 20 + 5 = 25.00
      assert out_delivery.smart_price == Decimal.new("25.00")
    end
  end

  describe "evaluate_smart_rules/2 — value inheritance" do
    test "rule with NULL value falls back to item.default_value" do
      kitchen = standard_catalogue()
      services = smart_catalogue()
      panel = standard_item(kitchen, %{base_price: Decimal.new("100")})

      rule = %CatalogueRule{
        uuid: Ecto.UUID.generate(),
        referenced_catalogue_uuid: kitchen.uuid,
        value: nil,
        unit: "percent",
        position: 0
      }

      delivery =
        smart_item(services, [rule], %{
          default_value: Decimal.new("8"),
          default_unit: "percent"
        })

      [_, out_delivery] =
        Catalogue.evaluate_smart_rules([
          %{item: panel, qty: 1},
          %{item: delivery, qty: 1}
        ])

      # 8% (inherited) of 100 = 8.00
      assert out_delivery.smart_price == Decimal.new("8.00")
    end

    test "rule with NULL value AND no item default → 0 contribution" do
      kitchen = standard_catalogue()
      services = smart_catalogue()
      panel = standard_item(kitchen, %{base_price: Decimal.new("100")})

      rule = %CatalogueRule{
        uuid: Ecto.UUID.generate(),
        referenced_catalogue_uuid: kitchen.uuid,
        value: nil,
        unit: "percent",
        position: 0
      }

      delivery = smart_item(services, [rule])

      [_, out_delivery] =
        Catalogue.evaluate_smart_rules([
          %{item: panel, qty: 1},
          %{item: delivery, qty: 1}
        ])

      assert out_delivery.smart_price == Decimal.new("0.00")
    end
  end

  describe "evaluate_smart_rules/2 — edge cases" do
    test "smart item with no rules → 0 (matches reference impl)" do
      services = smart_catalogue()
      delivery = smart_item(services, [])

      [out] = Catalogue.evaluate_smart_rules([%{item: delivery, qty: 1}])

      assert out.smart_price == Decimal.new("0.00")
    end

    test "rule referencing a catalogue not in the entry list → 0 contribution" do
      services = smart_catalogue()
      missing = standard_catalogue()
      delivery = smart_item(services, [percent_rule(missing.uuid, "50")])

      [out] = Catalogue.evaluate_smart_rules([%{item: delivery, qty: 1}])

      assert out.smart_price == Decimal.new("0.00")
    end

    test "rule with unknown unit (not percent/flat) → 0 contribution" do
      kitchen = standard_catalogue()
      services = smart_catalogue()
      panel = standard_item(kitchen, %{base_price: Decimal.new("100")})

      bogus_rule = %CatalogueRule{
        uuid: Ecto.UUID.generate(),
        referenced_catalogue_uuid: kitchen.uuid,
        value: Decimal.new("50"),
        unit: "bogus_unit",
        position: 0
      }

      delivery = smart_item(services, [bogus_rule])

      [_, out_delivery] =
        Catalogue.evaluate_smart_rules([
          %{item: panel, qty: 1},
          %{item: delivery, qty: 1}
        ])

      # Pins the {_, _} -> 0 fallback in `rule_amount/3`. If a future
      # migration adds a new unit (`per_meter`, etc.) the evaluator
      # falls through to 0 silently — flag this test if you add a new
      # unit so the fallback is intentional, not forgotten.
      assert out_delivery.smart_price == Decimal.new("0.00")
    end

    test "standard item with nil base_price contributes 0 to ref_sums" do
      kitchen = standard_catalogue()
      services = smart_catalogue()
      free_panel = standard_item(kitchen, %{base_price: nil})
      delivery = smart_item(services, [percent_rule(kitchen.uuid, "10")])

      [_, out_delivery] =
        Catalogue.evaluate_smart_rules([
          %{item: free_panel, qty: 5},
          %{item: delivery, qty: 1}
        ])

      assert out_delivery.smart_price == Decimal.new("0.00")
    end

    test "smart items don't contribute to ref_sums (smart→standard rule with smart entry)" do
      kitchen = standard_catalogue()
      services = smart_catalogue()
      # Two smart items in the same smart catalogue. If smart contributed,
      # delivery_b would include itself indirectly via ref_sums.
      delivery_a =
        smart_item(services, [flat_rule(kitchen.uuid, "10")], %{
          base_price: Decimal.new("999")
        })

      delivery_b = smart_item(services, [percent_rule(services.uuid, "100")])

      [_, out_b] =
        Catalogue.evaluate_smart_rules([
          %{item: delivery_a, qty: 1},
          %{item: delivery_b, qty: 1}
        ])

      # ref_sum for services should be empty (only standard items contribute);
      # 100% of 0 = 0.
      assert out_b.smart_price == Decimal.new("0.00")
    end

    test "qty accepts integer, Decimal, and float" do
      kitchen = standard_catalogue()
      services = smart_catalogue()
      panel = standard_item(kitchen, %{base_price: Decimal.new("100")})
      delivery = smart_item(services, [percent_rule(kitchen.uuid, "10")])

      for qty <- [3, Decimal.new("3"), 3.0] do
        [_, out_delivery] =
          Catalogue.evaluate_smart_rules([
            %{item: panel, qty: qty},
            %{item: delivery, qty: 1}
          ])

        # 10% of (100 × 3) = 30.00
        assert Decimal.equal?(out_delivery.smart_price, Decimal.new("30.00")),
               "qty #{inspect(qty)} produced #{out_delivery.smart_price}"
      end
    end

    test "non-exact float qty is accepted (no crash, produces a price)" do
      # Pins the moduledoc's "Numeric precision for `:qty`" caveat: a float
      # qty like `1.1` (no exact binary representation) is accepted — no
      # crash, no validation rejection — and still produces a price. We do
      # NOT pin the exact `Decimal.from_float/1` round-trip: its
      # representation is library-version-dependent and not part of this
      # function's contract. Callers needing cent-exact billing pass
      # `Decimal.t()` or `integer()` per the moduledoc.
      kitchen = standard_catalogue()
      services = smart_catalogue()
      panel = standard_item(kitchen, %{base_price: Decimal.new("100")})
      delivery = smart_item(services, [percent_rule(kitchen.uuid, "10")])

      [_, out_float] =
        Catalogue.evaluate_smart_rules([
          %{item: panel, qty: 1.1},
          %{item: delivery, qty: 1}
        ])

      # Float input is accepted; no raise, no validation rejection.
      assert %Decimal{} = out_float.smart_price
    end
  end

  describe "evaluate_smart_rules/2 — preload guards" do
    test "raises ArgumentError when item.catalogue is NotLoaded" do
      services = smart_catalogue()
      delivery = smart_item(services, [])
      bad_item = %{delivery | catalogue: %Ecto.Association.NotLoaded{}}

      assert_raise ArgumentError, ~r/:catalogue to be preloaded/, fn ->
        Catalogue.evaluate_smart_rules([%{item: bad_item, qty: 1}])
      end
    end

    test "raises ArgumentError when smart item.catalogue_rules is NotLoaded" do
      services = smart_catalogue()
      delivery = smart_item(services, [])
      bad_item = %{delivery | catalogue_rules: %Ecto.Association.NotLoaded{}}

      assert_raise ArgumentError, ~r/:catalogue_rules to be preloaded/, fn ->
        Catalogue.evaluate_smart_rules([%{item: bad_item, qty: 1}])
      end
    end
  end

  describe "evaluate_smart_rules/2 — :write_to opt" do
    test "uses the configured key" do
      services = smart_catalogue()
      delivery = smart_item(services, [])

      [out] =
        Catalogue.evaluate_smart_rules([%{item: delivery, qty: 1}], write_to: :computed_price)

      assert out.computed_price == Decimal.new("0.00")
      refute Map.has_key?(out, :smart_price)
    end
  end

  describe "evaluate_smart_rules/2 — :line_total opt" do
    test "custom line_total controls the ref_sum" do
      kitchen = standard_catalogue()
      services = smart_catalogue()
      panel = standard_item(kitchen, %{base_price: Decimal.new("100")})
      delivery = smart_item(services, [percent_rule(kitchen.uuid, "10")])

      # Override: each entry contributes 1000 regardless of price/qty
      [_, out_delivery] =
        Catalogue.evaluate_smart_rules(
          [
            %{item: panel, qty: 1},
            %{item: delivery, qty: 1}
          ],
          line_total: fn _entry -> Decimal.new("1000") end
        )

      # 10% of 1000 = 100.00
      assert out_delivery.smart_price == Decimal.new("100.00")
    end

    test "custom line_total models discount-pre-rule (the issue author's case)" do
      kitchen = standard_catalogue()
      services = smart_catalogue()

      # Standard item with a 10% discount baked into the line total
      panel =
        standard_item(kitchen, %{
          base_price: Decimal.new("100"),
          discount_percentage: Decimal.new("10")
        })

      delivery = smart_item(services, [percent_rule(kitchen.uuid, "15")])

      discounted_line_total = fn %{item: i, qty: q} ->
        i.base_price
        |> Decimal.mult(Decimal.new(q))
        |> Decimal.mult(
          Decimal.sub(Decimal.new(1), Decimal.div(i.discount_percentage, Decimal.new(100)))
        )
      end

      [_, out_delivery] =
        Catalogue.evaluate_smart_rules(
          [
            %{item: panel, qty: 1},
            %{item: delivery, qty: 1}
          ],
          line_total: discounted_line_total
        )

      # ref_sum = 100 × 1 × 0.9 = 90; 15% of 90 = 13.50
      assert out_delivery.smart_price == Decimal.new("13.50")
    end
  end
end
