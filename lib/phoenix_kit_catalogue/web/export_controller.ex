defmodule PhoenixKitCatalogue.Web.ExportController do
  @moduledoc """
  Stateless controller for the catalogue export download.

  Receives `destination`, `format`, `catalogue_uuids[]`, and an optional
  `prefix_catalogue` flag as query params, builds the export in memory via
  `PhoenixKitCatalogue.Export.build/1`, and streams the result as an attachment.
  Nothing is written to disk.
  """

  use PhoenixKitWeb, :controller

  plug(PhoenixKitWeb.Users.Auth, :phoenix_kit_require_admin)

  def download(conn, params) do
    destination = Map.get(params, "destination", "")
    format = Map.get(params, "format", "")
    prefix_catalogue = Map.get(params, "prefix_catalogue", false)
    # Hand-typed URLs: a malformed uuid is refused, not silently dropped —
    # a typo in a bookmarked link must not hand back a partial export
    # that looks complete (GLM-5.3, PR review 2026-09-13).
    requested = params |> Map.get("catalogue_uuids", []) |> List.wrap()

    catalogue_uuids =
      Enum.filter(requested, &(is_binary(&1) and match?({:ok, ^&1}, Ecto.UUID.cast(&1))))

    if length(catalogue_uuids) != length(requested) do
      conn |> put_status(400) |> text("catalogue_uuids must be canonical uuids")
    else
      download_export(conn, destination, format, catalogue_uuids, prefix_catalogue)
    end
  end

  defp download_export(conn, destination, format, catalogue_uuids, prefix_catalogue) do
    {filename, content, mime} =
      PhoenixKitCatalogue.Export.build(%{
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
