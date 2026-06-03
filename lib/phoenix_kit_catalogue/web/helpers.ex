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

  alias PhoenixKitCatalogue.Catalogue.ActivityLog
  alias PhoenixKitWeb.Components.AITranslate.FormGlue

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

  # ── AI translation (delegates to the shared core glue) ───────────────
  # All modal/progress/stall state + dispatch + PubSub handling lives in
  # `PhoenixKitWeb.Components.AITranslate.FormGlue`; the catalogue-specific
  # storage (multilang `data`, `_`-prefixed keys) is in
  # `PhoenixKitCatalogue.AITranslateBinding`.

  @doc "See `FormGlue.assign_ai_translation/4` — wires the catalogue binding."
  def assign_ai_translation(socket, resource_type, resource),
    do:
      FormGlue.assign_ai_translation(
        socket,
        resource_type,
        resource,
        PhoenixKitCatalogue.AITranslateBinding
      )

  defdelegate toggle_ai_modal(socket), to: FormGlue
  defdelegate select_ai_endpoint(socket, uuid), to: FormGlue
  defdelegate select_ai_prompt(socket, uuid), to: FormGlue
  defdelegate select_ai_scope(socket, scope), to: FormGlue
  defdelegate generate_ai_prompt(socket), to: FormGlue
  defdelegate ai_translate_config(assigns), to: FormGlue
  defdelegate dispatch_ai_translate(socket, lang), to: FormGlue
  defdelegate handle_ai_translation_event(socket, event, payload, assign_cs), to: FormGlue

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
