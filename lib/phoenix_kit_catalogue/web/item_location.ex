defmodule PhoenixKitCatalogue.Web.ItemLocation do
  @moduledoc """
  The item form's Location (boss, 2026-09-19): where an item lives — a
  catalogue, and optionally a category in it — and the folder tree a new
  place is picked from: folders › catalogues › categories › subcategories,
  nested the way the index and the catalogue pages nest them.

  A place is a target string: `"catalogue:<uuid>"` (the catalogue itself,
  no category) or `"category:<uuid>"`. The tree offers only catalogues of
  the item's own kind — standard and smart items price differently and
  never cross — and a folder only when it leads to one of them.

  `tree/1`, `path_names/1` and `resolve/2` read the database; the rest is
  pure over a loaded tree.
  """

  alias PhoenixKitCatalogue.Catalogue

  @type target :: String.t()

  @type tree_node :: %{
          id: String.t(),
          type: :folder | :catalogue | :category,
          name: String.t(),
          archived?: boolean(),
          children: [tree_node()]
        }

  @doc "Where `item` is now, as a target."
  @spec target_of(map()) :: target() | nil
  def target_of(%{category_uuid: category_uuid}) when is_binary(category_uuid),
    do: "category:" <> category_uuid

  def target_of(%{catalogue_uuid: catalogue_uuid}) when is_binary(catalogue_uuid),
    do: "catalogue:" <> catalogue_uuid

  def target_of(_item), do: nil

  @doc "`{:catalogue | :category, uuid}` for a target, `:error` for anything else."
  @spec parse(term()) :: {:catalogue | :category, String.t()} | :error
  def parse("catalogue:" <> uuid) when uuid != "", do: {:catalogue, uuid}
  def parse("category:" <> uuid) when uuid != "", do: {:category, uuid}
  def parse(_target), do: :error

  @doc """
  The picker's tree for items of `kind` (`"standard"` | `"smart"`):
  folders first, then the catalogues filed at that level, each catalogue
  holding its category tree. Trashed folders, catalogues and categories
  are left out; a row whose parent is trashed moves up to the nearest
  live level rather than vanishing, as on the index and the detail page.
  """
  @spec tree(String.t()) :: [tree_node()]
  def tree(kind) do
    by_folder =
      Map.new(Catalogue.catalogues_by_folder(), fn {folder_uuid, catalogues} ->
        {folder_uuid, Enum.filter(catalogues, &(&1.kind == kind))}
      end)

    catalogue_uuids = by_folder |> Map.values() |> List.flatten() |> Enum.map(& &1.uuid)

    categories =
      catalogue_uuids
      |> Catalogue.list_live_categories()
      |> Enum.group_by(& &1.catalogue_uuid)

    folder_children =
      Catalogue.list_folder_tree()
      |> Enum.map(&elem(&1, 0))
      |> Enum.group_by(& &1.parent_uuid)

    level(nil, folder_children, by_folder, categories)
  end

  defp level(folder_uuid, folder_children, by_folder, categories) do
    folders =
      folder_children
      |> Map.get(folder_uuid, [])
      |> Enum.map(fn folder ->
        %{
          id: "folder:" <> folder.uuid,
          type: :folder,
          name: folder.name,
          archived?: false,
          children: level(folder.uuid, folder_children, by_folder, categories)
        }
      end)
      |> Enum.reject(&(&1.children == []))

    catalogues =
      for catalogue <- Map.get(by_folder, folder_uuid, []) do
        %{
          id: "catalogue:" <> catalogue.uuid,
          type: :catalogue,
          name: catalogue.name,
          archived?: catalogue.status == "archived",
          children: category_nodes(Map.get(categories, catalogue.uuid, []))
        }
      end

    folders ++ catalogues
  end

  # A category whose parent is not among the live ones is a root here.
  # Walking down from the roots also means a corrupt parent cycle can
  # never loop: nothing in a cycle is reachable from a root.
  defp category_nodes(categories) do
    live = MapSet.new(categories, & &1.uuid)

    by_parent =
      Enum.group_by(categories, fn category ->
        if category.parent_uuid && MapSet.member?(live, category.parent_uuid),
          do: category.parent_uuid,
          else: nil
      end)

    category_level(nil, by_parent)
  end

  defp category_level(parent_uuid, by_parent) do
    for category <- Map.get(by_parent, parent_uuid, []) do
      %{
        id: "category:" <> category.uuid,
        type: :category,
        name: category.name,
        archived?: false,
        children: category_level(category.uuid, by_parent)
      }
    end
  end

  @doc "Whether `target` is a place the tree offers (a catalogue or category row)."
  @spec member?([tree_node()], term()) :: boolean()
  def member?(tree, target) when is_binary(target) do
    case chain(tree, target) do
      [%{type: type} | _] when type in [:catalogue, :category] -> true
      _ -> false
    end
  end

  def member?(_tree, _target), do: false

  @doc """
  The names from the catalogue down to `target`, read off the tree — the
  folders above the catalogue are how the admin files catalogues, not
  where the item is, so they are left out. `[]` when the tree lacks it.
  """
  @spec path_in([tree_node()], target()) :: [String.t()]
  def path_in(tree, target) do
    tree
    |> chain(target)
    |> Enum.reverse()
    |> Enum.reject(&(&1.type == :folder))
    |> Enum.map(& &1.name)
  end

  @doc "The ids of the rows above `id`, root first — what to open to show it."
  @spec ancestor_ids([tree_node()], String.t() | nil) :: [String.t()]
  def ancestor_ids(_tree, nil), do: []

  def ancestor_ids(tree, id) do
    case chain(tree, id) do
      [_self | above] -> above |> Enum.reverse() |> Enum.map(& &1.id)
      [] -> []
    end
  end

  # The row with `id` followed by its ancestors (nearest first); [] when
  # the tree has no such row.
  defp chain(nodes, id) do
    Enum.find_value(nodes, [], fn node ->
      cond do
        node.id == id ->
          [node]

        (found = chain(node.children, id)) != [] ->
          found ++ [node]

        true ->
          nil
      end
    end)
  end

  @doc """
  The tree cut down to the rows whose name contains `query` (case and
  accents ignored) and the rows above them, plus the ids to open so every
  match shows. A matching row keeps its whole subtree, closed — searching
  for a catalogue still lets the admin open it and pick a category.
  A blank query returns the tree untouched and opens nothing.
  """
  @spec filter([tree_node()], String.t()) :: {[tree_node()], [String.t()]}
  def filter(tree, query) do
    case fold(query) do
      "" -> {tree, []}
      needle -> filter_level(tree, needle)
    end
  end

  defp filter_level(nodes, needle) do
    Enum.reduce(nodes, {[], []}, &filter_node(&1, needle, &2))
  end

  # A match stays whole; otherwise a row stays only for a match below it,
  # and is opened to show it.
  defp filter_node(node, needle, {kept, open}) do
    if String.contains?(fold(node.name), needle) do
      {kept ++ [node], open}
    else
      case filter_level(node.children, needle) do
        {[], _} -> {kept, open}
        {children, below} -> {kept ++ [%{node | children: children}], [node.id | open] ++ below}
      end
    end
  end

  defp fold(text) when is_binary(text) do
    text
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
    |> String.trim()
  end

  defp fold(_text), do: ""

  @doc """
  The names from the catalogue down to `target`, read from the database —
  for the section's path before the tree has been loaded. `[]` when the
  place no longer exists.
  """
  @spec path_names(target() | nil) :: [String.t()]
  def path_names(target) do
    case parse(target) do
      {:catalogue, uuid} ->
        case Catalogue.get_catalogue(uuid) do
          nil -> []
          catalogue -> [catalogue.name]
        end

      {:category, uuid} ->
        case Catalogue.get_category(uuid) do
          nil ->
            []

          category ->
            catalogue = Catalogue.get_catalogue(category.catalogue_uuid)
            ancestors = Catalogue.list_category_ancestors(category.uuid)

            Enum.reject([catalogue && catalogue.name], &is_nil/1) ++
              Enum.map(ancestors, & &1.name) ++ [category.name]
        end

      :error ->
        []
    end
  end

  @doc """
  `{:ok, {catalogue_uuid, category_uuid | nil}}` for a target that is
  still a live place of `kind`, re-read at save time: the tree the admin
  picked from may be minutes old. `{:error, :location_gone}` otherwise.
  """
  @spec resolve(target(), String.t()) ::
          {:ok, {String.t(), String.t() | nil}} | {:error, :location_gone}
  def resolve(target, kind) do
    with {:ok, {catalogue_uuid, category_uuid}} <- place(parse(target)),
         true <- live_catalogue?(catalogue_uuid, kind) do
      {:ok, {catalogue_uuid, category_uuid}}
    else
      _ -> {:error, :location_gone}
    end
  end

  defp place({:catalogue, uuid}), do: {:ok, {uuid, nil}}

  defp place({:category, uuid}) do
    case Catalogue.get_category(uuid) do
      %{status: status, catalogue_uuid: catalogue_uuid} when status != "deleted" ->
        {:ok, {catalogue_uuid, uuid}}

      _ ->
        :error
    end
  end

  defp place(:error), do: :error

  defp live_catalogue?(uuid, kind) do
    match?(%{kind: ^kind, status: status} when status != "deleted", Catalogue.get_catalogue(uuid))
  end
end
