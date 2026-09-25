defmodule PhoenixKitCatalogue.Web.ItemTypeSelectorTest do
  @moduledoc """
  `scope.item_types` in `ItemSelectorModal` (the warehouse's "goods only"
  picker): the listing, the level counters, the preselection check and the
  detail lookup all go by the EFFECTIVE item type.
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue

  setup do
    cat = fixture_catalogue(%{name: "Mixed Catalogue"})
    shelf = fixture_category(cat, %{name: "Shelf"})

    {:ok, bolt} =
      Catalogue.create_item(%{
        name: "Hex Bolt",
        catalogue_uuid: cat.uuid,
        category_uuid: shelf.uuid
      })

    # The only loose (uncategorized) item is a service.
    {:ok, transport} =
      Catalogue.create_item(%{
        name: "Transport Run",
        catalogue_uuid: cat.uuid,
        item_type: "service"
      })

    %{cat: cat, shelf: shelf, bolt: bolt, transport: transport}
  end

  defp open(conn, query), do: live(conn, "/test/selector-host?#{query}")
  defp picker(view), do: with_target(view, "#picker")

  test "a goods-only scope never lists a service", %{conn: conn, cat: cat, shelf: shelf} do
    {:ok, view, _html} = open(conn, "c=#{cat.uuid}&types=goods&sel=click")

    html = view |> picker() |> render_change("browse_search", %{"search" => ""})
    refute html =~ "Transport Run"

    html = view |> picker() |> render_click("browse_category", %{"uuid" => shelf.uuid})
    assert html =~ "Hex Bolt"

    html = view |> picker() |> render_change("browse_search", %{"search" => "Transport"})
    refute html =~ "Transport Run"
  end

  test "without the scope key both types are listed", %{conn: conn, cat: cat} do
    {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")
    html = view |> picker() |> render_change("browse_search", %{"search" => "Transport"})
    assert html =~ "Transport Run"
  end

  test "the uncategorized counter counts goods only, so a services-only bucket is hidden",
       %{conn: conn, cat: cat} do
    {:ok, _view, html} = open(conn, "c=#{cat.uuid}&sel=click")
    assert html =~ "__uncategorized__"

    {:ok, _view, html} = open(conn, "c=#{cat.uuid}&types=goods&sel=click")
    refute html =~ "__uncategorized__"
  end

  test "a preselected service is unavailable under a goods scope", %{
    conn: conn,
    cat: cat,
    transport: transport
  } do
    {:ok, view, _html} = open(conn, "c=#{cat.uuid}&types=goods&pre=#{transport.uuid}:1&sel=click")

    view |> picker() |> render_click("toggle_tray", %{})
    assert render(view) =~ "Not available in this selection"

    view |> picker() |> render_click("confirm", %{})
    refute render(view) =~ ~s(id="picked")
  end

  test "an item that became a service after it was listed opens no detail", %{
    conn: conn,
    cat: cat,
    shelf: shelf,
    bolt: bolt
  } do
    {:ok, view, _html} = open(conn, "c=#{cat.uuid}&types=goods&details=true&sel=click")
    view |> picker() |> render_click("browse_category", %{"uuid" => shelf.uuid})

    {:ok, _} = Catalogue.update_item(bolt, %{item_type: "service"})

    view |> picker() |> render_click("show_detail", %{"uuid" => to_string(bolt.uuid)})
    refute has_element?(view, "#picker-detail-card")
  end
end
