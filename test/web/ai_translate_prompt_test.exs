defmodule PhoenixKitCatalogue.Web.AITranslatePromptTest do
  @moduledoc """
  Regression coverage for the in-form AI-translate button on item/category
  forms: `assign_ai_translation/3` (`Web.Helpers`) must preselect the
  catalogue's own translation prompt (`AIPrompt.ensure_prompt/0`), not the
  shared `phoenixkit-translate-content` default `FormGlue` falls back to.

  The shared prompt has no `seo_title`/`seo_description`/`summary` slots
  (block-6 plan, Task 1 widened `field_columns/1` to include them), so
  dispatching a translation on the shared prompt fails every job with
  `{:missing_fields, [...]}`. Multilang is DB-settings-backed — see
  `ItemFormSeoTest`'s moduledoc — so every test here enables the Languages
  module with a second language before mounting.

  Oban isn't started by the catalogue test environment (see
  `TranslationSweepWorkerTest`'s notes) — each test starts its own
  `:manual`-mode instance against the sandboxed test repo.
  """

  use PhoenixKitCatalogue.LiveCase
  use Oban.Testing, repo: PhoenixKitCatalogue.Test.Repo

  alias PhoenixKit.Modules.Languages
  alias PhoenixKitAI.TranslateWorker
  alias PhoenixKitCatalogue.AIPrompt

  @base "/en/admin/catalogues"
  @lang "fr-FR"

  defp edit_item_url(uuid), do: "#{@base}/items/#{uuid}/edit"
  defp edit_category_url(uuid), do: "#{@base}/categories/#{uuid}/edit"

  defp translate_worker_jobs, do: all_enqueued(worker: TranslateWorker)

  defp enable_multilang! do
    {:ok, _} = Languages.enable_system()
    {:ok, _} = Languages.add_language(@lang)
    :ok
  end

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

  describe "item form" do
    test "dispatching an AI translation enqueues a job on the catalogue prompt", %{conn: conn} do
      catalogue = fixture_catalogue()
      item = fixture_item(%{catalogue_uuid: catalogue.uuid, name: "Vase"})

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

      render_click(view, "ai_translate_lang", %{"lang" => "*"})

      assert {:ok, catalogue_prompt_uuid} = AIPrompt.ensure_prompt()
      shared_default = PhoenixKitAI.Translations.default_prompt_uuid()

      assert [%{args: %{"resource_uuid" => uuid, "prompt_uuid" => prompt_uuid}} | _] =
               translate_worker_jobs()

      assert uuid == item.uuid
      assert prompt_uuid == catalogue_prompt_uuid
      refute prompt_uuid == shared_default
    end
  end

  describe "category form" do
    test "dispatching an AI translation enqueues a job on the catalogue prompt", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue, %{name: "Shelves"})

      {:ok, view, _html} = live(conn, edit_category_url(category.uuid))

      render_click(view, "ai_translate_lang", %{"lang" => "*"})

      assert {:ok, catalogue_prompt_uuid} = AIPrompt.ensure_prompt()
      shared_default = PhoenixKitAI.Translations.default_prompt_uuid()

      assert [%{args: %{"resource_uuid" => uuid, "prompt_uuid" => prompt_uuid}} | _] =
               translate_worker_jobs()

      assert uuid == category.uuid
      assert prompt_uuid == catalogue_prompt_uuid
      refute prompt_uuid == shared_default
    end
  end
end
