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
  alias PhoenixKitCatalogue.Web.PlaceTree

  @type target :: String.t()

  @type tree_node :: PlaceTree.tree_node()

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
  holding its category tree — `PlaceTree.places/2`, its names in
  `locale` (nil keeps the stored ones).
  """
  @spec tree(String.t(), String.t() | nil) :: [tree_node()]
  def tree(kind, locale \\ nil), do: PlaceTree.places(kind, locale: locale)

  @doc "Whether `target` is a place the tree offers (a catalogue or category row)."
  @spec member?([tree_node()], term()) :: boolean()
  def member?(tree, target), do: PlaceTree.member?(tree, target, [:catalogue, :category])

  @doc """
  The names from the catalogue down to `target`, read off the tree — the
  folders above the catalogue are how the admin files catalogues, not
  where the item is, so they are left out. `[]` when the tree lacks it.
  """
  @spec path_in([tree_node()], target()) :: [String.t()]
  def path_in(tree, target), do: PlaceTree.path_in(tree, target, [:folder])

  @doc "The ids of the rows above `id`, root first — what to open to show it."
  @spec ancestor_ids([tree_node()], String.t() | nil) :: [String.t()]
  defdelegate ancestor_ids(tree, id), to: PlaceTree

  @doc "See `PlaceTree.filter/2`."
  @spec filter([tree_node()], String.t()) :: {[tree_node()], [String.t()]}
  defdelegate filter(tree, query), to: PlaceTree

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
