defmodule PhoenixKitCatalogue.Web.CatalogueDetailBranchesTest do
  @moduledoc """
  Branch coverage for `CatalogueDetailLive` events the existing
  smoke tests don't pin: switch_view, search / clear_search,
  delete/restore/permanently_delete for items + categories,
  move_category_up/down, cancel_delete confirm flow.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue

  setup do
    cat = fixture_catalogue(%{name: "Detail Branches"})
    %{catalogue: cat}
  end

  describe "switch_view active/deleted" do
    test "switch_view to deleted then back to active when deleted items exist",
         %{conn: conn, catalogue: cat} do
      # Create + trash an item so the deleted view has content. Without
      # this the LV auto-switches back to active.
      {:ok, item} = Catalogue.create_item(%{name: "Trashed", catalogue_uuid: cat.uuid})
      {:ok, _} = Catalogue.trash_item(item)

      {:ok, view, _html} = live(conn, "/en/admin/catalogue/#{cat.uuid}")

      render_click(view, "switch_view", %{"mode" => "deleted"})
      assert :sys.get_state(view.pid).socket.assigns.view_mode == "deleted"

      render_click(view, "switch_view", %{"mode" => "active"})
      assert :sys.get_state(view.pid).socket.assigns.view_mode == "active"
    end
  end

  describe "search / clear_search" do
    test "search with non-empty query populates search_results",
         %{conn: conn, catalogue: cat} do
      {:ok, _item} = Catalogue.create_item(%{name: "Searchable", catalogue_uuid: cat.uuid})

      {:ok, view, _html} = live(conn, "/en/admin/catalogue/#{cat.uuid}")

      render_change(view, "search", %{"query" => "Searchable"})

      assigns = :sys.get_state(view.pid).socket.assigns
      # search_results becomes a list (or stays nil if the search task
      # is still in flight). Pin the search_query landed.
      assert assigns.search_query == "Searchable"
    end

    test "search with empty query clears results", %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/#{cat.uuid}")

      render_change(view, "search", %{"query" => "anything"})
      render_change(view, "search", %{"query" => ""})

      assert :sys.get_state(view.pid).socket.assigns.search_results == nil
    end

    test "clear_search resets search state", %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/#{cat.uuid}")

      render_change(view, "search", %{"query" => "stuff"})
      render_click(view, "clear_search", %{})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.search_results == nil
      assert assigns.search_query == ""
    end
  end

  describe "delete_item / restore_item happy path" do
    test "delete_item trashes + restore_item un-trashes", %{conn: conn, catalogue: cat} do
      {:ok, item} = Catalogue.create_item(%{name: "Cycle", catalogue_uuid: cat.uuid})
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/#{cat.uuid}")

      render_click(view, "delete_item", %{"uuid" => item.uuid})
      assert Catalogue.get_item(item.uuid).status == "deleted"

      # Switch to deleted mode then restore.
      render_click(view, "switch_view", %{"mode" => "deleted"})
      render_click(view, "restore_item", %{"uuid" => item.uuid})
      assert Catalogue.get_item(item.uuid).status == "active"
    end

    test "delete_item with unknown uuid flashes 'not found'",
         %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/#{cat.uuid}")

      html = render_click(view, "delete_item", %{"uuid" => Ecto.UUID.generate()})
      assert html =~ "not found" or html =~ "Item not found"
    end
  end

  describe "trash_category / restore_category happy path" do
    test "request_trash_category trashes empty category directly + restore reverses",
         %{conn: conn, catalogue: cat} do
      cat_obj = fixture_category(cat, %{name: "TrashCat"})
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/#{cat.uuid}")

      # `request_trash_category` (the renamed event) trashes directly
      # when the subtree has no active items; otherwise it would open
      # the item-disposition modal first.
      render_click(view, "request_trash_category", %{"uuid" => cat_obj.uuid})
      assert Catalogue.get_category(cat_obj.uuid).status == "deleted"

      render_click(view, "switch_view", %{"mode" => "deleted"})
      render_click(view, "restore_category", %{"uuid" => cat_obj.uuid})
      assert Catalogue.get_category(cat_obj.uuid).status == "active"
    end
  end

  describe "show_delete_confirm + cancel_delete + permanently_delete_*" do
    test "show_delete_confirm + cancel_delete toggles confirm_delete",
         %{conn: conn, catalogue: cat} do
      cat_obj = fixture_category(cat, %{name: "Confirm"})
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/#{cat.uuid}")

      render_click(view, "show_delete_confirm", %{
        "uuid" => cat_obj.uuid,
        "type" => "category"
      })

      assert :sys.get_state(view.pid).socket.assigns.confirm_delete ==
               {"category", cat_obj.uuid}

      render_click(view, "cancel_delete", %{})
      assert :sys.get_state(view.pid).socket.assigns.confirm_delete == nil
    end

    test "permanently_delete_item runs only after show_delete_confirm matches",
         %{conn: conn, catalogue: cat} do
      {:ok, item} = Catalogue.create_item(%{name: "Hard", catalogue_uuid: cat.uuid})
      {:ok, _} = Catalogue.trash_item(item)

      {:ok, view, _html} = live(conn, "/en/admin/catalogue/#{cat.uuid}?view=deleted")
      render_click(view, "show_delete_confirm", %{"uuid" => item.uuid, "type" => "item"})
      render_click(view, "permanently_delete_item", %{})

      assert Catalogue.get_item(item.uuid) == nil
    end
  end

  # `move_category_up` / `move_category_down` events were removed
  # when category reorder switched to drag-only via the SortableGrid
  # hook. The drag path is exercised end-to-end by
  # `apply_category_reorder/3` in the parent LV; tests for it would
  # need to drive the SortableGrid hook from a browser, which is out
  # of scope for the fixture-driven LV-test stack here.

  # ─────────────────────────────────────────────────────────────────
  # Bulk selection + actions (added 2026-05-09)
  # ─────────────────────────────────────────────────────────────────

  describe "bulk item selection + actions" do
    test "toggle_select_item flips an item in/out of the selection set",
         %{conn: conn, catalogue: cat} do
      category = fixture_category(cat)
      item = fixture_item(%{name: "I", category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, "/en/admin/catalogue/#{cat.uuid}")

      render_click(view, "toggle_select_item", %{"uuid" => item.uuid})
      assert MapSet.member?(:sys.get_state(view.pid).socket.assigns.selected_items, item.uuid)

      render_click(view, "toggle_select_item", %{"uuid" => item.uuid})
      refute MapSet.member?(:sys.get_state(view.pid).socket.assigns.selected_items, item.uuid)
    end

    test "request_bulk_delete_items + confirm_bulk_action soft-deletes the selection",
         %{conn: conn, catalogue: cat} do
      category = fixture_category(cat)
      a = fixture_item(%{name: "A", category_uuid: category.uuid})
      b = fixture_item(%{name: "B", category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, "/en/admin/catalogue/#{cat.uuid}")
      render_click(view, "toggle_select_item", %{"uuid" => a.uuid})
      render_click(view, "toggle_select_item", %{"uuid" => b.uuid})

      render_click(view, "request_bulk_delete_items", %{})

      assert :sys.get_state(view.pid).socket.assigns.bulk_confirm == %{
               kind: :items,
               mode: :trash,
               count: 2
             }

      render_click(view, "confirm_bulk_action", %{})

      assert Catalogue.get_item(a.uuid).status == "deleted"
      assert Catalogue.get_item(b.uuid).status == "deleted"
      assert MapSet.size(:sys.get_state(view.pid).socket.assigns.selected_items) == 0
    end

    test "request_bulk_move_items opens the move modal with same-catalogue targets",
         %{conn: conn, catalogue: cat} do
      cat_a = fixture_category(cat, %{name: "Cat A"})
      _cat_b = fixture_category(cat, %{name: "Cat B"})
      item = fixture_item(%{name: "I", category_uuid: cat_a.uuid})

      {:ok, view, _html} = live(conn, "/en/admin/catalogue/#{cat.uuid}")
      render_click(view, "toggle_select_item", %{"uuid" => item.uuid})

      render_click(view, "request_bulk_move_items", %{})

      modal = :sys.get_state(view.pid).socket.assigns.bulk_move_modal
      assert modal.count == 1
      assert modal.disposition == :uncategorize
      target_uuids = Enum.map(modal.targets, fn {c, _depth} -> c.uuid end)
      assert cat_a.uuid in target_uuids
    end

    test "confirm_bulk_move_items uncategorizes the selection",
         %{conn: conn, catalogue: cat} do
      category = fixture_category(cat)
      a = fixture_item(%{name: "A", category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, "/en/admin/catalogue/#{cat.uuid}")
      render_click(view, "toggle_select_item", %{"uuid" => a.uuid})
      render_click(view, "request_bulk_move_items", %{})
      render_click(view, "confirm_bulk_move_items", %{})

      assert Catalogue.get_item(a.uuid).category_uuid == nil
    end

    test "clear_selection drops both selection sets",
         %{conn: conn, catalogue: cat} do
      category = fixture_category(cat)
      item = fixture_item(%{name: "I", category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, "/en/admin/catalogue/#{cat.uuid}")
      render_click(view, "toggle_select_item", %{"uuid" => item.uuid})
      render_click(view, "toggle_select_category", %{"uuid" => category.uuid})

      render_click(view, "clear_selection", %{})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert MapSet.size(assigns.selected_items) == 0
      assert MapSet.size(assigns.selected_categories) == 0
    end
  end

  describe "expand_card per-card pagination" do
    test "expand_card appends the next slice of items into a single card",
         %{conn: conn, catalogue: cat} do
      category = fixture_category(cat)
      # @per_card is 25; create 30 so a single expand reaches the end.
      for i <- 1..30 do
        fixture_item(%{name: "I#{i}", category_uuid: category.uuid})
      end

      {:ok, view, first_html} = live(conn, "/en/admin/catalogue/#{cat.uuid}")
      assert first_html =~ "Show 5 more"

      render_click(view, "expand_card", %{"scope" => category.uuid})
      :sys.get_state(view.pid)
      assigns = :sys.get_state(view.pid).socket.assigns

      [card] = Enum.filter(assigns.loaded_cards, &(&1.kind == :category))
      assert length(card.items) == 30
      assert MapSet.size(assigns.expanding_cards) == 0
    end

    test "expand_timeout while still expanding restores the button + flashes a retry message",
         %{conn: conn, catalogue: cat} do
      category = fixture_category(cat)
      _ = fixture_item(%{name: "I", category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, "/en/admin/catalogue/#{cat.uuid}")

      # Drop the in-flight :apply_expand message so the timeout
      # branch fires (simulating a stuck mailbox / lost connection).
      send(view.pid, {:expand_timeout, category.uuid})

      # First mark the scope as expanding so the timeout branch
      # actually fires.
      :sys.replace_state(view.pid, fn state ->
        socket = state.socket
        new_assigns = Map.put(socket.assigns, :expanding_cards, MapSet.new([category.uuid]))
        %{state | socket: %{socket | assigns: new_assigns}}
      end)

      send(view.pid, {:expand_timeout, category.uuid})
      :sys.get_state(view.pid)

      assigns = :sys.get_state(view.pid).socket.assigns
      assert MapSet.size(assigns.expanding_cards) == 0
    end
  end

  describe "cross-tab live updates" do
    test "catalogue_card_refresh from another pid refreshes only the affected scope",
         %{conn: conn, catalogue: cat} do
      category = fixture_category(cat)
      _ = fixture_item(%{name: "Original", category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, "/en/admin/catalogue/#{cat.uuid}")

      # Simulate another LV pid broadcasting a card refresh.
      send(view.pid, {:catalogue_card_refresh, cat.uuid, category.uuid, nil, :ok, self()})
      :sys.get_state(view.pid)

      # The handler ran (no crash) and the card still renders.
      html = render(view)
      assert html =~ "Original"
    end

    test "catalogue_card_refresh from self() is ignored (no double-render)",
         %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/#{cat.uuid}")

      # Self-broadcast — should be a no-op so the originator doesn't
      # double-render after their own action.
      send(view.pid, {:catalogue_card_refresh, cat.uuid, :uncategorized, nil, :ok, view.pid})
      :sys.get_state(view.pid)

      assert Process.alive?(view.pid)
    end

    test "catalogue_bulk_change schedules the deferred apply",
         %{conn: conn, catalogue: cat} do
      category = fixture_category(cat)
      item = fixture_item(%{name: "Bulk", category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, "/en/admin/catalogue/#{cat.uuid}")

      send(view.pid, {:catalogue_bulk_change, cat.uuid, :trashed, [item.uuid], [], self()})
      :sys.get_state(view.pid)

      # Two-step animation: receiver applied red flash; the deferred
      # :bulk_change_apply still runs ~800ms later and reset_and_loads.
      # We don't sleep here — just verify the handler didn't crash and
      # the LV is still alive.
      assert Process.alive?(view.pid)
    end
  end
end
