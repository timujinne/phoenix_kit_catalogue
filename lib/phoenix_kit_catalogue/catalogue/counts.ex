defmodule PhoenixKitCatalogue.Catalogue.Counts do
  @moduledoc """
  Catalogue-level item and category counts. Includes both per-uuid
  helpers and single-query batch versions to avoid N+1 lookups when
  rendering catalogue lists with associated item / category counts.

  Public surface is re-exported from `PhoenixKitCatalogue.Catalogue`.
  """

  import Ecto.Query, warn: false

  alias PhoenixKitCatalogue.Catalogue.Tree
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
    subtree = Tree.subtree_uuids(category_uuid)

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

  @doc """
  Batch "has attached documents" counts for list rows: given resources
  (items / catalogues / row maps) whose `data["files_folder_uuid"]` points
  at their attachment folder, returns `%{resource_uuid => count}` of the
  NON-image, live files in that folder — the same set the product card's
  Files section lists (`ProductCard.resolve_files/1`, over
  `Attachments.folder_files_query/1`: home files PLUS folder-linked
  ones, not trashed, not system-managed, not an image — photos are
  already conveyed by the featured thumb, so the paperclip means
  documents). Linked files are what a content-duplicate upload becomes;
  counting the home folder alone left them out (client, 2026-09-12).

  Two grouped queries for the whole page (home rows, link rows);
  resources without a folder simply don't appear in the map. Rescued to `%{}` — a Storage hiccup must not
  take down a list render.
  """
  @spec attached_file_counts([map()]) :: %{optional(String.t()) => non_neg_integer()}
  def attached_file_counts(resources) when is_list(resources) do
    # folder → [resource_uuid, ...]: normally 1:1 (folders are created
    # per resource), but a cloned/imported resource that carries a
    # copied `files_folder_uuid` must not silently swallow its twin's
    # count — every resource pointing at a folder gets that count.
    folder_to_uuids =
      resources
      |> Enum.reduce(%{}, fn resource, acc ->
        with %{data: data} when is_map(data) <- resource,
             folder when is_binary(folder) and folder != "" <-
               Map.get(data, "files_folder_uuid") do
          Map.update(acc, folder, [resource.uuid], &[resource.uuid | &1])
        else
          _ -> acc
        end
      end)

    case Map.keys(folder_to_uuids) do
      [] ->
        %{}

      folder_uuids ->
        folder_uuids
        |> attached_document_counts()
        |> Enum.flat_map(fn {folder, count} ->
          folder_to_uuids |> Map.fetch!(folder) |> Enum.map(&{&1, count})
        end)
        |> Map.new()
    end
  rescue
    _ -> %{}
  end

  # Two grouped queries for the whole page — home rows grouped by their
  # folder, link rows grouped by the folder they point into — summed per
  # folder. A linked file's own folder_uuid is ANOTHER folder's, so the
  # home-or-linked set has no single column to group on; two queries
  # is the honest shape. Filters mirror `ProductCard.list_folder_files/1`:
  # live, not system-managed, not an image. A folder with nothing
  # attached stays absent from the result, as callers test presence.
  #
  # A link row that names the file's OWN home folder is skipped: the
  # listing's `home OR linked` reads such a file once, and the sum must
  # not read it twice. The shape is real — a file linked into a folder
  # and later re-homed there by the media manager keeps its link row.
  defp attached_document_counts(folder_uuids) do
    home =
      from(f in PhoenixKit.Modules.Storage.File,
        where: f.folder_uuid in ^folder_uuids,
        where: f.status != "trashed" and f.system_managed == false and f.file_type != "image",
        group_by: f.folder_uuid,
        select: {f.folder_uuid, count(f.uuid)}
      )
      |> repo().all()

    linked =
      from(fl in PhoenixKit.Modules.Storage.FolderLink,
        join: f in PhoenixKit.Modules.Storage.File,
        on: f.uuid == fl.file_uuid,
        where: fl.folder_uuid in ^folder_uuids,
        where: f.status != "trashed" and f.system_managed == false and f.file_type != "image",
        where: is_nil(f.folder_uuid) or f.folder_uuid != fl.folder_uuid,
        group_by: fl.folder_uuid,
        select: {fl.folder_uuid, count(f.uuid)}
      )
      |> repo().all()

    Enum.reduce(home ++ linked, %{}, fn {folder, n}, acc ->
      Map.update(acc, folder, n, &(&1 + n))
    end)
  end
end
