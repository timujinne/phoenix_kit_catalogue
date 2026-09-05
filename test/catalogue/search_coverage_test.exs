defmodule PhoenixKitCatalogue.Catalogue.SearchCoverageTest do
  @moduledoc """
  What catalogue search covers, pinned end to end (Max's audit,
  2026-08-28): item names, category and SUBcategory names, every
  language, and the niceties — trimming, case, and LIKE metacharacters
  staying literal.

  Category search did not exist before this audit: searching a catalogue
  for a category it contains returned nothing, and the page only looked
  like it had matched because that category's own card was on screen.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue

  setup %{conn: conn, scope: scope} do
    cat = fixture_catalogue(%{name: "Kitchen Range"})

    {:ok, parent} = Catalogue.create_category(%{name: "Cabinet Doors", catalogue_uuid: cat.uuid})

    {:ok, child} =
      Catalogue.create_category(%{
        name: "Shaker Fronts",
        catalogue_uuid: cat.uuid,
        parent_uuid: parent.uuid
      })

    top =
      fixture_item(%{name: "Brass Handle", catalogue_uuid: cat.uuid, category_uuid: parent.uuid})

    deep = fixture_item(%{name: "Oak Panel", catalogue_uuid: cat.uuid, category_uuid: child.uuid})
    loose = fixture_item(%{name: "Loose Screw", catalogue_uuid: cat.uuid})

    %{
      conn: with_scope(conn, scope),
      cat: cat,
      parent: parent,
      child: child,
      top: top,
      deep: deep,
      loose: loose
    }
  end

  defp names(rows), do: Enum.map(rows, & &1.name)

  describe "items" do
    test "found catalogue-wide, inside subcategories, and uncategorized", ctx do
      assert names(Catalogue.search_items_in_catalogue(ctx.cat.uuid, "Brass")) == ["Brass Handle"]

      # A subcategory's item is found from the catalogue root…
      assert names(Catalogue.search_items_in_catalogue(ctx.cat.uuid, "Oak")) == ["Oak Panel"]

      # …and from its parent, whose scope includes descendants.
      assert names(Catalogue.search_items_in_category(ctx.parent.uuid, "Oak")) == ["Oak Panel"]

      assert names(
               Catalogue.search_items(" Loose ",
                 catalogue_uuids: [ctx.cat.uuid],
                 only: :uncategorized_only
               )
             ) == ["Loose Screw"]
    end
  end

  describe "categories" do
    test "by name, at any depth, scoped like items are", ctx do
      assert names(Catalogue.search_categories(ctx.cat.uuid, "Cabinet")) == ["Cabinet Doors"]
      assert names(Catalogue.search_categories(ctx.cat.uuid, "Shaker")) == ["Shaker Fronts"]

      # Drilled into the parent: its subtree, excluding the node you are
      # standing in (navigating to where you already are is not a result).
      assert names(
               Catalogue.search_categories(ctx.cat.uuid, "Shaker", parent_uuid: ctx.parent.uuid)
             ) ==
               ["Shaker Fronts"]

      assert Catalogue.search_categories(ctx.cat.uuid, "Cabinet", parent_uuid: ctx.parent.uuid) ==
               []
    end

    test "deleted categories stay out", ctx do
      {:ok, _} = Catalogue.trash_category(ctx.child)
      assert Catalogue.search_categories(ctx.cat.uuid, "Shaker") == []
    end
  end

  describe "every language" do
    test "items and categories are found by their translated names", ctx do
      {:ok, _} =
        Catalogue.update_category(ctx.child, %{data: %{"et" => %{"_name" => "Uksed Eesti"}}})

      {:ok, _} = Catalogue.update_item(ctx.deep, %{data: %{"et" => %{"_name" => "Tammepaneel"}}})

      # Translations live in each record's data JSONB; both searches match
      # it, so the language the admin is viewing in doesn't matter.
      assert names(Catalogue.search_items_in_catalogue(ctx.cat.uuid, "Tammepaneel")) == [
               "Oak Panel"
             ]

      assert names(Catalogue.search_categories(ctx.cat.uuid, "Uksed")) == ["Shaker Fronts"]
    end
  end

  describe "structure is not content" do
    test "a query matching only a JSON key finds nothing", ctx do
      # `data::text ILIKE` read the whole encoded document, so a row
      # holding the key "_name" answered a search for "a" — which is how
      # a catalogue called "Plumbing" turned up (Max, 2026-08-28).
      {:ok, _} = Catalogue.update_item(ctx.deep, %{data: %{"et" => %{"_name" => "Tammepaneel"}}})

      {:ok, _} =
        Catalogue.update_category(ctx.child, %{data: %{"et" => %{"_name" => "Uksed Eesti"}}})

      # The key names are "_name" and "et" — neither may match.
      refute Enum.any?(
               Catalogue.search_items_in_catalogue(ctx.cat.uuid, "_name"),
               &(&1.uuid == ctx.deep.uuid)
             )

      assert Catalogue.search_categories(ctx.cat.uuid, "_name") == []
      # (Not asserting on the language key "et" — it legitimately matches
      # "Cabinet Doors" by NAME.)

      # …while the VALUES still do.
      assert names(Catalogue.search_items_in_catalogue(ctx.cat.uuid, "Tammepaneel")) == [
               "Oak Panel"
             ]

      assert names(Catalogue.search_categories(ctx.cat.uuid, "Uksed")) == ["Shaker Fronts"]
    end

    test "the listing filter reads values, not the encoded map", ctx do
      # Same defect one layer up: the catalogues index filters rows in
      # memory, and JSON-encoding the row matched key names too.
      {:ok, _} =
        Catalogue.update_catalogue(ctx.cat, %{data: %{"et" => %{"_name" => "Köögisari"}}})

      # ?mode=catalogues: the index's auto mode answers a query with ITEM
      # results since the 2026-08-31 search-default flip — catalogue-name
      # coverage lives behind the explicit switch.
      {:ok, view, _html} = live(ctx.conn, "/en/admin/catalogue?mode=catalogues")

      assert render_change(view, "table_search", %{"query" => "Köögisari"}) =~ "Kitchen Range"
      refute render_change(view, "table_search", %{"query" => "_name"}) =~ "Kitchen Range"
    end
  end

  describe "the niceties" do
    test "trimmed, case-insensitive, and % is a literal percent", ctx do
      assert names(Catalogue.search_items_in_catalogue(ctx.cat.uuid, "  Brass  ")) == [
               "Brass Handle"
             ]

      assert names(Catalogue.search_items_in_catalogue(ctx.cat.uuid, "bRaSs")) == ["Brass Handle"]
      assert names(Catalogue.search_categories(ctx.cat.uuid, "  shaker ")) == ["Shaker Fronts"]

      # A bare "%" would match everything if it reached LIKE unescaped.
      assert Catalogue.search_items_in_catalogue(ctx.cat.uuid, "%") == []
      assert Catalogue.search_categories(ctx.cat.uuid, "%") == []

      # An all-space query is "no query", not "match nothing at all".
      assert Catalogue.search_categories(ctx.cat.uuid, "   ") == []
    end
  end

  describe "the detail page" do
    test "surfaces matching categories beside the items, with their trail", ctx do
      {:ok, view, _html} = live(ctx.conn, "/en/admin/catalogue/#{ctx.cat.uuid}")

      render_change(view, "search", %{"query" => "Oak"})
      html = render_async(view)
      assert html =~ "Oak Panel"

      render_change(view, "search", %{"query" => "Shaker"})
      render_async(view)
      assigns = :sys.get_state(view.pid).socket.assigns

      assert names(assigns.search_categories) == ["Shaker Fronts"]
      # The trail tells two same-named subcategories apart.
      assert assigns.category_trails[ctx.child.uuid] == "Cabinet Doors"

      # …and the item summary keeps quiet rather than announcing
      # "0 results" directly above the category it just found.
      refute render(view) =~ "0 results"
    end

    test "a query matching nothing at all says so once", ctx do
      {:ok, view, _html} = live(ctx.conn, "/en/admin/catalogue/#{ctx.cat.uuid}")

      render_change(view, "search", %{"query" => "zzz-nothing"})
      html = render_async(view)

      assert html =~ "Nothing matches your search."
    end
  end

  describe "the catalogues listing" do
    test "matches a catalogue by name in any language, trimmed", ctx do
      {:ok, _} =
        Catalogue.update_catalogue(ctx.cat, %{data: %{"et" => %{"_name" => "Köögisari"}}})

      # Explicit catalogues mode — see "structure is not content" above.
      {:ok, view, _html} = live(ctx.conn, "/en/admin/catalogue?mode=catalogues")

      assert render_change(view, "table_search", %{"query" => "  kitchen  "}) =~ "Kitchen Range"
      assert render_change(view, "table_search", %{"query" => "Köögisari"}) =~ "Kitchen Range"
    end
  end

  describe "order: :position (admin document order, 2026-08-31)" do
    test "browse fetches read position order; the default stays name order" do
      cat = fixture_catalogue(%{name: "Ordered Range"})
      grouping = fixture_category(cat, %{name: "Grouping"})

      # Names invert the positions, so the two orders are distinguishable.
      z_first =
        fixture_item(%{name: "Zed First", catalogue_uuid: cat.uuid, category_uuid: grouping.uuid})

      a_last =
        fixture_item(%{
          name: "Alpha Last",
          catalogue_uuid: cat.uuid,
          category_uuid: grouping.uuid
        })

      {:ok, _} = Catalogue.update_item(Catalogue.get_item!(z_first.uuid), %{position: 1})
      {:ok, _} = Catalogue.update_item(Catalogue.get_item!(a_last.uuid), %{position: 2})

      opts = [category_uuids: [grouping.uuid], include_descendants: false]

      by_position = Catalogue.search_items("", opts ++ [order: :position])
      assert Enum.map(by_position, & &1.name) == ["Zed First", "Alpha Last"]

      by_name = Catalogue.search_items("", opts)
      assert Enum.map(by_name, & &1.name) == ["Alpha Last", "Zed First"]
    end

    # `i.position` is per-(catalogue, category), so a listing that spans
    # SEVERAL categories — every CatalogueBrowse level (drill: :subtree
    # is the BrowseState default) and the selector popup's opt-in flat
    # root — must lead with the CATEGORY's position or the per-category
    # ordinals interleave: all the 1s, then all the 2s. The pin above
    # uses one category, where the two chains are indistinguishable.
    test "a listing spanning several categories walks category by category, not ordinal by ordinal" do
      cat = fixture_catalogue(%{name: "Two Section Range"})
      first = fixture_category(cat, %{name: "First Section", position: 1})
      second = fixture_category(cat, %{name: "Second Section", position: 2})

      for {category, names} <- [{first, ["F One", "F Two"]}, {second, ["S One", "S Two"]}] do
        names
        |> Enum.with_index(1)
        |> Enum.each(fn {name, position} ->
          item =
            fixture_item(%{
              name: name,
              catalogue_uuid: cat.uuid,
              category_uuid: category.uuid
            })

          {:ok, _} = Catalogue.update_item(Catalogue.get_item!(item.uuid), %{position: position})
        end)
      end

      # A loose item has no category position at all — it sorts last,
      # exactly as search_items_in_catalogue/3 places it.
      loose = fixture_item(%{name: "Loose End", catalogue_uuid: cat.uuid})
      {:ok, _} = Catalogue.update_item(Catalogue.get_item!(loose.uuid), %{position: 1})

      names =
        ""
        |> Catalogue.search_items(catalogue_uuids: [cat.uuid], order: :position)
        |> Enum.map(& &1.name)

      assert names == ["F One", "F Two", "S One", "S Two", "Loose End"]

      # The same chain the admin's catalogue-wide read walks.
      assert names ==
               cat.uuid
               |> Catalogue.search_items_in_catalogue("")
               |> Enum.map(& &1.name)
    end

    test "{field, dir} orders read the admin's directional sorts" do
      # Client, 2026-09-01: the module's shared sort names one of the
      # admin's directional fields, and browse fetches carry it as
      # `order: {field, dir}` — same chain as `item_order_by/3`, uuid
      # tie-broken.
      cat = fixture_catalogue(%{name: "Directional Range"})
      grouping = fixture_category(cat, %{name: "Grouping"})

      cheap =
        fixture_item(%{
          name: "Bravo Cheap",
          sku: "SKU-1",
          base_price: Decimal.new("1.00"),
          catalogue_uuid: cat.uuid,
          category_uuid: grouping.uuid
        })

      dear =
        fixture_item(%{
          name: "Alpha Dear",
          sku: "SKU-2",
          base_price: Decimal.new("9.00"),
          catalogue_uuid: cat.uuid,
          category_uuid: grouping.uuid
        })

      # Positions invert the names so {:position, _} is distinguishable
      # from every field sort.
      {:ok, _} = Catalogue.update_item(Catalogue.get_item!(cheap.uuid), %{position: 1})
      {:ok, _} = Catalogue.update_item(Catalogue.get_item!(dear.uuid), %{position: 2})

      opts = [category_uuids: [grouping.uuid], include_descendants: false]

      fetch = fn order ->
        Enum.map(Catalogue.search_items("", opts ++ [order: order]), & &1.name)
      end

      assert fetch.({:name, :asc}) == ["Alpha Dear", "Bravo Cheap"]
      assert fetch.({:name, :desc}) == ["Bravo Cheap", "Alpha Dear"]
      # SKUs invert the names, so this cannot be satisfied by the name
      # fallback (the non-distinguishing shape the first pin had).
      assert fetch.({:sku, :asc}) == ["Bravo Cheap", "Alpha Dear"]
      assert fetch.({:sku, :desc}) == ["Alpha Dear", "Bravo Cheap"]
      assert fetch.({:base_price, :desc}) == ["Alpha Dear", "Bravo Cheap"]
      assert fetch.({:base_price, :asc}) == ["Bravo Cheap", "Alpha Dear"]
      # Manual ignores the direction, exactly like the admin's.
      assert fetch.({:position, :desc}) == ["Bravo Cheap", "Alpha Dear"]
    end
  end
end
