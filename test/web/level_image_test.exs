defmodule PhoenixKitCatalogue.Web.LevelImageTest do
  @moduledoc """
  The place you are in shows its own picture (boss via Max, 2026-09-21:
  "when you're inside a category there's no way to see the image attached").
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue

  @base "/en/admin/catalogue"

  setup %{conn: conn, scope: scope} do
    catalogue = fixture_catalogue(%{name: "Pictures"})
    category = fixture_category(catalogue, %{name: "Doors"})
    %{conn: with_scope(conn, scope), catalogue: catalogue, category: category}
  end

  defp with_image(%{__struct__: _} = record, update) do
    image = UUIDv7.generate()

    {:ok, updated} =
      update.(record, %{data: Map.put(record.data || %{}, "featured_image_uuid", image)})

    {updated, image}
  end

  test "inside a category its picture shows, and opens its View card", %{
    conn: conn,
    catalogue: c,
    category: cat
  } do
    {_cat, image} = with_image(cat, &Catalogue.update_category/2)

    {:ok, view, _html} = live(conn, "#{@base}/#{c.uuid}?category=#{cat.uuid}")

    assert view |> element("#level-image") |> render() =~ image

    view |> element("#level-image") |> render_click()
    assert render(view) =~ "Doors"
    assert :sys.get_state(view.pid).socket.assigns[:card_open]
  end

  test "a category without a picture shows none — no empty frame", %{
    conn: conn,
    catalogue: c,
    category: cat
  } do
    {:ok, view, _html} = live(conn, "#{@base}/#{c.uuid}?category=#{cat.uuid}")
    refute has_element?(view, "#level-image")
  end

  test "the catalogue's top level shows the catalogue's picture, which opens its card",
       %{conn: conn, catalogue: c} do
    {_c, image} = with_image(c, &Catalogue.update_catalogue/2)

    {:ok, view, _html} = live(conn, "#{@base}/#{c.uuid}")
    assert view |> element("#level-image") |> render() =~ image

    view |> element("#level-image") |> render_click()
    assert :sys.get_state(view.pid).socket.assigns[:card_open]
    assert :sys.get_state(view.pid).socket.assigns[:card_name] == c.name
  end
end
