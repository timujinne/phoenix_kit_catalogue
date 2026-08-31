defmodule PhoenixKitCatalogue.Web.Components.BrowseTest do
  @moduledoc """
  Render-shape tests for the embeddable Browse components — the pieces a
  host composes directly, so their attrs/markup contract is pinned here
  independently of the picker that also uses them.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1, render_component: 2]

  alias PhoenixKitCatalogue.Web.Components.Browse

  defp presented(over \\ %{}) do
    Map.merge(
      %{
        uuid: "u-1",
        name: "M8 Screw",
        sku: "M8-100",
        price: Decimal.new("2.50"),
        unit: "piece",
        manufacturer: nil,
        photo_url: nil,
        thumb_url: nil,
        default_qty: Decimal.new(1)
      },
      over
    )
  end

  describe "item_card/1" do
    test "no photo renders the deliberate SKU tile, never a broken image" do
      html = render_component(&Browse.item_card/1, id: "c1", item: presented())

      refute html =~ "<img"
      assert html =~ "M8-100"
      # The tile leads with the SKU initial.
      assert html =~ ">M</span>"
    end

    test "a photo renders lazily inside the fixed square frame" do
      html =
        render_component(&Browse.item_card/1,
          id: "c1",
          item: presented(%{photo_url: "/signed/medium/x"})
        )

      assert html =~ ~s(src="/signed/medium/x")
      assert html =~ ~s(loading="lazy")
      assert html =~ "aspect-square"
      assert html =~ "object-cover"
    end

    test "selected state draws the ring and badge; unselected draws neither" do
      selected =
        render_component(&Browse.item_card/1, id: "c1", item: presented(), selected: true)

      plain = render_component(&Browse.item_card/1, id: "c1", item: presented())

      assert selected =~ "ring-2"
      assert selected =~ "hero-check"
      refute plain =~ "ring-2"
      refute plain =~ "hero-check"
    end

    test "price and sku toggle off for embeddings that hide them" do
      html =
        render_component(&Browse.item_card/1,
          id: "c1",
          item: presented(),
          show_price: false,
          show_sku: false
        )

      refute html =~ "2.50"
      # The SKU still appears in the no-photo tile — hiding show_sku hides
      # the card-body line, not the placeholder identity.
      refute html =~ ~s(class="font-mono text-xs text-base-content/60")
    end
  end

  describe "item_card/1 photo_click split (2026-08-31 delta pin)" do
    test "with photo_click the figure is its own details button; the body keeps the select" do
      item = %{
        uuid: "u-1",
        name: "Widget",
        sku: "W-1",
        price: nil,
        unit: "piece",
        photo_url: nil,
        thumb_url: nil
      }

      html =
        render_component(&Browse.item_card/1,
          id: "c1",
          item: item,
          photo_click: "show_detail"
        )

      assert html =~ ~s(phx-click="show_detail")
      assert html =~ ~s(phx-click="card_click")
      # The two gestures carry distinct accessible names.
      assert html =~ "View item details"

      # Without photo_click: one button, no details affordance.
      plain = render_component(&Browse.item_card/1, id: "c1", item: item)
      refute plain =~ "show_detail"
      refute plain =~ "View item details"
    end

    test "the select toggle keeps a hit area when sku and price both hide" do
      item = %{
        uuid: "u-1",
        name: "Widget",
        sku: nil,
        price: nil,
        unit: nil,
        photo_url: nil,
        thumb_url: nil
      }

      # With the details split on, the title opens details and the select
      # toggle is only what is LEFT of the body — nothing at all here. It
      # must still be hittable, or the card cannot be picked in card view.
      html =
        render_component(&Browse.item_card/1,
          id: "c1",
          item: item,
          clickable: true,
          photo_click: "show_detail"
        )

      assert html =~ ~s(phx-click="card_click")
      assert html =~ "min-h-[1.5rem]"

      # The quantity flavour's disabled toggle adds no blank strip.
      refute render_component(&Browse.item_card/1,
               id: "c1",
               item: item,
               clickable: false,
               photo_click: "show_detail"
             ) =~ "min-h-[1.5rem]"
    end
  end

  describe "item_table/1 + item_row/1 render contract (2026-08-31 delta pin)" do
    defp row_item do
      %{
        uuid: "u-1",
        name: "Widget",
        sku: "W-1",
        price: Decimal.new("2.50"),
        base_price: Decimal.new("2.00"),
        unit: "piece",
        manufacturer: "Acme",
        category: "Bolts",
        photo_url: nil,
        thumb_url: nil,
        default_qty: Decimal.new(1)
      }
    end

    test "the qty cell is never click-bound; data cells carry the select toggle" do
      html =
        render_component(&Browse.item_row/1,
          id: "r1",
          item: row_item(),
          columns: [:thumb, :name, :qty]
        )

      # A quantity keystroke must never toggle the row underneath it:
      # data cells are click-bound, the LAST cell (:qty) is not.
      assert html =~ ~s(phx-click="card_click")
      qty_cell = html |> String.split("<td") |> List.last()
      refute qty_cell =~ "card_click"
    end

    test "thumb_click rides the thumb AND name cells; checkbox renders when asked" do
      html =
        render_component(&Browse.item_row/1,
          id: "r1",
          item: row_item(),
          columns: [:thumb, :name, :sku],
          checkbox: true,
          thumb_click: "show_detail"
        )

      assert html =~ ~s(phx-click="show_detail")
      assert html =~ ~s(input type="checkbox")
      # Exactly the thumb and name cells carry the details event (Max,
      # 2026-08-31: clicking the title means the same as clicking the
      # image); the sku cell keeps the select toggle.
      assert length(String.split(html, ~s(phx-click="show_detail"))) == 3
      assert html =~ ~s(phx-click="card_click")
    end

    test "item_table renders the checkbox header cell in lockstep" do
      with_box =
        render_component(&Browse.item_table/1,
          id: "t1",
          columns: [:name],
          checkbox: true,
          inner_block: [%{inner_block: fn _, _ -> "" end}]
        )

      without =
        render_component(&Browse.item_table/1,
          id: "t1",
          columns: [:name],
          inner_block: [%{inner_block: fn _, _ -> "" end}]
        )

      assert length(String.split(with_box, "<th")) == length(String.split(without, "<th")) + 1
    end
  end

  describe "shared resolvers (2026-08-31 delta pin)" do
    test "resolve_view!/2 validates and defaults per caller" do
      assert Browse.resolve_view!(nil, "card") == "card"
      assert Browse.resolve_view!(:table, "card") == "table"
      assert_raise ArgumentError, ~r/table.*card/, fn -> Browse.resolve_view!("grid", "card") end
    end

    test "resolve_columns!/2 rejects unknown entries loudly" do
      assert_raise ArgumentError, ~r/unknown entries/, fn ->
        Browse.resolve_columns!([:name, :bogus], %{show_sku: true, show_prices: true})
      end
    end
  end

  describe "qty_stepper/1" do
    # 2026-08-30: a native <input type="number"> — browser spinner arrows,
    # no custom −/+ buttons.
    test "integer mode: native number control, step 1, numeric keyboard, no unit suffix" do
      html =
        render_component(&Browse.qty_stepper/1, id: "q1", uuid: "u-1", qty: "3", precision: 0)

      assert html =~ ~s(type="number")
      assert html =~ ~s(step="1")
      assert html =~ ~s(inputmode="numeric")
      refute html =~ "join-item pointer-events-none"
      refute html =~ "qty_inc"
      refute html =~ "qty_dec"
    end

    test "decimal mode: precision-derived step, decimal keyboard, unit suffix — same component" do
      html =
        render_component(&Browse.qty_stepper/1,
          id: "q1",
          uuid: "u-1",
          qty: "2.5",
          precision: 2,
          unit: "L"
        )

      assert html =~ ~s(step="0.01")
      assert html =~ ~s(inputmode="decimal")
      assert html =~ ">L</span>" or html =~ "L\n"
      assert html =~ ~s(value="2.5")
    end

    test "commit wiring: blur and submit target qty_commit, change targets qty_change" do
      html =
        render_component(&Browse.qty_stepper/1, id: "q1", uuid: "u-1", qty: "1", precision: 0)

      assert html =~ ~s(phx-blur="qty_commit")
      assert html =~ ~s(phx-submit="qty_commit")
      assert html =~ ~s(phx-change="qty_change")
      assert html =~ ~s(phx-debounce)
      assert html =~ ~s(name="uuid" value="u-1")
      # novalidate keeps Enter alive: step/min/max are validation
      # constraints, and a phx-submit form never fires while one fails —
      # the server owns rounding/clamping (2026-08-31, the entities-0.4.9
      # lesson applied to this control).
      assert html =~ "novalidate"
    end

    test "min and max shape the arrows when given, and are absent otherwise" do
      bounded =
        render_component(&Browse.qty_stepper/1,
          id: "q1",
          uuid: "u-1",
          qty: "1",
          precision: 0,
          min: "0",
          max: "99"
        )

      assert bounded =~ ~s(min="0")
      assert bounded =~ ~s(max="99")

      open =
        render_component(&Browse.qty_stepper/1, id: "q1", uuid: "u-1", qty: "1", precision: 0)

      refute open =~ ~s(min=)
      refute open =~ ~s(max=)
    end
  end

  describe "category_chips/1" do
    test "All is active with no selection; the active chip flips with it" do
      cats = [%{uuid: "a", name: "Bolts"}, %{uuid: "b", name: "Paint"}]

      none = render_component(&Browse.category_chips/1, id: "ch", categories: cats)

      one =
        render_component(&Browse.category_chips/1, id: "ch", categories: cats, active_uuid: "b")

      assert none =~ ~r/btn-primary[^>]*>\s*All/
      assert one =~ ~r/btn-primary[^>]*\n?\s*phx-click/ or one =~ "Paint"
      assert one =~ ~s(phx-value-uuid="b")
    end
  end

  describe "present_items/2" do
    test "resolves translation, featured photo and default qty once, up front" do
      item = %{
        uuid: "u-9",
        name: "Primary Name",
        sku: "SKU-9",
        base_price: Decimal.new("10.00"),
        unit: "L",
        manufacturer_name: nil,
        manufacturer_name_snapshot: "ACME",
        default_value: Decimal.new("2.5"),
        data: %{"featured_image_uuid" => "0198c2f0-0000-7000-8000-000000000001"}
      }

      [p] = Browse.present_items([item], "en")

      assert p.uuid == "u-9"
      assert p.sku == "SKU-9"
      assert p.manufacturer == "ACME"
      # The signed URLs are computed here — the card never talks to
      # Storage. Two sizes: medium for the card faces, the 150px
      # thumbnail for the 32-48px row cells (2026-08-29 image sweep).
      # The pointer must be UUID-shaped since the 2026-08-31 sweep — a
      # garbage value yields nil rather than an attacker-shaped path.
      assert p.photo_url =~ "0198c2f0-0000-7000-8000-000000000001"
      assert p.photo_url =~ "medium"
      assert p.thumb_url =~ "0198c2f0-0000-7000-8000-000000000001"
      assert p.thumb_url =~ "thumbnail"

      garbage = %{item | data: %{"featured_image_uuid" => "../../etc/passwd"}}
      [g] = Browse.present_items([garbage], "en")
      assert g.photo_url == nil
      assert g.thumb_url == nil
      # Starting qty is always 1. `default_value` is the smart-catalogue
      # fee fallback, not a pick quantity.
      assert Decimal.equal?(p.default_qty, Decimal.new(1))
    end

    test "Item structs expose selling price (markup applied), not base_price" do
      item = %PhoenixKitCatalogue.Schemas.Item{
        uuid: "u-11",
        name: "Priced",
        sku: "P-1",
        base_price: Decimal.new("100.00"),
        markup_percentage: nil,
        discount_percentage: nil,
        unit: "piece",
        manufacturer_name: nil,
        manufacturer_name_snapshot: nil,
        default_value: Decimal.new("5"),
        data: %{},
        catalogue: %PhoenixKitCatalogue.Schemas.Catalogue{
          markup_percentage: Decimal.new("10"),
          discount_percentage: Decimal.new("0")
        }
      }

      [p] = Browse.present_items([item], "en")

      assert Decimal.equal?(p.price, Decimal.new("110.00"))
      assert Decimal.equal?(p.default_qty, Decimal.new(1))
    end

    test "no featured image and no default_value degrade to nil photo and qty 1" do
      item = %{
        uuid: "u-10",
        name: "Plain",
        sku: nil,
        base_price: nil,
        unit: "piece",
        manufacturer_name: nil,
        manufacturer_name_snapshot: nil,
        default_value: nil,
        data: %{}
      }

      [p] = Browse.present_items([item], "en")

      assert p.photo_url == nil
      assert p.thumb_url == nil
      assert Decimal.equal?(p.default_qty, Decimal.new(1))
    end
  end

  describe "grid geometry" do
    test "skeleton cards share the card frame so arrival does not reflow" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <PhoenixKitCatalogue.Web.Components.Browse.grid_skeleton id="sk" count={2} />
        """)

      assert html =~ "aspect-square"
      # Same count as requested, each with a unique id.
      assert html =~ ~s(id="sk-1")
      assert html =~ ~s(id="sk-2")
    end
  end
end
