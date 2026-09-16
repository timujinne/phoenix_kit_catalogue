defmodule PhoenixKitCatalogue.Web.Components.ItemSelectorModalComfyTest do
  @moduledoc """
  Render-shape tests for the third `view_toggle` mode ("comfy") — no
  LiveCase, no Postgres. `item_selector_modal_test.exs` is a full
  `LiveCase` (Postgres) suite excluded whenever the test DB is
  unreachable, and its `initialize/2` mount path always fetches from
  `Catalogue` (`BrowseState.command(state, :reset)` has no `:noop`
  branch — see `browse_state.ex`), so the mode cannot be proven that
  way here. What follows instead is the pattern `browse_components_test.exs`
  and `item_picker_test.exs` already use: `Phoenix.LiveViewTest.render_component/2`
  against bare functions, no Repo involved.

  Four things make up "comfy", and each gets a describe block:

    1. `Browse.resolve_view!/2` accepts "comfy" and rejects garbage.
    2. `view_toggle/1` renders three buttons with exactly the current one
       marked active.
    3. The `pk-comfy` wrapper class appears only when `@view == "comfy"`.
    4. `Browse.item_row/1` itself carries the `[.pk-comfy_&]:…` density
       classes on its thumb — the wrapper class alone proves nothing
       without a descendant that actually reacts to it (round-3 FIX
       finding F1: the first three describe blocks stayed green with
       those classes deleted from `browse.ex`).
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias PhoenixKitCatalogue.Catalogue.BrowseState
  alias PhoenixKitCatalogue.Web.Components.Browse
  alias PhoenixKitCatalogue.Web.Components.ItemSelectorModal

  describe "Browse.resolve_view!/2 — the shared mount-time validator" do
    # ItemSelectorModal has no resolve_view!/1 of its own any more — main
    # centralized view validation into Browse.resolve_view!/2 (both browse
    # surfaces call it) while this branch was in flight. It already
    # accepted "table"/"card"; the assertions below are what this branch
    # actually adds: "comfy" as a third legal value.
    test "accepts \"comfy\" as-is" do
      assert Browse.resolve_view!("comfy", "table") == "comfy"
    end

    test "accepts the unchanged pair, table and card" do
      assert Browse.resolve_view!("table", "table") == "table"
      assert Browse.resolve_view!("card", "table") == "card"
    end

    test "accepts the atom form of all three" do
      assert Browse.resolve_view!(:comfy, "table") == "comfy"
      assert Browse.resolve_view!(:table, "table") == "table"
      assert Browse.resolve_view!(:card, "table") == "card"
    end

    test "nil defaults to the caller's default" do
      assert Browse.resolve_view!(nil, "table") == "table"
    end

    test "rejects garbage, naming all three legal values in the error" do
      assert_raise ArgumentError, ~r/"table", "comfy" or "card"/, fn ->
        Browse.resolve_view!("grid", "table")
      end

      assert_raise ArgumentError, fn -> Browse.resolve_view!(123, "table") end
      assert_raise ArgumentError, fn -> Browse.resolve_view!(:grid, "table") end
    end
  end

  describe "view_toggle/1 — three buttons, exactly one active" do
    # Same modes list, same order, as the production call site in
    # item_selector_modal.ex's render/1.
    @modes [
      %{mode: "card", icon: "hero-squares-2x2", label: "Card view"},
      %{mode: "comfy", icon: "hero-bars-3", label: "Comfy list view"},
      %{mode: "table", icon: "hero-bars-4", label: "Compact list view"}
    ]

    defp render_toggle(current),
      do: render_component(&Browse.view_toggle/1, id: "vt", modes: @modes, current: current)

    defp buttons(html), do: Regex.scan(~r/<button\b.*?<\/button>/s, html) |> List.flatten()

    test "renders exactly three buttons, one per mode" do
      html = render_toggle("table")

      assert length(buttons(html)) == 3
      assert html =~ "hero-squares-2x2"
      assert html =~ "hero-bars-3"
      assert html =~ "hero-bars-4"
    end

    test "comfy active: only the comfy button is marked" do
      [card_btn, comfy_btn, table_btn] = buttons(render_toggle("comfy"))

      assert comfy_btn =~ "btn-active"
      assert comfy_btn =~ ~s(aria-pressed="true")
      refute card_btn =~ "btn-active"
      refute table_btn =~ "btn-active"
      assert card_btn =~ ~s(aria-pressed="false")
      assert table_btn =~ ~s(aria-pressed="false")
    end

    test "table active: only the table button is marked (the pre-comfy default)" do
      [card_btn, comfy_btn, table_btn] = buttons(render_toggle("table"))

      refute card_btn =~ "btn-active"
      refute comfy_btn =~ "btn-active"
      assert table_btn =~ "btn-active"
    end

    test "card active: only the card button is marked" do
      [card_btn, comfy_btn, table_btn] = buttons(render_toggle("card"))

      assert card_btn =~ "btn-active"
      refute comfy_btn =~ "btn-active"
      refute table_btn =~ "btn-active"
    end
  end

  describe "pk-comfy wrapper — the class toggle that IS the comfy mode" do
    # render/1's own assign surface grew substantially (checkbox column,
    # thumb_click details, per-user view persistence, context header,
    # root_switcher, …) in the several days between this branch's first
    # commit and the main it now rebases onto — every key below is one
    # render/1 (or a function it calls with the full assigns map) reads
    # directly, gathered by tracing every `@foo` and every `helper(assigns)`
    # call in its body. Below the mount/initialize path (Catalogue +
    # Postgres) rather than through it, same as the rest of this file.
    defp base_modal_assigns(overrides) do
      browse = %{BrowseState.init() | items: [], loading?: false, exhausted?: true}
      cat_tree = %{roots: [], children: %{}, index: %{}}

      Map.merge(
        %{
          id: "sel",
          title: nil,
          view: "table",
          columns: Browse.default_table_columns(),
          visible_columns: Browse.default_table_columns(),
          selection_mode: "click",
          qty_precision: 0,
          qty_min: Decimal.new(1),
          qty_max: nil,
          show_prices: true,
          show_sku: true,
          show_tray: false,
          show_item_details: true,
          inline_qty: false,
          root_switcher: false,
          mode: :multiple,
          immediate: false,
          tray_open: false,
          drafts: %{},
          selection: %{},
          detail: nil,
          root_mode: "categories",
          search_cat_hits: [],
          scoped_root_category: nil,
          context_header?: false,
          header_context: nil,
          categories: [],
          cat_tree: cat_tree,
          browse: browse,
          myself: nil
        },
        overrides
      )
    end

    defp render_modal(view),
      do: render_component(&ItemSelectorModal.render/1, base_modal_assigns(%{view: view}))

    test "view: \"comfy\" wraps the table in pk-comfy" do
      html = render_modal("comfy")

      assert html =~ ~s(class="pk-comfy")
    end

    test "view: \"table\" carries no pk-comfy class anywhere in the output" do
      html = render_modal("table")

      refute html =~ "pk-comfy"
    end

    test "view: \"card\" carries no pk-comfy class either (the table wrapper doesn't even render)" do
      html = render_modal("card")

      refute html =~ "pk-comfy"
    end
  end

  describe "item_row/1 thumb — the descendant that actually reacts to .pk-comfy" do
    # `item_row` takes no `view`/density prop of its own — comfy is a pure
    # CSS hook (`[.pk-comfy_&]:…`), so the row markup is IDENTICAL in every
    # mode. What's being pinned here is that the markup carries the hook at
    # all, at each of the three spots `browse.ex` defines it.
    defp presented(over \\ %{}) do
      Map.merge(
        %{
          uuid: "u-1",
          name: "M8 Screw",
          sku: "M8-100",
          category: nil,
          price: nil,
          base_price: nil,
          unit: nil,
          manufacturer: nil,
          thumb_url: nil
        },
        over
      )
    end

    defp render_row(item),
      do:
        render_component(&Browse.item_row/1,
          id: "row-u-1",
          item: item,
          columns: [:thumb]
        )

    # item_row/1 (the table row) reads :thumb_url — a field distinct from
    # :photo_url, which only the card tile (item_card/1) reads (browse.ex
    # present_items/2 sets both, from the same source item, at two
    # different Storage variants).
    test "no-photo tile carries the w-16/h-16 comfy classes" do
      html = render_row(presented(%{thumb_url: nil}))

      refute html =~ "<img"
      assert html =~ "[.pk-comfy_&]:w-16"
      assert html =~ "[.pk-comfy_&]:h-16"
    end

    test "photo <img> carries the w-16/h-16 comfy classes" do
      html = render_row(presented(%{thumb_url: "/signed/medium/x"}))

      assert html =~ "<img"
      assert html =~ "[.pk-comfy_&]:w-16"
      assert html =~ "[.pk-comfy_&]:h-16"
    end

    test "the thumb cell itself carries the w-20 comfy class (row_cell_class/1)" do
      html = render_row(presented())

      # `row_cell_class/1` feeds a dynamic `class={[...]}` list, which HEEx
      # HTML-escapes (`&` -> `&amp;`) — unlike the static `class="…"`
      # attributes on the thumb image/tile above, which render the literal
      # `&`. Same source string, different escaping at the two call sites.
      assert html =~ "[.pk-comfy_&amp;]:w-20"
    end
  end

  describe "subcategory_level/1 — comfy renders the tiles, not just the heading" do
    # base_modal_assigns's cat_tree carries roots: [], so show_categories_block?/1
    # is always false in every test above and the subcategory_level block
    # never renders at all — proving nothing about the regression this
    # covers (comfy fell through both the "card" and "table" view branches
    # there, rendering the "Subcategories" heading with no tiles under it).
    # This fixture gives cat_tree a real root with a subcategory so the
    # block actually renders.
    defp cat_tree_with_subcategories do
      %{
        roots: [%{uuid: "cat-root", name: "Fasteners", data: %{}}],
        children: %{"cat-root" => [%{uuid: "cat-child", name: "Bolts", data: %{}}]},
        index: %{
          "cat-root" => %{parent_uuid: nil},
          "cat-child" => %{parent_uuid: "cat-root"}
        },
        counts: %{"cat-root" => 1, "cat-child" => 0}
      }
    end

    defp render_with_subcategories(view, browse_overrides \\ %{}) do
      browse =
        Map.merge(
          %{BrowseState.init() | items: [], loading?: false, exhausted?: true},
          browse_overrides
        )

      render_component(
        &ItemSelectorModal.render/1,
        base_modal_assigns(%{view: view, cat_tree: cat_tree_with_subcategories(), browse: browse})
      )
    end

    test "comfy mode renders the root tile as a table row, wrapped in pk-comfy" do
      html = render_with_subcategories("comfy")

      assert html =~ "pk-comfy"
      assert html =~ "Fasteners"
    end

    test "table mode renders the same root tile (comfy must not regress it)" do
      html = render_with_subcategories("table")

      assert html =~ "Fasteners"
    end

    test "card mode renders the root tile as a card" do
      html = render_with_subcategories("card")

      assert html =~ "Fasteners"
    end

    test "drilled into a category, comfy shows both the heading and the child tile" do
      html = render_with_subcategories("comfy", %{category_uuid: "cat-root"})

      assert html =~ "Subcategories"
      assert html =~ "Bolts"
    end
  end
end
