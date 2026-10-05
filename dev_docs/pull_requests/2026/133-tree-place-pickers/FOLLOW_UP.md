# PR #133 — Pick every place in a tree — follow-up

Triage of `CLAUDE_REVIEW.md` (11 findings) against `main` at `e8a969f` (0.46.1).

## Fixed (pre-existing)

- ~~BUG MEDIUM — New category: a URL parent the tree does not offer made Save do nothing: `offered_parent/3` drops such a pick to the top level, at mount and in `refresh_trees/1` (`lib/phoenix_kit_catalogue/web/category_form_live.ex:132`, `:242-245`, `:283`) — commit `66ecf20`.~~
- ~~BUG MEDIUM — New category: its catalogue deleted forever crashed the form: `parent_tree(nil, _locale)` returns `[]` (`category_form_live.ex:225`) — commit `66ecf20`.~~
- ~~IMPROVEMENT MEDIUM — subtree pruning missed live rows under a trashed parent: `Catalogue.category_subtree_uuids/1` (`lib/phoenix_kit_catalogue/catalogue.ex:3161`) feeds the prune on the detail page (`lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex:2187`, `:3667`) and in the category form's `move_tree/3` (`category_form_live.ex:268`) — commit `66ecf20`.~~
- ~~IMPROVEMENT MEDIUM — Export: a stale form post could undo a tick: `apply_form_params/2` reads only destination and format (`lib/phoenix_kit_catalogue/web/export_live.ex:213-227`); the picker's message is the one source of `selected_catalogue_uuids` (`:71`). Pinned by `test/web/export_picker_test.exs:62` — commit `66ecf20`.~~
- ~~IMPROVEMENT MEDIUM — dead `catalogue_categories` query in ImportLive: no `catalogue_categories` assign or query remains in `lib/`; the helper is `assign_import_category_tree/1` (`lib/phoenix_kit_catalogue/web/import_live.ex:2776`) — commit `66ecf20`.~~
- ~~NITPICK — orphaned comments above `safe_return_to/1`, `current_folder_place/2`, `catalogue_tree/3` and `mapping_blocker/1`: each now sits under a comment that describes it or under none (`item_form_live.ex:219-221`, `catalogues_live.ex:1109-1110`, `import_live.ex:1078-1081`, `:1137-1142`) — commit `66ecf20`.~~
- ~~NITPICK — gettext pins partial: `"top level"`, `"Select all"` and the import category prompt are pinned (`test/gettext_test.exs:167-170`) — commit `66ecf20`.~~
- ~~NITPICK — the item form's Location tree was not localized: `ItemLocation.tree/2` takes the locale (`lib/phoenix_kit_catalogue/web/item_location.ex:47`) and the item form passes `current_locale` (`lib/phoenix_kit_catalogue/web/item_form_live.ex:884`) — commit `66ecf20`.~~

## Skipped (with rationale)

- NITPICK — PlacePicker multiple mode: quadratic `branch_check/2`. **N/A in this repo now.** `Components.PlacePicker` is gone — no `place_picker.ex` and no `branch_check` anywhere in `lib/`; the pickers run on core's `TreePicker` since the move to core's shared toolkits (floor 2.38.0, `mix.exs:97-101`). Whether core's `TreePicker` kept the same per-row full-tree `find` was not checked here — it is core's code and outside this folder's scope.

## Files touched

None — triage only, no code changed.

## Verification

Each finding re-read against `main` at `e8a969f` on 2026-10-05 (grep + reading the cited lines; `git log -S` for the commits). The orphaned-comments item was checked by reading the comment above each of the four named functions, not by diffing against the pre-fix tree. `mix precommit` and `mix test` were not run in this pass — nothing was changed.

## Open

Awaiting Max's decision:

- **IMPROVEMENT MEDIUM — the category edit form builds the cross-catalogue move tree eagerly.** `lib/phoenix_kit_catalogue/web/category_form_live.ex:149` (mount, so twice per page load), and again at `:289` (every module-wide `:category | :catalogue | :folder` broadcast), `:584` and `:789`; `move_tree/3` (`:260-269`) loads the place tree plus the DB subtree for a Move section that is a collapsed `<details>`. A few indexed queries at current sizes. Fixing means loading the tree when the section opens (a server event on open, as the item form's Location picker does) — the section's open state is client-owned and pinned by a test, so that test changes too.
- **NITPICK — `Catalogue.list_move_target_categories/1` has no caller left in `lib/`.** `lib/phoenix_kit_catalogue/catalogue.ex:3178-3179`; only `test/catalogue_test.exs:4742-4760` calls it. The review kept it as a public, documented function. Fixing means either deprecating it (`@deprecated` pointing at the place tree + `category_subtree_uuids/1`) or removing it with its tests — a public-API removal, so a release-note item.
