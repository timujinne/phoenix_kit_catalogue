# Follow-up — PR #86 (search modes and the category browser)

Triage of `CLAUDE_REVIEW.md` (2026-08-29) against current `main`,
2026-08-31.

## Fixed (pre-existing)

- ~~Public-surface removal of
  `Catalogue.catalogue_uuids_with_attribute_values/1`~~ — handled at
  release time: zero remaining references verified and the removal
  recorded in the 0.22.0 CHANGELOG under Removed.

## Skipped (with rationale)

- **Facet counts computed twice per filter/toggle patch** (introduced
  by `272d59b`, surfaced in #87's review as finding 3 and deliberately
  not fixed there). Output is correct — the second call recomputes the
  same map — so this is cost, not a defect; every candidate fix couples
  `load_level/2` to search ordering the panel already had to untangle
  once. Deferred by the reviewer; on the books in #87's review. Trigger
  condition: any future change to `handle_url_state/2` or
  `assign_attribute_counts/2` should retire the double call as part of
  the work.

## Files touched

| File | Change |
|------|--------|
| — | none in this follow-up |

## Verification

Covered by the sweep-wide gate recorded in #87's review (`mix precommit`
clean, 2110 tests green then); re-run 2026-08-31 at 2133 tests, 0
failures.

## Open

None.
