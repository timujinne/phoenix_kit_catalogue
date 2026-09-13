defmodule PhoenixKitCatalogue.Workers.TranslationSweepWorkerTest do
  @moduledoc """
  Coverage for the opt-in translation sweep tick: a disabled tick still
  reschedules its successor but enqueues nothing; an enabled tick tops up
  `:missing`/`:stale` (resource, lang) pairs and never touches `:unknown`
  ones (excluded upstream by `TranslationStatus.list/2`'s state filter,
  not by any special-casing here); the per-tick cap is honored; and
  `ensure_scheduled/0` collapses repeated/concurrent calls to one pending
  tick via Oban's `unique:` option.

  Oban isn't started by the catalogue test environment (see
  `PdfLibraryTest`'s notes) — each test starts its own `:manual`-mode
  instance against the sandboxed test repo, so `Oban.insert/1` writes
  real rows without any queue actually processing them.
  """

  use PhoenixKitCatalogue.DataCase, async: false
  use Oban.Testing, repo: PhoenixKitCatalogue.Test.Repo

  alias PhoenixKit.Modules.Languages
  alias PhoenixKitAI.TranslateWorker
  alias PhoenixKitAI.Translations
  alias PhoenixKitCatalogue.AIPrompt
  alias PhoenixKitCatalogue.AITranslatable
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitCatalogue.TranslationStatus
  alias PhoenixKitCatalogue.Web.Settings, as: SweepSettings
  alias PhoenixKitCatalogue.Workers.TranslationSweepWorker

  @lang "fr-FR"

  setup do
    start_supervised!({Oban, repo: PhoenixKitCatalogue.Test.Repo, testing: :manual})

    {:ok, _} = PhoenixKitAI.enable_system()

    # `sweep_langs/0` keeps only enabled languages, like a manual Translate.
    {:ok, _} = Languages.enable_system()
    {:ok, _} = Languages.add_language(@lang)

    {:ok, endpoint} =
      PhoenixKitAI.create_endpoint(%{
        name: "Test Endpoint",
        provider: "openrouter",
        api_key: "test-key",
        model: "openai/gpt-4o-mini",
        enabled: true
      })

    SweepSettings.update_sweep_enabled(false)
    SweepSettings.update_sweep_langs([@lang])
    SweepSettings.update_sweep_max_per_run(200)
    SweepSettings.update_sweep_interval_minutes(60)

    # `ai_enabled` and the two cached sweep settings survive the sandbox
    # rollback in `PhoenixKit.Settings`'s ETS cache (invalidated on write,
    # not on transaction rollback) — reset them explicitly so later test
    # files see the same defaults they'd see with nothing ever written,
    # the same reason `TranslationStatusTest`'s `entities_enabled` setup
    # resets on exit.
    on_exit(fn ->
      Languages.disable_system()
      PhoenixKitAI.disable_system()
      SweepSettings.update_sweep_enabled(false)
      SweepSettings.update_sweep_max_per_run(200)
      SweepSettings.update_sweep_interval_minutes(60)
    end)

    %{endpoint: endpoint}
  end

  defp create_item!(name) do
    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "Catalogue " <> name})
    {:ok, item} = Catalogue.create_item(%{name: name, catalogue_uuid: catalogue.uuid})
    item
  end

  defp translate_worker_jobs, do: all_enqueued(worker: TranslateWorker)

  # A TranslateWorker job for `item`/@lang that Oban gave up on `ago` seconds ago.
  defp discard_job!(item, ago_seconds) do
    args = %{
      "resource_type" => "catalogue_item",
      "resource_uuid" => item.uuid,
      "endpoint_uuid" => Ecto.UUID.generate(),
      "prompt_uuid" => Ecto.UUID.generate(),
      "source_lang" => "en-US",
      "target_lang" => @lang,
      "actor_uuid" => nil
    }

    {:ok, job} = args |> TranslateWorker.new() |> Oban.insert()
    discarded_at = DateTime.add(DateTime.utc_now(), -ago_seconds, :second)

    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
      set: [state: "discarded", discarded_at: discarded_at]
    )

    job
  end

  defp available_translate_uuids do
    from(j in Oban.Job,
      where: j.worker == "PhoenixKitAI.TranslateWorker" and j.state == "available",
      select: fragment("?->>'resource_uuid'", j.args)
    )
    |> Repo.all()
  end

  defp sweep_worker_jobs, do: all_enqueued(worker: TranslationSweepWorker)

  describe "perform/1 — disabled" do
    test "enqueues nothing but still reschedules its own next tick" do
      _missing = create_item!("Widget")

      assert :ok = TranslationSweepWorker.perform(%Oban.Job{})

      assert translate_worker_jobs() == []
      assert [%Oban.Job{state: "scheduled"}] = sweep_worker_jobs()
    end
  end

  describe "perform/1 — enabled" do
    test "enqueues missing/stale pairs and never an unknown one" do
      SweepSettings.update_sweep_enabled(true)

      missing_a = create_item!("Alpha")
      missing_b = create_item!("Beta")
      unknown_c = create_item!("Gamma")

      # Translated outside `put_translation/4` — no fingerprint recorded,
      # so the pair is `:unknown`, not `:missing`/`:stale`.
      new_data =
        AITranslatable.force_put_language(unknown_c.data, @lang, %{"_name" => "Gamma FR"})

      {:ok, unknown_c} = Catalogue.update_item(unknown_c, %{data: new_data})
      assert TranslationStatus.state(unknown_c, @lang) == :unknown

      assert :ok = TranslationSweepWorker.perform(%Oban.Job{})

      jobs = translate_worker_jobs()
      assert length(jobs) == 2

      enqueued_uuids = Enum.map(jobs, & &1.args["resource_uuid"])
      assert missing_a.uuid in enqueued_uuids
      assert missing_b.uuid in enqueued_uuids
      refute unknown_c.uuid in enqueued_uuids

      assert Enum.all?(jobs, &(&1.args["target_lang"] == @lang))
      assert Enum.all?(jobs, &(&1.args["resource_type"] == "catalogue_item"))
    end

    test "picks up a stale pair (translated, then the source changed)" do
      SweepSettings.update_sweep_enabled(true)

      item = create_item!("Widget")
      {:ok, _} = AITranslatable.put_translation(item, @lang, %{"name" => "Widget FR"}, [])
      translated = Catalogue.get_item(item.uuid)
      {:ok, _} = Catalogue.update_item(translated, %{name: "Widget Mk2"})
      reloaded = Catalogue.get_item(item.uuid)
      assert TranslationStatus.state(reloaded, @lang) == :stale

      assert :ok = TranslationSweepWorker.perform(%Oban.Job{})

      assert [%{args: %{"resource_uuid" => uuid}}] = translate_worker_jobs()
      assert uuid == item.uuid
    end

    test "a pair whose job was discarded inside the back-off window is skipped, not re-enqueued" do
      SweepSettings.update_sweep_enabled(true)
      SweepSettings.update_sweep_max_per_run(1)

      # Sorted by name: the failing row comes first and, before the
      # back-off, filled the whole one-job page every tick.
      failing = create_item!("Alpha")
      next_in_line = create_item!("Beta")
      discard_job!(failing, 60)

      assert :ok = TranslationSweepWorker.perform(%Oban.Job{})

      assert available_translate_uuids() == [next_in_line.uuid]
    end

    test "a discard older than the back-off window is eligible again" do
      SweepSettings.update_sweep_enabled(true)
      item = create_item!("Alpha")
      discard_job!(item, 25 * 3600)

      assert :ok = TranslationSweepWorker.perform(%Oban.Job{})

      assert available_translate_uuids() == [item.uuid]
    end

    test "a stored sweep language that is not enabled is ignored" do
      SweepSettings.update_sweep_enabled(true)
      SweepSettings.update_sweep_langs([@lang, "xx-XX"])
      create_item!("Alpha")

      assert SweepSettings.sweep_langs() == [@lang]
      assert :ok = TranslationSweepWorker.perform(%Oban.Job{})
      assert Enum.all?(translate_worker_jobs(), &(&1.args["target_lang"] == @lang))
    end

    test "caps the number of jobs enqueued in one tick" do
      SweepSettings.update_sweep_enabled(true)
      SweepSettings.update_sweep_max_per_run(1)

      create_item!("Alpha")
      create_item!("Beta")
      create_item!("Gamma")

      assert :ok = TranslationSweepWorker.perform(%Oban.Job{})

      assert length(translate_worker_jobs()) == 1
    end
  end

  describe "ensure_scheduled/0" do
    test "repeated calls collapse to a single pending tick" do
      assert {:ok, _job} = TranslationSweepWorker.ensure_scheduled()
      assert {:ok, _job} = TranslationSweepWorker.ensure_scheduled()
      assert {:ok, _job} = TranslationSweepWorker.ensure_scheduled()

      assert length(sweep_worker_jobs()) == 1
    end
  end

  describe "ensure_scheduled_if_enabled/0" do
    test "seeds no chain while the sweep has never been enabled" do
      assert TranslationSweepWorker.ensure_scheduled_if_enabled() == :skipped
      assert sweep_worker_jobs() == []
    end

    test "seeds the chain once the sweep is enabled" do
      SweepSettings.update_sweep_enabled(true)

      assert {:ok, _job} = TranslationSweepWorker.ensure_scheduled_if_enabled()
      assert length(sweep_worker_jobs()) == 1
    end
  end

  describe "endpoint_and_prompts/0" do
    test "resolves a distinct prompt for catalogue_set_label than the shared default" do
      assert {:ok, _endpoint_uuid, prompts} = TranslationSweepWorker.endpoint_and_prompts()

      shared_default = Translations.default_prompt_uuid()
      {:ok, sets_prompt_uuid} = AIPrompt.ensure_sets_prompt()

      assert prompts["catalogue_set_label"] == sets_prompt_uuid
      assert prompts["catalogue_set_value"] == sets_prompt_uuid
      refute prompts["catalogue_set_label"] == shared_default
      refute prompts["catalogue_set_value"] == shared_default
    end
  end

  if Code.ensure_loaded?(PhoenixKitEntities.Managed) do
    describe "perform/1 — attribute-set labels" do
      setup do
        AttributeSets.register_deletion_guard()
        PhoenixKit.Settings.update_setting("entities_enabled", "true")
        on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)
        :ok
      end

      test "enqueues a set-label job whose prompt_uuid is NOT the shared default prompt" do
        SweepSettings.update_sweep_enabled(true)

        {:ok, set} =
          AttributeSets.create_set(%{name: "Ikea colors"}, actor_uuid: Ecto.UUID.generate())

        assert :ok = TranslationSweepWorker.perform(%Oban.Job{})

        jobs = translate_worker_jobs()
        assert [%{args: %{"resource_uuid" => uuid, "prompt_uuid" => prompt_uuid}}] = jobs
        assert uuid == set.uuid

        refute prompt_uuid == Translations.default_prompt_uuid()
        assert {:ok, prompt_uuid} == AIPrompt.ensure_sets_prompt()
      end
    end
  end
end
