# PR #112: Show every attached file everywhere, and say when an upload was a duplicate — Claude review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/112
**Author**: @mdon
**Reviewer**: Claude (Fable 5.1) — post-merge pass
**Merge commit**: `b7da9f0` (12 commits, `228d684`..`b4189e3`)
**Date**: 2026-09-13
**Status**: reviewed; one MEDIUM correctness fix and one NITPICK applied post-merge

## Scope

A twelve-commit sweep, in four threads:

1. **Attachments read one set everywhere.** `Attachments.list_folder_files/2`
   and `folder_files_query/1` are now THE reader (home files plus
   `FolderLink` rows, live, oldest first, capped at 200). The product card,
   the paperclip counts (`Counts.attached_file_counts/1`) and
   `Duplication` all go through it, so a content-duplicate upload — which
   Storage turns into a link, not a home row — shows on the card and in
   the count, not just in the editor. The type/system-managed filters
   moved into SQL so the cap cannot eat the rows a caller wanted.
2. **Attachment writes land at once.** A drop reorder, a removal and the
   first upload of an existing resource are persisted immediately as
   owned-key writes (`data_owned_keys:`), not at Save; the pointer to the
   folder follows the first upload. A duplicate upload is reported in a
   flash instead of silently doing nothing; a trashed duplicate is
   restored. `refresh_files/1` re-applies the editor's order and adopts a
   reorder made in another tab (`media_order_persisted` tracker). Every
   form LiveView subscribes and refreshes its grid on its own resource's
   broadcast.
3. **`ComponentRelay`.** A per-open process that holds the catalogue
   PubSub subscription for a LiveComponent and delivers debounced
   `send_update/3` refreshes with an ack/abandon protocol. The item
   selector modal uses it to stay live while open; `BrowseState` gained
   `:refresh` (re-read every loaded page as one fetch, keep the page
   cursor).
4. **Sweep.** Attribute/value mutations now log activity rows and take
   `opts`; `update_catalogue/3` honours `:data_owned_keys` like
   `update_item/3`; the supplier-fields blueprint is edited under a row
   lock; `mode:` from callers reaches the log; the PDF library no longer
   trashes a file that is some product's attachment; the export download
   returns 400 for a non-canonical uuid; crafted event payloads
   (`trim_param/1`, `column_index/1`, `narrow_new_data/2`) no longer crash
   forms; the item supplier broadcast now carries the item's catalogue;
   the tree remembers open parents in the browser and a move names its
   destination. `move_item_and_reorder_destination/4` and the duplicate
   `attribute_set_valid_selection/2` delegate were removed as dead code.

## Verification

- **Storage contract.** `Storage.restore_file/1` and
  `Storage.Folder.trashed_at` exist in the pinned core, so the
  trashed-duplicate restore and the "live folders only" link re-homing
  compile against what ships. `PhoenixKitEntities` is itself the
  `phoenix_kit_entities` schema, so `lock_blueprint/1`'s
  `from(e in PhoenixKitEntities, lock: "FOR UPDATE")` is a valid
  queryable.
- **Owned-key writes.** `narrow_data_ownership/4` re-reads the row
  `FOR UPDATE` inside the caller's transaction, and `update_catalogue/3`
  now wraps its update in one — same shape as items and categories. An
  owned key with an explicit `nil` deletes; `attach_files/3` and the
  three forms were checked to omit, not `nil`, a key they have nothing to
  say about.
- **Relay lifetime.** `spawn` (not link) plus `Process.monitor/1` on the
  host, `stop/1` from every close path (cancel, ESC/backdrop, confirm,
  immediate single pick), and the ack timeout for a host that unmounts
  without a close. `send_update/3`'s assigns reach `update/2` once and are
  not re-sent by a later host render, so `live_refresh` cannot replay.
  The dead render never starts one.
- **`BrowseState :refresh`.** `fetch/1` resets items, known uuids and
  `exhausted?`, then the page cursor is restored and the limit is
  `(page + 1) × per_page`; `Search.search_items/2` does not clamp
  `:limit`, so a deep scroll refreshes in one query. `ingest/4`'s
  exhausted latch still holds for the widened page.
- **Supplier broadcast scoping.** `CatalogueDetailLive` now ignores
  `:item_supplier_info` events for other catalogues; a `nil` parent (row
  whose item is gone) still refreshes.
- **Events page.** Action badges are rendered from the string itself, so
  the seven new attribute action names need no label table; the
  `mode_label/1` and `humanize_resource_type/1` wrappers cover the two
  columns that did have English literals.
- **Removed public functions.** No caller of
  `move_item_and_reorder_destination/4` or `attribute_set_valid_selection/2`
  in this repo or in any sibling `lib/` under the workspace
  (`valid_attribute_set_selection/2` stays). Recorded in the CHANGELOG as a
  removal.
- **`test/edge_cases_test.exs` shows as binary in the diff** only because
  the null-byte test used to embed a literal NUL; it is now `<<0>>`.

## Findings

### BUG - MEDIUM — the paperclip count could double-count a re-homed file

`Counts.attached_document_counts/1` sums a home-rows query and a link-rows
query. `Attachments.folder_files_query/1` reads `home OR linked`, so a
file with a home in folder F **and** a `FolderLink` row for F is listed
once but counted twice. The shape is reachable: a file linked into F
(a content-duplicate upload) and later re-homed into F by the media
manager keeps its link row; `assign_file_to_folder/2` only skips the link
when the file is already home there at upload time.

**Fixed:** the link-rows query now excludes rows whose file's own
`folder_uuid` is the linked folder (`is_nil(f.folder_uuid) or
f.folder_uuid != fl.folder_uuid`), so the two sets are disjoint and the
count is the listing's cardinality. Pinned in
`test/web/product_card_db_test.exs` ("a link row naming the file's own
home folder counts it once").

### NITPICK — the category form's "moved into" flash was not localized

`CatalogueDetailLive.moved_flash/2` localizes the destination name with
`Catalogue.localize_one/2`; `CategoryFormLive.moved_flash/1` interpolated
the primary-language `name` column. Same action, two languages for an
admin browsing in a secondary locale.

**Fixed:** the form's flash takes the socket and localizes with
`current_locale` like the detail page.

### NITPICK — `Enum.filter(requested, &(… match?({:ok, ^&1}, …)))` in the export controller

A pinned capture argument inside `match?/2` compiles, but it is the kind
of line a reader has to parse twice. **Not changed:** it is correct, it is
pinned by three controller tests, and a rewrite would be taste.

### Recorded, not fixed

- **`item_catalogue_uuid/1` per supplier broadcast** is one extra query
  per mutation on a supplier row. Correct and cheap at current volumes;
  a caller that already holds the item could pass it in later.
- **Relay abandonment needs a second event.** An orphaned relay (host
  unmounted the modal without a close) lives until the next relevant
  event after the 15 s ack window. Bounded and documented in the
  moduledoc; the README tells hosts to mount with `:if` and reset on
  `{:item_selector_closed, …}`, which is the close path.

## Gate

`mix format`, `mix precommit` and `mix test` — see the release commit.
