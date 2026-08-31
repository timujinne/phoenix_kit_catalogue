# PR #87: Drilled mixed view follow-ups — card-grade images, subtree search toggle, one Columns popup

**Author**: @mdon
**Reviewer**: Claude (`elixir:phoenix-thinking` + `elixir:ecto-thinking` applied before reading source)
**Status**: Merged
**Commit**: `ebb481f` (merge of `99f3e40..c0eb6d8`)
**Date**: 2026-08-30
**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/87
**Reviewed as part of**: the 0.22.0 release sweep, together with [#85](/dev_docs/pull_requests/2026/85-catalogue-quality-sweep) and [#86](/dev_docs/pull_requests/2026/86-search-modes-and-category-browser) — the three PRs merged after `v0.21.0` and never published.

## What changed

Three follow-ups on the drilled category page:

1. **Card-grade images.** `card_media` gained `variant` (defaults to the 800px `medium` for card-width slots) and `comfy_scale` (false for fill slots, so the `[.pk-comfy_&]:w-18` row override stops shrinking a band image to a 72px square). The band grew `h-24 → h-40` and moved *inside* the `:card_media` slot, because the pinned core ignores `card_media_class`. Small row cells went the other way: a new `Browse.featured_thumb_url/1` feeds `thumb_url` to the 32–48px cells that had been downloading the 800px asset.
2. **Subtree search toggle.** A drilled category's page is one mixed view; the old Categories/Items switcher became an "include subcategory items" toggle. Its final semantics — settled *within the PR* by `6b8e551` and `c0eb6d8` — are that it refines **the search only, never the browse list**, and it is offered whenever subcategories exist so it can pre-arm the next search.
3. **One Columns popup.** `TableToolbar.column_sections_modal/1` replaces two side-by-side Columns buttons with one modal carrying a section per visible table.

## Findings

### 1. IMPROVEMENT — HIGH: dead subtree machinery on the browse path, shipping as public API

The PR first widened the *browse* listing to the subtree (`4289661`, `117c8ff`), then reversed that design two commits later — `6b8e551` "The subtree toggle refines the search only, never the browse list", reaffirmed by `c0eb6d8` ("its EFFECT stays search-only"). The reversal changed the LiveView but left the context-layer machinery behind:

- `Catalogue.item_status_counts_for_categories/1` — **no caller anywhere** in `lib/` or `test/`. Its own `@doc` advertises it as "for the detail page's tabs when 'include subcategory items' is on", but `node_status_counts/2` still calls the singular `item_status_counts_for_category/1` unconditionally, which is now the correct behaviour.
- The `:include_descendants` option on `list_items_for_category_paged/2` and `item_count_for_category/2`, via the private `level_category_uuids/2` and `apply_level_item_order/2`. **Every** call site — the only two in production, `fetch_card_items/6` and `card_total/4` — passed `include_descendants: false` explicitly. No caller, in `lib/` or `test/`, ever passed `true`.

Why it matters beyond tidiness: `PhoenixKitCatalogue.Catalogue` is the module's single public context, so publishing 0.22.0 would have put an untested, unreachable option on the released API surface — one whose behaviour contradicts the design the PR settled on. `apply_level_item_order/2`'s subtree branch is also the one place in the file that appends a `join` *after* `filter_by_attribute_values/2` has already added its `EXISTS` clauses; it has zero test coverage, so it would be exercised for the first time by whoever eventually flipped the option on.

**Fixed**: removed `item_status_counts_for_categories/1`, `level_category_uuids/2` and `apply_level_item_order/2`; `list_items_for_category_paged/2` and `item_count_for_category/2` are back to the plain single-category scope and `apply_item_order/2`. Both `@doc`s now state the level-only rule and point at `search_items_in_category/3`'s `:include_descendants` as the place the subtree question actually lives. The two LiveView call sites dropped the now-meaningless `include_descendants: false`, with a comment recording why there is nothing to choose between.

Nothing was removed from the search path: `Catalogue.search_items_in_category/3` → `Search.expand_category_scope/1` still expands the subtree, and `counts_scope/2` still widens the facet counts to `category_subtree_uuids/1` during a subtree search. That is the mechanism the toggle drives, and it is covered.

**Test added** (`test/catalogue_test.exs`): pins that the level listing and the count under a category header stay direct-only while the *search* over the same category still returns the subtree — so the browse path cannot silently re-widen.

### 2. BUG — HIGH: the release gate was red, and dialyzer had stopped running

`mix precommit` exits **2** on this tree. `credo --strict` fails on a
`Credo.Check.Design.AliasUsage` violation introduced by `232f561` ("Merge the two
Columns buttons into one sectioned modal") — a fully-qualified
`PhoenixKitCatalogue.Web.TableConfig.default_columns(:detail_categories)` inline in
`test/web/catalogue_detail_live_test.exs:563` where every other reference in that
file goes through an alias.

The consequence is bigger than the style nit: `precommit` chains
`compile --warnings-as-errors`, `deps.unlock --check-unused`, `hex.audit`, then
`quality.ci` = `format --check-formatted` → `credo --strict` → `dialyzer`. Mix
aborts an alias at the first failing task, so **dialyzer has not run on this tree
since #87 merged** — the gate was reporting a credo style failure while silently
skipping the type check behind it.

This is the same shape as the `<.icon class={[...]}>` warning PR #83 left behind
before the 0.21.0 release (see
[#84's review](/dev_docs/pull_requests/2026/84-attributes-viewer-honest-search-filter/CLAUDE_REVIEW.md),
finding 1): a small defect in a merged PR that takes the whole shared gate down
until someone runs it at release time.

**Fixed**: aliased `PhoenixKitCatalogue.Web.TableConfig` at the top of the test
module alongside the existing `Catalogue` alias, and called `TableConfig.default_columns/1`
through it. `credo --strict` is clean, and dialyzer runs again.

### 3. IMPROVEMENT — MEDIUM: facet counts computed twice on a filter/toggle patch (not fixed)

Introduced by #86 (`272d59b`), surfaced while tracing this PR's toggle. In `handle_url_state/2`:

```elixir
filter_changed? or toggles_changed? ->
  socket |> handle_url_state_search(state.search_query) |> reset_and_load()
```

`handle_url_state_search/2` → `run_search/2` calls `assign_attribute_counts/2`, then `reset_and_load/1` → `load_level/2` calls it again (`catalogue_detail_live.ex`, the `assign(view_mode: …) |> assign_attribute_counts(uuid)` pair). Both run synchronously in the LiveView process, and `value_match_counts/1` is a lateral-join + `group_by` over `ItemAttributeSet` — so every attribute-filter toggle and every subtree-toggle click pays for it twice and throws one result away. It also quietly defeats #86's own panel finding: `run_search/2` deliberately *skips* the count query for a `"categories"`-type search, and `load_level/2` then runs it anyway.

**Not fixed.** Output is correct either way (the second call wins and computes the same map), so this is cost, not a defect. Every fix I could see either couples `load_level/2` to "is a search about to run right after me" — the exact ordering coupling the panel already had to untangle once in `load_url_state_level/3` — or reorders a `cond` branch that the search stamp depends on. That is a deliberate refactor for a quiet moment, not a change to fold into a release gate. Recorded here so the cost is on the books.

## Not defects on verification

- **`thumb_url` vs `photo_url` split.** `AttributeSetItemsModal`, `ItemSelectorModal`'s tray and `Browse.item_row` all switched to `row.thumb_url`, which would be a `KeyError` for any row map not built by `Browse.present_items/2`. Traced every producer: the modal zips `present_items/2` output (`attribute_set_items_modal.ex:103`), and both selector-entry builders go through it too (`item_selector_modal.ex:442`, and `select_entry/2`, whose `item` is already a presented row). `confirm_payload/1` still sends the host `photo_url` — that is the host contract (card-width URL), correctly left alone.
- **`card_media` overlay move.** `render_slot(@overlay)` moved out of the new private `card_media_visual/1` up into `card_media/1`, so overlay controls still render after the visual and keep their own clicks rather than being nested inside the new `<.link>`. Correct.
- **Columns modal event wiring.** `data-sortable-event={"reorder_columns_#{s.scope}"}` and `phx-value-scope` are matched by handlers guarded on `~w(detail_items detail_categories)` before `String.to_existing_atom/1` — no atom-exhaustion path from client input — and `detail_column_scopes/1` can only return those same two scopes, so no section can render an event with no handler.
- **Sort whitelists in sync.** `TableConfig.columns(:detail_items)` `sortable?` ids match `@items_sort_fields`; `columns(:detail_categories)` matches both `detail_categories_sort_field/1` and the `sort_categories` handler's clauses (`position name items updated`), and `sort_categories/4` has a branch for each. `ViewConfig.load_global_sort/1` validates stored ids against the same config, so a stale setting can't smuggle in an unhandled field.
- **Raw-binary UUIDs from `Tree.subtree_uuids_for/1`.** The schemaless CTE returns 16-byte binaries, which `counts_scope/2` feeds into `scope_categories/2`'s `i.category_uuid in ^uuids`. Established pattern (`Search.expand_category_scope/1` does the same), and `Ecto.UUID.cast/1` accepts the binary form.

## Gate

- `mix precommit` (compile `--warnings-as-errors`, `deps.unlock --check-unused`, `hex.audit`, format check, `credo --strict`, dialyzer) — **was exiting 2** on the merged tree (finding 2); clean after the fix, with dialyzer running for the first time since #87 merged.
- `mix test` against a live Postgres, so integration tests ran rather than being excluded: **2 doctests, 2110 tests, 0 failures** (2109 before the test added here).

## Related

- Previous: [#86](/dev_docs/pull_requests/2026/86-search-modes-and-category-browser) — this PR is its follow-up round.
- Previous: [#85](/dev_docs/pull_requests/2026/85-catalogue-quality-sweep)
