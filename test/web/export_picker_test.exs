defmodule PhoenixKitCatalogue.Web.ExportPickerTest do
  @moduledoc """
  Export picks its catalogues in a tree under their folders, not a flat
  checklist (boss via Max, 2026-09-21: "no flat lists, only proper
  pickers"). A folder's box ticks every catalogue in it; the tree's hidden
  inputs post the ticked ones with the form, and the download follows.
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue

  @url "/en/admin/catalogue/export"

  setup do
    {:ok, rooms} = Catalogue.create_folder(%{name: "Rooms"})
    kitchen = fixture_catalogue(%{name: "Kitchen"})
    bath = fixture_catalogue(%{name: "Bath"})
    loose = fixture_catalogue(%{name: "Loose"})
    {:ok, _} = Catalogue.move_catalogue_to_folder(kitchen, rooms.uuid)
    {:ok, _} = Catalogue.move_catalogue_to_folder(bath, rooms.uuid)
    %{rooms: rooms, kitchen: kitchen, bath: bath, loose: loose}
  end

  defp selected(view), do: :sys.get_state(view.pid).socket.assigns.selected_catalogue_uuids

  test "a folder's box ticks its catalogues; rows tick one by one", %{conn: conn} = ctx do
    {:ok, view, html} = live(conn, @url)
    refute html =~ ~s(type="checkbox" name="catalogue_uuids[]")

    view
    |> element(~s(#export-catalogue-picker [data-pick-all="folder:#{ctx.rooms.uuid}"]))
    |> render_click()

    assert Enum.sort(selected(view)) == Enum.sort([ctx.kitchen.uuid, ctx.bath.uuid])

    view
    |> element(~s(#export-catalogue-picker [data-place="catalogue:#{ctx.loose.uuid}"]))
    |> render_click()

    view
    |> element(
      ~s(#export-catalogue-picker button[phx-click=toggle][phx-value-id="folder:#{ctx.rooms.uuid}"][aria-label])
    )
    |> render_click()

    view
    |> element(~s(#export-catalogue-picker [data-place="catalogue:#{ctx.bath.uuid}"]))
    |> render_click()

    assert Enum.sort(selected(view)) == Enum.sort([ctx.kitchen.uuid, ctx.loose.uuid])

    # The form carries the ticked ones on its next change, and the link follows.
    html = view |> form("#export-form") |> render_change(%{})
    assert Enum.sort(selected(view)) == Enum.sort([ctx.kitchen.uuid, ctx.loose.uuid])
    assert html =~ ctx.kitchen.uuid
    assert html =~ "2 / "
  end

  # A destination/format change posted before a tick's re-render reached
  # the browser carries the previous ticks; the picker's own message is
  # the selection, so the stale post must not undo the tick.
  test "a form change with stale ticks keeps the picker's selection", %{conn: conn} = ctx do
    {:ok, view, _html} = live(conn, @url)

    view
    |> element(~s(#export-catalogue-picker [data-place="catalogue:#{ctx.loose.uuid}"]))
    |> render_click()

    render_change(view, "change_form", %{"catalogue_uuids" => [ctx.bath.uuid]})
    assert selected(view) == [ctx.loose.uuid]
  end
end
