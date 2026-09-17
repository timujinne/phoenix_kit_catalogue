# PR #124: Duplicate a catalogue, move anything to any catalogue, and fix the picker's missing photos — Grok review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/124
**Reviewer**: Grok 4.3, no tools; each round answered a short brief (no repository access)
**Date**: 2026-09-17
**Scope**: three rounds: the design draft before `da871e4`; locking in the move and copy paths at `c2116b6`; a re-check of the fixes at `b35d897`

## Round 1: design of Duplicate catalogue

**1. Always archived** (and refuse if the source is `deleted`). Duplicating is “make a working copy”, not “put another live catalogue in every listing”. Mirroring `active` drops a second live tree (same markup/discount, same SKUs) next to the original; mirroring `deleted` makes a copy you then have to restore. Shop binds by name so `"X (copy)"` will not go live by itself — archived is the review gate, not a shop-safety net. Activate is a deliberate second click.

**2. SKUs verbatim; slugs empty.** SKUs are not unique and are product identity: the point of cloning a catalogue is the same products under new catalogue policy. Blanking thousands of SKUs is unusable; a `-copy` suffix is a new identity scheme nobody asked for (and collides on the second duplicate). Slugs are unique **per language across the whole table** — copying them aborts the transaction; generating unique ones now invents URL policy at clone time. Empty matches `duplicate_item`. If the copy later needs URLs, that is a bulk “fill missing slugs” job after review, not a side effect of clone.

**3. Neither long source-lock txn in LiveView, nor RR with no lock.** Use a **background job** (not `start_async` — navigate-away kills the LV and rolls back a minute of work). Take a **REPEATABLE READ snapshot of the source** so the copy is a point-in-time tree, and hold only a **short “clone this source” mutex** so two duplicates cannot fight over `"X (copy)"` and folder position. Do **not** hold the operational advisory lock that serialises trash/restore/reorder/move for the whole minute — that punishes editors for a read of a frozen tree.

- **One txn + source operational lock:** consistent, but source is frozen, `idle_in_transaction` / statement_timeout, and 6–10 queries × thousands of items is 20–30k round-trips in one WAL balloon. Fine only if you **bulk `INSERT … SELECT`** (tens of statements, not tens of thousands).
- **RR, no lock at all:** snapshot of items is fine; what breaks is **concurrent clone** (two `"X (copy)"`, same insert slot) and **folder position** (that lock is per-catalogue, not per-folder).
- **Chunked commits:** only if you keep the per-item copier. Then the dest must be unlisted (`archived` / `duplicating`) until the last chunk, with **purge-the-dest** on failure (files folder, FolderLinks, supplier comment threads). Partial trees in the admin UI are the failure mode.

**4. Shared FolderLinks are correct; copying bytes is almost never worth it.** Later:

- **Hard-delete in Media** removes the blob for **both** catalogues. At item-clone scale that is rare; at catalogue scale a “clean up the copy” sweep is how you delete production assets. Unlink must be the default; hard-delete only when refcount is 0.
- **Reorder** is fine if position lives on the **link**. It fights if position lives on the file row.
- **`featured_image_uuid`** is copied as the same media UUID (data minus `files_folder_uuid`). Display-by-UUID still works; folder-scoped queries do not unless you also link that UUID into the dest folder.

Byte-copy only if a catalogue must be isolatable (franchisee, “delete this client’s files”). Cost is storage, time, and rewriting every UUID in jsonb. Refcounted blobs are the real fix.

**5. Do not copy namespaces you do not own. Publish an id map.** `featured_item_uuid` still pointing at the source item is a cross-catalogue leak or a silent 404; **Shopify `product_id` / handle** on the copy is the actually destructive case (two trees syncing one product). Catalogue should allowlist its own keys (`translations`, `meta`, `featured_image_uuid`) and **drop `ecommerce` (and any unknown top-level key)**. Then broadcast `catalogue.duplicated` with `%{source_id => dest_id}` for catalogue / categories / items. Shop remaps `featured_item_uuid` or clears it, and **must nil Shopify ids**. A behaviour/hook is cleaner than catalogue parsing a sibling’s jsonb; copying opaque `data` is how you ship a time bomb.

**6. Shop-by-exact-name is already a footgun; clone adds three more.** Names are apparently not unique. `Repo.get_by(name: …)` is whichever row the index returns.

- Clone itself is safe (`"X (copy)"` ≠ `"X"`) **until** someone renames.
- Second clone → two catalogues named `"X (copy)"` unless you disambiguate (`"X (copy 2)"`).
- Rename-swap (point shop at the clone by giving it the old name while the original still exists) is undefined; rename-after-archive-original is the only sane fork-and-replace.
- Copied Shopify ids + a later name collision = dual sync of the same products.

Clone must guarantee a **name that no existing catalogue has** (all languages). The real fix is shop resolving by **catalogue UUID**; until then the confirm modal should say so.

**7. Misses, by how much they hurt**

1. Looping `duplicate_item` without remapping `catalogue_uuid` / `category_uuid` — copies land in the **source** (today’s helper is same-catalogue). Need an explicit id map and a catalogue-scoped copier.
2. Opaque `data` copy (Shopify ids, featured item) — see 5.
3. `start_async` + 20k queries under the **operational** source lock — cancelled jobs, blocked editors; see 3.
4. Non-deleted items whose category is deleted — not in “top-level subtrees” and not uncategorized; they vanish or keep a foreign parent.
5. `"X (copy)"` / folder-position races and shop-by-name — see 3 and 6.
6. Smart rules: they should keep pointing at the **same STANDARD catalogue** (right). Duplicating that STANDARD does **not** retarget existing smart catalogues (also right, but surprising — say it on the modal).
7. Per-row fresh supplier comment threads × thousands — noise, not wrong. i18n of `"(copy)"`. Permissions on a full pricing clone.

## Round 2: locking review (`c2116b6`)

Questions: deadlocks between new and existing paths; an interleaving that leaves a live item in a trashed category or with a catalogue different from its category's; an interleaving that yields a wrong copy.

**1. Deadlock (one pair)**

`MOVE_ITEM_TO_CATEGORY` × `MOVE_CATEGORY_TO_CATALOGUE`, dest a **descendant** of the moved cat (not the root — that root is already `FOR UPDATE` before items), and the item still in that subtree.

- MITC holds dest `FOR SHARE`, waits item `FOR UPDATE`.
- MCTC holds that item `Exclusive` (`UPDATE items in subtree`), waits dest `Exclusive` (`UPDATE subtree categories`).

Same inversion as existing `UPDATE_ITEM` × MCTC. Other new paths take `L(catalogue)` / `L(S,T)` first, so they serialize with MCTC/TRASH on the dest catalogue and never reach the inverted row locks. MITC is the one that skipped the advisory lock. Two MITCs (cat then item) do not invert.

**2. MITC × MCTC → catalogue skew (not trash)**

TRASH updates **categories then items**, so dest is `Exclusive` for the rest of that txn; MITC’s `FOR SHARE (live)` either waits and then sees `deleted`, or commits first and TRASH’s item update still sees current membership. No live-in-trashed category unless TRASH deletes by a **preloaded item-id list**.

MCTC is the opposite order. Sandwich:

1. MITC: dest `D` `FOR SHARE` (`D.catalogue` still `S`; `D` in the moving subtree).
2. MCTC: `L(S,T)`; root `FOR UPDATE`; `UPDATE items … SET catalogue=T` (item not in the subtree yet → not rewritten).
3. MCTC: `UPDATE subtree categories` blocks on MITC’s share on `D`.
4. MITC: item `FOR UPDATE`; `UPDATE` item → `category=D`, `catalogue=S` (from the share-frozen `D`).
5. MITC commits; MCTC sets `D.catalogue=T`.

Result: live item with `catalogue=S` under a category now in `T`. Dest share freezes `D`’s row for MITC, not for MCTC’s later statement.

**3. DUP (READ COMMITTED, no source lock)**

After the per-category item read for copied `K`, concurrent `CREATE_ITEM` / `MOVE_ITEM_TO_CATEGORY` / `BULK_MOVE` places live `X` in `K`.

Copy never sees `X`. Orphan pass does **not** cover it: `X.category` **was** copied, so `X` is not uncategorized. Source is fine.

(The rule **does** cover a category created *after* the category listing: those items come through as uncategorized. It does **not** cover A→B between two per-category scans: `X` is copied twice.)

## Round 3: re-check of the fixes (`b35d897`)

Questions: any remaining deadlock or skew in the subtree-locking category move; any interleaving in the one-read copy that still yields a wrong copy.

**1. A — remaining hole is `CREATE_CATEGORY`, not the lockers you listed.**

Among `MCTC`, `TRASH_CATEGORY` / restore / permanent delete, and a second `MCTC` on an overlapping subtree: **no deadlock, no skew.** All take `L(catalogue)` first (pair in uuid order for two catalogues), then categories `FOR UPDATE ORDER BY uuid`. Overlapping trees share a source catalogue, so they serialize on `S` before any category rows. `TRASH` on a subcategory only needs `S`; it cannot form a wait-cycle with `L(S,T)`.

`UPDATE_ITEM` (name/price/etc.): **no deadlock.** Skew only if the changeset writes `catalogue_id` / `category_id` from a stale load; a normal dirty-field update will not.

**`CREATE_CATEGORY(parent)` still skews.** Plain `SELECT` does not wait on `FOR UPDATE`. Sequence:

1. Read parent → catalogue `S`
2. `MCTC` locks parent `FOR UPDATE`, moves subtree to `T`, commits
3. `INSERT` was blocked on `FOR KEY SHARE` of parent; it now proceeds with **stale `S`**

Child in `S`, parent in `T`. The descendant re-read cannot see it: the insert cannot commit until `MCTC` drops the lock. Same TOCTOU if you reparent a node into that parent without taking `L(S)` first.

`CREATE_ITEM` / `MOVE_ITEM` dodged this in the probe because they take `L(catalogue)` and re-check the category under that lock. `CREATE_CATEGORY` does neither.

Fix: `SELECT parent FOR SHARE` (or `L(parent.catalogue)` then re-read `parent.catalogue_id`) in the same txn as the insert; insert that id, not the first read.

---

**2. B — no duplicate rows; mixed snapshot, not a corrupt tree.**

One items `SELECT` + partition by category membership ⇒ each item copied once. No double insert.

The two `SELECT`s under **READ COMMITTED** are two instants:

- Category created after the category read and before the items read: **lost live category**; its items copy **uncategorized**
- Anything committed after the items read: **lost live row** (normal if you do not `L(catalogue)` / `REPEATABLE READ`)

**Dangling parent is not created by interleaving.** The category list is fixed; parent pointers do not change under you. Dangle only if a live row’s `parent_id` was already outside that live set (trashed / other-catalogue parent) and you remap to the old id instead of nulling. Copy from the lists; do not re-read parents.

Per-item extras after the item insert can miss a concurrent add/delete; they will not duplicate a row or dangle a category parent.

Fix: both bulk `SELECT`s (and ideally extras) in one `REPEATABLE READ` txn, or `L(source)` for the read phase — still does not close `CREATE_CATEGORY` unless that op takes a catalogue/parent lock.
