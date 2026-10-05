# PR #129 — Supplier comments before Save, wording, UI conventions sweep, View popup — follow-up

Triage of `GROK_REVIEW.md` (4 findings) against `main` at `e8a969f` (0.46.1).

## Fixed (pre-existing)

- ~~BUG MEDIUM — the Deleted tab's item menus dropped View: `trash_row_menu/1` takes an optional `preview_event` and renders View above Restore (`lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex:6800-6818`); the item call sites pass `"show_product_card"` (`:6343`, `:6470`) and the category one now passes `"show_category_card"` (`:6066`). Pinned by `test/web/catalogue_detail_live_test.exs:154-156` — commit `80944aa`.~~
- ~~IMPROVEMENT MEDIUM — the View tests did not uniquely pin the card's own Edit: the card Edit carries `id="catalogue-detail-product-edit"` (`catalogue_detail_live.ex:4900`) and the tests assert on that id (`test/web/catalogue_detail_live_test.exs:106`, `:116-117`, `:134`, `:161`) and on View being on the listing menus (`:75`, `:82`) — commit `80944aa`.~~

## Skipped (with rationale)

- NITPICK — `|| UUIDv7.generate()` after `thread_for_pair/2` is dead for valid pairs. Still written at `lib/phoenix_kit_catalogue/catalogue/duplication.ex:804` and `lib/phoenix_kit_catalogue/catalogue/item_supplier_infos.ex:189`. The review itself called it a harmless safety net and asked for no change: it only fires on a missing or malformed uuid, where a fresh thread is a better answer than `nil`. Listed here on the review's say-so, not as a new decision.

## Files touched

None — triage only, no code changed.

## Verification

Each finding re-read against `main` at `e8a969f` on 2026-10-05 (grep + reading the cited lines; `git log -S` for the commits). `mix precommit` and `mix test` were not run in this pass — nothing was changed.

## Open

Awaiting Max's decision:

- **NITPICK — `de`/`fr` have no translation for "View" and "Primary supplier".** `priv/gettext/de/LC_MESSAGES/default.po:471-472` and `:1069-1070`, and the same lines in `priv/gettext/fr/LC_MESSAGES/default.po`, are still `msgstr ""` (they render in English). Part of the wider `de`/`fr` gap already on record as Max's call in the #97 follow-up. Fixing these two means hand-writing four msgstrs; a real fix is the `de`/`fr` translation pass.
