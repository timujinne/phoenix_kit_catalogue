# Follow-up Items for PR #78

Triaged 2026-08-24 against `main` (`3437621`, then the post-merge pass).
Reviewers: Codex (`CODEX_REVIEW.md`), Gemini (`GEMINI_REVIEW.md`), Grok
(`GROK_REVIEW.md`), ZAI (`ZAI_REVIEW.md`), four Claude triage passes
(`CLAUDE_REVIEW.md`). Every finding was re-verified before being acted on.

## Fixed (Batch 1 — 2026-08-24, commit 3437621)

- ~~Client-captured uuids without a catalogue scope~~ — `scoped_actor_opts/1` / `scoped_muted_actor_opts/1` pass the page's catalogue; `Catalogue.bulk_move_categories_under/3`, `Duplication.bulk_duplicate_*/2` refuse per entry (`:wrong_catalogue_scope`); `scope_item_uuids/2` / `scope_category_uuids/2` filter the item trash / restore / purge and category trash paths; `category_move_targets/2` drops foreign categories. Tests in `catalogue_detail_bulk_categories_test.exs` and `duplication_test.exs`.
- ~~KeyError on a closed modal~~ — nil-modal guard clause on all six handlers; test "modal events after the modal closed are no-ops".
- ~~Activity logged inside the Duplication transaction~~ — logs collected, written after commit (`flush_logs/1`); one `item.bulk_duplicated` / `category.bulk_duplicated` summary row; `parent_catalogue_uuid` moved into metadata.
- ~~Suffix in the actor's locale~~ — `suffix_language_entry/2` renders per language with `Gettext.with_locale`; test pins `"A-et (koopia)"`.
- ~~`bulk_select:clear` is a no-op in core's hook~~ — `bulk_epoch` is part of both scope ids and bumps after every bulk op, remounting the hook (the push stays for a core that handles it); test pins the remount. Core follow-up: add the handler to `BulkSelectScope`.
- ~~Future-dated row closed with an inverted window; stale-struct currentness check~~ (Codex) — `close_current/1` re-reads under `FOR UPDATE`, refuses a non-current row, closes on `max(today, valid_from)`; the activity row carries `"closed"` and `"valid_to"`.
- ~~`set_primary/2` accepts closed revisions~~ (Codex) — `{:error, :not_current}`.
- ~~`update/2` can re-point a row at another item/supplier pair~~ (Codex) — identity keys dropped from update attrs.
- ~~Unlocked sibling renumbering~~ — `lock_sibling_scope/3` (`pg_advisory_xact_lock` on the scope) before reading siblings.
- ~~N events from `bulk_trash_categories`~~ — one nil-uuid batch per catalogue; `surface_broadcasts_test` F13 updated.
- ~~Bulk error shapes~~ — `normalize_error/1` collapses changesets and tagged tuples to atoms.
- ~~Duplicated handlers / pickers / per-row calls / missing docs / silent rescue~~ — `flash_bulk_result/6`, `move_target_picker/1`, hoisted `page_path`, `@doc`+`@spec` on `item_edit_raw/2`, `Logger.warning` in `resolve_resources/1`.
- ~~`{:import_result, _}` after "Import another" yanks the fresh wizard~~ (ZAI) — guarded on `import_task: nil`; test added.
- ~~Test smells~~ — bulk-op event order pinned (bulk change before batch `:item`); the import-monitor test monitors a real process from inside the LiveView and asserts the monitor is released; the permanent-delete test pins the broadcast.

## Fixed (Batch 2 — 2026-08-24, post-merge release pass)

- ~~`trash_category(items: {:move_to, child})` parked live items in a deleted category~~ — context returns `:move_target_in_subtree`; the three modal pickers clamp select + confirm to offered targets; `request_trash_category` / `restore_category` refuse a foreign catalogue uuid.
- ~~`set_primary/2` / `revise_unit_cost/3` trusted a stale struct~~ — lock-reload under `FOR UPDATE`, refuse `:not_current`. `set_primary` now has the missing pin.
- ~~Category Duplicate did not lock the target parent~~ — `ensure_same_catalogue!/2` takes `FOR SHARE`, matching `catalogue_for/2`.
- ~~`Attachments.refresh_files/1` was a no-op without a folder pointer~~ — resolves the deterministic `catalogue-item-<uuid>` name (ZAI).
- ~~Item-form `delete` / `set_primary` / history ignored `owned_supplier_info/2`~~ — crafted uuid of another item's row is a no-op.
- ~~New error atoms and Duplicate activity actions unpinned~~ — `Errors.message/1` + `errors_test.exs` + `activity_logging_test.exs` + hand-edited catalogues.

## Not defects on verification

See `CLAUDE_REVIEW.md` "Not defects on verification" (cost-range currency grouping, nil min/max, search-results staleness, pending-window drop, prune broadcast, `valid_from`).

## Open — for Max to decide

- **Grok: SKU copied as-is** — every Duplicate yields two live rows with the same SKU (no unique index today). Blank it, suffix it, or keep?
- **Grok: files are linked, not copied** — a copy's files are `FolderLink`s to files homed in the source folder; purging the original's folder removes them from the copy too. Copy the file rows instead (physical storage stays shared)?
- **Grok: "(copy) (copy)" on re-duplicate** — count up ("(copy 2)") instead?
- **Codex (SUSPECTED): renumbering issues one `UPDATE` per sibling per copy** — M×N statements for a bulk of M in a list of N. Fine at admin scale; a single `UPDATE … FROM unnest(...)` is possible if it ever matters.
- **Gemini: `bulk_change_pending` is a boolean** — two overlapping bulk broadcasts within the flash window cut the second's fade short. Counter instead?
- **Search results render a fixed column set** (no Supplier price, no Columns config) — pre-existing; extend to `items_columns`?
- **Triage: PRO100 loader logs `mode: "manual"`, `actor_uuid: nil`** — pre-existing; thread `actor_uuid` / `mode: "import"` through `apply_plan/2`?
- ~~**ZAI: `Attachments.refresh_files/1` when THIS tab has no folder pointer yet**~~ — fixed in batch 2.
- **Codex: `surface_broadcasts_test` post-commit assertions are same-process** — cannot distinguish an in-transaction broadcast; needs a separate subscriber reading the committed row.
- **Test gaps still open**: attachments upload broadcast (needs `render_upload`), attribute-set / attribute-group copy in Duplication (entities-gated), the item form's stale-thread unsubscribe.

## Files touched

| File | Change |
|------|--------|
| `lib/phoenix_kit_catalogue/catalogue/duplication.ex` | post-commit logs, bulk summary, scope, lock, per-language suffix, error normalisation |
| `lib/phoenix_kit_catalogue/catalogue.ex` | scope on bulk move / trash / restore / purge; one batch event for trashed categories |
| `lib/phoenix_kit_catalogue/catalogue/item_supplier_infos.ex` | `close_current/1`, `set_primary/2` guard, immutable identity, close metadata |
| `lib/phoenix_kit_catalogue/catalogue/supplier_comments.ex` | warning in the resolver rescue |
| `lib/phoenix_kit_catalogue/paths.ex` | `@doc`/`@spec` on `item_edit_raw/2` |
| `lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex` | modal guards, scoped opts, `bulk_epoch`, `flash_bulk_result/6`, `move_target_picker/1` |
| `lib/phoenix_kit_catalogue/web/item_form_live.ex` | hoisted supplier page path |
| `lib/phoenix_kit_catalogue/web/import_live.ex` | abandoned-task result ignored |
| `test/…` | pins for each item above (bulk categories, duplication, live surfaces, surface broadcasts, pickers, duplicate) |

## Verification

Batch 1: `mix precommit` green; `mix test`: 2 doctests, 1927 tests, 0 failures. Deployed to max-dev.

Batch 2: see the post-merge commit; `mix precommit` + `mix test` re-run before the 0.19.0 publish.

## Open

See "Open — for Max to decide" above. SKU / shared files / "(copy) (copy)" stacking remain product calls.
