# PR #86: Search modes and the category browser — Catalogues/Categories × Items, searching where the user stands

**Author**: @mdon
**Reviewer**: Claude (`elixir:phoenix-thinking` + `elixir:ecto-thinking` applied before reading source)
**Status**: Merged
**Commit**: `046147d` (merge of `a3d1294..30a3ce2`)
**Date**: 2026-08-29
**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/86
**Reviewed as part of**: the 0.22.0 release sweep, together with [#85](/dev_docs/pull_requests/2026/85-catalogue-quality-sweep) and [#87](/dev_docs/pull_requests/2026/87-drilled-mixed-view-and-images).

## What changed

The index and the detail page both gained a Catalogues/Categories × Items search axis. Search now happens **where the user stands** rather than through a folder select: the drilled folder (index) or the drilled category (detail) is the scope, and the folder `<select>` is gone. Categories mode became a category browser with the folder tree brought over. The index's items mode went async. Supporting context work: `list_catalogue_items_paged/2` + `count_items_for_catalogue/2` + `item_status_counts_for_catalogue/1` (catalogue-wide item listing in document order), and a `"description"` column on the catalogues table, hidden by default.

## Findings

No defects found that warranted a code change in this PR. Two things carried forward:

1. **Facet counts computed twice per filter/toggle patch** — introduced here (`272d59b`), documented in full and deliberately not fixed. See finding 2 of [#87's review](/dev_docs/pull_requests/2026/87-drilled-mixed-view-and-images/CLAUDE_REVIEW.md), where it surfaced.
2. **Removal of `Catalogue.catalogue_uuids_with_attribute_values/1`** — a public context function deleted here. Verified zero remaining references in `lib/`, `test/` and `dev_docs/`; the index's attribute filter now scopes through `attribute_value_match_counts/1` + `catalogue_uuids:` instead. It shipped in 0.21.0, so it is a public-surface removal — noted in the CHANGELOG under Removed rather than treated as a silent internal change.

## Not defects on verification

- **The async items mode is disciplined.** `load_item_results/1` cancels **both** `:item_results` and `:item_page` before kicking off, with a comment recording that `start_async/3` does *not* cancel a same-key predecessor on LV 1.2.11 — this is the exact gotcha `elixir:phoenix-thinking` flags, and the PR handles it rather than tripping over it. Every reply is guarded by an `item_stamp/2` covering query + offset + attribute slugs + scope uuids, so a superseded reply cannot land; `handle_async(:item_page, …)` additionally checks `length(loaded) == offset` so a double-scroll can't double-append. The `{:exit, reason}` clause distinguishes deliberate cancellation from a real crash and only flashes for the results task.
- **Empty scope short-circuits.** `item_scope_uuids/1` returning `[]` (a drilled folder holding no catalogues) is handled before the async kickoff, because `search_items/2` treats `catalogue_uuids: []` as *unscoped* — the opposite of what the list is showing. Correct, and commented.
- **List and count agree.** Both the drilled-category list (`search_items_in_category/3`) and its total (`count_search_items/2` with `category_uuids:`) resolve to the same `Search.search_items_base/2`, so the two cannot disagree about scope, text match, attribute slugs or `include_descendants`. Same for the root pair.
- **`apply_catalogue_item_order/2` binding positions.** `list_catalogue_items_paged/2` orders on `[i, c]` where `c` is the `left_join`ed `Category` at position 1; `filter_by_attribute_values/2` runs first but only appends `EXISTS` subqueries (no joins), so the positional binding stays correct. Non-position sorts fall through to the shared `apply_item_order/2` whitelist.
- **`TableQuery` folder handling after `filterable?` was dropped.** The `enum_options/3` clause for `"folder"` was removed along with the toolbar select, but the `filter_match?/4` clauses remain because the LiveView still sets `filters["folder"]` by navigation. The new `%MapSet{}` clause (subtree scope while searching) is fed by `folder_subtree_set/2`, which walks the already-loaded `folder_lookup` — string uuids on both sides, matching `to_string(row[:folder_uuid])`. `set_filter`/`clear_filter` are gated on `filterable_ids/1`, so the drilled folder can't be cleared from a toolbar that no longer offers it.
- **The new `"description"` column is fully wired** — `sort_key` reads `row[:description]` and `render_cell(:catalogues, "description", row)` exists, so the config list and the render clauses have not drifted.

## Gate

Covered by the sweep-wide run recorded in [#87's review](/dev_docs/pull_requests/2026/87-drilled-mixed-view-and-images/CLAUDE_REVIEW.md): `mix precommit` clean after the credo fix recorded there, `mix test` 2110 tests / 0 failures with a live Postgres.

## Related

- Follow-up: [#87](/dev_docs/pull_requests/2026/87-drilled-mixed-view-and-images) — the drilled page's mixed view and the subtree toggle.
- Previous: [#85](/dev_docs/pull_requests/2026/85-catalogue-quality-sweep)
