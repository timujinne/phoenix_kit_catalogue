defmodule PhoenixKitCatalogue.Web.ItemLocationLocaleTest do
  @moduledoc """
  The item form's Location — the path under the section and the tree its
  picker opens — and the header's catalogue name are in the language the
  page is shown in, as every other place picker is.
  """
  use PhoenixKitCatalogue.LiveCase

  alias PhoenixKitCatalogue.Catalogue

  # "et" is the records' own primary language; the page is in English.
  @primary %{data: %{"_primary_language" => "et"}}

  defp translate!(record, name, update) do
    {:ok, _} = Catalogue.set_translation(record, "en", %{"_name" => name}, update)
  end

  test "the path and the picker's tree follow the page language", %{conn: conn} do
    catalogue = fixture_catalogue(Map.merge(%{name: "Primaarne kataloog"}, @primary))
    category = fixture_category(catalogue, Map.merge(%{name: "Uksed"}, @primary))
    item = fixture_item(%{name: "Tamm", category_uuid: category.uuid})

    translate!(catalogue, "Primary Catalogue", &Catalogue.update_catalogue(&1, &2))
    translate!(category, "Doors", &Catalogue.update_category(&1, &2))

    {:ok, view, html} = live(conn, "/en/admin/catalogue/items/#{item.uuid}/edit")
    assert html =~ "Doors"
    refute html =~ "Uksed"

    html = render_click(view, "open_location_picker", %{})
    assert html =~ "Primary Catalogue"
    refute html =~ "Primaarne kataloog"
  end
end
