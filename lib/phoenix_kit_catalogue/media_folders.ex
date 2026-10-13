defmodule PhoenixKitCatalogue.MediaFolders do
  @moduledoc """
  The catalogue's own media folder layout: every record's folder sits
  inside the folder of the record that contains it, named after it.

      Catalogues/
        <catalogue>/
          <category>/
            <subcategory>/
              <item>/
          <item without a category>/
        PDF/

  A category's folder holds its items' folders and its subcategories'.
  Names are the records' names in the site's primary language; an item
  whose name another live item in the same place shares gets its SKU
  appended, `<name> (<sku>)`, and without a SKU keeps the deterministic
  `catalogue-item-<uuid>`. The `Catalogues` and `PDF` folders are created
  on first use in the site's media library and remembered by uuid
  (`catalogue_media_folder_uuid`, `catalogue_pdf_media_folder_uuid`), so a
  person may rename or move them.

  ## On by default

  `mix.exs` sets both attachment hooks to this module's defaults:

      attachments_parent_folder: {PhoenixKitCatalogue.MediaFolders, :default_parent_for}
      attachments_folder_name: {PhoenixKitCatalogue.MediaFolders, :default_folder_name}

  A host's own `config :phoenix_kit_catalogue, ...` replaces either key.
  The defaults work as a pair: once the host sets either key, the other
  default steps back (the media root / the deterministic name), so a host
  that configured hooks before this layout existed sees no change. To
  combine one of these hooks with a host hook, name it explicitly —
  `{PhoenixKitCatalogue.MediaFolders, :parent_for}` or `:folder_name`. To
  turn the layout off, set both keys to `nil`.

  ## Renames and moves

  While these hooks place and name folders, a record's folder follows it
  (`follow/2`, called by the context after a save): renamed, its folder
  is renamed; moved to another category, parent or catalogue, its folder
  moves into the new container — a category's folder moves once, its
  whole subtree with it. A folder a person has moved or renamed — one
  that is not where and as these hooks put it — is left alone, and so is
  a record without a folder. The trash paths that take items out of a
  category (`items: :uncategorize` / `{:move_to, _}`, an item restored out
  of a trashed category) and the promotion of a live subcategory by a
  permanent delete move folders the same way. A category trashed whole, or
  a trashed subcategory promoted in its trash, keeps its folders where they
  are, as the records stay where they are.

  A hard delete leaves a record's folder and files in the media library,
  but `release_plan/1` / `release/1` rename the folder to the deterministic
  `catalogue-<kind>-<uuid>` first (when it is still as the hooks put it),
  with a UUID suffix if that name is already occupied,
  so a new record of the same name starts a folder of its own.

  Folders that predate the layout (the flat `catalogue-item-<uuid>`
  folders at the media root) are the media reorganizer's to move: after
  upgrading, run `mix phoenix_kit.media.reorganize --source catalogue` to
  see the plan and add `--apply` to carry it out. A host that changes its
  hooks in `config.exs` restarts the app first — dev's code reloader does
  not reload a changed config.

  The hooks create the containers they answer with, so a reorganizer dry
  run may already create the `Catalogues/<catalogue>/<category>` folders
  it plans into (empty, and the place the records' files go anyway).
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Folder, Libraries, ResourceFolders}
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.TreeQuery
  alias PhoenixKitCatalogue.Attachments
  alias PhoenixKitCatalogue.Catalogue.Translations
  alias PhoenixKitCatalogue.Schemas.{Catalogue, Category, Item}

  @app :phoenix_kit_catalogue
  @parent_key :attachments_parent_folder
  @name_key :attachments_folder_name
  @default_parent {__MODULE__, :default_parent_for}
  @default_name {__MODULE__, :default_folder_name}
  @module_folder_name "Catalogues"
  @module_folder_setting "catalogue_media_folder_uuid"
  @pdf_folder_name "PDF"
  @pdf_folder_setting "catalogue_pdf_media_folder_uuid"
  @pointer "files_folder_uuid"
  @settings_module "catalogue"
  @fallback_language "en-US"
  # A category chain deeper than this is treated as broken (a cycle the
  # tree guards should have refused) and ends at the catalogue's folder.
  @max_depth 64

  # ── Hooks ──────────────────────────────────────────────────────────

  @doc """
  Parent hook: where a `kind` folder for `subject` belongs — `Catalogues`
  for a catalogue, the catalogue's folder for a top-level category or an
  item without a category, the parent category's / the category's folder
  otherwise, and `Catalogues/PDF` for PDFs. Missing containers are created
  (and their records' pointers written) on the way. `nil` (the media
  root) for anything else.
  """
  @spec parent_for(atom(), String.t() | nil, term()) ::
          {:ok, String.t()} | {:error, term()} | nil
  def parent_for(:catalogue, actor_uuid, _subject), do: module_folder(actor_uuid)
  def parent_for(:pdf, actor_uuid, _subject), do: pdf_folder(actor_uuid)

  def parent_for(:category, actor_uuid, %Category{} = category),
    do: container(category.catalogue_uuid, category.parent_uuid, actor_uuid)

  def parent_for(:item, actor_uuid, %Item{} = item),
    do: container(item.catalogue_uuid, item.category_uuid, actor_uuid)

  def parent_for(_kind, _actor_uuid, _subject), do: nil

  @doc """
  Name hook: a saved record's name in the site's primary language; an item
  sharing its name with another live item in the same place gets
  `" (<sku>)"` appended. `nil` — the deterministic name — for an unsaved
  record, a blank name, a namesake without a SKU, or a catalogue named like
  the `PDF` folder it would otherwise share the `Catalogues` folder with.
  """
  @spec folder_name(term(), String.t() | nil) :: {:ok, String.t()} | nil
  def folder_name(%Item{uuid: uuid} = item, _actor_uuid) when is_binary(uuid) do
    case hook_base(item) do
      nil ->
        nil

      name ->
        if namesake?(item, name), do: with_sku(name, item.sku), else: folder_name_result(name)
    end
  end

  def folder_name(%schema{uuid: uuid} = record, _actor_uuid)
      when schema in [Category, Catalogue] and is_binary(uuid) do
    case hook_base(record) do
      nil -> nil
      name -> folder_name_result(name)
    end
  end

  def folder_name(_subject, _actor_uuid), do: nil

  @doc """
  The parent hook `mix.exs` installs: `parent_for/3` while the name hook is
  still the default too, else `nil` (the media root, as before the layout).
  """
  @spec default_parent_for(atom(), String.t() | nil, term()) ::
          {:ok, String.t()} | {:error, term()} | nil
  def default_parent_for(kind, actor_uuid, subject) do
    if Application.get_env(@app, @name_key) == @default_name,
      do: parent_for(kind, actor_uuid, subject),
      else: nil
  end

  @doc """
  The name hook `mix.exs` installs: `folder_name/2` while the parent hook is
  still the default too, else `nil` (the deterministic name).
  """
  @spec default_folder_name(term(), String.t() | nil) :: {:ok, String.t()} | nil
  def default_folder_name(subject, actor_uuid) do
    if Application.get_env(@app, @parent_key) == @default_parent,
      do: folder_name(subject, actor_uuid),
      else: nil
  end

  # ── Following renames and moves ────────────────────────────────────

  @doc """
  After a save: moves and renames the folders of records that changed
  place or name, given `[{before, after}]` structs — only while these hooks
  are in use, and only folders still where and as they put them. Never
  fails the save: a failure is logged and the folder stays.
  """
  @spec follow([{struct(), struct()}], String.t() | nil) :: :ok
  def follow(pairs, actor_uuid) when is_list(pairs) do
    moves? = ours?(@parent_key)
    renames? = ours?(@name_key)

    if moves? or renames? do
      pairs
      |> Enum.filter(&changed?(&1, moves?, renames?))
      |> follow_changed(%{moves?: moves?, renames?: renames?, actor: actor_uuid})
    end

    :ok
  rescue
    exception ->
      Logger.warning(
        "[Catalogue] media folders did not follow a save: " <>
          ResourceFolders.describe_failure(exception)
      )

      :ok
  catch
    kind, reason ->
      Logger.warning(
        "[Catalogue] media folders did not follow a save: " <>
          ResourceFolders.describe_failure({kind, reason})
      )

      :ok
  end

  @doc """
  The items among `uuids` that have a folder, as they are now — the
  `before` side of a bulk move, read inside its transaction before the
  update. `[]` (no query) while these hooks do not place folders.
  """
  @spec moving_items([String.t()]) :: [Item.t()]
  def moving_items(uuids) when is_list(uuids) do
    if uuids != [] and ours?(@parent_key),
      do: folder_records(from(i in Item, where: i.uuid in ^uuids and i.status != "deleted")),
      else: []
  end

  @doc """
  The records of `query` that have a folder, as they are now — the `before`
  side of a move the context makes with a bulk update. `[]` (no query)
  while these hooks do not place folders.
  """
  @spec moving_records(Ecto.Queryable.t()) :: [struct()]
  def moving_records(query), do: if(ours?(@parent_key), do: folder_records(query), else: [])

  @doc """
  Before a hard delete: what to do with the folders of the records the
  `queries` select. A deleted record's folder stays (it holds the files),
  but under the name the hooks gave it a new record of the same name would
  find it and take its files over — so each such folder, if it is still
  where and as the hooks put it, is to be renamed to the deterministic
  `catalogue-<kind>-<uuid>`. Read while the records and their containers
  still exist; hand the result to `release/1` once the delete has gone
  through. `[]` while these hooks are not in use.
  """
  @spec release_plan([Ecto.Queryable.t()]) :: [%{folder: Folder.t(), name: String.t()}]
  def release_plan(queries) when is_list(queries) do
    if active?(), do: queries |> Enum.flat_map(&folder_records/1) |> release_steps(), else: []
  end

  @doc "Carries out a `release_plan/1`. Never fails the delete: a failure is logged."
  @spec release([%{folder: Folder.t(), name: String.t()}]) :: :ok
  def release(plan) when is_list(plan) do
    Enum.each(plan, fn %{folder: folder, name: name} ->
      with {:ok, {:error, reason}} <- release_folder(folder, name) do
        Logger.warning(
          "[Catalogue] media folder #{folder.uuid} was not released from its deleted " <>
            "record: #{ResourceFolders.describe_failure(reason)}"
        )
      end
    end)
  rescue
    exception ->
      Logger.warning(
        "[Catalogue] media folders were not released: " <>
          ResourceFolders.describe_failure(exception)
      )

      :ok
  catch
    kind, reason ->
      Logger.warning(
        "[Catalogue] media folders were not released: " <>
          ResourceFolders.describe_failure({kind, reason})
      )

      :ok
  end

  defp release_folder(folder, name) do
    repo().transaction(fn ->
      Storage.lock_folder_tree()
      release_fresh_folder(folder, name)
    end)
  end

  defp release_fresh_folder(folder, name) do
    # A person may have changed the folder since the plan was read.
    case ResourceFolders.live_folder(folder.uuid) do
      %Folder{name: old_name, parent_uuid: parent} = fresh
      when old_name == folder.name and parent == folder.parent_uuid ->
        release_name =
          free_name(
            [name, "#{name}-#{folder.uuid}", "#{name}-#{Ecto.UUID.generate()}"],
            fresh,
            parent
          )

        if release_name,
          do: write_changes(fresh, %{name: release_name}),
          else: {:error, :name_taken}

      _changed_or_gone ->
        :ok
    end
  end

  defp release_steps([]), do: []

  defp release_steps(records) do
    ctx = %{moves?: ours?(@parent_key), renames?: ours?(@name_key), actor: nil}
    folders = records |> Enum.map(&pointer/1) |> live_folders()

    {steps, _cache} =
      Enum.flat_map_reduce(records, %{}, fn record, cache ->
        case Map.get(folders, pointer(record)) do
          nil -> {[], cache}
          folder -> release_step(folder, record, ctx, cache)
        end
      end)

    steps
  end

  defp release_step(folder, record, ctx, cache) do
    {hooked?, cache} = hooked?(folder, record, ctx, cache)
    name = Attachments.legacy_folder_name(record)

    if hooked? and is_binary(name) and name != folder.name,
      do: {[%{folder: folder, name: name}], cache},
      else: {[], cache}
  end

  defp folder_records(query),
    do: query |> where([r], not is_nil(fragment("?->>?", r.data, ^@pointer))) |> repo().all()

  defp active?, do: ours?(@parent_key) or ours?(@name_key)

  defp ours?(key) do
    case Application.get_env(@app, key) do
      {__MODULE__, fun} when fun in [:parent_for, :folder_name] -> true
      @default_parent -> Application.get_env(@app, @name_key) == @default_name
      @default_name -> Application.get_env(@app, @parent_key) == @default_parent
      _other -> false
    end
  end

  defp changed?({before, after_save}, moves?, renames?) do
    is_binary(pointer(after_save) || pointer(before)) and
      ((moves? and place(before) != place(after_save)) or
         (renames? and renamed?(before, after_save)))
  end

  defp follow_changed([], _ctx), do: :ok

  defp follow_changed(pairs, ctx) do
    folders =
      pairs
      |> Enum.map(fn {before, after_save} -> pointer(after_save) || pointer(before) end)
      |> live_folders()

    {steps, _cache} =
      Enum.flat_map_reduce(pairs, %{}, fn {before, after_save}, cache ->
        case Map.get(folders, pointer(after_save) || pointer(before)) do
          nil -> {[], cache}
          folder -> step(folder, before, after_save, ctx, cache)
        end
      end)

    apply_steps(steps)
  end

  # What one record's folder should become, or nothing when the folder is
  # not where and as these hooks put it. Containers are looked up once per
  # distinct place, so a bulk move asks for its destination once.
  defp step(folder, before, after_save, ctx, cache) do
    {hooked?, cache} = hooked?(folder, before, ctx, cache)

    if hooked? do
      {new_parent, cache} = destination(folder, before, after_save, ctx, cache)

      name =
        if ctx.renames? and renamed?(before, after_save),
          do: own_name(after_save),
          else: folder.name

      if not ctx.moves? or is_binary(new_parent),
        do: {[%{folder: folder, parent: new_parent, name: name, record: after_save}], cache},
        else: {[], cache}
    else
      {[], cache}
    end
  end

  # Is the folder where and as these hooks put the record's? The place
  # counts only while our parent hook is the one placing folders.
  defp hooked?(folder, record, ctx, cache) do
    {parent, cache} =
      if ctx.moves?,
        do: cached(cache, {:old, place(record)}, fn -> old_container(record) end),
        else: {folder.parent_uuid, cache}

    {(not ctx.moves? or is_binary(parent)) and folder.parent_uuid == parent and
       folder.name in old_names(record, ctx), cache}
  end

  defp destination(folder, before, after_save, %{moves?: true} = ctx, cache) do
    if place(before) != place(after_save),
      do: cached(cache, {:new, place(after_save)}, fn -> new_container(after_save, ctx) end),
      else: {folder.parent_uuid, cache}
  end

  defp destination(folder, _before, _after_save, _ctx, cache), do: {folder.parent_uuid, cache}

  # Plain moves into one container go together (`batch_move/2`), as many as
  # a bulk move brings; renames, and a move that has to find a free name,
  # one by one.
  defp apply_steps(steps) do
    {moves, others} =
      Enum.split_with(steps, &(&1.name == &1.folder.name and &1.parent != &1.folder.parent_uuid))

    leftover =
      moves
      |> Enum.group_by(& &1.parent)
      |> Enum.flat_map(fn
        {_parent, [_single] = group} -> group
        {parent, group} -> batch_move(group, parent)
      end)

    Enum.each(others ++ leftover, &relocate(&1.folder, &1.parent, &1.name, &1.record))
  end

  # One transaction, one UPDATE, for folders moving into the same parent:
  # the folder-tree lock core's own moves take, then the checks a single
  # move makes (parent live and in the same library, no cycle) for the
  # whole group. A folder whose name is taken in the new place, or that
  # shares its name with another in the group, is handed back to the
  # one-by-one path, which finds it a free name.
  defp batch_move(group, parent_uuid) do
    result =
      repo().transaction(fn ->
        Storage.lock_folder_tree()

        with %Folder{library_uuid: library} <- ResourceFolders.live_folder(parent_uuid),
             {eligible, rest} <- split_batch(group, parent_uuid, library) do
          now = DateTime.utc_now()
          uuids = Enum.map(eligible, & &1.folder.uuid)

          from(f in Folder, where: f.uuid in ^uuids and is_nil(f.trashed_at))
          |> repo().update_all(set: [parent_uuid: parent_uuid, updated_at: now])

          rest
        else
          _no_parent -> group
        end
      end)

    case result do
      {:ok, rest} ->
        rest

      {:error, reason} ->
        Logger.warning(
          "[Catalogue] media folders did not move together: " <>
            ResourceFolders.describe_failure(reason)
        )

        group
    end
  end

  defp split_batch(group, parent_uuid, library) do
    blocked = [parent_uuid | TreeQuery.ancestor_uuids(Folder, parent_uuid)]
    names = Enum.map(group, & &1.name)

    taken =
      from(f in Folder,
        where: f.parent_uuid == ^parent_uuid and f.name in ^names and is_nil(f.trashed_at),
        select: f.name
      )
      |> repo().all()
      |> MapSet.new()

    {eligible, _seen, rest} =
      Enum.reduce(group, {[], taken, []}, fn step, {eligible, seen, rest} ->
        if step.folder.library_uuid == library and step.folder.uuid not in blocked and
             not MapSet.member?(seen, step.name),
           do: {[step | eligible], MapSet.put(seen, step.name), rest},
           else: {eligible, seen, [step | rest]}
      end)

    {eligible, Enum.reverse(rest)}
  end

  defp cached(cache, key, fun) do
    case Map.fetch(cache, key) do
      {:ok, value} ->
        {value, cache}

      :error ->
        value = fun.()
        {value, Map.put(cache, key, value)}
    end
  end

  # Where the hooks put the record's folder before the change — read
  # through the containers' pointers, never created.
  defp old_container(%Catalogue{}), do: remembered_folder(@module_folder_setting)
  defp old_container(%Category{} = c), do: container_folder(c.catalogue_uuid, c.parent_uuid)
  defp old_container(%Item{} = i), do: container_folder(i.catalogue_uuid, i.category_uuid)

  defp container_folder(catalogue_uuid, nil), do: pointed_folder(Catalogue, catalogue_uuid)

  defp container_folder(_catalogue_uuid, category_uuid),
    do: pointed_folder(Category, category_uuid)

  defp new_container(record, ctx) do
    case parent_for(kind(record), ctx.actor, record) do
      {:ok, uuid} when is_binary(uuid) ->
        uuid

      {:error, reason} ->
        Logger.warning(
          "[Catalogue] no media folder to move #{kind(record)} #{record.uuid} into: " <>
            ResourceFolders.describe_failure(reason)
        )

        nil

      _root ->
        nil
    end
  end

  # The names these hooks (or the deterministic fallback) could have given
  # the record before the change.
  defp old_names(record, ctx) do
    own =
      if ctx.renames? do
        base = hook_base(record)
        sku = present(Map.get(record, :sku))
        [base, base && sku && "#{base} (#{sku})"]
      else
        [ResourceFolders.host_name(@app, record, ctx.actor)]
      end

    Enum.reject([Attachments.legacy_folder_name(record) | own], &(&1 in [nil, false]))
  end

  defp own_name(record) do
    case folder_name(record, nil) do
      {:ok, name} -> name
      nil -> Attachments.legacy_folder_name(record)
    end
  end

  # Moves and/or renames the folder under the folder-tree's name lock. A
  # name another folder there already has gives way to the record's own
  # name as of now (an item's namesake check, in the new place), then to
  # the deterministic name; when all of them are taken the folder stays
  # where it is. The refusal is settled here, before the write: the context
  # calls `follow/2` from inside its own transactions too, and a refused
  # folder update rolls back, which in a nested transaction would take the
  # caller's delete or trash down with it.
  defp relocate(folder, parent_uuid, name, record) do
    result =
      repo().transaction(fn ->
        # Take the tree lock before the name lock, as the batch path does.
        # Core's update_folder rolls back on a refused move; a nested
        # rollback would abort the catalogue operation too. Check the same
        # tree invariants here and return refusals as values instead.
        Storage.lock_folder_tree()
        relocate_locked(folder, parent_uuid, name, record)
      end)

    with {:ok, {:error, reason}} <- result do
      Logger.warning(
        "[Catalogue] media folder #{folder.uuid} did not follow #{kind(record)} " <>
          "#{record.uuid}: #{ResourceFolders.describe_failure(reason)}"
      )
    end

    :ok
  end

  defp relocate_locked(folder, parent_uuid, name, record) do
    with :ok <- movable(folder, parent_uuid) do
      case free_name(
             [name, own_name(record), Attachments.legacy_folder_name(record)],
             folder,
             parent_uuid
           ) do
        nil -> {:error, :name_taken}
        name -> write_changes(folder, changes(folder, parent_uuid, name))
      end
    end
  end

  defp write_changes(_folder, attrs) when attrs == %{}, do: :ok

  defp write_changes(folder, attrs) do
    # A concurrent name claim can still hit the unique constraint. A
    # savepoint keeps that failed statement from aborting the caller.
    with {:ok, _folder} <- folder |> Folder.changeset(attrs) |> repo().update(mode: :savepoint),
         do: :ok
  end

  defp movable(_folder, nil), do: :ok

  defp movable(folder, parent_uuid) do
    case ResourceFolders.live_folder(parent_uuid) do
      nil ->
        {:error, :folder_unavailable}

      %Folder{library_uuid: library} when library != folder.library_uuid ->
        {:error, :other_library}

      %Folder{} ->
        if Storage.ancestor_of?(folder.uuid, parent_uuid), do: {:error, :cycle}, else: :ok
    end
  end

  defp free_name(names, folder, parent_uuid) do
    names
    |> Enum.uniq()
    |> Enum.filter(&(is_binary(&1) and String.length(&1) in 1..255))
    |> Enum.find(fn name ->
      ResourceFolders.lock_name(parent_uuid, name)

      case ResourceFolders.find_under(name, parent_uuid) do
        nil -> true
        %Folder{uuid: uuid} -> uuid == folder.uuid
      end
    end)
  end

  defp changes(folder, parent_uuid, name) do
    [parent_uuid: parent_uuid, name: name]
    |> Enum.reject(fn {key, value} -> Map.fetch!(folder, key) == value end)
    |> Map.new()
  end

  defp place(%Item{} = i), do: {i.catalogue_uuid, i.category_uuid}
  defp place(%Category{} = c), do: {c.catalogue_uuid, c.parent_uuid}
  defp place(%Catalogue{}), do: :catalogues

  # The cheap comparison first: a record whose name, SKU and translations
  # did not change is not asked for its name in the site's language.
  defp renamed?(before, after_save) do
    name_inputs(before) != name_inputs(after_save) and
      name_facts(before) != name_facts(after_save)
  end

  defp name_inputs(record), do: {record.name, Map.get(record, :sku), record.data}

  defp name_facts(record), do: {hook_base(record), present(Map.get(record, :sku))}

  defp kind(%Item{}), do: :item
  defp kind(%Category{}), do: :category
  defp kind(%Catalogue{}), do: :catalogue

  # ── Containers ─────────────────────────────────────────────────────

  defp container(nil, _category_uuid, actor_uuid), do: module_folder(actor_uuid)

  defp container(catalogue_uuid, nil, actor_uuid),
    do: catalogue_folder(catalogue_uuid, actor_uuid)

  defp container(catalogue_uuid, category_uuid, actor_uuid) do
    case get_record(Category, category_uuid) do
      nil ->
        catalogue_folder(catalogue_uuid, actor_uuid)

      category ->
        case pointed_folder(category) do
          uuid when is_binary(uuid) -> {:ok, uuid}
          nil -> category_chain_folder(category, actor_uuid)
        end
    end
  end

  # The category's folder, building every missing folder of its chain from
  # the catalogue down — each level under the one above, never through the
  # hook again.
  defp category_chain_folder(category, actor_uuid) do
    chain = ancestors(category, [category], MapSet.new([category.uuid]))

    Enum.reduce_while(chain, catalogue_folder(category.catalogue_uuid, actor_uuid), fn
      cat, {:ok, parent_uuid} ->
        {:cont, Attachments.ensure_folder_under(cat, parent_uuid, actor_uuid)}

      _cat, error ->
        {:halt, error}
    end)
  end

  defp ancestors(%Category{parent_uuid: nil}, chain, _seen), do: chain

  defp ancestors(%Category{parent_uuid: parent_uuid}, chain, seen) do
    with false <- MapSet.member?(seen, parent_uuid) or MapSet.size(seen) >= @max_depth,
         %Category{} = parent <- get_record(Category, parent_uuid) do
      ancestors(parent, [parent | chain], MapSet.put(seen, parent.uuid))
    else
      _broken -> chain
    end
  end

  defp catalogue_folder(catalogue_uuid, actor_uuid) do
    case get_record(Catalogue, catalogue_uuid) do
      nil -> module_folder(actor_uuid)
      catalogue -> record_folder(catalogue, actor_uuid)
    end
  end

  defp record_folder(catalogue, actor_uuid) do
    case pointed_folder(catalogue) do
      uuid when is_binary(uuid) ->
        {:ok, uuid}

      nil ->
        with {:ok, parent_uuid} <- module_folder(actor_uuid),
             do: Attachments.ensure_folder_under(catalogue, parent_uuid, actor_uuid)
    end
  end

  defp module_folder(actor_uuid) do
    case remembered_folder(@module_folder_setting) do
      uuid when is_binary(uuid) ->
        {:ok, uuid}

      nil ->
        @module_folder_name
        |> ResourceFolders.ensure(nil, actor_uuid, lookup: &media_root_module_folder/0)
        |> remember(@module_folder_setting)
    end
  end

  defp pdf_folder(actor_uuid) do
    case remembered_folder(@pdf_folder_setting) do
      uuid when is_binary(uuid) ->
        {:ok, uuid}

      nil ->
        with {:ok, parent_uuid} <- module_folder(actor_uuid) do
          @pdf_folder_name
          |> ResourceFolders.ensure(parent_uuid, actor_uuid)
          |> remember(@pdf_folder_setting)
        end
    end
  end

  # Core's by-name lookup takes a root folder of that name in ANY library;
  # the module folder is only ever one of the site's media library.
  defp media_root_module_folder do
    from(f in Folder,
      where: f.name == ^@module_folder_name and is_nil(f.parent_uuid) and is_nil(f.trashed_at),
      where: f.library_uuid == ^Libraries.media_uuid(),
      order_by: [asc: f.inserted_at, asc: f.uuid],
      limit: 1
    )
    |> repo().one()
  end

  defp remembered_folder(setting) do
    case ResourceFolders.live_folder(Settings.get_setting(setting)) do
      %Folder{uuid: uuid} -> uuid
      nil -> nil
    end
  end

  defp remember({:ok, %Folder{uuid: uuid}}, setting) do
    case Settings.update_setting_with_module(setting, uuid, @settings_module) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Catalogue] could not remember media folder #{setting}: " <>
            ResourceFolders.describe_failure(reason)
        )
    end

    {:ok, uuid}
  end

  defp remember({:error, _reason} = error, _setting), do: error

  # ── Records ────────────────────────────────────────────────────────

  defp get_record(_schema, nil), do: nil

  defp get_record(schema, uuid) do
    if match?({:ok, _}, Ecto.UUID.cast(uuid)),
      do: repo().one(from(r in schema, where: r.uuid == ^uuid and r.status != "deleted")),
      else: nil
  end

  defp pointed_folder(_schema, nil), do: nil

  defp pointed_folder(schema, uuid) do
    if match?({:ok, _}, Ecto.UUID.cast(uuid)) do
      from(r in schema, where: r.uuid == ^uuid, select: fragment("?->>?", r.data, ^@pointer))
      |> repo().one()
      |> live_folder_uuid()
    end
  end

  defp pointed_folder(record), do: record |> pointer() |> live_folder_uuid()

  defp live_folder_uuid(uuid) do
    case ResourceFolders.live_folder(uuid) do
      %Folder{uuid: uuid} -> uuid
      nil -> nil
    end
  end

  defp live_folders(uuids) do
    uuids = uuids |> Enum.filter(&match?({:ok, _}, Ecto.UUID.cast(&1))) |> Enum.uniq()

    from(f in Folder, where: f.uuid in ^uuids and is_nil(f.trashed_at))
    |> repo().all()
    |> Map.new(&{&1.uuid, &1})
  end

  defp pointer(%{data: %{@pointer => uuid}}) when is_binary(uuid) and uuid != "", do: uuid
  defp pointer(_record), do: nil

  defp base_name(record) do
    record
    |> Translations.translated_name(site_language())
    |> present()
  end

  # The name a hook gives the record's folder, before an item's SKU: its
  # name in the site's language — except a catalogue named `PDF`, whose
  # folder would be the `Catalogues/PDF` one.
  defp hook_base(%Catalogue{} = catalogue) do
    name = base_name(catalogue)
    if name && String.downcase(name) == String.downcase(@pdf_folder_name), do: nil, else: name
  end

  defp hook_base(record), do: base_name(record)

  # The site's default language as saved, not `Multilang.primary_language/0`
  # or `Languages.get_default_language/0`: those answer with the language
  # of the request being served when one is set, and a folder is named for
  # the site, not for whoever is saving.
  defp site_language do
    case Enum.find(Languages.get_languages(), & &1.is_default) do
      %{code: code} when is_binary(code) -> code
      _none -> @fallback_language
    end
  end

  # Another live item in the same place whose name reads the same.
  defp namesake?(%Item{} = item, name) do
    Item
    |> where([i], i.uuid != ^item.uuid and i.status != "deleted")
    |> where([i], i.catalogue_uuid == ^item.catalogue_uuid)
    |> same_category(item.category_uuid)
    |> where(
      [i],
      fragment("btrim(?) = ?", i.name, ^name) or
        fragment(
          """
          EXISTS (SELECT 1 FROM jsonb_each(?) AS t(locale, value)
                  WHERE btrim(COALESCE(value->>'_name', value->>'name')) = ?)
          """,
          i.data,
          ^name
        )
    )
    |> repo().all()
    |> Enum.any?(&(base_name(&1) == name))
  end

  defp same_category(query, nil), do: where(query, [i], is_nil(i.category_uuid))
  defp same_category(query, uuid), do: where(query, [i], i.category_uuid == ^uuid)

  defp with_sku(name, sku) do
    case present(sku) do
      nil -> nil
      sku -> folder_name_result("#{name} (#{sku})")
    end
  end

  defp folder_name_result(name) do
    if String.length(name) <= 255, do: {:ok, name}, else: nil
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
