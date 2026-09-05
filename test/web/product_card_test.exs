defmodule PhoenixKitCatalogue.Web.Components.ProductCardTest do
  @moduledoc """
  Render-shape tests for the `product_card/1` function component and unit
  tests for its DB-free field extraction (`build_fields/2`). The DB-backed
  `resolve_images/1` folder listing + broken-featured filtering are covered
  in `product_card_db_test.exs`; here we pin the pure gallery render +
  hide-empty logic.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKitCatalogue.Schemas.Item
  alias PhoenixKitCatalogue.Web.Components.ProductCard

  defp images do
    [
      %{uuid: "img-1", name: "front.jpg"},
      %{uuid: "img-2", name: "back.jpg"},
      %{uuid: "img-3", name: nil}
    ]
  end

  defp base_assigns(overrides) do
    Map.merge(
      %{
        id: "pc",
        show: true,
        target: nil,
        item_name: "Oak Panel",
        images: images(),
        current_image: "img-1",
        fields: [],
        on_close: "card_close"
      },
      overrides
    )
  end

  defp render_card(overrides \\ %{}) do
    render_component(&ProductCard.product_card/1, base_assigns(overrides))
  end

  describe "carousel" do
    test "renders every image as a slide (medium variant) and the item name as title" do
      html = render_card()

      assert html =~ "Oak Panel"
      assert html =~ "carousel-item"
      for uuid <- ["img-1", "img-2", "img-3"], do: assert(html =~ uuid)
      assert html =~ "medium"
    end

    test "slides are switched client-side: jump strip + arrows, no server events" do
      html = render_card()

      # The strip and arrows scroll the snap track locally…
      assert html =~ "data-pc-track"
      assert html =~ "scrollIntoView"
      assert html =~ "scrollBy"
      assert html =~ "Previous"
      assert html =~ "Next"
      # …and no slide event ever reaches the server.
      refute html =~ "card_select_image"
    end

    test "a single image renders no strip and no arrows (nothing to switch to)" do
      html = render_card(%{images: [%{uuid: "only", name: "x.jpg"}]})

      assert html =~ "only"
      refute html =~ "scrollIntoView"
      refute html =~ "scrollBy"
    end

    test "files continue the same swipe track after the photos" do
      html = render_card(%{files: files()})

      # PDF slide: lazy inline viewer inside the carousel.
      assert html =~ "<iframe"
      assert html =~ ~s[loading="lazy"]
      # Non-PDF slide: a tile with the name and an Open action.
      assert html =~ "notes.txt"
      # The jump strip gets a tile per file too (extension label).
      assert html =~ "pdf"
      assert html =~ "txt"
    end
  end

  describe "fields" do
    test "renders the provided filled fields" do
      html = render_card(%{fields: [{"SKU", "KF-001"}, {"Price", "42.50"}]})

      assert html =~ "SKU"
      assert html =~ "KF-001"
      assert html =~ "Price"
      assert html =~ "42.50"
    end

    test "renders no field list when there are no fields" do
      html = render_card(%{fields: []})

      refute html =~ "<dl"
    end
  end

  describe "show=false" do
    test "renders nothing when closed" do
      html = render_card(%{show: false})

      refute html =~ "Oak Panel"
    end
  end

  describe "build_fields/2 (hide-empty logic)" do
    # Plain structs, no DB: sku/unit/description/metadata resolve purely;
    # price is rescued to nil when there's no catalogue to price against.
    test "includes filled scalar + metadata fields, keyed by their labels" do
      item = %Item{
        name: "Oak Panel",
        sku: "KF-001",
        unit: "running_meter",
        description: "Solid oak",
        catalogue: nil,
        base_price: nil,
        data: %{"meta" => %{"color" => "Natural", "material" => "Oak"}}
      }

      fields = ProductCard.build_fields(item, "en")

      assert {"SKU", "KF-001"} in fields
      assert {"Unit", "rm"} in fields
      assert {"Description", "Solid oak"} in fields
      assert {"Color", "Natural"} in fields
      assert {"Material", "Oak"} in fields
    end

    test "does not crash on a non-scalar metadata value (drops the bad metadata)" do
      # A malformed/legacy meta value that is itself a map makes
      # `Metadata.build_state/2` raise (it `to_string`s each value). build_fields
      # must swallow that and still return the scalar fields, never crash.
      item = %Item{
        name: "X",
        sku: "KF-1",
        unit: nil,
        description: nil,
        catalogue: nil,
        base_price: nil,
        data: %{"meta" => %{"color" => %{"nested" => "map"}}}
      }

      fields = ProductCard.build_fields(item, "en")

      assert is_list(fields)
      # The scalar SKU field still comes through; the bad metadata is dropped.
      assert {"SKU", "KF-1"} in fields
      refute Enum.any?(fields, fn {label, _value} -> label == "Color" end)
    end

    test "drops empty fields entirely" do
      item = %Item{
        name: "Bare",
        sku: nil,
        unit: nil,
        description: "",
        catalogue: nil,
        base_price: nil,
        data: %{}
      }

      labels = item |> ProductCard.build_fields("en") |> Enum.map(&elem(&1, 0))

      refute "SKU" in labels
      refute "Description" in labels
      refute "Unit" in labels
    end

    test "the Price row falls back to the smart fee, formatted like the listing" do
      # The detail card must never disagree with the row the click came
      # from: flat fee formats through Browse.format_price ("49.00", not
      # "49.0000"), percent renders its note (external review pins,
      # 2026-08-31).
      flat = %Item{
        name: "Delivery",
        sku: nil,
        unit: nil,
        description: nil,
        catalogue: nil,
        base_price: nil,
        default_value: Decimal.new("49.0000"),
        default_unit: "flat",
        data: %{}
      }

      assert {"Price", "49.00"} in ProductCard.build_fields(flat, "en")

      percent = %Item{flat | default_value: Decimal.new("12.0000"), default_unit: "percent"}
      assert {"Price", "12%"} in ProductCard.build_fields(percent, "en")

      # And the fee row obeys the price grant like a real price.
      no_price = ProductCard.build_fields(percent, "en", include_price: false)
      refute Enum.any?(no_price, fn {label, _v} -> label == "Price" end)
    end
  end

  # ── Files section (pdf viewer / file list) ────────────────────────

  defp files do
    [
      %{uuid: "pdf-1", name: "spec-sheet.pdf", size: 120_000, pdf?: true},
      %{uuid: "doc-1", name: "notes.txt", size: 900, pdf?: false}
    ]
  end

  describe "files list" do
    test "lists files with size and an Open link, no server events" do
      html = render_card(%{files: files()})

      assert html =~ "spec-sheet.pdf"
      assert html =~ "notes.txt"
      assert html =~ "120.0 KB"
      assert html =~ ~s(target="_blank")
      refute html =~ "card_view_file"
    end

    test "no files renders no Files heading" do
      refute render_card() =~ ">Files<"
    end
  end

  describe "product_card_body/1 (notpopup form)" do
    test "renders the same content without the modal shell" do
      html =
        render_component(
          &ProductCard.product_card_body/1,
          base_assigns(%{files: files()}) |> Map.drop([:id, :show, :on_close])
        )

      assert html =~ "img-1"
      assert html =~ "spec-sheet.pdf"
      assert html =~ "carousel"
      refute html =~ "<dialog"
    end
  end
end
