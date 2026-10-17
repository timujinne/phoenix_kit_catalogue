defmodule PhoenixKitCatalogue.API.DeleteCategories do
  @moduledoc false
  # Tool `catalogue.delete_categories`: trash, never delete. A category goes the way the
  # admin's delete button takes it by default (`items: :cascade`): its subcategories and
  # the items in its subtree go to the trash with it, stamped as taken by it, so
  # `Catalogue.restore_category/2` brings back exactly that set.

  alias PhoenixKitCatalogue.API
  alias PhoenixKitCatalogue.API.Common
  alias PhoenixKitCatalogue.Catalogue

  @tool "catalogue.delete_categories"

  @spec call(map(), map()) ::
          {:ok, map()} | {:preview, map(), String.t()} | {:error, atom(), String.t(), map()}
  def call(input, ctx) do
    with {:ok, catalogue} <- API.resolve_catalogue(input["catalogue_id"], writable: true) do
      resolutions =
        API.resolve_refs(input["refs"], kind: :category, catalogue_uuid: catalogue.uuid)

      plan = Common.removal_plan(resolutions, catalogue, :category)
      tree = tree(catalogue)

      if ctx.dry_run?, do: preview(plan, tree), else: execute(plan, catalogue, tree, ctx)
    end
  end

  # --- the category tree (reads only) ----------------------------------------------------

  # The tree the write cascades through: every category of the catalogue, trashed ones too
  # (`Tree.subtree_uuids/1` passes through them, and a live category can sit below a trashed
  # one). `parents`: uuid => parent uuid; `children`: uuid => child uuids; `live`: the uuids of
  # the categories that are not in the trash.
  defp tree(catalogue) do
    # `mode: :deleted` is "every status" for the categories.
    categories = Catalogue.list_categories_metadata_for_catalogue(catalogue.uuid, mode: :deleted)

    %{
      parents: Map.new(categories, &{&1.uuid, &1.parent_uuid}),
      children: Enum.group_by(categories, & &1.parent_uuid, & &1.uuid),
      live: for(c <- categories, c.status != "deleted", into: MapSet.new(), do: c.uuid)
    }
  end

  # The categories above `uuid`, root first. `acc` stops a corrupt cycle.
  defp ancestors(uuid, tree), do: ancestors(Map.get(tree.parents, uuid), tree, [])

  defp ancestors(nil, _tree, acc), do: acc

  defp ancestors(uuid, tree, acc) do
    if uuid in acc or not Map.has_key?(tree.parents, uuid),
      do: acc,
      else: ancestors(Map.get(tree.parents, uuid), tree, [uuid | acc])
  end

  # `uuid` and everything below it, in any state.
  defp subtree(uuid, tree), do: subtree([uuid], tree, MapSet.new())

  defp subtree([], _tree, seen), do: MapSet.to_list(seen)

  defp subtree([uuid | rest], tree, seen) do
    if MapSet.member?(seen, uuid),
      do: subtree(rest, tree, seen),
      else: subtree(Map.get(tree.children, uuid, []) ++ rest, tree, MapSet.put(seen, uuid))
  end

  # What a trash of `uuid` takes, given its `subtree` and `items` (uuid => the live items
  # directly in it): the live subcategories and the live items of the subtree, as sorted uuids.
  # The write trashes exactly these (the rest of the subtree is in the trash already and keeps
  # its own stamp).
  defp taken_by(uuid, subtree, items, tree) do
    categories =
      for sub <- subtree, sub != uuid, MapSet.member?(tree.live, sub), do: sub

    {Enum.sort(categories), subtree |> Enum.flat_map(&Map.get(items, &1, [])) |> Enum.sort()}
  end

  # --- dry run -------------------------------------------------------------------------

  # The fingerprint follows the rows and WHICH categories and items would go, not only how many,
  # so a swap of equal size between the preview and the confirmation is caught too.
  defp preview(plan, tree) do
    taken = removable(plan)

    classified =
      Enum.map(plan, fn
        {:remove, ref, category} ->
          if covered?(category, taken, tree),
            do: {:covered, ref, category},
            else: {:taken, ref, category, subtree(category.uuid, tree)}

        other ->
          other
      end)

    # Only the subtrees the write takes are read, by the write's own predicate.
    items =
      for({:taken, _ref, _category, subtree} <- classified, uuid <- subtree, uniq: true, do: uuid)
      |> Catalogue.live_item_uuids_by_category()

    entries =
      Enum.map(classified, fn
        {:covered, ref, category} ->
          {Common.row_ok(ref, "unchanged", category.uuid), nil}

        {:taken, ref, category, subtree} ->
          preview_row(ref, category, taken_by(category.uuid, subtree, items, tree))

        other ->
          {Common.removal_row(other), nil}
      end)

    rows = Enum.map(entries, &elem(&1, 0))

    body = %{
      "requires_confirmation" => true,
      "rows" => rows,
      "summary" => Common.summary(rows)
    }

    {:preview, body, Common.fingerprint({rows, Enum.map(entries, &elem(&1, 1))})}
  end

  defp preview_row(ref, category, {categories, items}) do
    row =
      Common.row_ok(ref, "removed", category.uuid, %{
        "name" => category.name,
        "changes" => %{"status" => %{"from" => category.status, "to" => "deleted"}},
        "subcategories" => length(categories),
        "items" => length(items)
      })

    {row, {categories, items}}
  end

  defp removable(plan), do: MapSet.new(for {:remove, _ref, category} <- plan, do: category.uuid)

  # A category below another one of the request goes with it, whichever comes first.
  defp covered?(category, taken, tree),
    do: category.uuid |> ancestors(tree) |> Enum.any?(&MapSet.member?(taken, &1))

  # --- execution -------------------------------------------------------------------------

  # Ancestors go first (the order the admin's bulk trash uses), so a category listed with one of
  # its descendants takes it, whatever the order of the request: the descendant is then stamped as
  # taken by it and a restore of the ancestor brings it back. The rows are answered in request order.
  defp execute(plan, catalogue, tree, ctx) do
    opts = Common.write_opts(ctx, @tool, broadcast: false, items: :cascade)

    rows =
      plan
      |> Enum.with_index()
      |> Enum.sort_by(fn {entry, _index} -> depth(entry, tree) end)
      |> Enum.map(fn {entry, index} -> {index, run(entry, opts)} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    if Enum.any?(rows, &(&1["action"] == "removed")),
      do: Catalogue.broadcast_categories_trashed(catalogue.uuid)

    Common.batch_result(rows)
  end

  defp depth({:remove, _ref, category}, tree), do: category.uuid |> ancestors(tree) |> length()
  defp depth(_entry, _tree), do: 0

  defp run({:remove, ref, category}, opts) do
    case Catalogue.trash_category_outcome(category, opts) do
      {:ok, :trashed, _trashed} ->
        Common.row_ok(ref, "removed", category.uuid)

      # Someone else trashed it after the request was planned, or an ancestor of this
      # request took it.
      {:ok, :already_trashed, _trashed} ->
        Common.row_ok(ref, "unchanged", category.uuid)

      {:error, :not_found} ->
        Common.row_error(ref, :not_found, "The category no longer exists.")

      {:error, _reason} ->
        Common.row_error(ref, :internal_error, "The category could not be moved to the trash.")
    end
  end

  defp run(other, _opts), do: Common.removal_row(other)
end
