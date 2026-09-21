defmodule PhoenixKitCatalogue.Web.NoTutorialHintsTest do
  @moduledoc """
  The pages carry no "how to use this page" hints (boss, 2026-09-19: "remove
  the tutorial stuff"). Checked in the states that used to show them: a
  name-sorted item list (the drag-reorder hint) and a searched index (the
  folder-tree hint).
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Web.ViewConfig

  @base "/en/admin/catalogue"

  setup %{conn: conn, scope: scope} do
    catalogue = fixture_catalogue(%{name: "Hints cat"})
    category = fixture_category(catalogue, %{name: "Hints chapter"})

    for name <- ["Alpha hint item", "Beta hint item"] do
      fixture_item(%{name: name, catalogue_uuid: catalogue.uuid, category_uuid: category.uuid})
    end

    %{conn: with_scope(conn, scope), catalogue: catalogue, category: category}
  end

  test "a name-sorted item list explains nothing about drag-reorder", %{
    conn: conn,
    catalogue: catalogue,
    category: category
  } do
    ViewConfig.save_global_sort(:detail_items, "name", :asc)
    {:ok, _view, html} = live(conn, "#{@base}/#{catalogue.uuid}?category=#{category.uuid}")

    assert html =~ "Alpha hint item"
    refute html =~ "Drag-reorder"
    refute html =~ "sort selector"
  end

  test "a searched index says nothing about the folder tree", %{conn: conn} do
    {:ok, _view, html} = live(conn, "#{@base}?q=Hints")

    refute html =~ "to see the folder tree"
  end
end
