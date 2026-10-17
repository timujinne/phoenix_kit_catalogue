defmodule PhoenixKitCatalogue.API.Attributes do
  @moduledoc false
  # Attribute sets (the v2 attribute system) as the API sees them:
  # `[%{"set_id", "values" => [value keys]}]`. Reads are batched; writes are
  # validated up front (`validate/1`) so a failure after the item itself was
  # written is a race, not a typo.

  alias PhoenixKitCatalogue.Catalogue

  @doc "`%{item_uuid => [set card]}` for these items; items without a set are absent."
  @spec for_items([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => [map()]}
  def for_items([]), do: %{}

  def for_items(item_uuids) do
    item_uuids
    |> Catalogue.resolve_attribute_sets()
    |> Map.new(fn {uuid, %{sets: sets}} -> {uuid, Enum.map(sets, &card/1)} end)
  end

  defp card(set) do
    %{
      "set_id" => set.uuid,
      "key" => set.key,
      "name" => set.name,
      "kind" => set.kind,
      "values" => Enum.map(set.values, & &1.key),
      "selected" => Map.get(set, :selected, [])
    }
  end

  @doc """
  Checks the sets exist and the value keys belong to them. `:ok` or
  `{:error, message, context}` (the message names the set; the context lists
  what was wrong and what is allowed).
  """
  @spec validate([map()]) :: :ok | {:error, String.t(), map()}
  def validate(entries) do
    {verdict, _cache} = validate(entries, %{})
    verdict
  end

  @doc """
  `validate/1` for a batch: `cache` (a map the caller threads from row to row)
  remembers each set once looked up. Returns `{verdict, cache}`.
  """
  @spec validate([map()], map()) :: {:ok | {:error, String.t(), map()}, map()}
  def validate([], cache), do: {:ok, cache}

  def validate(entries, cache) when is_list(entries) do
    if Catalogue.attribute_sets_enabled?() do
      first_error(entries, cache)
    else
      {{:error, "Attribute sets are not available: the entities module is off.", %{}}, cache}
    end
  end

  defp first_error(entries, cache) do
    Enum.reduce_while(entries, {:ok, cache}, fn entry, {:ok, cache} ->
      case validate_entry(entry, cache) do
        {:ok, cache} -> {:cont, {:ok, cache}}
        {{:error, _message, _context} = error, cache} -> {:halt, {error, cache}}
      end
    end)
  end

  # `set_id` is a row-level string (the schema has no length floor, see
  # `Schemas`): a malformed id is this row's error, not a CastError.
  defp validate_entry(%{"set_id" => set_id, "values" => values}, cache) do
    {set, cache} = resolve_set(set_id, cache)

    case set do
      nil ->
        {{:error, "Attribute set #{set_id} does not exist.", %{"set_id" => set_id}}, cache}

      %{values: set_values} ->
        allowed = Enum.map(set_values, & &1.key)

        case Enum.reject(values, &(&1 in allowed)) do
          [] ->
            {:ok, cache}

          unknown ->
            {{:error, "Unknown value for attribute set #{set_id}.",
              %{"set_id" => set_id, "unknown" => unknown, "allowed" => allowed}}, cache}
        end
    end
  end

  defp resolve_set(set_id, cache) do
    case Map.fetch(cache, set_id) do
      {:ok, set} ->
        {set, cache}

      :error ->
        set = lookup_set(set_id)
        {set, Map.put(cache, set_id, set)}
    end
  end

  defp lookup_set(set_id) do
    case Ecto.UUID.cast(set_id) do
      {:ok, uuid} -> Catalogue.resolve_attribute_set(uuid)
      :error -> nil
    end
  end

  @doc """
  Whether applying `entries` would change anything: a set that is not attached
  yet, or an attached set whose selection differs (order ignored). Call it
  BEFORE `apply_to_item/3`; `update_products` uses it so that re-sending the
  current selection answers `unchanged`, not `updated`.
  """
  @spec changed?(Ecto.UUID.t(), [map()]) :: boolean()
  def changed?(_item_uuid, []), do: false

  def changed?(item_uuid, entries) do
    attached = selections(item_uuid)

    Enum.any?(entries, fn %{"set_id" => set_id, "values" => values} ->
      with {:ok, set_uuid} <- Ecto.UUID.cast(set_id),
           {:ok, current} <- Map.fetch(attached, set_uuid) do
        Enum.sort(current) != Enum.sort(values)
      else
        _not_attached_or_malformed -> true
      end
    end)
  end

  @doc """
  The value keys selected for every set attached to an item, as
  `%{set_uuid => [value key]}`, in one query.
  """
  @spec selections(Ecto.UUID.t()) :: %{Ecto.UUID.t() => [String.t()]}
  def selections(item_uuid) do
    item_uuid
    |> Catalogue.list_attribute_set_attachments()
    |> Map.new(&{&1.set_uuid, List.wrap((&1.data || %{})["selected_value_slugs"])})
  end

  @doc "The value keys currently selected for one attached set (`[]` when the set is not attached)."
  @spec selection(Ecto.UUID.t(), Ecto.UUID.t()) :: [String.t()]
  def selection(item_uuid, set_uuid), do: item_uuid |> selections() |> Map.get(set_uuid, [])

  @doc "Attaches each set (a no-op when attached) and stores the selection. `opts` carry `:actor_uuid`, `:mode` and `:log_metadata` (the activity entries then say `via: api` and which tool)."
  @spec apply_to_item(Ecto.UUID.t(), [map()], keyword()) :: :ok | {:error, term()}
  def apply_to_item(item_uuid, entries, opts) do
    Enum.reduce_while(entries, :ok, fn %{"set_id" => set_id, "values" => values}, :ok ->
      with {:ok, _row} <- Catalogue.attach_attribute_set(item_uuid, set_id, opts),
           :ok <- Catalogue.set_attribute_set_selection(item_uuid, set_id, values, opts) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
