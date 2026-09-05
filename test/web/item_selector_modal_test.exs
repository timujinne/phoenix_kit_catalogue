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

  # The root either-or is opt-in since 2026-08-31 (root_switcher) — a
  # test that asserts on the ROOT's flat item list must open with
  # `rs=true` and switch over first.
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
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&precision=1&sel=click&iq=true")
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
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click&iq=true")
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

    test "quantity mode ignores inline_qty — the documented disjunct has a pin", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      # In click mode the stepper appears only on SELECTED rows under
      # iq=true; in quantity mode every rendered row carries it at 0
      # regardless of iq. Deleting/inverting the inline_qty half of
      # stepper?/2 for quantity mode used to fail nothing (external
      # review, 2026-08-31).
      {:ok, _view, html} = open(conn, "c=#{cat.uuid}&iq=true")

      assert html =~ ~s(id="picker-qty-#{screw.uuid}-r0")
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
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click&iq=true")

      # Row cells carry the same card_click binding the card face uses.
      # (The thumb AND name cells are the details affordance now, so
      # target a data cell — the sku one.)
      view
      |> element(~s(#picker-row-#{screw.uuid} td[phx-click="card_click"]), "M8-100")
      |> render_click()

      assert has_element?(view, ~s(#picker-row-#{screw.uuid}[data-selected="true"]))
      # The stepper appeared in the qty cell (the inline_qty opt-in)…
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

      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click&rs=true")
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

      {:ok, view, html} = open(conn, "c=#{cat.uuid}&sel=click&rs=true")
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

    test "a scoped category's popup OPENS standing in it: own items + child tiles",
         %{conn: conn, cat: cat} do
      # Boss, 2026-08-31 (the trashcans report): a category-scoped popup
      # is the drilled level from the first paint — its child tiles AND
      # the items filed directly on it. Subtree coverage belongs to
      # search; there is no synthetic outline above the floor, so no
      # Back either.
      parent = fixture_category(cat, %{name: "Parent Scope"})
      child = fixture_category(cat, %{name: "Child Scope", parent_uuid: parent.uuid})

      {:ok, _} =
        Catalogue.create_item(%{
          name: "Direct On Parent",
          catalogue_uuid: cat.uuid,
          category_uuid: parent.uuid
        })

      {:ok, _} =
        Catalogue.create_item(%{
          name: "Deep Nested Item",
          catalogue_uuid: cat.uuid,
          category_uuid: child.uuid
        })

      {:ok, view, html} = open(conn, "c=#{cat.uuid}&cat_scope=#{parent.uuid}&sel=click")

      # The floor: own items + the child tile, header names the level,
      # no Back (nowhere further back in this popup).
      assert html =~ "Direct On Parent"
      refute html =~ "Deep Nested Item"
      assert html =~ "Child Scope"
      assert has_element?(view, "h3", "Parent Scope")
      refute has_element?(view, "#picker-back")

      # A search still finds down the subtree…
      html = view |> picker() |> render_change("browse_search", %{"search" => "deep"})
      assert html =~ "Deep Nested Item"

      # …and clearing it returns to the floor's own listing.
      html = view |> picker() |> render_change("browse_search", %{"search" => ""})
      refute html =~ "Deep Nested Item"
      assert html =~ "Direct On Parent"

      # The child level lists its item, and Back climbs to the floor.
      html = view |> picker() |> render_click("browse_category", %{"uuid" => child.uuid})
      assert html =~ "Deep Nested Item"
      assert has_element?(view, ~s(#picker-back[phx-value-uuid="#{parent.uuid}"]))
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
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click&rs=true")
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

    test "only the THUMBNAIL opens details; the title selects instead", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      # Boss, 2026-08-31 — supersedes the earlier title-joins-the-photo
      # ruling: the look-closer gesture is the image alone.
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")

      # Table: the NAME cell does NOT carry the details binding…
      refute has_element?(
               view,
               ~s(#picker-row-#{screw.uuid} td[phx-click="show_detail"]),
               "M8 Screw"
             )

      # …it follows the row's select behaviour in click mode.
      view
      |> element(~s(#picker-row-#{screw.uuid} td[phx-click="card_click"]), "M8 Screw")
      |> render_click()

      view |> picker() |> render_click("confirm", %{})
      assert render(view) =~ "M8 Screw|M8-100|qty=1"
    end

    test "in card view the title sits inside the select button, not the details one", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")
      view |> picker() |> render_click("set_view", %{"mode" => "card"})

      refute has_element?(
               view,
               ~s(#picker-card-#{screw.uuid} button[phx-click="show_detail"]),
               "M8 Screw"
             )

      view
      |> element(~s(#picker-card-#{screw.uuid} button[phx-click="card_click"]), "M8 Screw")
      |> render_click()

      view |> picker() |> render_click("confirm", %{})
      assert render(view) =~ "M8 Screw|M8-100|qty=1"
    end

    test "a cancel with the details stacked closes only the details", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      # Esc's server contract (Max, 2026-08-31: "Esc closes both popups,
      # but only top one needs to go"): core's PkDialog relays the
      # grouped cancel, and on the server a cancel arriving with @detail
      # open must close the TOP popup only — the selector keeps its
      # state. The second cancel closes the selector itself.
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")

      view |> picker() |> render_click("show_detail", %{"uuid" => to_string(screw.uuid)})
      assert render(view) =~ "close_detail"

      html = view |> picker() |> render_click("cancel", %{})
      refute html =~ "close_detail"
      refute has_element?(view, "#closed")

      view |> picker() |> render_click("cancel", %{})
      assert has_element?(view, "#closed")
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

    test "the auto-load sentinel is the colocated hook targeting the component", %{
      conn: conn,
      cat: cat
    } do
      {:ok, _} =
        Catalogue.create_item(%{name: "Page Two Item", sku: "P2-1", catalogue_uuid: cat.uuid})

      {:ok, view, html} = open(conn, "c=#{cat.uuid}&pp=2")

      # Core's InfiniteScroll routed its push to the ROOT LiveView on
      # every published core — a host without a load_more clause crashed
      # and remounted, dropping the popup and every pick (external
      # review, 2026-08-31). The colocated .AutoLoad pushes through the
      # sentinel's own phx-target instead, so both attributes ARE the
      # contract.
      assert has_element?(view, "#picker-scroll-sentinel[phx-target]")
      assert html =~ "AutoLoad"
      refute html =~ ~s(phx-hook="InfiniteScroll")

      # The cursor carries the full list identity — the catalogue drill
      # included, so drilling re-arms it even on equal page lengths.
      assert has_element?(view, ~s(#picker-scroll-sentinel[data-cursor]))
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

    test "forcing click with a visible :qty stays either-or: leftmost checkbox, read-only qty", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      # Max, 2026-08-31: "if there is a checkmark then no need for a
      # number" — the old default paired a check icon with a
      # stepper-on-select here.
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")

      assert has_element?(view, "#picker-row-#{screw.uuid} input[type=checkbox]")
      refute has_element?(view, "#picker-qty-#{screw.uuid}-r0-input")

      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
      # Still no number ENTRY — the picked amount shows read-only.
      refute has_element?(view, "#picker-qty-#{screw.uuid}-r0-input")
      assert has_element?(view, "#picker-row-#{screw.uuid} input[type=checkbox][checked]")
      assert has_element?(view, "#picker-row-#{screw.uuid} td:last-of-type span", "1")
    end

    test "the read-only amount reaches CARD view too, not just the table row", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      # The row carried the picked amount from the start; the card
      # footer only got the stepper, so a host preselecting at another
      # quantity saw the number in one view and not the other.
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")
      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
      html = view |> picker() |> render_click("set_view", %{"mode" => "card"})

      assert html =~ ~s(id="picker-card-#{screw.uuid}")
      # Still no number ENTRY in this flavour…
      refute has_element?(view, "#picker-qty-#{screw.uuid}-r0-input")
      # …but the amount is visible on the card.
      assert has_element?(view, "#picker-card-#{screw.uuid} div.tabular-nums", "1")
    end

    test "inline_qty is the deliberate both-signals opt-in", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click&iq=true")

      # The legacy pairing: no checkbox column, stepper once selected.
      refute has_element?(view, "#picker-row-#{screw.uuid} input[type=checkbox]")
      refute has_element?(view, "#picker-qty-#{screw.uuid}-r0-input")

      view |> picker() |> render_click("card_click", %{"uuid" => screw.uuid})
      assert has_element?(view, ~s(#picker-qty-#{screw.uuid}-r0-input[value="1"]))
    end

    test "the native control carries the mode's floor: qty_min in click mode, 0 in quantity mode",
         %{conn: conn, cat: cat, screw: screw} do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&min=2&sel=click&iq=true")
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

      # Back (in the modal header since 2026-08-31) from a root-level
      # tile returns to the popup root.
      assert has_element?(view, ~s(#picker-back[phx-value-uuid=""]))

      view |> picker() |> render_click("browse_category", %{"uuid" => child.uuid})

      # Back from the child names its actual parent; the level lists its
      # item.
      assert has_element?(view, ~s(#picker-back[phx-value-uuid="#{parent.uuid}"]))

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

      # No switcher by default (Max, 2026-08-31): a root is just a level.
      refute has_element?(view, "#picker-root-mode")
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

    test "a root is just a level: tiles only, no switcher, no page-1 fetch, flip refused",
         %{conn: conn, cat: cat} do
      # Max, 2026-08-31: the switcher read as a search-mode control while
      # flipping the browse listing — dropped from the default. The root
      # renders the outline alone; items come from drilling or searching.
      {:ok, view, html} = open(conn, "c=#{cat.uuid}&sel=click")

      assert has_element?(view, "#picker-levelnav")
      refute has_element?(view, "#picker-root-mode")
      # The skipped fetch is observable: no item markup at the root at
      # all — not even hidden rows.
      refute html =~ "M8-100"
      refute html =~ "Hex Bolt"

      # A crafted set_root_mode must not reveal the unfetched (empty)
      # item block.
      html = view |> picker() |> render_click("set_root_mode", %{"mode" => "items"})
      assert has_element?(view, "#picker-levelnav")
      refute html =~ "M8-100"

      # Drilling fetches and lists as always.
      html = view |> picker() |> render_click("browse_category", %{"uuid" => "__uncategorized__"})
      assert html =~ "M8 Screw"

      # And climbing back up returns to the tiles-only root.
      html = view |> picker() |> render_click("browse_category", %{"uuid" => ""})
      refute html =~ "M8-100"
      assert has_element?(view, "#picker-levelnav")

      # Search still answers with items from the root.
      html = view |> picker() |> render_change("browse_search", %{"search" => "bolt"})
      assert html =~ "Hex Bolt"
    end

    test "tile triggers carry a pointer cursor in both views", %{conn: conn, cat: cat} do
      # A bare <button> gets NO pointer cursor from the browser — the
      # admin's tiles point because they are patch <a> links; the
      # popup's identical-looking tiles are buttons and didn't (Max,
      # 2026-08-31: "the mouse doesn't change on hovering").
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")

      assert view |> element("#picker-levelnav") |> render() =~ "cursor-pointer"

      view |> picker() |> render_click("set_view", %{"mode" => "card"})
      assert view |> element("#picker-levelnav") |> render() =~ "cursor-pointer"
    end

    test "root_switcher: true restores the admin either-or — flat list one switch away",
         %{conn: conn, cat: cat} do
      {:ok, view, html} = open(conn, "c=#{cat.uuid}&sel=click&rs=true")

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

  describe "multi-catalogue level navigation (tim-dev wide picker, 2026-08-31)" do
    # A scope naming SEVERAL catalogues used to get no tiles, no switcher,
    # no category hits at all ("check why the categories and sub
    # categories aren't showing up"). The root now groups each offered
    # catalogue's top-level categories under the catalogue's name;
    # drilling below the root works exactly like the single-catalogue
    # tree — category uuids are global and the fetch re-ANDs the scope.
    setup %{cat: cat, other: other} do
      doors = fixture_category(cat, %{name: "Doors"})
      tools = fixture_category(other, %{name: "Other Tools"})
      sub = fixture_category(other, %{name: "Other Drills", parent_uuid: tools.uuid})

      {:ok, drill} =
        Catalogue.create_item(%{
          name: "Power Drill",
          catalogue_uuid: other.uuid,
          category_uuid: sub.uuid
        })

      %{doors: doors, tools: tools, sub: sub, drill: drill}
    end

    test "the root lists CATALOGUES; drilling goes catalogue, category, subcategory", %{
      conn: conn,
      cat: cat,
      other: other,
      doors: doors,
      tools: tools,
      sub: sub
    } do
      {:ok, view, html} = open(conn, "c=#{cat.uuid}&c2=#{other.uuid}&sel=click")

      # Catalogue-first (Max, 2026-08-31: "we should first have the user
      # choose a catalogue"): the root shows catalogue tiles only — no
      # category is offered yet — with the switcher labeled Catalogues.
      assert has_element?(view, ~s(#picker-levelnav button[phx-value-uuid="#{cat.uuid}"]))
      assert has_element?(view, ~s(#picker-levelnav button[phx-value-uuid="#{other.uuid}"]))
      refute has_element?(view, ~s(#picker-levelnav button[phx-value-uuid="#{doors.uuid}"]))
      refute has_element?(view, ~s(#picker-levelnav button[phx-value-uuid="#{tools.uuid}"]))
      # No switcher by default; with root_switcher it reads Catalogues
      # (pinned below).
      refute has_element?(view, "#picker-root-mode")
      refute html =~ "__uncategorized__"

      # Choosing a catalogue shows ITS top categories + its own
      # Uncategorized bucket, like a single-catalogue root.
      view |> picker() |> render_click("browse_catalogue", %{"uuid" => other.uuid})
      assert has_element?(view, ~s(#picker-levelnav button[phx-value-uuid="#{tools.uuid}"]))
      refute has_element?(view, ~s(#picker-levelnav button[phx-value-uuid="#{doors.uuid}"]))
      assert has_element?(view, ~s(#picker-levelnav button[phx-value-uuid="__uncategorized__"]))
      assert has_element?(view, ~s(#picker-back[phx-value-uuid=""]))

      # Category and subcategory levels work as in a single catalogue.
      view |> picker() |> render_click("browse_category", %{"uuid" => tools.uuid})
      assert has_element?(view, ~s(#picker-levelnav button[phx-value-uuid="#{sub.uuid}"]))

      html = view |> picker() |> render_click("browse_category", %{"uuid" => sub.uuid})
      assert html =~ "Power Drill"

      # Up chain: subcategory -> category -> catalogue level -> root.
      view |> picker() |> render_click("browse_category", %{"uuid" => tools.uuid})
      view |> picker() |> render_click("browse_category", %{"uuid" => ""})
      assert has_element?(view, ~s(#picker-levelnav button[phx-value-uuid="#{tools.uuid}"]))

      view |> picker() |> render_click("browse_catalogue", %{"uuid" => ""})
      assert has_element?(view, ~s(#picker-levelnav button[phx-value-uuid="#{cat.uuid}"]))
    end

    test "a chosen catalogue narrows the items; a foreign catalogue uuid is refused", %{
      conn: conn,
      cat: cat,
      other: other,
      drill: drill
    } do
      third = fixture_catalogue(%{name: "Unoffered Catalogue"})

      {:ok, _} =
        Catalogue.create_item(%{name: "Unoffered Item", catalogue_uuid: third.uuid})

      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&c2=#{other.uuid}&sel=click&rs=true")

      # Items mode at the root: everything offered, nothing beyond.
      html = view |> picker() |> render_click("set_root_mode", %{"mode" => "items"})
      assert html =~ "M8 Screw"
      assert html =~ drill.name
      refute html =~ "Unoffered Item"

      # Chosen catalogue: its items only.
      view |> picker() |> render_click("set_root_mode", %{"mode" => "categories"})
      view |> picker() |> render_click("browse_catalogue", %{"uuid" => other.uuid})
      html = view |> picker() |> render_click("set_root_mode", %{"mode" => "items"})
      refute html =~ "M8 Screw"
      assert html =~ "Forbidden Item"

      # A crafted uuid outside the offered list is a no-op — the drilled
      # catalogue stands (its item still listed, the outsider's absent).
      html = view |> picker() |> render_click("browse_catalogue", %{"uuid" => third.uuid})
      refute html =~ "Unoffered Item"
      assert html =~ "Forbidden Item"
    end

    test "with root_switcher the multi-catalogue switcher reads Catalogues", %{
      conn: conn,
      cat: cat,
      other: other
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&c2=#{other.uuid}&sel=click&rs=true")
      assert has_element?(view, "#picker-root-mode button", "Catalogues")
    end

    test "a crafted category from ANOTHER offered catalogue is refused while drilled", %{
      conn: conn,
      cat: cat,
      other: other,
      doors: doors,
      tools: tools,
      sub: sub
    } do
      # The tiles and search hits never offer B's categories while
      # drilled into A; a crafted event naming one would wed A to B's
      # category — a contradictory, empty dead-end level (external
      # review, 2026-08-31). The component refuses it like BrowseState
      # refuses out-of-scope uuids.
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&c2=#{other.uuid}&sel=click")

      view |> picker() |> render_click("browse_catalogue", %{"uuid" => cat.uuid})
      assert has_element?(view, ~s(#picker-levelnav button[phx-value-uuid="#{doors.uuid}"]))

      view |> picker() |> render_click("browse_category", %{"uuid" => tools.uuid})

      # Still standing at cat's catalogue level — the crafted drill did
      # nothing (tools' subcategory tile would render if it had).
      assert has_element?(view, ~s(#picker-levelnav button[phx-value-uuid="#{doors.uuid}"]))
      refute has_element?(view, ~s(#picker-levelnav button[phx-value-uuid="#{sub.uuid}"]))
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
      assert has_element?(view, "h3", "Bolts")
      assert has_element?(view, "#picker-back")
    end

    test "a CATEGORY-ONLY scope still gets the subcategory tiles", %{
      conn: conn,
      cat: cat
    } do
      # tim-dev's per-category narrow pickers pass category_uuids with
      # catalogue_uuids: nil — the tree builder keyed off the catalogue
      # and handed that shape the EMPTY tree, so WASTE SORTERS' healthy
      # children never rendered (error report, 2026-08-31). The
      # catalogue is implied by the scoped category; the tree derives it.
      sorters = fixture_category(cat, %{name: "Waste Sorters"})
      franke = fixture_category(cat, %{name: "Franke Sorter", parent_uuid: sorters.uuid})
      blanco = fixture_category(cat, %{name: "Blanco", parent_uuid: sorters.uuid})

      {:ok, _} =
        Catalogue.create_item(%{
          name: "Franke 90L",
          catalogue_uuid: cat.uuid,
          category_uuid: franke.uuid
        })

      # No c= param: the scope names ONLY the category, like Andi's.
      {:ok, view, _html} = open(conn, "cat_scope=#{sorters.uuid}&sel=click")

      assert has_element?(view, ~s(#picker-levelnav button[phx-value-uuid="#{franke.uuid}"]))
      assert has_element?(view, ~s(#picker-levelnav button[phx-value-uuid="#{blanco.uuid}"]))

      # Drilling one works, lists its item, and Back climbs home.
      html = view |> picker() |> render_click("browse_category", %{"uuid" => franke.uuid})
      assert html =~ "Franke 90L"
      assert has_element?(view, "h3", "Franke Sorter")

      view |> picker() |> render_click("browse_category", %{"uuid" => ""})
      assert has_element?(view, ~s(#picker-levelnav button[phx-value-uuid="#{blanco.uuid}"]))

      # The derived catalogue feeds the TREE only — the fetch stays on
      # the host's category scope (out-of-scope items never appear).
      html = view |> picker() |> render_change("browse_search", %{"search" => "m8"})
      refute html =~ "M8 Screw"
    end

    test "a tile's IMAGE enters the level like its name does", %{
      conn: conn,
      cat: cat
    } do
      # Max, 2026-08-31: "for the categories and catalogues… image and
      # title should be clickable to enter them." The table view's thumb
      # cell used to be inert.
      pictured =
        fixture_category(cat, %{
          name: "Pictured",
          data: %{"featured_image_uuid" => Ecto.UUID.generate()}
        })

      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")

      # The thumb cell's button carries the same drill event + uuid the
      # name button does — two triggers per pictured tile.
      html = view |> element("#picker-levelnav-table") |> render()
      assert length(String.split(html, ~s(phx-value-uuid="#{pictured.uuid}"))) == 3

      # And the uncategorized row's folder icon drills the bucket —
      # two triggers there as well.
      assert length(String.split(html, ~s(phx-value-uuid="__uncategorized__"))) == 3
    end

    test "the header names where you stand and carries Back (Max, 2026-08-31)", %{
      conn: conn,
      cat: cat,
      parent: parent
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")

      # Root: no Back, the host-scoped context (or plain title) stands.
      refute has_element?(view, "#picker-back")

      # Drilled: the header names the level and offers the way back.
      view |> picker() |> render_click("browse_category", %{"uuid" => parent.uuid})
      assert has_element?(view, "h3", "Fasteners")
      assert has_element?(view, "#picker-back")

      # Back climbs; the header follows.
      view |> picker() |> render_click("browse_category", %{"uuid" => ""})
      refute has_element?(view, "h3", "Fasteners")
      refute has_element?(view, "#picker-back")
    end

    test "a whitespace-only query is no search: level navigation and drill stand", %{
      conn: conn,
      cat: cat,
      parent: parent
    } do
      # The fetch layer trims "   " to no text filter, so treating it as
      # live search flipped a :direct level to subtree listing and hid
      # the tiles for a query that filters nothing (external review,
      # 2026-08-31).
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click")
      assert has_element?(view, ~s(#picker-levelnav button[phx-value-uuid="#{parent.uuid}"]))

      view |> picker() |> render_change("browse_search", %{"search" => "   "})
      assert has_element?(view, ~s(#picker-levelnav button[phx-value-uuid="#{parent.uuid}"]))
      refute has_element?(view, "#picker-search-cats")
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

    test "the scoped floor: hits cover descendants only, Back climbs home to it", %{
      conn: conn,
      cat: cat
    } do
      # A category-scoped popup OPENS standing in its category (boss,
      # 2026-08-31), so the old drill-to-the-standing-root hit scenario
      # dissolved: hits offer the subtree BELOW the floor, never the
      # floor itself or its out-of-scope ancestors — and Back at the
      # floor stays hidden (the grandparent-aimed dead button this test
      # used to guard against cannot render at all).
      top = fixture_category(cat, %{name: "Hardware"})
      mid = fixture_category(cat, %{name: "Widgets", parent_uuid: top.uuid})
      leaf = fixture_category(cat, %{name: "Widget Clips", parent_uuid: mid.uuid})

      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&cat_scope=#{mid.uuid}&sel=click")
      refute has_element?(view, "#picker-back")

      view |> picker() |> render_change("browse_search", %{"search" => "widget"})

      assert has_element?(view, ~s(#picker-search-cats button[phx-value-uuid="#{leaf.uuid}"]))
      refute has_element?(view, ~s(#picker-search-cats button[phx-value-uuid="#{mid.uuid}"]))
      refute has_element?(view, ~s(#picker-search-cats button[phx-value-uuid="#{top.uuid}"]))

      # Drilling a hit works, and Back names the floor, not the
      # out-of-scope grandparent.
      view |> picker() |> render_click("open_category_hit", %{"uuid" => leaf.uuid})
      assert has_element?(view, ~s(#picker-back[phx-value-uuid="#{mid.uuid}"]))

      view |> picker() |> render_click("browse_category", %{"uuid" => mid.uuid})
      refute has_element?(view, "#picker-back")
    end

    test "the root's Items mode (opt-in) searches items only — the admin's items-type search", %{
      conn: conn,
      cat: cat
    } do
      {:ok, view, _html} = open(conn, "c=#{cat.uuid}&sel=click&rs=true")
      view |> picker() |> render_click("set_root_mode", %{"mode" => "items"})

      html = view |> picker() |> render_change("browse_search", %{"search" => "bolt"})
      assert html =~ "Hex Bolt"
      refute has_element?(view, "#picker-search-cats")
    end
  end

  describe "content language (tim-dev error report, 2026-08-31)" do
    # The host process carries the viewer's gettext locale and passes no
    # :locale attr — exactly Andi's integration. The list used to read
    # the wrong translation key ("name" where the editor stores "_name"),
    # so names never translated; the detail popup resolved "_name" and
    # came out right, which kept the miss invisible on single-language
    # data.
    test "the process locale reaches the list AND the inspection popup with no locale attr",
         %{conn: conn, cat: cat, screw: screw} do
      {:ok, _} =
        Catalogue.update_item(screw, %{
          data: %{
            "_primary_language" => "en",
            "en" => %{"_name" => "M8 Screw", "_description" => "Steel screw"},
            "et" => %{"_name" => "M8 Kruvi", "_description" => "Teraskruvi"}
          }
        })

      {:ok, view, html} = open(conn, "c=#{cat.uuid}&sel=click&loc=et")

      # The list translates (this line is the fixed bug)…
      assert html =~ "M8 Kruvi"
      refute html =~ "M8 Screw"

      # …and the inspection popup translates name and description.
      html = view |> picker() |> render_click("show_detail", %{"uuid" => to_string(screw.uuid)})
      assert html =~ "M8 Kruvi"
      assert html =~ "Teraskruvi"
    end

    test "an explicit :locale attr still wins over the process locale", %{
      conn: conn,
      cat: cat,
      screw: screw
    } do
      {:ok, _} =
        Catalogue.update_item(screw, %{
          data: %{
            "_primary_language" => "en",
            "en" => %{"_name" => "M8 Screw"},
            "et" => %{"_name" => "M8 Kruvi"}
          }
        })

      # Host process in et, component forced to en.
      {:ok, _view, html} = open(conn, "c=#{cat.uuid}&sel=click&loc=et&clocale=en")
      assert html =~ "M8 Screw"
      refute html =~ "M8 Kruvi"
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

  describe "the module's shared sort (client, 2026-09-01: one order everywhere)" do
    defp appears_before?(html, first, second) do
      {i1, _} = :binary.match(html, first)
      {i2, _} = :binary.match(html, second)
      i1 < i2
    end

    test "listings follow catalogue_sort_detail_items", %{conn: conn, cat: cat} do
      # The seed items tie on position, so the default document order
      # falls to name asc — a name:desc setting must flip them.
      {:ok, _} = ViewConfig.save_global_sort(:detail_items, "name", :desc)

      {:ok, _view, html} = open(conn, "c=#{cat.uuid}")
      assert appears_before?(html, "White Paint", "M8 Screw")

      # Back to the default: document order (name asc on the tie).
      {:ok, _} = ViewConfig.save_global_sort(:detail_items, "position", :asc)

      {:ok, _view, html} = open(conn, "c=#{cat.uuid}")
      assert appears_before?(html, "M8 Screw", "White Paint")
    end

    test "category tiles follow catalogue_sort_detail_categories", %{conn: conn, cat: cat} do
      # Positions invert the names, so which order is active is readable
      # from which tile renders first.
      fixture_category(cat, %{name: "Alpha Section", position: 2})
      fixture_category(cat, %{name: "Zed Section", position: 1})

      {:ok, _view, html} = open(conn, "c=#{cat.uuid}")
      assert appears_before?(html, "Zed Section", "Alpha Section")

      {:ok, _} = ViewConfig.save_global_sort(:detail_categories, "name", :asc)

      {:ok, _view, html} = open(conn, "c=#{cat.uuid}")
      assert appears_before?(html, "Alpha Section", "Zed Section")

      {:ok, _} = ViewConfig.save_global_sort(:detail_categories, "position", :asc)
    end

    test "manual category tiles tie-break on the lowercased name", %{conn: conn, cat: cat} do
      # Equal positions force the tie-break; the names are cased so a raw
      # C-collation query order ("Zebra" < "apple" by byte) differs from
      # the admin's lowercased key ("apple" < "zebra"). On an en_US-collated
      # DB both agree - the pin still guards "no in-memory sort at all".
      fixture_category(cat, %{name: "Zebra Tie", position: 5})
      fixture_category(cat, %{name: "apple tie", position: 5})

      {:ok, _view, html} = open(conn, "c=#{cat.uuid}")
      assert appears_before?(html, "apple tie", "Zebra Tie")
    end
  end
end
