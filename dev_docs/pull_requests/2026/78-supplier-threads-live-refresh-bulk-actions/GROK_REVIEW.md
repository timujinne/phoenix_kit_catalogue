# Review — PR #78: Supplier comment threads, live refresh, and bulk Move / Duplicate / Supplier price

**Author:** Max Don (@mdon)
**Reviewed:** 2026-08-24
**Status:** Merged as `d274e7c` (`51e699a` on `mdon/main`)
**Verdict:** SHIP after the post-merge pass. The first review batch (`3437621`)
closed the cross-catalogue bulk holes, closed-modal `KeyError`s, and
post-commit activity logging. This pass closed the leftover races and
the live-refresh hole the PR claimed to fix.

Reviewed against phoenix-thinking, ecto-thinking, and elixir-thinking.
Data loads in `handle_url_state` / `handle_params`, not `mount/3`.
`Duplication` is a module of functions, not a process. PubSub stays on
the single `"phoenix_kit_catalogue"` topic (admin-only, not multi-tenant).

An earlier panel pass (`grok -p`, excerpts only) is appended below. Every
claim from that pass was re-verified against the code before acting —
see `FOLLOW_UP.md`.

---

## What landed

Four product asks in one series:

1. **Per item × supplier comment threads** — `Catalogue.SupplierComments`
   mints a thread uuid in `metadata["comment_thread_uuid"]`, inherited on
   revision / re-attach, stamped server-side so imports cannot re-point it.
   Removing a supplier **closes** the row. `resource_links/0` registers the
   resolver with core (no host config).
2. **Live refresh** — remaining stale surfaces subscribe to
   `{:catalogue_data_changed, kind, uuid, parent}`. PRO100 loader broadcasts
   after commit. Import wizard ignores an abandoned task's result.
3. **Categories act like items** — `BulkSelectScope` for both levels, bulk
   Move / Duplicate, pickers wrapped in `<form phx-change>` so LiveView 1.2
   actually delivers the event.
4. **Supplier price column** — one grouped query per page
   (`supplier_cost_ranges/1`), on by default, live on `:item_supplier_info`.

---

## Findings (post-merge pass)

### 1. BUG - HIGH — `trash_category(items: {:move_to, child})` parked live items in a deleted category *(fixed)*

`apply_item_disposition/4` reparented first, then the same transaction
deleted the whole subtree, including the target. The LV picker hid that
target; `select_trash_target` accepted any uuid, and confirm did not
re-check the picker list (Codex asked for this; only category-Move confirm
did it).

**Fix:** context refuses `:move_target_in_subtree` (binary/textual UUID
normalised — `Tree.subtree_uuids/1` returns 16-byte binaries). The three
pickers clamp select + confirm to offered targets. `request_trash_category`
/ `restore_category` refuse a uuid from another catalogue.

### 2. BUG - HIGH — `set_primary/2` and `revise_unit_cost/3` still trusted a stale struct *(fixed)*

`delete/2` was re-read under `FOR UPDATE` in `3437621`. `set_primary/2`
only guarded `valid_to` on the caller's struct, then `Multi.update`d that
struct — a concurrent close promoted a closed row and left
`primary_for_item/1` returning `nil`. `revise_unit_cost/3` closed the
stale struct and inserted a successor, racing the current-pair unique
index.

**Fix:** both paths lock-reload, refuse `:not_current`, and write the
locked row. `set_primary/2` now has the missing `:not_current` pin.

### 3. BUG - MEDIUM — Duplicate of a category did not lock the target parent *(fixed)*

`catalogue_for/2` (item copies) already `FOR SHARE`s the category so a
concurrent `move_category_to_catalogue/3` cannot leave a stale
`catalogue_uuid`. `ensure_same_catalogue!/2` for a category copy was a
plain `Repo.get`. Same race, same fix.

### 4. BUG - MEDIUM — first upload in another tab never reached this tab's files grid *(fixed)*

The PR claimed the item form follows file writes. `handle_info(:item)`
called `Attachments.refresh_files/1`, which re-read
`assigns.files_folder_uuid`. A tab that had never uploaded still had
`nil`, so the grid stayed empty until reload. Duplicate already resolved
the deterministic `catalogue-item-<uuid>` folder name; refresh now does
too.

### 5. BUG - MEDIUM — `delete` / `set_primary` / history on the item form ignored `owned_supplier_info/2` *(fixed)*

`open_supplier_comments` was scoped to rows this form rendered ("a crafted
uuid must not address another item's thread"). The sibling events still
`ItemSupplierInfos.get/1`'d any uuid, so an admin form for item A could
close or promote a supplier row on item B and open B's price history.

**Fix:** all three go through `owned_supplier_info/2`.

### 6. IMPROVEMENT - MEDIUM — new context error atoms and activity actions had no pins *(fixed)*

AGENTS.md: a new error atom needs `Errors.message/1` + `errors_test.exs`;
a new activity atom needs `activity_logging_test.exs`. Duplicate added
`item.duplicated` / `category.duplicated` / `*.bulk_duplicated` and
`:invalid_uuid` / `:files_folder` / `:wrong_catalogue_scope` (now also on
Duplicate) / `:not_current` without either. Added, plus
`:move_target_in_subtree`, hand-edited into `default.pot` and en/et/ru.

---

## Verified as correct

- **Thread identity.** Mint on first create, copy on revision, inherit on
  re-attach, stamp on every write, drop on Duplicate. Resolver prefers the
  current row; closed-only threads still resolve. Paths are raw;
  `prefixed: true` is applied once by core.
- **Close-on-remove.** `valid_to = max(today, valid_from)`, primary
  dropped, `FOR UPDATE`. Re-attach resumes the thread.
- **Bulk catalogue scope.** `scoped_actor_opts/1` on Move / Duplicate /
  trash / restore / purge; `:wrong_catalogue_scope` per entry.
- **Closed-modal handlers.** Six guards, no `KeyError` on `%{}`.
- **Activity after commit.** Duplication collects logs, `flush_logs/1`
  after the transaction; one bulk summary row.
- **Per-language "(copy)".** `Gettext.with_locale` per language entry
  (`"A-et (koopia)"`).
- **`bulk_epoch` remounts BulkSelectScope** (core has no `bulk_select:clear`
  handler). Core follow-up still needed.
- **PRO100 loader** broadcasts after the transaction.
- **Abandoned import** `handle_info({:import_result, _}, %{import_task: nil})`
  is a no-op.
- **Gettext.** New UI strings were already in en/et/ru and pinned.
- **No queries in `CatalogueDetailLive.mount/3`** — subscribe + sort
  defaults; the level loads in `handle_url_state`.

## Not done (recorded, product)

See `FOLLOW_UP.md` "Open — for Max to decide": SKU copied as-is, files
linked not copied, `"(copy) (copy)"` stacking, per-row renumber
`UPDATE`s, boolean `bulk_change_pending`. Those are product calls, not
defects against the written contract.

---

## Earlier panel review (verbatim, `grok -p`, excerpts only)

**Reviewer**: Grok (xAI, `grok -p`, no tools)
**Scope**: Design of the Duplicate action, with excerpts of duplication.ex
**Date**: 2026-08-24
**Method**: Design questions answered from excerpts (grok bails on large diffs)

Verbatim output; every claim was re-verified against the code before acting — see `FOLLOW_UP.md` for the verdict on each.

---

**(1) First bite: SKU, then shared files, then names. Concurrent positions last.**

SKU copied as-is. Failure: every Duplicate yields two live rows with the same SKU. Search, Pro100/Universal export, supplier matching, and “find by SKU” immediately go dual. If you later add a unique index, bulk Duplicate starts failing on *every* row. This is the daily one.

Files are aliases (`FolderLink` to files still homed in the source folder). Failure: trash/purge the original (or empty/purge its home folder). Storage deletes files with that home; the copy’s “own” attachments and the copied featured-image UUID vanish. Unlink-from-copy is safe; delete-original is not. Won’t show up on day one, will on first cleanup.

`"(copy)"` is English, written into every language map, and stacked on re-duplicate (`"Uks (copy) (copy)"`). Ugly in et/ru, not data loss. Child categories/items keeping names is correct.

`place_item_after` SELECTs all non-deleted siblings with no `FOR UPDATE`, then N `update_all`s. Two admins duplicating (or one duplicate + one drag-reorder) both compute 1..n; last commit wins; copies share positions or the other reorder is wiped. Rare in a small admin, catastrophic in a fat category (rewrites the whole sibling list per copy).

**(2) Missed vs a conventional catalogue copy**

- New SKU/slug/barcode (or a unique suffix).  
- Own file bytes or a copy-home, not links into the source home; featured-image pointer is the same shared UUID.  
- Force `status: "active"` — `@item_fields` copies archived/deleted.  
- Always allocate a new files folder. `files == []` skips `put_folder_pointer!`; if `copy_data` left `files_folder_uuid`, the copy keeps the source folder and the next upload writes into the original.  
- Per-item attribute *values* if they are not the set/group join rows.  
- PDF-library / related-item / external-id rows, if those exist.  

Current-only supplier rows, fresh comment threads, no activity/comments: correct.

**(3) Per-source + best-effort is right for 50**

All-or-nothing: item 47 hits a unique/rule/storage error and rolls back 46 good copies. Users retry blind. Duplicate-selected is 50 independent intents; a category tree is already one transaction. Emit a per-uuid error list and one PubSub after the loop. Cost: partial sibling order if some fail — acceptable.

**(4) Ecto**

`insert(cs, on_conflict: :nothing)` on conflict returns `{:ok, _}`, not `{:error, cs}`. The `rollback` arm never runs for dup links; conflicts are swallowed. `:nothing` and rollback are opposite policies. Drop `:nothing` or treat `{:ok, %{uuid: nil}}`.

`Repo.rollback/1` only works inside `transaction/1`. Fine if bulk always wraps; a bare `copy_item` raises.

`update_all` *does* roll back with the transaction. That part is fine. It skips validations/`updated_at`. The bug is the unlocked SELECT. `FOR SHARE` is wrong: two duplicators can both hold it and both renumber. Use `FOR UPDATE` on the sibling rows (or an advisory lock on the parent).

Inserting the copy at `source.position` *before* renumber: any unique `(catalogue, category, position)` index raises `ConstraintError` (not a changeset) and the UI gets a 500. If Storage folders commit on another Repo/path, a later rollback orphans folders.
