defmodule PhoenixKitCatalogue.Web.LevelEditButtonTest do
  @moduledoc """
  The Edit button at the top of a catalogue page edits the place you are in
  (boss via Max, 2026-09-21: "inside a catalogue it edits the catalogue; in
  a subcategory you would be editing that subcategory — instead it always
  edits the catalogue").
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Paths

  @base "/en/admin/catalogue"

  setup %{conn: conn, scope: scope} do
    catalogue = fixture_catalogue(%{name: "Edit here"})
    doors = fixture_category(catalogue, %{name: "Doors"})
    oak = fixture_category(catalogue, %{name: "Oak", parent_uuid: doors.uuid})
    %{conn: with_scope(conn, scope), catalogue: catalogue, doors: doors, oak: oak}
  end

  defp edit_href(view) do
    view
    |> element("#level-edit-button")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("href")
    |> List.first()
  end

  test "at the catalogue's top level it edits the catalogue", %{conn: conn, catalogue: c} do
    {:ok, view, _html} = live(conn, "#{@base}/#{c.uuid}")

    assert edit_href(view) =~ Paths.catalogue_edit(c.uuid)
    assert view |> element("#level-edit-button") |> render() =~ "Edit catalogue"
  end

  test "inside a category it edits that category, and comes back to it", %{
    conn: conn,
    catalogue: c,
    doors: doors
  } do
    {:ok, view, _html} = live(conn, "#{@base}/#{c.uuid}?category=#{doors.uuid}")

    href = edit_href(view)
    assert href =~ Paths.category_edit(doors.uuid)
    assert URI.decode_query(URI.parse(href).query || "")["return_to"] =~ doors.uuid
    assert view |> element("#level-edit-button") |> render() =~ "Edit category"
  end

  test "one level deeper it follows you to the subcategory", %{
    conn: conn,
    catalogue: c,
    doors: doors,
    oak: oak
  } do
    {:ok, view, _html} = live(conn, "#{@base}/#{c.uuid}?category=#{doors.uuid}")
    render_patch(view, "#{@base}/#{c.uuid}?category=#{oak.uuid}")

    assert edit_href(view) =~ Paths.category_edit(oak.uuid)
  end
end
