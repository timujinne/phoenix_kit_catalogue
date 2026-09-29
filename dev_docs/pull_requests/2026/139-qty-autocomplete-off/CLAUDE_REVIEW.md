# PR #139 — Quantity stepper: turn off the browser's saved-input suggestions

- **Author:** Timujeen (`timujinne/fix/qty-autocomplete-off`)
- **Merged:** 2026-09-24 (`4cef8da`; commit `4cbce18`)
- **Reviewer:** Claude (post-merge)
- **Scope:** 2 files, +18. Adds `autocomplete="off"` to
  `Browse.qty_stepper/1`'s input, plus a test covering all three
  precision modes (`0`, `2`, `:any`).

## Verified

- **The cause is real.** The input is `name="value"`, a generic name, so
  browsers offered values saved from any other field with that name. This
  input has no form-level autocomplete, so the attribute on the input is
  what turns suggestions off.
- **Every mode gets it.** Both the `type="number"` (integer/decimal) and
  `type="text"` (`:any`) variants render the same `<input>`, and the test
  asserts the attribute in all three modes.
- **No other quantity input needs it.** The item-selector modal renders
  its quantities through `qty_stepper/1`. The other `type="number"` inputs
  in `lib/` (settings, item form, import) are form fields with specific
  `name`s, which doesn't cause this problem.

## Findings

None.
