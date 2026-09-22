defmodule PhoenixKitCatalogue.Web.PreviewColumnTest do
  @moduledoc """
  Every admin list carries a preview column, and every row fills it (boss
  via Max, 2026-09-21: "sometimes we have the image previews with the
  letter inside, sometimes we don't — and when we don't we sometimes have
  an offset anyway… either have the offset with the image previews or don't
  have it at all").

  The column used to appear only when some row on that level had a picture,
  so a list's names moved from level to level, and the rows without one sat
  beside an empty gap. Now: a picture, the files tile, or the item picker's
  letter tile — the picker's own rule.
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Web.Components

  @base "/en/admin/catalogue"

  setup %{conn: conn, scope: scope} do
    catalogue = fixture_catalogue(%{name: "Previews"})
    fixture_category(catalogue, %{name: "melamine", position: 0})
    fixture_category(catalogue, %{name: "Veneer", position: 1})
    %{conn: with_scope(conn, scope), catalogue: catalogue}
  end

  defp rows(html, selector) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.to_list()
  end

  test "no picture anywhere: the column is still there, each row a letter tile", %{
    conn: conn,
    catalogue: c
  } do
    {:ok, _view, html} = live(conn, "#{@base}/#{c.uuid}")

    tree_rows = rows(html, ~s(#catalogue-categories-tree [id^="category-tree-row-"]))
    assert length(tree_rows) == 2

    letters =
      Enum.map(tree_rows, fn row ->
        row |> LazyHTML.query("[data-thumb-letter]") |> LazyHTML.text() |> String.trim()
      end)

    # Upper-cased first letter, the picker's tile.
    assert letters == ["M", "V"]
  end

  test "an item without a photo gets the SKU's initial, as in the picker", %{conn: conn} do
    bare = fixture_catalogue(%{name: "Items level"})
    fixture_item(%{catalogue_uuid: bare.uuid, name: "Hinge", sku: "x-100"})

    {:ok, _view, html} = live(conn, "#{@base}/#{bare.uuid}")

    assert html |> rows("[data-thumb-letter]") |> Enum.map(&String.trim(LazyHTML.text(&1))) ==
             ["X"]
  end

  test "the index: folders get a folder tile, catalogues a letter, no stray type icons", %{
    conn: conn
  } do
    {:ok, folder} = Catalogue.create_folder(%{name: "A folder"})

    {:ok, view, _html} = live(conn, @base)
    html = render(view)

    folder_row = rows(html, ~s(#catalogues-tree-table tr[data-tree-uuid="#{folder.uuid}"]))
    assert [row] = folder_row
    assert LazyHTML.to_html(row) =~ "hero-folder"

    assert rows(html, "#catalogues-tree-table [data-thumb-letter]") != []
    refute html =~ "hero-document-text"
  end

  test "a picture wins over the letter" do
    uuid = UUIDv7.generate()
    resource = %{uuid: UUIDv7.generate(), name: "Oak", data: %{"featured_image_uuid" => uuid}}

    html = render_component(&Components.featured_thumb/1, resource: resource, letter: true)
    assert html =~ "<img"
    refute html =~ "data-thumb-letter"
  end

  test "without the opt-in, a row with no picture still renders nothing (cards, fill slots)" do
    resource = %{uuid: UUIDv7.generate(), name: "Oak", data: %{}}

    assert render_component(&Components.featured_thumb/1, resource: resource) |> String.trim() ==
             ""
  end
end
