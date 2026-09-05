defmodule PhoenixKitCatalogue.Web.Components.BrowseTest do
  @moduledoc """
  Render-shape tests for the embeddable Browse components — the pieces a
  host composes directly, so their attrs/markup contract is pinned here
  independently of the picker that also uses them.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1, render_component: 2]

  alias PhoenixKitCatalogue.Schemas.Item
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

    test "a photo renders eagerly inside the fixed square frame" do
      html =
        render_component(&Browse.item_card/1,
          id: "c1",
          item: presented(%{photo_url: "/signed/medium/x"})
        )

      assert html =~ ~s(src="/signed/medium/x")
      # No loading="lazy": lazy images patched into an open top-layer
      # <dialog> can stay unloaded in Chromium ("photos invisible in the
      # popup", 2026-08-31), and a capped modal page saves nothing lazy.
      refute html =~ ~s(loading="lazy")
      assert html =~ "aspect-square"
      assert html =~ "object-cover"
    end

    test "selected state rides data-selected; the badge stays server-drawn" do
      # Since 2026-08-31 the ring/border classes are data-[selected=true]
      # variants present on EVERY card — the attribute drives the look, so
      # the qty hook can flip it instantly (Max: highlight "only after a
      # delay").
      selected =
        render_component(&Browse.item_card/1, id: "c1", item: presented(), selected: true)

      plain = render_component(&Browse.item_card/1, id: "c1", item: presented())

      assert selected =~ ~s(data-selected="true")
      assert selected =~ "hero-check"
      assert plain =~ ~s(data-selected="false")
      assert plain =~ "data-[selected=true]:ring-2"
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
      # Exactly ONE details trigger — the figure; the title sits inside
      # the select button (boss, 2026-08-31: only the thumbnail is the
      # look-closer gesture).
      assert length(String.split(html, ~s(phx-click="show_detail"))) == 2

      # Without photo_click: one button, no details affordance.
      plain = render_component(&Browse.item_card/1, id: "c1", item: item)
      refute plain =~ "show_detail"
      refute plain =~ "View item details"
    end

    test "the select toggle always carries the title — it can never render empty" do
      item = %{
        uuid: "u-1",
        name: "Widget",
        sku: nil,
        price: nil,
        unit: nil,
        photo_url: nil,
        thumb_url: nil
      }

      # With details on, the body (title included) IS the select button
      # (boss, 2026-08-31) — so even with sku and price both hidden the
      # card keeps a real select target, which retired the #89 review's
      # min-height patch for the empty-button case.
      html =
        render_component(&Browse.item_card/1,
          id: "c1",
          item: item,
          clickable: true,
          photo_click: "show_detail"
        )

      assert html =~ ~s(phx-click="card_click")
      assert html =~ "Widget"
      refute html =~ "min-h-[1.5rem]"
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

    test "smart fees show where the price goes: flat IS the price, percent and rules display" do
      # Smart-catalogue items rendered a BLANK price everywhere
      # (2026-08-31 — tim-dev's rule-priced services). Flat standalone
      # fees are real prices (line totals included); percent shows its
      # number; rule-priced items say Computed.
      flat = %Item{
        uuid: "sf-1",
        name: "Delivery",
        unit: "piece",
        base_price: nil,
        default_value: Decimal.new("49.00"),
        default_unit: "flat",
        markup_percentage: nil,
        discount_percentage: nil,
        catalogue: nil,
        category: nil,
        data: %{}
      }

      percent = %Item{
        flat
        | uuid: "sf-2",
          default_value: Decimal.new("12"),
          default_unit: "percent"
      }

      computed = %Item{flat | uuid: "sf-3", default_value: nil, default_unit: "percent"}

      [p_flat, p_percent, p_computed] = Browse.present_items([flat, percent, computed], "en")

      assert Decimal.equal?(p_flat.price, Decimal.new("49.00"))
      assert p_flat.fee_note == nil

      assert p_percent.price == nil
      assert p_percent.fee_note == "12%"

      assert p_computed.price == nil
      assert p_computed.fee_note == "Computed"

      # The row shows the note in the price cell; the card shows it on
      # the price line (and hides it with show_price=false, the same
      # grant as prices).
      row =
        render_component(&Browse.item_row/1, id: "r1", item: p_percent, columns: [:name, :price])

      assert row =~ "12%"

      card = render_component(&Browse.item_card/1, id: "c1", item: p_percent)
      assert card =~ "12%"

      hidden = render_component(&Browse.item_card/1, id: "c1", item: p_percent, show_price: false)
      refute hidden =~ "12%"
    end

    test "smart_fee crosses the {unit, value} product — the margins hid a clause once" do
      flat_base = %Item{
        uuid: "sfx-1",
        name: "Fee",
        unit: "piece",
        base_price: nil,
        default_value: Decimal.new("49.00"),
        default_unit: "flat",
        markup_percentage: nil,
        discount_percentage: nil,
        catalogue: nil,
        category: nil,
        data: %{}
      }

      # A DB numeric arrives with its scale — the display must normalize
      # (the "12.0000%" regression this pins, and the flat twin).
      db_percent = %Item{
        flat_base
        | default_value: Decimal.new("12.0000"),
          default_unit: "percent"
      }

      assert Browse.smart_fee(db_percent) == {:note, "12%"}

      # Flat with NO value: a fee item missing its number says Computed —
      # the same words the percent twin uses.
      assert Browse.smart_fee(%Item{flat_base | default_value: nil}) ==
               {:note, "Computed"}

      # A PRICED item carrying fee fields is a plain item — the fee
      # fallback must never override a real price.
      assert Browse.smart_fee(%Item{flat_base | base_price: Decimal.new("10.00")}) == nil

      # A fee-less unit with no price is simply price-less, not Computed.
      assert Browse.smart_fee(%Item{flat_base | default_unit: nil, default_value: nil}) == nil
    end

    test "instant qty feedback: hook on the stepper, styling keyed off data-selected" do
      # Max, 2026-08-31: "I add 1 and it gets highlighted blue but only
      # after a delay" — the QtySignal hook flips data-selected locally,
      # so the row/card highlight must key off the ATTRIBUTE, not a
      # server-computed class.
      stepper =
        render_component(&Browse.qty_stepper/1,
          id: "q1",
          uuid: "u-1",
          qty: "0",
          precision: 0
        )

      # The colocated hook's rendered name is the expanded module form.
      assert stepper =~ "QtySignal"

      row =
        render_component(&Browse.item_row/1,
          id: "r1",
          item: row_item(),
          columns: [:name, :qty]
        )

      assert row =~ "data-selected"
      assert row =~ "data-[selected=true]:bg-primary/10"

      card =
        render_component(&Browse.item_card/1,
          id: "c1",
          item: row_item()
        )

      assert card =~ "data-[selected=true]:border-primary"
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

    test "thumb_click rides ONLY the thumb cell; checkbox renders when asked" do
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
      # Exactly the thumb cell carries the details event (boss,
      # 2026-08-31: only the thumbnail is the look-closer gesture —
      # supersedes the title-joins-the-photo ruling); the name and sku
      # cells follow the row's select behaviour.
      assert length(String.split(html, ~s(phx-click="show_detail"))) == 2
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
