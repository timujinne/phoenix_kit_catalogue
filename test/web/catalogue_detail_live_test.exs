defmodule PhoenixKitCatalogue.Web.CatalogueDetailLiveTest do
  @moduledoc """
  End-to-end tests for CatalogueDetailLive — infinite scroll paging,
  view-mode toggle, search, item mutations preserving scroll, category
  reorder/trash/restore/permanent_delete, not-found redirect.
  """
  use PhoenixKitCatalogue.LiveCase

  alias PhoenixKitCatalogue.Catalogue

  @base "/en/admin/catalogue"

  defp url(uuid), do: "#{@base}/#{uuid}"

  # ─────────────────────────────────────────────────────────────────
  # Mount / render
  # ─────────────────────────────────────────────────────────────────

  describe "mount" do
    test "renders catalogue name and header actions in active mode", %{conn: conn} do
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

  # ─────────────────────────────────────────────────────────────────
  # Infinite scroll
  # ─────────────────────────────────────────────────────────────────

  describe "infinite scroll" do
    test "initial mount loads the first category's card", %{conn: conn} do
      catalogue = fixture_catalogue()
      cat_a = fixture_category(catalogue, %{name: "First", position: 0})
      _cat_b = fixture_category(catalogue, %{name: "Second", position: 1})

      for i <- 1..3 do
        fixture_item(%{name: "A#{i}", category_uuid: cat_a.uuid})
      end

      {:ok, _view, html} = live(conn, url(catalogue.uuid))

      assert html =~ "First"
      assert html =~ "A1"
    end

    test "every category renders eagerly with its own preview slice", %{conn: conn} do
      # 2026-05-09: Items tab swapped infinite scroll for per-card
      # expand (mirrors PdfSearchModal). All categories show on first
      # render with a 25-item preview + per-card "Show N more" button.
      catalogue = fixture_catalogue()
      cat_a = fixture_category(catalogue, %{name: "First", position: 0})
      cat_b = fixture_category(catalogue, %{name: "Second", position: 1})

      fixture_item(%{name: "A only", category_uuid: cat_a.uuid})
      fixture_item(%{name: "B only", category_uuid: cat_b.uuid})

      {:ok, _view, html} = live(conn, url(catalogue.uuid))

      assert html =~ "First"
      assert html =~ "A only"
      assert html =~ "Second"
      assert html =~ "B only"
    end

    test "expand_card loads more items into a single category", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)

      # @per_card is 25 — create 30 so an expand is needed.
      for i <- 1..30 do
        fixture_item(%{
          name: "Item #{String.pad_leading("#{i}", 3, "0")}",
          category_uuid: category.uuid
        })
      end

      {:ok, view, first_html} = live(conn, url(catalogue.uuid))

      # First render: items 001..025 visible, "Show 5 more" button visible.
      assert first_html =~ "Item 001"
      assert first_html =~ "Item 025"
      refute first_html =~ "Item 030"
      assert first_html =~ "Show 5 more"

      # `expand_card` is asynchronous: the event handler defers the
      # actual fetch via send/2 + a recovery `expand_timeout` so the
      # button can re-render in its loading state. Drain the LV's
      # mailbox by issuing any synchronous pull (e.g. another render)
      # — `:sys.get_state` waits for everything queued before it.
      render_click(view, "expand_card", %{"scope" => category.uuid})
      :sys.get_state(view.pid)
      html_after = render(view)

      assert html_after =~ "Item 026"
      assert html_after =~ "Item 030"
    end

    test "Uncategorized renders eagerly when the catalogue has loose items", %{conn: conn} do
      catalogue = fixture_catalogue()
      cat_a = fixture_category(catalogue, %{name: "Cat A"})

      fixture_item(%{name: "In Category", category_uuid: cat_a.uuid})
      fixture_item(%{name: "Loose Item", catalogue_uuid: catalogue.uuid})

      {:ok, _view, html} = live(conn, url(catalogue.uuid))

      assert html =~ "Cat A"
      assert html =~ "In Category"
      assert html =~ "Uncategorized"
      assert html =~ "Loose Item"
    end

    test "category card shows the total item count, not the loaded count", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)

      for i <- 1..30 do
        fixture_item(%{name: "I#{i}", category_uuid: category.uuid})
      end

      {:ok, _view, html} = live(conn, url(catalogue.uuid))

      # Badge shows total (30), not the first preview slice (25).
      assert html =~ "30 items"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # View mode (active / deleted tabs)
  # ─────────────────────────────────────────────────────────────────

  describe "view_mode toggle" do
    test "switch_view resets the cursor and reloads with deleted items", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      active = fixture_item(%{name: "Active item", category_uuid: category.uuid})
      deleted = fixture_item(%{name: "Deleted item", category_uuid: category.uuid})
      Catalogue.trash_item(deleted)

      {:ok, view, html} = live(conn, url(catalogue.uuid))

      assert html =~ "Active item"
      refute html =~ "Deleted item"

      html_after = render_click(view, "switch_view", %{"mode" => "deleted"})

      assert html_after =~ "Deleted item"
      refute html_after =~ active.uuid
    end

    test "Active tab badge shows the non-deleted item count", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      fixture_item(%{name: "A", category_uuid: category.uuid})
      fixture_item(%{name: "B", category_uuid: category.uuid})
      gone = fixture_item(%{name: "Gone", category_uuid: category.uuid})
      Catalogue.trash_item(gone)

      {:ok, _view, html} = live(conn, url(catalogue.uuid))
      # Active (2) and Deleted (1) tabs are present; check the Active count appears.
      assert html =~ "Active"
      assert html =~ "(2)"
      assert html =~ "Deleted"
      assert html =~ "(1)"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Item mutations (local updates — scroll is preserved)
  # ─────────────────────────────────────────────────────────────────

  describe "item mutations" do
    test "delete_item removes the item from the card without a full reload", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      item = fixture_item(%{name: "Doomed", category_uuid: category.uuid})
      fixture_item(%{name: "Survivor", category_uuid: category.uuid})

      {:ok, view, html} = live(conn, url(catalogue.uuid))
      assert html =~ "Doomed"

      html_after = render_click(view, "delete_item", %{"uuid" => item.uuid})

      refute html_after =~ "Doomed"
      assert html_after =~ "Survivor"
      # DB reflects the trash (status = "deleted")
      assert Catalogue.get_item(item.uuid).status == "deleted"
    end

    test "restore_item (from the Items tab Deleted view) marks the item active", %{conn: conn} do
      # After restore, the deleted view auto-flips back to Active because
      # `deleted_item_count` hits 0 — the restored item ends up visible
      # in the active stream rather than removed from the page entirely.
      # The behavioral pin is: the DB row is "active" and the page
      # doesn't crash.
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      item = fixture_item(%{name: "Comeback", category_uuid: category.uuid})
      Catalogue.trash_item(item)

      {:ok, view, _html} = live(conn, url(catalogue.uuid))
      html = render_click(view, "switch_view", %{"mode" => "deleted"})
      assert html =~ "Comeback"

      render_click(view, "restore_item", %{"uuid" => item.uuid})

      assert Catalogue.get_item(item.uuid).status == "active"
      assert Process.alive?(view.pid)
    end

    test "delete_item with a bogus uuid doesn't crash and leaves existing items untouched", %{
      conn: conn
    } do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      survivor = fixture_item(%{name: "Survivor", category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, url(catalogue.uuid))

      html =
        render_click(view, "delete_item", %{"uuid" => "00000000-0000-0000-0000-000000000000"})

      # Page still renders; survivor is still listed.
      assert html =~ "Survivor"
      assert Catalogue.get_item(survivor.uuid).status == "active"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Category mutations
  # ─────────────────────────────────────────────────────────────────

  describe "clickable names" do
    test "category name is a link to the category edit page in active mode", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue, %{name: "Clickable category"})

      {:ok, _view, html} = live(conn, url(catalogue.uuid))

      expected_href = "/en/admin/catalogue/categories/#{category.uuid}/edit"
      assert html =~ ~s(href="#{expected_href}")
      assert html =~ "Clickable category"
    end

    test "category name renders without an edit link in the Categories tab Deleted view",
         %{conn: conn} do
      # Items tab no longer renders trashed categories at all (the
      # "separate status" rule). The Categories tab Deleted view shows
      # the category as a plain row with no edit link — restore /
      # delete-forever buttons replace the per-card actions.
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue, %{name: "Deleted category"})
      Catalogue.trash_category(category)

      {:ok, view, _html} = live(conn, url(catalogue.uuid) <> "?tab=categories")
      html = render_click(view, "switch_view", %{"mode" => "deleted"})

      assert html =~ "Deleted category"
      # No edit link to the deleted category — only Restore + Delete Forever.
      refute html =~ "/en/admin/catalogue/categories/#{category.uuid}/edit"
    end

    test "item name in the card body is a link to the item edit page", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      item = fixture_item(%{name: "Clickable item", category_uuid: category.uuid})

      {:ok, _view, html} = live(conn, url(catalogue.uuid))

      expected_href = "/en/admin/catalogue/items/#{item.uuid}/edit"
      assert html =~ ~s(href="#{expected_href}")
      assert html =~ "Clickable item"
    end
  end

  describe "category mutations" do
    test "request_trash_category removes the category card when the subtree is empty",
         %{conn: conn} do
      # `request_trash_category` (the renamed event) trashes directly
      # when the subtree has no active items. With items it would
      # open the disposition modal first; here both fixtures are empty.
      catalogue = fixture_catalogue()
      cat_a = fixture_category(catalogue, %{name: "Trashable", position: 0})
      _cat_b = fixture_category(catalogue, %{name: "Staying", position: 1})

      {:ok, view, html} = live(conn, url(catalogue.uuid))
      assert html =~ "Trashable"

      html_after = render_click(view, "request_trash_category", %{"uuid" => cat_a.uuid})
      refute html_after =~ "Trashable"
      assert html_after =~ "Staying"
    end

    test "restore_category in deleted mode brings it back and auto-flips to active", %{
      conn: conn
    } do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue, %{name: "Brought Back"})
      Catalogue.trash_category(category)

      {:ok, view, _html} = live(conn, url(catalogue.uuid))
      _deleted_html = render_click(view, "switch_view", %{"mode" => "deleted"})

      html_after = render_click(view, "restore_category", %{"uuid" => category.uuid})
      # Either the category is now shown in the page (if we're still on
      # deleted mode and there are other deleted things) or the view
      # auto-flipped back to active. Either way it must now be visible.
      assert html_after =~ "Brought Back"
    end

    # `move_category_up` / `move_category_down` events were removed
    # when category reorder switched to drag-only via the SortableGrid
    # hook. The new wire is the `reorder_categories` event the hook
    # pushes; LV-test coverage of drag would need to drive SortableJS
    # from a browser, out of scope for this fixture-driven stack.
  end

  # ─────────────────────────────────────────────────────────────────
  # Search
  # ─────────────────────────────────────────────────────────────────

  describe "search" do
    test "search shows matching items and hides the infinite-scroll cards", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue, %{name: "Hidden while searching"})
      fixture_item(%{name: "Oak panel", category_uuid: category.uuid})
      fixture_item(%{name: "Pine board", category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, url(catalogue.uuid))

      render_change(view, "search", %{"query" => "oak"})
      # Search runs via start_async — wait for handle_async to land before asserting.
      html_after = render_async(view)

      # Search results visible
      assert html_after =~ "Oak panel"
      # Pine board excluded from results
      refute html_after =~ "Pine board"
    end

    test "empty search query falls back to normal paged view", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      fixture_item(%{name: "Only item", category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, url(catalogue.uuid))

      render_change(view, "search", %{"query" => "anything"})
      _after_search = render_async(view)
      html_after = render_change(view, "search", %{"query" => ""})

      # Back to the normal view
      assert html_after =~ "Only item"
    end

    test "clear_search restores the paged view", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      fixture_item(%{name: "Item", category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, url(catalogue.uuid))
      render_change(view, "search", %{"query" => "nothing matches"})
      _ = render_async(view)
      html_after = render_click(view, "clear_search", %{})

      assert html_after =~ "Item"
    end

    test "shows a loading indicator for the first search before results land", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      fixture_item(%{name: "Oak panel", category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, url(catalogue.uuid))
      html_pending = render_change(view, "search", %{"query" => "oak"})

      # While the async task is still running, the user sees a "Searching"
      # indicator — not stale data or silence.
      assert html_pending =~ "Searching for"
      assert html_pending =~ "loading-spinner"

      html_after = render_async(view)

      # Once the async lands, the spinner is gone and results are visible.
      refute html_after =~ "Searching for"
      assert html_after =~ "Oak panel"
    end

    test "dims previous results while a newer query is loading", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      fixture_item(%{name: "Oak panel", category_uuid: category.uuid})
      fixture_item(%{name: "Pine board", category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, url(catalogue.uuid))

      # First search settles.
      render_change(view, "search", %{"query" => "oak"})
      _ = render_async(view)

      # Second search fires — while pending, prior "oak" results are dimmed.
      html_pending = render_change(view, "search", %{"query" => "pine"})

      assert html_pending =~ "opacity-50"
      # Spinner visible next to the summary
      assert html_pending =~ "loading-spinner"
    end
  end
end
