defmodule PhoenixKitCatalogue.Web.SettingsLiveTest do
  @moduledoc """
  Settings → Catalogue. Every control is driven through the page's real form
  and the stored setting read back — a control that renders but never writes
  is the failure this guards against.
  """
  use PhoenixKitCatalogue.LiveCase

  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitCatalogue.Web.Settings

  @path "/en/admin/settings/catalogues"

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
      assert Multilang.enabled_languages() == [Multilang.primary_language()]

      {:ok, view, html} = live(conn, @path)

      assert html =~ "nothing to sweep"
      refute has_element?(view, "#catalogue-sweep-langs-form")
    end
  end

  describe "the sweep's languages" do
    alias PhoenixKit.Modules.Languages

    setup do
      {:ok, _} = Languages.enable_system()
      {:ok, _} = Languages.add_language("fr-FR")
      {:ok, _} = Languages.add_language("de-DE")

      # The page offers every enabled language but the primary one.
      offered = Multilang.enabled_languages() -- [Multilang.primary_language()]
      assert "fr-FR" in offered and "de-DE" in offered
      %{offered: offered}
    end

    defp stored_codes,
      do: PhoenixKit.Settings.get_json_setting("catalogue_translation_sweep_langs")

    test "each box posts its own language code", %{conn: conn, offered: offered} do
      {:ok, view, _html} = live(conn, @path)

      for lang <- offered do
        assert has_element?(
                 view,
                 ~s(#catalogue-sweep-langs-form input[type="checkbox"][name="langs[]"][value="#{lang}"])
               )
      end

      # A hidden companion would post a second value under the same name.
      refute has_element?(view, ~s(#catalogue-sweep-langs-form input[type="hidden"]))
    end

    test "one ticked stores that code", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      html =
        view |> form("#catalogue-sweep-langs-form", %{"langs" => ["fr-FR"]}) |> render_change()

      assert stored_codes() == %{"codes" => ["fr-FR"]}
      assert Settings.sweep_langs() == ["fr-FR"]
      assert html =~ "Saved."
      assert has_element?(view, "#catalogue-sweep-lang-fr-FR[checked]")
      refute has_element?(view, "#catalogue-sweep-lang-de-DE[checked]")
    end

    test "several ticked store each of them", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      view
      |> form("#catalogue-sweep-langs-form", %{"langs" => ["fr-FR", "de-DE"]})
      |> render_change()

      assert %{"codes" => codes} = stored_codes()
      assert Enum.sort(codes) == ["de-DE", "fr-FR"]
      assert has_element?(view, "#catalogue-sweep-lang-fr-FR[checked]")
      assert has_element?(view, "#catalogue-sweep-lang-de-DE[checked]")
    end

    test "none ticked stores none, and a box can be ticked again", %{conn: conn} do
      {:ok, _} = Settings.update_sweep_langs(["fr-FR", "de-DE"])
      {:ok, view, _html} = live(conn, @path)

      view |> form("#catalogue-sweep-langs-form", %{"langs" => []}) |> render_change()

      assert stored_codes() == %{"codes" => []}
      assert Settings.sweep_langs() == []
      refute has_element?(view, "#catalogue-sweep-langs-form input[checked]")

      view |> form("#catalogue-sweep-langs-form", %{"langs" => ["de-DE"]}) |> render_change()
      assert Settings.sweep_langs() == ["de-DE"]
    end

    test "a code the page does not offer is dropped", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      # `form/3` refuses a value no box carries, so the crafted post is
      # pushed as the event the form sends.
      render_change(view, "save_sweep_langs", %{"langs" => ["fr-FR", "xx-XX", "false", "true"]})

      assert stored_codes() == %{"codes" => ["fr-FR"]}
    end
  end

  describe "who changed a setting" do
    alias PhoenixKit.Modules.Languages

    setup %{conn: conn, scope: scope} do
      {:ok, _} = Languages.enable_system()
      {:ok, _} = Languages.add_language("fr-FR")
      {:ok, _} = Settings.update_context_menu_enabled(true)
      {:ok, _} = Settings.update_seo_fields_visible(false)
      {:ok, _} = Settings.update_sweep_enabled(false)
      {:ok, _} = Settings.update_sweep_interval_minutes(60)
      {:ok, _} = Settings.update_sweep_max_per_run(200)
      {:ok, _} = Settings.update_sweep_langs([])

      %{conn: with_scope(conn, scope), actor: scope.user.uuid}
    end

    # Every control on the page, each through its own form.
    for {form, params, key} <- [
          {"#catalogue-context-menu-form", %{"value" => "false"},
           "catalogue_row_context_menu_enabled"},
          {"#catalogue-seo-fields-form", %{"value" => "true"},
           "catalogue_item_seo_fields_visible"},
          {"#catalogue-sweep-form", %{"value" => "true"}, "catalogue_translation_sweep_enabled"},
          {"#catalogue-sweep-interval-form", %{"value" => "15"},
           "catalogue_translation_sweep_interval_minutes"},
          {"#catalogue-sweep-max-form", %{"value" => "7"},
           "catalogue_translation_sweep_max_per_run"},
          {"#catalogue-sweep-langs-form", %{"langs" => ["fr-FR"]},
           "catalogue_translation_sweep_langs"}
        ] do
      test "#{key}: the history entry names the admin and the settings page",
           %{conn: conn, actor: actor} do
        {:ok, view, _html} = live(conn, @path)

        view |> form(unquote(form), unquote(Macro.escape(params))) |> render_change()

        row =
          assert_activity_logged("setting.changed",
            actor_uuid: actor,
            metadata_has: %{"key" => unquote(key), "source" => "settings"}
          )

        assert row.mode == "manual"
      end
    end
  end

  describe "what the page does not handle" do
    import ExUnit.CaptureLog

    test "an unknown event and a stray message are logged and ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)

      log =
        capture_log([level: :debug], fn ->
          render_hook(view, "no_such_event", %{})
          send(view.pid, :stray_message)
          # A number where the form posts a string, as a crafted event would.
          render_hook(view, "save_sweep_interval", %{"value" => 5})
          render_hook(view, "save_sweep_max_per_run", %{"value" => nil})
          assert render(view) =~ "Minutes between runs"
        end)

      assert log =~ ~s(SettingsLive ignored unhandled event: "no_such_event")
      assert log =~ "SettingsLive ignored unhandled message: :stray_message"
      assert log =~ ~s(SettingsLive ignored unhandled event: "save_sweep_interval")
      assert log =~ ~s(SettingsLive ignored unhandled event: "save_sweep_max_per_run")
    end
  end

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
    assert tab.path == "catalogues"
    assert tab.live_view == {PhoenixKitCatalogue.Web.SettingsLive, :settings}
    assert tab.permission == PhoenixKitCatalogue.module_key()
  end
end
