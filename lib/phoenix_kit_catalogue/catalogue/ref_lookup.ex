defmodule PhoenixKitCatalogue.Catalogue.RefLookup do
  @moduledoc """
  Batched lookups of items and categories by uuid, sku or `external_id`
  (`data -> 'api' ->> 'external_id'`), for the shop API's reference resolution
  (`PhoenixKitCatalogue.API.Refs`). Public surface re-exported from
  `PhoenixKitCatalogue.Catalogue` as `lookup_by_ids/3`, `lookup_by_skus/3` and
  `lookup_by_external_ids/3`.

  `kind` is `:item` or `:category`. The values must already be valid: ids are
  UUIDs (the caller casts them; a raw `where: uuid in ^ids` on a malformed
  string raises `Ecto.Query.CastError`), skus and external ids are non-blank
  strings. Each function runs ONE query and answers a map keyed by the value.
  A sku or external id containing a NUL byte can match nothing and Postgres
  refuses it, so it is dropped from the query instead of failing the batch.

  ## Options

    * `:catalogue_uuid` — only rows of this catalogue.
    * `:include_deleted` — default `false`: trashed rows are not found.
    * `:preload` — associations to preload, default none.
  """

  import Ecto.Query, warn: false

  alias PhoenixKitCatalogue.Schemas.{Category, Item}

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc "`%{uuid => row}` for the given uuids."
  @spec by_ids(:item | :category, [Ecto.UUID.t()], keyword()) :: %{Ecto.UUID.t() => struct()}
  def by_ids(_kind, [], _opts), do: %{}

  def by_ids(kind, ids, opts) do
    ids = Enum.uniq(ids)

    kind
    |> scoped(opts)
    |> where([r], r.uuid in ^ids)
    |> repo().all()
    |> Map.new(&{&1.uuid, &1})
  end

  @doc "`%{sku => [row]}`; items only (categories have no sku: an empty map)."
  @spec by_skus(:item | :category, [String.t()], keyword()) :: %{String.t() => [struct()]}
  def by_skus(_kind, [], _opts), do: %{}
  def by_skus(:category, _skus, _opts), do: %{}

  def by_skus(:item, skus, opts) do
    case queryable_texts(skus) do
      [] ->
        %{}

      skus ->
        :item
        |> scoped(opts)
        |> where([r], r.sku in ^skus)
        |> repo().all()
        |> Enum.group_by(& &1.sku)
    end
  end

  @doc "`%{external_id => [row]}`."
  @spec by_external_ids(:item | :category, [String.t()], keyword()) :: %{String.t() => [struct()]}
  def by_external_ids(_kind, [], _opts), do: %{}

  def by_external_ids(kind, eids, opts) do
    case queryable_texts(eids) do
      [] ->
        %{}

      eids ->
        kind
        |> scoped(opts)
        |> where(
          [r],
          fragment(
            "(? -> 'api' ->> 'external_id') = ANY(?)",
            r.data,
            type(^eids, {:array, :string})
          )
        )
        |> repo().all()
        |> Enum.group_by(&get_in(&1.data || %{}, ["api", "external_id"]))
    end
  end

  defp queryable_texts(values) do
    values
    |> Enum.uniq()
    |> Enum.reject(&String.contains?(&1, <<0>>))
  end

  defp schema(:item), do: Item
  defp schema(:category), do: Category

  defp scoped(kind, opts) do
    query = from(r in schema(kind))

    query =
      if Keyword.get(opts, :include_deleted, false),
        do: query,
        else: where(query, [r], r.status != "deleted")

    query =
      case Keyword.get(opts, :catalogue_uuid) do
        nil -> query
        catalogue_uuid -> where(query, [r], r.catalogue_uuid == ^catalogue_uuid)
      end

    case Keyword.get(opts, :preload, []) do
      [] -> query
      preloads -> preload(query, ^preloads)
    end
  end
end
