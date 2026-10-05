# PR #141 — Item type goods / service — follow-up

Triage of `GROK_REVIEW.md` (Grok, 2026-09-26). Two BUGs, one NITPICK.

## Fixed (pre-existing)

- ~~BUG - MEDIUM — the unpaged item lists ignored `item_types`.~~ `list_items_for_category/2` (`lib/phoenix_kit_catalogue/catalogue.ex:5392`, filter at `:5399`) and `list_items_for_catalogue/2` (`:5424`, filter at `:5433`) name the `:item` binding and call `filter_by_item_types/2`. Test: `test/catalogue/item_type_test.exs:163` ("the unpaged listings take the same item_types filter"). Commit `a2e92ea` (0.46.0).
- ~~BUG - MEDIUM — a stay-save left "As in catalogue (…)" stale.~~ `refresh_after_edit/2` calls `assign_catalogue_item_type/1` after the saved place is assigned (`lib/phoenix_kit_catalogue/web/item_form_live.ex:2877-2880`). Test: `test/web/item_type_ui_test.exs:139` ("a stay-save re-reads the catalogue type the hint names"). Commit `a2e92ea`.
- ~~NITPICK — `create_item/2` did not document `:item_type`.~~ Documented at `lib/phoenix_kit_catalogue/catalogue.ex:5708`.

## Skipped (with rationale)

None.

## Files touched

None.

## Verification

Re-verified by reading `main` at `e8a969f` (0.46.1) on 2026-10-05 (quality sweep, Phase 1): each reference below was grepped and the lines read. No code changed, so no gate was run for this triage; `mix precommit` and `mix test` were not re-run.

## Open

None.

## Codex release recheck — 2026-10-05

- Fixed `CODEX_REVIEW.md`'s BUG - MEDIUM: import confirmation reads the current
  catalogue default, and execution retains its already re-fetched catalogue
  before Skip duplicates. The three regressions in
  `test/web/import_live_execute_test.exs` reproduce the stale counter,
  unnecessary duplicate, and incorrectly skipped row.
- Combined validation is recorded in PR #144's `CODEX_REVIEW.md`.
