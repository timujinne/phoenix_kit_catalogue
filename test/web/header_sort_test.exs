defmodule PhoenixKitCatalogue.Web.HeaderSortTest do
  @moduledoc """
  Column headers sort by a click once the list is out of Manual order, and
  are plain labels in Manual order (boss via Max, 2026-09-21: "when the
  sorting mode isn't in manual, the column headers would have the arrow…
  if it was manual, the arrows wouldn't be there").

  In Manual order a header click would silently leave the order someone
  arranged by hand and take the drag handles with it, so there the sort
  dropdown is the one way out. Every table is driven through its real
  controls and read back.
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Web.Components
  alias PhoenixKitCatalogue.Web.ViewConfig

  @base "/en/admin/catalogue"

  setup %{conn: conn, scope: scope} do
    before =
      for s <- [:catalogues, :detail_categories, :detail_items],
          into: %{},
          do: {s, ViewConfig.load_global_sort(s)}

    on_exit(fn -> for {s, {by, dir}} <- before, do: ViewConfig.save_global_sort(s, by, dir) end)

    # Every list starts in Manual order, whatever an earlier test left.
    for s <- Map.keys(before), do: ViewConfig.save_global_sort(s, "position", :asc)

    catalogue = fixture_catalogue(%{name: "Headers"})
    fixture_category(catalogue, %{name: "B cat", position: 0})
    fixture_category(catalogue, %{name: "A cat", position: 1})

    %{conn: with_scope(conn, scope), catalogue: catalogue}
  end

  test "header_sort/2: nil in Manual order, the sort otherwise" do
    assert Components.header_sort(:position, :asc) == nil
    assert Components.header_sort("position", :desc) == nil
    assert Components.header_sort(:name, :desc) == %{by: :name, dir: :desc}
    assert Components.header_sort("updated", :asc) == %{by: "updated", dir: :asc}
  end

  describe "a catalogue's categories" do
    @header ~s(#catalogue-categories-tree th button[phx-click="toggle_sort_categories"])

    test "no header sorts in Manual order", %{conn: conn, catalogue: c} do
      {:ok, view, _html} = live(conn, "#{@base}/#{c.uuid}")
      refute has_element?(view, @header)
    end

    test "out of Manual order the headers sort, and a click re-sorts", %{
      conn: conn,
      catalogue: c
    } do
      {:ok, view, _html} = live(conn, "#{@base}/#{c.uuid}")
      view |> element("#categories-sort-selector") |> render_change(%{"sort_by" => "updated"})

      assert has_element?(view, ~s(#{@header}[phx-value-by="name"]))

      view |> element(~s(#{@header}[phx-value-by="name"])) |> render_click()
      assert ViewConfig.load_global_sort(:detail_categories) == {"name", :asc}

      # The same header again flips the direction.
      view |> element(~s(#{@header}[phx-value-by="name"])) |> render_click()
      assert ViewConfig.load_global_sort(:detail_categories) == {"name", :desc}
    end

    test "a pushed header click naming Manual order is ignored", %{conn: conn, catalogue: c} do
      {:ok, view, _html} = live(conn, "#{@base}/#{c.uuid}")
      view |> element("#categories-sort-selector") |> render_change(%{"sort_by" => "name"})

      render_click(view, "toggle_sort_categories", %{"by" => "position"})
      assert ViewConfig.load_global_sort(:detail_categories) == {"name", :asc}
    end
  end

  describe "a catalogue's items" do
    setup %{catalogue: c} do
      # An item-only level puts the items list on the page.
      bare = fixture_catalogue(%{name: "Items only"})
      fixture_item(%{catalogue_uuid: bare.uuid, name: "Hinge", sku: "H-1"})
      fixture_item(%{catalogue_uuid: bare.uuid, name: "Door", sku: "D-1"})
      %{items_catalogue: bare, catalogue: c}
    end

    @header ~s(th button[phx-click="toggle_sort_items"])

    test "no header sorts in Manual order; out of it they do", %{
      conn: conn,
      items_catalogue: c
    } do
      {:ok, view, _html} = live(conn, "#{@base}/#{c.uuid}")
      refute has_element?(view, @header)

      render_change(view, "sort_items", %{"sort_by" => "name"})
      assert has_element?(view, ~s(#{@header}[phx-value-by="sku"]))

      view |> element(~s(#{@header}[phx-value-by="sku"])) |> render_click()
      assert ViewConfig.load_global_sort(:detail_items) == {"sku", :asc}
    end

    test "a pushed header click naming Manual order is ignored", %{
      conn: conn,
      items_catalogue: c
    } do
      {:ok, view, _html} = live(conn, "#{@base}/#{c.uuid}")
      render_change(view, "sort_items", %{"sort_by" => "name"})

      render_click(view, "toggle_sort_items", %{"by" => "position"})
      assert ViewConfig.load_global_sort(:detail_items) == {"name", :asc}
    end
  end

  describe "the catalogues index" do
    @header ~s(th button[phx-click="toggle_sort"])

    test "no header sorts in Manual order; out of it they do", %{conn: conn} do
      {:ok, view, _html} = live(conn, @base)
      refute has_element?(view, @header)

      render_change(view, "set_sort", %{"sort_by" => "name"})
      assert has_element?(view, ~s(#{@header}[phx-value-by="name"]))

      view |> element(~s(#{@header}[phx-value-by="name"])) |> render_click()
      assert ViewConfig.load_global_sort(:catalogues) == {"name", :desc}
    end

    test "a pushed header click naming Manual order is ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, @base)
      render_change(view, "set_sort", %{"sort_by" => "name"})

      render_click(view, "toggle_sort", %{"by" => "position"})
      assert ViewConfig.load_global_sort(:catalogues) == {"name", :asc}
    end
  end
end
