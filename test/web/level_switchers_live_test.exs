defmodule PhoenixKitCatalogue.Web.LevelSwitchersLiveTest do
  @moduledoc """
  The detail page hands its level switchers to core's header. With a core
  that has the switcher, the ▾ lists render; with an older one the page
  renders exactly as before (the maps are ignored) — both are checked here,
  whichever core the suite runs against.
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  @base "/en/admin/catalogue"
  @core_switcher? Code.ensure_loaded?(PhoenixKitWeb.Components.Core.CrumbSwitcher)

  setup %{conn: conn, scope: scope} do
    kitchen = fixture_catalogue(%{name: "Kitchen switch"})
    _bath = fixture_catalogue(%{name: "Bathroom switch"})
    doors = fixture_category(kitchen, %{name: "Doors", position: 0})
    _handles = fixture_category(kitchen, %{name: "Handles", position: 1})
    oak = fixture_category(kitchen, %{name: "Oak doors", parent_uuid: doors.uuid, position: 0})

    _glass =
      fixture_category(kitchen, %{name: "Glass doors", parent_uuid: doors.uuid, position: 1})

    %{conn: with_scope(conn, scope), kitchen: kitchen, doors: doors, oak: oak}
  end

  defp list_labels(html, id) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("##{id}-list a")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  test "the root's title switches catalogues", %{conn: conn, kitchen: kitchen} do
    {:ok, view, html} = live(conn, "#{@base}/#{kitchen.uuid}")

    names = :sys.get_state(view.pid).socket.assigns.switch_catalogues |> Enum.map(& &1.name)
    assert "Kitchen switch" in names and "Bathroom switch" in names

    if @core_switcher? do
      labels = list_labels(html, "pk-title-switcher")
      assert "Kitchen switch" in labels and "Bathroom switch" in labels
    else
      refute html =~ "pk-title-switcher"
    end
  end

  test "a subcategory's page switches at every level of the trail", %{
    conn: conn,
    kitchen: kitchen,
    oak: oak
  } do
    {:ok, _view, html} = live(conn, "#{@base}/#{kitchen.uuid}?category=#{oak.uuid}")

    if @core_switcher? do
      # Crumbs: the catalogue, then Doors; the title is Oak doors.
      assert "Bathroom switch" in list_labels(html, "pk-crumb-switcher-0")
      assert list_labels(html, "pk-crumb-switcher-1") == ["Doors", "Handles"]
      assert list_labels(html, "pk-title-switcher") == ["Oak doors", "Glass doors"]
    else
      assert html =~ "Oak doors"
    end
  end
end
