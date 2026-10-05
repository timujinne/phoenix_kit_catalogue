# PR #131 — One look for every catalogue screen; right-click rows; Settings → Catalogue; trees under every sort — follow-up

Triage of `CLAUDE_REVIEW.md` (7 numbered findings plus 6 small items under finding 8) against `main` at `e8a969f` (0.46.1). The list pages' toolbars were reworked after this review (View options / Filters pop-ups, the bulk bar under the list); each item below was re-checked against the current code, and none turned out to be about markup that is gone.

## Fixed (pre-existing)

- ~~1. BUG HIGH — the PR used core attributes the lock did not have (`card_context_menu`, `sort_selector`'s `label`, core 2.35.0): the lock is at 2.41.2 (`mix.lock:69`) and the floor has since moved to `>= 2.38.0` (`mix.exs:132`, commit `45e7d6e`), so the "floor stays at 2.34" caveat no longer applies either — lock first moved in commit `2bd1bb1`.~~
- ~~2. BUG MEDIUM — the Active tab showed the wrong count in the Deleted view: `load_data` keeps the live rows in their own `active_catalogues` assign (`lib/phoenix_kit_catalogue/web/catalogues_live.ex:461-475`) and the count reads from it (`:766-770`). Pinned by `test/web/catalogues_live_test.exs:1124` — commit `2bd1bb1`.~~
- ~~3. BUG MEDIUM — "Reorder all" in the Deleted view renumbered only the trashed catalogues: one `reorder_all_offered?/1` (`catalogues_live.ex:1209`) gates the button (`:3426`) and both handlers (`:2399`, `:2415`) — commit `2bd1bb1`.~~
- ~~4. BUG MEDIUM — a new item's slug froze on the first keystroke, out of sight: the form tracks what it generated in `:derived_slug` (`lib/phoenix_kit_catalogue/web/item_form_live.ex:367-375`, `:751-760`) — commit `2bd1bb1`.~~
- ~~5. IMPROVEMENT MEDIUM — a Folder sort ordered nothing inside the tree: `catalogue_level_sort/1` sorts a level by name when Folder is picked (`catalogues_live.ex:1250-1258`) — commit `2bd1bb1`.~~
- ~~8 (sixth item). NITPICK — AGENTS.md's settings table lacked `catalogue_item_seo_fields_visible`: listed at `AGENTS.md:331`.~~

## Skipped (with rationale)

None.

## Files touched

None — triage only, no code changed.

## Verification

Each finding re-read against `main` at `e8a969f` on 2026-10-05 (grep + reading the cited lines; `git log -S` for the commits). `mix precommit` and `mix test` were not run in this pass — nothing was changed.

## Open

Awaiting Max's decision:

- **6. IMPROVEMENT MEDIUM — SEO edits on a formerly multilingual record, on a single-language install, do not show.** `lib/phoenix_kit_catalogue/web/item_form_live.ex:428-431` (and `lib/phoenix_kit_catalogue/web/category_form_live.ex:801-803`): `seo_value/2` reads through `Multilang.get_primary_data/1`, which follows `_primary_language` into a nested map when `data` still has one, while `merge_seo_params/2` / `put_seo_field/3` write flat `data["_seo_title"]` (`item_form_live.ex:456-477`, `category_form_live.ex:390`). The edit is stored at the top level and the form keeps showing the stale nested value. Needs a record that crossed a multilang on→off switch and the hidden SEO fields turned on. Fixing means writing the two fields where the reader looks (through core's `put_language_data` for the primary language) in both forms, with a test on a record holding a nested `data`.
- **7. NITPICK (partially fixed) — turning the sweep on reports "Saved." even when its tick was not scheduled.** `lib/phoenix_kit_catalogue/web/settings.ex:107`: `update_sweep_enabled/1` still discards `TranslationSweepWorker.reschedule()`'s `{:error, _}` and returns `{:ok, setting}`. The setting heals on the next boot. The review's second half is fixed: an interval change now moves the waiting tick (`settings.ex:130`). Fixing the rest means returning the scheduling error (or a distinct flash) from `update_sweep_enabled/1` and showing it in `SettingsLive`'s `save/3`.
- **8a. NITPICK — the catalogue View card on the detail page edits without `return_to`.** `lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex:895`: `card_edit_path` is a bare `Paths.catalogue_edit(catalogue.uuid)`, while the category card beside it wraps its path in `with_return_to/2` (`:866-869`). Saving the catalogue from that card does not come back to where the person was. Fixing is wrapping the path in `with_return_to/2` with the page's current path, plus a test on the href.
- **8b. NITPICK — the detail page's categories sort-change `handle_info` copies `apply_categories_sort/3`.** `catalogue_detail_live.ex:539-555` repeats the assign-and-re-sort body of `apply_categories_sort/3` (`:6576-6588`) minus the persist and broadcast. Fixing means extracting the shared assign + `sort_categories` step into one private helper both call.
- **8c. NITPICK — an item whose own `_primary_language` differs from the global one still opens on its primary tab, not the viewing language.** `lib/phoenix_kit_catalogue/web/item_form_live.ex:340-341`: `mount_multilang(open_on: :viewing_language)` is followed by `adjust_multilang_for_item/2`, whose `check_item_primary_language/2` assigns `current_lang: item_primary` unconditionally (`:639-647`). Fixing means leaving `current_lang` alone there when the viewing language already picked a tab — a product call on which tab should win for such items.
- **8d. NITPICK — two stale texts in `components.ex`.** `lib/phoenix_kit_catalogue/web/components.ex:2005` — the `search_input` comment still says the box "grows to fill its group", which contradicts `search_width_class/0` (`:875`, `w-full sm:w-80`); and the moduledoc example at `:75` calls `<.search_input>` without the now-required `id` (`:1983-1984`). Fixing is rewording the comment and adding an `id` to the example.
- **8e. NITPICK — "Danger zone" is a msgid with no caller.** `priv/gettext/default.pot:802` (and every `.po`); a grep of `lib/` finds no use. Fixing means hand-deleting the entry from the `.pot` and the five `.po` files (the catalogue is hand-maintained), and any pin in `test/gettext_test.exs`.
