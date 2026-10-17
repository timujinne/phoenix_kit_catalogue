defmodule PhoenixKitCatalogue.API.CatalogueScope do
  @moduledoc false
  # Which catalogue a shop API tool works in; see
  # `PhoenixKitCatalogue.API.resolve_catalogue/2`.

  alias PhoenixKitCatalogue.API.Common
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Schemas.Catalogue, as: CatalogueSchema

  @type result :: {:ok, CatalogueSchema.t()} | {:error, atom(), String.t(), map()}

  @spec resolve(term(), keyword()) :: result()
  def resolve(catalogue_id, opts \\ [])

  def resolve(nil, opts) do
    case Keyword.get(opts, :default_uuid) do
      uuid when is_binary(uuid) -> resolve(uuid, opts)
      _none -> autodetect()
    end
  end

  def resolve(id, opts) when is_binary(id) do
    case Catalogue.get_catalogue(id) do
      nil ->
        not_found(id)

      %CatalogueSchema{status: "deleted"} ->
        not_found(id)

      %CatalogueSchema{kind: kind} when kind != "standard" ->
        Common.invalid("catalogue_id", "Smart catalogues are not available through the API.")

      %CatalogueSchema{} = catalogue ->
        check_writable(catalogue, Keyword.get(opts, :writable, false))
    end
  end

  def resolve(_other, _opts), do: Common.invalid("catalogue_id", "must be a catalogue UUID")

  defp check_writable(%CatalogueSchema{status: "active"} = catalogue, _writable) do
    {:ok, catalogue}
  end

  defp check_writable(catalogue, false), do: {:ok, catalogue}

  defp check_writable(_catalogue, true) do
    Common.invalid("catalogue_id", "The catalogue is archived: it can be read but not changed.")
  end

  defp autodetect do
    case Catalogue.list_catalogues(status: "active", kind: :standard) do
      [only] ->
        {:ok, only}

      [] ->
        Common.invalid("catalogue_id", "There is no active catalogue.", [])

      many ->
        Common.invalid(
          "catalogue_id",
          "catalogue_id is required: this install has #{length(many)} active catalogues.",
          Enum.map(many, & &1.uuid)
        )
    end
  end

  defp not_found(id) do
    {:error, :not_found, "No catalogue has this id.", %{catalogue_id: String.slice(id, 0, 100)}}
  end
end
