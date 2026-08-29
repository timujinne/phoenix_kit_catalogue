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

  Three things make up "comfy", and each gets a describe block:

    1. `resolve_view!/1` accepts "comfy" and rejects garbage.
    2. `view_toggle/1` renders three buttons with exactly the current one
       marked active.
    3. The `pk-comfy` wrapper class appears only when `@view == "comfy"`.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias PhoenixKitCatalogue.Catalogue.BrowseState
  alias PhoenixKitCatalogue.Web.Components.Browse
  alias PhoenixKitCatalogue.Web.Components.ItemSelectorModal

  describe "resolve_view!/1 — the mount-time validator" do
    test "accepts \"comfy\" as-is" do
      assert ItemSelectorModal.resolve_view!("comfy") == "comfy"
    end

    test "accepts the unchanged pair, table and card" do
      assert ItemSelectorModal.resolve_view!("table") == "table"
      assert ItemSelectorModal.resolve_view!("card") == "card"
    end

    test "accepts the atom form of all three" do
      assert ItemSelectorModal.resolve_view!(:comfy) == "comfy"
      assert ItemSelectorModal.resolve_view!(:table) == "table"
      assert ItemSelectorModal.resolve_view!(:card) == "card"
    end

    test "nil defaults to \"table\"" do
      assert ItemSelectorModal.resolve_view!(nil) == "table"
    end

    test "rejects garbage, naming all three legal values in the error" do
      assert_raise ArgumentError, ~r/"table", "comfy" or "card"/, fn ->
        ItemSelectorModal.resolve_view!("grid")
      end

      assert_raise ArgumentError, fn -> ItemSelectorModal.resolve_view!(123) end
      assert_raise ArgumentError, fn -> ItemSelectorModal.resolve_view!(:grid) end
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
    defp base_modal_assigns(overrides) do
      browse = %{BrowseState.init() | items: [], loading?: false, exhausted?: true}

      Map.merge(
        %{
          id: "sel",
          title: nil,
          view: "table",
          columns: Browse.default_table_columns(),
          visible_columns: Browse.default_table_columns(),
          selection_mode: "click",
          qty_precision: 0,
          show_prices: true,
          show_sku: true,
          mode: :multiple,
          immediate: false,
          tray_open: false,
          drafts: %{},
          selection: %{},
          categories: [],
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
end
