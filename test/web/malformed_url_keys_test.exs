defmodule PhoenixKitCatalogue.Web.MalformedUrlKeysTest do
  @moduledoc """
  A hand-edited URL must never wedge a page (boss, 2026-09-19: `page=5`
  typed onto a category's URL with a second `?` — `?category=<uuid>?page=5`
  — made the category key "<uuid>?page=5"). Ecto raised a CastError on it
  during the CONNECTED mount only, so the page rendered, crashed, reloaded
  and crashed again: an endless spinner. A key that is not a UUID names no
  row; every getter now says "not found", and the pages already know what
  to do with that.
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.Helpers

  @base "/en/admin/catalogue"

  describe "the getters answer not-found for a key that is not a UUID" do
    test "nil from the plain getters, NoResultsError from the bang ones" do
      for bad <- ["019da71b-c248-7c6f-b5d2-9de1041a798d?page=5", "not-a-uuid", "", nil, 5] do
        refute Helpers.uuid?(bad)
        assert Catalogue.get_catalogue(bad) == nil
        assert Catalogue.get_category(bad) == nil
        assert Catalogue.get_item(bad) == nil
        assert Catalogue.get_folder(bad) == nil
        assert Catalogue.get_pdf(bad) == nil
        assert Catalogue.get_attribute_group(bad) == nil
        assert Catalogue.get_attribute(bad) == nil
        assert Catalogue.get_attribute_value(bad) == nil
        assert_raise Ecto.NoResultsError, fn -> Catalogue.fetch_catalogue!(bad) end
        assert_raise Ecto.NoResultsError, fn -> Catalogue.get_category!(bad) end
        assert_raise Ecto.NoResultsError, fn -> Catalogue.get_item!(bad) end
      end
    end

    test "a real UUID still finds its row" do
      catalogue = fixture_catalogue(%{name: "Keys cat"})
      assert Helpers.uuid?(catalogue.uuid)
      assert Catalogue.get_catalogue(catalogue.uuid).uuid == catalogue.uuid
      assert Catalogue.fetch_catalogue!(catalogue.uuid).uuid == catalogue.uuid
    end
  end

  describe "the new-item and new-category forms check their catalogue first" do
    setup %{conn: conn, scope: scope} do
      %{conn: with_scope(conn, scope)}
    end

    for {label, suffix} <- [{"item", "items/new"}, {"category", "categories/new"}],
        bad <- ["not-a-uuid", "019da71b-0000-7000-8000-000000000000"] do
      test "a new #{label} under #{bad} goes back to the list", %{conn: conn} do
        result = live(conn, "#{@base}/#{unquote(bad)}/#{unquote(suffix)}")
        assert {:error, {:live_redirect, %{to: to}}} = result
        assert to =~ @base

        {:ok, _index, html} = follow_redirect(result, conn)
        assert html =~ "Catalogue not found."
      end
    end

    test "a garbage ?category= on a real catalogue's new item is simply ignored", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Keys cat"})
      {:ok, view, _html} = live(conn, "#{@base}/#{catalogue.uuid}/items/new?category=junk?page=5")
      assert Process.alive?(view.pid)
    end
  end

  describe "the detail page recovers from a hand-edited URL" do
    setup %{conn: conn, scope: scope} do
      catalogue = fixture_catalogue(%{name: "Keys cat"})
      category = fixture_category(catalogue, %{name: "Keys chapter"})
      %{conn: with_scope(conn, scope), catalogue: catalogue, category: category}
    end

    test "?category=<uuid>?page=5 (the boss's URL) lands on the catalogue with a message", %{
      conn: conn,
      catalogue: catalogue,
      category: category
    } do
      {:ok, view, _html} =
        live(conn, "#{@base}/#{catalogue.uuid}?category=#{category.uuid}?page=5")

      html = render(view)
      assert html =~ "Category not found."
      assert :sys.get_state(view.pid).socket.assigns.current_category == nil
      assert Process.alive?(view.pid)
    end

    test "a proper &page=5 is simply ignored", %{
      conn: conn,
      catalogue: catalogue,
      category: category
    } do
      {:ok, view, _html} =
        live(conn, "#{@base}/#{catalogue.uuid}?category=#{category.uuid}&page=5")

      assert :sys.get_state(view.pid).socket.assigns.current_category.uuid == category.uuid
    end

    test "&page=5 glued onto the catalogue's own uuid goes back to the list", %{
      conn: conn,
      catalogue: catalogue
    } do
      result = live(conn, "#{@base}/#{catalogue.uuid}&page=5")
      assert {:error, {:live_redirect, %{to: to}}} = result
      assert to =~ @base

      {:ok, _index, html} = follow_redirect(result, conn)
      assert html =~ "Catalogue not found."
    end
  end
end
