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

  # ─────────────────────────────────────────────────────────────────
  # Helpers
  # ─────────────────────────────────────────────────────────────────

  @base "/en/admin/catalogue"

  defp new_item_url(catalogue_uuid), do: "#{@base}/#{catalogue_uuid}/items/new"
  defp edit_item_url(item_uuid), do: "#{@base}/items/#{item_uuid}/edit"

  defp catalogue_detail_url(catalogue_uuid), do: "#{@base}/#{catalogue_uuid}"

  defp base_item_params(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "Oak Panel",
        "description" => "",
        "sku" => "",
        "base_price" => "25.50",
        "unit" => "piece",
        "category_uuid" => "",
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

      assert html =~ "New Item"
      assert html =~ ~s(name="item[name]")
      assert html =~ ~s(name="item[base_price]")
    end

    test "lists the catalogue's categories in the category dropdown", %{conn: conn} do
      catalogue = fixture_catalogue()
      fixture_category(catalogue, %{name: "Frames"})
      fixture_category(catalogue, %{name: "Hinges"})

      {:ok, _view, html} = live(conn, new_item_url(catalogue.uuid))

      assert html =~ "Frames"
      assert html =~ "Hinges"
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

      params = base_item_params(%{"category_uuid" => category.uuid})

      {:error, {:live_redirect, %{to: to}}} =
        view
        |> form("form[action=\"#\"][phx-submit=save]", %{"item" => params})
        |> render_submit()

      # After create the LiveView navigates to the catalogue detail.
      assert to == catalogue_detail_url(catalogue.uuid)

      # Verify the item actually landed with the right derived catalogue.
      [item] = TestRepo.all(Item)
      assert item.name == "Oak Panel"
      assert item.category_uuid == category.uuid
      assert item.catalogue_uuid == catalogue.uuid
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

    test "a category from another catalogue is refused, not silently followed",
         %{conn: conn} do
      catalogue = fixture_catalogue()
      other = fixture_catalogue()
      foreign_category = fixture_category(other, %{name: "Elsewhere"})

      {:ok, view, _html} = live(conn, new_item_url(catalogue.uuid))

      # The longer route to the same field: `derive_catalogue_uuid/2` copies
      # the CATEGORY's catalogue over whatever the server set, deliberately,
      # so a forged category_uuid beats the server-side scope pin.
      html =
        render_submit(view, "save", %{
          "item" =>
            base_item_params(%{
              "name" => "Smuggled",
              "category_uuid" => foreign_category.uuid
            })
        })

      assert html =~ "another catalogue"
      assert TestRepo.all(Item) == []
    end

    test "saves an uncategorized item (empty category_uuid)", %{conn: conn} do
      catalogue = fixture_catalogue()
      {:ok, view, _html} = live(conn, new_item_url(catalogue.uuid))

      {:error, {:live_redirect, _}} =
        view
        |> form("form[action=\"#\"][phx-submit=save]", %{
          "item" => base_item_params(%{"name" => "Loose item", "category_uuid" => ""})
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
      assert html =~ "New Item"
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
          "item" => base_item_params(%{"name" => "New name", "category_uuid" => category.uuid})
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
              "category_uuid" => category.uuid,
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

  describe "supplier info card" do
    test "save_supplier_info attributes the activity log to the logged-in actor",
         %{conn: conn, scope: scope} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      item = fixture_item(%{name: "Oak Panel", category_uuid: category.uuid})
      supplier = fixture_supplier()

      {:ok, view, _html} = conn |> with_scope(scope) |> live(edit_item_url(item.uuid))

      render_click(view, "open_add_supplier", %{})

      render_change(view, "supplier_info_field_change", %{
        "supplier_info" => %{"supplier_uuid" => supplier.uuid}
      })

      render_click(view, "save_supplier_info", %{})

      [info] = Catalogue.list_supplier_infos_for_item(item.uuid)

      assert_activity_logged("item_supplier_info.created",
        resource_uuid: info.uuid,
        actor_uuid: scope.user.uuid,
        metadata_has: %{"item_uuid" => item.uuid}
      )
    end

    # Owner decisions 2026-08-21: the supplier form carries the picker and
    # the PRICE, nothing else. SKU, lead time and MOQ stay behind
    # @supplier_terms_fields — their data and columns are untouched.
    test "the modal carries the picker and the price, and nothing else", %{conn: conn} do
      item =
        fixture_item(%{
          name: "Oak Panel",
          category_uuid: fixture_category(fixture_catalogue()).uuid
        })

      {:ok, view, _page} = live(conn, edit_item_url(item.uuid))
      html = render_click(view, "open_add_supplier", %{})

      assert html =~ ~s(name="supplier_info[supplier_uuid]")
      assert html =~ ~s(name="supplier_info[unit_cost]")
      assert html =~ ~s(name="supplier_info[currency]")

      for field <- ~w(supplier_sku lead_time_days min_order_qty) do
        refute html =~ ~s(name="supplier_info[#{field}]")
      end
    end

    # 2026-08-31 delta pin: the Unit label is hand-rolled to Input's
    # markup (label mb-2 + plain font-semibold span) because core's
    # <.select> labelled through FormFieldLabel's fieldset-legend span,
    # which rendered smaller than the Input labels beside it. Local
    # until the core harmonisation releases; a revert re-breaks the row.
    test "the Unit label matches its Input neighbours' markup", %{conn: conn} do
      item =
        fixture_item(%{
          name: "Oak Panel",
          category_uuid: fixture_category(fixture_catalogue()).uuid
        })

      {:ok, _view, html} = live(conn, edit_item_url(item.uuid))

      assert html =~ ~r/<label class="label mb-2"[^>]*>\s*<span class="font-semibold">\s*Unit/
    end

    # The price control comes from entities' `decimal` renderer, not a
    # hand-rolled number input — that is what keeps it exact.
    test "the price control is the entities decimal field", %{conn: conn} do
      item =
        fixture_item(%{
          name: "Oak Panel",
          category_uuid: fixture_category(fixture_catalogue()).uuid
        })

      {:ok, view, _page} = live(conn, edit_item_url(item.uuid))
      html = render_click(view, "open_add_supplier", %{})

      # The control's step is whatever entities derives from the built-in
      # definition — asserted as delegation, not a literal, so this holds
      # at every entities version: pre-"step" releases derive 0.0001 from
      # the scale, 0.4.9+ honours the declared "any" (arrows walk by 1;
      # every 4-place typed value stays saveable — `step` IS a browser
      # validation constraint that gates the submit event, which is why
      # the original cent step was wrong; entities 0.4.9 review).
      builtin = Catalogue.supplier_builtin_field("unit_cost")
      assert html =~ ~s(step="#{PhoenixKitEntities.FieldTypes.decimal_step(builtin)}")

      # Catalogue's side of the contract: sane arrows, 4-place storage,
      # nothing typed ever blocked — the boss's "too precise" report,
      # 2026-08-30, corrected 2026-08-31.
      assert builtin["scale"] == 4
      assert builtin["step"] == "any"
      assert builtin["type"] == "decimal"
    end

    # The whole reason entities grew a `decimal` type: a price must reach
    # NUMERIC(14,4) exactly, not via Float.parse/1.
    test "a price saves to the column exactly, to four places", %{conn: conn} do
      item =
        fixture_item(%{
          name: "Oak Panel",
          category_uuid: fixture_category(fixture_catalogue()).uuid
        })

      supplier = fixture_supplier()

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))
      render_click(view, "open_add_supplier", %{})

      render_change(view, "supplier_info_field_change", %{
        "supplier_info" => %{
          "supplier_uuid" => supplier.uuid,
          "unit_cost" => "5.1234",
          "currency" => "eur"
        }
      })

      render_click(view, "save_supplier_info", %{})

      [info] = Catalogue.list_supplier_infos_for_item(item.uuid)
      assert Decimal.equal?(info.unit_cost, Decimal.new("5.1234"))
      assert Decimal.to_string(info.unit_cost, :normal) == "5.1234"
      # Currency is upcased on the way in — the input is uppercase by CSS only.
      assert info.currency == "EUR"
    end

    test "a price that is not a number is refused inside the modal", %{conn: conn} do
      item =
        fixture_item(%{
          name: "Oak Panel",
          category_uuid: fixture_category(fixture_catalogue()).uuid
        })

      supplier = fixture_supplier()

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))
      render_click(view, "open_add_supplier", %{})

      render_change(view, "supplier_info_field_change", %{
        "supplier_info" => %{"supplier_uuid" => supplier.uuid, "unit_cost" => "abc"}
      })

      html = render_click(view, "save_supplier_info", %{})

      assert html =~ "Unit cost must be a number."
      assert Catalogue.list_supplier_infos_for_item(item.uuid) == []
    end

    # Max hit this on max-dev: the same supplier could be added twice,
    # leaving one item with two live prices for one company.
    test "a supplier already on the item is not offered again", %{conn: conn} do
      item =
        fixture_item(%{
          name: "Oak Panel",
          category_uuid: fixture_category(fixture_catalogue()).uuid
        })

      linked = fixture_supplier()
      other = fixture_supplier()

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))
      render_click(view, "open_add_supplier", %{})

      render_change(view, "supplier_info_field_change", %{
        "supplier_info" => %{"supplier_uuid" => linked.uuid}
      })

      render_click(view, "save_supplier_info", %{})

      html = render_click(view, "open_add_supplier", %{})

      refute html =~ linked.uuid
      assert html =~ other.uuid
    end

    test "adding the same supplier twice is refused with a clear reason", %{conn: conn} do
      item =
        fixture_item(%{
          name: "Oak Panel",
          category_uuid: fixture_category(fixture_catalogue()).uuid
        })

      supplier = fixture_supplier()

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

      for _attempt <- 1..2 do
        render_click(view, "open_add_supplier", %{})

        render_change(view, "supplier_info_field_change", %{
          "supplier_info" => %{"supplier_uuid" => supplier.uuid}
        })

        render_click(view, "save_supplier_info", %{})
      end

      assert length(Catalogue.list_supplier_infos_for_item(item.uuid)) == 1
    end

    test "add is refused with no supplier picked, and says so inside the modal",
         %{conn: conn} do
      item =
        fixture_item(%{
          name: "Oak Panel",
          category_uuid: fixture_category(fixture_catalogue()).uuid
        })

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

      render_click(view, "open_add_supplier", %{})
      html = render_click(view, "save_supplier_info", %{})

      assert html =~ "Please select a supplier."
      assert Catalogue.list_supplier_infos_for_item(item.uuid) == []
    end

    test "edit_supplier_info updates the row's columns", %{conn: conn} do
      item =
        fixture_item(%{
          name: "Oak Panel",
          category_uuid: fixture_category(fixture_catalogue()).uuid
        })

      supplier = fixture_supplier()

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))
      render_click(view, "open_add_supplier", %{})

      render_change(view, "supplier_info_field_change", %{
        "supplier_info" => %{"supplier_uuid" => supplier.uuid, "supplier_sku" => "OLD-1"}
      })

      render_click(view, "save_supplier_info", %{})
      [info] = Catalogue.list_supplier_infos_for_item(item.uuid)

      render_click(view, "edit_supplier_info", %{"uuid" => info.uuid})

      render_click(view, "save_supplier_info", %{
        "supplier_info" => %{"supplier_sku" => "NEW-2", "lead_time_days" => "5"}
      })

      [updated] = Catalogue.list_supplier_infos_for_item(item.uuid)
      assert updated.supplier_sku == "NEW-2"
      assert updated.lead_time_days == 5
    end

    # A cost CHANGE closes the current row and opens a successor, which is
    # what feeds the History dialog — a plain overwrite would lose it.
    test "changing an existing unit cost creates a price revision", %{conn: conn} do
      item =
        fixture_item(%{
          name: "Oak Panel",
          category_uuid: fixture_category(fixture_catalogue()).uuid
        })

      supplier = fixture_supplier()

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))
      render_click(view, "open_add_supplier", %{})

      render_change(view, "supplier_info_field_change", %{
        "supplier_info" => %{
          "supplier_uuid" => supplier.uuid,
          "unit_cost" => "10.00",
          "currency" => "EUR"
        }
      })

      render_click(view, "save_supplier_info", %{})
      [info] = Catalogue.list_supplier_infos_for_item(item.uuid)

      render_click(view, "edit_supplier_info", %{"uuid" => info.uuid})

      render_click(view, "save_supplier_info", %{
        "supplier_info" => %{"unit_cost" => "12.50", "currency" => "EUR"}
      })

      # One CURRENT row at the new price...
      [current] = Catalogue.list_supplier_infos_for_item(item.uuid)
      assert Decimal.equal?(current.unit_cost, Decimal.new("12.50"))
      assert is_nil(current.valid_to)

      # ...and the old price kept as a closed row.
      history = Catalogue.supplier_info_history_for_pair(item.uuid, supplier.uuid)
      assert length(history) == 2
      assert Enum.any?(history, &(not is_nil(&1.valid_to)))
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

        # The supplier modal carries no Extra fields block either.
        modal_html = render_click(view, "open_add_supplier", %{})
        refute modal_html =~ "Extra fields"
        refute modal_html =~ "custom_fields["

        render_change(view, "supplier_info_field_change", %{
          "supplier_info" => %{"supplier_uuid" => supplier.uuid}
        })

        render_click(view, "save_supplier_info", %{})

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
        render_click(view, "edit_supplier_info", %{"uuid" => info.uuid})

        render_click(view, "save_supplier_info", %{
          "supplier_info" => %{"supplier_sku" => "STILL-EDITABLE"}
        })

        [updated] = Catalogue.list_supplier_infos_for_item(item.uuid)
        assert updated.supplier_sku == "STILL-EDITABLE"
        assert updated.metadata["custom_fields"] == %{"incoterm" => "DAP"}
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # move_item
  # ─────────────────────────────────────────────────────────────────

  describe "move_item" do
    test "moves item to a different category via the move form", %{conn: conn} do
      catalogue = fixture_catalogue()
      source = fixture_category(catalogue, %{name: "Source"})
      target = fixture_category(catalogue, %{name: "Target"})
      item = fixture_item(%{name: "Movable", category_uuid: source.uuid})

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

      # The form's move dropdown picks a target category.
      render_change(view, "select_move_target", %{"category_uuid" => target.uuid})
      render_click(view, "move_item", %{})

      reloaded = Catalogue.get_item(item.uuid)
      assert reloaded.category_uuid == target.uuid
    end

    test "move event with no selected target is a no-op", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      item = fixture_item(%{name: "Stays", category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

      # No select_move_target event fired — move_target is still nil.
      render_click(view, "move_item", %{})

      reloaded = Catalogue.get_item(item.uuid)
      assert reloaded.category_uuid == category.uuid
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
    test "?category= prefills the category select on the new form", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)

      {:ok, _view, html} =
        live(conn, new_item_url(catalogue.uuid) <> "?category=#{category.uuid}")

      assert html =~ ~s(<option selected="" value="#{category.uuid}")
    end

    test "a category from another catalogue is ignored", %{conn: conn} do
      catalogue = fixture_catalogue()
      other = fixture_catalogue(%{name: "Other"})
      foreign = fixture_category(other)

      {:ok, _view, html} =
        live(conn, new_item_url(catalogue.uuid) <> "?category=#{foreign.uuid}")

      refute html =~ ~s(<option selected="" value="#{foreign.uuid}")
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
      {:ok, group} = Catalogue.create_attribute_group(%{name: "Ideedeuksed"})

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
