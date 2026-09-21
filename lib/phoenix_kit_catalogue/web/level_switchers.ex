defmodule PhoenixKitCatalogue.Web.LevelSwitchers do
  @moduledoc """
  The level switchers in the catalogue detail page's admin header (boss,
  2026-09-19: "like in GitHub"): a ▾ beside the catalogue and beside each
  category of the trail opens a searchable list of the other things on
  that level — every catalogue, or that category's siblings — and picking
  one switches to it.

  Pure: builds the maps core's header renders — a `page_crumbs` entry's
  `:switcher` and `page_title_switcher` — from what the page has already
  loaded. A core older than the switcher ignores both, so the header
  renders exactly as before.

  A level with nothing to switch to (a category with no siblings) gets no
  switcher: a ▾ that lists only the current row would be noise.
  """
  use Gettext, backend: PhoenixKitCatalogue.Gettext

  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Schemas.Category

  @typedoc """
  What the page knows: every catalogue the switcher offers (in the index's
  order), the catalogue's live categories grouped by `parent_uuid` (`nil`
  for the top level), and whether the Uncategorized bucket holds anything
  — it sits beside the top-level categories the way the tree shows it.
  """
  @type context :: %{
          catalogues: [map()],
          siblings: %{(String.t() | nil) => [Category.t()]},
          uncategorized?: boolean()
        }

  @doc """
  The drill trail's crumbs — the catalogue, then each ancestor category —
  each with the switcher for its own level. Empty at the catalogue root,
  where the catalogue is the page title instead.
  """
  @spec crumbs(map() | nil, Category.t() | :uncategorized | nil, [Category.t()], context()) ::
          [map()]
  def crumbs(nil, _current, _trail, _ctx), do: []
  def crumbs(_catalogue, nil, _trail, _ctx), do: []

  def crumbs(catalogue, _current, trail, ctx) do
    [
      crumb(
        %{label: catalogue.name, path: Paths.catalogue_detail(catalogue.uuid)},
        catalogue_switcher(catalogue.uuid, ctx)
      )
      | Enum.map(trail, fn cat ->
          crumb(
            %{label: cat.name, path: Paths.category_browse(catalogue.uuid, cat.uuid)},
            category_switcher(catalogue.uuid, cat.parent_uuid, cat.uuid, ctx)
          )
        end)
    ]
  end

  @doc """
  The switcher for the page title: the catalogues at the root, the current
  category's siblings when drilled, the top level's for Uncategorized.
  """
  @spec title(map() | nil, Category.t() | :uncategorized | nil, context()) :: map() | nil
  def title(nil, _current, _ctx), do: nil
  def title(catalogue, nil, ctx), do: catalogue_switcher(catalogue.uuid, ctx)

  def title(catalogue, :uncategorized, ctx),
    do: category_switcher(catalogue.uuid, nil, :uncategorized, ctx)

  def title(catalogue, %Category{} = cat, ctx),
    do: category_switcher(catalogue.uuid, cat.parent_uuid, cat.uuid, ctx)

  defp crumb(crumb, nil), do: crumb
  defp crumb(crumb, switcher), do: Map.put(crumb, :switcher, switcher)

  defp catalogue_switcher(current_uuid, ctx) do
    items =
      for c <- ctx.catalogues do
        %{
          label: c.name,
          navigate: Paths.catalogue_detail(c.uuid),
          current: c.uuid == current_uuid
        }
      end

    switcher(gettext("Switch catalogue"), gettext("Search catalogues…"), items)
  end

  # `current` is the category's uuid, or :uncategorized for the bucket.
  defp category_switcher(catalogue_uuid, parent_uuid, current, ctx) do
    categories =
      for cat <- Map.get(ctx.siblings, parent_uuid, []) do
        %{
          label: cat.name,
          patch: Paths.category_browse(catalogue_uuid, cat.uuid),
          current: cat.uuid == current
        }
      end

    items =
      if is_nil(parent_uuid) and (ctx.uncategorized? or current == :uncategorized) do
        categories ++
          [
            %{
              label: gettext("Uncategorized"),
              patch: Paths.uncategorized_browse(catalogue_uuid),
              current: current == :uncategorized
            }
          ]
      else
        categories
      end

    switcher(gettext("Switch category"), gettext("Search categories…"), items)
  end

  defp switcher(_title, _placeholder, items) when length(items) < 2, do: nil

  defp switcher(title, placeholder, items),
    do: %{title: title, search_placeholder: placeholder, items: items}
end
