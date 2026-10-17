defmodule PhoenixKitCatalogue.Catalogue.Trash do
  @moduledoc false
  # Trash provenance stamps and the per-catalogue advisory lock every
  # trash / restore / permanent-delete path of the catalogue context takes.
  # Internal; reached only from `Catalogue.*` (`lock_catalogue!/1` is also
  # re-exported from `PhoenixKitCatalogue.Catalogue` for `Duplication`).

  import Ecto.Query, warn: false

  alias PhoenixKitCatalogue.Schemas.Category

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # Every trash path stamps each row it flips with WHAT flipped it, under
  # the reserved top-level `data["_trash"]` key:
  #
  #     %{"via" => "self" | "catalogue" | "category",
  #       "root" => uuid of the row the operator trashed,
  #       "from_status" => the status the row had}
  #
  # Restoring a root revives only the rows whose stamp names that root,
  # back to their (whitelisted) `from_status`, and clears the stamp — so a
  # restore undoes exactly the trash that put a row in the bin, and a row
  # trashed on its own before its parent stays there.
  #
  # The stamp is read ONLY on deleted rows, written by every trash path
  # and cleared by every restore path, so a stale copy on a live row is
  # inert. A deleted row with no stamp predates provenance:
  # `restore_catalogue/2` revives it with its catalogue, as it always did;
  # `restore_category/2` leaves it alone. Guide:
  # `dev_docs/guides/trash-and-restore.md`.
  #
  # Every trash / restore / permanent-delete path takes `lock_catalogue!/1`
  # first and decides from rows re-read under it. Without it a category
  # trash racing an item restore left an ACTIVE item under a DELETED
  # category of an active catalogue — in neither the tree nor any
  # Deleted tab.

  @catalogue_lock_class 727_401_120

  # Public only for `Catalogue.Duplication`, which holds a source's lock
  # while copying it.
  @doc false
  @spec lock_catalogue!(Ecto.UUID.t() | nil) :: :ok
  def lock_catalogue!(nil), do: :ok

  def lock_catalogue!(catalogue_uuid) do
    repo().query!("SELECT pg_advisory_xact_lock($1::int, hashtext($2::text))", [
      @catalogue_lock_class,
      to_string(catalogue_uuid)
    ])

    :ok
  end

  # Several catalogues: always in the same (sorted) order, so two bulk
  # operations over overlapping catalogues cannot deadlock.
  @doc false
  def lock_catalogues!(catalogue_uuids) do
    catalogue_uuids
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(&lock_catalogue!/1)
  end

  # A transaction whose locks are keyed on a catalogue read before locking.
  # When a concurrent move changed that catalogue the attempt rolls back
  # with `:catalogue_moved` and runs again from the top, which releases
  # every lock first. Nested in an outer transaction there is nothing to
  # release, so the error goes back to the caller.
  @doc false
  def locked_transaction(fun, attempts \\ 3) do
    case guard_external_id(fn -> repo().transaction(fun) end) do
      {:error, :catalogue_moved} = error when attempts > 1 ->
        if repo().in_transaction?(), do: error, else: locked_transaction(fun, attempts - 1)

      result ->
        result
    end
  end

  # A restore brings rows back with `update_all`, which cannot map a
  # constraint to a changeset: a live row that took the `external_id` of a
  # trashed one arrives as a raised unique violation on one of the two V5
  # indexes. Only that one is turned into a result; every other database
  # error is re-raised untouched. The exception unwinds the transaction, so
  # nothing is half-restored. Inside a caller's own transaction Postgres has
  # already aborted it, so a tuple would invite the caller to carry on in a
  # dead transaction (25P02); there the exception goes to the caller as is.
  @external_id_indexes [
    "phoenix_kit_cat_items_external_id_uniq",
    "phoenix_kit_cat_categories_external_id_uniq"
  ]

  @doc false
  def guard_external_id(fun) do
    fun.()
  rescue
    error in Postgrex.Error ->
      if external_id_violation?(error) and not repo().in_transaction?(),
        do: {:error, :external_id_taken},
        else: reraise(error, __STACKTRACE__)
  end

  @doc false
  @spec external_id_conflict?(Ecto.Changeset.t()) :: boolean()
  def external_id_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:data, {_message, opts}} -> opts[:constraint_name] in @external_id_indexes
      _other -> false
    end)
  end

  defp external_id_violation?(%Postgrex.Error{postgres: %{code: :unique_violation} = postgres}),
    do: postgres[:constraint] in @external_id_indexes

  defp external_id_violation?(_error), do: false

  # Bulk paths: locks every catalogue the rows live in, then checks none
  # moved between that read and the locks. A category move takes the same
  # locks, so the set is stable from here to commit.
  @doc false
  def lock_catalogues_of!(schema, uuids) do
    catalogue_uuids = catalogue_uuids_of(schema, uuids)
    lock_catalogues!(catalogue_uuids)

    if catalogue_uuids_of(schema, uuids) != catalogue_uuids,
      do: repo().rollback(:catalogue_moved)

    catalogue_uuids
  end

  @doc false
  def catalogue_uuids_of(schema, uuids) do
    from(r in schema,
      where: r.uuid in ^uuids and not is_nil(r.catalogue_uuid),
      distinct: true,
      order_by: r.catalogue_uuid,
      select: r.catalogue_uuid
    )
    |> repo().all()
  end

  # A catalogue's category rows FOR UPDATE, in a stable order, before its
  # items change: an item create or move into one of them (FOR SHARE on the
  # category) either commits first and is swept, or waits and then sees the
  # category trashed.
  @doc false
  def lock_catalogue_categories!(catalogue_uuid) do
    repo().all(
      from(c in Category,
        where: c.catalogue_uuid == ^catalogue_uuid,
        order_by: c.uuid,
        lock: "FOR UPDATE",
        select: c.uuid
      )
    )

    :ok
  end

  # Locks the catalogue a category or item lives in, then re-reads the row
  # FOR UPDATE: every decision is made from the locked row, never from the
  # caller's (possibly stale) struct.
  @doc false
  def lock_row_in_catalogue!(schema, uuid) do
    case repo().one(from(r in schema, where: r.uuid == ^uuid, select: {r.uuid, r.catalogue_uuid})) do
      nil ->
        repo().rollback(:not_found)

      {_uuid, catalogue_uuid} ->
        lock_catalogue!(catalogue_uuid)

        fresh =
          repo().one(from(r in schema, where: r.uuid == ^uuid, lock: "FOR UPDATE")) ||
            repo().rollback(:not_found)

        # Moved to another catalogue between the read and the lock. Taking
        # the new key now could invert the sorted order another path holds
        # both in, so this attempt gives up and `locked_transaction/1` runs
        # it again from the top.
        if fresh.catalogue_uuid != catalogue_uuid, do: repo().rollback(:catalogue_moved)

        fresh
    end
  end

  # Category rows FOR UPDATE, in a stable order. An item create or move
  # takes its target category FOR SHARE, so it either commits before a
  # subtree trash (and is swept by it) or waits and then sees the trash.
  @doc false
  def lock_categories!([]), do: :ok

  def lock_categories!(category_uuids) do
    repo().all(
      from(c in Category,
        where: c.uuid in ^category_uuids,
        order_by: c.uuid,
        lock: "FOR UPDATE",
        select: c.uuid
      )
    )

    :ok
  end

  # Flips live rows to "deleted" and stamps who took them. One statement:
  # `from_status` reads the row's status before the SET applies.
  @doc false
  def stamp_trashed(query, via, root_uuid, now) do
    update(query, [r],
      set: [
        status: "deleted",
        updated_at: ^now,
        data:
          fragment(
            "jsonb_set(COALESCE(?, '{}'::jsonb), '{_trash}', jsonb_build_object('via', ?::text, 'root', ?::text, 'from_status', ?))",
            r.data,
            ^via,
            ^to_string(root_uuid),
            r.status
          )
      ]
    )
  end

  # The same, for rows the operator trashed directly (each is its own root).
  @doc false
  def stamp_trashed_self(query, now) do
    update(query, [r],
      set: [
        status: "deleted",
        updated_at: ^now,
        data:
          fragment(
            "jsonb_set(COALESCE(?, '{}'::jsonb), '{_trash}', jsonb_build_object('via', 'self', 'root', ?::text, 'from_status', ?))",
            r.data,
            r.uuid,
            r.status
          )
      ]
    )
  end

  # Brings rows back to the status the stamp recorded — whitelisted, since
  # `data` is a free-form map — and clears the stamp.
  @doc false
  def restore_trashed(query, :item, now) do
    update(query, [r],
      set: [
        status:
          fragment(
            "CASE ? #>> '{_trash,from_status}' WHEN 'inactive' THEN 'inactive' WHEN 'discontinued' THEN 'discontinued' ELSE 'active' END",
            r.data
          ),
        data: fragment("COALESCE(?, '{}'::jsonb) - '_trash'", r.data),
        updated_at: ^now
      ]
    )
  end

  def restore_trashed(query, :catalogue, now) do
    update(query, [r],
      set: [
        status:
          fragment(
            "CASE ? #>> '{_trash,from_status}' WHEN 'archived' THEN 'archived' ELSE 'active' END",
            r.data
          ),
        data: fragment("COALESCE(?, '{}'::jsonb) - '_trash'", r.data),
        updated_at: ^now
      ]
    )
  end

  def restore_trashed(query, :category, now) do
    update(query, [r],
      set: [
        status: "active",
        data: fragment("COALESCE(?, '{}'::jsonb) - '_trash'", r.data),
        updated_at: ^now
      ]
    )
  end

  @doc false
  def trashed_by(query, root_uuid) do
    where(query, [r], fragment("(? #>> '{_trash,root}') = ?", r.data, ^to_string(root_uuid)))
  end

  @doc false
  def trashed_by_or_unstamped(query, root_uuid) do
    where(
      query,
      [r],
      fragment(
        "((? -> '_trash') IS NULL OR (? #>> '{_trash,root}') = ?)",
        r.data,
        r.data,
        ^to_string(root_uuid)
      )
    )
  end

  # For an item query bound `as: :item`: skips items whose category is in
  # the trash, so a restore never leaves a live item in a trashed category.
  # Items a restore had to leave in the trash because their category is
  # still trashed under another root. Their stamp named the root being
  # restored, so a later trash and restore of that root would have revived
  # them from under the trashed category (randomized test, seed 423352).
  # They join that category's unit instead: its stamp root (restoring the
  # category, or what trashed it, brings them back with it), or their own
  # when the category carries no stamp. `from_status` is kept. The same
  # rule Delete Forever applies to rows it leaves behind.
  @doc false
  def restamp_left_behind!(stamped_items) do
    from(i in stamped_items,
      join: c in Category,
      on: c.uuid == i.category_uuid,
      where: c.status == "deleted",
      update: [
        set: [
          data:
            fragment(
              """
              COALESCE(?, '{}'::jsonb) || jsonb_build_object('_trash',
                COALESCE(? -> '_trash', '{}'::jsonb) || jsonb_build_object(
                  'root', COALESCE(? #>> '{_trash,root}', ?::text),
                  'via', CASE WHEN ? #>> '{_trash,root}' IS NULL THEN 'self' ELSE 'category' END))
              """,
              i.data,
              i.data,
              c.data,
              i.uuid,
              c.data
            )
        ]
      ]
    )
    |> repo().update_all([])
  end

  @doc false
  def outside_trashed_categories(query) do
    where(
      query,
      [item: i],
      is_nil(i.category_uuid) or
        not exists(
          from(c in Category,
            where: c.uuid == parent_as(:item).category_uuid and c.status == "deleted"
          )
        )
    )
  end
end
