# PR #118 — Claude review — quality sweep re-validation agents

**Reviewer**: Claude (Opus 5), four Explore agents with the C12 prompts from the quality sweep playbook, each finding verified against the code before it was acted on
**Date**: 2026-09-15
**Scope**: every change on `main` since `upstream/main` (`8388156`)

## Agent #1 — security, error handling, async UX

- **BUG - MEDIUM** — single-row `restore_item`, `permanently_delete_item` and `permanently_delete_category` looked rows up by the client's uuid only, with no catalogue or status check; `show_delete_confirm` stores any uuid. A forged event on one catalogue's page could hard-delete a live category of another. Older code, now reached from the rebuilt Deleted tab's row menus.
- **BUG - MEDIUM** — `permanently_delete_category/2` removed the whole subtree whatever each row's status: trash A with a child B, restore only B (shown at the top level of Active), Delete Forever A → live B and its live items destroyed.
- **NITPICK** — double-clicking bulk Restore shows a misleading error flash. *Refuted on verification*: already-restored categories fall through silently; the second click only flashes "Restored 0 categories."
- **IMPROVEMENT - MEDIUM** — `bulk_result({:error, _})` and `trash_items_in_category`'s error branch drop the reason without logging; a `:catalogue_moved` after three lock retries reads as "Deleted 0 items".
- **NITPICK** — the `phx:bulk_select:clear` listener clears every scope in the document, not only the pushing LiveView's.
- **NITPICK** — a comment above `resolve_node/2` still said a trashed category can be opened.
- Checked and fine: no secrets, bound SQL parameters everywhere, no SSRF surface, `URI.encode_query` for return paths, new bulk events scoped to the catalogue, no new logging of sensitive data, no widened casts, `phx-disable-with` on row Restore, no new `rescue`.

## Agent #2 — translations, activity logging, tests

- Translations complete: every msgid used in the changed code is in the `.pot` and all five `.po` files; renamed and new strings translated in et and ru.
- **NITPICK** — new count flashes use singular-only wording ("Permanently deleted 1 categories."), and runtime gettext inside HEEx attributes.
- **IMPROVEMENT - MEDIUM** — `test/activity_logging_test.exs` had no test for `category.trashed`, `category.restored`, `category.permanently_deleted`, `catalogue.permanently_deleted`, `item.restored` or the `item.bulk_*` trash actions, and none pinned the new metadata keys.
- **IMPROVEMENT - MEDIUM** — bulk Delete Forever refusing a live category of the same catalogue was untested.
- **IMPROVEMENT** — the error atom `:catalogue_moved` had no `Errors.message/1` clause or pin.
- C11 delta audit, missing pins: lock changes (not testable under the SQL sandbox), `_trash` not copied by duplication, `:statuses` ignored when searching the trash, the Status column forced onto the Deleted tab, the JS clear listener, the `outside_trashed_categories` option at the context level.

## Agent #3 — PubSub, cleanliness, public API

- **BUG - MEDIUM** — race: bulk Delete Forever checked `status: "deleted"` on a plain read, then `permanently_delete_category/2` deleted under the lock without re-checking, so a category restored in another tab in between was destroyed with its subtree.
- **IMPROVEMENT** — repeated queries per level load (category children counts twice when drilled; discarded child listing and count maps at the root's Deleted tab; the category tree read twice at the root's Active tab), a category row read twice per item write, and one recursive query per selected uuid in `ancestors_first/1`.
- **NITPICK** — dead server-side item selection left by the rebuild (`toggle_select_item`, `clear_selection`, `toggle/2`, the `@selected_items` attr and fallback, stale comments), and two comments separated from their functions.
- **NITPICK** — `restore_item` locks the item before the category, against the categories-before-items order; cannot deadlock because every trash/restore path holds the same advisory lock.
- Checked and fine: topic constants, broadcast after commit, subscribe before the first load, `handle_info` catch-alls, no `Task.start`/`IO.inspect`/TODO markers, `@doc`/`@spec`/`defdelegate` on the new public functions, removed names fully gone, sorted lock order.

## Agent #4 — host-integration boundaries

- No broken boundary. Weakly tested: the JS clear listener (LiveView tests stop at the push), the `outside_trashed_categories` option at the context level, and ecommerce's Shopify sync, which now gets a changeset error if a target category is trashed mid-sync.
- The listener cannot affect other modules' pages in practice: no other module or core pushes or handles `bulk_select:clear`, and core's clear is client-only.
- `item_counts_by_catalogue/1` had no options upstream, so no sibling loses a mode; no sibling calls the changed restore/trash functions or `search_items(trashed: true)`.

## Release review (2026-09-15) — the fix batches

One agent reviewed what Batches 1–3 (`bbd0aed`, `12cdb8c`, `c651dcc`, with `b6b3d82`'s later changes) added to `lib/`; each finding was re-checked against HEAD.

- **IMPROVEMENT - MEDIUM** — Delete Forever on a trashed category left trash stamps pointing at a root that no longer exists.
  - Scenario: trash A, which stamps child B, grandchild C and their items with root A. Restore only B. Delete Forever A keeps live B and its subtree, but C and the items under B stay stamped root A.
  - Result: C's card counted 0, C's Restore brought back C without its items, and a catalogue restore skipped them too, because of the foreign stamp.
  - Before Batch 1 these rows were destroyed along with A.
- **IMPROVEMENT - MEDIUM** — the Active tab's `delete_item` event still looked the item up by the client's uuid alone. Batch 1 scoped only restore and Delete Forever. A forged event could trash an item of another catalogue (reversible, but the same class as Agent #1's finding).
- **NITPICK** — a kept live subcategory moved to the top level kept its old position, which can tie with the existing top-level rows.
- **NITPICK** — the bulk Delete Forever confirmation still says "everything in them will be permanently deleted"; neither confirmation mentions that a live subcategory is kept and moved.
- **NITPICK** — `drop_from_search` lowers `search_offset`, so an in-flight `:search_page` reply is discarded with `search_loading` still true. It heals on the restore's own broadcast, which re-runs the search.
- Checked and fine: `only_trashed` re-checked under the lock, the trashed-part walk reads statuses after `lock_categories!`, `permanent_delete_scope/1` matches the delete, `card_restore_counts` mirrors `do_restore_category`, the tab rule, trash search and sort, the item write's reused `FOR SHARE` facts, and `ancestors_first/1` under the lock.
