# PR #142 — Fix the admin header trail — follow-up

Triage of `CLAUDE_REVIEW.md` (Claude, 2026-09-25: one BUG, one NITPICK) and `GROK_REVIEW.md` (Grok, 2026-09-26: no findings, re-review of the follow-up).

## Fixed (pre-existing)

- ~~BUG - MEDIUM — the new-category trail drew a parent the form had rejected.~~ The `:new` trail is built from `PlaceTree.uuid(parent_pick)`, the parent `offered_parent/3` accepted (`lib/phoenix_kit_catalogue/web/category_form_live.ex:132`, `:142`, `:252-253`). `HeaderTrail.place_crumbs/3` draws a category chain only for a category whose `catalogue_uuid` is the catalogue's (`lib/phoenix_kit_catalogue/web/header_trail.ex:46-57`). Tests: `test/web/header_trail_test.exs:72` and `:174-188`. Commit `afc71a7` (0.45.1).
- ~~NITPICK — Events and PDFs still prefixed their subtitle with `Catalogues · `.~~ No such prefix is left in `lib/`: the subtitles are `"Events: %{count}"` (`web/events_live.ex:314`) and `"%{count} PDFs"` (`web/pdf_library_live.ex:425`). Commit `afc71a7`.

## Skipped (with rationale)

- **The browser tab reads just `Edit` on every edit page.** The Claude review marked it "Not a finding": core's header-trail guide says `page_title` feeds the tab and carries no trail.

## Files touched

None.

## Verification

Re-verified by reading `main` at `e8a969f` (0.46.1) on 2026-10-05 (quality sweep, Phase 1): each reference below was grepped and the lines read. No code changed, so no gate was run for this triage; `mix precommit` and `mix test` were not re-run.

The admin address moved from `/admin/catalogue` to `/admin/catalogues` after these reviews; the trail code goes through `Paths`, so neither finding is affected.

## Open

None.
