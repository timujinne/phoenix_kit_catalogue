defmodule PhoenixKitCatalogue.API.Refs do
  @moduledoc false
  # Reference resolution for the shop API; the public door is
  # `PhoenixKitCatalogue.API.resolve_refs/2` (see its doc).
  #
  # Three batched lookups at most, one per kind of key, run by the context
  # (`Catalogue.lookup_by_ids/3`, `lookup_by_skus/3`, `lookup_by_external_ids/3`):
  # this module parses and shapes, it never touches `Repo` (AGENTS.md: all
  # business logic goes through the single public context).
  # Input is untrusted: a value that is not a UUID names no row (a raw
  # `where: uuid == ^value` on it would raise `Ecto.Query.CastError`), and a
  # text containing a NUL byte names no row either (Postgres refuses it with
  # `invalid byte sequence`, which would fail the whole batch), so both are
  # answered here, per reference, before they reach the context.

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Schemas.{Category, Item}

  @type error :: :not_found | :invalid_ref | {:ambiguous_ref, [Ecto.UUID.t()]}
  @type resolution :: {term(), {:ok, Item.t() | Category.t()} | {:error, error()}}

  @keys %{"id" => :id, "sku" => :sku, "external_id" => :external_id}

  @doc ~S|The external id a record carries (`data["api"]["external_id"]`), or `nil`.|
  @spec external_id(map()) :: String.t() | nil
  def external_id(%{data: %{"api" => %{"external_id" => value}}}) when is_binary(value), do: value
  def external_id(_record), do: nil

  @spec resolve([term()], keyword()) :: [resolution()]
  def resolve(refs, opts \\ []) when is_list(refs) do
    kind = Keyword.get(opts, :kind, :item)
    lookup_opts = Keyword.take(opts, [:catalogue_uuid, :include_deleted, :preload])
    parsed = Enum.map(refs, &{&1, parse(&1, kind)})

    by_id =
      Catalogue.lookup_by_ids(
        kind,
        for({_ref, {:id, id}} <- parsed, is_binary(id), do: id),
        lookup_opts
      )

    by_sku =
      Catalogue.lookup_by_skus(
        kind,
        for({_ref, {:sku, sku}} <- parsed, is_binary(sku), do: sku),
        lookup_opts
      )

    by_eid =
      Catalogue.lookup_by_external_ids(
        kind,
        for({_ref, {:external_id, eid}} <- parsed, is_binary(eid), do: eid),
        lookup_opts
      )

    Enum.map(parsed, fn
      {ref, :invalid} -> {ref, {:error, :invalid_ref}}
      {ref, {:id, :malformed}} -> {ref, {:error, :not_found}}
      {ref, {:sku, :malformed}} -> {ref, {:error, :not_found}}
      {ref, {:external_id, :malformed}} -> {ref, {:error, :not_found}}
      {ref, {:id, id}} -> {ref, found(Map.get(by_id, id))}
      {ref, {:sku, sku}} -> {ref, many(Map.get(by_sku, sku, []))}
      {ref, {:external_id, eid}} -> {ref, many(Map.get(by_eid, eid, []))}
    end)
  end

  # Exactly one of id / sku / external_id, a non-empty string.
  defp parse(ref, kind) when is_map(ref) do
    given =
      Enum.flat_map(@keys, fn {key, atom} ->
        case Map.get(ref, key, Map.get(ref, atom)) do
          nil -> []
          value -> [{key, value}]
        end
      end)

    case given do
      [{"id", value}] -> parse_id(value)
      [{"sku", value}] when kind == :item -> parse_text(:sku, value)
      [{"external_id", value}] -> parse_text(:external_id, value)
      _other -> :invalid
    end
  end

  defp parse(_ref, _kind), do: :invalid

  defp parse_id(value) when is_binary(value) do
    with false <- String.trim(value) == "",
         36 <- byte_size(value),
         {:ok, uuid} <- Ecto.UUID.cast(value) do
      {:id, uuid}
    else
      true -> :invalid
      _not_a_uuid -> {:id, :malformed}
    end
  end

  defp parse_id(_other), do: :invalid

  defp parse_text(kind, value) when is_binary(value) do
    cond do
      String.trim(value) == "" -> :invalid
      String.contains?(value, <<0>>) -> {kind, :malformed}
      true -> {kind, value}
    end
  end

  defp parse_text(_kind, _value), do: :invalid

  defp found(nil), do: {:error, :not_found}
  defp found(row), do: {:ok, row}

  defp many([]), do: {:error, :not_found}
  defp many([one]), do: {:ok, one}

  defp many(several) do
    {:error, {:ambiguous_ref, several |> Enum.map(& &1.uuid) |> Enum.sort()}}
  end
end
