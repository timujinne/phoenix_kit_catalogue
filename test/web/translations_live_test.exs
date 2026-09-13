defmodule PhoenixKitCatalogue.Web.TranslationsLiveTest do
  @moduledoc """
  LiveView coverage for the catalogue translation-freshness admin page
  (block-6 plan, Task 5): the notice shown when AI isn't configured, the
  filtered listing, the "Translate" / "Stamp fresh" row actions, and a
  bulk action scoped to the current type/language filter.

  Oban isn't started by the catalogue test environment (see
  `TranslationSweepWorkerTest`'s notes) — each test starts its own
  `:manual`-mode instance against the sandboxed test repo.

  Multilang is DB-settings-backed — see `ItemFormSeoTest`'s moduledoc —
  so `setup` enables the Languages module with `@lang` as a second
  language (`enable_multilang!/0`, same helper as `AITranslatePromptTest`).
  This LiveView's `lang` filter now validates against `@languages`
  (block-6-followup: the language-filter fix), so a test that skipped
  this would see every `@lang` row treated as unknown and folded into
  "all languages" instead.
  """

  use PhoenixKitCatalogue.LiveCase
  use Oban.Testing, repo: PhoenixKitCatalogue.Test.Repo

  alias PhoenixKit.Modules.Languages
  alias PhoenixKitAI.TranslateWorker
  alias PhoenixKitCatalogue.AITranslatable
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.TranslationStatus

  @base "/en/admin/catalogue/translations"
  @lang "fr-FR"

  defp translate_worker_jobs, do: all_enqueued(worker: TranslateWorker)

  defp enable_multilang! do
    {:ok, _} = Languages.enable_system()
    {:ok, _} = Languages.add_language(@lang)
    :ok
  end

  defp create_item!(name) do
    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "Catalogue " <> name})
    {:ok, item} = Catalogue.create_item(%{name: name, catalogue_uuid: catalogue.uuid})
    item
  end

  defp create_category!(name) do
    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "Catalogue " <> name})
    {:ok, category} = Catalogue.create_category(%{name: name, catalogue_uuid: catalogue.uuid})
    category
  end

  describe "AI translation not configured" do
    test "renders a notice instead of the table", %{conn: conn} do
      {:ok, _view, html} = live(conn, @base)

      assert html =~ "AI translation is not configured"
      refute html =~ "translations-table"
    end

    # `:languages` is only assigned once `ai_available` is true (see
    # `mount/3`) — a crafted "filter" event must not reach
    # `socket.assigns.languages` directly and crash the LiveView with a
    # `KeyError` while the notice is showing.
    test "a crafted filter event does not crash the LiveView", %{conn: conn} do
      {:ok, view, _html} = live(conn, @base)

      html = render_change(view, "filter", %{"filter" => %{"lang" => "xx-XX"}})

      assert Process.alive?(view.pid)
      assert html =~ "AI translation is not configured"
    end
  end

  describe "with AI configured" do
    setup do
      start_supervised!({Oban, repo: PhoenixKitCatalogue.Test.Repo, testing: :manual})
      enable_multilang!()

      {:ok, _} = PhoenixKitAI.enable_system()

      {:ok, endpoint} =
        PhoenixKitAI.create_endpoint(%{
          name: "Test Endpoint",
          provider: "openrouter",
          api_key: "test-key",
          model: "openai/gpt-4o-mini",
          enabled: true
        })

      on_exit(fn -> PhoenixKitAI.disable_system() end)

      %{endpoint: endpoint}
    end

    test "the enqueueing buttons carry a busy state (sweep 2026-09-13)", %{conn: conn} do
      _item = create_item!("Busy Widget")
      {:ok, _view, html} = live(conn, @base <> "?type=item&lang=#{@lang}")

      # Every rendered button for these events carries the busy state; the
      # row buttons only render when the AI is configured, so assert "none
      # without" rather than "one with".
      assert html =~ ~s(phx-click="bulk_translate_missing")

      for ev <- ~w(bulk_translate_missing bulk_retranslate_stale translate stamp_fresh) do
        refute html =~ ~r/phx-click="#{ev}"(?:(?!phx-disable-with)[^>])*>/s, ev
      end
    end

    test "lists an item as missing for the selected language", %{conn: conn} do
      item = create_item!("Widget")

      {:ok, _view, html} = live(conn, @base <> "?lang=#{@lang}")

      assert html =~ item.name
      assert html =~ "Missing"
    end

    test "clicking Translate enqueues one job for that resource and language", %{conn: conn} do
      item = create_item!("Widget")

      {:ok, view, _html} = live(conn, @base <> "?lang=#{@lang}")

      view
      |> element("button[phx-click='translate'][phx-value-uuid='#{item.uuid}']")
      |> render_click()

      assert [%{args: %{"resource_uuid" => uuid, "target_lang" => @lang}}] =
               translate_worker_jobs()

      assert uuid == item.uuid
    end

    test "Stamp fresh flips an unknown pair to fresh", %{conn: conn} do
      item = create_item!("Widget")

      new_data = AITranslatable.force_put_language(item.data, @lang, %{"_name" => "Widget FR"})
      {:ok, item} = Catalogue.update_item(item, %{data: new_data})
      assert TranslationStatus.state(item, @lang) == :unknown

      {:ok, view, html} = live(conn, @base <> "?lang=#{@lang}")
      assert html =~ "Unknown"

      view
      |> element("button[phx-click='stamp_fresh'][phx-value-uuid='#{item.uuid}']")
      |> render_click()

      reloaded = Catalogue.get_item(item.uuid)
      assert TranslationStatus.state(reloaded, @lang) == :fresh
    end

    test "bulk Translate all missing only enqueues rows matching the current filter", %{
      conn: conn
    } do
      item = create_item!("Widget")
      _category = create_category!("Cards")

      {:ok, view, _html} = live(conn, @base <> "?type=item&lang=#{@lang}")

      view
      |> element("button[phx-click='bulk_translate_missing']")
      |> render_click()

      jobs = translate_worker_jobs()
      assert length(jobs) == 1
      assert [%{args: %{"resource_type" => "catalogue_item", "resource_uuid" => uuid}}] = jobs
      assert uuid == item.uuid
    end

    test "a crafted phx-value-type does not crash the LiveView", %{conn: conn} do
      item = create_item!("Widget")
      {:ok, view, _html} = live(conn, @base <> "?lang=#{@lang}")

      html =
        render_click(view, "translate", %{"type" => "bogus", "uuid" => item.uuid, "lang" => @lang})

      assert Process.alive?(view.pid)
      assert html =~ item.name
      assert translate_worker_jobs() == []
    end

    test "an unrelated module's translation_completed event does not crash the page", %{
      conn: conn
    } do
      item = create_item!("Widget")
      {:ok, view, _html} = live(conn, @base <> "?lang=#{@lang}")

      send(
        view.pid,
        {:ai_translation, :translation_completed,
         %{resource_type: "some_other_module_thing", resource_uuid: "x", target_lang: @lang}}
      )

      html = render(view)
      assert Process.alive?(view.pid)
      assert html =~ item.name
    end

    test "a catalogue translation_completed event refreshes the rows after the debounce window",
         %{conn: conn} do
      item = create_item!("Widget")
      {:ok, _} = AITranslatable.put_translation(item, @lang, %{"name" => "Widget FR"}, [])
      {:ok, view, html} = live(conn, @base <> "?lang=#{@lang}")
      assert html =~ "Fresh"

      # The source changes after the page's first render — until the
      # debounced refresh runs, the page still shows the stale state.
      {:ok, _} = Catalogue.update_item(Catalogue.get_item(item.uuid), %{name: "Widget Mk2"})

      send(
        view.pid,
        {:ai_translation, :translation_completed,
         %{resource_type: "catalogue_item", resource_uuid: item.uuid, target_lang: @lang}}
      )

      Process.sleep(400)
      assert render(view) =~ "Stale"
    end

    test "the language select has no blank-value option to silently fall back to",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, @base)

      refute has_element?(view, "#translations-filter-lang option[value='']")
      assert has_element?(view, "#translations-filter-lang option[value='all']")
    end

    test "a blank lang filter falls back to the enabled languages instead of an empty string",
         %{conn: conn} do
      item = create_item!("Widget")
      {:ok, view, _html} = live(conn, @base)

      html = render_change(view, "filter", %{"filter" => %{"lang" => ""}})

      assert has_element?(view, "#translation-row-item-#{item.uuid}-#{@lang}")
      refute html =~ ~s(id="translation-row-item-#{item.uuid}-")
    end

    test "an unknown lang filter value falls back to all languages", %{conn: conn} do
      item = create_item!("Widget")
      {:ok, view, _html} = live(conn, @base)

      render_change(view, "filter", %{"filter" => %{"lang" => "xx-XX"}})

      assert has_element?(view, "#translation-row-item-#{item.uuid}-#{@lang}")
    end

    test "a crafted ?lang= query param falls back to all languages instead of collapsing rows",
         %{conn: conn} do
      item = create_item!("Widget")

      {:ok, view, _html} = live(conn, @base <> "?lang=xx-XX")

      assert has_element?(view, "#translation-row-item-#{item.uuid}-#{@lang}")
    end

    test "a blank lang filter does not report an existing translation as missing", %{conn: conn} do
      item = create_item!("Widget")
      {:ok, _} = AITranslatable.put_translation(item, @lang, %{"name" => "Widget FR"}, [])

      {:ok, view, _html} = live(conn, @base)

      html = render_change(view, "filter", %{"filter" => %{"lang" => ""}})

      # The per-state chips always render the word "Missing" (as a static
      # label, count 0 or not) — assert the actual counts instead of the
      # word's mere presence, or this would pass even with the bug back.
      assert html =~ "Fresh: 1"
      assert html =~ "Missing: 0"
    end

    test "clicking Translate after a blank lang filter still queues the job", %{conn: conn} do
      item = create_item!("Widget")
      {:ok, view, _html} = live(conn, @base)

      render_change(view, "filter", %{"filter" => %{"lang" => ""}})

      html =
        view
        |> element("button[phx-click='translate'][phx-value-uuid='#{item.uuid}']")
        |> render_click()

      refute html =~ "Could not queue"
      refute html =~ "Unknown target language"

      assert [%{args: %{"resource_uuid" => uuid, "target_lang" => @lang}}] =
               translate_worker_jobs()

      assert uuid == item.uuid
    end

    test "translate with an unknown target lang is rejected before reaching enqueue",
         %{conn: conn} do
      item = create_item!("Widget")
      {:ok, view, _html} = live(conn, @base <> "?lang=#{@lang}")

      html =
        render_click(view, "translate", %{
          "type" => "item",
          "uuid" => item.uuid,
          "lang" => "xx-XX"
        })

      assert Process.alive?(view.pid)
      assert html =~ "Unknown target language"
      assert translate_worker_jobs() == []
    end

    test "translate with a blank target lang is rejected before reaching enqueue", %{conn: conn} do
      item = create_item!("Widget")
      {:ok, view, _html} = live(conn, @base <> "?lang=#{@lang}")

      html =
        render_click(view, "translate", %{"type" => "item", "uuid" => item.uuid, "lang" => ""})

      assert Process.alive?(view.pid)
      assert html =~ "Unknown target language"
      assert translate_worker_jobs() == []
    end
  end
end
