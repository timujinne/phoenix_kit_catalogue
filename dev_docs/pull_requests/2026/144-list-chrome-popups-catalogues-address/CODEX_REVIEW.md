# PR #144 — List chrome and addresses: release recheck

- **Reviewer:** Codex
- **Date:** 2026-10-05
- **Checkout:** 0.47.0 (`7e5999e`)
- **Wider scope:** release changes from 0.45.1 through 0.47.0, including header
  trails, units, item types, source labels, list controls and old addresses.

## IMPROVEMENT - MEDIUM — compatibility skips remove unrelated layout coverage

Claude correctly made tests stop requiring core 2.54.0's TableFit hook on
older cores. However, skipping the whole four tests also skips checks of
header/body cell alignment and the Image-column category-tree layout. Those
contracts apply to supported older cores too, including the locked 2.53.0.

**Fixed:** check rendered table rows on every core. When the core declares
`fit`, additionally require the fitting hook and the expected fitted-table
ids. Remove all four skips. The Image-column indentation assertions now run
on the locked core, and no dependency floor needs to change.

## NITPICK — the redirect changes a second address inside the suffix

`target/2` applied one replacement for each of two old-address patterns.
Although each replacement used `global: false`, a path containing both
patterns could be rewritten twice. For example,
`/admin/catalogue/x/admin/settings/catalogue` became
`/admin/catalogues/x/admin/settings/catalogues`; the documented unchanged
suffix should remain `/x/admin/settings/catalogue`.

This is an edge-case path-fidelity issue, not an authorization or open-redirect
finding. Ordinary catalogue paths are unaffected.

**Fixed:** match either configured old address in one regex and replace only
the first match. Add regressions for both orders, including query preservation.
The added assertion failed before the fix. Existing renamed-admin,
whole-segment, leading-slash and controller response tests still pass.

## Other checks

- The shared level sort persists both scopes; direction-only changes preserve
  each table's field, and a new page reads the persisted sorts.
- Dialog actions close their containing pop-up; the Filters controls retain
  their forms, and the bulk docks remain under their respective lists.
- The core helpers imported by these changes exist at the declared 2.38.0
  floor. Column fitting remains optional and is not a reason to raise it.
- Reviewed the header-trail helper, unit vocabulary and import aliases, and
  translated import/export labels. No additional finding in those changes.
- The 0.46.0 import duplicate bug is recorded and fixed in PR #141's
  `CODEX_REVIEW.md`.

## Validation

- Baseline, locked Hex core 2.53.0: 2 doctests, 3,562 tests, zero failures,
  four skipped.
- Before fixes: 21 focused tests, four failures reproducing the import bug's
  three cases and the redirect suffix issue.
- After fixes: 36 focused tests, zero failures, no skips.
- Full suite, locked Hex core 2.53.0: 2 doctests, 3,565 tests, zero failures,
  no skips; database-backed integration tests ran.
- `mix precommit`: passes (compile with warnings as errors, unused-lock check,
  Hex audit, formatting check, strict Credo and Dialyzer).
- Isolated copy against committed local core 2.54.0 (`d8de0cdd6`): the same
  36 focused tests pass, including fitting-hook assertions. The main
  checkout's lockfile and the active core workspace were not changed.

No release or version bump is part of this review.
