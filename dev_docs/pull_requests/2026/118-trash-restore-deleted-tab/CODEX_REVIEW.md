# PR #118 — Codex review — trash / restore / Deleted tab

**Reviewer**: Codex (gpt-5.6), read-only repo access (`--cd`, `-s read-only`), no test runs
**Date**: 2026-09-15
**Scope**: commits `94b8cb6..210e0a2`, focused on whether the Deleted tabs' counts and listings agree with what Restore and Delete Forever actually do

Brief: `item_counts_by_catalogue(mode: :restorable)` vs `restore_catalogue/2`; `trash_unit_counts` vs `restore_category/2`; reachability of trashed rows; tab selection. Findings below are the reviewer's answer as given (file links shortened).

## Findings

- **BUG — HIGH:** card counts describe Restore, but Delete Forever has a broader destructive scope. `lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex:2673`, `lib/phoenix_kit_catalogue/catalogue.ex:2143`, `lib/phoenix_kit_catalogue/catalogue/counts.ex:82`, `lib/phoenix_kit_catalogue/catalogue.ex:987`.
  Sequence 1: create `A > D > item`; trash `D`, then trash `A`. `D` and the item retain root `D`; the sole visible `A` card says Items 0 / Subcategories 0. Delete Forever on `A` nevertheless deletes `D` and the item.
  Sequence 2: trash an item on its own, then trash its catalogue. The catalogue row says Items 0, while Delete Forever deletes that item.
  Expected: destructive totals, or a separate warning/count, must include every row the hard delete removes. Actual: the UI can display zero immediately before destroying hidden rows.

- **BUG — MEDIUM:** `trash_unit_counts` does not always mirror `restore_category/2`. `lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex:2676`, `lib/phoenix_kit_catalogue/catalogue.ex:2094`.
  Sequence: create `A > B > D > item`; trash `A` with cascade; restore `B` alone. `B` becomes live, while `D` and the item retain root `A`. The card traversal follows deleted children only, so `B` breaks the path and `A` reports Items 0 / Subcategories 0. Restoring `A` uses the full physical subtree, crosses live `B`, and reports `items_restored: 1`, `descendants_restored: 1`.
  Expected: 1/1 if the card promises to count what Restore brings back. Actual: 0/0.

- **BUG — MEDIUM:** initial tab selection ignores content consisting solely of deleted categories. `lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex:2719`, `lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex:2744`, `lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex:3588`.
  Sequence: in an otherwise empty live catalogue, create and trash an empty category, then open the catalogue.
  `level_tab_counts` has Deleted 1, but `pick_counts` copies only Active from those counts and passes no Deleted count to `effective_view_mode`. The page opens on empty Active while Deleted contains the category. Expected: open Deleted. The populated tab remains visible; it is not hidden.

## Checks that held

- `item_counts_by_catalogue(mode: :restorable)` matches the number of non-deleted items after `restore_catalogue/2`: both use item root/unstamped eligibility plus the direct category’s post-restore status. No counterexample found, including moves.
- No valid soft-deleted row is completely outside every enclosing unit: deleted-category chains have a top-level deleted card; items in live catalogues are either loose or under such a card; deleted catalogues have their catalogue card.
- Deleted-tab search finds every deleted item in a live catalogue regardless of category status. Items in deleted catalogues are intentionally excluded by `lib/phoenix_kit_catalogue/catalogue/search.ex:317` and are reachable only through the enclosing catalogue unit.
- `outside_trashed_categories` is applied consistently to the root Deleted listing and count.
- Restoring an individual item beneath a still-deleted category correctly uncategorizes it.
- Apart from the wrong initial selection above, populated tabs are not dropped by `visible_status_tabs/2`.

Read-only review; no tests run as requested.
