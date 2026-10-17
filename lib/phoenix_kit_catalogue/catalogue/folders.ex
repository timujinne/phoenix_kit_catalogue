defmodule PhoenixKitCatalogue.Catalogue.Folders do
  @moduledoc """
  Catalogue folders.

  A module-global nesting layer for organizing catalogues on the admin
  index (inline tree-table). Folders are their own dedicated thing —
  unrelated to the media-folder system. Catalogues carry a nullable
  `folder_uuid` (NULL = unfiled / root). Mirrors the category-tree
  helpers, minus the catalogue scoping (folders are not scoped to
  one catalogue). All write invariants (cycle guard, reject-trashed
  target, position normalization) live here in the context.

  Public surface is re-exported from `PhoenixKitCatalogue.Catalogue` via
  `defdelegate`, so callers keep using the canonical context module.
  """

  import Ecto.Query, warn: false

  alias PhoenixKitCatalogue.Catalogue.{ActivityLog, Helpers, Shared}
  alias PhoenixKitCatalogue.Schemas.{Catalogue, Folder}

  @reorder_max_uuids Shared.reorder_max_uuids()

  defp repo, do: PhoenixKit.RepoHelper.repo()

  defp folder_ref(nil), do: ActivityLog.ref(nil, nil, folder_root_label())

  defp folder_ref(uuid),
    do: ActivityLog.ref(uuid, Shared.name_of(&get_folder/1, uuid), folder_root_label())

  defp folder_root_label,
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "All catalogues")

  @doc """
  Returns folders paired with their tree depth, in depth-first display
  order (`position`, then `name`, recursing into children). Each entry is
  `{folder, depth}` where depth `0` is a root. Mirrors
  `list_category_tree/2` but folders are module-global.

  ## Options

    * `:mode` — `:active` (default, excludes deleted) or `:deleted`.
    * `:exclude_subtree_of` — skip a folder and all its descendants (the
      folder being moved — you can't parent it under itself/its subtree).
  """
  @spec list_folder_tree(keyword()) :: [{Folder.t(), non_neg_integer()}]
  def list_folder_tree(opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)

    exclude_uuids =
      case Keyword.get(opts, :exclude_subtree_of) do
        nil -> []
        uuid -> folder_subtree_uuids(uuid)
      end

    normalized = normalized_folder_rows(mode, exclude_uuids)
    index = Enum.group_by(normalized, & &1.parent_uuid)

    {acc, _} =
      Enum.reduce(Map.get(index, nil, []), {[], index}, fn root, {acc, idx} ->
        {collect_folder_tree(root, idx, 0, acc), idx}
      end)

    Enum.reverse(acc)
  end

  defp collect_folder_tree(%Folder{} = folder, index, depth, acc) do
    acc = [{folder, depth} | acc]

    index
    |> Map.get(folder.uuid, [])
    |> Enum.reduce(acc, fn child, acc -> collect_folder_tree(child, index, depth + 1, acc) end)
  end

  # Loads folders for `mode`, drops the excluded subtree, and
  # orphan-promotes rows whose parent is missing from the set (a deleted
  # parent in `:active` mode, or the excluded subtree) to roots by
  # rewriting `parent_uuid` to nil — so a child never vanishes when its
  # parent is trashed (trash is non-cascading, parity with categories).
  defp normalized_folder_rows(mode, exclude_uuids) do
    # uuid last — see `normalized_category_rows/3`.
    base = from(f in Folder, order_by: [asc: f.position, asc: f.name, asc: f.uuid])

    query =
      case mode do
        :active -> where(base, [f], f.status != "deleted")
        :deleted -> where(base, [f], f.status == "deleted")
      end

    folders =
      query
      |> repo().all()
      |> Enum.reject(&(&1.uuid in exclude_uuids))

    uuid_set = MapSet.new(folders, & &1.uuid)

    Enum.map(folders, fn f ->
      if f.parent_uuid == nil or MapSet.member?(uuid_set, f.parent_uuid) do
        f
      else
        %{f | parent_uuid: nil}
      end
    end)
  end

  @doc """
  Returns the set of folder UUIDs (in the given `:mode`) that have at
  least one child folder — lets the tree show an expand affordance
  without an N+1.
  """
  @spec folder_uuids_with_children(keyword()) :: MapSet.t()
  def folder_uuids_with_children(opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)

    base =
      from(f in Folder, where: not is_nil(f.parent_uuid), select: f.parent_uuid, distinct: true)

    query =
      case mode do
        :active -> where(base, [f], f.status != "deleted")
        :deleted -> where(base, [f], f.status == "deleted")
      end

    query |> repo().all() |> MapSet.new()
  end

  @doc """
  Groups non-deleted catalogues by their folder home for the tree view.
  Returns `%{(folder_uuid | nil) => [Catalogue.t()]}`. A catalogue whose
  folder is trashed or missing is promoted to the `nil` (root) bucket so it
  never disappears — parity with the folder/category orphan promotion.
  Within a bucket, catalogues keep `position, name` order.

  ## Options

    * `:status` — passed through to `list_catalogues/1` (e.g. `"deleted"` for
      the deleted view). Defaults to non-deleted (active + archived).
  """
  @spec catalogues_by_folder(keyword()) :: %{(Ecto.UUID.t() | nil) => [Catalogue.t()]}
  def catalogues_by_folder(opts \\ []) do
    active_folders =
      from(f in Folder, where: f.status != "deleted", select: f.uuid)
      |> repo().all()
      |> MapSet.new()

    catalogues =
      case Keyword.get(opts, :status) do
        nil -> PhoenixKitCatalogue.Catalogue.list_catalogues()
        status -> PhoenixKitCatalogue.Catalogue.list_catalogues(status: status)
      end

    Enum.group_by(catalogues, fn c ->
      if c.folder_uuid != nil and MapSet.member?(active_folders, c.folder_uuid),
        do: c.folder_uuid,
        else: nil
    end)
  end

  @doc "Fetches a folder by UUID. Returns `nil` if not found."
  @spec get_folder(Ecto.UUID.t()) :: Folder.t() | nil
  def get_folder(uuid), do: Helpers.get_by_uuid(Folder, uuid)

  @doc """
  Creates a folder. `:parent_uuid` (optional) nests it; a new folder is
  inserted at the front of its parent level (one below the current min
  interleaved position) so it is immediately visible.
  """
  @spec create_folder(map(), keyword()) ::
          {:ok, Folder.t()} | {:error, Ecto.Changeset.t(Folder.t())}
  def create_folder(attrs, opts \\ []) do
    result =
      repo().transaction(fn ->
        Shared.lock_catalogues_order!()
        parent_uuid = Shared.normalize_folder_uuid(Helpers.fetch_attr(attrs, :parent_uuid))

        attrs =
          attrs
          |> Helpers.put_attr(:parent_uuid, parent_uuid)
          |> Helpers.put_attr(:position, front_level_position(parent_uuid))

        case %Folder{} |> Folder.changeset(attrs) |> repo().insert() do
          {:ok, folder} -> folder
          {:error, changeset} -> repo().rollback(changeset)
        end
      end)

    case result do
      {:ok, folder} = ok ->
        Shared.log_activity(
          %{
            action: "folder.created",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "folder",
            resource_uuid: folder.uuid,
            metadata: %{"name" => folder.name, "parent_uuid" => folder.parent_uuid}
          },
          Keyword.take(opts, [:broadcast, :mode])
        )

        ok

      error ->
        error
    end
  end

  @doc """
  Updates a folder's own fields (name/status/data). Parent moves go
  through `move_folder/3` — a `parent_uuid` key here is ignored.
  """
  @spec update_folder(Folder.t(), map(), keyword()) ::
          {:ok, Folder.t()} | {:error, Ecto.Changeset.t(Folder.t())}
  def update_folder(%Folder{} = folder, attrs, opts \\ []) do
    attrs = attrs |> Map.delete(:parent_uuid) |> Map.delete(:position)

    case folder |> Folder.changeset(attrs) |> repo().update() do
      {:ok, updated} = ok ->
        if changed?(folder, updated, [:name, :status, :data]) do
          Shared.log_activity(%{
            action: "folder.updated",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "folder",
            resource_uuid: updated.uuid,
            metadata: %{"name" => updated.name}
          })
        end

        ok

      error ->
        error
    end
  end

  @doc """
  Moves a folder under `new_parent_uuid` (`nil` = root). Rejects a move
  into the folder's own subtree (cycle) or into a trashed/missing parent.
  The folder is appended at the end of the target level. No-op when the
  parent is unchanged.
  """
  @spec move_folder(Folder.t(), Ecto.UUID.t() | nil, keyword()) ::
          {:ok, Folder.t()} | {:error, :cycle | :folder_not_found | :folder_trashed | term()}
  def move_folder(%Folder{} = folder, new_parent_uuid, opts \\ []) do
    new_parent = Shared.normalize_folder_uuid(new_parent_uuid)

    if new_parent == folder.parent_uuid do
      {:ok, folder}
    else
      do_move_folder(folder, new_parent, opts)
    end
  end

  # Cycle check + target validation + position calc + update run inside a
  # single transaction with `FOR UPDATE` on the moved row, mirroring
  # `do_move_category_under/3`. The cycle check re-runs against the
  # committed tree under the lock, so a concurrent reparent that already
  # landed is seen here and rejected with `:cycle` rather than silently
  # committing a structure that would vanish from `list_folder_tree/1`
  # (it only walks from `nil` roots).
  defp do_move_folder(folder, new_parent, opts) do
    result =
      repo().transaction(fn ->
        Shared.lock_catalogues_order!()
        repo().one!(from(f in Folder, where: f.uuid == ^folder.uuid, lock: "FOR UPDATE"))
        run_locked_folder_move(folder, new_parent)
      end)

    with {:ok, updated} <- result do
      Shared.log_activity(%{
        action: "folder.moved",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "folder",
        resource_uuid: folder.uuid,
        metadata: %{
          "name" => folder.name,
          "changes" =>
            ActivityLog.changes([
              {:parent, folder_ref(folder.parent_uuid), folder_ref(new_parent)}
            ])
        }
      })

      {:ok, updated}
    end
  end

  # Runs under the `FOR UPDATE` lock from `do_move_folder/3`. Re-checks the
  # cycle against the committed tree, validates the target, then reparents.
  # Any error rolls the transaction back with the reason so the outer
  # `{:ok, _} <- result` short-circuits without logging.
  defp run_locked_folder_move(folder, new_parent) do
    attrs = %{parent_uuid: new_parent, position: Shared.next_level_position(new_parent)}

    with :ok <- folder_cycle_guard(folder, new_parent),
         :ok <- validate_target_folder(new_parent),
         {:ok, updated} <- folder |> Folder.changeset(attrs) |> repo().update() do
      updated
    else
      {:error, reason} -> repo().rollback(reason)
    end
  end

  defp folder_cycle_guard(folder, new_parent) do
    if new_parent != nil and new_parent in folder_subtree_uuids(folder.uuid),
      do: {:error, :cycle},
      else: :ok
  end

  @doc """
  Soft-deletes a folder (status `"deleted"`). Non-cascading: child
  folders and the catalogues filed here keep their `*_uuid`, but
  orphan-promote to root in the active tree view. Nothing else changes.
  A folder already in the trash is returned unchanged.
  """
  @spec trash_folder(Folder.t(), keyword()) ::
          {:ok, Folder.t()} | {:error, Ecto.Changeset.t(Folder.t())}
  def trash_folder(%Folder{} = folder, opts \\ []) do
    result =
      repo().transaction(fn ->
        # The lock `restore_catalogue/2` holds while it decides whether a
        # catalogue's folder is still a home to return to.
        Shared.lock_catalogues_order!()

        # Decided from the row, not the argument: a folder already in the
        # trash is not trashed again.
        case repo().get(Folder, folder.uuid) do
          %Folder{status: "deleted"} = fresh -> {:unchanged, fresh}
          fresh -> {:trashed, update_folder_status!(fresh || folder, %{status: "deleted"})}
        end
      end)

    case result do
      {:ok, {:trashed, updated}} ->
        Shared.log_activity(%{
          action: "folder.trashed",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "folder",
          resource_uuid: folder.uuid,
          metadata: %{"name" => folder.name}
        })

        {:ok, updated}

      {:ok, {:unchanged, fresh}} ->
        {:ok, fresh}

      error ->
        error
    end
  end

  defp restore_folder_row!(folder) do
    parent = if validate_target_folder(folder.parent_uuid) == :ok, do: folder.parent_uuid

    update_folder_status!(folder, %{
      status: "active",
      parent_uuid: parent,
      position: Shared.next_level_position(parent)
    })
  end

  defp update_folder_status!(folder, attrs) do
    case folder |> Folder.changeset(attrs) |> repo().update() do
      {:ok, updated} -> updated
      {:error, changeset} -> repo().rollback(changeset)
    end
  end

  @doc """
  Restores a soft-deleted folder. If its prior parent is gone or still
  trashed, the folder is restored to root (appended) so it stays
  reachable; otherwise it keeps its parent. A folder that is not in the
  trash is returned unchanged.
  """
  @spec restore_folder(Folder.t(), keyword()) ::
          {:ok, Folder.t()} | {:error, Ecto.Changeset.t(Folder.t())}
  def restore_folder(%Folder{} = folder, opts \\ []) do
    result =
      repo().transaction(fn ->
        Shared.lock_catalogues_order!()

        # Decided from the row, not the argument: a folder that is not in
        # the trash keeps its place and is not restored again.
        case repo().get(Folder, folder.uuid) do
          %Folder{status: status} = fresh when status != "deleted" ->
            {:unchanged, fresh}

          fresh ->
            {:restored, restore_folder_row!(fresh || folder)}
        end
      end)

    case result do
      {:ok, {:restored, updated}} ->
        Shared.log_activity(%{
          action: "folder.restored",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "folder",
          resource_uuid: folder.uuid,
          metadata: %{"name" => folder.name, "parent_uuid" => updated.parent_uuid}
        })

        {:ok, updated}

      {:ok, {:unchanged, fresh}} ->
        {:ok, fresh}

      error ->
        error
    end
  end

  @doc """
  Hard-deletes an EMPTY folder — no trash step, no restore. Folders are
  organizational titles; deleting one is only allowed once nothing
  references it: no subfolders and no catalogues filed in it (any
  status — a trashed catalogue still points at its folder). Returns
  `{:error, :not_empty}` otherwise.
  """
  @spec delete_empty_folder(Folder.t(), keyword()) ::
          {:ok, Folder.t()} | {:error, :not_empty | term()}
  def delete_empty_folder(%Folder{} = folder, opts \\ []) do
    # Membership writers (create/move/file) take the same catalogues-order
    # lock, so a concurrent insert cannot sneak in under READ COMMITTED
    # after NOT EXISTS is evaluated — that would otherwise trip
    # `ON DELETE SET NULL` and silently unfile the new occupant.
    {count, _} =
      repo().transaction(fn ->
        Shared.lock_catalogues_order!()

        {n, _} =
          repo().delete_all(
            from(f in Folder,
              as: :folder,
              where: f.uuid == ^folder.uuid,
              where:
                not exists(from(sf in Folder, where: sf.parent_uuid == parent_as(:folder).uuid)),
              where:
                not exists(from(c in Catalogue, where: c.folder_uuid == parent_as(:folder).uuid))
            )
          )

        n
      end)
      |> case do
        {:ok, n} -> {n, nil}
        {:error, reason} -> {0, reason}
      end

    if count == 1 do
      Shared.log_activity(%{
        action: "folder.deleted",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "folder",
        resource_uuid: folder.uuid,
        metadata: %{"name" => folder.name}
      })

      {:ok, folder}
    else
      # Not deleted: either the folder is non-empty, or it's already
      # gone. Report :not_empty when contents explain it; otherwise the
      # row vanished under us and the delete is effectively done.
      not_empty? =
        repo().exists?(from(f in Folder, where: f.parent_uuid == ^folder.uuid)) or
          repo().exists?(from(c in Catalogue, where: c.folder_uuid == ^folder.uuid))

      cond do
        not_empty? -> {:error, :not_empty}
        repo().exists?(from(f in Folder, where: f.uuid == ^folder.uuid)) -> {:error, :not_empty}
        true -> {:ok, folder}
      end
    end
  end

  @doc """
  Permanently deletes a folder from the database. Non-cascading, matching
  the trash/orphan-promotion semantics: direct child folders are promoted
  to root (their `parent_uuid` is NULLed) and catalogues filed here are
  unfiled (their `folder_uuid` is NULLed) inside the same transaction
  before the folder row is removed — so neither is destroyed along with
  the folder. This cannot be undone.
  """
  @spec permanently_delete_folder(Folder.t(), keyword()) ::
          {:ok, Folder.t()} | {:error, term()}
  def permanently_delete_folder(%Folder{} = folder, opts \\ []) do
    result =
      repo().transaction(fn ->
        Shared.lock_catalogues_order!()

        from(f in Folder, where: f.parent_uuid == ^folder.uuid)
        |> repo().update_all(set: [parent_uuid: nil])

        from(c in Catalogue, where: c.folder_uuid == ^folder.uuid)
        |> repo().update_all(set: [folder_uuid: nil])

        repo().delete!(folder)
      end)

    with {:ok, _} <- result do
      Shared.log_activity(%{
        action: "folder.permanently_deleted",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "folder",
        resource_uuid: folder.uuid,
        metadata: %{"name" => folder.name}
      })

      result
    end
  end

  @doc """
  Re-indexes the supplied folder UUIDs into positions `1..N`. The caller
  passes only the UUIDs of one level (same parent); positions are global
  integers but the tree groups by `parent_uuid` first, so per-level
  `1..N` is correct. UUIDs missing from the table are skipped.
  """
  @spec reorder_folders([Ecto.UUID.t()], keyword()) ::
          :ok | {:error, :too_many_uuids | term()}
  def reorder_folders(ordered_uuids, opts \\ [])

  def reorder_folders([], _opts), do: :ok

  def reorder_folders(ordered_uuids, opts)
      when is_list(ordered_uuids) and length(ordered_uuids) > @reorder_max_uuids do
    Shared.log_reorder_rejected(:folder, :too_many_uuids, length(ordered_uuids), nil, opts)
    {:error, :too_many_uuids}
  end

  def reorder_folders(ordered_uuids, opts) when is_list(ordered_uuids) do
    unique_uuids = Helpers.dedupe_keep_last(ordered_uuids)

    result =
      repo().transaction(fn ->
        Shared.lock_catalogues_order!()

        unique_uuids
        |> Enum.with_index(1)
        |> Enum.each(fn {uuid, idx} ->
          from(f in Folder, where: f.uuid == ^uuid) |> repo().update_all(set: [position: idx])
        end)
      end)

    case result do
      {:ok, _} ->
        Shared.log_activity(%{
          action: "folder.reordered",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "folder",
          resource_uuid: List.first(unique_uuids),
          metadata: %{"count" => length(unique_uuids)}
        })

        :ok

      {:error, reason} ->
        Shared.log_reorder_db_error(:folder, unique_uuids, nil, opts)
        {:error, reason}
    end
  end

  @doc """
  Writes one merged manual order for a single level of the folder tree.

  `entries` is the level's full display order as `{"folder" | "catalogue",
  uuid}` tuples; each row's `position` is set to its index in the merged
  sequence, so folders and catalogues interleave exactly where the user
  dropped them (a level's display order sorts both types together by
  `position`). Rows the caller omits keep their old positions — callers
  send a complete level, so this only matters for concurrent edits.
  """
  @spec place_level_rows([{String.t(), Ecto.UUID.t()}], keyword()) ::
          :ok | {:error, term()}
  def place_level_rows(entries, opts \\ [])

  # An empty payload is a no-op, not a write: the body's activity log
  # reads `List.first/1` of the deduped list, which would crash on []
  # after committing a pointless transaction. Reachable from a forged
  # or degenerate `drop_row` push whose `entries` list is empty.
  def place_level_rows([], _opts), do: :ok

  def place_level_rows(entries, opts)
      when is_list(entries) and length(entries) > @reorder_max_uuids do
    Shared.log_reorder_rejected(:level, :too_many_uuids, length(entries), nil, opts)
    {:error, :too_many_uuids}
  end

  def place_level_rows(entries, opts) when is_list(entries) do
    with {:ok, unique} <- normalize_level_entries(entries),
         :ok <- validate_level_siblings(unique) do
      write_level_positions(unique, opts)
    end
  end

  defp normalize_level_entries(entries) do
    if Enum.any?(entries, fn
         {type, uuid} when type in ~w(folder catalogue) and is_binary(uuid) -> false
         _ -> true
       end) do
      {:error, :invalid_entry}
    else
      {:ok, Enum.uniq_by(entries, fn {_type, uuid} -> uuid end)}
    end
  end

  # Every named row must already live on the same folder level. A forged
  # payload that mixes two parents would rewrite positions on both, which
  # corrupts the untouched level's interleaved order.
  defp validate_level_siblings([]), do: :ok

  defp validate_level_siblings(entries) do
    folder_uuids = for {"folder", uuid} <- entries, do: uuid
    catalogue_uuids = for {"catalogue", uuid} <- entries, do: uuid

    folder_levels =
      from(f in Folder, where: f.uuid in ^folder_uuids, select: f.parent_uuid) |> repo().all()

    catalogue_levels =
      from(c in Catalogue, where: c.uuid in ^catalogue_uuids, select: c.folder_uuid)
      |> repo().all()

    case Enum.uniq(folder_levels ++ catalogue_levels) do
      [] -> :ok
      [_level] -> :ok
      _ -> {:error, :not_siblings}
    end
  end

  defp write_level_positions(unique, opts) do
    result =
      repo().transaction(fn ->
        Shared.lock_catalogues_order!()

        unique
        |> Enum.with_index(1)
        |> Enum.each(fn
          {{"folder", uuid}, idx} ->
            from(f in Folder, where: f.uuid == ^uuid) |> repo().update_all(set: [position: idx])

          {{"catalogue", uuid}, idx} ->
            from(c in Catalogue, where: c.uuid == ^uuid)
            |> repo().update_all(set: [position: idx])
        end)
      end)

    case result do
      {:ok, _} ->
        {first_type, first_uuid} = List.first(unique)
        resource_type = if first_type == "folder", do: "folder", else: "catalogue"

        Shared.log_activity(%{
          action: "catalogue.level_reordered",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: resource_type,
          resource_uuid: first_uuid,
          metadata: %{"count" => length(unique)}
        })

        :ok

      {:error, reason} ->
        Shared.log_reorder_db_error(:level, Enum.map(unique, &elem(&1, 1)), nil, opts)
        {:error, reason}
    end
  end

  @doc """
  Files a catalogue into `folder_uuid` (`nil`/`:unfiled` = root). Rejects
  a trashed/missing target folder; appends to the end of the target
  level. No-op (no write, no log) when already there.
  """
  @spec move_catalogue_to_folder(Catalogue.t(), Ecto.UUID.t() | nil | :unfiled, keyword()) ::
          {:ok, Catalogue.t()} | {:error, :folder_not_found | :folder_trashed | term()}
  def move_catalogue_to_folder(%Catalogue{} = catalogue, folder_uuid, opts \\ []) do
    target = Shared.normalize_folder_uuid(folder_uuid)

    if target == catalogue.folder_uuid do
      {:ok, catalogue}
    else
      do_move_catalogue_to_folder(catalogue, target, opts)
    end
  end

  defp do_move_catalogue_to_folder(catalogue, target, opts) do
    result =
      repo().transaction(fn ->
        Shared.lock_catalogues_order!()

        with :ok <- validate_target_folder(target),
             attrs = %{folder_uuid: target, position: Shared.next_level_position(target)},
             {:ok, updated} <- catalogue |> Catalogue.changeset(attrs) |> repo().update() do
          updated
        else
          {:error, reason} -> repo().rollback(reason)
        end
      end)

    with {:ok, updated} <- result do
      Shared.log_activity(%{
        action: "catalogue.moved_to_folder",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "catalogue",
        resource_uuid: catalogue.uuid,
        metadata: %{
          "name" => catalogue.name,
          "changes" =>
            ActivityLog.changes([
              {:folder, folder_ref(catalogue.folder_uuid), folder_ref(target)}
            ])
        }
      })

      {:ok, updated}
    end
  end

  # ── Folder helpers ───────────────────────────────────────────────

  # `[uuid]` for `root_uuid` + every descendant folder (textual UUIDs).
  # In-memory walk over the full adjacency list — folders are global and
  # few, so one cheap scan beats a recursive CTE. `UNION`-style cycle
  # safety: visited UUIDs are never re-walked.
  defp folder_subtree_uuids(root_uuid) do
    index =
      from(f in Folder, select: {f.parent_uuid, f.uuid})
      |> repo().all()
      |> Enum.group_by(fn {parent, _uuid} -> parent end, fn {_parent, uuid} -> uuid end)

    walk_folder_subtree([root_uuid], index, [])
  end

  defp walk_folder_subtree([], _index, acc), do: acc

  defp walk_folder_subtree([uuid | rest], index, acc) do
    if uuid in acc do
      walk_folder_subtree(rest, index, acc)
    else
      children = Map.get(index, uuid, [])
      walk_folder_subtree(children ++ rest, index, [uuid | acc])
    end
  end

  # nil/root target is always valid; otherwise the folder must exist and
  # be active. Used by move_folder/3, restore_folder/2, and
  # move_catalogue_to_folder/3.
  defp validate_target_folder(nil), do: :ok

  defp validate_target_folder(uuid) do
    case repo().one(from(f in Folder, where: f.uuid == ^uuid, select: f.status)) do
      "active" -> :ok
      nil -> {:error, :folder_not_found}
      _ -> {:error, :folder_trashed}
    end
  end

  # One below the smallest occupied slot so a freshly created folder
  # sorts first. (Manual reorder later normalizes to 1..N.)
  defp front_level_position(level_uuid) do
    case Shared.level_position_bound(:min, level_uuid) do
      nil -> 1
      n -> n - 1
    end
  end

  defp changed?(before, after_, fields) do
    Enum.any?(fields, fn f -> Map.get(before, f) != Map.get(after_, f) end)
  end
end
