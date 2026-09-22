# PR #133: Pick every place in a tree: no flat lists of catalogues, categories or folders — Claude review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/133
**Author**: @mdon (Max Don)
**Reviewer**: Claude Opus 5 — post-merge pass
**Date**: 2026-09-22
**Merge**: `40af748`, 27 files, +2641 / −1115
**Status**: reviewed; 5 findings fixed with regression tests, the rest on record; released as 0.44.0

## Scope

`Web.PlaceTree` (pure folder › catalogue › category trees, built from
`catalogues_by_folder` + `list_live_categories` + `list_folder_tree`) and the
`Components.PlacePicker` LiveComponent (single and multiple pick, search,
hidden-input form mode) replace every flat `<select>` of places: bulk move of
items and categories, the trash dialog's "move items to…", the category form's
parent and Move, the import's target catalogue and category, the export's
catalogue checklist, and "Move to folder" on the index. `ItemLocation` now
builds on `PlaceTree`. `check_parent_catalogue` refuses setting a trashed parent.

## Findings

### BUG - MEDIUM — New category: a URL parent the tree does not offer made Save do nothing (fixed)

`CategoryFormLive.mount_category_form/5` took `?parent_uuid=` as the pick
without checking it against `parent_tree`. That check existed in
`refresh_trees/1`, but only ran on PubSub. For a parent trashed since the link
was rendered, a category of another catalogue, or a non-UUID, the picker
showed nothing picked while its hidden input still posted the uuid.
`create_category` then failed on `:parent_uuid`, a field the form renders no
error for, so Save silently did nothing. The old `<select>` with no matching
option posted the root.

**Fix:** `offered_parent/3` drops a pick the tree lacks to the top level. Mount
and `refresh_trees/1` both use it. Test: all three URL shapes start at `root`
and save at the top level.

### BUG - MEDIUM — New category: its catalogue deleted forever crashed the form (fixed)

On the `:catalogue` broadcast, `refresh_trees(:new)` passed
`get_catalogue/1`'s `nil` to `PlaceTree.categories/2`, which raised
`FunctionClauseError`. The LiveView crashed, then recovered by redirecting.

**Fix:** `parent_tree(nil, _)` returns `[]`. Test: after
`permanently_delete_catalogue` the view stays alive with an empty tree.

### IMPROVEMENT - MEDIUM — subtree pruning missed live rows under a trashed parent (fixed)

`PlaceTree.prune/2` removes what hangs under the pruned row *in the live tree*.
A live category restored on its own under a trashed parent (A › B trashed › C)
is shown at the top level, so it escaped the prune. Moving A, or trashing A
with "move items to…", then offered C. The context refused the pick
(`:would_create_cycle` / `in_subtree?`), so no data was corrupted, but the
admin got a target that errors. The removed `list_move_target_categories/1`
used the DB subtree and did not have this gap.

**Fix:** a new `Catalogue.category_subtree_uuids/1` returns the DB subtree
through trashed rows, as text, ignoring non-UUIDs. The detail page's
`category_move_tree` / `trash_tree` and the category form's `move_tree` now
prune with it. Tests cover the context function, both detail-page trees and the
form's tree.

### IMPROVEMENT - MEDIUM — Export: a stale form post could undo a tick (fixed)

The selection came from two sources: the picker's message and the hidden
inputs `change_form` posts. A destination or format change sent before a tick's
re-render reached the browser carried the previous ticks and overwrote the new
selection.

**Fix:** the picker message is now the only source, and `apply_form_params/2`
no longer reads `catalogue_uuids`. Test: a `change_form` with stale ticks keeps
the picked selection.

### IMPROVEMENT - MEDIUM — dead `catalogue_categories` query in ImportLive (fixed)

After the flat category options were removed, the template stopped reading
`@catalogue_categories`, but every entry to the map step still ran
`list_categories_for_catalogue/1`. The assign and the query are gone, and the
helper is renamed `assign_import_category_tree/1`.

### IMPROVEMENT - MEDIUM — the category edit form builds the cross-catalogue move tree eagerly (not changed)

`move_tree/3` runs in mount (so twice) and on every module-wide
`:category | :catalogue | :folder` broadcast. It now does one more query for
the DB subtree. The Move section is a collapsed `<details>`, and the item form
already loads its Location tree only when the picker opens. It was left eager
because the Move section owns its open state on the client (pinned by a test),
so a lazy load needs a server round-trip on open, a larger change than a
review fix. At current catalogue counts the cost is a few indexed queries.
Worth doing if the edit form shows up in page timings.

### NITPICK — orphaned comments (fixed)

Four comments survived their functions and sat above unrelated ones:
`safe_return_to/1`, `current_folder_place/2`, `catalogue_tree/3`, and
`resolve_import_category`'s (it had drifted above `mapping_blocker/1`). The
dead ones are removed and the others moved back or rewritten.

### NITPICK — gettext pins partial (fixed)

Only 4 of the PR's 9 new msgids were pinned. `"top level"`, `"Select all"` and
the import category prompt are now pinned too. All 9 were already present in
`default.pot` and every `.po`.

### NITPICK — the item form's Location tree was not localized (fixed)

`ItemLocation.tree/1` called `PlaceTree.places/1` with no `:locale`, while
every new picker passes one. It now takes the locale
(`ItemLocation.tree/2`, default `nil`), and the item form passes
`current_locale`. This predates the PR.

### NITPICK — `list_move_target_categories/1` now unused in `lib/` (not changed)

It is still a public, documented function of the context, so it is kept rather
than removed in a minor release.

### NITPICK — PlacePicker multiple mode: quadratic `branch_check/2` (not changed)

Each non-pickable row does a full-tree `find` per render. This is pure CPU and
only the export's folder rows reach it. Acceptable at current sizes.

## Checked and fine

- **Kind:** item and category moves build `PlaceTree.places(catalogue.kind)`.
  The context refuses a kind mismatch under the lock, and
  `ItemLocation.resolve/2` re-checks at save.
- **Trashed rows** are excluded by all three tree sources, with orphan
  promotion.
- **Forged picks:** `PlacePicker` checks `pick` / `pick_all` with `member?`,
  the LVs re-check against the stored modal tree, and the context re-checks
  under locks.
- **URL uuids** reach only `PlaceTree.find` (pure) or the context getters, so
  there is no `CastError` path.
- **`handle_info` catch-alls** are present on every touched LV (ExportLive
  gained one).
- **Folder move** prunes the moved folder's own branch.
- **Import:** a trashed catalogue is refused at Run, "An existing category"
  with nothing picked is blocked, and a stale category pick is dropped when the
  catalogue changes.
- **PlacePicker inside forms:** the search input has no `name`, and the hook
  stops `input` / `change` / Enter.
