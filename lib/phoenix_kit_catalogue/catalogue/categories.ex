defmodule PhoenixKitCatalogue.Catalogue.Categories do
  @moduledoc """
  Categories — the nested tree inside a catalogue: listing, CRUD, moves
  (within and across catalogues), subtree trash / restore / permanent
  delete, positions and the bulk category actions.

  Public surface is re-exported from `PhoenixKitCatalogue.Catalogue` via
  `defdelegate`, so callers keep using the canonical context module.
  """

  import Ecto.Query, warn: false

  alias PhoenixKitCatalogue.Catalogue.{ActivityLog, Helpers, PubSub, Shared, Trash, Tree}
  alias PhoenixKitCatalogue.MediaFolders
  alias PhoenixKitCatalogue.Schemas.{Catalogue, Category, Item}

  @reorder_max_uuids Shared.reorder_max_uuids()

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @category_logged_fields [
    :name,
    :status,
    :description,
    :parent_uuid,
    :position,
    :slug,
    :ai_notes,
    :internal
  ]

  @category_slugs_table "phoenix_kit_cat_category_slugs"

  @doc """
  Lists non-deleted categories for a catalogue, ordered by position then name.

  Preloads items (non-deleted only).
  """
  @spec list_categories_for_catalogue(Ecto.UUID.t()) :: [Category.t()]
  def list_categories_for_catalogue(catalogue_uuid) do
    from(c in Category,
      where: c.catalogue_uuid == ^catalogue_uuid and c.status != "deleted",
      order_by: [asc: :position, asc: :name],
      preload: [:items]
    )
    |> repo().all()
  end

  @doc """
  Lists categories for a catalogue **without** preloading items, ordered by
  position then name. Used by the infinite-scroll detail view to walk
  categories in display order without fetching potentially thousands of
  items up front.

  ## Options

    * `:mode` — `:active` (default, excludes deleted categories) or
      `:deleted` (all categories — deleted categories can still contain
      trashed items we want to show).
  """
  @spec list_categories_metadata_for_catalogue(Ecto.UUID.t(), keyword()) :: [Category.t()]
  def list_categories_metadata_for_catalogue(catalogue_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)

    query =
      from(c in Category,
        where: c.catalogue_uuid == ^catalogue_uuid,
        order_by: [asc: :position, asc: :name]
      )

    query =
      case mode do
        :active -> where(query, [c], c.status != "deleted")
        :deleted -> query
      end

    repo().all(query)
  end

  @doc """
  One-shot helper for lazy-loading a catalogue's category tree. Returns
  category metadata plus per-category and uncategorized item counts in
  two queries instead of three.

  Combines the work of:

    * `list_categories_metadata_for_catalogue/2`
    * `item_counts_by_category_for_catalogue/2`
    * `uncategorized_count_for_catalogue/2`

  Categories are ordered the same way `list_categories_metadata_for_catalogue/2`
  orders them. Empty categories don't appear in `:item_counts` (treat
  missing keys as `0`).

  ## Options

    * `:mode` — `:active` (default, excludes deleted) or `:deleted`.
      Mode is applied uniformly to both the categories query and the
      item-count query.
  """
  @spec category_summary_for_catalogue(Ecto.UUID.t(), keyword()) :: %{
          categories: [Category.t()],
          item_counts: %{Ecto.UUID.t() => non_neg_integer()},
          uncategorized_count: non_neg_integer()
        }
  def category_summary_for_catalogue(catalogue_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)

    categories = list_categories_metadata_for_catalogue(catalogue_uuid, mode: mode)

    rows =
      from(i in Item,
        where: i.catalogue_uuid == ^catalogue_uuid,
        group_by: i.category_uuid,
        select: {i.category_uuid, count(i.uuid)}
      )
      |> apply_summary_mode(mode)
      |> repo().all()

    {item_counts, uncategorized_count} =
      Enum.reduce(rows, {%{}, 0}, fn
        {nil, count}, {map, _} -> {map, count}
        {uuid, count}, {map, uncat} -> {Map.put(map, uuid, count), uncat}
      end)

    %{
      categories: categories,
      item_counts: item_counts,
      uncategorized_count: uncategorized_count
    }
  end

  defp apply_summary_mode(query, :active),
    do: where(query, [i], i.status != "deleted")

  defp apply_summary_mode(query, :deleted),
    do: where(query, [i], i.status == "deleted")

  @doc """
  Lists all non-deleted categories across all non-deleted catalogues,
  with breadcrumb-style names prefixed by their catalogue and every
  ancestor category (e.g. `"Kitchen / Cabinets / Frames"`). Useful for
  item move dropdowns where the user needs to distinguish
  same-named leaves under different parents.

  Entries are grouped by catalogue (catalogues ordered by name) and
  within each catalogue returned in depth-first display order.

  One query for catalogues + one query for all their categories — the
  tree walk and breadcrumb rewrite happen in memory. Safe to call on
  demand from move-dropdowns.
  """
  @spec list_all_categories() :: [Category.t()]
  def list_all_categories do
    catalogues =
      from(cat in Catalogue,
        where: cat.status != "deleted",
        order_by: [asc: cat.position, asc: cat.name]
      )
      |> repo().all()

    case catalogues do
      [] ->
        []

      catalogues ->
        catalogue_uuids = Enum.map(catalogues, & &1.uuid)

        categories_by_catalogue =
          from(c in Category,
            where: c.catalogue_uuid in ^catalogue_uuids and c.status != "deleted",
            order_by: [asc: :position, asc: :name]
          )
          |> repo().all()
          |> Enum.group_by(& &1.catalogue_uuid)

        Enum.flat_map(catalogues, fn %Catalogue{uuid: uuid, name: cat_name} ->
          categories = Map.get(categories_by_catalogue, uuid, [])
          breadcrumb_categories_for_catalogue(cat_name, categories)
        end)
    end
  end

  # Builds the depth-first list of `%Category{name: "A / B / C"}` for
  # one catalogue from a flat, pre-sorted list of its categories.
  defp breadcrumb_categories_for_catalogue(cat_name, categories) when is_list(categories) do
    uuid_set = MapSet.new(categories, & &1.uuid)

    # Promote orphans (children whose parent isn't in this list because
    # it's been deleted or excluded) to roots so they still appear.
    normalized =
      Enum.map(categories, fn c ->
        if c.parent_uuid == nil or MapSet.member?(uuid_set, c.parent_uuid) do
          c
        else
          %{c | parent_uuid: nil}
        end
      end)

    index = Tree.build_children_index(normalized)

    {reversed, _} =
      normalized
      |> Enum.filter(&is_nil(&1.parent_uuid))
      |> Enum.reduce({[], %{}}, fn root, {acc, path_by_uuid} ->
        collect_breadcrumb(root, index, cat_name, path_by_uuid, acc)
      end)

    Enum.reverse(reversed)
  end

  defp collect_breadcrumb(%Category{} = cat, index, catalogue_name, path_by_uuid, acc) do
    parent_label =
      case cat.parent_uuid do
        nil -> catalogue_name
        parent_uuid -> Map.get(path_by_uuid, parent_uuid, catalogue_name)
      end

    full_label = "#{parent_label} / #{cat.name}"
    labeled = %{cat | name: full_label}
    path_by_uuid = Map.put(path_by_uuid, cat.uuid, full_label)
    acc = [labeled | acc]

    index
    |> Map.get(cat.uuid, [])
    |> Enum.reduce({acc, path_by_uuid}, fn child, {acc, path_by_uuid} ->
      collect_breadcrumb(child, index, catalogue_name, path_by_uuid, acc)
    end)
  end

  @doc "Fetches a category by UUID. Returns `nil` if not found."
  @spec get_category(Ecto.UUID.t()) :: Category.t() | nil
  def get_category(uuid), do: Helpers.get_by_uuid(Category, uuid)

  @doc "Fetches a category by UUID. Raises `Ecto.NoResultsError` if not found."
  @spec get_category!(Ecto.UUID.t()) :: Category.t()
  def get_category!(uuid), do: Helpers.get_by_uuid!(Category, uuid)

  @doc """
  Fetches a category by its per-language `slug`.

  Tries an exact match in `lang`'s base language first (`"en-US"` folds
  to `"en"`), falling back to any language when `opts[:any_lang]` is
  `true`. The result is `{:error, :not_found}` on a miss; a hit is a
  2-tuple by default, or — whenever `opts[:any_lang]` is `true`, even
  when the base language itself matched — a 3-tuple carrying the
  language the slug actually matched in, so a caller that opted into
  the fallback can always destructure the same shape.
  """
  @spec get_category_by_slug(String.t(), String.t(), keyword()) ::
          {:ok, Category.t()} | {:ok, Category.t(), String.t()} | {:error, :not_found}
  def get_category_by_slug(slug, lang, opts \\ []) do
    Shared.find_by_slug(@category_slugs_table, "category_uuid", slug, lang, opts, fn uuid,
                                                                                     _opts ->
      get_category(uuid)
    end)
  end

  @doc """
  Creates a category within a catalogue.

  ## Required attributes

    * `:name` — category name (1-255 chars)
    * `:catalogue_uuid` — the parent catalogue

  ## Optional attributes

    * `:description`, `:position` (default 0), `:status` (`"active"` or `"deleted"`)
    * `:data` — flexible JSON map

  ## Examples

      Catalogue.create_category(%{name: "Frames", catalogue_uuid: catalogue.uuid})
  """
  @spec create_category(map(), keyword()) ::
          {:ok, Category.t()} | {:error, Ecto.Changeset.t(Category.t())}
  def create_category(attrs, opts \\ []) do
    # One transaction, so the parent read `FOR SHARE` in the catalogue
    # check holds until the insert commits: a move of the parent's tree
    # to another catalogue either lands first (and the check sees the new
    # catalogue) or waits and then carries the new child along.
    result =
      repo().transaction(fn ->
        %Category{}
        |> Category.changeset(put_default_category_position(attrs))
        |> validate_parent_in_same_catalogue()
        |> Shared.stamp_created_deleted()
        |> repo().insert()
        |> case do
          {:ok, category} -> category
          {:error, changeset} -> repo().rollback(changeset)
        end
      end)

    case result do
      {:ok, category} = ok ->
        Shared.log_activity(
          %{
            action: "category.created",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "category",
            resource_uuid: category.uuid,
            parent_catalogue_uuid: category.catalogue_uuid,
            metadata: %{"name" => category.name, "catalogue_uuid" => category.catalogue_uuid}
          },
          Keyword.take(opts, [:broadcast, :mode, :log_metadata])
        )

        ok

      error ->
        error
    end
  end

  @doc """
  Updates a category with the given attributes.

  Pass `:data_owned_keys` (a list of top-level `data` keys) when the
  caller only owns PART of `data` — e.g. a form that only rendered a
  subset of it. See `update_item/3`'s doc for the full rationale; the
  mechanism is identical.

  Takes `:data_owned_paths`, `:logged_data_paths` and `:log_metadata` exactly as
  `update_item/3` does (the row is read `FOR UPDATE`, the update applies to it,
  only the named `data` paths are copied).

  The logged `from` values are those of the row as it is stored when the update
  runs (the locked row), not of the caller's copy: under `:data_owned_paths`
  always, and without it when the parent changes.
  """
  @spec update_category(Category.t(), map(), keyword()) ::
          {:ok, Category.t()}
          | {:error, Ecto.Changeset.t(Category.t()) | :not_found | :catalogue_moved}
  def update_category(%Category{} = category, attrs, opts \\ []) do
    paths = Shared.owned_paths!(opts)

    result =
      Trash.locked_transaction(fn ->
        # A new parent is checked for a cycle against the tree as committed:
        # under the lock of the catalogue the row is in now (not the
        # caller's copy's), taken before any row lock — the order
        # `move_category_under/3` takes them in — so two opposite re-parents
        # neither both pass nor deadlock on each other's rows. The checks
        # then run on the locked row.
        category =
          if reparenting?(category, attrs),
            do: Trash.lock_row_in_catalogue!(Category, category.uuid),
            else: category

        {attrs, base} = narrow_category_data(category, attrs, paths, opts)

        changeset =
          base
          |> Category.changeset(attrs)
          |> Shared.keep_trash_status(Category, base.uuid)
          |> validate_parent_in_same_catalogue()

        case repo().update(changeset) do
          {:ok, updated} -> {base, updated}
          {:error, changeset} -> repo().rollback(changeset)
        end
      end)

    case result do
      {:ok, {before, updated}} ->
        Shared.log_activity(
          %{
            action: "category.updated",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "category",
            resource_uuid: updated.uuid,
            parent_catalogue_uuid: updated.catalogue_uuid,
            metadata:
              ActivityLog.with_changes(
                %{"name" => updated.name},
                before,
                updated,
                @category_logged_fields,
                Keyword.get(opts, :logged_data_paths, [])
              )
          },
          opts
        )

        MediaFolders.follow([{before, updated}], opts[:actor_uuid])
        {:ok, updated}

      {:error, _reason} = error ->
        error
    end
  end

  defp narrow_category_data(%Category{} = category, attrs, paths, opts) do
    case paths do
      nil ->
        {Shared.narrow_data_ownership(Category, category.uuid, attrs, opts), category}

      paths ->
        case Shared.lock_fresh(Category, category.uuid) do
          nil -> repo().rollback(:not_found)
          fresh -> {Shared.splice_owned_paths(fresh, attrs, paths), fresh}
        end
    end
  end

  # Any change of parent, to the top level included: a move there skips
  # no cycle check, but it must not slip past the lock a trash or restore
  # decides the subtree under.
  defp reparenting?(%Category{parent_uuid: current}, attrs) do
    case Map.get(attrs, :parent_uuid, Map.get(attrs, "parent_uuid", current)) do
      parent when parent in [nil, ""] -> not is_nil(current)
      parent -> to_string(parent) != to_string(current)
    end
  end

  # Guards both create_category/2 and update_category/3 against a
  # `parent_uuid` that names a category in a different catalogue, AND
  # against cycles on update (a raw
  # `update_category(cat, %{parent_uuid: descendant.uuid})` would
  # otherwise sail past the `move_category_under/3` checks). The
  # self-parent rejection lives on `Category.changeset`; the
  # cross-catalogue and full-subtree cycle checks need DB lookups, so
  # they live here.
  defp validate_parent_in_same_catalogue(%Ecto.Changeset{} = changeset) do
    catalogue_uuid = Ecto.Changeset.get_field(changeset, :catalogue_uuid)
    parent_uuid = Ecto.Changeset.get_field(changeset, :parent_uuid)
    own_uuid = Ecto.Changeset.get_field(changeset, :uuid)

    cond do
      parent_uuid in [nil, ""] ->
        changeset

      is_nil(catalogue_uuid) ->
        Ecto.Changeset.add_error(
          changeset,
          :parent_uuid,
          "cannot be set without a catalogue"
        )

      own_uuid && cycle?(parent_uuid, own_uuid) ->
        Ecto.Changeset.add_error(
          changeset,
          :parent_uuid,
          "would create a cycle"
        )

      true ->
        check_parent_catalogue(changeset, parent_uuid, catalogue_uuid)
    end
  end

  # `Tree.subtree_uuids/1` returns raw 16-byte binaries (the schema-less
  # outer CTE select strips Ecto's type info). The textual `parent_uuid`
  # we got from the changeset doesn't match those, so dump it to the
  # raw binary form before the membership test. Without this, a real
  # cycle is silently accepted — the test
  # `update_category/3 rejects a parent that is a descendant (cycle)`
  # pins the regression.
  defp cycle?(parent_uuid, own_uuid) do
    case Ecto.UUID.dump(parent_uuid) do
      {:ok, raw} -> raw in Tree.subtree_uuids(own_uuid)
      :error -> false
    end
  end

  # `FOR SHARE`: callers run inside a transaction, so the parent cannot
  # change catalogue between this check and their write.
  # A parent being SET must be live: a new or moved category under a
  # trashed one would be a live row inside the trash. A row that keeps its
  # parent (a restore, an edit of other fields) is not re-checked for it.
  defp check_parent_catalogue(changeset, parent_uuid, catalogue_uuid) do
    case repo().one(from(c in Category, where: c.uuid == ^parent_uuid, lock: "FOR SHARE")) do
      nil ->
        Ecto.Changeset.add_error(changeset, :parent_uuid, "does not exist")

      %Category{status: "deleted"} = parent ->
        if Ecto.Changeset.get_change(changeset, :parent_uuid),
          do: Ecto.Changeset.add_error(changeset, :parent_uuid, "does not exist"),
          else: check_same_catalogue(changeset, parent, catalogue_uuid)

      %Category{} = parent ->
        check_same_catalogue(changeset, parent, catalogue_uuid)
    end
  end

  defp check_same_catalogue(changeset, %Category{catalogue_uuid: catalogue_uuid}, catalogue_uuid),
    do: changeset

  defp check_same_catalogue(changeset, _parent, _catalogue_uuid),
    do: Ecto.Changeset.add_error(changeset, :parent_uuid, "must belong to the same catalogue")

  @doc "Hard-deletes a category. Prefer `trash_category/1` for soft-delete."
  @spec delete_category(Category.t(), keyword()) :: {:ok, Category.t()} | {:error, term()}
  def delete_category(%Category{} = category, opts \\ []) do
    release = MediaFolders.release_plan([from(c in Category, where: c.uuid == ^category.uuid)])

    case repo().delete(category) do
      {:ok, _} = ok ->
        MediaFolders.release(release)

        Shared.log_activity(%{
          action: "category.deleted",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "category",
          resource_uuid: category.uuid,
          parent_catalogue_uuid: category.catalogue_uuid,
          metadata: %{"name" => category.name}
        })

        ok

      error ->
        error
    end
  end

  @doc """
  Soft-deletes a category and its entire subtree by setting their
  status to `"deleted"`.

  **Cascades the categories downward** in a transaction (the category
  itself and every descendant flip to `"deleted"`), following the V103
  nested-category tree.

  **Items in the subtree** are handled per the `:items` opt:

    * `:cascade` (default) — items in the subtree flip to `"deleted"`
      alongside the categories. Original behavior, kept for programmatic
      callers + admin "delete and trash everything" intent.
    * `:uncategorize` — items in the subtree keep their `catalogue_uuid`
      but get `category_uuid: nil`, surviving the category trash. Used
      by the admin modal when the operator wants the category gone but
      the items kept in the same catalogue.
    * `{:move_to, target_uuid}` — items move to the target category
      (which must live in the same catalogue) before the category is
      trashed. Cross-catalogue moves aren't supported here; the LV
      restricts the dropdown to same-catalogue targets.

  Every category and cascaded item it flips is stamped as taken by this
  category, so `restore_category/2` can bring back exactly that set
  (`dev_docs/guides/trash-and-restore.md`). `{:move_to, _}` refuses a
  trashed target with `{:error, :move_target_not_found}`.

  Logs a single `category.trashed` activity on the root with
  `subtree_size`, `items_handled`, and `items_disposition` in metadata.
  Options besides `:items`: `:actor_uuid`, `:mode`, `:broadcast` (`false`
  sends no PubSub event) and `:log_metadata` (extra keys for the entry).

  ## Examples

      {:ok, _} = Catalogue.trash_category(category)
      {:ok, _} = Catalogue.trash_category(category, items: :uncategorize)
      {:ok, _} = Catalogue.trash_category(category, items: {:move_to, target_uuid})
  """
  @spec trash_category(Category.t(), keyword()) ::
          {:ok, Category.t()}
          | {:error,
             :move_target_not_found
             | :cross_catalogue_move
             | :move_target_in_subtree
             | term()}
  def trash_category(%Category{} = category, opts \\ []) do
    with {:ok, _outcome, updated} <- trash_category_outcome(category, opts), do: {:ok, updated}
  end

  @doc """
  `trash_category/2` that tells whether THIS call trashed anything:
  `{:ok, :trashed, category}`, or `{:ok, :already_trashed, category}` when the
  category was in the trash already with nothing live under it (a concurrent
  trash that landed first); nothing is changed or logged then.
  """
  @spec trash_category_outcome(Category.t(), keyword()) ::
          {:ok, :trashed | :already_trashed, Category.t()}
          | {:error,
             :move_target_not_found
             | :cross_catalogue_move
             | :move_target_in_subtree
             | term()}
  def trash_category_outcome(%Category{} = category, opts \\ []) do
    disposition = Keyword.get(opts, :items, :cascade)

    result =
      Trash.locked_transaction(fn ->
        category = Trash.lock_row_in_catalogue!(Category, category.uuid)
        now = DateTime.utc_now()
        subtree = Tree.subtree_uuids(category.uuid)
        Trash.lock_categories!(subtree)
        moving = disposition_moving(disposition, subtree)

        case apply_item_disposition(disposition, subtree, category, now) do
          {:ok, items_handled} ->
            root = category.uuid

            {children, _} =
              from(c in Category,
                where: c.uuid in ^subtree and c.uuid != ^root and c.status != "deleted"
              )
              |> Trash.stamp_trashed("category", root, now)
              |> repo().update_all([])

            {self, _} =
              from(c in Category, where: c.uuid == ^root and c.status != "deleted")
              |> Trash.stamp_trashed("self", root, now)
              |> repo().update_all([])

            changed? = children + self + items_handled > 0
            pairs = disposition_pairs(moving, disposition, category)
            {repo().get!(Category, root), length(subtree), items_handled, changed?, pairs}

          {:error, reason} ->
            repo().rollback(reason)
        end
      end)

    case result do
      # Already in the trash with nothing live under it: this call trashed
      # nothing, so it records nothing.
      {:ok, {updated, _subtree_size, _items_handled, false, _pairs}} ->
        {:ok, :already_trashed, updated}

      {:ok, {updated, subtree_size, items_handled, true, pairs}} ->
        MediaFolders.follow(pairs, opts[:actor_uuid])

        # `broadcast: false` lets `bulk_trash_categories/3` run this inside
        # its own transaction and fan out once after that commits.
        Shared.log_activity(
          %{
            action: "category.trashed",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "category",
            resource_uuid: updated.uuid,
            parent_catalogue_uuid: updated.catalogue_uuid,
            metadata: %{
              "name" => updated.name,
              "catalogue_uuid" => updated.catalogue_uuid,
              "subtree_size" => subtree_size,
              "items_handled" => items_handled,
              "items_disposition" => disposition_to_metadata(disposition)
            }
          },
          Keyword.take(opts, [:log_metadata, :broadcast, :mode])
        )

        {:ok, :trashed, updated}

      error ->
        error
    end
  end

  # The items a trash takes out of the subtree, with a folder, as they are
  # now — their folders follow them to the catalogue or the target category.
  defp disposition_moving(:cascade, _subtree), do: []

  defp disposition_moving(_disposition, subtree) do
    MediaFolders.moving_records(
      from(i in Item, where: i.category_uuid in ^subtree and i.status != "deleted")
    )
  end

  defp disposition_pairs(moving, :uncategorize, category),
    do:
      Enum.map(moving, &{&1, %{&1 | category_uuid: nil, catalogue_uuid: category.catalogue_uuid}})

  defp disposition_pairs(moving, {:move_to, target_uuid}, category) do
    Enum.map(
      moving,
      &{&1, %{&1 | category_uuid: target_uuid, catalogue_uuid: category.catalogue_uuid}}
    )
  end

  defp disposition_pairs(_moving, _disposition, _category), do: []

  defp apply_item_disposition(:cascade, subtree, category, now) do
    {count, _} =
      from(i in Item,
        where: i.category_uuid in ^subtree and i.status != "deleted"
      )
      |> Trash.stamp_trashed("category", category.uuid, now)
      |> repo().update_all([])

    {:ok, count}
  end

  defp apply_item_disposition(:uncategorize, subtree, category, now) do
    {count, _} =
      from(i in Item,
        where: i.category_uuid in ^subtree and i.status != "deleted"
      )
      |> repo().update_all(
        set: [category_uuid: nil, catalogue_uuid: category.catalogue_uuid, updated_at: now]
      )

    {:ok, count}
  end

  defp apply_item_disposition({:move_to, target_uuid}, subtree, category, now) do
    case Helpers.get_by_uuid(Category, target_uuid) do
      nil ->
        {:error, :move_target_not_found}

      # Moving live items into a trashed category would hide them.
      %Category{status: "deleted"} ->
        {:error, :move_target_not_found}

      %Category{catalogue_uuid: target_cat_uuid}
      when target_cat_uuid != category.catalogue_uuid ->
        {:error, :cross_catalogue_move}

      %Category{uuid: ^target_uuid} = target ->
        # The picker hides the subtree, but a crafted target inside it
        # would reparent items onto a category this same transaction then
        # deletes — leaving live items in a deleted category.
        if in_subtree?(target.uuid, subtree) do
          {:error, :move_target_in_subtree}
        else
          {count, _} =
            from(i in Item,
              where: i.category_uuid in ^subtree and i.status != "deleted"
            )
            |> repo().update_all(
              set: [
                category_uuid: target.uuid,
                catalogue_uuid: target.catalogue_uuid,
                updated_at: now
              ]
            )

          {:ok, count}
        end
    end
  end

  # `Tree.subtree_uuids/1` returns raw 16-byte binaries; loaded rows
  # carry the textual form.
  defp in_subtree?(textual_uuid, subtree) do
    case Ecto.UUID.dump(textual_uuid) do
      {:ok, dumped} -> dumped in subtree
      :error -> false
    end
  end

  defp disposition_to_metadata(:cascade), do: "cascade"
  defp disposition_to_metadata(:uncategorize), do: "uncategorize"
  defp disposition_to_metadata({:move_to, uuid}), do: "move_to:#{uuid}"

  @doc """
  Restores a soft-deleted category, and with it exactly what
  `trash_category/2` took: the descendant categories and the items
  stamped as taken by THIS category, each back to the status it had.

  - **Refuses with `{:error, :parent_catalogue_deleted}`** when the
    catalogue is deleted — restore the catalogue first.
  - Rows trashed on their own (a descendant category, an item), rows a
    different trash took, and deleted rows with no stamp (they predate
    provenance) stay in the trash. So restoring a leaf of a trashed
    subtree brings back only that leaf, which `list_category_tree/2`
    orphan-promotes to a root while its ancestors stay trashed.
  - An item whose own category is still trashed after the pass stays in
    the trash, so no live item sits in a trashed category.
  - Items that an `:uncategorize` / `{:move_to, _}` trash moved out stay
    where they were moved — those dispositions are not undone.

  A category that is not deleted is returned unchanged. Logs
  `category.restored` with `descendants_restored` and `items_restored`.

  Refuses with `{:error, :external_id_taken}` when a live row has taken the
  `external_id` of one of the rows coming back; nothing is restored.

  Inside a caller's own transaction the collision is raised as the
  `Postgrex.Error` instead, because the database has already aborted that
  transaction.

  ## Examples

      {:ok, _} = Catalogue.restore_category(category)
      {:error, :parent_catalogue_deleted} =
        Catalogue.restore_category(category_under_deleted_catalogue)
  """
  @spec restore_category(Category.t(), keyword()) ::
          {:ok, Category.t()}
          | {:error, :parent_catalogue_deleted | :not_found | term()}
  def restore_category(%Category{} = category, opts \\ []) do
    result =
      Trash.locked_transaction(fn ->
        fresh = Trash.lock_row_in_catalogue!(Category, category.uuid)

        if Shared.catalogue_deleted?(fresh.catalogue_uuid),
          do: repo().rollback(:parent_catalogue_deleted)

        if fresh.status == "deleted",
          do: {:restored, do_restore_category(fresh)},
          else: {:unchanged, {fresh, 0, 0}}
      end)

    case result do
      {:ok, {:restored, {updated, categories_restored, items_restored}}} ->
        Shared.log_activity(%{
          action: "category.restored",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "category",
          resource_uuid: updated.uuid,
          parent_catalogue_uuid: updated.catalogue_uuid,
          metadata: %{
            "name" => updated.name,
            "catalogue_uuid" => updated.catalogue_uuid,
            "descendants_restored" => categories_restored,
            "items_restored" => items_restored
          }
        })

        {:ok, updated}

      {:ok, {:unchanged, {fresh, _, _}}} ->
        {:ok, fresh}

      error ->
        error
    end
  end

  defp do_restore_category(%Category{uuid: root}) do
    now = DateTime.utc_now()
    subtree = Tree.subtree_uuids(root)
    Trash.lock_categories!(subtree)

    from(c in Category, where: c.uuid == ^root)
    |> Trash.restore_trashed(:category, now)
    |> repo().update_all([])

    {categories_restored, _} =
      from(c in Category,
        where: c.uuid in ^subtree and c.uuid != ^root and c.status == "deleted"
      )
      |> Trash.trashed_by(root)
      |> Trash.restore_trashed(:category, now)
      |> repo().update_all([])

    stamped_items =
      from(i in Item, as: :item, where: i.category_uuid in ^subtree and i.status == "deleted")
      |> Trash.trashed_by(root)

    {items_restored, _} =
      stamped_items
      |> Trash.outside_trashed_categories()
      |> Trash.restore_trashed(:item, now)
      |> repo().update_all([])

    Trash.restamp_left_behind!(stamped_items)

    {repo().get!(Category, root), categories_restored, items_restored}
  end

  @doc """
  Permanently deletes a category and its subtree from the database.

  A **live** category takes its entire subtree: every descendant category
  and every item in any of them. A **trashed** category takes only the
  trashed part: the trashed descendants reached without passing through a
  live one, and the items in those categories. A live subcategory under it
  (one restored on its own, which the Active tab already shows at the top
  level) is kept with its own subtree and moves to the end of the top level.
  Trashed rows under a kept subcategory that the removed categories' trash
  took are re-stamped to a root that still exists, so a Restore can bring
  them back together (see `dev_docs/guides/trash-and-restore.md`).

  Pass `only_trashed: true` from a Deleted-tab action: the call then
  refuses with `{:error, :not_in_trash}` when the category, re-read under
  the lock, is no longer trashed (restored in another tab meanwhile).

  Runs in one transaction. This cannot be undone.
  """
  @spec permanently_delete_category(Category.t(), keyword()) ::
          {:ok, Category.t()} | {:error, term()}
  def permanently_delete_category(%Category{} = category, opts \\ []) do
    result =
      Trash.locked_transaction(fn ->
        fresh = Trash.lock_row_in_catalogue!(Category, category.uuid)

        if opts[:only_trashed] == true and fresh.status != "deleted",
          do: repo().rollback(:not_in_trash)

        subtree = Tree.subtree_uuids(fresh.uuid)
        # Locked before the item delete: an item created in or moved into
        # the subtree meanwhile waits on its category row and then fails
        # its foreign key, instead of surviving uncategorized through
        # `ON DELETE SET NULL`.
        Trash.lock_categories!(subtree)

        {doomed, kept} = permanent_delete_split(fresh, subtree)

        release =
          MediaFolders.release_plan([
            from(c in Category, where: c.uuid in ^doomed),
            from(i in Item, where: i.category_uuid in ^doomed)
          ])

        # A live subcategory kept from a trashed parent moves to the top
        # level, where the Active tab already lists it, after its last row.
        # Its folder goes with it while its old parent still exists.
        moving = MediaFolders.moving_records(from(c in Category, where: c.uuid in ^kept))
        move_kept_to_top_level(fresh.catalogue_uuid, kept)

        moving
        |> Enum.map(&{&1, %{&1 | parent_uuid: nil}})
        |> MediaFolders.follow(opts[:actor_uuid])

        restamp_orphaned_trash(fresh.catalogue_uuid, subtree, doomed, kept)

        {items_cascaded, _} =
          from(i in Item, where: i.category_uuid in ^doomed)
          |> repo().delete_all()

        # V103's self-FK on parent_uuid has no ON DELETE CASCADE — a
        # straight `delete_all` would reject any parent row while its
        # children still reference it. Every row in `doomed` is being
        # deleted anyway, so NULL out parent_uuid first to break the
        # FKs between them, then delete in one shot.
        from(c in Category, where: c.uuid in ^doomed)
        |> repo().update_all(set: [parent_uuid: nil])

        from(c in Category, where: c.uuid in ^doomed)
        |> repo().delete_all()

        {length(doomed), items_cascaded, length(kept), release}
      end)

    case result do
      {:ok, {subtree_size, items_cascaded, kept_count, release}} ->
        MediaFolders.release(release)

        Shared.log_activity(%{
          action: "category.permanently_deleted",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "category",
          resource_uuid: category.uuid,
          parent_catalogue_uuid: category.catalogue_uuid,
          metadata: %{
            "name" => category.name,
            "catalogue_uuid" => category.catalogue_uuid,
            "subtree_size" => subtree_size,
            "items_cascaded" => items_cascaded,
            "kept_live_subcategories" => kept_count
          }
        })

        {:ok, category}

      error ->
        error
    end
  end

  @doc """
  What `permanently_delete_category/2` would remove, without removing it:
  `%{subcategories: n, items: m, dependents: d}`, the categories below the
  given one, the items in all of them, and how many other items list one
  of those as a dependency (those rows go with the delete — see
  `Catalogue.count_outside_dependents/1`). For a trashed category this includes rows that
  were trashed on their own before it, which its Restore does not bring
  back and its card does not count, so a Delete Forever confirmation can
  say what is really destroyed.
  """
  @spec permanent_delete_scope(Category.t()) :: %{
          subcategories: non_neg_integer(),
          items: non_neg_integer(),
          dependents: non_neg_integer()
        }
  def permanent_delete_scope(%Category{} = category) do
    case repo().get(Category, category.uuid) do
      nil ->
        %{subcategories: 0, items: 0, dependents: 0}

      fresh ->
        {doomed, _kept} = permanent_delete_split(fresh, Tree.subtree_uuids(fresh.uuid))
        items = from(i in Item, where: i.category_uuid in ^doomed) |> repo().aggregate(:count)

        %{
          subcategories: max(length(doomed) - 1, 0),
          items: items,
          dependents:
            PhoenixKitCatalogue.Catalogue.count_outside_dependents({:categories, doomed})
        }
    end
  end

  # What a permanent delete removes. A live root takes its whole subtree; a
  # trashed root takes the trashed categories reached from it without
  # crossing a live one, and returns the live children it stops at.
  defp permanent_delete_split(%Category{status: "deleted", uuid: root}, subtree) do
    children =
      from(c in Category, where: c.uuid in ^subtree, select: {c.uuid, c.parent_uuid, c.status})
      |> repo().all()
      |> Enum.group_by(&elem(&1, 1))

    walk_trashed([root], children, [], [])
  end

  defp permanent_delete_split(_live_root, subtree), do: {subtree, []}

  defp walk_trashed([], _children, doomed, kept), do: {doomed, kept}

  defp walk_trashed([uuid | rest], children, doomed, kept) do
    {trashed, live} =
      children
      |> Map.get(uuid, [])
      |> Enum.split_with(fn {_uuid, _parent, status} -> status == "deleted" end)

    walk_trashed(
      Enum.map(trashed, &elem(&1, 0)) ++ rest,
      children,
      [uuid | doomed],
      Enum.map(live, &elem(&1, 0)) ++ kept
    )
  end

  defp move_kept_to_top_level(_catalogue_uuid, []), do: :ok

  defp move_kept_to_top_level(catalogue_uuid, kept) do
    first = next_category_position(catalogue_uuid, nil)

    from(c in Category, where: c.uuid in ^kept, order_by: [c.position, c.uuid], select: c.uuid)
    |> repo().all()
    |> Enum.with_index(first)
    |> Enum.each(fn {uuid, position} ->
      from(c in Category, where: c.uuid == ^uuid)
      |> repo().update_all(set: [parent_uuid: nil, position: position])
    end)
  end

  # The rows under a kept subcategory that the removed categories' trash
  # took still name one of them as their root, so no Restore would bring
  # them back together. Each takes the root its nearest trashed parent has
  # (the topmost trashed category on its path becomes its own root), and an
  # item in a live category becomes trashed on its own. `from_status` stays.
  defp restamp_orphaned_trash(_catalogue_uuid, _subtree, _doomed, []), do: :ok

  defp restamp_orphaned_trash(catalogue_uuid, subtree, doomed, _kept),
    do: restamp_trash_roots(catalogue_uuid, subtree, doomed)

  # A moved subtree can carry trashed rows stamped with a root the move
  # takes them out from under — a category restored on its own while its
  # trashed ancestor stays in the bin, then moved. That root's Restore
  # walks its current subtree and would never reach them again, so they
  # are restamped the way Delete Forever restamps what it leaves behind.
  # `covering` are the roots still above the landing spot (its catalogue
  # and ancestors); a stamp naming one of them, or a row of the subtree
  # itself, still works and is left alone. Call it after the move.
  defp restamp_moved_trash!(catalogue_uuid, subtree, covering) do
    subtree = Enum.map(subtree, &uuid_string/1)
    keep = MapSet.new(subtree ++ Enum.map(covering, &uuid_string/1))

    category_roots =
      from(c in Category,
        where: c.uuid in ^subtree and c.status == "deleted",
        select: fragment("? #>> '{_trash,root}'", c.data)
      )

    item_roots =
      from(i in Item,
        where: i.category_uuid in ^subtree and i.status == "deleted",
        select: fragment("? #>> '{_trash,root}'", i.data)
      )

    doomed =
      category_roots
      |> union(^item_roots)
      |> repo().all()
      |> Enum.reject(&(is_nil(&1) or MapSet.member?(keep, &1)))

    if doomed != [], do: restamp_trash_roots(catalogue_uuid, subtree, doomed)
    :ok
  end

  defp restamp_trash_roots(catalogue_uuid, subtree, doomed) do
    doomed_set = MapSet.new(doomed)
    remaining = Enum.reject(subtree, &MapSet.member?(doomed_set, &1))

    info =
      from(c in Category,
        where: c.uuid in ^remaining,
        select: {c.uuid, {c.parent_uuid, c.status, fragment("? #>> '{_trash,root}'", c.data)}}
      )
      |> repo().all()
      |> Map.new()

    trashed = for {uuid, {_parent, "deleted", _root}} <- info, do: uuid
    live = for {uuid, {_parent, status, _root}} <- info, status != "deleted", do: uuid

    trashed
    |> Enum.group_by(&current_trash_root(&1, info, doomed_set, map_size(info)))
    |> Enum.each(fn {root, categories} ->
      via = if root == catalogue_uuid, do: "catalogue", else: "category"

      from(c in Category, where: c.uuid == ^root)
      |> orphaned_by(doomed)
      |> restamp_trash_self()
      |> repo().update_all([])

      from(c in Category, where: c.uuid in ^categories and c.uuid != ^root)
      |> orphaned_by(doomed)
      |> restamp_trash(via, root)
      |> repo().update_all([])

      from(i in Item, where: i.category_uuid in ^categories and i.status == "deleted")
      |> orphaned_by(doomed)
      |> restamp_trash(via, root)
      |> repo().update_all([])
    end)

    from(i in Item, where: i.category_uuid in ^live and i.status == "deleted")
    |> orphaned_by(doomed)
    |> restamp_trash_self()
    |> repo().update_all([])

    :ok
  end

  # The root a trashed category's row answers to once `doomed` is gone: its
  # own stamp's root when that survives (the category itself when unstamped),
  # otherwise its trashed parent's, otherwise itself. `fuel` stops a cycle.
  defp current_trash_root(uuid, info, doomed, fuel) do
    {parent, _status, root} = Map.fetch!(info, uuid)

    cond do
      is_nil(root) ->
        uuid

      not MapSet.member?(doomed, root) ->
        root

      fuel > 0 and match?({_, "deleted", _}, Map.get(info, parent)) ->
        current_trash_root(parent, info, doomed, fuel - 1)

      true ->
        uuid
    end
  end

  defp orphaned_by(query, doomed) do
    where(
      query,
      [r],
      fragment("(? #>> '{_trash,root}') = ANY(?)", r.data, type(^doomed, {:array, :string}))
    )
  end

  defp restamp_trash(query, via, root_uuid) do
    update(query, [r],
      set: [
        data:
          fragment(
            "jsonb_set(jsonb_set(?, '{_trash,via}', to_jsonb(?::text)), '{_trash,root}', to_jsonb(?::text))",
            r.data,
            ^via,
            ^to_string(root_uuid)
          )
      ]
    )
  end

  defp restamp_trash_self(query) do
    update(query, [r],
      set: [
        data:
          fragment(
            "jsonb_set(jsonb_set(?, '{_trash,via}', to_jsonb('self'::text)), '{_trash,root}', to_jsonb(?::text))",
            r.data,
            r.uuid
          )
      ]
    )
  end

  @doc """
  Moves a category — along with its entire subtree and every item
  inside — to a different catalogue.

  The moved category's `parent_uuid` is cleared (it detaches from its
  former parent, which stays in the source catalogue) and it takes the
  next available root-level position in the target — or, with
  `parent_uuid:`, the next position under that category of the target
  catalogue. Internal parent links inside the moved subtree are
  preserved.

  Refuses a trashed category (`:not_found`), a missing or trashed
  target catalogue (`:catalogue_not_found`), a target of the other kind
  (`:kind_mismatch` — standard and smart items price differently), and
  a `parent_uuid:` that is missing, trashed or in another catalogue
  (`:parent_not_found`) or inside the moved subtree
  (`:would_create_cycle`), and a move that would give an item the
  `external_id` a live item of the target already holds
  (`:external_id_taken`; inside a caller's own transaction this is raised
  as the `Postgrex.Error` instead, because the database has already
  aborted that transaction). Both catalogues are told about the move.

  With `catalogue_uuid:`, a category that is no longer in that catalogue
  when its row is locked is refused (`:wrong_catalogue_scope`).

  ## Examples

      {:ok, moved} = Catalogue.move_category_to_catalogue(category, target_catalogue_uuid)
      {:ok, moved} = Catalogue.move_category_to_catalogue(category, target, parent_uuid: parent)
  """
  @spec move_category_to_catalogue(Category.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Category.t()} | {:error, term()}
  def move_category_to_catalogue(%Category{} = category, target_catalogue_uuid, opts \\ []) do
    parent_uuid = opts[:parent_uuid]

    cond do
      not Shared.valid_uuid?(target_catalogue_uuid) -> {:error, :catalogue_not_found}
      not (is_nil(parent_uuid) or Shared.valid_uuid?(parent_uuid)) -> {:error, :parent_not_found}
      true -> do_move_category_to_catalogue(category, target_catalogue_uuid, parent_uuid, opts)
    end
  end

  defp do_move_category_to_catalogue(category, target_catalogue_uuid, parent_uuid, opts) do
    result =
      Trash.locked_transaction(fn ->
        # Both catalogues' trash/restore locks first, in sorted order: a
        # trash or restore in either one otherwise deadlocks against this
        # move, each holding a row the other updates next.
        source_catalogue_uuid =
          repo().one(
            from(c in Category, where: c.uuid == ^category.uuid, select: c.catalogue_uuid)
          ) ||
            repo().rollback(:not_found)

        Trash.lock_catalogues!([source_catalogue_uuid, target_catalogue_uuid])

        # Take an exclusive row lock on the category being moved. This
        # serializes concurrent `create_item`/`update_item` calls that
        # read the same category via `FOR SHARE` in
        # `put_catalogue_from_effective_category/2`: while we hold the
        # lock they block, and once we commit they read the new
        # `catalogue_uuid`. No item can slip in with a stale
        # `catalogue_uuid` between our items-update and our commit.
        locked =
          repo().one!(from(c in Category, where: c.uuid == ^category.uuid, lock: "FOR UPDATE"))

        check_move_source!(locked, source_catalogue_uuid, opts[:catalogue_uuid])

        # Read under both locks, so a trash of the target cannot land
        # between this check and the commit.
        Shared.check_move_destination!(source_catalogue_uuid, target_catalogue_uuid)

        subtree = lock_subtree!(category.uuid)
        if parent_uuid, do: check_move_parent!(parent_uuid, target_catalogue_uuid, subtree)
        now = DateTime.utc_now()

        {items_updated, _} =
          from(i in Item, where: i.category_uuid in ^subtree)
          |> repo().update_all(set: [catalogue_uuid: target_catalogue_uuid, updated_at: now])

        # Reparent the whole subtree to the target catalogue in a
        # single query — internal parent_uuids stay intact because
        # they still reference rows in the subtree.
        {categories_updated, _} =
          from(c in Category, where: c.uuid in ^subtree)
          |> repo().update_all(set: [catalogue_uuid: target_catalogue_uuid, updated_at: now])

        restamp_moved_trash!(
          target_catalogue_uuid,
          subtree,
          [target_catalogue_uuid | parent_and_ancestors(parent_uuid)]
        )

        # Position is computed inside the transaction (after the
        # subtree has moved) to avoid the same-`max_position` race
        # called out in prior PR reviews.
        next_pos = next_category_position(target_catalogue_uuid, parent_uuid)

        moved =
          locked
          |> Category.changeset(%{
            catalogue_uuid: target_catalogue_uuid,
            parent_uuid: parent_uuid,
            position: next_pos
          })
          |> repo().update!()

        {moved, categories_updated, items_updated, source_catalogue_uuid, locked.parent_uuid}
      end)

    case result do
      {:ok, {moved, categories_updated, items_updated, source_catalogue_uuid, from_parent_uuid}} ->
        Shared.log_activity(
          %{
            action: "category.moved",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "category",
            resource_uuid: moved.uuid,
            parent_catalogue_uuid: target_catalogue_uuid,
            metadata: %{
              "name" => moved.name,
              "subtree_size" => categories_updated,
              "items_cascaded" => items_updated,
              "changes" =>
                ActivityLog.changes([
                  {:catalogue, Shared.catalogue_ref(source_catalogue_uuid),
                   Shared.catalogue_ref(target_catalogue_uuid)},
                  {:parent, Shared.category_ref(from_parent_uuid),
                   Shared.category_ref(parent_uuid)}
                ])
            }
          },
          Keyword.take(opts, [:broadcast, :mode])
        )

        # The activity broadcast names the target; pages open on the
        # source lost a subtree and its items and must reload too.
        if source_catalogue_uuid != target_catalogue_uuid and Keyword.get(opts, :broadcast, true),
          do: broadcast_moved_out(source_catalogue_uuid)

        before = %{moved | catalogue_uuid: source_catalogue_uuid, parent_uuid: from_parent_uuid}
        MediaFolders.follow([{before, moved}], opts[:actor_uuid])
        {:ok, moved}

      error ->
        error
    end
  end

  # Every category of the moving subtree, row-locked before any item is
  # touched. Creating, updating or moving an item reads its category
  # `FOR SHARE`, so it either finishes first — and the item update below
  # then carries it along — or waits and reads the new catalogue. With
  # only the root locked, an item could land in a subcategory under the
  # old catalogue, or deadlock against the item update (review finding).
  # Re-read until the subtree stops changing under the locks.
  defp lock_subtree!(root_uuid, attempts \\ 3) do
    subtree = Tree.subtree_uuids(root_uuid)
    Trash.lock_categories!(subtree)

    cond do
      Enum.sort(Tree.subtree_uuids(root_uuid)) == Enum.sort(subtree) -> subtree
      attempts > 1 -> lock_subtree!(root_uuid, attempts - 1)
      true -> repo().rollback(:catalogue_moved)
    end
  end

  defp broadcast_moved_out(catalogue_uuid) do
    PubSub.broadcast(:category, nil, catalogue_uuid)
    PubSub.broadcast(:item, nil, catalogue_uuid)
  end

  # A parent in the destination: live, in that catalogue, and not a
  # member of the subtree being moved (the subtree carries raw uuids).
  # `FOR SHARE` holds it against a concurrent trash until commit.
  defp check_move_parent!(parent_uuid, catalogue_uuid, subtree) do
    case repo().one(from(c in Category, where: c.uuid == ^parent_uuid, lock: "FOR SHARE")) do
      %Category{status: status, catalogue_uuid: ^catalogue_uuid} when status != "deleted" ->
        {:ok, raw} = Ecto.UUID.dump(parent_uuid)
        if raw in subtree, do: repo().rollback(:would_create_cycle), else: :ok

      _ ->
        repo().rollback(:parent_not_found)
    end
  end

  @doc """
  Reparents a category within the same catalogue, placing it under
  `new_parent_uuid` (or promoting it to a root with `nil`).

  Rejects moves that would:
    * produce a cycle (`new_parent_uuid` is the category itself or one
      of its descendants) — returns `{:error, :would_create_cycle}`
    * cross a catalogue boundary — returns `{:error, :cross_catalogue}`.
      Callers who want that should run `move_category_to_catalogue/3`
      first, then reparent.
    * target a missing or trashed parent — returns `{:error, :parent_not_found}`
    * move a trashed category — returns `{:error, :not_found}`

  The moved category takes the next-available position among its new
  siblings. Its subtree comes along untouched (parent links inside the
  subtree stay valid).

  Passing `new_parent_uuid = nil` promotes the category to a root within
  its current catalogue.

  ## Examples

      {:ok, moved} = Catalogue.move_category_under(child, parent.uuid)
      {:ok, moved} = Catalogue.move_category_under(child, nil)  # promote to root
  """
  @spec move_category_under(Category.t(), Ecto.UUID.t() | nil, keyword()) ::
          {:ok, Category.t()}
          | {:error,
             :would_create_cycle
             | :cross_catalogue
             | :parent_not_found
             | :not_found
             | :catalogue_moved
             | Ecto.Changeset.t(Category.t())}
  def move_category_under(category, new_parent_uuid, opts \\ [])

  def move_category_under(%Category{parent_uuid: same} = category, same, _opts)
      when is_binary(same) or is_nil(same),
      do: {:ok, category}

  def move_category_under(%Category{} = category, nil, opts),
    do: do_move_category_under(category, nil, opts)

  def move_category_under(%Category{} = category, new_parent_uuid, opts)
      when is_binary(new_parent_uuid) do
    cond do
      new_parent_uuid == category.uuid -> {:error, :would_create_cycle}
      not Shared.valid_uuid?(new_parent_uuid) -> {:error, :parent_not_found}
      true -> do_move_category_under(category, new_parent_uuid, opts)
    end
  end

  # Runs the checks, the position calc and the update in one transaction
  # under the catalogue lock plus `FOR UPDATE` on the moved row, so it
  # serialises with every trash/restore path (a category trashed a moment
  # ago is refused, not revived as a live child of a live parent) and
  # with a concurrent reparent: two reparents that would jointly create a
  # cycle — the second one re-runs `Tree.subtree_uuids/1` against the
  # post-commit tree and gets `:would_create_cycle`.
  defp do_move_category_under(category, new_parent_uuid, opts) do
    result =
      Trash.locked_transaction(fn ->
        catalogue_uuid =
          repo().one(
            from(c in Category, where: c.uuid == ^category.uuid, select: c.catalogue_uuid)
          ) || repo().rollback(:not_found)

        Trash.lock_catalogue!(catalogue_uuid)

        locked =
          repo().one!(from(c in Category, where: c.uuid == ^category.uuid, lock: "FOR UPDATE"))

        cond do
          locked.catalogue_uuid != catalogue_uuid ->
            repo().rollback(:catalogue_moved)

          locked.status == "deleted" ->
            repo().rollback(:not_found)

          new_parent_uuid && cycle?(new_parent_uuid, locked.uuid) ->
            repo().rollback(:would_create_cycle)

          true ->
            moved = run_locked_reparent(locked, new_parent_uuid)

            restamp_moved_trash!(
              catalogue_uuid,
              Tree.subtree_uuids(locked.uuid),
              [catalogue_uuid | parent_and_ancestors(new_parent_uuid)]
            )

            moved
        end
      end)

    with {:ok, {moved, from_parent_uuid}} <- result do
      Shared.log_activity(
        %{
          action: "category.moved",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "category",
          resource_uuid: moved.uuid,
          parent_catalogue_uuid: moved.catalogue_uuid,
          metadata: %{
            "name" => moved.name,
            "catalogue_uuid" => moved.catalogue_uuid,
            "changes" =>
              ActivityLog.changes([
                {:parent, Shared.category_ref(from_parent_uuid),
                 Shared.category_ref(new_parent_uuid)}
              ])
          }
        },
        Keyword.take(opts, [:broadcast, :mode])
      )

      MediaFolders.follow([{%{moved | parent_uuid: from_parent_uuid}, moved}], opts[:actor_uuid])
      {:ok, moved}
    end
  end

  # `opts[:catalogue_uuid]`, when given, is a scope: a category outside it
  # is refused (`:wrong_catalogue_scope`) — the uuids come from the client.
  defp move_one_category(uuid, new_parent_uuid, opts) do
    scope = opts[:catalogue_uuid]

    case get_category(uuid) do
      nil ->
        {:error, :not_found}

      %Category{catalogue_uuid: c} when is_binary(scope) and c != scope ->
        {:error, :wrong_catalogue_scope}

      category ->
        move_category_under(category, new_parent_uuid, opts)
    end
  end

  @doc """
  Re-parents several categories at once — under `new_parent_uuid`, or to
  the root of their catalogue when it is `nil`. Each move is
  `move_category_under/3` with its own guards (cycles, cross-catalogue,
  missing parent); one refusal does not stop the others. Per-move
  broadcasts are muted and ONE `:category` batch event per touched
  catalogue is emitted after the loop, so every open page reloads once.

  Pass `catalogue_uuid:` to refuse categories outside that catalogue
  (`:wrong_catalogue_scope`) — the uuids are client-captured.

  Returns `{:ok, %{moved: n, errors: [{uuid, reason}]}}`.
  """
  @spec bulk_move_categories_under([Ecto.UUID.t()], Ecto.UUID.t() | nil, keyword()) ::
          {:ok, %{moved: non_neg_integer(), errors: [{Ecto.UUID.t(), term()}]}}
  def bulk_move_categories_under(uuids, new_parent_uuid, opts \\ []) when is_list(uuids) do
    muted = Keyword.put(opts, :broadcast, false)

    {moved, errors, catalogues} =
      Enum.reduce(uuids, {0, [], MapSet.new()}, fn uuid, {moved, errors, cats} ->
        case move_one_category(uuid, new_parent_uuid, muted) do
          {:ok, m} -> {moved + 1, errors, MapSet.put(cats, m.catalogue_uuid)}
          {:error, reason} -> {moved, [{uuid, reason} | errors], cats}
        end
      end)

    if moved > 0 and Keyword.get(opts, :broadcast, true) do
      Enum.each(catalogues, &PubSub.broadcast(:category, nil, &1))
    end

    {:ok, %{moved: moved, errors: Enum.reverse(errors)}}
  end

  # Loads a raw 16-byte binary UUID from a Tree CTE result back into the
  # textual `xxxxxxxx-xxxx-...` form, falling back to the raw input if
  # it isn't a valid UUID. Used by `list_category_tree/2`'s
  # `:exclude_subtree_of` membership test (loaded `Category` rows carry
  # textual UUIDs).
  defp check_move_source!(locked, source_catalogue_uuid, scope) do
    cond do
      locked.catalogue_uuid != source_catalogue_uuid -> repo().rollback(:catalogue_moved)
      locked.status == "deleted" -> repo().rollback(:not_found)
      # A client-captured selection is checked where the row is locked:
      # moved to another catalogue since the page read it, it is not this
      # page's to move any more.
      scope && scope != source_catalogue_uuid -> repo().rollback(:wrong_catalogue_scope)
      true -> :ok
    end
  end

  # `Tree` returns raw 16-byte uuids; stamps hold the string form.
  defp uuid_string(<<_::128>> = raw), do: Ecto.UUID.load!(raw)
  defp uuid_string(uuid), do: uuid

  defp parent_and_ancestors(nil), do: []
  defp parent_and_ancestors(uuid), do: [uuid | Tree.ancestor_uuids(uuid)]

  defp load_uuid(raw) do
    case Ecto.UUID.load(raw) do
      {:ok, str} -> str
      :error -> raw
    end
  end

  defp run_locked_reparent(category, nil), do: reparent!(category, nil)

  # `FOR SHARE` holds the parent against a concurrent trash until commit;
  # a trashed parent would hide the moved subtree from every tree.
  defp run_locked_reparent(category, new_parent_uuid) do
    case repo().one(from(c in Category, where: c.uuid == ^new_parent_uuid, lock: "FOR SHARE")) do
      nil ->
        repo().rollback(:parent_not_found)

      %Category{status: "deleted"} ->
        repo().rollback(:parent_not_found)

      %Category{catalogue_uuid: other} when other != category.catalogue_uuid ->
        repo().rollback(:cross_catalogue)

      %Category{} ->
        reparent!(category, new_parent_uuid)
    end
  end

  defp reparent!(category, new_parent_uuid) do
    from_parent_uuid = category.parent_uuid
    next_pos = next_category_position(category.catalogue_uuid, new_parent_uuid)

    case category
         |> Category.changeset(%{parent_uuid: new_parent_uuid, position: next_pos})
         |> repo().update() do
      {:ok, moved} -> {moved, from_parent_uuid}
      {:error, changeset} -> repo().rollback(changeset)
    end
  end

  @doc """
  Atomically swaps the positions of two categories within a transaction.

  Positions are scoped to `(catalogue_uuid, parent_uuid)` sibling
  groups (V103). Swapping positions of categories that are not
  siblings would mix two independent ordering axes, so this function
  refuses with `{:error, :not_siblings}` when the categories live
  under different parents or in different catalogues. The detail-view
  reorder buttons enforce the same constraint at the LV level; this
  is the context-level guard for any programmatic caller.

  ## Examples

      {:ok, _} = Catalogue.swap_category_positions(cat_a, cat_b)
      {:error, :not_siblings} = Catalogue.swap_category_positions(root, child)
  """
  @spec swap_category_positions(Category.t(), Category.t(), keyword()) ::
          {:ok, term()} | {:error, :not_siblings | term()}
  def swap_category_positions(%Category{} = cat_a, %Category{} = cat_b, opts \\ []) do
    if cat_a.catalogue_uuid != cat_b.catalogue_uuid or
         cat_a.parent_uuid != cat_b.parent_uuid do
      {:error, :not_siblings}
    else
      do_swap_category_positions(cat_a, cat_b, opts)
    end
  end

  defp do_swap_category_positions(cat_a, cat_b, opts) do
    result =
      repo().transaction(fn ->
        # Take FOR UPDATE on both rows before reading their positions so
        # two concurrent swaps with overlapping siblings serialise. The
        # first transaction commits its swap; the second re-reads the
        # post-commit positions and writes the correct values, instead
        # of computing both positions off pre-commit reads and producing
        # duplicates.
        # Locked in uuid order, like every other multi-row category lock, so
        # two swaps over the same pair (or a swap and a subtree trash)
        # cannot deadlock.
        locked =
          from(c in Category,
            where: c.uuid in ^[cat_a.uuid, cat_b.uuid],
            order_by: c.uuid,
            lock: "FOR UPDATE"
          )
          |> repo().all()
          |> Map.new(&{&1.uuid, &1})

        a = Map.fetch!(locked, cat_a.uuid)
        b = Map.fetch!(locked, cat_b.uuid)

        a |> Category.changeset(%{position: b.position}) |> repo().update!()
        b |> Category.changeset(%{position: a.position}) |> repo().update!()
      end)

    with {:ok, _} <- result do
      Shared.log_activity(%{
        action: "category.positions_swapped",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "category",
        resource_uuid: cat_a.uuid,
        parent_catalogue_uuid: cat_a.catalogue_uuid,
        metadata: %{
          "category_a_uuid" => cat_a.uuid,
          "category_a_name" => cat_a.name,
          "category_b_uuid" => cat_b.uuid,
          "category_b_name" => cat_b.name
        }
      })

      result
    end
  end

  @doc "Returns a changeset for tracking category changes."
  @spec change_category(Category.t(), map()) :: Ecto.Changeset.t(Category.t())
  def change_category(%Category{} = category, attrs \\ %{}) do
    Category.changeset(category, attrs)
  end

  @doc """
  The categories the embeddable pop-ups leave out: every category marked
  `internal` and every category under one, at any depth, as text uuids.
  An item filed in one of them is left out with it. Trashed rows count
  too — a live subcategory of a trashed internal category is still under
  it. `[]` when nothing is internal.
  """
  @spec internal_category_uuids() :: [Ecto.UUID.t()]
  def internal_category_uuids do
    case from(c in Category, where: c.internal == true, select: c.uuid) |> repo().all() do
      [] -> []
      roots -> category_subtree_uuids(roots)
    end
  end

  @doc """
  Returns the uuids of `category_uuids` and every category below them,
  trashed rows included, as text. A move or trash picker prunes these:
  a live category under a trashed one is still in the subtree, which a
  tree of live rows alone cannot see (it shows such a row at the top).
  Strings that are not UUIDs are ignored.
  """
  @spec category_subtree_uuids([String.t()]) :: [Ecto.UUID.t()]
  def category_subtree_uuids(category_uuids) when is_list(category_uuids) do
    category_uuids
    |> Enum.filter(&match?({:ok, _}, Ecto.UUID.cast(&1)))
    |> Tree.subtree_uuids_for()
    |> Enum.map(&load_uuid/1)
  end

  @doc """
  Returns same-catalogue active categories that can receive items from
  a category about to be deleted (the category itself and its V103
  descendants are excluded). Used by the admin "delete category" modal
  to populate the move-target dropdown.

  Each entry is `{category, depth}`, depth-first order — the same shape
  `list_category_tree/2` returns so callers can render the same indent
  rules.
  """
  @spec list_move_target_categories(Category.t()) :: [{Category.t(), non_neg_integer()}]
  def list_move_target_categories(%Category{} = category) do
    # `Tree.subtree_uuids/1` returns raw 16-byte binaries; `list_category_tree/2`
    # returns Ecto-loaded categories whose `:uuid` is the textual form.
    # Normalise both to text via `load_uuid/1` so the membership check fires.
    subtree =
      category.uuid
      |> Tree.subtree_uuids()
      |> Enum.map(&load_uuid/1)
      |> MapSet.new()

    category.catalogue_uuid
    |> list_category_tree(mode: :active)
    |> Enum.reject(fn {cat, _depth} -> MapSet.member?(subtree, cat.uuid) end)
  end

  @doc """
  Returns the categories in a catalogue paired with their tree depth,
  in depth-first display order (position, then name, recursing into
  children). Each entry is `{category, depth}` where depth `0` means a
  root. Used to render flat parent-pickers and indented listings.

  ## Options

    * `:mode` — `:active` (default, excludes deleted categories) or
      `:deleted` (all statuses — the detail view in deleted mode still
      wants deleted categories that contain trashed items).
    * `:exclude_subtree_of` — skip a category and all its descendants
      (e.g. the category being edited — you can't parent it under
      itself or its descendants).
  """
  @spec list_category_tree(Ecto.UUID.t(), keyword()) :: [{Category.t(), non_neg_integer()}]
  def list_category_tree(catalogue_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)

    # Plain list (not MapSet) because the exclude subtree is typically
    # a single branch (order of 1–20 uuids) and keeping a list here
    # lets dialyzer type-check the `in` check without tripping on
    # MapSet's opaque struct.
    # `Tree.subtree_uuids/1` returns raw 16-byte binaries; loaded
    # `Category` rows carry textual UUIDs. Normalise both sides via
    # `Ecto.UUID.load/1` so the membership test actually fires.
    exclude_uuids =
      case Keyword.get(opts, :exclude_subtree_of) do
        nil -> []
        uuid -> uuid |> Tree.subtree_uuids() |> Enum.map(&load_uuid/1)
      end

    normalized = normalized_category_rows(catalogue_uuid, mode, exclude_uuids)
    index = Tree.build_children_index(normalized)

    {acc, _} =
      Enum.reduce(Map.get(index, nil, []), {[], index}, fn root, {acc, idx} ->
        {collect_tree(root, idx, 0, acc), idx}
      end)

    Enum.reverse(acc)
  end

  @doc """
  The live (non-deleted) categories of several catalogues in one query,
  in `list_category_tree/2`'s sibling order (position, then name). The
  nesting is left to the caller through `parent_uuid` — for pickers that
  show many catalogues' trees at once, where one `list_category_tree/2`
  per catalogue would be a query each.
  """
  @spec list_live_categories([Ecto.UUID.t()]) :: [Category.t()]
  def list_live_categories([]), do: []

  def list_live_categories(catalogue_uuids) when is_list(catalogue_uuids) do
    from(c in Category,
      where: c.catalogue_uuid in ^catalogue_uuids and c.status != "deleted",
      order_by: [asc: :position, asc: :name]
    )
    |> repo().all()
  end

  defp collect_tree(%Category{} = cat, index, depth, acc) do
    acc = [{cat, depth} | acc]

    index
    |> Map.get(cat.uuid, [])
    |> Enum.reduce(acc, fn child, acc -> collect_tree(child, index, depth + 1, acc) end)
  end

  # Loads the catalogue's categories for `mode`, drops the excluded
  # subtree, and orphan-promotes rows whose parent is missing from the
  # set (deleted ancestor in :active mode, or excluded subtree) to roots
  # by rewriting `parent_uuid` to nil — so they never vanish from the UI.
  # Shared by `list_category_tree/2` and `list_child_categories/3` so the
  # drill-down's level view and the flat tree agree on what's a root.
  defp normalized_category_rows(catalogue_uuid, mode, exclude_uuids) do
    query =
      from(c in Category,
        where: c.catalogue_uuid == ^catalogue_uuid,
        # uuid last: two siblings sharing a position and a name would
        # otherwise come back in either order, and a sort that keeps ties
        # in input order (or reverses them) would swap them between renders.
        order_by: [asc: :position, asc: :name, asc: :uuid]
      )

    query =
      case mode do
        :active -> where(query, [c], c.status != "deleted")
        :deleted -> query
      end

    categories =
      query
      |> repo().all()
      |> Enum.reject(&(&1.uuid in exclude_uuids))

    uuid_set = MapSet.new(categories, & &1.uuid)

    Enum.map(categories, fn c ->
      if c.parent_uuid == nil or MapSet.member?(uuid_set, c.parent_uuid) do
        c
      else
        %{c | parent_uuid: nil}
      end
    end)
  end

  @doc """
  Lists the categories shown at one drill level — the direct children of
  `parent_uuid` within the catalogue (`nil` = the root level).

  In `:active` mode (default) the result reuses `list_category_tree/2`'s
  orphan promotion: a category whose parent is deleted (e.g. a child
  restored under a still-trashed parent — `restore_category/2` does not
  cascade) surfaces at the root level so it stays reachable by
  drill-down. In `:deleted` mode it returns the strict set of *deleted*
  direct children (no promotion) — the deleted subtree is navigated by
  drilling into deleted parents.

  Ordered by `position` then `name`.
  """
  @spec list_child_categories(Ecto.UUID.t(), Ecto.UUID.t() | nil, keyword()) :: [Category.t()]
  def list_child_categories(catalogue_uuid, parent_uuid, opts \\ []) do
    case Keyword.get(opts, :mode, :active) do
      :active ->
        catalogue_uuid
        |> normalized_category_rows(:active, [])
        |> Enum.filter(&(&1.parent_uuid == parent_uuid))

      :deleted ->
        base =
          from(c in Category,
            where: c.catalogue_uuid == ^catalogue_uuid and c.status == "deleted",
            order_by: [asc: :position, asc: :name]
          )

        query =
          case parent_uuid do
            nil -> where(base, [c], is_nil(c.parent_uuid))
            uuid -> where(base, [c], c.parent_uuid == ^uuid)
          end

        repo().all(query)
    end
  end

  @doc """
  `%{parent_uuid => n}` of direct child categories per parent within a
  catalogue — the count form of `category_uuids_with_children/2`, for
  the detail table's optional Subcategories column.
  """
  @spec category_children_counts(Ecto.UUID.t(), keyword()) :: %{
          Ecto.UUID.t() => non_neg_integer()
        }
  def category_children_counts(catalogue_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)

    query =
      from(c in Category,
        where: c.catalogue_uuid == ^catalogue_uuid and not is_nil(c.parent_uuid),
        group_by: c.parent_uuid,
        select: {c.parent_uuid, count(c.uuid)}
      )

    query =
      case mode do
        :active -> where(query, [c], c.status != "deleted")
        # The deleted view lists only deleted children, so its
        # Subcategories count must match — unfiltered it counted the
        # active children too (restore is non-cascading, so mixed
        # levels are normal).
        :deleted -> where(query, [c], c.status == "deleted")
      end

    query |> repo().all() |> Map.new()
  end

  @doc """
  Returns the set of category UUIDs (within the catalogue, in the given
  `:mode`) that have at least one child category — lets drill cards show
  a "has subcategories" affordance without an N+1 per card.
  """
  @spec category_uuids_with_children(Ecto.UUID.t(), keyword()) :: MapSet.t()
  def category_uuids_with_children(catalogue_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)

    query =
      from(c in Category,
        where: c.catalogue_uuid == ^catalogue_uuid and not is_nil(c.parent_uuid),
        select: c.parent_uuid,
        distinct: true
      )

    query =
      case mode do
        :active -> where(query, [c], c.status != "deleted")
        # Match `category_children_counts/2`: restore is non-cascading,
        # so a deleted parent can have only-active children. The deleted
        # view's chevron must not light up for a child list that is empty.
        :deleted -> where(query, [c], c.status == "deleted")
      end

    query |> repo().all() |> MapSet.new()
  end

  # New categories append to their level: when the caller supplies no
  # position (the form dropped its Position field), compute max+1 for
  # the (catalogue, parent) level. Without this every new category
  # lands on the schema default 0 and collides with the manual order.
  # Handles string- and atom-keyed attrs without mixing key types
  # (mixed keys make Ecto.Changeset.cast/4 raise).
  defp put_default_category_position(attrs) do
    given = Map.get(attrs, :position) || Map.get(attrs, "position")
    catalogue_uuid = Map.get(attrs, :catalogue_uuid) || Map.get(attrs, "catalogue_uuid")

    if given in [nil, ""] and is_binary(catalogue_uuid) do
      parent_uuid =
        case Map.get(attrs, :parent_uuid) || Map.get(attrs, "parent_uuid") do
          "" -> nil
          parent -> parent
        end

      position = next_category_position(catalogue_uuid, parent_uuid)
      key = if Enum.any?(Map.keys(attrs), &is_binary/1), do: "position", else: :position
      Map.put(attrs, key, position)
    else
      attrs
    end
  end

  @max_category_position 1_000_000

  @doc """
  Returns the next available position for a new category among its
  siblings. Position is scoped to `(catalogue_uuid, parent_uuid)` — the
  set of categories sharing the same parent within a catalogue — since
  V103's nested-category tree makes a single catalogue-wide ordering
  ambiguous.

  `parent_uuid` defaults to `nil`, i.e. root-level siblings. Returns 0
  if no siblings exist at that level, otherwise `max_position + 1`, at most
  `max_category_position/0` so that a stored huge position cannot push the
  next one out of the column.
  """
  @spec next_category_position(Ecto.UUID.t(), Ecto.UUID.t() | nil) :: non_neg_integer()
  def next_category_position(catalogue_uuid, parent_uuid \\ nil) do
    query =
      from(c in Category,
        where: c.catalogue_uuid == ^catalogue_uuid,
        select: max(c.position)
      )

    query =
      case parent_uuid do
        nil -> where(query, [c], is_nil(c.parent_uuid))
        uuid -> where(query, [c], c.parent_uuid == ^uuid)
      end

    case repo().one(query) do
      nil -> 0
      max_pos -> min(max_pos + 1, @max_category_position)
    end
  end

  @doc "The largest position a category is given or accepted with."
  @spec max_category_position() :: pos_integer()
  def max_category_position, do: @max_category_position

  @doc """
  Re-indexes a sibling group of categories from a list of UUIDs.

  Sibling scope is `(catalogue_uuid, parent_uuid)` — the same scope used
  by `swap_category_positions/2` and `next_category_position/2`. The
  function loads the supplied categories, verifies they all share that
  scope, and writes positions `1..N` in the order given. UUIDs not found
  in the table are ignored; UUIDs that don't share the scope abort the
  whole batch with `{:error, :not_siblings}`.

  Two-pass updates inside a single transaction — the first pass writes
  negative positions to dodge any future unique index on
  `(catalogue_uuid, parent_uuid, position)`; the second pass writes the
  final positive values. If no such index exists today, the cost is one
  extra `UPDATE` per row, which is cheap relative to the LV round-trip
  that triggers the call.
  """
  @spec reorder_categories(Ecto.UUID.t(), Ecto.UUID.t() | nil, [Ecto.UUID.t()], keyword()) ::
          :ok | {:error, :not_siblings | :too_many_uuids | term()}
  def reorder_categories(catalogue_uuid, parent_uuid, ordered_uuids, opts \\ [])
      when is_binary(catalogue_uuid) and is_list(ordered_uuids) do
    case validate_and_apply_category_reorder(catalogue_uuid, parent_uuid, ordered_uuids) do
      {:ok, 0} ->
        # No matching rows after dedupe — silent no-op, no audit row.
        :ok

      {:ok, count} ->
        Shared.log_activity(%{
          action: "category.reordered",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "category",
          resource_uuid: List.first(Helpers.dedupe_keep_last(ordered_uuids)),
          parent_catalogue_uuid: catalogue_uuid,
          metadata: %{
            "parent_uuid" => parent_uuid,
            "count" => count
          }
        })

        :ok

      {:error, reason} when reason in [:too_many_uuids, :not_siblings] ->
        Shared.log_reorder_rejected(
          :category,
          reason,
          length(ordered_uuids),
          catalogue_uuid,
          opts
        )

        {:error, reason}

      {:error, reason} ->
        Shared.log_reorder_db_error(
          :category,
          Helpers.dedupe_keep_last(ordered_uuids),
          catalogue_uuid,
          opts
        )

        {:error, reason}
    end
  end

  @doc """
  Re-indexes multiple sibling groups of categories in **one outer
  transaction** — the LV layer hits this when a single drop touches
  more than one parent group.

  Each group is `{parent_uuid_or_nil, [uuid]}`. All groups are
  validated up front (cap + sibling scope) before any writes; if any
  group fails validation, the whole batch returns the error and no
  writes happen.

  Atomicity: a DB-level failure in any group rolls back every group.
  Beats the previous LV-side `Enum.reduce` over per-group calls,
  which committed groups one at a time and could leave partial state.
  """
  @spec reorder_categories_groups(
          Ecto.UUID.t(),
          [{Ecto.UUID.t() | nil, [Ecto.UUID.t()]}],
          keyword()
        ) :: :ok | {:error, :too_many_uuids | :not_siblings | term()}
  def reorder_categories_groups(catalogue_uuid, groups, opts \\ [])
      when is_binary(catalogue_uuid) and is_list(groups) do
    deduped_groups =
      Enum.map(groups, fn {parent_uuid, uuids} ->
        {parent_uuid, Helpers.dedupe_keep_last(uuids)}
      end)

    total_count = deduped_groups |> Enum.flat_map(fn {_p, u} -> u end) |> length()

    if total_count > @reorder_max_uuids do
      Shared.log_reorder_rejected(:category, :too_many_uuids, total_count, catalogue_uuid, opts)
      {:error, :too_many_uuids}
    else
      run_categories_groups_transaction(catalogue_uuid, deduped_groups, total_count, opts)
    end
  end

  defp run_categories_groups_transaction(catalogue_uuid, deduped_groups, total_count, opts) do
    txn_result =
      repo().transaction(fn ->
        Trash.lock_catalogue!(catalogue_uuid)

        Enum.reduce_while(deduped_groups, :ok, fn group, _acc ->
          apply_category_group_step(catalogue_uuid, group)
        end)
      end)

    case txn_result do
      {:ok, :ok} ->
        Shared.log_activity(
          %{
            action: "category.reordered",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "category",
            parent_catalogue_uuid: catalogue_uuid,
            metadata: %{
              "groups" => length(deduped_groups),
              "count" => total_count
            }
          },
          opts
        )

        :ok

      {:error, reason} when reason in [:too_many_uuids, :not_siblings] ->
        Shared.log_reorder_rejected(:category, reason, total_count, catalogue_uuid, opts)
        {:error, reason}

      {:error, reason} ->
        Shared.log_reorder_db_error(
          :category,
          Enum.flat_map(deduped_groups, fn {_p, u} -> u end),
          catalogue_uuid,
          opts
        )

        {:error, reason}
    end
  end

  # Step inside `Enum.reduce_while` over groups. Returns the
  # `:cont` / `:halt` tuple the caller's reduce expects, and on error
  # rolls back the outer transaction so partial commits aren't
  # possible.
  defp apply_category_group_step(catalogue_uuid, {parent_uuid, uuids}) do
    case validate_and_apply_category_reorder_in_txn(catalogue_uuid, parent_uuid, uuids) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, repo().rollback(reason)}
    end
  end

  # Validates scope + applies the two-pass write inside its own
  # transaction. Returns `{:ok, count}` on success or `{:error, reason}`
  # without any logging — callers handle logging outside the
  # transaction so audit rows survive a rollback.
  defp validate_and_apply_category_reorder(catalogue_uuid, _parent_uuid, ordered_uuids)
       when is_binary(catalogue_uuid) and is_list(ordered_uuids) and
              length(ordered_uuids) > @reorder_max_uuids,
       do: {:error, :too_many_uuids}

  defp validate_and_apply_category_reorder(catalogue_uuid, parent_uuid, ordered_uuids)
       when is_binary(catalogue_uuid) and is_list(ordered_uuids) do
    unique_uuids = Helpers.dedupe_keep_last(ordered_uuids)

    case category_scope_check(catalogue_uuid, parent_uuid, unique_uuids) do
      :empty -> {:ok, 0}
      :ok -> commit_category_positions(catalogue_uuid, unique_uuids)
      {:error, _} = err -> err
    end
  end

  # Reorders take the catalogue's trash/restore lock: a reorder writes rows
  # one at a time in the caller's order while a trash or restore writes the
  # same rows in scan order, and two transactions taking one set of rows in
  # different orders can deadlock.
  defp commit_category_positions(catalogue_uuid, unique_uuids) do
    reorder = fn ->
      Trash.lock_catalogue!(catalogue_uuid)
      write_category_positions(unique_uuids)
    end

    case repo().transaction(reorder) do
      {:ok, _} -> {:ok, length(unique_uuids)}
      {:error, reason} -> {:error, reason}
    end
  end

  # In-transaction variant for `reorder_categories_groups/3` —
  # validates + writes without opening its own savepoint. Returns
  # `:ok` on empty/success, `{:error, reason}` otherwise.
  defp validate_and_apply_category_reorder_in_txn(catalogue_uuid, parent_uuid, unique_uuids)
       when is_binary(catalogue_uuid) and is_list(unique_uuids) do
    case category_scope_check(catalogue_uuid, parent_uuid, unique_uuids) do
      :empty -> :ok
      :ok -> write_category_positions(unique_uuids)
      {:error, _} = err -> err
    end
  end

  defp category_scope_check(catalogue_uuid, parent_uuid, unique_uuids) do
    rows =
      from(c in Category, where: c.uuid in ^unique_uuids)
      |> repo().all()

    cond do
      rows == [] ->
        :empty

      not Enum.all?(rows, fn c ->
        c.catalogue_uuid == catalogue_uuid and c.parent_uuid == parent_uuid
      end) ->
        {:error, :not_siblings}

      true ->
        :ok
    end
  end

  # Future (perf): collapse the two-pass loop below to a single
  # `UPDATE phoenix_kit_cat_categories SET position = v.pos
  #   FROM (VALUES (uuid, pos), …) AS v(uuid, pos)
  #   WHERE phoenix_kit_cat_categories.uuid = v.uuid`
  # round-trip per scope. PG checks unique constraints at statement
  # end, so a CASE-based or VALUES-join UPDATE works even with a
  # future unique index on `(catalogue_uuid, parent_uuid, position)`.
  # Trigger to revisit: `:reorder_max_uuids` config bumped past 1000,
  # or a unique index is added.
  defp write_category_positions(unique_uuids) do
    # Rows are written (and so locked) in uuid order rather than the
    # caller's, the order a subtree trash locks them in.
    pairs = unique_uuids |> Enum.with_index(1) |> Enum.sort_by(fn {uuid, _idx} -> uuid end)

    Enum.each(pairs, fn {uuid, idx} ->
      from(c in Category, where: c.uuid == ^uuid)
      |> repo().update_all(set: [position: -idx])
    end)

    Enum.each(pairs, fn {uuid, idx} ->
      from(c in Category, where: c.uuid == ^uuid)
      |> repo().update_all(set: [position: idx])
    end)

    :ok
  end

  @doc "Category counterpart of `item_slug_taken?/3`."
  @spec category_slug_taken?(String.t(), String.t(), keyword()) :: boolean()
  def category_slug_taken?(slug, lang, opts \\ []) do
    Shared.slug_taken?(@category_slugs_table, "category_uuid", slug, lang, opts[:exclude_uuid])
  end

  @doc """
  Moves several categories, each with its subtree and items, to another
  catalogue — at its top level, or under `parent_uuid` there. Each move
  is `move_category_to_catalogue/3` with its own guards; one refusal
  does not stop the others.

  A selected category whose ancestor is also selected travels inside
  that ancestor instead of being detached from it; if the ancestor does
  not move, it moves on its own. With the target equal
  to the scope catalogue this is `bulk_move_categories_under/3`.

  `opts[:catalogue_uuid]` is the source scope; categories outside it are
  refused (`:wrong_catalogue_scope`). Per-move broadcasts are muted and
  both catalogues get one batch event each.

  Returns `{:ok, %{moved: n, errors: [{uuid, reason}]}}`.
  """
  @spec bulk_move_categories_to_catalogue(
          [Ecto.UUID.t()],
          Ecto.UUID.t(),
          Ecto.UUID.t() | nil,
          keyword()
        ) :: {:ok, %{moved: non_neg_integer(), errors: [{Ecto.UUID.t(), term()}]}}
  def bulk_move_categories_to_catalogue(uuids, target_catalogue_uuid, parent_uuid, opts \\ [])
      when is_list(uuids) do
    if target_catalogue_uuid == opts[:catalogue_uuid] do
      bulk_move_categories_under(uuids, parent_uuid, opts)
    else
      do_bulk_move_categories_to_catalogue(uuids, target_catalogue_uuid, parent_uuid, opts)
    end
  end

  defp do_bulk_move_categories_to_catalogue(uuids, target, parent_uuid, opts) do
    uuids = Enum.uniq(uuids)

    case opts[:catalogue_uuid] do
      scope when is_binary(scope) ->
        run_bulk_category_move(uuids, target, parent_uuid, scope, opts)

      _ ->
        {:ok, %{moved: 0, errors: Enum.map(uuids, &{&1, :missing_catalogue_scope})}}
    end
  end

  defp run_bulk_category_move(uuids, target, parent_uuid, scope, opts) do
    muted = opts |> Keyword.put(:broadcast, false) |> Keyword.put(:parent_uuid, parent_uuid)
    {valid, invalid} = Enum.split_with(uuids, &Shared.valid_uuid?/1)
    rows = from(c in Category, where: c.uuid in ^valid) |> repo().all() |> Map.new(&{&1.uuid, &1})

    # The scope is checked for every entry before anything moves, so an
    # entry that later arrives inside a moved ancestor was this page's.
    {in_scope, refused} =
      Enum.split_with(valid, &match?(%Category{catalogue_uuid: ^scope}, rows[&1]))

    depth = selected_ancestor_counts(in_scope)

    # Outer categories first, then inner ones shallowest first: each inner
    # one either arrived inside its moved ancestor, or — the ancestor
    # refused, or it was lifted out meanwhile — moves on its own.
    {moved, errors, catalogues} =
      in_scope
      |> Enum.sort_by(&Map.get(depth, &1, 0))
      |> Enum.reduce({0, [], MapSet.new()}, fn uuid, {moved, errors, cats} ->
        case move_selected_category(uuid, target, Map.has_key?(depth, uuid), muted) do
          {:ok, :carried} ->
            {moved + 1, errors, cats}

          {:ok, {m, from}} ->
            {moved + 1, errors, cats |> MapSet.put(m.catalogue_uuid) |> MapSet.put(from)}

          {:error, reason} ->
            {moved, [{uuid, bulk_reason(reason)} | errors], cats}
        end
      end)

    if moved > 0 and Keyword.get(opts, :broadcast, true),
      do: Enum.each(catalogues, &broadcast_moved_out/1)

    errors =
      Enum.reverse(errors) ++
        Enum.map(refused, &{&1, if(rows[&1], do: :wrong_catalogue_scope, else: :not_found)}) ++
        Enum.map(invalid, &{&1, :invalid_uuid})

    {:ok, %{moved: moved, errors: errors}}
  end

  # One shape per error entry; a changeset would drag a whole row into
  # the page's error log.
  defp bulk_reason(%Ecto.Changeset{}), do: :invalid
  defp bulk_reason(reason), do: reason

  defp move_selected_category(uuid, target, true = _inner?, opts) do
    case get_category(uuid) do
      %Category{catalogue_uuid: ^target, status: status} when status != "deleted" ->
        {:ok, :carried}

      _ ->
        move_one_category_to_catalogue(uuid, target, opts)
    end
  end

  defp move_selected_category(uuid, target, false, opts),
    do: move_one_category_to_catalogue(uuid, target, opts)

  defp move_one_category_to_catalogue(uuid, target, opts) do
    scope = opts[:catalogue_uuid]

    case get_category(uuid) do
      nil ->
        {:error, :not_found}

      %Category{catalogue_uuid: c} when c != scope ->
        {:error, :wrong_catalogue_scope}

      category ->
        # The scope is re-checked under the lock, so it is the source.
        with {:ok, moved} <- move_category_to_catalogue(category, target, opts),
             do: {:ok, {moved, scope}}
    end
  end

  # For each selected uuid below another selected one: how many selected
  # ancestors it has (its depth within the selection). Top ones are absent.
  defp selected_ancestor_counts(uuids) do
    selected = MapSet.new(uuids)

    Enum.reduce(uuids, %{}, fn uuid, acc ->
      uuid
      |> Tree.subtree_uuids()
      |> Enum.map(&load_uuid/1)
      |> Enum.filter(&(&1 != uuid and MapSet.member?(selected, &1)))
      |> Enum.reduce(acc, fn below, acc -> Map.update(acc, below, 1, &(&1 + 1)) end)
    end)
  end

  @doc """
  Bulk soft-deletes categories by UUID with a uniform item disposition
  (cascade / uncategorize / move_to). Each category goes through the
  same logic as `trash_category/2`. Returns `{:ok, %{categories:
  count, items_handled: count}}` or surfaces the first error.
  """
  @spec bulk_trash_categories(
          [Ecto.UUID.t()],
          :cascade | :uncategorize | {:move_to, Ecto.UUID.t()},
          keyword()
        ) ::
          {:ok, %{categories: non_neg_integer(), items_handled: non_neg_integer()}}
          | {:error, term()}
  def bulk_trash_categories([], _disposition, _opts),
    do: {:ok, %{categories: 0, items_handled: 0}}

  def bulk_trash_categories(uuids, disposition, opts) when is_list(uuids) do
    uuids = scope_category_uuids(uuids, opts[:catalogue_uuid])

    # Each step runs `trash_category/2` muted: a broadcast from inside the
    # outer transaction would reach subscribers before the rows commit
    # (and before a later step could roll them back). The trashed
    # `{uuid, catalogue_uuid}` pairs are collected and fanned out once the
    # transaction has committed.
    step_opts = Keyword.put(opts, :broadcast, false)

    Trash.locked_transaction(fn ->
      Trash.lock_catalogues_of!(Category, uuids)

      uuids
      |> ancestors_first()
      |> Enum.reduce_while(%{categories: 0, items_handled: 0, trashed: []}, fn uuid, acc ->
        bulk_trash_category_step(uuid, disposition, step_opts, acc)
      end)
    end)
    |> case do
      {:ok, %{trashed: trashed} = summary} ->
        broadcast_trashed_categories(trashed, opts)
        {:ok, Map.delete(summary, :trashed)}

      error ->
        error
    end
  end

  # A selection holding a category AND one of its descendants trashes the
  # ancestor first, so the descendant is stamped as taken by it — the
  # order the uuids happen to arrive in must not decide what restoring the
  # ancestor brings back.
  #
  # Depths come from one read of the selected categories' catalogues, taken
  # under their locks, not from a recursive ancestor query per selected uuid.
  defp ancestors_first(uuids) do
    parents =
      from(c in Category,
        where:
          c.catalogue_uuid in subquery(
            from(s in Category, where: s.uuid in ^uuids, select: s.catalogue_uuid)
          ),
        select: {c.uuid, c.parent_uuid}
      )
      |> repo().all()
      |> Map.new()

    Enum.sort_by(uuids, &category_depth(&1, parents, 0))
  end

  # Walks parent links up to a root, counting the steps. No real chain has
  # more steps than the catalogues hold categories, so a longer walk is a
  # cycle (which the tree guards forbid) and ends there; a deep chain is never
  # cut short.
  defp category_depth(uuid, parents, depth) do
    case Map.get(parents, uuid) do
      nil -> depth
      _parent_uuid when depth >= map_size(parents) -> depth
      parent_uuid -> category_depth(parent_uuid, parents, depth + 1)
    end
  end

  defp scope_category_uuids(uuids, nil), do: uuids

  defp scope_category_uuids(uuids, catalogue_uuid) do
    repo().all(
      from(c in Category,
        where: c.uuid in ^uuids and c.catalogue_uuid == ^catalogue_uuid,
        select: c.uuid
      )
    )
  end

  # One batch event per touched catalogue (like the other bulk ops), not
  # one per category — N per-row events made every open page reload N
  # times (review finding, 2026-08-24).
  defp broadcast_trashed_categories(trashed, opts) do
    if Keyword.get(opts, :broadcast, true) do
      trashed
      |> Enum.map(fn {_uuid, catalogue_uuid} -> catalogue_uuid end)
      |> Enum.uniq()
      |> Enum.each(fn catalogue_uuid ->
        PubSub.broadcast(:category, nil, catalogue_uuid)
      end)
    end

    :ok
  end

  @doc """
  Announces that categories of a catalogue were trashed: the one event a
  bulk trash sends per touched catalogue, for a caller that trashed with
  `broadcast: false`.
  """
  @spec broadcast_categories_trashed(Ecto.UUID.t()) :: :ok
  def broadcast_categories_trashed(catalogue_uuid),
    do: PubSub.broadcast(:category, nil, catalogue_uuid)

  defp bulk_trash_category_step(uuid, disposition, opts, acc) do
    case Helpers.get_by_uuid(Category, uuid) do
      nil -> {:cont, acc}
      %Category{status: "deleted"} -> {:cont, acc}
      %Category{} = category -> trash_one_in_bulk(category, disposition, opts, acc)
    end
  end

  defp trash_one_in_bulk(category, disposition, opts, acc) do
    case trash_category(category, Keyword.put(opts, :items, disposition)) do
      {:ok, _} ->
        {:cont,
         %{
           acc
           | categories: acc.categories + 1,
             trashed: [{category.uuid, category.catalogue_uuid} | acc.trashed]
         }}

      {:error, reason} ->
        {:halt, repo().rollback(reason)}
    end
  end
end
