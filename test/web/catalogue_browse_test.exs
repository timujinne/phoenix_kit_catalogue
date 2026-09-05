defmodule PhoenixKitCatalogue.Web.Components.CatalogueBrowseTest do
  @moduledoc """
  The embeddable browse surface, driven through the same test host as the
  picker — same scope rules, no selection chrome, one generic message.
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Web.ViewConfig

  setup do
    cat = fixture_catalogue(%{name: "Browse Cat"})
    other = fixture_catalogue(%{name: "Other Cat"})
    {:ok, item} = Catalogue.create_item(%{name: "Widget", sku: "W-1", catalogue_uuid: cat.uuid})
    {:ok, _} = Catalogue.create_item(%{name: "Elsewhere", catalogue_uuid: other.uuid})
    %{cat: cat, item: item}
  end

  test "renders the scoped grid with no picker chrome", %{conn: conn, cat: cat} do
    {:ok, view, html} = live(conn, "/test/selector-host?browse=true&c=#{cat.uuid}")

    assert html =~ "Widget"
    refute html =~ "Elsewhere"
    # No tray, no confirm — browse only.
    refute html =~ "Confirm selection"

    # phx-submit routes Enter to a re-search — without it LiveView treats
    # a phx-change-only form as external and Enter runs a NATIVE submit,
    # navigating the page away.
    assert has_element?(view, ~s(#surface-search-form[phx-submit="browse_search"]))

    assert view |> element("#surface-search-form") |> render_submit(%{"search" => "Widget"}) =~
             "Widget"
  end

  test "listings follow the module's shared item sort", %{conn: conn, cat: cat} do
    # Client, 2026-09-01: one order everywhere — this embed reads the same
    # catalogue_sort_detail_items setting the admin and the picker do.
    {:ok, _} = Catalogue.create_item(%{name: "Anvil", catalogue_uuid: cat.uuid})

    {:ok, _} =
      ViewConfig.save_global_sort(:detail_items, "name", :desc)

    {:ok, _view, html} = live(conn, "/test/selector-host?browse=true&c=#{cat.uuid}")
    {widget, _} = :binary.match(html, "Widget")
    {anvil, _} = :binary.match(html, "Anvil")
    assert widget < anvil

    {:ok, _} =
      ViewConfig.save_global_sort(:detail_items, "position", :asc)
  end

  test "item click reports the generic message to the host", %{
    conn: conn,
    cat: cat,
    item: item
  } do
    {:ok, view, _html} = live(conn, "/test/selector-host?browse=true&c=#{cat.uuid}")

    view |> element("#surface-card-#{item.uuid} > button") |> render_click()
    html = render(view)

    assert html =~ ~s(id="clicked")
    assert html =~ "Widget|W-1"
  end

  test "search narrows the surface", %{conn: conn, cat: cat} do
    {:ok, view, _html} = live(conn, "/test/selector-host?browse=true&c=#{cat.uuid}")

    html =
      view
      |> with_target("#surface")
      |> render_change("browse_search", %{"search" => "zzz-no-match"})

    refute html =~ "Widget"
    assert html =~ "No items match your search."
  end

  test "a crafted payload with missing keys is a no-op, not a crash", %{
    conn: conn,
    cat: cat
  } do
    {:ok, view, _html} = live(conn, "/test/selector-host?browse=true&c=#{cat.uuid}")

    html =
      view
      |> with_target("#surface")
      |> render_click("nonsense_event", %{})

    assert html =~ "Widget"
  end

  # 2026-08-31 regression pin (PR #88 review): the table's default-hidden
  # pair (:sku, :breadcrumb) is VISIBILITY, not a grant. Subtracting it
  # from the grant instead also stripped the SKU line the cards had shown
  # since this component shipped — and no host could get it back, since
  # `show_sku: true` was already the default and only an explicit
  # `columns` list (which also re-adds the table column) would restore it.
  test "the default card view keeps its SKU line; the table starts without the column", %{
    conn: conn,
    cat: cat
  } do
    {:ok, view, html} = live(conn, "/test/selector-host?browse=true&c=#{cat.uuid}")

    assert html =~ "W-1"

    html = view |> with_target("#surface") |> render_click("set_view", %{"mode" => "table"})

    assert html =~ "Widget"
    refute html =~ "W-1"
  end

  # 2026-08-30: the widget gained the modal's list view. Card grid stays
  # the default so existing embeds render unchanged.
  test "the view toggle switches to the admin-look table and back", %{
    conn: conn,
    cat: cat,
    item: item
  } do
    {:ok, view, html} = live(conn, "/test/selector-host?browse=true&c=#{cat.uuid}")

    # Default: grid, no table.
    assert html =~ ~s(id="surface-grid")
    refute html =~ ~s(id="surface-table")

    html = view |> with_target("#surface") |> render_click("set_view", %{"mode" => "table"})
    assert html =~ ~s(id="surface-table")
    assert html =~ "Widget"
    # No selection chrome in the table: no checkbox column, no qty cell.
    refute html =~ "input type=\"checkbox\""
    refute html =~ "qty_commit"

    # Rows report the same generic message cards do.
    view |> element("#surface-row-#{item.uuid} td", "Widget") |> render_click()
    assert render(view) =~ ~s(id="clicked")

    html = view |> with_target("#surface") |> render_click("set_view", %{"mode" => "card"})
    assert html =~ ~s(id="surface-grid")
  end

  # 2026-08-31 sweep pins.
  test "a decorative embed (on_item_click false, the default) sends nothing", %{
    conn: conn,
    cat: cat,
    item: item
  } do
    {:ok, view, html} = live(conn, "/test/selector-host?browse=true&bclick=false&c=#{cat.uuid}")

    # Cards render inert — and a crafted click is refused server-side,
    # or a host with no handle_info clause would crash.
    refute html =~ ~s(phx-click="card_click")
    view |> with_target("#surface") |> render_click("card_click", %{"uuid" => item.uuid})
    refute render(view) =~ ~s(id="clicked")
  end

  test "a crafted click for an item this surface never rendered is refused", %{
    conn: conn,
    cat: cat
  } do
    other = fixture_catalogue(%{name: "Elsewhere Cat"})
    {:ok, foreign} = Catalogue.create_item(%{name: "Foreign", catalogue_uuid: other.uuid})

    {:ok, view, _html} = live(conn, "/test/selector-host?browse=true&c=#{cat.uuid}")

    view
    |> with_target("#surface")
    |> render_click("card_click", %{"uuid" => to_string(foreign.uuid)})

    refute render(view) =~ ~s(id="clicked")
  end

  # The subtree-expansion fix from the 2026-08-25 quorum review reached
  # only the modal; the widget compared literally and hid descendant
  # chips. Shared via Browse.expand_scope/1 (2026-08-30).
  test "a parent-category scope shows and accepts descendant chips", %{conn: conn, cat: cat} do
    parent = fixture_category(cat, %{name: "Parent Cat"})
    child = fixture_category(cat, %{name: "Child Cat", parent_uuid: parent.uuid})

    {:ok, _nested} =
      Catalogue.create_item(%{
        name: "Nested Item",
        catalogue_uuid: cat.uuid,
        category_uuid: child.uuid
      })

    {:ok, view, html} =
      live(conn, "/test/selector-host?browse=true&c=#{cat.uuid}&cat_scope=#{parent.uuid}")

    assert html =~ "Child Cat"
    assert html =~ "Nested Item"

    html =
      view
      |> with_target("#surface")
      |> render_click("browse_category", %{"uuid" => child.uuid})

    assert html =~ "Nested Item"
  end
end
