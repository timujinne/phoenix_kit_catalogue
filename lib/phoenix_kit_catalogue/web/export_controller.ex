defmodule PhoenixKitCatalogue.Web.ExportController do
  @moduledoc """
  Stateless controller for the catalogue export download.

  Receives `destination`, `format`, and `catalogue_uuids[]` as query params,
  builds the export in memory via `PhoenixKitCatalogue.Export.build/1`, and
  streams the result as an attachment. Nothing is written to disk.
  """

  use PhoenixKitWeb, :controller

  plug(PhoenixKitWeb.Users.Auth, :phoenix_kit_require_admin)

  def download(conn, params) do
    destination = Map.get(params, "destination", "")
    format = Map.get(params, "format", "")
    catalogue_uuids = Map.get(params, "catalogue_uuids", [])

    {filename, content, _mime} =
      PhoenixKitCatalogue.Export.build(%{
        destination: destination,
        format: format,
        catalogue_uuids: catalogue_uuids
      })

    send_download(conn, {:binary, IO.iodata_to_binary(content)}, filename: filename)
  end
end
