defmodule PhoenixKitCatalogue.Web.TreeSortTest do
  @moduledoc """
  Sorting a list must never take its structure away (boss via Max,
  2026-09-21: "switch the sort and sometimes it's just a flat list, or you
  can't even open the subcategories").

  It used to: any sort but Manual order swapped the category tree for a flat
  table of one level, whose "2 subcategories" badge looked like the tree's
  toggle and did nothing; the index dropped its folders the same way; and
  card view ignored the sort altogether. And the sort is one shared setting
  pushed live, so one person's "Name" flattened everyone's tree — the
  "sometimes".

  Each test drives the real sort control and reads the rendered page.
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Web.TableConfig
  alias PhoenixKitCatalogue.Web.ViewConfig

  @base "/en/admin/catalogue"

  setup %{conn: conn, scope: scope} do
    # The sorts are module-wide settings: put every one back.
    before =
      for s <- [:catalogues, :detail_categories],
          into: %{},
          do: {s, ViewConfig.load_global_sort(s)}

    on_exit(fn ->
      for {s, {by, dir}} <- before, do: ViewConfig.save_global_sort(s, by, dir)
    end)

    catalogue = fixture_catalogue(%{name: "Sorted tree"})

    # Manual order and name order disagree on purpose: B, A at the top level,
    # Z, Y inside B.
    b = fixture_category(catalogue, %{name: "B doors", position: 0})
    a = fixture_category(catalogue, %{name: "A handles", position: 1})
    z = fixture_category(catalogue, %{name: "Z glass", parent_uuid: b.uuid, position: 0})
    y = fixture_category(catalogue, %{name: "Y oak", parent_uuid: b.uuid, position: 1})

    %{conn: with_scope(conn, scope), catalogue: catalogue, a: a, b: b, y: y, z: z}
  end

  defp sort_categories(view, by) do
    view
    |> element("#categories-sort-selector")
    |> render_change(%{"sort_by" => by})
  end

  defp tree_names(html) do
    html
    |> LazyHTML.from_fragment()
    # The name link only — the preview cell links to the same place, and it
    # now always renders (its text is the letter tile).
    |> LazyHTML.query(~s([id^="category-tree-row-"] a.link[href*="category="]))
    |> Enum.map(&LazyHTML.text/1)
    |> Enum.map(&String.trim/1)
  end

  describe "a catalogue's categories" do
    test "a sort keeps the tree, and a parent still opens", %{conn: conn, catalogue: c, b: b} do
      {:ok, view, _html} = live(conn, "#{@base}/#{c.uuid}")
      sort_categories(view, "name")

      assert has_element?(view, "#catalogue-categories-tree")

      html =
        view
        |> element(~s(#category-tree-row-#{b.uuid} button[phx-click="toggle_category_expand"]))
        |> render_click()

      assert html =~ "Y oak"
      assert html =~ "Z glass"
    end

    test "each level is ordered by the sort, children under their parent", %{
      conn: conn,
      catalogue: c,
      b: b
    } do
      {:ok, view, _html} = live(conn, "#{@base}/#{c.uuid}")
      render_click(view, "toggle_category_expand", %{"uuid" => b.uuid})

      # Manual order: B then A, B's children Z then Y.
      assert tree_names(render(view)) == ["B doors", "Z glass", "Y oak", "A handles"]

      # By name: A then B at the top, Y then Z inside B — still nested.
      assert tree_names(sort_categories(view, "name")) ==
               ["A handles", "B doors", "Y oak", "Z glass"]
    end

    test "the open branches survive a sort change", %{conn: conn, catalogue: c, b: b} do
      # Read from the TREE only: the card view renders every nested box into
      # the same page, so "the name is somewhere in the HTML" proves nothing.
      {:ok, view, _html} = live(conn, "#{@base}/#{c.uuid}")
      render_click(view, "toggle_category_expand", %{"uuid" => b.uuid})

      assert "Z glass" in tree_names(sort_categories(view, "name"))
      assert "Z glass" in tree_names(sort_categories(view, "position"))
    end

    test "dragging is offered only in Manual order", %{conn: conn, catalogue: c, b: b} do
      {:ok, view, _html} = live(conn, "#{@base}/#{c.uuid}")
      assert has_element?(view, ~s(#category-tree-row-#{b.uuid} [data-tree-item]))

      sort_categories(view, "name")
      # The row is still there — only its handle has gone.
      assert has_element?(view, "#category-tree-row-#{b.uuid}")
      refute has_element?(view, ~s(#category-tree-row-#{b.uuid} [data-tree-item]))
    end

    test "an edge drop pushed under a sort writes no order", %{
      conn: conn,
      catalogue: c,
      a: a,
      b: b
    } do
      # The handle is gone, but a hook push can still arrive (a drag begun
      # before someone changed the shared sort, a stale page, a forged
      # event). An EDGE drop writes sibling order, which the sort would
      # hide — refused.
      {:ok, view, _html} = live(conn, "#{@base}/#{c.uuid}")
      sort_categories(view, "name")

      before = Catalogue.get_category(a.uuid).position

      render_click(view, "drop_row", %{
        "type" => "category",
        "uuid" => a.uuid,
        "parent" => "root",
        "entries" => ["category:#{a.uuid}", "category:#{b.uuid}"]
      })

      assert Catalogue.get_category(a.uuid).position == before
    end

    test "a nest dropped under a sort still nests, as the index files a catalogue", %{
      conn: conn,
      catalogue: c,
      a: a,
      b: b
    } do
      {:ok, view, _html} = live(conn, "#{@base}/#{c.uuid}")
      sort_categories(view, "name")

      render_click(view, "move_to_folder", %{
        "type" => "category",
        "uuid" => a.uuid,
        "target" => b.uuid
      })

      assert Catalogue.get_category(a.uuid).parent_uuid == b.uuid
    end

    test "the bulk Reorder is offered only in Manual order", %{conn: conn, catalogue: c} do
      hidden = ~s(#categories-bulk [class*="data-bulk-action*=reorder"])

      {:ok, view, _html} = live(conn, "#{@base}/#{c.uuid}")
      refute has_element?(view, hidden)

      sort_categories(view, "name")
      assert has_element?(view, hidden)
    end

    for by <- ~w(position name items updated), dir <- ~w(asc desc) do
      test "the tree renders, nested and openable, sorted by #{by} #{dir}", %{
        conn: conn,
        catalogue: c,
        b: b
      } do
        {:ok, view, _html} = live(conn, "#{@base}/#{c.uuid}")
        render_click(view, "toggle_category_expand", %{"uuid" => b.uuid})

        view
        |> element("#categories-sort-selector")
        |> render_change(%{"sort_by" => unquote(by), "sort_dir" => unquote(dir)})

        names = tree_names(render(view))
        assert Enum.sort(names) == ["A handles", "B doors", "Y oak", "Z glass"]

        # Children always directly under their parent, whatever the order.
        b_at = Enum.find_index(names, &(&1 == "B doors"))
        assert Enum.slice(names, b_at + 1, 2) |> Enum.sort() == ["Y oak", "Z glass"]
      end
    end

    # Nested levels sort by their OWN counts. The crossed test above runs on
    # empty categories, where every count is 0 and :items is indistinguishable
    # from input order — so this one puts items two levels down.
    test "Items orders a nested level by that level's counts", %{
      conn: conn,
      catalogue: c,
      b: b,
      y: y
    } do
      for n <- 1..2,
          do: fixture_item(%{catalogue_uuid: c.uuid, category_uuid: y.uuid, name: "Oak #{n}"})

      {:ok, view, _html} = live(conn, "#{@base}/#{c.uuid}")
      render_click(view, "toggle_category_expand", %{"uuid" => b.uuid})

      # Manual order puts Z before Y inside B; Items desc must put Y (2) first.
      assert tree_names(render(view)) |> Enum.slice(1, 2) == ["Z glass", "Y oak"]

      names =
        view
        |> element("#categories-sort-selector")
        |> render_change(%{"sort_by" => "items", "sort_dir" => "desc"})
        |> tree_names()

      b_at = Enum.find_index(names, &(&1 == "B doors"))
      assert Enum.slice(names, b_at + 1, 2) == ["Y oak", "Z glass"]
    end

    test "card view follows the sort too", %{conn: conn, catalogue: c} do
      {:ok, view, _html} = live(conn, "#{@base}/#{c.uuid}")
      html = sort_categories(view, "name")

      cards =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[data-card-view]")
        |> LazyHTML.text()

      {a_at, _} = :binary.match(cards, "A handles")
      {b_at, _} = :binary.match(cards, "B doors")
      assert a_at < b_at, "card view ignored the sort"
    end

    test "a sort pushed live from another page keeps the tree here", %{
      conn: conn,
      catalogue: c,
      b: b
    } do
      {:ok, view, _html} = live(conn, "#{@base}/#{c.uuid}")
      render_click(view, "toggle_category_expand", %{"uuid" => b.uuid})

      send(view.pid, {:catalogue_view_sort_changed, :detail_categories, "name", :asc, self()})

      html = render(view)
      assert has_element?(view, "#catalogue-categories-tree")
      assert tree_names(html) == ["A handles", "B doors", "Y oak", "Z glass"]
    end
  end

  describe "the catalogues index" do
    setup %{catalogue: catalogue} do
      {:ok, folder} = Catalogue.create_folder(%{name: "Showroom folder"})

      {:ok, filed} =
        Catalogue.update_catalogue(
          fixture_catalogue(%{name: "Inside the folder"}),
          %{folder_uuid: folder.uuid}
        )

      %{folder: folder, filed: filed, loose: catalogue}
    end

    test "a sort keeps the folders", %{conn: conn, folder: folder} do
      {:ok, view, _html} = live(conn, @base)

      html = render_change(view, "set_sort", %{"sort_by" => "name"})

      assert html =~ "Showroom folder"
      assert has_element?(view, ~s([data-tree-uuid="#{folder.uuid}"]))
    end

    test "a folder still opens and closes under a sort", %{conn: conn, folder: folder} do
      {:ok, view, _html} = live(conn, @base)
      render_change(view, "set_sort", %{"sort_by" => "name"})

      # Asked of the folder's own children, not the page text: the old flat
      # list showed every catalogue anyway, so "the name is on the page"
      # could never fail.
      child = ~s([data-tree-type="catalogue"][data-tree-parent="#{folder.uuid}"])

      opened? = has_element?(view, child)
      render_click(view, "toggle_folder_expand", %{"uuid" => folder.uuid})
      assert has_element?(view, child) != opened?, "the folder did not toggle"
      render_click(view, "toggle_folder_expand", %{"uuid" => folder.uuid})
      assert has_element?(view, child) == opened?
    end

    test "folders come first under a sort, the tree loses its drag handles", %{
      conn: conn,
      folder: folder
    } do
      {:ok, view, _html} = live(conn, @base)
      assert has_element?(view, ~s([data-tree-item="folder:#{folder.uuid}"]))

      html = render_change(view, "set_sort", %{"sort_by" => "name"})

      # The folder row is still there, but nothing can be dragged.
      assert has_element?(view, ~s([data-tree-uuid="#{folder.uuid}"]))
      refute has_element?(view, "[data-tree-item]")

      {folder_at, _} = :binary.match(html, "Showroom folder")
      {loose_at, _} = :binary.match(html, "Sorted tree")
      assert folder_at < loose_at, "folders come before catalogues under a sort"
    end

    test "a drop pushed under a sort writes nothing", %{conn: conn, folder: folder, loose: loose} do
      {:ok, view, _html} = live(conn, @base)
      render_change(view, "set_sort", %{"sort_by" => "name"})

      render_click(view, "drop_row", %{
        "type" => "catalogue",
        "uuid" => loose.uuid,
        "parent" => folder.uuid,
        "entries" => ["catalogue:#{loose.uuid}"]
      })

      assert Catalogue.get_catalogue(loose.uuid).folder_uuid == nil
    end

    # Crossed, not sampled: a folder has only some of a catalogue's columns,
    # and the folder half of each level goes through the same sort. Every
    # sortable column, both directions, must render the tree with the folder
    # in it — a sort key that reads a field a folder lacks would crash here.
    for {id, _} <-
          TableConfig.columns(:catalogues)
          |> Enum.filter(& &1.sortable?)
          |> Enum.map(&{&1.id, &1}),
        dir <- ~w(asc desc) do
      test "the folder tree renders sorted by #{id} #{dir}", %{conn: conn, folder: folder} do
        {:ok, view, _html} = live(conn, @base)
        render_change(view, "set_sort", %{"sort_by" => unquote(id)})

        if unquote(dir) == "desc" do
          render_change(view, "set_sort", %{"sort_dir" => "desc"})
        end

        assert has_element?(view, ~s([data-tree-uuid="#{folder.uuid}"]))
      end
    end

    test "a search still lists every match flat", %{conn: conn} do
      {:ok, view, _html} = live(conn, @base)
      html = render_change(view, "table_search", %{"query" => "Inside"})
      assert html =~ "Inside the folder"
    end
  end
end
