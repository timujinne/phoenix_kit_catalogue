# PR #132 — Real alt text on catalogue thumbnails and chip previews — follow-up

Triage of `CLAUDE_REVIEW.md` (no bugs; 1 nitpick) against `main` at `e8a969f` (0.46.1).

## Fixed (pre-existing)

None — the review found nothing to fix.

## Skipped (with rationale)

- NITPICK — redundant alt next to identical visible text, at three sites: the selector's tray row (`lib/phoenix_kit_catalogue/web/components/item_selector_modal.ex:3234`), the item form's archived attribute-value chip (`lib/phoenix_kit_catalogue/web/item_form_live.ex:3742`) and the attribute-set items modal row (`lib/phoenix_kit_catalogue/web/components/attribute_set_items_modal.ex:247`). All three still carry the name, as the PR shipped them. The review itself asked for no change: both readings are defensible (W3C's "redundant image" against users who navigate by graphic), the PR weighed it, it matches the `item_picker` precedent, and changing only these three would split the convention. Listed here on the review's say-so, not as a new decision; a screen reader does read the name twice at these sites, so it is Max's to reopen if he wants `alt=""` there.

## Files touched

None — triage only, no code changed.

## Verification

The three sites and the other `alt={…}` sites in `lib/` re-read against `main` at `e8a969f` on 2026-10-05. `mix precommit` and `mix test` were not run in this pass — nothing was changed.

## Open

None.
