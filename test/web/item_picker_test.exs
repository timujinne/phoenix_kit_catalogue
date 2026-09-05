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

  alias PhoenixKitCatalogue.Schemas.{Catalogue, Category, Item}
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

  describe "locale fallback (tim-dev error report, 2026-08-31)" do
    test "without a :locale attr the process gettext locale applies" do
      item = %{
        fake_item("i-loc-1", "Steel screw")
        | data: %{
            "_primary_language" => "en",
            "en" => %{"_name" => "Steel screw"},
            "et" => %{"_name" => "Teraskruvi"}
          }
      }

      # The Andi shape: the host process is in et, no attr passed. The
      # picker used to default to a hardcoded "en" here — its dropdown,
      # breadcrumbs and product-card popup all stayed English.
      Gettext.put_locale("et")

      html =
        render_component(
          ItemPicker,
          base_assigns() |> Map.delete(:locale) |> Map.put(:selected_item, item)
        )

      assert html =~ "Teraskruvi"
      refute html =~ "Steel screw"
    end

    test "an explicit locale={nil} falls back too — the common host shape" do
      # `locale={@locale}` with a nil assign passes the key PRESENT and
      # nil; a put_new-style fallback skipped it and the page silently
      # dropped to untranslated names (external review, 2026-08-31).
      item = %{
        fake_item("i-loc-3", "Steel screw")
        | data: %{
            "_primary_language" => "en",
            "en" => %{"_name" => "Steel screw"},
            "et" => %{"_name" => "Teraskruvi"}
          }
      }

      Gettext.put_locale("et")

      html =
        render_component(
          ItemPicker,
          base_assigns() |> Map.put(:locale, nil) |> Map.put(:selected_item, item)
        )

      assert html =~ "Teraskruvi"
      refute html =~ "Steel screw"
    end

    test "an explicit :locale attr still wins" do
      item = %{
        fake_item("i-loc-2", "Steel screw")
        | data: %{
            "_primary_language" => "en",
            "en" => %{"_name" => "Steel screw"},
            "et" => %{"_name" => "Teraskruvi"}
          }
      }

      Gettext.put_locale("et")

      html =
        render_component(
          ItemPicker,
          base_assigns() |> Map.put(:locale, "en") |> Map.put(:selected_item, item)
        )

      assert html =~ "Steel screw"
    end
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

    test "a nil price renders the option row without crashing (BadBooleanError pin)" do
      # PR #63 fixed `price && …` vs `price != nil and …` in the option
      # row after a nil price crashed it; every other render test uses a
      # constant string price, so this is the only case that would
      # regress if the boolean guard ever reverts to `or`/`and` on a
      # possibly-nil value.
      html =
        render_component(
          ItemPicker,
          base_assigns(%{
            open: true,
            options: [fake_item("item-nil-price", "Priceless Plank")],
            has_more: false,
            show_unit: false,
            format_price: fn _ -> nil end
          })
        )

      assert html =~ "Priceless Plank"
      refute html =~ "€123"
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

    test "inserts the ancestor chain from category_paths between catalogue and direct category" do
      category = %Category{uuid: "cat-furniture", name: "Furniture", data: %{}}
      item = %{fake_item("item-1", "Oak Chair") | category: category}

      html =
        render_component(
          ItemPicker,
          base_assigns(%{
            open: true,
            options: [item],
            has_more: false,
            category_paths: %{"cat-furniture" => ["Home", "Living Room"]}
          })
        )

      assert html =~ "Kitchen / Home / Living Room / Furniture"
    end

    test "omits ancestor names when category_paths has no entry for the category" do
      category = %Category{uuid: "cat-furniture", name: "Furniture", data: %{}}
      item = %{fake_item("item-1", "Oak Chair") | category: category}

      html =
        render_component(
          ItemPicker,
          base_assigns(%{open: true, options: [item], has_more: false})
        )

      assert html =~ "Kitchen / Furniture"
      refute html =~ "Home"
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

      # Name still renders, but the muted unit row is omitted entirely.
      assert html =~ "Oak Plank"
      refute html =~ ~s(<div class="text-xs text-base-content/50">)
    end
  end

  describe "show_sku (opt-in SKU column)" do
    test "show_sku=true renders the item's SKU in the row" do
      item = %{fake_item("item-1", "Oak Plank") | sku: "74.W1000.ST76.1.5.43"}

      html =
        render_component(
          ItemPicker,
          base_assigns(%{
            open: true,
            show_sku: true,
            options: [item],
            has_more: false
          })
        )

      assert html =~ "74.W1000.ST76.1.5.43"
    end

    test "show_sku=true with a missing SKU renders an em dash" do
      item = %{fake_item("item-1", "Oak Plank") | sku: nil}

      html =
        render_component(
          ItemPicker,
          base_assigns(%{
            open: true,
            show_sku: true,
            options: [item],
            has_more: false
          })
        )

      assert html =~ "Oak Plank"
      assert html =~ "—"
    end

    test "show_sku defaults to false and hides the SKU (backward compatible)" do
      item = %{fake_item("item-1", "Oak Plank") | sku: "74.W1000.ST76.1.5.43"}

      html =
        render_component(
          ItemPicker,
          base_assigns(%{
            open: true,
            options: [item],
            has_more: false
          })
        )

      refute html =~ "74.W1000.ST76.1.5.43"
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

  describe "selected item photo preview" do
    test "renders a thumbnail to the left of the input when the selected item has a photo" do
      item = %{
        fake_item("item-1", "Oak Plank")
        | data: %{"featured_image_uuid" => "photo-uuid-abc"}
      }

      html = render_component(ItemPicker, base_assigns(%{selected_item: item}))

      # An <img> preview appears and its src carries the featured file UUID.
      assert html =~ "<img"
      assert html =~ "photo-uuid-abc"
    end

    test "alt carries the item's display name, not an empty string (inert thumbnail)" do
      item = %{
        fake_item("item-1", "Oak Plank")
        | data: %{"featured_image_uuid" => "photo-uuid-abc"}
      }

      html = render_component(ItemPicker, base_assigns(%{selected_item: item}))

      assert html =~ ~s(alt="Oak Plank")
      refute html =~ ~s(alt="")
    end

    test "alt carries the item's display name on the clickable thumbnail too" do
      item = %{
        fake_item("item-1", "Oak Plank")
        | data: %{"featured_image_uuid" => "photo-uuid-abc"}
      }

      html =
        render_component(ItemPicker, base_assigns(%{selected_item: item, photo_clickable: true}))

      assert html =~ ~s(alt="Oak Plank")
      refute html =~ ~s(alt="")
    end

    test "renders no thumbnail when the selected item has no photo" do
      # fake_item/2 sets data: %{} — no featured_image_uuid.
      item = fake_item("item-1", "Oak Plank")

      html = render_component(ItemPicker, base_assigns(%{selected_item: item}))

      refute html =~ "<img"
    end

    test "renders no thumbnail when nothing is selected" do
      html = render_component(ItemPicker, base_assigns())

      refute html =~ "<img"
    end

    test "treats a blank featured_image_uuid as no photo" do
      item = %{fake_item("item-1", "Oak Plank") | data: %{"featured_image_uuid" => ""}}

      html = render_component(ItemPicker, base_assigns(%{selected_item: item}))

      refute html =~ "<img"
    end

    test "thumbnail is inert by default (no click hook)" do
      item = %{
        fake_item("item-1", "Oak Plank")
        | data: %{"featured_image_uuid" => "photo-uuid-abc"}
      }

      html = render_component(ItemPicker, base_assigns(%{selected_item: item}))

      assert html =~ "<img"
      refute html =~ ~s(phx-click="photo_click")
    end

    test "photo_clickable=true wraps the thumbnail in a click hook" do
      item = %{
        fake_item("item-1", "Oak Plank")
        | data: %{"featured_image_uuid" => "photo-uuid-abc"}
      }

      html =
        render_component(ItemPicker, base_assigns(%{selected_item: item, photo_clickable: true}))

      # The navigation hook the product-card feature (L026.1) wires up.
      assert html =~ ~s(phx-click="photo_click")
      assert html =~ "photo-uuid-abc"
    end

    test "photo_clickable=true renders cursor-pointer on the thumbnail button" do
      item = %{
        fake_item("item-1", "Oak Plank")
        | data: %{"featured_image_uuid" => "photo-uuid-abc"}
      }

      html =
        render_component(ItemPicker, base_assigns(%{selected_item: item, photo_clickable: true}))

      assert html =~ "cursor-pointer"
    end
  end

  describe "photo_placeholder (opt-in no-photo placeholder)" do
    test "defaults to false: a photo-less selected item renders no placeholder (backward compatible)" do
      item = fake_item("item-1", "Oak Plank")

      html =
        render_component(ItemPicker, base_assigns(%{selected_item: item, photo_clickable: true}))

      refute html =~ "hero-photo"
      refute html =~ ~s(phx-click="photo_click")
    end

    test "photo_placeholder=true + photo_clickable=true renders a clickable placeholder for a photo-less selected item" do
      item = fake_item("item-1", "Oak Plank")

      html =
        render_component(
          ItemPicker,
          base_assigns(%{selected_item: item, photo_clickable: true, photo_placeholder: true})
        )

      assert html =~ "hero-photo"
      assert html =~ ~s(phx-click="photo_click")
      assert html =~ "cursor-pointer"
    end

    test "photo_placeholder=true without photo_clickable renders nothing (no click target to offer)" do
      item = fake_item("item-1", "Oak Plank")

      html =
        render_component(
          ItemPicker,
          base_assigns(%{selected_item: item, photo_clickable: false, photo_placeholder: true})
        )

      refute html =~ "hero-photo"
    end

    test "photo_placeholder=true with nothing selected renders nothing" do
      html =
        render_component(
          ItemPicker,
          base_assigns(%{photo_clickable: true, photo_placeholder: true})
        )

      refute html =~ "hero-photo"
    end

    test "photo_placeholder=true does not change rendering for a selected item WITH a photo" do
      item = %{
        fake_item("item-1", "Oak Plank")
        | data: %{"featured_image_uuid" => "photo-uuid-abc"}
      }

      with_placeholder =
        render_component(
          ItemPicker,
          base_assigns(%{selected_item: item, photo_clickable: true, photo_placeholder: true})
        )

      without_placeholder =
        render_component(
          ItemPicker,
          base_assigns(%{selected_item: item, photo_clickable: true, photo_placeholder: false})
        )

      refute with_placeholder =~ "hero-photo"
      assert with_placeholder == without_placeholder
    end
  end

  describe "photo_size (thumbnail/placeholder size override)" do
    test "defaults to w-8 h-8, rendering byte-for-byte as before the attribute existed" do
      item = %{
        fake_item("item-1", "Oak Plank")
        | data: %{"featured_image_uuid" => "photo-uuid-abc"}
      }

      html = render_component(ItemPicker, base_assigns(%{selected_item: item}))

      assert html =~
               ~s(class="w-8 h-8 shrink-0 rounded object-cover bg-base-200 border border-base-300")
    end

    test "a custom photo_size overrides the thumbnail size" do
      item = %{
        fake_item("item-1", "Oak Plank")
        | data: %{"featured_image_uuid" => "photo-uuid-abc"}
      }

      html =
        render_component(
          ItemPicker,
          base_assigns(%{selected_item: item, photo_size: "w-16 h-16"})
        )

      assert html =~
               ~s(class="w-16 h-16 shrink-0 rounded object-cover bg-base-200 border border-base-300")

      refute html =~
               ~s(class="w-8 h-8 shrink-0 rounded object-cover bg-base-200 border border-base-300")
    end

    test "a custom photo_size also sizes the placeholder" do
      item = fake_item("item-1", "Oak Plank")

      html =
        render_component(
          ItemPicker,
          base_assigns(%{
            selected_item: item,
            photo_clickable: true,
            photo_placeholder: true,
            photo_size: "w-16 h-16"
          })
        )

      assert html =~ "w-16 h-16"
    end

    # A088: the placeholder's own box (excluding padding) must match the
    # image's box byte-for-byte at every photo_size — NOT merely "changes
    # when photo_size changes", which is also true on the buggy code (the
    # placeholder carried an extra `p-1.5` that shrinks its visible box by
    # 12px relative to the image, at every size). Asserting the full class
    # string — img minus `object-cover`, placeholder minus `p-1.5
    # opacity-40` — is the only check that distinguishes "same box" from
    # "some box that also happens to scale".
    test "the placeholder box matches the image box exactly at the default photo_size" do
      item_with_photo = %{
        fake_item("item-1", "Oak Plank")
        | data: %{"featured_image_uuid" => "photo-uuid-abc"}
      }

      item_without_photo = fake_item("item-2", "Pine Plank")

      img_html = render_component(ItemPicker, base_assigns(%{selected_item: item_with_photo}))

      placeholder_html =
        render_component(
          ItemPicker,
          base_assigns(%{
            selected_item: item_without_photo,
            photo_clickable: true,
            photo_placeholder: true
          })
        )

      assert img_html =~
               ~s(class="w-8 h-8 shrink-0 rounded object-cover bg-base-200 border border-base-300")

      assert placeholder_html =~
               ~s(class="hero-photo w-8 h-8 shrink-0 rounded bg-base-200 border border-base-300 opacity-40")
    end

    test "the placeholder box matches the image box exactly at a non-default photo_size" do
      item_with_photo = %{
        fake_item("item-1", "Oak Plank")
        | data: %{"featured_image_uuid" => "photo-uuid-abc"}
      }

      item_without_photo = fake_item("item-2", "Pine Plank")

      img_html =
        render_component(
          ItemPicker,
          base_assigns(%{selected_item: item_with_photo, photo_size: "w-20 h-20"})
        )

      placeholder_html =
        render_component(
          ItemPicker,
          base_assigns(%{
            selected_item: item_without_photo,
            photo_clickable: true,
            photo_placeholder: true,
            photo_size: "w-20 h-20"
          })
        )

      assert img_html =~
               ~s(class="w-20 h-20 shrink-0 rounded object-cover bg-base-200 border border-base-300")

      assert placeholder_html =~
               ~s(class="hero-photo w-20 h-20 shrink-0 rounded bg-base-200 border border-base-300 opacity-40")
    end
  end

  describe "photo_asset_type (storage variant override)" do
    test "defaults to \"thumbnail\", rendering byte-for-byte as before the attribute existed" do
      item = %{
        fake_item("item-1", "Oak Plank")
        | data: %{"featured_image_uuid" => "photo-uuid-abc"}
      }

      html = render_component(ItemPicker, base_assigns(%{selected_item: item}))

      assert html =~ "/photo-uuid-abc/thumbnail/"
    end

    test "a custom photo_asset_type changes the signed URL's variant segment" do
      item = %{
        fake_item("item-1", "Oak Plank")
        | data: %{"featured_image_uuid" => "photo-uuid-abc"}
      }

      html =
        render_component(
          ItemPicker,
          base_assigns(%{selected_item: item, photo_asset_type: "medium"})
        )

      assert html =~ "/photo-uuid-abc/medium/"
      refute html =~ "/photo-uuid-abc/thumbnail/"
    end
  end

  describe "show_photo (programmatically force the placeholder for every selected item)" do
    test "show_photo: false + item WITH a photo + photo_clickable: true renders the clickable placeholder, not the real image" do
      item = %{
        fake_item("item-1", "Oak Plank")
        | data: %{"featured_image_uuid" => "photo-uuid-abc"}
      }

      html =
        render_component(
          ItemPicker,
          base_assigns(%{selected_item: item, photo_clickable: true, show_photo: false})
        )

      refute html =~ "<img"
      assert html =~ "hero-photo"
      assert html =~ ~s(phx-click="photo_click")
    end

    test "show_photo: false + item WITHOUT a photo + photo_clickable: true also renders the clickable placeholder" do
      item = fake_item("item-1", "Oak Plank")

      html =
        render_component(
          ItemPicker,
          base_assigns(%{selected_item: item, photo_clickable: true, show_photo: false})
        )

      refute html =~ "<img"
      assert html =~ "hero-photo"
      assert html =~ ~s(phx-click="photo_click")
    end

    test "show_photo: false with photo_clickable: false renders nothing clickable (no click target to offer)" do
      item = %{
        fake_item("item-1", "Oak Plank")
        | data: %{"featured_image_uuid" => "photo-uuid-abc"}
      }

      html =
        render_component(
          ItemPicker,
          base_assigns(%{selected_item: item, photo_clickable: false, show_photo: false})
        )

      refute html =~ "<img"
      refute html =~ "hero-photo"
      refute html =~ ~s(phx-click="photo_click")
    end

    test "show_photo: true (explicit) renders identically to the default for an item with a photo" do
      item = %{
        fake_item("item-1", "Oak Plank")
        | data: %{"featured_image_uuid" => "photo-uuid-abc"}
      }

      default_html =
        render_component(ItemPicker, base_assigns(%{selected_item: item, photo_clickable: true}))

      explicit_html =
        render_component(
          ItemPicker,
          base_assigns(%{selected_item: item, photo_clickable: true, show_photo: true})
        )

      assert default_html == explicit_html
    end

    # A caller can pass an explicit `nil` (not merely omit the attr) — e.g.
    # `show_photo={@maybe_nil}` — and `update/2` assigns it as-is. The
    # placeholder condition must treat that the same as the documented
    # `true` default (nothing forced), not as `false` (hide) — `!nil` and
    # `nil == false` disagree, which is exactly the gap this pins down.
    test "show_photo: nil (explicit) behaves like the true default — a photo-less item without photo_placeholder renders nothing" do
      item = fake_item("item-1", "Oak Plank")

      html =
        render_component(
          ItemPicker,
          base_assigns(%{selected_item: item, photo_clickable: true, show_photo: nil})
        )

      refute html =~ "hero-photo"
      refute html =~ "<img"
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

  # The wrapper in `components.ex` and the LiveComponent are two layers: an
  # attribute declared on the wrapper but not passed down is accepted from the
  # caller and silently dropped. Every render test above goes straight to the
  # LiveComponent, so none of them can see that gap — it shipped unnoticed
  # twice. This checks the two layers agree at the source level.
  describe "wrapper forwards every declared attribute" do
    test "each attr/2 on item_picker/1 is passed to the live_component" do
      source = File.read!("lib/phoenix_kit_catalogue/web/components.ex")

      [_, block] = String.split(source, "  def item_picker(assigns) do", parts: 2)
      [call, _] = String.split(block, "\n  end", parts: 2)

      [_, attr_block] =
        String.split(source, "  attr(:id, :string, required: true)", parts: 2)

      declared =
        attr_block
        |> String.split("  def item_picker(assigns) do", parts: 2)
        |> hd()
        |> then(&Regex.scan(~r/attr\(:(\w+),/, &1))
        |> Enum.map(fn [_, name] -> name end)

      missing = Enum.reject(declared, &String.contains?(call, "#{&1}={@#{&1}}"))

      assert missing == [],
             "declared on the wrapper but never forwarded to the LiveComponent: " <>
               Enum.join(missing, ", ")
    end
  end
end
