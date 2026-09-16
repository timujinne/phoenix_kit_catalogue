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

## Fixed (Batch 3 — 2026-09-15, commit c651dcc; ecommerce b5abf0b)

Max asked for the open items to be fixed.

- ~~Performance (Claude #3).~~ A drilled level reads its child-category counts once for both
  modes and its listing reuses them; the root's Deleted tab skips the level listing and the
  count maps it never used; an item write passes the category its derive step read `FOR SHARE` to the
  category check instead of reading it again; `ancestors_first/1` orders by depth from one
  query, under the catalogue lock, instead of one recursive query per selected uuid.
  Covered by the existing tab, tree, trash-card and bulk-trash tests.
- ~~Behaviour change for ecommerce (Claude #4).~~ `phoenix_kit_ecommerce`'s Shopify
  collection sync now leaves an item whose target category the catalogue refuses where it
  is, with a warning, instead of halting the run (commit `b5abf0b` in that repo, with a
  test that trashes the category mid-run and fails without the fix).
- ~~Untested: the Status column forced onto the Deleted tab.~~ Pinned: "the Deleted tab
  shows the Status column even when the user's columns leave it out"
  (`test/web/catalogue_deleted_tab_test.exs`).

## Fixed (Release review — 2026-09-15, release 0.32.0)

From the release-review section of `CLAUDE_REVIEW.md`.

- ~~IMPROVEMENT - MEDIUM — Delete Forever left stamps pointing at a removed root.~~
  `permanently_delete_category/2` re-stamps, in the same transaction, the
  trashed rows under a kept subcategory whose root is one of the removed
  categories:
  - a trashed category takes the root its trashed parent now has, and the
    topmost one becomes `via: self`;
  - an item in a live category becomes `via: self`;
  - `from_status` is kept.

  The rule is written into `dev_docs/guides/trash-and-restore.md`. Pinned: "rows
  under a kept subcategory get a trash root that still exists"
  (`test/catalogue/trash_edges_test.exs`).
- ~~IMPROVEMENT - MEDIUM — the Active tab's `delete_item` was unscoped.~~ It now
  uses `item_in_catalogue/2`. Pinned in "single-row actions ignore a uuid from
  another catalogue".
- ~~NITPICK — a kept subcategory kept its old position.~~ Kept subcategories go
  to the end of the top level (`next_category_position/2`), in their old order.
  Pinned in the same trash-edges test.

### Skipped (release review)

- **The bulk confirmation does not mention kept subcategories.** It needs new
  msgids in six catalogues. The single-category confirmation already counts
  only what is removed.
- **`drop_from_search` can discard an in-flight page reply.** It heals itself on
  the restore's broadcast, which re-runs the search.

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

Batch 3: `lib/phoenix_kit_catalogue/catalogue.ex`, `lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex`, `test/web/catalogue_deleted_tab_test.exs`; ecommerce `lib/phoenix_kit_ecommerce/shopify/collection_sync.ex` and its test.

## Verification

- Before the fixes: the full suite ten times back to back, 10 × 2800 tests + 2 doctests, 0 failures.
- After Batch 1: three more runs, 3 × 2822, 0 failures.
- After Batch 2: full suite 2827 tests + 2 doctests, 0 failures; `mix precommit` clean (compile, format, credo --strict, dialyzer).
- Browser on max-dev: a trashed shelf card read Items 2 / Subcategories 1 while its confirmation said 3 items; confirming kept the subcategory restored on its own; Batch 2's trash view fixes checked on a seeded catalogue.

- Batch fixing the open items (2026-09-15, commit c651dcc): full suite 2850 tests + 2 doctests, 0 failures; `mix precommit` clean; checked on the dev server.
- Release review batch (2026-09-15, release 0.32.0): full suite 2881 tests + 2 doctests, 0 failures; `mix precommit` clean. The re-stamp and the kept-subcategory position are covered by the randomized run in `trash_restore_test.exs` as well as the new trash-edges pin.

## Open

None.
