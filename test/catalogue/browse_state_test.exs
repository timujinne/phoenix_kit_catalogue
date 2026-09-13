defmodule PhoenixKitCatalogue.Catalogue.BrowseStateTest do
  @moduledoc """
  The reducer is the security boundary of the item selector: every fetch's
  opts derive from the immutable host scope, so these tests cross the
  {command, scope-shape} product rather than sampling it — the 2026-08-21
  quality-sweep lesson is that untested combinations are where the defects
  were.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitCatalogue.Catalogue.BrowseState
  alias PhoenixKitCatalogue.Web.TableConfig

  defp item(uuid), do: %{uuid: uuid}

  defp opts_map({_state, {:fetch, opts, _gen}}), do: Map.new(opts)

  describe ":refresh re-reads in place" do
    test "keeps search and level, covers every loaded page in one fetch, pages on from there" do
      state = BrowseState.init(scope: %{catalogue_uuids: ["cat-1"]}, per_page: 2)
      {state, _} = BrowseState.command(state, {:search, "screw"})
      state = BrowseState.ingest(state, state.gen, [item("a"), item("b")], 5)
      {state, _} = BrowseState.command(state, :load_more)
      state = BrowseState.ingest(state, state.gen, [item("c"), item("d")], 5)
      assert state.page == 1

      {refreshed, {:fetch, opts, gen}} = BrowseState.command(state, :refresh)

      assert gen == state.gen + 1
      assert opts[:search] == nil or opts[:search] == "screw"
      assert refreshed.search == "screw"
      assert refreshed.page == 1
      assert opts[:offset] == 0
      assert opts[:limit] == 4, "both loaded pages in one read"
      assert refreshed.items == []
      assert refreshed.loading?

      # The re-read replaces the accumulator and paging continues after it.
      refreshed =
        BrowseState.ingest(refreshed, gen, [item("a"), item("c"), item("d"), item("e")], 5)

      assert Enum.map(refreshed.items, & &1.uuid) == ["a", "c", "d", "e"]
      refute refreshed.exhausted?

      {next, {:fetch, next_opts, _}} = BrowseState.command(refreshed, :load_more)
      assert next.page == 2
      assert next_opts[:offset] == 4
    end

    test "a refresh that comes back short is exhausted, like any page" do
      state = BrowseState.init(scope: %{}, per_page: 2)
      {state, _} = BrowseState.command(state, :reset)
      state = BrowseState.ingest(state, state.gen, [item("a"), item("b")], 3)
      {state, _} = BrowseState.command(state, :load_more)
      state = BrowseState.ingest(state, state.gen, [item("c")], 3)

      {refreshed, {:fetch, _opts, gen}} = BrowseState.command(state, :refresh)
      refreshed = BrowseState.ingest(refreshed, gen, [item("a"), item("c")], 2)

      assert refreshed.exhausted?
      assert {_, :noop} = BrowseState.command(refreshed, :load_more)
    end
  end

  describe "scope is a boundary" do
    test "catalogue_uuids and :only survive every command that fetches" do
      scope = %{
        catalogue_uuids: ["cat-1"],
        only: :uncategorized_only,
        statuses: [:active],
        include_descendants: false
      }

      state = BrowseState.init(scope: scope)

      for cmd <- [:reset, {:search, "screw"}, :load_more] do
        opts = opts_map(BrowseState.command(state, cmd))

        assert opts[:catalogue_uuids] == ["cat-1"], "#{inspect(cmd)} dropped catalogue scope"
        assert opts[:only] == :uncategorized_only, "#{inspect(cmd)} dropped :only"
        assert opts[:statuses] == [:active], "#{inspect(cmd)} dropped :statuses"
        assert opts[:include_descendants] == false, "#{inspect(cmd)} dropped :include_descendants"
      end
    end

    test "a string-keyed or unknown-key scope raises rather than silently widening" do
      assert_raise ArgumentError, ~r/unknown keys/, fn ->
        BrowseState.init(scope: %{"catalogue_uuids" => ["cat-1"]})
      end

      assert_raise ArgumentError, ~r/unknown keys/, fn ->
        BrowseState.init(scope: %{catalogue_uuids: ["cat-1"], extra: true})
      end
    end

    test "a non-binary search or category command is a no-op, not a crash" do
      state = BrowseState.init(scope: %{})
      assert {^state, :noop} = BrowseState.command(state, {:search, ["crafted"]})
      assert {^state, :noop} = BrowseState.command(state, {:set_category, 123})
    end

    test "a category command NARROWS scope.category_uuids, never escapes it" do
      state = BrowseState.init(scope: %{category_uuids: ["a", "b"]})

      # Inside the allowed set: narrows to exactly that category.
      assert {narrowed, {:fetch, opts, _}} = BrowseState.command(state, {:set_category, "a"})
      assert Map.new(opts)[:category_uuids] == ["a"]
      assert narrowed.category_uuid == "a"

      # Outside it: rejected outright — a crafted chip event cannot widen
      # what the host allowed.
      assert {^state, :noop} = BrowseState.command(state, {:set_category, "evil"})
    end

    test "clearing the category falls back to the scope restriction, not to everything" do
      state = BrowseState.init(scope: %{category_uuids: ["a", "b"]})
      {state, _} = BrowseState.command(state, {:set_category, "a"})

      opts = opts_map(BrowseState.command(state, {:set_category, nil}))
      assert opts[:category_uuids] == ["a", "b"]
    end

    test "an unscoped state allows any UUID category and nil clears to all" do
      state = BrowseState.init(scope: %{})
      uuid = Ecto.UUID.generate()

      assert {_, {:fetch, opts, _}} = BrowseState.command(state, {:set_category, uuid})
      assert Map.new(opts)[:category_uuids] == [uuid]

      # No restriction and no chip -> the key is absent entirely.
      opts = opts_map(BrowseState.command(BrowseState.init(scope: %{}), :reset))
      refute Map.has_key?(opts, :category_uuids)
    end

    test "an unscoped state still rejects a non-UUID category string" do
      # With no allow-list, membership can't guard the value — and a
      # crafted "garbage" would raise Ecto.Query.CastError inside the
      # subtree expansion, crashing the host LiveView. :noop instead.
      state = BrowseState.init(scope: %{})
      assert {^state, :noop} = BrowseState.command(state, {:set_category, "garbage"})
    end

    test "an :uncategorized_only scope rejects every category command" do
      # search_items/2 raises on :uncategorized_only + category_uuids by
      # contract, so allowing the narrowing would emit contradictory opts.
      state = BrowseState.init(scope: %{only: :uncategorized_only})
      assert {^state, :noop} = BrowseState.command(state, {:set_category, Ecto.UUID.generate()})

      # The scope itself still fetches fine — only the narrowing is barred.
      assert {_, {:fetch, opts, _}} = BrowseState.command(state, :reset)
      assert Map.new(opts)[:only] == :uncategorized_only
      refute Map.has_key?(Map.new(opts), :category_uuids)
    end

    test "the :uncategorized narrowing becomes :uncategorized_only, never category_uuids" do
      state = BrowseState.init(scope: %{catalogue_uuids: ["cat-1"]})

      assert {state, {:fetch, opts, _}} =
               BrowseState.command(state, {:set_category, :uncategorized})

      opts = Map.new(opts)
      assert opts[:only] == :uncategorized_only
      refute Map.has_key?(opts, :category_uuids)
      assert opts[:catalogue_uuids] == ["cat-1"]

      # Clearing the chip restores the plain scope.
      assert {_, {:fetch, opts, _}} = BrowseState.command(state, {:set_category, nil})
      refute Map.has_key?(Map.new(opts), :only)
    end

    test ":uncategorized is refused where the scope restricts categories or sets :only" do
      restricted = BrowseState.init(scope: %{category_uuids: ["a"]})

      assert {^restricted, :noop} =
               BrowseState.command(restricted, {:set_category, :uncategorized})

      only = BrowseState.init(scope: %{only: :categorized_only})
      assert {^only, :noop} = BrowseState.command(only, {:set_category, :uncategorized})
    end

    test "per_page is floored at 1 — a 0 page size could never exhaust" do
      assert BrowseState.init(per_page: 0).per_page == 1
      assert BrowseState.init(per_page: 24).per_page == 24
    end

    test "set_catalogue narrows within a multi-catalogue scope and rejects outsiders" do
      state = BrowseState.init(scope: %{catalogue_uuids: ["cat-a", "cat-b"]})

      assert {drilled, {:fetch, opts, _}} =
               BrowseState.command(state, {:set_catalogue, "cat-b"})

      assert Map.new(opts)[:catalogue_uuids] == ["cat-b"]
      assert drilled.catalogue_uuid == "cat-b"

      assert {^state, :noop} = BrowseState.command(state, {:set_catalogue, "cat-evil"})
      assert {^state, :noop} = BrowseState.command(state, {:set_catalogue, 123})

      # Clearing restores the full offered list.
      opts = opts_map(BrowseState.command(drilled, {:set_catalogue, nil}))
      assert opts[:catalogue_uuids] == ["cat-a", "cat-b"]
    end

    test "set_catalogue is refused on a singleton scope — no catalogue level exists there" do
      # The documented contract: only accepted when the scope names
      # SEVERAL catalogues. A crafted accept on [A] would strand the
      # presentation in a level it never renders tiles for
      # (external review, 2026-08-31).
      state = BrowseState.init(scope: %{catalogue_uuids: ["cat-a"]})
      assert {^state, :noop} = BrowseState.command(state, {:set_catalogue, "cat-a"})

      unscoped = BrowseState.init(scope: %{})
      assert {^unscoped, :noop} = BrowseState.command(unscoped, {:set_catalogue, "cat-a"})
    end

    test "browse listings in ONE catalogue read in the admin's position order" do
      # Max, 2026-08-31: the popup and the admin showed different item
      # orders — the admin's default is document order (position, name),
      # the fetch layer's was name. BROWSE fetches ask for :position
      # explicitly (since 2026-09-12 for every scope, and it is the fetch
      # layer's default as well); a live SEARCH passes no order.
      single = BrowseState.init(scope: %{catalogue_uuids: ["cat-1"]}, drill: :direct)
      assert opts_map(BrowseState.command(single, :reset))[:order] == :position

      assert opts_map(BrowseState.command(single, {:set_category, Ecto.UUID.generate()}))[
               :order
             ] == :position

      # Searching passes no order (the fetch layer's default, Manual since
      # 2026-09-12, stands); clearing it restores the explicit position.
      opts = opts_map(BrowseState.command(single, {:search, "screw"}))
      refute Map.has_key?(opts, :order)

      # A multi-catalogue ROOT reads in document order too (Max,
      # 2026-09-12: "the default should be the manual order" — the
      # fetch layer's chain leads with the catalogue's position)…
      multi = BrowseState.init(scope: %{catalogue_uuids: ["cat-1", "cat-2"]})
      assert opts_map(BrowseState.command(multi, :reset))[:order] == :position

      # …and so does drilling catalogue-first into one.
      assert opts_map(BrowseState.command(multi, {:set_catalogue, "cat-2"}))[:order] ==
               :position
    end

    test "a CATEGORY-ONLY scope reads in position order too" do
      # Client, 2026-09-12: "the popup's order isn't the catalogue's" —
      # tim-dev's per-category narrow pickers pass category_uuids with
      # catalogue_uuids: nil. The Manual gate keyed off the catalogue
      # alone, so that shape silently dropped :position and the fetch
      # layer listed the category A→Z while the admin showed the
      # hand-arranged order. A category belongs to exactly one catalogue,
      # so an explicit category set is as coherent for position as a
      # single catalogue is.
      narrow = BrowseState.init(scope: %{category_uuids: ["cat-a"]}, drill: :direct)
      assert opts_map(BrowseState.command(narrow, :reset))[:order] == :position

      # The shared Manual sort rides it the same way.
      manual =
        BrowseState.init(
          scope: %{category_uuids: ["cat-a"], catalogue_uuids: nil},
          drill: :direct,
          order: {:position, :asc}
        )

      assert opts_map(BrowseState.command(manual, :reset))[:order] == :position

      # A parent scope expanded to its subtree is still an explicit set.
      subtree = BrowseState.init(scope: %{category_uuids: ["cat-a", "cat-a-1", "cat-a-2"]})
      assert opts_map(BrowseState.command(subtree, :reset))[:order] == :position

      # Drilling a category under a multi-catalogue root keeps it.
      multi = BrowseState.init(scope: %{catalogue_uuids: ["cat-1", "cat-2"]}, drill: :direct)

      assert opts_map(BrowseState.command(multi, {:set_category, Ecto.UUID.generate()}))[
               :order
             ] == :position

      # A live search passes no order here as everywhere.
      refute Map.has_key?(opts_map(BrowseState.command(narrow, {:search, "screw"})), :order)

      # The fetch scope is untouched: no catalogue is invented for it.
      refute Map.has_key?(opts_map(BrowseState.command(narrow, :reset)), :catalogue_uuids)
    end

    test "the module's shared sort rides every browse fetch; search still wins" do
      # Client, 2026-09-01: one order for the whole module, the popup
      # included. The components pass the shared sort as init `:order`.
      state =
        BrowseState.init(scope: %{catalogue_uuids: ["cat-1"]}, order: {:name, :desc})

      assert opts_map(BrowseState.command(state, :reset))[:order] == {:name, :desc}

      # A field sort is coherent across catalogues — unlike position, a
      # multi-catalogue root applies it too.
      multi =
        BrowseState.init(
          scope: %{catalogue_uuids: ["cat-1", "cat-2"]},
          order: {:base_price, :asc}
        )

      assert opts_map(BrowseState.command(multi, :reset))[:order] == {:base_price, :asc}

      # A live search passes no order — the fetch layer's Manual default
      # stands, like the admin's in-catalogue search results.
      opts = opts_map(BrowseState.command(state, {:search, "screw"}))
      refute Map.has_key?(opts, :order)

      # Manual keeps the direction-less :position opt (the admin's Manual
      # sort has no direction either), whatever the scope offers.
      manual = BrowseState.init(scope: %{catalogue_uuids: ["cat-1"]}, order: {:position, :asc})
      assert opts_map(BrowseState.command(manual, :reset))[:order] == :position

      manual_multi =
        BrowseState.init(
          scope: %{catalogue_uuids: ["cat-1", "cat-2"]},
          order: {:position, :asc}
        )

      assert opts_map(BrowseState.command(manual_multi, :reset))[:order] == :position

      # Junk raises at init — a bad field must not sail into the fetch
      # layer as a no-op sort.
      assert_raise ArgumentError, ~r/order must be/, fn ->
        BrowseState.init(order: {:markup, :asc})
      end

      assert_raise ArgumentError, ~r/order must be/, fn ->
        BrowseState.init(order: "name:desc")
      end
    end

    test "a whitespace-only search keeps the :direct level's own-items listing" do
      # The fetch layer trims "   " to no text filter, so treating it as
      # a live search would flip the level to subtree listing for a query
      # that filters nothing (external review, 2026-08-31).
      uuid = Ecto.UUID.generate()
      state = BrowseState.init(scope: %{}, drill: :direct)
      {state, _} = BrowseState.command(state, {:set_category, uuid})

      opts = opts_map(BrowseState.command(state, {:search, "   "}))
      assert opts[:category_uuids] == [uuid]
      assert opts[:include_descendants] == false

      # A real query still covers the subtree — finding beats filing.
      opts = opts_map(BrowseState.command(state, {:search, "screw"}))
      assert opts[:category_uuids] == [uuid]
      refute Map.has_key?(opts, :include_descendants)
    end
  end

  describe "paging" do
    test "reset fetches page 0 and load_more advances the offset" do
      state = BrowseState.init(per_page: 24)

      {state, {:fetch, opts, gen}} = BrowseState.command(state, :reset)
      assert Map.new(opts)[:offset] == 0
      assert Map.new(opts)[:limit] == 24

      state = BrowseState.ingest(state, gen, Enum.map(1..24, &item("u#{&1}")), 100)

      {_state, {:fetch, opts, _}} = BrowseState.command(state, :load_more)
      assert Map.new(opts)[:offset] == 24
    end

    test "load_more is a no-op while loading or exhausted" do
      state = BrowseState.init()
      {loading, {:fetch, _, _}} = BrowseState.command(state, :reset)
      assert {^loading, :noop} = BrowseState.command(loading, :load_more)

      {state, {:fetch, _, gen}} = BrowseState.command(BrowseState.init(per_page: 24), :reset)
      exhausted = BrowseState.ingest(state, gen, [item("only")], 1)
      assert exhausted.exhausted?
      assert {^exhausted, :noop} = BrowseState.command(exhausted, :load_more)
    end

    test "a short page marks exhausted; a full page under total does not" do
      {state, {:fetch, _, gen}} = BrowseState.command(BrowseState.init(per_page: 2), :reset)

      full = BrowseState.ingest(state, gen, [item("a"), item("b")], 5)
      refute full.exhausted?

      {state2, {:fetch, _, gen2}} = BrowseState.command(full, :load_more)
      short = BrowseState.ingest(state2, gen2, [item("c")], 5)
      assert short.exhausted?
    end
  end

  describe "generations" do
    test "a stale ingest is discarded whole" do
      {state, {:fetch, _, stale_gen}} =
        BrowseState.command(BrowseState.init(), {:search, "a"})

      # The user kept typing before page 1 of "a" resolved.
      {state, {:fetch, _, _fresh_gen}} = BrowseState.command(state, {:search, "ab"})

      after_stale = BrowseState.ingest(state, stale_gen, [item("wrong")], 1)
      assert after_stale.items == []
      assert after_stale.loading?
    end

    test "search resets the accumulator, not just the page" do
      {state, {:fetch, _, gen}} = BrowseState.command(BrowseState.init(), :reset)
      state = BrowseState.ingest(state, gen, [item("old")], 1)

      {state, {:fetch, opts, _}} = BrowseState.command(state, {:search, "new"})
      assert state.items == []
      assert Map.new(opts)[:offset] == 0
    end

    test "an unchanged search or category is a no-op — no gratuitous refetch" do
      {state, {:fetch, _, gen}} = BrowseState.command(BrowseState.init(), {:search, "q"})
      state = BrowseState.ingest(state, gen, [], 0)

      assert {^state, :noop} = BrowseState.command(state, {:search, "q"})
      assert {^state, :noop} = BrowseState.command(state, {:set_category, nil})
    end
  end

  describe "input capping" do
    test "the search string is capped at 200 characters" do
      long = String.duplicate("a", 5_000)
      {state, {:fetch, _, _}} = BrowseState.command(BrowseState.init(), {:search, long})
      assert String.length(state.search) == 200
    end
  end

  describe "the shared sort's vocabulary" do
    test "every sortable :detail_items column is an accepted browse order" do
      # Two lists that must stay in sync. TableConfig's sortable ids are
      # exactly what the `catalogue_sort_detail_items` setting may name,
      # and `init/1` RAISES on a field it does not know — so a new
      # sortable column would crash every popup and embed the moment an
      # admin picked it, not at the point it was added. Fail here instead.
      for %{id: id} <- Enum.filter(TableConfig.columns(:detail_items), & &1.sortable?),
          dir <- [:asc, :desc] do
        order = {String.to_existing_atom(id), dir}

        assert %BrowseState{order: ^order} =
                 BrowseState.init(scope: %{catalogue_uuids: ["cat-1"]}, order: order)
      end
    end
  end

  describe "ingest de-duplication" do
    test "a row re-served by a shifted offset does not append twice" do
      {state, {:fetch, _, gen}} = BrowseState.command(BrowseState.init(per_page: 2), :reset)
      state = BrowseState.ingest(state, gen, [item("a"), item("b")], 4)

      {state, {:fetch, _, gen2}} = BrowseState.command(state, :load_more)
      state = BrowseState.ingest(state, gen2, [item("b"), item("c")], 4)

      assert Enum.map(state.items, & &1.uuid) == ["a", "b", "c"]
    end
  end
end
