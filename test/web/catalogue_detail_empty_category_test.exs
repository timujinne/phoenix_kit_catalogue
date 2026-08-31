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
end
