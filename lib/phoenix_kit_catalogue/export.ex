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

  alias PhoenixKitCatalogue.Catalogue
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

  Returns `{filename, iodata, mime_type}`.

  Raises `ArgumentError` if the destination or format is not recognised, or if
  `catalogue_uuids` is nil/missing.
  """
  @spec build(map()) :: {String.t(), iodata(), String.t()}
  def build(%{destination: destination_key, format: format_key} = params) do
    catalogue_uuids = Map.get(params, :catalogue_uuids, [])

    destination_mod =
      destination_by_key(to_atom(destination_key)) ||
        raise ArgumentError, "unknown export destination: #{inspect(destination_key)}"

    format_atom = to_atom(format_key)

    unless Enum.any?(destination_mod.formats(), fn {k, _} -> k == format_atom end) do
      raise ArgumentError,
            "unknown format #{inspect(format_key)} for destination #{inspect(destination_mod.key())}"
    end

    items = list_export_items(catalogue_uuids)
    catalogues = Enum.map(catalogue_uuids, &Catalogue.get_catalogue!/1)

    ctx = %{
      items: items,
      index: System.os_time(:second),
      catalogues: catalogues
    }

    destination_mod.render(format_atom, ctx)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp to_atom(value) when is_atom(value), do: value
  defp to_atom(value) when is_binary(value), do: String.to_existing_atom(value)
end
