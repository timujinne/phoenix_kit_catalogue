defmodule PhoenixKitCatalogue.Catalogue.TrashRestoreTest do
  @moduledoc """
  Trash / restore provenance: restoring a root brings back exactly what
  trashing it took — no more (rows trashed on their own stay in the
  trash), no less (a category's cascade comes back with it) — each row
  to the status it had. Ends with a randomized run over combinations of
  every trash and restore path that checks the invariants after each
  step, and that trashing then restoring any live root changes nothing.

  Concurrency is not exercised here: the SQL sandbox serializes every
  process onto one connection.
  """
  use PhoenixKitCatalogue.DataCase, async: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Schemas.Catalogue, as: CatalogueRow
  alias PhoenixKitCatalogue.Schemas.{Category, Item}

  describe "restore_catalogue/2" do
    test "leaves an item and a category trashed on their own in the trash" do
      cat = catalogue!()
      kept = category!(cat)
      gone = category!(cat)
      in_gone = item!(%{category_uuid: gone.uuid})
      loose_gone = item!(%{catalogue_uuid: cat.uuid})
      stays = item!(%{category_uuid: kept.uuid})

      {:ok, _} = Catalogue.trash_item(loose_gone)
      {:ok, _} = Catalogue.trash_category(gone, items: :cascade)
      {:ok, _} = Catalogue.trash_catalogue(cat)
      {:ok, _} = Catalogue.restore_catalogue(cat)

      assert status(CatalogueRow, cat.uuid) == "active"
      assert status(Category, kept.uuid) == "active"
      assert status(Item, stays.uuid) == "active"
      assert status(Item, loose_gone.uuid) == "deleted"
      assert status(Category, gone.uuid) == "deleted"
      assert status(Item, in_gone.uuid) == "deleted"

      # Each of them still restores on its own, whole.
      {:ok, _} = Catalogue.restore_category(reload(gone))
      assert status(Item, in_gone.uuid) == "active"
      {:ok, _} = Catalogue.restore_item(reload(loose_gone))
      assert status(Item, loose_gone.uuid) == "active"
    end

    test "brings every row back to the status it had" do
      cat = catalogue!(%{status: "archived"})
      c = category!(cat)
      inactive = item!(%{category_uuid: c.uuid, status: "inactive"})
      discontinued = item!(%{catalogue_uuid: cat.uuid, status: "discontinued"})
      active = item!(%{category_uuid: c.uuid})

      {:ok, _} = Catalogue.trash_catalogue(cat)
      assert status(Item, inactive.uuid) == "deleted"

      {:ok, restored} = Catalogue.restore_catalogue(cat)

      assert restored.status == "archived"
      assert status(Item, inactive.uuid) == "inactive"
      assert status(Item, discontinued.uuid) == "discontinued"
      assert status(Item, active.uuid) == "active"
      refute Map.has_key?(reload(inactive).data, "_trash")
      refute Map.has_key?(reload(c).data, "_trash")
      refute Map.has_key?(restored.data, "_trash")
    end

    test "revives a deleted row with no stamp (trashed before provenance) with the catalogue" do
      cat = catalogue!()
      c = category!(cat)
      legacy = item!(%{category_uuid: c.uuid})
      {:ok, _} = Catalogue.trash_item(legacy)
      strip_stamp!(Item, legacy.uuid)

      {:ok, _} = Catalogue.trash_catalogue(cat)
      {:ok, _} = Catalogue.restore_catalogue(cat)

      assert status(Item, legacy.uuid) == "active"
    end

    test "keeps an unstamped item in the trash while its category stays trashed" do
      cat = catalogue!()
      c = category!(cat)
      legacy = item!(%{category_uuid: c.uuid})
      {:ok, _} = Catalogue.trash_item(legacy)
      strip_stamp!(Item, legacy.uuid)
      {:ok, _} = Catalogue.trash_category(reload(c))

      {:ok, _} = Catalogue.trash_catalogue(cat)
      {:ok, _} = Catalogue.restore_catalogue(cat)

      assert status(Category, c.uuid) == "deleted"
      assert status(Item, legacy.uuid) == "deleted"
    end

    test "trashing a catalogue a legacy trash left with live children sweeps them, and restore brings them back" do
      cat = catalogue!()
      c = category!(cat)
      i = item!(%{category_uuid: c.uuid})

      from(r in CatalogueRow, where: r.uuid == ^cat.uuid)
      |> Repo.update_all(set: [status: "deleted"])

      {:ok, _} = Catalogue.trash_catalogue(reload(cat))
      assert status(Item, i.uuid) == "deleted"
      assert status(Category, c.uuid) == "deleted"

      {:ok, _} = Catalogue.restore_catalogue(reload(cat))
      assert status(CatalogueRow, cat.uuid) == "active"
      assert status(Item, i.uuid) == "active"
      assert status(Category, c.uuid) == "active"
    end
  end

  describe "restore_category/2" do
    test "brings back the subtree and the items its cascade took, with their statuses" do
      cat = catalogue!()
      root = category!(cat)
      mid = category!(cat, %{parent_uuid: root.uuid})
      leaf = category!(cat, %{parent_uuid: mid.uuid})
      i_root = item!(%{category_uuid: root.uuid})
      i_leaf = item!(%{category_uuid: leaf.uuid, status: "inactive"})

      {:ok, _} = Catalogue.trash_category(root, items: :cascade)
      {:ok, _} = Catalogue.restore_category(reload(root))

      for c <- [root, mid, leaf], do: assert(status(Category, c.uuid) == "active")
      assert status(Item, i_root.uuid) == "active"
      assert status(Item, i_leaf.uuid) == "inactive"
    end

    test "leaves what was trashed on its own before the category in the trash" do
      cat = catalogue!()
      root = category!(cat)
      sub = category!(cat, %{parent_uuid: root.uuid})
      own = item!(%{category_uuid: root.uuid})
      in_sub = item!(%{category_uuid: sub.uuid})
      stays = item!(%{category_uuid: root.uuid})

      {:ok, _} = Catalogue.trash_item(own)
      {:ok, _} = Catalogue.trash_category(sub, items: :cascade)
      {:ok, _} = Catalogue.trash_category(reload(root), items: :cascade)
      {:ok, _} = Catalogue.restore_category(reload(root))

      assert status(Category, root.uuid) == "active"
      assert status(Item, stays.uuid) == "active"
      assert status(Item, own.uuid) == "deleted"
      assert status(Category, sub.uuid) == "deleted"
      assert status(Item, in_sub.uuid) == "deleted"
    end

    test "restoring a leaf of a trashed subtree brings back only the leaf" do
      cat = catalogue!()
      root = category!(cat)
      leaf = category!(cat, %{parent_uuid: root.uuid})
      i = item!(%{category_uuid: leaf.uuid})

      {:ok, _} = Catalogue.trash_category(root, items: :cascade)
      {:ok, _} = Catalogue.restore_category(reload(leaf))

      assert status(Category, leaf.uuid) == "active"
      assert status(Category, root.uuid) == "deleted"
      assert status(Item, i.uuid) == "deleted"

      # Restoring the root afterwards brings back the rest.
      {:ok, _} = Catalogue.restore_category(reload(root))
      assert status(Item, i.uuid) == "active"
    end

    test "keeps an item in the trash when its own category was trashed again on its own" do
      # The item is stamped as taken by `root`, but its category `sub` was
      # restored and then trashed on its own in between: reviving the item
      # with `root` would put a live item in a trashed category.
      cat = catalogue!()
      root = category!(cat)
      sub = category!(cat, %{parent_uuid: root.uuid})
      i = item!(%{category_uuid: sub.uuid})

      {:ok, _} = Catalogue.trash_category(root, items: :cascade)
      {:ok, _} = Catalogue.restore_category(reload(sub))
      {:ok, _} = Catalogue.trash_category(reload(sub), items: :cascade)
      {:ok, _} = Catalogue.restore_category(reload(root))

      assert status(Category, root.uuid) == "active"
      assert status(Category, sub.uuid) == "deleted"
      assert status(Item, i.uuid) == "deleted"

      # Restoring the item itself still works — it comes back uncategorized.
      {:ok, restored} = Catalogue.restore_item(reload(i))
      assert restored.status == "active"
      assert is_nil(restored.category_uuid)
    end

    test "does not revive a deleted row with no stamp" do
      cat = catalogue!()
      c = category!(cat)
      legacy = item!(%{category_uuid: c.uuid})
      {:ok, _} = Catalogue.trash_category(c, items: :cascade)
      strip_stamp!(Item, legacy.uuid)

      {:ok, _} = Catalogue.restore_category(reload(c))

      assert status(Item, legacy.uuid) == "deleted"
    end
  end

  describe "bulk paths" do
    test "bulk_restore_items brings back the status each item had" do
      cat = catalogue!()
      c = category!(cat)
      a = item!(%{category_uuid: c.uuid, status: "discontinued"})
      b = item!(%{category_uuid: c.uuid})

      assert {2, nil} = Catalogue.bulk_trash_items([a.uuid, b.uuid], [])
      assert {2, nil} = Catalogue.bulk_restore_items([a.uuid, b.uuid], [])

      assert status(Item, a.uuid) == "discontinued"
      assert status(Item, b.uuid) == "active"
      refute Map.has_key?(reload(a).data, "_trash")
    end

    test "bulk_trash_categories trashes an ancestor before its descendant, whatever the order given" do
      cat = catalogue!()
      parent = category!(cat)
      child = category!(cat, %{parent_uuid: parent.uuid})
      i = item!(%{category_uuid: child.uuid})

      {:ok, _} = Catalogue.bulk_trash_categories([child.uuid, parent.uuid], :cascade, [])
      {:ok, _} = Catalogue.restore_category(reload(parent))

      assert status(Category, child.uuid) == "active"
      assert status(Item, i.uuid) == "active"
    end
  end

  describe "no live item in a trashed category" do
    test "create_item and update_item refuse a trashed category" do
      cat = catalogue!()
      c = category!(cat)
      {:ok, _} = Catalogue.trash_category(c)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Catalogue.create_item(%{name: "Late", category_uuid: c.uuid})

      assert %{category_uuid: [_]} = errors_on(changeset)

      live = item!(%{catalogue_uuid: cat.uuid})
      assert {:error, %Ecto.Changeset{}} = Catalogue.update_item(live, %{category_uuid: c.uuid})
      assert is_nil(reload(live).category_uuid)
    end

    test "move_item_to_category and bulk moves refuse a trashed category" do
      cat = catalogue!()
      c = category!(cat)
      live = item!(%{catalogue_uuid: cat.uuid})
      {:ok, _} = Catalogue.trash_category(c)

      assert {:error, :category_not_found} = Catalogue.move_item_to_category(live, c.uuid)

      assert {:error, :category_not_found} =
               Catalogue.bulk_move_items_to_category([live.uuid], c.uuid,
                 catalogue_uuid: cat.uuid
               )

      assert is_nil(reload(live).category_uuid)
    end

    test "duplicating an item into a trashed category is refused" do
      cat = catalogue!()
      c = category!(cat)
      source = item!(%{catalogue_uuid: cat.uuid})
      {:ok, _} = Catalogue.trash_category(c)

      assert {:error, _} = Catalogue.duplicate_item(source, category_uuid: c.uuid)

      live_in_c =
        Repo.aggregate(
          from(i in Item, where: i.category_uuid == ^c.uuid and i.status != "deleted"),
          :count
        )

      assert live_in_c == 0
    end

    test "trash_category :move_to refuses a trashed target" do
      cat = catalogue!()
      source = category!(cat)
      target = category!(cat)
      item!(%{category_uuid: source.uuid})
      {:ok, _} = Catalogue.trash_category(target)

      assert {:error, :move_target_not_found} =
               Catalogue.trash_category(source, items: {:move_to, target.uuid})

      assert status(Category, source.uuid) == "active"
    end
  end

  describe "plain updates never trash or restore" do
    test "saving a trashed item, category or catalogue through an update does not revive it" do
      cat = catalogue!()
      c = category!(cat)
      i = item!(%{category_uuid: c.uuid, status: "inactive"})
      stale_item = i
      stale_catalogue = cat

      {:ok, _} = Catalogue.trash_catalogue(cat)

      # A form opened before the trash posts a live status with its save.
      {:ok, saved} = Catalogue.update_item(stale_item, %{name: "Renamed", status: "active"})
      assert saved.name == "Renamed"
      assert status(Item, i.uuid) == "deleted"

      {:ok, _} = Catalogue.update_category(reload(c), %{status: "active"})
      assert status(Category, c.uuid) == "deleted"

      {:ok, _} = Catalogue.update_catalogue(stale_catalogue, %{status: "active"})
      assert status(CatalogueRow, cat.uuid) == "deleted"

      # Restore still brings the item back to the status it had.
      {:ok, _} = Catalogue.restore_catalogue(reload(cat))
      assert status(Item, i.uuid) == "inactive"
    end

    test "a row created already deleted is stamped, so a catalogue round trip leaves it in the trash" do
      cat = catalogue!()
      c = category!(cat)
      born_deleted = item!(%{category_uuid: c.uuid, status: "deleted"})

      assert reload(born_deleted).data["_trash"]["via"] == "self"

      {:ok, _} = Catalogue.trash_catalogue(cat)
      {:ok, _} = Catalogue.restore_catalogue(reload(cat))

      assert status(Category, c.uuid) == "active"
      assert status(Item, born_deleted.uuid) == "deleted"
    end

    test "an update cannot trash a row, and live status changes still apply" do
      cat = catalogue!()
      c = category!(cat)
      i = item!(%{category_uuid: c.uuid})

      {:ok, _} = Catalogue.update_item(i, %{status: "deleted"})
      {:ok, _} = Catalogue.update_category(c, %{status: "deleted"})
      {:ok, _} = Catalogue.update_catalogue(cat, %{status: "deleted"})

      assert status(Item, i.uuid) == "active"
      assert status(Category, c.uuid) == "active"
      assert status(CatalogueRow, cat.uuid) == "active"

      {:ok, _} = Catalogue.update_item(reload(i), %{status: "discontinued"})
      {:ok, _} = Catalogue.update_catalogue(reload(cat), %{status: "archived"})
      assert status(Item, i.uuid) == "discontinued"
      assert status(CatalogueRow, cat.uuid) == "archived"
    end
  end

  describe "rows a restore has to leave behind" do
    defp trash_stamp(schema, uuid),
      do: (reload(%{__struct__: schema, uuid: uuid}).data || %{})["_trash"]

    test "an item left inside a still-trashed category joins that category's trash (seed 423352)" do
      cat = catalogue!()
      r = category!(cat)
      m = category!(cat, %{parent_uuid: r.uuid})
      l = category!(cat, %{parent_uuid: m.uuid})
      i = item!(%{category_uuid: l.uuid})

      {:ok, _} = Catalogue.trash_category(m, items: :cascade)
      {:ok, _} = Catalogue.restore_category(reload(l))
      {:ok, _} = Catalogue.trash_category(reload(r), items: :cascade)
      {:ok, _} = Catalogue.restore_category(reload(m))

      # m's restore could not bring i back (l is trashed by r), so i now
      # belongs to l's trash, not m's.
      assert status(Item, i.uuid) == "deleted"
      assert %{"root" => root, "via" => "category"} = trash_stamp(Item, i.uuid)
      assert root == r.uuid

      {:ok, _} = Catalogue.restore_category(reload(l))

      # A later trash and restore of m leaves i where it is.
      {:ok, _} = Catalogue.trash_category(reload(m), items: :cascade)
      {:ok, _} = Catalogue.restore_category(reload(m))
      assert status(Item, i.uuid) == "deleted"

      # Restoring what took l brings i back.
      {:ok, _} = Catalogue.restore_category(reload(r))
      assert status(Item, i.uuid) == "active"
    end

    test "a catalogue restore hands a legacy item in a self-trashed category to that category" do
      cat = catalogue!()
      k = category!(cat)
      j = item!(%{category_uuid: k.uuid})

      {:ok, _} = Catalogue.trash_category(k, items: :cascade)
      strip_stamp!(Item, j.uuid)
      {:ok, _} = Catalogue.trash_catalogue(reload(cat))
      {:ok, _} = Catalogue.restore_catalogue(reload(cat))

      assert status(Category, k.uuid) == "deleted"
      assert status(Item, j.uuid) == "deleted"
      assert %{"root" => root, "via" => "category"} = trash_stamp(Item, j.uuid)
      assert root == k.uuid

      {:ok, _} = Catalogue.restore_category(reload(k))
      assert status(Item, j.uuid) == "active"
    end

    test "an item left in an unstamped trashed category becomes trashed on its own" do
      cat = catalogue!()
      m = category!(cat)
      l = category!(cat, %{parent_uuid: m.uuid})
      i = item!(%{category_uuid: l.uuid, status: "inactive"})

      {:ok, _} = Catalogue.trash_category(m, items: :cascade)
      # l as a pre-provenance trash: m's restore does not take it back.
      strip_stamp!(Category, l.uuid)
      {:ok, _} = Catalogue.restore_category(reload(m))

      assert status(Category, l.uuid) == "deleted"
      assert status(Item, i.uuid) == "deleted"

      assert %{"root" => root, "via" => "self", "from_status" => "inactive"} =
               trash_stamp(Item, i.uuid)

      assert root == i.uuid
    end
  end

  describe "randomized combinations" do
    @describetag timeout: 600_000

    test "invariants hold after every step, and trash-then-restore of any live root changes nothing" do
      seed = ExUnit.configuration()[:seed] || 0
      :rand.seed(:exsss, {seed, 1789, 42})

      # Sized to keep the suite quick; widen a run with e.g.
      # TRASH_FUZZ_WORLDS=150 TRASH_FUZZ_STEPS=15 mix test <this file>.
      worlds = String.to_integer(System.get_env("TRASH_FUZZ_WORLDS", "60"))
      steps = String.to_integer(System.get_env("TRASH_FUZZ_STEPS", "12"))

      for world_n <- 1..worlds do
        world = build_world(:rand.uniform(2) == 1)

        Enum.reduce(1..steps, [], fn _step, history ->
          op = random_op(world)
          history = [{op, apply_op(op, world)} | history]
          context = {seed, world_n, history}

          assert_invariants(world, context)
          assert_round_trip(world, context)
          history
        end)
      end
    end
  end

  # ── fixtures ─────────────────────────────────────────────────────────

  defp catalogue!(attrs \\ %{}) do
    {:ok, c} = Catalogue.create_catalogue(Map.merge(%{name: "Catalogue #{uniq()}"}, attrs))
    c
  end

  defp category!(cat, attrs \\ %{}) do
    {:ok, c} =
      Catalogue.create_category(
        Map.merge(%{name: "Category #{uniq()}", catalogue_uuid: cat.uuid}, attrs)
      )

    c
  end

  defp item!(attrs) do
    {:ok, i} = Catalogue.create_item(Map.merge(%{name: "Item #{uniq()}"}, attrs))
    i
  end

  defp uniq, do: System.unique_integer([:positive])
  defp status(schema, uuid), do: Repo.get!(schema, uuid).status
  defp reload(%schema{uuid: uuid}), do: Repo.get!(schema, uuid)

  # Simulates a row trashed before provenance existed.
  defp strip_stamp!(schema, uuid) do
    from(r in schema,
      where: r.uuid == ^uuid,
      update: [set: [data: fragment("COALESCE(?, '{}'::jsonb) - '_trash'", r.data)]]
    )
    |> Repo.update_all([])
  end

  # ── randomized run ───────────────────────────────────────────────────

  # A catalogue with a three-deep branch, a sibling, categorised and loose
  # items in every status — plus a bystander catalogue nothing may touch.
  defp build_world(archived?) do
    cat = catalogue!(if archived?, do: %{status: "archived"}, else: %{})
    r = category!(cat)
    m = category!(cat, %{parent_uuid: r.uuid})
    l = category!(cat, %{parent_uuid: m.uuid})
    s = category!(cat)

    items = [
      item!(%{category_uuid: r.uuid}),
      item!(%{category_uuid: m.uuid, status: "inactive"}),
      item!(%{category_uuid: l.uuid}),
      item!(%{category_uuid: s.uuid, status: "discontinued"}),
      item!(%{catalogue_uuid: cat.uuid}),
      item!(%{catalogue_uuid: cat.uuid, status: "inactive"})
    ]

    other = catalogue!()
    other_category = category!(other)
    other_item = item!(%{category_uuid: other_category.uuid})

    %{
      catalogue: cat.uuid,
      categories: Enum.map([r, m, l, s], & &1.uuid),
      items: Enum.map(items, & &1.uuid),
      bystander: {other.uuid, other_category.uuid, other_item.uuid}
    }
  end

  # Weighted by repetition: category restores come up twice as often as the
  # other operations, and :cascade twice as often as each other disposition.
  @random_ops [
    &__MODULE__.op_trash_item/1,
    &__MODULE__.op_restore_item/1,
    &__MODULE__.op_trash_category/1,
    &__MODULE__.op_restore_category/1,
    &__MODULE__.op_restore_category/1,
    &__MODULE__.op_bulk_trash_items/1,
    &__MODULE__.op_bulk_restore_items/1,
    &__MODULE__.op_bulk_trash_categories/1,
    &__MODULE__.op_trash_catalogue/1,
    &__MODULE__.op_restore_catalogue/1,
    &__MODULE__.op_move_category_under/1
  ]

  defp random_op(world), do: pick(@random_ops).(world)

  def op_trash_item(%{items: items}), do: {:trash_item, pick(items)}
  def op_restore_item(%{items: items}), do: {:restore_item, pick(items)}

  def op_trash_category(%{categories: cats}),
    do:
      {:trash_category, pick(cats),
       pick([:cascade, :cascade, :uncategorize, {:move_to, pick(cats)}])}

  def op_restore_category(%{categories: cats}), do: {:restore_category, pick(cats)}
  def op_bulk_trash_items(%{items: items}), do: {:bulk_trash_items, subset(items)}
  def op_bulk_restore_items(%{items: items}), do: {:bulk_restore_items, subset(items)}

  def op_bulk_trash_categories(%{categories: cats}),
    do: {:bulk_trash_categories, subset(cats), :cascade}

  def op_move_category_under(%{categories: cats}),
    do: {:move_category_under, pick(cats), pick([nil | cats])}

  def op_trash_catalogue(_world), do: :trash_catalogue
  def op_restore_catalogue(_world), do: :restore_catalogue

  defp pick(list), do: Enum.at(list, :rand.uniform(length(list)) - 1)
  defp subset(list), do: Enum.filter(list, fn _ -> :rand.uniform(2) == 1 end)

  defp apply_op({:trash_item, uuid}, _w), do: outcome(Catalogue.trash_item(Repo.get!(Item, uuid)))

  defp apply_op({:restore_item, uuid}, _w),
    do: outcome(Catalogue.restore_item(Repo.get!(Item, uuid)))

  defp apply_op({:trash_category, uuid, disposition}, _w),
    do: outcome(Catalogue.trash_category(Repo.get!(Category, uuid), items: disposition))

  defp apply_op({:restore_category, uuid}, _w),
    do: outcome(Catalogue.restore_category(Repo.get!(Category, uuid)))

  defp apply_op({:bulk_trash_items, uuids}, _w),
    do: outcome(Catalogue.bulk_trash_items(uuids, []))

  defp apply_op({:bulk_restore_items, uuids}, _w),
    do: outcome(Catalogue.bulk_restore_items(uuids, []))

  defp apply_op({:bulk_trash_categories, uuids, disposition}, _w),
    do: outcome(Catalogue.bulk_trash_categories(uuids, disposition, []))

  defp apply_op(:trash_catalogue, w),
    do: outcome(Catalogue.trash_catalogue(Repo.get!(CatalogueRow, w.catalogue)))

  defp apply_op(:restore_catalogue, w),
    do: outcome(Catalogue.restore_catalogue(Repo.get!(CatalogueRow, w.catalogue)))

  defp apply_op({:move_category_under, uuid, parent_uuid}, _w),
    do: outcome(Catalogue.move_category_under(Repo.get!(Category, uuid), parent_uuid))

  defp outcome({:ok, _}), do: :ok
  defp outcome({:error, %Ecto.Changeset{}}), do: :changeset
  defp outcome({:error, reason}), do: reason
  defp outcome({count, nil}) when is_integer(count), do: count

  defp assert_invariants(w, context) do
    live_in_trashed_category =
      Repo.all(
        from(i in Item,
          join: c in Category,
          on: c.uuid == i.category_uuid,
          where: i.catalogue_uuid == ^w.catalogue,
          where: i.status != "deleted" and c.status == "deleted",
          select: i.uuid
        )
      )

    assert live_in_trashed_category == [], failure("live item in a trashed category", context)

    drifted =
      Repo.all(
        from(i in Item,
          join: c in Category,
          on: c.uuid == i.category_uuid,
          where: i.catalogue_uuid == ^w.catalogue and i.catalogue_uuid != c.catalogue_uuid,
          select: i.uuid
        )
      )

    assert drifted == [], failure("item catalogue differs from its category's", context)

    for schema <- [Item, Category] do
      rows =
        Repo.all(
          from(r in schema,
            where: r.catalogue_uuid == ^w.catalogue,
            select: {r.status, fragment("(? -> '_trash') IS NOT NULL", r.data)}
          )
        )

      assert Enum.all?(rows, fn {status, stamped?} -> stamped? == (status == "deleted") end),
             failure(
               "#{inspect(schema)}: a deleted row without a stamp, or a live row with one",
               context
             )
    end

    assert unreachable_stamps(w) == [],
           failure("a trashed row's stamp names a root its restore cannot reach", context)

    catalogue = Repo.get!(CatalogueRow, w.catalogue)

    assert Map.has_key?(catalogue.data || %{}, "_trash") == (catalogue.status == "deleted"),
           failure("catalogue stamp does not match its status", context)

    {other, other_category, other_item} = w.bystander

    assert status(CatalogueRow, other) == "active",
           failure("bystander catalogue touched", context)

    assert status(Category, other_category) == "active",
           failure("bystander category touched", context)

    assert status(Item, other_item) == "active", failure("bystander item touched", context)
  end

  # A restore walks its root's current subtree (or the catalogue), so a
  # stamp must name the catalogue, the row itself, or one of its ancestors.
  defp unreachable_stamps(w) do
    parents =
      Repo.all(
        from(c in Category,
          where: c.catalogue_uuid == ^w.catalogue,
          select: {c.uuid, c.parent_uuid}
        )
      )
      |> Map.new()

    stamped = fn schema, category_of ->
      Repo.all(
        from(r in schema,
          where: r.catalogue_uuid == ^w.catalogue and r.status == "deleted",
          select: {r.uuid, field(r, ^category_of), fragment("? #>> '{_trash,root}'", r.data)}
        )
      )
    end

    for {uuid, start, root} <-
          stamped.(Category, :uuid) ++ stamped.(Item, :category_uuid),
        root not in [w.catalogue, uuid | path_up(start, parents, map_size(parents))],
        do: uuid
  end

  defp path_up(nil, _parents, _fuel), do: []
  defp path_up(_uuid, _parents, 0), do: []

  defp path_up(uuid, parents, fuel),
    do: [uuid | path_up(Map.get(parents, uuid), parents, fuel - 1)]

  defp assert_round_trip(w, context) do
    case round_trip_target(w) do
      nil ->
        :ok

      {label, trash, restore} ->
        before = snapshot(w)
        trash.()
        restore.()

        assert snapshot(w) == before,
               failure("trash then restore of #{label} changed something", context)
    end
  end

  defp round_trip_target(w) do
    catalogue = Repo.get!(CatalogueRow, w.catalogue)
    if catalogue.status == "deleted", do: nil, else: pick(round_trip_candidates(w, catalogue))
  end

  defp round_trip_candidates(w, catalogue) do
    live_categories =
      Repo.all(
        from(c in Category,
          where: c.uuid in ^w.categories and c.status != "deleted",
          select: c.uuid
        )
      )

    live_items =
      Repo.all(
        from(i in Item, where: i.uuid in ^w.items and i.status != "deleted", select: i.uuid)
      )

    [catalogue_candidate(w, catalogue)] ++
      Enum.map(live_categories, &category_candidate/1) ++
      Enum.map(live_items, &item_candidate/1) ++
      bulk_candidate(subset(live_items))
  end

  defp catalogue_candidate(w, catalogue) do
    {"the catalogue", fn -> Catalogue.trash_catalogue(reload(catalogue)) end,
     fn -> Catalogue.restore_catalogue(Repo.get!(CatalogueRow, w.catalogue)) end}
  end

  defp category_candidate(uuid) do
    {"category #{uuid}",
     fn -> Catalogue.trash_category(Repo.get!(Category, uuid), items: :cascade) end,
     fn -> Catalogue.restore_category(Repo.get!(Category, uuid)) end}
  end

  defp item_candidate(uuid) do
    {"item #{uuid}", fn -> Catalogue.trash_item(Repo.get!(Item, uuid)) end,
     fn -> Catalogue.restore_item(Repo.get!(Item, uuid)) end}
  end

  defp bulk_candidate([]), do: []

  defp bulk_candidate(uuids) do
    [
      {"items #{inspect(uuids)} in bulk", fn -> Catalogue.bulk_trash_items(uuids, []) end,
       fn -> Catalogue.bulk_restore_items(uuids, []) end}
    ]
  end

  defp snapshot(w) do
    categories =
      Repo.all(
        from(c in Category,
          where: c.catalogue_uuid == ^w.catalogue,
          select: {c.uuid, c.status, c.parent_uuid, c.data}
        )
      )

    items =
      Repo.all(
        from(i in Item,
          where: i.catalogue_uuid == ^w.catalogue,
          select: {i.uuid, i.status, i.category_uuid, i.data}
        )
      )

    catalogue = Repo.get!(CatalogueRow, w.catalogue)

    %{
      catalogue: {catalogue.status, catalogue.folder_uuid, (catalogue.data || %{})["_trash"]},
      categories: categories |> Enum.map(&trash_view/1) |> Enum.sort(),
      items: items |> Enum.map(&trash_view/1) |> Enum.sort()
    }
  end

  defp trash_view({uuid, status, ref, data}), do: {uuid, status, ref, (data || %{})["_trash"]}

  defp failure(what, {seed, world_n, history}) do
    "#{what} — seed #{seed}, world #{world_n}, ops newest first: #{inspect(history, limit: :infinity)}"
  end
end
