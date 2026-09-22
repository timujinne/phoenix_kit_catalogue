defmodule PhoenixKitCatalogue.Web.RowContextMenuTest do
  @moduledoc """
  Right-clicking a list row opens that row's `⋮` menu at the pointer
  (boss via Max, 2026-09-21). The wiring is one attribute — a row flagged
  `data-row-menu-context` is right-clickable, an unflagged one is not — so
  these check that the flag reaches the rows, that the Settings → Catalogue
  switch removes it, and that no list ships a menu its rows cannot open.
  """
  use PhoenixKitCatalogue.LiveCase

  alias PhoenixKitCatalogue.Web.Settings

  @base "/en/admin/catalogue"

  setup do
    on_exit(fn -> Settings.update_context_menu_enabled(true) end)
    :ok
  end

  describe "the flag reaches the rows" do
    test "the catalogues index flags its rows", %{conn: conn} do
      fixture_catalogue(%{name: "Right-click me"})

      {:ok, _view, html} = live(conn, @base)

      assert html =~ "data-row-menu-context"
    end

    # Every view, not just the default table: card view renders through
    # different components, and a flag threaded into one and not the other
    # crashes that view outright (a function component does not see its
    # parent's assigns — how the first cut of this broke card view).
    for mode <- ~w(card table comfy) do
      test "the catalogues index flags its rows in #{mode} view", %{conn: conn} do
        fixture_catalogue(%{name: "Right-click me in #{unquote(mode)}"})

        {:ok, view, _html} = live(conn, @base)
        html = render_click(view, "set_view", %{"mode" => unquote(mode)})

        assert html =~ "data-row-menu-context"
      end
    end

    test "a catalogue's own list flags its rows", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Inner"})
      fixture_item(%{catalogue_uuid: catalogue.uuid, name: "An item", sku: "RC-1"})

      {:ok, _view, html} = live(conn, "#{@base}/#{catalogue.uuid}")

      assert html =~ "data-row-menu-context"
    end
  end

  describe "the setting" do
    test "turning it off removes the flag from every row", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "No right-click"})
      fixture_item(%{catalogue_uuid: catalogue.uuid, name: "An item", sku: "RC-2"})

      {:ok, _} = Settings.update_context_menu_enabled(false)

      {:ok, _view, index} = live(conn, @base)
      {:ok, _view, detail} = live(conn, "#{@base}/#{catalogue.uuid}")

      refute index =~ "data-row-menu-context"
      refute detail =~ "data-row-menu-context"

      # …and the ⋮ menus are still there. Turning the gesture off must not
      # cost anyone the actions themselves.
      assert index =~ "data-row-menu-wrapper"
      assert detail =~ "data-row-menu-wrapper"
    end

    test "it defaults to on, so a fresh install has the gesture", %{conn: _conn} do
      assert Settings.context_menu_enabled?()
    end

    test "the flag follows the setting rather than a cached mount", %{conn: conn} do
      fixture_catalogue(%{name: "Follows the setting"})

      {:ok, _} = Settings.update_context_menu_enabled(false)
      {:ok, _view, off} = live(conn, @base)
      refute off =~ "data-row-menu-context"

      {:ok, _} = Settings.update_context_menu_enabled(true)
      {:ok, _view, on} = live(conn, @base)
      assert on =~ "data-row-menu-context"
    end
  end

  describe "coverage" do
    # Sourced from `lib/`, not from a list this module also renders from: a
    # NEW list page with a row menu and no flag fails here. The counterpart
    # list is explicit so removing the flag from a page that has one cannot
    # pass by being quietly dropped from both.
    @flagged ~w(
      lib/phoenix_kit_catalogue/web/catalogues_live.ex
      lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex
      lib/phoenix_kit_catalogue/web/components.ex
      lib/phoenix_kit_catalogue/web/pdf_library_live.ex
    )

    # A row menu that is deliberately NOT right-clickable, with the reason.
    @unflagged %{
      "lib/phoenix_kit_catalogue/web/item_form_live.ex" =>
        "the supplier rows are unsaved draft rows inside a form, keyed by a " <>
          "client-side row key rather than a record uuid — right-clicking a " <>
          "form field to act on the draft under it is not the gesture"
    }

    test "every file with a row menu either flags its rows or says why not" do
      with_menus =
        for file <- Path.wildcard("lib/phoenix_kit_catalogue/web/**/*.ex"),
            source = File.read!(file),
            String.contains?(source, "<.table_row_menu"),
            do: file

      assert with_menus != [], "the scan found no row menus at all — check the pattern"

      unaccounted = with_menus -- (@flagged ++ Map.keys(@unflagged))

      assert unaccounted == [],
             "these render a row menu but neither flag their rows nor appear in " <>
               "@unflagged with a reason:\n" <> Enum.join(unaccounted, "\n")

      # Neither list may name a file that no longer has a menu, or it stops
      # describing the code.
      assert (@flagged ++ Map.keys(@unflagged)) -- with_menus == []
    end

    test "every flagged file actually carries the attribute" do
      missing =
        for file <- @flagged,
            not String.contains?(File.read!(file), "data-row-menu-context"),
            do: file

      assert missing == [],
             "listed as right-clickable but no row carries the flag:\n" <>
               Enum.join(missing, "\n")
    end

    test "the flag is threaded, never read per row" do
      # `Settings.context_menu_enabled?()` inside a row component would be one
      # settings read per row per render. It belongs in `mount`.
      offenders =
        for file <- @flagged,
            {line, number} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
            line =~ "context_menu_enabled?",
            not String.contains?(line, "row_context_menu:"),
            do: "#{file}:#{number}: #{String.trim(line)}"

      assert offenders == [],
             "read the setting once in mount and thread it:\n" <> Enum.join(offenders, "\n")
    end
  end
end
