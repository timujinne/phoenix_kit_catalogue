# PR #124 follow-up

How each finding in `CLAUDE_REVIEW.md`, `GROK_REVIEW.md`, `ZAI_REVIEW.md` and
`VIBE_REVIEW.md` was resolved. Each finding was checked against the code first.
Codex was asked for the design round but had run out of quota, so there is
no Codex review.

## Design rounds (before the build)

- **Status of a copy.** Grok, Zai and Vibe all argued for "archived". The
  maintainer chose **same status as the original**. The dialog offers "Start
  the copy archived" (`:archived`), off by default.
- **SKUs.** All three said copy them verbatim, and a copy keeps them. The
  dialog can leave them out (`:skus`).
- **Slugs.** Grok said leave them empty; Zai and Vibe said generate them now.
  **Kept empty**, as item and category Duplicate already do. Slugs are unique
  across the whole table, and the edit form fills one on the next save.
- **Locking and snapshot.** Resolved differently from every proposal. The copy
  is one transaction that reads items first, then categories, once, under the
  source catalogue's trash/restore/move lock (`9b090f2`). Every item read
  therefore belongs to a category that already exists, and plain edits are
  not blocked. The copy runs in a supervised task, so leaving the page does
  not roll it back. It takes 0.67 s for 1000 items and 50 categories, so the
  inserts are not batched.
- **Shared files.** Copies link the source's files through `FolderLink`s; no
  bytes are copied. Removing a file from either catalogue removes only that
  catalogue's link, and the dialog now says so. Copying bytes is not offered.
  The dialog can leave files out (`:files`).
- **Foreign namespaces in `data`.** Two mechanisms:
  - a generic remap re-points any uuid that names another copied row;
  - the new optional `Extension.duplicate_data/2` hook lets the namespace's
    owner drop its external ids. Ecommerce implements it in
    BeamLabEU/phoenix_kit_ecommerce#58.
- **Shop resolves its catalogue by name.** A second copy is named
  "(copy 2)", and a trashed "(copy)" doesn't count as taken. Binding the
  shop by uuid is a shop-side change and out of scope.
- **Misses they listed:**
  - A live category under a trashed parent becomes top level.
  - A live item whose category isn't copied becomes uncategorized.
  - A double click or a remount can't start a second copy: the per-source
    try-lock refuses it with `:already_duplicating`.
  - A failed copy is reported with a flash.
  - Duplicate is offered for smart catalogues too; their rules keep
    pointing at the same standard catalogues.

## Fixed

- ~~Grok 2.1 / Zai 1: moving an item into a subcategory deadlocks with moving
  that subcategory's ancestor to another catalogue.~~ `b35d897`: the category
  move row-locks its whole subtree (uuid order, re-read until stable) before
  touching items. Grok's round 3 found no remaining cycle.
- ~~Grok 2.2: an item created, edited or moved into a subcategory during a
  category move keeps the old catalogue.~~ `b35d897`, as above. Probe on the
  dev server's live node: 68 of 150 rounds drifted before the fix, 0 of 150
  after.
- ~~Grok 2.3 / Zai 2a, 2b, 2c: a copy that reads per category can lose a
  subtree trashed mid-copy, copy a moved row twice, or copy a trashed root
  as live.~~ `b35d897` copies from one categories read and one items read;
  `9b090f2` reads items first under the source lock, so a trash or move
  waits for the copy. Live-node probe: 0 of 120 rounds failed.
- ~~Grok 3.1: `create_category` read its parent with a plain SELECT, so a
  subcategory created while its parent's tree moved stayed behind.~~
  `109bfbd` reads the parent `FOR SHARE` inside the insert's transaction.
  1 of 150 rounds before, 0 of 450 after. Older than this PR.
- ~~Grok 3.2: the two reads are two instants.~~ `9b090f2`, as above.
- ~~Zai 4.1 / 4.2: a selected subcategory is silently skipped when its
  selected parent fails to move, or was lifted out of it meanwhile.~~
  `b2df84e`: it moves on its own.
- ~~Zai 5.5 (first half): quadratic log lists in a category copy.~~ `b2df84e`.
- ~~Claude A1.1: a forged uuid crashed the catalogues page (Duplicate and
  trash).~~ `ab9b2eb`: the uuid is cast first. Tested.
- ~~Claude A1.3: a killed or throwing copy task never reported back, and a
  second Duplicate while one runs said nothing.~~ `ab9b2eb` runs the copy
  under `Task.Supervisor.async_nolink`:
  - `:DOWN` flashes "Failed to duplicate the catalogue.";
  - a second request flashes "This catalogue is already being duplicated.".
  Both are tested.
- ~~Claude A1.4: the rescues log too little, `inspect(other)` can log
  external ids, and `run_duplicate/3` misses throws and exits.~~ `ab9b2eb`:
  - the page logs the exception type and stacktrace, but not the message,
    which can carry form params;
  - the extension hook catches every kind of failure and logs its kind and
    type only;
  - a bad return is logged without its value.
- ~~Claude A1.5: category-form move errors not logged; generic message for
  `:parent_not_found`.~~ `ad159af`: both paths log and flash
  `move_error_message/1`.
- ~~Claude A1.6: bulk-move refusals not logged; stale log labels.~~
  `ad159af`.
- ~~Claude A1.7: the scope check in `bulk_move_categories_to_catalogue` was
  optional and skipped nested entries.~~ `ad159af`:
  - a scope is required;
  - every entry is checked against it in one read before anything moves.
  Tested.
- ~~Claude A1.8: forged-only crashes in `set_duplicate_choices` and the
  catalogue pickers.~~ `ab9b2eb`, `ad159af`. Tested.
- ~~Claude A1.9: a changeset could reach the bulk result's log.~~
  `ad159af`: a refused entry reports `:invalid`.
- ~~Claude A2.1: the copy's name used the backend's default language.~~
  Two parts:
  - `ab9b2eb`: the name column's suffix follows the content's primary
    language, which no longer depends on the process;
  - `f2cffb1`: the "Created" flash names the copy in the admin's language.
  Both tested.
- ~~Claude A2.2: no activity-log tests for the move actions; `archived` not
  pinned.~~ `ad159af`, `ab9b2eb`.
- ~~Claude A2.3: move error messages untested in the UI.~~ `ad159af`
  tests these:
  - "Category not found." (item form, trashed category);
  - "Parent category not found." (category form, deleted landing and
    refused reparent);
  - "Catalogue not found." (detail page, destination trashed after the
    modal opened).
- ~~Claude A2.4: the destination broadcast was untested.~~ `ad159af`.
- ~~Claude A2.5: in-flight guard, failure, `:not_found` and choices without a
  dialog untested; `:not_found` said "Not found.".~~ `ab9b2eb`. Tested.
- ~~Claude A2.6: the hook's nil and non-map returns, `duplicate_category`
  through the hook, and `files: false` on the catalogue row were
  untested.~~ `ab9b2eb`.
- ~~Claude A2.7: unoffered category-form value, option labels and the
  item's own place untested.~~ `ad159af`.
- ~~Claude A2.8: the open-state fix unpinned on the danger zone and meta
  section.~~ `ad159af`.
- ~~Claude A2.9: test smells.~~
  - `Process.alive?` is replaced by a state assertion.
  - Confirm and disposition now go through their rendered elements.
  - The cancel test now also asserts nothing is being tracked.
- ~~Claude A3.1: `valid_uuid?/1` accepted raw 16-byte binaries.~~
  `ad159af`: canonical strings only. Tested.
- ~~Claude A3.2: a stale item struct made "already there" wrong in the item
  form and the context.~~ `ad159af`:
  - the context decides from the locked row;
  - the form re-reads the item after a move.
  Tested.
- ~~Claude A3.3 / A1.2 (second half): a second copy held its source lock
  while waiting on the copy-names lock.~~ `ab9b2eb` takes the copy-names
  lock first.
- ~~Claude A3.4: dead bulk-move helpers, stale labels, misleading scope
  flash.~~ `ad159af`:
  - `bulk_move_items_to_category/3` is a wrapper over `bulk_move_items/3`;
  - the flash reads "Some selected items are no longer in this catalogue.
    Reload the page and try again.".
- ~~Claude A3.8: a three-level selection could detach a grandchild.~~
  `ad159af` moves the selection shallowest first. Tested.
- ~~Claude A3.9: an invalid `parent_uuid` said `:catalogue_not_found`.~~
  `ad159af`.
- ~~Claude A3.10: specs.~~ `ad159af`.
- ~~Claude A3.11: repeated broadcasts.~~ `ad159af` uses
  `broadcast_moved_out/1`.
- ~~Claude A3.12 (magic values): inline lock names and copy-number cap.~~
  `ab9b2eb` names them.
- ~~Claude A3.13: docs out of step.~~ `ad159af`, `ab9b2eb`.
- ~~Claude A3.14: the finish reload on another tab, the hard match on
  `start_child`, `:not_found` wording, attribute placement.~~
  `f2cffb1`, `ab9b2eb`.
- ~~Claude A4.1: ecommerce kept the Shopify collection id on category
  copies.~~ BeamLabEU/phoenix_kit_ecommerce#58, second commit.
- ~~Claude A4.2: a malformed extension registration crashed every copy.~~
  `ab9b2eb`:
  - registrations are filtered to atoms;
  - the copy-aware check rescues;
  - the hook catches throws and exits.
  Tested.
- ~~Claude A4.3: the ecommerce integration test failed instead of skipping
  on an older catalogue; no category coverage.~~ BeamLabEU/phoenix_kit_ecommerce#58.
- ~~Claude A4.4: an extension keyed like a language code (`"pos"`) would get
  its name suffixed.~~ `ab9b2eb` never suffixes extension-owned keys.
  Tested.
- ~~Claude A4 note: a single-category Duplicate didn't re-point references
  inside its subtree.~~ `ab9b2eb`. Tested.
- ~~Vibe 1 (partly): "Deleted items", "Removing one from the copy".~~
  - `5ef6bb0` uses "items in Deleted", the tab's own name.
  - `15e3379` rewrote the files hint: "Shared with the original, not
    duplicated. Removing one from either catalogue leaves the other
    untouched."
- ~~Vibe 4.1: warn that SKUs are copied.~~ `15e3379` adds a "Copy SKUs"
  choice.

## Found by the randomized test, not a reviewer

- ~~A restore that has to leave an item behind (its category still trashed
  under another root) kept the item's stamp naming the restored root, so a
  second trash and restore of that root brought it back under a trashed
  category.~~ `d9c5ff8`: such items join their category's unit. Seed 423352;
  older than this PR. Three tests.

## Declined, with reasons

- **Claude A1.2 (first half) / Zai 1 / Zai 5.4: a copy holds its source lock
  (and the copy-names lock) for its whole run.** Kept. A copy of 1000 items
  takes under a second, well inside the 15 s a waiting trash or move
  tolerates.
- **Claude A3.5: the kind check reads both catalogues without a lock.**
  Kept. The catalogue form can switch a catalogue's kind while it holds
  items, with no check at all, so a move racing that switch produces nothing
  a switch made just after the move wouldn't. Whether a non-empty catalogue
  may change kind is a separate product question.
- **Claude A3.6: move-option helpers repeated across the two forms; the item
  form's option labels repeat the catalogue name and load other-kind
  categories.** Left for a later cleanup. Behaviour is right and tested.
- **Claude A2.7 (last point): the item form's option names are not
  localized.** Older than this PR.
- **Claude A3.7: `Duplication` calls back into `Catalogue.lock_catalogue!/1`.**
  Kept. It is the context's one lock protocol; moving it is a refactor
  of its own.
- **Claude A3.12 (lock form): single-key `hashtext` locks.** Kept, and noted
  at the attribute. These names are only ever taken by this module.
- **Zai 3: the remap re-points any string equal to a copied row's uuid.**
  Documented in the `Duplication` moduledoc; no field meant to keep naming
  the original exists. Rules keep pointing at the catalogues they reference
  by design, and comment threads are created fresh.
- **Zai 5.1: the catalogue row skips the extension hook.** Kept.
  Extensions own namespaces on items and categories only; the moduledoc says
  so.
- **Zai 5.2: `"%{name} (copy %{number})"` is not in the `.pot`.** Refuted:
  it was added by hand to the `.pot` and every locale in `da871e4`, and is
  pinned.
- **Zai 5.3: a rename can collide with a copy's name.** Names are not unique
  by design; see the shop note above.
- **Zai 5.5 (second half): per-member row loads when ordering a nested
  selection.** Refuted: `load_uuid/1` converts a binary to a string and does
  not query. It is one subtree query per selected uuid.
- **Vibe 1 (rest):**
  - "(this catalogue)" is kept.
  - "Move to Another Parent" and "Move to Another Category" are existing
    headings in the forms' title case, unchanged here.
- **Vibe 3 / 4.2: a link to the copy, undo, and a dry-run preview for bulk
  moves.** Not built.

## Open

None.

## Release review (0.36.0)

How each finding in the "Release review (post-merge)" section of
`CLAUDE_REVIEW.md` was resolved.

- ~~A category move carried trashed rows stamped for a root it left
  behind.~~ Both `move_category_to_catalogue/3` and `move_category_under/3`
  now call `restamp_moved_trash!/3`. Any stamp in the moved subtree whose
  root is not the landing catalogue, an ancestor of the landing spot, or a
  row of the subtree is restamped the way Delete Forever restamps what it
  leaves behind; that logic moved out into `restamp_trash_roots/3`. Tested:
  - three cases in `moves_test.exs`;
  - the randomized run gains a `move_category_under` op and an invariant
    that every stamp's root still covers its row. Without the fix, that
    invariant fails at `TRASH_FUZZ_WORLDS=600 TRASH_FUZZ_STEPS=20`
    (seed 199947).
- ~~An upper-case uuid crashed the bulk item move.~~ `sanitize_uuids/1`
  keeps canonical uuids only, and `do_bulk_move_items/3` logs and flashes any
  other error. Tested.
- ~~The bulk category move checked its scope without a lock.~~
  `move_category_to_catalogue/3` takes `catalogue_uuid:` and refuses with
  `:wrong_catalogue_scope` under the row lock, so the batch broadcast names
  the real source. Tested.
- ~~Crash logs could carry values.~~ `:DOWN` logs the reason's shape only,
  and the stacktrace keeps argument counts, not arguments.
- ~~An extension `key/0` that throws or exits aborted every copy.~~
  `copy_aware?/1` and `valid_key?/1` catch every kind of failure, and the
  callback doc names every way a namespace is dropped. Tested.
- ~~A forged non-string `parent_uuid` crashed the category form.~~ Ignored.
  Tested.
- ~~A stale `step=` assertion after the entities 0.4.16 lock bump.~~ The test
  now pins the text + `inputmode="decimal"` control.
- Declined items are listed, with reasons, in the review.

Shipped in 0.36.0.
