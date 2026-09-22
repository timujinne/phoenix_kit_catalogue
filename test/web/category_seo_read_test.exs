defmodule PhoenixKitCatalogue.Web.CategorySeoReadTest do
  @moduledoc """
  A single-language install stored a category's SEO text flat in `data`,
  the form read it back from a per-language map that is empty there, showed
  blanks — and the next save posted the blanks over the text. Found while
  hiding the item form's SEO fields (2026-09-21); the category form had the
  same reader.
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  test "saved SEO text shows again and survives a second save", %{conn: conn, scope: scope} do
    conn = with_scope(conn, scope)
    catalogue = fixture_catalogue(%{name: "Cat SEO"})
    category = fixture_category(catalogue, %{name: "Doors"})
    url = "/en/admin/catalogue/categories/#{category.uuid}/edit"

    {:ok, view, _html} = live(conn, url)

    view
    |> form("#category-form", %{"category" => %{"seo_title" => "Door title"}})
    |> render_submit()

    {:ok, view, html} = live(conn, url)
    assert html =~ "Door title"

    view |> form("#category-form", %{"category" => %{"name" => "Doors 2"}}) |> render_submit()

    {:ok, _view, html} = live(conn, url)
    assert html =~ "Door title"
  end
end
