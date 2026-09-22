defmodule PhoenixKitCatalogue.Web.EditScreenNoDeleteTest do
  @moduledoc """
  The edit screens carry no delete (boss via Max, 2026-09-21: the edit
  screen's delete was "not quite correct anymore, as we have a whole delete
  goes to trash, and then you have to permanently delete from there… maybe
  just remove the delete thing from the editing completely").

  The catalogue and category forms used to end in a "Danger zone" whose
  "Delete forever" skipped the trash. Deleting is the list rows' ⋮ → Move
  to trash, and deleting forever is the Deleted tab's, so both paths go
  through the trash with its provenance and restore.
  """
  use PhoenixKitCatalogue.LiveCase

  alias PhoenixKitCatalogue.Catalogue

  @base "/en/admin/catalogue"

  setup do
    catalogue = fixture_catalogue(%{name: "Kitchen"})
    category = fixture_category(catalogue, %{name: "Doors"})
    item = fixture_item(%{catalogue_uuid: catalogue.uuid, name: "Hinge"})
    %{catalogue: catalogue, category: category, item: item}
  end

  test "no edit screen offers a delete", %{conn: conn} = ctx do
    for path <- [
          "#{@base}/#{ctx.catalogue.uuid}/edit",
          "#{@base}/categories/#{ctx.category.uuid}/edit",
          "#{@base}/items/#{ctx.item.uuid}/edit"
        ] do
      {:ok, view, html} = live(conn, path)

      refute html =~ "Danger zone", path
      refute html =~ "Delete forever", path
      refute has_element?(view, ~s(button[phx-click="show_delete_confirm"])), path
    end
  end

  test "a pushed old delete event deletes nothing", %{conn: conn} = ctx do
    for {path, event} <- [
          {"#{@base}/#{ctx.catalogue.uuid}/edit", "delete_catalogue"},
          {"#{@base}/categories/#{ctx.category.uuid}/edit", "delete_category"}
        ] do
      {:ok, view, _html} = live(conn, path)
      Process.flag(:trap_exit, true)
      catch_exit(render_click(view, event, %{}))
    end

    assert %{status: "active"} = Catalogue.get_catalogue(ctx.catalogue.uuid)
    assert %{status: "active"} = Catalogue.get_category(ctx.category.uuid)
  end
end
