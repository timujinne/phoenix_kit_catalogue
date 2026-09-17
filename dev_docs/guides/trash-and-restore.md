# Trash and restore

Catalogues, categories and items soft-delete through their `status` column
(`"deleted"`). This guide explains how a trash is recorded so that a restore
can undo exactly that trash, and how the paths are serialized. The code is in
`PhoenixKitCatalogue.Catalogue` (search for "Trash provenance").

## The rule

**Restoring a row undoes the trash that put it in the bin — no more, no less.**

- *No more:* a row trashed on its own before its parent stays in the trash when
  the parent is restored.
- *No less:* the rows a catalogue or category trash took come back with it.
- Every row returns to the status it had: an `inactive` or `discontinued` item
  stays so, an `archived` catalogue comes back `archived`.

## Provenance stamps

Every trash path writes, in the same statement that flips `status`, a reserved
top-level key into the row's `data`:

```json
"_trash": {"via": "self" | "catalogue" | "category",
           "root": "<uuid of the row the operator trashed>",
           "from_status": "<status the row had>"}
```

| Operation | Rows it flips | Stamp |
|---|---|---|
| `trash_catalogue/2` | the catalogue's live items and categories, then the catalogue | children `via: catalogue, root: <catalogue>`; the catalogue itself `via: self` |
| `trash_category/2` with `items: :cascade` | the subtree's live categories and items | `via: category, root: <category>`; the category itself `via: self` |
| `trash_item/2`, `bulk_trash_items/2`, `trash_items_in_category/2` | the items | `via: self, root: <item>` |

A trash only ever flips rows that are still live, so a row already in the bin
keeps the stamp of whatever trashed it first. `bulk_trash_categories/3` trashes
ancestors before descendants, so a selection holding both stamps the descendant
as taken by its ancestor.

| Operation | Rows it brings back |
|---|---|
| `restore_catalogue/2` | categories and items stamped `root: <catalogue>`, **plus deleted rows with no stamp** |
| `restore_category/2` | the category, and descendants and items stamped `root: <category>` |
| `restore_item/2`, `bulk_restore_items/2` | the items |

Each restore sets the whitelisted `from_status` and removes the stamp in one
statement.

Delete Forever on a trashed category removes only the trashed part of its
subtree and keeps a live subcategory it stops at (moved to the end of the top
level). Rows under that subcategory which the removed categories' trash took
would name a root that no longer exists, so they are re-stamped in the same
transaction: a trashed category takes the root its trashed parent has (the
topmost one becomes `via: self`), and an item in a live category becomes
`via: self`. `from_status` is kept.

### Why a key in `data` is safe

The stamp is read only on deleted rows. Every trash writes it and every restore
clears it, so a stale copy on a live row — from a form that round-trips `data`,
or an import — is inert and is overwritten by the next trash. A stamp lost from
a deleted row degrades to the legacy behaviour below, never to a broken state.
`Duplication` does not copy the key.

### Rows trashed before stamps existed

A deleted row with no stamp cannot say what trashed it. `restore_catalogue/2`
brings it back with its catalogue, which is what it did before stamps, so a
legacy trashed catalogue still restores whole. `restore_category/2` leaves such
rows alone, because category restore never revived anything before.

Some long-lived installs also hold catalogues marked deleted whose children were
never cascaded (still `active`). A trashed catalogue's row on the catalogue
list therefore counts its live items along with the deleted ones its Restore
brings back. Running `trash_catalogue/2` on such a catalogue sweeps and stamps
the live children.

## What a restore does not undo

- **`items: :uncategorize` and `items: {:move_to, target}`** move items out of
  the category and leave them live. Restoring the category does not move them
  back.
- **`restore_item/2` on an item whose category is still trashed** clears
  `category_uuid`, so the item reappears in Uncategorized rather than silently
  reviving its category. Restore the category instead to get items back in place.
- **An item stamped by a root whose own category is still trashed** (its category
  was restored and trashed again in between) stays in the trash when the root is
  restored, inside that category — and joins that category's trash: it takes the
  category's stamp root (`via: category`), or becomes `via: self` when the
  category has no stamp, keeping `from_status`. Restoring the category, or what
  trashed it, then brings it back, and a later trash and restore of the first
  root leaves it alone. `restore_catalogue/2` applies the same rule to the
  items it leaves behind.

## What a catalogue's Deleted tab lists

A trashed category is one unit, the way a trashed catalogue is on the catalogue
list: the tab shows each top-level trashed category (its parent is not trashed)
as a card, and it cannot be opened. A trashed card counts what its Restore
brings back: the subcategories and items its own trash stamped, not rows
trashed on their own before it, which stay in the trash. A trashed catalogue's
row on the catalogue list counts the same way. Items are listed on their own only when they sit
outside a trashed category (uncategorized, or in a live category), and the
tab's count follows the same rule. Search in the tab still finds every trashed
item. To act on a category's items separately, trash it with `:uncategorize` or
`{:move_to, _}` instead of `:cascade`.

## Status only changes through trash and restore

`update_item/3`, `update_category/3` and `update_catalogue/3` never move a row
into or out of `"deleted"`; such a status change is dropped from the changeset,
decided from the row as it is in the database. A form cannot show `"deleted"` in
its status select, so saving a trashed row posts the first live option, and a
form opened before a trash would otherwise revive the row on save with none of
the rules above. Moves between live statuses (`inactive`, `archived`, …) apply
as normal. A row *created* already `"deleted"` (an import, an API caller) is
stamped as trashed on its own, so a catalogue restore leaves it in the trash.

## No live item in a trashed category

A live item under a deleted category is in neither the category tree nor any
Deleted tab. Nothing may produce one:

- Restores skip items whose category is still trashed after the category pass.
- `create_item/2` and `update_item/3` add a changeset error on a trashed
  `category_uuid`; `move_item_to_category/3`, `bulk_move_items_to_category/3`,
  `duplicate_item/2` and `trash_category/2`'s `{:move_to, _}` refuse a trashed
  target.

## Locking

Every trash, restore and permanent-delete path runs in a transaction that first
takes a transaction-scoped advisory lock per catalogue (`lock_catalogue!/1`;
bulk paths lock several in sorted order), then re-reads the rows it decides on.
Without it, a category trash racing an item restore could leave a live item in
a trashed category: under `READ COMMITTED` a transaction alone does not stop
another commit landing between a read and a write.

The key is the catalogue a row lives in, read just before locking.
`move_category_to_catalogue/3` takes both catalogues' locks, in sorted order,
so a move and a trash or restore in either catalogue serialize instead of
deadlocking. If a row turns out to have moved between that read and the lock,
the attempt rolls back with `:catalogue_moved` and `locked_transaction/1` runs
it again from the top, rather than taking a second key out of order. Bulk paths
re-check their set of catalogues the same way.

Category and item reorders take the same per-catalogue lock: they write rows
one at a time in the caller's order, which would otherwise deadlock against a
trash or restore writing the same rows in scan order.

Paths that write items into a category without that lock take the category row
`FOR SHARE`; a catalogue or subtree trash locks its category rows `FOR UPDATE`
before touching items. A concurrent create or move therefore either commits first and
is swept by the trash, or waits and then sees the category trashed.

Permanent deletes lock the category rows, and for a catalogue the catalogue
row, before deleting items, so an item created or moved in meanwhile fails its
foreign key instead of surviving uncategorized through `ON DELETE SET NULL`.

## Adding a trash or restore path

- Stamp with `stamp_trashed/4` or `stamp_trashed_self/2`, and only rows that
  are still live.
- Restore with `restore_trashed/3`, filtered by `trashed_by/2` (or
  `trashed_by_or_unstamped/2` for the legacy catalogue case), and exclude items
  in trashed categories with `outside_trashed_categories/1`.
- Take `lock_catalogue!/1` (or `lock_row_in_catalogue!/2` /
  `lock_catalogues_of!/2`) inside `locked_transaction/1` before reading anything
  the path decides on.
- Add the path to the randomized run in `test/catalogue/trash_restore_test.exs`.
  It applies random sequences of every path, checks the invariants after each
  step, and asserts that trashing then restoring any live root changes nothing.
  A failure message carries the seed and the operation history; rerun with
  `mix test --seed <seed> test/catalogue/trash_restore_test.exs` to replay it.
  The default size keeps the suite quick; widen a run with
  `TRASH_FUZZ_WORLDS=150 TRASH_FUZZ_STEPS=15`.
