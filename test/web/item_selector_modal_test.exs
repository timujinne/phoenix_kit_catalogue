defmodule PhoenixKitCatalogue.Web.Components.ItemSelectorModalTest do
  @moduledoc """
  Drives `ItemSelectorModal` through `Test.SelectorHostLive`, asserting the
  PROCESS-MESSAGE contract a production host consumes (rendered back as
  DOM by the host) — not component internals. Security clamps get the
  adversarial cases: crafted uuids, out-of-scope categories, absurd
  quantities.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Web.ViewConfig

  defp seed(_ctx) do
    cat = fixture_catalogue(%{name: "Picker Catalogue"})
    other = fixture_catalogue(%{name: "Forbidden Catalogue"})

    {:ok, screw} =
      Catalogue.create_item(%{
        name: "M8 Screw",
        sku: "M8-100",
        base_price: Decimal.new("2.50"),
        catalogue_uuid: cat.uuid
      })

    {:ok, paint} =
      Catalogue.create_item(%{
        name: "White Paint",
        sku: "PAINT-W",
        catalogue_uuid: cat.uuid
      })

    {:ok, forbidden} =
      Catalogue.create_item(%{
        name: "Forbidden Item",
        sku: "NOPE-1",
        catalogue_uuid: other.uuid
      })

    %{cat: cat, other: other, screw: screw, paint: paint, forbidden: forbidden}
  end

  setup :seed

  defp open(conn, query), do: live(conn, "/test/selector-host?#{query}")

  defp picker(view), do: with_target(view, "#picker")

  # A root that has categories opens as the admin-style category browser;
  # tests that assert on the ROOT's flat item list switch it over first.
  defp to_items_mode(view),
    do: view |> picker() |> render_click("set_root_mode", %{"mode" => "items"})

  describe "scoped browsing" do
    test "renders only the scoped catalogue's items", %{conn: conn, cat: cat} do
      {:ok, _view, html} = open(conn, "c=#{cat.uuid}&sel=click")

      assert html =~ "M8 Screw"
      assert html =~ "White Paint"
      refute html =~ "Forbidden Item"
    end

    test "search narrows within the scope", %{conn: conn, cat: cat} do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")

      html = view |> picker() |> render_change("browse_search", %{"search" => "screw"})

      assert html =~ "M8 Screw"
      refute html =~ "White Paint"
    end

    test "a crafted category event cannot leak the other catalogue", %{
      conn: conn,
      cat: cat,
      other: other
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")

      # Every fetch re-ANDs scope.catalogue_uuids, so even a category value
      # from another catalogue can never surface its items.
      html =
        view
        |> picker()
        |> render_click("browse_category", %{"uuid" => other.uuid})

      refute html =~ "Forbidden Item"
    end

    test "a category outside scope.category_uuids is rejected as a no-op", %{
      conn: conn,
      cat: cat
    } do
      # The case category_allowed?/2 actually guards: the host restricted
      # browsing to ONE category, and a crafted event names a sibling.
      allowed = fixture_category(cat, %{name: "Allowed"})
      hidden = fixture_category(cat, %{name: "Hidden"})

      {:ok, in_cat} =
        Catalogue.create_item(%{
          name: "Allowed Widget",
          catalogue_uuid: cat.uuid,
          category_uuid: allowed.uuid
        })

      {:ok, _out} =
        Catalogue.create_item(%{
          name: "Hidden Widget",
          catalogue_uuid: cat.uuid,
          category_uuid: hidden.uuid
        })

      {:ok, view, html} =
        live(conn, "/test/selector-host?c=#{cat.uuid}&cat_scope=#{allowed.uuid}&sel=click")

      assert html =~ "Allowed Widget"
      refute html =~ "Hidden Widget"

      # The crafted chip event names the sibling category. BrowseState must
      # refuse it outright — the grid stays exactly as scoped.
      html =
        view
        |> picker()
        |> render_click("browse_category", %{"uuid" => hidden.uuid})

      assert html =~ "Allowed Widget"
      refute html =~ "Hidden Widget"
      _ = in_cat
    end
  end

  describe "selection and confirm — the host contract" do
    test "select, confirm: the host receives Decimal qty and the snapshot", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")

      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
      view |> picker() |> render_click("confirm", %{})
      html = render(view)

      assert html =~ ~s(id="picked")
      assert html =~ "M8 Screw|M8-100|qty=1|decimal=true|line=2.50"
      # Confirm also closes.
      assert html =~ ~s(id="closed")
    end

    test "a crafted card_click with an unrendered uuid is refused", %{
      conn: conn,
      cat: cat,
      forbidden: forbidden
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")

      view |> picker() |> render_click("card_click", %{"uuid" => forbidden.uuid})
      view |> picker() |> render_click("confirm", %{})
      html = render(view)

      # The forbidden item never enters the selection, so nothing is
      # confirmable and the confirm itself is refused — no message at all.
      refute html =~ ~s(id="picked")
    end

    test "clicking a selected card deselects it", %{conn: conn, cat: cat, screw: screw} do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")

      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
      view |> picker() |> render_click("confirm", %{})
      html = render(view)

      # Deselected back to empty: confirm is refused rather than sending
      # `picks: []`.
      refute html =~ ~s(id="picked")
    end

    test "cancel sends the closed message and nothing else", %{conn: conn, cat: cat} do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")

      view |> picker() |> render_click("cancel", %{})
      html = render(view)

      assert html =~ ~s(id="closed")
      refute html =~ ~s(id="picked")
    end
  end

  describe "quantities" do
    # The native number control's spinner arrows land as debounced
    # qty_change events carrying the NEW value (2026-08-30 — the custom
    # −/+ buttons and their qty_inc/qty_dec events are gone).
    test "a qty_change applies live; below-minimum change is ignored", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")
      uuid = to_string(screw.uuid)

      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
      view |> picker() |> render_click("qty_change", %{"uuid" => uuid, "value" => "2"})
      view |> picker() |> render_click("confirm", %{})
      html = render(view)
      assert html =~ "qty=2"

      # Fresh mount: in click mode the arrows stop at qty_min, so a
      # below-minimum change (crafted, or a browser quirk) is ignored —
      # deselection is the row click or the tray's remove, not the arrows.
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")
      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
      view |> picker() |> render_click("qty_change", %{"uuid" => uuid, "value" => "0"})
      view |> picker() |> render_click("confirm", %{})
      html = render(view)
      assert html =~ "qty=1"
    end

    # The live path must never reset the input mid-typing: "2." on the way
    # to "2.5" parses invalid, is ignored, and leaves the revision alone
    # (a bump would recreate the input and eat the keystrokes). The commit
    # path (blur/Enter) keeps the revision-bump reset for settled garbage.
    test "an in-progress qty_change is ignored without a revision bump", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&precision=1&sel=click")
      uuid = to_string(screw.uuid)

      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
      view |> picker() |> render_click("qty_change", %{"uuid" => uuid, "value" => "2."})

      assert has_element?(view, "#picker-qty-#{uuid}-r0-input")

      view |> picker() |> render_click("confirm", %{})
      assert render(view) =~ "qty=1"
    end

    test "commit parses a decimal comma when precision allows", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&precision=2&sel=click")
      uuid = to_string(screw.uuid)

      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
      view |> picker() |> render_click("qty_commit", %{"uuid" => uuid, "value" => "2,5"})
      view |> picker() |> render_click("confirm", %{})
      html = render(view)

      assert html =~ "qty=2.5"
      assert html =~ "line=6.25"
    end

    test "integer precision rounds a decimal commit", %{conn: conn, cat: cat, screw: screw} do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")
      uuid = to_string(screw.uuid)

      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
      view |> picker() |> render_click("qty_commit", %{"uuid" => uuid, "value" => "2.5"})
      view |> picker() |> render_click("confirm", %{})
      html = render(view)

      # precision 0: 2.5 rounds, it does not become a fractional pick.
      assert html =~ ~r/qty=[23]\|/
      refute html =~ "qty=2.5"
    end

    test "garbage and hostile quantities cannot corrupt the selection", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&max=99&sel=click")
      uuid = to_string(screw.uuid)

      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})

      # Garbage keeps the committed value.
      view |> picker() |> render_click("qty_commit", %{"uuid" => uuid, "value" => "abc"})
      # Negative is rejected outright.
      view |> picker() |> render_click("qty_commit", %{"uuid" => uuid, "value" => "-5"})
      # Absurd is clamped to qty_max, not stored.
      view |> picker() |> render_click("qty_commit", %{"uuid" => uuid, "value" => "1000000000"})

      view |> picker() |> render_click("confirm", %{})
      html = render(view)
      assert html =~ "qty=99"
    end
  end

  describe "preselection" do
    test "hydrates in-scope preselects with their quantities", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, html} = open(conn, "c=#{cat.uuid}&pre=#{screw.uuid}:3&sel=click")

      # Already selected: the card shows its selected state on first render.
      assert html =~ ~s(data-selected="true")

      view |> picker() |> render_click("confirm", %{})
      html = render(view)
      assert html =~ "qty=3"
    end

    test "an out-of-scope preselect is shown but never confirmed", %{
      conn: conn,
      cat: cat,
      forbidden: forbidden
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&pre=#{forbidden.uuid}:2&sel=click")

      # The tray starts collapsed; expand it to see the rows. Visible and
      # flagged — the host's data is not silently dropped…
      html = view |> picker() |> render_click("toggle_tray", %{})
      assert html =~ "Forbidden Item"
      assert html =~ "Not available in this selection"

      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&pre=#{forbidden.uuid}:2&sel=click")
      view |> picker() |> render_click("confirm", %{})
      html = render(view)

      # …and with nothing available the confirm itself is refused — no
      # message at all, not a `picks: []` a replace-semantics host would
      # read as "erase everything".
      refute html =~ ~s(id="picked")
      refute html =~ ~s(id="closed")
    end
  end

  describe "hardening from the 2026-08-22 implementation review" do
    test "an :only-excluded preselect is unavailable, not confirmable", %{conn: conn, cat: cat} do
      # The item HAS a category, the scope says :uncategorized_only — the
      # browse could never return it, so hydration must not bless it.
      category = fixture_category(cat, %{name: "Cat"})

      {:ok, categorized} =
        Catalogue.create_item(%{
          name: "Categorized",
          catalogue_uuid: cat.uuid,
          category_uuid: category.uuid
        })

      {:ok, view, _html} =
        live(
          conn,
          "/test/selector-host?c=#{cat.uuid}&only=uncategorized&pre=#{categorized.uuid}:2&sel=click"
        )

      view |> picker() |> render_click("confirm", %{})
      html = render(view)
      # Nothing available -> the confirm is refused, no message at all.
      refute html =~ ~s(id="picked")
    end

    test "a :categorized_only-excluded uncategorized preselect is not confirmable", %{
      conn: conn,
      cat: cat
    } do
      {:ok, loose} =
        Catalogue.create_item(%{
          name: "Loose Widget",
          catalogue_uuid: cat.uuid
        })

      {:ok, view, _html} =
        live(
          conn,
          "/test/selector-host?c=#{cat.uuid}&only=categorized&pre=#{loose.uuid}:2&sel=click"
        )

      # Hydration of a nil category_uuid against a restriction list must
      # not crash (to_string(nil) is not implemented). Tray starts collapsed.
      html = view |> picker() |> render_click("toggle_tray", %{})
      assert html =~ "Loose Widget"
      assert html =~ "Not available in this selection"

      {:ok, view, _html} =
        live(
          conn,
          "/test/selector-host?c=#{cat.uuid}&only=categorized&pre=#{loose.uuid}:2&sel=click"
        )

      view |> picker() |> render_click("confirm", %{})
      html = render(view)
      # Nothing available -> the confirm is refused, no message at all.
      refute html =~ ~s(id="picked")
    end

    test "an uncategorized preselect under a category_uuids scope does not crash", %{
      conn: conn,
      cat: cat
    } do
      allowed = fixture_category(cat, %{name: "Allowed"})

      {:ok, loose} =
        Catalogue.create_item(%{
          name: "Uncategorized Preselect",
          catalogue_uuid: cat.uuid
        })

      {:ok, view, _html} =
        live(
          conn,
          "/test/selector-host?c=#{cat.uuid}&cat_scope=#{allowed.uuid}&pre=#{loose.uuid}:1&sel=click"
        )

      html = view |> picker() |> render_click("toggle_tray", %{})
      assert html =~ "Uncategorized Preselect"
      assert html =~ "Not available in this selection"

      {:ok, view, _html} =
        live(
          conn,
          "/test/selector-host?c=#{cat.uuid}&cat_scope=#{allowed.uuid}&pre=#{loose.uuid}:1&sel=click"
        )

      view |> picker() |> render_click("confirm", %{})
      html = render(view)
      # Nothing available -> the confirm is refused, no message at all.
      refute html =~ ~s(id="picked")
    end

    test "a descendant-category preselect is confirmable (search expands the tree)", %{
      conn: conn,
      cat: cat
    } do
      parent = fixture_category(cat, %{name: "Kitchen"})
      child = fixture_category(cat, %{name: "Frames", parent_uuid: parent.uuid})

      {:ok, nested} =
        Catalogue.create_item(%{
          name: "Nested Frame",
          catalogue_uuid: cat.uuid,
          category_uuid: child.uuid
        })

      {:ok, view, _html} =
        live(
          conn,
          "/test/selector-host?c=#{cat.uuid}&cat_scope=#{parent.uuid}&pre=#{nested.uuid}:2&sel=click"
        )

      view |> picker() |> render_click("confirm", %{})
      html = render(view)

      assert html =~ "Nested Frame"
      assert html =~ "qty=2"
    end

    test "statuses scope hides inactive items from the grid", %{conn: conn, cat: cat} do
      {:ok, _inactive} =
        Catalogue.create_item(%{
          name: "Sleepy Widget",
          sku: "SLP-1",
          catalogue_uuid: cat.uuid,
          status: "inactive"
        })

      {:ok, _view, html} =
        live(conn, "/test/selector-host?c=#{cat.uuid}&statuses=active&sel=click")

      refute html =~ "Sleepy Widget"
      assert html =~ "M8 Screw"
    end

    test "selling price (markup applied) is what the card and snapshot show", %{
      conn: conn
    } do
      cat =
        fixture_catalogue(%{
          name: "Marked Up",
          markup_percentage: Decimal.new("10"),
          discount_percentage: Decimal.new("0")
        })

      {:ok, item} =
        Catalogue.create_item(%{
          name: "Priced Widget",
          sku: "PW-1",
          base_price: Decimal.new("100.00"),
          catalogue_uuid: cat.uuid
        })

      {:ok, view, html} = open(conn, "c=#{cat.uuid}&sel=click")

      assert html =~ "110.00"
      refute html =~ ">100.00<"

      view |> picker() |> render_click("card_click", %{"uuid" => item.uuid})
      view |> picker() |> render_click("confirm", %{})
      html = render(view)

      assert html =~ "line=110.00"
    end

    test "invalid qty commit bumps the stepper revision so morphdom recreates the input",
         %{
           conn: conn,
           cat: cat,
           screw: screw
         } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")
      uuid = to_string(screw.uuid)

      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
      html = render(view)
      assert html =~ ~s(id="picker-qty-#{uuid}-r0")

      html =
        view
        |> picker()
        |> render_click("qty_commit", %{"uuid" => uuid, "value" => "abc"})

      assert html =~ ~s(id="picker-qty-#{uuid}-r1")
      refute html =~ ~s(id="picker-qty-#{uuid}-r0")
    end

    test "exponent quantities are rejected, not parsed to 1e9", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")
      uuid = to_string(screw.uuid)

      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
      view |> picker() |> render_click("qty_commit", %{"uuid" => uuid, "value" => "1e9"})
      view |> picker() |> render_click("qty_commit", %{"uuid" => uuid, "value" => "1e1000000"})

      view |> picker() |> render_click("confirm", %{})
      html = render(view)
      assert html =~ "qty=1|"
    end

    test "a crafted payload with missing keys is a no-op, not a crash", %{conn: conn, cat: cat} do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")

      view |> picker() |> render_click("card_click", %{})
      view |> picker() |> render_click("qty_commit", %{"value" => "5"})
      html = view |> picker() |> render_click("nonsense_event", %{})

      # Still alive, still rendering.
      assert html =~ "M8 Screw"
    end
  end

  describe "single mode" do
    test "a second pick replaces the first", %{conn: conn, cat: cat, screw: screw, paint: paint} do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&mode=single&sel=click")

      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
      view |> picker() |> render_click("card_click", %{"uuid" => paint.uuid})
      view |> picker() |> render_click("confirm", %{})
      html = render(view)

      assert html =~ ~s(<span id="picked-count">1</span>)
      assert html =~ "White Paint"
      refute html =~ "pick-#{screw.uuid}"
    end

    test "immediate mode confirms on the tap itself", %{conn: conn, cat: cat, screw: screw} do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&mode=single&immediate=true&sel=click")

      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
      html = render(view)

      assert html =~ ~s(id="picked")
      assert html =~ "M8 Screw"
      assert html =~ ~s(id="closed")
    end
  end

  describe "multiple pickers on one page" do
    test "every element id stays unique", %{conn: conn, cat: cat} do
      {:ok, _view, html} = open(conn, "c=#{cat.uuid}&two=true&sel=click")

      # \s anchor: phx-value-uuid="…" contains the substring id="…", which
      # a naive scan counts as an element id.
      ids = Regex.scan(~r/\sid="([^"]+)"/, html, capture: :all_but_first) |> List.flatten()
      dupes = ids |> Enum.frequencies() |> Enum.filter(fn {_id, n} -> n > 1 end)

      assert dupes == [], "duplicate DOM ids: #{inspect(dupes)}"
    end
  end

  describe "hardening from the 2026-08-25 quorum review" do
    test "the search form routes submit — Enter must not become a native page load", %{
      conn: conn,
      cat: cat
    } do
      {:ok, view, html} = open(conn, "c=#{cat.uuid}&sel=click")

      # The attribute is the fix: a phx-change form WITHOUT phx-submit is
      # an "external form" to LiveView's client — Enter would run a native
      # submit and destroy the modal with every pick in it.
      assert has_element?(view, ~s(#picker-search-form[phx-submit="browse_search"]))
      assert html =~ ~s(phx-submit="browse_search")

      # And the routed submit is just a re-search.
      html =
        view
        |> element("#picker-search-form")
        |> render_submit(%{"search" => "M8"})

      assert html =~ "M8 Screw"
      refute html =~ "White Paint"
    end

    test "an :uncategorized_only scope offers no category chips", %{conn: conn, cat: cat} do
      _category = fixture_category(cat, %{name: "Visible Cat"})

      {:ok, _view, html} = open(conn, "c=#{cat.uuid}&only=uncategorized&sel=click")

      # Every chip would be an invalid action (search_items/2 raises on
      # the combination), so the whole row is suppressed.
      refute html =~ ~s(id="picker-chips")
    end

    test "a crafted browse_category with a non-UUID string is a no-op, not a crash", %{
      conn: conn,
      cat: cat
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")

      html = view |> picker() |> render_click("browse_category", %{"uuid" => "garbage"})

      # Without the reducer guard this raised Ecto.Query.CastError inside
      # the subtree expansion and took the host LiveView down.
      assert Process.alive?(view.pid)
      assert html =~ "M8 Screw"
    end

    test "hydrated preselect quantities are clamped like typed ones", %{
      conn: conn,
      cat: cat,
      screw: screw,
      paint: paint
    } do
      # Above the absolute ceiling → capped; below the minimum → floored.
      {:ok, view, _html} =
        open(conn, "c=#{cat.uuid}&pre=#{screw.uuid}:5000000,#{paint.uuid}:0&sel=click")

      view |> picker() |> render_click("confirm", %{})
      html = render(view)

      assert html =~ "qty=1000000"
      assert html =~ "qty=1"
    end

    test "single mode keeps at most one preselected entry", %{
      conn: conn,
      cat: cat,
      screw: screw,
      paint: paint
    } do
      {:ok, view, _html} =
        open(conn, "c=#{cat.uuid}&pre=#{paint.uuid}:1,#{screw.uuid}:1&mode=single&sel=click")

      view |> picker() |> render_click("confirm", %{})
      html = render(view)

      assert html =~ ~s(<span id="picked-count">1</span>)
    end

    test "a crafted confirm with nothing selected is refused outright", %{conn: conn, cat: cat} do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")

      view |> picker() |> render_click("confirm", %{})
      html = render(view)

      refute html =~ ~s(id="picked")
      refute html =~ ~s(id="closed")
    end

    test "a preselect under a soft-deleted catalogue is unavailable", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      # The search joins exclude items under deleted parents; hydration
      # must judge the same way or the tray blesses a row the browse could
      # never return.
      {:ok, _} = Catalogue.update_catalogue(cat, %{status: "deleted"})

      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&pre=#{screw.uuid}:2&sel=click")

      html = view |> picker() |> render_click("toggle_tray", %{})
      assert html =~ "Not available in this selection"

      view |> picker() |> render_click("confirm", %{})
      refute render(view) =~ ~s(id="picked")
    end

    test "with qty_min: 0 a typed \"0\" commits instead of reverting", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&min=0&sel=click")

      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
      view |> picker() |> render_click("qty_commit", %{"uuid" => screw.uuid, "value" => "0"})
      view |> picker() |> render_click("confirm", %{})

      assert render(view) =~ "qty=0"
    end

    test "a qty_commit for an unselected uuid changes nothing and cannot crash", %{
      conn: conn,
      cat: cat
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")

      view
      |> picker()
      |> render_click("qty_commit", %{"uuid" => Ecto.UUID.generate(), "value" => "5"})

      assert Process.alive?(view.pid)
      refute render(view) =~ ~s(id="picked")
    end

    test "a fresh search resets the selectable set — stale uuids are refused", %{
      conn: conn,
      cat: cat,
      screw: screw,
      paint: paint
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")

      # Narrow to paint only, then card_click the screw (rendered by the
      # PREVIOUS query, absent from this one): refused, so a later
      # confirm has nothing.
      view |> picker() |> render_change("browse_search", %{"search" => "Paint"})
      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
      view |> picker() |> render_click("confirm", %{})
      refute render(view) =~ ~s(id="picked")

      # Positive control: the currently-rendered card still selects.
      view |> picker() |> render_click("card_click", %{"uuid" => paint.uuid})
      view |> picker() |> render_click("confirm", %{})
      assert render(view) =~ ~s(<span id="picked-count">1</span>)
    end

    test "table is the default view and cards are one toggle away", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, html} = open(conn, "c=#{cat.uuid}&sel=click")

      # Default: the admin-look list — rows, headers, no photo cards.
      assert html =~ ~s(id="picker-table")
      assert html =~ ~s(id="picker-row-#{screw.uuid}")
      refute html =~ ~s(id="picker-card-#{screw.uuid}")
      assert html =~ "SKU"
      assert html =~ "Price"

      # The toggle flips to the photo grid and back.
      html = view |> picker() |> render_click("set_view", %{"mode" => "card"})
      assert html =~ ~s(id="picker-card-#{screw.uuid}")
      refute html =~ ~s(id="picker-table")

      html = view |> picker() |> render_click("set_view", %{"mode" => "table"})
      assert html =~ ~s(id="picker-table")
    end

    test "view=card starts on the photo grid and its DOM click still selects", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, html} = open(conn, "c=#{cat.uuid}&view=card&sel=click")

      assert html =~ ~s(id="picker-card-#{screw.uuid}")
      refute html =~ ~s(id="picker-table")

      # The card face's real binding, not the targeted shortcut. With
      # details on by default the figure AND the title are their own
      # buttons — target the select one (the rest of the body).
      view
      |> element(~s(#picker-card-#{screw.uuid} button[phx-click="card_click"]))
      |> render_click()

      view |> picker() |> render_click("confirm", %{})
      assert render(view) =~ ~s(<span id="picked-count">1</span>)
    end

    test "a table row's DOM click selects — and the qty cell does not toggle", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")

      # Row cells carry the same card_click binding the card face uses.
      # (The thumb AND name cells are the details affordance now, so
      # target a data cell — the sku one.)
      view
      |> element(~s(#picker-row-#{screw.uuid} td[phx-click="card_click"]), "M8-100")
      |> render_click()

      assert has_element?(view, ~s(#picker-row-#{screw.uuid}[data-selected="true"]))
      # The stepper appeared in the qty cell…
      assert has_element?(view, "#picker-qty-#{screw.uuid}-r0-input")
      # …and that cell is not click-bound, so stepping can't deselect.
      refute has_element?(view, ~s(#picker-row-#{screw.uuid} td:last-of-type[phx-click]))

      view |> picker() |> render_click("confirm", %{})
      assert render(view) =~ "M8 Screw|M8-100|qty=1|decimal=true|line=2.50"
    end

    test "columns are a host contract — nothing renders uninvited", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      # Client-safe embed: thumb + name + qty. No SKU, no price anywhere
      # in the list (2.50 is the screw's price).
      {:ok, _view, html} = open(conn, "c=#{cat.uuid}&cols=thumb,name,qty&sel=click")

      assert html =~ ~s(id="picker-row-#{screw.uuid}")
      refute html =~ "SKU"
      refute html =~ "Price"
      refute html =~ "2.50"
      refute html =~ "M8-100"
    end

    test "omitting the :qty column keeps quantities in the tray only", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&cols=name,price&sel=click")

      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})

      # Selected, but no inline stepper — the row has no qty cell.
      assert render(view) =~ ~s(data-selected="true")
      refute has_element?(view, "#picker-qty-#{screw.uuid}-r0-input")
    end

    test "unknown column entries raise instead of silently dropping", %{conn: conn, cat: cat} do
      exit_value = catch_exit(open(conn, "c=#{cat.uuid}&cols=name,bogus&sel=click"))
      assert inspect(exit_value) =~ "unknown entries"
    end

    test "show_prices/show_sku shape the DEFAULT columns", %{conn: conn, cat: cat} do
      # The host host-level opt-outs carry into the derived column set.
      {:ok, _view, html} = open(conn, "c=#{cat.uuid}&hide_prices=true&sel=click")

      refute html =~ "Price"
      assert html =~ "SKU"
    end

    test "the list adapts: staged columns and a widened modal, no sideways scroll", %{
      conn: conn,
      cat: cat
    } do
      {:ok, _view, html} = open(conn, "c=#{cat.uuid}&sel=click")

      # Low-priority columns carry their responsive stage on th AND td…
      # (unit rides inside the price cell and SKU starts hidden, so only
      # the lg stage appears in the default visible set).
      assert html =~ "hidden lg:table-cell"
      # …and the modal box grows past core Modal's 4xl cap on big screens.
      assert html =~ "xl:max-w-6xl"
      assert html =~ "2xl:max-w-7xl"
    end

    test "price is the SELLING price with inline unit; base_price is opt-in raw", %{
      conn: conn
    } do
      # 10% catalogue markup: base 10.00 sells at 11.00. The client-facing
      # default must show the selling price (with the unit folded in) and
      # never the raw number.
      marked = fixture_catalogue(%{name: "Marked Cat", markup_percentage: Decimal.new("10")})

      {:ok, _item} =
        Catalogue.create_item(%{
          name: "Marked Widget",
          catalogue_uuid: marked.uuid,
          base_price: Decimal.new("10.00"),
          unit: "set"
        })

      {:ok, view, html} = open(conn, "c=#{marked.uuid}")
      assert html =~ "11.00"
      assert html =~ "/ set"
      refute has_element?(view, "#picker-table th", "Unit")
      refute has_element?(view, "#picker-table th", "Base price")
      refute html =~ ">10.00<"

      # An internal embed asks for the raw column explicitly.
      {:ok, view, html} = open(conn, "c=#{marked.uuid}&cols=name,base_price")
      assert has_element?(view, "#picker-table th", "Base price")
      assert html =~ "10.00"
      refute html =~ "11.00"
    end

    test "SKU (article) starts VISIBLE; the Columns dropdown can hide it", %{
      conn: conn,
      cat: cat
    } do
      # Default-visible since 2026-08-31 (boss: "make article by
      # default"); only :breadcrumb starts hidden now.
      {:ok, view, html} = open(conn, "c=#{cat.uuid}&sel=click")

      assert has_element?(view, "#picker-table th", "SKU")
      assert html =~ "M8-100"
      refute has_element?(view, "#picker-table th", "Category prefix")

      # Hiding removes header and data both; re-showing brings them back.
      view |> picker() |> render_click("toggle_column", %{"col" => "sku"})
      refute has_element?(view, "#picker-table th", "SKU")
      refute render(view) =~ "M8-100"

      view |> picker() |> render_click("toggle_column", %{"col" => "sku"})
      assert has_element?(view, "#picker-table th", "SKU")
      assert render(view) =~ "M8-100"
    end

    test "toggle_column refuses pinned and ungranted columns", %{conn: conn, cat: cat} do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")

      # :name is the last visible identity column here; :base_price was
      # never granted; garbage is garbage.
      view |> picker() |> render_click("toggle_column", %{"col" => "name"})
      view |> picker() |> render_click("toggle_column", %{"col" => "base_price"})
      view |> picker() |> render_click("toggle_column", %{"col" => "bogus"})

      assert has_element?(view, "#picker-table th", "Name")
      refute has_element?(view, "#picker-table th", "Base price")
      assert Process.alive?(view.pid)
    end

    test "breadcrumb: the category prefix gets its own unlabeled column beside Name", %{
      conn: conn,
      cat: cat
    } do
      fasteners = fixture_category(cat, %{name: "Fasteners"})

      {:ok, _} =
        Catalogue.create_item(%{
          name: "Wood screws 4x40 (100pk)",
          catalogue_uuid: cat.uuid,
          category_uuid: fasteners.uuid
        })

      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")
      to_items_mode(view)

      # Off by default, offered in the dropdown.
      refute render(view) =~ "Fasteners /"
      assert has_element?(view, ~s(#picker-column-toggle [phx-value-col="breadcrumb"]))

      view |> picker() |> render_click("toggle_column", %{"col" => "breadcrumb"})
      # Redundant standalone Category column can go in its favour.
      view |> picker() |> render_click("toggle_column", %{"col" => "category"})

      html = render(view)
      # The prefix lives in its OWN cell — muted, slash-terminated — and
      # the name stays clean in the Name column.
      assert html =~ "Fasteners /"
      assert has_element?(view, "#picker-table td", "Fasteners /")
      assert has_element?(view, "#picker-table th", "Name")
      refute has_element?(view, "#picker-table th", "Category")

      # An uncategorized row simply leaves the prefix cell empty (the seed
      # items have no category and must not render a stray slash).
      refute html =~ "> /<"

      # Name is the identity column and cannot be hidden.
      view |> picker() |> render_click("toggle_column", %{"col" => "name"})
      assert has_element?(view, "#picker-table th", "Name")
    end

    test "quantity-first pins the qty column — the selector cannot be hidden", %{
      conn: conn,
      cat: cat
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=quantity")

      refute has_element?(view, ~s(#picker-column-toggle [phx-value-col="qty"]))
      view |> picker() |> render_click("toggle_column", %{"col" => "qty"})
      assert has_element?(view, "#picker-table th", "Qty")
    end

    test "hidden_columns is the host's knob — empty list shows SKU from the start", %{
      conn: conn,
      cat: cat
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&hide=&sel=click")

      assert has_element?(view, "#picker-table th", "SKU")
    end

    test "the Uncategorized chip makes the filters add up", %{conn: conn, cat: cat} do
      # Categorized and uncategorized items coexist; without this chip the
      # category chips can never reach the loose items.
      tools = fixture_category(cat, %{name: "Tools"})

      {:ok, _} =
        Catalogue.create_item(%{
          name: "Torx Driver",
          catalogue_uuid: cat.uuid,
          category_uuid: tools.uuid
        })

      {:ok, view, html} = open(conn, "c=#{cat.uuid}&sel=click")
      assert html =~ "Uncategorized"

      # Narrow to the loose items: the categorized one disappears, the
      # uncategorized seed items stay.
      html = view |> picker() |> render_click("browse_category", %{"uuid" => "__uncategorized__"})
      refute html =~ "Torx Driver"
      assert html =~ "M8 Screw"

      # All returns to the ROOT, which is the category browser again —
      # the flat list (and the categorized item) is one switch away.
      html = view |> picker() |> render_click("browse_category", %{"uuid" => ""})
      refute html =~ "Torx Driver"

      html = to_items_mode(view)
      assert html =~ "Torx Driver"
    end

    test "the Uncategorized chip stays away from scopes that cannot accept it", %{
      conn: conn,
      cat: cat
    } do
      tools = fixture_category(cat, %{name: "Tools"})

      {:ok, _} =
        Catalogue.create_item(%{
          name: "Torx Driver",
          catalogue_uuid: cat.uuid,
          category_uuid: tools.uuid
        })

      # Category-restricted scope: uncategorized sits outside it.
      {:ok, _view, html} = open(conn, "c=#{cat.uuid}&cat_scope=#{tools.uuid}&sel=click")
      refute html =~ "Uncategorized"

      # And a crafted event is refused by the reducer either way.
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&cat_scope=#{tools.uuid}&sel=click")
      html = view |> picker() |> render_click("browse_category", %{"uuid" => "__uncategorized__"})
      assert html =~ "Torx Driver"
    end

    test "cards honor the columns contract — no price/SKU one toggle away", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      # Host granted neither :price nor :sku. The table hides them; the
      # card view must not have them reappear.
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&cols=thumb,name,qty&sel=click")

      html = view |> picker() |> render_click("set_view", %{"mode" => "card"})
      assert html =~ ~s(id="picker-card-#{screw.uuid}")
      refute html =~ "2.50"
      refute html =~ "M8-100"

      # A viewer-HIDDEN column stays hidden on cards too (visible drives
      # both views) — sku is default-visible now, so hide it first.
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")
      view |> picker() |> render_click("toggle_column", %{"col" => "sku"})
      html = view |> picker() |> render_click("set_view", %{"mode" => "card"})
      refute html =~ ~s(class="font-mono text-xs text-base-content/60">M8-100)

      view |> picker() |> render_click("set_view", %{"mode" => "table"})
      view |> picker() |> render_click("toggle_column", %{"col" => "sku"})
      html = view |> picker() |> render_click("set_view", %{"mode" => "card"})
      assert html =~ "M8-100"
    end

    test "root covers the subtree; a drilled level lists its own items; search covers the subtree again",
         %{conn: conn, cat: cat} do
      # Admin-page semantics since 2026-08-31 (the tiles rework): standing
      # in a category shows ITS items — subtree coverage belongs to the
      # popup root and to search. (Before the tiles, chips were flat and a
      # parent chip had to mean the whole subtree; that pin lived here.)
      parent = fixture_category(cat, %{name: "Parent Scope"})
      child = fixture_category(cat, %{name: "Child Scope", parent_uuid: parent.uuid})

      {:ok, _} =
        Catalogue.create_item(%{
          name: "Deep Nested Item",
          catalogue_uuid: cat.uuid,
          category_uuid: child.uuid
        })

      # Root of a parent-scoped popup, Items mode: the whole subtree.
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&cat_scope=#{parent.uuid}&sel=click")
      assert to_items_mode(view) =~ "Deep Nested Item"

      # Drilling into the parent level: its own (zero) items, its child
      # as a tile to drill on.
      html = view |> picker() |> render_click("browse_category", %{"uuid" => parent.uuid})
      refute html =~ "Deep Nested Item"
      assert html =~ "Child Scope"

      # A search from the drilled level still finds down the subtree.
      html = view |> picker() |> render_change("browse_search", %{"search" => "deep"})
      assert html =~ "Deep Nested Item"

      # Clearing the search returns to the level's own listing.
      html = view |> picker() |> render_change("browse_search", %{"search" => ""})
      refute html =~ "Deep Nested Item"

      # And the child level lists the item directly.
      html = view |> picker() |> render_click("browse_category", %{"uuid" => child.uuid})
      assert html =~ "Deep Nested Item"
    end

    test "qty bounds that invert after precision rounding raise at init", %{
      conn: conn,
      cat: cat
    } do
      # precision 0: min 1 (ceiled) vs max 0.9 -> 0 (floored) — every qty
      # would silently collapse to 0. Config fails loud instead.
      exit_value = catch_exit(open(conn, "c=#{cat.uuid}&max=0&min=1&sel=click"))
      assert inspect(exit_value) =~ "rounds below"
    end

    test "quantity + single + immediate delivers the TYPED quantity", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=quantity&mode=single&immediate=true")

      # Typing 5 into an unselected row confirms immediately — with 5, not
      # the default the old ordering shipped before the typed value landed.
      view |> picker() |> render_click("qty_commit", %{"uuid" => screw.uuid, "value" => "5"})

      html = render(view)
      assert html =~ ~s(<span id="picked-count">1</span>)
      assert html =~ "qty=5"
    end

    test "quantity-first with qty_min: 0 — zero deselects everywhere", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=quantity&min=0")

      # Arrow up then back to zero: the line is gone, not a zero-qty pick.
      view |> picker() |> render_click("qty_change", %{"uuid" => screw.uuid, "value" => "1"})
      view |> picker() |> render_click("qty_change", %{"uuid" => screw.uuid, "value" => "0"})
      view |> picker() |> render_click("confirm", %{})
      refute render(view) =~ ~s(id="picked")

      # Committing "0" on a selected row removes it too.
      view |> picker() |> render_click("qty_change", %{"uuid" => screw.uuid, "value" => "1"})
      view |> picker() |> render_click("qty_commit", %{"uuid" => screw.uuid, "value" => "0"})
      view |> picker() |> render_click("confirm", %{})
      refute render(view) =~ ~s(id="picked")
    end

    # The arrows stop at min="0" in this mode even when qty_min is higher —
    # so a zero arriving on a selected row must deselect, not be rejected
    # as below-minimum and strand the row showing 0 while holding qty 1.
    test "quantity-first with the default qty_min: zero still deselects", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=quantity")

      view |> picker() |> render_click("qty_change", %{"uuid" => screw.uuid, "value" => "1"})
      view |> picker() |> render_click("qty_change", %{"uuid" => screw.uuid, "value" => "0"})
      view |> picker() |> render_click("confirm", %{})
      refute render(view) =~ ~s(id="picked")
    end

    test "quantity mode without the :qty column is a config error", %{conn: conn, cat: cat} do
      exit_value = catch_exit(open(conn, "c=#{cat.uuid}&sel=quantity&cols=name,price"))
      assert inspect(exit_value) =~ "requires the :qty column"
    end

    test "quantity mode force-shows a merely hidden :qty column", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=quantity&hide=qty")

      assert has_element?(view, "#picker-qty-#{screw.uuid}-r0-input")
    end

    test "omitting :qty keeps quantities tray-only in BOTH views", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&cols=thumb,name,price&sel=click")

      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
      refute has_element?(view, "#picker-qty-#{screw.uuid}-r0-input")

      # The card footer honored show-everything before; it follows the
      # columns contract now.
      view |> picker() |> render_click("set_view", %{"mode" => "card"})
      refute has_element?(view, "#picker-qty-#{screw.uuid}-r0-input")
    end

    test "a qty_min above the safety ceiling is a config error", %{conn: conn, cat: cat} do
      exit_value = catch_exit(open(conn, "c=#{cat.uuid}&min=2000000&sel=click"))
      assert inspect(exit_value) =~ "safety ceiling"
    end

    test "quantity-first: every row is an order line, no click-selection", %{
      conn: conn,
      cat: cat,
      screw: screw,
      paint: paint
    } do
      {:ok, view, html} = open(conn, "c=#{cat.uuid}&sel=quantity")

      # Quantity controls at 0 on every rendered row; rows are not
      # click-targets.
      assert has_element?(view, ~s(#picker-qty-#{screw.uuid}-r0-input[value="0"]))
      assert has_element?(view, ~s(#picker-qty-#{paint.uuid}-r0-input[value="0"]))
      refute html =~ ~s(phx-click="card_click")

      # An arrow up on an unselected row selects at that quantity…
      view |> picker() |> render_click("qty_change", %{"uuid" => screw.uuid, "value" => "1"})
      # …and typing a positive quantity selects at that quantity.
      view |> picker() |> render_click("qty_commit", %{"uuid" => paint.uuid, "value" => "5"})

      view |> picker() |> render_click("confirm", %{})
      html = render(view)
      assert html =~ ~s(<span id="picked-count">2</span>)
      assert html =~ "M8 Screw|M8-100|qty=1|"
      assert html =~ "White Paint|PAINT-W|qty=5|"
    end

    test "quantity-first: back to zero is deselection, zero input stays nothing", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=quantity")

      # Typing "0" on an untouched row selects nothing.
      view |> picker() |> render_click("qty_commit", %{"uuid" => screw.uuid, "value" => "0"})
      view |> picker() |> render_click("confirm", %{})
      refute render(view) =~ ~s(id="picked")

      # Up then back down to zero removes the line entirely.
      view |> picker() |> render_click("qty_change", %{"uuid" => screw.uuid, "value" => "1"})
      view |> picker() |> render_click("qty_change", %{"uuid" => screw.uuid, "value" => "0"})
      view |> picker() |> render_click("confirm", %{})
      refute render(view) =~ ~s(id="picked")
    end

    test "quantity-first: crafted clicks and foreign uuids stay refused", %{
      conn: conn,
      cat: cat,
      screw: screw,
      forbidden: forbidden
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=quantity")

      # card_click has no meaning in this mode — even crafted.
      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
      # A quantity event for an item this modal never rendered is refused
      # by the same presented gate that guards clicks — change and commit
      # alike.
      view |> picker() |> render_click("qty_change", %{"uuid" => forbidden.uuid, "value" => "1"})
      view |> picker() |> render_click("qty_commit", %{"uuid" => forbidden.uuid, "value" => "3"})

      view |> picker() |> render_click("confirm", %{})
      refute render(view) =~ ~s(id="picked")
    end

    test "the category column shows each item's category, host-omittable", %{
      conn: conn,
      cat: cat
    } do
      shelving = fixture_category(cat, %{name: "Shelving"})

      {:ok, _item} =
        Catalogue.create_item(%{
          name: "Wall Bracket",
          catalogue_uuid: cat.uuid,
          category_uuid: shelving.uuid
        })

      # Default columns include Category, populated per row. Assertions
      # scope to the table — the chips row legitimately shows the name
      # regardless of columns (navigation, not data).
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")
      to_items_mode(view)
      assert has_element?(view, "#picker-table th", "Category")
      assert has_element?(view, "#picker-table td", "Shelving")

      # A host that leaves it out shows neither header nor value.
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&cols=name,qty&sel=click")
      to_items_mode(view)
      refute has_element?(view, "#picker-table th", "Category")
      refute has_element?(view, "#picker-table td", "Shelving")
    end

    test "a parent-category scope shows and accepts descendant chips", %{conn: conn, cat: cat} do
      parent = fixture_category(cat, %{name: "Parent Cat"})
      child = fixture_category(cat, %{name: "Child Cat", parent_uuid: parent.uuid})

      {:ok, _nested} =
        Catalogue.create_item(%{
          name: "Nested Item",
          catalogue_uuid: cat.uuid,
          category_uuid: child.uuid
        })

      {:ok, view, html} = open(conn, "c=#{cat.uuid}&cat_scope=#{parent.uuid}&sel=click")

      # The subtree is part of the scope, so its tiles must be offered…
      assert html =~ "Child Cat"
      assert to_items_mode(view) =~ "Nested Item"

      # …and narrowing to a descendant is accepted, not rejected as
      # out-of-scope.
      html = view |> picker() |> render_click("browse_category", %{"uuid" => child.uuid})
      assert html =~ "Nested Item"
    end
  end

  describe "context header and tray flexibility (2026-08-30)" do
    test "the header shows the scoped catalogue instead of a bare title", %{
      conn: conn,
      cat: cat
    } do
      {:ok, _view, html} = open(conn, "c=#{cat.uuid}&sel=click")

      assert html =~ "Picker Catalogue"
      refute html =~ "Select items"
    end

    test "a scoped category outranks its catalogue in the header", %{conn: conn, cat: cat} do
      shelving = fixture_category(cat, %{name: "Shelving Wall"})

      {:ok, _view, html} = open(conn, "c=#{cat.uuid}&cat_scope=#{shelving.uuid}&sel=click")

      assert html =~ "Shelving Wall"
    end

    test "context_header off falls back to the plain title; explicit title wins", %{
      conn: conn,
      cat: cat
    } do
      {:ok, _view, html} = open(conn, "c=#{cat.uuid}&ch=false&sel=click")
      assert html =~ "Select items"
      refute html =~ ~s(class="w-12 h-12 rounded-lg)

      {:ok, _view, html} = open(conn, "c=#{cat.uuid}&title=Order+sheet&sel=click")
      assert html =~ "Order sheet"
    end

    test "show_tray off hides the cart button and refuses its toggle", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, html} = open(conn, "c=#{cat.uuid}&tray=false&sel=click")

      refute html =~ "toggle_tray"
      # Confirm still works without the tray chrome.
      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
      view |> picker() |> render_click("toggle_tray", %{})
      refute render(view) =~ "remove_pick"

      view |> picker() |> render_click("confirm", %{})
      assert render(view) =~ ~s(id="picked")
    end
  end

  describe "item details page (2026-08-30)" do
    # ON by default since 2026-08-31 (Max's call); false is the opt-out
    # for embeds that must not expose the detail body.
    test "on by default; details=false removes the affordance and refuses the event", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, _view, html} = open(conn, "c=#{cat.uuid}&sel=click")
      assert html =~ ~s(phx-click="show_detail")

      {:ok, view, html} = open(conn, "c=#{cat.uuid}&sel=click&details=false")
      refute html =~ "show_detail"

      view |> picker() |> render_click("show_detail", %{"uuid" => to_string(screw.uuid)})
      refute render(view) =~ "close_detail"
    end

    test "thumb opens the details page; Back returns to the intact list", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, html} = open(conn, "c=#{cat.uuid}&details=true&sel=click")

      # The affordance is wired in the table rows.
      assert html =~ ~s(phx-click="show_detail")

      # Narrow the search first — Back must land on the narrowed list.
      view |> picker() |> render_change("browse_search", %{"search" => "screw"})

      html = view |> picker() |> render_click("show_detail", %{"uuid" => to_string(screw.uuid)})
      assert html =~ "M8 Screw"
      assert html =~ "close_detail"
      # The detail fields include the SKU row from ProductCard.
      assert html =~ "M8-100"

      html = view |> picker() |> render_click("close_detail", %{})
      refute html =~ "close_detail"
      # The narrowed search survived the round trip.
      assert html =~ "M8 Screw"
      refute html =~ "White Paint"
    end

    test "clicking the title is the same as clicking the image — both open details", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      # Quantity mode (the default) — where the title used to be dead.
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}")

      # Table: the NAME cell carries the same details binding the thumb does.
      view
      |> element(~s(#picker-row-#{screw.uuid} td[phx-click="show_detail"]), "M8 Screw")
      |> render_click()

      assert render(view) =~ "close_detail"
      view |> picker() |> render_click("close_detail", %{})

      # Cards: the TITLE is its own details button beside the figure's.
      view |> picker() |> render_click("set_view", %{"mode" => "card"})

      view
      |> element(~s(#picker-card-#{screw.uuid} button[phx-click="show_detail"]), "M8 Screw")
      |> render_click()

      assert render(view) =~ "close_detail"
    end

    test "a foreign uuid is refused by the rendered-uuid gate", %{
      conn: conn,
      cat: cat,
      forbidden: forbidden
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&details=true&sel=click")

      view |> picker() |> render_click("show_detail", %{"uuid" => to_string(forbidden.uuid)})
      html = render(view)
      refute html =~ "close_detail"
      refute html =~ "Forbidden Item"
    end

    test "click mode: Add from the detail footer lands in the confirm payload", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&details=true&sel=click")
      uuid = to_string(screw.uuid)

      view |> picker() |> render_click("show_detail", %{"uuid" => uuid})
      html = view |> picker() |> render_click("card_click", %{"uuid" => uuid})
      # The footer flipped to the remove state.
      assert html =~ "Remove from selection"

      view |> picker() |> render_click("confirm", %{})
      assert render(view) =~ "M8 Screw|M8-100|qty=1"
    end

    test "quantity mode: the detail footer's input selects at the typed quantity", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&details=true&sel=quantity")
      uuid = to_string(screw.uuid)

      view |> picker() |> render_click("show_detail", %{"uuid" => uuid})
      view |> picker() |> render_click("qty_commit", %{"uuid" => uuid, "value" => "4"})
      view |> picker() |> render_click("confirm", %{})

      assert render(view) =~ "qty=4"
    end

    test "the detail page honours show_prices", %{conn: conn, cat: cat, screw: screw} do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&details=true&hide_prices=true&sel=click")

      html = view |> picker() |> render_click("show_detail", %{"uuid" => to_string(screw.uuid)})
      # The screw has base_price 2.50; with prices hidden the detail
      # fields must not show it.
      refute html =~ "2.50"
    end

    # 2026-08-31 external-review fixes.
    test "an unavailable preselect's detail is refused — its body is what the scope excludes",
         %{conn: conn, cat: cat, forbidden: forbidden} do
      {:ok, view, _html} =
        open(conn, "c=#{cat.uuid}&details=true&pre=#{forbidden.uuid}:1&sel=click")

      # The tray may name it (shown-but-excluded, by design)…
      view |> picker() |> render_click("toggle_tray", %{})
      assert render(view) =~ "Not available in this selection"

      # …but a crafted show_detail must not open its full body.
      view |> picker() |> render_click("show_detail", %{"uuid" => to_string(forbidden.uuid)})
      refute has_element?(view, "#picker-detail-card")
    end

    test "a crafted NaN or Infinity quantity mutates nothing", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=quantity")
      uuid = to_string(screw.uuid)

      view |> picker() |> render_click("qty_change", %{"uuid" => uuid, "value" => "2"})

      for garbage <- ["NaN", "Infinity", "-Infinity"] do
        view |> picker() |> render_click("qty_change", %{"uuid" => uuid, "value" => garbage})
        view |> picker() |> render_click("qty_commit", %{"uuid" => uuid, "value" => garbage})
      end

      view |> picker() |> render_click("confirm", %{})
      assert render(view) =~ "qty=2"
    end

    # Direct pin on the ProductCard.build_fields/3 grants the detail page
    # relies on (2026-08-31 delta audit — the LV test above covers price
    # only; sku needs its own).
    test "build_fields/3 honours include_price and include_sku", %{screw: screw} do
      alias PhoenixKitCatalogue.Web.Components.ProductCard

      item = Catalogue.get_item!(to_string(screw.uuid))

      full = ProductCard.build_fields(item, "en")
      assert Enum.any?(full, fn {_l, v} -> v == "M8-100" end)
      assert Enum.any?(full, fn {_l, v} -> v =~ "2.50" end)

      no_sku = ProductCard.build_fields(item, "en", include_sku: false)
      refute Enum.any?(no_sku, fn {_l, v} -> v == "M8-100" end)

      no_price = ProductCard.build_fields(item, "en", include_price: false)
      refute Enum.any?(no_price, fn {_l, v} -> v =~ "2.50" end)
    end

    test "revoking show_prices while a detail is open rebuilds its fields", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&details=true&sel=click")

      view |> picker() |> render_click("show_detail", %{"uuid" => to_string(screw.uuid)})
      assert view |> element("#picker-detail-card") |> render() =~ "2.50"

      # The HOST re-renders with show_prices flipped off — the open
      # detail must drop the price row, not keep the stale grant. (The
      # list's :price COLUMN stays granted — grants are init-time; only
      # the detail body re-reads the display flags.)
      render_click(view, "toggle_prices", %{})
      refute view |> element("#picker-detail-card") |> render() =~ "2.50"
    end
  end

  describe "2026-08-31 quality-sweep pins" do
    test "load_more accretes the presented gate — page-2 rows stay selectable", %{
      conn: conn,
      cat: cat
    } do
      {:ok, third} =
        Catalogue.create_item(%{name: "Za Last Item", sku: "ZZZ-1", catalogue_uuid: cat.uuid})

      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&pp=2")

      # Page 1 holds 2 of 3 items; the third arrives via load_more…
      refute has_element?(view, "#picker-row-#{third.uuid}")
      view |> picker() |> render_click("load_more", %{})
      assert has_element?(view, "#picker-row-#{third.uuid}")

      # …and is fully interactive: the presented gate must have accreted
      # page 2, or every event for it is refused and the grid below the
      # fold is dead while shipping green.
      view
      |> picker()
      |> render_click("qty_change", %{"uuid" => to_string(third.uuid), "value" => "3"})

      view |> picker() |> render_click("confirm", %{})
      assert render(view) =~ "Za Last Item|ZZZ-1|qty=3"
    end

    test "the tray's remove drops exactly the named pick and its draft state", %{
      conn: conn,
      cat: cat,
      screw: screw,
      paint: paint
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")

      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
      view |> picker() |> render_click("card_click", %{"uuid" => paint.uuid})
      view |> picker() |> render_click("remove_pick", %{"uuid" => to_string(screw.uuid)})
      view |> picker() |> render_click("confirm", %{})

      html = render(view)
      assert html =~ ~s(<span id="picked-count">1</span>)
      assert html =~ "White Paint"
      refute html =~ "M8 Screw|M8-100|qty="
    end

    test "a double-clicked confirm delivers the picks exactly once", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")

      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
      view |> picker() |> render_click("confirm", %{})
      view |> picker() |> render_click("confirm", %{})

      assert render(view) =~ ~s(<span id="picked-messages">1</span>)
    end

    test "immediate mode confirms on the COMMIT, never on the debounced live value", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=quantity&mode=single&immediate=true")
      uuid = to_string(screw.uuid)

      # The live path selects but must not confirm — a debounce firing
      # mid-typing ("1" on the way to "15") would close the modal early.
      view |> picker() |> render_click("qty_change", %{"uuid" => uuid, "value" => "1"})
      refute render(view) =~ ~s(id="picked")

      view |> picker() |> render_click("qty_commit", %{"uuid" => uuid, "value" => "15"})
      assert render(view) =~ "qty=15"
    end

    test "the detail page honours the columns GRANT, not only the flags", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      # The client-safe shape: no :price, no :sku granted.
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&cols=thumb,name,qty")

      view |> picker() |> render_click("show_detail", %{"uuid" => to_string(screw.uuid)})

      detail = view |> element("#picker-detail-card") |> render()
      refute detail =~ "2.50"
      refute detail =~ "M8-100"
    end

    test "garbage preselect keys drop instead of crashing the host at mount", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, _html} =
        open(conn, "c=#{cat.uuid}&sel=click&pre=not-a-uuid:1,#{screw.uuid}:2")

      # The valid key hydrated; the garbage one is "unresolvable" and
      # dropped — previously it raised Ecto.Query.CastError in update/2.
      view |> picker() |> render_click("confirm", %{})
      html = render(view)
      assert html =~ ~s(<span id="picked-count">1</span>)
      assert html =~ "qty=2"
    end
  end

  describe "checkbox column (2026-08-30)" do
    test "click mode leads with unchecked checkboxes; selecting checks the box", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      # Either-or (2026-08-31): the checkbox flavour is the popup WITHOUT
      # a :qty column — hiding it derives click mode with checkboxes.
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&hide=qty,sku,breadcrumb")

      # Visible before the first pick — the affordance is the point.
      assert has_element?(view, "#picker-row-#{screw.uuid} input[type=checkbox]")
      refute has_element?(view, "#picker-row-#{screw.uuid} input[type=checkbox][checked]")

      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})

      assert has_element?(view, "#picker-row-#{screw.uuid} input[type=checkbox][checked]")
      # The checkbox replaces the name-cell check icon — one selected
      # signal per row, not two a cell apart.
      refute has_element?(view, "#picker-row-#{screw.uuid} .hero-check")
    end

    test "quantity mode renders no checkbox column", %{conn: conn, cat: cat, screw: screw} do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=quantity")

      assert has_element?(view, "#picker-row-#{screw.uuid}")
      refute has_element?(view, "#picker-row-#{screw.uuid} input[type=checkbox]")
    end

    # Either-or (2026-08-31): the default flavour derives from the
    # columns — a visible :qty column IS the amount mode.
    test "the default with a :qty column is quantity-first, no checkboxes", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, html} = open(conn, "c=#{cat.uuid}")

      # Inputs at 0 on every row, no checkbox, rows not click-targets.
      assert has_element?(view, ~s(#picker-qty-#{screw.uuid}-r0-input[value="0"]))
      refute has_element?(view, "#picker-row-#{screw.uuid} input[type=checkbox]")
      refute html =~ ~s(phx-click="card_click")

      # A number above zero IS the selection.
      view
      |> picker()
      |> render_click("qty_change", %{"uuid" => to_string(screw.uuid), "value" => "2"})

      view |> picker() |> render_click("confirm", %{})
      assert render(view) =~ "qty=2"
    end

    test "the default without a :qty column is the checkbox flavour", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&cols=thumb,name,price")

      assert has_element?(view, "#picker-row-#{screw.uuid} input[type=checkbox]")
      refute has_element?(view, "#picker-qty-#{screw.uuid}-r0-input")

      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
      assert has_element?(view, "#picker-row-#{screw.uuid} input[type=checkbox][checked]")
    end

    test "forcing click with a visible :qty keeps the legacy stepper-on-select, no checkbox", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")

      # Either-or holds even when forced: qty visible → no checkbox.
      refute has_element?(view, "#picker-row-#{screw.uuid} input[type=checkbox]")
      refute has_element?(view, "#picker-qty-#{screw.uuid}-r0-input")

      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
      assert has_element?(view, ~s(#picker-qty-#{screw.uuid}-r0-input[value="1"]))
    end

    test "the native control carries the mode's floor: qty_min in click mode, 0 in quantity mode",
         %{conn: conn, cat: cat, screw: screw} do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&min=2&sel=click")
      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
      assert has_element?(view, ~s(#picker-qty-#{screw.uuid}-r0-input[min="2"]))

      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=quantity&min=2")
      assert has_element?(view, ~s(#picker-qty-#{screw.uuid}-r0-input[min="0"]))
    end
  end

  describe "subcategory tiles (admin-style levels)" do
    # The flat chip strip became one level of the admin pages' category
    # tiles (2026-08-31): drill down a tile, climb back with Up, and the
    # level you stand in lists its own items.
    setup %{cat: cat} do
      parent = fixture_category(cat, %{name: "Fasteners"})
      child = fixture_category(cat, %{name: "Bolts", parent_uuid: parent.uuid})

      {:ok, bolt} =
        Catalogue.create_item(%{
          name: "Hex Bolt",
          catalogue_uuid: cat.uuid,
          category_uuid: child.uuid
        })

      %{parent: parent, child: child, bolt: bolt}
    end

    test "root tiles are the top level; drilling and Up walk the tree", %{
      conn: conn,
      cat: cat,
      parent: parent,
      child: child
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")

      # Top-level category as a tile; the nested one is not offered yet.
      assert has_element?(
               view,
               ~s(#picker-levelnav button[phx-value-uuid="#{parent.uuid}"]),
               "Fasteners"
             )

      refute has_element?(view, ~s(#picker-levelnav button[phx-value-uuid="#{child.uuid}"]))

      view |> picker() |> render_click("browse_category", %{"uuid" => parent.uuid})

      assert has_element?(
               view,
               ~s(#picker-levelnav button[phx-value-uuid="#{child.uuid}"]),
               "Bolts"
             )

      # Up from a root-level tile returns to the popup root.
      assert has_element?(view, ~s(#picker-levelnav button[phx-value-uuid=""]), "Up")

      view |> picker() |> render_click("browse_category", %{"uuid" => child.uuid})

      # Up from the child names its actual parent; the level lists its item.
      assert has_element?(
               view,
               ~s(#picker-levelnav button[phx-value-uuid="#{parent.uuid}"]),
               "Up"
             )

      assert render(view) =~ "Hex Bolt"
    end

    test "the level follows the view toggle: rows in table view, tiles in cards", %{
      conn: conn,
      cat: cat,
      parent: parent
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")

      # Table view (the default): the root category browser renders as
      # table ROWS — the admin tables' shared columns — not tiles. The
      # switcher labels the root, so no section headings in a pure mode.
      assert has_element?(view, "#picker-levelnav-table")

      assert has_element?(
               view,
               ~s(#picker-levelnav-table button[phx-value-uuid="#{parent.uuid}"]),
               "Fasteners"
             )

      assert has_element?(view, "#picker-root-mode button", "Categories")
      refute has_element?(view, "#picker-items-heading")

      # Card view: the shared admin tiles, no table.
      view |> picker() |> render_click("set_view", %{"mode" => "card"})
      refute has_element?(view, "#picker-levelnav-table")

      assert has_element?(
               view,
               ~s(#picker-levelnav button[phx-value-uuid="#{parent.uuid}"]),
               "Fasteners"
             )

      # Drilled: both sections, headed like the admin's.
      view |> picker() |> render_click("browse_category", %{"uuid" => parent.uuid})
      assert has_element?(view, "#picker-levelnav div", "Subcategories")
      assert has_element?(view, "#picker-items-heading", "Items")
    end

    test "the root is either-or like the admin: category browser first, flat list one switch away",
         %{conn: conn, cat: cat} do
      {:ok, view, html} = open(conn, "c=#{cat.uuid}&sel=click")

      # Categories mode (default): the outline only — no item rows, not
      # even the seed items ("in the hardware catalogue there are 3
      # items, why am I seeing 9" — Max, 2026-08-31: root showed the
      # outline AND the flat list at once; the admin shows one or the
      # other).
      assert has_element?(view, "#picker-levelnav")
      refute html =~ "M8-100"

      # Items mode: everything in scope as one flat list, outline hidden.
      html = to_items_mode(view)
      assert html =~ "M8-100"
      assert html =~ "Hex Bolt"
      refute has_element?(view, "#picker-levelnav")

      # And back. The switch is presentation only — nothing refetched,
      # nothing deselected.
      html = view |> picker() |> render_click("set_root_mode", %{"mode" => "categories"})
      refute html =~ "M8-100"
      assert has_element?(view, "#picker-levelnav")
    end

    test "the Uncategorized drill is a root tile", %{conn: conn, cat: cat} do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")

      assert has_element?(
               view,
               ~s(#picker-levelnav button[phx-value-uuid="__uncategorized__"]),
               "Uncategorized"
             )

      html = view |> picker() |> render_click("browse_category", %{"uuid" => "__uncategorized__"})
      assert html =~ "M8 Screw"
      refute html =~ "Hex Bolt"
    end

    test "tiles hide while a search is active — results cover the subtree", %{
      conn: conn,
      cat: cat
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")
      assert has_element?(view, "#picker-levelnav")

      html = view |> picker() |> render_change("browse_search", %{"search" => "bolt"})
      refute has_element?(view, "#picker-levelnav")
      assert html =~ "Hex Bolt"
    end
  end

  describe "search category hits (the admin two-list surface)" do
    # The popup search works like the admin's (Max, 2026-08-31): item
    # results are the primary, default list; categories whose name (in
    # any language) matches render above them as navigation.
    setup %{cat: cat} do
      parent = fixture_category(cat, %{name: "Fasteners"})
      child = fixture_category(cat, %{name: "Bolts", parent_uuid: parent.uuid})

      {:ok, _} =
        Catalogue.create_item(%{
          name: "Hex Bolt",
          catalogue_uuid: cat.uuid,
          category_uuid: child.uuid
        })

      %{parent: parent, child: child}
    end

    test "matching categories render above the item results; a hit opens the category with the search cleared",
         %{conn: conn, cat: cat, child: child} do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")

      html = view |> picker() |> render_change("browse_search", %{"search" => "bolt"})

      # Items stay the primary results; the hit carries its ancestor
      # trail so same-named subcategories stay apart.
      assert html =~ "Hex Bolt"

      assert has_element?(
               view,
               ~s(#picker-search-cats button[phx-value-uuid="#{child.uuid}"]),
               "Bolts"
             )

      assert has_element?(view, "#picker-search-cats button", "Fasteners")

      # The hit opens the chapter's content: search cleared, standing in
      # Bolts with its own item listed — no hits strip any more.
      html = view |> picker() |> render_click("open_category_hit", %{"uuid" => child.uuid})
      assert html =~ "Hex Bolt"
      refute has_element?(view, "#picker-search-cats")
      refute has_element?(view, ~s(#picker-search[value="bolt"]))
      assert has_element?(view, "#picker-levelnav", "Bolts")
    end

    test "hits respect the scope allow-list and the drilled subtree", %{
      conn: conn,
      cat: cat,
      parent: parent,
      child: child
    } do
      # Same catalogue, OUTSIDE the scoped parent's subtree — matches
      # the query but must never be offered by a parent-scoped embed.
      outside = fixture_category(cat, %{name: "Bolt Bin"})

      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&cat_scope=#{parent.uuid}&sel=click")
      view |> picker() |> render_change("browse_search", %{"search" => "bolt"})

      assert has_element?(view, ~s(#picker-search-cats button[phx-value-uuid="#{child.uuid}"]))
      refute has_element?(view, ~s(#picker-search-cats button[phx-value-uuid="#{outside.uuid}"]))

      # Unscoped popup, drilled into the parent: hits cover only the
      # subtree you stand in, like the admin's drilled search.
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")
      view |> picker() |> render_click("browse_category", %{"uuid" => parent.uuid})
      view |> picker() |> render_change("browse_search", %{"search" => "bolt"})

      assert has_element?(view, ~s(#picker-search-cats button[phx-value-uuid="#{child.uuid}"]))
      refute has_element?(view, ~s(#picker-search-cats button[phx-value-uuid="#{outside.uuid}"]))
    end

    test "a hit on the scoped root itself leaves Up alive", %{conn: conn, cat: cat} do
      # A scoped embed's OWN root category is inside the tree, so a
      # search that matches its name offers it as a hit. Drilling there
      # used to aim Up at the grandparent — outside the scope, refused
      # by BrowseState — so the only way back up was a dead button.
      top = fixture_category(cat, %{name: "Hardware"})
      mid = fixture_category(cat, %{name: "Widgets", parent_uuid: top.uuid})
      leaf = fixture_category(cat, %{name: "Widget Clips", parent_uuid: mid.uuid})

      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&cat_scope=#{mid.uuid}&sel=click")
      view |> picker() |> render_change("browse_search", %{"search" => "widget"})

      assert has_element?(view, ~s(#picker-search-cats button[phx-value-uuid="#{mid.uuid}"]))
      view |> picker() |> render_click("open_category_hit", %{"uuid" => mid.uuid})

      assert has_element?(view, ~s(#picker-levelnav button[phx-value-uuid=""]), "Up")
      refute has_element?(view, ~s(#picker-levelnav button[phx-value-uuid="#{top.uuid}"]))

      # And the climb actually lands back on the popup root's tiles.
      view |> picker() |> render_click("browse_category", %{"uuid" => ""})

      assert has_element?(
               view,
               ~s(#picker-levelnav button[phx-value-uuid="#{leaf.uuid}"]),
               "Widget Clips"
             )
    end

    test "the root's Items mode searches items only — the admin's items-type search", %{
      conn: conn,
      cat: cat
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")
      view |> picker() |> render_click("set_root_mode", %{"mode" => "items"})

      html = view |> picker() |> render_change("browse_search", %{"search" => "bolt"})
      assert html =~ "Hex Bolt"
      refute has_element?(view, "#picker-search-cats")
    end
  end

  describe "per-user persistence" do
    # The view and hidden-column choices ride phoenix_kit_users.custom_fields
    # (ViewConfig's "__selector__" key, 2026-08-31 — boss: "save settings
    # after a user changes them"), so a remount — next open, next session,
    # another device — reopens the picker the way the user last shaped it.
    # Every OTHER test in this file mounts without a user and still toggles
    # freely: persistence is best-effort, never a requirement.

    test "the chosen view survives a remount", %{
      conn: conn,
      scope: scope,
      cat: cat,
      screw: screw
    } do
      conn = with_scope(conn, scope)
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")

      view |> picker() |> render_click("set_view", %{"mode" => "card"})

      {:ok, _view, html} = open(conn, "c=#{cat.uuid}&sel=click")
      assert html =~ ~s(id="picker-card-#{screw.uuid}")
      refute html =~ ~s(id="picker-table")
    end

    test "hidden columns and the view survive together — one save must not clobber the other",
         %{conn: conn, scope: scope, cat: cat, screw: screw} do
      conn = with_scope(conn, scope)
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")

      view |> picker() |> render_click("toggle_column", %{"col" => "sku"})
      view |> picker() |> render_click("set_view", %{"mode" => "card"})

      # Both halves reload: the picker opens on the photo grid, and the
      # table face still has SKU hidden. (The second save merged into the
      # REFRESHED user — a stale snapshot would have dropped the first.)
      {:ok, view, html} = open(conn, "c=#{cat.uuid}&sel=click")
      assert html =~ ~s(id="picker-card-#{screw.uuid}")

      view |> picker() |> render_click("set_view", %{"mode" => "table"})
      refute has_element?(view, "#picker-table th", "SKU")
      assert has_element?(view, "#picker-table th", "Name")
    end

    test "a reopen on the SAME page sees choices saved moments ago", %{
      conn: conn,
      scope: scope,
      cat: cat,
      screw: screw
    } do
      conn = with_scope(conn, scope)
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")

      view |> picker() |> render_click("set_view", %{"mode" => "card"})

      # The host's current_user assign now PREDATES the save (hosts don't
      # refresh it on a modal close); the component re-reads the row at
      # init, so a close + reopen without a page load still opens in
      # cards — this is the demo-page bug from 2026-08-31.
      render_click(view, "toggle_show")
      render_click(view, "toggle_show")

      assert render(view) =~ ~s(id="picker-card-#{screw.uuid}")
      refute render(view) =~ ~s(id="picker-table")
    end

    test "a saved hide loses to the grant: no stepper stripped, stale names ignored", %{
      conn: conn,
      scope: scope,
      cat: cat,
      screw: screw
    } do
      user = Auth.get_user!(scope.user.uuid)
      {:ok, _} = ViewConfig.save_selector(user, %{hidden: ["qty", "sku", "gone_column"]})
      conn = with_scope(conn, scope)

      # Quantity flavour: the stepper IS the selector, so the saved "qty"
      # hide is forced back visible instead of raising or applying.
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&cols=thumb,name,sku,qty&sel=quantity")
      assert has_element?(view, "#picker-qty-#{screw.uuid}-r0-input")
      refute has_element?(view, "#picker-table th", "SKU")

      # A grant that never had those columns just ignores the stale names.
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&cols=thumb,name&sel=click")
      assert has_element?(view, "#picker-table th", "Name")
    end
  end
end
