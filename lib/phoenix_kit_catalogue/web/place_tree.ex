defmodule PhoenixKitCatalogue.Web.PlaceTree do
  @moduledoc """
  The trees a place picker (core's `PhoenixKitWeb.Components.TreePicker`)
  offers in the catalogue. No list of places is shown flat: a category is
  picked under its parent, a catalogue under its folder (the owner, via
  Max, 2026-09-21: "no flat lists anywhere, only proper pickers").

  Nodes are core `PhoenixKit.Utils.Tree` nodes, shown by core's
  `PhoenixKitWeb.Components.TreePicker`: `%{id, type, name, icon,
  archived?, children}` plus an optional `:hint` (e.g. "top level" beside a
  catalogue row that stands for its own top level) and a `:badge` on an
  archived catalogue. Ids say what they are — `"folder:<uuid>"`,
  `"catalogue:<uuid>"`, `"category:<uuid>"` — and `"root"` is the level
  above every folder.

  The builders read the database; the pure operations are core's `Tree`.
  """

  alias PhoenixKit.Utils.Tree
  alias PhoenixKitCatalogue.Catalogue

  @type node_type :: :root | :folder | :catalogue | :category

  @type tree_node :: %{
          required(:id) => String.t(),
          required(:type) => node_type(),
          required(:name) => String.t(),
          required(:icon) => String.t(),
          required(:archived?) => boolean(),
          required(:children) => [tree_node()],
          optional(:hint) => String.t(),
          optional(:badge) => String.t()
        }

  @doc "The id of the level above every folder."
  @spec root_id() :: String.t()
  defdelegate root_id, to: Tree

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
    |> Tree.map_nodes(fn node ->
      if hint && node.type == :catalogue, do: Map.put(node, :hint, hint), else: node
    end)
  end

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
        [root_node(catalogue.name, nodes, hint: hint)]
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

    [root_node(root_name, folder_level(nil, children))]
  end

  defp root_node(name, children, opts \\ []),
    do: name |> Tree.root(children, opts) |> Map.put(:archived?, false)

  defp folder_level(parent_uuid, children) do
    for folder <- Map.get(children, parent_uuid, []),
        do: folder_node(folder, folder_level(folder.uuid, children))
  end

  defp folder_node(folder, children) do
    %{
      id: "folder:" <> folder.uuid,
      type: :folder,
      name: folder.name,
      icon: "hero-folder",
      archived?: false,
      children: children
    }
  end

  defp catalogue_node(catalogue, children) do
    node = %{
      id: "catalogue:" <> catalogue.uuid,
      type: :catalogue,
      name: catalogue.name,
      icon: "hero-book-open",
      archived?: catalogue.status == "archived",
      children: children
    }

    if node.archived?,
      do: Map.put(node, :badge, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Archived")),
      else: node
  end

  # A category whose parent is not among the live ones is a root here, and
  # a corrupt parent cycle cannot loop (`Tree.from_flat/2`).
  defp category_nodes(categories) do
    Tree.from_flat(categories,
      id: &("category:" <> &1.uuid),
      parent: &(&1.parent_uuid && "category:" <> &1.parent_uuid),
      node: &%{type: :category, name: &1.name, icon: "hero-rectangle-stack", archived?: false}
    )
  end

  # ── Pure operations (core's Tree) ──────────────────────────────────

  @doc "See `PhoenixKit.Utils.Tree.prune/2`."
  @spec prune([tree_node()], [String.t()]) :: [tree_node()]
  defdelegate prune(tree, ids), to: Tree

  @doc "See `PhoenixKit.Utils.Tree.find/2`."
  @spec find([tree_node()], term()) :: tree_node() | nil
  defdelegate find(tree, id), to: Tree

  @doc "See `PhoenixKit.Utils.Tree.member?/3`."
  @spec member?([tree_node()], term(), [atom()] | :all) :: boolean()
  defdelegate member?(tree, id, types), to: Tree

  @doc "See `PhoenixKit.Utils.Tree.path/3`."
  @spec path_in([tree_node()], term(), [atom()]) :: [String.t()]
  defdelegate path_in(tree, id, skip \\ []), to: Tree, as: :path

  @doc "See `PhoenixKit.Utils.Tree.ancestor_ids/2`."
  @spec ancestor_ids([tree_node()], term()) :: [String.t()]
  defdelegate ancestor_ids(tree, id), to: Tree

  @doc "See `PhoenixKit.Utils.Tree.filter/2`."
  @spec filter([tree_node()], String.t()) :: {[tree_node()], [String.t()]}
  defdelegate filter(tree, query), to: Tree

  @doc "See `PhoenixKit.Utils.Tree.ids_of/2`."
  @spec ids_of([tree_node()], [atom()] | :all) :: [String.t()]
  defdelegate ids_of(tree, types), to: Tree

  @doc """
  What a picker posts for a typed id: the bare uuid, or `""` for `"root"`
  (no parent, no folder) — pass as `TreePicker`'s `post`.
  """
  @spec post(String.t()) :: String.t()
  def post(id), do: uuid(id) || ""

  @doc "The uuid inside a typed id; `nil` for `\"root\"` or anything else."
  @spec uuid(term()) :: String.t() | nil
  def uuid("folder:" <> uuid) when uuid != "", do: uuid
  def uuid("catalogue:" <> uuid) when uuid != "", do: uuid
  def uuid("category:" <> uuid) when uuid != "", do: uuid
  def uuid(_id), do: nil
end
