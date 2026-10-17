defmodule PhoenixKitCatalogue.API.ListCategories do
  @moduledoc false
  # Tool `catalogue.list_categories`.

  alias PhoenixKitCatalogue.API
  alias PhoenixKitCatalogue.API.Presenter
  alias PhoenixKitCatalogue.Catalogue

  @spec call(map(), map()) :: {:ok, map()} | {:error, atom(), String.t(), map()}
  def call(input, _ctx) do
    with {:ok, catalogue} <- API.resolve_catalogue(input["catalogue_id"]) do
      categories = Catalogue.list_categories_metadata_for_catalogue(catalogue.uuid)

      {:ok,
       %{
         "catalogue_id" => catalogue.uuid,
         "categories" => tree(categories),
         "count" => length(categories)
       }}
    end
  end

  # Children grouped by parent in the order the query gave (position, name).
  # A category whose parent is not among the live ones is a root.
  defp tree(categories) do
    present = MapSet.new(categories, & &1.uuid)

    by_parent =
      Enum.group_by(categories, fn category ->
        if MapSet.member?(present, category.parent_uuid), do: category.parent_uuid, else: nil
      end)

    nodes(by_parent, nil, %{})
  end

  # `seen` stops a corrupt cycle from recursing for ever.
  defp nodes(by_parent, parent, seen) do
    by_parent
    |> Map.get(parent, [])
    |> Enum.reject(&Map.has_key?(seen, &1.uuid))
    |> Enum.map(fn category ->
      children = nodes(by_parent, category.uuid, Map.put(seen, category.uuid, true))
      Map.put(Presenter.category(category), "children", children)
    end)
  end
end
