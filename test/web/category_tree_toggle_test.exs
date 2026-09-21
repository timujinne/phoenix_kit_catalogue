defmodule PhoenixKitCatalogue.Web.CategoryTreeToggleTest do
  @moduledoc """
  The category tree's expand control says what it does (boss, 2026-09-19:
  the bare `›` before a name did not read as "this opens the
  subcategories"). A row with subcategories carries a button naming the
  count after its name; a row without has nothing, and no reserved gap;
  the rows it opens hang off guide rails, untinted — a blue row reads as
  selected here.
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Web.TableConfig

  @base "/en/admin/catalogue"

  setup %{conn: conn, scope: scope} do
    catalogue = fixture_catalogue(%{name: "Tree cat"})
    parent = fixture_category(catalogue, %{name: "Doors", position: 0})
    leaf = fixture_category(catalogue, %{name: "Handles", position: 1})
    fixture_category(catalogue, %{name: "Oak doors", parent_uuid: parent.uuid, position: 0})
    fixture_category(catalogue, %{name: "Glass doors", parent_uuid: parent.uuid, position: 1})

    %{conn: with_scope(conn, scope), catalogue: catalogue, parent: parent, leaf: leaf}
  end

  defp row(html, uuid) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query("#category-tree-row-#{uuid}")
  end

  defp tree_html(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#catalogue-categories-tree")
    |> LazyHTML.to_html()
  end

  defp toggle(html, uuid) do
    row(html, uuid) |> LazyHTML.query(~s(button[phx-click="toggle_category_expand"]))
  end

  test "a row with subcategories names them; a row without has no control and no gap", %{
    conn: conn,
    catalogue: catalogue,
    parent: parent,
    leaf: leaf
  } do
    {:ok, _view, html} = live(conn, "#{@base}/#{catalogue.uuid}")

    button = toggle(html, parent.uuid)
    assert LazyHTML.text(button) =~ "2 subcategories"
    assert LazyHTML.attribute(button, "aria-expanded") == ["false"]

    assert Enum.empty?(toggle(html, leaf.uuid))
    # The old reserved 20px spacer and the chevron are gone.
    refute LazyHTML.to_html(row(html, leaf.uuid)) =~ "w-5 shrink-0"
    refute tree_html(html) =~ "hero-chevron-right-mini"

    # Collapsed: the children are not in the tree yet.
    refute tree_html(html) =~ "Oak doors"
  end

  test "the button opens the branch: children appear on guide rails, nothing looks selected", %{
    conn: conn,
    catalogue: catalogue,
    parent: parent
  } do
    {:ok, view, _html} = live(conn, "#{@base}/#{catalogue.uuid}")

    html =
      view
      |> element(~s(#category-tree-row-#{parent.uuid} button[phx-click="toggle_category_expand"]))
      |> render_click()

    assert tree_html(html) =~ "Oak doors"
    assert tree_html(html) =~ "Glass doors"
    assert LazyHTML.attribute(toggle(html, parent.uuid), "aria-expanded") == ["true"]

    rows =
      html |> LazyHTML.from_fragment() |> LazyHTML.query("#catalogue-categories-tree tbody tr")

    # No tint on the open branch: blue rows read as selected rows here.
    refute Enum.any?(rows, &(LazyHTML.attribute(&1, "class") |> List.first("") =~ "bg-primary"))

    # Each child hangs off one guide rail; a top-level row has none.
    child_rail =
      rows
      |> Enum.find(&(LazyHTML.text(&1) =~ "Oak doors"))
      |> LazyHTML.query("span[aria-hidden].border-l-2")

    assert Enum.count(child_rail) == 1
    assert Enum.empty?(row(html, parent.uuid) |> LazyHTML.query("span[aria-hidden].border-l-2"))

    # And closes again.
    html =
      view
      |> element(~s(#category-tree-row-#{parent.uuid} button[phx-click="toggle_category_expand"]))
      |> render_click()

    refute tree_html(html) =~ "Oak doors"
  end

  test "the sorted (flat) table says the same thing in words", %{
    conn: conn,
    catalogue: catalogue
  } do
    {:ok, view, _html} = live(conn, "#{@base}/#{catalogue.uuid}")
    html = render_click(view, "sort_categories", %{"sort_by" => "name"})

    flat =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("table")
      |> Enum.find(&(LazyHTML.to_html(&1) =~ "catalogue-child-categories"))
      |> LazyHTML.to_html()

    assert flat =~ "2 subcategories"
    refute flat =~ "hero-rectangle-stack"
  end

  test "the Subcategories column is no longer on by default — the button carries the count" do
    refute "subcategories" in TableConfig.default_columns(:detail_categories)
    assert "subcategories" in Enum.map(TableConfig.managed_columns(:detail_categories), & &1.id)
  end
end
