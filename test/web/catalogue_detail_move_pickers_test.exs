defmodule PhoenixKitCatalogue.Web.CatalogueDetailMovePickersTest do
  @moduledoc """
  The category pickers in the "move items", "trash category" and "move
  categories" modals must live inside a `<form phx-change>`: LiveView's JS
  refuses a bare `<select phx-change>` ("form events require the input to
  be inside a form"), the event never reaches the server and the confirm
  button stays disabled. Found on max-dev 2026-08-24; these drive the real
  forms so `render_click` cannot paper over it again.
  """
  use PhoenixKitCatalogue.LiveCase

  alias PhoenixKitCatalogue.Catalogue

  @base "/en/admin/catalogue"

  setup do
    cat = fixture_catalogue(%{name: "Pickers"})
    a = fixture_category(cat, %{name: "Alpha"})
    b = fixture_category(cat, %{name: "Beta"})
    %{catalogue: cat, a: a, b: b}
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  test "the items Move picker reaches the server through its form",
       %{conn: conn, catalogue: cat, a: a} do
    item = fixture_item(%{catalogue_uuid: cat.uuid, name: "Loose item"})
    {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}")

    render_click(view, "request_bulk_move_items", %{"uuids" => [item.uuid]})
    render_click(view, "set_bulk_move_disposition", %{"disposition" => "move_to"})

    view
    |> element("form[phx-change=select_bulk_move_target]")
    |> render_change(%{"category_uuid" => a.uuid})

    assert assigns(view).bulk_move_modal.target_uuid == a.uuid
    refute has_element?(view, "button[phx-click=confirm_bulk_move_items][disabled]")
  end

  test "the trash-category picker reaches the server through its form",
       %{conn: conn, catalogue: cat, a: a, b: b} do
    # An empty category is trashed outright; the modal only opens with items.
    fixture_item(%{catalogue_uuid: cat.uuid, category_uuid: a.uuid, name: "Alpha item"})
    {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}")

    render_click(view, "request_trash_category", %{"uuid" => a.uuid})
    render_click(view, "set_trash_disposition", %{"disposition" => "move_to"})

    view
    |> element("form[phx-change=select_trash_target]")
    |> render_change(%{"category_uuid" => b.uuid})

    assert assigns(view).trash_modal.target_uuid == b.uuid
  end

  test "a forged picker uuid is ignored so confirm stays a no-op",
       %{conn: conn, catalogue: cat, a: a, b: b} do
    item = fixture_item(%{catalogue_uuid: cat.uuid, name: "Loose item"})
    fixture_item(%{catalogue_uuid: cat.uuid, category_uuid: a.uuid, name: "Alpha item"})
    {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}")

    render_click(view, "request_bulk_move_items", %{"uuids" => [item.uuid]})
    render_click(view, "set_bulk_move_disposition", %{"disposition" => "move_to"})
    render_click(view, "select_bulk_move_target", %{"category_uuid" => UUIDv7.generate()})
    assert assigns(view).bulk_move_modal.target_uuid == nil

    render_click(view, "request_trash_category", %{"uuid" => a.uuid})
    render_click(view, "set_trash_disposition", %{"disposition" => "move_to"})
    # The category being trashed is not in its own picker.
    render_click(view, "select_trash_target", %{"category_uuid" => a.uuid})
    assert assigns(view).trash_modal.target_uuid == nil

    render_click(view, "select_trash_target", %{"category_uuid" => b.uuid})
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
