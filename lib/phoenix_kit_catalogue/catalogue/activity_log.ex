defmodule PhoenixKitCatalogue.Catalogue.ActivityLog do
  @moduledoc false
  # Shared activity-logging helper used by every Catalogue submodule.
  # Wraps `PhoenixKit.Activity.log/1` with the catalogue module key
  # injected. External plugins must guard with `Code.ensure_loaded?/1`,
  # which we do here once so callers don't have to repeat it.
  #
  # ## Convention — layered logging
  #
  # The context layer (this module's callers — `Catalogue`, `Rules`,
  # `Manufacturers`, etc.) logs on **success only**. Validation errors
  # never reach the audit feed: they're handled by the LV's
  # `assign_form/2` cycle and never persisted as audit rows.
  #
  # The LV layer logs on **both branches** via
  # `PhoenixKitCatalogue.Web.Helpers.log_operation_error/3` (added in
  # the 2026-04-28 re-validation Batch 4). On `{:error, _}`-from-
  # context failures — FK violations, stale-entry races, downstream
  # cascade refusals — the helper writes the same action atom the
  # success path would have written, with `metadata.db_pending: true`
  # so audit-feed readers can filter or highlight failed attempts.
  #
  # The two layers solve different problems and coexist:
  #
  #   * **Engineer-visible** errors flow through `Logger.error` with
  #     full changeset/atom context for production-incident triage.
  #   * **User-visible** audit rows capture user *intent* — a
  #     legitimate attempted action that failed is still audit-worthy
  #     for security and forensic purposes.
  #
  # Validation cycles never produce audit noise because
  # `log_operation_error/3` is only called from `handle_event`
  # `{:error, _}` branches that the form's error display didn't
  # already handle.

  require Logger

  @module_key "catalogue"

  @doc """
  Direct, fire-and-forget log call. Always returns `:ok`.

  Use this from inside transactions, multi-step operations, and the
  module enable/disable callbacks. Never raises — DB hiccups, missing
  table (host hasn't run core's V90 migration), or a mis-shaped Activity
  context all swallow silently with a `Logger.warning`. Returning a
  result from the primary operation must take precedence over logging
  fidelity.
  """
  @spec log(map()) :: :ok
  def log(attrs) when is_map(attrs) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      try do
        PhoenixKit.Activity.log(Map.put(attrs, :module, @module_key))
      rescue
        e in Postgrex.Error ->
          # Host hasn't run the activity migration — silent so test DBs
          # without the table don't spam warnings.
          if match?(%{postgres: %{code: :undefined_table}}, e) do
            :ok
          else
            Logger.warning(
              "PhoenixKitCatalogue activity log failed: #{Exception.message(e)} — attrs=#{inspect(Map.take(attrs, [:action, :resource_type, :resource_uuid]))}"
            )
          end

        DBConnection.OwnershipError ->
          # Async PubSub broadcast crossing into a logging path without
          # sandbox checkout (test-only) — swallow per publishing-Batch-5.
          :ok

        error ->
          Logger.warning(
            "PhoenixKitCatalogue activity log failed: #{Exception.message(error)} — attrs=#{inspect(Map.take(attrs, [:action, :resource_type, :resource_uuid]))}"
          )
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  @doc """
  Adds a `"changes"` map to `metadata` when anything actually moved.

  The diff lives under a RESERVED key, never merged into the metadata's own
  keys. Merging them collides: `@item_logged_fields` includes `:name`, so a
  rename overwrote the identity `"name" => "T-Joint 25mm"` with
  `"name" => %{"from" => …, "to" => …}` — and the deep-link title, which
  reads `:metadata.name` and calls `to_string/1` on it, raised
  `Protocol.UndefinedError`. A renamed row therefore lost the very link this
  work added, on the one action most worth opening (found by the design
  panel, 2026-09-20; reproduced before fixing).

  Identity stays at the top level so a row is readable and linkable; the
  change sits beside it so a reader can tell the two apart.
  """
  @spec with_changes(map(), struct(), struct(), [atom()]) :: map()
  def with_changes(metadata, before, now, fields) do
    case changed_fields(before, now, fields) do
      empty when map_size(empty) == 0 -> metadata
      changes -> Map.put(metadata, "changes", changes)
    end
  end

  @doc """
  The fields that actually changed, as `%{field => %{"from" => old, "to" => new}}`.

  Core renders that shape as `old → new` in the Activity detail's metadata
  table (`PhoenixKit.Activity.humanize_metadata_value/1`), which is what turns
  an entry from "this item was updated" into "what was updated" — the owner
  opened an event and could not tell what had changed (boss via Max,
  2026-09-20).

  Takes the record as it was and as it now is, plus the fields worth
  reporting. Only fields whose value really moved are included, so an
  untouched save logs no diff at all rather than a wall of unchanged rows.

  Values are stringified: the metadata column is JSONB, and a `Decimal` or a
  `Date` in there comes back out through `inspect/1` looking like code.
  Multilang maps (`name`, `description`) are skipped by the callers, which
  pass the resolved scalar instead — a raw translations map would render as
  every language at once.
  """
  # Long bodies record only THAT they changed. Two copies of a description in
  # every row's JSONB is a lot of storage for a fact the record itself shows
  # better — but omitting it silently is worse, because the reader cannot tell
  # an untouched description from one that was rewritten (design panel,
  # 2026-09-20: unanimous on both halves).
  @flag_only_fields [:description]

  @spec changed_fields(struct(), struct(), [atom()]) :: %{optional(String.t()) => map()}
  def changed_fields(before, now, fields) when is_list(fields) do
    # Deliberately a reduce, not a comprehension with `old = Map.get(...)`
    # clauses: a non-generator clause in `for` is a FILTER, so binding a nil
    # old value there silently dropped every field being set for the first
    # time — exactly the change most worth seeing.
    Enum.reduce(fields, %{}, fn field, acc ->
      old = Map.get(before, field)
      new = Map.get(now, field)

      cond do
        equal_values?(old, new) -> acc
        field in @flag_only_fields -> Map.put(acc, to_string(field), %{"changed" => true})
        true -> Map.put(acc, to_string(field), diff_pair(old, new))
      end
    end)
  end

  defp diff_pair(old, new), do: %{"from" => display_value(old), "to" => display_value(new)}

  # A bulk row records which rows it touched, but not an unbounded list of
  # them: a 500-item move would put 18KB of uuids into every reader's page,
  # for a list nobody reads past the first few (design panel, 2026-09-20 —
  # "unbounded nested dumps" is what breaks first, not row count).
  @uuid_sample_size 10

  @doc """
  The uuids a bulk action touched, capped, with a note when it truncated.
  """
  @spec sample_uuids([binary()], non_neg_integer()) :: map()
  def sample_uuids(uuids, count) when is_list(uuids) do
    sample = Enum.take(uuids, @uuid_sample_size)

    if count > length(sample) do
      %{"uuids" => sample, "uuids_truncated" => count - length(sample)}
    else
      %{"uuids" => sample}
    end
  end

  def sample_uuids(_uuids, _count), do: %{}

  @doc """
  A snapshotted reference to another record: `%{"uuid" =>, "label" =>}`.

  The label is resolved when the row is WRITTEN, never when it is read. That
  is what an audit row means — "the supplier was Acme when Jane did this" —
  and it is the only version that still works once the referenced record is
  gone, which is exactly when the log is the only name left (design panel,
  2026-09-20, unanimous). Core renders the pair as the label alone.

  `nil` uuid means "nowhere": the top of a tree, an uncategorized item, a
  catalogue at the folder root. It gets a label so the arrow still reads.
  """
  @spec ref(binary() | nil, binary() | nil, binary()) :: map()
  def ref(uuid, label, nowhere_label \\ "—")

  def ref(nil, _label, nowhere_label), do: %{"label" => nowhere_label}

  def ref(uuid, label, _nowhere_label) do
    %{"uuid" => uuid, "label" => presence(label) || unresolved_label(uuid)}
  end

  # A reference that HAS a uuid but whose name would not resolve is NOT the
  # same as no reference at all. Falling back to the nowhere label made a
  # move into a since-deleted category read as "moved to Uncategorized" —
  # an audit row stating something that never happened, and the reader has
  # no way to tell (design review, codex, 2026-09-20; it was the only seat
  # to spot it). Say plainly that the row is gone, and keep the uuid so the
  # reference is still identifiable.
  defp unresolved_label(uuid) do
    short = uuid |> to_string() |> String.slice(0, 8)
    "#{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Deleted")} (#{short}…)"
  end

  @doc """
  Builds a `"changes"` map from explicit `{field, from, to}` triples, keeping
  only the dimensions that really moved.

  Used by the move actions, where the two sides are references rather than
  scalars and there is no "before" struct to diff against.
  """
  @spec changes([{atom() | String.t(), term(), term()}]) :: map()
  def changes(triples) when is_list(triples) do
    for {field, from, to} <- triples,
        not same_ref?(from, to),
        into: %{},
        do: {to_string(field), %{"from" => from, "to" => to}}
  end

  defp same_ref?(%{"uuid" => a}, %{"uuid" => b}), do: a == b
  defp same_ref?(a, b), do: a == b

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value) when is_binary(value), do: value
  defp presence(_), do: nil

  # Decimal needs `compare/2`: 8.50 and 8.5 are the same price and must not
  # read as a change, but they are different terms.
  defp equal_values?(%Decimal{} = a, %Decimal{} = b), do: Decimal.equal?(a, b)
  defp equal_values?(a, b), do: a == b

  defp display_value(nil), do: ""
  defp display_value(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp display_value(value) when is_binary(value), do: value
  defp display_value(value) when is_number(value) or is_boolean(value), do: to_string(value)

  # Everything else is inspected rather than stringified. `to_string/1` is
  # wrong or fatal for most of what a schema field can hold: a list of
  # strings comes out as an iolist with its boundaries gone (`["a", "b"]`
  # → `"ab"`), and a tuple, MapSet or atom list raises — taking the whole
  # save down for the sake of an audit row (codex, 2026-09-20). No field in
  # the lists above holds one today; this is about the next one that does.
  defp display_value(value), do: inspect(value)

  @doc """
  Runs `op_fun` and, on `{:ok, _}`, logs an activity entry with `attrs_fun(record)`.
  Collapses the repeating `case Repo.insert(...) do {:ok, x} = ok -> log; ok; ... end`
  pattern that appears across every CRUD function.

  `op_fun` should return `{:ok, record} | {:error, anything}`. `attrs_fun` is
  only called on success and receives the inserted/updated record.
  """
  @spec with_log((-> {:ok, term()} | {:error, term()}), (term() -> map())) ::
          {:ok, term()} | {:error, term()}
  def with_log(op_fun, attrs_fun) when is_function(op_fun, 0) and is_function(attrs_fun, 1) do
    case op_fun.() do
      {:ok, record} = ok ->
        log(attrs_fun.(record))
        ok

      {:error, _} = err ->
        err
    end
  end
end
