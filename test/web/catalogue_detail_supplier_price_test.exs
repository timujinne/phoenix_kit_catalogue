defmodule PhoenixKitCatalogue.Web.CatalogueDetailSupplierPriceTest do
  @moduledoc """
  The catalogue page's "Supplier price" column: on by default, shows the
  min–max of the item's current supplier prices, and follows supplier-row
  changes live without a reload.
  """
  use PhoenixKitCatalogue.LiveCase

  alias PhoenixKitCatalogue.Catalogue

  @base "/en/admin/catalogue"

  setup do
    cat = fixture_catalogue(%{name: "Prices"})
    alpha = fixture_category(cat, %{name: "Alpha"})
    item = fixture_item(%{catalogue_uuid: cat.uuid, category_uuid: alpha.uuid, name: "Pipe"})
    s1 = fixture_supplier(%{name: "Cheap"})
    s2 = fixture_supplier(%{name: "Dear"})
    %{catalogue: cat, alpha: alpha, item: item, s1: s1, s2: s2}
  end

  defp price!(item, supplier, cost) do
    {:ok, row} =
      Catalogue.create_supplier_info(%{
        item_uuid: item.uuid,
        supplier_uuid: supplier.uuid,
        unit_cost: Decimal.new(cost),
        currency: "EUR"
      })

    row
  end

  test "renders the range in the table and follows supplier changes live",
       %{conn: conn, catalogue: cat, alpha: alpha, item: item, s1: s1, s2: s2} do
    price!(item, s1, "5.69")
    price!(item, s2, "9.99")

    {:ok, view, html} = live(conn, "#{@base}/#{cat.uuid}?category=#{alpha.uuid}&mode=items")

    assert html =~ "Supplier price"
    assert html =~ "5.69–9.99"

    # A third supplier undercuts everyone: the page hears the broadcast
    # and re-derives just this column.
    s3 = fixture_supplier(%{name: "Cheapest"})
    price!(item, s3, "4.20")

    assert render(view) =~ "4.20–9.99"
    refute render(view) =~ "5.69–9.99"
  end

  test "an item with no priced supplier shows a dash", %{conn: conn, catalogue: cat, alpha: alpha} do
    {:ok, _view, html} = live(conn, "#{@base}/#{cat.uuid}?category=#{alpha.uuid}&mode=items")
    assert html =~ "Supplier price"
    refute html =~ "–"
  end
end
