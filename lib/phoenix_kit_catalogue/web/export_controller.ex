defmodule PhoenixKitCatalogue.Web.ExportController do
  @moduledoc """
  Stateless controller for the catalogue export download.

  Receives `destination`, `format`, `catalogue_uuids[]`, and an optional
  `prefix_catalogue` flag as query params, builds the export in memory via
  `PhoenixKitCatalogue.Export.build/1`, and streams the result as an attachment.
  Nothing is written to disk.
  """

  use PhoenixKitWeb, :controller

  alias PhoenixKitCatalogue.Export
  alias PhoenixKitWeb.Users.Auth

  plug(Auth, :phoenix_kit_require_admin)
  # The admin gate above passes for any role that reaches the admin area.
  # The export carries every item with its prices, so it asks for what the
  # module's pages ask for: the `catalogue` permission, with the module on.
  plug(:require_catalogue_access)

  def download(conn, params) do
    prefix_catalogue = Map.get(params, "prefix_catalogue", false)
    # Hand-typed URLs: a malformed uuid is refused, not silently dropped —
    # a typo in a bookmarked link must not hand back a partial export
    # that looks complete (GLM-5.3, PR review 2026-09-13).
    requested = params |> Map.get("catalogue_uuids", []) |> List.wrap()

    catalogue_uuids =
      Enum.filter(requested, &(is_binary(&1) and match?({:ok, ^&1}, Ecto.UUID.cast(&1))))

    with {:ok, destination} <- fetch_destination(params["destination"]),
         {:ok, format} <- fetch_format(destination, params["format"]),
         :ok <- all_canonical(catalogue_uuids, requested) do
      download_export(conn, destination.key(), format, catalogue_uuids, prefix_catalogue)
    else
      {:error, message} -> conn |> put_status(400) |> text(message)
    end
  end

  defp require_catalogue_access(conn, _opts),
    do: Auth.require_module_access(conn, PhoenixKitCatalogue.module_key())

  # `Export.build/1` raises on a destination or format it does not know;
  # a URL is user input, so those are answered here as a bad request.
  defp fetch_destination(key) when is_binary(key) do
    case Export.destination_by_key(key) do
      nil -> {:error, "unknown destination"}
      destination -> {:ok, destination}
    end
  end

  defp fetch_destination(_key), do: {:error, "unknown destination"}

  defp fetch_format(destination, key) when is_binary(key) do
    case Enum.find(destination.formats(), fn {format, _label} -> Atom.to_string(format) == key end) do
      {format, _label} -> {:ok, format}
      nil -> {:error, "unknown format"}
    end
  end

  defp fetch_format(_destination, _key), do: {:error, "unknown format"}

  defp all_canonical(catalogue_uuids, requested) do
    if length(catalogue_uuids) == length(requested),
      do: :ok,
      else: {:error, "catalogue_uuids must be canonical uuids"}
  end

  defp download_export(conn, destination, format, catalogue_uuids, prefix_catalogue) do
    {filename, content, mime} =
      Export.build(%{
        destination: destination,
        format: format,
        catalogue_uuids: catalogue_uuids,
        prefix_catalogue: prefix_catalogue
      })

    send_download(conn, {:binary, IO.iodata_to_binary(content)},
      filename: filename,
      content_type: mime
    )
  end
end
