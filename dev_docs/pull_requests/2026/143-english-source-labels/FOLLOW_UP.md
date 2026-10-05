# PR #143 — Import/export source names in English — follow-up

Triage of `CLAUDE_REVIEW.md` (Claude, 2026-09-28). One IMPROVEMENT, one NITPICK.

## Fixed (pre-existing)

- ~~IMPROVEMENT - MEDIUM — Russian admins lost the Russian labels.~~ The callbacks translate at call time: `lib/phoenix_kit_catalogue/import/source/universal.ex:9`, `:14`; `lib/phoenix_kit_catalogue/export/universal.ex:18`; `lib/phoenix_kit_catalogue/export/pro100.ex:49-50`. `"Universal"`, `"Furniture"`, `"Materials"` and `"JSON (export)"` are each in `priv/gettext/default.pot` and all five locales. The behaviour docs say so (`import/source.ex:4`, `export/destination.ex:19`, `:24`). Pinned by `test/gettext_test.exs:1254`. Commit `339fa33` (0.46.1).

## Skipped (with rationale)

- **NITPICK — comment wording.** `lib/phoenix_kit_catalogue/web/components/browse.ex:138` still reads `the Russian "pcs"`. The review judged it clear enough in context and left it; it is a comment only.

## Files touched

None.

## Verification

Re-verified by reading `main` at `e8a969f` (0.46.1) on 2026-10-05 (quality sweep, Phase 1): each reference below was grepped and the lines read. No code changed, so no gate was run for this triage; `mix precommit` and `mix test` were not re-run.

## Open

None.
