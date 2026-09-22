defmodule PhoenixKitCatalogue.Web.SettingsLiveTest do
  @moduledoc """
  Settings → Catalogue. Every control is driven through the page's real form
  and the stored setting read back — a control that renders but never writes
  is the failure this guards against.
  """
  use PhoenixKitCatalogue.LiveCase

  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitCatalogue.Web.Settings

  @path "/en/admin/settings/catalogue"

  setup do
    before = %{
      context_menu: Settings.context_menu_enabled?(),
      sweep: Settings.sweep_enabled?(),
      interval: Settings.sweep_interval_minutes(),
      max: Settings.sweep_max_per_run()
    }

    on_exit(fn ->
      Settings.update_context_menu_enabled(before.context_menu)
      Settings.update_sweep_enabled(before.sweep)
      Settings.update_sweep_interval_minutes(before.interval)
      Settings.update_sweep_max_per_run(before.max)
    end)

    :ok
  end

  test "renders both sections with what is stored", %{conn: conn} do
    {:ok, _} = Settings.update_context_menu_enabled(true)
    {:ok, _} = Settings.update_sweep_interval_minutes(45)

    {:ok, view, _html} = live(conn, @path)

    assert has_element?(view, "#catalogue-context-menu[checked]")
    assert has_element?(view, ~s(#catalogue-sweep-interval[value="45"]))
  end

  describe "right-click menus" do
    test "switching it off writes the setting", %{conn: conn} do
      {:ok, _} = Settings.update_context_menu_enabled(true)
      {:ok, view, _html} = live(conn, @path)

      view
      |> form("#catalogue-context-menu-form", %{"value" => "false"})
      |> render_change()

      refute Settings.context_menu_enabled?()
      refute has_element?(view, "#catalogue-context-menu[checked]")
    end

    test "switching it back on writes the setting", %{conn: conn} do
      {:ok, _} = Settings.update_context_menu_enabled(false)
      {:ok, view, _html} = live(conn, @path)

      view
      |> form("#catalogue-context-menu-form", %{"value" => "true"})
      |> render_change()

      assert Settings.context_menu_enabled?()
    end
  end

  describe "translation sweep" do
    test "the toggle writes the setting", %{conn: conn} do
      {:ok, _} = Settings.update_sweep_enabled(false)
      {:ok, view, _html} = live(conn, @path)

      view
      |> form("#catalogue-sweep-form", %{"value" => "true"})
      |> render_change()

      assert Settings.sweep_enabled?()
    end

    test "the interval saves a whole number of minutes", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      view
      |> form("#catalogue-sweep-interval-form", %{"value" => "90"})
      |> render_change()

      assert Settings.sweep_interval_minutes() == 90
    end

    test "the per-run cap saves a whole number", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      view
      |> form("#catalogue-sweep-max-form", %{"value" => "25"})
      |> render_change()

      assert Settings.sweep_max_per_run() == 25
    end

    # Crossed, not sampled: each numeric field against each input it must
    # refuse. A new clause that skips the check for one shape fails here.
    for {form, reader} <- [
          {"#catalogue-sweep-interval-form", :sweep_interval_minutes},
          {"#catalogue-sweep-max-form", :sweep_max_per_run}
        ],
        bad <- ["0", "-5", "1.5", "ten", "", " "] do
      test "#{form} refuses #{inspect(bad)} and keeps what was stored", %{conn: conn} do
        before = apply(Settings, unquote(reader), [])
        {:ok, view, _html} = live(conn, @path)

        html =
          view
          |> form(unquote(form), %{"value" => unquote(bad)})
          |> render_change()

        assert apply(Settings, unquote(reader), []) == before
        assert html =~ "whole number"
      end
    end

    test "a single-language install is told there is nothing to sweep", %{conn: conn} do
      # Asserted, not assumed: if the test database ever gains a second
      # language, this fails and the checkbox path below needs an LV test.
      assert Multilang.enabled_languages() == [Multilang.primary_language()]

      {:ok, view, html} = live(conn, @path)

      assert html =~ "nothing to sweep"
      refute has_element?(view, "#catalogue-sweep-langs-form")
    end
  end

  # The checkbox group only renders when a second language is enabled, which
  # the test database does not have — so what the group POSTS is pinned here,
  # against explicit inputs, rather than through a form that never renders.
  describe "picked_langs/2" do
    alias PhoenixKitCatalogue.Web.SettingsLive

    @available ["et", "ru", "fi"]

    test "keeps the ticked codes" do
      assert SettingsLive.picked_langs(%{"langs" => ["et", "ru"]}, @available) == ["et", "ru"]
    end

    test "an unticked group posts no key at all, and that means none" do
      assert SettingsLive.picked_langs(%{}, @available) == []
    end

    test "a code that is not on offer is dropped" do
      assert SettingsLive.picked_langs(%{"langs" => ["et", "xx"]}, @available) == ["et"]
    end

    test "a lone value (not a list) still counts" do
      assert SettingsLive.picked_langs(%{"langs" => "ru"}, @available) == ["ru"]
    end

    test "junk shapes never reach the setting" do
      assert SettingsLive.picked_langs(%{"langs" => [1, nil, %{}, "fi"]}, @available) == ["fi"]
      assert SettingsLive.picked_langs(%{"langs" => ["et", "et"]}, @available) == ["et"]
    end
  end

  test "the module registers the page under Settings" do
    [tab] = PhoenixKitCatalogue.settings_tabs()

    assert tab.parent == :admin_settings
    assert tab.path == "catalogue"
    assert tab.live_view == {PhoenixKitCatalogue.Web.SettingsLive, :settings}
    assert tab.permission == PhoenixKitCatalogue.module_key()
  end
end
