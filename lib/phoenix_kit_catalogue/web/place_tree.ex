defmodule PhoenixKitCatalogue.Web.PlaceTree do
  @moduledoc """
  The trees a place picker (`Web.PlacePicker`) offers, and the pure
  operations over them. No list of places is shown flat: a category is
  picked under its parent, a catalogue under its folder (the owner, via
  Max, 2026-09-21: "no flat lists anywhere, only proper pickers").

  A node is `%{id, type, name, archived?, children}` plus an optional
  `:hint` (e.g. "top level" beside a catalogue row that stands for its own
  top level). Ids say what they are — `"folder:<uuid>"`,
  `"catalogue:<uuid>"`, `"category:<uuid>"` — and `"root"` is the level
  above every folder.

  The builders read the database; the rest is pure.
  """

  alias PhoenixKitCatalogue.Catalogue

  @type node_type :: :root | :folder | :catalogue | :category

  @type tree_node :: %{
          required(:id) => String.t(),
          required(:type) => node_type(),
          required(:name) => String.t(),
          required(:archived?) => boolean(),
          required(:children) => [tree_node()],
          optional(:hint) => String.t()
        }

  @root "root"

  @doc "The id of the level above every folder."
  @spec root_id() :: String.t()
  def root_id, do: @root

  # ── Builders ────────────────────────────────────────────────────────

  @doc """
  Folders › catalogues › categories › subcategories. `kind` (`"standard"`
  | `"smart"`) keeps only catalogues of that kind; `nil` keeps all. A
  folder shows only when it leads to a catalogue. Trashed rows are left
  out, and a row whose parent is trashed moves up to the nearest live
  level rather than vanishing, as on the index and the catalogue page.

  ## Options

    * `:categories` — `false` stops at the catalogues (default `true`)
    * `:catalogue_hint` — shown beside every catalogue row, saying what
      picking the catalogue itself means ("top level", "uncategorized")
    * `:locale` — names in that language, as the page shows them
  """
  @spec places(String.t() | nil, keyword()) :: [tree_node()]
  def places(kind, opts \\ []) do
    locale = Keyword.get(opts, :locale)

    by_folder =
      Map.new(Catalogue.catalogues_by_folder(), fn {folder_uuid, catalogues} ->
        {folder_uuid,
         catalogues
         |> Enum.filter(&(is_nil(kind) or &1.kind == kind))
         |> Catalogue.localize(locale)}
      end)

    categories =
      if Keyword.get(opts, :categories, true) do
        by_folder
        |> Map.values()
        |> List.flatten()
        |> Enum.map(& &1.uuid)
        |> Catalogue.list_live_categories()
        |> Catalogue.localize(locale)
        |> Enum.group_by(& &1.catalogue_uuid)
      else
        %{}
      end

    folder_children =
      Catalogue.list_folder_tree()
      |> Enum.map(&elem(&1, 0))
      |> Enum.group_by(& &1.parent_uuid)

    hint = Keyword.get(opts, :catalogue_hint)

    place_level(nil, folder_children, by_folder, categories)
    |> map_nodes(fn node ->
      if hint && node.type == :catalogue, do: Map.put(node, :hint, hint), else: node
    end)
  end

  defp map_nodes(nodes, fun),
    do: Enum.map(nodes, fn node -> fun.(%{node | children: map_nodes(node.children, fun)}) end)

  defp place_level(folder_uuid, folder_children, by_folder, categories) do
    folders =
      folder_children
      |> Map.get(folder_uuid, [])
      |> Enum.map(fn folder ->
        folder_node(folder, place_level(folder.uuid, folder_children, by_folder, categories))
      end)
      |> Enum.reject(&(&1.children == []))

    catalogues =
      for catalogue <- Map.get(by_folder, folder_uuid, []) do
        catalogue_node(catalogue, category_nodes(Map.get(categories, catalogue.uuid, [])))
      end

    folders ++ catalogues
  end

  @doc """
  One catalogue's categories. With `root: hint` they hang under a `"root"`
  row named after the catalogue, which stands for its top level (the hint
  says so beside the name) — no parent, no category; without, the
  categories are the roots. `:locale` names them in that language.
  """
  @spec categories(map(), keyword()) :: [tree_node()]
  def categories(%{uuid: uuid} = catalogue, opts \\ []) do
    locale = Keyword.get(opts, :locale)
    catalogue = Catalogue.localize_one(catalogue, locale)

    nodes =
      [uuid]
      |> Catalogue.list_live_categories()
      |> Catalogue.localize(locale)
      |> category_nodes()

    case Keyword.get(opts, :root) do
      nil ->
        nodes

      hint ->
        [
          %{
            id: @root,
            type: :root,
            name: catalogue.name,
            hint: hint,
            archived?: false,
            children: nodes
          }
        ]
    end
  end

  @doc """
  Every live folder, nested, under the `"root"` row named `root_name` —
  the level no folder files a catalogue in.
  """
  @spec folders(String.t()) :: [tree_node()]
  def folders(root_name) do
    children =
      Catalogue.list_folder_tree()
      |> Enum.map(&elem(&1, 0))
      |> Enum.group_by(& &1.parent_uuid)

    [
      %{
        id: @root,
        type: :root,
        name: root_name,
        archived?: false,
        children: folder_level(nil, children)
      }
    ]
  end

  defp folder_level(parent_uuid, children) do
    for folder <- Map.get(children, parent_uuid, []),
        do: folder_node(folder, folder_level(folder.uuid, children))
  end

  defp folder_node(folder, children) do
    %{
      id: "folder:" <> folder.uuid,
      type: :folder,
      name: folder.name,
      archived?: false,
      children: children
    }
  end

  defp catalogue_node(catalogue, children) do
    %{
      id: "catalogue:" <> catalogue.uuid,
      type: :catalogue,
      name: catalogue.name,
      archived?: catalogue.status == "archived",
      children: children
    }
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

  # ── Pure operations ─────────────────────────────────────────────────

  @doc """
  The tree without the rows in `ids` and everything under them — a
  category cannot move into its own subtree, a folder into itself.
  """
  @spec prune([tree_node()], [String.t()]) :: [tree_node()]
  def prune(tree, []), do: tree

  def prune(tree, ids) do
    drop = MapSet.new(ids)

    for node <- tree,
        not MapSet.member?(drop, node.id),
        do: %{node | children: prune(node.children, ids)}
  end

  @doc "The row with `id`, or nil."
  @spec find([tree_node()], term()) :: tree_node() | nil
  def find(tree, id) when is_binary(id) do
    case chain(tree, id) do
      [node | _] -> node
      [] -> nil
    end
  end

  def find(_tree, _id), do: nil

  @doc "Whether the tree offers `id` as a row of one of `types`."
  @spec member?([tree_node()], term(), [node_type()]) :: boolean()
  def member?(tree, id, types) do
    case find(tree, id) do
      %{type: type} -> type in types
      nil -> false
    end
  end

  @doc """
  The names from the top down to `id`. `skip` leaves rows of those types
  out — the folders above a catalogue are how catalogues are filed, not
  where a category is. `[]` when the tree lacks it.
  """
  @spec path_in([tree_node()], term(), [node_type()]) :: [String.t()]
  def path_in(tree, id, skip \\ [])

  def path_in(tree, id, skip) when is_binary(id) do
    tree
    |> chain(id)
    |> Enum.reverse()
    |> Enum.reject(&(&1.type in skip))
    |> Enum.map(& &1.name)
  end

  def path_in(_tree, _id, _skip), do: []

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

  @doc "Every id in the tree whose row is one of `types`."
  @spec ids_of([tree_node()], [node_type()]) :: [String.t()]
  def ids_of(tree, types) do
    Enum.flat_map(tree, fn node ->
      own = if node.type in types, do: [node.id], else: []
      own ++ ids_of(node.children, types)
    end)
  end

  @doc "The uuid inside a typed id; `nil` for `\"root\"` or anything else."
  @spec uuid(term()) :: String.t() | nil
  def uuid("folder:" <> uuid) when uuid != "", do: uuid
  def uuid("catalogue:" <> uuid) when uuid != "", do: uuid
  def uuid("category:" <> uuid) when uuid != "", do: uuid
  def uuid(_id), do: nil
end
