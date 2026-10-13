defmodule PhoenixKitCatalogue.Web.ExportControllerTest do
  @moduledoc """
  A hand-edited export URL with a malformed uuid is refused, not partially
  served (PR review, 2026-09-13). The first tests call the action directly;
  "who may download" runs the controller's own plug pipeline, since the
  test router does not mount the host-injected download route.
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

  describe "who may download" do
    alias PhoenixKit.Users.Auth.Scope
    alias PhoenixKit.Users.Auth.User

    setup do
      # Core answers "is this module on" from its registry, which a host
      # fills at boot; the teardown has already stopped the registry by the
      # time `on_exit` runs, so the module is dropped from the term it reads.
      start_supervised!(PhoenixKit.ModuleRegistry)
      :ok = PhoenixKit.ModuleRegistry.register(PhoenixKitCatalogue)

      on_exit(fn ->
        :persistent_term.put(
          {PhoenixKit, :registered_modules},
          List.delete(PhoenixKit.ModuleRegistry.all_modules(), PhoenixKitCatalogue)
        )
      end)

      {:ok, _} = PhoenixKit.Settings.update_boolean_setting("catalogue_enabled", true)
      %{catalogue: fixture_catalogue(%{name: "Gated Export Cat"})}
    end

    # A role that reaches the admin area through `permissions`, the way a
    # custom role does.
    defp scope_with(permissions) do
      %Scope{
        user: %User{
          uuid: UUIDv7.generate(),
          email: "export-gate@example.com",
          confirmed_at: DateTime.utc_now()
        },
        authenticated?: true,
        cached_roles: ["Clerk"],
        cached_permissions: MapSet.new(permissions)
      }
    end

    defp request(scope, params) do
      Phoenix.ConnTest.build_conn(:get, "/admin/catalogues/export/download", params)
      |> Plug.Test.init_test_session(%{})
      |> Phoenix.Controller.fetch_flash()
      |> Plug.Conn.assign(:phoenix_kit_current_scope, scope)
      |> ExportController.call(ExportController.init(:download))
    end

    defp valid(catalogue),
      do: %{
        "destination" => "universal",
        "format" => "json",
        "catalogue_uuids" => [catalogue.uuid]
      }

    defp requests(catalogue) do
      [
        valid: valid(catalogue),
        bad_destination: %{valid(catalogue) | "destination" => "nowhere"},
        nested_destination: %{valid(catalogue) | "destination" => %{"a" => "1"}},
        missing_destination: Map.delete(valid(catalogue), "destination"),
        bad_format: %{valid(catalogue) | "format" => "exe"},
        other_destinations_format: %{valid(catalogue) | "format" => "furniture"},
        nested_format: %{valid(catalogue) | "format" => ["json"]},
        bad_uuid: %{valid(catalogue) | "catalogue_uuids" => ["typo"]}
      ]
    end

    test "with the catalogue permission: the valid request downloads, each bad one is a 400",
         %{catalogue: catalogue} do
      for {name, params} <- requests(catalogue) do
        conn = request(scope_with(["catalogue"]), params)

        if name == :valid do
          assert conn.status == 200, "valid: #{conn.status}"
          assert conn.resp_body =~ "Gated Export Cat"
        else
          assert conn.status == 400, "#{name}: #{conn.status}"
          assert Plug.Conn.get_resp_header(conn, "content-disposition") == []
        end
      end
    end

    test "an admin-area role without the catalogue permission gets nothing, whatever it asks",
         %{catalogue: catalogue} do
      for {name, params} <- requests(catalogue) do
        conn = request(scope_with(["users"]), params)

        assert conn.halted, "#{name} was served"
        assert conn.status == 302, "#{name}: #{conn.status}"
        refute conn.resp_body =~ "Gated Export Cat"
        assert Plug.Conn.get_resp_header(conn, "content-disposition") == []
      end
    end

    test "with the module disabled even a permitted role gets nothing", %{catalogue: catalogue} do
      {:ok, _} = PhoenixKit.Settings.update_boolean_setting("catalogue_enabled", false)

      for {name, params} <- requests(catalogue) do
        conn = request(scope_with(["catalogue"]), params)

        assert conn.halted, "#{name} was served"
        assert conn.status == 302, "#{name}: #{conn.status}"
        refute conn.resp_body =~ "Gated Export Cat"
      end
    end

    test "a signed-out visitor is sent to log in", %{catalogue: catalogue} do
      conn = request(Scope.for_user(nil), valid(catalogue))

      assert conn.halted
      assert conn.status == 302
      assert conn |> Plug.Conn.get_resp_header("location") |> hd() =~ "log-in"
    end
  end
end
