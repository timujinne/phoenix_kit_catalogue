defmodule PhoenixKitCatalogue.Web.InfrastructureSmokeTest do
  @moduledoc """
  Sanity check that the LiveView test infrastructure is wired up
  correctly. If any of these fail, every other LiveView test will fail
  too — fix these first.
  """
  use PhoenixKitCatalogue.LiveCase

  test "test endpoint is running" do
    config = Application.get_env(:phoenix_kit_catalogue, PhoenixKitCatalogue.Test.Endpoint)
    assert config[:secret_key_base]
  end

  test "catalogues index renders", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/en/admin/catalogues")
    assert html =~ "Catalogues"
  end
end
