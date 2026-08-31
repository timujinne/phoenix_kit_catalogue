defmodule PhoenixKitCatalogue.Web.DeadRenderSkeletonsTest do
  @moduledoc """
  Every page that defers its data to the connected mount must render a
  skeleton on the dead HTTP render — not an empty state. "No catalogues
  yet." / "No PDFs uploaded yet." / "No events recorded yet" / "No
  categories or items yet" all flashed on pages that were NOT empty
  (Max's report, 2026-08-27, first seen on the attributes tab — that
  page's dead render is pinned in attribute_sets_surfaces_test.exs).
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  setup %{conn: conn, scope: scope} do
    %{conn: with_scope(conn, scope)}
  end

  test "catalogues index: skeleton, not 'No catalogues yet.'", %{conn: conn} do
    fixture_catalogue(%{name: "Dead Render Cat"})

    static = conn |> get("/en/admin/catalogue") |> html_response(200)
    refute static =~ "No catalogues yet."
    assert static =~ "skeleton"

    {:ok, _view, html} = live(conn, "/en/admin/catalogue")
    assert html =~ "Dead Render Cat"
  end

  test "catalogue detail: spinner, not 'No categories or items yet'", %{conn: conn} do
    # This page was already safe: the body is gated on :if={@catalogue}
    # (nil until the connected load) and the dead render shows a spinner.
    cat = fixture_catalogue(%{name: "Detail Dead Render"})
    fixture_item(%{name: "Detail Item", catalogue_uuid: cat.uuid})

    static = conn |> get("/en/admin/catalogue/#{cat.uuid}") |> html_response(200)
    refute static =~ "No categories or items yet"
    assert static =~ "loading-spinner"

    {:ok, _view, html} = live(conn, "/en/admin/catalogue/#{cat.uuid}?mode=items")
    assert html =~ "Detail Item"
  end

  test "PDF library: skeleton, not 'No PDFs uploaded yet.'", %{conn: conn} do
    static = conn |> get("/en/admin/catalogue/pdfs") |> html_response(200)
    refute static =~ "No PDFs uploaded yet."
    assert static =~ "skeleton"
  end

  test "events log: skeleton, not 'No events recorded yet'", %{conn: conn} do
    static = conn |> get("/en/admin/catalogue/events") |> html_response(200)
    refute static =~ "No events recorded yet"
    assert static =~ "skeleton"

    # The first connected load clears the initial loading flag, so a
    # genuinely empty log still reaches its real empty state.
    {:ok, view, _html} = live(conn, "/en/admin/catalogue/events")
    refute :sys.get_state(view.pid).socket.assigns.loading
  end
end
