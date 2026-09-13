defmodule PhoenixKitCatalogue.Workers.TranslationSweepWorker do
  @moduledoc """
  Opt-in, self-rescheduling Oban worker that tops up catalogue AI
  translations: on every tick it enqueues one `PhoenixKitAI.TranslateWorker`
  job per (resource, target language) pair currently `:missing` or
  `:stale` — `:unknown` is never picked up automatically (design source
  doc §4.1: an operator decides that pair's fate explicitly).

  Settings (`PhoenixKitCatalogue.Web.Settings`, Task 4):

    * `catalogue_translation_sweep_enabled` — off by default; a disabled
      tick still reschedules its successor, it just does no work.
    * `catalogue_translation_sweep_interval_minutes` — gap to the next tick.
    * `catalogue_translation_sweep_langs` — target languages to consider.
    * `catalogue_translation_sweep_max_per_run` — enqueue cap for one tick,
      counted in jobs (across every resource type) not resources.

  ## Self-rescheduling

  The very first action of `perform/1` is scheduling the NEXT tick —
  before any of the tick's own work runs — so a crashed or slow tick
  never breaks the chain. Uniqueness (`period: :infinity`, `states:
  [:available, :scheduled]`) keeps at most one pending tick in the
  queue at a time; the explicit state list (rather than Oban's default,
  which references `:suspended`) sidesteps the `22P02` landmine
  `PhoenixKitAI.Translations` and `PhoenixKitCatalogue.Workers.PdfExtractor`
  already document for hosts whose `oban_job_state` enum predates that
  value. `max_attempts: 1` — retrying a missed tick is pointless, the
  next one is already scheduled.

  `ensure_scheduled/0` seeds the very first tick at boot (see
  `PhoenixKitCatalogue.children/0`) and is safe to call again any time
  (e.g. a future settings save) — the same uniqueness collapses repeat
  calls to the one pending job.
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitAI.Translations
  alias PhoenixKitCatalogue.AIPrompt
  alias PhoenixKitCatalogue.TranslationStatus
  alias PhoenixKitCatalogue.Web.Settings, as: SweepSettings

  # `TranslationStatus.list/2` type ↔ the `ai_translatables/0` resource_type
  # string `PhoenixKitAI.Translations.enqueue/1` expects.
  @resource_types %{
    item: "catalogue_item",
    category: "catalogue_category",
    set_label: "catalogue_set_label",
    set_value: "catalogue_set_value"
  }

  @doc "The `ai_translatables/0` resource_type string for a `TranslationStatus.list/2` type atom."
  @spec resource_type_for(:item | :category | :set_label | :set_value) :: String.t()
  def resource_type_for(type), do: Map.fetch!(@resource_types, type)

  @unique_opts [period: :infinity, states: [:available, :scheduled]]

  # A pair whose last translation job was DISCARDED (every attempt spent,
  # or a deterministic failure) this recently is left alone. Without it
  # the candidate list — deterministic, sorted, capped — re-enqueued the
  # same failing rows every tick and never reached anything behind them
  # (week review, 2026-09-13). The state the pair is in does not change:
  # it is still `:missing`/`:stale`, still on the Translations page, and
  # a manual Translate there is unaffected — only the automatic top-up
  # backs off. Oban keeps discarded rows for its pruner's window (7 days
  # by default), comfortably longer than this.
  @failure_backoff_hours 24

  # Boot-time bootstrap, mirroring `AttributeSets.child_spec/1` /
  # `SupplierFields.child_spec/1`: a one-shot `Task` (not a GenServer —
  # there's nothing to keep alive) that seeds the first scheduled tick and
  # then exits. `restart: :temporary` — a failed attempt just means no
  # chain until the next boot or manual `ensure_scheduled/0` call; nothing
  # here is worth restart-looping over.
  #
  # Gated on `ensure_scheduled_if_enabled/0` rather than the unconditional
  # `ensure_scheduled/0`: the Global Constraints of the block-6 plan
  # require this feature to be additive for every OTHER catalogue
  # consumer — a host that never turns the sweep on must not get a
  # perpetual hourly no-op Oban job from merely upgrading the dependency.
  # A host that DOES enable it gets the chain from
  # `Web.Settings.update_sweep_enabled/1` instead (see there), and once
  # started, the chain keeps re-scheduling itself regardless of the
  # setting's later value — same self-healing property, just deferred
  # until the feature is actually opted into.
  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    %{
      id: __MODULE__.Bootstrap,
      start: {Task, :start_link, [&__MODULE__.ensure_scheduled_if_enabled/0]},
      restart: :temporary
    }
  end

  @impl Oban.Worker
  def perform(_job) do
    _ = schedule_next_tick()

    if SweepSettings.sweep_enabled?() do
      sweep()
    end

    :ok
  end

  @doc """
  Ensures exactly one sweep tick is available/scheduled. Called from the
  boot-time task registered in `children/0`; concurrent callers (boot,
  a future settings save, the tick itself) all collapse onto the same
  unique row.
  """
  @spec ensure_scheduled() :: {:ok, Oban.Job.t()} | {:error, term()}
  def ensure_scheduled, do: schedule_next_tick()

  @doc """
  Boot-time gate for `ensure_scheduled/0`: seeds the chain only if the
  sweep is already enabled, so a host that has never turned it on gets no
  ticking job row. `Web.Settings.update_sweep_enabled/1` calls
  `ensure_scheduled/0` unconditionally when it flips the setting to
  `true`, so the chain always starts exactly when a host first opts in —
  at boot (already enabled from a previous save) or from that save
  itself.
  """
  @spec ensure_scheduled_if_enabled() :: {:ok, Oban.Job.t()} | {:error, term()} | :skipped
  def ensure_scheduled_if_enabled do
    if SweepSettings.sweep_enabled?(), do: ensure_scheduled(), else: :skipped
  end

  defp schedule_next_tick do
    interval_seconds = SweepSettings.sweep_interval_minutes() * 60

    %{}
    |> new(unique: @unique_opts, schedule_in: interval_seconds)
    |> Oban.insert()
  rescue
    e in [
      DBConnection.ConnectionError,
      Postgrex.Error,
      Ecto.QueryError,
      ArgumentError,
      RuntimeError
    ] ->
      Logger.warning(
        "TranslationSweepWorker: could not schedule the next tick: #{Exception.message(e)}"
      )

      {:error, :schedule_failed}
  catch
    :exit, reason ->
      Logger.warning(
        "TranslationSweepWorker: could not schedule the next tick: #{inspect(reason)}"
      )

      {:error, :schedule_failed}
  end

  defp sweep do
    case endpoint_and_prompts() do
      {:ok, endpoint_uuid, prompts} ->
        langs = SweepSettings.sweep_langs()
        max = SweepSettings.sweep_max_per_run()

        langs
        |> candidates(max)
        |> Enum.each(&enqueue_row(&1, endpoint_uuid, prompts))

      :unavailable ->
        :ok
    end
  end

  # Up to `max` (resource, lang) rows across every catalogue translatable
  # type, `:missing` or `:stale` only — `:unknown` is excluded by the state
  # filter, never reaching this list at all — minus the pairs that failed
  # within the back-off window. The page is widened by the size of that
  # set so the exclusion cannot empty it: two hundred failing rows at the
  # head of the sort no longer hide the two-hundred-and-first.
  defp candidates(langs, max) do
    failed = recently_failed()
    per_page = max + map_size(failed)

    @resource_types
    |> Enum.flat_map(fn {type, resource_type} ->
      type
      |> TranslationStatus.list(langs: langs, state: [:missing, :stale], per_page: per_page)
      |> Enum.reject(&Map.has_key?(failed, {resource_type, &1.uuid, &1.lang}))
    end)
    |> Enum.take(max)
  end

  # `{resource_type, resource_uuid, target_lang}` of every TranslateWorker
  # job discarded inside the back-off window, as the keys of a plain map
  # (not a MapSet: dialyzer cannot see through the opaque type across the
  # `rescue`). Fails open (empty) on any query error — a sweep that cannot
  # read the job table still sweeps, as it did before the back-off existed.
  defp recently_failed do
    since = DateTime.add(DateTime.utc_now(), -@failure_backoff_hours * 3600, :second)

    from(j in "oban_jobs",
      where: j.worker == "PhoenixKitAI.TranslateWorker",
      where: j.state == "discarded" and j.discarded_at > ^since,
      select:
        {fragment("?->>'resource_type'", j.args), fragment("?->>'resource_uuid'", j.args),
         fragment("?->>'target_lang'", j.args)}
    )
    |> PhoenixKit.RepoHelper.repo().all()
    |> Map.new(&{&1, true})
  rescue
    e ->
      Logger.warning(
        "TranslationSweepWorker: could not read failed jobs: #{Exception.message(e)}"
      )

      %{}
  end

  defp enqueue_row(%{type: type, uuid: uuid, lang: lang}, endpoint_uuid, prompts) do
    resource_type = Map.fetch!(@resource_types, type)

    case Map.get(prompts, resource_type) do
      nil ->
        Logger.warning(
          "TranslationSweepWorker: no prompt configured for #{resource_type} — skipping #{uuid}/#{lang}"
        )

      prompt_uuid ->
        do_enqueue(resource_type, uuid, lang, endpoint_uuid, prompt_uuid)
    end
  end

  defp do_enqueue(resource_type, uuid, lang, endpoint_uuid, prompt_uuid) do
    params = %{
      resource_type: resource_type,
      resource_uuid: uuid,
      endpoint_uuid: endpoint_uuid,
      prompt_uuid: prompt_uuid,
      source_lang: Multilang.primary_language(),
      target_lang: lang,
      actor_uuid: nil
    }

    case Translations.enqueue(params) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "TranslationSweepWorker: enqueue failed for #{resource_type}/#{uuid}/#{lang}: " <>
            inspect(reason)
        )
    end
  end

  @doc """
  Resolves the AI endpoint and per-resource-type prompt uuids, the same way
  every sweep tick does: `Translations.available?/0` ALONE isn't enough (it
  doesn't verify the configured default endpoint still exists/is enabled) —
  the double check the design source calls for (§4.3 step 2).

  Public so `Web.TranslationsLive`'s manual "Translate" / bulk actions share
  this exact resolution path with the automatic sweep tick, rather than
  re-deriving which prompt belongs to which resource type a second time.
  """
  @spec endpoint_and_prompts() ::
          {:ok, String.t(), %{String.t() => String.t()}} | :unavailable
  def endpoint_and_prompts do
    with true <- Translations.available?(),
         endpoint_uuid when is_binary(endpoint_uuid) <- Translations.default_endpoint_uuid(),
         {:ok, catalogue_prompt_uuid} <- AIPrompt.ensure_prompt(),
         {:ok, sets_prompt_uuid} <- AIPrompt.ensure_sets_prompt() do
      prompts = %{
        "catalogue_item" => catalogue_prompt_uuid,
        "catalogue_category" => catalogue_prompt_uuid,
        "catalogue_set_label" => sets_prompt_uuid,
        "catalogue_set_value" => sets_prompt_uuid
      }

      {:ok, endpoint_uuid, prompts}
    else
      _ -> :unavailable
    end
  end
end
