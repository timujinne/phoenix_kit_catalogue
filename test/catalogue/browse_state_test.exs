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
