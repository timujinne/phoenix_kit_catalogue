# PR #84: Attributes viewer, honest search, and an attribute-value filter that only offers what it can deliver

**Author**: @mdon
**Reviewer**: Claude (diff review via forked subagent, `elixir:ecto-thinking` + `elixir:phoenix-thinking` applied), claims re-read against current `main`
**Date**: 2026-08-28
**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/84
**Reviewed together with**: #82 and #83 (both merged directly beforehand; no separate docs — trivial, clean on review; #83 left one compile warning fixed in this doc, see below)

## What changed

Three things bundled together:

1. **Attributes viewer** replaces the old attribute-set editor UI. `attribute_set_form_live.ex` (1273 lines) is deleted outright, along with its two routes in `phoenix_kit_catalogue.ex`; a new `Web.Components.AttributeSetItemsModal` LiveComponent (loaded in `update/2`, not `mount/1` — no query-on-mount) replaces it as a read-focused viewer.
2. **Honest search**: listing search and facet-count search now share one `Search.match_item_text/2` fragment, so the two can no longer disagree about what a query matches (the bug this closes: "search finds it, but the count above the results says zero").
3. **Attribute-value filter that only offers what it can deliver**: `Catalogue.filter_by_attribute_values/2` (via `parent_as(:item)` + one `EXISTS` per selected slug, AND semantics) backs a facet UI that greys out/hides values that would return zero results given the current filter state, instead of offering dead-end options.

## Findings

1. **BUG — `<.icon class={[...]}>` list value fails `mix compile --warnings-as-errors`.** Introduced by PR #83 (`item_picker.ex:712`, commit `ff3214e`), not by this PR — but it blocked the shared `mix precommit` gate for the whole tree at release time, so it's fixed here. `PhoenixKitWeb.Components.Core.Icon.icon/1` declares `attr :class, :string`; passing a list (which works for plain HTML tags via HEEx's class-list merging) produces a compile warning for a function component that just embeds the value as-is. **Fixed**: interpolated to a single string (`"#{@photo_size} shrink-0 rounded bg-base-200 border border-base-300 p-1.5 opacity-40"`), matching the plain-string convention already used at the other `<.icon class="...">` call site in the same file.

2. **NITPICK — doc/markup mismatch for PR #82's `:show_sku`.** The moduledoc said SKU renders "between the category breadcrumb and the unit label ... on each dropdown row's second line"; the actual markup (`item_picker.ex:796-802`) renders it as its own flex column between the name/breadcrumb block and the price/unit block — a sibling `<div>`, not inline text on the breadcrumb line. Cosmetic only, no functional impact. **Fixed**: reworded the doc to match the real layout.

## Not defects on verification

- **Duplicated JSONB string-search SQL fragment** (`Search.search_categories/3`, `Search.match_item_text/2`, and a `Helpers.json_string_values_doc/0` stub whose body is `:see_moduledoc` and is called nowhere). This is exactly the "two lists that must stay in sync" shape the review skill flags — a future edit to one copy without the others could silently reintroduce the pre-#84 search-dishonesty bug. Not fixed here: turning the doc stub into an actual shared fragment-builder is a real refactor, not a bug fix, and risks moving code paths that just got a dedicated fix (finding #2 in this PR's own stated goal). Worth doing as deliberate follow-up work, not folded into a release-gate pass.
- **Mild N+1 in `AttributeSets.filter_options/2`** — one `get_set/2` query per distinct attribute set uuid rather than a batched `get_sets/2`. Bounded by admin-curated set counts (small), and no batch API exists yet to swap in without adding one. Pre-existing shape, not a regression from this PR.
- **Deleted `attribute_set_form_live.ex` (1273 lines) leaves no dangling references** — verified zero remaining references anywhere in `lib/`, and both its routes were cleanly removed from `phoenix_kit_catalogue.ex`'s `admin_tabs/0`.
- **PubSub staleness** — `load_data/2` (triggered by `{:catalogue_data_changed, ...}`) now also calls `refresh_attribute_scope/1`, so filter eligibility and facet counts don't go stale after a PubSub-driven reload. The PR's own comments note this was a bug specifically closed here.

## Fix applied

- `lib/phoenix_kit_catalogue/web/components/item_picker.ex`: `<.icon>` class list → interpolated string (finding 1, blocks the release gate).
- `lib/phoenix_kit_catalogue/web/components/item_picker.ex`: `:show_sku` moduledoc reworded to match actual markup (finding 2).

## Gate

`mix precommit` clean after the fix above (was failing on the PR #83 `<.icon>` warning before it). `mix test`: new coverage for this PR's surfaces (`attribute_filter_test.exs`, `search_coverage_test.exs`, `attribute_sets_surfaces_test.exs`, `attribute_set_items_modal_test.exs`) passes, 48/48.
