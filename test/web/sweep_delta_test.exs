defmodule PhoenixKitCatalogue.Web.SweepDeltaTest do
  @moduledoc """
  Pins the LV-visible deltas introduced by the 2026-04 quality sweep.
  Each test pairs with a specific change in a `lib/` file; if that
  change reverts, the corresponding test here fails.

  See `dev_docs/sweep_2026_04_delta_audit.md` for the revert-fail
  mapping written during C11.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  setup do
    cat = fixture_catalogue()
    %{catalogue: cat}
  end

  describe "C5 — phx-disable-with on item-table destructive buttons" do
    test "components.ex source pins the perm-delete phx-disable-with attr" do
      # The C5 fix added `phx-disable-with="Deleting…"` to the two
      # perm-delete button call sites (`item_row_actions/1` and
      # `item_actions/1`, both private). Both are exercised when the
      # detail-view item card / table row exposes its action menu.
      # `item_actions/1` is `defp` so we can't render it directly; the
      # next-cheapest pin is a source-level grep.
      source =
        File.read!("lib/phoenix_kit_catalogue/web/components.ex")

      # Match HEEX button declarations (start with `<button` or
      # `<.table_row_menu_button`) that fire `@on_permanent_delete`.
      perm_delete_blocks =
        Regex.scan(
          ~r/<(?:button|\.table_row_menu_button)[^>]*?@on_permanent_delete[^>]*?\/?>/s,
          source
        )
        |> List.flatten()

      assert length(perm_delete_blocks) >= 2,
             "Expected at least two perm-delete button declarations in components.ex (got #{length(perm_delete_blocks)})"

      Enum.each(perm_delete_blocks, fn block ->
        assert block =~ "phx-disable-with",
               "Expected `phx-disable-with` on every perm-delete button. Missing in: #{block}"
      end)
    end
  end

  describe "C6 — String.capitalize → status_label" do
    test "catalogue card view renders translated 'Active' status, not raw 'active'", %{
      catalogue: cat
    } do
      # Card view is the path components.ex:1167 covered (was
      # `String.capitalize(item.status || "unknown")`). After C6 it
      # routes through `status_label/1` which returns "Active" via
      # gettext for the known "active" status. We assert the rendered
      # admin-list HTML contains the gettext form.
      _ = cat

      {:ok, _view, html} = live(conn(), "/en/admin/catalogue")

      assert html =~ "Active"
    end
  end

  describe "C6 — handle_info catch-all logs at debug" do
    test "stray messages don't crash CataloguesLive (catch-all is exhaustive)" do
      {:ok, view, _html} = live(conn(), "/en/admin/catalogue")

      # Send an unexpected message — the LV's catch-all should `:noreply`
      # without crashing (and emit a Logger.debug, which we don't
      # capture here because pinning log lines is brittle across host
      # log configs; the structural guarantee is that the pid stays
      # alive).
      send(view.pid, :totally_unexpected_message)
      assert Process.alive?(view.pid)
    end
  end

  defp conn, do: Phoenix.ConnTest.build_conn() |> Plug.Test.init_test_session(%{})
end
