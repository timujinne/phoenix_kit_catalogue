defmodule PhoenixKitCatalogue.Web.HeaderTrail do
  @moduledoc """
  The crumbs a page under a catalogue hands core's admin header.

  Core draws `Project · Admin Panel / page_section / crumbs… / page_title`;
  a page only says where it is. Under this module the section is always
  `Catalogues` (the admin tab, linking to the landing page), the crumbs are
  every level between — the catalogue, then each category down to the one
  the page is in, and for an edit page the record itself — and the title is
  the page alone (`Edit`, `New item`). A form must show the trail the level
  page it was opened from shows, plus the record; a trail that loses a
  level is the header's one rule broken.

  `LevelSwitchers` builds the detail page's crumbs from what it has already
  loaded; this module reads the chain from the database for the pages that
  load nothing else about it.
  """

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Schemas.Category

  @doc """
  The crumbs from the catalogue down to `category` — the catalogue, its
  ancestors, then the category itself — each linking to its level page,
  named in `locale`. `[]` without a catalogue; the catalogue alone for a
  `nil` category, one that no longer exists, or one of another catalogue.
  """
  @spec place_crumbs(map() | nil, Category.t() | String.t() | nil, String.t() | nil) :: [map()]
  def place_crumbs(nil, _category, _locale), do: []

  def place_crumbs(catalogue, category, locale) do
    catalogue = Catalogue.localize_one(catalogue, locale)

    [
      %{label: catalogue.name, path: Paths.catalogue_detail(catalogue.uuid)}
      | category_crumbs(catalogue.uuid, category, locale)
    ]
  end

  @doc "The crumb for a record that has no page of its own: text, no link."
  @spec record_crumb(String.t() | nil) :: [map()]
  def record_crumb(name) when is_binary(name) and name != "", do: [%{label: name}]
  def record_crumb(_name), do: []

  defp category_crumbs(_catalogue_uuid, nil, _locale), do: []

  defp category_crumbs(catalogue_uuid, uuid, locale) when is_binary(uuid) do
    case Catalogue.get_category(uuid) do
      nil -> []
      category -> category_crumbs(catalogue_uuid, category, locale)
    end
  end

  defp category_crumbs(
         catalogue_uuid,
         %Category{catalogue_uuid: catalogue_uuid} = category,
         locale
       ) do
    category.uuid
    |> Catalogue.list_category_ancestors()
    |> Kernel.++([category])
    |> Catalogue.localize(locale)
    |> Enum.map(&%{label: &1.name, path: Paths.category_browse(catalogue_uuid, &1.uuid)})
  end

  defp category_crumbs(_catalogue_uuid, %Category{}, _locale), do: []
end
