defmodule PhoenixKitCatalogue.API.Common do
  @moduledoc false
  # Small helpers every tool handler shares: the write options that make a log
  # entry say who and how, validation errors in the executor's shape, the row
  # shapes of batch answers, and the preview/fingerprint pair of a dry run.

  alias PhoenixKitCatalogue.Catalogue

  # --- who and how --------------------------------------------------------------

  @doc """
  The options every API write passes to the `Catalogue` context: the key
  owner as actor, `mode: "auto"`, and the metadata that marks the entry as an
  API write. `extra` is merged over them.
  """
  @spec write_opts(map(), String.t(), keyword()) :: keyword()
  def write_opts(ctx, tool, extra \\ []) do
    actor = ctx.actor

    meta = %{
      "via" => "api",
      "key_prefix" => actor.key_prefix,
      "request_id" => ctx.request_id,
      "tool" => tool
    }

    meta =
      case Map.get(ctx, :approved_by_uuid) do
        uuid when is_binary(uuid) -> Map.put(meta, "approved_by_uuid", uuid)
        _none -> meta
      end

    Keyword.merge([actor_uuid: actor.user_uuid, mode: "auto", log_metadata: meta], extra)
  end

  # --- input checks ---------------------------------------------------------------

  @doc "A handler error for one input path, in the shape core's executor uses."
  @spec invalid(String.t(), String.t(), [term()] | nil) ::
          {:error, :validation_failed, String.t(), map()}
  def invalid(path, message, allowed \\ nil) do
    {:error, :validation_failed, message,
     %{errors: [%{path: path, message: message, limit: nil, allowed: allowed}]}}
  end

  @spec parse_uuid(term(), String.t()) ::
          {:ok, Ecto.UUID.t() | nil} | {:error, atom(), String.t(), map()}
  def parse_uuid(nil, _path), do: {:ok, nil}

  def parse_uuid(value, path) when is_binary(value) and byte_size(value) == 36 do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> invalid(path, "must be a UUID")
    end
  end

  def parse_uuid(_other, path), do: invalid(path, "must be a UUID")

  @required_schema 5

  @doc """
  The write tools that store or look up an `external_id` (`create_products`,
  `update_products`, `upsert_categories`) refuse to run until the module's
  database chain is at V5, where the unique indexes that make an `external_id`
  safe exist. Without them two rows could take the same id, and the later
  `CREATE UNIQUE INDEX` would fail on the duplicates. `version` defaults to
  the applied chain version read from the database marker. The marker reader
  answers `0` both for a database that was never migrated and when it could
  not read the marker at all, so `0` is reported as "could not confirm".
  """
  @spec ensure_schema(non_neg_integer()) :: :ok | {:error, atom(), String.t(), map()}
  def ensure_schema(version \\ PhoenixKitCatalogue.Migrations.migrated_version_runtime()) do
    if version >= @required_schema do
      :ok
    else
      {:error, :internal_error, schema_message(version),
       %{required: @required_schema, applied: version}}
    end
  end

  defp schema_message(0) do
    "Could not confirm the catalogue database schema version; the shop API tools need " <>
      "#{@required_schema} (external_id indexes). Retry, or run the module's migrations " <>
      "(mix phoenix_kit.update) if the database was never migrated."
  end

  defp schema_message(version) do
    "The catalogue database schema is at version #{version}; the shop API tools need #{@required_schema} " <>
      "(external_id indexes). Run the module's migrations (mix phoenix_kit.update) first."
  end

  @spec blank?(term()) :: boolean()
  def blank?(nil), do: true
  def blank?(value) when is_binary(value), do: String.trim(value) == ""
  def blank?(_other), do: false

  # --- batch rows -------------------------------------------------------------------

  @spec row_ok(term(), String.t(), String.t() | nil, map()) :: map()
  def row_ok(ref, action, id, extra \\ %{}) do
    Map.merge(%{"ref" => ref, "action" => action, "id" => id}, extra)
  end

  @spec row_error(term(), atom(), String.t(), map()) :: map()
  def row_error(ref, code, message, context \\ %{}) do
    %{"ref" => ref, "action" => "error", "error" => error_body(code, message, context)}
  end

  @spec row_skipped(term(), atom(), String.t(), map()) :: map()
  def row_skipped(ref, code, message, context \\ %{}) do
    %{"ref" => ref, "action" => "skipped", "error" => error_body(code, message, context)}
  end

  defp error_body(code, message, context) do
    %{"code" => to_string(code), "message" => message, "context" => context}
  end

  @spec summary([map()]) :: %{String.t() => pos_integer()}
  def summary(rows), do: Enum.frequencies_by(rows, & &1["action"])

  @spec batch_result([map()]) :: {:ok, map()}
  def batch_result(rows), do: {:ok, %{"results" => rows, "summary" => summary(rows)}}

  @doc """
  A dry run's answer: the would-be rows and a fingerprint of them. The
  fingerprint follows the rows' content (the current values the operation
  touches are in them), so a change of state between the preview and the
  confirmation changes it. The `{:preview, preview, fingerprint}` triple is
  what core's executor expects from a handler on a dry run.
  """
  @spec preview([map()]) :: {:preview, map(), String.t()}
  def preview(rows), do: preview(rows, %{})

  @doc """
  `preview/1` with `extra` keys in the preview (not in the fingerprint). The
  tools that always need a confirmation say so with `%{"requires_confirmation" => true}`.
  """
  @spec preview([map()], map()) :: {:preview, map(), String.t()}
  def preview(rows, extra) do
    {:preview, Map.merge(extra, %{"rows" => rows, "summary" => summary(rows)}), fingerprint(rows)}
  end

  @spec fingerprint(term()) :: String.t()
  def fingerprint(term) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(term, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  @spec with_warnings(map(), [map()]) :: map()
  def with_warnings(body, []), do: body
  def with_warnings(body, warnings), do: Map.put(body, "warnings", warnings)

  # --- removing records (the trash tools) ---------------------------------------------

  @doc """
  The plan of a trash tool, one entry per reference in order: `{:remove, ref, record}`,
  `{:already, ref, record}` (a reference to a record already in the trash),
  `{:rejected, ref, message}` (the same record twice) or `{:resolution_error, ref, reason}`.
  `resolutions` came from `API.resolve_refs/2` for `kind` (`:item` or `:category`) inside `catalogue`.
  """
  @spec removal_plan([{term(), {:ok, struct()} | {:error, term()}}], struct(), :item | :category) ::
          [tuple()]
  def removal_plan(resolutions, catalogue, kind) do
    trashed = trashed_by_ref(resolutions, catalogue, kind)

    {planned, _seen} =
      Enum.map_reduce(resolutions, MapSet.new(), fn
        {ref, {:ok, record}}, seen ->
          if MapSet.member?(seen, record.uuid),
            do: {{:rejected, ref, "The same #{kind} appears twice in this request."}, seen},
            else: {{:remove, ref, record}, MapSet.put(seen, record.uuid)}

        {ref, {:error, :not_found}}, seen ->
          case Map.fetch(trashed, ref) do
            :error -> {{:resolution_error, ref, :not_found}, seen}
            {:ok, record} -> {{:already, ref, record}, seen}
          end

        {ref, {:error, reason}}, seen ->
          {{:resolution_error, ref, reason}, seen}
      end)

    planned
  end

  # A reference that matched no LIVE record may name one that is already in the
  # trash, by any of its keys. A sku or external_id that several trashed records
  # share names none of them (the lookup answers `ambiguous_ref`, which stays
  # `not_found` here).
  defp trashed_by_ref(resolutions, catalogue, kind) do
    case for({ref, {:error, :not_found}} <- resolutions, do: ref) do
      [] ->
        %{}

      refs ->
        refs
        |> PhoenixKitCatalogue.API.resolve_refs(
          kind: kind,
          catalogue_uuid: catalogue.uuid,
          include_deleted: true
        )
        |> Enum.flat_map(fn
          {ref, {:ok, %{status: "deleted"} = record}} -> [{ref, record}]
          _other -> []
        end)
        |> Map.new()
    end
  end

  @doc "The row of a plan entry that does not depend on the mode (anything but `:remove`)."
  @spec removal_row(tuple()) :: map()
  def removal_row({:already, ref, record}), do: row_ok(ref, "unchanged", record.uuid)

  def removal_row({:rejected, ref, message}),
    do:
      row_error(ref, :validation_failed, message, %{
        "errors" => [%{"path" => "refs", "message" => message}]
      })

  def removal_row({:resolution_error, ref, reason}), do: resolution_error(ref, reason)

  # --- categories -------------------------------------------------------------------------

  @doc """
  Whether `id` is an active category of `catalogue`. Returns `{verdict, cache}`
  where `verdict` is `{:ok, canonical_uuid}` (the lower-case form of the id, the
  only form the context's writes accept) or `{:error, message}`; the caller
  threads `cache` (a map) through a batch so each category is read once.
  """
  @spec category_verdict(term(), struct(), map()) ::
          {{:ok, Ecto.UUID.t()} | {:error, String.t()}, map()}
  def category_verdict(id, catalogue, cache) do
    key = cache_key(id)

    case Map.fetch(cache, key) do
      {:ok, verdict} ->
        {verdict, cache}

      :error ->
        verdict = verdict_for(key, catalogue.uuid)
        {verdict, Map.put(cache, key, verdict)}
    end
  end

  # An upper-case UUID and its lower-case form are one category (and one cache entry).
  defp cache_key(id) when is_binary(id) and byte_size(id) == 36 do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> id
    end
  end

  defp cache_key(id), do: id

  # The schema lets any string through (row-level ids, see `Schemas`), so a
  # malformed id is answered here, per row, before it can reach Ecto as a
  # CastError.
  defp verdict_for(id, target) do
    with true <- is_binary(id) and byte_size(id) == 36 and match?({:ok, _}, Ecto.UUID.cast(id)),
         %{} = category <- PhoenixKitCatalogue.Catalogue.get_category(id) do
      active_in?(category, target)
    else
      false -> {:error, "must be a UUID"}
      nil -> {:error, "no category has this id"}
    end
  end

  defp active_in?(%{status: "active", catalogue_uuid: target, uuid: uuid}, target),
    do: {:ok, uuid}

  defp active_in?(_category, _target), do: {:error, "is not an active category of this catalogue"}

  # --- reference and changeset failures -----------------------------------------------

  @spec resolution_error(term(), term()) :: map()
  def resolution_error(ref, :not_found) do
    row_error(ref, :not_found, "No record matches this reference.")
  end

  def resolution_error(ref, :invalid_ref) do
    message =
      "A reference needs exactly one of id, sku (items only) or external_id, as a non-empty string."

    row_error(ref, :validation_failed, message, %{
      "errors" => [%{"path" => "ref", "message" => message}]
    })
  end

  def resolution_error(ref, {:ambiguous_ref, ids}) do
    row_error(
      ref,
      :ambiguous_ref,
      "This reference matches #{length(ids)} records; use id or external_id.",
      %{"candidates" => ids}
    )
  end

  @doc ~S|A changeset's errors as `[%{"path" => field, "message" => text}]`, options interpolated.|
  @spec changeset_errors(Ecto.Changeset.t()) :: [map()]
  def changeset_errors(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} -> interpolate(message, opts) end)
    |> Enum.flat_map(fn {field, messages} ->
      messages
      |> List.wrap()
      |> List.flatten()
      |> Enum.map(&%{"path" => to_string(field), "message" => &1})
    end)
  end

  defp interpolate(message, opts) do
    Regex.replace(~r"%{(\w+)}", message, fn _, key -> option_text(opts, key) end)
  end

  defp option_text(opts, key) do
    Enum.find_value(opts, key, fn {name, value} ->
      if Atom.to_string(name) == key, do: to_string(value)
    end)
  end

  @doc "A fixed sentence for why an attribute write was refused; never the raw reason."
  @spec attribute_sentence(term()) :: String.t()
  def attribute_sentence(:set_not_found), do: "an attribute set no longer exists"
  def attribute_sentence(:not_attached), do: "an attribute set is no longer attached to the item"
  def attribute_sentence(:entities_disabled), do: "attribute sets are not available"
  def attribute_sentence(_other), do: "the write was refused"

  @doc "A short machine-readable code for a context refusal: the atom, `invalid` or `unknown`."
  @spec reason_code(term()) :: String.t()
  def reason_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  def reason_code(%Ecto.Changeset{}), do: "invalid"
  def reason_code(_reason), do: "unknown"

  @doc "True when the changeset failed on the V5 `external_id` unique index."
  @spec external_id_conflict?(Ecto.Changeset.t()) :: boolean()
  def external_id_conflict?(%Ecto.Changeset{} = changeset),
    do: Catalogue.external_id_conflict?(changeset)
end
