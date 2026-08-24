defmodule PhoenixKitCatalogue.Catalogue.SupplierCostRangesTest do
  @moduledoc """
  The "Supplier price" column: min–max of an item's CURRENT supplier
  rows, one range per currency, formatted `5.69–9.99`.
  """
  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase, only: [fixture_item: 1, fixture_supplier: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.ItemSupplierInfos
  alias PhoenixKitCatalogue.Web.Components

  defp row!(item, supplier, cost, extra \\ %{}) do
    {:ok, row} =
      Catalogue.create_supplier_info(
        Map.merge(
          %{item_uuid: item.uuid, supplier_uuid: supplier.uuid, unit_cost: cost, currency: "EUR"},
          extra
        )
      )

    row
  end

  test "groups current priced rows per item and currency, cheapest first" do
    item = fixture_item(%{name: "Pipe"})
    other = fixture_item(%{name: "Loose"})
    [s1, s2, s3, s4] = Enum.map(1..4, &fixture_supplier(%{name: "S#{&1}"}))

    row!(item, s1, Decimal.new("9.99"))
    cheap = row!(item, s2, Decimal.new("1.00"))
    # A revision closes the old row: only the successor's price counts.
    {:ok, _} = ItemSupplierInfos.revise_unit_cost(cheap, Decimal.new("5.69"), [])
    row!(item, s3, Decimal.new("4.00"), %{currency: "USD"})
    # No price → not a range.
    row!(item, s4, nil)

    assert %{} = ranges = Catalogue.supplier_cost_ranges([item.uuid, other.uuid])
    refute Map.has_key?(ranges, other.uuid)

    assert [
             %{currency: "USD", min: usd_min, max: usd_max, count: 1},
             %{currency: "EUR", min: eur_min, max: eur_max, count: 2}
           ] = ranges[item.uuid]

    assert Decimal.equal?(usd_min, "4.00") and Decimal.equal?(usd_max, "4.00")
    assert Decimal.equal?(eur_min, "5.69") and Decimal.equal?(eur_max, "9.99")

    assert Components.format_supplier_costs(ranges[item.uuid]) == "4.00 USD, 5.69–9.99 EUR"
    assert Catalogue.supplier_cost_ranges([]) == %{}
  end

  test "formatting: single price, range, nothing" do
    one = [%{currency: "EUR", min: Decimal.new("5.69"), max: Decimal.new("5.69"), count: 1}]
    range = [%{currency: nil, min: Decimal.new("5.69"), max: Decimal.new("9.99"), count: 3}]

    assert Components.format_supplier_costs(one) == "5.69"
    assert Components.format_supplier_costs(range) == "5.69–9.99"
    assert Components.format_supplier_costs([]) == "—"
    assert Components.format_supplier_costs(nil) == "—"
  end
end
