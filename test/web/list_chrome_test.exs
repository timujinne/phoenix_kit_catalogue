defmodule PhoenixKitCatalogue.Web.ListChromeTest do
  @moduledoc """
  The top of the list pages (boss via Max, 2026-10-05: too busy) and the
  tables' column fitting.

  Everything that tunes a list sits in one of two pop-ups — Filters beside
  the search (which rows), View options (how they are shown) — so these
  check the controls are still THERE, inside them, and nowhere loose.

  Column fitting hides a column by its position in the header row, so a
  body row with one cell more or fewer than the header would lose the wrong
  cell. Every fitted table is checked for that, in each shape it renders.
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  @base "/en/admin/catalogues"

  # `<.table_default fit>` first shipped in phoenix_kit 2.54.0. The module
  # passes it as a dynamic attribute (`Components.table_fit/0`), so an older
  # core just ignores it and the tables scroll as they always did. Row
  # alignment and tree layout still have to work there; only hook presence
  # is conditional on the core's support.
  @core_fit? :fit in Enum.map(
               PhoenixKitWeb.Components.Core.TableDefault.__components__()[:table_default].attrs,
               & &1.name
             )

  setup %{conn: conn, scope: scope} do
    catalogue = fixture_catalogue(%{name: "Chrome cat"})
    parent = fixture_category(catalogue, %{name: "Doors", position: 0})
    child = fixture_category(catalogue, %{name: "Oak doors", parent_uuid: parent.uuid})
    fixture_category(catalogue, %{name: "Oak panels", parent_uuid: child.uuid})
    fixture_item(%{catalogue_uuid: catalogue.uuid, category_uuid: parent.uuid, name: "Door A"})
    fixture_item(%{catalogue_uuid: catalogue.uuid, name: "Loose item"})

    %{conn: with_scope(conn, scope), catalogue: catalogue, parent: parent, child: child}
  end

  defp doc(html), do: LazyHTML.from_fragment(html)

  defp inside?(html, container, selector) do
    html |> doc() |> LazyHTML.query("#{container} #{selector}") |> Enum.count() > 0
  end

  defp count(html, selector), do: html |> doc() |> LazyHTML.query(selector) |> Enum.count()

  # [{wrapper_id, header_cell_count, [body_row_cell_count]}] for every fitted
  # table in the page. A cell with a colspan is skipped by the hook, so a row
  # holding one is not a row it has to line up.
  defp fitted_tables(html) do
    for wrapper <- html |> doc() |> LazyHTML.query(~s([phx-hook="TableFit"])) do
      [id] = LazyHTML.attribute(wrapper, "id")
      [{_, _, _} = tree] = LazyHTML.to_tree(wrapper)
      table = find(tree, "table")
      head = table |> find("thead") |> find("tr") |> cells()

      {id, length(head), body_row_sizes(table)}
    end
  end

  defp list_tables(html) do
    for {table, index} <- html |> doc() |> LazyHTML.query("table") |> Enum.with_index(1) do
      id = List.first(LazyHTML.attribute(table, "id")) || "table #{index}"
      [tree] = LazyHTML.to_tree(table)
      head = tree |> find("thead") |> find("tr") |> cells()
      {id, length(head), body_row_sizes(tree)}
    end
  end

  defp body_row_sizes(table) do
    for {"tbody", _, kids} <- children(table),
        {"tr", _, _} = tr <- kids,
        cs = cells(tr),
        not Enum.any?(cs, &spanning?/1),
        do: length(cs)
  end

  defp spanning?({_, attrs, _}), do: List.keymember?(attrs, "colspan", 0)

  # {{categories_by, dir}, {items_by, dir}} as the LiveView holds them.
  defp sorts(view) do
    a = :sys.get_state(view.pid).socket.assigns
    {{a.categories_sort_by, a.categories_sort_dir}, {a.items_sort_by, a.items_sort_dir}}
  end

  defp position(html, text), do: html |> :binary.match(text) |> elem(0)

  defp children({_, _, kids}), do: Enum.filter(kids, &is_tuple/1)
  defp find(node, tag), do: Enum.find(children(node), &(elem(&1, 0) == tag))
  defp cells(tr), do: Enum.filter(children(tr), &(elem(&1, 0) in ["td", "th"]))

  defp assert_rows_line_up(html, expected_ids) do
    tables = list_tables(html)
    assert tables != [], "no tables rendered — the row check would pass on nothing"

    if @core_fit? do
      fitted = fitted_tables(html)
      ids = Enum.map(fitted, &elem(&1, 0))
      assert fitted != []

      for id <- expected_ids,
          do: assert(id in ids, "no fitted table #{id}; found #{inspect(ids)}")
    end

    for {id, head, rows} <- tables do
      assert rows != [], "#{id} rendered no body rows — the check would pass on nothing"

      assert Enum.all?(rows, &(&1 == head)),
             "#{id}: header has #{head} cells, body rows have #{inspect(Enum.uniq(rows))}"
    end
  end

  describe "the index" do
    test "sort, Columns and the view switch live in View options, not on the row", %{conn: conn} do
      {:ok, _view, html} = live(conn, @base)

      assert inside?(html, "#catalogues-view-options", "#catalogues-sort-controls")
      assert inside?(html, "#catalogues-view-options", ~s(button[phx-click*="show_column_modal"]))
      assert inside?(html, "#catalogues-view-options", ~s(button[phx-click="set_view"]))

      # each exactly once: nothing left behind on the row, nothing doubled
      assert count(html, "#catalogues-sort-controls") == 1
      assert count(html, ~s(button[phx-click*="show_column_modal"])) == 1
      assert count(html, ~s(button[phx-click="set_view"])) == 3
    end

    # The pop-up is opened and closed on the client, so a control in it that
    # opens a dialog has to close it too — or it is still there, backdrop
    # and all, when the dialog shuts.
    test "Columns closes the pop-up it sits in", %{conn: conn} do
      {:ok, _view, html} = live(conn, @base)

      [click] =
        html
        |> doc()
        |> LazyHTML.query(~s(#catalogues-view-options button[phx-click*="show_column_modal"]))
        |> LazyHTML.attribute("phx-click")

      assert click =~ ~s("hide")
      assert click =~ "#catalogues-view-options"
    end

    test "the status filter lives in Filters, beside the search", %{conn: conn} do
      {:ok, _view, html} = live(conn, @base)

      assert inside?(html, "#catalogues-filters", "#filter-form-status")
      assert count(html, "#filter-form-status") == 1
      refute inside?(html, "#catalogues-view-options", "#filter-form-status")
    end

    test "the Filters button counts a filter that is on", %{conn: conn} do
      {:ok, view, html} = live(conn, @base)

      refute html |> doc() |> LazyHTML.query(~s(button[title="Filters"] .badge)) |> Enum.any?()

      html =
        view
        |> form("#filter-form-status", %{"column_id" => "status", "value" => "active"})
        |> render_change()

      assert [badge] =
               html
               |> doc()
               |> LazyHTML.query(~s(button[title="Filters"] .badge))
               |> Enum.to_list()

      assert LazyHTML.text(badge) =~ "1"
    end

    for mode <- ~w(table comfy) do
      test "every row lines up with the header in #{mode} view", %{conn: conn} do
        {:ok, view, _html} = live(conn, @base)
        html = render_click(view, "set_view", %{"mode" => unquote(mode)})

        assert_rows_line_up(html, [])
      end
    end
  end

  describe "inside a catalogue" do
    test "the list controls live in View options, up with the create buttons", %{
      conn: conn,
      catalogue: catalogue
    } do
      {:ok, _view, html} = live(conn, "#{@base}/#{catalogue.uuid}")

      assert inside?(html, "#detail-view-options", "#categories-sort-selector")
      assert inside?(html, "#detail-view-options", ~s(button[phx-click*="show_column_modal"]))
      assert count(html, "#categories-sort-selector") == 1
      assert count(html, "#detail-view-options") == 1
    end

    # No row is kept on the page just to hold a button: without status tabs,
    # a picture or a description there is nothing between the toolbar and
    # the tables.
    test "the caption row exists only when it has something to say", %{
      conn: conn,
      catalogue: catalogue
    } do
      {:ok, _view, html} = live(conn, "#{@base}/#{catalogue.uuid}")
      assert count(html, "#detail-level-caption") == 0

      described = fixture_catalogue(%{name: "Described", description: "Pipes and fittings."})
      fixture_category(described, %{name: "Any"})

      {:ok, _view, html} = live(conn, "#{@base}/#{described.uuid}")
      assert inside?(html, "#detail-level-caption", "p")
      assert html =~ "Pipes and fittings."
    end

    # The bar docks under its list, so ticking a row moves nothing above it.
    test "a selection's action bar sits after the table, not before it", %{
      conn: conn,
      catalogue: catalogue
    } do
      {:ok, _view, html} = live(conn, "#{@base}/#{catalogue.uuid}")

      [bar] =
        html
        |> doc()
        |> LazyHTML.query(~s(#categories-bulk > [data-bulk-show="has-selection"]))
        |> LazyHTML.attribute("class")

      assert bar =~ "order-last"
      assert bar =~ "sticky"
      refute html =~ ~s(data-bulk-swap)
    end

    # A level with subcategories and items has two lists and ONE sort for
    # both. The items' own used to sit in a bar between the two tables.
    test "a level with both lists has one sort, in View options, for both", %{
      conn: conn,
      catalogue: catalogue,
      parent: parent
    } do
      fixture_item(%{catalogue_uuid: catalogue.uuid, category_uuid: parent.uuid, name: "Door B"})
      {:ok, view, html} = live(conn, "#{@base}/#{catalogue.uuid}?category=#{parent.uuid}")

      assert inside?(html, "#detail-view-options", "#level-sort-selector")
      assert count(html, "#categories-sort-selector") == 0
      assert count(html, "#items-header-sort-selector") == 0

      # the items' action bar is the docked one, hidden until a row is ticked
      [bar] =
        html
        |> doc()
        |> LazyHTML.query(~s(#items-bulk > [data-bulk-show="has-selection"]))
        |> LazyHTML.attribute("class")

      assert bar =~ "order-last"

      # a field both lists have sorts both
      render_hook(view, "sort_level", %{"sort_by" => "name"})
      html = render_hook(view, "sort_level", %{"sort_dir" => "desc"})
      assert sorts(view) == {{:name, :desc}, {:name, :desc}}
      assert position(html, "Door B") < position(html, "Door A")

      # a field only the items have: the categories stand on Name
      render_hook(view, "sort_level", %{"sort_by" => "sku"})
      assert {{:name, _}, {:sku, _}} = sorts(view)

      # Manual order is manual for both
      render_hook(view, "sort_level", %{"sort_by" => "position"})
      assert {{:position, _}, {:position, _}} = sorts(view)

      # an unknown field changes nothing
      render_hook(view, "sort_level", %{"sort_by" => "inserted_at; drop"})
      assert {{:position, _}, {:position, _}} = sorts(view)
    end

    test "the shared sort: a categories-only field, a split made by a header, and what is stored",
         %{
           conn: conn,
           catalogue: catalogue,
           parent: parent
         } do
      {:ok, view, _html} = live(conn, "#{@base}/#{catalogue.uuid}?category=#{parent.uuid}")

      # a field only the categories have: the items stand on Name
      render_hook(view, "sort_level", %{"sort_by" => "items"})
      assert {{:items, :asc}, {:name, :asc}} = sorts(view)

      # a column header sorts its own table and leaves the other alone …
      render_hook(view, "toggle_sort_items", %{"by" => "sku"})
      assert {{:items, _}, {:sku, _}} = sorts(view)

      # … and the arrow then turns BOTH round without moving either off its field
      render_hook(view, "sort_level", %{"sort_dir" => "desc"})
      assert sorts(view) == {{:items, :desc}, {:sku, :desc}}

      # both lists' sorts are the shared, stored ones: a fresh page opens on them
      render_hook(view, "sort_level", %{"sort_by" => "name"})
      {:ok, fresh, _html} = live(conn, "#{@base}/#{catalogue.uuid}?category=#{parent.uuid}")
      assert sorts(fresh) == {{:name, :desc}, {:name, :desc}}
    end

    test "the search refinements live in Filters", %{
      conn: conn,
      catalogue: catalogue,
      parent: parent
    } do
      {:ok, _view, html} = live(conn, "#{@base}/#{catalogue.uuid}?category=#{parent.uuid}")

      assert inside?(html, "#catalogue-level-filters", ~s(input[phx-click="toggle_items_scope"]))
      assert count(html, ~s(input[phx-click="toggle_items_scope"])) == 1
    end

    test "an opened subcategory is set in: rail in the photo column, elbow and picture in the name cell",
         %{conn: conn, catalogue: catalogue, parent: parent, child: child} do
      {:ok, view, _html} = live(conn, "#{@base}/#{catalogue.uuid}")
      html = render_click(view, "toggle_category_expand", %{"uuid" => parent.uuid})

      top = html |> doc() |> LazyHTML.query("#category-tree-row-#{parent.uuid}")
      sub = html |> doc() |> LazyHTML.query("#category-tree-row-#{child.uuid}")

      assert Enum.count(sub) == 1
      assert sub |> LazyHTML.query(".hero-arrow-turn-down-right") |> Enum.count() == 1
      assert top |> LazyHTML.query(".hero-arrow-turn-down-right") |> Enum.count() == 0
    end

    # The Image column takes the photo column's place, and with it the cell
    # that draws the first level's rail — the name cell then has to draw every
    # level itself, or a first-level subcategory is not set in at all.
    test "a subcategory is still set in when the Image column replaces the photo column", %{
      conn: conn,
      catalogue: catalogue,
      parent: parent,
      child: child
    } do
      {:ok, view, _html} = live(conn, "#{@base}/#{catalogue.uuid}")

      render_click(view, "add_column", %{"column_id" => "image", "section" => "detail_categories"})

      html = render_click(view, "toggle_category_expand", %{"uuid" => parent.uuid})

      # the photo column is gone: no rail cell before the name
      refute html =~ "left-[1.9375rem]"

      sub = html |> doc() |> LazyHTML.query("#category-tree-row-#{child.uuid}")
      name_cell = sub |> LazyHTML.query("td.relative") |> LazyHTML.to_html()

      assert name_cell =~ "border-l-2"
      assert name_cell =~ "padding-left"
      assert_rows_line_up(html, ["catalogue-categories-tree-table-fit"])
    end

    test "every row lines up with the header: tree with an opened branch, and the items table", %{
      conn: conn,
      catalogue: catalogue,
      parent: parent,
      child: child
    } do
      {:ok, view, _html} = live(conn, "#{@base}/#{catalogue.uuid}")
      render_click(view, "toggle_category_expand", %{"uuid" => parent.uuid})
      html = render_click(view, "toggle_category_expand", %{"uuid" => child.uuid})

      assert_rows_line_up(html, ["catalogue-categories-tree-table-fit"])

      {:ok, _view, html} = live(conn, "#{@base}/#{catalogue.uuid}?category=#{parent.uuid}")
      assert_rows_line_up(html, ["level-items-active-fit"])
    end
  end
end
