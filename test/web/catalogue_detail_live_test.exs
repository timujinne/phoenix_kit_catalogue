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
  alias PhoenixKitCatalogue.Web.TableConfig

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
    test "category names open the chapter's ITEMS, not a sub-browser", %{conn: conn} do
      catalogue = fixture_catalogue()
      cat_a = fixture_category(catalogue, %{name: "First", position: 0})
      _cat_b = fixture_category(catalogue, %{name: "Second", position: 1})

      {:ok, _view, html} = live(conn, url(catalogue.uuid))

      assert html =~ "First"
      assert html =~ "Second"
      # A name click lands on that category's page — its subcategories
      # AND items together (Max, 2026-08-29). The browser itself never
      # re-roots.
      assert html =~ "?category=#{cat_a.uuid}"
      # The pencil keeps a one-click path to the edit form.
      assert html =~ "/en/admin/catalogue/categories/#{cat_a.uuid}/edit"
      # Root search is catalogue-wide.
      assert html =~ "Search items by name, description, or SKU"
    end

    test "the Uncategorized bucket presents like a subcategory in the browser",
         %{conn: conn} do
      catalogue = fixture_catalogue()
      fixture_category(catalogue, %{name: "A Category"})
      fixture_item(%{name: "Loose Item", catalogue_uuid: catalogue.uuid})

      # Reversed 2026-08-31 (Max: "show them, just like if we were
      # inside a category and there were sub categories" — the browser
      # hiding the bucket made a 9-item catalogue read as 3): the root
      # browser offers the bucket as an entry alongside the categories.
      {:ok, _view, html} = live(conn, url(catalogue.uuid))
      assert html =~ "?category=uncategorized"
      assert html =~ "Uncategorized"

      # Items mode still lists the loose items catalogue-wide.
      {:ok, _view, html} = live(conn, url(catalogue.uuid) <> "?mode=items")
      assert html =~ "Loose Item"
    end

    test "an empty Uncategorized bucket stays out of the browser", %{conn: conn} do
      catalogue = fixture_catalogue()
      cat = fixture_category(catalogue, %{name: "A Category"})
      fixture_item(%{name: "Filed Item", catalogue_uuid: catalogue.uuid, category_uuid: cat.uuid})

      # Nothing loose: a virtual empty folder would be noise (real
      # categories still show at zero — the user created those).
      {:ok, _view, html} = live(conn, url(catalogue.uuid))
      refute html =~ "?category=uncategorized"
    end

    test "with no categories, the catalogue's loose items live behind Items mode",
         %{conn: conn} do
      catalogue = fixture_catalogue()
      fixture_item(%{name: "Loose Alpha", catalogue_uuid: catalogue.uuid})

      # The category browser shows no items — it points at Items mode.
      {:ok, _view, html} = live(conn, url(catalogue.uuid))
      refute html =~ "Loose Alpha"
      assert html =~ "Switch to Items"

      {:ok, _view, html} = live(conn, url(catalogue.uuid) <> "?mode=items")
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
  # Category browser (the index's folder tree, one level down)
  # ─────────────────────────────────────────────────────────────────

  describe "category browser" do
    test "manual order shows a collapsible tree; other sorts flatten", %{conn: conn} do
      catalogue = fixture_catalogue()
      parent = fixture_category(catalogue, %{name: "Chapter A"})
      _child = fixture_category(catalogue, %{name: "Nested A1", parent_uuid: parent.uuid})
      fixture_category(catalogue, %{name: "Chapter B"})

      {:ok, view, html} = live(conn, url(catalogue.uuid))

      # Tree face in manual order: top level visible, children collapsed
      # behind the chevron; drag contract attributes present. Scoped to
      # the tree element — the CARD face in the same DOM shows nesting
      # unconditionally, which is its job.
      assert html =~ "catalogue-categories-tree"
      tree = view |> element("#catalogue-categories-tree") |> render()
      assert tree =~ "Chapter A"
      assert tree =~ "Chapter B"
      refute tree =~ "Nested A1"
      assert tree =~ ~s(data-tree-drop="#{parent.uuid}")
      assert tree =~ ~s(data-tree-item="category:#{parent.uuid}")

      render_click(view, "toggle_category_expand", %{"uuid" => parent.uuid})
      assert view |> element("#catalogue-categories-tree") |> render() =~ "Nested A1"

      # A real sort falls back to the flat table (its sortable tbody id
      # is the marker — the wrapper renders no id in the plain path).
      flat = render_change(view, "sort_categories", %{"sort_by" => "name"})
      refute flat =~ "catalogue-categories-tree"
      assert flat =~ "catalogue-child-categories"
    end

    test "category card pictures are card-grade, framed, and link like the title",
         %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue, %{name: "Pictured"})

      {:ok, _} =
        Catalogue.update_category(category, %{
          data: %{"featured_image_uuid" => UUIDv7.generate()}
        })

      {:ok, _view, html} = live(conn, url(catalogue.uuid))

      # The card face loads the 800px medium variant — the 150px list
      # thumbnail stretched across a card was the blur the boss reported
      # (2026-08-29). The tiny tree-row cell keeps the light thumbnail.
      assert html =~ "/medium/"
      assert html =~ "/thumbnail/"
      # The shared band got taller, and the picture links where the
      # title does: the items link appears for both name and image.
      assert html =~ "h-40"
      assert length(String.split(html, "?category=#{category.uuid}")) - 1 >= 2
    end

    test "the card view nests too: parents are boxes holding their children", %{conn: conn} do
      catalogue = fixture_catalogue()
      parent = fixture_category(catalogue, %{name: "Chapter A"})
      child = fixture_category(catalogue, %{name: "Nested A1", parent_uuid: parent.uuid})
      fixture_category(catalogue, %{name: "Chapter B"})

      {:ok, _view, html} = live(conn, url(catalogue.uuid))

      # The parent renders as a box (a drop target) with the child's
      # card inside it, carrying the tree contract — nesting is visible
      # and draggable in card view, not just in the table (Max,
      # 2026-08-29: "how about the nesting?").
      assert html =~ "catalogue-categories-cards"
      assert html =~ ~s(data-tree-drop="#{parent.uuid}")
      assert html =~ ~s(data-tree-parent="#{parent.uuid}")
      assert html =~ "Nested A1"
    end

    test "a middle drop nests, an edge drop reorders and re-parents", %{conn: conn} do
      catalogue = fixture_catalogue()
      a = fixture_category(catalogue, %{name: "Chapter A", position: 0})
      b = fixture_category(catalogue, %{name: "Chapter B", position: 1})
      c = fixture_category(catalogue, %{name: "Chapter C", position: 2})

      {:ok, view, _html} = live(conn, url(catalogue.uuid))

      # Nest C under A (middle drop).
      html =
        render_click(view, "move_to_folder", %{
          "type" => "category",
          "uuid" => c.uuid,
          "target" => a.uuid
        })

      assert Catalogue.get_category(c.uuid).parent_uuid == a.uuid
      # The drop target stays expanded so the moved row is visible.
      assert html =~ "Chapter C"

      # Edge drop: lift C back to the top level, ordered before A.
      render_click(view, "drop_row", %{
        "type" => "category",
        "uuid" => c.uuid,
        "parent" => "root",
        "entries" => ["category:#{c.uuid}", "category:#{a.uuid}", "category:#{b.uuid}"]
      })

      assert Catalogue.get_category(c.uuid).parent_uuid == nil

      assert Catalogue.list_child_categories(catalogue.uuid, nil)
             |> Enum.map(& &1.name) == ["Chapter C", "Chapter A", "Chapter B"]
    end

    test "a category cannot be dropped into its own subtree", %{conn: conn} do
      catalogue = fixture_catalogue()
      parent = fixture_category(catalogue, %{name: "Chapter A"})
      child = fixture_category(catalogue, %{name: "Nested A1", parent_uuid: parent.uuid})

      {:ok, view, _html} = live(conn, url(catalogue.uuid))

      html =
        render_click(view, "move_to_folder", %{
          "type" => "category",
          "uuid" => parent.uuid,
          "target" => child.uuid
        })

      assert html =~ "cannot move into its own subtree"
      assert Catalogue.get_category(parent.uuid).parent_uuid == nil
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
      # The breadcrumb root crumb patches back to the catalogue root.
      assert html =~ ~s(href="#{url(catalogue.uuid)}")
      # Search is scoped to this category.
      assert html =~ "Search within this category"

      # The category's page shows its own items directly — sections and
      # content together (Max, 2026-08-29).
      assert html =~ "Hinge 90"
    end

    test "content renders in the viewer's locale, not the primary language", %{conn: conn} do
      # 2026-08-16 report: interface in English, primary language
      # Estonian — lists showed Estonian names even though English
      # translations existed. Lists must render the locale-resolved
      # name (Catalogue.localize/2 at load), falling back to primary.
      catalogue = fixture_catalogue(%{name: "Primaarne kataloog"})
      category = fixture_category(catalogue, %{name: "Uksed"})
      item = fixture_item(%{name: "Tamm", category_uuid: category.uuid})
      untranslated = fixture_category(catalogue, %{name: "Aknad"})
      _keep = untranslated

      {:ok, _} =
        Catalogue.set_translation(catalogue, "en", %{"_name" => "Primary Catalogue"}, fn c, a ->
          Catalogue.update_catalogue(c, a)
        end)

      {:ok, _} =
        Catalogue.set_translation(category, "en", %{"_name" => "Doors"}, fn c, a ->
          Catalogue.update_category(c, a)
        end)

      {:ok, _} =
        Catalogue.set_translation(item, "en", %{"_name" => "Oak"}, fn i, a ->
          Catalogue.update_item(i, a)
        end)

      # Root level: catalogue title + category names localized; the
      # untranslated category falls back to its primary name.
      {:ok, _view, html} = live(conn, url(catalogue.uuid))
      assert html =~ "Primary Catalogue"
      assert html =~ "Doors"
      assert html =~ "Aknad"
      refute html =~ "Uksed"

      # Drilled into Items mode: the title/crumbs and item list follow too.
      {:ok, _view, html} = live(conn, cat_url(catalogue.uuid, category.uuid) <> "&mode=items")
      assert html =~ "Doors"
      assert html =~ "Oak"
      refute html =~ "Tamm"
    end

    test "the trail lives in the admin header and the level shows its description", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Catalogue X", description: "Root blurb"})
      parent = fixture_category(catalogue, %{name: "Hardware"})

      child =
        fixture_category(catalogue, %{
          name: "Hinges",
          parent_uuid: parent.uuid,
          description: "Hinge blurb"
        })

      {:ok, _view, html} = live(conn, cat_url(catalogue.uuid, child.uuid))

      # Header crumbs: catalogue root + ancestor, both as links; the current
      # category is the page title, not a crumb.
      assert html =~ ~s(href="#{url(catalogue.uuid)}")
      assert html =~ ~s(href="#{cat_url(catalogue.uuid, parent.uuid)}")
      # No in-page drill trail (the old "name › name" h1 is gone) — the
      # level's own description renders in its place, not the root's.
      refute html =~ "Root blurb"
      assert html =~ "Hinge blurb"
    end

    test "manual mode wires the card view for drag reorder too", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      fixture_item(%{name: "Item A", category_uuid: category.uuid})
      fixture_item(%{name: "Item B", category_uuid: category.uuid})

      {:ok, _view, html} = live(conn, cat_url(catalogue.uuid, category.uuid) <> "&mode=items")

      # The card container only gets its -cards id (and the SortableGrid
      # hook + per-card grips with it) when on_reorder is wired.
      assert html =~ ~s(id="level-items-active-cards")
    end

    test "a single item is not drag-reorderable in card view", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      fixture_item(%{name: "Only item", category_uuid: category.uuid})

      {:ok, _view, html} = live(conn, cat_url(catalogue.uuid, category.uuid) <> "&mode=items")

      refute html =~ ~s(id="level-items-active-cards")
    end

    test "Add Category on a drilled level pre-seeds the current category as parent", %{
      conn: conn
    } do
      # Boss's call (2026-08-18): subcategories are a first-class flow,
      # so the button shows on every level — drilled, it creates a
      # SUBCATEGORY (parent_uuid carried in the new-category link).
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)

      {:ok, _view, html} = live(conn, cat_url(catalogue.uuid, category.uuid))

      assert html =~ "Add Category"
      assert html =~ "parent_uuid=#{category.uuid}"

      # At root the header button still creates a ROOT category; the
      # per-row "New subcategory" menu entries are what carry parents now.
      {:ok, _view, html} = live(conn, url(catalogue.uuid))
      assert html =~ "Add Category"
      refute html =~ "categories/new?parent_uuid=#{catalogue.uuid}"
    end

    test "shows subcategories as drill cards alongside the category's own items", %{conn: conn} do
      catalogue = fixture_catalogue()
      parent = fixture_category(catalogue, %{name: "Parent"})
      child = fixture_category(catalogue, %{name: "Child", parent_uuid: parent.uuid})
      fixture_item(%{name: "Parent direct item", category_uuid: parent.uuid})

      {:ok, _view, html} = live(conn, cat_url(catalogue.uuid, parent.uuid))

      # Sections and content together on one page: the subcategory (its
      # name opening ITS page) beside the parent's own items.
      assert html =~ "Child"
      assert html =~ "?category=#{child.uuid}"
      assert html =~ "Parent direct item"
    end

    test "an item in the level list links to its edit page", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      item = fixture_item(%{name: "Clickable item", category_uuid: category.uuid})

      {:ok, _view, html} = live(conn, cat_url(catalogue.uuid, category.uuid) <> "&mode=items")

      # The edit link carries the level it was clicked from, so save/cancel
      # can land back here instead of the catalogue root.
      assert html =~ ~s(href="/en/admin/catalogue/items/#{item.uuid}/edit?return_to=)
      assert html =~ "Clickable item"
    end

    test "Add Item from a category level carries the category and return path", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)

      {:ok, _view, html} = live(conn, cat_url(catalogue.uuid, category.uuid))

      assert html =~ ~s(category=#{category.uuid})
      assert html =~ "return_to="
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

      {:ok, view, html} = live(conn, cat_url(catalogue.uuid, category.uuid) <> "&mode=items")
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

  describe "items table columns + category menus" do
    test "columns modal narrows and reorders the items table", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Cols catalogue"})
      fixture_item(%{name: "Col item", sku: "COL-1", catalogue_uuid: catalogue.uuid})

      {:ok, view, html} = live(conn, url(catalogue.uuid) <> "?mode=items")

      # Default columns render; the Columns button is present.
      assert html =~ "COL-1"
      assert html =~ "Columns"

      render_click(view, "show_column_modal", %{})
      # Drop the SKU column — the editor is live, no Apply step.
      updated =
        render_click(view, "remove_column", %{"column_id" => "sku", "scope" => "detail_items"})

      refute updated =~ "COL-1"
      assert updated =~ "Col item"
    end

    test "categories table has its own Columns editor", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Cat cols"})
      fixture_category(catalogue, %{name: "Configurable"})

      {:ok, view, html} = live(conn, url(catalogue.uuid))
      assert html =~ "Items"

      render_click(view, "show_column_modal", %{})

      updated =
        render_click(view, "add_column", %{
          "column_id" => "updated",
          "scope" => "detail_categories"
        })

      assert updated =~ "Updated"
    end

    test "both tables share one Columns button and one modal", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Merged cols"})
      parent = fixture_category(catalogue, %{name: "Chapter with both"})
      fixture_category(catalogue, %{name: "Sub chapter", parent_uuid: parent.uuid})
      fixture_item(%{name: "Direct item", sku: "DIR-1", category_uuid: parent.uuid})

      {:ok, view, html} = live(conn, cat_url(catalogue.uuid, parent.uuid))

      # One button for the whole page — Max: two side-by-side "Columns"
      # buttons "probobly should be in the same popup".
      assert length(String.split(html, ~s(phx-click="show_column_modal"))) == 2

      # The modal carries a section per table, each editing its own
      # scope without touching the other.
      opened = render_click(view, "show_column_modal", %{})
      assert opened =~ "columns-shown-detail_categories"
      assert opened =~ "columns-shown-detail_items"

      updated =
        render_click(view, "remove_column", %{"column_id" => "sku", "scope" => "detail_items"})

      refute updated =~ "DIR-1"

      assert :sys.get_state(view.pid).socket.assigns.categories_columns ==
               TableConfig.default_columns(:detail_categories)

      # Reset restores every section shown.
      reset = render_click(view, "reset_columns", %{})
      assert reset =~ "DIR-1"
    end

    test "detail sorts are shared across users and follow live", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Global sort cat"})
      fixture_item(%{name: "Alpha item", catalogue_uuid: catalogue.uuid, position: 1})
      fixture_item(%{name: "Zed item", catalogue_uuid: catalogue.uuid, position: 0})

      {:ok, changer, _} = live(conn, url(catalogue.uuid) <> "?mode=items")
      {:ok, viewer, _} = live(conn, url(catalogue.uuid) <> "?mode=items")

      render_click(changer, "sort_items", %{"sort_by" => "name"})

      # Persisted globally: the setting is written...
      assert PhoenixKit.Settings.get_setting("catalogue_sort_detail_items", nil) ==
               "name:asc"

      # ...a fresh session opens with it...
      {:ok, _fresh, fresh_html} = live(conn, url(catalogue.uuid) <> "?mode=items")

      assert :binary.match(fresh_html, "Alpha item") |> elem(0) <
               :binary.match(fresh_html, "Zed item") |> elem(0)

      # ...and the already-open viewer followed the broadcast.
      viewer_html = render(viewer)

      assert :binary.match(viewer_html, "Alpha item") |> elem(0) <
               :binary.match(viewer_html, "Zed item") |> elem(0)
    end

    test "category rows use the standardized row menu", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Menu catalogue"})
      category = fixture_category(catalogue, %{name: "Menu category"})

      {:ok, _view, html} = live(conn, url(catalogue.uuid))

      assert html =~ "category-menu-#{category.uuid}"
      # Old inline pencil affordance is gone from category rows.
      refute html =~ "Edit category"
    end
  end

  describe "item mutations" do
    test "delete_item removes the item and trashes it in the DB", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      item = fixture_item(%{name: "Doomed", category_uuid: category.uuid})
      fixture_item(%{name: "Survivor", category_uuid: category.uuid})

      {:ok, view, html} = live(conn, cat_url(catalogue.uuid, category.uuid) <> "&mode=items")
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
      # Pair the DB check with the user-visible flash (per quality_sweep
      # "don't leave DB-only assertions" — the view auto-flips back to
      # the Active tab, where the restored item now appears).
      assert render(view) =~ "Item restored."
    end

    test "delete_item with a bogus uuid doesn't crash", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      survivor = fixture_item(%{name: "Survivor", category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, cat_url(catalogue.uuid, category.uuid) <> "&mode=items")

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

      {:ok, view, html} = live(conn, cat_url(catalogue.uuid, category.uuid) <> "&mode=items")
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

      {:ok, view, _html} = live(conn, cat_url(catalogue.uuid, category.uuid) <> "&mode=items")
      html = render_change(view, "sort_items", %{"sort_by" => "evil; DROP"})

      assert html =~ "Solo"
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

      {:ok, view, html} = live(conn, cat_url(catalogue.uuid, category.uuid) <> "&mode=items")
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

    test "items mode lists the WHOLE catalogue with the full surface", %{conn: conn} do
      catalogue = fixture_catalogue()
      cat_a = fixture_category(catalogue, %{name: "Chapter A"})
      fixture_item(%{name: "Widget in A", category_uuid: cat_a.uuid})
      fixture_item(%{name: "Loose widget", catalogue_uuid: catalogue.uuid})

      # With drilling gone there is no level to stand in: root Items mode
      # answers for every item in the catalogue, in document order.
      {:ok, view, _html} = live(conn, url(catalogue.uuid) <> "?mode=items")
      html = render_async(view)

      assert html =~ "Loose widget"
      assert html =~ "Widget in A"
      # The category browser is folded away, and the chips yield to the mode.
      refute html =~ "catalogue-categories-views"
      refute html =~ "set_search_type"

      # A legacy drilled link still scopes to that category's own items.
      {:ok, view, _html} = live(conn, cat_url(catalogue.uuid, cat_a.uuid) <> "&mode=items")
      html = render_async(view)
      assert html =~ "Widget in A"
      refute html =~ "Loose widget"
    end

    test "searching inside items mode narrows the flat list", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue, %{name: "Oak chapter"})
      fixture_item(%{name: "Oak panel", category_uuid: category.uuid})
      fixture_item(%{name: "Pine board", category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, url(catalogue.uuid) <> "?mode=items&q=oak")
      html = render_async(view)

      assert html =~ "Oak panel"
      refute html =~ "Pine board"
      # No category hits in items mode, even when the name matches.
      refute html =~ "Oak chapter"
    end

    test "a category's page shows its subcategories above its items", %{conn: conn} do
      catalogue = fixture_catalogue()
      parent = fixture_category(catalogue, %{name: "Hardware chapter"})
      _child = fixture_category(catalogue, %{name: "Frames sub", parent_uuid: parent.uuid})
      fixture_item(%{name: "Hinge item", category_uuid: parent.uuid})

      # The exact gap Max hit (2026-08-29): a category nested under
      # Hardware was invisible on Hardware's own page — the old drilled
      # view showed subcategories and the no-drilling rework lost them.
      {:ok, view, _html} = live(conn, cat_url(catalogue.uuid, parent.uuid) <> "&mode=items")
      html = render_async(view)

      assert html =~ "Frames sub"
      assert html =~ "Hinge item"

      # The ROOT items page stays pure items — the outline lives in
      # Categories mode there.
      {:ok, view, _html} = live(conn, url(catalogue.uuid) <> "?mode=items")
      html = render_async(view)
      refute html =~ "catalogue-categories-views"
    end

    test "the subtree toggle widens the SEARCH, never the browse list", %{conn: conn} do
      catalogue = fixture_catalogue()
      parent = fixture_category(catalogue, %{name: "Hardware chapter"})
      child = fixture_category(catalogue, %{name: "Frames sub", parent_uuid: parent.uuid})
      fixture_item(%{name: "Steel widget own", category_uuid: parent.uuid})
      fixture_item(%{name: "Steel widget nested", category_uuid: child.uuid})

      # Browsing: the category's OWN items only. The toggle is offered
      # (Max, 2026-08-30: "should alwasy be there" with subcategories)
      # but it "should only do something when searching" — flipping it
      # here pre-arms the next search without touching the list.
      {:ok, view, html} = live(conn, cat_url(catalogue.uuid, parent.uuid))
      assert html =~ "Steel widget own"
      refute html =~ "Steel widget nested"
      assert html =~ "Include subcategory items"

      # Even with ?items=subtree in the URL the browse list stays direct.
      {:ok, _view, html} =
        live(conn, cat_url(catalogue.uuid, parent.uuid) <> "&items=subtree")

      refute html =~ "Steel widget nested"

      # A running search offers the toggle; off = direct matches only.
      {:ok, view, _html} = live(conn, cat_url(catalogue.uuid, parent.uuid) <> "&q=widget")
      html = render_async(view)
      assert html =~ "Include subcategory items"
      assert html =~ "Steel widget own"
      refute html =~ "Steel widget nested"

      # Flipping it re-runs the search over the whole subtree.
      render_click(view, "toggle_items_scope", %{})
      assert assert_patch(view) =~ "items=subtree"
      html = render_async(view)
      assert html =~ "Steel widget own"
      assert html =~ "Steel widget nested"
    end

    test "subcategories stay visible on the inactive tab", %{conn: conn} do
      catalogue = fixture_catalogue()
      parent = fixture_category(catalogue, %{name: "Sleepy chapter"})
      _child = fixture_category(catalogue, %{name: "Live sub", parent_uuid: parent.uuid})
      dormant = fixture_item(%{name: "Dormant item", category_uuid: parent.uuid})
      {:ok, _} = Catalogue.update_item(dormant, %{status: "inactive"})

      # Only-inactive direct items auto-land the page on the Inactive
      # tab — which used to hide the subcategories and the subtree
      # toggle entirely (panel finding, 2026-08-29).
      {:ok, _view, html} = live(conn, cat_url(catalogue.uuid, parent.uuid))
      assert html =~ "Dormant item"
      assert html =~ "Live sub"
    end

    test "the toggle no longer blocks reordering the browse list", %{conn: conn} do
      catalogue = fixture_catalogue()
      parent = fixture_category(catalogue, %{name: "Mixed chapter"})
      child = fixture_category(catalogue, %{name: "Inner", parent_uuid: parent.uuid})
      fixture_item(%{name: "Own one", category_uuid: parent.uuid})
      fixture_item(%{name: "Own two", category_uuid: parent.uuid})
      fixture_item(%{name: "Nested one", category_uuid: child.uuid})

      # The subtree toggle is a search refinement now — the browse list
      # it would renumber is always the direct one, so reorder stays.
      {:ok, view, _html} =
        live(conn, cat_url(catalogue.uuid, parent.uuid) <> "&items=subtree")

      render_click(view, "open_items_reorder_modal", %{})
      assert :sys.get_state(view.pid).socket.assigns.show_items_reorder
    end

    test "root items mode hides the toolbar Reorder via CSS", %{conn: conn} do
      catalogue = fixture_catalogue()
      fixture_category(catalogue, %{name: "Grouping chapter"})
      fixture_item(%{name: "Loose item", catalogue_uuid: catalogue.uuid})

      # Root items mode with categories present cannot strategy-reorder
      # (document order is grouped by category). The substring match is
      # load-bearing: Tailwind reads a bare `_` in an arbitrary value
      # as a space, and escaping cannot work because Tailwind scans
      # the raw source while HEEx renders the parsed string.
      {:ok, view, _html} = live(conn, url(catalogue.uuid) <> "?mode=items")
      assert render_async(view) =~ "[data-bulk-action*=reorder]]:!hidden"
    end

    test "a stale ?items=subtree does not leak into root or the bucket", %{conn: conn} do
      catalogue = fixture_catalogue()
      fixture_category(catalogue, %{name: "Any chapter"})

      {:ok, view, _html} = live(conn, url(catalogue.uuid) <> "?items=subtree")
      assert :sys.get_state(view.pid).socket.assigns.items_scope == ""
    end

    test "a root items-mode search settles even when the tab auto-flips", %{conn: conn} do
      catalogue = fixture_catalogue()
      gone = fixture_item(%{name: "Binned widget", catalogue_uuid: catalogue.uuid})
      Catalogue.trash_item(gone)

      # Only deleted items: the level load auto-picks the Deleted tab
      # AFTER the search used to stamp itself for items mode — the reply
      # then failed its own stamp and the spinner never cleared (panel
      # finding). The search now runs after the level settles.
      {:ok, view, _html} = live(conn, url(catalogue.uuid) <> "?mode=items&q=binned")
      render_async(view)
      refute :sys.get_state(view.pid).socket.assigns.search_loading
    end

    test "no subcategories, no toggle", %{conn: conn} do
      catalogue = fixture_catalogue()
      leaf = fixture_category(catalogue, %{name: "Leaf chapter"})
      fixture_item(%{name: "Leaf item", category_uuid: leaf.uuid})

      {:ok, _view, html} = live(conn, cat_url(catalogue.uuid, leaf.uuid))
      assert html =~ "Leaf item"
      refute html =~ "Include subcategory items"
    end

    test "a drilled search covers categories and items together, no chips", %{conn: conn} do
      catalogue = fixture_catalogue()
      parent = fixture_category(catalogue, %{name: "Oak chapter"})
      _sub = fixture_category(catalogue, %{name: "Oak veneers", parent_uuid: parent.uuid})
      fixture_item(%{name: "Oak panel", category_uuid: parent.uuid})

      {:ok, view, _html} = live(conn, cat_url(catalogue.uuid, parent.uuid) <> "&q=oak")
      html = render_async(view)

      # Matches in both render as two sections, automatically — the
      # type chooser is a root-only concept (Max, 2026-08-29).
      assert html =~ "Oak veneers"
      assert html =~ "Oak panel"
      refute html =~ "set_search_type"
    end

    test "the Categories switcher returns to the root outline, expanded to where you were",
         %{conn: conn} do
      catalogue = fixture_catalogue()
      parent = fixture_category(catalogue, %{name: "Outer chapter"})
      category = fixture_category(catalogue, %{name: "Deep chapter", parent_uuid: parent.uuid})
      fixture_item(%{name: "Deep item", category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, cat_url(catalogue.uuid, category.uuid) <> "&mode=items")
      assert render_async(view) =~ "Deep item"

      render_click(view, "set_search_mode", %{"mode" => "categories"})
      path = assert_patch(view)

      # Both the mode AND the drilled category clear — the outline
      # browser lives only at the root — and the tree opens expanded
      # down to the category just left: a collapsed root made it look
      # vanished (Max's Frames report, 2026-08-29). "Deep chapter" is
      # NESTED, so seeing it in the tree proves the expansion.
      refute path =~ "mode="
      refute path =~ "category="
      assert view |> element("#catalogue-categories-tree") |> render() =~ "Deep chapter"
    end

    test "the mode switcher patches ?mode= and leaving restores the outline", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue, %{name: "Only chapter"})
      fixture_item(%{name: "Only item", category_uuid: category.uuid})
      fixture_item(%{name: "Loose thing", catalogue_uuid: catalogue.uuid})

      {:ok, view, _html} = live(conn, url(catalogue.uuid))

      render_click(view, "set_search_mode", %{"mode" => "items"})
      assert assert_patch(view) =~ "mode=items"
      # The CLICK path must reload the level, not just flip the assign —
      # UrlState auto-assigns params before the callback, so a naive
      # changed? check reads "unchanged" and skips the reload (bug found
      # live, 2026-08-29). The loose root item proves the load ran.
      html = render_async(view)
      assert html =~ "Loose thing"
      # Catalogue-wide: the categorized item is in the flat list too.
      assert html =~ "Only item"

      render_click(view, "set_search_mode", %{"mode" => "categories"})
      path = assert_patch(view)
      refute path =~ "mode="
      # The outline browse is back.
      assert render(view) =~ "Only chapter"
    end

    test "items mode pages by @per_page and a search page tiles without duplicates",
         %{conn: conn} do
      # The detail page's batch is 100 — the fixture must cross that
      # boundary or this test proves nothing about paging.
      catalogue = fixture_catalogue()

      for n <- 1..105 do
        fixture_item(%{
          name: "Widget #{String.pad_leading("#{n}", 3, "0")}",
          catalogue_uuid: catalogue.uuid
        })
      end

      # The level list pages…
      {:ok, view, _html} = live(conn, url(catalogue.uuid) <> "?mode=items")
      html = render_async(view)
      assert html =~ "Widget 001"
      refute html =~ "Widget 105"

      render_hook(view, "load_more", %{})
      html = render_async(view)
      assert html =~ "Widget 105"

      # …and so do search results, tiling without duplicates: the search
      # ordering ends in a uuid tiebreak, so OFFSET cannot shuffle equal
      # keys across page boundaries (million-items paranoia, Max,
      # 2026-08-29).
      render_change(view, "search", %{"query" => "widget"})
      render_async(view)
      render_hook(view, "load_more", %{})
      render_async(view)

      results = :sys.get_state(view.pid).socket.assigns.search_results
      assert length(results) == 105
      assert results |> Enum.map(& &1.uuid) |> Enum.uniq() |> length() == 105
    end

    test "the type chips narrow what the search returns", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue, %{name: "Oak things"})
      fixture_item(%{name: "Oak panel", category_uuid: category.uuid})

      # Default (All): the category hit sits above the item results.
      {:ok, view, _html} = live(conn, url(catalogue.uuid) <> "?q=oak")
      html = render_async(view)
      assert html =~ "Oak things"
      assert html =~ "Oak panel"

      # Categories only — the item side is not even queried.
      {:ok, view, _html} = live(conn, url(catalogue.uuid) <> "?q=oak&type=categories")
      html = render_async(view)
      assert html =~ "Oak things"
      refute html =~ "Oak panel"

      # Items only — no category hits.
      {:ok, view, _html} = live(conn, url(catalogue.uuid) <> "?q=oak&type=items")
      html = render_async(view)
      assert html =~ "Oak panel"
      refute html =~ "Oak things"
    end

    test "a sticky ?type=categories cannot dead-end the uncategorized bucket", %{conn: conn} do
      catalogue = fixture_catalogue()
      fixture_item(%{name: "Loose oak plank", catalogue_uuid: catalogue.uuid})

      # The bucket holds no categories and hides the chips, so a type
      # carried in from elsewhere used to turn every search into a false
      # "Nothing matches your search." with no control to escape. The
      # bucket always searches as All.
      {:ok, view, _html} =
        live(conn, url(catalogue.uuid) <> "?category=uncategorized&q=oak&type=categories")

      html = render_async(view)
      assert html =~ "Loose oak plank"
      refute html =~ "Nothing matches"
    end

    test "set_search_type patches ?type= and re-asks the search", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue, %{name: "Oak category"})
      fixture_item(%{name: "Oak item", category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, url(catalogue.uuid) <> "?q=oak")
      render_async(view)

      render_click(view, "set_search_type", %{"type" => "items"})
      assert assert_patch(view) =~ "type=items"

      html = render_async(view)
      assert html =~ "Oak item"
      refute html =~ "Oak category"
    end

    test "clear_search restores the level view", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)
      fixture_item(%{name: "Only item", category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, cat_url(catalogue.uuid, category.uuid) <> "&mode=items")
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

  # ─────────────────────────────────────────────────────────────────
  # URL-backed drill + search state (?category= / ?q=)
  # ─────────────────────────────────────────────────────────────────

  describe "url state" do
    test "?q= in the URL runs the search on arrival", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue, %{name: "Cat A"})
      fixture_item(%{name: "Oak panel", category_uuid: category.uuid})
      fixture_item(%{name: "Pine board", category_uuid: category.uuid})

      {:ok, view, _html} = live(conn, cat_url(catalogue.uuid, category.uuid) <> "&q=oak")
      html = render_async(view)

      assert html =~ "Oak panel"
      refute html =~ "Pine board"
    end

    test "searching writes ?q= into the URL and clearing takes it back out", %{conn: conn} do
      catalogue = fixture_catalogue()
      fixture_item(%{name: "Oak panel", catalogue_uuid: catalogue.uuid})

      {:ok, view, _html} = live(conn, url(catalogue.uuid))

      render_change(view, "search", %{"query" => "oak"})
      assert_patch(view, url(catalogue.uuid) <> "?q=oak")
      _ = render_async(view)

      render_click(view, "clear_search", %{})
      assert_patch(view, url(catalogue.uuid))
    end

    # `?category=` (empty) is the root level, and the assign has to say so
    # too: the item-list DOM ids are built from `@current_category_uuid ||
    # "root"`, and push_url_state reads its merge base back from the assigns
    # — so a raw "" left in place both mangles the ids and re-writes the
    # empty `?category=` into every later search patch.
    test "an empty ?category= normalizes to the root level", %{conn: conn} do
      catalogue = fixture_catalogue()
      fixture_item(%{name: "Oak panel", catalogue_uuid: catalogue.uuid})

      {:ok, view, html} = live(conn, url(catalogue.uuid) <> "?category=&mode=items")

      assert html =~ "Oak panel"
      assert html =~ ~s(id="items-body-root")

      render_change(view, "search", %{"query" => "oak"})
      assert_patch(view, url(catalogue.uuid) <> "?mode=items&q=oak")
    end

    # `?q=` now survives the level load, so a deep link into a node whose
    # Active tab is empty settles on the Deleted view with search results on
    # screen. The input has to come along, or there is no way to clear them.
    test "the search input stays reachable when the level lands on a non-active tab",
         %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue, %{name: "Cat A"})
      gone = fixture_item(%{name: "Retired panel", category_uuid: category.uuid})
      Catalogue.trash_item(gone)

      {:ok, view, _html} = live(conn, cat_url(catalogue.uuid, category.uuid) <> "&q=oak")
      html = render_async(view)

      # The empty state now speaks for items AND categories, since search
      # covers both (2026-08-28).
      assert html =~ "Nothing matches your search."
      assert html =~ "Search within this category"
      assert html =~ "clear_search"
    end
  end
end
