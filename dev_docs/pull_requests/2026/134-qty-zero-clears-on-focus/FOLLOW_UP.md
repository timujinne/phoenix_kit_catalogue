# PR #134 — qty_stepper: a zero clears itself on focus — follow-up

Triage of `CLAUDE_REVIEW.md` (4 findings) against `main` at `e8a969f` (0.46.1).

## Fixed (pre-existing)

- ~~BUG MEDIUM — the remembered zero lived in `dataset`, which a LiveView patch of the focused input strips: it lives in element properties (`this.__pkZero`) — `lib/phoenix_kit_catalogue/web/components/browse.ex:1209-1224`. `test/web/browse_components_test.exs:459` asserts no handler touches `dataset` — commit `ffc2b2d`.~~
- ~~BUG MEDIUM — typed then erased, the restore went unannounced: the focus handler tracks `input` events (`__pkZeroEdited`, `browse.ex:1214`) and the blur handler dispatches a bubbling `input` after restoring an edited field (`:1220`) — commit `ffc2b2d`.~~
- ~~BUG MEDIUM — Enter in the emptied field submitted `""`: an `onkeydown` handler puts the zero back on Enter (`browse.ex:1224`, wired at `:1405`) — commit `ffc2b2d`.~~
- ~~NITPICK — readonly fields: the zero test starts with `!this.readOnly` (`browse.ex:1213`) — commit `ffc2b2d`.~~

## Skipped (with rationale)

None.

## Files touched

None — triage only, no code changed.

## Verification

Each finding re-read against `main` at `e8a969f` on 2026-10-05 (grep + reading the handler strings and their wiring at `browse.ex:1403-1405`; `git log -S` for the commit). The node-harness tests the review added were not run — `mix precommit` and `mix test` were not run in this pass, and nothing was changed.

## Open

None.
