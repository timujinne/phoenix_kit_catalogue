defmodule PhoenixKitCatalogue.Catalogue.Tree do
  @moduledoc false
  # Recursive tree helpers for the category adjacency list (V103).
  # Used by the cascade operations (trash/restore/permanent-delete),
  # cross-catalogue move, cycle checks, and search expansion.
  #
  # The recursive queries are core's `PhoenixKit.Utils.TreeQuery` (one
  # CTE each). For UIs that already have every category in the catalogue
  # loaded (e.g. the detail view), prefer `build_index/1` + `walk_subtree/2`
  # — same shape, no DB trip.
  #
  # ## Cycle safety
  #
  # The context API guards against cycles (`move_category_under/3`
  # rejects a descendant parent, `Category.changeset` rejects a
  # self-parent), so a well-formed DB never contains a cycle. As
  # defense in depth against corrupted data or direct SQL writes, the
  # CTEs use `UNION` (not `UNION ALL`), which ends a cycle's recursion.

  import Ecto.Query, warn: false

  alias PhoenixKit.Utils.TreeQuery
  alias PhoenixKitCatalogue.Schemas.Category

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc """
  Returns `[uuid]` for `root_uuid` and every descendant. Order
  unspecified. Used for subtree updates (trash, move_to_catalogue,
  permanent delete).
  """
  @spec subtree_uuids(Ecto.UUID.t()) :: [Ecto.UUID.t()]
  def subtree_uuids(root_uuid) when is_binary(root_uuid) do
    subtree_uuids_for([root_uuid])
  end

  @doc """
  Returns every UUID in the union of subtrees seeded by `roots`.
  Duplicates (when one seed is an ancestor of another) are collapsed.
  Used to expand a search scope from selected categories down into
  their descendants.
  """
  @spec subtree_uuids_for([Ecto.UUID.t()]) :: [Ecto.UUID.t()]
  def subtree_uuids_for([]), do: []

  def subtree_uuids_for(roots) when is_list(roots) do
    # Raw 16-byte binaries, as the callers expect: most pipe these straight
    # into another `c.uuid in ^uuids` query (subtree trash / restore /
    # permanent-delete), and the one that compares against a textual UUID
    # — `validate_parent_in_same_catalogue/1` — normalises both sides via
    # `Ecto.UUID.dump/1` (see `catalogue.ex`).
    Category |> TreeQuery.subtree_uuids(roots) |> Enum.map(&Ecto.UUID.dump!/1)
  end

  @doc """
  Returns `[uuid]` for every ancestor of `uuid`, walking up to the root.
  Excludes `uuid` itself. Order unspecified.
  """
  @spec ancestor_uuids(Ecto.UUID.t()) :: [Ecto.UUID.t()]
  def ancestor_uuids(uuid) when is_binary(uuid) do
    # Raw 16-byte binaries — see `subtree_uuids_for/1`.
    Category |> TreeQuery.ancestor_uuids(uuid) |> Enum.map(&Ecto.UUID.dump!/1)
  end

  @doc """
  Returns the list of ancestor categories ordered from root → direct
  parent. Excludes the category itself. Used for breadcrumbs.
  """
  @spec ancestors_in_order(Ecto.UUID.t()) :: [Category.t()]
  def ancestors_in_order(uuid) when is_binary(uuid) do
    case ancestor_uuids(uuid) do
      [] ->
        []

      uuids ->
        # `ancestor_uuids/1` returns raw 16-byte binaries; the loaded
        # `Category` rows below carry textual UUIDs via the schema's
        # `UUIDv7` cast. Build the lookup map keyed by textual UUID,
        # then seed the walk from the input's `parent_uuid` (also
        # textual). Don't try to seed from `uuid` itself — the input
        # category is intentionally excluded from `ancestor_uuids/1`'s
        # result, so it isn't in the map and the walk would short-
        # circuit on the very first lookup.
        by_uuid =
          from(c in Category, where: c.uuid in ^uuids)
          |> repo().all()
          |> Map.new(&{&1.uuid, &1})

        seed_parent_uuid =
          from(c in Category, where: c.uuid == type(^uuid, UUIDv7), select: c.parent_uuid)
          |> repo().one()

        case seed_parent_uuid do
          nil -> []
          # walk_up/3 prepends each ancestor as it walks up, so the
          # accumulator already comes out root → direct-parent without
          # any reverse. (Direct parent is added first → ends up at
          # the tail; the root is added last → ends up at the head.)
          parent -> walk_up(parent, by_uuid, [])
        end
    end
  end

  defp walk_up(uuid, by_uuid, acc) do
    case Map.get(by_uuid, uuid) do
      %Category{parent_uuid: nil} = cat -> [cat | acc]
      %Category{parent_uuid: parent_uuid} = cat -> walk_up(parent_uuid, by_uuid, [cat | acc])
      nil -> acc
    end
  end

  @doc """
  Builds a `%{parent_uuid => [child_category, ...]}` index from a flat
  list of categories. Children are kept in the list's incoming order
  (callers are expected to pass them pre-sorted by position/name).
  Root categories land under the `nil` key.
  """
  @spec build_children_index([Category.t()]) :: %{
          (Ecto.UUID.t() | nil) => [Category.t()]
        }
  def build_children_index(categories) when is_list(categories) do
    Enum.group_by(categories, & &1.parent_uuid)
  end

  @doc """
  Walks a preloaded tree depth-first starting at `root_uuid` (or at
  every root if `nil` is passed), invoking `fun.(category, depth)` for
  each node. Depth starts at `0` for the seed.
  """
  @spec walk_subtree(
          %{(Ecto.UUID.t() | nil) => [Category.t()]},
          Ecto.UUID.t() | nil,
          (Category.t(), non_neg_integer() -> any())
        ) :: :ok
  def walk_subtree(index, root_uuid, fun) when is_function(fun, 2) do
    index
    |> Map.get(root_uuid, [])
    |> Enum.each(&do_walk(&1, index, 0, fun))

    :ok
  end

  defp do_walk(%Category{} = cat, index, depth, fun) do
    fun.(cat, depth)

    index
    |> Map.get(cat.uuid, [])
    |> Enum.each(&do_walk(&1, index, depth + 1, fun))
  end
end
