defmodule PhoenixKitCatalogue.Web.CatalogueDetailMovePickersTest do
  @moduledoc """
  The catalogue page's move dialogs pick the destination in a tree, never
  a flat select (boss via Max, 2026-09-21: "no flat lists, only proper
  pickers"): bulk-move items and the trash dialog's "move items to…".
  Every pick goes through the real tree rows; forged picks of rows the
  tree does not offer change nothing.
  """
  use PhoenixKitCatalogue.LiveCase

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Web.PlaceTree

  @base "/en/admin/catalogue"

  setup do
    cat = fixture_catalogue(%{name: "Pickers"})
    a = fixture_category(cat, %{name: "Alpha"})
    b = fixture_category(cat, %{name: "Beta"})
    %{catalogue: cat, a: a, b: b}
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp pick(view, picker, id),
    do: view |> element(~s(##{picker} [data-place="#{id}"])) |> render_click()

  test "bulk-moving items: a category row of this catalogue, then confirm",
       %{conn: conn, catalogue: cat, a: a} do
    item = fixture_item(%{catalogue_uuid: cat.uuid, name: "Loose item"})
    {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}")

    render_click(view, "request_bulk_move_items", %{"uuids" => [item.uuid]})
    refute has_element?(view, "#bulk-move-items-picker select")
    assert has_element?(view, "button[phx-click=confirm_bulk_move_items][disabled]")

    # This catalogue starts open, badged Current: its categories show.
    pick(view, "bulk-move-items-picker", "category:" <> a.uuid)
    assert assigns(view).bulk_move_modal.target == "category:" <> a.uuid
    assert view |> element("#bulk-move-items-destination") |> render() =~ "Pickers › Alpha"
    refute has_element?(view, "button[phx-click=confirm_bulk_move_items][disabled]")

    view |> element("button[phx-click=confirm_bulk_move_items]") |> render_click()
    assert Catalogue.get_item(item.uuid).category_uuid == a.uuid
  end

  test "the trash dialog's tree shows for Move items, without the category being trashed",
       %{conn: conn, catalogue: cat, a: a, b: b} do
    # An empty category is trashed outright; the modal only opens with items.
    item = fixture_item(%{catalogue_uuid: cat.uuid, category_uuid: a.uuid, name: "Alpha item"})
    {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}")

    render_click(view, "request_trash_category", %{"uuid" => a.uuid})
    refute has_element?(view, "#trash-target-picker")

    render_click(view, "set_trash_disposition", %{"disposition" => "move_to"})
    html = view |> element("#trash-target-picker") |> render()
    refute html =~ ~s(data-place="category:#{a.uuid}")

    pick(view, "trash-target-picker", "category:" <> b.uuid)
    assert assigns(view).trash_modal.target_uuid == b.uuid

    view |> element("button[phx-click=confirm_trash_category]") |> render_click()
    assert Catalogue.get_category(a.uuid).status == "deleted"
    assert Catalogue.get_item(item.uuid).category_uuid == b.uuid
  end

  # A › B (trashed) › C (restored on its own): C shows at the top level,
  # but it is in A's subtree, so neither A's move nor A's trash offers it.
  test "a live category below a trashed one in the subtree is left out of both trees",
       %{conn: conn, catalogue: cat, a: a, b: b} do
    {:ok, mid} =
      Catalogue.create_category(%{name: "Mid", catalogue_uuid: cat.uuid, parent_uuid: a.uuid})

    {:ok, low} =
      Catalogue.create_category(%{name: "Low", catalogue_uuid: cat.uuid, parent_uuid: mid.uuid})

    {:ok, _} = Catalogue.trash_category(mid)
    {:ok, _} = Catalogue.restore_category(Catalogue.get_category(low.uuid))
    _item = fixture_item(%{catalogue_uuid: cat.uuid, category_uuid: a.uuid, name: "Keeps A open"})

    {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}")

    render_click(view, "request_bulk_move_categories", %{"uuids" => [a.uuid]})
    move_tree = assigns(view).bulk_move_categories_modal.tree
    refute PlaceTree.find(move_tree, "category:" <> low.uuid)
    assert PlaceTree.find(move_tree, "category:" <> b.uuid)

    render_click(view, "request_trash_category", %{"uuid" => a.uuid})
    trash_tree = assigns(view).trash_modal.tree
    refute PlaceTree.find(trash_tree, "category:" <> low.uuid)
    assert PlaceTree.find(trash_tree, "category:" <> b.uuid)
  end

  test "forged picks of rows the trees do not offer are ignored",
       %{conn: conn, catalogue: cat, a: a, b: b} do
    item = fixture_item(%{catalogue_uuid: cat.uuid, name: "Loose item"})
    fixture_item(%{catalogue_uuid: cat.uuid, category_uuid: a.uuid, name: "Alpha item"})
    {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}")

    render_click(view, "request_bulk_move_items", %{"uuids" => [item.uuid]})

    view
    |> with_target("#bulk-move-items-picker")
    |> render_click("pick", %{"id" => "category:" <> UUIDv7.generate()})

    assert assigns(view).bulk_move_modal.target == nil
    render_click(view, "confirm_bulk_move_items", %{})
    assert Catalogue.get_item(item.uuid).category_uuid == nil

    render_click(view, "cancel_bulk_move", %{})
    render_click(view, "request_trash_category", %{"uuid" => a.uuid})
    render_click(view, "set_trash_disposition", %{"disposition" => "move_to"})

    # The category being trashed is not in its own tree.
    view
    |> with_target("#trash-target-picker")
    |> render_click("pick", %{"id" => "category:" <> a.uuid})

    assert assigns(view).trash_modal.target_uuid == nil

    pick(view, "trash-target-picker", "category:" <> b.uuid)
    assert assigns(view).trash_modal.target_uuid == b.uuid
  end

  test "trashing a category from another catalogue is refused",
       %{conn: conn, catalogue: cat} do
    other = fixture_catalogue(%{name: "Elsewhere"})
    foreign = fixture_category(other, %{name: "Foreign"})
    {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}")

    html = render_click(view, "request_trash_category", %{"uuid" => foreign.uuid})
    assert html =~ "Category not found."
    assert Catalogue.get_category(foreign.uuid).status == "active"
  end
end
