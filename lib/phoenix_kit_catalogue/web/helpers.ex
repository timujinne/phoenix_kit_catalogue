defmodule PhoenixKitCatalogue.Web.Helpers do
  @moduledoc """
  Tiny utilities shared by every catalogue LiveView. Imported into LVs
  via the standard `import PhoenixKitCatalogue.Web.Helpers` line.

  Currently exports:

    * `actor_opts/1` — extract the current user's UUID from socket
      assigns, return `[actor_uuid: uuid]` for the `opts \\\\ []` keyword
      list every mutating context function accepts. Returns `[]` when
      no user is signed in (e.g. inside a test that mounts the LV with
      a bare conn). The atom is suitable to thread through
      `Catalogue.create_*` / `update_*` / `trash_*` / `restore_*` /
      `permanently_delete_*` etc.
    * `actor_uuid/1` — the raw UUID (or `nil`). Use when you need the
      value directly rather than a keyword list, e.g. when building
      activity-log metadata in a LiveView.
    * `log_operation_error/3` — engineer-visible `Logger.error` for a
      failed mutation **plus** an Activity row tagged
      `db_pending: true` so the user-visible audit feed records the
      attempted action even when it fails. The function's own docs
      describe the success-vs-failure layering in detail.
  """

  require Logger

  alias PhoenixKit.Modules.AI.Translations
  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitCatalogue.Catalogue.ActivityLog

  # How long the translation progress may **stall** — no language completing
  # — before the form shows the "taking a while, runs in the background"
  # hint. It's about the bar hanging, not any single language's duration: a
  # lang taking 2s is fine; the bar sitting still for this long is not. Each
  # completion resets the clock. Overridable per host via app config; the
  # default is a sensible 5s.
  @default_ai_stall_ms 5_000

  defp ai_stall_ms do
    Application.get_env(:phoenix_kit_catalogue, :ai_translation_stall_ms, @default_ai_stall_ms)
  end

  @typedoc "Convenience alias for the keyword list shape mutating ctx fns accept."
  @type actor_opts :: [actor_uuid: Ecto.UUID.t()] | []

  @doc """
  Extracts `[actor_uuid: uuid]` from `socket.assigns.phoenix_kit_current_user`.

  Returns `[]` when no user is signed in. Pass the result straight into
  any `PhoenixKitCatalogue.Catalogue` mutating function as its trailing
  `opts` argument.
  """
  @spec actor_opts(Phoenix.LiveView.Socket.t()) :: actor_opts()
  def actor_opts(socket) do
    case actor_uuid(socket) do
      nil -> []
      uuid -> [actor_uuid: uuid]
    end
  end

  @doc """
  Returns the current user's UUID from socket assigns, or `nil`.
  """
  @spec actor_uuid(Phoenix.LiveView.Socket.t()) :: Ecto.UUID.t() | nil
  def actor_uuid(socket) do
    case socket.assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} -> uuid
      _ -> nil
    end
  end

  @doc """
  Translates a catalogue/category/item/manufacturer/supplier `status`
  field value to a localised label via gettext.

  Handles every status string that any catalogue schema can emit
  (`active` / `inactive` / `archived` / `deleted` / `discontinued`)
  with explicit literal `gettext(...)` clauses so `mix gettext.extract`
  picks them up. Unknown status values pass through unchanged — never
  use `String.capitalize/1` on translated text because the result
  would pin English casing on a value the extractor can't see.
  """
  @spec status_label(String.t() | nil) :: String.t()
  def status_label("active"), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Active")
  def status_label("inactive"), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Inactive")
  def status_label("archived"), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Archived")
  def status_label("deleted"), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Deleted")

  def status_label("discontinued"),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Discontinued")

  def status_label(other) when is_binary(other), do: other
  def status_label(_), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Unknown")

  @doc """
  Logs a failed LV mutation in two places at once:

  1. **Engineer log** — `Logger.error` with the operation, the
     LV-level entity context, and the changeset / atom reason. This
     is the rich-context line that production-incident triage reads.
  2. **User-visible audit row** — an Activity entry with the same
     action atom the success path would have written, plus
     `metadata.db_pending: true`. The audit feed therefore records
     **what the user attempted**, not just **what succeeded** — a
     deliberate change in the post-Apr 2026 pipeline (workspace
     `AGENTS.md` C12 agent #2 — "Activity logging coverage").

  The action atom is derived from `operation` via
  `derive_activity_action/2`. Validation cycles (form-validate
  events) never reach this helper — by construction it's only called
  from `{:error, _}` handle_event branches, where the failure is a
  real infrastructure / consistency error worth auditing.

  ## Expected `context` keys

    * `:entity_type` — `"item"` / `"category"` / `"catalogue"` /
      `"manufacturer"` / `"supplier"` (drives both the activity
      `resource_type` and the action-atom prefix).
    * `:entity_uuid` — primary-key UUID; lands as `resource_uuid`.
    * `:reason` — an `%Ecto.Changeset{}`, an atom, or any other
      `inspect`able shape. Logged engineer-side; on the audit row
      it's summarised into PII-safe `metadata.error_keys` (changeset
      field names only — never values, since user-typed strings can
      carry PII).

  Activity-log failures (missing table, ownership errors, sandbox
  exit) are swallowed by `ActivityLog.log/1`; they never bubble up
  to the LV.
  """
  @spec log_operation_error(Phoenix.LiveView.Socket.t(), String.t(), map()) :: :ok
  def log_operation_error(socket, operation, context) do
    actor = actor_uuid(socket)
    ctx = Map.put_new(context, :actor_uuid, actor)

    Logger.error(fn ->
      [
        catalogue_lv_label(socket),
        " ",
        operation,
        " failed: ",
        format_error_context(ctx)
      ]
    end)

    entity_type = Map.get(context, :entity_type)
    entity_uuid = Map.get(context, :entity_uuid)
    reason = Map.get(context, :reason)

    case derive_activity_action(operation, entity_type) do
      nil ->
        :ok

      action ->
        ActivityLog.log(%{
          action: action,
          mode: "manual",
          actor_uuid: actor,
          resource_type: entity_type,
          resource_uuid: entity_uuid,
          metadata: build_failure_metadata(reason)
        })
    end
  end

  @doc """
  Maps an LV operation string + entity_type to the canonical activity
  action atom the catalogue context already uses on the success path.

  Falls back to `nil` when the operation doesn't follow the
  `<verb>_<entity>` shape; the caller skips the audit-row write in
  that case (engineer log still fires).
  """
  @spec derive_activity_action(String.t(), String.t() | nil) :: String.t() | nil
  def derive_activity_action(operation, entity_type)
      when is_binary(operation) and is_binary(entity_type) do
    case verb_for(operation) do
      nil -> nil
      past -> "#{entity_type}.#{past}"
    end
  end

  def derive_activity_action(_, _), do: nil

  # Operation prefix → past-tense action verb. Order matters:
  # `permanently_delete_` must be checked before `delete_`.
  @verb_map [
    {"permanently_delete_", "permanently_deleted"},
    {"trash_", "trashed"},
    {"restore_", "restored"},
    {"delete_", "deleted"}
  ]

  defp verb_for(operation) do
    Enum.find_value(@verb_map, fn {prefix, past} ->
      if String.starts_with?(operation, prefix), do: past
    end)
  end

  # ── Private ──────────────────────────────────────────────────────

  defp catalogue_lv_label(%Phoenix.LiveView.Socket{view: view}) when is_atom(view) do
    view |> Module.split() |> List.last() |> to_string()
  end

  defp format_error_context(%{reason: reason} = ctx) do
    rest = Map.delete(ctx, :reason)

    [
      inspect(rest, limit: :infinity),
      " reason=",
      format_reason(reason)
    ]
  end

  defp format_reason(%Ecto.Changeset{} = cs) do
    errors =
      Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {k, v}, acc ->
          String.replace(acc, "%{#{k}}", to_string(v))
        end)
      end)

    "changeset_errors=#{inspect(errors)}"
  end

  defp format_reason(other), do: inspect(other)

  # PII-safe metadata: only field names from a changeset, not values
  # (user-typed strings can carry PII). For non-changeset reasons,
  # store the atom or a `:other` marker.
  defp build_failure_metadata(%Ecto.Changeset{} = cs) do
    %{
      "db_pending" => true,
      "error_kind" => "changeset",
      "error_keys" => cs.errors |> Enum.map(fn {k, _} -> Atom.to_string(k) end) |> Enum.uniq()
    }
  end

  defp build_failure_metadata(reason) when is_atom(reason) do
    %{"db_pending" => true, "error_kind" => "atom", "reason" => Atom.to_string(reason)}
  end

  defp build_failure_metadata(_other) do
    %{"db_pending" => true, "error_kind" => "other"}
  end

  # ── AI translation (shared by the three form LVs) ───────────────────
  # Thin glue over core's `PhoenixKit.Modules.AI.Translations`. Each form
  # calls `assign_ai_translation/3` in mount, delegates its
  # `ai_translate_missing` event to `dispatch_ai_translation/1`, and routes
  # `{:ai_translation, _, _}` messages through `handle_ai_translation_event/4`.

  @doc """
  Assigns the AI-translation form state and (on a connected, edit-mode
  mount) subscribes to the resource's core translation topic.

  Pass the resource struct on `:edit`; pass `nil` on `:new` (AI translate
  is disabled until the row exists). `resource_type` is the globally-unique
  key registered via `ai_translatables/0` (e.g. `"catalogue_item"`).
  """
  @spec assign_ai_translation(Phoenix.LiveView.Socket.t(), String.t(), struct() | nil) ::
          Phoenix.LiveView.Socket.t()
  def assign_ai_translation(socket, resource_type, %{uuid: uuid} = _resource)
      when is_binary(resource_type) do
    available? = Translations.available?()

    if available? and Phoenix.LiveView.connected?(socket) do
      Translations.subscribe(resource_type, uuid)
    end

    socket =
      Phoenix.Component.assign(socket,
        ai_resource_type: resource_type,
        ai_resource_uuid: uuid,
        ai_translation_available?: available?,
        ai_in_flight: [],
        ai_scope: :missing,
        ai_modal_open: false,
        ai_status: nil,
        ai_progress: 0,
        ai_total: 0,
        ai_slow: false,
        ai_slow_timer_ref: nil,
        ai_slow_token: nil
      )

    # The endpoint/prompt lookups hit Settings + the AI plugin, so only run
    # them on the connected mount (the dead HTTP render doesn't need them and
    # mount/3 fires twice).
    if available? and Phoenix.LiveView.connected?(socket) do
      Phoenix.Component.assign(socket,
        ai_endpoints: Translations.list_endpoints(),
        ai_prompts: Translations.list_prompts(),
        ai_selected_endpoint: Translations.default_endpoint_uuid(),
        ai_selected_prompt: Translations.default_prompt_uuid(),
        ai_default_prompt_exists: Translations.default_prompt_exists?()
      )
    else
      Phoenix.Component.assign(socket,
        ai_endpoints: [],
        ai_prompts: [],
        ai_selected_endpoint: nil,
        ai_selected_prompt: nil,
        ai_default_prompt_exists: false
      )
    end
  end

  def assign_ai_translation(socket, _resource_type, _resource) do
    Phoenix.Component.assign(socket,
      ai_resource_type: nil,
      ai_resource_uuid: nil,
      ai_translation_available?: false,
      ai_in_flight: [],
      ai_scope: :missing,
      ai_modal_open: false,
      ai_status: nil,
      ai_progress: 0,
      ai_total: 0,
      ai_slow: false,
      ai_slow_timer_ref: nil,
      ai_slow_token: nil,
      ai_endpoints: [],
      ai_prompts: [],
      ai_selected_endpoint: nil,
      ai_selected_prompt: nil,
      ai_default_prompt_exists: false
    )
  end

  @doc "Modal open/close toggle."
  def toggle_ai_modal(socket),
    do: Phoenix.Component.assign(socket, :ai_modal_open, not socket.assigns.ai_modal_open)

  @doc "Endpoint dropdown change."
  def select_ai_endpoint(socket, uuid),
    do: Phoenix.Component.assign(socket, :ai_selected_endpoint, blank_to_nil(uuid))

  @doc "Prompt dropdown change."
  def select_ai_prompt(socket, uuid),
    do: Phoenix.Component.assign(socket, :ai_selected_prompt, blank_to_nil(uuid))

  @doc "Scope radio change (`missing` | `all` | `current`)."
  def select_ai_scope(socket, scope) when scope in ~w(missing all current),
    do: Phoenix.Component.assign(socket, :ai_scope, String.to_existing_atom(scope))

  def select_ai_scope(socket, _scope), do: socket

  @doc "Provision the shared default translation prompt and select it."
  def generate_ai_prompt(socket) do
    case Translations.ensure_default_prompt() do
      {:ok, %{uuid: uuid}} ->
        socket
        |> Phoenix.Component.assign(:ai_prompts, Translations.list_prompts())
        |> Phoenix.Component.assign(:ai_default_prompt_exists, true)
        |> Phoenix.Component.assign(:ai_selected_prompt, uuid)
        |> Phoenix.LiveView.put_flash(
          :info,
          Gettext.gettext(PhoenixKitCatalogue.Gettext, "Default translation prompt generated.")
        )

      {:error, _reason} ->
        flash_error(
          socket,
          Gettext.gettext(
            PhoenixKitCatalogue.Gettext,
            "Could not generate the default translation prompt."
          )
        )
    end
  end

  @doc """
  Builds the `ai_translate` config map for `PhoenixKitWeb.Components.AITranslate`
  from the form's assigns, or `nil` when AI translation isn't available
  (component renders nothing). The `missing` list is derived from the live
  changeset, so it reflects unsaved + just-translated state.
  """
  @spec ai_translate_config(map()) :: map() | nil
  def ai_translate_config(assigns) do
    if assigns[:ai_translation_available?] do
      %{
        enabled: true,
        event: "ai_translate_lang",
        toggle_event: "ai_toggle_modal",
        select_endpoint_event: "ai_select_endpoint",
        select_prompt_event: "ai_select_prompt",
        select_scope_event: "ai_select_scope",
        generate_prompt_event: "ai_generate_prompt",
        missing: changeset_missing_langs(assigns.changeset),
        all_langs: all_target_langs(),
        in_flight: assigns.ai_in_flight,
        modal_open: assigns.ai_modal_open,
        endpoints: assigns.ai_endpoints,
        prompts: assigns.ai_prompts,
        selected_endpoint_uuid: assigns.ai_selected_endpoint,
        selected_prompt_uuid: assigns.ai_selected_prompt,
        scope: assigns.ai_scope,
        default_prompt_exists: assigns.ai_default_prompt_exists,
        current_lang: assigns[:current_lang],
        primary_lang: Multilang.primary_language(),
        primary_lang_name: lang_name(assigns[:language_tabs], Multilang.primary_language()),
        translation_status: assigns.ai_status,
        translation_progress: assigns.ai_progress,
        translation_total: assigns.ai_total,
        slow: assigns.ai_slow
      }
    end
  end

  defp lang_name(tabs, code) do
    case Enum.find(tabs || [], &(&1.code == code)) do
      %{name: name} when is_binary(name) -> name
      _ -> nil
    end
  end

  @doc """
  Dispatch a translation from the modal's "Translate" action. `lang` is the
  scope sentinel: `"*"` (missing only), `"**"` (all non-primary, overwrite),
  or a concrete language code (current tab). Closes the modal, grows
  `:ai_in_flight`, advances the progress session, and flashes the outcome.
  """
  @spec dispatch_ai_translate(Phoenix.LiveView.Socket.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def dispatch_ai_translate(socket, lang) do
    socket = Phoenix.Component.assign(socket, :ai_modal_open, false)
    endpoint = socket.assigns.ai_selected_endpoint || Translations.default_endpoint_uuid()
    prompt = socket.assigns.ai_selected_prompt || Translations.default_prompt_uuid()

    cond do
      blank_to_nil(endpoint) == nil ->
        flash_error(
          socket,
          Gettext.gettext(PhoenixKitCatalogue.Gettext, "Select an AI endpoint first.")
        )

      blank_to_nil(prompt) == nil ->
        flash_error(
          socket,
          Gettext.gettext(PhoenixKitCatalogue.Gettext, "Select a translation prompt first.")
        )

      true ->
        do_dispatch_ai(socket, lang, endpoint, prompt)
    end
  end

  # Bulk scopes: "*" (missing) / "**" (all non-primary).
  defp do_dispatch_ai(socket, scope, endpoint, prompt) when scope in ["*", "**"] do
    targets =
      case scope do
        "*" -> changeset_missing_langs(socket.assigns.changeset)
        "**" -> all_target_langs()
      end
      |> Enum.reject(&(&1 in socket.assigns.ai_in_flight))

    base = %{
      resource_type: socket.assigns.ai_resource_type,
      resource_uuid: socket.assigns.ai_resource_uuid,
      endpoint_uuid: endpoint,
      prompt_uuid: prompt,
      source_lang: Multilang.primary_language(),
      actor_uuid: actor_uuid(socket)
    }

    case Translations.enqueue_all_missing(base, targets) do
      {:ok, %{in_flight: [_ | _] = in_flight, errors: errors}} ->
        socket
        |> add_in_flight(in_flight)
        |> bump_started(length(in_flight))
        |> dispatch_flash(in_flight, errors)

      {:ok, %{errors: [_ | _] = errors}} ->
        dispatch_flash(socket, [], errors)

      {:ok, _} ->
        Phoenix.LiveView.put_flash(
          socket,
          :info,
          Gettext.gettext(PhoenixKitCatalogue.Gettext, "Nothing to translate.")
        )

      {:error, _reason} ->
        flash_error(
          socket,
          Gettext.gettext(PhoenixKitCatalogue.Gettext, "Could not start translation.")
        )
    end
  end

  # Single language (current tab).
  # Refuse to translate INTO the source language — the component disables
  # that option, but a stale/crafted event must not target the primary (which
  # is the source, and would also write into the primary subtree).
  defp do_dispatch_ai(socket, lang, _endpoint, _prompt)
       when is_binary(lang) and lang == "" do
    socket
  end

  defp do_dispatch_ai(socket, lang, endpoint, prompt) do
    if lang == Multilang.primary_language() do
      flash_error(
        socket,
        Gettext.gettext(PhoenixKitCatalogue.Gettext, "Can't translate the source language.")
      )
    else
      do_dispatch_single(socket, lang, endpoint, prompt)
    end
  end

  defp do_dispatch_single(socket, lang, endpoint, prompt) do
    params = %{
      resource_type: socket.assigns.ai_resource_type,
      resource_uuid: socket.assigns.ai_resource_uuid,
      endpoint_uuid: endpoint,
      prompt_uuid: prompt,
      source_lang: Multilang.primary_language(),
      target_lang: lang,
      actor_uuid: actor_uuid(socket)
    }

    case Translations.enqueue(params) do
      {:ok, %{conflict?: false}} ->
        socket
        |> add_in_flight([lang])
        |> bump_started(1)
        |> Phoenix.LiveView.put_flash(
          :info,
          Gettext.gettext(PhoenixKitCatalogue.Gettext, "Translating to %{lang}…",
            lang: String.upcase(lang)
          )
        )

      {:ok, %{conflict?: true}} ->
        Phoenix.LiveView.put_flash(
          socket,
          :info,
          Gettext.gettext(PhoenixKitCatalogue.Gettext, "Translation already in progress.")
        )

      {:error, _reason} ->
        flash_error(
          socket,
          Gettext.gettext(PhoenixKitCatalogue.Gettext, "Could not start translation.")
        )
    end
  end

  defp add_in_flight(socket, langs),
    do:
      Phoenix.Component.assign(
        socket,
        :ai_in_flight,
        Enum.uniq(socket.assigns.ai_in_flight ++ langs)
      )

  # Progress session: reset on a fresh start, add to a running total.
  defp bump_started(socket, count) when count > 0 do
    socket = arm_stall_timer(socket)

    case socket.assigns.ai_status do
      s when s in [nil, :completed] ->
        Phoenix.Component.assign(socket,
          ai_status: :in_progress,
          ai_progress: 0,
          ai_total: count,
          ai_slow: false
        )

      :in_progress ->
        Phoenix.Component.assign(socket, :ai_total, socket.assigns.ai_total + count)
    end
  end

  defp bump_started(socket, _zero), do: socket

  # (Re)start the stall clock: cancel any pending timer, schedule a fresh one,
  # and clear the hint. Called at dispatch AND after each completion so the
  # timer only fires when progress has been STALLED (no language completing)
  # for `ai_stall_ms/0`. Reuses the `{:ai_translation, _, _}` tuple so the
  # form's existing handle_info clause routes it — no extra wiring.
  defp arm_stall_timer(socket) do
    socket = cancel_stall_timer(socket)

    # A per-arm token guards against a stale `:slow_tick` that was already
    # delivered to the mailbox before `cancel_stall_timer/1` ran (cancel can't
    # un-send it). The :slow_tick clause ignores any tick whose token isn't
    # the current one, so a tick fired by a now-superseded clock can't flip
    # the hint after progress just advanced.
    token = make_ref()

    ref =
      if Phoenix.LiveView.connected?(socket) do
        Process.send_after(self(), {:ai_translation, :slow_tick, %{token: token}}, ai_stall_ms())
      end

    Phoenix.Component.assign(socket,
      ai_slow_timer_ref: ref,
      ai_slow_token: token,
      ai_slow: false
    )
  end

  defp cancel_stall_timer(socket) do
    case socket.assigns[:ai_slow_timer_ref] do
      ref when is_reference(ref) -> Process.cancel_timer(ref)
      _ -> :ok
    end

    Phoenix.Component.assign(socket, ai_slow_timer_ref: nil, ai_slow_token: nil)
  end

  # Enabled non-primary codes lacking any `_`-prefixed translation in the
  # current changeset data (so it reflects unsaved + just-translated state).
  defp changeset_missing_langs(changeset) do
    data = Ecto.Changeset.get_field(changeset, :data) || %{}

    Translations.missing_languages(
      Multilang.enabled_languages(),
      Multilang.primary_language(),
      existing_translation_langs(data)
    )
  end

  defp all_target_langs do
    primary = Multilang.primary_language()
    Enum.reject(Multilang.enabled_languages(), &(&1 == primary))
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  defp blank_to_nil(v), do: v

  defp dispatch_flash(socket, in_flight, errors) do
    cond do
      in_flight == [] and errors != [] ->
        flash_error(
          socket,
          Gettext.gettext(PhoenixKitCatalogue.Gettext, "Translation could not be started.")
        )

      errors != [] ->
        Phoenix.LiveView.put_flash(
          socket,
          :info,
          Gettext.ngettext(
            PhoenixKitCatalogue.Gettext,
            "Translating %{count} language; some could not start.",
            "Translating %{count} languages; some could not start.",
            length(in_flight)
          )
        )

      true ->
        Phoenix.LiveView.put_flash(
          socket,
          :info,
          Gettext.ngettext(
            PhoenixKitCatalogue.Gettext,
            "Translating %{count} language…",
            "Translating %{count} languages…",
            length(in_flight)
          )
        )
    end
  end

  @doc """
  Fold a `{:ai_translation, event, payload}` message into the form socket.

  `assign_changeset` is the form's own `(socket, changeset) -> socket`
  helper — on `:translation_completed` the translated fields are merged
  into the live changeset's `data` (so the result shows without a DB reload
  and unsaved edits survive). Returns the updated socket.
  """
  @spec handle_ai_translation_event(
          Phoenix.LiveView.Socket.t(),
          atom(),
          map(),
          (Phoenix.LiveView.Socket.t(), Ecto.Changeset.t() -> Phoenix.LiveView.Socket.t())
        ) :: Phoenix.LiveView.Socket.t()
  def handle_ai_translation_event(socket, :translation_started, %{target_lang: lang}, _assign_cs)
      when is_binary(lang) do
    if lang in socket.assigns.ai_in_flight do
      # Our own dispatch already added it + sized the progress session; the
      # broadcast echo is a no-op.
      socket
    else
      # A job started elsewhere (another session/tab on this resource). Track
      # it AND grow the progress session so a later completion can't push
      # progress past total.
      socket
      |> add_in_flight([lang])
      |> bump_started(1)
    end
  end

  def handle_ai_translation_event(socket, :translation_completed, payload, assign_cs) do
    lang = payload[:target_lang]
    fields = payload[:fields] || %{}

    # No per-language flash — with many languages that's dozens of toasts.
    # The progress bar + the field filling in carry the signal.
    socket
    |> maybe_apply_translation(lang, fields, assign_cs)
    |> mark_lang_done(lang)
  end

  def handle_ai_translation_event(socket, :translation_failed, payload, _assign_cs) do
    lang = payload[:target_lang]

    socket
    |> mark_lang_done(lang)
    |> Phoenix.LiveView.put_flash(:error, ai_failed_flash(lang))
  end

  # Stall timer landed (scheduled by arm_stall_timer/1): no language has
  # completed for ai_stall_ms/0, so show the "taking a while" reassurance —
  # but only if something's still running.
  def handle_ai_translation_event(socket, :slow_tick, payload, _assign_cs) do
    cond do
      # Nothing running — a stall is meaningless.
      socket.assigns.ai_in_flight == [] ->
        socket

      # Stale tick from a clock that's since been re-armed or cancelled
      # (the message was already in the mailbox when we reset). Ignore it.
      payload[:token] != socket.assigns[:ai_slow_token] ->
        socket

      true ->
        Phoenix.Component.assign(socket, :ai_slow, true)
    end
  end

  def handle_ai_translation_event(socket, _event, _payload, _assign_cs), do: socket

  defp maybe_apply_translation(socket, lang, fields, assign_cs)
       when is_binary(lang) and map_size(fields) > 0 do
    cs = socket.assigns.changeset
    data = Ecto.Changeset.get_field(cs, :data) || %{}
    # The multilang form reads per-language overrides under `_`-prefixed keys
    # (`_name`/`_description`); the broadcast carries plain engine names.
    # Force-store (even when equal to the primary) so the field never looks
    # like a failed translation — same rationale as the worker's persist.
    lang_fields = Map.new(fields, fn {k, v} -> {"_" <> k, v} end)
    new_data = PhoenixKitCatalogue.AITranslatable.force_put_language(data, lang, lang_fields)
    assign_cs.(socket, Ecto.Changeset.put_change(cs, :data, new_data))
  end

  defp maybe_apply_translation(socket, _lang, _fields, _assign_cs), do: socket

  # Terminal lifecycle for a language: drop it from in-flight and advance the
  # progress session, flipping to :completed when nothing is left running.
  # No-op for a stale/duplicate event whose lang already left in-flight.
  defp mark_lang_done(socket, lang) when is_binary(lang) do
    in_flight = socket.assigns.ai_in_flight

    if lang in in_flight do
      new_in_flight = in_flight -- [lang]
      # Clamp to total — defends the bar against any started/completed
      # accounting skew (e.g. a cross-session event the started handler
      # didn't size for).
      progress = min((socket.assigns.ai_progress || 0) + 1, socket.assigns.ai_total)
      status = if new_in_flight == [], do: :completed, else: :in_progress

      socket =
        Phoenix.Component.assign(socket,
          ai_in_flight: new_in_flight,
          ai_progress: progress,
          ai_status: status
        )

      # Progress just advanced: restart the stall clock (and hide the hint)
      # if more remain, or cancel it entirely once the batch is done.
      if new_in_flight == [],
        do: socket |> cancel_stall_timer() |> Phoenix.Component.assign(:ai_slow, false),
        else: arm_stall_timer(socket)
    else
      socket
    end
  end

  defp mark_lang_done(socket, _lang), do: socket

  defp ai_failed_flash(lang) when is_binary(lang),
    do:
      Gettext.gettext(PhoenixKitCatalogue.Gettext, "Translation failed for %{lang}.",
        lang: String.upcase(lang)
      )

  defp ai_failed_flash(_),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Translation failed.")

  defp flash_error(socket, msg), do: Phoenix.LiveView.put_flash(socket, :error, msg)

  defp existing_translation_langs(data) when is_map(data) do
    data
    |> Map.drop(["_primary_language"])
    |> Enum.filter(fn {k, v} -> is_binary(k) and translated_subtree?(v) end)
    |> Enum.map(fn {k, _v} -> k end)
  end

  defp existing_translation_langs(_), do: []

  # A language counts as already translated only when its subtree holds at
  # least one non-empty `_`-prefixed override (the multilang form's key
  # shape) — not just any incidental key.
  defp translated_subtree?(v) when is_map(v) do
    Enum.any?(v, fn {k, val} ->
      is_binary(k) and String.starts_with?(k, "_") and is_binary(val) and String.trim(val) != ""
    end)
  end

  defp translated_subtree?(_), do: false

  # ── PDF library display helpers ─────────────────────────────────────
  # Shared between `Web.PdfLibraryLive` and `Web.PdfDetailLive`. Pure
  # accessors / formatters with no side effects — safe to call from a
  # template's interpolated expression.

  @doc "Pulls the extraction status off a (possibly preloaded) Pdf row; defaults to `pending`."
  @spec pdf_extraction_status(map()) :: String.t()
  def pdf_extraction_status(%{extraction: %{extraction_status: s}}) when is_binary(s), do: s
  def pdf_extraction_status(_), do: "pending"

  @doc "Pulls the page count off a (possibly preloaded) Pdf row; returns nil if unknown."
  @spec pdf_extraction_pages(map()) :: integer() | nil
  def pdf_extraction_pages(%{extraction: %{page_count: n}}) when is_integer(n), do: n
  def pdf_extraction_pages(_), do: nil

  @doc "Pulls the extracted_at timestamp off a (possibly preloaded) Pdf row; nil if not extracted."
  @spec pdf_extracted_at(map()) :: DateTime.t() | NaiveDateTime.t() | nil
  def pdf_extracted_at(%{extraction: %{extracted_at: dt}}), do: dt
  def pdf_extracted_at(_), do: nil

  @doc "Pulls the error_message off a (possibly preloaded) Pdf row; nil if no error."
  @spec pdf_error_message(map()) :: String.t() | nil
  def pdf_error_message(%{extraction: %{error_message: m}}) when is_binary(m), do: m
  def pdf_error_message(_), do: nil

  @doc "daisyUI badge class for an extraction status string."
  @spec pdf_status_badge_class(String.t()) :: String.t()
  def pdf_status_badge_class("pending"), do: "badge-ghost"
  def pdf_status_badge_class("extracting"), do: "badge-info"
  def pdf_status_badge_class("extracted"), do: "badge-success"
  def pdf_status_badge_class("scanned_no_text"), do: "badge-warning"
  def pdf_status_badge_class("failed"), do: "badge-error"
  def pdf_status_badge_class(_), do: "badge-ghost"

  @doc "Translated label for an extraction status."
  @spec pdf_status_label(String.t()) :: String.t()
  def pdf_status_label("pending"), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Pending")

  def pdf_status_label("extracting"),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Extracting")

  def pdf_status_label("extracted"), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Extracted")

  def pdf_status_label("scanned_no_text"),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Scanned (no text)")

  def pdf_status_label("failed"), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed")
  def pdf_status_label(other), do: other

  @doc "Human-readable byte size with B / KB / MB / GB suffixes."
  @spec format_byte_size(integer() | nil) :: String.t()
  def format_byte_size(nil), do: "—"
  def format_byte_size(bytes) when bytes < 1024, do: "#{bytes} B"
  def format_byte_size(bytes) when bytes < 1024 * 1024, do: "#{div(bytes, 1024)} KB"

  def format_byte_size(bytes) when bytes < 1024 * 1024 * 1024,
    do: "#{div(bytes, 1024 * 1024)} MB"

  def format_byte_size(bytes), do: "#{Float.round(bytes / (1024 * 1024 * 1024), 2)} GB"

  @doc """
  Translated relative-time label for a timestamp.

  Buckets: `< 1m` → "just now", `< 1h` → "Nm ago", `< 1d` → "Nh ago",
  `< 1w` → "Nd ago", else `Mon DD, YYYY` (locale-formatted via
  gettext'd strftime template).
  """
  @spec format_time_ago(DateTime.t() | nil) :: String.t()
  def format_time_ago(nil), do: "—"

  def format_time_ago(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 ->
        Gettext.gettext(PhoenixKitCatalogue.Gettext, "just now")

      diff < 3600 ->
        Gettext.gettext(PhoenixKitCatalogue.Gettext, "%{n}m ago", n: div(diff, 60))

      diff < 86_400 ->
        Gettext.gettext(PhoenixKitCatalogue.Gettext, "%{n}h ago", n: div(diff, 3600))

      diff < 604_800 ->
        Gettext.gettext(PhoenixKitCatalogue.Gettext, "%{n}d ago", n: div(diff, 86_400))

      true ->
        Calendar.strftime(
          datetime,
          Gettext.gettext(PhoenixKitCatalogue.Gettext, "%b %d, %Y")
        )
    end
  end

  @doc "HTML-escapes a string for safe interpolation into raw markup."
  @spec escape_html(String.t() | nil) :: String.t()
  def escape_html(s),
    do: s |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
