# Follow-up — PR #87 (drilled mixed view, card-grade images, one Columns popup)

Triage of `CLAUDE_REVIEW.md` (2026-08-30) against current `main`,
2026-08-31.

## Fixed (pre-existing)

Both fixes landed in the release commit (`53155f2`, "Fix the release
gate and the dead subtree path, review #85-#87, bump to 0.22.0"):

- ~~Finding 1 (IMPROVEMENT — HIGH): dead subtree machinery shipping as
  public API~~ — verified `item_status_counts_for_categories/1`,
  `level_category_uuids/2` and `apply_level_item_order/2` are gone from
  `catalogue.ex`; `list_items_for_category_paged/2` /
  `item_count_for_category/2` are level-only, with the pinning test in
  `test/catalogue_test.exs`.
- ~~Finding 2 (BUG — HIGH): red release gate — the credo AliasUsage
  violation in `catalogue_detail_live_test.exs` that had silently
  stopped dialyzer running~~ — verified the `TableConfig` alias is in
  place; `mix precommit` (dialyzer included) has run clean repeatedly
  since.

## Skipped (with rationale)

- **Finding 3 (IMPROVEMENT — MEDIUM): facet counts computed twice on a
  filter/toggle patch.** Deferred by the reviewer in the review itself
  ("cost, not a defect … a deliberate refactor for a quiet moment").
  Cross-referenced in #86's FOLLOW_UP.md with the trigger condition.

## Files touched

| File | Change |
|------|--------|
| — | none in this follow-up; both fixes landed with `53155f2` |

## Verification

`mix precommit` clean (dialyzer running) and `mix test` 2 doctests,
2133 tests, 0 failures — re-run 2026-08-31.

## Open

None.
