defmodule PhoenixKitCatalogue.Web.AttributeSetsSurfacesTest do
  @moduledoc """
  The remaining attribute-sets UI surfaces the quality sweep found
  untested (C11, 2026-08-19): the sets listing tab and its delete flow,
  the legacy group-form redirect, the OrphanPruner subscriber, the
  product card's selection-aware attribute rows, the catalogue-detail
  bottom navigation, and the set Paths.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitCatalogue.Catalogue.AttributeSets.OrphanPruner
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Test.Repo
  alias PhoenixKitCatalogue.Web.Components.ProductCard

  if Code.ensure_loaded?(PhoenixKitEntities.Managed) do
    setup %{conn: conn, scope: scope} do
      AttributeSets.register_deletion_guard()
      PhoenixKit.Settings.update_setting("entities_enabled", "true")
      on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)

      %{conn: with_scope(conn, scope)}
    end

    describe "CataloguesLive attributes tab (sets enabled)" do
      test "the tab is a VIEWER: values and attached items, no edit or delete", %{conn: conn} do
        # 2026-08-27 direction: the subtab shows sets and the items
        # they're attached to; ALL editing lives in the entities module.
        {:ok, set} = Catalogue.create_attribute_set(%{name: "Tab colors"})
        {:ok, _red} = Catalogue.create_attribute_set_value(set, %{label: "Red"})
        item = fixture_item(%{name: "TabItem"})
        {:ok, _} = Catalogue.attach_attribute_set(item.uuid, set.uuid)

        {:ok, view, html} = live(conn, "/en/admin/catalogue/attributes")

        assert :sys.get_state(view.pid).socket.assigns.sets_enabled
        assert html =~ "Tab colors"
        # The viewer shows the set's values; items are a COUNT that
        # opens the popup (2026-08-28) — names never render inline.
        assert html =~ "Red"
        refute html =~ "TabItem"

        assert has_element?(
                 view,
                 ~s|button[phx-click="open_set_items_modal"][phx-value-uuid="#{set.uuid}"]|,
                 "1"
               )

        # …links every edit affordance into entities…
        assert html =~ "/admin/entities/#{set.name}/data"

        # The NAME goes to the entities values page (the detail page
        # became the items POPUP, 2026-08-28); the slug is not
        # rendered — it only rides inside hrefs.
        assert has_element?(
                 view,
                 ~s|a[href$="/admin/entities/#{set.name}/data"]|,
                 "Tab colors"
               )

        # The kebab leads with View items (opens the popup), then the
        # entities editing links.
        assert has_element?(view, ~s|#attr-set-menu-t-#{set.uuid} button|, "View items")
        refute has_element?(view, "#attribute-sets-table .font-mono")
        assert html =~ "/admin/entities/#{set.uuid}/edit"
        # …and carries no delete flow of its own — the handler itself is
        # gone (a crafted push would FunctionClauseError, proving no code
        # path on this LV can delete a set).
        refute html =~ "delete_attribute_set"
        refute html =~ "show_delete_confirm"
        assert %{} = Catalogue.get_attribute_set(set.uuid)
      end

      test "New Set collects a name only, stamps ownership, hands off to entities", %{
        conn: conn
      } do
        {:ok, view, _html} = live(conn, "/en/admin/catalogue/attributes")

        render_click(view, "open_new_set_modal", %{})

        assert {:error, {:live_redirect, %{to: to}}} =
                 view
                 |> element("#new-attribute-set-modal form")
                 |> render_submit(%{"name" => "Handed Off"})

        # Straight to ADDING VALUES — not the blueprint editor.
        assert to =~ "/admin/entities/"
        assert to =~ "/data/new"

        [set] =
          Catalogue.list_attribute_sets()
          |> Enum.filter(&(&1.display_name == "Handed Off"))

        # The one reason creation stays here: the managed stamp. Kind is
        # no longer asked for (nothing consumes it) and defaults quietly.
        assert PhoenixKitEntities.Managed.owner(set) == "catalogue"
        assert Catalogue.attribute_set_kind(set) == "multi"

        # Kind is stored but HIDDEN from every surface until something
        # consumes it (Max, 2026-08-27) — no badge, no column.
        {:ok, _view, listing} = live(conn, "/en/admin/catalogue/attributes")
        refute listing =~ "Fixed value"
        refute listing =~ "Multiple values"
      end

      test "a thousand of anything stays capped: pages, chips, previews", %{conn: conn} do
        # 30 sets -> two pages; one set with 12 values and 7 items ->
        # capped chips + "+N" to entities, capped item links + plain
        # overflow count. Counts stay the REAL numbers throughout.
        {:ok, big} = Catalogue.create_attribute_set(%{name: "Big Set"})

        for i <- 1..20 do
          {:ok, _} = Catalogue.create_attribute_set_value(big, %{label: "Val #{i}"})
        end

        for i <- 1..7 do
          item = fixture_item(%{name: "BigItem #{String.pad_leading(to_string(i), 2, "0")}"})
          {:ok, _} = Catalogue.attach_attribute_set(item.uuid, big.uuid)
        end

        for i <- 1..29 do
          {:ok, _} =
            Catalogue.create_attribute_set(%{
              name: "Filler #{String.pad_leading(to_string(i), 2, "0")}"
            })
        end

        {:ok, view, html} = live(conn, "/en/admin/catalogue/attributes")

        # Page 1 of 2, 30 sets total; page 2 reachable and clamped.
        assert html =~ "Page 1 of 2"
        refute html =~ "Filler 29"
        html = render_click(view, "attr_sets_page", %{"dir" => "next"})
        assert html =~ "Filler 29"
        html = render_click(view, "attr_sets_page", %{"dir" => "next"})
        assert html =~ "Page 2 of 2"

        # Search narrows and resets to page 1.
        html = render_change(view, "attr_sets_search", %{"q" => "Big Set"})
        assert html =~ "Big Set"
        refute html =~ "Filler 01"

        # Chips capped (12 in the table face since 2026-08-28 — the
        # items column shrank to a count, so values own the width) with
        # the real count and a "+N" LINK to entities — never all twenty
        # inline.
        assert html =~ "Val 12"
        refute html =~ "Val 13"
        assert html =~ "+8"
        assert html =~ "(20)"
        assert html =~ "/admin/entities/#{big.name}/data"

        # …and the cap is RESPONSIVE: both tiers ship and CSS picks one,
        # so a phone never gets a desktop-width chip strip. Table face
        # 6 (+14) below xl / 12 (+8) from xl; card face 5 (+15) below
        # sm / 8 (+12) from sm.
        assert html =~ "hidden xl:inline-flex"
        assert html =~ "+14"
        assert html =~ "hidden sm:inline-flex"
        assert html =~ "+15"

        # Items are ONLY a count opening the popup — no name dump at
        # any size (2026-08-28: the count is the button).
        refute html =~ "BigItem 01"

        assert has_element?(
                 view,
                 ~s|button[phx-click="open_set_items_modal"][phx-value-uuid="#{big.uuid}"]|,
                 "7"
               )

        # The kebab carries the only actions, in both faces.
        assert html =~ ~s(id="attr-set-menu-t-#{big.uuid}")
        assert html =~ ~s(id="attr-set-menu-c-#{big.uuid}")
      end

      test "the static render shows a skeleton, never the legacy empty state", %{conn: conn} do
        # Data is deferred to the connected mount (whole-LV pattern); the
        # HTTP render used to flash "No attribute groups yet" from the
        # LEGACY branch before the sets loaded.
        {:ok, _} = Catalogue.create_attribute_set(%{name: "Flash Guard"})

        static = conn |> get("/en/admin/catalogue/attributes") |> html_response(200)
        refute static =~ "No attribute groups yet"
        refute static =~ "No sets yet"
        assert static =~ "skeleton"

        # The connected mount replaces the skeleton with the real listing.
        {:ok, _view, html} = live(conn, "/en/admin/catalogue/attributes")
        assert html =~ "Flash Guard"
        refute html =~ "skeleton h-24"
      end

      test "no-match search says so instead of rendering silence", %{conn: conn} do
        {:ok, _} = Catalogue.create_attribute_set(%{name: "Only Set"})
        {:ok, view, _html} = live(conn, "/en/admin/catalogue/attributes")

        html = render_change(view, "attr_sets_search", %{"q" => "zzz-nothing"})
        assert html =~ "No sets match your search."
        # …and ONLY the no-match message: "No sets yet" used to key off
        # the page rows and pile on above the search bar (Max, 2026-08-28).
        refute html =~ "No sets yet."
      end

      test "search finds a set by what is IN it, not just its name", %{conn: conn} do
        # Max, 2026-08-28: typing a value label must reach the set that
        # holds it — the name is not the only handle people have.
        {:ok, colors} = Catalogue.create_attribute_set(%{name: "Front finishes"})
        {:ok, _} = Catalogue.create_attribute_set_value(colors, %{label: "Oak veneer"})
        {:ok, other} = Catalogue.create_attribute_set(%{name: "Hinge sides"})
        {:ok, _} = Catalogue.create_attribute_set_value(other, %{label: "Left"})

        {:ok, view, _html} = live(conn, "/en/admin/catalogue/attributes")

        html = render_change(view, "attr_sets_search", %{"q" => "oak"})
        assert html =~ "Front finishes"
        refute html =~ "Hinge sides"

        # The set's own name and slug still match, and a term matching
        # neither still says so.
        html = render_change(view, "attr_sets_search", %{"q" => "Hinge"})
        assert html =~ "Hinge sides"
        refute html =~ "Front finishes"

        html = render_change(view, "attr_sets_search", %{"q" => "zzz-nothing"})
        assert html =~ "No sets match your search."
      end

      test "archived values don't make a set match", %{conn: conn} do
        {:ok, set} = Catalogue.create_attribute_set(%{name: "Retired palette"})
        {:ok, value} = Catalogue.create_attribute_set_value(set, %{label: "Discontinued teal"})

        # Archiving is an entities-side lifecycle change; the catalogue's
        # update_value/4 only carries the label and extras.
        {:ok, _} =
          PhoenixKitEntities.EntityData.update(value, %{status: "archived"}, activity_log: false)

        {:ok, view, _html} = live(conn, "/en/admin/catalogue/attributes")

        # The viewer hides archived values, so they must not drag their
        # set into the results either.
        html = render_change(view, "attr_sets_search", %{"q" => "teal"})
        assert html =~ "No sets match your search."
      end

      test "the query is trimmed: a trailing space still matches", %{conn: conn} do
        {:ok, _} = Catalogue.create_attribute_set(%{name: "Doors Color"})
        {:ok, view, _html} = live(conn, "/en/admin/catalogue/attributes")

        html = render_change(view, "attr_sets_search", %{"q" => "Doors Color "})
        assert html =~ "Doors Color"
        refute html =~ "No sets match your search."

        # Spaces-only means "no filter", not "match nothing".
        html = render_change(view, "attr_sets_search", %{"q" => "   "})
        assert html =~ "Doors Color"
      end

      test "the deferred backstop migration message reloads without crashing", %{conn: conn} do
        {:ok, view, _html} = live(conn, "/en/admin/catalogue/attributes")

        send(view.pid, :auto_migrate_legacy)
        assert render(view)
      end
    end

    describe "AttributeGroupFormLive with sets live" do
      test "redirects to the attributes listing instead of rendering", %{conn: conn} do
        assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
                 live(conn, "/en/admin/catalogue/attributes/new")

        assert to == Paths.attribute_groups()
        assert flash["info"] =~ "replaced by sets"
      end
    end

    describe "OrphanPruner subscriber" do
      test "prunes on :entity_deleted, absorbs everything else" do
        {:ok, set} = Catalogue.create_attribute_set(%{name: "Pruned"})
        item = fixture_item(%{name: "PrunedItem"})
        {:ok, _} = Catalogue.attach_attribute_set(item.uuid, set.uuid)

        # Out-of-band delete (bypasses the guard), then the PubSub
        # handler — invoked directly so the sandbox owns the DB calls.
        Repo.delete!(set)
        assert {:noreply, %{}} = OrphanPruner.handle_info({:entity_deleted, set.uuid}, %{})
        assert Catalogue.list_attribute_set_attachments(item.uuid) == []

        # Shared-topic traffic and junk payloads are absorbed.
        assert {:noreply, %{}} = OrphanPruner.handle_info({:entity_created, set.uuid}, %{})
        assert {:noreply, %{}} = OrphanPruner.handle_info({:entity_deleted, "junk"}, %{})
        assert {:noreply, %{}} = OrphanPruner.handle_info(:noise, %{})
      end
    end

    describe "product card attribute rows" do
      test "selection narrows the set row; no selection shows all values" do
        {:ok, set} = Catalogue.create_attribute_set(%{name: "Card colors"})
        {:ok, red} = Catalogue.create_attribute_set_value(set, %{label: "Red"})
        {:ok, _} = Catalogue.create_attribute_set_value(set, %{label: "Blue"})

        item = fixture_item(%{name: "CardItem"})
        {:ok, _} = Catalogue.attach_attribute_set(item.uuid, set.uuid)
        item = Catalogue.get_item(item.uuid)

        # No selection → the whole set renders.
        assert {"Card colors", "Red, Blue"} in ProductCard.build_fields(item, "en")

        # One tick → this exact object.
        :ok = Catalogue.set_attribute_set_selection(item.uuid, set.uuid, [red.slug])
        assert {"Card colors", "Red"} in ProductCard.build_fields(item, "en")
      end
    end

    describe "catalogue detail bottom navigation" do
      test "root shows All catalogues; category level adds Up one level", %{conn: conn} do
        catalogue = fixture_catalogue(%{name: "NavCat"})
        category = fixture_category(catalogue, %{name: "NavCategory"})

        {:ok, _view, root_html} = live(conn, "/en/admin/catalogue/#{catalogue.uuid}")
        assert root_html =~ "All catalogues"
        refute root_html =~ "Up one level"

        {:ok, _view, cat_html} =
          live(conn, "/en/admin/catalogue/#{catalogue.uuid}?category=#{category.uuid}")

        assert cat_html =~ "Up one level"
        assert cat_html =~ "All catalogues"
      end
    end

    describe "paths" do
      test "the set editor paths are gone — editing moved to entities" do
        refute function_exported?(Paths, :attribute_set_new, 0)
        refute function_exported?(Paths, :attribute_set_edit, 1)
      end
    end
  else
    @tag :skip
    test "entities package lacks the Managed contract — suite skipped" do
      assert true
    end
  end
end
