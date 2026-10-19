defmodule PhoenixKitCatalogue.Catalogue.Catalogues do
  @moduledoc """
  Catalogues — the top-level grouping: listing, CRUD, trash / restore /
  permanent delete (cascading to categories and items), and the
  catalogue order on the index.

  Public surface is re-exported from `PhoenixKitCatalogue.Catalogue` via
  `defdelegate`, so callers keep using the canonical context module.
  """

  import Ecto.Query, warn: false

  alias PhoenixKitCatalogue.Catalogue.{ActivityLog, Helpers, Shared, Trash}
  alias PhoenixKitCatalogue.MediaFolders
  alias PhoenixKitCatalogue.Schemas.{Catalogue, Category, Folder, Item}

  @reorder_max_uuids Shared.reorder_max_uuids()

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @catalogue_logged_fields [
    :name,
    :kind,
    :item_type,
    :status,
    :markup_percentage,
    :discount_percentage,
    :description,
    :ai_notes
  ]

  # Auto-assigns a position to a new catalogue when the caller hasn't
  # supplied one — places the new row at the end of the manual-order
  # list. Existing tests / callers that pass `:position` keep control.
  defp maybe_put_catalogue_position(attrs) when is_map(attrs) do
    if Helpers.has_attr?(attrs, :position) do
      attrs
    else
      # Append on the *level* the catalogue will land on (root unless
      # `folder_uuid` is set). Positions are one interleaved sequence
      # per folder level — a global catalogue-only max would collide
      # with folders already occupying those slots.
      folder = attrs |> Helpers.fetch_attr(:folder_uuid) |> Shared.normalize_folder_uuid()
      Helpers.put_attr(attrs, :position, Shared.next_level_position(folder))
    end
  end

  @doc """
  Lists catalogues in the index's Manual order — position, then
  lowercased name. Excludes deleted by default.

  ## Options

    * `:status` — when provided, returns only catalogues with this exact status
      (e.g. `"active"`, `"archived"`, `"deleted"`).
      When nil (default), returns all non-deleted catalogues.
    * `:kind` — when provided, filters to a specific kind (`:standard`, `:smart`,
      or their string equivalents). When nil (default), returns all kinds.
    * `:folder_uuid` — when provided, filters by folder home: a folder UUID
      returns only catalogues filed there, `:unfiled` returns root (NULL-folder)
      catalogues. When omitted, returns catalogues in any folder. Note this is a
      strict DB filter and does NOT orphan-promote catalogues whose folder is
      trashed — the tree view groups in-memory against the active folder set.

  ## Examples

      Catalogue.list_catalogues()                     # active + archived
      Catalogue.list_catalogues(status: "deleted")    # only deleted
      Catalogue.list_catalogues(status: "active")     # only active
      Catalogue.list_catalogues(kind: :smart)         # only smart catalogues
      Catalogue.list_catalogues(kind: :standard)      # only standard catalogues
      Catalogue.list_catalogues(folder_uuid: :unfiled) # only root (unfiled)
  """
  @spec list_catalogues(keyword()) :: [Catalogue.t()]
  def list_catalogues(opts \\ []) do
    query =
      from(c in Catalogue,
        # Same tie-break as `Search`'s catalogue chain: two catalogues at
        # one position with the same case-folded name must walk in the
        # same order on the index as in the popup and the browse embed.
        order_by: [asc: c.position, asc: fragment("lower(?)", c.name), asc: c.uuid]
      )

    query
    |> filter_status(Keyword.get(opts, :status))
    |> filter_kind(Keyword.get(opts, :kind))
    |> filter_folder(Keyword.get(opts, :folder_uuid, :any))
    |> repo().all()
  end

  defp filter_status(query, nil), do: where(query, [c], c.status != "deleted")
  defp filter_status(query, status), do: where(query, [c], c.status == ^status)

  defp filter_kind(query, nil), do: query
  defp filter_kind(query, kind), do: where(query, [c], c.kind == ^to_string(kind))

  defp filter_folder(query, :any), do: query

  defp filter_folder(query, folder) when folder in [:unfiled, nil],
    do: where(query, [c], is_nil(c.folder_uuid))

  defp filter_folder(query, uuid), do: where(query, [c], c.folder_uuid == ^uuid)

  @doc """
  Lists catalogues whose name starts with `prefix`, case-insensitive.

  Anchored at the start of the name — this is a *prefix* match
  (`name ILIKE 'prefix%'`), not a contains match. LIKE metacharacters
  (`%`, `_`) in the prefix are escaped.

  Excludes deleted catalogues by default. Useful for narrowing a search
  scope: pair with `search_items/2`'s `:catalogue_uuids` to search only
  the matched catalogues.

  ## Options

    * `:status` — when provided, returns only catalogues with this exact status.
      Defaults to non-deleted (active + archived).
    * `:limit` — max results (no limit by default).

  ## Examples

      Catalogue.list_catalogues_by_name_prefix("Kit")
      #=> [%Catalogue{name: "Kitchen Furniture"}, %Catalogue{name: "Kits"}]

      Catalogue.list_catalogues_by_name_prefix("Kit", limit: 5)
      Catalogue.list_catalogues_by_name_prefix("", limit: 10)  # returns first 10

      # Compose with search
      uuids =
        "Kit"
        |> Catalogue.list_catalogues_by_name_prefix()
        |> Enum.map(& &1.uuid)

      Catalogue.search_items("oak", catalogue_uuids: uuids)
  """
  @spec list_catalogues_by_name_prefix(String.t(), keyword()) :: [Catalogue.t()]
  def list_catalogues_by_name_prefix(prefix, opts \\ []) when is_binary(prefix) do
    pattern = "#{Helpers.sanitize_like(prefix)}%"

    query =
      from(c in Catalogue,
        where: ilike(c.name, ^pattern),
        order_by: [asc: :name]
      )

    query =
      case Keyword.get(opts, :status) do
        nil -> where(query, [c], c.status != "deleted")
        status -> where(query, [c], c.status == ^status)
      end

    query =
      case Keyword.get(opts, :limit) do
        nil -> query
        lim -> limit(query, ^lim)
      end

    repo().all(query)
  end

  @doc "Returns the count of soft-deleted catalogues."
  @spec deleted_catalogue_count() :: non_neg_integer()
  def deleted_catalogue_count do
    from(c in Catalogue, where: c.status == "deleted")
    |> repo().aggregate(:count)
  end

  @doc "Fetches a catalogue by UUID without preloads. Returns `nil` if not found."
  @spec get_catalogue(Ecto.UUID.t()) :: Catalogue.t() | nil
  def get_catalogue(uuid), do: Helpers.get_by_uuid(Catalogue, uuid)

  @doc """
  Fetches a catalogue by UUID without preloading categories or items.
  Raises `Ecto.NoResultsError` if not found. Prefer this over
  `get_catalogue!/2` in read paths that don't need the nested preloads
  (e.g. the infinite-scroll detail view, which pages categories and
  items separately).
  """
  @spec fetch_catalogue!(Ecto.UUID.t()) :: Catalogue.t()
  def fetch_catalogue!(uuid), do: Helpers.get_by_uuid!(Catalogue, uuid)

  @doc """
  Fetches a catalogue by UUID with preloaded categories and items.
  Raises `Ecto.NoResultsError` if not found.

  ## Options

    * `:mode` — `:active` (default) or `:deleted`
      - `:active` — preloads non-deleted categories with non-deleted items
      - `:deleted` — preloads all categories with only deleted items
        (so you can see which categories contain trashed items)

  ## Examples

      Catalogue.get_catalogue!(uuid)                  # active view
      Catalogue.get_catalogue!(uuid, mode: :deleted)  # deleted view
  """
  @spec get_catalogue!(Ecto.UUID.t(), keyword()) :: Catalogue.t()
  def get_catalogue!(uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)

    {category_query, item_query} =
      case mode do
        :active ->
          {from(c in Category, where: c.status != "deleted", order_by: [asc: :position]),
           from(i in Item, where: i.status != "deleted", order_by: [asc: :position, asc: :name])}

        :deleted ->
          {from(c in Category, order_by: [asc: :position]),
           from(i in Item,
             where: i.status == "deleted",
             order_by: [asc: :position, asc: :name]
           )}
      end

    Catalogue
    |> Helpers.get_by_uuid!(uuid)
    |> repo().preload(categories: {category_query, [items: item_query]})
  end

  @doc """
  Creates a catalogue.

  ## Required attributes

    * `:name` — catalogue name (1-255 chars)

  ## Optional attributes

    * `:description` — text description
    * `:status` — `"active"` (default), `"archived"`, or `"deleted"`
    * `:data` — flexible JSON map

  ## Examples

      Catalogue.create_catalogue(%{name: "Kitchen Furniture"})
  """
  @spec create_catalogue(map(), keyword()) ::
          {:ok, Catalogue.t()} | {:error, Ecto.Changeset.t(Catalogue.t())}
  def create_catalogue(attrs, opts \\ []) do
    result =
      repo().transaction(fn ->
        Shared.lock_catalogues_order!()
        attrs = maybe_put_catalogue_position(attrs)

        case %Catalogue{}
             |> Catalogue.changeset(attrs)
             |> Shared.stamp_created_deleted()
             |> repo().insert() do
          {:ok, catalogue} -> catalogue
          {:error, changeset} -> repo().rollback(changeset)
        end
      end)

    case result do
      {:ok, catalogue} = ok ->
        Shared.log_activity(
          %{
            action: "catalogue.created",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "catalogue",
            resource_uuid: catalogue.uuid,
            metadata: %{"name" => catalogue.name}
          },
          Keyword.take(opts, [:broadcast, :mode])
        )

        ok

      error ->
        error
    end
  end

  @doc "Updates a catalogue with the given attributes."
  @spec update_catalogue(Catalogue.t(), map(), keyword()) ::
          {:ok, Catalogue.t()} | {:error, Ecto.Changeset.t(Catalogue.t())}
  def update_catalogue(%Catalogue{} = catalogue, attrs, opts \\ []) do
    # `:data_owned_keys` — same contract as `update_item/3`: the row is
    # re-read `FOR UPDATE` inside the transaction and only the listed
    # `data` keys are taken from `attrs`, so a caller holding a stale
    # snapshot cannot clobber what another process wrote meanwhile.
    result =
      repo().transaction(fn ->
        attrs = Shared.narrow_data_ownership(Catalogue, catalogue.uuid, attrs, opts)

        case catalogue
             |> Catalogue.changeset(attrs)
             |> Shared.keep_trash_status(Catalogue, catalogue.uuid)
             |> repo().update() do
          {:ok, updated} -> updated
          {:error, changeset} -> repo().rollback(changeset)
        end
      end)

    case result do
      {:ok, updated} = ok ->
        Shared.log_activity(
          %{
            action: "catalogue.updated",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "catalogue",
            resource_uuid: updated.uuid,
            metadata:
              ActivityLog.with_changes(
                %{"name" => updated.name},
                catalogue,
                updated,
                @catalogue_logged_fields
              )
          },
          opts
        )

        MediaFolders.follow([{catalogue, updated}], opts[:actor_uuid])
        ok

      error ->
        error
    end
  end

  @doc "Hard-deletes a catalogue. Prefer `trash_catalogue/1` for soft-delete."
  @spec delete_catalogue(Catalogue.t(), keyword()) ::
          {:ok, Catalogue.t()} | {:error, Ecto.Changeset.t(Catalogue.t())}
  def delete_catalogue(%Catalogue{} = catalogue, opts \\ []) do
    release =
      MediaFolders.release_plan([
        from(c in Catalogue, where: c.uuid == ^catalogue.uuid),
        from(c in Category, where: c.catalogue_uuid == ^catalogue.uuid)
      ])

    case repo().delete(catalogue) do
      {:ok, _} = ok ->
        MediaFolders.release(release)

        Shared.log_activity(%{
          action: "catalogue.deleted",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "catalogue",
          resource_uuid: catalogue.uuid,
          metadata: %{"name" => catalogue.name}
        })

        ok

      error ->
        error
    end
  end

  @doc """
  Soft-deletes a catalogue by setting its status to `"deleted"`.

  **Cascades downward** in a transaction: every live item and category in
  the catalogue flips to `"deleted"`, stamped as taken by this catalogue,
  then the catalogue itself (its prior status stamped too, so an
  `archived` catalogue comes back `archived`). Rows already in the trash
  keep their own stamp, so `restore_catalogue/2` leaves them there. See
  `dev_docs/guides/trash-and-restore.md`.

  On an already-trashed catalogue it only sweeps children that are still
  live (rows left behind by a trash that predates the cascade), and logs
  nothing when there were none.

  ## Examples

      {:ok, catalogue} = Catalogue.trash_catalogue(catalogue)
  """
  @spec trash_catalogue(Catalogue.t(), keyword()) :: {:ok, Catalogue.t()} | {:error, term()}
  def trash_catalogue(%Catalogue{} = catalogue, opts \\ []) do
    result =
      repo().transaction(fn ->
        root = catalogue.uuid
        Trash.lock_catalogue!(root)
        Trash.lock_catalogue_categories!(root)
        now = DateTime.utc_now()

        {items, _} =
          from(i in Item, where: i.catalogue_uuid == ^root and i.status != "deleted")
          |> Trash.stamp_trashed("catalogue", root, now)
          |> repo().update_all([])

        {categories, _} =
          from(c in Category, where: c.catalogue_uuid == ^root and c.status != "deleted")
          |> Trash.stamp_trashed("catalogue", root, now)
          |> repo().update_all([])

        {self, _} =
          from(c in Catalogue, where: c.uuid == ^root and c.status != "deleted")
          |> Trash.stamp_trashed("self", root, now)
          |> repo().update_all([])

        updated = repo().get(Catalogue, root) || repo().rollback(:not_found)
        {updated, items + categories + self}
      end)

    # A catalogue already in the trash with nothing live under it was not
    # trashed by this call, so there is nothing to record.
    with {:ok, {updated, rows_trashed}} <- result do
      if rows_trashed > 0 do
        Shared.log_activity(%{
          action: "catalogue.trashed",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "catalogue",
          resource_uuid: catalogue.uuid,
          metadata: %{"name" => catalogue.name}
        })
      end

      {:ok, updated}
    end
  end

  @doc """
  Restores a soft-deleted catalogue, and with it exactly what
  `trash_catalogue/2` took.

  In a transaction: the categories and items stamped as taken by this
  catalogue come back, each to the status it had (an `inactive` item
  returns `inactive`, an `archived` catalogue returns `archived`). Rows
  trashed on their own before the catalogue — an item, or a category with
  whatever its own trash took — stay in the catalogue's trash. Deleted
  rows with no stamp predate provenance and come back with the catalogue,
  as they always did. An item whose category is still in the trash after
  that pass stays in the trash too, so no live item sits in a trashed
  category.

  The catalogue returns to its folder, or to root when that folder is
  gone or trashed. A catalogue that is not deleted is returned unchanged
  (decided from the row, not the argument — callers often pass the
  pre-trash struct).

  Refuses with `{:error, :external_id_taken}` when a live row has taken the
  `external_id` of one of the rows coming back; nothing is restored.

  Inside a caller's own transaction the collision is raised as the
  `Postgrex.Error` instead, because the database has already aborted that
  transaction.

  ## Examples

      {:ok, catalogue} = Catalogue.restore_catalogue(catalogue)
  """
  @spec restore_catalogue(Catalogue.t(), keyword()) ::
          {:ok, Catalogue.t()} | {:error, term()}
  def restore_catalogue(%Catalogue{} = catalogue, opts \\ []) do
    result =
      Trash.guard_external_id(fn ->
        repo().transaction(fn -> restore_locked_catalogue(catalogue) end)
      end)

    case result do
      {:ok, {:restored, {updated, categories_restored, items_restored}}} ->
        Shared.log_activity(%{
          action: "catalogue.restored",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "catalogue",
          resource_uuid: updated.uuid,
          metadata: %{
            "name" => updated.name,
            "categories_restored" => categories_restored,
            "items_restored" => items_restored
          }
        })

        {:ok, updated}

      {:ok, {:unchanged, {fresh, _, _}}} ->
        {:ok, fresh}

      {:error, _} = error ->
        error
    end
  end

  defp restore_locked_catalogue(catalogue) do
    Shared.lock_catalogues_order!()
    Trash.lock_catalogue!(catalogue.uuid)

    case repo().get(Catalogue, catalogue.uuid) do
      nil -> repo().rollback(:not_found)
      %Catalogue{status: "deleted"} = fresh -> {:restored, do_restore_catalogue(fresh)}
      fresh -> {:unchanged, {fresh, 0, 0}}
    end
  end

  defp do_restore_catalogue(%Catalogue{uuid: root} = catalogue) do
    now = DateTime.utc_now()

    {categories_restored, _} =
      from(c in Category, where: c.catalogue_uuid == ^root and c.status == "deleted")
      |> Trash.trashed_by_or_unstamped(root)
      |> Trash.restore_trashed(:category, now)
      |> repo().update_all([])

    stamped_items =
      from(i in Item, as: :item, where: i.catalogue_uuid == ^root and i.status == "deleted")
      |> Trash.trashed_by_or_unstamped(root)

    {items_restored, _} =
      stamped_items
      |> Trash.outside_trashed_categories()
      |> Trash.restore_trashed(:item, now)
      |> repo().update_all([])

    Trash.restamp_left_behind!(stamped_items)

    # Restore to where it came from — unless that home is gone. A
    # hard-deleted folder already SET NULLed the reference (root); a
    # legacy-trashed folder is merely hidden, so restoring into it would
    # strand the catalogue — normalize that to root too.
    query = from(c in Catalogue, where: c.uuid == ^root) |> Trash.restore_trashed(:catalogue, now)

    query =
      case restored_folder_home(catalogue.folder_uuid) do
        :keep ->
          query

        :root ->
          update(query, set: [folder_uuid: nil, position: ^Shared.next_level_position(nil)])
      end

    repo().update_all(query, [])

    {repo().get!(Catalogue, root), categories_restored, items_restored}
  end

  @doc """
  Permanently deletes a catalogue and all its contents from the database.

  **Cascades downward** in a transaction:
  1. Hard-deletes all items in the catalogue's categories
  2. Hard-deletes all categories
  3. Hard-deletes the catalogue

  Refuses with `{:error, {:referenced_by_smart_items, count}}` when one or
  more smart-catalogue items still have rules pointing at this catalogue.
  V102's `ON DELETE CASCADE` would silently wipe those rule rows;
  callers should resolve the references explicitly (or remove the rules)
  before retrying. Use `:force` to bypass this guard at your own risk.

  This cannot be undone.

  ## Options

    * `:actor_uuid` — UUID to attribute on the activity log
    * `:force` — when `true`, deletes even if smart-rule references exist
    * `:only_trashed` — pass `true` from a Deleted-tab action: the call
      then refuses with `{:error, :not_in_trash}` when the catalogue,
      re-read under the lock, is no longer trashed (restored in another
      tab meanwhile)

  ## Examples

      {:ok, _} = Catalogue.permanently_delete_catalogue(catalogue)
      {:error, {:referenced_by_smart_items, 3}} =
        Catalogue.permanently_delete_catalogue(catalogue_with_refs)
  """
  @spec permanently_delete_catalogue(Catalogue.t(), keyword()) ::
          {:ok, Catalogue.t()}
          | {:error, {:referenced_by_smart_items, non_neg_integer()}}
          | {:error, term()}
  def permanently_delete_catalogue(%Catalogue{} = catalogue, opts \\ []) do
    force? = Keyword.get(opts, :force, false)

    result =
      repo().transaction(fn ->
        Trash.lock_catalogue!(catalogue.uuid)
        lock_catalogue_rows!(catalogue.uuid)

        if opts[:only_trashed] == true and
             not match?(%{status: "deleted"}, repo().get(Catalogue, catalogue.uuid)),
           do: repo().rollback(:not_in_trash)

        # Counted under the lock: a rule added between a pre-flight count
        # and the delete would be wiped by V102's ON DELETE CASCADE.
        ref_count = PhoenixKitCatalogue.Catalogue.catalogue_reference_count(catalogue.uuid)

        if ref_count > 0 and not force?,
          do: repo().rollback({:referenced_by_smart_items, ref_count})

        release = catalogue_release_plan(catalogue.uuid)
        do_permanently_delete_catalogue(catalogue.uuid)
        {ref_count, release}
      end)

    with {:ok, {ref_count, release}} <- result do
      MediaFolders.release(release)

      Shared.log_activity(%{
        action: "catalogue.permanently_deleted",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "catalogue",
        resource_uuid: catalogue.uuid,
        metadata: %{
          "name" => catalogue.name,
          "smart_rules_cascaded" => ref_count
        }
      })

      {:ok, catalogue}
    end
  end

  # Category rows first, then the catalogue row — the order an item insert
  # takes them (its category FOR SHARE, then the catalogue's foreign key).
  # A create or move into this catalogue meanwhile waits on those rows and
  # then fails its foreign key, instead of surviving the delete unfiled
  # through `ON DELETE SET NULL`.
  defp lock_catalogue_rows!(catalogue_uuid) do
    Trash.lock_catalogue_categories!(catalogue_uuid)

    repo().one(
      from(c in Catalogue, where: c.uuid == ^catalogue_uuid, lock: "FOR UPDATE", select: c.uuid)
    ) || repo().rollback(:not_found)
  end

  # The folders of a catalogue and everything in it, read while they exist.
  defp catalogue_release_plan(catalogue_uuid) do
    MediaFolders.release_plan([
      from(c in Catalogue, where: c.uuid == ^catalogue_uuid),
      from(c in Category, where: c.catalogue_uuid == ^catalogue_uuid),
      from(i in Item, where: i.catalogue_uuid == ^catalogue_uuid)
    ])
  end

  defp do_permanently_delete_catalogue(catalogue_uuid) do
    from(i in Item, where: i.catalogue_uuid == ^catalogue_uuid)
    |> repo().delete_all()

    # Break V103 self-FKs inside the catalogue before deleting — every
    # category in the catalogue is being removed anyway, so NULLing
    # parent_uuid first is the simplest way to avoid a leaf-first traversal.
    from(c in Category, where: c.catalogue_uuid == ^catalogue_uuid)
    |> repo().update_all(set: [parent_uuid: nil])

    from(c in Category, where: c.catalogue_uuid == ^catalogue_uuid)
    |> repo().delete_all()

    from(c in Catalogue, where: c.uuid == ^catalogue_uuid)
    |> repo().delete_all()
  end

  @doc "Returns a changeset for tracking catalogue changes."
  @spec change_catalogue(Catalogue.t(), map()) :: Ecto.Changeset.t(Catalogue.t())
  def change_catalogue(%Catalogue{} = catalogue, attrs \\ %{}) do
    Catalogue.changeset(catalogue, attrs)
  end

  defp restored_folder_home(nil), do: :keep

  defp restored_folder_home(folder_uuid) do
    case repo().one(from(f in Folder, where: f.uuid == ^folder_uuid, select: f.status)) do
      "active" -> :keep
      _ -> :root
    end
  end

  @doc """
  Returns the next available `position` for a new catalogue — one past
  the current max, falling back to `1` on an empty table.
  """
  @spec next_catalogue_position() :: integer()
  def next_catalogue_position do
    case repo().one(from(c in Catalogue, select: max(c.position))) do
      nil -> 1
      n -> n + 1
    end
  end

  @doc """
  Re-indexes the supplied list of catalogue UUIDs into positions
  `1..N`. Used by the catalogues index DnD handler.

  UUIDs missing from the table are skipped. The whole pass runs in one
  transaction. Returns `:ok` on success or `{:error, reason}` on
  transaction failure.
  """
  @spec reorder_catalogues([Ecto.UUID.t()], keyword()) ::
          :ok | {:error, :too_many_uuids | term()}
  def reorder_catalogues(ordered_uuids, opts \\ [])

  def reorder_catalogues([], _opts), do: :ok

  def reorder_catalogues(ordered_uuids, opts)
      when is_list(ordered_uuids) and length(ordered_uuids) > @reorder_max_uuids do
    Shared.log_reorder_rejected(:catalogue, :too_many_uuids, length(ordered_uuids), nil, opts)
    {:error, :too_many_uuids}
  end

  def reorder_catalogues(ordered_uuids, opts) when is_list(ordered_uuids) do
    unique_uuids = Helpers.dedupe_keep_last(ordered_uuids)

    case write_catalogue_positions(unique_uuids) do
      {:ok, _} ->
        Shared.log_activity(%{
          action: "catalogue.reordered",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "catalogue",
          resource_uuid: List.first(unique_uuids),
          metadata: %{"count" => length(unique_uuids)}
        })

        :ok

      {:error, reason} ->
        Shared.log_reorder_db_error(:catalogue, unique_uuids, nil, opts)
        {:error, reason}
    end
  end

  # Future (perf): single-pass and single-statement variant once payload
  # sizes warrant it (see categories/items helpers above for the same
  # cross-reference). Catalogues currently have no unique index on
  # `position`, so the negative-pass dance isn't even strictly
  # required — kept here for parity with the other reorder paths.
  defp write_catalogue_positions(unique_uuids) do
    pairs = Enum.with_index(unique_uuids, 1)

    repo().transaction(fn ->
      Shared.lock_catalogues_order!()

      Enum.each(pairs, fn {uuid, idx} ->
        from(c in Catalogue, where: c.uuid == ^uuid)
        |> repo().update_all(set: [position: idx])
      end)
    end)
  end
end
