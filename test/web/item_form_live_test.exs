defmodule PhoenixKitCatalogue.Web.ItemFormLiveTest do
  @moduledoc """
  End-to-end LiveView tests for ItemFormLive. Drives the form through
  Phoenix.LiveViewTest so form params arrive as real string-keyed
  maps (the exact shape that caused the mixed-key CastError we hit in
  production).
  """
  use PhoenixKitCatalogue.LiveCase

  alias PhoenixKitCatalogue.Catalogue
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
end
