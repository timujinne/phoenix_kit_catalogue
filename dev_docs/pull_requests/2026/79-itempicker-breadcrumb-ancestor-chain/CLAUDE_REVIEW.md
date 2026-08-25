# PR #79: ItemPicker — show full ancestor chain in breadcrumb, keep it only in the open suggestion list

**Author**: @timujinne
**Reviewer**: Claude (read-only diff review, `elixir:phoenix-thinking` applied), every claim re-read against current `main`
**Date**: 2026-08-24
**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/79

## What changed

`item_picker.ex` breadcrumbs (the muted line under each dropdown row) used to show only `catalogue / direct category`. The PR walks the full ancestor chain (root → direct parent) via the pre-existing `Catalogue.list_category_ancestors/1` and renders `catalogue / ancestor… / direct category`. Ancestor names are memoized per unique category uuid in a new `:category_paths` socket assign (`ensure_category_paths/2`, called from `run_search/2`) so a page of up to `page_size` items only issues one ancestor lookup per *distinct* category, not one per item, and a category looked up on one search page stays cached for the next.

## Findings

1. **TEST — the feature shipped with zero coverage.** The existing `describe "breadcrumb"` block had a single pre-existing case (uncategorized item, no ancestors). Nothing exercised `ensure_category_paths/2`, `category_uuid_of/1`, or the ancestor-names branch of `item_breadcrumb/3` — the actual point of the PR. `test/web/item_picker_test.exs` renders the component directly (`render_component/2`, no DB), so `:category_paths` can be injected as a plain assign without touching `Catalogue.list_category_ancestors/1`. **Fixed**: added two tests — ancestor names spliced in when `category_paths` has an entry for the category (`"Kitchen / Home / Living Room / Furniture"`), and the direct-category-only fallback when it doesn't.

## Not defects on verification

- **Locale staleness in the `:category_paths` cache.** The cache is keyed by category uuid only and never invalidated, so if the same mounted component instance later saw a different `:locale` assign, previously-cached ancestor names would stay in the old locale while the catalogue/direct-category names (computed live, not cached) would flip immediately — a mixed-locale breadcrumb. Not reachable here: this repo's admin routes carry locale as a URL segment (`/en/admin/catalogue`, see `AGENTS.md`), and there is no in-app locale switcher that changes `@locale` without a full navigation — which remounts the LiveComponent and resets `:category_paths` to `%{}`. Worth a `@moduledoc` note if `:locale` is ever made live-switchable by a host.
- **N ancestor queries instead of 1 batched query.** `ensure_category_paths/2` still issues one `list_category_ancestors/1` (one recursive CTE) per *distinct* uncached category rather than a single batched query seeded by all new uuids. The PR's own comment frames the win correctly (per-unique-category vs. per-item, not "one query total"), and distinct categories per page is small in practice — not worth the added complexity of a batched ancestors-for-many API on `Catalogue.Tree` for this call site.

## Fix applied

- `test/web/item_picker_test.exs`: added `Category` alias and two breadcrumb tests covering the ancestor-chain splice and its no-entry fallback (finding 1).

## Gate

`mix precommit` (format + `compile --warnings-as-errors` + `credo --strict` + dialyzer) clean. `mix test`: 2 doctests, 1946 tests, 0 failures.
