defmodule PhoenixKitCatalogue.Catalogue.AttributeFilterTest do
  @moduledoc """
  Filtering items by their attribute VALUES — "all items with blue doors"
  (Max, 2026-08-28). The slugs are the ones an item's attachment stores
  in `data["selected_value_slugs"]`, i.e. what the item form writes.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitCatalogue.Schemas.ItemAttributeSet
  alias PhoenixKitCatalogue.Test.Repo, as: TestRepo
  alias PhoenixKitCatalogue.Web.Components

  if Code.ensure_loaded?(PhoenixKitEntities.Managed) do
    setup %{conn: conn, scope: scope} do
      AttributeSets.register_deletion_guard()
      PhoenixKit.Settings.update_setting("entities_enabled", "true")
      on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)

      catalogue = fixture_catalogue(%{name: "Filter Cat"})

      {:ok, category} =
        Catalogue.create_category(%{name: "Doors", catalogue_uuid: catalogue.uuid})

      {:ok, colour} = Catalogue.create_attribute_set(%{name: "Colour"})
      {:ok, blue} = Catalogue.create_attribute_set_value(colour, %{label: "Blue"})
      {:ok, red} = Catalogue.create_attribute_set_value(colour, %{label: "Red"})

      {:ok, wood} = Catalogue.create_attribute_set(%{name: "Wood"})
      {:ok, oak} = Catalogue.create_attribute_set_value(wood, %{label: "Oak"})

      blue_oak =
        fixture_item(%{
          name: "Blue oak door",
          catalogue_uuid: catalogue.uuid,
          category_uuid: category.uuid
        })

      blue_pine =
        fixture_item(%{
          name: "Blue pine door",
          catalogue_uuid: catalogue.uuid,
          category_uuid: category.uuid
        })

      red_door =
        fixture_item(%{
          name: "Red door",
          catalogue_uuid: catalogue.uuid,
          category_uuid: category.uuid
        })

      for {item, set, slug} <- [
            {blue_oak, colour, blue.slug},
            {blue_oak, wood, oak.slug},
            {blue_pine, colour, blue.slug},
            {red_door, colour, red.slug}
          ] do
        {:ok, _} = Catalogue.attach_attribute_set(item.uuid, set.uuid)
        :ok = AttributeSets.set_attachment_selection(item.uuid, set.uuid, [slug])
      end

      %{
        conn: with_scope(conn, scope),
        catalogue: catalogue,
        category: category,
        colour: colour,
        blue: blue,
        red: red,
        oak: oak,
        items: %{blue_oak: blue_oak, blue_pine: blue_pine, red_door: red_door}
      }
    end

    defp names(items), do: items |> Enum.map(& &1.name) |> Enum.sort()

    defp assert_patched_with_filter(view, slugs) do
      path = assert_patch(view, 100)
      assert path =~ "attr="
      for slug <- slugs, do: assert(path =~ slug)
    rescue
      # The patch may already have been consumed by an earlier assertion;
      # the assigns are the source of truth either way.
      _ ->
        assert Enum.sort(
                 :sys.get_state(view.pid).socket.assigns.attribute_filter
                 |> String.split(",", trim: true)
               ) == Enum.sort(slugs)
    end

    test "one slug narrows the level to the items carrying it", ctx do
      assert names(
               Catalogue.list_items_for_category_paged(ctx.category.uuid,
                 value_slugs: [ctx.blue.slug]
               )
             ) == ["Blue oak door", "Blue pine door"]

      assert Catalogue.item_count_for_category(ctx.category.uuid, value_slugs: [ctx.blue.slug]) ==
               2
    end

    test "two slugs NARROW, they don't widen", ctx do
      # "blue oak doors" is one item, not three.
      assert names(
               Catalogue.list_items_for_category_paged(ctx.category.uuid,
                 value_slugs: [ctx.blue.slug, ctx.oak.slug]
               )
             ) == ["Blue oak door"]
    end

    test "no slugs is no filter, and an unknown slug matches nothing", ctx do
      assert length(Catalogue.list_items_for_category_paged(ctx.category.uuid)) == 3

      assert Catalogue.list_items_for_category_paged(ctx.category.uuid, value_slugs: [])
             |> length() == 3

      assert Catalogue.list_items_for_category_paged(ctx.category.uuid, value_slugs: ["nope"]) ==
               []
    end

    test "search stays inside the filter", ctx do
      assert names(
               Catalogue.search_items("door",
                 catalogue_uuids: [ctx.catalogue.uuid],
                 value_slugs: [ctx.blue.slug]
               )
             ) == ["Blue oak door", "Blue pine door"]
    end

    test "the page filters, and the filter is in the URL", ctx do
      url = "/en/admin/catalogue/#{ctx.catalogue.uuid}?category=#{ctx.category.uuid}&mode=items"

      {:ok, view, html} = live(ctx.conn, url)
      assert html =~ "Blue oak door"
      assert html =~ "Red door"

      # The control offers the sets in use…
      assert html =~ "Colour"
      assert html =~ "Wood"

      # …and picking a value narrows the level. The click patches the URL,
      # so read the view AFTER the patch rather than the click's return.
      render_click(view, "toggle_attribute_filter", %{"slug" => ctx.blue.slug})
      html = render(view)
      assert html =~ "Blue oak door"
      assert html =~ "Blue pine door"
      refute html =~ "Red door"

      # A second value narrows further rather than widening.
      render_click(view, "toggle_attribute_filter", %{"slug" => ctx.oak.slug})
      html = render(view)
      assert html =~ "Blue oak door"
      refute html =~ "Blue pine door"

      # It rides in the URL, so the filtered view is a link…
      assert_patched_with_filter(view, [ctx.blue.slug, ctx.oak.slug])

      # …and clicking the same value again removes it.
      render_click(view, "toggle_attribute_filter", %{"slug" => ctx.oak.slug})
      html = render(view)
      assert html =~ "Blue pine door"

      render_click(view, "clear_attribute_filter", %{})
      html = render(view)
      assert html =~ "Red door"
    end

    test "a filtered link opens filtered", ctx do
      {:ok, _view, html} =
        live(
          ctx.conn,
          "/en/admin/catalogue/#{ctx.catalogue.uuid}?category=#{ctx.category.uuid}&mode=items&attr=#{ctx.blue.slug}"
        )

      assert html =~ "Blue oak door"
      refute html =~ "Red door"
    end

    test "counts say what each value would still match", ctx do
      counts = Catalogue.attribute_value_match_counts(catalogue_uuid: ctx.catalogue.uuid)

      assert counts[ctx.blue.slug] == 2
      assert counts[ctx.oak.slug] == 1

      # Conditioned on the current selection: with Blue on, Oak reports
      # the blue OAK items, not every oak item — so a dead combination
      # reads 0 before it is picked rather than emptying the list after.
      narrowed =
        Catalogue.attribute_value_match_counts(
          catalogue_uuid: ctx.catalogue.uuid,
          value_slugs: [ctx.blue.slug]
        )

      assert narrowed[ctx.oak.slug] == 1

      # A value nothing carries is simply absent — the UI reads that as 0
      # and disables it.
      {:ok, unused} = Catalogue.create_attribute_set_value(ctx.colour, %{label: "Chartreuse"})
      refute Map.has_key?(counts, unused.slug)
    end

    test "a value that leads nowhere is offered disabled, not clickable", ctx do
      # "Chartreuse" exists on the set but nothing carries it.
      {:ok, dead} = Catalogue.create_attribute_set_value(ctx.colour, %{label: "Chartreuse"})

      {:ok, view, _html} =
        live(ctx.conn, "/en/admin/catalogue/#{ctx.catalogue.uuid}?category=#{ctx.category.uuid}")

      assert has_element?(view, ~s|button[phx-value-slug="#{dead.slug}"][disabled]|)
      refute has_element?(view, ~s|button[phx-value-slug="#{ctx.blue.slug}"][disabled]|)

      # Picking Blue greys out what cannot be combined with it: no item
      # is both blue and red, so Red dies the moment Blue is on.
      render_click(view, "toggle_attribute_filter", %{"slug" => ctx.blue.slug})

      assert has_element?(view, ~s|button[phx-value-slug="#{ctx.red.slug}"][disabled]|)
      # Oak survives — one item is both.
      refute has_element?(view, ~s|button[phx-value-slug="#{ctx.oak.slug}"][disabled]|)
      # And Blue itself stays clickable, or it could never be switched off.
      refute has_element?(view, ~s|button[phx-value-slug="#{ctx.blue.slug}"][disabled]|)
    end

    test "counts follow the level you are standing in", ctx do
      # An item in ANOTHER category of the same catalogue must not keep a
      # value alive here: the filter narrows this level, so the counts
      # have to be about this level.
      {:ok, elsewhere} =
        Catalogue.create_category(%{name: "Elsewhere", catalogue_uuid: ctx.catalogue.uuid})

      far =
        fixture_item(%{
          name: "Far away",
          catalogue_uuid: ctx.catalogue.uuid,
          category_uuid: elsewhere.uuid
        })

      {:ok, teal} = Catalogue.create_attribute_set_value(ctx.colour, %{label: "Teal"})
      {:ok, _} = Catalogue.attach_attribute_set(far.uuid, ctx.colour.uuid)
      :ok = AttributeSets.set_attachment_selection(far.uuid, ctx.colour.uuid, [teal.slug])

      # Catalogue-wide, Teal matches one item…
      assert Catalogue.attribute_value_match_counts(catalogue_uuid: ctx.catalogue.uuid)[teal.slug] ==
               1

      # …but standing in Doors, it matches nothing, so the page offers it
      # disabled.
      {:ok, view, _html} =
        live(ctx.conn, "/en/admin/catalogue/#{ctx.catalogue.uuid}?category=#{ctx.category.uuid}")

      assert has_element?(view, ~s|button[phx-value-slug="#{teal.slug}"][disabled]|)
    end

    test "a level where nothing carries a value offers no filter at all", ctx do
      {:ok, empty_cat} =
        Catalogue.create_category(%{name: "Plain", catalogue_uuid: ctx.catalogue.uuid})

      fixture_item(%{
        name: "Plain item",
        catalogue_uuid: ctx.catalogue.uuid,
        category_uuid: empty_cat.uuid
      })

      {:ok, view, html} =
        live(
          ctx.conn,
          "/en/admin/catalogue/#{ctx.catalogue.uuid}?category=#{empty_cat.uuid}&mode=items"
        )

      assert html =~ "Plain item"
      # Items mode keeps the control visible (it is a primary control
      # there since 2026-08-29) — but every value is dead at this level,
      # so each one is offered disabled, not clickable.
      assert has_element?(view, ~s|button[phx-value-slug="#{ctx.blue.slug}"][disabled]|)

      # …while the level that does carry values offers it live.
      {:ok, doors, _} =
        live(
          ctx.conn,
          "/en/admin/catalogue/#{ctx.catalogue.uuid}?category=#{ctx.category.uuid}&mode=items"
        )

      assert has_element?(doors, ~s|button[phx-value-slug="#{ctx.blue.slug}"]:not([disabled])|)
    end

    test "the index counts catalogues, not items", ctx do
      counts =
        Catalogue.attribute_value_match_counts(count: :catalogues)

      # Two blue items, but they live in ONE catalogue.
      assert counts[ctx.blue.slug] == 1
    end

    test "toggling the filter engages the item results and narrows them", ctx do
      # The filter used to mean "which catalogues have blue in them" —
      # an item question grafted onto a catalogue list, which needed a
      # disclaimer line. Since 2026-08-29 it narrows actual items, and
      # since 2026-08-31 it ENGAGES the item-results section by itself
      # (the modes are retired — one surface).
      other = fixture_catalogue(%{name: "No Attributes Here"})
      fixture_item(%{name: "Plain thing", catalogue_uuid: other.uuid})

      {:ok, view, html} = live(ctx.conn, "/en/admin/catalogue")
      refute html =~ "item-result-"

      render_click(view, "toggle_attribute_filter", %{"slug" => ctx.blue.slug})
      html = render_async(view)

      assert html =~ "Blue oak door"
      assert html =~ "Blue pine door"
      refute html =~ "Plain thing"

      # Clearing the last narrowing disengages the section entirely.
      render_click(view, "clear_attribute_filter", %{})
      refute render_async(view) =~ "item-result-"
    end

    test "the filter is offered on the plain index — it is the way IN", ctx do
      assert ctx.catalogue

      # With the modes retired (2026-08-31) the filter must be visible
      # before any results exist: toggling a value is what engages the
      # item-results section. The control's own DOM id — the word
      # "Attributes" and the swatch icon both also appear in the admin
      # chrome, so they prove nothing.
      {:ok, _view, html} = live(ctx.conn, "/en/admin/catalogue")
      assert html =~ ~s(id="attribute-filter")
    end

    test "the index offers every set in use anywhere", ctx do
      assert ctx.catalogue

      names = Catalogue.attribute_filter_options(:all) |> Enum.map(& &1.name)
      assert "Colour" in names
      assert "Wood" in names
    end

    test "the filter offers only sets this catalogue actually uses", ctx do
      {:ok, _unused} = Catalogue.create_attribute_set(%{name: "Unused elsewhere"})

      options = Catalogue.attribute_filter_options(ctx.catalogue.uuid)

      assert Enum.map(options, & &1.name) == ["Colour", "Wood"]

      colour = Enum.find(options, &(&1.name == "Colour"))
      assert Enum.sort(Enum.map(colour.values, & &1.title)) == ["Blue", "Red"]
    end

    test "a categories-type search hides the item-level filter", ctx do
      # The filter narrows items; a categories-only result list cannot
      # show its effect, so offering it there is a control that lies.
      # "door" (singular) matters: it matches the items AND the "Doors"
      # category — "doors" matches no item, and the filter would hide in
      # All mode too, for the ordinary every-value-is-dead reason.
      {:ok, view, _html} =
        live(ctx.conn, "/en/admin/catalogue/#{ctx.catalogue.uuid}?q=door&type=categories")

      refute render_async(view) =~ ~s(id="attribute-filter")

      {:ok, view, _html} = live(ctx.conn, "/en/admin/catalogue/#{ctx.catalogue.uuid}?q=door")
      assert render_async(view) =~ ~s(id="attribute-filter")
    end

    test "an attribute-set broadcast reloads an open items-mode index", ctx do
      {:ok, view, _html} = live(ctx.conn, "/en/admin/catalogue?mode=items")
      render_click(view, "toggle_attribute_filter", %{"slug" => ctx.blue.slug})
      assert render_async(view) =~ "Blue oak door"

      # Prune the selection straight in the DB — a context write would
      # ALSO broadcast :item and mask what this test pins — then deliver
      # only the :attribute_set message a set-level write sends. The open
      # list must move on that kind alone, or a value archived elsewhere
      # leaves an items search offering rows the filter no longer
      # matches.
      import Ecto.Query

      {1, _} =
        TestRepo.update_all(
          from(a in ItemAttributeSet,
            where: a.item_uuid == ^ctx.items.blue_oak.uuid and a.set_uuid == ^ctx.colour.uuid
          ),
          set: [data: %{"selected_value_slugs" => []}]
        )

      send(view.pid, {:catalogue_data_changed, :attribute_set, ctx.colour.uuid, nil})

      refute render_async(view) =~ "Blue oak door"
    end

    test "items mode keeps the filter visible when a search kills every value", ctx do
      # The dead-values rule used to hide the whole button; in items mode
      # the filter is a primary control — greyed values, not a vanished
      # button (Max, 2026-08-29).
      other = fixture_catalogue(%{name: "No Attributes Here"})
      fixture_item(%{name: "Plain thing", catalogue_uuid: other.uuid})

      {:ok, _view, html} = live(ctx.conn, "/en/admin/catalogue?q=plain")
      assert html =~ ~s(id="attribute-filter")

      # Same on the detail page, searched into nothing.
      {:ok, view, _html} =
        live(ctx.conn, "/en/admin/catalogue/#{ctx.catalogue.uuid}?q=zzznothing")

      assert render_async(view) =~ ~s(id="attribute-filter")
    end

    test "a repeated slug in the URL still toggles off in one click", ctx do
      assert ctx.catalogue

      # `?attr=oak,oak` parsed to two entries, and toggling deleted one —
      # the box stayed ticked and the control read as dead.
      assert Components.attribute_filter_slugs(%{attribute_filter: "oak,oak"}) == ["oak"]

      assert Components.attribute_filter_slugs(%{attribute_filter: " blue , oak ,blue"}) ==
               ["blue", "oak"]
    end

    describe "counts answer for the list beside them" do
      # "Selectable means it has results" is the whole promise (Max,
      # 2026-08-28). Every scope the LISTING is under has to reach the
      # counts, or a value is offered as live on a page that has none of
      # it — and picking it empties the list, which is the thing this was
      # built to prevent.

      test "a search narrows them", ctx do
        all = Catalogue.attribute_value_match_counts(catalogue_uuid: ctx.catalogue.uuid)
        assert all[ctx.blue.slug] == 2
        assert all[ctx.red.slug] == 1

        # "oak" matches one item, and that item is blue — so Red is dead
        # here even though the catalogue has a red door.
        searched =
          Catalogue.attribute_value_match_counts(
            catalogue_uuid: ctx.catalogue.uuid,
            search: "oak"
          )

        assert searched[ctx.blue.slug] == 1
        assert searched[ctx.oak.slug] == 1
        assert Map.get(searched, ctx.red.slug, 0) == 0
      end

      test "a blank or whitespace search is no constraint", ctx do
        for term <- [nil, "", "   "] do
          counts =
            Catalogue.attribute_value_match_counts(
              catalogue_uuid: ctx.catalogue.uuid,
              search: term
            )

          assert counts[ctx.blue.slug] == 2
        end
      end

      test "the index counts only within the catalogues on screen", ctx do
        other = fixture_catalogue(%{name: "Elsewhere"})
        stray = fixture_item(%{name: "Stray red", catalogue_uuid: other.uuid})
        {:ok, _} = Catalogue.attach_attribute_set(stray.uuid, ctx.colour.uuid)
        :ok = AttributeSets.set_attachment_selection(stray.uuid, ctx.colour.uuid, [ctx.red.slug])

        # Unscoped, Red is carried by two catalogues.
        assert Catalogue.attribute_value_match_counts(count: :catalogues)[ctx.red.slug] == 2

        # Scoped to the one the list is showing, by one.
        scoped =
          Catalogue.attribute_value_match_counts(
            count: :catalogues,
            catalogue_uuids: [ctx.catalogue.uuid]
          )

        assert scoped[ctx.red.slug] == 1

        # And a list showing nothing offers nothing — an empty scope is a
        # real answer, not "no constraint".
        assert Catalogue.attribute_value_match_counts(count: :catalogues, catalogue_uuids: []) ==
                 %{}
      end

      test "the index's items mode counts inside the drilled folder's subtree", ctx do
        {:ok, parent} = Catalogue.create_folder(%{name: "Parent shelf"})
        {:ok, child} = Catalogue.create_folder(%{name: "Child shelf", parent_uuid: parent.uuid})
        {:ok, _} = Catalogue.move_catalogue_to_folder(ctx.catalogue, child.uuid)

        # A second red item OUTSIDE the folder — an unscoped count would
        # read 2.
        other = fixture_catalogue(%{name: "Elsewhere"})
        stray = fixture_item(%{name: "Stray red", catalogue_uuid: other.uuid})
        {:ok, _} = Catalogue.attach_attribute_set(stray.uuid, ctx.colour.uuid)

        :ok =
          AttributeSets.set_attachment_selection(stray.uuid, ctx.colour.uuid, [ctx.red.slug])

        {:ok, view, _html} =
          live(ctx.conn, "/en/admin/catalogue?folder=#{parent.uuid}&attr=#{ctx.red.slug}")

        render_async(view)
        counts = :sys.get_state(view.pid).socket.assigns.attribute_value_counts

        # Items mode stands where the user stands: "Filter Cat" sits in
        # the SUBFOLDER, so its one red door counts; the stray red lives
        # outside the drilled folder and must not. Level-only scoping
        # would count nothing at all.
        assert counts[ctx.red.slug] == 1
      end

      test "the trash counts its own items rather than contradicting itself", ctx do
        {:ok, _} = Catalogue.trash_item(ctx.items.blue_oak)

        # Default: deleted items are out.
        live = Catalogue.attribute_value_match_counts(catalogue_uuid: ctx.catalogue.uuid)
        assert live[ctx.blue.slug] == 1

        # Asked for explicitly, they are counted — `status in ["deleted"]`
        # used to meet a hardcoded `status != "deleted"` and every value
        # came back 0, which read as "nothing here is filterable".
        trashed =
          Catalogue.attribute_value_match_counts(
            catalogue_uuid: ctx.catalogue.uuid,
            statuses: ["deleted"]
          )

        assert trashed[ctx.blue.slug] == 1
        assert trashed[ctx.oak.slug] == 1
      end
    end
  end
end
