defmodule PhoenixKitCatalogue.Catalogue.Dependencies do
  @moduledoc """
  Item dependencies — what an item needs, as a list of
  `PhoenixKitCatalogue.Schemas.ItemDependency` rows: one target each (a
  catalogue, a category or an item), a quantity and an optional note.

  The list is edited as a whole on the item form and written with
  `put_item_dependencies/3`, a replace-all that writes nothing when the
  list is unchanged — so an unrelated save of the item logs and
  broadcasts nothing. Nothing here computes with a dependency: the rows
  are for the people using the catalogue.

  `list_item_dependents/1` is the other direction ("who lists this?") for
  internal callers; no page shows it. `count_outside_dependents/1` is what
  a permanent-delete confirmation states: how many OTHER items list
  something that delete removes, because the database then removes those
  rows with it.

  Public surface is re-exported from `PhoenixKitCatalogue.Catalogue`.
  """

  import Ecto.Query, warn: false

  alias PhoenixKitCatalogue.Catalogue.{ActivityLog, Helpers, PubSub}
  alias PhoenixKitCatalogue.Schemas.{Catalogue, Category, Item, ItemDependency}

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @typedoc """
  One dependency as a caller hands it to `put_item_dependencies/3`: a
  `:target` of `{:catalogue | :category | :item, uuid}` (or the three
  `target_*_uuid` keys directly), a `:quantity` and an optional `:note`.
  Atom or string keys.
  """
  @type spec :: map()

  @doc """
  An item's dependencies in their order, each with its target preloaded —
  `target_catalogue`, `target_category` (with its catalogue) or
  `target_item` (with its catalogue and category) — so a page can show
  the target's name, place and status (a trashed target stays listed).
  """
  @spec list_item_dependencies(Item.t() | Ecto.UUID.t()) :: [ItemDependency.t()]
  def list_item_dependencies(%Item{uuid: uuid}), do: list_item_dependencies(uuid)
  def list_item_dependencies(nil), do: []

  def list_item_dependencies(item_uuid) when is_binary(item_uuid) do
    if Helpers.uuid?(item_uuid) do
      from(d in ItemDependency,
        where: d.item_uuid == ^item_uuid,
        order_by: [asc: d.position, asc: d.inserted_at],
        preload: [
          :target_catalogue,
          target_category: :catalogue,
          target_item: [:catalogue, :category]
        ]
      )
      |> repo().all()
    else
      []
    end
  end

  @doc """
  Finds the live target an import names — `%{type, uuid, sku, name,
  catalogue}` as `Import.DependencyCell` reads it — and answers
  `{:ok, {kind, uuid}}`, `{:error, :not_found}` or `{:error, :ambiguous}`
  (several rows match and none is preferred), so an import report can say
  which.

  The uuid wins when it names a live row of that kind (an export imported
  back into the same database). Otherwise an item is found by its exact
  SKU, a catalogue by its exact name, and a category by its exact name in
  the catalogue the reference names. A match must be unique; when several
  items share a SKU, the one in `:catalogue_uuid` (the catalogue being
  imported into) is taken if it is the only one there. Trashed rows and
  rows of trashed catalogues are never matched.
  """
  @spec resolve_import_ref(map(), keyword()) ::
          {:ok, {ItemDependency.kind(), Ecto.UUID.t()}} | {:error, :not_found | :ambiguous}
  def resolve_import_ref(%{type: type} = ref, opts \\ []) do
    kind = String.to_existing_atom(type)

    case by_uuid(kind, ref[:uuid]) do
      nil ->
        case by_name(kind, ref, opts[:catalogue_uuid]) do
          {:ok, uuid} -> {:ok, {kind, uuid}}
          {:error, _reason} = error -> error
        end

      uuid ->
        {:ok, {kind, uuid}}
    end
  rescue
    ArgumentError -> {:error, :not_found}
  end

  defp by_uuid(_kind, uuid) when not is_binary(uuid), do: nil

  defp by_uuid(kind, uuid) do
    if Helpers.uuid?(uuid) do
      kind |> live_query() |> where([r], r.uuid == ^uuid) |> select([r], r.uuid) |> repo().one()
    end
  end

  defp by_name(:item, %{sku: sku}, preferred) when is_binary(sku) do
    :item
    |> live_query()
    |> where([r], r.sku == ^sku)
    |> select([r], {r.uuid, r.catalogue_uuid})
    |> repo().all()
    |> pick_unique(preferred)
  end

  defp by_name(:catalogue, %{name: name}, _preferred) when is_binary(name) do
    :catalogue
    |> live_query()
    |> where([r], r.name == ^name)
    |> select([r], {r.uuid, r.uuid})
    |> repo().all()
    |> pick_unique(nil)
  end

  defp by_name(:category, %{name: name} = ref, preferred) when is_binary(name) do
    query =
      :category
      |> live_query()
      |> where([r], r.name == ^name)
      |> select([r], {r.uuid, r.catalogue_uuid})

    query =
      case ref[:catalogue] do
        catalogue when is_binary(catalogue) ->
          join(query, :inner, [r], c in Catalogue,
            on: c.uuid == r.catalogue_uuid and c.name == ^catalogue
          )

        _ when is_binary(preferred) ->
          where(query, [r], r.catalogue_uuid == ^preferred)

        _ ->
          query
      end

    query |> repo().all() |> pick_unique(nil)
  end

  defp by_name(_kind, _ref, _preferred), do: {:error, :not_found}

  defp pick_unique([], _preferred), do: {:error, :not_found}
  defp pick_unique([{uuid, _}], _preferred), do: {:ok, uuid}

  defp pick_unique(matches, preferred) when is_binary(preferred) do
    case Enum.filter(matches, fn {_uuid, catalogue} -> catalogue == preferred end) do
      [{uuid, _}] -> {:ok, uuid}
      _ -> {:error, :ambiguous}
    end
  end

  defp pick_unique(_matches, _preferred), do: {:error, :ambiguous}

  # Live rows of a kind, in live catalogues.
  defp live_query(:catalogue), do: from(r in Catalogue, where: r.status != "deleted")

  defp live_query(:category) do
    from(r in Category,
      join: c in Catalogue,
      on: c.uuid == r.catalogue_uuid,
      where: r.status != "deleted" and c.status != "deleted"
    )
  end

  defp live_query(:item) do
    from(r in Item,
      join: c in Catalogue,
      on: c.uuid == r.catalogue_uuid,
      where: r.status != "deleted" and c.status != "deleted"
    )
  end

  @doc """
  The dependencies of many items at once, as `%{item_uuid => rows}` with
  the same preloads as `list_item_dependencies/1` — one query, for an
  export. Items with none are absent from the map.
  """
  @spec dependencies_by_item([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => [ItemDependency.t()]}
  def dependencies_by_item(item_uuids) when is_list(item_uuids) do
    case Enum.filter(item_uuids, &Helpers.uuid?/1) do
      [] ->
        %{}

      uuids ->
        from(d in ItemDependency,
          where: d.item_uuid in ^uuids,
          order_by: [asc: d.item_uuid, asc: d.position, asc: d.inserted_at],
          preload: [
            :target_catalogue,
            target_category: :catalogue,
            target_item: [:catalogue, :category]
          ]
        )
        |> repo().all()
        |> Enum.group_by(& &1.item_uuid)
    end
  end

  @doc """
  Replaces an item's dependencies with `specs`, in that order.

  Writes nothing — no activity row, no broadcast — when the list already
  reads the same (same targets, quantities and notes in the same order).
  Otherwise the old rows are deleted and the new ones inserted in one
  transaction, one `item.dependencies_synced` activity row records the
  counts, and the item is broadcast as changed.

  Pass `expected:` — the rows the caller read and showed (from
  `list_item_dependencies/1`) — to refuse the write when someone else has
  changed the list since: `{:error, :dependencies_changed}`, nothing
  written. The check and the write run under a lock on the item row, so
  two saves of one item take turns. The check compares contents, not a
  revision: a list changed and changed back reads as unchanged.

  Returns `{:ok, rows}` (as `list_item_dependencies/1` reads them),
  `{:error, changeset}` for the first row that does not validate, or
  `{:error, :dependencies_changed}` — no row is written in either error.
  """
  @spec put_item_dependencies(Item.t(), [spec()], keyword()) ::
          {:ok, [ItemDependency.t()]}
          | {:error, Ecto.Changeset.t(ItemDependency.t())}
          | {:error, :dependencies_changed}
  def put_item_dependencies(%Item{} = item, specs, opts \\ []) when is_list(specs) do
    changesets =
      specs
      |> Enum.with_index()
      |> Enum.map(fn {spec, index} ->
        ItemDependency.changeset(%ItemDependency{}, spec_attrs(spec, item.uuid, index))
      end)

    case Enum.find(changesets, &(not &1.valid?)) do
      nil -> write_if_changed(item, changesets, opts)
      bad -> {:error, %{bad | action: :insert}}
    end
  end

  @doc """
  Whether `put_item_dependencies/3` with these `specs` and `expected:`
  would answer `{:error, :dependencies_changed}` right now: the stored list
  is neither what `specs` asks for nor what the caller read. A read-only
  look, without the lock — for a form that must not write anything else
  first. The write still decides under its lock.
  """
  @spec dependencies_conflict?(Item.t(), [spec()], [ItemDependency.t()]) :: boolean()
  def dependencies_conflict?(%Item{} = item, specs, expected)
      when is_list(specs) and is_list(expected) do
    current = item |> list_item_dependencies() |> Enum.map(&comparable/1)

    wanted =
      specs
      |> Enum.with_index()
      |> Enum.map(fn {spec, index} ->
        %ItemDependency{}
        |> ItemDependency.changeset(spec_attrs(spec, item.uuid, index))
        |> comparable()
      end)

    current != wanted and current != Enum.map(expected, &comparable/1)
  end

  defp write_if_changed(item, changesets, opts) do
    expected = Keyword.get(opts, :expected)

    case repo().transaction(fn -> decide_and_write(item, changesets, expected) end) do
      {:ok, {:unchanged, existing}} ->
        {:ok, existing}

      {:ok, {:written, before}} ->
        ActivityLog.log(%{
          action: "item.dependencies_synced",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "item",
          resource_uuid: item.uuid,
          metadata: %{
            "name" => item_name(item),
            "before" => before,
            "total" => length(changesets)
          }
        })

        if Keyword.get(opts, :broadcast, true),
          do: PubSub.broadcast(:item, item.uuid, item.catalogue_uuid)

        {:ok, list_item_dependencies(item)}

      {:error, :dependencies_changed} ->
        {:error, :dependencies_changed}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  # Under the item lock: refuse a stale `expected`, skip an unchanged list,
  # else replace it.
  defp decide_and_write(item, changesets, expected) do
    lock_item!(item)
    existing = list_item_dependencies(item)
    current = Enum.map(existing, &comparable/1)

    cond do
      # Already what this save asks for (someone saved the same list): no
      # conflict and nothing to write.
      current == Enum.map(changesets, &comparable/1) ->
        {:unchanged, existing}

      is_list(expected) and Enum.map(expected, &comparable/1) != current ->
        repo().rollback(:dependencies_changed)

      true ->
        from(d in ItemDependency, where: d.item_uuid == ^item.uuid) |> repo().delete_all()
        Enum.each(changesets, &insert_or_rollback/1)
        {:written, length(existing)}
    end
  end

  # Two saves of one item's list take turns: the second reads what the
  # first wrote before it decides anything.
  defp lock_item!(%Item{uuid: uuid}) do
    from(i in Item, where: i.uuid == ^uuid, lock: "FOR UPDATE", select: i.uuid)
    |> repo().one()
  end

  defp insert_or_rollback(changeset) do
    case repo().insert(changeset) do
      {:ok, _row} -> :ok
      {:error, failed} -> repo().rollback(failed)
    end
  end

  # The fields that make two lists "the same list": the target, the amount
  # and the note, in order. Decimals compare by value ("8" == "8.0000").
  defp comparable(%Ecto.Changeset{} = changeset) do
    comparable(Ecto.Changeset.apply_changes(changeset))
  end

  defp comparable(%ItemDependency{} = row) do
    {ItemDependency.target(row), row.quantity && Decimal.normalize(row.quantity), row.note}
  end

  defp spec_attrs(spec, item_uuid, index) do
    base = %{
      item_uuid: item_uuid,
      quantity: Helpers.fetch_attr(spec, :quantity),
      note: blank_to_nil(Helpers.fetch_attr(spec, :note)),
      position: index
    }

    case Helpers.fetch_attr(spec, :target) do
      {kind, uuid} when kind in [:catalogue, :category, :item] ->
        Map.put(base, ItemDependency.target_field(kind), uuid)

      _ ->
        Map.merge(base, %{
          target_catalogue_uuid: Helpers.fetch_attr(spec, :target_catalogue_uuid),
          target_category_uuid: Helpers.fetch_attr(spec, :target_category_uuid),
          target_item_uuid: Helpers.fetch_attr(spec, :target_item_uuid)
        })
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp item_name(%Item{name: name}) when is_binary(name), do: name
  defp item_name(_), do: nil

  @doc """
  The dependency rows that name `target` — `{:catalogue | :category |
  :item, uuid}` — with their owning item (and its catalogue) preloaded:
  "who lists this?". Only the rows naming the target itself, not those
  naming something inside it (a category's items are not its dependents).
  For internal use; no page shows it.
  """
  @spec list_item_dependents({ItemDependency.kind(), Ecto.UUID.t()}) :: [ItemDependency.t()]
  def list_item_dependents({kind, uuid}) when kind in [:catalogue, :category, :item] do
    if Helpers.uuid?(uuid) do
      field = ItemDependency.target_field(kind)

      from(d in ItemDependency,
        join: i in Item,
        on: i.uuid == d.item_uuid,
        where: field(d, ^field) == ^uuid,
        order_by: [asc: i.name, asc: d.position],
        preload: [item: {i, :catalogue}]
      )
      |> repo().all()
    else
      []
    end
  end

  @doc """
  How many items OUTSIDE what a permanent delete of `record` removes
  list something it removes — the catalogue, a category in it or an item
  in it (for a catalogue); one of the categories, or an item in one (for
  `{:categories, uuids}` — the categories a category's delete removes);
  the item itself (for an item). The database
  removes those dependency rows with the delete, so a confirmation says
  so first. Items deleted along with `record` are not counted.
  """
  @spec count_outside_dependents(Catalogue.t() | Item.t() | {:categories, [Ecto.UUID.t()]}) ::
          non_neg_integer()
  # A uuid that is nil (an unsaved record) or not a uuid counts nothing —
  # a nil would otherwise compile to `IS NULL` and count unrelated rows.
  def count_outside_dependents(%{uuid: uuid} = record)
      when is_struct(record, Item) or is_struct(record, Catalogue) do
    if Helpers.uuid?(uuid), do: count_valid(record), else: 0
  end

  def count_outside_dependents({:categories, category_uuids}) when is_list(category_uuids) do
    count_categories(Enum.filter(category_uuids, &valid_category_uuid?/1))
  end

  # Raw 16-byte uuids (what the tree helpers return) are valid too.
  defp valid_category_uuid?(uuid) when is_binary(uuid) and byte_size(uuid) == 16, do: true
  defp valid_category_uuid?(uuid), do: Helpers.uuid?(uuid)

  defp count_valid(%Item{uuid: uuid}) do
    from(d in ItemDependency,
      where: d.target_item_uuid == ^uuid and d.item_uuid != ^uuid,
      select: count(d.item_uuid, :distinct)
    )
    |> repo().one()
  end

  defp count_valid(%Catalogue{uuid: uuid}) do
    removed_items = from(i in Item, where: i.catalogue_uuid == ^uuid, select: i.uuid)
    removed_categories = from(c in Category, where: c.catalogue_uuid == ^uuid, select: c.uuid)

    count_outside(
      dynamic(
        [d],
        d.target_catalogue_uuid == ^uuid or
          d.target_category_uuid in subquery(removed_categories) or
          d.target_item_uuid in subquery(removed_items)
      ),
      removed_items
    )
  end

  # A category's permanent delete does not always take its whole subtree
  # (a trashed root stops at live children), so the caller names the
  # categories it removes — `Categories.permanent_delete_scope/1` does.
  defp count_categories(category_uuids) do
    removed_items = from(i in Item, where: i.category_uuid in ^category_uuids, select: i.uuid)

    count_outside(
      dynamic(
        [d],
        d.target_category_uuid in ^category_uuids or
          d.target_item_uuid in subquery(removed_items)
      ),
      removed_items
    )
  end

  defp count_outside(target_condition, removed_items) do
    from(d in ItemDependency,
      where: ^target_condition,
      where: d.item_uuid not in subquery(removed_items),
      select: count(d.item_uuid, :distinct)
    )
    |> repo().one()
  end
end
