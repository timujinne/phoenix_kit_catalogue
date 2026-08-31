defmodule PhoenixKitCatalogue.Web.ViewPersistenceTest do
  @moduledoc """
  The card/comfy/table choice is ONE per-user preference for the whole
  module (boss via Max, 2026-08-28: it should stay when you switch to a
  different page). Before this, each surface kept its own — and two of
  them kept theirs in the browser's localStorage — so a choice made on
  the catalogues index never reached the catalogue you opened next.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitCatalogue.Web.ViewConfig

  setup %{conn: conn, scope: scope} do
    catalogue = fixture_catalogue(%{name: "View Pref Cat"})
    fixture_item(%{name: "View Pref Item", catalogue_uuid: catalogue.uuid})
    %{conn: with_scope(conn, scope), catalogue: catalogue, user: scope.user}
  end

  test "choosing a view on the index changes what every other page opens with",
       %{conn: conn, catalogue: catalogue, user: user} do
    {:ok, index, _html} = live(conn, "/en/admin/catalogue")
    render_click(index, "set_view", %{"mode" => "table"})

    # Stored against the user, not the page…
    assert ViewConfig.load_view(reload_user(user)) == "table"

    # …so the detail page, the attributes tab and the PDF library all
    # open in it rather than in whatever they last remembered.
    {:ok, detail, _} = live(conn, "/en/admin/catalogue/#{catalogue.uuid}")
    assert :sys.get_state(detail.pid).socket.assigns.view_mode_pref == "table"

    {:ok, attrs, _} = live(conn, "/en/admin/catalogue/attributes")
    assert :sys.get_state(attrs.pid).socket.assigns.view_mode == "table"

    {:ok, pdfs, _} = live(conn, "/en/admin/catalogue/pdfs")
    assert :sys.get_state(pdfs.pid).socket.assigns.view_mode == "table"
  end

  test "and it travels the other way too", %{conn: conn, catalogue: catalogue, user: user} do
    {:ok, detail, _} = live(conn, "/en/admin/catalogue/#{catalogue.uuid}")
    render_click(detail, "set_view", %{"mode" => "card"})

    assert ViewConfig.load_view(reload_user(user)) == "card"

    {:ok, index, _} = live(conn, "/en/admin/catalogue")
    assert :sys.get_state(index.pid).socket.assigns.view_configs.catalogues.view == "card"
  end

  test "the switch itself needs no server round trip", %{conn: conn, catalogue: catalogue} do
    # Routing the click through the server cost 150-350ms and could spike
    # to seconds (Max, 2026-08-28). A page that renders BOTH faces lets
    # CSS do the switching and persists afterwards, so the click is free.
    # (Asserted on the detail page because the attributes tab and the PDF
    # library render no toggle at all when they have nothing to list.)
    {:ok, view, html} = live(conn, "/en/admin/catalogue/#{catalogue.uuid}?mode=items")

    # The table is UNCONTROLLED — it carries the shared storage key, which
    # is what lets the client swap faces without asking the server.
    assert html =~ ~s(data-storage-key="catalogue-view")
    refute html =~ ~s(phx-click="set_view")

    # …and the hook that persists the choice knows what the server holds,
    # so a browser that has never been here still opens correctly.
    assert has_element?(view, ~s|[phx-hook="ViewPref"][data-server-view]|)
  end

  test "a later column change does not undo the chosen view",
       %{conn: conn, catalogue: catalogue, user: user} do
    # Both writes merge into the SAME `custom_fields` map. Saving the view
    # and then dropping the refreshed user left the socket holding a
    # snapshot from before it, so the next scope save wrote that snapshot
    # back and the view vanished — silently, and only visible one page
    # later as "my view didn't stick".
    {:ok, index, _} = live(conn, "/en/admin/catalogue")
    render_click(index, "set_view", %{"mode" => "table"})
    assert ViewConfig.load_view(reload_user(user)) == "table"

    render_click(index, "remove_column", %{"column_id" => "status"})

    assert ViewConfig.load_view(reload_user(user)) == "table"
    {:ok, detail, _} = live(conn, "/en/admin/catalogue/#{catalogue.uuid}")
    assert :sys.get_state(detail.pid).socket.assigns.view_mode_pref == "table"
  end

  test "an unknown mode is ignored rather than blanking the page", %{conn: conn, user: user} do
    {:ok, index, _} = live(conn, "/en/admin/catalogue")

    # The payload is client-forgeable, so an unknown mode is ignored by
    # a catch-all rather than crashing the LiveView, and nothing is
    # persisted.
    render_click(index, "set_view", %{"mode" => "sideways"})
    assert ViewConfig.load_view(reload_user(user)) == "comfy"
    assert :sys.get_state(index.pid).socket.assigns.view_configs.catalogues.view == "comfy"
  end

  defp reload_user(%{uuid: uuid}), do: Auth.get_user!(uuid)
  defp reload_user(other), do: other
end
