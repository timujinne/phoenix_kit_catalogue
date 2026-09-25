defmodule PhoenixKitCatalogue.Web.ItemFormLiveTest do
  @moduledoc """
  End-to-end LiveView tests for ItemFormLive. Drives the form through
  Phoenix.LiveViewTest so form params arrive as real string-keyed
  maps (the exact shape that caused the mixed-key CastError we hit in
  production).
  """
  use PhoenixKitCatalogue.LiveCase

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.SupplierFields
  alias PhoenixKitCatalogue.Schemas.Item
  alias PhoenixKitCatalogue.Test.Repo, as: TestRepo
  alias PhoenixKitCatalogue.Web.SupplierDraft

  # ─────────────────────────────────────────────────────────────────
  # Helpers
  # ─────────────────────────────────────────────────────────────────

  @base "/en/admin/catalogue"

  describe "crafted payloads (review sweep, 2026-09-12)" do
    test "a non-string choice index cannot crash the form (sweep 2026-09-13)", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Idx Cat"})
      item = fixture_item(%{name: "Idx", catalogue_uuid: catalogue.uuid})
      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

      render_click(view, "remove_supplier_field_choice", %{"index" => 0})
      render_click(view, "remove_supplier_field_choice", %{"index" => %{"x" => 1}})
      render_click(view, "remove_supplier_field_choice", %{})
      assert Process.alive?(view.pid)
    end

    test "a create cannot seed data keys the form does not own (sweep 2026-09-13)", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Seed Cat"})
      {:ok, view, _html} = live(conn, new_item_url(catalogue.uuid))

      render_submit(view, "save", %{
        "item" => %{
          "name" => "Seeded",
          "data" => %{
            "_translation_fingerprints" => %{"de" => %{"name" => "deadbeef"}},
            "evil" => "x"
          }
        },
        "save_action" => "exit"
      })

      item =
        Catalogue.list_items_for_catalogue(catalogue.uuid) |> Enum.find(&(&1.name == "Seeded"))

      assert item
      refute Map.has_key?(item.data || %{}, "_translation_fingerprints")
      refute Map.has_key?(item.data || %{}, "evil")
    end

    # Location owns where the item lives; a category in the payload is not
    # a field the form renders, so it is dropped — whatever its shape.
    test "a category_uuid in the payload is ignored, not crashed on", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Scope Cat"})
      item = fixture_item(%{name: "Scoped", catalogue_uuid: catalogue.uuid})
      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

      render_submit(view, "save", %{
        "item" => %{"name" => "Renamed", "category_uuid" => %{"x" => "1"}},
        "save_action" => "stay"
      })

      assert Process.alive?(view.pid)
      saved = Catalogue.get_item!(item.uuid)
      assert saved.name == "Renamed"
      assert is_nil(saved.category_uuid)
    end
  end

  defp new_item_url(catalogue_uuid), do: "#{@base}/#{catalogue_uuid}/items/new"
  defp edit_item_url(item_uuid), do: "#{@base}/items/#{item_uuid}/edit"

  defp catalogue_detail_url(catalogue_uuid), do: "#{@base}/#{catalogue_uuid}"

  # The Location picker is core's TreePicker. A pick goes to the picker's
  # own event (its search box carries the hook and the target), which takes
  # only a row its tree offers — the path a click on a row takes too, so a
  # forged target is checked the same way.
  defp pick_place(view, target),
    do: view |> element("#location-tree-picker-search") |> render_hook("pick", %{"id" => target})

  defp search_places(view, text),
    do:
      view |> element("#location-tree-picker-search") |> render_hook("search", %{"value" => text})

  defp base_item_params(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "Oak Panel",
        "description" => "",
        "sku" => "",
        "base_price" => "25.50",
        "unit" => "piece",
        "manufacturer_uuid" => "",
        "status" => "active"
      },
      overrides
    )
  end

  # ─────────────────────────────────────────────────────────────────
  # :new action
  # ─────────────────────────────────────────────────────────────────

  describe "new item — mount and render" do
    test "mounts with a catalogue_uuid and renders the form", %{conn: conn} do
      catalogue = fixture_catalogue()

      {:ok, _view, html} = live(conn, new_item_url(catalogue.uuid))

      assert html =~ "New item"
      assert html =~ ~s(name="item[name]")
      assert html =~ ~s(name="item[base_price]")
    end

    test "Location starts at the catalogue and offers its categories", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Kitchen"})
      fixture_category(catalogue, %{name: "Frames"})
      fixture_category(catalogue, %{name: "Hinges"})

      {:ok, view, _html} = live(conn, new_item_url(catalogue.uuid))

      assert view |> element("#item-location-path") |> render() =~ "Kitchen"

      tree = render_click(view, "open_location_picker", %{})
      assert tree =~ "Frames"
      assert tree =~ "Hinges"
    end
  end

  describe "new item — unit select" do
    test "renders both optgroups with every unit code, including pair and sheet", %{conn: conn} do
      catalogue = fixture_catalogue()
      {:ok, _view, html} = live(conn, new_item_url(catalogue.uuid))

      document = LazyHTML.from_fragment(html)
      unit_select = LazyHTML.query(document, "select#item_unit")

      optgroup_labels =
        unit_select
        |> LazyHTML.query("optgroup")
        |> LazyHTML.attribute("label")

      assert length(optgroup_labels) == 2

      option_values =
        unit_select
        |> LazyHTML.query("option")
        |> LazyHTML.attribute("value")

      for unit <- Item.allowed_units() do
        assert unit in option_values, "expected #{unit} to be a selectable option"
      end

      assert "pair" in option_values
      assert "sheet" in option_values
    end
  end

  describe "new item — validate" do
    test "shows name error when name is blank", %{conn: conn} do
      catalogue = fixture_catalogue()
      {:ok, view, _html} = live(conn, new_item_url(catalogue.uuid))

      html =
        view
        |> form("form[action=\"#\"][phx-submit=save]", %{
          "item" => base_item_params(%{"name" => ""})
        })
        |> render_change()

      # The exact error wording comes from gettext; assert the field is
      # flagged via the form's error class.
      assert html =~ "error" or html =~ "blank"
    end

    test "accepts a valid input shape without raising", %{conn: conn} do
      catalogue = fixture_catalogue()
      {:ok, view, _html} = live(conn, new_item_url(catalogue.uuid))

      html =
        view
        |> form("form[action=\"#\"][phx-submit=save]", %{"item" => base_item_params()})
        |> render_change()

      assert html =~ "Oak Panel"
    end
  end

  describe "new item — save" do
    test "saves and redirects with string-keyed form params (regression)", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue, %{name: "Frames"})

      {:ok, view, _html} = live(conn, new_item_url(catalogue.uuid))

      render_click(view, "open_location_picker", %{})
      pick_place(view, "category:" <> category.uuid)

      {:error, {:live_redirect, %{to: to}}} =
        view
        |> form("form[action=\"#\"][phx-submit=save]", %{"item" => base_item_params()})
        |> render_submit()

      # After create the LiveView navigates to the catalogue detail.
      assert to == catalogue_detail_url(catalogue.uuid)

      # Verify the item actually landed with the right derived catalogue.
      [item] = TestRepo.all(Item)
      assert item.name == "Oak Panel"
      assert item.category_uuid == category.uuid
      assert item.catalogue_uuid == catalogue.uuid
    end

    test "a comma or dot decimal in price/markup/discount lands unrounded", %{conn: conn} do
      catalogue = fixture_catalogue(%{kind: "standard"})
      {:ok, view, _html} = live(conn, new_item_url(catalogue.uuid))

      {:error, {:live_redirect, _}} =
        view
        |> form("form[action=\"#\"][phx-submit=save]", %{
          "item" =>
            base_item_params(%{
              "name" => "Comma Item",
              "base_price" => "25,5",
              # markup/discount_percentage are `numeric(7,2)` columns — two
              # decimal places is the field's own ceiling, not something
              # this migration changes; the comma is what's under test.
              "markup_percentage" => "0,12",
              "discount_percentage" => "3,25"
            })
        })
        |> render_submit()

      [item] = TestRepo.all(Item)
      assert Decimal.equal?(item.base_price, Decimal.new("25.5"))
      assert Decimal.equal?(item.markup_percentage, Decimal.new("0.12"))
      assert Decimal.equal?(item.discount_percentage, Decimal.new("3.25"))
    end

    test "a comma or dot decimal in a smart catalogue's default value lands unrounded",
         %{conn: conn} do
      catalogue = fixture_catalogue(%{kind: "smart"})
      {:ok, view, _html} = live(conn, new_item_url(catalogue.uuid))

      {:error, {:live_redirect, _}} =
        view
        |> form("form[action=\"#\"][phx-submit=save]", %{
          "item" => %{
            "name" => "Smart Comma Item",
            "status" => "active",
            "default_value" => "1,5"
          }
        })
        |> render_submit()

      [item] = TestRepo.all(Item)
      assert Decimal.equal?(item.default_value, Decimal.new("1.5"))
    end

    test "garbage in base_price is rejected exactly as before", %{conn: conn} do
      catalogue = fixture_catalogue(%{kind: "standard"})
      {:ok, view, _html} = live(conn, new_item_url(catalogue.uuid))

      html =
        render_submit(view, "save", %{
          "item" => base_item_params(%{"name" => "Bad Price", "base_price" => "abc"})
        })

      assert html =~ "New item"
      assert TestRepo.all(Item) == []
    end

    test "a forged catalogue_uuid cannot file the item under another catalogue",
         %{conn: conn} do
      catalogue = fixture_catalogue()
      other = fixture_catalogue()

      {:ok, view, _html} = live(conn, new_item_url(catalogue.uuid))

      # Driven as a raw event, not through `form/3`: the point of the fix is
      # that a LiveView event is not bound by the markup that produced it,
      # and `form/3` refuses to send anything the rendered form does not
      # offer. A forged submit does not come from the form.
      {:error, {:live_redirect, _}} =
        render_submit(view, "save", %{
          "item" => base_item_params(%{"name" => "Forged", "catalogue_uuid" => other.uuid})
        })

      [item] = TestRepo.all(Item)
      assert item.catalogue_uuid == catalogue.uuid
      refute item.catalogue_uuid == other.uuid
    end

    # The longer route to the catalogue: `derive_catalogue_uuid/2` copies a
    # CATEGORY's catalogue over whatever the server set, so a forged
    # category_uuid would beat the scope pin. Location owns the place, and
    # the payload's category is dropped.
    test "a forged category from another catalogue is not followed", %{conn: conn} do
      catalogue = fixture_catalogue()
      other = fixture_catalogue()
      foreign_category = fixture_category(other, %{name: "Elsewhere"})

      {:ok, view, _html} = live(conn, new_item_url(catalogue.uuid))

      {:error, {:live_redirect, _}} =
        render_submit(view, "save", %{
          "item" =>
            base_item_params(%{
              "name" => "Smuggled",
              "category_uuid" => foreign_category.uuid
            })
        })

      [item] = TestRepo.all(Item)
      assert item.catalogue_uuid == catalogue.uuid
      assert is_nil(item.category_uuid)
    end

    test "a new item is created where Location says, even in another catalogue",
         %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Opened here"})
      other = fixture_catalogue(%{name: "Filed there"})
      target = fixture_category(other, %{name: "Shelves"})

      {:ok, view, _html} = live(conn, new_item_url(catalogue.uuid))

      render_click(view, "open_location_picker", %{})
      pick_place(view, "category:" <> target.uuid)

      assert view |> element("#item-location-path") |> render() =~ "Filed there"

      {:error, {:live_redirect, _}} =
        render_submit(view, "save", %{"item" => base_item_params(%{"name" => "Placed"})})

      [item] = TestRepo.all(Item)
      assert item.catalogue_uuid == other.uuid
      assert item.category_uuid == target.uuid
    end

    test "a place trashed after it was picked stops the create with a message",
         %{conn: conn} do
      catalogue = fixture_catalogue()
      target = fixture_category(catalogue, %{name: "Doomed"})

      {:ok, view, _html} = live(conn, new_item_url(catalogue.uuid))

      render_click(view, "open_location_picker", %{})
      pick_place(view, "category:" <> target.uuid)
      {:ok, _} = Catalogue.trash_category(target)

      html = render_submit(view, "save", %{"item" => base_item_params(%{"name" => "Homeless"})})

      assert html =~ "That location no longer exists."
      assert TestRepo.all(Item) == []
    end

    test "saves an uncategorized item (empty category_uuid)", %{conn: conn} do
      catalogue = fixture_catalogue()
      {:ok, view, _html} = live(conn, new_item_url(catalogue.uuid))

      {:error, {:live_redirect, _}} =
        view
        |> form("form[action=\"#\"][phx-submit=save]", %{
          "item" => base_item_params(%{"name" => "Loose item"})
        })
        |> render_submit()

      [item] = TestRepo.all(Item)
      assert item.catalogue_uuid == catalogue.uuid
      assert is_nil(item.category_uuid)
    end

    test "re-renders the form with errors on invalid submit and preserves typed input", %{
      conn: conn
    } do
      catalogue = fixture_catalogue()
      {:ok, view, _html} = live(conn, new_item_url(catalogue.uuid))

      html =
        view
        |> form("form[action=\"#\"][phx-submit=save]", %{
          "item" => base_item_params(%{"name" => "", "sku" => "user-typed-sku"})
        })
        |> render_submit()

      # Still on the form — no redirect.
      assert html =~ "New item"
      # User's typed SKU is still in the input so they don't lose work.
      assert html =~ "user-typed-sku"
      # And nothing got written.
      assert TestRepo.all(Item) == []
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # :edit action
  # ─────────────────────────────────────────────────────────────────

  describe "edit item" do
    test "mounts with an existing item's values filled in", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)

      {:ok, item} =
        Catalogue.create_item(%{
          name: "Oak Panel",
          sku: "OAK-18",
          base_price: "25.50",
          category_uuid: category.uuid
        })

      {:ok, _view, html} = live(conn, edit_item_url(item.uuid))

      assert html =~ "Oak Panel"
      assert html =~ "OAK-18"
    end

    test "a forged catalogue_uuid cannot move an uncategorized item on edit",
         %{conn: conn} do
      catalogue = fixture_catalogue()
      other = fixture_catalogue()

      # UNCATEGORIZED on purpose: `derive_catalogue_uuid/2` overrides the
      # field from the item's category, but with no category
      # `put_catalogue_from_effective_category(attrs, nil)` returns attrs
      # untouched — so nothing on the edit path contradicted a forged value.
      # That is every smart item and every loose standard one.
      item = fixture_item(%{name: "Loose", catalogue_uuid: catalogue.uuid})

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

      render_submit(view, "save", %{
        "item" =>
          base_item_params(%{
            "name" => "Loose",
            "category_uuid" => "",
            "catalogue_uuid" => other.uuid
          })
      })

      reloaded = Catalogue.get_item(item.uuid)
      assert reloaded.catalogue_uuid == catalogue.uuid
      refute reloaded.catalogue_uuid == other.uuid
    end

    test "save updates the item and redirects back to its catalogue", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      item = fixture_item(%{name: "Old name", category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

      {:error, {:live_redirect, %{to: to}}} =
        view
        |> form("form[action=\"#\"][phx-submit=save]", %{
          "item" => base_item_params(%{"name" => "New name"})
        })
        |> render_submit()

      assert to == catalogue_detail_url(catalogue.uuid)
      reloaded = Catalogue.get_item(item.uuid)
      assert reloaded.name == "New name"
    end

    # NOTE: cross-catalogue category changes via the in-form category
    # dropdown aren't possible — the dropdown only lists categories
    # within the item's current catalogue. Users cross catalogues via
    # the move_item flow (see the "move_item" describe block below),
    # which invokes `Catalogue.move_item_to_category/3` directly. The
    # string-keyed form-params derivation path is covered by the
    # "regression" tests in catalogue_test.exs at the context level.

    test "regression: saving with empty-string manufacturer_uuid doesn't crash", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      item = fixture_item(%{name: "X", category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

      {:error, {:live_redirect, _}} =
        view
        |> form("form[action=\"#\"][phx-submit=save]", %{
          "item" =>
            base_item_params(%{
              "name" => "X",
              "manufacturer_uuid" => ""
            })
        })
        |> render_submit()

      reloaded = Catalogue.get_item(item.uuid)
      assert is_nil(reloaded.manufacturer_uuid)
    end

    test "redirects to index if the item doesn't exist", %{conn: conn} do
      bogus_uuid = "00000000-0000-0000-0000-000000000000"

      {:error, {:live_redirect, %{to: to}}} =
        live(conn, edit_item_url(bogus_uuid))

      assert to == @base
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Suppliers card (item_supplier_info)
  # ─────────────────────────────────────────────────────────────────

  # 2026-09-19 (boss): the PDF search left the bottom of the form (a
  # "Search PDFs" button under the Save row) for a tab of its own, with a
  # search box in case the exact name does not match.
  describe "PDFs tab" do
    test "the old button is gone and the tab searches only once opened", %{conn: conn} do
      item =
        fixture_item(%{
          name: "Oak Panel",
          category_uuid: fixture_category(fixture_catalogue()).uuid
        })

      {:ok, view, html} = live(conn, edit_item_url(item.uuid))

      refute html =~ "Find this item in PDFs"
      refute html =~ "open_pdf_search"
      assert has_element?(view, ~s(button[phx-value-tab="pdfs"]))
      refute has_element?(view, "#item-pdf-search")

      render_click(view, "switch_tab", %{"tab" => "pdfs"})

      # The box starts with the item's name and has already searched it.
      assert view |> element("#item-pdf-search input[name=q]") |> render() =~
               ~s(value="Oak Panel")

      assert render(view) =~ "No PDF mentions this item by name."

      # Another tab and back: still mounted, still the same search.
      render_click(view, "switch_tab", %{"tab" => "details"})
      assert has_element?(view, "#item-pdf-search")
    end

    test "editing the box searches the library for what was typed", %{conn: conn} do
      item =
        fixture_item(%{
          name: "Oak Panel",
          category_uuid: fixture_category(fixture_catalogue()).uuid
        })

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))
      render_click(view, "switch_tab", %{"tab" => "pdfs"})

      html =
        view
        |> element("#item-pdf-search-query-form")
        |> render_change(%{"q" => "walnut veneer"})

      assert html =~ "No pages match your search."

      # Putting the name back is the item search again.
      html =
        view
        |> element("#item-pdf-search-query-form")
        |> render_change(%{"q" => "Oak Panel"})

      assert html =~ "No PDF mentions this item by name."
    end

    test "saving the item under a new name searches the new name", %{conn: conn} do
      item =
        fixture_item(%{
          name: "Oak Panel",
          category_uuid: fixture_category(fixture_catalogue()).uuid
        })

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))
      render_click(view, "switch_tab", %{"tab" => "pdfs"})

      render_submit(view, "save", %{
        "item" => %{"name" => "Walnut Panel"},
        "save_action" => "stay"
      })

      assert Catalogue.get_item!(item.uuid).name == "Walnut Panel"

      assert view |> element("#item-pdf-search input[name=q]") |> render() =~
               ~s(value="Walnut Panel")
    end

    test "a typed query survives a rename", %{conn: conn} do
      item =
        fixture_item(%{
          name: "Oak Panel",
          category_uuid: fixture_category(fixture_catalogue()).uuid
        })

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))
      render_click(view, "switch_tab", %{"tab" => "pdfs"})

      view
      |> element("#item-pdf-search-query-form")
      |> render_change(%{"q" => "walnut veneer"})

      render_submit(view, "save", %{
        "item" => %{"name" => "Walnut Panel"},
        "save_action" => "stay"
      })

      assert view |> element("#item-pdf-search input[name=q]") |> render() =~
               ~s(value="walnut veneer")

      assert render(view) =~ "No pages match your search."
    end

    test "show more from results a newer search replaced is a no-op", %{conn: conn} do
      item =
        fixture_item(%{
          name: "Oak Panel",
          category_uuid: fixture_category(fixture_catalogue()).uuid
        })

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))
      render_click(view, "switch_tab", %{"tab" => "pdfs"})

      view
      |> with_target("#item-pdf-search")
      |> render_click("show_more", %{"pdf_uuid" => Ecto.UUID.generate()})

      assert Process.alive?(view.pid)
      assert has_element?(view, "#item-pdf-search input[name=q]")
    end

    test "a ?tab=pdfs link opens the tab with its search", %{conn: conn} do
      item =
        fixture_item(%{
          name: "Oak Panel",
          category_uuid: fixture_category(fixture_catalogue()).uuid
        })

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid) <> "?tab=pdfs")

      assert has_element?(view, "#item-pdf-search input[name=q]")
    end

    test "a new item has no PDFs tab", %{conn: conn} do
      catalogue = fixture_catalogue()
      {:ok, view, _html} = live(conn, "#{@base}/#{catalogue.uuid}/items/new")
      refute has_element?(view, ~s(button[phx-value-tab="pdfs"]))
    end

    test "a new item sent to ?tab=pdfs lands on Details, not an empty form", %{conn: conn} do
      catalogue = fixture_catalogue()
      {:ok, view, _html} = live(conn, "#{@base}/#{catalogue.uuid}/items/new?tab=pdfs")
      assert has_element?(view, ~s(button.tab-active[phx-value-tab="details"]))

      render_click(view, "switch_tab", %{"tab" => "pdfs"})
      assert has_element?(view, ~s(button.tab-active[phx-value-tab="details"]))
    end
  end

  # Max, 2026-09-19: picking a supplier is enough to add it, the cost is
  # edited straight in the table, and the item's Save commits it all —
  # adds, costs, removes and the primary alike.
  describe "suppliers, staged until Save" do
    defp supplier_item do
      fixture_item(%{
        name: "Oak Panel",
        category_uuid: fixture_category(fixture_catalogue()).uuid
      })
    end

    defp pick_supplier(view, supplier_uuid) do
      view
      |> element("#supplier-add-picker")
      |> render_change(%{"supplier_add" => supplier_uuid})
    end

    defp save_suppliers(view, rows \\ %{}, mode \\ "stay") do
      render_submit(view, "save", %{
        "item" => %{"name" => "Oak Panel"},
        "supplier_rows" => rows,
        "save_action" => mode
      })
    end

    defp saved_row(item, supplier, attrs \\ %{}) do
      {:ok, info} =
        Catalogue.create_supplier_info(
          Map.merge(
            %{
              "item_uuid" => item.uuid,
              "supplier_uuid" => supplier.uuid,
              "supplier_source" => "local"
            },
            attrs
          )
        )

      info
    end

    test "picking a supplier adds its row at once, and Save writes it",
         %{conn: conn, scope: scope} do
      item = supplier_item()
      supplier = fixture_supplier()

      {:ok, view, _html} = conn |> with_scope(scope) |> live(edit_item_url(item.uuid))

      html = pick_supplier(view, supplier.uuid)

      assert has_element?(view, "#supplier-row-#{supplier.uuid}")
      assert html =~ "Unsaved changes"
      # Nothing written yet.
      assert Catalogue.list_supplier_infos_for_item(item.uuid) == []
      # The picked supplier is no longer offered; the picker is back on its
      # placeholder.
      refute view |> element("#supplier-add-picker") |> render() =~ supplier.uuid

      save_suppliers(view)

      [info] = Catalogue.list_supplier_infos_for_item(item.uuid)
      assert info.supplier_uuid == supplier.uuid
      # The first supplier on an item is its primary.
      assert info.is_primary

      assert_activity_logged("item_supplier_info.created",
        resource_uuid: info.uuid,
        actor_uuid: scope.user.uuid,
        metadata_has: %{"item_uuid" => item.uuid}
      )

      refute render(view) =~ "Unsaved changes"
    end

    test "the cost is typed in the row, through the item form, and saved exactly",
         %{conn: conn} do
      item = supplier_item()
      supplier = fixture_supplier()

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))
      pick_supplier(view, supplier.uuid)

      row = %{supplier.uuid => %{"unit_cost" => "5.1234", "currency" => "eur"}}

      view |> form("#item-form", %{"supplier_rows" => row}) |> render_change()
      assert Catalogue.list_supplier_infos_for_item(item.uuid) == []

      view |> form("#item-form", %{"supplier_rows" => row}) |> render_submit()

      [info] = Catalogue.list_supplier_infos_for_item(item.uuid)
      assert Decimal.to_string(info.unit_cost, :normal) == "5.1234"
      # Currency is upcased on the way in — the input is uppercase by CSS only.
      assert info.currency == "EUR"
    end

    # The price control comes from entities' `decimal` renderer, not a
    # hand-rolled number input — that is what keeps it exact.
    test "the row's price control is the entities decimal field", %{conn: conn} do
      item = supplier_item()
      supplier = fixture_supplier()

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))
      html = pick_supplier(view, supplier.uuid)

      [control] = Regex.run(~r/<input[^>]*id="supplier-cost-#{supplier.uuid}"[^>]*>/, html)
      assert control =~ ~s(inputmode="decimal")
      assert control =~ ~s(name="supplier_rows[#{supplier.uuid}][unit_cost]")
      refute control =~ ~s(type="number")
      refute control =~ "step="

      builtin = Catalogue.supplier_builtin_field("unit_cost")
      assert builtin["scale"] == 4
      assert builtin["type"] == "decimal"
    end

    test "a price that is not a number shows on the row and blocks the whole save",
         %{conn: conn} do
      item = supplier_item()
      supplier = fixture_supplier()

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))
      pick_supplier(view, supplier.uuid)

      html =
        view
        |> form("#item-form", %{"supplier_rows" => %{supplier.uuid => %{"unit_cost" => "abc"}}})
        |> render_change()

      assert html =~ "Unit cost must be a number."

      html =
        render_submit(view, "save", %{
          "item" => %{"name" => "Renamed"},
          "supplier_rows" => %{supplier.uuid => %{"unit_cost" => "abc"}},
          "save_action" => "exit"
        })

      assert html =~ "Some supplier values are not valid."
      assert Catalogue.list_supplier_infos_for_item(item.uuid) == []
      # The item's own fields waited too.
      assert Catalogue.get_item(item.uuid).name == "Oak Panel"
    end

    test "a currency that is not three letters is refused", %{conn: conn} do
      item = supplier_item()
      supplier = fixture_supplier()

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))
      pick_supplier(view, supplier.uuid)

      html = save_suppliers(view, %{supplier.uuid => %{"unit_cost" => "3", "currency" => "EURO"}})

      assert html =~ "Currency must be a three-letter code, like EUR."
      assert Catalogue.list_supplier_infos_for_item(item.uuid) == []
    end

    # A cost CHANGE closes the current row and opens a successor, which is
    # what feeds the History dialog — a plain overwrite would lose it.
    test "a new cost on a saved row is a price revision on Save", %{conn: conn} do
      item = supplier_item()
      supplier = fixture_supplier()
      saved_row(item, supplier, %{"unit_cost" => "10.00", "currency" => "EUR"})

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

      # The saved price shows without the column's trailing zeros.
      assert view |> element("#supplier-cost-#{supplier.uuid}") |> render() =~ ~s(value="10")

      save_suppliers(view, %{supplier.uuid => %{"unit_cost" => "12.50", "currency" => "EUR"}})

      [current] = Catalogue.list_supplier_infos_for_item(item.uuid)
      assert Decimal.equal?(current.unit_cost, Decimal.new("12.50"))

      history = Catalogue.supplier_info_history_for_pair(item.uuid, supplier.uuid)
      assert length(history) == 2
    end

    test "a row saved back unchanged writes nothing", %{conn: conn} do
      item = supplier_item()
      supplier = fixture_supplier()
      info = saved_row(item, supplier, %{"unit_cost" => "10.0000", "currency" => "EUR"})

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))
      save_suppliers(view, %{supplier.uuid => %{"unit_cost" => "10", "currency" => "eur"}})

      assert [%{uuid: uuid}] = Catalogue.list_supplier_infos_for_item(item.uuid)
      assert uuid == info.uuid
      assert length(Catalogue.supplier_info_history_for_pair(item.uuid, supplier.uuid)) == 1
    end

    test "a stored empty currency is not a change", %{conn: conn} do
      item = supplier_item()
      supplier = fixture_supplier()
      info = saved_row(item, supplier, %{"unit_cost" => "4"})

      # Only a raw write stores "" (the changeset casts it to nil).
      import Ecto.Query, only: [from: 2]

      TestRepo.update_all(
        from(i in PhoenixKitCatalogue.Schemas.ItemSupplierInfo, where: i.uuid == ^info.uuid),
        set: [currency: ""]
      )

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))
      refute render(view) =~ "Unsaved changes"

      save_suppliers(view, %{supplier.uuid => %{"unit_cost" => "4", "currency" => ""}})

      assert [%{uuid: uuid, currency: ""}] = Catalogue.list_supplier_infos_for_item(item.uuid)
      assert uuid == info.uuid
    end

    test "Remove waits for Save, and Undo takes it back", %{conn: conn} do
      item = supplier_item()
      supplier = fixture_supplier()
      saved_row(item, supplier)

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

      render_click(view, "stage_supplier_remove", %{"supplier" => supplier.uuid})

      assert has_element?(
               view,
               ~s(#supplier-row-#{supplier.uuid} button[phx-click="restore_supplier"])
             )

      assert [_] = Catalogue.list_supplier_infos_for_item(item.uuid)

      render_click(view, "restore_supplier", %{"supplier" => supplier.uuid})
      save_suppliers(view)
      assert [_] = Catalogue.list_supplier_infos_for_item(item.uuid)

      render_click(view, "stage_supplier_remove", %{"supplier" => supplier.uuid})
      save_suppliers(view)
      assert Catalogue.list_supplier_infos_for_item(item.uuid) == []
    end

    test "a staged row removed before Save is simply dropped", %{conn: conn} do
      item = supplier_item()
      supplier = fixture_supplier()

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))
      pick_supplier(view, supplier.uuid)
      render_click(view, "stage_supplier_remove", %{"supplier" => supplier.uuid})

      refute has_element?(view, "#supplier-row-#{supplier.uuid}")
      assert view |> element("#supplier-add-picker") |> render() =~ supplier.uuid

      save_suppliers(view)
      assert Catalogue.list_supplier_infos_for_item(item.uuid) == []
    end

    test "Make primary waits for Save", %{conn: conn} do
      item = supplier_item()
      first = fixture_supplier()
      second = fixture_supplier()
      saved_row(item, first)
      saved_row(item, second)

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

      render_click(view, "stage_supplier_primary", %{"supplier" => second.uuid})

      assert view |> element("#supplier-row-#{second.uuid}") |> render() =~ "badge-primary"
      refute view |> element("#supplier-row-#{first.uuid}") |> render() =~ "badge-primary"

      assert Enum.find(Catalogue.list_supplier_infos_for_item(item.uuid), & &1.is_primary).supplier_uuid ==
               first.uuid

      save_suppliers(view)

      assert Enum.find(Catalogue.list_supplier_infos_for_item(item.uuid), & &1.is_primary).supplier_uuid ==
               second.uuid
    end

    test "a supplier on the item, saved or staged, is not offered again", %{conn: conn} do
      item = supplier_item()
      linked = fixture_supplier()
      staged = fixture_supplier()
      other = fixture_supplier()
      saved_row(item, linked)

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))
      pick_supplier(view, staged.uuid)
      # A second pick of the same supplier (a forged or stale event) stages nothing new.
      render_change(view, "stage_supplier_add", %{"supplier_add" => staged.uuid})
      render_change(view, "stage_supplier_add", %{"supplier_add" => linked.uuid})

      picker = view |> element("#supplier-add-picker") |> render()
      refute picker =~ linked.uuid
      refute picker =~ staged.uuid
      assert picker =~ other.uuid

      assert :sys.get_state(view.pid).socket.assigns.supplier_draft.adds == [staged.uuid]
    end

    test "a supplier linked elsewhere meanwhile is reported, not doubled", %{conn: conn} do
      item = supplier_item()
      supplier = fixture_supplier()

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))
      pick_supplier(view, supplier.uuid)

      # Another session links the same supplier before this one saves; the
      # broadcast reaches the form, which drops the now-duplicate staged row.
      saved_row(item, supplier)
      _ = render(view)

      save_suppliers(view)
      assert [_] = Catalogue.list_supplier_infos_for_item(item.uuid)
    end

    test "a new item takes its staged suppliers when it is created", %{conn: conn} do
      catalogue = fixture_catalogue()
      supplier = fixture_supplier()

      {:ok, view, _html} = live(conn, new_item_url(catalogue.uuid))
      pick_supplier(view, supplier.uuid)

      {:error, {:live_redirect, _}} =
        render_submit(view, "save", %{
          "item" => base_item_params(%{"name" => "Born supplied"}),
          "supplier_rows" => %{supplier.uuid => %{"unit_cost" => "7", "currency" => "EUR"}}
        })

      [item] = TestRepo.all(Item)
      [info] = Catalogue.list_supplier_infos_for_item(item.uuid)
      assert info.supplier_uuid == supplier.uuid
      assert Decimal.equal?(info.unit_cost, Decimal.new("7"))
    end

    # Owner decisions 2026-08-21: SKU, lead time and MOQ stay behind
    # @supplier_terms_fields — their data and columns are untouched, and
    # the row dialog that edits them is reachable by its event.
    test "the row dialog stages the terms; Save writes them", %{conn: conn} do
      item = supplier_item()
      supplier = fixture_supplier()
      saved_row(item, supplier, %{"supplier_sku" => "OLD-1"})

      {:ok, view, html} = live(conn, edit_item_url(item.uuid))

      for field <- ~w(supplier_sku lead_time_days min_order_qty) do
        refute html =~ ~s([#{field}])
      end

      render_click(view, "edit_supplier_info", %{"supplier" => supplier.uuid})

      render_click(view, "save_supplier_info", %{
        "supplier_info" => %{
          "supplier_sku" => "NEW-2",
          "lead_time_days" => "5",
          "min_order_qty" => "2,5"
        }
      })

      assert [%{supplier_sku: "OLD-1"}] = Catalogue.list_supplier_infos_for_item(item.uuid)

      save_suppliers(view)

      [updated] = Catalogue.list_supplier_infos_for_item(item.uuid)
      assert updated.supplier_sku == "NEW-2"
      assert updated.lead_time_days == 5
      assert Decimal.equal?(updated.min_order_qty, Decimal.new("2.5"))
    end

    # The badge must mean "a save would write something". Re-staging a
    # row's own values is not a change: the dialog seeds itself from the
    # row, and Done sends that seed straight back.
    test "the row dialog closed without an edit leaves the row clean", %{conn: conn} do
      item = supplier_item()
      supplier = fixture_supplier()

      saved_row(item, supplier, %{
        "supplier_sku" => "OLD-1",
        "lead_time_days" => "5",
        "min_order_qty" => "2.5",
        "unit_cost" => "7",
        "currency" => "EUR"
      })

      {:ok, view, html} = live(conn, edit_item_url(item.uuid))
      refute html =~ "Unsaved changes"

      render_click(view, "edit_supplier_info", %{"supplier" => supplier.uuid})

      html =
        render_click(view, "save_supplier_info", %{
          "supplier_info" => %{
            "supplier_sku" => "OLD-1",
            "lead_time_days" => "5",
            "min_order_qty" => "2.5",
            "unit_cost" => "7",
            "currency" => "EUR"
          }
        })

      refute html =~ "Unsaved changes"

      state = :sys.get_state(view.pid).socket.assigns
      refute SupplierDraft.dirty?(state.supplier_draft, state.supplier_infos)
    end

    test "garbage in the row dialog stays in the dialog", %{conn: conn} do
      item = supplier_item()
      supplier = fixture_supplier()
      saved_row(item, supplier)

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))
      render_click(view, "edit_supplier_info", %{"supplier" => supplier.uuid})

      html =
        render_click(view, "save_supplier_info", %{
          "supplier_info" => %{"min_order_qty" => "abc"}
        })

      assert html =~ "Could not save the supplier."
      assert :sys.get_state(view.pid).socket.assigns.supplier_draft.values == %{}
    end

    # Scope the lookup to the rows this item actually shows: a uuid from a
    # crafted payload must not reach another item's supplier row.
    test "staging events for a supplier the item does not hold do nothing", %{conn: conn} do
      item = supplier_item()
      other_item = supplier_item()
      supplier = fixture_supplier()
      saved_row(other_item, supplier)

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

      render_click(view, "stage_supplier_remove", %{"supplier" => supplier.uuid})
      render_click(view, "stage_supplier_primary", %{"supplier" => supplier.uuid})
      render_click(view, "edit_supplier_info", %{"supplier" => supplier.uuid})

      render_change(view, "validate", %{
        "supplier_rows" => %{supplier.uuid => %{"unit_cost" => "1"}}
      })

      assert :sys.get_state(view.pid).socket.assigns.supplier_draft == SupplierDraft.new()

      assert :sys.get_state(view.pid).socket.assigns.supplier_form == nil
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Supplier custom fields — HIDDEN (owner decision 2026-08-21)
  #
  # The feature is intact behind ItemFormLive's @supplier_custom_fields
  # flag; its context is covered by supplier_fields_test.exs. These pin
  # what SHIPS: nothing entity-shaped reaches the supplier UI, and data
  # already written survives untouched so a restore brings it back.
  # ─────────────────────────────────────────────────────────────────

  if Code.ensure_loaded?(PhoenixKitEntities.Managed) do
    describe "supplier custom fields (hidden)" do
      setup do
        SupplierFields.startup()
        PhoenixKit.Settings.update_setting("entities_enabled", "true")
        on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)
        :ok
      end

      test "a defined field reaches neither the table nor the modal", %{conn: conn} do
        item =
          fixture_item(%{
            name: "Oak Panel",
            category_uuid: fixture_category(fixture_catalogue()).uuid
          })

        supplier = fixture_supplier()
        {:ok, _} = Catalogue.add_supplier_field(%{label: "Incoterm", type: "text"})

        {:ok, view, html} = live(conn, edit_item_url(item.uuid))

        # No manager affordance, and no column for the defined field.
        refute html =~ "open_supplier_field_manager"
        refute html =~ "Incoterm"

        # A picked supplier's row carries no extra-field column or input,
        # and no row dialog to reach one.
        fields_html =
          view
          |> element("#supplier-add-picker")
          |> render_change(%{"supplier_add" => supplier.uuid})

        refute fields_html =~ "Incoterm"
        refute fields_html =~ "custom_fields["
        refute fields_html =~ ~s(phx-click="edit_supplier_info")

        render_submit(view, "save", %{"item" => %{"name" => "Oak Panel"}, "save_action" => "stay"})

        # Nothing entity-shaped is stamped onto rows written while hidden.
        # (The comment thread key is the catalogue's own, not a field.)
        [info] = Catalogue.list_supplier_infos_for_item(item.uuid)
        assert Map.delete(info.metadata, "comment_thread_uuid") == %{}
      end

      test "the manager cannot be opened by a crafted event", %{conn: conn} do
        item =
          fixture_item(%{
            name: "Oak Panel",
            category_uuid: fixture_category(fixture_catalogue()).uuid
          })

        {:ok, _} = Catalogue.add_supplier_field(%{label: "Incoterm", type: "text"})
        {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

        html = render_click(view, "open_supplier_field_manager", %{})

        refute html =~ "Supplier extra fields"
        refute html =~ "Add field"
      end

      # The restore path depends on this: values written before the
      # feature was hidden must still be there when it comes back.
      test "values stored earlier survive an edit while the UI is hidden", %{conn: conn} do
        item =
          fixture_item(%{
            name: "Oak Panel",
            category_uuid: fixture_category(fixture_catalogue()).uuid
          })

        supplier = fixture_supplier()

        {:ok, info} =
          Catalogue.create_supplier_info(%{
            "item_uuid" => item.uuid,
            "supplier_uuid" => supplier.uuid,
            "supplier_source" => "local",
            "metadata" => %{"custom_fields" => %{"incoterm" => "DAP"}}
          })

        {:ok, view, _html} = live(conn, edit_item_url(item.uuid))
        render_click(view, "edit_supplier_info", %{"supplier" => info.supplier_uuid})

        render_click(view, "save_supplier_info", %{
          "supplier_info" => %{"supplier_sku" => "STILL-EDITABLE"}
        })

        render_submit(view, "save", %{"item" => %{"name" => "Oak Panel"}, "save_action" => "stay"})

        [updated] = Catalogue.list_supplier_infos_for_item(item.uuid)
        assert updated.supplier_sku == "STILL-EDITABLE"
        assert updated.metadata["custom_fields"] == %{"incoterm" => "DAP"}
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Location (boss, 2026-09-19): one section on Details, a folder tree to
  # pick from, the move made on Save. Replaced the Category select and the
  # Move section.
  # ─────────────────────────────────────────────────────────────────

  describe "Location" do
    defp pick(view, target) do
      render_click(view, "open_location_picker", %{})
      pick_place(view, target)
    end

    defp save_stay(view, params) do
      render_submit(view, "save", %{"item" => params, "save_action" => "stay"})
    end

    test "the Move section and the Category select are gone", %{conn: conn} do
      catalogue = fixture_catalogue()
      item = fixture_item(%{name: "Placed", catalogue_uuid: catalogue.uuid})

      {:ok, view, html} = live(conn, edit_item_url(item.uuid))

      refute has_element?(view, "#item-move-section")
      refute html =~ ~s(name="item[category_uuid]")
      assert has_element?(view, "#item-location #item-location-change")
    end

    test "a pick moves nothing until Save; Save moves it and stays",
         %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Kitchen"})
      parent = fixture_category(catalogue, %{name: "Hardware"})
      target = fixture_category(catalogue, %{name: "Hinges", parent_uuid: parent.uuid})
      item = fixture_item(%{name: "Movable", catalogue_uuid: catalogue.uuid})

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

      pick(view, "category:" <> target.uuid)

      path = view |> element("#item-location-path") |> render()
      assert path =~ "Kitchen"
      assert path =~ "Hardware"
      assert path =~ "Hinges"
      assert render(view) =~ "Unsaved changes"
      assert is_nil(Catalogue.get_item(item.uuid).category_uuid)

      save_stay(view, %{"name" => "Movable"})

      assert Catalogue.get_item(item.uuid).category_uuid == target.uuid
      refute view |> element("#item-location") |> render() =~ "Unsaved changes"
    end

    test "a move to another catalogue reloads the form there", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Here"})
      other = fixture_catalogue(%{name: "There"})
      item = fixture_item(%{name: "Traveller", catalogue_uuid: catalogue.uuid})

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))
      pick(view, "catalogue:" <> other.uuid)

      assert {:error, {:live_redirect, %{to: to}}} = save_stay(view, %{"name" => "Traveller"})
      assert to =~ "/items/#{item.uuid}/edit"

      moved = Catalogue.get_item(item.uuid)
      assert moved.catalogue_uuid == other.uuid
      assert is_nil(moved.category_uuid)
    end

    test "Save & Exit after a move goes to the item's new catalogue", %{conn: conn} do
      catalogue = fixture_catalogue()
      other = fixture_catalogue()
      item = fixture_item(%{name: "Leaver", catalogue_uuid: catalogue.uuid})

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))
      pick(view, "catalogue:" <> other.uuid)

      assert {:error, {:live_redirect, %{to: to}}} =
               render_submit(view, "save", %{
                 "item" => %{"name" => "Leaver"},
                 "save_action" => "exit"
               })

      assert to == catalogue_detail_url(other.uuid)
    end

    test "Undo, or picking the item's own place, takes the move back", %{conn: conn} do
      catalogue = fixture_catalogue()
      shelf = fixture_category(catalogue, %{name: "Shelf"})
      target = fixture_category(catalogue, %{name: "Elsewhere"})
      item = fixture_item(%{name: "Stayer", category_uuid: shelf.uuid})

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

      pick(view, "category:" <> target.uuid)
      render_click(view, "reset_location", %{})
      save_stay(view, %{"name" => "Stayer"})
      assert Catalogue.get_item(item.uuid).category_uuid == shelf.uuid

      pick(view, "category:" <> target.uuid)
      pick(view, "category:" <> shelf.uuid)
      refute render(view) =~ "Unsaved changes"
      save_stay(view, %{"name" => "Stayer"})
      assert Catalogue.get_item(item.uuid).category_uuid == shelf.uuid
    end

    test "a place the tree did not offer is ignored", %{conn: conn} do
      catalogue = fixture_catalogue()
      {:ok, smart} = Catalogue.create_catalogue(%{name: "NotOffered", kind: "smart"})
      item = fixture_item(%{name: "Standard", catalogue_uuid: catalogue.uuid})

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

      # Kinds never mix: a smart catalogue is not in a standard item's tree.
      pick(view, "catalogue:" <> smart.uuid)
      pick(view, "category:" <> Ecto.UUID.generate())
      pick(view, "garbage")

      assert is_nil(:sys.get_state(view.pid).socket.assigns.location_target)
      save_stay(view, %{"name" => "Standard"})
      assert Catalogue.get_item(item.uuid).catalogue_uuid == catalogue.uuid
    end

    test "a smart item moves among smart catalogues only", %{conn: conn} do
      {:ok, smart} = Catalogue.create_catalogue(%{name: "Services", kind: "smart"})
      {:ok, other_smart} = Catalogue.create_catalogue(%{name: "Extras", kind: "smart"})
      _standard = fixture_catalogue(%{name: "Plain Standard"})
      item = fixture_item(%{name: "Delivery", catalogue_uuid: smart.uuid})

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

      render_click(view, "open_location_picker", %{})
      # The rules picker lists standard catalogues too; the tree does not.
      tree = view |> element("#location-tree-picker-tree") |> render()
      assert tree =~ "Extras"
      refute tree =~ "Plain Standard"

      pick_place(view, "catalogue:" <> other_smart.uuid)
      save_stay(view, %{"name" => "Delivery"})

      assert Catalogue.get_item(item.uuid).catalogue_uuid == other_smart.uuid
    end

    test "the tree nests catalogues in their folders, and search keeps the path",
         %{conn: conn} do
      {:ok, folder} = Catalogue.create_folder(%{name: "Estonian stuff"})
      {:ok, _empty} = Catalogue.create_folder(%{name: "Nothing here"})
      filed = fixture_catalogue(%{name: "Tables"})
      {:ok, _} = Catalogue.move_catalogue_to_folder(filed, folder.uuid)
      legs = fixture_category(filed, %{name: "Legs"})
      _tops = fixture_category(filed, %{name: "Tops"})

      home = fixture_catalogue(%{name: "Home"})
      item = fixture_item(%{name: "Leg", catalogue_uuid: home.uuid})

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))
      tree = render_click(view, "open_location_picker", %{})

      assert tree =~ "Estonian stuff"
      # A folder leading to no catalogue of the item's kind is left out.
      refute tree =~ "Nothing here"
      # Closed until opened.
      refute tree =~ "Legs"

      html =
        view
        |> element(~s(#location-tree-picker [data-tree-node="folder:#{folder.uuid}"]))
        |> render_click()

      assert html =~ "Tables"

      html = search_places(view, "leg")

      # The match and the rows above it, opened; its siblings are gone.
      assert html =~ "Estonian stuff"
      assert html =~ "Tables"
      assert html =~ ~s(data-tree-node="category:#{legs.uuid}")
      refute html =~ "Tops"

      html = search_places(view, "zzz")
      assert html =~ "No matches."
    end

    test "a category trashed after the pick keeps the save and reports the move",
         %{conn: conn} do
      catalogue = fixture_catalogue()
      target = fixture_category(catalogue, %{name: "Soon gone"})
      item = fixture_item(%{name: "Hopeful", catalogue_uuid: catalogue.uuid})

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))
      pick(view, "category:" <> target.uuid)
      {:ok, _} = Catalogue.trash_category(target)

      html = save_stay(view, %{"name" => "Renamed hopeful"})

      assert html =~ "Category not found."
      saved = Catalogue.get_item(item.uuid)
      assert saved.name == "Renamed hopeful"
      assert is_nil(saved.category_uuid)
      # Still staged, for the admin to pick again or take back.
      assert :sys.get_state(view.pid).socket.assigns.location_target == "category:" <> target.uuid
    end

    test "a move decides from the item as it is now, not as the page loaded it",
         %{conn: conn} do
      catalogue = fixture_catalogue()
      shelf = fixture_category(catalogue, %{name: "Shelf"})
      item = fixture_item(%{name: "Wanderer", category_uuid: shelf.uuid})
      {:ok, away} = Catalogue.create_catalogue(%{name: "Away"})

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

      # Another tab moves it away meanwhile.
      {:ok, _} = Catalogue.move_item_to_catalogue(item, away.uuid)

      pick(view, "catalogue:" <> catalogue.uuid)
      save_stay(view, %{"name" => "Wanderer"})

      moved = Catalogue.get_item(item.uuid)
      assert moved.catalogue_uuid == catalogue.uuid
      assert moved.category_uuid == nil
    end

    test "?category= on a new item starts Location there", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Kitchen"})
      category = fixture_category(catalogue, %{name: "Frames"})

      {:ok, view, _html} =
        live(conn, new_item_url(catalogue.uuid) <> "?category=" <> category.uuid)

      assert view |> element("#item-location-path") |> render() =~ "Frames"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Smart-catalogue rules — toggle/set_value/set_unit/clear_all
  # ─────────────────────────────────────────────────────────────────

  describe "smart-catalogue rules" do
    setup do
      smart = fixture_catalogue(%{name: "Services", kind: "smart"})
      kitchen = fixture_catalogue(%{name: "Kitchen"})
      hardware = fixture_catalogue(%{name: "Hardware"})

      smart_item =
        fixture_item(%{
          name: "Delivery",
          catalogue_uuid: smart.uuid,
          default_value: Decimal.new("5"),
          default_unit: "percent"
        })

      %{smart: smart, kitchen: kitchen, hardware: hardware, item: smart_item}
    end

    test "toggle_catalogue_rule adds and removes a rule client-side", %{
      conn: conn,
      item: item,
      kitchen: kitchen
    } do
      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

      # Initial: no working rules
      render_click(view, "toggle_catalogue_rule", %{"uuid" => kitchen.uuid})
      # Toggle off again
      render_click(view, "toggle_catalogue_rule", %{"uuid" => kitchen.uuid})

      # No persistence yet — saving the form persists the working set.
      assert Catalogue.list_catalogue_rules(item) == []
    end

    test "set_catalogue_rule_value + save persists the value", %{
      conn: conn,
      item: item,
      kitchen: kitchen
    } do
      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

      render_click(view, "toggle_catalogue_rule", %{"uuid" => kitchen.uuid})
      render_change(view, "set_catalogue_rule_value", %{"uuid" => kitchen.uuid, "value" => "10"})

      view
      |> form("form[action=\"#\"][phx-submit=save]",
        item: %{
          "name" => item.name,
          "status" => "active"
        }
      )
      |> render_submit()

      [rule] = Catalogue.list_catalogue_rules(item)
      assert rule.referenced_catalogue_uuid == kitchen.uuid
      assert Decimal.equal?(rule.value, Decimal.new("10"))
    end

    test "set_catalogue_rule_value accepts a comma or dot decimal, unrounded", %{
      conn: conn,
      item: item,
      kitchen: kitchen
    } do
      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

      render_click(view, "toggle_catalogue_rule", %{"uuid" => kitchen.uuid})

      render_change(view, "set_catalogue_rule_value", %{
        "uuid" => kitchen.uuid,
        "value" => "7,25"
      })

      view
      |> form("form[action=\"#\"][phx-submit=save]",
        item: %{
          "name" => item.name,
          "status" => "active"
        }
      )
      |> render_submit()

      [rule] = Catalogue.list_catalogue_rules(item)
      assert Decimal.equal?(rule.value, Decimal.new("7.25"))
    end

    test "set_catalogue_rule_unit accepts only known units", %{
      conn: conn,
      item: item,
      kitchen: kitchen
    } do
      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

      render_click(view, "toggle_catalogue_rule", %{"uuid" => kitchen.uuid})
      render_change(view, "set_catalogue_rule_unit", %{"uuid" => kitchen.uuid, "unit" => "flat"})

      view
      |> form("form[action=\"#\"][phx-submit=save]",
        item: %{
          "name" => item.name,
          "status" => "active"
        }
      )
      |> render_submit()

      [rule] = Catalogue.list_catalogue_rules(item)
      assert rule.unit == "flat"
    end

    test "clear_catalogue_rules wipes the working set client-side", %{
      conn: conn,
      item: item,
      kitchen: kitchen,
      hardware: hardware
    } do
      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

      render_click(view, "toggle_catalogue_rule", %{"uuid" => kitchen.uuid})
      render_click(view, "toggle_catalogue_rule", %{"uuid" => hardware.uuid})
      render_click(view, "clear_catalogue_rules", %{})

      view
      |> form("form[action=\"#\"][phx-submit=save]",
        item: %{
          "name" => item.name,
          "status" => "active"
        }
      )
      |> render_submit()

      assert Catalogue.list_catalogue_rules(item) == []
    end

    test "rule picker excludes smart catalogues + the parent itself (issue #16)", %{
      conn: conn,
      item: item,
      smart: smart,
      kitchen: kitchen,
      hardware: hardware
    } do
      other_smart = fixture_catalogue(%{name: "Other Smart", kind: "smart"})

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

      candidates = :sys.get_state(view.pid).socket.assigns.rule_candidates
      uuids = Enum.map(candidates, & &1.uuid)

      assert kitchen.uuid in uuids
      assert hardware.uuid in uuids
      refute smart.uuid in uuids
      refute other_smart.uuid in uuids
    end
  end

  describe "origin-aware Add Item" do
    test "?category= starts the new item's Location in that category", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue, %{name: "Origin shelf"})

      {:ok, view, _html} =
        live(conn, new_item_url(catalogue.uuid) <> "?category=#{category.uuid}")

      assert view |> element("#item-location-path") |> render() =~ "Origin shelf"
    end

    test "a category from another catalogue is ignored", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Mine"})
      other = fixture_catalogue(%{name: "Other"})
      foreign = fixture_category(other, %{name: "Foreign shelf"})

      {:ok, view, _html} =
        live(conn, new_item_url(catalogue.uuid) <> "?category=#{foreign.uuid}")

      path = view |> element("#item-location-path") |> render()
      refute path =~ "Foreign shelf"
      assert path =~ "Mine"
    end

    test "a valid return_to drives the Cancel link; an external one is dropped", %{conn: conn} do
      catalogue = fixture_catalogue()
      rt = "/en/admin/catalogue/#{catalogue.uuid}?category=uncategorized"

      {:ok, _view, html} =
        live(conn, new_item_url(catalogue.uuid) <> "?" <> URI.encode_query(return_to: rt))

      assert html =~ ~s(href="#{Phoenix.HTML.html_escape(rt) |> Phoenix.HTML.safe_to_string()}")

      {:ok, _view, html} =
        live(
          conn,
          new_item_url(catalogue.uuid) <>
            "?" <> URI.encode_query(return_to: "https://evil.example")
        )

      refute html =~ "evil.example"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Attributes tab
  # ─────────────────────────────────────────────────────────────────

  describe "attributes tab" do
    test "saving with a selected group assigns it; clearing removes it", %{conn: conn} do
      {:ok, group} = Catalogue.create_attribute_group(%{name: "Idea doors"})
      catalogue = fixture_catalogue()

      {:ok, view, html} = live(conn, new_item_url(catalogue.uuid))
      assert html =~ "Idea doors"

      {:error, {:live_redirect, _}} =
        view
        |> form("form[action=\"#\"][phx-submit=save]", %{
          "item" => base_item_params(),
          "attribute_group_uuid" => group.uuid
        })
        |> render_submit()

      [item] = TestRepo.all(Item)
      assert Catalogue.get_item_attribute_group_uuid(item.uuid) == group.uuid

      # Re-open for edit: preselected; clearing the select detaches on save.
      # (The kit <.select> renders via options_for_select, which emits
      # `selected` BEFORE `value` — assert order-agnostically.)
      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

      assert has_element?(
               view,
               "select[name='attribute_group_uuid'] option[value='#{group.uuid}'][selected]"
             )

      view
      |> form("form[action=\"#\"][phx-submit=save]", %{
        "item" => base_item_params(),
        "attribute_group_uuid" => ""
      })
      |> render_submit()

      assert Catalogue.get_item_attribute_group_uuid(item.uuid) == nil
    end

    test "the group dropdown shows the viewer's locale, not the primary language", %{
      conn: conn
    } do
      # An explicit non-English `_primary_language` keeps "en" a
      # genuinely secondary locale here — this test env's system
      # default is "en-US", so without it the "en" override below would
      # land in the primary bucket itself (same base as "en-US")
      # instead of a secondary one. See PR discussion.
      {:ok, group} =
        Catalogue.create_attribute_group(%{
          name: "Ideedeuksed",
          data: %{"_primary_language" => "et"}
        })

      {:ok, _} =
        Catalogue.set_translation(group, "en", %{"_name" => "Idea doors"}, fn g, a ->
          Catalogue.update_attribute_group(g, a)
        end)

      catalogue = fixture_catalogue()

      {:ok, _view, html} = live(conn, new_item_url(catalogue.uuid))

      assert html =~ "Idea doors"
      refute html =~ "Ideedeuksed"
    end

    test "legacy metadata collapse renders only when old values exist", %{conn: conn} do
      catalogue = fixture_catalogue()

      plain = fixture_item(%{name: "No meta", catalogue_uuid: catalogue.uuid})
      {:ok, _view, html} = live(conn, edit_item_url(plain.uuid))
      refute html =~ "View old values"

      legacy =
        fixture_item(%{
          name: "Has meta",
          catalogue_uuid: catalogue.uuid,
          data: %{"meta" => %{"color" => "red", "weight" => "5kg"}}
        })

      {:ok, _view, html} = live(conn, edit_item_url(legacy.uuid))
      assert html =~ "View old values (2)"
      assert html =~ "red"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Save vs Save & Exit
  # ─────────────────────────────────────────────────────────────────

  describe "save modes" do
    test "Save on :new lands on the created item's edit form, keeping return_to", %{conn: conn} do
      catalogue = fixture_catalogue()
      rt = catalogue_detail_url(catalogue.uuid)

      {:ok, view, _html} =
        live(conn, new_item_url(catalogue.uuid) <> "?" <> URI.encode_query(return_to: rt))

      {:error, {:live_redirect, %{to: to}}} =
        view
        |> form("form[action=\"#\"][phx-submit=save]", %{"item" => base_item_params()})
        |> put_submitter(~s(button[name=save_action][value=stay]))
        |> render_submit()

      [item] = TestRepo.all(Item)
      assert to == edit_item_url(item.uuid) <> "?" <> URI.encode_query(return_to: rt)
    end

    test "Save on :edit stays on the form with the saved values", %{conn: conn} do
      catalogue = fixture_catalogue()
      item = fixture_item(%{name: "Before", catalogue_uuid: catalogue.uuid})

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

      html =
        view
        |> form("form[action=\"#\"][phx-submit=save]", %{
          "item" => base_item_params(%{"name" => "After"})
        })
        |> put_submitter(~s(button[name=save_action][value=stay]))
        |> render_submit()

      # No redirect — still on the edit form, retitled to the new name.
      assert html =~ "After"
      assert Catalogue.get_item(item.uuid).name == "After"
    end

    test "Save & Exit on :edit navigates back out", %{conn: conn} do
      catalogue = fixture_catalogue()
      item = fixture_item(%{name: "Exiting", catalogue_uuid: catalogue.uuid})

      {:error, {:live_redirect, %{to: to}}} =
        live(conn, edit_item_url(item.uuid))
        |> elem(1)
        |> form("form[action=\"#\"][phx-submit=save]", %{
          "item" => base_item_params(%{"name" => "Exiting"})
        })
        |> put_submitter(~s(button[name=save_action][value=exit]))
        |> render_submit()

      assert to == catalogue_detail_url(catalogue.uuid)
    end
  end
end
