# PR #118 follow-up

How each finding in `CLAUDE_REVIEW.md`, `CODEX_REVIEW.md`, `GROK_REVIEW.md` and
`ZAI_REVIEW.md` was resolved. Every finding was verified against the code before
it was acted on. A fifth seat (Mistral's vibe) was asked and gave no answer in
40 minutes.

## Fixed (Batch 1 — 2026-09-15, commit bbd0aed)

- ~~BUG - MEDIUM (Claude #1) — single-row Restore / Delete Forever looked rows up by
  the client's uuid alone.~~ `restore_item`, `permanently_delete_item` and
  `permanently_delete_category` act only on this catalogue's rows
  (`item_in_catalogue/2`, `category_in_catalogue/2` in `catalogue_detail_live.ex`).
  Pinned: "single-row actions ignore a uuid from another catalogue"
  (`test/web/catalogue_deleted_tab_test.exs`).
- ~~BUG - MEDIUM (Claude #1) — Delete Forever on a trashed category destroyed a
  subcategory restored on its own.~~ `permanently_delete_category/2` removes only the
  trashed part of a trashed category's subtree and moves a live subcategory it stops at
  to the top level; a live category still takes everything. Activity metadata gains
  `kept_live_subcategories`. Pinned: `test/catalogue/trash_edges_test.exs`.
- ~~BUG - MEDIUM (Claude #3) — bulk Delete Forever checked the status on a plain read.~~
  Delete Forever (single and bulk, categories and items) passes `only_trashed: true`,
  re-checked under the lock; a row restored meanwhile is refused with `:not_in_trash`
  and a message. Pinned: "only_trashed refuses …" (two tests in `trash_edges_test.exs`).
- ~~BUG - HIGH (Codex) — a trashed card's counts describe Restore while Delete Forever
  removes more.~~ The category confirmation names what is really removed
  (`permanent_delete_scope/1`): "This category, N subcategories and M items inside it
  will be permanently deleted." The catalogue confirmation already says "all its
  categories, and all items". Pinned: "the Delete Forever confirm names what is really
  removed".
- ~~BUG - MEDIUM (Codex, Grok Q2) — a category card undercounted when a subcategory in
  between was restored on its own.~~ Card counts mirror `restore_category/2` over the
  whole subtree. Pinned: "a card counts what its Restore brings back past a subcategory
  restored on its own".
- ~~BUG - MEDIUM (Codex) — a level with only trashed categories opened on an empty
  Active.~~ Together with a dead end found while verifying it (a catalogue holding only
  trashed items opened on Deleted with no Active tab and no Add buttons): Active is
  always offered as a tab, and a level with nothing live opens on Deleted. Pinned: "a
  catalogue holding nothing live opens on Deleted and still offers Active" and the
  updated test in `catalogue_detail_empty_category_test.exs`.
- ~~IMPROVEMENT - MEDIUM (Claude #2) — trash/restore/permanent-delete activity rows
  unpinned.~~ One test per action with its metadata in `test/activity_logging_test.exs`.
- ~~IMPROVEMENT - MEDIUM (Claude #2) — bulk Delete Forever's live-category guard
  untested.~~ Pinned: "bulk Delete forever leaves a live category of this catalogue
  alone".
- ~~IMPROVEMENT (Claude #2) — `:catalogue_moved` had no message.~~ It and the new
  `:not_in_trash` have `Errors.message/1` clauses, pins in `test/errors_test.exs`, and
  et/ru translations pinned in `test/gettext_test.exs`.
- ~~IMPROVEMENT - MEDIUM (Claude #1) — a rolled-back bulk item operation dropped its
  reason.~~ Logged as a warning.
- ~~NITPICK (Claude #3, #1) — dead server-side item selection, misplaced comments, a
  stale `resolve_node/2` comment.~~ Removed and moved.
- ~~C11 gaps (Claude #2, #4)~~ — pinned: `_trash` not copied on duplicate, trash search
  ignoring `:statuses`, `outside_trashed_categories` at the context level
  (`trash_edges_test.exs`), the JS clear listener (`js_sources_test.exs`).

## Fixed (Batch 2 — 2026-09-15, commit 12cdb8c)

- ~~Zai 1 — a trashed subcategory's card inside a live category showed raw counts.~~
  Cards count the same way at every level. Pinned: "a trashed subcategory's card inside
  a live category counts what its Restore brings back".
- ~~Zai 2 — a trashed item's name linked to its edit form.~~ Plain text in the Deleted
  tab. Pinned: "a trashed item's name does not link to its edit form".
- ~~Zai 4 — a row restored from the Deleted tab's search stayed in the results.~~
  Restoring or deleting a search result drops it; the total and the next page's offset
  follow. Pinned: "restoring a row from the Deleted tab's search takes it out of the
  results".
- ~~Zai 5 — the Deleted tab's sort headers did nothing.~~ The Deleted tab sorts like the
  others. Pinned: "the Deleted tab's sort headers sort the trashed items".
- ~~Zai 6 — the result-type chips stayed in the trash, where "Categories" found
  nothing.~~ No chips in the trash, which always searches everything. Pinned: "the trash
  searches everything, whatever result type was chosen before".

## Skipped (with rationale)

- **Zai 3** — refuted: bulk item restore and permanent delete already scope uuids to the
  catalogue (`scope_item_uuids/2`), and the single category delete was fixed in Batch 1.
- **Claude #1, double-clicked bulk Restore shows a misleading error** — refuted: an
  already-restored category falls through silently; the second click flashes "Restored 0
  categories."
- **Claude #1, the clear listener is document-wide** — only this page pushes
  `bulk_select:clear`, and core's clear is client-only (confirmed by Claude #4).
- **Claude #2, singular-only count wording** ("Permanently deleted 1 categories.") —
  the same shape as the module's existing bulk flashes; plural forms would change
  existing msgids in five locales.
- **Claude #2, runtime gettext inside HEEx attributes** — the strings are in the
  hand-maintained catalogue (a code-vs-catalogue diff found all of them); converting to
  the macro form is the module's standing AGENTS.md TODO.
- **Claude #3, `restore_item` locks the item before the category** — cannot deadlock:
  every trash/restore path holds the same per-catalogue advisory lock.
- **Claude #2, lock changes have no pinning test** — the SQL sandbox serializes every
  process onto one connection; the races were reproduced and re-checked in max-dev's
  live node before and after the fixes.

## Files touched

| File | Batch | Change |
|------|-------|--------|
| `lib/phoenix_kit_catalogue/catalogue.ex` | 1 | trashed-part permanent delete, `permanent_delete_scope/1`, `only_trashed`, bulk rollback log, moved comment |
| `lib/phoenix_kit_catalogue/errors.ex` | 1 | `:catalogue_moved`, `:not_in_trash` |
| `lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex` | 1, 2 | scoped row actions, confirmation text, exact card counts at every level, tab rules, trash-only view fixes, dead code |
| `priv/gettext/*` | 1 | three new strings, et/ru translated |
| `test/catalogue/trash_edges_test.exs` | 1 | new |
| `test/activity_logging_test.exs`, `test/errors_test.exs`, `test/gettext_test.exs`, `test/phoenix_kit_catalogue/js_sources_test.exs` | 1 | pins |
| `test/web/catalogue_deleted_tab_test.exs` | 1, 2 | new LiveView tests |
| `test/web/catalogue_detail_branches_test.exs`, `test/web/catalogue_detail_empty_category_test.exs` | 1 | follow the removed selection and the new tab rule |

## Verification

- Before the fixes: the full suite ten times back to back, 10 × 2800 tests + 2 doctests, 0 failures.
- After Batch 1: three more runs, 3 × 2822, 0 failures.
- After Batch 2: full suite 2827 tests + 2 doctests, 0 failures; `mix precommit` clean (compile, format, credo --strict, dialyzer).
- Browser on max-dev: a trashed shelf card read Items 2 / Subcategories 1 while its confirmation said 3 items; confirming kept the subcategory restored on its own; Batch 2's trash view fixes checked on a seeded catalogue.

## Open

For the maintainer to decide (not deferred by this follow-up):

- **Performance (Claude #3):** some queries repeat per level load, a category row is read twice per item write, and `ancestors_first/1` runs one query per selected uuid. Correct, and cheap at current volumes.
- **Behaviour change for ecommerce (Claude #4):** the Shopify collection sync now gets a changeset error if a target category is trashed mid-sync.
- **Untested:** the Status column forced onto the Deleted tab when a user's column set leaves it out.
