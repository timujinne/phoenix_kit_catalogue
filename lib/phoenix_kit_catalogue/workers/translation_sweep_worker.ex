defmodule PhoenixKitCatalogue.Workers.TranslationSweepWorker do
  @moduledoc """
  The catalogue's AI-translation sweep: an opt-in, self-rescheduling
  Oban chain that tops up every translation a catalogue resource is
  missing or has let go stale. The chain, the gates, the caps, the
  back-off for pairs that keep failing and the record of each tick are
  `PhoenixKitAI.TranslationSweep`'s; this worker keeps its name (scheduled
  jobs point at it) and supplies what is the catalogue's:

    * the candidates — categories, items, attribute-set labels and values
      whose translation `TranslationStatus` reports `:missing` or `:stale`
      (never `:unknown`: an operator decides that pair's fate), in that
      order;
    * the prompts — the catalogue prompt for items and categories, the
      sets prompt for labels and values (`endpoint_and_prompts/0`, shared
      with `Web.TranslationsLive`'s manual actions);
    * the settings (`PhoenixKitCatalogue.Web.Settings`):
      `catalogue_translation_sweep_enabled` (off by default),
      `…_interval_minutes`, `…_langs`, and `…_max_per_run` — the most
      translation jobs of the catalogue's that may be waiting or running
      at once (the engine's `max_in_flight`; a tick tops up to it rather
      than adding that many again while earlier ones still run).

  `ensure_scheduled_if_enabled/0` seeds the first tick at boot only when
  the sweep is on, so a host that never opts in gets no ticking job;
  turning it on (`Web.Settings.update_sweep_enabled/1`) starts the chain,
  and saving a new interval reschedules it.
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  @behaviour PhoenixKitAI.TranslationSweep

  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitAI.Translations
  alias PhoenixKitAI.TranslationSweep
  alias PhoenixKitCatalogue.AIPrompt
  alias PhoenixKitCatalogue.TranslationStatus
  alias PhoenixKitCatalogue.Web.Settings, as: SweepSettings

  # `TranslationStatus.list/2` type ↔ the `ai_translatables/0` resource_type
  # string `PhoenixKitAI.Translations.enqueue/1` expects — in the order the
  # sweep takes them.
  @resource_types [
    category: "catalogue_category",
    item: "catalogue_item",
    set_label: "catalogue_set_label",
    set_value: "catalogue_set_value"
  ]

  @doc "The `ai_translatables/0` resource_type string for a `TranslationStatus.list/2` type atom."
  @spec resource_type_for(:item | :category | :set_label | :set_value) :: String.t()
  def resource_type_for(type), do: Keyword.fetch!(@resource_types, type)

  # Boot-time bootstrap: a one-shot `Task` that seeds the first tick when
  # the sweep is already on, then exits (`restart: :temporary` — a failed
  # attempt means no chain until the next boot or settings save).
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
  def perform(_job), do: TranslationSweep.perform(__MODULE__)

  @doc "Makes sure one tick is waiting (the worker's uniqueness keeps it to one)."
  @spec ensure_scheduled() :: {:ok, Oban.Job.t()} | {:error, term()}
  def ensure_scheduled, do: TranslationSweep.ensure_scheduled(__MODULE__)

  @doc "`ensure_scheduled/0` only when the sweep is on — the boot-time seed."
  @spec ensure_scheduled_if_enabled() :: {:ok, Oban.Job.t()} | {:error, term()} | :skipped
  def ensure_scheduled_if_enabled do
    if SweepSettings.sweep_enabled?(), do: ensure_scheduled(), else: :skipped
  end

  @doc "Moves the waiting tick to the current interval, or starts one (after a settings save)."
  @spec reschedule() :: {:ok, Oban.Job.t()} | {:error, term()}
  def reschedule, do: TranslationSweep.reschedule(__MODULE__)

  @doc "An operator's run now — every gate but the automatic-sweep switch."
  @spec run_manual_tick() :: {atom(), map()}
  def run_manual_tick, do: TranslationSweep.run_tick(__MODULE__, :manual)

  @doc "The last tick's outcome, the waiting tick and whether one is running."
  @spec status() :: map()
  def status, do: TranslationSweep.status(__MODULE__)

  # ── PhoenixKitAI.TranslationSweep ────────────────────────────────

  @impl TranslationSweep
  def sweep_key, do: "catalogue"

  @impl TranslationSweep
  def sweep_settings do
    %{
      enabled?: SweepSettings.sweep_enabled?(),
      interval_minutes: SweepSettings.sweep_interval_minutes(),
      languages: SweepSettings.sweep_langs(),
      max_in_flight: SweepSettings.sweep_max_per_run(),
      source_language: Multilang.primary_language()
    }
  end

  @impl TranslationSweep
  def sweep_resource_types, do: Keyword.values(@resource_types)

  # Every (resource, language) row `:missing` or `:stale`, grouped into
  # one candidate per resource with its languages, types in `@resource_types`
  # order and each type's rows in `TranslationStatus`'s own order.
  @impl TranslationSweep
  def sweep_candidates(_source_lang, target_langs) do
    Enum.flat_map(@resource_types, fn {type, resource_type} ->
      type
      |> TranslationStatus.list(
        langs: target_langs,
        state: [:missing, :stale],
        per_page: :all
      )
      |> group_by_resource(resource_type)
    end)
  end

  defp group_by_resource(rows, resource_type) do
    {order, langs} =
      Enum.reduce(rows, {[], %{}}, fn %{uuid: uuid, lang: lang}, {order, langs} ->
        if Map.has_key?(langs, uuid),
          do: {order, Map.update!(langs, uuid, &[lang | &1])},
          else: {[uuid | order], Map.put(langs, uuid, [lang])}
      end)

    for uuid <- Enum.reverse(order) do
      %{resource_type: resource_type, uuid: uuid, languages: Enum.reverse(langs[uuid])}
    end
  end

  @impl TranslationSweep
  def sweep_prompts do
    case endpoint_and_prompts() do
      {:ok, _endpoint_uuid, prompts} -> {:ok, prompts}
      :unavailable -> {:error, :unavailable}
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
