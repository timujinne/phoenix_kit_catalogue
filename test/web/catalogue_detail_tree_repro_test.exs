defmodule PhoenixKitCatalogue.Web.CatalogueDetailTreeReproTest do
  @moduledoc """
  A reported bug: a category moved around repeatedly in the detail tree showed
  up twice. Replays that sequence through the real detail page, ten rounds,
  and asserts after every step that the category exists once in the DB and
  once in the tree.
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  import Ecto.Query

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Schemas.Category
  alias PhoenixKitCatalogue.Test.Repo

  @base "/en/admin/catalogues"

  defp db_count(name) do
    Repo.aggregate(from(c in Category, where: c.name == ^name), :count)
  end

  # The page renders the tree twice — the table (desktop) and the card
  # level (phone), one shown per breakpoint — so count table rows only.
  defp tree_count(html, uuid), do: length(Regex.scan(~r/<tr[^>]*data-tree-uuid="#{uuid}"/, html))
  defp card_count(html, uuid), do: length(Regex.scan(~r/<div[^>]*data-tree-uuid="#{uuid}"/, html))

  defp settle(view) do
    # Let the page's own PubSub broadcasts (moved/reordered) be handled.
    _ = :sys.get_state(view.pid)
    render(view)
  end

  test "moving a freshly created category in and out of a sibling never doubles it", %{
    conn: conn
  } do
    catalogue = fixture_catalogue(%{name: "Kitchen furniture"})
    carcasses = fixture_category(catalogue, %{name: "Cabinet carcasses", position: 0})
    melamine = fixture_category(catalogue, %{name: "Melamine", parent_uuid: carcasses.uuid})
    other = fixture_category(catalogue, %{name: "Melamine Lux", parent_uuid: melamine.uuid})

    # The New Category form, opened from Cabinet carcasses, creates it there.
    {:ok, standard} =
      Catalogue.create_category(%{
        name: "Melamine Standard",
        catalogue_uuid: catalogue.uuid,
        parent_uuid: carcasses.uuid,
        position: Catalogue.next_category_position(catalogue.uuid, carcasses.uuid)
      })

    {:ok, view, _html} = live(conn, "#{@base}/#{catalogue.uuid}?category=#{carcasses.uuid}")
    render_click(view, "toggle_category_expand", %{"uuid" => melamine.uuid})
    html = settle(view)
    assert tree_count(html, standard.uuid) == 1

    for round <- 1..10 do
      # Edge drop under Melamine, before its existing child.
      render_click(view, "drop_row", %{
        "type" => "category",
        "uuid" => standard.uuid,
        "parent" => melamine.uuid,
        "entries" => ["category:#{standard.uuid}", "category:#{other.uuid}"]
      })

      html = settle(view)
      assert db_count("Melamine Standard") == 1, "round #{round}: DB doubled after nesting"
      assert tree_count(html, standard.uuid) == 1, "round #{round}: tree doubled after nesting"
      assert Catalogue.get_category(standard.uuid).parent_uuid == melamine.uuid

      # Swap places with the sibling (edge drop after it).
      render_click(view, "drop_row", %{
        "type" => "category",
        "uuid" => standard.uuid,
        "parent" => melamine.uuid,
        "entries" => ["category:#{other.uuid}", "category:#{standard.uuid}"]
      })

      html = settle(view)
      assert db_count("Melamine Standard") == 1, "round #{round}: DB doubled after swap"
      assert tree_count(html, standard.uuid) == 1, "round #{round}: tree doubled after swap"

      # Middle drop straight onto Melamine (already its parent — a no-op move).
      render_click(view, "move_to_folder", %{
        "type" => "category",
        "uuid" => standard.uuid,
        "target" => melamine.uuid
      })

      html = settle(view)
      assert db_count("Melamine Standard") == 1, "round #{round}: DB doubled after re-drop"
      assert tree_count(html, standard.uuid) == 1, "round #{round}: tree doubled after re-drop"

      # Back out to the Cabinet carcasses level, before Melamine.
      render_click(view, "drop_row", %{
        "type" => "category",
        "uuid" => standard.uuid,
        "parent" => "root",
        "entries" => ["category:#{standard.uuid}", "category:#{melamine.uuid}"]
      })

      html = settle(view)
      assert db_count("Melamine Standard") == 1, "round #{round}: DB doubled after lifting"
      assert tree_count(html, standard.uuid) == 1, "round #{round}: tree doubled after lifting"
      assert card_count(html, standard.uuid) == 1, "round #{round}: cards doubled after lifting"
      assert Catalogue.get_category(standard.uuid).parent_uuid == carcasses.uuid
    end

    # The whole tree, once each.
    html = settle(view)
    assert tree_count(html, melamine.uuid) == 1
    assert tree_count(html, other.uuid) == 1
    assert db_count("Melamine") == 1
  end

  test "a category created or moved in another tab reaches the open tree without a reload", %{
    conn: conn
  } do
    catalogue = fixture_catalogue(%{name: "Two Tabs"})
    parent = fixture_category(catalogue, %{name: "Parent", position: 0})
    {:ok, view, html} = live(conn, "#{@base}/#{catalogue.uuid}")
    assert tree_count(html, parent.uuid) == 1

    # Tab B creates a sibling and nests a child under Parent.
    {:ok, sibling} =
      Catalogue.create_category(%{name: "From tab B", catalogue_uuid: catalogue.uuid})

    {:ok, child} =
      Catalogue.create_category(%{
        name: "Nested from tab B",
        catalogue_uuid: catalogue.uuid,
        parent_uuid: parent.uuid
      })

    send(view.pid, {:catalogue_data_changed, :category, sibling.uuid, catalogue.uuid})
    html = settle(view)
    assert tree_count(html, sibling.uuid) == 1
    # Parent now has a child: it gets a chevron (expandable) at once.
    render_click(view, "toggle_category_expand", %{"uuid" => parent.uuid})
    assert tree_count(settle(view), child.uuid) == 1
  end

  test "the tree remembers open parents through the browser, and a move names its destination", %{
    conn: conn
  } do
    catalogue = fixture_catalogue(%{name: "Memory"})
    parent = fixture_category(catalogue, %{name: "Parent", position: 0})
    child = fixture_category(catalogue, %{name: "Child", parent_uuid: parent.uuid})
    loose = fixture_category(catalogue, %{name: "Loose", position: 1})
    {:ok, view, html} = live(conn, "#{@base}/#{catalogue.uuid}")
    assert tree_count(html, child.uuid) == 0

    # Opening a parent hands the open set to the hook, which stores it.
    render_click(view, "toggle_category_expand", %{"uuid" => parent.uuid})
    assert_push_event(view, "category_tree_open", %{uuids: [uuid]})
    assert uuid == parent.uuid

    # A fresh mount restores what the browser remembered; junk is ignored.
    {:ok, view2, html2} = live(conn, "#{@base}/#{catalogue.uuid}")
    assert tree_count(html2, child.uuid) == 0

    html2 =
      render_hook(view2, "restore_expanded_categories", %{
        "uuids" => [parent.uuid, "not-a-category", 7, child.uuid]
      })

    assert tree_count(html2, child.uuid) == 1

    # A drop onto a parent says where the category went.
    html3 =
      render_click(view2, "move_to_folder", %{
        "type" => "category",
        "uuid" => loose.uuid,
        "target" => parent.uuid
      })

    assert html3 =~ "Category moved into Parent."
    assert_push_event(view2, "category_tree_open", %{uuids: _})

    html4 =
      render_click(view2, "drop_row", %{
        "type" => "category",
        "uuid" => loose.uuid,
        "parent" => "root",
        "entries" => ["category:#{loose.uuid}", "category:#{parent.uuid}"]
      })

    assert html4 =~ "Category moved to the top level."
  end

  test "a crafted search payload cannot crash the page (sweep 2026-09-13)", %{conn: conn} do
    catalogue = fixture_catalogue(%{name: "Search Junk"})
    {:ok, view, _} = live(conn, "#{@base}/#{catalogue.uuid}")
    render_click(view, "search", %{"query" => ["x"]})
    render_click(view, "search", %{"query" => %{"a" => 1}})
    assert Process.alive?(view.pid)
  end
end
