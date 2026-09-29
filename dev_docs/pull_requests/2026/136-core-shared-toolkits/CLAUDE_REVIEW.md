# PR #136 — Run on core's shared toolkits and ai's sweep engine, with the category-lock and form fixes

- **Author:** Max Don (`mdon/main`)
- **Merged:** 2026-09-23 (`8e0932f`; commits `4abe67c..be561c7`)
- **Reviewer:** Claude (post-merge)
- **Scope:** 71 files, +2141 / −4204. Actor, activity logging and edit
  languages move to core (`PhoenixKitWeb.Actor`, `PhoenixKit.Activity.log/3`).
  The place pickers move to core's `TreePicker` with `Utils.Tree` and
  `TreeQuery`. Attachments, uploads and the media reorganizer move to core's
  `ResourceFolders`, `PhoenixKitWeb.Attachments` and `ResourceSource`.
  Per-user table and selector choices move to core's `Users.ViewPrefs`, with
  migration V3 copying the old `custom_fields` configs. The translation sweep
  now runs on `PhoenixKitAI.TranslationSweep`. Category re-parents now take
  the catalogue lock before any row lock. The category form's places are
  fixed, and forms no longer clear an image or order they never knew about.

## Verified

- **Lock order.** Every path that re-parents or moves a category takes the
  catalogue advisory lock before any `FOR UPDATE` on a category row:
  - `update_category` when re-parenting;
  - `do_move_category_under`;
  - `move_category_to_catalogue`, which locks both catalogues in sorted order;
  - trash, restore and permanent delete.

  Each re-checks the catalogue under the lock and retries on
  `:catalogue_moved`. The cycle check runs under the lock. Duplication's name
  lock is followed by the catalogue lock, and no path takes them in the
  opposite order.
- **Core `Tree` / `TreeQuery` match the removed local code.** The root is in
  its subtree and not among its ancestors, and trashed rows are still inside
  the CTE. The prefix is carried through `Category`'s schema prefix. A
  non-UUID input now returns `[]` rather than raising `CastError`, which is
  an improvement.
- **TreePicker call sites.** Every call site passes `pickable`. Every one
  with `name` passes `post={&PlaceTree.post/1}`. Every LiveView handles
  `{TreePicker, id, value}` for the pickers it renders and re-checks the pick
  against live data.
- **Attachments port.**
  - Every core call (`resolve`, `ensure`, `name_pending`, `detach`, `attach`,
    `list_files`, `files_query`, `write_pointer`, `claimed?`, `parent_hook`)
    exists with the arity, options and return shape used.
  - The owner key is always `:phoenix_kit_catalogue`.
  - The removed public functions have no callers left.
  - The detach rules match the old local ones: nothing is hard-deleted.
- **V3 copy.**
  - It is guarded by both the table's presence and the
    `catalogue_view_prefs_copied_at` row, so a replay changes nothing.
  - The scopes match `TableConfig.scope()`.
  - The merge `EXCLUDED.prefs || existing.prefs` keeps a field already in
    core and adds the legacy fields a row lacks.
  - The field names match what `ViewConfig` and `TableColumns` read.
  - No `DROP` or `DELETE` statements, so the ownership test holds.
- **The sweep worker implements `TranslationSweep`'s callbacks.** Name,
  arity and return shape all match. The tick args are still `%{}` with the
  same uniqueness, so jobs already scheduled still decode.
- **Gettext.** Both new msgids are in `default.pot` and all five `.po`
  files, and both are pinned. The removed msgids have no callers.
- **Suite.** It runs green against the local core and ai checkouts
  (`PHOENIX_KIT_PATH`, `PHOENIX_KIT_AI_PATH`): 3409 tests, 0 failures after
  the fixes below.

## Findings

### 1. BUG - CRITICAL — `main` does not build against any published core or ai (not fixed here: release blocker)

The PR calls modules that exist only on unreleased branches:

- **Core.** `PhoenixKitWeb.Actor`, `PhoenixKit.Activity.log/3`, `TreePicker`,
  `Utils.Tree`, `TreeQuery`, `Storage.ResourceFolders`,
  `Reorganizer.ResourceSource`, `PhoenixKitWeb.Attachments`,
  `PhoenixKit.Utils.Format`, `Users.ViewPrefs`, `PhoenixKitWeb.TableColumns`,
  `mount_multilang(open_on:)`, and migration V201's
  `phoenix_kit_user_view_prefs`. These came from core #860, which is merged
  on core `main` but listed under "Unreleased". Core's `@version` is still
  2.37.5, and `v2.37.5` does not contain it.
- **phoenix_kit_ai.** `PhoenixKitAI.TranslationSweep` came from ai PR #29,
  which was merged after the 0.23.2 bump, so no tag contains it.

Against the locked Hex deps (core 2.37.5, ai 0.23.2),
`mix compile --warnings-as-errors` fails with undefined-module warnings. A
host would raise `UndefinedFunctionError` on the first form mount,
`actor_opts/1` call, `ViewConfig` load or sweep tick. None of these calls is
feature-detected, and core's CHANGELOG asks modules that keep an open pin to
feature-detect `Activity.log/3` and `Actor`.

The floors are still `phoenix_kit >= 2.34.0` and `phoenix_kit_ai ~> 0.18`.
Every version they admit fails to compile.

**Required before the next release:**

1. Publish core with #860 and phoenix_kit_ai with `TranslationSweep`.
2. Raise `:phoenix_kit`'s floor to that core release. Keep the compound
   `>= X and < 3.0.0` form, and update the `mix.exs` comment and
   `test/core_pin_conformance_test.exs` (`@must_admit` / `@must_reject` and
   the moduledoc).
3. Raise `:phoenix_kit_ai` to the release carrying `TranslationSweep`.
4. Run `mix deps.get` to relock.

This is not tightening a constraint for its own sake: the code does not
compile on anything below those versions.

**Not changed here.** The versions do not exist yet, so the pins are left
as they are.

### 2. BUG - HIGH — after a save that keeps the form open, clearing the featured image did not persist (fixed)

Commit be561c7 made a form write a clear marker (`featured_image_uuid: nil`
or `media_order: nil`) only when it "knew" a value. It judges that from
`:featured_image_at_mount` / `:media_order_at_mount`, which only
`mount_attachments/3` sets. A stay-save never re-mounts, so those baselines
stayed at the form's opening state. `:attachments_resource` and
`:media_order_persisted` went stale the same way.

**Scenario.** Open a record with no image, pick X, and Save (stay). Then
clear the image and Save again. No marker is written, so the form shows no
image while the record and the product card keep X. A removal of X that only
detached a link also compared against the stale resource and left the
pointer in place.

**Fix.** A new `Attachments.after_save/2` re-baselines all four assigns from
the saved record. The item, catalogue and category forms call it from
`refresh_after_edit/2`.

**Test.** `test/web/attachments_lv_test.exs` "an image picked and saved here
can be cleared by the next save": it picks, saves, clears, saves, and checks
that the key is gone. It fails without the fix.

### 3. BUG - MEDIUM — the category form could file the category row back into its old catalogue (fixed)

The edit form's Save and validate posted the `:catalogue_uuid` assign.
`move_to/2` re-read the category, which may have moved to another catalogue
since the page loaded, and assigned it without the matching
`:catalogue_uuid`. The changeset was then built on the fresh row (catalogue
B) with the stale assign (A).

**Scenario.** A bulk cross-catalogue move takes the category from A to B.
The admin then moves it to B's top level in the form and presses Save. The
row goes back to A while its children and items stay in B.
`validate_parent_in_same_catalogue` passes because the parent is nil.

**Fix.**
- An edit now posts the category's own `catalogue_uuid`
  (`form_catalogue_uuid/1`), so Save can never change it; only a move moves
  a category between catalogues.
- `move_to/2` assigns `:catalogue_uuid` alongside the re-read category.

**Test.** `test/web/category_form_places_test.exs` "Save after a move made
elsewhere keeps the category where it is". It fails without the fix.

### 4. IMPROVEMENT - MEDIUM — a bulk move did not refresh the category form's place (fixed)

`refresh_placement/1` ran only for a broadcast naming this category.
`bulk_move_categories_under` and the bulk cross-catalogue move broadcast
`(:category, nil, …)`. After one, the Move picker kept its old "current",
and picking the real place staged a no-op move that still flashed "moved".

**Fix.** A category broadcast with no uuid now re-reads the placement, for
an existing category only.

**Test.** "a bulk move re-reads the form's place". It fails without the fix.

### 5. IMPROVEMENT - MEDIUM — the item selector still re-read the user on every open (fixed)

`refresh_user/1` ran `Auth.get_user!/1` at every selector init. It guarded
against a stale `custom_fields` snapshot, but the selector's choices now live
in `ViewPrefs` and are read fresh by uuid. So it was a wasted query per open.
Its `rescue` also cannot catch a DB-ownership `:exit`: one full-suite run
crashed `SelectorHostLive` at that line, and the failure did not reproduce
on three reruns.

**Fix.**
- Removed `refresh_user/1` and the `Auth` alias.
- The moduledoc no longer says the choices live in `custom_fields`.
- The existing "REFRESHED user" test still passes, because `ViewPrefs`
  writes per field.

### 6. NITPICK — `update_category` moved a category to the top level without the catalogue lock (fixed)

`reparenting?/2` returned `false` for a new parent of `nil` or `""`, so
`update_category(cat, %{parent_uuid: nil})` skipped the lock that
`move_category_under(cat, nil)` takes. There is no cycle risk, but that path
slipped past the lock that trash and restore decide the subtree under. Any
change of parent now counts as a re-parent.

### 7. NITPICK — V3's "waits for a later run" overstated when that run happens (reworded)

A host replays the module chain only while a later version is pending
(`MigrationModules.pending/1`). So a copy skipped because core's table was
missing waits for V4, not for the next `mix phoenix_kit.update`. On the
normal path core's chain runs first in the same update, so the table is
there.

The comment and the test name now say this. AGENTS.md said the copy "guards
on the stored marker"; it guards on the `catalogue_view_prefs_copied_at`
row, and AGENTS.md now says so.

### 8. NITPICK — stale references and dead code (fixed)

- Three comments still named `Attachments.inject_featured_image/2`, which is
  now private and takes three arguments. They now point to
  `inject_attachment_data/2`.
- `legacy_folder_name/1`'s comment named the reorganizer as its caller; only
  `Duplication` calls it now.
- Two pre-existing dead items were removed:
  - `defdelegate category_subtree_uuids/1`: it was shadowed by the earlier
    `def` of the same name and arity, and returned raw binaries rather than
    text.
  - `Tree.descendant_uuids/1`: it had no callers, and it subtracted a text
    uuid from raw binaries, so the root was never removed.

### Not changed

- **NITPICK.** `Attachments.only_option/1` honours only one of `:file_type`
  and `:exclude_file_type` when both are passed. The old code applied both.
  No caller passes both.
- **NITPICK.** The import catalogue picker keeps `path_skip={[]}`, so its
  path shows folders. This matches its explicit pre-PR setting, so it is
  left alone.
- **IMPROVEMENT - MEDIUM.** `attachments_api_test.exs`'s placement cases now
  call core's `ResourceFolders.place_stored/2` directly, so they re-test
  core. The catalogue's own upload path is covered end to end by the new
  `item_form_upload_test.exs`.
- **NITPICK.** `ActivityLog` now lets core log "Activity logging error" when
  the activities table is missing, where the old code stayed silent. It
  still never raises. This is log noise only.
- **Pre-existing.** `attachments_lv_test.exs` "remove_file when the file
  exists … trashes it" passes vacuously: `files_folder_uuid` is nil at that
  point, so it takes its `assert true` branch. Its raw `INSERT` would also
  now fail on the NOT NULL `ext` / `file_checksum` columns. The new test
  above uses `Storage.create_file/1` instead.
