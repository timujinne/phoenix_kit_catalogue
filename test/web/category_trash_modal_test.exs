defmodule PhoenixKitCatalogue.Web.CategoryTrashModalTest do
  @moduledoc """
  The "what about the items?" popup a category Delete opens. Delete is a
  trash, so the popup defaults to sending the items to the Deleted view
  with the category — the one choice a restore of the category undoes.
  """
  use PhoenixKitCatalogue.LiveCase

  alias PhoenixKitCatalogue.Catalogue

  @base "/en/admin/catalogue"

  test "trashing a category with items defaults to sending the items to Deleted with it",
       %{conn: conn} do
    catalogue = fixture_catalogue()
    category = fixture_category(catalogue, %{name: "Full"})
    item = fixture_item(%{name: "Inside", category_uuid: category.uuid})

    {:ok, view, _html} = live(conn, "#{@base}/#{catalogue.uuid}")
    html = render_click(view, "request_trash_category", %{"uuid" => category.uuid})

    assert html =~ "Move category to Deleted — what about its items?"
    assert html =~ "Restoring the category brings them back with it."
    assert :sys.get_state(view.pid).socket.assigns.trash_modal.disposition == :cascade

    # Confirming without touching the choice trashes both, and restoring
    # the category brings the item back.
    render_click(view, "confirm_trash_category", %{})
    assert Catalogue.get_category(category.uuid).status == "deleted"
    assert Catalogue.get_item(item.uuid).status == "deleted"

    {:ok, _} = Catalogue.restore_category(Catalogue.get_category(category.uuid))
    assert Catalogue.get_item(item.uuid).status == "active"
  end

  test "the bulk category delete defaults to the same", %{conn: conn} do
    catalogue = fixture_catalogue()
    category = fixture_category(catalogue)
    fixture_item(%{category_uuid: category.uuid})

    {:ok, view, _html} = live(conn, "#{@base}/#{catalogue.uuid}")
    render_click(view, "request_bulk_delete_categories", %{"uuids" => [category.uuid]})

    assert :sys.get_state(view.pid).socket.assigns.trash_modal.disposition == :cascade
  end
end
