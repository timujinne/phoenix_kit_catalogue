defmodule PhoenixKitCatalogue.Web.CatalogueDetailEmptyCategoryTest do
  @moduledoc """
  Deleting the last active item in a category must not dump the admin into
  the Deleted view ("stuck in garbage", admin report 2026-08-26). The
  populated-tab auto-pick belongs to ENTERING a node, not to reloads of the
  node the user is already standing on — and because the auto-pick used to
  run on every reload, switching back to the emptied Active tab immediately
  flipped to Deleted again: genuinely stuck.
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue

  @base "/en/admin/catalogue"

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp tab_statuses(view), do: Enum.map(assigns(view).status_tabs, &elem(&1, 0))

  setup do
    cat = fixture_catalogue(%{name: "Sticky Cat"})
    category = fixture_category(cat, %{name: "Emptyable"})

    item =
      fixture_item(%{
        catalogue_uuid: cat.uuid,
        category_uuid: category.uuid,
        name: "The Last Item"
      })

    %{cat: cat, category: category, item: item}
  end

  test "deleting the last active item keeps the admin on the Active tab", %{
    conn: conn,
    cat: cat,
    category: category,
    item: item
  } do
    {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}?category=#{category.uuid}")
    assert assigns(view).view_mode == "active"

    render_click(view, "delete_item", %{"uuid" => item.uuid})

    # Still on Active — empty, but exactly where the user was working.
    assert assigns(view).view_mode == "active"
    refute render(view) =~ "The Last Item"
  end

  test "the emptied Active tab can be chosen and STAYS chosen", %{
    conn: conn,
    cat: cat,
    category: category,
    item: item
  } do
    {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}?category=#{category.uuid}")
    render_click(view, "delete_item", %{"uuid" => item.uuid})

    # Even after deliberately visiting Deleted, Active is selectable again
    # and holds — the old auto-pick made this flip straight back.
    render_click(view, "switch_view", %{"mode" => "deleted"})
    assert assigns(view).view_mode == "deleted"

    render_click(view, "switch_view", %{"mode" => "active"})
    assert assigns(view).view_mode == "active"
  end

  test "ENTERING an all-deleted category still auto-picks Deleted", %{
    conn: conn,
    cat: cat,
    category: category,
    item: item
  } do
    # The deliberate 2026-08 navigation behavior survives the fix: a fresh
    # visit to a node whose items are all deleted opens on Deleted rather
    # than an empty Active.
    {:ok, _} = Catalogue.trash_item(item)

    {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}?category=#{category.uuid}")
    assert assigns(view).view_mode == "deleted"
  end

  describe "categories count toward the tabs that list them" do
    # Max's sequence on max-dev: the category came back empty, its item stayed
    # in the trash on its own, and the catalogue opened on Deleted with no
    # tabs — the restored category was unreachable, even after a refresh.
    test "a catalogue whose categories are empty and whose trash holds an item opens on Active",
         %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Round trip"})
      category = fixture_category(catalogue, %{name: "Round-trip category"})
      item = fixture_item(%{name: "Round-trip item", category_uuid: category.uuid})

      {:ok, _} = Catalogue.trash_category(category, items: :cascade)
      {:ok, _} = Catalogue.restore_item(Catalogue.get_item(item.uuid))
      {:ok, _} = Catalogue.trash_item(Catalogue.get_item(item.uuid))
      {:ok, _} = Catalogue.restore_category(Catalogue.get_category(category.uuid))

      {:ok, view, html} = live(conn, "#{@base}/#{catalogue.uuid}")

      assert assigns(view).view_mode == "active"
      assert html =~ "Round-trip category"
      assert tab_statuses(view) == ["active", "deleted"]
    end

    # Max, 2026-09-15: "Active (2)" for one category holding one item — the
    # item was counted on its own and again through its category.
    test "the root's Active count is what it lists: top-level categories and loose items",
         %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Counted"})
      shelf = fixture_category(catalogue, %{name: "Counted shelf"})
      fixture_category(catalogue, %{name: "Counted sub", parent_uuid: shelf.uuid})
      fixture_item(%{name: "Inside", category_uuid: shelf.uuid})

      {:ok, view, _html} = live(conn, "#{@base}/#{catalogue.uuid}")
      assert {"active", _label, 1} = List.keyfind(assigns(view).status_tabs, "active", 0)

      fixture_item(%{name: "Loose live", catalogue_uuid: catalogue.uuid})
      dormant = fixture_item(%{name: "Loose dormant", catalogue_uuid: catalogue.uuid})
      {:ok, _} = Catalogue.update_item(dormant, %{status: "inactive"})

      {:ok, view, _html} = live(conn, "#{@base}/#{catalogue.uuid}")
      assert {"active", _label, 2} = List.keyfind(assigns(view).status_tabs, "active", 0)
    end

    test "a category whose only live content is a subcategory opens on Active", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Shelves"})
      parent = fixture_category(catalogue, %{name: "Shelf unit"})
      fixture_category(catalogue, %{name: "Empty shelf", parent_uuid: parent.uuid})
      gone = fixture_item(%{name: "Binned bracket", category_uuid: parent.uuid})
      {:ok, _} = Catalogue.trash_item(gone)

      {:ok, view, html} = live(conn, "#{@base}/#{catalogue.uuid}?category=#{parent.uuid}")

      assert assigns(view).view_mode == "active"
      assert html =~ "Empty shelf"
      assert tab_statuses(view) == ["active", "deleted"]
    end

    test "a category holding only a trashed subcategory opens on Deleted and still offers Active",
         %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Racks"})
      parent = fixture_category(catalogue, %{name: "Rack unit"})
      sub = fixture_category(catalogue, %{name: "Binned rack", parent_uuid: parent.uuid})
      {:ok, _} = Catalogue.trash_category(sub)

      {:ok, view, _html} = live(conn, "#{@base}/#{catalogue.uuid}?category=#{parent.uuid}")

      assert assigns(view).view_mode == "deleted"
      assert tab_statuses(view) == ["active", "deleted"]
      assert render(view) =~ "Binned rack"
    end
  end
end
