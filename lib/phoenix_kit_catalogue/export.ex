defmodule PhoenixKitCatalogue.Export do
  @moduledoc """
  Export context for the Catalogue module.

  Drives the Export tab: registry of destinations, item selection, and
  in-memory file generation. Nothing is persisted to disk.

  ## Usage

      destinations = Export.destinations()
      items        = Export.list_export_items(catalogue_uuids)

      {filename, content, mime} = Export.build(%{
        destination: :pro100,
        format: :furniture,
        catalogue_uuids: [uuid1, uuid2]
      })
  """

  import Ecto.Query, warn: false

  alias PhoenixKitCatalogue.Schemas.{Category, Item}

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ---------------------------------------------------------------------------
  # Destination registry
  # ---------------------------------------------------------------------------

  @destinations [PhoenixKitCatalogue.Export.Pro100, PhoenixKitCatalogue.Export.Universal]

  @doc """
  Returns the list of registered export destination modules.
  Each element implements `PhoenixKitCatalogue.Export.Destination`.
  """
  @spec destinations() :: [module()]
  def destinations, do: @destinations

  @doc """
  Finds a destination module by its atom key, or `nil` if not found.
  """
  @spec destination_by_key(atom() | String.t()) :: module() | nil
  def destination_by_key(key) when is_atom(key) do
    Enum.find(@destinations, fn mod -> mod.key() == key end)
  end

  def destination_by_key(key) when is_binary(key) do
    atom_key = String.to_existing_atom(key)
    destination_by_key(atom_key)
  rescue
    ArgumentError -> nil
  end

  # ---------------------------------------------------------------------------
  # Item selection
  # ---------------------------------------------------------------------------

  @doc """
  Lists non-deleted items for export across one or more catalogues.

  Returns all active items where `catalogue_uuid in ^catalogue_uuids` and
  `status != "deleted"`, ordered by catalogue, then category position, then
  item position, then name. The `:catalogue` and `:category` associations are
  preloaded on every item.

  Returns `[]` when `catalogue_uuids` is empty.
  """
  @spec list_export_items([Ecto.UUID.t()]) :: [Item.t()]
  def list_export_items(catalogue_uuids) when is_list(catalogue_uuids) do
    if catalogue_uuids == [] do
      []
    else
      from(i in Item,
        left_join: c in Category,
        on: i.category_uuid == c.uuid,
        where:
          i.catalogue_uuid in ^catalogue_uuids and
            i.status != "deleted",
        order_by: [
          asc: i.catalogue_uuid,
          asc_nulls_last: c.position,
          asc: i.position,
          asc: i.name
        ],
        preload: [:catalogue, :category]
      )
      |> repo().all()
    end
  end

  # ---------------------------------------------------------------------------
  # Build
  # ---------------------------------------------------------------------------

  @doc """
  Builds the export file in memory.

  `params` is a map with keys:
  - `:destination` — atom or string destination key (e.g. `:pro100` or `"pro100"`)
  - `:format` — atom or string format key (e.g. `:furniture` or `"furniture"`)
  - `:catalogue_uuids` — list of catalogue UUIDs to export
  - `:prefix_catalogue` — optional; when truthy, PRO100 text formats prefix each
    item name with its catalogue name (`"<catalogue> / <item>"`). Default false.

  Returns `{filename, iodata, mime_type}`.

  Raises `ArgumentError` if the destination or format is not recognised, or if
  `catalogue_uuids` is nil/missing.
  """
  @spec build(map()) :: {String.t(), iodata(), String.t()}
  def build(%{destination: destination_key, format: format_key} = params) do
    catalogue_uuids = Map.get(params, :catalogue_uuids, [])
    prefix_catalogue = Map.get(params, :prefix_catalogue, false) in [true, "true", "on", "1"]

    destination_mod =
      destination_by_key(destination_key) ||
        raise ArgumentError, "unknown export destination: #{inspect(destination_key)}"

    format_atom = safe_atom(format_key)

    unless format_atom && Enum.any?(destination_mod.formats(), fn {k, _} -> k == format_atom end) do
      raise ArgumentError,
            "unknown format #{inspect(format_key)} for destination #{inspect(destination_mod.key())}"
    end

    items = list_export_items(catalogue_uuids)
    catalogues = list_catalogue_headers(catalogue_uuids)

    ctx = %{
      items: items,
      index: System.os_time(:second),
      catalogues: catalogues,
      prefix_catalogue: prefix_catalogue
    }

    destination_mod.render(format_atom, ctx)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp safe_atom(value) when is_atom(value), do: value

  defp safe_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  # Lightweight catalogue headers (uuid + name only) for the export context.
  # Avoids Catalogue.get_catalogue!/1, which preloads the whole category+item
  # tree per catalogue — items are already loaded by list_export_items/1.
  defp list_catalogue_headers(catalogue_uuids) do
    from(c in PhoenixKitCatalogue.Schemas.Catalogue,
      where: c.uuid in ^catalogue_uuids,
      order_by: c.name,
      select: %{uuid: c.uuid, name: c.name}
    )
    |> repo().all()
  end
end
