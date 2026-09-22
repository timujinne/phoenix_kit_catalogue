defmodule PhoenixKitCatalogue.Web.TableColumnsTest do
  @moduledoc """
  The column editor and the table shape it drives (boss, 2026-09-19):

    * hiding every optional column must leave the table with Name alone,
      not snap back to the defaults;
    * no row may carry a cell the header lacks — the Uncategorized row
      once did, whenever the columns list held an id the header skips
      (the defaults' unmanaged "name"), and the table then drew its
      header past every other row's right edge;
    * Name is the one column that grows, so the rest pack to the right,
      and the ⋮ column carries no visible label.
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Web.Components
  alias PhoenixKitCatalogue.Web.TableConfig

  @base "/en/admin/catalogue"

  setup %{conn: conn, scope: scope} do
    catalogue = fixture_catalogue(%{name: "Columns cat"})
    fixture_category(catalogue, %{name: "A chapter", position: 0})
    fixture_category(catalogue, %{name: "B chapter", position: 1})
    # A loose item puts the Uncategorized row in the category table.
    fixture_item(%{name: "Loose item", catalogue_uuid: catalogue.uuid})

    %{conn: with_scope(conn, scope), catalogue: catalogue}
  end

  # {header cells, [cells per body row]} for the table whose markup
  # contains `marker` (the classic table branch renders no id of its own).
  defp shape(html, marker) do
    table =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("table")
      |> Enum.find(&(LazyHTML.to_html(&1) =~ marker))

    assert table, "no table containing #{inspect(marker)}"

    heads = table |> LazyHTML.query("thead th") |> Enum.count()

    rows =
      table
      |> LazyHTML.query("tbody tr")
      |> Enum.map(&(&1 |> LazyHTML.query("td") |> Enum.count()))

    {heads, rows}
  end

  defp assert_rectangular(html, marker) do
    {heads, rows} = shape(html, marker)
    # Two chapters plus the Uncategorized row.
    assert length(rows) == 3

    assert Enum.all?(rows, &(&1 == heads)),
           "header has #{heads} cells, rows have #{inspect(rows)}"
  end

  @column_sets [
    [],
    ["status"],
    ["description", "items"],
    ["created", "image", "subcategories"],
    ~w(items subcategories description files status updated created image)
  ]

  describe "every row is exactly as wide as the header" do
    test "the tree table, on the defaults and on every edited set", %{
      conn: conn,
      catalogue: catalogue
    } do
      {:ok, view, html} = live(conn, "#{@base}/#{catalogue.uuid}")

      # The boss's screenshot: the untouched defaults.
      assert_rectangular(html, "category-menu-uncategorized-tree")

      for ids <- @column_sets do
        html =
          render_click(view, "reorder_columns_detail_categories", %{"ordered_ids" => ids})

        assert_rectangular(html, "category-menu-uncategorized-tree")
      end
    end

    # A sort no longer swaps in a flat table (boss via Max, 2026-09-21) — it
    # keeps the tree and takes the drag handles away. The handle's CELL has
    # to stay, or every row under a sort is one cell short of its header.
    test "the tree table under a sort, with its drag handles gone", %{
      conn: conn,
      catalogue: catalogue
    } do
      {:ok, view, _html} = live(conn, "#{@base}/#{catalogue.uuid}")
      html = render_click(view, "sort_categories", %{"sort_by" => "name"})

      refute html =~ "data-tree-item"
      assert_rectangular(html, "category-menu-uncategorized-tree")

      for ids <- @column_sets do
        html =
          render_click(view, "reorder_columns_detail_categories", %{"ordered_ids" => ids})

        assert_rectangular(html, "category-menu-uncategorized-tree")
      end
    end

    test "an id no table draws adds no cell anywhere" do
      assert Components.category_cell_ids(["name", "items", "bogus", "status"]) ==
               ["items", "status"]

      ext = %{"shop:flag" => %{label: fn -> "Flag" end, render: fn _ -> "" end}}

      assert Components.category_cell_ids(["shop:flag", "shop:gone"], ext) == ["shop:flag"]
    end
  end

  describe "hiding every optional column" do
    test "leaves Name on the detail page, and it survives a reload", %{
      conn: conn,
      catalogue: catalogue
    } do
      {:ok, view, _html} = live(conn, "#{@base}/#{catalogue.uuid}")
      render_click(view, "show_column_modal", %{})

      html =
        Enum.reduce(TableConfig.default_columns(:detail_categories), nil, fn id, _ ->
          render_click(view, "remove_column", %{
            "column_id" => id,
            "scope" => "detail_categories"
          })
        end)

      assert :sys.get_state(view.pid).socket.assigns.categories_columns == []
      assert html =~ "A chapter"
      assert_rectangular(html, "category-menu-uncategorized-tree")

      {:ok, again, _html} = live(conn, "#{@base}/#{catalogue.uuid}")
      assert :sys.get_state(again.pid).socket.assigns.categories_columns == []

      # Reset is still how you get the defaults back.
      render_click(again, "reset_columns", %{})

      assert :sys.get_state(again.pid).socket.assigns.categories_columns ==
               TableConfig.default_columns(:detail_categories)
    end

    test "leaves Name on the index too, keeping the sort", %{conn: conn} do
      {:ok, view, _html} = live(conn, @base)

      for id <- TableConfig.default_columns(:catalogues) do
        render_click(view, "remove_column", %{"column_id" => id})
      end

      cfg = :sys.get_state(view.pid).socket.assigns.view_configs.catalogues
      assert cfg.columns == []
      assert cfg.sort_by == elem(TableConfig.default_sort(:catalogues), 0)
      assert render(view) =~ "Columns cat"

      {:ok, again, _html} = live(conn, @base)
      assert :sys.get_state(again.pid).socket.assigns.view_configs.catalogues.columns == []
    end
  end

  describe "column widths" do
    test "Name is the only auto column; the rest are fixed, the ⋮ one unlabelled", %{
      conn: conn,
      catalogue: catalogue
    } do
      {:ok, view, _html} = live(conn, "#{@base}/#{catalogue.uuid}")

      html =
        render_click(view, "reorder_columns_detail_categories", %{
          "ordered_ids" => ~w(items description status updated)
        })

      heads =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#catalogue-categories-tree thead th")
        |> Enum.map(fn th ->
          {th |> LazyHTML.attribute("class") |> List.first(""),
           th |> LazyHTML.text() |> String.trim()}
        end)

      # Leading drag + checkbox columns (w-8) and the preview column (w-12,
      # always there since 2026-09-21) are fixed; every header after Name
      # must be too, or it shares the spare width with Name.
      {before, [{name_classes, "Name"} | rest]} =
        Enum.split_while(heads, fn {_c, text} -> text != "Name" end)

      refute name_classes =~ ~r/\bw-/
      assert Enum.all?(before, fn {c, _} -> c =~ ~r/\bw-(8|12)\b/ end)
      assert Enum.any?(before, fn {c, _} -> c =~ ~r/\bw-12\b/ end), "the preview column is there"

      assert Enum.map(rest, &elem(&1, 1)) == [
               "Items",
               "Description",
               "Status",
               "Updated",
               "Actions"
             ]

      assert Enum.all?(rest, fn {c, _} -> c =~ "w-px" end), inspect(rest)

      # The menu column's word is for screen readers only.
      assert html =~ ~s(<span class="sr-only">Actions</span>)
    end

    test "only Name grows; prose wraps, everything else holds one line" do
      assert Components.column_fit_class("name") == nil
      assert Components.column_fit_class(:name) == nil
      assert Components.column_fit_class("description") == "w-px"
      assert Components.column_fit_class("attributes") == "w-px"

      for id <- ~w(sku price supplier_price unit status items subcategories files updated created) do
        assert Components.column_fit_class(id) == "w-px whitespace-nowrap", id
      end
    end
  end
end
