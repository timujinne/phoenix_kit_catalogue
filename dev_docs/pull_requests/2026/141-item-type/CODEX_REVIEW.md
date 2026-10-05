# PR #141 — Item type: release recheck

- **Reviewer:** Codex
- **Date:** 2026-10-05
- **Release reviewed:** 0.46.0, as carried forward through 0.47.0 (`7e5999e`)

## BUG - MEDIUM — import duplicate detection uses a stale catalogue type

The wizard retains `selected_catalogue` from the upload step. Both the
confirmation counter and execution's Skip duplicates pass that row's
`item_type` to the mapper. Changing the catalogue default in another admin
session therefore changes what existing inheriting items mean, while the
wizard continues comparing against their former type.

For an existing Transport item with no override and an incoming row naming
`service`, changing Goods to Service after confirmation creates an unnecessary
duplicate. Changing Service to Goods skips the incoming service even though
the existing item is now goods. A change before confirmation also leaves the
counter wrong.

**Fixed:** confirmation lets `Mapper.detect_existing_duplicates/3` read the
current default. Execution retains the catalogue already fetched by its
not-trashed guard, so `start_import/6` receives the current default too.
No extra execution query or change to the mapper's public contract is needed.

Three LiveView regressions in `test/web/import_live_execute_test.exs` cover
the confirmation counter and both execution directions, waiting for completion
and checking the created rows. All three failed before the fix.

## Other checks

Reviewed effective-type resolution, SQL filtering in listings/search/counts,
selector scope propagation, item and catalogue copies, and JSON import/export
of explicit versus inherited item types. The earlier unpaged-list and
stay-save-hint fixes remain in place. No further finding in these paths.

## Validation

See the accompanying PR #144 `CODEX_REVIEW.md` for the combined release-sweep
validation. This review changes no version or dependency requirement.
