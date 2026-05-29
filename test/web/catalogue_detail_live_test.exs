defmodule PhoenixKitCatalogue.Web.CatalogueDetailLiveTest do
  @moduledoc """
  End-to-end tests for CatalogueDetailLive — the category drill-down:
  root landing (category cards + Uncategorized card), drilling into a
  category (`?category=<uuid>`) to see its subcategories + own items,
  the uncategorized bucket, per-level Active/Deleted, scoped search,
  item/category mutations, orphan reachability, and not-found handling.
  """
  use PhoenixKitCatalogue.LiveCase

  alias PhoenixKitCatalogue.Catalogue

  @base "/en/admin/catalogue"

  defp url(uuid), do: "#{@base}/#{uuid}"
  defp cat_url(cat_uuid, category_uuid), do: "#{url(cat_uuid)}?category=#{category_uuid}"
  defp uncat_url(cat_uuid), do: "#{url(cat_uuid)}?category=uncategorized"

  # Character index of `needle` in `html` — for asserting relative
  # render order of two item names.
  defp position_of(html, needle) do
    case :binary.match(html, needle) do
      {idx, _len} -> idx
      :nomatch -> flunk("expected #{inspect(needle)} in rendered HTML")
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Mount / root landing
  # ─────────────────────────────────────────────────────────────────

  describe "mount" do
    test "renders catalogue name and header actions", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Kitchen"})

      {:ok, _view, html} = live(conn, url(catalogue.uuid))

      assert html =~ "Kitchen"
      assert html =~ "Add Item"
      assert html =~ "Add Category"
    end

    test "redirects to the index when the catalogue doesn't exist", %{conn: conn} do
      bogus = "00000000-0000-0000-0000-000000000000"

      {:error, {:live_redirect, %{to: to}}} = live(conn, url(bogus))
      assert to == @base
    end

    test "renders the empty-state card when there are no categories or items", %{conn: conn} do
      catalogue = fixture_catalogue()

      {:ok, _view, html} = live(conn, url(catalogue.uuid))

      assert html =~ "No categories or items yet"
    end
  end

  describe "root landing" do
    test "shows root categories as drill cards and the catalogue-wide search", %{conn: conn} do
      catalogue = fixture_catalogue()
      cat_a = fixture_category(catalogue, %{name: "First", position: 0})
      _cat_b = fixture_category(catalogue, %{name: "Second", position: 1})

      {:ok, _view, html} = live(conn, url(catalogue.uuid))

      assert html =~ "First"
      assert html =~ "Second"
      # Each card is a drill link into the category.
      assert html =~ "?category=#{cat_a.uuid}"
      # The pencil keeps a one-click path to the edit form.
      assert html =~ "/en/admin/catalogue/categories/#{cat_a.uuid}/edit"
      # Root search is catalogue-wide.
      assert html =~ "Search items by name, description, or SKU"
    end

    test "shows an Uncategorized drill card when there are categories + loose items",
         %{conn: conn} do
      catalogue = fixture_catalogue()
      # A category must exist for the Uncategorized card to appear — with no
      # categories the loose items render inline instead (see next test).
      fixture_category(catalogue, %{name: "A Category"})
      fixture_item(%{name: "Loose Item", catalogue_uuid: catalogue.uuid})

      {:ok, _view, html} = live(conn, url(catalogue.uuid))

      assert html =~ "Uncategorized"
      assert html =~ "?category=uncategorized"
    end

    test "with no categories, the catalogue's loose items render inline at root",
         %{conn: conn} do
      catalogue = fixture_catalogue()
      fixture_item(%{name: "Loose Alpha", catalogue_uuid: catalogue.uuid})

      {:ok, _view, html} = live(conn, url(catalogue.uuid))

      # Items show directly — no redundant Uncategorized drill card to click.
      assert html =~ "Loose Alpha"
      refute html =~ "?category=uncategorized"
    end

    test "does NOT render category items inline at the root level", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue, %{name: "Cat A"})
      fixture_item(%{name: "Deep Inside Item", category_uuid: category.uuid})

      {:ok, _view, html} = live(conn, url(catalogue.uuid))

      assert html =~ "Cat A"
      # Categorised items only show once you drill into the category.
      refute html =~ "Deep Inside Item"
    end

    test "no breadcrumb at the root level", %{conn: conn} do
      catalogue = fixture_catalogue()
      fixture_category(catalogue, %{name: "Cat"})

      {:ok, _view, html} = live(conn, url(catalogue.uuid))

      refute html =~ "breadcrumbs"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Drilling into a category
  # ─────────────────────────────────────────────────────────────────

  describe "drill into a category" do
    test "shows the breadcrumb, the scoped search, and the category's own items", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Catalogue X"})
      category = fixture_category(catalogue, %{name: "Hardware"})
      fixture_item(%{name: "Hinge 90", category_uuid: category.uuid})

      {:ok, _view, html} = live(conn, cat_url(catalogue.uuid, category.uuid))

      # The breadcrumb is folded into the page title: catalogue name (a
      # link back to root) ▸ current category name.
      assert html =~ "Catalogue X"
      assert html =~ "Hardware"
      assert html =~ "Hinge 90"
      # The breadcrumb root crumb patches back to the catalogue root.
      assert html =~ ~s(href="#{url(catalogue.uuid)}")
      # Search is scoped to this category.
      assert html =~ "Search within this category"
    end

    test "shows subcategories as drill cards alongside the category's own items", %{conn: conn} do
      catalogue = fixture_catalogue()
      parent = fixture_category(catalogue, %{name: "Parent"})
      child = fixture_category(catalogue, %{name: "Child", parent_uuid: parent.uuid})
      fixture_item(%{name: "Parent direct item", category_uuid: parent.uuid})

      {:ok, _view, html} = live(conn, cat_url(catalogue.uuid, parent.uuid))

      # Subcategory card (drillable) + the parent's own direct item.
      assert html =~ "Child"
      assert html =~ "?category=#{child.uuid}"
      assert html =~ "Parent direct item"
    end

    test "an item in the level list links to its edit page", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      item = fixture_item(%{name: "Clickable item", category_uuid: category.uuid})

      {:ok, _view, html} = live(conn, cat_url(catalogue.uuid, category.uuid))

      assert html =~ ~s(href="/en/admin/catalogue/items/#{item.uuid}/edit")
      assert html =~ "Clickable item"
    end

    test "a missing / foreign category bounces back to the root level", %{conn: conn} do
      catalogue = fixture_catalogue()
      bogus = "00000000-0000-0000-0000-000000000000"

      case live(conn, cat_url(catalogue.uuid, bogus)) do
        {:ok, _view, html} -> assert html =~ "Add Category"
        {:error, {:live_redirect, %{to: to}}} -> assert to =~ url(catalogue.uuid)
      end
    end
  end

  describe "uncategorized bucket" do
    test "shows the catalogue's loose items", %{conn: conn} do
      catalogue = fixture_catalogue()
      _categorised = fixture_category(catalogue, %{name: "Cat A"})
      fixture_item(%{name: "Loose Item", catalogue_uuid: catalogue.uuid})

      {:ok, _view, html} = live(conn, uncat_url(catalogue.uuid))

      assert html =~ "Uncategorized"
      assert html =~ "Loose Item"
      assert html =~ "Search uncategorized items"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Per-level Active / Deleted
  # ─────────────────────────────────────────────────────────────────

  describe "view_mode toggle (per-level)" do
    test "switch_view shows the current category's deleted items", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      active = fixture_item(%{name: "Active item", category_uuid: category.uuid})
      deleted = fixture_item(%{name: "Deleted item", category_uuid: category.uuid})
      Catalogue.trash_item(deleted)

      {:ok, view, html} = live(conn, cat_url(catalogue.uuid, category.uuid))
      assert html =~ "Active item"
      refute html =~ "Deleted item"

      html_after = render_click(view, "switch_view", %{"mode" => "deleted"})

      assert html_after =~ "Deleted item"
      refute html_after =~ active.uuid
    end

    test "the toggle reflects the level's active + deleted counts", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      fixture_item(%{name: "A", category_uuid: category.uuid})
      fixture_item(%{name: "B", category_uuid: category.uuid})
      gone = fixture_item(%{name: "Gone", category_uuid: category.uuid})
      Catalogue.trash_item(gone)

      {:ok, _view, html} = live(conn, cat_url(catalogue.uuid, category.uuid))

      assert html =~ "Active"
      assert html =~ "(2)"
      assert html =~ "Deleted"
      assert html =~ "(1)"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Item mutations (inside a category)
  # ─────────────────────────────────────────────────────────────────

  describe "item mutations" do
    test "delete_item removes the item and trashes it in the DB", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      item = fixture_item(%{name: "Doomed", category_uuid: category.uuid})
      fixture_item(%{name: "Survivor", category_uuid: category.uuid})

      {:ok, view, html} = live(conn, cat_url(catalogue.uuid, category.uuid))
      assert html =~ "Doomed"

      html_after = render_click(view, "delete_item", %{"uuid" => item.uuid})

      refute html_after =~ "Doomed"
      assert html_after =~ "Survivor"
      assert Catalogue.get_item(item.uuid).status == "deleted"
    end

    test "restore_item from the level's Deleted view marks the item active", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      item = fixture_item(%{name: "Comeback", category_uuid: category.uuid})
      Catalogue.trash_item(item)

      {:ok, view, _html} = live(conn, cat_url(catalogue.uuid, category.uuid))
      html = render_click(view, "switch_view", %{"mode" => "deleted"})
      assert html =~ "Comeback"

      render_click(view, "restore_item", %{"uuid" => item.uuid})

      assert Catalogue.get_item(item.uuid).status == "active"
      assert Process.alive?(view.pid)
    end

    test "delete_item with a bogus uuid doesn't crash", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      survivor = fixture_item(%{name: "Survivor", category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, cat_url(catalogue.uuid, category.uuid))

      html =
        render_click(view, "delete_item", %{"uuid" => "00000000-0000-0000-0000-000000000000"})

      assert html =~ "Survivor"
      assert Catalogue.get_item(survivor.uuid).status == "active"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Category mutations
  # ─────────────────────────────────────────────────────────────────

  describe "category mutations" do
    test "request_trash_category removes an empty category card from the root", %{conn: conn} do
      catalogue = fixture_catalogue()
      cat_a = fixture_category(catalogue, %{name: "Trashable", position: 0})
      _cat_b = fixture_category(catalogue, %{name: "Staying", position: 1})

      {:ok, view, html} = live(conn, url(catalogue.uuid))
      assert html =~ "Trashable"

      html_after = render_click(view, "request_trash_category", %{"uuid" => cat_a.uuid})
      refute html_after =~ "Trashable"
      assert html_after =~ "Staying"
    end

    test "restore_category brings a trashed category back", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue, %{name: "Brought Back"})
      Catalogue.trash_category(category)

      {:ok, view, _html} = live(conn, url(catalogue.uuid))
      _deleted_html = render_click(view, "switch_view", %{"mode" => "deleted"})

      html_after = render_click(view, "restore_category", %{"uuid" => category.uuid})
      assert html_after =~ "Brought Back"
    end

    test "a child restored under a still-trashed parent stays reachable at the root",
         %{conn: conn} do
      # restore_category/2 is non-cascading: restoring the child leaves the
      # parent trashed. list_child_categories/3 orphan-promotes the child to
      # the root so the drill-down can still reach it.
      catalogue = fixture_catalogue()
      parent = fixture_category(catalogue, %{name: "TrashedParent"})
      child = fixture_category(catalogue, %{name: "OrphanChild", parent_uuid: parent.uuid})

      # Trashing the parent cascades the subtree (parent + child → deleted).
      Catalogue.trash_category(parent, items: :cascade)
      # Restore only the child.
      {:ok, _} = Catalogue.restore_category(Catalogue.get_category(child.uuid))

      {:ok, _view, html} = live(conn, url(catalogue.uuid))

      assert html =~ "OrphanChild"
      assert html =~ "?category=#{child.uuid}"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Active item list: core List-UI toolkit (sort + reorder + bulk)
  # ─────────────────────────────────────────────────────────────────

  describe "active item list — sort dropdown" do
    test "sort_items changes the rendered order", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      fixture_item(%{name: "Cherry", position: 0, category_uuid: category.uuid})
      fixture_item(%{name: "Apple", position: 1, category_uuid: category.uuid})

      {:ok, view, html} = live(conn, cat_url(catalogue.uuid, category.uuid))
      # Manual (position) order: Cherry before Apple.
      assert position_of(html, "Cherry") < position_of(html, "Apple")

      html_after = render_change(view, "sort_items", %{"sort_by" => "name"})
      # Name-asc order: Apple before Cherry.
      assert position_of(html_after, "Apple") < position_of(html_after, "Cherry")
    end

    test "sort_items ignores an unknown field", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      fixture_item(%{name: "Solo", category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, cat_url(catalogue.uuid, category.uuid))
      html = render_change(view, "sort_items", %{"sort_by" => "evil; DROP"})

      assert html =~ "Solo"
      assert Process.alive?(view.pid)
    end
  end

  describe "active item list — strategy reorder modal" do
    test "open → apply renumbers items by strategy", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      fixture_item(%{name: "Cherry", category_uuid: category.uuid})
      fixture_item(%{name: "Apple", category_uuid: category.uuid})
      fixture_item(%{name: "Banana", category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, cat_url(catalogue.uuid, category.uuid))

      # Open the modal with no selection captured → "reorder all".
      render_hook(view, "open_items_reorder_modal", %{"uuids" => []})
      render_hook(view, "apply_items_reorder", %{"strategy" => "name_asc"})

      positions =
        category.uuid
        |> Catalogue.list_items_for_category_paged(sort_by: :position, sort_dir: :asc)
        |> Enum.map(&{&1.name, &1.position})

      assert positions == [{"Apple", 1}, {"Banana", 2}, {"Cherry", 3}]
    end

    test "apply with a selected subset sharing positions flashes a normalise hint", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      a = fixture_item(%{name: "A", category_uuid: category.uuid})
      b = fixture_item(%{name: "B", category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, cat_url(catalogue.uuid, category.uuid))

      render_hook(view, "open_items_reorder_modal", %{"uuids" => [a.uuid, b.uuid]})
      html = render_hook(view, "apply_items_reorder", %{"strategy" => "name_asc"})

      assert html =~ "Reorder all"
      # Positions untouched (both still 0).
      assert Catalogue.get_item(a.uuid).position == 0
      assert Catalogue.get_item(b.uuid).position == 0
    end

    test "apply with an unknown strategy asks for one", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      fixture_item(%{name: "X", category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, cat_url(catalogue.uuid, category.uuid))
      html = render_hook(view, "apply_items_reorder", %{"strategy" => "bogus"})

      assert html =~ "Pick a strategy"
    end
  end

  describe "active item list — DnD reorder (scope from socket)" do
    test "reorder_items persists the dropped order using the current node scope", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      a = fixture_item(%{name: "A", position: 0, category_uuid: category.uuid})
      b = fixture_item(%{name: "B", position: 1, category_uuid: category.uuid})
      c = fixture_item(%{name: "C", position: 2, category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, cat_url(catalogue.uuid, category.uuid))

      # Drag C to the front. No catalogueUuid/categoryUuid in the payload —
      # the handler must take scope from socket assigns.
      render_hook(view, "reorder_items", %{
        "ordered_ids" => [c.uuid, a.uuid, b.uuid],
        "moved_id" => c.uuid
      })

      positions =
        category.uuid
        |> Catalogue.list_items_for_category_paged(sort_by: :position, sort_dir: :asc)
        |> Enum.map(& &1.name)

      assert positions == ["C", "A", "B"]
    end
  end

  describe "active item list — bulk delete via captured uuids" do
    test "request → confirm trashes the captured items", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      doomed = fixture_item(%{name: "Doomed", category_uuid: category.uuid})
      survivor = fixture_item(%{name: "Survivor", category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, cat_url(catalogue.uuid, category.uuid))

      # The toolbar pushes the client-captured uuids.
      render_hook(view, "request_bulk_delete_items", %{"uuids" => [doomed.uuid]})
      render_click(view, "confirm_bulk_action", %{})

      assert Catalogue.get_item(doomed.uuid).status == "deleted"
      assert Catalogue.get_item(survivor.uuid).status == "active"
    end

    test "bulk move via captured uuids uncategorizes the items", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      item = fixture_item(%{name: "Mover", category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, cat_url(catalogue.uuid, category.uuid))

      render_hook(view, "request_bulk_move_items", %{"uuids" => [item.uuid]})
      render_click(view, "confirm_bulk_move_items", %{})

      assert Catalogue.get_item(item.uuid).category_uuid == nil
    end
  end

  describe "active item list — load_more still pages" do
    test "load_more appends the next page of items", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)

      for i <- 1..130 do
        fixture_item(%{
          name: "Item #{String.pad_leading("#{i}", 3, "0")}",
          position: i,
          category_uuid: category.uuid
        })
      end

      {:ok, view, html} = live(conn, cat_url(catalogue.uuid, category.uuid))
      # First page is 100 items.
      assert html =~ "Item 100"
      refute html =~ "Item 130"

      html_after = render_hook(view, "load_more", %{})
      assert html_after =~ "Item 130"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Search (scoped per level)
  # ─────────────────────────────────────────────────────────────────

  describe "search" do
    test "root search spans the whole catalogue", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue, %{name: "Some category"})
      fixture_item(%{name: "Oak panel", category_uuid: category.uuid})
      fixture_item(%{name: "Pine board", category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, url(catalogue.uuid))

      render_change(view, "search", %{"query" => "oak"})
      html_after = render_async(view)

      assert html_after =~ "Oak panel"
      refute html_after =~ "Pine board"
    end

    test "search inside a category is scoped to that category", %{conn: conn} do
      catalogue = fixture_catalogue()
      cat_a = fixture_category(catalogue, %{name: "Cat A"})
      cat_b = fixture_category(catalogue, %{name: "Cat B"})
      fixture_item(%{name: "Oak in A", category_uuid: cat_a.uuid})
      fixture_item(%{name: "Oak in B", category_uuid: cat_b.uuid})

      {:ok, view, _html} = live(conn, cat_url(catalogue.uuid, cat_a.uuid))

      render_change(view, "search", %{"query" => "oak"})
      html_after = render_async(view)

      assert html_after =~ "Oak in A"
      refute html_after =~ "Oak in B"
    end

    test "clear_search restores the level view", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      fixture_item(%{name: "Only item", category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, cat_url(catalogue.uuid, category.uuid))
      render_change(view, "search", %{"query" => "nothing matches"})
      _ = render_async(view)
      html_after = render_click(view, "clear_search", %{})

      assert html_after =~ "Only item"
    end

    test "shows a loading indicator for the first search before results land", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      fixture_item(%{name: "Oak panel", category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, cat_url(catalogue.uuid, category.uuid))
      html_pending = render_change(view, "search", %{"query" => "oak"})

      assert html_pending =~ "Searching for"
      assert html_pending =~ "loading-spinner"

      html_after = render_async(view)

      refute html_after =~ "Searching for"
      assert html_after =~ "Oak panel"
    end
  end
end
