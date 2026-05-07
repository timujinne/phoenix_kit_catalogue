defmodule PhoenixKitCatalogue.Catalogue.Counts do
  @moduledoc """
  Catalogue-level item and category counts. Includes both per-uuid
  helpers and single-query batch versions to avoid N+1 lookups when
  rendering catalogue lists with associated item / category counts.

  Public surface is re-exported from `PhoenixKitCatalogue.Catalogue`.
  """

  import Ecto.Query, warn: false

  alias PhoenixKitCatalogue.Schemas.{Category, Item}

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc "Counts non-deleted items in a catalogue, including items without a category."
  @spec item_count_for_catalogue(Ecto.UUID.t()) :: non_neg_integer()
  def item_count_for_catalogue(catalogue_uuid) do
    from(i in Item,
      where: i.catalogue_uuid == ^catalogue_uuid and i.status != "deleted"
    )
    |> repo().aggregate(:count)
  end

  @doc """
  Counts active items in a category subtree (the category itself and
  every V103 descendant). Used by the admin "delete category" modal to
  decide whether to ask the operator what should happen to the items.
  """
  @spec active_item_count_in_subtree(Ecto.UUID.t()) :: non_neg_integer()
  def active_item_count_in_subtree(category_uuid) do
    subtree = PhoenixKitCatalogue.Catalogue.Tree.subtree_uuids(category_uuid)

    from(i in Item,
      where: i.category_uuid in ^subtree and i.status != "deleted"
    )
    |> repo().aggregate(:count)
  end

  @doc """
  Returns a map of `%{catalogue_uuid => non_deleted_item_count}` for all catalogues.

  Single-query batch version of `item_count_for_catalogue/1` — avoids N+1 when
  displaying item counts alongside a catalogue list. Includes items both in
  categories and directly attached to a catalogue (uncategorized).
  """
  @spec item_counts_by_catalogue() :: %{Ecto.UUID.t() => non_neg_integer()}
  def item_counts_by_catalogue do
    from(i in Item,
      where: i.status != "deleted" and not is_nil(i.catalogue_uuid),
      group_by: i.catalogue_uuid,
      select: {i.catalogue_uuid, count(i.uuid)}
    )
    |> repo().all()
    |> Map.new()
  end

  @doc "Counts non-deleted categories for a catalogue."
  @spec category_count_for_catalogue(Ecto.UUID.t()) :: non_neg_integer()
  def category_count_for_catalogue(catalogue_uuid) do
    from(c in Category,
      where: c.catalogue_uuid == ^catalogue_uuid and c.status != "deleted"
    )
    |> repo().aggregate(:count)
  end

  @doc """
  Returns a map of `catalogue_uuid => non_deleted_category_count`, in a
  single query. Useful for displaying category counts alongside a
  catalogue list (e.g. in the import wizard's catalogue picker) without
  N+1 lookups.
  """
  @spec category_counts_by_catalogue() :: %{Ecto.UUID.t() => non_neg_integer()}
  def category_counts_by_catalogue do
    from(c in Category,
      where: c.status != "deleted",
      group_by: c.catalogue_uuid,
      select: {c.catalogue_uuid, count(c.uuid)}
    )
    |> repo().all()
    |> Map.new()
  end

  @doc "Counts deleted items in a catalogue, including items without a category."
  @spec deleted_item_count_for_catalogue(Ecto.UUID.t()) :: non_neg_integer()
  def deleted_item_count_for_catalogue(catalogue_uuid) do
    from(i in Item,
      where: i.catalogue_uuid == ^catalogue_uuid and i.status == "deleted"
    )
    |> repo().aggregate(:count)
  end

  @doc "Counts deleted categories for a catalogue."
  @spec deleted_category_count_for_catalogue(Ecto.UUID.t()) :: non_neg_integer()
  def deleted_category_count_for_catalogue(catalogue_uuid) do
    from(c in Category,
      where: c.catalogue_uuid == ^catalogue_uuid and c.status == "deleted"
    )
    |> repo().aggregate(:count)
  end

  @doc """
  Total count of deleted entities (items + categories) for a catalogue.

  Used to determine whether to show the "Deleted" tab.
  """
  @spec deleted_count_for_catalogue(Ecto.UUID.t()) :: non_neg_integer()
  def deleted_count_for_catalogue(catalogue_uuid) do
    deleted_item_count_for_catalogue(catalogue_uuid) +
      deleted_category_count_for_catalogue(catalogue_uuid)
  end
end
