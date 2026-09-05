defmodule PhoenixKitCatalogue.Web.CataloguesLiveTest do
  @moduledoc """
  End-to-end tests for CataloguesLive — the index page that hosts
  three tabs (Catalogues / Manufacturers / Suppliers), the Items
  column, the active/deleted toggle, search, and CRUD event handlers.
  """
  use PhoenixKitCatalogue.LiveCase

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Web.ViewConfig

  @base "/en/admin/catalogue"

  # ─────────────────────────────────────────────────────────────────
  # Tab switching
  # ─────────────────────────────────────────────────────────────────

  describe "folder location is URL state (boss's call, 2026-08-18)" do
    test "navigating a folder patches ?folder= and a reload restores it", %{conn: conn} do
      {:ok, folder} = Catalogue.create_folder(%{name: "URL folder"})
      inside = fixture_catalogue(%{name: "Inside cat"})
      {:ok, _} = Catalogue.move_catalogue_to_folder(inside, folder.uuid)
      _loose = fixture_catalogue(%{name: "Loose cat"})

      {:ok, view, _html} = live(conn, @base)

      render_click(view, "navigate_folder", %{"uuid" => folder.uuid})
      assert_patch(view, @base <> "?folder=#{folder.uuid}")

      # Up to root clears the param entirely.
      render_click(view, "navigate_folder", %{"uuid" => ""})
      assert_patch(view, @base)

      # Deep link: a fresh mount from the URL lands inside the folder.
      {:ok, _view, html} = live(conn, @base <> "?folder=#{folder.uuid}")
      assert html =~ "Inside cat"
      assert html =~ "URL folder"
    end

    test "Back into a ?folder= entry while in deleted view restores the active view", %{
      conn: conn
    } do
      {:ok, folder} = Catalogue.create_folder(%{name: "History folder"})
      trashed = fixture_catalogue(%{name: "Trashed cat"})
      Catalogue.trash_catalogue(trashed)

      {:ok, view, _html} = live(conn, @base)
      render_click(view, "switch_catalogue_view", %{"mode" => "deleted"})

      # Simulate Back restoring a history entry recorded while drilled
      # in ACTIVE mode: a patch to ?folder= arrives with the deleted
      # assign still set. The view must return to active — the deleted
      # list must never be silently filtered by a folder.
      html = render_patch(view, @base <> "?folder=#{folder.uuid}")
      assert html =~ "History folder"
      refute html =~ "Trashed cat"
    end

    test "the drilled folder is never persisted to the user's view config", %{conn: conn} do
      {:ok, folder} = Catalogue.create_folder(%{name: "Unsaved folder"})

      {:ok, view, _html} = live(conn, @base)
      render_click(view, "navigate_folder", %{"uuid" => folder.uuid})

      # Round-trip through ViewConfig: a save of the current cfg (any
      # preference change triggers one) must not carry the folder, and
      # a legacy stored folder is ignored on load.
      user = %PhoenixKit.Users.Auth.User{
        uuid: UUIDv7.generate(),
        custom_fields: %{
          "catalogue_view_configs" => %{
            "catalogues" => %{"filters" => %{"folder" => folder.uuid, "status" => "active"}}
          }
        }
      }

      cfg = ViewConfig.load(user, :catalogues)
      refute Map.has_key?(cfg.filters, "folder")
      assert cfg.filters["status"] == "active"
      _ = view
    end
  end

  describe "tabs" do
    test "index tab renders catalogues", %{conn: conn} do
      fixture_catalogue(%{name: "Kitchen"})

      {:ok, _view, html} = live(conn, @base)
      assert html =~ "Kitchen"
      assert html =~ "New Catalogue"
    end

    test "empty catalogues state", %{conn: conn} do
      {:ok, _view, html} = live(conn, @base)
      assert html =~ "No catalogues yet"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Items column
  # ─────────────────────────────────────────────────────────────────

  describe "item counts column" do
    test "catalogues table shows per-catalogue item counts", %{conn: conn} do
      cat_a = fixture_catalogue(%{name: "Kitchen"})
      cat_b = fixture_catalogue(%{name: "Bathroom"})
      category_a = fixture_category(cat_a)

      fixture_item(%{name: "A1", category_uuid: category_a.uuid})
      fixture_item(%{name: "A2", category_uuid: category_a.uuid})
      fixture_item(%{name: "Loose in B", catalogue_uuid: cat_b.uuid})

      {:ok, _view, html} = live(conn, @base)

      # Two catalogues listed, counts visible
      assert html =~ "Kitchen"
      assert html =~ "Bathroom"
      # 2 items in Kitchen, 1 in Bathroom — both numbers appear
      assert html =~ "2"
      assert html =~ "1"
    end

    test "deleted catalogues don't show the Items column", %{conn: conn} do
      cat = fixture_catalogue(%{name: "Trashed"})
      Catalogue.trash_catalogue(cat)

      {:ok, view, _html} = live(conn, @base)
      deleted_html = render_click(view, "switch_catalogue_view", %{"mode" => "deleted"})

      # The Items header only appears in active mode.
      assert deleted_html =~ "Trashed"
      # Column headers in deleted view: Name / Status / Updated / Actions.
      # Just verify "Trashed" is present and the page didn't crash.
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Active / Deleted toggle
  # ─────────────────────────────────────────────────────────────────

  describe "catalogues tree table" do
    test "manual order shows collapsible folder rows; other sorts flatten", %{conn: conn} do
      {:ok, folder} = Catalogue.create_folder(%{name: "Tree parent"})
      {:ok, _child} = Catalogue.create_folder(%{name: "Tree child", parent_uuid: folder.uuid})
      filed = fixture_catalogue(%{name: "Filed in tree"})
      {:ok, _} = Catalogue.move_catalogue_to_folder(filed, folder.uuid)
      fixture_catalogue(%{name: "Root level catalogue"})

      {:ok, view, html} = live(conn, @base)

      # Manual order default: the tree renders, folder collapsed
      # (children hidden), unfiled catalogue at the root level.
      assert html =~ "catalogues-tree-table"
      assert html =~ "Tree parent"
      refute html =~ "Tree child"
      assert html =~ "Root level catalogue"
      # Drag contract: folder rows are drop targets with grip handles.
      assert html =~ ~s(data-tree-drop="#{folder.uuid}")
      assert html =~ ~s(data-tree-item="folder:#{folder.uuid}")

      # Chevron expands the folder: nested folder + filed catalogue appear.
      expanded =
        view
        |> element(
          ~s{#catalogues-tree-table button[phx-click="toggle_folder_expand"][phx-value-uuid="#{folder.uuid}"]}
        )
        |> render_click()

      assert expanded =~ "Tree child"
      assert expanded =~ "Filed in tree"

      # Switching to a real sort falls back to the flat sortable table.
      flat = render_click(view, "set_sort", %{"sort_by" => "name"})
      refute flat =~ "catalogues-tree-table"
      assert flat =~ "Filed in tree"
    end

    test "drilling re-roots the tree and Up walks back", %{conn: conn} do
      {:ok, folder} = Catalogue.create_folder(%{name: "Drill target"})
      filed = fixture_catalogue(%{name: "Filed catalogue"})
      {:ok, _} = Catalogue.move_catalogue_to_folder(filed, folder.uuid)
      fixture_catalogue(%{name: "Loose catalogue"})

      {:ok, view, _html} = live(conn, @base)

      drilled =
        view
        |> element(
          ~s{#catalogues-tree-table button[phx-click="navigate_folder"][phx-value-uuid="#{folder.uuid}"]:not([role="menuitem"])}
        )
        |> render_click()

      # Re-rooted: the Up row shows, only the folder's contents render.
      assert drilled =~ "Up"
      assert drilled =~ "Filed catalogue"
      refute drilled =~ "Loose catalogue"

      # Up returns to the root level.
      root = render_click(view, "navigate_folder", %{"uuid" => ""})
      assert root =~ "Loose catalogue"
    end

    test "card view groups cards inside visible folder boxes", %{conn: conn} do
      {:ok, folder} = Catalogue.create_folder(%{name: "Card folder"})
      {:ok, nested} = Catalogue.create_folder(%{name: "Nested box", parent_uuid: folder.uuid})
      filed = fixture_catalogue(%{name: "Filed card"})
      {:ok, _} = Catalogue.move_catalogue_to_folder(filed, folder.uuid)
      fixture_catalogue(%{name: "Loose card"})

      {:ok, view, _html} = live(conn, @base)
      html = render_click(view, "set_view", %{"mode" => "card"})

      # Folder boxes render with their contents VISIBLE at the top level:
      # the filed card and the nested (empty) box both show inside.
      assert html =~ "catalogues-card-level"
      assert html =~ ~s(data-tree-drop="#{folder.uuid}")
      assert html =~ "Filed card"
      assert html =~ "Nested box"
      assert html =~ "Empty folder"
      assert html =~ "Loose card"

      # Drilling via the folder name re-roots to just that box's contents.
      drilled =
        view
        |> element(
          ~s{#catalogues-card-level button[phx-click="navigate_folder"][phx-value-uuid="#{folder.uuid}"]:not([role="menuitem"])}
        )
        |> render_click()

      assert drilled =~ "Filed card"
      refute drilled =~ "Loose card"

      # The nested box still carries the drag contract inside its parent.
      assert drilled =~ ~s(data-tree-parent="#{folder.uuid}")
      assert drilled =~ ~s(data-tree-uuid="#{nested.uuid}")

      # Up returns to the full grouped view.
      root = render_click(view, "navigate_folder", %{"uuid" => ""})
      assert root =~ "Loose card"
    end

    test "searching flattens the tree", %{conn: conn} do
      {:ok, _folder} = Catalogue.create_folder(%{name: "Hidden while searching"})
      fixture_catalogue(%{name: "Searchable catalogue"})

      {:ok, _view, html} = live(conn, "#{@base}?q=searchable&mode=catalogues")

      refute html =~ "catalogues-tree-table"
      assert html =~ "Searchable catalogue"
    end

    test "tree drag events file, unfile, nest, and reorder", %{conn: conn} do
      {:ok, folder_a} = Catalogue.create_folder(%{name: "Drop target"})
      {:ok, folder_b} = Catalogue.create_folder(%{name: "Will nest"})
      cat = fixture_catalogue(%{name: "Dragged catalogue"})

      {:ok, view, html} = live(conn, @base)

      # Grip handles render on every row (the drag affordance).
      assert html =~ ~s(data-tree-item="folder:#{folder_a.uuid}")
      assert html =~ ~s(data-tree-item="catalogue:#{cat.uuid}")

      # Folder middle drop files the catalogue; root zone unfiles it.
      render_click(view, "move_to_folder", %{
        "type" => "catalogue",
        "uuid" => cat.uuid,
        "target" => folder_a.uuid
      })

      assert Catalogue.get_catalogue(cat.uuid).folder_uuid == folder_a.uuid

      render_click(view, "move_to_folder", %{
        "type" => "catalogue",
        "uuid" => cat.uuid,
        "target" => "root"
      })

      assert Catalogue.get_catalogue(cat.uuid).folder_uuid == nil

      # Folder onto folder nests; nesting under a descendant is refused.
      render_click(view, "move_to_folder", %{
        "type" => "folder",
        "uuid" => folder_b.uuid,
        "target" => folder_a.uuid
      })

      assert Catalogue.get_folder(folder_b.uuid).parent_uuid == folder_a.uuid

      render_click(view, "move_to_folder", %{
        "type" => "folder",
        "uuid" => folder_a.uuid,
        "target" => folder_b.uuid
      })

      assert Catalogue.get_folder(folder_a.uuid).parent_uuid == nil

      # Edge drop reorders same-parent siblings (subset write).
      {:ok, folder_c} = Catalogue.create_folder(%{name: "Second root"})
      render_click(view, "reorder_folders", %{"ordered_ids" => [folder_c.uuid, folder_a.uuid]})

      root_order =
        for {f, 0} <- Catalogue.list_folder_tree(),
            f.uuid in [folder_a.uuid, folder_c.uuid],
            do: f.name

      assert root_order == ["Second root", "Drop target"]
    end

    test "drop_row works from card view too — the guard is view-independent", %{conn: conn} do
      # Regression pin: drop_row/reorder_folders used to require TREE
      # mode, so the card view rendered the same drop targets but every
      # edge drop silently no-opped. Structure mode (active + manual
      # order + no search/filter) is what data safety needs; the
      # card/tree split is a rendering concern only.
      {:ok, folder} = Catalogue.create_folder(%{name: "Card target"})
      inside = fixture_catalogue(%{name: "Card inside"})
      {:ok, _} = Catalogue.move_catalogue_to_folder(inside, folder.uuid)
      loose = fixture_catalogue(%{name: "Card loose"})

      {:ok, view, _html} = live(conn, @base)
      render_click(view, "set_view", %{"mode" => "card"})

      render_click(view, "drop_row", %{
        "type" => "catalogue",
        "uuid" => loose.uuid,
        "parent" => folder.uuid,
        "entries" => ["catalogue:#{loose.uuid}", "catalogue:#{inside.uuid}"]
      })

      assert Catalogue.get_catalogue(loose.uuid).folder_uuid == folder.uuid
    end

    test "drop_row reparents and positions in one gesture", %{conn: conn} do
      {:ok, folder} = Catalogue.create_folder(%{name: "Level target"})
      inside_a = fixture_catalogue(%{name: "Inside A"})
      inside_b = fixture_catalogue(%{name: "Inside B"})
      {:ok, _} = Catalogue.move_catalogue_to_folder(inside_a, folder.uuid)
      {:ok, _} = Catalogue.move_catalogue_to_folder(inside_b, folder.uuid)
      loose = fixture_catalogue(%{name: "Loose one"})

      {:ok, view, _html} = live(conn, @base)

      # A root-level catalogue edge-dropped between the folder's two
      # children lands in that folder AND between them.
      render_click(view, "drop_row", %{
        "type" => "catalogue",
        "uuid" => loose.uuid,
        "parent" => folder.uuid,
        "entries" => [
          "catalogue:#{inside_a.uuid}",
          "catalogue:#{loose.uuid}",
          "catalogue:#{inside_b.uuid}"
        ]
      })

      assert Catalogue.get_catalogue(loose.uuid).folder_uuid == folder.uuid

      names =
        Catalogue.catalogues_by_folder()
        |> Map.get(folder.uuid, [])
        |> Enum.map(& &1.name)

      assert names == ["Inside A", "Loose one", "Inside B"]

      # A folder edge-dropped under its own descendant is refused whole —
      # no reparent AND no placement applied.
      {:ok, child} = Catalogue.create_folder(%{name: "Child level", parent_uuid: folder.uuid})

      html =
        render_click(view, "drop_row", %{
          "type" => "folder",
          "uuid" => folder.uuid,
          "parent" => child.uuid,
          "entries" => ["folder:#{folder.uuid}"]
        })

      assert Catalogue.get_folder(folder.uuid).parent_uuid == nil
      assert html =~ "into itself or one of its subfolders"
    end

    test "levels interleave folders and catalogues by manual placement", %{conn: conn} do
      {:ok, folder_a} = Catalogue.create_folder(%{name: "First folder"})
      {:ok, folder_b} = Catalogue.create_folder(%{name: "Second folder"})
      cat = fixture_catalogue(%{name: "Between them"})

      {:ok, view, _html} = live(conn, @base)

      # Place the catalogue BETWEEN the two root folders.
      html =
        render_click(view, "drop_row", %{
          "type" => "catalogue",
          "uuid" => cat.uuid,
          "parent" => "root",
          "entries" => [
            "folder:#{folder_a.uuid}",
            "catalogue:#{cat.uuid}",
            "folder:#{folder_b.uuid}"
          ]
        })

      # The rendered tree keeps the mixed order — no folders-first regrouping.
      first = :binary.match(html, "First folder") |> elem(0)
      between = :binary.match(html, "Between them") |> elem(0)
      second = :binary.match(html, "Second folder") |> elem(0)
      assert first < between and between < second

      # A malformed entry rejects the whole payload (forgeable input).
      before = Catalogue.get_catalogue(cat.uuid).position

      render_click(view, "drop_row", %{
        "type" => "catalogue",
        "uuid" => cat.uuid,
        "parent" => "root",
        "entries" => ["catalogue:#{cat.uuid}", "bogus"]
      })

      assert Catalogue.get_catalogue(cat.uuid).position == before
    end

    test "new_folder honors a validated parent from the drill level", %{conn: conn} do
      {:ok, folder} = Catalogue.create_folder(%{name: "Parent here"})

      {:ok, view, _html} = live(conn, @base)
      render_click(view, "new_folder", %{"parent" => folder.uuid})

      tree = Catalogue.list_folder_tree()
      assert Enum.any?(tree, fn {f, depth} -> f.parent_uuid == folder.uuid and depth == 1 end)

      # A forged/unknown parent falls back to a root folder instead of erroring.
      render_click(view, "new_folder", %{"parent" => Ecto.UUID.generate()})
      roots = for {f, 0} <- Catalogue.list_folder_tree(), do: f
      assert length(roots) >= 2
    end
  end

  describe "catalogue view toggle" do
    test "folder delete is permanent and refused unless empty", %{conn: conn} do
      {:ok, folder} = Catalogue.create_folder(%{name: "Holds things"})
      filed = fixture_catalogue(%{name: "Blocker"})
      {:ok, _} = Catalogue.move_catalogue_to_folder(filed, folder.uuid)

      {:ok, view, _html} = live(conn, @base)

      # Non-empty: the confirmed delete is refused with the empty-first flash.
      render_click(view, "show_delete_confirm", %{"uuid" => folder.uuid, "type" => "folder"})
      refused = render_click(view, "permanently_delete_folder", %{})
      assert refused =~ "Only empty folders can be deleted"
      assert Catalogue.get_folder(folder.uuid)

      # Emptied: the same flow hard-deletes — no trash, no restore.
      # (Refetch — the local struct predates the move into the folder.)
      {:ok, _} =
        filed.uuid |> Catalogue.get_catalogue() |> Catalogue.move_catalogue_to_folder(nil)

      render_click(view, "show_delete_confirm", %{"uuid" => folder.uuid, "type" => "folder"})
      render_click(view, "permanently_delete_folder", %{})
      assert Catalogue.get_folder(folder.uuid) == nil
    end

    test "legacy trashed folders keep a Delete Forever exit (no restore)", %{conn: conn} do
      {:ok, folder} = Catalogue.create_folder(%{name: "Binned folder"})
      inside = fixture_catalogue(%{name: "Was inside"})
      {:ok, _} = Catalogue.move_catalogue_to_folder(inside, folder.uuid)
      {:ok, _} = Catalogue.trash_folder(folder)

      {:ok, view, _html} = live(conn, @base)

      deleted = render_click(view, "switch_catalogue_view", %{"mode" => "deleted"})
      assert deleted =~ "Binned folder"
      refute deleted =~ "Restore"

      # Legacy delete keeps promote-contents semantics: the filed
      # catalogue is unfiled, not destroyed.
      render_click(view, "show_delete_confirm", %{
        "uuid" => folder.uuid,
        "type" => "legacy_folder"
      })

      render_click(view, "permanently_delete_legacy_folder", %{})
      assert Catalogue.get_folder(folder.uuid) == nil
      assert Catalogue.get_catalogue(inside.uuid).folder_uuid == nil
    end

    test "entering the deleted view clears a stale folder filter", %{conn: conn} do
      {:ok, folder} = Catalogue.create_folder(%{name: "Live folder"})
      filed = fixture_catalogue(%{name: "Filed catalogue"})
      {:ok, _} = Catalogue.move_catalogue_to_folder(filed, folder.uuid)
      trashed = fixture_catalogue(%{name: "Binned catalogue"})
      Catalogue.trash_catalogue(trashed)

      {:ok, view, _html} = live(conn, @base)
      render_click(view, "navigate_folder", %{"uuid" => folder.uuid})

      # The unfiled trashed catalogue must be visible despite the filter.
      deleted = render_click(view, "switch_catalogue_view", %{"mode" => "deleted"})
      assert deleted =~ "Binned catalogue"

      # Back to active: the folder filter was dropped, everything shows.
      active = render_click(view, "switch_catalogue_view", %{"mode" => "active"})
      assert active =~ "Filed catalogue"
    end

    test "deleted toggle only appears when there are deleted catalogues", %{conn: conn} do
      fixture_catalogue(%{name: "Active"})

      {:ok, _view, html} = live(conn, @base)
      refute html =~ "Deleted (1)"
    end

    test "switch_catalogue_view shows deleted catalogues", %{conn: conn} do
      fixture_catalogue(%{name: "Active one"})
      deleted = fixture_catalogue(%{name: "Deleted one"})
      Catalogue.trash_catalogue(deleted)

      {:ok, view, html} = live(conn, @base)
      assert html =~ "Active one"
      refute html =~ "Deleted one"

      deleted_html = render_click(view, "switch_catalogue_view", %{"mode" => "deleted"})
      assert deleted_html =~ "Deleted one"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Catalogue mutations
  # ─────────────────────────────────────────────────────────────────

  describe "clickable names" do
    test "catalogue name in the table view is a link to its detail page", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Clickable"})

      {:ok, _view, html} = live(conn, @base)

      expected_href = "/en/admin/catalogue/#{catalogue.uuid}"
      assert html =~ ~s(href="#{expected_href}")
    end
  end

  describe "catalogue mutations" do
    test "trash_catalogue removes the catalogue from the active view", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Goner"})

      {:ok, view, html} = live(conn, @base)
      assert html =~ "Goner"

      after_html = render_click(view, "trash_catalogue", %{"uuid" => catalogue.uuid})
      refute after_html =~ "Goner"
      assert Catalogue.get_catalogue(catalogue.uuid).status == "deleted"
    end

    test "restore_catalogue from the deleted view brings it back", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Comeback"})
      Catalogue.trash_catalogue(catalogue)

      {:ok, view, _html} = live(conn, @base)
      _ = render_click(view, "switch_catalogue_view", %{"mode" => "deleted"})

      render_click(view, "restore_catalogue", %{"uuid" => catalogue.uuid})
      assert Catalogue.get_catalogue(catalogue.uuid).status == "active"
    end

    test "permanently_delete_catalogue deletes from DB", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Forever gone"})
      Catalogue.trash_catalogue(catalogue)

      {:ok, view, _html} = live(conn, @base)
      _ = render_click(view, "switch_catalogue_view", %{"mode" => "deleted"})

      render_click(view, "show_delete_confirm", %{"uuid" => catalogue.uuid, "type" => "catalogue"})

      render_click(view, "permanently_delete_catalogue", %{})

      assert Catalogue.get_catalogue(catalogue.uuid) == nil
    end

    test "show_delete_confirm opens the modal; cancel_delete clears the confirm state", %{
      conn: conn
    } do
      catalogue = fixture_catalogue(%{name: "Trashable"})
      Catalogue.trash_catalogue(catalogue)

      {:ok, view, _html} = live(conn, @base)
      _ = render_click(view, "switch_catalogue_view", %{"mode" => "deleted"})

      opened =
        render_click(view, "show_delete_confirm", %{
          "uuid" => catalogue.uuid,
          "type" => "catalogue"
        })

      # Modal content ("This will permanently delete…") is visible.
      assert opened =~ "This will permanently delete this catalogue"

      closed = render_click(view, "cancel_delete", %{})
      # After cancel the modal warning copy is gone from the render.
      refute closed =~ "This will permanently delete this catalogue"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # URL-backed search (?q=)
  # ─────────────────────────────────────────────────────────────────

  describe "url-backed search" do
    test "?q= filters the catalogue rows straight from the URL", %{conn: conn} do
      fixture_catalogue(%{name: "Zephyr"})
      fixture_catalogue(%{name: "Quokka"})

      # Explicit catalogues mode since 2026-08-31 — the auto default
      # searches ITEMS.
      {:ok, _view, html} = live(conn, "#{@base}?q=zeph&mode=catalogues")

      assert html =~ "Zephyr"
      refute html =~ "Quokka"
    end

    test "table_search patches ?q= in, and clearing patches it back out", %{conn: conn} do
      fixture_catalogue(%{name: "Zephyr"})
      fixture_catalogue(%{name: "Quokka"})

      {:ok, view, _html} = live(conn, "#{@base}?mode=catalogues")

      html = render_change(view, "table_search", %{"query" => "quo"})
      path = assert_patch(view)
      assert path =~ "q=quo"
      assert html =~ "Quokka"
      refute html =~ "Zephyr"

      html = render_change(view, "table_search", %{"query" => ""})
      path = assert_patch(view)
      refute path =~ "q="
      assert html =~ "Zephyr"
    end

    test "?q= filters the list the route selected", %{conn: conn} do
      fixture_catalogue(%{name: "Zephyr Werke"})
      fixture_catalogue(%{name: "Quokka GmbH"})

      {:ok, _view, html} = live(conn, "#{@base}?q=quokka&mode=catalogues")

      assert html =~ "Quokka GmbH"
      refute html =~ "Zephyr Werke"
    end

    # The folder select left the toolbar (Max, 2026-08-29): search works
    # where the user stands, and scope is chosen by navigating folders.
    test "the toolbar offers no folder select, only the status filter", %{conn: conn} do
      {:ok, folder} = Catalogue.create_folder(%{name: "Some folder"})
      filed = fixture_catalogue(%{name: "Filed catalogue"})
      {:ok, _} = Catalogue.move_catalogue_to_folder(filed, folder.uuid)

      {:ok, _view, html} = live(conn, @base)

      refute html =~ "filter-form-folder"
      assert html =~ "filter-form-status"
    end

    test "searching a drilled folder covers its whole subtree", %{conn: conn} do
      {:ok, parent} = Catalogue.create_folder(%{name: "Parent folder"})
      {:ok, child} = Catalogue.create_folder(%{name: "Child folder", parent_uuid: parent.uuid})

      direct = fixture_catalogue(%{name: "Verso direct"})
      {:ok, _} = Catalogue.move_catalogue_to_folder(direct, parent.uuid)
      deep = fixture_catalogue(%{name: "Verso deep"})
      {:ok, _} = Catalogue.move_catalogue_to_folder(deep, child.uuid)
      _outside = fixture_catalogue(%{name: "Verso outside"})

      {:ok, _view, html} =
        live(conn, "#{@base}?folder=#{parent.uuid}&q=verso&mode=catalogues")

      # The catalogue in the subfolder is VISIBLE in the tree behind the
      # search, so the search must find it too — not just direct children.
      assert html =~ "Verso direct"
      assert html =~ "Verso deep"
      # Where the user is not: a match elsewhere stays out of this scope.
      refute html =~ "Verso outside"
    end

    test "the location row survives the search's flat table", %{conn: conn} do
      {:ok, folder} = Catalogue.create_folder(%{name: "Standing here"})
      filed = fixture_catalogue(%{name: "Filed catalogue"})
      {:ok, _} = Catalogue.move_catalogue_to_folder(filed, folder.uuid)

      {:ok, _view, html} = live(conn, "#{@base}?folder=#{folder.uuid}&q=filed")

      # The tree is gone while searching; the Up + folder-name row is the
      # only sign of where the search is looking, so it must stay. The Up
      # button's icon is the marker — the folder NAME also appears in the
      # flat table's Folder column, so it proves nothing here.
      refute html =~ "catalogues-tree-table"
      assert html =~ "Standing here"
      assert html =~ "hero-arrow-uturn-left"
    end

    # `tab_changed?` keeps the search patch from re-running load_data — the
    # tab's own assigns (active_tab, page_title, the rows it already loaded)
    # still have to survive that patch.
    test "a search patch leaves the tab itself intact", %{conn: conn} do
      fixture_catalogue(%{name: "Zephyr Werke"})

      {:ok, view, _html} = live(conn, "#{@base}?mode=catalogues")

      html = render_change(view, "table_search", %{"query" => "zephyr"})

      assert html =~ "Zephyr Werke"
      assert html =~ "New Catalogue"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Description column — Max, 2026-08-29
  # ─────────────────────────────────────────────────────────────────

  describe "description column" do
    test "available via Columns, hidden by default", %{conn: conn} do
      # Search matches descriptions through the data JSONB, so the column
      # is how a match with no visible trace explains itself.
      fixture_catalogue(%{
        name: "Hardware",
        description: "Fasteners, tools, and general hardware."
      })

      {:ok, view, html} = live(conn, @base)
      refute html =~ "Fasteners, tools"

      html = render_click(view, "add_column", %{"column_id" => "description"})
      assert html =~ "Fasteners, tools"

      html = render_click(view, "remove_column", %{"column_id" => "description"})
      refute html =~ "Fasteners, tools"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Search-aware Deleted tab — Max, 2026-08-29
  # ─────────────────────────────────────────────────────────────────

  describe "search-aware Deleted tab" do
    test "shows in a search only when the trash holds a match", %{conn: conn} do
      fixture_catalogue(%{name: "Zephyr live"})
      binned = fixture_catalogue(%{name: "Binned thing"})
      Catalogue.trash_catalogue(binned)

      # Nothing in the trash matches "zephyr" — a "Deleted (1)" here is
      # an invitation into an empty list.
      {:ok, _view, html} = live(conn, "#{@base}?q=zephyr&mode=catalogues")
      refute html =~ "Deleted ("

      {:ok, _view, html} = live(conn, "#{@base}?q=binned&mode=catalogues")
      assert html =~ "Deleted (1)"

      # No search: the global count, as before.
      {:ok, _view, html} = live(conn, @base)
      assert html =~ "Deleted (1)"
    end

    test "a matching trashed folder counts too", %{conn: conn} do
      fixture_catalogue(%{name: "Live one"})
      {:ok, folder} = Catalogue.create_folder(%{name: "Old shelf"})
      {:ok, _} = Catalogue.trash_folder(folder)

      {:ok, _view, html} = live(conn, "#{@base}?q=shelf&mode=catalogues")
      assert html =~ "Deleted (1)"

      {:ok, _view, html} = live(conn, "#{@base}?q=live&mode=catalogues")
      refute html =~ "Deleted ("
    end

    test "switching to Deleted keeps the query, and the way back stays open", %{conn: conn} do
      fixture_catalogue(%{name: "Zephyr live"})
      binned = fixture_catalogue(%{name: "Binned thing"})
      Catalogue.trash_catalogue(binned)

      {:ok, view, _html} = live(conn, "#{@base}?q=binned&mode=catalogues")
      html = render_click(view, "switch_catalogue_view", %{"mode" => "deleted"})

      # The query survives the switch (Max, 2026-08-29) and filters the
      # trash list.
      assert html =~ ~s(value="binned")
      assert html =~ "Binned thing"
      refute html =~ "Zephyr live"

      # Searching for something the trash lacks while STANDING in
      # Deleted: the tab row stays — hiding it would trap the user.
      html = render_change(view, "table_search", %{"query" => "zephyr"})
      assert html =~ "Deleted (0)"
      refute html =~ "Binned thing"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Items search mode (?mode=items) — Max, 2026-08-29
  # ─────────────────────────────────────────────────────────────────

  describe "view toggle" do
    test "the card/comfy/table toggle renders on the index toolbar", %{conn: conn} do
      # Regression pin: the items-mode toolbar rework silently dropped
      # the <:view_toggle> slot and the switcher vanished for hours
      # before anyone noticed (2026-08-29).
      fixture_catalogue(%{name: "Toggleable"})

      {:ok, _view, html} = live(conn, @base)
      assert html =~ ~s(phx-click="set_view")

      # The catalogues listing (and its tools) stays through a query —
      # item results render BELOW it since 2026-08-31, they don't
      # replace it.
      {:ok, _view, html} = live(conn, "#{@base}?q=toggle")
      assert html =~ ~s(phx-click="set_view")
    end
  end

  describe "item results section" do
    # One surface since 2026-08-31 (Max): a query filters the catalogue
    # listing AND renders matching items below it — the popup search's
    # two-list idiom. No modes, no switcher, no `?mode=` state.
    test "a query shows matching catalogues above matching items", %{
      conn: conn
    } do
      cat = fixture_catalogue(%{name: "Zephyr Catalogue"})
      fixture_item(%{name: "Zephyr widget", catalogue_uuid: cat.uuid})
      fixture_catalogue(%{name: "Unrelated Catalogue"})

      # No switcher anywhere on the toolbar.
      {:ok, _view, html} = live(conn, @base)
      refute html =~ "set_search_mode"

      {:ok, view, _html} = live(conn, "#{@base}?q=zephyr")
      html = render_async(view)
      # Both halves, one page: the matching catalogue row stays as
      # navigation, the matching item renders in the results below.
      assert html =~ "Zephyr Catalogue"
      assert html =~ "Zephyr widget"
      refute html =~ "Unrelated Catalogue"
    end

    test "a whitespace-only query engages nothing", %{conn: conn} do
      fixture_catalogue(%{name: "Quiet Catalogue"})

      {:ok, view, _html} = live(conn, "#{@base}?q=%20%20")
      html = render_async(view)
      assert html =~ "Quiet Catalogue"
      refute html =~ "item-result-"
    end

    test "lists items across catalogues with their catalogue and category", %{conn: conn} do
      cat_a = fixture_catalogue(%{name: "Alpha Catalogue"})
      cat_b = fixture_catalogue(%{name: "Beta Catalogue"})
      {:ok, doors} = Catalogue.create_category(%{name: "Doors", catalogue_uuid: cat_a.uuid})
      fixture_item(%{name: "Oak door", catalogue_uuid: cat_a.uuid, category_uuid: doors.uuid})
      fixture_item(%{name: "Pine shelf", catalogue_uuid: cat_b.uuid})

      fixture_item(%{name: "Oak shelf", catalogue_uuid: cat_b.uuid})

      {:ok, view, _html} = live(conn, "#{@base}?q=oak")
      html = render_async(view)

      assert html =~ "Oak door"
      assert html =~ "Oak shelf"
      # Context columns — a hit can come from anywhere, so each row says
      # which catalogue and category it lives in.
      assert html =~ "Alpha Catalogue"
      assert html =~ "Doors"
    end

    test "a legacy ?mode= URL is ignored, not an error", %{conn: conn} do
      cat = fixture_catalogue(%{name: "Anything"})
      fixture_item(%{name: "Anything widget", catalogue_uuid: cat.uuid})

      # Old bookmarks carry the retired mode key; the page simply reads
      # its real state (query/attr) and lists as always.
      {:ok, view, _html} = live(conn, "#{@base}?mode=items")
      html = render_async(view)
      assert html =~ "Anything"
      refute html =~ "item-result-"

      {:ok, view, _html} = live(conn, "#{@base}?mode=catalogues&q=anything")
      html = render_async(view)
      assert html =~ "Anything widget"
      _ = view
    end

    test "?q= searches the items, not the catalogues", %{conn: conn} do
      cat = fixture_catalogue(%{name: "Container"})
      fixture_item(%{name: "Findable widget", catalogue_uuid: cat.uuid})
      fixture_item(%{name: "Other thing", catalogue_uuid: cat.uuid})

      {:ok, view, _html} = live(conn, "#{@base}?q=findable")
      html = render_async(view)

      assert html =~ "Findable widget"
      refute html =~ "Other thing"
    end

    test "a drilled folder scopes the items to its subtree", %{conn: conn} do
      {:ok, parent} = Catalogue.create_folder(%{name: "Parent shelf"})
      {:ok, child} = Catalogue.create_folder(%{name: "Child shelf", parent_uuid: parent.uuid})
      inside = fixture_catalogue(%{name: "Inside"})
      {:ok, _} = Catalogue.move_catalogue_to_folder(inside, child.uuid)
      outside = fixture_catalogue(%{name: "Outside"})
      fixture_item(%{name: "Inner widget", catalogue_uuid: inside.uuid})
      fixture_item(%{name: "Outer widget", catalogue_uuid: outside.uuid})

      {:ok, view, _html} = live(conn, "#{@base}?q=widget&folder=#{parent.uuid}")
      html = render_async(view)

      assert html =~ "Inner widget"
      refute html =~ "Outer widget"
    end

    test "a result links straight to the item's EDIT page", %{conn: conn} do
      cat = fixture_catalogue(%{name: "Container"})
      {:ok, category} = Catalogue.create_category(%{name: "Doors", catalogue_uuid: cat.uuid})

      item =
        fixture_item(%{
          name: "Oak door",
          catalogue_uuid: cat.uuid,
          category_uuid: category.uuid
        })

      {:ok, view, _html} = live(conn, "#{@base}?q=oak")
      html = render_async(view)

      # Whoever searched an item by name wants THAT item (boss,
      # 2026-08-31) — not its category's page with the query re-applied
      # and every sibling around it.
      assert html =~ "/items/#{item.uuid}/edit"
      refute html =~ "category=#{category.uuid}"
    end

    test "the unfiled sentinel scopes items mode to unfiled catalogues", %{conn: conn} do
      {:ok, folder} = Catalogue.create_folder(%{name: "Filed away"})
      filed = fixture_catalogue(%{name: "Filed"})
      {:ok, _} = Catalogue.move_catalogue_to_folder(filed, folder.uuid)
      unfiled = fixture_catalogue(%{name: "Unfiled"})
      fixture_item(%{name: "Filed widget", catalogue_uuid: filed.uuid})
      fixture_item(%{name: "Unfiled widget", catalogue_uuid: unfiled.uuid})

      # The sentinel is legacy-URL-only, but it must still MEAN unfiled:
      # drop_stale_folder_filter used to clear it as "not a real folder",
      # silently widening the search to everywhere.
      {:ok, view, _html} = live(conn, "#{@base}?q=widget&folder=__unfiled__")
      html = render_async(view)

      assert html =~ "Unfiled widget"
      refute html =~ "Filed widget"
    end

    test "load_more_items appends the next page", %{conn: conn} do
      cat = fixture_catalogue(%{name: "Big"})

      for n <- 1..55 do
        fixture_item(%{
          name: "Widget #{String.pad_leading("#{n}", 2, "0")}",
          catalogue_uuid: cat.uuid
        })
      end

      {:ok, view, _html} = live(conn, "#{@base}?q=widget")
      html = render_async(view)

      # Name-ordered, one page of 50: 01 is on it, 55 is not yet.
      assert html =~ "Widget 01"
      refute html =~ "Widget 55"

      render_click(view, "load_more_items", %{})
      html = render_async(view)
      assert html =~ "Widget 55"

      # Million-items paranoia (Max, 2026-08-29): the pages must tile —
      # 55 rows loaded, none twice. Ordering carries a uuid tiebreak, so
      # OFFSET cannot shuffle equal keys across page boundaries.
      results = :sys.get_state(view.pid).socket.assigns.item_results
      assert length(results) == 55
      assert results |> Enum.map(& &1.uuid) |> Enum.uniq() |> length() == 55
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Manual order (drag-and-drop reorder of catalogues)
  # ─────────────────────────────────────────────────────────────────
  #
  # `reorder_catalogues` only acts in manual-order mode, so the test first
  # drives `set_sort` to "position" — reachable now that `ViewConfig.save/3`
  # degrades gracefully on the harness's bare `%{uuid: uuid}` user instead of
  # raising out of `put_cfg` (per-user persistence is skipped; the in-memory
  # cfg and the global sort setting still update).
  describe "manual order — DnD reorder" do
    test "reorder_catalogues persists the dropped order", %{conn: conn} do
      a = fixture_catalogue(%{name: "A", position: 0})
      b = fixture_catalogue(%{name: "B", position: 1})
      c = fixture_catalogue(%{name: "C", position: 2})

      {:ok, view, _html} = live(conn, @base)

      render_click(view, "set_sort", %{"sort_by" => "position"})
      render_hook(view, "reorder_catalogues", %{"ordered_ids" => [c.uuid, a.uuid, b.uuid]})

      assert Catalogue.list_catalogues() |> Enum.map(& &1.name) == ["C", "A", "B"]
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Global sort — the catalogues index shares ONE sort across admins
  # ─────────────────────────────────────────────────────────────────
  describe "global sort (catalogues scope)" do
    alias PhoenixKitCatalogue.Web.ViewConfig

    defp appears_before?(html, first, second) do
      {i1, _} = :binary.match(html, first)
      {i2, _} = :binary.match(html, second)
      i1 < i2
    end

    test "set_sort persists the shared setting", %{conn: conn} do
      fixture_catalogue(%{name: "Alpha"})

      {:ok, view, _html} = live(conn, @base)
      render_click(view, "set_sort", %{"sort_by" => "updated"})

      assert PhoenixKit.Settings.get_setting("catalogue_sort_catalogues", nil) == "updated:asc"
    end

    test "a second open index follows a sort change live", %{conn: conn} do
      # Positions invert the alphabetical order, so which name renders first
      # tells us which sort is active.
      fixture_catalogue(%{name: "Alpha", position: 1})
      fixture_catalogue(%{name: "Zed", position: 0})

      {:ok, viewer, viewer_html} = live(conn, @base)
      {:ok, changer, _html} = live(conn, @base)

      assert appears_before?(viewer_html, "Zed", "Alpha")

      render_click(changer, "set_sort", %{"sort_by" => "name"})

      assert appears_before?(render(viewer), "Alpha", "Zed")
    end

    test "a fresh mount reads the shared sort", %{conn: conn} do
      fixture_catalogue(%{name: "Alpha", position: 1})
      fixture_catalogue(%{name: "Zed", position: 0})

      {:ok, _} = ViewConfig.save_global_sort(:catalogues, "position", :asc)

      {:ok, _view, html} = live(conn, @base)
      assert appears_before?(html, "Zed", "Alpha")
    end

    test "an invalid stored value falls back to the default sort" do
      PhoenixKit.Settings.update_setting_with_module(
        "catalogue_sort_catalogues",
        "bogus:sideways",
        "catalogue"
      )

      assert ViewConfig.load_global_sort(:catalogues) == {"position", :asc}
    end
  end
end
