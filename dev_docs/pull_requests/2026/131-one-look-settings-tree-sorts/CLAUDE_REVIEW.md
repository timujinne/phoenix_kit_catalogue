# PR #131: One look for every catalogue screen; right-click rows; Settings → Catalogue; trees under every sort — Claude review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/131
**Author**: @mdon (Max Don)
**Reviewer**: Claude Opus 5 — post-merge pass
**Date**: 2026-09-21
**Merge**: `1c4cc9b` (`f774359..7c3fe05`), 53 files, +4008 / −830
**Status**: reviewed; 4 findings fixed with regression tests, the rest on record; released as 0.43.0

## Scope

1. **One controls row** for every catalogue screen: tabs on the left, the table's
   own controls on the right, with one search box and counted status tabs
   (`Shared.list_controls_row`, `status_tab`, `search_width_class/0`).
2. **Right-click a row** for its `⋮` menu (`data-row-menu-context`, core's
   `RowMenu`), switchable from the new settings page.
3. **Settings → Catalogue** (`Web.SettingsLive`, `settings_tabs/0`): the
   right-click switch, the item form's slug/SEO switch, and the whole
   AI-translation sweep, which had no UI until now.
4. **Trees under every sort**: the folder tree and the category tree keep their
   structure outside Manual order, sortable column headers, drag only in Manual
   order, and a drag stranded by a patch is ended (`CatalogueTreeDnD.updated`).
5. **The owner's nine**: renaming a folder from inside it, distinct names for new
   folders, the Edit button editing the place you are in, the current place's
   picture, the preview column, edit forms opening on the viewing language, no
   delete on edit screens, slug/SEO hidden by default, and `only_trashed:` on
   delete-forever so it refuses a row restored in another tab.

## Findings

### 1. BUG - HIGH: the PR uses core attributes that the lock doesn't have (fixed)

`table_default`'s `card_context_menu` (`pdf_library_live.ex`, `components.ex`)
and `sort_selector`'s `label` (`table_toolbar.ex`) first ship in core
**2.35.0**. `mix.lock` still pinned 2.34.0. So `mix compile
--warnings-as-errors --force`, and therefore `mix precommit`, failed with
"undefined attribute" on a fresh checkout. `mix test` still passed, because an
unknown attribute is only a warning.

**Fixed:** `mix deps.update phoenix_kit`, so the lock is now 2.35.0 (on Hex).
**The floor stays at `>= 2.34.0`, deliberately.** On a 2.34 host nothing
crashes: right-clicking a *card* opens the browser's own menu and the sort
selector loses its label, and rows are unaffected. Raising the floor for a
cosmetic degradation would be the proactive tightening we avoid. The
requirement is recorded in the 0.43.0 CHANGELOG entry instead.

### 2. BUG - MEDIUM: the Active tab shows the wrong count in the Deleted view (fixed)

`active_tab_count/1` counted `catalogue_rows + folder_tree`. In the Deleted
view, `load_data(:index)` fills `catalogue_rows` with the **trashed**
catalogues, so with 20 live catalogues, 3 folders and 2 in the trash, the tab
read "Active (5)".

**Fixed:** `load_data` keeps the live catalogues in their own
`active_catalogues` assign in both views, the way it already kept the deleted
rows, and the count reads from it. Its comment now says what it counts: the
whole index, narrowed by the search. Test: `catalogues_live_test.exs`, "Active
tab and Reorder all while the Deleted view shows".

### 3. BUG - MEDIUM: "Reorder all" in the Deleted view renumbers only the trashed catalogues (fixed)

The button, `open_catalogues_reorder_modal` and `apply_catalogues_reorder` were
all gated on `folder_tree == []` only. In the Deleted view they re-indexed the
trashed rows into 1..N, colliding with every live row's position. That is the
duplicate-`position` corruption the handler's own comment warns about. The
defect is older than this PR, but the shared controls row now renders it in
both views.

**Fixed:** one `reorder_all_offered?/1` (no folder tree *and* the Active
view) gates the button and both handlers. Test: a pushed apply in the Deleted
view leaves every position alone.

### 4. BUG - MEDIUM: a new item's slug froze on the first keystroke, now out of sight (fixed)

`apply_slug/2` treated the slug already in the changeset, and the value the
slug input echoed back, as the user's own. `Slugs.maybe_generate/3` only
fills a blank slug, so the first debounced validate fixed it: validate "Bi",
then save "Birch board", and the stored slug was `bi`. The bug is older than
this PR. What changed is that the slug input is now **hidden by default**, so
nobody could see or correct the value (the AGENTS.md "stale echo freezes a
derived field" landmine).

**Fixed:** the form tracks what it generated in `:derived_slug`. An entry
equal to it, whether from the changeset or echoed by the input, is dropped
before generating again, so the slug follows the name until someone types
one. The tracker resets after a stay-save, so a stored slug stops following
the name. Tests in `item_seo_fields_test.exs`: the hidden form follows the
name; a slug the person typed stays theirs.

### 5. IMPROVEMENT - MEDIUM: a Folder sort orders nothing inside the tree (fixed)

Each tree level holds catalogues from one folder, so sorting by Folder kept
whatever order `catalogues_by_folder` returned while the header showed an
active sort. **Fixed:** `catalogue_level_sort/1` sorts one level by name, in
the requested direction, when Folder is picked.

### 6. IMPROVEMENT - MEDIUM: SEO edits on a formerly multilingual record, single-language install (not fixed)

`seo_value/2` reads through `Multilang.get_primary_data/1`, which follows
`_primary_language` into a nested map when `data` still has one (languages were
on once, then turned off). `merge_seo_params/2` writes flat `data["_seo_title"]`,
so an edit lands at the top level while the form keeps reading the stale nested
value. It needs a record that crossed a multilang on→off switch *and* the
hidden-by-default fields turned on, so it is left on record rather than
threading `put_language_data` through both forms now.

### 7. NITPICK: turning the sweep on reports "Saved." even if its first tick was not scheduled

`update_sweep_enabled/1` ignores `ensure_scheduled/0`'s `{:error,
:schedule_failed}` (Oban down, for example). The flag is stored, and the
boot-time `ensure_scheduled_if_enabled/0` seeds the chain on the next start, so
the setting heals. Changing the interval also does not move a tick that is
already queued, so one tick keeps the old spacing. Left alone.

### 8. NITPICK: smaller items, on record

- The catalogue View card opened from the level picture (`show_catalogue_card`
  on the detail page) edits without `return_to`; the category card beside it
  carries one.
- The detail page's `:detail_categories` sort-change `handle_info` copies
  `apply_categories_sort/3` minus the persist and broadcast. Split it into a
  shared helper before the copies drift apart.
- An item whose own `_primary_language` differs from the global one is reset by
  `adjust_multilang_for_item/2` after `open_on_viewing_language/2`, so those
  items still open on their primary tab.
- `components.ex`: the `search_input` comment still says the box "grows to fill
  its group", which contradicts `search_width_class/0`, and the moduledoc
  example omits the now-required `id`.
- "Danger zone" is still a msgid in `default.pot` and every `.po`, with no
  caller left in `lib/`.
- AGENTS.md's settings table claimed to list every key but lacked
  `catalogue_item_seo_fields_visible` (added).

## Checked and fine

- **Delete forever vs restore.** `only_trashed: true` re-reads the row under the
  catalogue lock for catalogues, categories and items. `:not_in_trash` has its
  `Errors.message/1` clause and pin.
- **Folder rename from inside.** It requires `renaming_folder == uuid` (the
  blur after Enter is a no-op) and an active folder, through `get_folder`.
- **Header sort.** The `toggle_sort*` handlers refuse `"position"` and unknown
  keys and have catch-alls. Headers are plain labels in Manual order. Drag is
  refused server-side outside Manual order (`catalogues_reorderable?` /
  `categories_reorderable?`).
- **Hidden slug/SEO inputs** post the stored values under the same names, so a
  save keeps them. A secondary tab does not copy primary SEO text into its
  language.
- **Viewing language.** Only applies on edit. Core keeps the primary `name`
  on a secondary tab, so required-field validation holds.
- **Delete removal** from the edit screens leaves no dead handlers or assigns.
- **Settings page.** A crafted language list is filtered to enabled languages,
  and every read goes through `Web.Settings`. The tests' settings writes roll
  back with the sandbox, since the settings cache is not started under test.
- **Gettext.** Every new msgid is in `default.pot` and all five locales.
- **Tests.** 3319 green before the fixes. `mix precommit` clean after them.
