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
      # the fetch layer's is name. Single-catalogue BROWSE fetches now
      # ask for :position; several catalogues keep name order (position
      # is per-catalogue scope, interleaving it is meaningless), and a
      # live SEARCH stays name-ordered everywhere, like the admin's
      # results.
      single = BrowseState.init(scope: %{catalogue_uuids: ["cat-1"]}, drill: :direct)
      assert opts_map(BrowseState.command(single, :reset))[:order] == :position

      assert opts_map(BrowseState.command(single, {:set_category, Ecto.UUID.generate()}))[
               :order
             ] == :position

      # Searching switches to name order; clearing it restores position.
      opts = opts_map(BrowseState.command(single, {:search, "screw"}))
      refute Map.has_key?(opts, :order)

      # A multi-catalogue ROOT keeps name order…
      multi = BrowseState.init(scope: %{catalogue_uuids: ["cat-1", "cat-2"]})
      refute Map.has_key?(opts_map(BrowseState.command(multi, :reset)), :order)

      # …but drilling catalogue-first into one restores document order.
      assert opts_map(BrowseState.command(multi, {:set_catalogue, "cat-2"}))[:order] ==
               :position
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

      # A live search stays name-ordered, like the admin's results.
      opts = opts_map(BrowseState.command(state, {:search, "screw"}))
      refute Map.has_key?(opts, :order)

      # Manual keeps the single-catalogue guard and the direction-less
      # :position opt (the admin's Manual sort has no direction either).
      manual = BrowseState.init(scope: %{catalogue_uuids: ["cat-1"]}, order: {:position, :asc})
      assert opts_map(BrowseState.command(manual, :reset))[:order] == :position

      manual_multi =
        BrowseState.init(
          scope: %{catalogue_uuids: ["cat-1", "cat-2"]},
          order: {:position, :asc}
        )

      refute Map.has_key?(opts_map(BrowseState.command(manual_multi, :reset)), :order)

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
