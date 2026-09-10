defmodule PhoenixKitCatalogue.Web.TranslationsLive do
  @moduledoc """
  Admin page for catalogue AI-translation freshness (block-6 plan, Task 5):
  `/admin/catalogue/translations`.

  Lists (resource, target language) rows across the four catalogue
  translatable types (`item` / `category` / `set_label` / `set_value`),
  filterable by type, language, freshness state and a name search, with a
  per-state count in the header. Row actions enqueue a single translation
  (`Translate`) or record the current source as the reference without
  calling the AI (`Stamp fresh`, `TranslationStatus.stamp_fresh/2`); bulk
  actions do the same across every row matching the current type/language/
  search scope for one target state ("Translate all missing" /
  "Retranslate all stale").

  Only rendered when `PhoenixKitAI` is configured with a working endpoint —
  otherwise a notice points at the AI admin section. Availability and the
  endpoint/prompt resolution are the SAME check the sweep tick makes
  (`TranslationSweepWorker.endpoint_and_prompts/0`), so a manual click here
  and an automatic sweep enqueue can never disagree about which endpoint
  or prompt a resource type uses.

  ## In-flight tracking

  `PhoenixKitAI.Translations.job_in_flight?/1` (the private check `enqueue/1`
  itself uses for dedup) isn't part of the module's public API, so rather
  than re-querying `oban_jobs` directly this page tracks in-flight rows the
  same way `phoenix_kit_ai`'s own single-resource `AITranslate` component
  does: an `enqueue/1` call's `conflict?`/`:ok` result marks a row, and the
  global `{:ai_translation, event, payload}` broadcast
  (`Translations.subscribe/0`) clears it again on completion/failure — no
  private function, no direct DB query.

  ## Gettext

  Uses the local `gettext/1,2` macros (`use Gettext, backend:
  PhoenixKitCatalogue.Gettext`), not the qualified `Gettext.gettext(Backend,
  ...)` runtime call some older catalogue modules still carry — the
  qualified form is a plain function call the extractor never sees (see
  commit "Fix strings the gettext extractor cannot see").
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitCatalogue.Gettext

  use PhoenixKitWeb.Live.UrlState,
    params: [
      type: [default: "all", url_key: "type", in: ~w(all item category set_label set_value)],
      lang: [default: "all", url_key: "lang"],
      translation_state: [
        default: "all",
        url_key: "state",
        in: ~w(all missing stale unknown fresh)
      ],
      search: [default: "", url_key: "q"]
    ]

  require Logger

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Select, only: [select: 1]
  import PhoenixKitWeb.Components.Core.TableDefault

  alias PhoenixKit.Utils.Multilang
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitAI.Translations
  alias PhoenixKitCatalogue.AITranslatable
  alias PhoenixKitCatalogue.AITranslatable.Sets
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.TranslationStatus
  alias PhoenixKitCatalogue.Web.Helpers
  alias PhoenixKitCatalogue.Web.Settings, as: SweepSettings
  alias PhoenixKitCatalogue.Web.TableQuery
  alias PhoenixKitCatalogue.Workers.TranslationSweepWorker

  # Upper bound on how many (resource, lang) rows ONE TYPE contributes to
  # one filter scope (each type is listed separately in `load_rows/2` and
  # `bulk_enqueue/2` — this is a per-type cap, not a combined one). Sized
  # above item_count × target_language_count for this fork's actual
  # catalogue (665 items × 2 languages = 1330; the old 1000 silently
  # dropped 330 item rows from both the table AND the header counts,
  # since both are derived from the same capped list). Still a fixed
  # bound, not real pagination — there is no pager in this first cut (not
  # asked for by the block-6 plan's Task 5 interfaces); revisit with one
  # if the catalogue grows another order of magnitude.
  @per_page 5000

  @all_types [:item, :category, :set_label, :set_value]
  @all_states ~w(missing stale unknown fresh)

  # PhoenixKit auto-applies its admin chrome layout to external module admin
  # views via socket.private[:live_layout]. Opt out here so this view can
  # self-wrap with LayoutWrapper.app_layout and push its title/subtitle into
  # the global admin header (same pattern as every other catalogue admin page).
  on_mount({__MODULE__, :self_wrapped_layout})

  def on_mount(:self_wrapped_layout, _params, _session, socket) do
    {:cont, put_in(socket.private[:live_layout], {PhoenixKitWeb.Layouts, :app})}
  end

  @impl true
  def mount(_params, _session, socket) do
    # `endpoint_and_prompts/0` can WRITE (`AIPrompt.ensure_prompt/0` and
    # `ensure_sets_prompt/0` upsert a default prompt on first use), and
    # `mount/3` runs on both the disconnected HTTP render and the WebSocket
    # connect — calling it unconditionally would double-fire that write on
    # every page visit. Deferring to the connected mount (matching
    # `Helpers.maybe_preselect_catalogue_prompt/2`'s guard) means the dead
    # render just shows the "unavailable" notice until the socket connects
    # and re-mounts with the real state.
    socket =
      if connected?(socket) do
        case TranslationSweepWorker.endpoint_and_prompts() do
          {:ok, endpoint_uuid, prompts} ->
            Translations.subscribe()

            assign(socket,
              ai_available: true,
              endpoint_uuid: endpoint_uuid,
              prompts: prompts,
              languages: default_languages(),
              in_flight: MapSet.new(),
              refresh_scheduled?: false,
              rows: [],
              counts: %{},
              total: 0
            )

          :unavailable ->
            assign(socket, ai_available: false)
        end
      else
        assign(socket, ai_available: false)
      end

    {:ok, assign(socket, :page_title, gettext("Translations"))}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_url_state(state, socket) do
    if socket.assigns[:ai_available], do: load_rows(socket, state), else: socket
  end

  # ── Filter form ────────────────────────────────────────────────────

  @impl true
  def handle_event("filter", params, socket) do
    filter = Map.get(params, "filter", %{})

    {:noreply,
     push_url_state(
       socket,
       [
         type: Map.get(filter, "type", socket.assigns.type),
         lang: Map.get(filter, "lang", socket.assigns.lang),
         search: Map.get(filter, "search", socket.assigns.search)
       ],
       replace: true
     )}
  end

  @impl true
  def handle_event("filter_state", %{"state" => s}, socket) do
    {:noreply, push_url_state(socket, translation_state: s)}
  end

  # ── Row actions ──────────────────────────────────────────────────────

  @impl true
  def handle_event("translate", %{"type" => type_str, "uuid" => uuid, "lang" => lang}, socket) do
    case row_type(type_str) do
      {:ok, type} -> {:noreply, enqueue_one(socket, type, uuid, lang)}
      :error -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event(
        "stamp_fresh",
        %{"type" => type_str, "uuid" => uuid, "lang" => lang},
        socket
      ) do
    socket =
      with {:ok, type} <- row_type(type_str),
           {:ok, resource} <- fetch_resource(type, uuid),
           {:ok, _updated} <- TranslationStatus.stamp_fresh(resource, lang) do
        socket
        |> put_flash(:info, gettext("Marked the current source as the translation baseline."))
        |> refresh_rows()
      else
        :error ->
          socket

        {:error, :no_translation} ->
          put_flash(
            socket,
            :error,
            gettext("This row has no translation yet — nothing to stamp.")
          )

        {:error, reason} ->
          Logger.warning("TranslationsLive: stamp_fresh failed: #{inspect(reason)}")
          put_flash(socket, :error, gettext("Could not update the translation baseline."))
      end

    {:noreply, socket}
  end

  # ── Bulk actions ─────────────────────────────────────────────────────

  @impl true
  def handle_event("bulk_translate_missing", _params, socket) do
    {:noreply, bulk_enqueue(socket, :missing)}
  end

  @impl true
  def handle_event("bulk_retranslate_stale", _params, socket) do
    {:noreply, bulk_enqueue(socket, :stale)}
  end

  # ── PubSub (in-flight tracking) ──────────────────────────────────────
  #
  # `Translations.subscribe/0` (mount/3) is the GLOBAL `:ai_translation`
  # topic — every module's translation jobs land here, not just
  # catalogue's — and a bulk run enqueues hundreds of jobs in a burst.
  # Two guards keep that from recomputing the whole listing (full
  # `list_items/0`, one `list_values/1` per set, a sha256 per resource
  # per language) on every single message:
  #
  #   1. Only a catalogue resource type triggers a refresh at all —
  #      another module's translation completing is irrelevant here.
  #   2. Refreshes COALESCE: the first qualifying message in a quiet
  #      period schedules one `:coalesced_refresh` after
  #      `@refresh_debounce_ms`; every message that arrives before it
  #      fires just updates `:in_flight` (cheap) and folds into that
  #      same pending refresh instead of running its own.

  @refresh_debounce_ms 250
  @catalogue_resource_types ~w(catalogue_item catalogue_category catalogue_set_label catalogue_set_value)

  @impl true
  def handle_info({:ai_translation, :translation_started, payload}, socket) do
    {:noreply, track_in_flight(socket, payload, true)}
  end

  def handle_info({:ai_translation, event, payload}, socket)
      when event in [:translation_completed, :translation_failed] do
    socket = track_in_flight(socket, payload, false)

    socket =
      if catalogue_payload?(payload), do: schedule_coalesced_refresh(socket), else: socket

    {:noreply, socket}
  end

  def handle_info(:coalesced_refresh, socket) do
    {:noreply, socket |> assign(:refresh_scheduled?, false) |> refresh_rows()}
  end

  def handle_info(msg, socket) do
    Logger.debug("TranslationsLive ignored unhandled message: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp catalogue_payload?(%{resource_type: type}), do: type in @catalogue_resource_types
  defp catalogue_payload?(_payload), do: false

  defp schedule_coalesced_refresh(socket) do
    if socket.assigns[:refresh_scheduled?] do
      socket
    else
      Process.send_after(self(), :coalesced_refresh, @refresh_debounce_ms)
      assign(socket, :refresh_scheduled?, true)
    end
  end

  # ── Data loading ─────────────────────────────────────────────────────

  defp load_rows(socket, state) do
    langs = target_langs(state.lang)
    types = target_types(state.type)

    all_rows =
      types
      |> Enum.flat_map(&TranslationStatus.list(&1, langs: langs, per_page: @per_page))
      |> TableQuery.search(state.search, & &1.name)
      |> Enum.sort_by(&{&1.name, &1.lang})

    assign(socket,
      rows: filter_by_state(all_rows, state.translation_state),
      counts: Enum.frequencies_by(all_rows, & &1.state),
      total: length(all_rows)
    )
  end

  defp refresh_rows(socket) do
    load_rows(socket, %{
      type: socket.assigns.type,
      lang: socket.assigns.lang,
      translation_state: socket.assigns.translation_state,
      search: socket.assigns.search
    })
  end

  defp target_types("all"), do: @all_types
  defp target_types(type), do: [String.to_existing_atom(type)]

  defp target_langs("all"), do: default_languages()
  defp target_langs(lang), do: [lang]

  defp default_languages, do: Multilang.enabled_languages() -- [Multilang.primary_language()]

  defp filter_by_state(rows, "all"), do: rows
  defp filter_by_state(rows, s), do: Enum.filter(rows, &(Atom.to_string(&1.state) == s))

  # ── Row/bulk enqueue ─────────────────────────────────────────────────

  defp enqueue_one(socket, type, uuid, lang) do
    resource_type = TranslationSweepWorker.resource_type_for(type)

    params = %{
      resource_type: resource_type,
      resource_uuid: uuid,
      endpoint_uuid: socket.assigns.endpoint_uuid,
      prompt_uuid: Map.fetch!(socket.assigns.prompts, resource_type),
      source_lang: Multilang.primary_language(),
      target_lang: lang,
      actor_uuid: Helpers.actor_uuid(socket)
    }

    case Translations.enqueue(params) do
      {:ok, %{conflict?: true}} ->
        socket
        |> track_key({resource_type, uuid, lang}, true)
        |> put_flash(:info, gettext("A translation job for this row is already queued."))

      {:ok, %{conflict?: false}} ->
        socket
        |> track_key({resource_type, uuid, lang}, true)
        |> put_flash(:info, gettext("Translation queued."))

      {:error, reason} ->
        Logger.warning("TranslationsLive: enqueue failed: #{inspect(reason)}")
        put_flash(socket, :error, gettext("Could not queue the translation."))
    end
  end

  defp bulk_enqueue(socket, target_state) do
    langs = target_langs(socket.assigns.lang)
    types = target_types(socket.assigns.type)

    matched =
      types
      |> Enum.flat_map(
        &TranslationStatus.list(&1, langs: langs, state: target_state, per_page: @per_page)
      )
      |> TableQuery.search(socket.assigns.search, & &1.name)

    # Caps how many rows one click enqueues SYNCHRONOUSLY in this LiveView
    # process (each row does a dedup query + an Oban insert) — reuses the
    # sweep's own per-tick cap rather than inventing a second knob; a
    # filter matching more than that gets queued a batch at a time, one
    # click per batch, same as the sweep already self-throttles per tick.
    cap = SweepSettings.sweep_max_per_run()
    rows = Enum.take(matched, cap)
    truncated? = length(matched) > cap

    {socket, enqueued, errors} =
      Enum.reduce(rows, {socket, 0, 0}, fn row, {sock, ok, err} ->
        case do_bulk_enqueue(sock, row) do
          {:ok, sock} -> {sock, ok + 1, err}
          {:error, sock} -> {sock, ok, err + 1}
        end
      end)

    socket
    |> flash_bulk_result(enqueued, errors, truncated?)
    |> refresh_rows()
  end

  defp do_bulk_enqueue(socket, row) do
    resource_type = TranslationSweepWorker.resource_type_for(row.type)

    params = %{
      resource_type: resource_type,
      resource_uuid: row.uuid,
      endpoint_uuid: socket.assigns.endpoint_uuid,
      prompt_uuid: Map.fetch!(socket.assigns.prompts, resource_type),
      source_lang: Multilang.primary_language(),
      target_lang: row.lang,
      actor_uuid: Helpers.actor_uuid(socket)
    }

    case Translations.enqueue(params) do
      {:ok, _} -> {:ok, track_key(socket, {resource_type, row.uuid, row.lang}, true)}
      {:error, _reason} -> {:error, socket}
    end
  end

  defp flash_bulk_result(socket, 0, 0, _truncated?) do
    put_flash(socket, :info, gettext("Nothing matched the current filter."))
  end

  defp flash_bulk_result(socket, enqueued, 0, truncated?) do
    message =
      ngettext(
        "Queued %{count} translation.",
        "Queued %{count} translations.",
        enqueued,
        count: enqueued
      )

    put_flash(socket, :info, append_truncated_notice(message, truncated?))
  end

  defp flash_bulk_result(socket, enqueued, errors, truncated?) do
    message =
      gettext("Queued %{ok}; %{failed} could not be queued.", ok: enqueued, failed: errors)

    put_flash(socket, :warning, append_truncated_notice(message, truncated?))
  end

  # More rows matched than the sweep's per-tick cap allows one bulk click
  # to enqueue synchronously — tell the operator the filter still has
  # more to queue, rather than letting "Queued N" read as "that was all
  # of them".
  defp append_truncated_notice(message, false), do: message

  defp append_truncated_notice(message, true) do
    message <> " " <> gettext("More rows match — click again to queue the next batch.")
  end

  defp fetch_resource(:item, uuid), do: AITranslatable.fetch("catalogue_item", uuid)
  defp fetch_resource(:category, uuid), do: AITranslatable.fetch("catalogue_category", uuid)
  defp fetch_resource(:set_label, uuid), do: Sets.fetch("catalogue_set_label", uuid)
  defp fetch_resource(:set_value, uuid), do: Sets.fetch("catalogue_set_value", uuid)

  # Client-supplied `phx-value-type` — a crafted event must not reach
  # `String.to_existing_atom/1` (ArgumentError on an unrecognized string)
  # or `resource_type_for/1`'s `Map.fetch!` (KeyError), either of which
  # would kill the LiveView.
  defp row_type("item"), do: {:ok, :item}
  defp row_type("category"), do: {:ok, :category}
  defp row_type("set_label"), do: {:ok, :set_label}
  defp row_type("set_value"), do: {:ok, :set_value}
  defp row_type(_other), do: :error

  # ── In-flight tracking ───────────────────────────────────────────────

  defp track_in_flight(socket, %{resource_type: t, resource_uuid: u, target_lang: l}, add?),
    do: track_key(socket, {t, u, l}, add?)

  defp track_in_flight(socket, _payload, _add?), do: socket

  defp track_key(socket, key, true),
    do: assign(socket, :in_flight, MapSet.put(socket.assigns.in_flight, key))

  defp track_key(socket, key, false),
    do: assign(socket, :in_flight, MapSet.delete(socket.assigns.in_flight, key))

  defp in_flight?(in_flight, row) do
    resource_type = TranslationSweepWorker.resource_type_for(row.type)
    MapSet.member?(in_flight, {resource_type, row.uuid, row.lang})
  end

  # ── Labels ───────────────────────────────────────────────────────────

  defp all_states, do: @all_states

  defp type_label(:item), do: gettext("Item")
  defp type_label(:category), do: gettext("Category")
  defp type_label(:set_label), do: gettext("Set label")
  defp type_label(:set_value), do: gettext("Set value")

  defp type_options do
    [
      {gettext("All types"), "all"},
      {type_label(:item), "item"},
      {type_label(:category), "category"},
      {type_label(:set_label), "set_label"},
      {type_label(:set_value), "set_value"}
    ]
  end

  defp state_label("missing"), do: gettext("Missing")
  defp state_label("stale"), do: gettext("Stale")
  defp state_label("unknown"), do: gettext("Unknown")
  defp state_label("fresh"), do: gettext("Fresh")
  defp state_label("all"), do: gettext("All")

  defp state_badge_class(:missing), do: "badge-ghost"
  defp state_badge_class(:stale), do: "badge-warning"
  defp state_badge_class(:unknown), do: "badge-info"
  defp state_badge_class(:fresh), do: "badge-success"

  defp state_chip_class(current, current), do: "btn btn-xs btn-primary"
  defp state_chip_class(_current, _value), do: "btn btn-xs btn-ghost"

  defp bulk_confirm(counts, state) do
    gettext("Queue translation for %{count} row(s)?", count: Map.get(counts, state, 0))
  end

  # ── Render ───────────────────────────────────────────────────────────

  @impl true
  def render(%{ai_available: false} = assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={@page_title}
      page_subtitle={gettext("Catalogue")}
      current_path={assigns[:url_path] || Paths.translations()}
      current_locale={assigns[:current_locale]}
    >
      <div class="flex flex-col items-center justify-center py-24 px-4 text-center gap-3">
        <.icon name="hero-language" class="w-12 h-12 opacity-40" />
        <h2 class="text-lg font-medium">{gettext("AI translation is not configured")}</h2>
        <p class="text-base-content/60 max-w-md">
          {gettext("Set up an AI endpoint before translating catalogue content.")}
        </p>
        <.link navigate={Routes.path("/admin/ai/endpoints")} class="btn btn-primary btn-sm">
          {gettext("Configure AI")}
        </.link>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={@page_title}
      page_subtitle={gettext("Catalogue") <> " · " <> gettext("%{count} rows", count: @total)}
      current_path={assigns[:url_path] || Paths.translations()}
      current_locale={assigns[:current_locale]}
    >
      <div class="flex flex-col w-full px-4 py-6 gap-4">
        <%!-- Per-state counts --%>
        <div class="flex flex-wrap gap-2" id="translations-state-counts">
          <button
            type="button"
            phx-click="filter_state"
            phx-value-state="all"
            class={state_chip_class(@translation_state, "all")}
          >
            {state_label("all")}: {@total}
          </button>
          <button
            :for={s <- all_states()}
            type="button"
            phx-click="filter_state"
            phx-value-state={s}
            class={state_chip_class(@translation_state, s)}
          >
            {state_label(s)}: {Map.get(@counts, String.to_existing_atom(s), 0)}
          </button>
        </div>

        <%!-- Filters --%>
        <div class="bg-base-200 rounded-lg p-3">
          <.form
            for={%{}}
            id="translations-filter"
            phx-change="filter"
            class="flex flex-wrap gap-3 items-end"
          >
            <div class="fieldset">
              <.select
                name="filter[type]"
                id="translations-filter-type"
                label={gettext("Type")}
                value={@type}
                options={type_options()}
                class="select-sm"
              />
            </div>

            <div class="fieldset">
              <.select
                name="filter[lang]"
                id="translations-filter-lang"
                label={gettext("Language")}
                value={@lang}
                prompt={gettext("All languages")}
                options={Enum.map(@languages, &{&1, &1})}
                class="select-sm"
              />
            </div>

            <div class="fieldset grow basis-64">
              <label class="input input-sm w-full">
                <.icon name="hero-magnifying-glass" class="h-4 w-4 opacity-50" />
                <input
                  type="text"
                  name="filter[search]"
                  value={@search}
                  placeholder={gettext("Search by name…")}
                  phx-debounce="300"
                  class="grow"
                />
              </label>
            </div>
          </.form>
        </div>

        <%!-- Bulk actions --%>
        <div class="flex flex-wrap gap-2">
          <button
            type="button"
            phx-click="bulk_translate_missing"
            data-confirm={bulk_confirm(@counts, :missing)}
            class="btn btn-sm btn-outline"
            disabled={Map.get(@counts, :missing, 0) == 0}
          >
            {gettext("Translate all missing")}
          </button>
          <button
            type="button"
            phx-click="bulk_retranslate_stale"
            data-confirm={bulk_confirm(@counts, :stale)}
            class="btn btn-sm btn-outline"
            disabled={Map.get(@counts, :stale, 0) == 0}
          >
            {gettext("Retranslate all stale")}
          </button>
        </div>

        <%!-- Table --%>
        <%= if @rows == [] do %>
          <div class="text-center py-12 text-base-content/60">
            <.icon name="hero-language" class="w-12 h-12 mx-auto mb-2 opacity-50" />
            <p>{gettext("No rows match the current filter.")}</p>
          </div>
        <% else %>
          <.table_default id="translations-table" size="sm">
            <.table_default_header>
              <.table_default_row>
                <.table_default_header_cell>{gettext("Resource")}</.table_default_header_cell>
                <.table_default_header_cell>{gettext("Type")}</.table_default_header_cell>
                <.table_default_header_cell>{gettext("Language")}</.table_default_header_cell>
                <.table_default_header_cell>{gettext("State")}</.table_default_header_cell>
                <.table_default_header_cell class="text-right">
                  {gettext("Actions")}
                </.table_default_header_cell>
              </.table_default_row>
            </.table_default_header>
            <.table_default_body>
              <.table_default_row
                :for={row <- @rows}
                id={"translation-row-#{row.type}-#{row.uuid}-#{row.lang}"}
              >
                <.table_default_cell class="font-medium">{row.name}</.table_default_cell>
                <.table_default_cell>{type_label(row.type)}</.table_default_cell>
                <.table_default_cell>{row.lang}</.table_default_cell>
                <.table_default_cell>
                  <span class={"badge badge-sm #{state_badge_class(row.state)}"}>
                    {state_label(Atom.to_string(row.state))}
                  </span>
                  <span :if={in_flight?(@in_flight, row)} class="badge badge-sm badge-outline ml-1">
                    {gettext("queued")}
                  </span>
                </.table_default_cell>
                <.table_default_cell class="text-right">
                  <button
                    type="button"
                    phx-click="translate"
                    phx-value-type={row.type}
                    phx-value-uuid={row.uuid}
                    phx-value-lang={row.lang}
                    class="btn btn-ghost btn-xs"
                    disabled={in_flight?(@in_flight, row)}
                  >
                    {gettext("Translate")}
                  </button>
                  <button
                    type="button"
                    phx-click="stamp_fresh"
                    phx-value-type={row.type}
                    phx-value-uuid={row.uuid}
                    phx-value-lang={row.lang}
                    class="btn btn-ghost btn-xs"
                    disabled={row.state == :missing}
                  >
                    {gettext("Stamp fresh")}
                  </button>
                </.table_default_cell>
              </.table_default_row>
            </.table_default_body>
          </.table_default>
        <% end %>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
