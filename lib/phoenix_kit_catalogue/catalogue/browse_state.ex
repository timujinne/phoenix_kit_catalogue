defmodule PhoenixKitCatalogue.Catalogue.BrowseState do
  @moduledoc """
  Pure browse-state reducer for paged, searchable, category-filtered item
  browsing — the shared brain of `ItemSelectorModal` and any embedded
  browse surface.

  Holds no process and runs no queries. A caller feeds it commands, it
  answers with what to fetch; the caller runs the query (however it likes —
  synchronously in `handle_event/3` today, `start_async` tomorrow) and hands
  the result back to `ingest/4`. That split is what makes every transition
  testable without a database, and what lets two different LiveComponents
  drive one implementation instead of drifting copies.

      {state, effect} = BrowseState.command(state, {:search, "screw"})
      # effect: {:fetch, query_opts, gen} | :noop

      case effect do
        {:fetch, opts, gen} ->
          items = Search.search_items(state.search, opts)
          total = Search.count_search_items(state.search, opts)
          BrowseState.ingest(state, gen, items, total)

        :noop ->
          state
      end

  ## Scope is a boundary, not a default

  `init/1` fixes the host-supplied scope for the state's lifetime and every
  `query_opts/1` re-derives from it, so no later command can widen it: a
  category command narrows WITHIN `scope.category_uuids` (and is rejected
  outside it), search composes with it, and nothing can un-set
  `:catalogue_uuids` / `:only`. A crafted client event can therefore never
  make the fetch layer return items the host did not allow.

  An empty list (`[]`) in a scope entry means **unrestricted** — the same
  alias for `nil` the whole `Search.search_items/2` vocabulary uses — not
  "nothing allowed". A host wanting to show nothing should not mount the
  browse surface at all.

  ## Generations

  Every effectful command bumps `gen`, and `ingest/4` discards results
  carrying a stale one. With synchronous fetches events serialize and the
  guard never fires; it exists so moving to async fetches is a drop-in
  rather than a redesign — a page 1 of "a" resolving after the state reset
  to "ab" must not append the wrong results.
  """

  alias PhoenixKitCatalogue.Schemas.Item

  @default_per_page 24

  # Mirrors the `Search.search_items/2` filter vocabulary (paging/preload
  # excluded). A string-keyed or unknown-key scope would read as no
  # restriction and silently widen browsing — fail loud at init instead.
  @scope_keys [:catalogue_uuids, :category_uuids, :only, :statuses, :include_descendants]

  defstruct scope: %{},
            search: "",
            category_uuid: nil,
            page: 0,
            per_page: @default_per_page,
            drill: :subtree,
            items: [],
            known_uuids: MapSet.new(),
            total: nil,
            loading?: false,
            exhausted?: false,
            gen: 0

  @type t :: %__MODULE__{}

  @doc """
  Builds the initial state. `opts`:

    * `:scope` — map with any of `:catalogue_uuids`, `:category_uuids`,
      `:only`, `:statuses`, `:include_descendants`. Fixed for the state's
      lifetime. Unknown keys raise `ArgumentError`.
    * `:per_page` — page size (default #{@default_per_page}).
    * `:drill` — what browsing INTO a category lists. `:subtree` (default)
      keeps today's flat-chip semantics: the category and everything under
      it. `:direct` is the admin detail page's file-explorer semantics (the
      boss's 2026-08-30 ruling there): the level you are standing in shows
      its OWN items, while a non-empty search still covers the subtree —
      finding beats filing. Fixed at init like the scope.
  """
  def init(opts \\ []) do
    drill = opts[:drill] || :subtree

    if drill not in [:subtree, :direct] do
      raise ArgumentError, "BrowseState drill must be :subtree or :direct, got: #{inspect(drill)}"
    end

    %__MODULE__{
      scope: validate_scope!(Map.new(opts[:scope] || %{})),
      # Floored at 1: a 0 page size never satisfies `length(items) < per_page`,
      # so `exhausted?` could not latch and :load_more would page forever.
      per_page: max(opts[:per_page] || @default_per_page, 1),
      drill: drill
    }
  end

  defp validate_scope!(scope) do
    case Map.keys(scope) -- @scope_keys do
      [] ->
        scope

      bad ->
        raise ArgumentError,
              "BrowseState scope has unknown keys #{inspect(bad)} — " <>
                "use #{inspect(@scope_keys)} (atoms, the search_items/2 vocabulary)"
    end
  end

  @doc """
  Applies a command. Returns `{state, {:fetch, query_opts, gen}}` when the
  caller should run a fetch, `{state, :noop}` otherwise.

  Commands:

    * `:reset` — first load / clear everything back to the scope.
    * `{:search, q}` — replace the search string (no-op when unchanged).
    * `{:set_category, uuid | :uncategorized | nil}` — narrow to one
      category, to the items WITHOUT one, or back to all within scope.
      Rejected with `:noop` when the uuid falls outside
      `scope.category_uuids`, or (for `:uncategorized`) when the scope
      restricts categories or carries its own `:only` — scope only ever
      narrows.
    * `:load_more` — next page. No-op while loading or exhausted.
  """
  def command(state, :reset) do
    fetch(%{state | search: "", category_uuid: nil})
  end

  def command(%{search: q} = state, {:search, q}), do: {state, :noop}

  def command(state, {:search, q}) when is_binary(q) do
    # Client input: cap it. Nothing a human searches for needs more, and an
    # unbounded string goes straight into a query.
    fetch(%{state | search: String.slice(q, 0, 200)})
  end

  def command(state, {:search, _}), do: {state, :noop}

  def command(%{category_uuid: uuid} = state, {:set_category, uuid}), do: {state, :noop}

  def command(state, {:set_category, nil}), do: fetch(%{state | category_uuid: nil})

  def command(state, {:set_category, :uncategorized}) do
    # "No category" is a real narrowing choice — the chips otherwise never
    # add up when uncategorized items exist. Only offered/accepted where
    # the scope neither restricts categories (uncategorized sits outside
    # any allow-list) nor carries an :only of its own (search_items/2
    # raises on contradictions).
    if state.scope[:only] == nil and state.scope[:category_uuids] in [nil, []] do
      fetch(%{state | category_uuid: :uncategorized})
    else
      {state, :noop}
    end
  end

  def command(state, {:set_category, uuid}) when is_binary(uuid) do
    if category_allowed?(state.scope, uuid) do
      fetch(%{state | category_uuid: uuid})
    else
      {state, :noop}
    end
  end

  def command(state, {:set_category, _}), do: {state, :noop}

  def command(%{loading?: true} = state, :load_more), do: {state, :noop}
  def command(%{exhausted?: true} = state, :load_more), do: {state, :noop}

  def command(state, :load_more) do
    state = %{state | page: state.page + 1, loading?: true, gen: state.gen + 1}
    {state, {:fetch, query_opts(state), state.gen}}
  end

  # A fresh fetch: page 0, accumulator cleared.
  defp fetch(state) do
    state = %{
      state
      | page: 0,
        items: [],
        known_uuids: MapSet.new(),
        total: nil,
        exhausted?: false,
        loading?: true,
        gen: state.gen + 1
    }

    {state, {:fetch, query_opts(state), state.gen}}
  end

  @doc """
  Folds a fetched page into the state. A stale `gen` is discarded whole —
  the state that requested it no longer exists.

  Appends are de-duplicated by uuid: offset paging over a live catalogue can
  re-serve a row when the sort shifts between fetches, and a duplicate card
  (same DOM id twice) is worse than a briefly missing one.
  """
  def ingest(%{gen: gen} = state, gen, items, total) do
    fresh = Enum.reject(items, &MapSet.member?(state.known_uuids, uuid_of(&1)))
    all = state.items ++ fresh

    %{
      state
      | items: all,
        known_uuids: Enum.into(fresh, state.known_uuids, &uuid_of/1),
        total: total,
        loading?: false,
        exhausted?: length(items) < state.per_page or (is_integer(total) and length(all) >= total)
    }
  end

  def ingest(state, _stale_gen, _items, _total), do: state

  @doc """
  The `Search.search_items/2` opts for the current state — always derived
  from the immutable scope, never from anything a client event set directly.
  """
  def query_opts(state) do
    base = Map.take(state.scope, [:catalogue_uuids, :only, :statuses, :include_descendants])

    base =
      case state.category_uuid do
        # The uncategorized narrowing IS an :only — never combined with
        # category_uuids (the fetch layer raises on the contradiction, and
        # command/2 only admits it on scopes without their own :only).
        :uncategorized ->
          Map.put(base, :only, :uncategorized_only)

        # A drilled level under :direct lists its OWN items; a search from
        # there still covers the subtree (see the :drill doc on init/1).
        uuid when is_binary(uuid) and state.drill == :direct and state.search == "" ->
          base
          |> Map.put(:category_uuids, [uuid])
          |> Map.put(:include_descendants, false)

        _ ->
          Map.put(base, :category_uuids, effective_category_uuids(state))
      end

    base
    |> Map.put(:limit, state.per_page)
    |> Map.put(:offset, state.page * state.per_page)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  # nil scope restriction + no chip -> nil (all); chip -> [chip];
  # scope restriction + no chip -> the restriction itself.
  defp effective_category_uuids(%{category_uuid: nil, scope: scope}),
    do: scope[:category_uuids]

  defp effective_category_uuids(%{category_uuid: uuid}), do: [uuid]

  # Beyond the allow-list, two rejections keep a crafted (or merely stale)
  # chip event from crashing the host LV in the fetch layer:
  # `:uncategorized_only` scopes contradict ANY category narrowing —
  # `search_items/2` raises on the combination by contract — and on an
  # UNRESTRICTED scope a non-UUID string would sail into the subtree
  # expansion and raise `Ecto.Query.CastError`. Both degrade to :noop.
  # A host-provided allow-list is trusted as-is: membership is the guard
  # there, and garbage a host wrote crashes loudly on its own head.
  # (`Ecto.UUID.cast/1` also accepts 16-byte raw UUIDs; that's fine —
  # those are still valid query input.)
  defp category_allowed?(scope, uuid) do
    if scope[:only] == :uncategorized_only do
      false
    else
      case scope[:category_uuids] do
        nil -> valid_uuid?(uuid)
        [] -> valid_uuid?(uuid)
        allowed -> uuid in allowed
      end
    end
  end

  defp valid_uuid?(uuid), do: match?({:ok, _}, Ecto.UUID.cast(uuid))

  defp uuid_of(%Item{uuid: uuid}), do: to_string(uuid)
  defp uuid_of(%{uuid: uuid}), do: to_string(uuid)
end
