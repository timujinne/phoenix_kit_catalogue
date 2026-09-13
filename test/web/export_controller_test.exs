defmodule PhoenixKitCatalogue.Web.ExportControllerTest do
  @moduledoc """
  A hand-edited export URL with a malformed uuid is refused, not partially
  served (PR review, 2026-09-13). The action is called directly: the test
  router does not mount the host-injected download route, and the admin
  plug it carries is the host's concern.
  """
  use PhoenixKitCatalogue.DataCase, async: false

  import Phoenix.ConnTest, only: [build_conn: 0]
  import PhoenixKitCatalogue.LiveCase, only: [fixture_catalogue: 1]

  alias PhoenixKitCatalogue.Web.ExportController

  defp download(params), do: ExportController.download(build_conn(), params)

  test "a malformed catalogue uuid is a 400" do
    conn =
      download(%{"destination" => "universal", "format" => "json", "catalogue_uuids" => ["typo"]})

    assert conn.status == 400
    assert conn.resp_body =~ "canonical"
  end

  test "a bare string instead of a list is a 400 too" do
    conn =
      download(%{"destination" => "universal", "format" => "json", "catalogue_uuids" => "abc"})

    assert conn.status == 400
  end

  test "canonical uuids download" do
    catalogue = fixture_catalogue(%{name: "Export Cat"})

    conn =
      download(%{
        "destination" => "universal",
        "format" => "json",
        "catalogue_uuids" => [catalogue.uuid]
      })

    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "content-disposition") != []
  end
end
