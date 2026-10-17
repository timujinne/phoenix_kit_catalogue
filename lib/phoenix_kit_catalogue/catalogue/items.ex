defmodule PhoenixKitCatalogue.Catalogue.Items do
  @moduledoc """
  Items — listing, paging and counts, CRUD, trash / restore / permanent
  delete, moves, positions, the bulk item actions and pricing.

  Public surface is re-exported from `PhoenixKitCatalogue.Catalogue` via
  `defdelegate`, so callers keep using the canonical context module.
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.Modules.Storage.ResourceFolders
  alias PhoenixKit.Utils.Values
  alias PhoenixKitCatalogue.Catalogue.{ActivityLog, Helpers, Manufacturers, PubSub, Shared, Trash}
  alias PhoenixKitCatalogue.MediaFolders
  alias PhoenixKitCatalogue.Schemas.{Catalogue, Category, Item, ItemAttributeSet}

  require Logger

  @reorder_max_uuids Shared.reorder_max_uuids()

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # What an `.updated` entry reports as changed, per resource. The activity
  # feed used to say only that a row had been updated, naming it but never
  # what moved (boss via Max, 2026-09-20). `ActivityLog.changed_fields/3`
  # turns these into `from`/`to` pairs, which core renders as `old → new`.
  #
  # `description` is tracked but records only THAT it changed — see
  # `ActivityLog`'s `@flag_only_fields`. `slug` is a per-language map and is
  # reported per language (`slug.en-US`), so a changed slug leaves the old one
  # in the log. A move is not here at all; it has its own action
  # (`item.moved`, `category.moved`, `catalogue.moved_to_folder`) carrying both
  # ends.
  @item_logged_fields [
    :name,
    :sku,
    :base_price,
    :markup_percentage,
    :discount_percentage,
    :unit,
    :item_type,
    :status,
    :default_value,
    :default_unit,
    :description,
    :slug
  ]

  # Slug projection tables read by `get_item_by_slug/3` / `get_category_by_slug/3`
  # (owned by `PhoenixKitCatalogue.Catalogue.Slugs`'s generation rule, kept in
  # sync by the `trg_cat_item_slugs` / `trg_cat_category_slugs` triggers).
  @item_slugs_table "phoenix_kit_cat_item_slugs"

  # Same idea for items, scoped by `(catalogue_uuid, category_uuid)`.
  # Only fires when both scope fields are already in attrs — otherwise
  # we don't have enough information to compute the next position, so
  # we leave it at the schema default (0).
  defp maybe_put_item_position(attrs) when is_map(attrs) do
    cond do
      Helpers.has_attr?(attrs, :position) ->
        attrs

      Helpers.has_attr?(attrs, :catalogue_uuid) ->
        catalogue_uuid = Helpers.fetch_attr(attrs, :catalogue_uuid)

        category_uuid =
          if Helpers.has_attr?(attrs, :category_uuid),
            do: attrs |> Helpers.fetch_attr(:category_uuid) |> Values.blank_to_nil(),
            else: nil

        if is_binary(catalogue_uuid) do
          Helpers.put_attr(attrs, :position, next_item_position(catalogue_uuid, category_uuid))
        else
          attrs
        end

      true ->
        attrs
    end
  end

  @doc """
  Lists a page of items for a single category, in the admin's Manual
  order by default (`:sort_by`, `:sort_dir` select another).

  Used by the infinite-scroll detail view; returns at most `:limit`
  items starting at `:offset`. Preloads `:catalogue` and `:manufacturer`
  so the table cell renderers can access them without extra queries.

  DIRECT items only — never the subtree. The detail page's "include
  subcategory items" toggle is a SEARCH refinement (Max, 2026-08-30:
  it "should only do something when searching"); the browse list always
  shows the level you are standing on. Widening a subtree search is
  `Catalogue.search_items_in_category/3`'s `:include_descendants`.

  ## Options

    * `:mode` — `:active` (default, excludes deleted items) or `:deleted`
      (only deleted items)
    * `:offset` — default `0`
    * `:limit` — default `50`
    * `:preload` — extra associations appended to the default
      `[:catalogue]`.
    * `:item_types` — only items of these EFFECTIVE types
      (`filter_by_item_types/2`); `nil`/`[]` = all.
  """
  @spec list_items_for_category_paged(Ecto.UUID.t(), keyword()) :: [Item.t()]
  def list_items_for_category_paged(category_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)
    offset = Keyword.get(opts, :offset, 0)
    limit = Keyword.get(opts, :limit, 50)
    preloads = Helpers.merge_preloads([:catalogue], opts)

    query =
      from(i in Item,
        as: :item,
        where: i.category_uuid == ^category_uuid,
        offset: ^offset,
        limit: ^limit,
        preload: ^preloads
      )

    query
    |> filter_by_attribute_values(opts)
    |> filter_by_item_types(opts)
    |> apply_item_status_filter(opts, mode)
    |> apply_item_order(opts)
    |> repo().all()
    |> Manufacturers.hydrate()
  end

  @doc """
  Lists a page of a catalogue's items ACROSS all its categories — the
  detail page's Items mode since category drilling was removed (Max,
  2026-08-29): with no level to stand in, the mode lists the whole
  catalogue. Same options as `list_items_for_category_paged/2`, plus
  `:outside_trashed_categories` — `true` skips items inside a trashed
  category, which the Deleted tab counts on that category's card instead.
  The default (position) order is the DOCUMENT order — category position,
  then item position — the same walk the export uses.
  """
  @spec list_catalogue_items_paged(Ecto.UUID.t(), keyword()) :: [Item.t()]
  def list_catalogue_items_paged(catalogue_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)
    offset = Keyword.get(opts, :offset, 0)
    limit = Keyword.get(opts, :limit, 50)
    preloads = Helpers.merge_preloads([:catalogue, category: :catalogue], opts)

    query =
      from(i in Item,
        as: :item,
        left_join: c in Category,
        on: i.category_uuid == c.uuid,
        where: i.catalogue_uuid == ^catalogue_uuid,
        offset: ^offset,
        limit: ^limit,
        preload: ^preloads
      )

    query
    |> filter_by_attribute_values(opts)
    |> filter_by_item_types(opts)
    |> apply_item_status_filter(opts, mode)
    |> maybe_outside_trashed_categories(opts)
    |> apply_catalogue_item_order(opts)
    |> repo().all()
    |> Manufacturers.hydrate()
  end

  @doc "Total item count for `list_catalogue_items_paged/2`'s filters."
  @spec count_items_for_catalogue(Ecto.UUID.t(), keyword()) :: non_neg_integer()
  def count_items_for_catalogue(catalogue_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)

    from(i in Item, as: :item, where: i.catalogue_uuid == ^catalogue_uuid)
    |> filter_by_attribute_values(opts)
    |> filter_by_item_types(opts)
    |> apply_item_status_filter(opts, mode)
    |> maybe_outside_trashed_categories(opts)
    |> repo().aggregate(:count)
  end

  defp maybe_outside_trashed_categories(query, opts) do
    if Keyword.get(opts, :outside_trashed_categories, false),
      do: Trash.outside_trashed_categories(query),
      else: query
  end

  @doc "Per-status item counts for a whole catalogue: `%{\"active\" => n, …}`."
  @spec item_status_counts_for_catalogue(Ecto.UUID.t()) :: %{
          optional(String.t()) => non_neg_integer()
        }
  def item_status_counts_for_catalogue(catalogue_uuid) do
    from(i in Item,
      where: i.catalogue_uuid == ^catalogue_uuid,
      group_by: i.status,
      select: {i.status, count(i.uuid)}
    )
    |> repo().all()
    |> Map.new()
  end

  # Position on a catalogue-wide list means the DOCUMENT order (category
  # position, then item position) — bare `i.position` interleaves
  # per-category sequences into noise. Every other sort defers to the
  # shared whitelist.
  defp apply_catalogue_item_order(query, opts) do
    case Keyword.get(opts, :sort_by, :position) do
      :position ->
        order_by(query, [i, c],
          asc_nulls_last: c.position,
          asc: i.position,
          asc: i.name,
          asc: i.uuid
        )

      _ ->
        apply_item_order(query, opts)
    end
  end

  # Status filter shared by the item list/count queries. `:status` (an
  # exact status string like `"discontinued"`) takes precedence and filters
  # to that one status — used by the detail page's per-status tabs. Without
  # it, the coarser `:mode` applies: `:deleted` → deleted only, anything
  # else → all non-deleted (used for the category-card "N items" totals).
  defp apply_item_status_filter(query, opts, mode) do
    cond do
      status = Keyword.get(opts, :status) ->
        where(query, [i], i.status == ^status)

      mode == :deleted ->
        where(query, [i], i.status == "deleted")

      true ->
        where(query, [i], i.status != "deleted")
    end
  end

  @doc """
  Lists a page of uncategorized items for a catalogue, in the admin's
  Manual order by default.

  Same shape as `list_items_for_category_paged/2`, but for items where
  `category_uuid IS NULL AND catalogue_uuid = ?`. Used as the final
  section of the infinite-scroll detail view.

  ## Options

    * `:mode` — `:active` (default) or `:deleted`
    * `:offset` — default `0`
    * `:limit` — default `50`
    * `:preload` — extra associations appended to the default
      `[:catalogue]`.
    * `:item_types` — only items of these EFFECTIVE types
      (`filter_by_item_types/2`); `nil`/`[]` = all.
  """
  @spec list_uncategorized_items_paged(Ecto.UUID.t(), keyword()) :: [Item.t()]
  def list_uncategorized_items_paged(catalogue_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)
    offset = Keyword.get(opts, :offset, 0)
    limit = Keyword.get(opts, :limit, 50)
    preloads = Helpers.merge_preloads([:catalogue], opts)

    query =
      from(i in Item,
        as: :item,
        where: i.catalogue_uuid == ^catalogue_uuid and is_nil(i.category_uuid),
        offset: ^offset,
        limit: ^limit,
        preload: ^preloads
      )

    query
    |> filter_by_attribute_values(opts)
    |> filter_by_item_types(opts)
    |> apply_item_status_filter(opts, mode)
    |> apply_item_order(opts)
    |> repo().all()
    |> Manufacturers.hydrate()
  end

  # ── Item sort + strategy reorder ─────────────────────────────────

  # Sortable item columns. `:position` is the manual-order default
  # (matches the pre-sort behavior); `name` sorts on the raw `name`
  # column (multilang lives in `data` JSONB, not sorted here).
  @item_sort_fields ~w(position name sku base_price inserted_at status)a

  # Applies `:sort_by` / `:sort_dir` from `opts` to an Item query. Every
  # order ends with `asc: i.uuid` so paging is deterministic across ties.
  defp apply_item_order(query, opts) do
    sort_by = Keyword.get(opts, :sort_by, :position)
    sort_dir = if Keyword.get(opts, :sort_dir) == :desc, do: :desc, else: :asc
    item_order_by(query, sort_by, sort_dir)
  end

  defp item_order_by(query, :position, _dir),
    do: order_by(query, [i], asc: i.position, asc: i.name, asc: i.uuid)

  defp item_order_by(query, field, dir) when field in @item_sort_fields,
    do: order_by(query, [i], [{^dir, field(i, ^field)}, {:asc, i.uuid}])

  defp item_order_by(query, _field, _dir),
    do: order_by(query, [i], asc: i.position, asc: i.name, asc: i.uuid)

  @doc """
  Counts the uncategorized items of a catalogue (items with
  `category_uuid IS NULL`). Used to decide whether the infinite-scroll
  detail view needs to show an "Uncategorized" card at all.

  ## Options

    * `:mode` — `:active` (default, all but deleted) or `:deleted`
    * `:status` — only items with this exact status; wins over `:mode`
    * `:value_slugs` — only items carrying all of these attribute value
      slugs (`filter_by_attribute_values/2`); `[]` = all.
    * `:item_types` — only items of these EFFECTIVE types
      (`filter_by_item_types/2`); `nil`/`[]` = all.
  """
  @spec uncategorized_count_for_catalogue(Ecto.UUID.t(), keyword()) :: non_neg_integer()
  def uncategorized_count_for_catalogue(catalogue_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)

    query =
      from(i in Item,
        as: :item,
        where: i.catalogue_uuid == ^catalogue_uuid and is_nil(i.category_uuid)
      )

    query
    |> filter_by_attribute_values(opts)
    |> filter_by_item_types(opts)
    |> apply_item_status_filter(opts, mode)
    |> repo().aggregate(:count)
  end

  @doc """
  Narrows an item query to the items carrying ALL of the given attribute
  VALUE slugs — "the blue doors", and with two slugs "the blue oak doors"
  (Max, 2026-08-28).

  The slugs are what an item's attachment row stores in
  `data["selected_value_slugs"]`, so this reads the selection the item
  form writes. AND semantics: each slug adds its own EXISTS, because
  narrowing is what a filter is for — an OR would widen the list as you
  pick more.

  Pass `value_slugs: [...]` to the paged listings and the counts; an
  empty list is no filter.
  """
  @spec filter_by_attribute_values(Ecto.Query.t(), keyword()) :: Ecto.Query.t()
  def filter_by_attribute_values(query, opts) do
    opts
    |> Keyword.get(:value_slugs, [])
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.reduce(query, fn slug, acc ->
      # `?` is the JSONB "key/element exists" operator; doubled here
      # because Ecto reads a single one as a parameter placeholder.
      from(i in acc,
        where:
          exists(
            from(a in ItemAttributeSet,
              where: a.item_uuid == parent_as(:item).uuid,
              where: fragment("jsonb_typeof(? -> 'selected_value_slugs') = 'array'", a.data),
              where: fragment("? -> 'selected_value_slugs' \\? ?", a.data, ^slug),
              select: 1
            )
          )
      )
    end)
  end

  @doc """
  Narrows an item query (it must carry the `:item` named binding) to the
  items whose EFFECTIVE type is one of `opts[:item_types]` — the item's own
  `item_type`, or its catalogue's when it has none (an item without a
  catalogue counts as goods). The SQL twin of `Item.effective_type/2`.

  Pass `item_types: ["goods"]` (strings or atoms) to the listings, the
  search and the counts; `nil` or `[]` is no filter.
  """
  @spec filter_by_item_types(Ecto.Query.t(), keyword()) :: Ecto.Query.t()
  def filter_by_item_types(query, opts) do
    case opts |> Keyword.get(:item_types) |> List.wrap() |> Enum.map(&to_string/1) do
      [] ->
        query

      types ->
        orphan_goods? = "goods" in types

        catalogue_has_type =
          from(c in Catalogue,
            where: c.uuid == parent_as(:item).catalogue_uuid and c.item_type in ^types,
            select: 1
          )

        where(
          query,
          [item: i],
          i.item_type in ^types or
            (is_nil(i.item_type) and
               (exists(subquery(catalogue_has_type)) or
                  (is_nil(i.catalogue_uuid) and type(^orphan_goods?, :boolean))))
        )
    end
  end

  @doc """
  Counts items in a single category (ignoring its catalogue scope).

  Used by the infinite-scroll detail view to show the total under each
  category header (the number in `"Category Name (N items)"`) without
  loading the items themselves.

  Counts the DIRECT items only, matching `list_items_for_category_paged/2`
  — the number under a header has to be the number of rows the header
  opens onto.

  ## Options

    * `:mode` — `:active` (default) or `:deleted`
    * `:item_types` — only items of these EFFECTIVE types
      (`filter_by_item_types/2`); `nil`/`[]` = all.
  """
  @spec item_count_for_category(Ecto.UUID.t(), keyword()) :: non_neg_integer()
  def item_count_for_category(category_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)

    query = from(i in Item, as: :item, where: i.category_uuid == ^category_uuid)

    query
    |> filter_by_attribute_values(opts)
    |> filter_by_item_types(opts)
    |> apply_item_status_filter(opts, mode)
    |> repo().aggregate(:count)
  end

  @doc """
  Returns `%{status => count}` for the items in a single category, across
  every status (`"active"`, `"inactive"`, `"discontinued"`, `"deleted"`).
  One grouped query — drives the detail page's per-status item tabs.
  Missing statuses are simply absent from the map (treat as 0).
  """
  @spec item_status_counts_for_category(Ecto.UUID.t()) :: %{String.t() => non_neg_integer()}
  def item_status_counts_for_category(category_uuid) do
    from(i in Item,
      where: i.category_uuid == ^category_uuid,
      group_by: i.status,
      select: {i.status, count(i.uuid)}
    )
    |> repo().all()
    |> Map.new()
  end

  @doc """
  `%{status => count}` for a catalogue's uncategorized items (`category_uuid
  IS NULL`), across every status. Per-status sibling of
  `uncategorized_count_for_catalogue/2`.
  """
  @spec item_status_counts_for_uncategorized(Ecto.UUID.t()) :: %{String.t() => non_neg_integer()}
  def item_status_counts_for_uncategorized(catalogue_uuid) do
    from(i in Item,
      where: i.catalogue_uuid == ^catalogue_uuid and is_nil(i.category_uuid),
      group_by: i.status,
      select: {i.status, count(i.uuid)}
    )
    |> repo().all()
    |> Map.new()
  end

  @doc """
  Returns a map of `%{category_uuid => item_count}` for every category
  in a catalogue in a single grouped query. Used by the infinite-scroll
  detail view so each category card can show its total count without a
  separate per-card round trip.

  Items without a category (uncategorized) are excluded here — use
  `uncategorized_count_for_catalogue/2` for those.

  ## Options

    * `:mode` — `:active` (default) or `:deleted`
    * `:item_types` — only items of these EFFECTIVE types
      (`filter_by_item_types/2`); `nil`/`[]` = all.
  """
  @spec item_counts_by_category_for_catalogue(Ecto.UUID.t(), keyword()) :: %{
          Ecto.UUID.t() => non_neg_integer()
        }
  def item_counts_by_category_for_catalogue(catalogue_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)

    query =
      from(i in Item,
        as: :item,
        where: i.catalogue_uuid == ^catalogue_uuid and not is_nil(i.category_uuid),
        group_by: i.category_uuid,
        select: {i.category_uuid, count(i.uuid)}
      )

    query =
      case mode do
        :active -> where(query, [i], i.status != "deleted")
        :deleted -> where(query, [i], i.status == "deleted")
      end

    query
    |> filter_by_item_types(opts)
    |> repo().all()
    |> Map.new()
  end

  @doc """
  Returns a map of `%{category_uuid => [item_uuid]}` for the LIVE (not trashed)
  items directly in the given categories, each list sorted; a category without
  live items has no key. The identity behind `item_counts_by_category_for_catalogue/2`,
  for a caller that has to tell two sets of the same size apart.
  """
  @spec live_item_uuids_by_category([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => [Ecto.UUID.t()]}
  def live_item_uuids_by_category(category_uuids) do
    from(i in Item,
      where: i.category_uuid in ^category_uuids and i.status != "deleted",
      select: {i.category_uuid, i.uuid}
    )
    |> repo().all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {category_uuid, uuids} -> {category_uuid, Enum.sort(uuids)} end)
  end

  @doc """
  Returns the next available `position` for a new item within a scope.

  Items are scoped to `(catalogue_uuid, category_uuid)`. Pass
  `category_uuid: nil` for the uncategorized bucket of a catalogue.
  """
  @spec next_item_position(Ecto.UUID.t(), Ecto.UUID.t() | nil) :: integer()
  def next_item_position(catalogue_uuid, category_uuid)
      when is_binary(catalogue_uuid) do
    query =
      from(i in Item,
        where: i.catalogue_uuid == ^catalogue_uuid,
        select: max(i.position)
      )

    query =
      case category_uuid do
        nil -> where(query, [i], is_nil(i.category_uuid))
        uuid -> where(query, [i], i.category_uuid == ^uuid)
      end

    case repo().one(query) do
      nil -> 1
      n -> n + 1
    end
  end

  @doc """
  Re-indexes the items inside a `(catalogue_uuid, category_uuid)`
  bucket. Pass `category_uuid: nil` to reorder the uncategorized
  bucket. Behaves like `reorder_categories/4`: validates scope, runs
  two passes inside a transaction, logs an activity row.

  UUIDs that don't belong to the scope abort with
  `{:error, :wrong_scope}` so a stale DOM can't bleed reorder writes
  across catalogues.
  """
  @spec reorder_items(Ecto.UUID.t(), Ecto.UUID.t() | nil, [Ecto.UUID.t()], keyword()) ::
          :ok | {:error, :wrong_scope | :too_many_uuids | term()}
  def reorder_items(catalogue_uuid, category_uuid, ordered_uuids, opts \\ [])
      when is_binary(catalogue_uuid) and is_list(ordered_uuids) do
    case validate_and_apply_item_reorder(catalogue_uuid, category_uuid, ordered_uuids) do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        unique_uuids = Helpers.dedupe_keep_last(ordered_uuids)

        Shared.log_activity(%{
          action: "item.reordered",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "item",
          resource_uuid: List.first(unique_uuids),
          parent_catalogue_uuid: catalogue_uuid,
          metadata: %{
            "category_uuid" => category_uuid,
            "count" => count
          }
        })

        :ok

      {:error, reason} when reason in [:too_many_uuids, :wrong_scope] ->
        Shared.log_reorder_rejected(
          :item,
          reason,
          length(ordered_uuids),
          catalogue_uuid,
          opts
        )

        {:error, reason}

      {:error, reason} ->
        Shared.log_reorder_db_error(
          :item,
          Helpers.dedupe_keep_last(ordered_uuids),
          catalogue_uuid,
          opts,
          category_uuid: category_uuid
        )

        {:error, reason}
    end
  end

  # Validates scope + applies the two-pass write inside its own
  # transaction. Returns `{:ok, count}` on success or `{:error, reason}`
  # without any logging — callers (incl. a future in-transaction caller)
  # handle logging outside the transaction so audit rows survive a
  # rollback.
  defp validate_and_apply_item_reorder(catalogue_uuid, _category_uuid, ordered_uuids)
       when is_binary(catalogue_uuid) and is_list(ordered_uuids) and
              length(ordered_uuids) > @reorder_max_uuids,
       do: {:error, :too_many_uuids}

  defp validate_and_apply_item_reorder(catalogue_uuid, category_uuid, ordered_uuids)
       when is_binary(catalogue_uuid) and is_list(ordered_uuids) do
    unique_uuids = Helpers.dedupe_keep_last(ordered_uuids)

    case item_scope_check(catalogue_uuid, category_uuid, unique_uuids) do
      :empty ->
        {:ok, 0}

      {:ok, valid} ->
        unique_uuids
        |> Enum.filter(&MapSet.member?(valid, &1))
        |> then(&commit_item_positions(catalogue_uuid, &1))

      {:error, _} = err ->
        err
    end
  end

  # The catalogue's trash/restore lock, as `commit_category_positions/2`.
  defp commit_item_positions(catalogue_uuid, unique_uuids) do
    reorder = fn ->
      Trash.lock_catalogue!(catalogue_uuid)
      write_item_positions(unique_uuids)
    end

    case repo().transaction(reorder) do
      {:ok, _} -> {:ok, length(unique_uuids)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Deleted items are excluded up front: a uuid captured in a client-side
  # selection (or stale DOM order) that gets trashed in another tab before
  # the reorder lands must not be re-slotted into the active sequence.
  # Mirrors the active-only invariant `scope_items/2` enforces on the
  # `:all` path. Returns the in-scope, non-deleted uuids as a MapSet so the
  # caller can drop them while preserving the requested order.
  defp item_scope_check(catalogue_uuid, category_uuid, unique_uuids) do
    rows =
      from(i in Item, where: i.uuid in ^unique_uuids and i.status != "deleted")
      |> repo().all()

    cond do
      rows == [] ->
        :empty

      not Enum.all?(rows, fn i ->
        i.catalogue_uuid == catalogue_uuid and i.category_uuid == category_uuid
      end) ->
        {:error, :wrong_scope}

      true ->
        {:ok, MapSet.new(rows, & &1.uuid)}
    end
  end

  # Future (perf): collapse the two-pass loop below to a single
  # `UPDATE phoenix_kit_cat_items SET position = v.pos
  #   FROM (VALUES (uuid, pos), …) AS v(uuid, pos)
  #   WHERE phoenix_kit_cat_items.uuid = v.uuid`
  # round-trip per scope. Trigger to revisit: `:reorder_max_uuids`
  # config bumped past 1000, or a unique index on
  # `(catalogue_uuid, category_uuid, position)` is added.
  defp write_item_positions(unique_uuids) do
    # Written (and so locked) in uuid order rather than the caller's.
    pairs = unique_uuids |> Enum.with_index(1) |> Enum.sort_by(fn {uuid, _idx} -> uuid end)

    Enum.each(pairs, fn {uuid, idx} ->
      from(i in Item, where: i.uuid == ^uuid)
      |> repo().update_all(set: [position: -idx])
    end)

    Enum.each(pairs, fn {uuid, idx} ->
      from(i in Item, where: i.uuid == ^uuid)
      |> repo().update_all(set: [position: idx])
    end)

    :ok
  end

  @valid_item_reorder_strategies ~w(name_asc name_desc created_asc created_desc reverse)a

  @doc """
  Bulk-reorders the items in one `(catalogue_uuid, category_uuid)` scope
  by a strategy (mirrors `PhoenixKitProjects.reorder_tasks_by/3`).

  `category_uuid` is normalized via `normalize_category_uuid/1` (`nil` /
  `:uncategorized` → the uncategorized scope). `scope`:

    * `:all` — reindex the whole scope `1..N` in strategy order.
    * a list of item UUIDs — permute those rows in place into their own
      (sorted) position slots. Requires distinct positions; otherwise
      `{:error, :duplicate_positions}` (run an `:all` reorder first to
      normalise — catalogue items default to `position: 0`).

  Strategies: `:name_asc` / `:name_desc` (raw `name` column),
  `:created_asc` / `:created_desc`, `:reverse`.
  """
  @spec reorder_items_by(
          Ecto.UUID.t(),
          Ecto.UUID.t() | :uncategorized | nil,
          atom(),
          :all | [Ecto.UUID.t()],
          keyword()
        ) ::
          :ok
          | {:error,
             :invalid_strategy
             | :duplicate_positions
             | :uuids_outside_scope
             | :too_many_uuids
             | term()}
  def reorder_items_by(catalogue_uuid, category_uuid, strategy, scope, opts \\ [])

  def reorder_items_by(_catalogue_uuid, _category_uuid, strategy, _scope, _opts)
      when strategy not in @valid_item_reorder_strategies,
      do: {:error, :invalid_strategy}

  def reorder_items_by(catalogue_uuid, category_uuid, strategy, :all, opts)
      when is_binary(catalogue_uuid) do
    cat_uuid = normalize_category_uuid(category_uuid)
    ordered = catalogue_uuid |> scope_items(cat_uuid) |> item_strategy_order(strategy)

    cond do
      ordered == [] ->
        :ok

      length(ordered) > @reorder_max_uuids ->
        {:error, :too_many_uuids}

      true ->
        finish_item_reorder_by(
          repo().transaction(fn ->
            Trash.lock_catalogue!(catalogue_uuid)
            write_item_positions(ordered)
          end),
          catalogue_uuid,
          cat_uuid,
          strategy,
          :all,
          ordered,
          opts
        )
    end
  end

  def reorder_items_by(catalogue_uuid, category_uuid, strategy, uuids, opts)
      when is_binary(catalogue_uuid) and is_list(uuids) do
    cat_uuid = normalize_category_uuid(category_uuid)
    unique = Helpers.dedupe_keep_last(uuids)

    if length(unique) > @reorder_max_uuids do
      {:error, :too_many_uuids}
    else
      case item_scope_check(catalogue_uuid, cat_uuid, unique) do
        :empty ->
          :ok

        {:error, :wrong_scope} ->
          {:error, :uuids_outside_scope}

        {:ok, valid} ->
          kept = Enum.filter(unique, &MapSet.member?(valid, &1))
          permute_items_by(catalogue_uuid, cat_uuid, kept, strategy, opts)
      end
    end
  end

  # Permute the selected rows into their own (sorted) position slots.
  defp permute_items_by(catalogue_uuid, cat_uuid, unique, strategy, opts) do
    rows = from(i in Item, where: i.uuid in ^unique) |> repo().all()
    slots = rows |> Enum.map(& &1.position) |> Enum.sort()

    if slots != Enum.uniq(slots) do
      {:error, :duplicate_positions}
    else
      pairs = Enum.zip(item_strategy_order(rows, strategy), slots)

      finish_item_reorder_by(
        repo().transaction(fn ->
          Trash.lock_catalogue!(catalogue_uuid)
          write_item_permutation(pairs)
        end),
        catalogue_uuid,
        cat_uuid,
        strategy,
        :selected,
        Enum.map(pairs, fn {uuid, _} -> uuid end),
        opts
      )
    end
  end

  defp finish_item_reorder_by({:ok, _}, catalogue_uuid, cat_uuid, strategy, mode, ordered, opts) do
    Shared.log_activity(%{
      action: "item.reordered",
      mode: "manual",
      actor_uuid: opts[:actor_uuid],
      resource_type: "item",
      resource_uuid: List.first(ordered),
      parent_catalogue_uuid: catalogue_uuid,
      metadata: %{
        "category_uuid" => cat_uuid,
        "strategy" => Atom.to_string(strategy),
        "scope" => Atom.to_string(mode),
        "count" => length(ordered)
      }
    })

    :ok
  end

  defp finish_item_reorder_by(
         {:error, reason},
         catalogue_uuid,
         cat_uuid,
         _strategy,
         _mode,
         ordered,
         opts
       ) do
    Shared.log_reorder_db_error(:item, ordered, catalogue_uuid, opts, category_uuid: cat_uuid)
    {:error, reason}
  end

  defp scope_items(catalogue_uuid, nil) do
    from(i in Item,
      where:
        i.catalogue_uuid == ^catalogue_uuid and is_nil(i.category_uuid) and i.status != "deleted"
    )
    |> repo().all()
  end

  defp scope_items(catalogue_uuid, category_uuid) do
    from(i in Item,
      where:
        i.catalogue_uuid == ^catalogue_uuid and i.category_uuid == ^category_uuid and
          i.status != "deleted"
    )
    |> repo().all()
  end

  # Writes arbitrary {uuid, position} pairs two-phase (negatives, then the
  # final positives) to dodge transient unique collisions; uuid-sorted
  # write order is deadlock-safe.
  defp write_item_permutation(pairs) do
    write_order = Enum.sort_by(pairs, fn {uuid, _pos} -> uuid end)

    write_order
    |> Enum.with_index(1)
    |> Enum.each(fn {{uuid, _pos}, idx} ->
      from(i in Item, where: i.uuid == ^uuid) |> repo().update_all(set: [position: -idx])
    end)

    Enum.each(write_order, fn {uuid, pos} ->
      from(i in Item, where: i.uuid == ^uuid) |> repo().update_all(set: [position: pos])
    end)

    :ok
  end

  # Maps rows → uuids in the order a strategy implies. uuid pre-sort is a
  # stable tiebreaker for equal names / same-second inserts.
  defp item_strategy_order(rows, :reverse),
    do: rows |> Enum.sort_by(& &1.position) |> Enum.reverse() |> Enum.map(& &1.uuid)

  defp item_strategy_order(rows, :name_asc),
    do:
      rows
      |> Enum.sort_by(& &1.uuid)
      |> Enum.sort_by(&downcase_or_empty(&1.name))
      |> Enum.map(& &1.uuid)

  defp item_strategy_order(rows, :name_desc),
    do:
      rows
      |> Enum.sort_by(& &1.uuid, :desc)
      |> Enum.sort_by(&downcase_or_empty(&1.name), :desc)
      |> Enum.map(& &1.uuid)

  # The DateTime sorter, not term order — structurally, DateTime structs
  # compare field-alphabetically (day before month), so a bare
  # `& &1.inserted_at` key put Jan 2nd AFTER Feb 1st. The category-side
  # strategies (`order_categories_for_strategy/2`) already sort this way.
  defp item_strategy_order(rows, :created_asc),
    do:
      rows
      |> Enum.sort_by(& &1.uuid)
      |> Enum.sort_by(& &1.inserted_at, {:asc, DateTime})
      |> Enum.map(& &1.uuid)

  defp item_strategy_order(rows, :created_desc),
    do:
      rows
      |> Enum.sort_by(& &1.uuid, :desc)
      |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
      |> Enum.map(& &1.uuid)

  defp downcase_or_empty(nil), do: ""
  defp downcase_or_empty(s) when is_binary(s), do: String.downcase(s)

  @doc """
  Normalizes a node reference to an item `category_uuid`: `nil` /
  `:uncategorized` / `"uncategorized"` → `nil` (the uncategorized scope);
  `%Category{}` → its uuid; a uuid string passes through. Shared by the
  detail LV and `reorder_items_by/5` so the uncategorized bucket always
  reaches scope checks as `category_uuid: nil`.
  """
  @spec normalize_category_uuid(nil | :uncategorized | String.t() | Category.t()) ::
          Ecto.UUID.t() | nil
  def normalize_category_uuid(nil), do: nil
  def normalize_category_uuid(:uncategorized), do: nil
  def normalize_category_uuid("uncategorized"), do: nil
  def normalize_category_uuid(%Category{uuid: uuid}), do: uuid
  def normalize_category_uuid(uuid) when is_binary(uuid), do: uuid

  @doc """
  Lists all non-deleted items across all catalogues in the admin's
  Manual document order — catalogue (position, name), category
  position, then item position and name — the same chain
  `search_items/2` defaults to.

  ALL of them: the catalogue join is a LEFT join, so an item whose
  catalogue row is gone still lists (last). `catalogue_uuid` is
  nullable and its FK is `ON DELETE SET NULL`, so hard-deleting a
  catalogue (`delete_catalogue/2`) orphans its items rather than
  removing them — and this function is what the Translations page
  enumerates items with, where a silently missing row reads as
  "already translated".

  Preloads category (with catalogue) and manufacturer.

  ## Options

    * `:status` — filter by status (e.g. `"active"`, `"inactive"`).
      When nil (default), returns all non-deleted items.
    * `:limit` — max results to return (default: no limit)
    * `:item_types` — only items of these EFFECTIVE types, e.g.
      `["goods"]` (`filter_by_item_types/2`); `nil`/`[]` = all.

  ## Examples

      Catalogue.list_items()                          # all non-deleted
      Catalogue.list_items(status: "active")          # only active
      Catalogue.list_items(limit: 100)                # first 100
  """
  @spec list_items(keyword()) :: [Item.t()]
  def list_items(opts \\ []) do
    query =
      from(i in Item,
        as: :item,
        left_join: cat in Catalogue,
        on: i.catalogue_uuid == cat.uuid,
        left_join: c in Category,
        on: i.category_uuid == c.uuid,
        order_by: [
          asc_nulls_last: cat.position,
          asc: fragment("lower(?)", cat.name),
          asc: cat.uuid,
          asc_nulls_last: c.position,
          asc: i.position,
          asc: i.name,
          asc: i.uuid
        ],
        preload: [:catalogue, category: :catalogue]
      )

    query =
      case Keyword.get(opts, :status) do
        nil -> where(query, [i], i.status != "deleted")
        status -> where(query, [i], i.status == ^status)
      end

    query =
      case Keyword.get(opts, :limit) do
        nil -> query
        limit -> limit(query, ^limit)
      end

    query |> filter_by_item_types(opts) |> repo().all() |> Manufacturers.hydrate()
  end

  @doc """
  Lists non-deleted items for a category, ordered by position then name.

  Default preloads `[:catalogue, category: :catalogue]`.
  Pass `:preload` in `opts` to add more (e.g.
  `preload: [catalogue_rules: :referenced_catalogue]` for smart-pricing
  consumers); the lists are concatenated, not replaced.

  ## Options

    * `:item_types` — only items of these EFFECTIVE types
      (`filter_by_item_types/2`); `nil`/`[]` = all. Same option as
      `list_items_for_category_paged/2`.
  """
  @spec list_items_for_category(Ecto.UUID.t(), keyword()) :: [Item.t()]
  def list_items_for_category(category_uuid, opts \\ []) do
    from(i in Item,
      as: :item,
      where: i.category_uuid == ^category_uuid and i.status != "deleted",
      order_by: [asc: i.position, asc: i.name],
      preload: ^Helpers.merge_preloads([:catalogue, category: :catalogue], opts)
    )
    |> filter_by_item_types(opts)
    |> repo().all()
    |> Manufacturers.hydrate()
  end

  @doc """
  Lists non-deleted items for a catalogue, ordered by category position,
  then item position, name and uuid. Includes uncategorized items (those
  with no category) at the end.

  Byte-for-byte the tail of `search_items/2`'s `:position` chain (the
  leading catalogue keys are constant here), uuid tie-break included —
  the unpaged read and the paged one must not disagree on two items
  that tie on every visible key.

  Default preloads `[:catalogue, category: :catalogue]`.
  Pass `:preload` in `opts` to add more — see `list_items_for_category/2`.

  ## Options

    * `:item_types` — only items of these EFFECTIVE types
      (`filter_by_item_types/2`); `nil`/`[]` = all. Same option as
      `list_catalogue_items_paged/2`.
  """
  @spec list_items_for_catalogue(Ecto.UUID.t(), keyword()) :: [Item.t()]
  def list_items_for_catalogue(catalogue_uuid, opts \\ []) do
    from(i in Item,
      as: :item,
      left_join: c in Category,
      on: i.category_uuid == c.uuid,
      where: i.catalogue_uuid == ^catalogue_uuid and i.status != "deleted",
      order_by: [asc_nulls_last: c.position, asc: i.position, asc: i.name, asc: i.uuid],
      preload: ^Helpers.merge_preloads([:catalogue, category: :catalogue], opts)
    )
    |> filter_by_item_types(opts)
    |> repo().all()
    |> Manufacturers.hydrate()
  end

  @doc """
  Lists soft-deleted items in a catalogue as a flat list, ordered by
  deletion date (most-recently-deleted first). `updated_at` is the
  deletion-time proxy — flipping `status` to `"deleted"` always bumps
  it. Used by the Items tab Deleted view, which surfaces a recency-
  ordered audit list rather than category-grouped cards.

  ## Options

    * `:limit` — caps the list (default 500). Pagination isn't wired
      yet; if a catalogue routinely exceeds the limit, layer a cursor
      on top of this query.
    * `:preload` — extra associations on top of the default
      `[:catalogue, category: :catalogue]`.

  ## Examples

      Catalogue.list_deleted_items_for_catalogue(catalogue_uuid)
  """
  @spec list_deleted_items_for_catalogue(Ecto.UUID.t(), keyword()) :: [Item.t()]
  def list_deleted_items_for_catalogue(catalogue_uuid, opts \\ []) do
    limit = Keyword.get(opts, :limit, 500)

    from(i in Item,
      where: i.catalogue_uuid == ^catalogue_uuid and i.status == "deleted",
      order_by: [desc: i.updated_at, asc: i.uuid],
      limit: ^limit,
      preload: ^Helpers.merge_preloads([:catalogue, category: :catalogue], opts)
    )
    |> repo().all()
    |> Manufacturers.hydrate()
  end

  @doc """
  Lists uncategorized items (no category assigned) for a specific catalogue.

  ## Options

    * `:mode` — `:active` (default) excludes deleted items;
      `:deleted` returns only deleted items.
    * `:preload` — extra associations appended to the default
      `[:catalogue]` preloads. Pass
      `[catalogue_rules: :referenced_catalogue]` for smart-pricing.

  ## Examples

      Catalogue.list_uncategorized_items(catalogue_uuid)
      Catalogue.list_uncategorized_items(catalogue_uuid, mode: :deleted)
  """
  @spec list_uncategorized_items(Ecto.UUID.t(), keyword()) :: [Item.t()]
  def list_uncategorized_items(catalogue_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)
    preloads = Helpers.merge_preloads([:catalogue], opts)

    query =
      from(i in Item,
        where: i.catalogue_uuid == ^catalogue_uuid and is_nil(i.category_uuid),
        order_by: [asc: i.position, asc: i.name],
        preload: ^preloads
      )

    query =
      case mode do
        :active -> where(query, [i], i.status != "deleted")
        :deleted -> where(query, [i], i.status == "deleted")
      end

    repo().all(query)
  end

  @doc """
  Fetches an item by UUID. Returns `nil` if not found.

  ## Options

    * `:preload` — list of associations to preload. Default `[]`.
      Common smart-pricing preload: `[catalogue_rules: :referenced_catalogue]`.

  ## Examples

      Catalogue.get_item(uuid)
      Catalogue.get_item(uuid, preload: [:catalogue, catalogue_rules: :referenced_catalogue])
  """
  @spec get_item(Ecto.UUID.t(), keyword()) :: Item.t() | nil
  def get_item(uuid, opts \\ []) do
    case Helpers.get_by_uuid(Item, uuid) do
      nil -> nil
      item -> repo().preload(item, Keyword.get(opts, :preload, []))
    end
  end

  @doc """
  Fetches an item by UUID with preloaded `:catalogue`, `:category`,
  and `:manufacturer`. Raises `Ecto.NoResultsError` if not found.

  Pass `:preload` to add more associations (concatenated with the
  defaults).
  """
  @spec get_item!(Ecto.UUID.t(), keyword()) :: Item.t()
  def get_item!(uuid, opts \\ []) do
    Item
    |> Helpers.get_by_uuid!(uuid)
    |> repo().preload(Helpers.merge_preloads([:catalogue, :category], opts))
    |> Manufacturers.hydrate()
  end

  @doc """
  Fetches an item by its per-language `slug`.

  Tries an exact match in `lang`'s base language first (`"en-US"` folds
  to `"en"`), falling back to any language when `opts[:any_lang]` is
  `true`. The result is `{:error, :not_found}` on a miss; a hit is a
  2-tuple by default, or — whenever `opts[:any_lang]` is `true`, even
  when the base language itself matched — a 3-tuple carrying the
  language the slug actually matched in, so a caller that opted into
  the fallback can always destructure the same shape. Any other option
  (e.g. `:preload`) is forwarded to `get_item/2`.
  """
  @spec get_item_by_slug(String.t(), String.t(), keyword()) ::
          {:ok, Item.t()} | {:ok, Item.t(), String.t()} | {:error, :not_found}
  def get_item_by_slug(slug, lang, opts \\ []) do
    Shared.find_by_slug(@item_slugs_table, "item_uuid", slug, lang, opts, &get_item/2)
  end

  @doc """
  Whether `slug` is already projected for `lang`'s base language by an
  item other than `opts[:exclude_uuid]`. Trashed items count: their slugs
  stay in the projection so a restore cannot collide, which is also why
  a generated slug must probe here rather than through `get_item_by_slug/3`.
  The probe `Catalogue.Slugs.unique/3` runs before a generated slug is
  written (the item form, the AI translation adapter).
  """
  @spec item_slug_taken?(String.t(), String.t(), keyword()) :: boolean()
  def item_slug_taken?(slug, lang, opts \\ []) do
    Shared.slug_taken?(@item_slugs_table, "item_uuid", slug, lang, opts[:exclude_uuid])
  end

  @doc """
  Bulk-fetches items by a list of UUIDs. Excludes soft-deleted items.
  Result order matches the input UUID order; missing UUIDs are dropped
  (no `nil` placeholders, no error). Duplicate input UUIDs collapse to
  a single result.

  Designed for snapshot rehydration — e.g. an order stored as a list of
  item UUIDs that needs full item data on reload. Avoids the N+1 trap
  of looping `get_item/1` per UUID.

  ## Options

    * `:preload` — extra associations appended to the default
      `[:catalogue, :category]`. Pass
      `[catalogue_rules: :referenced_catalogue]` for smart-pricing.

  ## Examples

      Catalogue.list_items_by_uuids([uuid1, uuid2, uuid3])
      Catalogue.list_items_by_uuids(uuids, preload: [catalogue_rules: :referenced_catalogue])
  """
  @spec list_items_by_uuids([Ecto.UUID.t()], keyword()) :: [Item.t()]
  def list_items_by_uuids(uuids, opts \\ [])

  def list_items_by_uuids([], _opts), do: []

  def list_items_by_uuids(uuids, opts) when is_list(uuids) do
    preloads = Helpers.merge_preloads([:catalogue, :category], opts)

    items_by_uuid =
      from(i in Item,
        where: i.uuid in ^uuids and i.status != "deleted",
        preload: ^preloads
      )
      |> repo().all()
      |> Map.new(&{&1.uuid, &1})

    uuids
    |> Enum.uniq()
    |> Enum.flat_map(fn uuid ->
      case Map.get(items_by_uuid, uuid) do
        nil -> []
        item -> [item]
      end
    end)
  end

  @doc """
  Creates an item.

  ## Required attributes

    * `:name` — item name (1-255 chars)
    * `:catalogue_uuid` — the parent catalogue (required). Auto-derived from
      `:category_uuid` when omitted and a category is provided.

  ## Optional attributes

    * `:description` — text description
    * `:sku` — stock keeping unit (max 100 chars; not unique — the same
      SKU may appear on multiple items)
    * `:base_price` — decimal, must be >= 0 (cost/purchase price before markup)
    * `:unit` — one of `Item.allowed_units/0` (default `"piece"`)
    * `:item_type` — `"goods"` or `"service"`; omit (or pass nil) to inherit
      the catalogue's type. Read it back with `Item.effective_type/2`
    * `:status` — `"active"` (default), `"inactive"`, `"discontinued"`, or `"deleted"`
    * `:category_uuid` — the parent category (optional — leave nil for uncategorized items)
    * `:manufacturer_uuid` — the manufacturer (optional)
    * `:data` — flexible JSON map

  ## Examples

      Catalogue.create_item(%{name: "Oak Panel 18mm", catalogue_uuid: cat.uuid, base_price: 25.50})
      Catalogue.create_item(%{name: "Hinge", category_uuid: category.uuid, manufacturer_uuid: m.uuid})
  """
  @spec create_item(map(), keyword()) ::
          {:ok, Item.t()} | {:error, Ecto.Changeset.t(Item.t())}
  def create_item(attrs, opts \\ []) do
    skip_derive? = Keyword.get(opts, :skip_derive, false)
    attrs = maybe_put_item_position(attrs)

    # We run derivation + insert in the same transaction so that the
    # `FOR SHARE` row lock inside `put_catalogue_from_effective_category`
    # is held until the INSERT commits. That closes the race with a
    # concurrent `move_category_to_catalogue/3` (which takes `FOR UPDATE`
    # on the same row): while the move holds the exclusive lock, our
    # derive waits; once we hold the shared lock, the move waits — so an
    # item can never be inserted with a stale `catalogue_uuid` mid-move.
    result =
      repo().transaction(fn ->
        {attrs, category} =
          if skip_derive?, do: {attrs, nil}, else: derive_catalogue_uuid(nil, attrs)

        case %Item{}
             |> Item.changeset(attrs)
             |> check_item_category(category)
             |> Shared.stamp_created_deleted()
             |> repo().insert() do
          {:ok, item} -> item
          {:error, changeset} -> repo().rollback(changeset)
        end
      end)

    case result do
      {:ok, item} ->
        Shared.log_activity(
          %{
            action: "item.created",
            mode: opts[:mode] || "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "item",
            resource_uuid: item.uuid,
            parent_catalogue_uuid: item.catalogue_uuid,
            metadata: %{"name" => item.name, "sku" => item.sku || ""}
          },
          opts
        )

        {:ok, item}

      {:error, _changeset} = error ->
        error
    end
  end

  # Keeps `catalogue_uuid` in lockstep with `category_uuid`. The
  # category is the single source of truth: an item in a category must
  # live in that category's catalogue. We compute the *effective*
  # resulting `category_uuid` (new value if attrs mentions it, otherwise
  # the item's current value) and, whenever that yields a category, we
  # set `catalogue_uuid` to that category's `catalogue_uuid` — overriding
  # any stale value the caller might have passed. This prevents silent
  # inconsistencies where an item ends up with a category in catalogue A
  # but `catalogue_uuid` pointing at catalogue B.
  #
  # Also normalizes an empty-string `category_uuid` from form params
  # into `nil` so the changeset treats it as "clear category" rather
  # than attempting a malformed DB lookup.
  #
  # Accepts both atom- and string-keyed maps, and a `nil` item for the
  # create path.
  # Returns `{attrs, category}`: the category it read FOR SHARE (or nil) goes
  # on to `check_item_category/2`, which would otherwise read it again.
  defp derive_catalogue_uuid(item, attrs) when is_map(attrs) do
    attrs
    |> normalize_blank_category()
    |> put_catalogue_from_effective_category(effective_category_uuid(item, attrs))
  end

  # Returns the category_uuid the item will have *after* this
  # create/update: the incoming one from attrs if provided (nil if it's
  # an empty string), otherwise the item's current value (nil on create).
  defp effective_category_uuid(item, attrs) do
    if Helpers.has_attr?(attrs, :category_uuid) do
      attrs |> Helpers.fetch_attr(:category_uuid) |> Values.blank_to_nil()
    else
      item && Map.get(item, :category_uuid)
    end
  end

  # An empty-string `category_uuid` arrives from form params; normalize it
  # to `nil` so the changeset treats it as "clear category" instead of
  # tripping a malformed FK lookup.
  defp normalize_blank_category(attrs) do
    if Helpers.has_attr?(attrs, :category_uuid) and
         Helpers.fetch_attr(attrs, :category_uuid) == "" do
      Helpers.put_attr(attrs, :category_uuid, nil)
    else
      attrs
    end
  end

  # The category an item is written into must be live while the item is,
  # and must belong to the item's catalogue. One FOR SHARE read, which also
  # waits out a `trash_category/2` or `move_category_to_catalogue/3` holding
  # the row. A form or tab still offering a trashed category gets a
  # changeset error instead of an item hidden from the tree; an importer
  # writing with `skip_derive: true` whose category moved to another
  # catalogue mid-import gets one instead of an item in a catalogue its
  # category is not in.
  defp check_item_category(%Ecto.Changeset{} = changeset, known) do
    with category_uuid when is_binary(category_uuid) <- category_to_check(changeset),
         {category_status, category_catalogue_uuid} <- category_facts(category_uuid, known) do
      live? = Ecto.Changeset.get_field(changeset, :status) != "deleted"

      cond do
        live? and category_status == "deleted" ->
          Ecto.Changeset.add_error(changeset, :category_uuid, "is invalid")

        Ecto.Changeset.get_field(changeset, :catalogue_uuid) != category_catalogue_uuid ->
          Ecto.Changeset.add_error(changeset, :category_uuid, "belongs to another catalogue")

        true ->
          changeset
      end
    else
      _ -> changeset
    end
  end

  # The category to check: a changed one, or the unchanged one when the
  # item's catalogue changes under it (an importer passing `skip_derive: true`
  # with a new `catalogue_uuid`). Either can leave an item in a category of
  # another catalogue.
  defp category_to_check(changeset) do
    case Ecto.Changeset.fetch_change(changeset, :category_uuid) do
      {:ok, category_uuid} ->
        category_uuid

      :error ->
        if Ecto.Changeset.changed?(changeset, :catalogue_uuid),
          do: Ecto.Changeset.get_field(changeset, :category_uuid)
    end
  end

  # The derive step already read this category FOR SHARE in the same
  # transaction; reading it again cost a query per item write, which imports
  # multiply.
  # A `do` block, not `, do:` — the formatter's indent for a wrapped
  # `, do:` continuation moved between Elixir 1.18 and 1.19, so the
  # one-liner flip-flops with whichever version last ran `mix format`.
  defp category_facts(uuid, %Category{uuid: uuid} = known) do
    {known.status, known.catalogue_uuid}
  end

  defp category_facts(uuid, _known) do
    repo().one(
      from(c in Category,
        where: c.uuid == ^uuid,
        lock: "FOR SHARE",
        select: {c.status, c.catalogue_uuid}
      )
    )
  end

  # If the effective category exists, pin `catalogue_uuid` to that
  # category's catalogue — this is the single source of truth and
  # overrides any stale value the caller might have passed. If no
  # category exists in the resulting state, leave `catalogue_uuid`
  # alone; `validate_required` enforces it ends up set.
  #
  # The `FOR SHARE` row lock closes the move_category race: see the
  # comment in `create_item/2`. Must be invoked inside a transaction
  # for the lock to persist until the insert/update commits.
  defp put_catalogue_from_effective_category(attrs, nil), do: {attrs, nil}

  defp put_catalogue_from_effective_category(attrs, category_uuid)
       when is_binary(category_uuid) do
    query = from(c in Category, where: c.uuid == ^category_uuid, lock: "FOR SHARE")

    case repo().one(query) do
      %Category{catalogue_uuid: cat_uuid} = category ->
        {Helpers.put_attr(attrs, :catalogue_uuid, cat_uuid), category}

      nil ->
        # Target category doesn't exist — leave attrs as-is so the
        # changeset's FK constraint surfaces a clear error.
        {attrs, nil}
    end
  end

  @doc """
  Updates an item with the given attributes.

  ## `:data_owned_keys`

  A caller (typically a form) that only rendered/edited PART of `data`
  can pass `:data_owned_keys` — a list of `data`'s top-level keys it
  actually owns. When set, this function re-reads the row `FOR UPDATE`
  inside its transaction and, for each owned key, takes that key's
  value from `attrs["data"]` (falling back to the fresh row's own value
  when the key is absent from `attrs["data"]` — an owned key is never
  written as a deletion by mere absence). Every key NOT listed keeps the
  freshest DB value untouched, no matter what stale copy `attrs["data"]`
  happens to carry for it — the whole point: a form built from a
  page-load snapshot can no longer clobber a key some other process
  wrote after that snapshot was taken (translation fingerprints, a sync,
  …).

  Omit the option (or pass `nil`) for the previous behavior: `data` is
  replaced wholesale by whatever `attrs["data"]` contains, same as a
  plain `Ecto.Changeset.cast/4` on a `:map` field.

  ## `:data_owned_paths`

  The nested counterpart of `:data_owned_keys`, for a writer that owns a few
  leaves of a key other writers also use (the shop API owns
  `["ecommerce", "compare_at_price"]`, the Shopify sync owns
  `["ecommerce", "shopify"]`). A list of paths, each a non-empty list of
  string keys (the first may not be `"_trash"`); `[]` owns nothing. The row
  is read `FOR UPDATE` in the transaction and **the update is applied to that
  fresh row**, not to the caller's copy: for every path present in
  `attrs["data"]` its value replaces the fresh value at that path (an
  explicit `nil` deletes the key and prunes the maps it empties); the rest of
  `data`, and every column the caller did not change, is the fresh row's.
  Returns `{:error, :not_found}` when the row is gone. Mutually exclusive
  with `:data_owned_keys` (`ArgumentError`). The returned struct is the locked
  row, so associations the caller had preloaded are not loaded on it (reload
  them if needed). A path that runs through a value that is not a map (say
  `data["api"]` holding a string) replaces that value with a map when written.

  ## `:slug_owned_langs`

  Only with `:data_owned_paths` (`ArgumentError` otherwise): a list of
  language codes. The `slug` column is one map for all languages, so a caller
  that read it earlier and writes it whole would silently overwrite a slug
  another writer (the translation sweep, the item form, a second API call)
  stored for ANOTHER language in between, and a lost slug is a moved URL with
  no redirect. With this option `attrs[:slug]` is read as a set of per-language
  deltas: for each listed language the value in `attrs[:slug]` replaces the
  locked fresh row's value (an absent or blank value deletes that language's
  slug), and every other language is the fresh row's. Nothing is merged, and
  the fresh row's slug map is kept as it is, when the list is `[]` or when
  `attrs` carries no `:slug` map at all (so a rename-only call never touches a
  slug). Without the option `attrs[:slug]` is cast whole like any column.

  ## Logging options

    * `:log_metadata` — a string-keyed map merged into the `item.updated`
      entry's metadata (the entry's own `"name"`, `"sku"` and `"changes"`
      win on a clash). The shop API sets `via`, `key_prefix`, `request_id`
      and `tool`.
    * `:logged_data_paths` — `data` paths whose before/after values appear in
      `metadata["changes"]` as `"data.<a>.<b>"`, next to the logged columns.
  """
  @spec update_item(Item.t(), map(), keyword()) ::
          {:ok, Item.t()} | {:error, Ecto.Changeset.t(Item.t()) | :not_found}
  def update_item(%Item{} = item, attrs, opts \\ []) do
    # A bad option raises before any query is issued.
    _ = Shared.owned_options!(opts)

    result =
      repo().transaction(fn ->
        case do_update_item(item, attrs, opts, []) do
          {:ok, {before, updated, _changed?}} -> {before, updated}
          {:error, reason} -> repo().rollback(reason)
        end
      end)

    case result do
      {:ok, {before, updated}} ->
        Shared.log_activity(
          %{
            action: "item.updated",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "item",
            resource_uuid: updated.uuid,
            parent_catalogue_uuid: updated.catalogue_uuid,
            metadata:
              ActivityLog.with_changes(
                %{"name" => updated.name, "sku" => updated.sku || ""},
                before,
                updated,
                @item_logged_fields,
                Keyword.get(opts, :logged_data_paths, [])
              )
          },
          opts
        )

        MediaFolders.follow([{before, updated}], opts[:actor_uuid])
        {:ok, updated}

      {:error, _changeset} = error ->
        error
    end
  end

  # One item update, run INSIDE the caller's transaction. Shared by
  # `update_item/3` and `update_items/2`. Returns `{:ok, {before, updated,
  # changed?}}` or `{:error, changeset | :not_found}`; `before` is the row the
  # diff is taken against (the locked fresh row under `:data_owned_paths`, the
  # caller's copy otherwise). `repo_opts` reach `repo().update/2` (the batch
  # passes `mode: :savepoint` so one bad row cannot poison the transaction).
  defp do_update_item(%Item{} = item, attrs, opts, repo_opts) do
    skip_derive? = Keyword.get(opts, :skip_derive, false)

    # The category (FOR SHARE, in the derive) before the item row (FOR
    # UPDATE, in the data narrowing): the order a category trash takes
    # them, so a form save and a trash cannot deadlock.
    {attrs, category} =
      if skip_derive?, do: {attrs, nil}, else: derive_catalogue_uuid(item, attrs)

    with {:ok, attrs, base} <- narrow_item_data(item, attrs, opts) do
      changeset =
        base
        |> Item.changeset(attrs)
        |> Shared.keep_trash_status(Item, base.uuid)
        |> check_item_category(category)

      case write_item(changeset, repo_opts) do
        {:ok, updated} -> {:ok, {base, updated, map_size(changeset.changes) > 0}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # The batch's write runs under a savepoint, so a database error there has
  # already been rolled back to it and is this row's alone. Only this write is
  # answered that way: an error in any read around it leaves the transaction
  # aborted and is not the row's to swallow.
  defp write_item(changeset, repo_opts) do
    repo().update(changeset, repo_opts)
  rescue
    error in Postgrex.Error ->
      if repo_opts[:mode] == :savepoint do
        Logger.warning(
          "update_items row #{changeset.data.uuid} failed: #{pg_error_summary(error)}"
        )

        {:error, :database_error}
      else
        reraise(error, __STACKTRACE__)
      end
  end

  defp narrow_item_data(%Item{} = item, attrs, opts) do
    case Shared.owned_options!(opts) do
      {nil, nil} ->
        {:ok, Shared.narrow_data_ownership(Item, item.uuid, attrs, opts), item}

      {paths, langs} ->
        case Shared.lock_fresh(Item, item.uuid) do
          nil ->
            {:error, :not_found}

          fresh ->
            attrs = Shared.splice_owned_paths(fresh, attrs, paths)
            attrs = Shared.splice_owned_slugs(fresh, attrs, langs)

            {:ok, attrs, fresh}
        end
    end
  end

  @doc """
  What `update_item/3` WOULD change, without writing anything: the diff in the
  shape `item.updated` logs (`%{"name" => %{"from" => a, "to" => b},
  "data.ecommerce.compare_at_price" => ...}`), or the changeset when the
  update is invalid. Takes the same `:data_owned_paths` and
  `:logged_data_paths` options; no lock is taken (it works on the caller's
  copy), no category derivation, no log entry, no broadcast. This is what the
  shop API's dry run and confirmation preview are made of.

  It models the column and `:data_owned_paths` changes only. `:slug_owned_langs`
  is validated but not applied: `attrs[:slug]` is taken as the planned whole
  slug map. A `status` change on a trashed row (which `update_item/3` discards)
  and `:data_owned_keys` are not modelled.
  """
  @spec preview_item_update(Item.t(), map(), keyword()) ::
          {:ok, %{optional(String.t()) => map()}} | {:error, Ecto.Changeset.t(Item.t())}
  def preview_item_update(%Item{} = item, attrs, opts \\ []) do
    attrs =
      case Shared.owned_options!(opts) do
        {nil, _langs} -> attrs
        {paths, _langs} -> Shared.splice_owned_paths(item, attrs, paths)
      end

    changeset = Item.changeset(item, attrs)

    if changeset.valid? do
      updated = Ecto.Changeset.apply_changes(changeset)

      metadata =
        ActivityLog.with_changes(
          %{},
          item,
          updated,
          @item_logged_fields,
          Keyword.get(opts, :logged_data_paths, [])
        )

      {:ok, Map.get(metadata, "changes", %{})}
    else
      {:error, changeset}
    end
  end

  @update_items_max 500

  @typedoc "What `update_items/2` answers for one row."
  @type item_outcome ::
          {:updated, Item.t()}
          | {:unchanged, Item.t()}
          | {:error, Ecto.Changeset.t(Item.t()) | :not_found | :duplicate_row | :database_error}

  @doc """
  Updates many items in ONE transaction and logs them with ONE insert and ONE
  broadcast (the shop API's batch write; a 500-row batch is not 500 inserts
  and 500 broadcasts).

  `rows` is a list of `{item_uuid, attrs}` or `{item_uuid, attrs, row_opts}`;
  `row_opts` override the shared `opts` for that row. At most 500 rows
  (`ArgumentError` above). Answers `{:ok, [{item_uuid, outcome}]}` in input
  order, where `outcome` is `{:updated, item}`, `{:unchanged, item}` (the
  changeset had nothing to change: no write, no log entry) or `{:error, reason}`
  with a changeset, `:not_found` (no such row, or not a UUID),
  `:duplicate_row` (the uuid already appeared earlier in this batch) or
  `:database_error`. A uuid is matched in its canonical lowercase form (an
  upper-case spelling of an existing row's uuid finds the row, and counts as
  the same row for `:duplicate_row`); the outcome tuple keeps the string the
  caller sent. The returned items carry no preloaded associations.

  **Rows are independent**, as far as the row's own UPDATE goes: each is
  applied under a savepoint, so a row whose UPDATE fails (a constraint, a
  value the database refuses) leaves the others written. Any other database
  error (the reads around the UPDATE, which touch rows the batch already
  holds) is raised, and nothing is written; `{:error, term}` is left for the
  `rollback/1` paths.

  Rows are locked in a fixed order (the categories involved `FOR SHARE`, then
  the item rows `FOR UPDATE`, each sorted by uuid), and every row goes through
  the same code as `update_item/3`, including `:data_owned_paths` (applied to
  the locked fresh row), `:skip_derive` and `:logged_data_paths`. Row and
  category locks are ordered, so two batches over overlapping rows cannot
  deadlock on them; waits on the `external_id` and slug unique indexes are
  not ordered, and a row that is the victim of a deadlock detected there
  answers `:database_error`.

  ## Options

  `:actor_uuid`, `:mode`, `:log_metadata`, `:logged_data_paths`,
  `:data_owned_paths`, `:slug_owned_langs`, `:skip_derive` as in
  `update_item/3`, and `:broadcast` (default `true`): when `false` no bulk
  event is sent. The options (shared and per row) are validated before any
  query is issued; a bad one raises `ArgumentError`, as in `update_item/3`.

  After the commit: one `item.updated` entry per CHANGED row in a single
  `ActivityLog.log_many/1`, and one `{:catalogue_bulk_change, catalogue_uuid,
  :updated, uuids, from}` per catalogue the changed rows live in (a row that
  moves to another catalogue through `category_uuid` is announced to the new
  catalogue only). The media folders of the changed rows follow their renames
  and moves in one `MediaFolders.follow/2` pass, like after `update_item/3`;
  a row that failed or changed nothing leaves its folder where it is.

  Called inside the caller's own transaction (the shop API's price and
  availability writes do), the transaction here is the caller's, so "after the
  commit" means only after this function's own statements, not after the
  caller's commit:

    * The activity entries are inserted inside it, and core announces them as
      soon as they are inserted; the `{:catalogue_bulk_change, ...}` and
      `{:catalogue_data_changed, :item, nil, catalogue}` events go out right
      after. All of them reach their listeners before the caller commits, and
      a rollback of the caller's transaction leaves them announced. Pass
      `broadcast: false` to hold back the two catalogue events and send them
      after the commit with `broadcast_item_batch_change/3`; the activity
      announcement is core's and cannot be held back.
    * The folder pass runs inside it, so the folders and the rows commit or
      roll back together, and a pass that has work to do holds the site-wide
      folder-tree lock until the caller commits. Rows that change neither name
      nor category (a price or an availability) give it nothing to do.
    * Neither the activity insert nor the folder pass runs under a savepoint.
      Both never raise, but a statement of either that fails in the database
      (an activity insert that errors, a batch move that meets a concurrent
      name claim) leaves the caller's transaction aborted while this function
      still answers `{:ok, _}`; the caller finds out at its next statement, and
      its own commit fails.

  A caller inside a transaction should therefore write only rows that move no
  folder, or keep `update_items/2` out of its transaction.
  """
  @spec update_items([{Ecto.UUID.t(), map()} | {Ecto.UUID.t(), map(), keyword()}], keyword()) ::
          {:ok, [{Ecto.UUID.t(), item_outcome()}]} | {:error, term()}
  def update_items(rows, opts \\ []) when is_list(rows) and is_list(opts) do
    if length(rows) > @update_items_max do
      raise ArgumentError,
            "update_items/2 takes at most #{@update_items_max} rows, got #{length(rows)}"
    end

    rows = Enum.map(rows, &normalize_update_row/1)

    # A bad option raises before any query is issued, like in `update_item/3`.
    Enum.each(rows, fn {_uuid, _attrs, row_opts} ->
      Shared.owned_options!(Keyword.merge(opts, row_opts))
    end)

    case repo().transaction(fn -> run_update_items(rows, opts) end) do
      {:ok, results} ->
        entries = for {_uuid, _outcome, entry, _before} <- results, entry != nil, do: entry
        ActivityLog.log_many(entries)
        follow_updated_items(results, opts)
        broadcast_updated_items(results, opts)
        {:ok, Enum.map(results, fn {uuid, outcome, _entry, _before} -> {uuid, outcome} end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_update_row({uuid, attrs}), do: {uuid, attrs, []}

  defp normalize_update_row({uuid, attrs, row_opts}) when is_list(row_opts),
    do: {uuid, attrs, row_opts}

  # Runs inside the transaction. Returns `[{uuid, outcome, log_entry | nil,
  # before | nil}]`; `before` is the row as it was, for the rows that changed.
  defp run_update_items(rows, opts) do
    canonical = Enum.map(rows, fn {uuid, _attrs, _row_opts} -> canonical_uuid(uuid) end)
    items = lock_items_for_batch(rows, Enum.reject(canonical, &is_nil/1))

    {results, _seen} =
      rows
      |> Enum.zip(canonical)
      |> Enum.map_reduce(MapSet.new(), fn {{uuid, attrs, row_opts}, canon}, seen ->
        key = canon || uuid

        if MapSet.member?(seen, key) do
          {{uuid, {:error, :duplicate_row}, nil, nil}, seen}
        else
          {outcome, entry, before} =
            update_batch_row(Map.get(items, canon), attrs, Keyword.merge(opts, row_opts))

          {{uuid, outcome, entry, before}, MapSet.put(seen, key)}
        end
      end)

    results
  end

  # The canonical (lowercase) form of anything `Ecto.UUID` accepts, else nil.
  defp canonical_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, canonical} -> canonical
      :error -> nil
    end
  end

  # Categories FOR SHARE, then items FOR UPDATE, each in uuid order: the order
  # a category trash takes them in, and the same order for every batch.
  defp lock_items_for_batch(_rows, []), do: %{}

  defp lock_items_for_batch(rows, uuids) do
    current_categories =
      repo().all(
        from(i in Item,
          where: i.uuid in ^uuids and not is_nil(i.category_uuid),
          select: i.category_uuid
        )
      )

    incoming_categories =
      rows
      |> Enum.map(fn {_uuid, attrs, _row_opts} ->
        attrs |> Helpers.fetch_attr(:category_uuid) |> canonical_uuid()
      end)
      |> Enum.reject(&is_nil/1)

    category_uuids = (current_categories ++ incoming_categories) |> Enum.uniq() |> Enum.sort()

    repo().all(
      from(c in Category,
        where: c.uuid in ^category_uuids,
        order_by: c.uuid,
        lock: "FOR SHARE",
        select: c.uuid
      )
    )

    from(i in Item, where: i.uuid in ^uuids, order_by: i.uuid, lock: "FOR UPDATE")
    |> repo().all()
    |> Map.new(&{&1.uuid, &1})
  end

  defp update_batch_row(nil, _attrs, _opts), do: {{:error, :not_found}, nil, nil}

  defp update_batch_row(%Item{} = item, attrs, opts) do
    case do_update_item(item, attrs, opts, mode: :savepoint) do
      {:ok, {before, updated, true}} ->
        {{:updated, updated}, batch_entry(before, updated, opts), before}

      {:ok, {_before, updated, false}} ->
        {{:unchanged, updated}, nil, nil}

      {:error, reason} ->
        {{:error, reason}, nil, nil}
    end
  end

  # Only the structured, value-free fields of a database error: its message and
  # detail can carry the offending value.
  defp pg_error_summary(%Postgrex.Error{postgres: %{} = pg}) do
    Enum.map_join([:pg_code, :code, :constraint, :table], " ", fn key ->
      "#{key}=#{Map.get(pg, key, "-")}"
    end)
  end

  defp pg_error_summary(%Postgrex.Error{}), do: "no server error"

  defp batch_entry(before, updated, opts) do
    metadata =
      %{"name" => updated.name, "sku" => updated.sku || ""}
      |> ActivityLog.with_changes(
        before,
        updated,
        @item_logged_fields,
        Keyword.get(opts, :logged_data_paths, [])
      )
      |> ActivityLog.with_extra(Keyword.get(opts, :log_metadata))

    %{
      action: "item.updated",
      mode: opts[:mode] || "manual",
      actor_uuid: opts[:actor_uuid],
      resource_type: "item",
      resource_uuid: updated.uuid,
      metadata: metadata
    }
  end

  # After the commit, like every other write: the folders of the rows that
  # changed follow them, in one pass for the whole batch. A row that failed or
  # changed nothing has no pair, so its folder stays where it is.
  defp follow_updated_items(results, opts) do
    results
    |> Enum.flat_map(fn
      {_uuid, {:updated, updated}, _entry, before} -> [{before, updated}]
      _other -> []
    end)
    |> MediaFolders.follow(opts[:actor_uuid])
  end

  defp broadcast_updated_items(results, opts) do
    if Keyword.get(opts, :broadcast, true) do
      results
      |> Enum.flat_map(fn
        {_uuid, {:updated, item}, _entry, _before} -> [item]
        _other -> []
      end)
      |> Enum.group_by(& &1.catalogue_uuid, & &1.uuid)
      |> Enum.each(fn {catalogue_uuid, uuids} ->
        PubSub.broadcast_bulk_change(catalogue_uuid, :updated, uuids)
        # the nil-uuid event the catalogues index listens to, once per catalogue
        PubSub.broadcast(:item, nil, catalogue_uuid)
      end)
    end

    :ok
  end

  @doc """
  Announces a batch of item changes made WITHOUT per-row broadcasts (the shop
  API creates and trashes with `broadcast: false` and announces once):
  `{:catalogue_bulk_change, catalogue_uuid, kind, uuids, self()}` followed by
  ONE `{:catalogue_data_changed, :item, nil, catalogue_uuid}` (what every
  existing batch operation sends, and all the catalogues index listens to).
  An empty list sends nothing.
  """
  @spec broadcast_item_batch_change(Ecto.UUID.t(), :created | :updated | :trashed, [
          Ecto.UUID.t()
        ]) :: :ok
  def broadcast_item_batch_change(_catalogue_uuid, _kind, []), do: :ok

  def broadcast_item_batch_change(catalogue_uuid, kind, uuids)
      when kind in [:created, :updated, :trashed] and is_list(uuids) do
    PubSub.broadcast_bulk_change(catalogue_uuid, kind, uuids)
    # Like every existing batch operation (`broadcast_item_batch/2`), also the nil-uuid
    # data-changed event: the catalogues index (Items count) listens to that one only.
    PubSub.broadcast(:item, nil, catalogue_uuid)
    :ok
  end

  @doc "Hard-deletes an item. Prefer `trash_item/1` for soft-delete."
  @spec delete_item(Item.t(), keyword()) :: {:ok, Item.t()} | {:error, term()}
  def delete_item(%Item{} = item, opts \\ []) do
    release = MediaFolders.release_plan([from(i in Item, where: i.uuid == ^item.uuid)])

    case repo().delete(item) do
      {:ok, _} = ok ->
        MediaFolders.release(release)

        Shared.log_activity(%{
          action: "item.deleted",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "item",
          resource_uuid: item.uuid,
          parent_catalogue_uuid: item.catalogue_uuid,
          metadata: %{"name" => item.name}
        })

        ok

      error ->
        error
    end
  end

  @doc """
  Soft-deletes an item by setting its status to `"deleted"`, stamped as
  trashed on its own — restoring its catalogue or category later leaves
  it in the trash. Returns `{:error, :not_found}` when the row is gone. An
  item already in the trash is returned unchanged.

  Options: `:actor_uuid`, `:mode`, `:broadcast` (`false` sends no PubSub
  event) and `:log_metadata` (extra keys for the activity entry).

  ## Examples

      {:ok, item} = Catalogue.trash_item(item)
  """
  @spec trash_item(Item.t(), keyword()) :: {:ok, Item.t()} | {:error, :not_found | term()}
  def trash_item(%Item{} = item, opts \\ []) do
    with {:ok, _outcome, trashed} <- trash_item_outcome(item, opts), do: {:ok, trashed}
  end

  @doc """
  `trash_item/2` that tells whether THIS call trashed the item: `{:ok, :trashed,
  item}`, or `{:ok, :already_trashed, item}` when it was in the trash already (a
  concurrent trash that landed first) and nothing was changed or logged.
  """
  @spec trash_item_outcome(Item.t(), keyword()) ::
          {:ok, :trashed | :already_trashed, Item.t()} | {:error, :not_found | term()}
  def trash_item_outcome(%Item{} = item, opts \\ []) do
    result =
      Trash.locked_transaction(fn ->
        _locked = Trash.lock_row_in_catalogue!(Item, item.uuid)

        {trashed_now, _} =
          from(i in Item, where: i.uuid == ^item.uuid and i.status != "deleted")
          |> Trash.stamp_trashed_self(DateTime.utc_now())
          |> repo().update_all([])

        {repo().get!(Item, item.uuid), trashed_now}
      end)

    # An item already in the trash was not trashed by this call.
    with {:ok, {trashed, trashed_now}} <- result do
      if trashed_now > 0 do
        Shared.log_activity(
          %{
            action: "item.trashed",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "item",
            resource_uuid: trashed.uuid,
            parent_catalogue_uuid: trashed.catalogue_uuid,
            metadata: %{"name" => trashed.name}
          },
          Keyword.take(opts, [:log_metadata, :broadcast, :mode])
        )
      end

      {:ok, if(trashed_now > 0, do: :trashed, else: :already_trashed), trashed}
    end
  end

  @doc """
  Restores a soft-deleted item to the status it had before it was
  trashed (`inactive` and `discontinued` survive the round trip).

  Refuses with `{:error, :parent_catalogue_deleted}` when the item's
  catalogue is deleted — restore the catalogue first. (An item cannot
  exist outside a catalogue.)

  When the catalogue is live but the item's category is still in the
  trash, the item is **uncategorized on restore**: `category_uuid` is set
  to `nil` so it resurfaces in the catalogue's Uncategorized bucket,
  instead of reviving the category behind the operator's back. To get the
  item back in place, restore the category instead — `restore_category/2`
  brings back the items its own trash took.

  An item that is not deleted is returned unchanged.

  Refuses with `{:error, :external_id_taken}` when a live item has taken the
  `external_id` of this one; nothing is restored.

  Inside a caller's own transaction the collision is raised as the
  `Postgrex.Error` instead, because the database has already aborted that
  transaction.

  Options: `:actor_uuid`, `:mode`, `:broadcast` (`false` sends no PubSub
  event) and `:log_metadata` (extra keys for the activity entry).

  ## Examples

      {:ok, item} = Catalogue.restore_item(item)
      {:error, :parent_catalogue_deleted} =
        Catalogue.restore_item(item_under_deleted_catalogue)
  """
  @spec restore_item(Item.t(), keyword()) ::
          {:ok, Item.t()} | {:error, :parent_catalogue_deleted | :not_found | term()}
  def restore_item(%Item{} = item, opts \\ []) do
    result =
      Trash.locked_transaction(fn ->
        fresh = Trash.lock_row_in_catalogue!(Item, item.uuid)

        if Shared.catalogue_deleted?(fresh.catalogue_uuid),
          do: repo().rollback(:parent_catalogue_deleted)

        if fresh.status == "deleted",
          do: {:restored, do_restore_item(fresh), fresh},
          else: {:unchanged, {fresh, false}}
      end)

    case result do
      {:ok, {:restored, {restored, detached?}, fresh}} ->
        if detached?, do: MediaFolders.follow([{fresh, restored}], opts[:actor_uuid])

        Shared.log_activity(
          %{
            action: "item.restored",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "item",
            resource_uuid: restored.uuid,
            parent_catalogue_uuid: restored.catalogue_uuid,
            metadata:
              %{"name" => restored.name}
              |> Map.merge(if detached?, do: %{"detached_from_category" => true}, else: %{})
          },
          Keyword.take(opts, [:log_metadata, :broadcast, :mode])
        )

        {:ok, restored}

      {:ok, {:unchanged, {fresh, _}}} ->
        {:ok, fresh}

      error ->
        error
    end
  end

  defp do_restore_item(%Item{} = item) do
    detached? = category_deleted?(item.category_uuid)

    query =
      from(i in Item, where: i.uuid == ^item.uuid)
      |> Trash.restore_trashed(:item, DateTime.utc_now())

    query = if detached?, do: update(query, set: [category_uuid: nil]), else: query
    repo().update_all(query, [])

    {repo().get!(Item, item.uuid), detached?}
  end

  defp category_deleted?(nil), do: false

  defp category_deleted?(category_uuid) do
    repo().one(
      from(c in Category, where: c.uuid == ^category_uuid, lock: "FOR SHARE", select: c.status)
    ) == "deleted"
  end

  @doc """
  Permanently deletes an item from the database. This cannot be undone.

  ## Examples

      {:ok, _} = Catalogue.permanently_delete_item(item)
  """
  @spec permanently_delete_item(Item.t(), keyword()) :: {:ok, Item.t()} | {:error, term()}
  def permanently_delete_item(%Item{} = item, opts \\ []) do
    result =
      Trash.locked_transaction(fn ->
        locked = Trash.lock_row_in_catalogue!(Item, item.uuid)

        # `only_trashed: true` (a Deleted-tab action) refuses an item that was
        # restored in another tab since the page showed it.
        if opts[:only_trashed] == true and locked.status != "deleted",
          do: repo().rollback(:not_in_trash)

        release = MediaFolders.release_plan([from(i in Item, where: i.uuid == ^item.uuid)])
        from(i in Item, where: i.uuid == ^item.uuid) |> repo().delete_all()
        release
      end)

    with {:ok, release} <- result do
      MediaFolders.release(release)

      Shared.log_activity(%{
        action: "item.permanently_deleted",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "item",
        resource_uuid: item.uuid,
        parent_catalogue_uuid: item.catalogue_uuid,
        metadata: %{"name" => item.name}
      })

      {:ok, item}
    end
  end

  @doc """
  Bulk soft-deletes all non-deleted items in a category.

  Returns `{count, nil}` where count is the number of items affected.

  ## Examples

      {3, nil} = Catalogue.trash_items_in_category(category_uuid)
  """
  @spec trash_items_in_category(Ecto.UUID.t(), keyword()) :: {non_neg_integer(), nil}
  def trash_items_in_category(category_uuid, opts \\ []) do
    parent_catalogue_uuid = Shared.lookup_parent(:category, category_uuid)

    trash = fn ->
      Trash.lock_catalogue!(parent_catalogue_uuid)

      if Shared.lookup_parent(:category, category_uuid) != parent_catalogue_uuid,
        do: repo().rollback(:catalogue_moved)

      {count, _} =
        from(i in Item,
          where: i.category_uuid == ^category_uuid and i.status != "deleted"
        )
        |> Trash.stamp_trashed_self(DateTime.utc_now())
        |> repo().update_all([])

      count
    end

    count =
      case Trash.locked_transaction(trash) do
        {:ok, count} -> count
        {:error, _} -> 0
      end

    if count > 0 do
      Shared.log_activity(
        %{
          action: "item.bulk_trashed",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "item",
          parent_catalogue_uuid: parent_catalogue_uuid,
          metadata: %{"category_uuid" => category_uuid, "count" => count}
        },
        opts
      )
    end

    {count, nil}
  end

  # ── Batch fan-out for uuid-list bulk ops ──────────────────────

  # A uuid list from the admin toolbar normally comes from one catalogue,
  # but nothing in the API forbids a mixed list — so the batch event goes
  # out once per touched catalogue (the `nil` uuid marks it as a batch;
  # see `broadcast_for/2`). The bulk paths get that list from
  # `lock_catalogues_of!/2`, read BEFORE the write for trash / delete: the
  # rows may no longer exist afterwards.

  defp broadcast_item_batch(catalogue_uuids, opts) do
    if Keyword.get(opts, :broadcast, true) do
      Enum.each(catalogue_uuids, &PubSub.broadcast(:item, nil, &1))
    end

    :ok
  end

  # ── Bulk actions on UUID lists (admin selection toolbar) ──────

  defp bulk_result({:ok, {count, catalogue_uuids}}), do: {count, catalogue_uuids}

  defp bulk_result({:error, reason}) do
    Logger.warning("Catalogue bulk item operation rolled back: #{inspect(reason)}")
    {0, []}
  end

  # `only_trashed: true` (a Deleted-tab action) leaves live items alone, so a
  # row restored in another tab since the page showed it is not destroyed.
  defp only_trashed_items(query, opts) do
    if opts[:only_trashed] == true,
      do: where(query, [i], i.status == "deleted"),
      else: query
  end

  @doc """
  Bulk soft-deletes items by UUID. Empty list is a no-op. Logs a single
  `item.bulk_trashed` activity row when count > 0.
  """
  @spec bulk_trash_items([Ecto.UUID.t()], keyword()) :: {non_neg_integer(), nil}
  def bulk_trash_items([], _opts), do: {0, nil}

  def bulk_trash_items(uuids, opts) when is_list(uuids) do
    uuids = scope_item_uuids(uuids, opts[:catalogue_uuid])

    {count, catalogue_uuids} =
      Trash.locked_transaction(fn ->
        catalogue_uuids = Trash.lock_catalogues_of!(Item, uuids)

        {count, _} =
          from(i in Item, where: i.uuid in ^uuids and i.status != "deleted")
          |> Trash.stamp_trashed_self(DateTime.utc_now())
          |> repo().update_all([])

        {count, catalogue_uuids}
      end)
      |> bulk_result()

    if count > 0 do
      Shared.log_activity(
        %{
          action: "item.bulk_trashed",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "item",
          metadata: %{"count" => count, "uuids" => uuids}
        },
        broadcast: false
      )

      broadcast_item_batch(catalogue_uuids, opts)
    end

    {count, nil}
  end

  @doc """
  Bulk restores items by UUID. Skips items whose parent catalogue is
  deleted (returns only the count of items actually flipped to active).
  Items with deleted parent categories are uncategorized on restore —
  same rule as `restore_item/2`.

  Each item comes back to the status it had before it was trashed.
  Runs under the per-catalogue lock every trash / restore path takes, so
  no category trash can land between the read that partitions the items
  and the write — a transaction alone does not stop that under READ
  COMMITTED, and it used to leave live items in a trashed category.

  When a live item already holds the `external_id` of one of the trashed ones
  the whole batch is rolled back and the answer is `{:error, :external_id_taken}`
  (no audit entry is written for it). Inside a caller's own transaction the
  collision is raised as the `Postgrex.Error` instead, because the database
  has already aborted that transaction.
  """
  @spec bulk_restore_items([Ecto.UUID.t()], keyword()) ::
          {non_neg_integer(), nil} | {:error, :external_id_taken}
  def bulk_restore_items([], _opts), do: {0, nil}

  def bulk_restore_items(uuids, opts) when is_list(uuids) do
    uuids = scope_item_uuids(uuids, opts[:catalogue_uuid])

    restore = fn ->
      Trash.lock_catalogues_of!(Item, uuids)
      do_bulk_restore_items(uuids)
    end

    case Trash.locked_transaction(restore) do
      {:ok, {count, count_detached, restored_uuids, catalogue_uuids, detached}} ->
        detached
        |> Enum.map(&{&1, %{&1 | category_uuid: nil}})
        |> MediaFolders.follow(opts[:actor_uuid])

        if count > 0 do
          Shared.log_activity(
            %{
              action: "item.bulk_restored",
              mode: "manual",
              actor_uuid: opts[:actor_uuid],
              resource_type: "item",
              metadata: %{
                "count" => count,
                "detached_count" => count_detached,
                "uuids" => restored_uuids
              }
            },
            broadcast: false
          )

          broadcast_item_batch(catalogue_uuids, opts)
        end

        {count, nil}

      # A refused restore changed nothing the operator asked for, so it
      # leaves no audit row (each retry of the click would add one).
      {:error, :external_id_taken} = refused ->
        Logger.warning("bulk_restore_items rolled back: :external_id_taken")
        refused

      # A rollback inside the batch is a result, not a MatchError — and
      # its audit row says "restore", not "reorder".
      {:error, reason} ->
        Logger.warning("bulk_restore_items rolled back: #{inspect(reason)}")

        Shared.log_activity(
          %{
            action: "item.bulk_restored",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "item",
            metadata: %{"count" => 0, "uuids" => uuids, "db_pending" => true}
          },
          broadcast: false
        )

        {0, nil}
    end
  end

  defp do_bulk_restore_items(uuids) do
    now = DateTime.utc_now()

    items =
      from(i in Item,
        where: i.uuid in ^uuids and i.status == "deleted",
        preload: [:catalogue, :category]
      )
      |> repo().all()
      |> Enum.reject(fn i -> i.catalogue && i.catalogue.status == "deleted" end)

    {attached_uuids, detached_uuids} =
      Enum.split_with(items, fn item ->
        is_nil(item.category) || item.category.status != "deleted"
      end)
      |> then(fn {attached, detached} ->
        {Enum.map(attached, & &1.uuid), Enum.map(detached, & &1.uuid)}
      end)

    # The lock makes the partition above current; the guard keeps the write
    # right even if a future caller forgets it.
    {count_attached, _} =
      from(i in Item, as: :item, where: i.uuid in ^attached_uuids and i.status == "deleted")
      |> Trash.outside_trashed_categories()
      |> Trash.restore_trashed(:item, now)
      |> repo().update_all([])

    {count_detached, _} =
      from(i in Item, where: i.uuid in ^detached_uuids and i.status == "deleted")
      |> Trash.restore_trashed(:item, now)
      |> update(set: [category_uuid: nil])
      |> repo().update_all([])

    catalogue_uuids = items |> Enum.map(& &1.catalogue_uuid) |> Enum.uniq()

    detached = Enum.filter(items, &(&1.uuid in detached_uuids))

    {count_attached + count_detached, count_detached, attached_uuids ++ detached_uuids,
     catalogue_uuids, detached}
  end

  @doc """
  Bulk hard-deletes items by UUID. Use with care — no soft-delete cycle.
  Logs a single `item.bulk_permanently_deleted` activity row when
  count > 0.
  """
  @spec bulk_permanently_delete_items([Ecto.UUID.t()], keyword()) ::
          {non_neg_integer(), nil}
  def bulk_permanently_delete_items([], _opts), do: {0, nil}

  def bulk_permanently_delete_items(uuids, opts) when is_list(uuids) do
    uuids = scope_item_uuids(uuids, opts[:catalogue_uuid])

    release =
      MediaFolders.release_plan([
        from(i in Item, where: i.uuid in ^uuids) |> only_trashed_items(opts)
      ])

    {count, catalogue_uuids} =
      Trash.locked_transaction(fn ->
        catalogue_uuids = Trash.lock_catalogues_of!(Item, uuids)

        {count, _} =
          from(i in Item, where: i.uuid in ^uuids)
          |> only_trashed_items(opts)
          |> repo().delete_all()

        {count, catalogue_uuids}
      end)
      |> bulk_result()

    if count > 0 do
      MediaFolders.release(release)

      Shared.log_activity(
        %{
          action: "item.bulk_permanently_deleted",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "item",
          metadata: %{"count" => count, "uuids" => uuids}
        },
        broadcast: false
      )

      broadcast_item_batch(catalogue_uuids, opts)
    end

    {count, nil}
  end

  @doc """
  Bulk-moves items to a target category within a single catalogue.

  ## Required opts

    * `:catalogue_uuid` — the calling LV's catalogue scope. Every item
      in `uuids` MUST already belong to this catalogue, and `target_uuid`
      (when not `nil`) must live in this catalogue. The single-item DnD
      handler enforces the same scope; this guard makes the bulk path
      symmetric so a crafted client request can't silently flip an
      item's `catalogue_uuid` cross-catalogue.

  Pass `target_uuid: nil` to uncategorize all items within their
  catalogue.

  Returns `{:ok, count}`, `{:error, :category_not_found}` (target),
  `{:error, :wrong_catalogue_scope}` (target lives elsewhere or one or
  more items don't belong to `:catalogue_uuid`), or
  `{:error, :missing_catalogue_scope}` (caller forgot the required opt).
  """
  @spec bulk_move_items_to_category([Ecto.UUID.t()], Ecto.UUID.t() | nil, keyword()) ::
          {:ok, non_neg_integer()}
          | {:error, :category_not_found}
          | {:error, :wrong_catalogue_scope}
          | {:error, :missing_catalogue_scope}
  def bulk_move_items_to_category([], _target, _opts), do: {:ok, 0}

  def bulk_move_items_to_category(uuids, target_uuid, opts) when is_list(uuids) do
    with {:ok, scope} <- fetch_bulk_scope(opts),
         :ok <- ensure_items_in_catalogue(uuids, scope),
         :ok <- target_in_scope(target_uuid, scope) do
      destination = if target_uuid, do: {:category, target_uuid}, else: {:catalogue, scope}
      bulk_move_items(uuids, destination, opts)
    end
  end

  # The same-catalogue flavour's one extra rule: the target category is
  # this catalogue's. `bulk_move_items/3` re-reads it under the locks.
  defp target_in_scope(nil, _scope), do: :ok

  defp target_in_scope(target_uuid, scope) do
    query =
      from(c in Category, where: c.uuid == ^target_uuid, select: {c.catalogue_uuid, c.status})

    case Shared.valid_uuid?(target_uuid) && repo().one(query) do
      {^scope, status} when status != "deleted" -> :ok
      {_other, status} when status != "deleted" -> {:error, :wrong_catalogue_scope}
      _ -> {:error, :category_not_found}
    end
  end

  @doc """
  Bulk-moves items from one catalogue to a destination anywhere:
  `{:category, uuid}` (the item takes that category's catalogue) or
  `{:catalogue, uuid}` (uncategorized in that catalogue — the current one
  included).

  `opts[:catalogue_uuid]` is required and is the SOURCE scope: every
  uuid must be an item of that catalogue, or nothing moves
  (`:wrong_catalogue_scope`) — the selection is client-captured. Both
  catalogues' locks are held for the move, so a trash of either cannot
  interleave. Refuses a missing/trashed destination
  (`:category_not_found` / `:catalogue_not_found`) and one of the other
  catalogue kind (`:kind_mismatch`). Trashed items in the list are
  skipped.

  Logs one `item.bulk_moved` activity and tells both catalogues.
  Returns `{:ok, count}`.
  """
  @spec bulk_move_items(
          [Ecto.UUID.t()],
          {:category, Ecto.UUID.t()} | {:catalogue, Ecto.UUID.t()},
          keyword()
        ) :: {:ok, non_neg_integer()} | {:error, atom()}
  def bulk_move_items(uuids, destination, opts) when is_list(uuids) do
    with {:ok, scope} <- fetch_bulk_scope(opts),
         {:ok, uuids} <- cast_uuids(uuids),
         :ok <- valid_destination(destination) do
      case uuids do
        [] -> {:ok, 0}
        uuids -> run_bulk_move_items(uuids, destination, scope, opts)
      end
    end
  end

  defp fetch_bulk_scope(opts) do
    case Keyword.fetch(opts, :catalogue_uuid) do
      {:ok, scope} when is_binary(scope) -> {:ok, scope}
      _ -> {:error, :missing_catalogue_scope}
    end
  end

  defp cast_uuids(uuids) do
    if Enum.all?(uuids, &Shared.valid_uuid?/1),
      do: {:ok, Enum.uniq(uuids)},
      else: {:error, :invalid_uuid}
  end

  defp valid_destination({kind, uuid}) when kind in [:category, :catalogue] do
    cond do
      Shared.valid_uuid?(uuid) -> :ok
      kind == :category -> {:error, :category_not_found}
      true -> {:error, :catalogue_not_found}
    end
  end

  defp valid_destination(_), do: {:error, :invalid_entry}

  defp run_bulk_move_items(uuids, destination, scope, opts) do
    result =
      Trash.locked_transaction(fn ->
        target_catalogue = destination_catalogue(destination)
        Trash.lock_catalogues!([scope, target_catalogue])

        if ensure_items_in_catalogue(uuids, scope) != :ok,
          do: repo().rollback(:wrong_catalogue_scope)

        target_category = lock_destination_category(destination, target_catalogue)
        Shared.check_move_destination!(scope, target_catalogue)
        moving = MediaFolders.moving_items(uuids)

        {count, _} =
          from(i in Item,
            where: i.uuid in ^uuids and i.catalogue_uuid == ^scope and i.status != "deleted"
          )
          |> repo().update_all(
            set: [
              catalogue_uuid: target_catalogue,
              category_uuid: target_category,
              updated_at: DateTime.utc_now()
            ]
          )

        {count, target_catalogue, target_category, moving}
      end)

    with {:ok, {count, target_catalogue, target_category, moving}} <- result do
      if count > 0,
        do: log_bulk_item_move(uuids, count, scope, target_catalogue, target_category, opts)

      moving
      |> Enum.filter(&(&1.catalogue_uuid == scope))
      |> Enum.map(&{&1, %{&1 | catalogue_uuid: target_catalogue, category_uuid: target_category}})
      |> MediaFolders.follow(opts[:actor_uuid])

      {:ok, count}
    end
  end

  defp log_bulk_item_move(uuids, count, scope, target_catalogue, target_category, opts) do
    Shared.log_activity(
      %{
        action: "item.bulk_moved",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "item",
        parent_catalogue_uuid: target_catalogue,
        metadata:
          %{
            "count" => count,
            # WHERE they landed, not a from/to: a bulk move gathers items
            # from many categories at once, so there is no single source to
            # put on the left of an arrow. Claiming one would be a lie the
            # reader cannot check.
            "moved_to" => %{
              "catalogue" => Shared.catalogue_ref(target_catalogue),
              "category" => Shared.category_ref(target_category)
            }
          }
          |> Map.merge(ActivityLog.sample_uuids(uuids, count))
      },
      opts
    )

    if scope != target_catalogue and Keyword.get(opts, :broadcast, true),
      do: PubSub.broadcast(:item, nil, scope)
  end

  # The catalogue a destination lives in, read before the locks; the
  # locked re-read in `lock_destination_category/2` retries the whole
  # transaction when a concurrent move changed it in between.
  defp destination_catalogue({:catalogue, uuid}), do: uuid

  defp destination_catalogue({:category, uuid}) do
    repo().one(from(c in Category, where: c.uuid == ^uuid, select: c.catalogue_uuid)) ||
      repo().rollback(:category_not_found)
  end

  defp lock_destination_category({:catalogue, _}, _catalogue_uuid), do: nil

  defp lock_destination_category({:category, uuid}, catalogue_uuid) do
    case repo().one(from(c in Category, where: c.uuid == ^uuid, lock: "FOR SHARE")) do
      %Category{status: "deleted"} -> repo().rollback(:category_not_found)
      %Category{catalogue_uuid: ^catalogue_uuid} -> uuid
      %Category{} -> repo().rollback(:catalogue_moved)
      nil -> repo().rollback(:category_not_found)
    end
  end

  # `opts[:catalogue_uuid]` on the bulk item ops is a scope: uuids that
  # are not this catalogue's items are dropped before anything is
  # touched (the lists are client-captured; the page only re-broadcasts
  # for its own catalogue).
  defp scope_item_uuids(uuids, nil), do: uuids

  defp scope_item_uuids(uuids, catalogue_uuid) do
    repo().all(
      from(i in Item,
        where: i.uuid in ^uuids and i.catalogue_uuid == ^catalogue_uuid,
        select: i.uuid
      )
    )
  end

  defp ensure_items_in_catalogue(uuids, catalogue_uuid) do
    foreign? =
      from(i in Item,
        where: i.uuid in ^uuids and i.catalogue_uuid != ^catalogue_uuid,
        limit: 1,
        select: i.uuid
      )
      |> repo().exists?()

    if foreign?, do: {:error, :wrong_catalogue_scope}, else: :ok
  end

  @doc """
  Moves an item to a different category.

  If the target category lives in a different catalogue, the item's
  `catalogue_uuid` is updated to match. Passing `nil` for `category_uuid`
  detaches the item from any category while keeping it in its current
  catalogue.

  Refuses a trashed item (`:not_found`), a missing or trashed category
  (`:category_not_found`) and a category in a catalogue of the other
  kind (`:kind_mismatch`). A move across catalogues tells both.

  The item's media folder follows it into the new category's folder. A caller
  that moves many items uses `move_item_to_category_deferred/3` instead and
  follows all the folders in one pass afterwards.

  ## Examples

      {:ok, item} = Catalogue.move_item_to_category(item, new_category_uuid)
      {:ok, item} = Catalogue.move_item_to_category(item, nil)  # make uncategorized
  """
  @spec move_item_to_category(Item.t(), Ecto.UUID.t() | nil, keyword()) ::
          {:ok, Item.t()}
          | {:error,
             :category_not_found | :not_found | :kind_mismatch | Ecto.Changeset.t(Item.t())}
  def move_item_to_category(item, category_uuid, opts \\ [])

  def move_item_to_category(%Item{} = item, category_uuid, opts)
      when is_nil(category_uuid) or is_binary(category_uuid) do
    with {:ok, {before, moved}} <- checked_item_move(item, category_uuid, opts) do
      MediaFolders.follow([{before, moved}], opts[:actor_uuid])
      {:ok, moved}
    end
  end

  @doc """
  `move_item_to_category/3` without the media folder step, for a caller that moves
  many items: it returns the `{before, moved}` pair of the move, where `before` is
  the row the move locked (not the caller's possibly stale copy), and the caller
  hands the pairs of all its moves to `follow_moved_items/2` once. The item's folder
  stays where it is until it does.
  """
  @spec move_item_to_category_deferred(Item.t(), Ecto.UUID.t() | nil, keyword()) ::
          {:ok, {Item.t(), Item.t()}}
          | {:error,
             :category_not_found | :not_found | :kind_mismatch | Ecto.Changeset.t(Item.t())}
  def move_item_to_category_deferred(%Item{} = item, category_uuid, opts \\ [])
      when is_nil(category_uuid) or is_binary(category_uuid),
      do: checked_item_move(item, category_uuid, opts)

  defp checked_item_move(item, category_uuid, opts) do
    if is_nil(category_uuid) or Shared.valid_uuid?(category_uuid),
      do: do_move_item_to_category(item, category_uuid, opts),
      else: {:error, :category_not_found}
  end

  defp do_move_item_to_category(item, category_uuid, opts) do
    # One transaction, so the FOR SHARE lock `resolve_move_attrs/1` takes on
    # the target is held until the move commits: a concurrent category
    # trash either lands first (and the move refuses) or waits. The target
    # is locked BEFORE the item: a category trash holds the category and
    # then updates its items, so the other order could deadlock with it.
    result =
      repo().transaction(fn ->
        with {:ok, attrs} <- resolve_move_attrs(category_uuid),
             {:ok, current} <- lock_live_item(item),
             :ok <- same_kind(current.catalogue_uuid, attrs[:catalogue_uuid]),
             {:ok, moved} <- current |> Item.changeset(attrs) |> repo().update() do
          {moved, current}
        else
          {:error, reason} -> repo().rollback(reason)
        end
      end)

    with {:ok, {moved, before}} <- result do
      Shared.log_activity(
        %{
          action: "item.moved",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "item",
          resource_uuid: moved.uuid,
          parent_catalogue_uuid: moved.catalogue_uuid,
          metadata: %{
            "name" => moved.name,
            "changes" =>
              ActivityLog.changes([
                {:category, Shared.category_ref(before.category_uuid),
                 Shared.category_ref(category_uuid)},
                {:catalogue, Shared.catalogue_ref(before.catalogue_uuid),
                 Shared.catalogue_ref(moved.catalogue_uuid)}
              ])
          }
        },
        Keyword.take(opts, [:broadcast, :mode, :log_metadata])
      )

      if before.catalogue_uuid != moved.catalogue_uuid and Keyword.get(opts, :broadcast, true),
        do: PubSub.broadcast(:item, nil, before.catalogue_uuid)

      {:ok, {before, moved}}
    end
  end

  @doc """
  Moves and renames the media folders of items moved with
  `move_item_to_category_deferred/3`, given the `{before, moved}` pairs of all the
  moves, in one pass instead of one by one (`MediaFolders.follow/2`).

  `moved` is re-read, all rows in one query, just before the pass: an item that was
  renamed or moved again since its own move (a window as long as the caller's
  batch) is followed to where it is now, not to where the move left it. An item that
  is gone keeps the pair as given. Never fails: a failure is logged and the folders
  stay.
  """
  @spec follow_moved_items([{Item.t(), Item.t()}], Ecto.UUID.t() | nil) :: :ok
  def follow_moved_items([], _actor_uuid), do: :ok

  def follow_moved_items(pairs, actor_uuid) when is_list(pairs) do
    pairs
    |> current_pairs()
    |> MediaFolders.follow(actor_uuid)
  end

  defp current_pairs(pairs) do
    uuids = Enum.map(pairs, fn {_before, moved} -> moved.uuid end)
    current = from(i in Item, where: i.uuid in ^uuids) |> repo().all() |> Map.new(&{&1.uuid, &1})

    Enum.map(pairs, fn {before, moved} -> {before, Map.get(current, moved.uuid, moved)} end)
  rescue
    exception ->
      Logger.warning(
        "[Catalogue] moved items could not be re-read for their media folders: " <>
          ResourceFolders.describe_failure(exception)
      )

      pairs
  end

  defp locked_move_item_to_catalogue(item, catalogue_uuid) do
    from_catalogue_uuid =
      repo().one(from(i in Item, where: i.uuid == ^item.uuid, select: i.catalogue_uuid)) ||
        repo().rollback(:not_found)

    if from_catalogue_uuid == catalogue_uuid, do: repo().rollback(:same_catalogue)
    Trash.lock_catalogues!([from_catalogue_uuid, catalogue_uuid])

    current =
      case lock_live_item(item) do
        {:ok, %Item{catalogue_uuid: ^from_catalogue_uuid} = current} -> current
        {:ok, _moved_meanwhile} -> repo().rollback(:catalogue_moved)
        {:error, reason} -> repo().rollback(reason)
      end

    Shared.check_move_destination!(from_catalogue_uuid, catalogue_uuid)

    case current
         |> Item.changeset(%{catalogue_uuid: catalogue_uuid, category_uuid: nil})
         |> repo().update() do
      {:ok, moved} ->
        {moved, current}

      {:error, changeset} ->
        repo().rollback(
          if Trash.external_id_conflict?(changeset), do: :external_id_taken, else: changeset
        )
    end
  end

  defp resolve_move_attrs(nil), do: {:ok, %{category_uuid: nil}}

  defp resolve_move_attrs(category_uuid) when is_binary(category_uuid) do
    case repo().one(from(c in Category, where: c.uuid == ^category_uuid, lock: "FOR SHARE")) do
      # A live item moved into a trashed category would vanish from the tree.
      %Category{status: "deleted"} ->
        {:error, :category_not_found}

      %Category{catalogue_uuid: cat_uuid} ->
        {:ok, %{category_uuid: category_uuid, catalogue_uuid: cat_uuid}}

      nil ->
        {:error, :category_not_found}
    end
  end

  # The item as it is now, row-locked; a trashed item is not movable (a
  # stale form or tab would otherwise carry a bin row somewhere new).
  defp lock_live_item(%Item{uuid: uuid}) do
    case repo().one(from(i in Item, where: i.uuid == ^uuid, lock: "FOR UPDATE")) do
      %Item{status: status} = current when status != "deleted" -> {:ok, current}
      _ -> {:error, :not_found}
    end
  end

  defp same_kind(_from, nil), do: :ok
  defp same_kind(same, same), do: :ok

  defp same_kind(from_uuid, to_uuid) do
    kinds =
      from(c in Catalogue, where: c.uuid in ^[from_uuid, to_uuid], select: {c.uuid, c.kind})
      |> repo().all()
      |> Map.new()

    if Map.get(kinds, from_uuid) == Map.get(kinds, to_uuid),
      do: :ok,
      else: {:error, :kind_mismatch}
  end

  @doc """
  Moves an item to a different catalogue, clearing its category.

  For smart items this is the whole move — categories don't apply; for
  standard items it files the item uncategorized in the target. Sets
  both `catalogue_uuid` and `category_uuid` in one update.

  Returns `{:error, :catalogue_not_found}` if the target catalogue is
  missing or trashed, `{:error, :same_catalogue}` if the item is already
  there, `{:error, :kind_mismatch}` for a catalogue of the other kind,
  `{:error, :not_found}` for a trashed item, `{:error, :external_id_taken}`
  when the target already holds a live item with the same `external_id`, or
  `{:error, changeset}` on validation failure. Inside a caller's own
  transaction that collision is raised as the `Postgrex.Error` instead,
  because the database has already aborted that transaction. Both
  catalogues' locks are held, so a concurrent
  trash of either cannot interleave. Logs an `item.moved` activity with
  from/to catalogue metadata and tells both catalogues.

  ## Examples

      {:ok, item} = Catalogue.move_item_to_catalogue(item, other_smart.uuid)
  """
  @spec move_item_to_catalogue(Item.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Item.t()}
          | {:error,
             :catalogue_not_found
             | :same_catalogue
             | :kind_mismatch
             | :not_found
             | :catalogue_moved
             | :external_id_taken
             | Ecto.Changeset.t(Item.t())}
  def move_item_to_catalogue(%Item{} = item, catalogue_uuid, opts \\ [])
      when is_binary(catalogue_uuid) do
    # Whether the item is already there is decided from the row under the
    # lock, not from the caller's struct, which may be stale.
    if Shared.valid_uuid?(catalogue_uuid),
      do: do_move_item_to_catalogue(item, catalogue_uuid, opts),
      else: {:error, :catalogue_not_found}
  end

  defp do_move_item_to_catalogue(item, catalogue_uuid, opts) do
    result =
      Trash.locked_transaction(fn -> locked_move_item_to_catalogue(item, catalogue_uuid) end)

    with {:ok, {moved, before}} <- result do
      Shared.log_activity(
        %{
          action: "item.moved",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "item",
          resource_uuid: moved.uuid,
          parent_catalogue_uuid: catalogue_uuid,
          metadata: %{
            "name" => moved.name,
            "changes" =>
              ActivityLog.changes([
                {:catalogue, Shared.catalogue_ref(before.catalogue_uuid),
                 Shared.catalogue_ref(catalogue_uuid)},
                {:category, Shared.category_ref(before.category_uuid), Shared.category_ref(nil)}
              ])
          }
        },
        Keyword.take(opts, [:broadcast, :mode])
      )

      if Keyword.get(opts, :broadcast, true),
        do: PubSub.broadcast(:item, nil, before.catalogue_uuid)

      MediaFolders.follow([{before, moved}], opts[:actor_uuid])
      {:ok, moved}
    end
  end

  @doc "Returns a changeset for tracking item changes."
  @spec change_item(Item.t(), map()) :: Ecto.Changeset.t(Item.t())
  def change_item(%Item{} = item, attrs \\ %{}) do
    Item.changeset(item, attrs)
  end

  @doc """
  Returns the full pricing breakdown for an item within its catalogue.

  Resolves both the catalogue's markup and discount (loading the
  catalogue association once if needed), then computes the sale price
  (after markup) and final price (after discount). The chain is
  `base → markup → discount`:

      sale_price  = base_price * (1 + effective_markup   / 100)
      final_price = sale_price  * (1 -  effective_discount / 100)

  Never raises — if the catalogue can't be loaded (e.g. DB hiccup), falls
  back to 0% markup and 0% discount and logs a warning so the caller
  still gets a renderable result instead of crashing a template.

  Returns a map with every field a pricing UI needs in one hop:

    * `:base_price` — the item's stored base price (or `nil` if unset)
    * `:catalogue_markup` — the catalogue's `markup_percentage` (the
      inherited default when the item has no override)
    * `:item_markup` — the item's markup override, or `nil` when
      inheriting from the catalogue
    * `:markup_percentage` — the markup actually applied (item override
      if set, otherwise catalogue's)
    * `:sale_price` — the price after markup, before any discount
      (or `nil` if no base price)
    * `:catalogue_discount` — the catalogue's `discount_percentage`
    * `:item_discount` — the item's discount override, or `nil` when
      inheriting from the catalogue
    * `:discount_percentage` — the discount actually applied (item
      override if set, otherwise catalogue's)
    * `:discount_amount` — the Decimal amount subtracted by the discount
      (`sale_price - final_price`), or `nil` if no discount applies or
      no base price
    * `:final_price` — the price after both markup and discount (or
      `nil` if no base price)

  ## Examples

      # Item inherits both markup (15%) and discount (10%)
      Catalogue.item_pricing(item)
      #=> %{
      #=>   base_price: Decimal.new("100.00"),
      #=>   catalogue_markup: Decimal.new("15.0"),
      #=>   item_markup: nil,
      #=>   markup_percentage: Decimal.new("15.0"),
      #=>   sale_price: Decimal.new("115.00"),
      #=>   catalogue_discount: Decimal.new("10.0"),
      #=>   item_discount: nil,
      #=>   discount_percentage: Decimal.new("10.0"),
      #=>   discount_amount: Decimal.new("11.50"),
      #=>   final_price: Decimal.new("103.50")
      #=> }

      # Item overrides discount to 0 — sale price is charged at full
      Catalogue.item_pricing(item_with_zero_discount)
      #=> %{..., final_price: Decimal.new("115.00"), discount_amount: Decimal.new("0.00"), ...}
  """
  @spec item_pricing(Item.t()) :: %{
          base_price: Decimal.t() | nil,
          catalogue_markup: Decimal.t() | nil,
          item_markup: Decimal.t() | nil,
          markup_percentage: Decimal.t() | nil,
          sale_price: Decimal.t() | nil,
          catalogue_discount: Decimal.t() | nil,
          item_discount: Decimal.t() | nil,
          discount_percentage: Decimal.t() | nil,
          discount_amount: Decimal.t() | nil,
          final_price: Decimal.t() | nil
        }
  def item_pricing(%Item{} = item) do
    {catalogue_markup, catalogue_discount} = safe_pricing_for_item(item)
    effective_markup = Item.effective_markup(item, catalogue_markup)
    effective_discount = Item.effective_discount(item, catalogue_discount)

    %{
      base_price: item.base_price,
      catalogue_markup: catalogue_markup,
      item_markup: item.markup_percentage,
      markup_percentage: effective_markup,
      sale_price: Item.sale_price(item, catalogue_markup),
      catalogue_discount: catalogue_discount,
      item_discount: item.discount_percentage,
      discount_percentage: effective_discount,
      discount_amount: Item.discount_amount(item, catalogue_markup, catalogue_discount),
      final_price: Item.final_price(item, catalogue_markup, catalogue_discount)
    }
  end

  @doc """
  The item type that actually applies to `item` — goods or service. The
  UI's entry point: unlike `Item.effective_type/1` it never raises and needs
  no preload. The item's own `item_type` answers without a query; otherwise
  a preloaded catalogue (or `category.catalogue`) is used, and failing that
  the catalogue's type is read — whatever the catalogue's status. An item
  without a catalogue (or whose catalogue row is gone) reads as goods.
  """
  @spec effective_item_type(Item.t()) :: String.t()
  def effective_item_type(%Item{item_type: type}) when is_binary(type), do: type

  def effective_item_type(%Item{} = item),
    do: Item.effective_type(item, catalogue_item_type(item))

  defp catalogue_item_type(%Item{catalogue: %Catalogue{item_type: type}}), do: type
  defp catalogue_item_type(%Item{catalogue: nil}), do: nil

  defp catalogue_item_type(%Item{category: %Category{catalogue: %Catalogue{item_type: type}}}),
    do: type

  defp catalogue_item_type(%Item{catalogue_uuid: uuid}) when is_binary(uuid) do
    repo().one(from(c in Catalogue, where: c.uuid == ^uuid, select: c.item_type))
  rescue
    # `effective_item_type/1` never raises — it is called while rendering —
    # so a failed read answers "no catalogue type" (goods). Said in the log,
    # or a database error would pass for an item without a catalogue.
    e ->
      Logger.warning(
        "Catalogue.effective_item_type: catalogue type read failed (#{inspect(e.__struct__)}); " <>
          "treating the item as having no catalogue type"
      )

      nil
  end

  defp catalogue_item_type(_item), do: nil

  # Returns {markup, discount} from the item's catalogue. Preloads
  # the catalogue association if needed; falls back to {0, 0} on any
  # failure so pricing rendering never crashes a template. One preload
  # handles both values.
  defp safe_pricing_for_item(item) do
    case item.catalogue do
      %Catalogue{} = catalogue ->
        {markup_from(catalogue), discount_from(catalogue)}

      %Ecto.Association.NotLoaded{} ->
        load_pricing(item)

      _ ->
        {Decimal.new("0"), Decimal.new("0")}
    end
  end

  defp load_pricing(item) do
    case repo().preload(item, [:catalogue]) do
      %Item{catalogue: %Catalogue{} = catalogue} ->
        {markup_from(catalogue), discount_from(catalogue)}

      _ ->
        {Decimal.new("0"), Decimal.new("0")}
    end
  rescue
    e ->
      Logger.warning(
        "[Catalogue] Failed to load catalogue for item_pricing/1 (item #{item.uuid}): " <>
          Exception.message(e)
      )

      {Decimal.new("0"), Decimal.new("0")}
  end

  defp markup_from(%Catalogue{markup_percentage: nil}), do: Decimal.new("0")
  defp markup_from(%Catalogue{markup_percentage: mp}), do: mp

  defp discount_from(%Catalogue{discount_percentage: nil}), do: Decimal.new("0")
  defp discount_from(%Catalogue{discount_percentage: d}), do: d
end
