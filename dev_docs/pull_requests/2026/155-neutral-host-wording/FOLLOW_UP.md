# PR #155 — follow-up

Triage of `CLAUDE_REVIEW.md` (Claude).

## Fixed

- IMPROVEMENT - MEDIUM — leftover `tim-dev` / `Nordic Line` in `lib/`, `test/`
  and `dev_docs`, replaced with neutral wording (comments, `describe` titles
  and docs only; no assertion or code changed).

## Skipped (with rationale)

- NITPICK — `max-dev` and the "Max" attributions: the maintainers' own
  environment and team, not the private host.

## Files touched

`lib/phoenix_kit_catalogue/catalogue/pdf_engines.ex`,
`lib/phoenix_kit_catalogue/web/components/{browse,item_picker,item_selector_modal}.ex`,
`test/catalogue/{browse_state,delete_guards}_test.exs`,
`test/web/{browse_components,catalogues_live,item_picker,item_selector_modal}_test.exs`,
`dev_docs/2026-08-16-pdf-extraction-engines.md`, and the PR 90 / 120 notes.
