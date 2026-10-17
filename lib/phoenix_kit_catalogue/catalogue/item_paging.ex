defmodule PhoenixKitCatalogue.Catalogue.ItemPaging do
  @moduledoc """
  Keyset paging of one catalogue's items, for the shop API's incremental
  export. Public surface re-exported from `PhoenixKitCatalogue.Catalogue`
  (`list_items_keyset/1`, `count_items_matching/1`, `decode_items_cursor/1`).

  Rows come ordered by `(updated_at, uuid)` ascending. `updated_at` has second
  precision, so one timestamp can cover many rows; the cursor therefore holds
  both values and the keyset predicate is `updated_at > c OR (updated_at = c
  AND uuid > c_uuid)`. The cursor is truncated to the second, so it is exact
  only while the column keeps whole seconds (`timestamp(0)`). The cursor
  handed to a client is opaque (`Base.url_encode64` of a JSON pair);
  `decode_cursor/1` answers `:error` for anything this module did not issue.

  A row whose transaction commits after a later page was read, with an
  `updated_at` earlier than the cursor, is not seen by that walk, and a row
  updated during the walk moves to the end and can come back a second time. A
  client therefore finishes an export by re-running from the last `updated_at`
  it saw (`:updated_since` is inclusive) and de-duplicating by id.

  ## Options

    * `:catalogue_uuid` — required.
    * `:category_uuid` — exactly this category (not its subtree).
    * `:status` — `"active"`, `"inactive"` or `"discontinued"`; default every
      status but `"deleted"`. `"deleted"` matches only with `include_deleted:
      true`; without it nothing is listed, so trashed rows never leak through
      a status filter.
    * `:include_deleted` — default `false`. `true` and no `:status`: trashed
      rows (status `"deleted"`) are listed too, so an incremental export can
      see deletions (a trash bumps `updated_at`). An explicit `:status` wins.
    * `:updated_since` — a UTC `DateTime`; INCLUSIVE (`>=`): a row changed in
      the same second as the last row of the previous page is not lost, the
      client de-duplicates by id.
    * `:q` — a case-insensitive substring match on `name`, `description` and
      `sku` ONLY. A term with a NUL character (which Postgres cannot store or
      compare) matches nothing. It deliberately does not reuse the admin's `Search.match_text/2`,
      which also matches every string inside `data` (shop price fields, cost,
      vendor, tags): through the API that is a way to read fields the caller's
      scopes do not allow, one substring at a time.
    * `:cursor` — the `{DateTime, uuid}` pair `decode_cursor/1` returns (no
      other value is accepted).
    * `:limit` — default 20, clamped to 1..100.
  """

  import Ecto.Query, warn: false

  alias PhoenixKitCatalogue.Catalogue.Helpers
  alias PhoenixKitCatalogue.Schemas.Item

  @default_limit 20
  @max_limit 100

  # Postgres `timestamp` and Postgrex stop at about year -4713, but rows only
  # carry real dates: a forged cursor outside this range is refused rather
  # than sent to the database.
  @year_range 1..9999

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc "One page: `%{items: [Item.t()], next_cursor: String.t() | nil}`. Items have `:category` preloaded."
  @spec page(keyword()) :: %{items: [Item.t()], next_cursor: String.t() | nil}
  def page(opts) do
    limit = clamp(Keyword.get(opts, :limit, @default_limit))

    rows =
      opts
      |> base()
      |> after_cursor(Keyword.get(opts, :cursor))
      |> order_by([item: i], asc: i.updated_at, asc: i.uuid)
      |> limit(^(limit + 1))
      |> preload([:category])
      |> repo().all()

    {items, rest} = Enum.split(rows, limit)
    next_cursor = if rest == [], do: nil, else: encode_cursor(List.last(items))

    %{items: items, next_cursor: next_cursor}
  end

  @doc "How many items match the filters (the cursor and the limit are ignored)."
  @spec count(keyword()) :: non_neg_integer()
  def count(opts), do: opts |> base() |> repo().aggregate(:count)

  @doc "`{:ok, {updated_at, uuid}}` for a cursor this module issued, `:error` for anything else."
  @spec decode_cursor(term()) :: {:ok, {DateTime.t(), Ecto.UUID.t()}} | :error
  def decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, [at, uuid]} when is_binary(at) and is_binary(uuid) <- Jason.decode(json),
         {:ok, at, _offset} <- DateTime.from_iso8601(at),
         true <- at.year in @year_range,
         {:ok, uuid} <- Ecto.UUID.cast(uuid) do
      {:ok, {DateTime.truncate(at, :second), uuid}}
    else
      _ -> :error
    end
  end

  def decode_cursor(_other), do: :error

  defp encode_cursor(%Item{updated_at: at, uuid: uuid}) do
    Base.url_encode64(Jason.encode!([DateTime.to_iso8601(at), uuid]), padding: false)
  end

  defp clamp(limit) when is_integer(limit), do: limit |> max(1) |> min(@max_limit)
  defp clamp(_other), do: @default_limit

  defp base(opts) do
    catalogue_uuid = Keyword.fetch!(opts, :catalogue_uuid)

    from(i in Item, as: :item, where: i.catalogue_uuid == ^catalogue_uuid)
    |> by_status(Keyword.get(opts, :status), Keyword.get(opts, :include_deleted, false))
    |> by_category(Keyword.get(opts, :category_uuid))
    |> updated_since(Keyword.get(opts, :updated_since))
    |> match_text(Keyword.get(opts, :q))
  end

  # Columns only (see the moduledoc): never `data`.
  defp match_text(query, term) when is_binary(term) do
    case String.trim(term) do
      "" ->
        query

      trimmed ->
        if String.contains?(trimmed, <<0>>),
          do: where(query, [item: i], false),
          else: match_pattern(query, trimmed)
    end
  end

  defp match_text(query, _none), do: query

  defp match_pattern(query, trimmed) do
    pattern = "%#{Helpers.sanitize_like(trimmed)}%"

    where(
      query,
      [item: i],
      ilike(i.name, ^pattern) or ilike(i.description, ^pattern) or ilike(i.sku, ^pattern)
    )
  end

  defp by_status(query, "deleted", include_deleted) when include_deleted != true,
    do: where(query, [item: i], false)

  defp by_status(query, nil, true), do: query
  defp by_status(query, nil, _include_deleted), do: where(query, [item: i], i.status != "deleted")

  defp by_status(query, status, _include_deleted) do
    where(query, [item: i], i.status == ^status)
  end

  defp by_category(query, nil), do: query

  defp by_category(query, category_uuid) do
    if Helpers.uuid?(category_uuid),
      do: where(query, [item: i], i.category_uuid == ^category_uuid),
      else: where(query, [item: i], false)
  end

  defp updated_since(query, nil), do: query

  # A bound before year 1 is older than every row (and cannot be encoded): no bound.
  defp updated_since(query, %DateTime{year: year}) when year < 1, do: query

  defp updated_since(query, %DateTime{} = since) do
    since = DateTime.truncate(since, :second)
    where(query, [item: i], i.updated_at >= ^since)
  end

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, {%DateTime{} = at, uuid}) do
    at = DateTime.truncate(at, :second)

    where(
      query,
      [item: i],
      i.updated_at > ^at or (i.updated_at == ^at and i.uuid > ^uuid)
    )
  end
end
