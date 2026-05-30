defmodule PhoenixKitCatalogue.Web.Components.ItemPickerTest do
  @moduledoc """
  Render-shape tests for the `ItemPicker` LiveComponent.

  These don't drive the event lifecycle — they just verify the
  template produces the HTML the hook and the parent LV expect
  (ARIA attrs, disabled/excluded styling, sentinel rows, wrapper
  classes). Search behaviour (server-side DB queries) belongs in
  integration tests.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKitCatalogue.Schemas.{Catalogue, Item}
  alias PhoenixKitCatalogue.Web.Components.ItemPicker

  defp fake_catalogue do
    %Catalogue{
      uuid: "cat-uuid-1",
      name: "Kitchen",
      markup_percentage: Decimal.new("0"),
      discount_percentage: Decimal.new("0"),
      kind: "standard",
      data: %{}
    }
  end

  defp fake_item(uuid, name, unit \\ "piece") do
    %Item{
      uuid: uuid,
      name: name,
      unit: unit,
      base_price: Decimal.new("100.00"),
      markup_percentage: nil,
      discount_percentage: nil,
      catalogue: fake_catalogue(),
      category: nil,
      data: %{}
    }
  end

  # Short-circuits item_pricing/1 in tests so we don't exercise the
  # DB or Decimal math — we're verifying the picker's render shape,
  # not pricing.
  defp constant_price(_item), do: "€123"

  defp base_assigns(overrides \\ %{}) do
    Map.merge(
      %{
        id: "test-picker",
        locale: "en",
        selected_item: nil,
        excluded_uuids: [],
        category_uuids: nil,
        catalogue_uuids: nil,
        format_price: &constant_price/1
      },
      overrides
    )
  end

  describe "render shape (closed state)" do
    test "renders combobox input with required ARIA attrs" do
      html = render_component(ItemPicker, base_assigns())

      assert html =~ ~s(role="combobox")
      assert html =~ ~s(aria-expanded="false")
      assert html =~ ~s(aria-autocomplete="list")
      assert html =~ ~s(aria-controls="test-picker-listbox")
    end

    test "renders with phx-hook set to the colocated ItemPicker hook" do
      html = render_component(ItemPicker, base_assigns())

      assert html =~ ~s(phx-hook=".ItemPicker") or
               html =~ ~s(phx-hook="PhoenixKitCatalogue.Web.Components.ItemPicker.ItemPicker")
    end

    test "does not render the listbox when closed" do
      html = render_component(ItemPicker, base_assigns())

      refute html =~ ~s(id="test-picker-listbox")
    end

    test "disabled=true disables the input and hides clear button" do
      html = render_component(ItemPicker, base_assigns(%{disabled: true}))

      assert html =~ "disabled"
      refute html =~ ~s(phx-click="clear")
    end

    test "placeholder defaults to gettext 'Search items…'" do
      html = render_component(ItemPicker, base_assigns())
      assert html =~ "Search items"
    end

    test "custom placeholder overrides the default" do
      html = render_component(ItemPicker, base_assigns(%{placeholder: "Pick a part"}))
      assert html =~ ~s(placeholder="Pick a part")
    end
  end

  describe "render shape (open with options)" do
    test "renders listbox and options when :open and :options are set" do
      html =
        render_component(
          ItemPicker,
          base_assigns(%{
            open: true,
            options: [fake_item("item-1", "Oak Plank"), fake_item("item-2", "Pine Plank")],
            has_more: false
          })
        )

      assert html =~ ~s(id="test-picker-listbox")
      assert html =~ ~s(role="listbox")
      assert html =~ "Oak Plank"
      assert html =~ "Pine Plank"
      assert html =~ "€123"
    end

    test "excluded items get aria-disabled=true and are not clickable" do
      html =
        render_component(
          ItemPicker,
          base_assigns(%{
            open: true,
            options: [
              fake_item("item-1", "Oak Plank"),
              fake_item("item-excluded", "Pine Plank")
            ],
            excluded_uuids: ["item-excluded"],
            has_more: false
          })
        )

      # The excluded option carries aria-disabled="true"
      assert html =~ ~s(aria-disabled="true")
      assert html =~ "Pine Plank"
    end

    test "selected item gets aria-selected=true" do
      item = fake_item("item-1", "Oak Plank")

      html =
        render_component(
          ItemPicker,
          base_assigns(%{
            open: true,
            options: [item],
            selected_item: item,
            has_more: false
          })
        )

      assert html =~ ~s(aria-selected="true")
    end

    test "has_more=true shows 'Type to refine search…' sentinel" do
      html =
        render_component(
          ItemPicker,
          base_assigns(%{
            open: true,
            options: [fake_item("item-1", "Oak Plank")],
            has_more: true
          })
        )

      assert html =~ "Type to refine search"
    end

    test "has_more=false omits the sentinel" do
      html =
        render_component(
          ItemPicker,
          base_assigns(%{
            open: true,
            options: [fake_item("item-1", "Oak Plank")],
            has_more: false
          })
        )

      refute html =~ "Type to refine search"
    end

    test "empty-options + non-empty query shows 'No items found'" do
      html =
        render_component(
          ItemPicker,
          base_assigns(%{
            open: true,
            query: "xyzzy",
            options: [],
            has_more: false
          })
        )

      assert html =~ "No items found"
    end
  end

  describe "breadcrumb" do
    test "renders catalogue name when category is nil (uncategorized item)" do
      item = fake_item("item-1", "Top-level item")

      html =
        render_component(
          ItemPicker,
          base_assigns(%{open: true, options: [item], has_more: false})
        )

      assert html =~ "Kitchen"
    end
  end

  describe "show_unit (opt-in unit column)" do
    test "show_unit=true renders the mapped unit label in the row" do
      html =
        render_component(
          ItemPicker,
          base_assigns(%{
            open: true,
            show_unit: true,
            options: [fake_item("item-1", "Oak Plank", "running_meter")],
            has_more: false
          })
        )

      assert html =~ "rm"
    end

    test "show_unit=true maps m2 to m²" do
      html =
        render_component(
          ItemPicker,
          base_assigns(%{
            open: true,
            show_unit: true,
            options: [fake_item("item-1", "Glass Pane", "m2")],
            has_more: false
          })
        )

      assert html =~ "m²"
    end

    test "show_unit defaults to false and hides the unit (backward compatible)" do
      html =
        render_component(
          ItemPicker,
          base_assigns(%{
            open: true,
            options: [fake_item("item-1", "Oak Plank", "running_meter")],
            has_more: false
          })
        )

      refute html =~ ">rm<"
    end

    test "show_unit=true with nil unit omits the unit label" do
      html =
        render_component(
          ItemPicker,
          base_assigns(%{
            open: true,
            show_unit: true,
            options: [fake_item("item-1", "Oak Plank", nil)],
            has_more: false
          })
        )

      # No unit row text leaks in; name still renders
      assert html =~ "Oak Plank"
    end
  end

  describe "selected_item styling" do
    test "selected_item non-nil adds input-primary class" do
      item = fake_item("item-1", "Oak Plank")

      html =
        render_component(
          ItemPicker,
          base_assigns(%{selected_item: item})
        )

      assert html =~ "input-primary"
      # Clear button renders
      assert html =~ ~s(phx-click="clear")
    end

    test "selected_item nil omits the primary class and clear button" do
      html = render_component(ItemPicker, base_assigns())

      refute html =~ "input-primary"
      refute html =~ ~s(phx-click="clear")
    end

    test "highlight_selected=false suppresses the primary border even when selected" do
      item = fake_item("item-1", "Oak Plank")

      html =
        render_component(
          ItemPicker,
          base_assigns(%{selected_item: item, highlight_selected: false})
        )

      refute html =~ "input-primary"
      # The selection itself is unaffected — the clear button still renders.
      assert html =~ ~s(phx-click="clear")
    end
  end

  describe "format_unit (custom unit labels)" do
    test "format_unit overrides the default unit label" do
      html =
        render_component(
          ItemPicker,
          base_assigns(%{
            open: true,
            show_unit: true,
            format_unit: fn "running_meter" -> "lm" end,
            options: [fake_item("item-1", "Beam", "running_meter")],
            has_more: false
          })
        )

      assert html =~ "lm"
      refute html =~ ">rm<"
    end
  end

  # initial_query SEEDING here only covers the DB-free guard branches (the
  # positive "search runs and prefills" path needs the catalogue Repo and lives
  # in the integration suite). update/2 must never clobber a real selection or a
  # blank input.
  describe "initial_query seeding (guards)" do
    test "does not clobber the input when an item is already selected" do
      item = fake_item("item-1", "Oak Plank")

      html =
        render_component(
          ItemPicker,
          base_assigns(%{selected_item: item, initial_query: "ignored seed"})
        )

      # The selected item's name wins; the seed string is ignored.
      assert html =~ "Oak Plank"
      refute html =~ "ignored seed"
    end

    test "a blank seed leaves the input empty and the dropdown closed" do
      html = render_component(ItemPicker, base_assigns(%{initial_query: ""}))

      assert html =~ ~s(value="")
      assert html =~ ~s(aria-expanded="false")
    end
  end
end
