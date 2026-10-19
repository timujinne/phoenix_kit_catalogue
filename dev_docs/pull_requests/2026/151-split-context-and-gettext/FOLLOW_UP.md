# PR #151 — follow-up

Triage of `CLAUDE_REVIEW.md` (Claude). No bugs; one NITPICK about the docs,
still live in current code.

## Fixed (pre-existing)

None.

## Skipped (with rationale)

None.

## Files touched

None — triage only.

## Verification

Findings re-verified against current `main` at commit `899fa9c`.

## Open

Awaiting the maintainer's decision (fix, skip, or punt):

- NITPICK — AGENTS.md and the trash guide point trash/restore paths at
  `Catalogue.Trash`, but `keep_trash_status/3` and `stamp_created_deleted/1`,
  which enforce the same rule ("plain `update_*` never moves a row into or out
  of `deleted`"), live in `Catalogue.Shared`
  (`lib/phoenix_kit_catalogue/catalogue/shared.ex:488`, `:505`). Docs at
  `AGENTS.md:187-193` and `dev_docs/guides/trash-and-restore.md:5-8`.
  Suggested fix: add one clause to each naming the two `Shared` helpers.
