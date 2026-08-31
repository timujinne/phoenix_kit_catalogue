defmodule PhoenixKitCatalogue.Catalogue.Search do
  @moduledoc """
  Item search — global, per-catalogue, and per-category, with optional
  scope composition (`catalogue_uuids` AND `category_uuids`).

  Matches case-insensitively against `name`, `description`, `sku`, and
  the multilang `data` JSONB. Excludes items in deleted catalogues or
  deleted categories. Uncategorized items are included unless a
  `:category_uuids` filter narrows the search.

  Public surface is re-exported from `PhoenixKitCatalogue.Catalogue`.
  """

  import Ecto.Query, warn: false

  alias PhoenixKitCatalogue.Catalogue.{Helpers, Manufacturers, Tree}
  alias PhoenixKitCatalogue.Schemas.{Catalogue, Category, Item}

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc """
  Searches items with flexible scope.

  ## Options

    * `:catalogue_uuids` — list of catalogue UUIDs to scope to. `nil` or `[]` = all.
    * `:category_uuids` — list of category UUIDs to scope to. `nil` or `[]` = all + uncategorized.
      Must contain only non-nil UUIDs; passing `[nil]` raises `ArgumentError`
      (use `:only => :uncategorized_only` for that intent).
    * `:include_descendants` — when `true` (default since V103), each
      entry in `:category_uuids` is expanded to include every descendant
      category in the nested-category tree. Pass `false` to scope
      strictly to the given UUIDs.
    * `:only` — `:uncategorized_only` restricts to items with no
      `category_uuid`; `:categorized_only` restricts to items that
      belong to some category. `nil` (default) is unrestricted.
      Combining `:uncategorized_only` with a non-empty `:category_uuids`
      is a logical contradiction and raises `ArgumentError`.
    * `:statuses` — list of item statuses to include (`"active"`,
      `"inactive"`, `"discontinued"`). `nil` or `[]` = all non-deleted
      (the historical default). Soft-deleted rows stay excluded even if
      `"deleted"` is listed. Atoms are accepted and stringified.
    * `:limit` — max results (default 50).
    * `:offset` — paging offset (default 0).
    * `:preload` — extra associations appended to the default
      `[:catalogue, category: :catalogue]`. Pass
      `[catalogue_rules: :referenced_catalogue]` for smart-pricing.
  """
  @spec search_items(String.t(), keyword()) :: [Item.t()]
  def search_items(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    preloads = Helpers.merge_preloads([:catalogue, category: :catalogue], opts)

    # Ordering note: `i.position` is intentionally NOT in the global
    # `search_items/2` order_by. `position` is per-`(catalogue_uuid,
    # category_uuid)` scope, so interleaving across catalogues by raw
    # position is meaningless. Single-catalogue search (see
    # `search_items_in_catalogue/3` below) keeps `i.position` because
    # the scope is narrow enough for it to be coherent.
    query
    |> search_items_base(opts)
    |> order_by([i, _cat, _c], asc: i.name, asc: i.uuid)
    |> limit(^limit)
    |> offset(^offset)
    |> preload(^preloads)
    |> repo().all()
    |> Manufacturers.hydrate()
  end

  @doc """
  Returns the total number of items matching `search_items/2`'s filters.
  Ignores `:limit`/`:offset`. Same scope opts as `search_items/2`.
  """
  @spec count_search_items(String.t(), keyword()) :: non_neg_integer()
  def count_search_items(query, opts \\ []) do
    query
    |> search_items_base(opts)
    |> select([i], count(i.uuid))
    |> repo().one()
  end

  @doc """
  Searches items within a specific catalogue. Convenience wrapper
  around `search_items/2` with `catalogue_uuids: [catalogue_uuid]`,
  but orders by category position first (then item name) for a stable
  walk through a catalogue's categories.

  Same `:preload` opt as `search_items/2` (extra associations appended
  to the default `[:catalogue, category: :catalogue]`).
  """
  @spec search_items_in_catalogue(Ecto.UUID.t(), String.t(), keyword()) :: [Item.t()]
  def search_items_in_catalogue(catalogue_uuid, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    opts = Keyword.put(opts, :catalogue_uuids, [catalogue_uuid])
    preloads = Helpers.merge_preloads([:catalogue, category: :catalogue], opts)

    query
    |> search_items_base(opts)
    |> order_by([i, _cat, c],
      asc_nulls_last: c.position,
      asc: i.position,
      asc: i.name,
      asc: i.uuid
    )
    |> limit(^limit)
    |> offset(^offset)
    |> preload(^preloads)
    |> repo().all()
    |> Manufacturers.hydrate()
  end

  @doc "Total match count for `search_items_in_catalogue/3`."
  @spec count_search_items_in_catalogue(Ecto.UUID.t(), String.t()) :: non_neg_integer()
  def count_search_items_in_catalogue(catalogue_uuid, query) do
    count_search_items(query, catalogue_uuids: [catalogue_uuid])
  end

  @doc """
  Searches items within a specific category. Convenience wrapper around
  `search_items/2` with `category_uuids: [category_uuid]`.
  """
  @spec search_items_in_category(Ecto.UUID.t(), String.t(), keyword()) :: [Item.t()]
  def search_items_in_category(category_uuid, query, opts \\ []) do
    opts = Keyword.put(opts, :category_uuids, [category_uuid])
    search_items(query, opts)
  end

  @doc "Total match count for `search_items_in_category/3`."
  @spec count_search_items_in_category(Ecto.UUID.t(), String.t()) :: non_neg_integer()
  def count_search_items_in_category(category_uuid, query) do
    count_search_items(query, category_uuids: [category_uuid])
  end

  @doc """
  Categories whose NAME or description matches, within one catalogue.

  Item search never covered these: searching a catalogue for a category
  it contains returned nothing, and the page looked like it had matched
  only because that category's own card happened to be on screen (Max,
  2026-08-28).

  `:parent_uuid` narrows to that category's SUBTREE (itself excluded),
  mirroring how `search_items_in_category/3` scopes items when the user
  has drilled in. Deleted categories and categories of deleted
  catalogues are excluded, as everywhere else.
  """
  @spec search_categories(Ecto.UUID.t(), String.t(), keyword()) :: [Category.t()]
  def search_categories(catalogue_uuid, query_str, opts \\ []) do
    limit = Keyword.get(opts, :limit, 25)

    case String.trim(query_str || "") do
      "" ->
        []

      trimmed ->
        pattern = "%#{Helpers.sanitize_like(trimmed)}%"

        from(c in Category,
          join: cat in Catalogue,
          on: c.catalogue_uuid == cat.uuid,
          where: c.catalogue_uuid == ^catalogue_uuid,
          where: c.status != "deleted" and cat.status != "deleted",
          # The data JSONB is what makes this work in EVERY language:
          # translations live there under language keys, so a category
          # named "Doors" in en and "Uksed" in et is found by either.
          # Only its string VALUES are searched — see
          # `Helpers.json_string_values_path/0`.
          where:
            ilike(c.name, ^pattern) or ilike(c.description, ^pattern) or
              fragment(
                "EXISTS (SELECT 1 FROM jsonb_path_query(?, '$.**') AS v WHERE jsonb_typeof(v) = 'string' AND v #>> '{}' ILIKE ?)",
                c.data,
                ^pattern
              ),
          order_by: [asc: c.name],
          limit: ^limit
        )
        |> maybe_scope_subtree(opts[:parent_uuid])
        |> repo().all()
    end
  end

  defp maybe_scope_subtree(query, nil), do: query

  defp maybe_scope_subtree(query, parent_uuid) when is_binary(parent_uuid) do
    # Tree.subtree_uuids_for/1 includes the node itself and returns raw
    # 16-byte binaries; drop the node (a search inside a category should
    # not offer to navigate to the category you are standing in).
    subtree =
      [parent_uuid]
      |> Tree.subtree_uuids_for()
      |> Enum.map(&normalize_uuid/1)
      |> Enum.reject(&(&1 in [nil, parent_uuid]))

    where(query, [c], c.uuid in ^subtree)
  end

  defp normalize_uuid(uuid) when is_binary(uuid) do
    case Ecto.UUID.load(uuid) do
      {:ok, text} -> text
      :error -> uuid
    end
  end

  @doc """
  Narrows any query with an `:item` named binding to the items a search
  term matches — name, description, SKU, and every translated string in
  the record's `data`.

  Public because the attribute filter's FACET COUNTS have to agree with
  the list beside them: a value offered as live while a search is on has
  to still be live under that search, and it can only promise that by
  asking the same question the listing asks. `nil` or a blank term is
  "no text constraint" and leaves the query alone.

  Callers pass a raw user string; trimming and LIKE-escaping happen here.
  """
  @spec match_text(Ecto.Query.t(), String.t() | nil) :: Ecto.Query.t()
  def match_text(query, term) do
    case String.trim(term || "") do
      "" -> query
      trimmed -> match_item_text(query, "%#{Helpers.sanitize_like(trimmed)}%")
    end
  end

  defp match_item_text(query, pattern) do
    where(
      query,
      [item: i],
      ilike(i.name, ^pattern) or
        ilike(i.description, ^pattern) or
        ilike(i.sku, ^pattern) or
        fragment(
          "EXISTS (SELECT 1 FROM jsonb_path_query(?, '$.**') AS v WHERE jsonb_typeof(v) = 'string' AND v #>> '{}' ILIKE ?)",
          i.data,
          ^pattern
        )
    )
  end

  # Builds the shared base query (joins + status + text-match + scope filters).
  defp search_items_base(query_str, opts) do
    validate_scope_opts!(opts)

    # Trimmed here, at the shared choke point: several input layers
    # (BrowseState among them) pass the raw string through, and a
    # trailing space must not turn a match into a miss.
    pattern = "%#{Helpers.sanitize_like(String.trim(query_str || ""))}%"
    catalogue_uuids = opts[:catalogue_uuids]
    category_uuids = expand_category_scope(opts)
    only = Keyword.get(opts, :only)
    statuses = opts[:statuses]

    from(i in Item,
      as: :item,
      join: cat in Catalogue,
      on: i.catalogue_uuid == cat.uuid,
      left_join: c in Category,
      on: i.category_uuid == c.uuid,
      where: i.status != "deleted" and cat.status != "deleted",
      where: is_nil(c.uuid) or c.status != "deleted"
    )
    |> match_item_text(pattern)
    |> maybe_scope_catalogues(catalogue_uuids)
    |> maybe_scope_categories(category_uuids)
    |> maybe_scope_only(only)
    |> maybe_scope_statuses(statuses)
    # Same `value_slugs:` the level listings take, so a search inside an
    # attribute filter stays inside it.
    |> PhoenixKitCatalogue.Catalogue.filter_by_attribute_values(opts)
  end

  # Catches two foot-guns up front so callers see a loud error instead
  # of a silently-wrong empty result set:
  #
  #   * `category_uuids: [nil]` — `WHERE category_uuid IN (NULL)` is a
  #     SQL no-op that returns no rows. The `:only => :uncategorized_only`
  #     option is the correct way to ask for "no category".
  #   * `only: :uncategorized_only` AND a non-empty `:category_uuids` —
  #     a logical contradiction (an item can't simultaneously belong to
  #     a category AND have no category). Always returns 0 rows.
  defp validate_scope_opts!(opts) do
    validate_only!(Keyword.get(opts, :only))
    validate_category_uuids!(opts[:category_uuids], Keyword.get(opts, :only))
  end

  defp validate_only!(nil), do: :ok
  defp validate_only!(:uncategorized_only), do: :ok
  defp validate_only!(:categorized_only), do: :ok

  defp validate_only!(other),
    do: raise(ArgumentError, "unknown :only value #{inspect(other)}")

  defp validate_category_uuids!(nil, _only), do: :ok
  defp validate_category_uuids!([], _only), do: :ok

  defp validate_category_uuids!(uuids, only) when is_list(uuids) do
    if Enum.any?(uuids, &is_nil/1) do
      raise ArgumentError,
            "category_uuids must contain non-nil UUIDs; pass `nil` or `[]` " <>
              "for unscoped, or `only: :uncategorized_only` for items without a category"
    end

    if only == :uncategorized_only do
      raise ArgumentError,
            "only: :uncategorized_only cannot be combined with a non-empty " <>
              "category_uuids — the two scopes contradict each other"
    end

    :ok
  end

  # Expands `:category_uuids` through the V103 nested-category tree so
  # filtering by "Kitchen" also matches items in "Kitchen / Frames".
  # `:include_descendants` defaults to `true`; callers can opt out for
  # the literal-set semantics by passing `false`.
  defp expand_category_scope(opts) do
    case opts[:category_uuids] do
      nil ->
        nil

      [] ->
        []

      uuids when is_list(uuids) ->
        if Keyword.get(opts, :include_descendants, true) do
          Tree.subtree_uuids_for(uuids)
        else
          uuids
        end
    end
  end

  defp maybe_scope_catalogues(query, uuids) when uuids in [nil, []], do: query

  defp maybe_scope_catalogues(query, uuids) when is_list(uuids) do
    from([i, _cat, _c] in query, where: i.catalogue_uuid in ^uuids)
  end

  defp maybe_scope_categories(query, uuids) when uuids in [nil, []], do: query

  defp maybe_scope_categories(query, uuids) when is_list(uuids) do
    from([i, _cat, _c] in query, where: i.category_uuid in ^uuids)
  end

  defp maybe_scope_only(query, nil), do: query

  defp maybe_scope_only(query, :uncategorized_only) do
    from([i, _cat, _c] in query, where: is_nil(i.category_uuid))
  end

  defp maybe_scope_only(query, :categorized_only) do
    from([i, _cat, _c] in query, where: not is_nil(i.category_uuid))
  end

  defp maybe_scope_statuses(query, statuses) when statuses in [nil, []], do: query

  defp maybe_scope_statuses(query, status) when is_binary(status) or is_atom(status) do
    maybe_scope_statuses(query, [status])
  end

  defp maybe_scope_statuses(query, statuses) when is_list(statuses) do
    statuses = Enum.map(statuses, &to_string/1)
    from([i, _cat, _c] in query, where: i.status in ^statuses)
  end
end
