# PR #136 — Run on core's shared toolkits and ai's sweep engine — follow-up

Triage of `CLAUDE_REVIEW.md` (Claude, post-merge). Eight numbered findings and five "Not changed" notes.

## Fixed (pre-existing)

- ~~1. BUG - CRITICAL — `main` did not build against any published core or ai.~~ The floors are `phoenix_kit >= 2.38.0 and < 3.0.0` (`mix.exs:132`, comment `:98-102`) and `phoenix_kit_ai ~> 0.24` (`mix.exs:140`); `test/core_pin_conformance_test.exs:41-42` admits 2.38.0+ and rejects 2.37.5; the lock holds core 2.41.2 and ai 0.24.1. Raised in the 0.45.0 release (`45e7d6e`), as PR #138's review records.
- ~~2. BUG - HIGH — clearing the featured image after a stay-save did not persist.~~ `Attachments.after_save/2` (`lib/phoenix_kit_catalogue/attachments.ex:870`) is called from all three forms' post-save refresh: `catalogue_form_live.ex:355`, `category_form_live.ex:790`, `item_form_live.ex:2881`. Test: `test/web/attachments_lv_test.exs:114`. Commit `5aabd98`.
- ~~3. BUG - MEDIUM — the category form could file the row back into its old catalogue.~~ `form_catalogue_uuid/1` (`category_form_live.ex:326-329`) feeds both validate and save (`:451`, `:476`), and `move_to/2` assigns `:catalogue_uuid` with the re-read category (`:547`). Test: `test/web/category_form_places_test.exs:80`. Commit `5aabd98`.
- ~~4. IMPROVEMENT - MEDIUM — a bulk move did not refresh the category form's place.~~ A `:category` broadcast with a nil uuid re-reads the placement for an existing category (`category_form_live.ex:644-646`). Test: `test/web/category_form_places_test.exs:104`. Commit `5aabd98`.
- ~~5. IMPROVEMENT - MEDIUM — the item selector re-read the user on every open.~~ `refresh_user`, the `Auth` alias and the `custom_fields` wording are all gone from `web/components/item_selector_modal.ex` (no matches).
- ~~6. NITPICK — `update_category` moved a category to the top level without the catalogue lock.~~ `reparenting?/2` now answers `not is_nil(current)` for a nil or empty new parent (`lib/phoenix_kit_catalogue/catalogue.ex:1945-1950`).
- ~~7. NITPICK — V3's "waits for a later run" wording.~~ The comment says a host replays the chain only while a later version is pending (`lib/phoenix_kit_catalogue/migrations.ex:298-303`); the test is named "a copy the chain skipped is made by a later replay of the chain" (`test/web/view_config_prefs_test.exs:179`); AGENTS.md names the `catalogue_view_prefs_copied_at` row.
- ~~8. NITPICK — stale references and dead code.~~ No comment names `inject_featured_image/2` any more (the only references are to the private `/3` inside `attachments.ex`); `legacy_folder_name/1`'s comment names `Catalogue.Duplication` (`attachments.ex:1032-1035`); `category_subtree_uuids/1` has one definition (`catalogue.ex:3161`); `descendant_uuids` has no match in `lib/`.

## Skipped (with rationale)

- **NITPICK — the import catalogue picker keeps `path_skip={[]}`.** The review left it because it matches the picker's explicit setting from before the PR. Unchanged: `lib/phoenix_kit_catalogue/web/import_live.ex:1840`, `:2070`.

## Files touched

None.

## Verification

Re-verified by reading `main` at `e8a969f` (0.46.1) on 2026-10-05 (quality sweep, Phase 1): each reference below was grepped and the lines read. No code changed, so no gate was run for this triage; `mix precommit` and `mix test` were not re-run.

The vacuous-test note below was read, not executed: whether `files_folder_uuid` is still nil at that point in the current test environment was not confirmed by a run.

## Open

Four notes the review recorded under "Not changed" still show in the code. Each is awaiting Max's decision.

- **NITPICK — `Attachments.only_option/1` honours only one of `:file_type` / `:exclude_file_type`.** `lib/phoenix_kit_catalogue/attachments.ex:1148-1155` is a `cond`, so the first present option wins, while the doc at `:1122-1125` says both older spellings are "still honoured". No caller in `lib/` passes either option today. Fixing it means either combining the two into one core `only:` filter or saying in the doc that they are exclusive.
- **IMPROVEMENT - MEDIUM — the placement cases re-test core.** `test/phoenix_kit_catalogue/attachments_api_test.exs:148-181` calls `ResourceFolders.place_stored/2` directly. The catalogue's own path is covered by `test/web/item_form_upload_test.exs`. Fixing it means deleting those cases or rewriting them through the catalogue's upload entry point.
- **Pre-existing — a test that passes without testing.** `test/web/attachments_lv_test.exs:209-247` ("remove_file when the file exists in the resource's folder trashes it") takes an `assert true` branch when `files_folder_uuid` is nil (`:215-218`), and its other branch uses a raw `INSERT` (`:226-234`) without the NOT NULL `ext` / `file_checksum` columns the review says would now fail. Fixing it means creating the folder and the file through `Storage.create_file/1`, as the test at `:114` does, and dropping the nil branch.
- **NITPICK — log noise when the activities table is missing.** `lib/phoenix_kit_catalogue/catalogue/activity_log.ex:44-50` hands every entry to core, which logs "Activity logging error" where the old local code stayed silent. It never raises. Silencing it would take a table-presence check before the call, or a change in core.
