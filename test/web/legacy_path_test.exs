defmodule PhoenixKitCatalogue.Web.LegacyPathTest do
  @moduledoc """
  The module's pages moved from `/admin/catalogue` to `/admin/catalogues`.
  What still points at the old address — bookmarks, sent mail, the activity
  log, sibling modules released before the change — has to keep landing.
  """
  use ExUnit.Case, async: false

  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Web.LegacyPathController, as: Legacy
  alias PhoenixKitCatalogue.Web.Routes

  # Core caches the configured admin segment.
  defp flush_admin_path_cache, do: PhoenixKit.Config.clear_admin_path_cache()

  describe "target/2" do
    test "the landing page, with and without a prefix and a locale" do
      assert Legacy.target("/admin/catalogue") == {:ok, "/admin/catalogues"}

      assert Legacy.target("/phoenix_kit/admin/catalogue") ==
               {:ok, "/phoenix_kit/admin/catalogues"}

      assert Legacy.target("/phoenix_kit/et/admin/catalogue") ==
               {:ok, "/phoenix_kit/et/admin/catalogues"}
    end

    test "everything after the segment carries over" do
      assert Legacy.target("/en/admin/catalogue/items/abc/edit") ==
               {:ok, "/en/admin/catalogues/items/abc/edit"}

      assert Legacy.target("/admin/catalogue/abc", "category=def&q=oak") ==
               {:ok, "/admin/catalogues/abc?category=def&q=oak"}
    end

    test "the settings page" do
      assert Legacy.target("/phoenix_kit/en/admin/settings/catalogue") ==
               {:ok, "/phoenix_kit/en/admin/settings/catalogues"}
    end

    test "only the whole segment moves, and only once" do
      assert Legacy.target("/admin/catalogue/x/admin/catalogue") ==
               {:ok, "/admin/catalogues/x/admin/catalogue"}

      assert Legacy.target("/admin/catalogue/x/admin/settings/catalogue", "q=1") ==
               {:ok, "/admin/catalogues/x/admin/settings/catalogue?q=1"}

      assert Legacy.target("/admin/settings/catalogue/x/admin/catalogue") ==
               {:ok, "/admin/settings/catalogues/x/admin/catalogue"}
    end

    # The answer that would otherwise be a redirect to the same address.
    test "an address that is not an old one is unchanged" do
      assert Legacy.target("/admin/catalogues/abc") == :unchanged
      assert Legacy.target("/admin/catalogue-old") == :unchanged
      assert Legacy.target("/admin/settings/catalogues") == :unchanged
      assert Legacy.target("/admin/settings/catalogue-x") == :unchanged
      assert Legacy.target("/somewhere/else", "q=1") == :unchanged
    end
  end

  # Core rewrites every `/admin…` route to the host's configured segment, so
  # on such a host the old address arrives wearing the new name. Matching the
  # literal `/admin/catalogue` there found nothing and redirected the request
  # to itself — a permanent redirect, so browsers cached the loop.
  describe "a host that renamed the admin area" do
    setup do
      previous = Application.get_env(:phoenix_kit, :admin_path)
      Application.put_env(:phoenix_kit, :admin_path, "/backoffice")
      flush_admin_path_cache()

      on_exit(fn ->
        if previous,
          do: Application.put_env(:phoenix_kit, :admin_path, previous),
          else: Application.delete_env(:phoenix_kit, :admin_path)

        flush_admin_path_cache()
      end)

      # Proof the rename took, or the tests below pass for the wrong reason.
      assert PhoenixKit.Utils.Routes.apply_admin_segment("/admin/x") == "/backoffice/x"
      :ok
    end

    test "the old address under the renamed segment moves" do
      assert Legacy.target("/phoenix_kit/en/backoffice/catalogue/abc", "q=1") ==
               {:ok, "/phoenix_kit/en/backoffice/catalogues/abc?q=1"}

      assert Legacy.target("/backoffice/settings/catalogue") ==
               {:ok, "/backoffice/settings/catalogues"}
    end

    test "the canonical name is not an address there" do
      assert Legacy.target("/admin/catalogue/abc") == :unchanged
    end
  end

  describe "forward/2" do
    defp forward(path, query \\ "") do
      :get
      |> Plug.Test.conn(if(query == "", do: path, else: path <> "?" <> query))
      |> Phoenix.Controller.put_format("html")
      |> Legacy.forward(%{})
    end

    test "301 to the current address, query intact" do
      conn = forward("/phoenix_kit/en/admin/catalogue/abc", "category=def")

      assert conn.status == 301

      assert Plug.Conn.get_resp_header(conn, "location") ==
               ["/phoenix_kit/en/admin/catalogues/abc?category=def"]
    end

    # The router drops empty segments, so this reaches `forward/2` with the
    # raw path intact; `redirect/2` raises on a target that starts `//`.
    test "a path with leading slashes is answered, never a crash or a protocol-relative redirect" do
      conn =
        :get
        |> Plug.Test.conn("/admin/catalogue")
        |> Phoenix.Controller.put_format("html")
        |> Map.put(:request_path, "//evil.example/admin/catalogue")
        |> Legacy.forward(%{})

      assert conn.status == 301

      assert Plug.Conn.get_resp_header(conn, "location") ==
               ["/evil.example/admin/catalogues"]
    end

    test "never a redirect to the address it came in on" do
      conn = forward("/phoenix_kit/en/admin/catalogues/abc")

      assert conn.status == 404
      assert Plug.Conn.get_resp_header(conn, "location") == []
    end
  end

  test "it is admin-only, like the module's other HTTP route" do
    source = File.read!("lib/phoenix_kit_catalogue/web/legacy_path_controller.ex")
    assert source =~ "plug(PhoenixKitWeb.Users.Auth, :phoenix_kit_require_admin)"
  end

  test "both route sets carry the old address, as the landing page and as a prefix" do
    for routes <- [Routes.admin_routes(), Routes.admin_locale_routes()] do
      source = Macro.to_string(routes)

      assert source =~ ~s("/admin/catalogue",)
      assert source =~ ~s("/admin/catalogue/*rest")
      assert source =~ ~s("/admin/settings/catalogue",)
      assert source =~ "LegacyPathController"
    end
  end

  test "the module's own paths are under the plural address" do
    assert Paths.index() =~ ~r{/admin/catalogues$}
    refute Paths.index() =~ ~r{/admin/catalogue(/|$)}
  end
end
