defmodule PhoenixKitCatalogue.Web.CatalogueDetailBulkDuplicateTest do
  @moduledoc """
  The Duplicate bulk action on the catalogue page: same client-side
  button shape as Move on both the items and the categories toolbar, one
  shared confirm modal, copies land next to their sources.
  """
  use PhoenixKitCatalogue.LiveCase

  alias PhoenixKitCatalogue.Catalogue

  @base "/en/admin/catalogue"

  setup do
    cat = fixture_catalogue(%{name: "Dup page"})
    alpha = fixture_category(cat, %{name: "Alpha", position: 0})
    item = fixture_item(%{catalogue_uuid: cat.uuid, category_uuid: alpha.uuid, name: "Pipe"})
    %{catalogue: cat, alpha: alpha, item: item}
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  test "both toolbars offer Duplicate", %{conn: conn, catalogue: cat, alpha: alpha} do
    {:ok, view, _} = live(conn, "#{@base}/#{cat.uuid}")

    assert has_element?(
             view,
             "[id^=categories-bulk-root] [data-bulk-action=request_bulk_duplicate_categories]"
           )

    {:ok, view, _} = live(conn, "#{@base}/#{cat.uuid}?category=#{alpha.uuid}&mode=items")
    assert has_element?(view, "[data-bulk-action=request_bulk_duplicate_items]")
  end

  test "items: request → confirm copies the selection next to the originals",
       %{conn: conn, catalogue: cat, alpha: alpha, item: item} do
    {:ok, view, _} = live(conn, "#{@base}/#{cat.uuid}?category=#{alpha.uuid}&mode=items")

    html = render_click(view, "request_bulk_duplicate_items", %{"uuids" => [item.uuid]})
    assert html =~ "Duplicate selected items"
    assert assigns(view).bulk_duplicate_modal == %{kind: :items, count: 1, uuids: [item.uuid]}

    before = assigns(view).bulk_epoch
    html = render_click(view, "confirm_bulk_duplicate", %{})
    assert html =~ "Duplicated 1 items."
    refute assigns(view).bulk_duplicate_modal
    # The selection scope remounts (new id) so the originals lose their ticks.
    assert assigns(view).bulk_epoch == before + 1
    assert has_element?(view, "#items-bulk-#{alpha.uuid}-#{before + 1}")

    assert Catalogue.list_items_for_category(alpha.uuid) |> Enum.map(& &1.name) ==
             ["Pipe", "Pipe (copy)"]
  end

  test "categories: the copy brings its items", %{conn: conn, catalogue: cat, alpha: alpha} do
    {:ok, view, _} = live(conn, "#{@base}/#{cat.uuid}")

    render_click(view, "request_bulk_duplicate_categories", %{"uuids" => [alpha.uuid]})
    html = render_click(view, "confirm_bulk_duplicate", %{})
    assert html =~ "Duplicated 1 categories."

    [_, copy] = Catalogue.list_child_categories(cat.uuid, nil)
    assert copy.name == "Alpha (copy)"
    assert Catalogue.list_items_for_category(copy.uuid) |> Enum.map(& &1.name) == ["Pipe"]
  end

  test "an empty selection and cancel are no-ops", %{conn: conn, catalogue: cat} do
    {:ok, view, _} = live(conn, "#{@base}/#{cat.uuid}")

    render_click(view, "request_bulk_duplicate_items", %{"uuids" => []})
    refute assigns(view).bulk_duplicate_modal

    render_click(view, "request_bulk_duplicate_items", %{"uuids" => ["x"]})
    render_click(view, "cancel_bulk_duplicate", %{})
    refute assigns(view).bulk_duplicate_modal
  end

  test "a forged uuid is dropped before it can reach a query", %{conn: conn, catalogue: cat} do
    {:ok, view, _} = live(conn, "#{@base}/#{cat.uuid}")

    render_click(view, "request_bulk_duplicate_categories", %{"uuids" => ["not-a-uuid"]})
    refute assigns(view).bulk_duplicate_modal
    assert Process.alive?(view.pid)
  end

  test "an unknown but well-formed uuid is reported, not crashed on", %{
    conn: conn,
    catalogue: cat
  } do
    {:ok, view, _} = live(conn, "#{@base}/#{cat.uuid}")

    render_click(view, "request_bulk_duplicate_categories", %{"uuids" => [UUIDv7.generate()]})
    html = render_click(view, "confirm_bulk_duplicate", %{})

    assert html =~ "1 categories could not be duplicated."
    refute html =~ "Duplicated"
    assert Catalogue.list_child_categories(cat.uuid, nil) |> length() == 1
  end
end
