## 0.6.0 - 2026-06-04

### Added
- **AI translation for catalogue resources** (#32) — catalogues, categories, and items can machine-translate their `name` + `description` into the multilang `data` JSONB via core's shared AI-translation pipeline. A `PhoenixKitCatalogue.AITranslatable` adapter (registered through the new `ai_translatables/0` module callback for `"catalogue"` / `"catalogue_category"` / `"catalogue_item"`) handles fetch / source-field extraction / persist for all three resource types, and `PhoenixKitCatalogue.AITranslateBinding` supplies the form-side storage glue; the translate button, modal, progress bar, and "taking a while" hint render on each form LiveView. Per-language overrides are written under the multilang `_`-prefixed keys the form reads, and a result is **force-stored even when identical to the source** (a product code, text already in the target language) so a field never reads as a failed translation. No new `phoenix_kit_ai` dependency — the enqueue, AI call, retry policy, broadcasts, and audit log all live in core.

### Changed
- **Catalogue-detail status filter scoped to inside categories** (#32) — the category drill step is pure navigation, so the active / inactive / discontinued / deleted tab strip now renders only alongside an actual item list and only when more than one status is populated; a node auto-opens on its first populated status instead of an empty Active.
- **Item reorder affordances skip no-ops** (#32) — the drag handle is hidden for a single-item list and a same-position drop short-circuits the DB write / broadcast / flash. The handle's column space is reserved (empty spacer cell) so deleting down to one row doesn't shift the layout.
- **AI-translate LiveView glue delegates to core `FormGlue`** (#32) — ~570 lines of inline modal / dispatch / PubSub state collapsed into nine delegators plus the small catalogue-specific `AITranslateBinding`.
- **Quieter AI-translation writes** (#32) — the per-row resource PubSub fan-out is suppressed on AI-translation `update_*` writes (they run inside a `FOR UPDATE` transaction and would otherwise fire pre-commit and look like a user edit); the `broadcast: false` opt is now forwarded through `update_catalogue/3`, `update_category/3`, and `update_item/3` so it actually takes effect. Normal admin edits still broadcast.

### Quality
- Post-merge review of #32 (writeup in `dev_docs/pull_requests/2026/32-ai-translation-shared-glue/CLAUDE_REVIEW.md`): dropped a dead `_ = primary` discard; replaced a runtime `String.to_existing_atom/1` + `rescue` with a compile-time field→column map in the AI adapter; flattened `put_translation/4` nesting (extracted `merge_translation!/6`) and aliased a fully-qualified `Web.Helpers` call to satisfy `credo --strict`; expanded the adapter unit tests 10 → 15 (source-field override / legacy-key paths, catalogue + category round-trips). Also dropped a redundant `import Ecto.Query, warn: false` from the PDF library context.

### Notes
- **Requires phoenix_kit 1.7.130+** — the generic AI-translation pipeline this release plugs into (`PhoenixKit.Modules.AI.{Translatable,Translations}`, `PhoenixKitWeb.Components.AITranslate.{FormGlue,FormBinding}`; BeamLabEU/phoenix_kit#582) first shipped in core **1.7.130**. The `mix.exs` constraint stays loose (`~> 1.7 and >= 1.7.125`) — pin a `phoenix_kit >= 1.7.130` in the parent app. Catalogue compiles and `mix precommit` (compile `--warnings-as-errors` + `format --check-formatted` + `credo --strict` + `dialyzer`) is clean against 1.7.130.
- Verification: ExUnit suites are DB-gated and run against a host whose schema is at core V111+; the new adapter tests pass against a local core (not exercised in CI without a database).

## 0.5.0 - 2026-06-01

### Added
- **PDF viewer fallback** (#31) — a persistent **"Open"** link on the PDF detail page points at the always-present signed `/file/` route, so the document is reachable in the browser's native viewer even when the embedded `/_pdfjs` frame can't load. Pairs with a core router-served `/_pdfjs` fallback, but the catalogue side works independently.
- **PDF extraction self-heal** (#31) — `Catalogue.requeue_stuck_extractions/1` re-drives every `pending` extraction plus `extracting` rows orphaned past `:stale_after_seconds` (default 900), and `Catalogue.retry_extraction/2` resets a single row to `pending` and re-enqueues so a terminal `failed` row runs again. Surfaced in the UI as a per-row **Retry** button, a detail-page Retry on the failed alert, and a **"Retry stuck"** header action. New `pdf.extraction_retried` activity action. Both functions re-exported from `Catalogue` via `defdelegate`.

### Changed
- **App-level Oban enqueue dedup** (#31) instead of Oban's built-in `unique:` — satisfying the `unique` compile check forces listing `:suspended`, an `oban_job_state` enum value absent on hosts that upgraded the Oban *lib* ahead of its *migration* (querying it raises `22P02` and kills every enqueue). The app guard skips the insert when a non-terminal `PdfExtractor` job already exists for the `file_uuid`, querying only the four always-present states (`available`/`scheduled`/`executing`/`retryable`) and proceeding on any query error. The worker name is derived via `inspect/1` so a rename is a compile error, not a silently-broken query.
- **Guarded, atomic extraction status transitions** (#31) — `mark_failed/2` and `mark_extracting/1` only advance from a non-terminal state (`UPDATE … WHERE status IN ('pending','extracting')`), so a concurrent worker can no longer clobber a success terminal (`extracted` / `scanned_no_text`) back to `failed` — silent data loss that broke search — nor pull a finished extraction back to `extracting`. Success markers stay last-writer-wins.
- **Honest, batched `requeue_stuck_extractions/1`** — returns `%{requeued, skipped, failed}` (capped at 1000 rows/call) where `skipped` is rows a live job already covers, so "Re-queued N" never takes credit for no-ops; the **"Retry stuck"** flash is a *warning* (not "success") when enqueues were refused — the exact queue-missing case the button targets. The whole selection is de-duped against live jobs in **one** query and enqueued with **one** `Oban.insert_all/1` rather than ~2k per-row round-trips at the cap.
- **`retry_extraction/2` refuses a success-terminal row** with `{:error, :already_extracted}` unless `force: true` is passed, so a stray programmatic caller can't reset a good extraction to `pending` and drop the PDF out of search mid-re-extract.
- **Bulk-action bars folded onto core `<.bulk_actions_bar>`** (#31) on the catalogue detail page (categories + deleted-items lists) — removes ~50 lines of duplicate component markup while keeping the sticky styling and `clear_selection` behaviour.
- `PdfLibraryLive` loads its list in `handle_params/3` (not `mount`, which runs twice) and now honours a `?filter=active|trashed` deep-link; the extraction-status badge is a HEEx component with auto-escaping instead of hand-built `Phoenix.HTML.raw` markup.

### Fixed
- The `permanently_delete_pdf/2` refcount-then-handoff sequence runs inside a `Repo.transaction(_, isolation: :serializable)` so a concurrent upload of the same content can't orphan a reference between the count and `Storage.trash_file/1`.

### Notes
- **No new core requirement** — still `phoenix_kit ~> 1.7 and >= 1.7.125`. The PDF `oban_jobs` dedup filters on `args ->> 'file_uuid'`, which has no index; since this module ships no migrations and `oban_jobs` is core/host-owned, a partial expression index belongs in a future core migration once the job table grows large (tracked in `AGENTS.md` and on `PdfLibrary.extraction_job_pending?/1`).
- Verification: `mix precommit` clean (compile + format + credo --strict + dialyzer). The Web/context test suites that exercise the new guards are DB-gated and run against a host whose schema is at core V111+.

## 0.4.0 - 2026-05-30

### Added
- **ItemPicker display options** (#29) — four backward-compatible attrs on `<.item_picker>` and the underlying `ItemPicker` LiveComponent, all defaulting to current behaviour: `show_unit` (opt-in; render the item's measurement unit beside the price in each dropdown row), `format_unit` (1-arity `unit -> label` function, mirroring `format_price`; defaults to the shared abbreviation map, return `""` to omit), `highlight_selected` (default `true`; pass `false` to drop the `input-primary` border on always-rendered pickers), and `initial_query` (optional seed string that prefills the search input and opens matching results once on first render, never clobbering a real selection or mid-typing query).

### Changed
- `ItemPicker` `category_uuids` / `catalogue_uuids` attrs relaxed from `:list` to `:any` so callers can pass an explicit `nil` (the documented "all categories" scope) without a Phoenix attr-type warning.
- Unit-abbreviation labels (`piece`→`pc`, `m2`→`m²`, `running_meter`→`rm`, …) are now centralised in `PhoenixKitCatalogue.Schemas.Item.unit_label/1` — a single source of truth shared by the items table and the item picker, instead of two divergent copies.

### Fixed
- **PDF extraction enqueue** refuses to enqueue when the `:catalogue_pdf` Oban queue isn't running (not configured, or Oban not started). Instead of piling up never-processed jobs it flips the extraction to a terminal failed status with an actionable message + activity row.

## 0.3.0 - 2026-05-29

### Added
- **Catalogue folders** — an inline, nested folder tree-table on `/admin/catalogue` (Finder-style): disclosure chevrons, native drag-and-drop filing, an Actions "Move to folder" picker, and front-insertion so new folders surface at the top. Folders are **module-global** (a dedicated `phoenix_kit_cat_folders` table; **requires core V123**) and unrelated to the media-folder system. New schema `PhoenixKitCatalogue.Schemas.Folder` and `cat_catalogues.folder_uuid` (`ON DELETE SET NULL`). New context API: `list_folder_tree/1`, `catalogues_by_folder/1`, `folder_uuids_with_children/1`, `get_folder/1`, `create_folder/2`, `update_folder/3`, `move_folder/3`, `trash_folder/2`, `restore_folder/2`, `permanently_delete_folder/2`, `reorder_folders/2`, `move_catalogue_to_folder/3`. Folder mutations broadcast a `:folder` PubSub event so the tree converges across open sessions.
- **Per-status item tabs** on the catalogue detail page — Active / Inactive / Discontinued / Deleted (empty Inactive hidden); discontinued items are no longer mixed into Active.
- **Detail drill-down rework** — the detail page is now a category drill-down built on the core list-UI toolkit (sortable / bulk-select / `load_more`), replacing the old per-card expand mechanism. The current category is carried in `?category=` for deep-linkable, back-button-friendly navigation.

### Changed
- **Full-width, sidebar-driven layout** for the catalogue admin pages — the three redundant top tabs are replaced by a sidebar-driven header.
- **Duplicate SKUs are now accepted** — core V123 drops the global unique `cat_items.sku` index.
- Housekeeping: catalogue search-empty states use core `<.empty_state>`; blank-string normalization migrated to `PhoenixKit.Utils.Values.blank_to_nil`.

### Fixed
- **Reorder no longer re-slots a trashed item into the active sequence** — `item_scope_check/3` now excludes `status = "deleted"` (parity with the active-only `:all` reorder path), closing a cross-tab race where an item selected client-side then trashed elsewhere could still be repositioned.
- **Folder moves are now serialized** — the cycle check + validation + update run inside a transaction with `FOR UPDATE` on the moved row (parity with category moves), so concurrent reparents can't commit a cycle that would vanish from the tree view.
- **Test suite repaired** — the suite had been silently uncompilable since the PDF sweep (a `with_scope/2` helper that never existed); added the missing LiveView scope test-infra + PDF routes and folder / PubSub / status-count coverage.
- De-brittled the smart-pricing float-qty test (assert behavior, not version-dependent `Decimal` internals).
- Trimmed redundant work on the index render (duplicate folder-tree / count queries) and the detail `load_level` (fetched both `:active` and `:deleted` child-category lists and discarded one; ran a per-category count `GROUP BY` even on the status tabs where no cards render).

### Removed
- Cross-category drag-move on the detail page — superseded by the explicit bulk "Move" modal in the single-node drill view.
- Dead code: `list_child_folders/2` and `folder_catalogue_counts/0`.

### Notes
- **Requires core V123** (catalogue folders + dropping the global unique `cat_items.sku` index), first shipped in `phoenix_kit 1.7.125`. The dep constraint is now `~> 1.7 and >= 1.7.125` — floored at the V123 release while keeping the `< 2.0.0` upper bound loose. Run migrations against a `phoenix_kit` ≥ 1.7.125 host.

## 0.2.0 - 2026-05-11

### Added
- **Per-module gettext backend** — `PhoenixKitCatalogue.Gettext` (`lib/phoenix_kit_catalogue/gettext.ex`). The module now owns its translations instead of borrowing `PhoenixKitWeb.Gettext` from the host app.
- **i18n-aware tab registration** — all 19 `%Tab{}` structs in `admin_tabs/0` carry `gettext_backend: PhoenixKitCatalogue.Gettext` and `gettext_domain: "default"`. Tab labels are now translated at render-time via `Tab.localized_label/1` (requires `phoenix_kit >= 1.7.107`).
- **Translation files** — `priv/gettext/{en,ru,et}/LC_MESSAGES/default.po` with complete translations for tab labels, page titles, status strings, error messages, flash messages, and UI copy. Russian uses 3 plural forms per CLDR; Estonian uses 2.
- **Smoke test** — `test/gettext_test.exs` verifies backend compilation, Russian/Estonian tab-label translation, fallback for tabs without a backend, and fallback to msgid for untranslated strings.

### Changed
- All `Gettext.gettext(PhoenixKitWeb.Gettext, ...)` and `Gettext.ngettext(PhoenixKitWeb.Gettext, ...)` calls replaced with `PhoenixKitCatalogue.Gettext`. Affects 18 files in `lib/`. This is a transparent change for end users — behaviour is identical as long as translations are kept in sync.
- Version bumped `0.1.17` → `0.2.0` (minor: tab labels are now locale-dependent, which is a visible behaviour change for downstream callers relying on raw English strings from `Tab.label`).

### Notes
- `{:phoenix_kit, "~> 1.7"}` constraint kept as-is (core is at 1.7.107 locally). A bump to `~> 1.8` is gated on the core hex release; `Tab.gettext_backend` and `Tab.localized_label/1` are already present at 1.7.107.

## 0.1.17 - 2026-05-09

### Added
- **Items / Categories tabs on the catalogue detail page** — reflected to URL via `?tab=items|categories`. Each tab keeps its own Active / Deleted counts and per-tab Active/Deleted switcher. The Items tab Deleted view is a flat recency-ordered list (`list_deleted_items_for_catalogue/2`, capped at 500) instead of category-grouped cards. Auto-flip back to Active when the per-tab Deleted bucket empties — no more landing in an empty Deleted view of one tab while the other still has rows.
- **Bulk select + actions** — row checkboxes (table + card view) with a sticky action bar. Items: Delete / Restore / Move (Move opens a same-catalogue target picker). Categories: Delete (opens the disposition modal in bulk mode) / Restore. New context fns `bulk_trash_items/2`, `bulk_restore_items/2`, `bulk_permanently_delete_items/2`, `bulk_move_items_to_category/3`, `bulk_trash_categories/3`. The bulk-move fn requires a `:catalogue_uuid` opt and validates both items + target stay in scope (mirrors the single-item DnD guard so a crafted client request can't silently flip a `catalogue_uuid` cross-catalogue).
- **Per-card pagination** — replaced the global infinite-scroll cursor with a PdfSearchModal-style 25-row preview + per-card "Show N more" button. `expand_card` is deferred (event handler returns immediately, button renders the loading state, fetch runs on the next mailbox tick) with an 8s `:expand_timeout` recovery so a network hiccup mid-click restores the button + flashes a retry message.
- **Cross-tab live updates** via PubSub — reorders, bulk operations, and category position changes broadcast to all open detail pages on the same catalogue. Bulk operations get a two-step receiver animation (red flash on leaving rows → 800ms delay → state refresh → green flash on arriving rows). New `Catalogue.PubSub` broadcasts: `broadcast_card_refresh/5`, `broadcast_category_reorder/4`, `broadcast_bulk_change/4`. All include `from \\ self()` so the originator's own broadcast is filtered on receive.
- **Item-disposition modal** when trashing a category that still has items — Cascade / Uncategorize / Move-to (with same-catalogue target picker via `list_move_target_categories/1`). `trash_category/2` accepts an `:items` opt: `:cascade` (default), `:uncategorize`, or `{:move_to, target_uuid}`. Activity metadata grows `items_handled` + `items_disposition`.
- **`active_item_count_in_subtree/1`** — admin "delete category" modal gate; counts items in the category and every V103 descendant.
- **`list_move_target_categories/1`** — same-catalogue active categories that can receive items from a category about to be deleted (the category itself and its V103 descendants are excluded). Used by the disposition modal's move-target dropdown.
- **`:parent_catalogue_deleted` error reason** with gettext message — surfaced when restoring a category or item whose parent catalogue is itself deleted.
- **Drag-handle-only DnD** across all catalogue admin views — `pk-drag-handle` class wired through `data-sortable-handle` on catalogues table, category rows, item tables, and smart-rule rows. The row body is no longer a drag affordance.

### Changed
- **Soft-delete is decoupled — each entity owns its own status.** `restore_category/2` no longer cascades up or down; only the target category's status flips back to `"active"`. Refuses with `{:error, :parent_catalogue_deleted}` when the parent catalogue is itself deleted (the operator must restore the catalogue first). Items that came down via `:cascade` stay deleted; descendants stay deleted; ancestor categories stay at whatever status they were. `restore_item/2` refuses if the parent catalogue is deleted; when the parent **category** is deleted, the item is uncategorized on restore (`category_uuid: nil`) so it surfaces in the catalogue's Uncategorized bucket without auto-reviving the category structure. Activity metadata grows `"detached_from_category" => true` in that case. **Behaviour change** for callers that relied on the old cascading restore — call `restore_catalogue/2` first, or restore items individually after the parent.
- `category.restored` activity metadata no longer carries `subtree_size` / `items_cascaded` (always 0 under the no-cascade rule); `category.trashed` carries `subtree_size`, `items_handled`, and `items_disposition` (`"cascade"` / `"uncategorize"` / `"move_to:<uuid>"`).
- `bulk_restore_items/2` now wraps the read-then-partition-then-write pipeline in `repo().transaction/1` so a concurrent parent-status flip can't push the partition off-by-one (would otherwise either detach an item that should have stayed attached or vice versa). Single-item `restore_item/2` was already transactional; the bulk path now matches.
- `do_bulk_move/4` (both clauses) gained `where: i.status != "deleted"` for surface consistency with `bulk_trash_items` / `bulk_restore_items` — defence against a stale tab submitting a deleted UUID.

### Fixed
- `restore_category/2` docstring rewritten to match the no-cascade behaviour (was still describing the prior cascade-both-directions semantics).
- 6 unwrapped flash strings in the catalogue-detail bulk handlers — all now wrapped in `Gettext.gettext`. Two `inspect(reason)` flashes that leaked raw Elixir terms replaced with gettext-wrapped user messages; raw reason routes to `log_operation_error/3` for engineer visibility.
- `Catalogue.PdfLibrary.sha256_file/1` — `File.stream!(path, [], 65_536)` was the pre-Elixir-1.16 signature (modes at arg 2, byte-count at arg 3). Modern signature is `File.stream!(path, line_or_bytes, modes)`. Fixed via swap to `File.stream!(path, 65_536, [])`. The contract violation was cascading into `no_local_return` on `sha256_file/1` + 7 "function will never be called" warnings across `existing_active_file/1`, `ensure_extraction/1`, `resolve_extraction_after_insert/1`, `insert_pdf_row/5`, `enqueue_extraction/1`, and `store_via_core/4` — all clear now that dialyzer can trace the call graph again.

### Removed
- `move_category_up` / `move_category_down` LV events — category reorder is drag-only via the SortableGrid hook now. The `apply_category_reorder/3` path is exercised end-to-end by the DnD wire.
- Global infinite-scroll cursor + `:has_more` / `:loading` mount-default assigns — superseded by per-card expand.
- Dead `_scopes` payload on `broadcast_bulk_change/5` — was always `[]` from every call site, always `_`-bound by every receiver. Dropped (signature is now `/4`).
- Old `subtree_size` / `items_cascaded` cascade in `restore_category` activity metadata — see Changed.

## 0.1.16 - 2026-05-05

### Added
- **`Catalogue.evaluate_smart_rules/2` (issue #20)** — public smart-pricing evaluator. Standard entries pass through; smart items get a computed price written to a configurable key (default `:smart_price`). Single consumer-policy injection point: `:line_total` lambda (default `base_price × qty`). Lives in new `PhoenixKitCatalogue.Catalogue.SmartPricing` submodule. Loud `ArgumentError` raises when `:catalogue` or `:catalogue_rules` is `%NotLoaded{}` on any entry — better than silent zero-pricing.
- **`Catalogue.list_items_by_uuids/2` (issue #19)** — order-preserving, soft-delete excluded, deduped, no `nil` placeholders for missing UUIDs. Designed for order-snapshot rehydration without leaking `Repo` to consumers.
- **`Catalogue.category_summary_for_catalogue/2` (issue #21)** — returns `%{categories:, item_counts:, uncategorized_count:}` in two queries. Replaces the three-roundtrip pattern (`list_categories_metadata_for_catalogue` + `item_counts_by_category_for_catalogue` + `uncategorized_count_for_catalogue`) lazy-load consumers had to write.
- **`:preload` opt on bulk fetchers (issue #19)** — `search_items/2`, `search_items_in_catalogue/3`, `list_items_for_category/2`, `list_items_for_catalogue/2`, `list_uncategorized_items/2`, `list_items_for_category_paged/2`, `list_uncategorized_items_paged/2`, `get_item/2`, `get_item!/2`, and `list_items_by_uuids/2` all accept `:preload`, concatenating onto each function's defaults. Pass `[catalogue_rules: :referenced_catalogue]` for smart-pricing.
- `Catalogue.Helpers.merge_preloads/2` — single-source preload concat helper (was duplicated in `catalogue.ex` and `search.ex`).

### Changed
- **`get_item!/2` default preloads expanded** to `[:catalogue, :category, :manufacturer]`. The previous arity-1 form silently omitted `:catalogue`, which downstream smart-pricing callers had to add via a separate `Repo.preload`. Pure addition for callers that didn't access `.catalogue`.
- **`list_uncategorized_items/2` default preload widened** from `[:manufacturer]` to `[:catalogue, :manufacturer]`. Pure addition.
- `guides/smart_catalogues.md` §4 rewritten to call `evaluate_smart_rules/2` directly. The 100-line copy-paste reference impl is gone; one source of truth lives in the package now. §5 (preload pitfall) updated to reference the new `:preload` opt.
- Test infrastructure switched from `Ecto.Migrator.run([{0, PhoenixKit.Migration}])` to `PhoenixKit.Migration.ensure_current/2`. The old pattern was idempotent at the outer Ecto.Migrator layer (version `0` cached in `schema_migrations`) so newly-shipped Vxxx migrations silently never applied. Requires `phoenix_kit ~> 1.7.105` for the test suite; runtime constraint unchanged.
- Test-helper rescue narrowed to `[DBConnection.ConnectionError, Postgrex.Error]` only — code/version bugs (`UndefinedFunctionError`, etc.) now propagate loudly instead of dark-running the `:integration` suite under a misleading "DB unavailable" banner.

### Fixed
- `evaluate_smart_rules/2` `%NotLoaded{}` raise message for `:catalogue` no longer points readers at `:catalogue_rules` (separate raise below already names that one).
- `Catalogue.Helpers.merge_preloads/2` docstring now matches the pinning test in `catalogue_test.exs` — bare-atom + nested-keyword collision merges (parent loads AND nested child loads), not "silently prefers nested" as the doc previously claimed.
- `lib/phoenix_kit_catalogue.ex` `version/0` and the `version/0` test were stuck at `"0.1.13"` since the 0.1.13 release — now match the package version.
- Closes #16, #17 — already shipped in 0.1.14 (PR #18) but didn't auto-close on GitHub.

## 0.1.15 - 2026-05-02

### Added
- **Drag-and-drop reorder** — catalogues, categories, items, and smart-rule rows can be reordered via DnD. Position writes use a two-pass (negative-then-positive) strategy to avoid unique-index collisions. Cap enforced via `Application.compile_env(:phoenix_kit_catalogue, :reorder_max_uuids, 1000)`.
- **`reorder_categories_groups/3`** — atomic reorder across multiple parent groups in a single outer transaction (cross-parent partial-commit protection).
- **`Helpers.dedupe_keep_last/1`** — shared last-wins deduplication for DnD payloads, replacing ad-hoc `Enum.uniq` calls.

### Changed
- **Audit-trail integrity on cross-category item moves** — rejection and DB-error log rows from `reorder_items/4` inside `move_item_and_reorder_destination/4` now survive outer-transaction rollbacks (split into unlogged inner + logged outer).
- **`refresh_card_items/3`** — gains explicit `delta` param (default `0`). In-scope reorder no longer inflates the limit by `+1` on every drag.
- **`@reorder_max_uuids`** consolidated to `Application.compile_env/3` — single config source shared by `Catalogue` and `Rules`.
- **Global `search_items/2` `order_by`** — reverted to `name + uuid` only. `position` is per-scope and meaningless across catalogues; catalogue-scoped search keeps it.

### Fixed
- Duplicate `list_catalogue_rules` query on smart-item mount eliminated — single fetch derives both `working_rules` and `rule_candidate_order`.
- Smart-rule DnD now uses `dedupe_keep_last` (last-wins) matching catalogue/category/item reorder semantics.

## 0.1.14 - 2026-04-28

### Added
- **Smart-chain guard (issue #16)** — `CatalogueRule` now rejects rules whose `referenced_catalogue` is itself `kind: "smart"`, with the error `"must reference a standard catalogue, not a smart catalogue"` on `:referenced_catalogue_uuid` (`validation: :smart_chain`). Self-references fall under the same guard. Applied to `create_catalogue_rule/2`, `update_catalogue_rule/3`, `put_catalogue_rules/3`, and `change_catalogue_rule/2`. The item-form rule picker now lists only standard catalogues so the user is never offered an option that would fail on save.
- **`:only` scope on `search_items/2` + `count_search_items/2` + `<.item_picker>` (issue #15)** — `:uncategorized_only` restricts to items with no `category_uuid`, `:categorized_only` restricts to items in some category, `nil` (default) is unrestricted.
- **`PhoenixKitCatalogue.Errors`** — central atom-to-string dispatcher (13 plain atoms + 9 tagged tuples) for UI flashes. Plus per-atom pinning tests.
- **Smart Catalogues guide** (`guides/smart_catalogues.md`) — concepts, schema diagram, worked example, host-side reference implementation, pitfalls. Wired into `mix.exs` `package.files` and `docs.extras`.
- `@spec` backfill on the 14 most-called CRUD entry points + 26 specs across `Catalogue`.
- `Test.Endpoint` / `Test.Router` / `Test.Layouts` / `LiveCase` test infra so the suite actually runs (598 → 869 tests).

### Changed
- `search_items/2` and `count_search_items/2` now raise `ArgumentError` on two foot-guns that previously yielded silent empty results: `category_uuids: [nil]` (use `:only => :uncategorized_only` instead) and `:only => :uncategorized_only` combined with non-empty `:category_uuids` (logical contradiction).
- Activity logging — `enable_system` / `disable_system` log `catalogue_module.{enabled,disabled}`. `enabled?/0` adds `catch :exit, _` for sandbox-owner shutdowns. `ActivityLog` rescue narrowed to `Postgrex.Error :undefined_table` for the host-without-V90 case before logging a warning.
- Failure-side audit rows — LV layer writes `metadata.db_pending: true` rows on every LV-visible failure via `Helpers.log_operation_error/3`. Context layer stays success-only.
- `Tree.subtree_uuids_for/1` and `ancestor_uuids/1` cast `^uuid` / `^roots` via `type(_, UUIDv7)` (CTE was losing type info). `ancestors_in_order/1` rewritten — previously returned `[]` for every non-root category.
- `Task.start/1` → `Task.Supervisor.start_child(PhoenixKit.TaskSupervisor, ...)` for the supervised import task.
- `phx-disable-with="Deleting..."` on the two permanent-delete buttons in `components.ex`.

### Removed
- Dead `Catalogue.broadcast_for/2` clauses (`"manufacturer"` / `"supplier"` / `"smart_rule"`) and the orphan `lookup_parent(:smart_rule, _)`. The submodules (`Manufacturers`, `Suppliers`, `Rules`) call `PubSub.broadcast/3` directly and never reached the helper.

### Fixed
- `change_catalogue_rule/2` smart-chain guard no longer issues a DB lookup on every form keystroke — switched to `Ecto.Changeset.get_change/2` so the lookup only fires when `:referenced_catalogue_uuid` actually changes.

## 0.1.13 - 2026-04-26

### Added
- `parent_catalogue_uuid` on PubSub broadcasts for scoped detail-view updates
- `refresh_in_place/1` — updates counts/category tree without wiping scroll state
- Smart items can now be assigned categories and manufacturers for organization
- Import executor emits single roll-up broadcast instead of per-row events

### Changed
- `PubSub.broadcast/3` now accepts optional `parent_catalogue_uuid` (backward-compatible)
- `log_activity/2` supports `broadcast: false` opt for bulk operations

## 0.1.12 - 2026-04-24

### Added
- **Catalogue form tabs** — `CatalogueFormLive` gains Details / Metadata / Files tabs (mirrors `ItemFormLive`). Featured image + attached files live under the Files tab; metadata under Metadata. Panels stay in the DOM (toggled via `hidden`) so multilang state and in-progress input survive tab switches. Save sits outside the tab panels and works from any tab.
- **Catalogue metadata** — `Metadata.definitions(:catalogue)` ships five opt-in fields (`brand`, `collection`, `season`, `region`, `vendor_ref`) stored under `catalogue.data["meta"]`.
- **Category featured image** — `CategoryFormLive` gains a featured-image card (no tabs, no file grid; a category is a taxonomy node). `Attachments.folder_name_for/1` picks up a `%Category{}` clause (`catalogue-category-<uuid>`). Folders are created lazily on first picker open, so categories without a featured image never materialize one.
- `Components.featured_image_card/1` — shared featured-image card (thumbnail + name + size, or dashed empty state with primary button) used by catalogue / category / item forms.
- `Components.metadata_editor/1` — shared metadata tab body (per-key text input + remove button + add-picker dropdown; legacy keys render disabled with a "Legacy" pill).

### Changed
- **`PhoenixKitCatalogue.ItemMetadata` → `PhoenixKitCatalogue.Metadata`** with resource-type-scoped `definitions/1`. Items keep `color / weight / width / height / depth / material / finish`; catalogues get the five new keys above. Upstream consumers of the `ItemMetadata` module (introduced in 0.1.11) need to update the alias and pass `:item` to `definitions/1`.
- Extracted the three-phase form helpers — `Metadata.build_state/2`, `absorb_params/2`, `inject_into_data/3` — out of `ItemFormLive` and into the shared module so `CatalogueFormLive` uses the same plumbing (~150 lines of duplication removed across the three form LVs).

### Notes
- No migrations. All three schemas (`Item`, `Catalogue`, `Category`) already carry JSONB `data`; `featured_image_uuid`, `files_folder_uuid`, and `meta` all live under that column.
- 27 unit tests for the pure `Metadata` helpers + 7 component-render tests for `featured_image_card/1` and `metadata_editor/1`.

## 0.1.11 - 2026-04-22

### Added
- **Nested categories** (requires phoenix_kit 1.7.103+ for the V103 `parent_uuid` self-FK migration). New `PhoenixKitCatalogue.Catalogue.Tree` module with recursive-CTE helpers (`subtree_uuids/1`, `descendant_uuids/1`, `ancestor_uuids/1`, `ancestors_in_order/1`) plus pure in-memory walkers (`build_children_index/1`, `walk_subtree/3`) for preloaded trees. CTEs use `UNION` (not `UNION ALL`) for defense-in-depth cycle safety.
- `Catalogue.move_category_under/3` — same-catalogue reparent with `:would_create_cycle` / `:cross_catalogue` / `:parent_not_found` rejection; `nil` promotes to root.
- `Catalogue.list_category_tree/2` returns `[{category, depth}]` with orphan promotion (deleted-ancestor children surface as roots) and an `:exclude_subtree_of` option for parent pickers.
- `Catalogue.list_category_ancestors/1` (delegates to `Tree.ancestors_in_order/1`) for breadcrumbs.
- `search_items/2` gains `:include_descendants` (default `true`) so a category-scoped search also matches items in descendant categories. Pass `false` for the literal-set semantics.
- **Attachments** — new `PhoenixKitCatalogue.Attachments` module shared by item + catalogue forms. Folder-per-resource, featured-image pointer, inline files dropzone (20 files / 100 MB / `auto_upload: true`), pending-folder rename on first save. Smart detach splits home-folder vs `FolderLink` files; `list_files_in_folder/1` capped at 200 rows. Save button disabled while uploads are in flight.
- **Item metadata** — new `PhoenixKitCatalogue.ItemMetadata` module with a global opt-in list of fields stored on `item.data["meta"]`. Labels are gettext-wrapped; legacy keys (dropped from code but still held by an item) surface as "Legacy" rows with a remove-only action so deleting a definition never wipes stored data.
- **Item picker** — new `PhoenixKitCatalogue.Web.Components.ItemPicker` combobox LiveComponent with server-side search, `:category_uuids` / `:catalogue_uuids` scoping, `:include_descendants` toggle, `:excluded_uuids` dim-and-disable, colocated keyboard hook (ArrowUp/Down, Home/End, Enter, Escape), `has_more` "type to refine" sentinel, and render-shape tests.

### Changed
- Category position scoping moved from `catalogue_uuid` to `(catalogue_uuid, parent_uuid)` — `next_category_position/2` now takes a `parent_uuid` arg (default `nil` for root).
- `swap_category_positions/3` refuses `{:error, :not_siblings}` when the two categories live under different parents or in different catalogues.
- `trash_category` / `restore_category` / `permanently_delete_category` walk the whole subtree in one transaction. `restore_category` also restores deleted ancestors + the parent catalogue so the restored node is reachable. Activity metadata carries `subtree_size` + `items_cascaded`.
- `move_category_to_catalogue` carries the subtree along in a transaction; takes `SELECT … FOR UPDATE` on the moved row and computes the target position *after* the subtree has moved — closes the stale-position race flagged in prior reviews.
- `list_all_categories/0` renders full breadcrumbs (`"Catalogue / Parent / Child"`) and loads in two queries instead of N+1 per catalogue.
- `Category.changeset` rejects self-parent; `create_category/2` and `update_category/3` additionally guard against cross-catalogue and descendant-as-parent (cycle) cases at the context level, so raw API / form callers can't bypass `move_category_under/3`.

### Fixed
- Catch-all `handle_info/2` on `CatalogueFormLive` and `ItemFormLive` — stray monitor signals used to crash these forms.
- `phx-disable-with` on every Move button (category-under-parent, category-to-catalogue, item-to-category, item-to-smart-catalogue).
- `Attachments.soft_trash_file/1` is inlined to avoid depending on the unreleased `PhoenixKit.Modules.Storage.trash_file/1`.
- Credo / dialyzer clean after refactors: nested-too-deep in meta handlers, cyclomatic-10 `file_type_from_mime`, opaque MapSet in `list_category_tree`, unreachable `read_string/2` fallback.

## 0.1.10 - 2026-04-20

### Added
- **Smart catalogues** (`kind: "smart"`) — catalogues whose items are priced as a rule-driven function of other catalogues. New `CatalogueRule` schema (`phoenix_kit_cat_item_catalogue_rules`) and `put_catalogue_rules/3` replace-all API with duplicate detection, per-leg `value`/`unit` inheritance via `CatalogueRule.effective/2`, and `smart_rules.synced` activity logging (added/updated/removed counts). Requires phoenix_kit 1.7.102+ for the V102 migration.
- **Per-item discount override** — nullable `Item.discount_percentage` (`nil` inherits the catalogue's discount, any value including `0` overrides). Pricing chain is now `base → markup → discount`, exposed via `Item.final_price/3`, `Item.effective_discount/2`, `Item.discount_amount/3`, and the expanded `Catalogue.item_pricing/1`.
- **Smart-item defaults** — `Item.default_value` / `Item.default_unit` as fallbacks when a `CatalogueRule` row has `nil` value/unit (lets a user set "5% across everything" once and override specific catalogues).
- `list_items_referencing_catalogue/1` + `catalogue_reference_count/1` for warn-before-delete flows; `permanently_delete_catalogue/2` now refuses with `{:error, {:referenced_by_smart_items, count}}` when smart items still reference the catalogue, unless `force: true` is passed.
- `list_catalogues(kind: :smart)` filter; `Catalogue.move_item_to_catalogue/3` for moving smart items across catalogues (categories don't apply to smart items).
- Scoped search: `search_items/2` accepts `:catalogue_uuids` / `:category_uuids` filters composed via `where dynamic`; new `scope_selector` component pairs with it.
- `category_counts_by_catalogue/0` grouped-query helper.

### Changed
- **Context split** — extracted the monolithic `catalogue.ex` into 10 focused submodules (`Rules`, `Search`, `Manufacturers`, `Suppliers`, `Links`, `Counts`, `PubSub`, `Translations`, `Helpers`, `ActivityLog`). Public surface is unchanged — every caller still goes through `Catalogue.*` via `defdelegate`.
- All form LiveViews (catalogue / category / item / manufacturer / supplier) migrated to Phoenix 1.7 component-style `<.input>` / `<.select>` / `<.textarea>` / `<.checkbox>` bindings. The multilang wrapper now scopes only translatable fields (name / description) — pricing, classification, and actions render as siblings so a language switch doesn't re-mount them.

### Fixed
- Replace raising `confirm_delete!/1` with a safe `case`-match + `unexpected_confirm_event/2` fallback across all 5 delete handlers (item / category / catalogue / manufacturer / supplier). Malformed push events flash + log instead of crashing the LV.
- `Catalogue.ActivityLog.log/1` now rescues — activity-logging failures no longer crash the primary mutation, matching the AGENTS.md contract.
- New `log_operation_error/3` helper in both admin LVs — structured logs carrying `actor_uuid`, `entity_type`, `entity_uuid`, and `Ecto.Changeset.traverse_errors`-expanded field/message pairs so production incidents can be debugged from the log alone.
- Search task-exit logs now include query, offset, and `catalogue_uuid`.
- `phx-disable-with` on 9 destructive-action buttons (trash / restore on catalogue + category + item tables and cards) to prevent double-mutation on slow networks.

## 0.1.9 - 2026-04-15

### Added
- Paged search with infinite scroll across global, per-catalogue, and per-category views (`:limit`/`:offset` on all three search functions; `count_search_items*` companions for "X of Y" totals)
- Per-item markup override — nullable `markup_percentage` on items (`nil` inherits the catalogue's markup, any value including `0` overrides it); requires phoenix_kit 1.7.96+ for the V97 migration
- `Item.effective_markup/2` and `Catalogue.item_pricing/1` expose which markup applies (catalogue vs item) for pricing UI
- Import wizard: markup override column with multilingual synonym detection (markup/margin/naceenka/juurdehindlus/aufschlag/...)
- Import wizard: manufacturer and supplier pickers (four-mode vocabulary `:none`/`:column`/`:create`/`:existing`), shared `<.party_picker>` and `<.new_party_form>` components
- Import wizard: language-aware category get-or-create with "match across all languages" toggle; inline category creation in `:create` mode
- Import wizard: empty-pool warning when a picker column is exhausted by a sibling picker's mapping

### Changed
- Search uses `start_async` with a query-equality guard in `handle_async`, so out-of-order or superseded responses are dropped; scroll paging also runs off the LV process via `start_async(:search_page, …)` guarded on `{query, offset}`
- Import executor phase 1 (get-or-create categories / manufacturers / suppliers) wrapped in a single `Repo.transaction` so a mid-phase crash rolls back any entities earlier loops persisted
- Three `:create`-mode resolutions in the wizard wrap in `Repo.transaction` at the LV layer so a failure on the second/third doesn't leave the first as an orphan
- `Catalogue.item_pricing/1` now returns `catalogue_markup`, `item_markup`, and effective `markup_percentage` so callers stay internally consistent
- `IntersectionObserver` hook re-fires on `updated()` — fixes the "loads forever" bug on tall viewports / Page Down

### Fixed
- Upload button stays disabled while the upload XHR is in flight (server-side guard in `parse_file`) — fixes the "click during upload erases the file" race
- Parser strips fully-empty columns (blank header AND every data cell blank) — fixes phantom mapping cards on FENIX-style spreadsheets with leading/trailing empty columns
- Catalogue picker loads on first HTTP mount (no empty-dropdown flash); options show counts (`Kitchen · 5 categories · 47 items`)
- Sample data table: `#` row-number column, truncation tooltips, stable collapse `id` so morphdom preserves open state

## 0.1.8 - 2026-04-12

### Fixed
- Add routing anti-pattern warning to AGENTS.md

## 0.1.7 - 2026-04-11

### Added
- Items belong directly to catalogues via catalogue_uuid FK (requires phoenix_kit 1.7.95+)
- Infinite scroll on catalogue detail page with cursor-based pagination
- Activity logging with Events tab (actor tracking on all mutations)
- Item counts on catalogue list view
- Clickable entity names (manufacturers, suppliers)
- Comprehensive test suite: LiveCase, LiveView tests, schema tests

### Changed
- Removed safe_nested_assoc/2 in favour of direct catalogue association on items
- Category and item mutations now accept actor_uuid for activity logging

## 0.1.6 - 2026-04-09

### Added
- Dynamic file import system (CSV/Excel with multi-sheet support)
- Auto-detect column→field mappings
- Unit normalization and duplicate detection
- Full import LiveView (upload → parse → map → confirm → execute)

### Changed
- Updated phoenix_kit dependency to 1.7.93

## 0.1.5 - 2026-04-08

### Added
- **Dynamic file import** — upload XLSX or CSV files, auto-detect column mappings, map columns to item fields via drag-down UI
- **Import language support** — select which language the file data is in, stored in multilang JSONB
- **Import category support** — import into existing category, create categories from column values, or import without category
- **Unit mapping** — auto-detect and map file unit values (TK, KMPL, LEHT, PAAR) to system units (piece, set, pair, sheet, m2, running_meter)
- **Duplicate detection** — detect identical rows within file and items already in catalogue, with skip/import choice
- **New unit types** — added `set`, `pair`, `sheet` to allowed item units
- **Multilang search** — search now matches translated content in JSONB `data` field across all languages

### Changed
- Removed unique constraint on item SKU field to allow duplicate article codes
- Item edit form now detects imported items with non-primary language and shows rekey warning

### Fixed
- Search across translated content in `data` JSONB field

## 0.1.4 - 2026-04-06

### Changed
- Wrap all user-visible strings in Gettext for i18n

## 0.1.3 - 2026-03-31

### Added
- **Pricing system** — rename `price` to `base_price` on items, add `markup_percentage` to catalogues (default 0%), computed sale price via `Item.sale_price/2` and `Catalogue.item_pricing/1`
- **Search** — `search_items/2` for global cross-catalogue search, `search_items_in_catalogue/3` for catalogue-scoped search, `search_items_in_category/3` for category-scoped search; matches name, description, SKU via case-insensitive ILIKE with special character sanitization
- **Reusable components** (`PhoenixKitCatalogue.Web.Components`):
  - `item_table/1` — configurable data-driven table with selectable columns, opt-in actions, card view toggle
  - `search_input/1` — search bar with debounce and clear button
  - `search_results_summary/1` — result count display
  - `empty_state/1` — centered empty state card
  - `view_mode_toggle/1` — global table/card toggle syncing multiple tables via shared storage key
- **Card view** — all tables (catalogues, manufacturers, suppliers, items) support table/card view toggle with localStorage persistence; card titles are clickable links
- **Inline actions** — table row actions render as inline buttons on desktop, collapse to dropdown menu on mobile (via `table_row_menu` `mode="auto"`)
- `Catalogue.swap_category_positions/2` — atomic position swap in a transaction
- `Catalogue.list_items/1` — global item listing with status filter and limit
- `Catalogue.item_count_for_catalogue/1` and `category_count_for_catalogue/1` — active counts
- **Gettext localization** — all component text (column headers, actions, tooltips, result counts) localizable via PhoenixKit's Gettext backend
- **Graceful error handling** — components never crash; unknown columns, unloaded associations, nil values, and bad path functions produce "—" placeholders and Logger warnings
- All item list/search functions now consistently preload `category: :catalogue` and `:manufacturer`

### Fixed
- Category reorder now atomic (wrapped in transaction instead of two separate updates)
- `sync_manufacturer_suppliers/2` and `sync_supplier_manufacturers/2` now return `{:ok, :synced}` or `{:error, reason}` instead of silently swallowing errors
- `restore_item/1` now cascades upward to both parent category AND parent catalogue (was only restoring category)
- `deleted_item_count_for_catalogue/1` uses single JOIN query instead of two separate queries
- Removed misleading `list_uncategorized_items_for_catalogue/2` (ignored catalogue param), replaced with `list_uncategorized_items/1`
- Confirm-delete flows use modal dialogs instead of broken inline two-step pattern
- Forms use `action="#"` to prevent HTTP POST fallback before LiveView connects
- Added `:phoenix_kit` to `extra_applications` for module discovery

### Changed
- All LiveViews migrated to use PhoenixKit core components (`table_default`, `table_row_menu`, `status_badge`, `admin_page_header`, `confirm_modal`, `icon`)
- Removed all inline HTML tables, SVG icons, and local badge/format helpers in favour of shared components
- Manufacturer/supplier form save flows now handle sync errors with warning flash messages

## 0.1.2 - 2026-03-27

### Changed
- Bump Elixir requirement from ~> 1.15 to ~> 1.18 (align with sibling modules)
- Bump ex_doc from ~> 0.34 to ~> 0.39
- Update AGENTS.md: reorganize commands, add critical conventions, commit message rules, external dependencies section, and PR docs templates

## 0.1.1 - 2026-03-25

### Changed
- Remove all migration references — database and migrations are managed by the parent `phoenix_kit` project
- Add "Database & Migrations" section to README and AGENTS.md explaining where DB lives
- Remove `test.setup` and `test.reset` mix aliases (no longer needed)
- Remove test-only migration file and migration runner from test helper

## 0.1.0 - 2026-03-25

### Added
- Extract Catalogue module from PhoenixKit into standalone `phoenix_kit_catalogue` package
- Implement `PhoenixKit.Module` behaviour with all required callbacks
- Add `Catalogue`, `Category`, `Item`, `Manufacturer`, `Supplier`, and `ManufacturerSupplier` schemas with UUIDv7 primary keys
- Add `PhoenixKitCatalogue.Catalogue` context with full CRUD for all schemas
- Add soft-delete system with cascading trash/restore for catalogues, categories, and items
- Add move operations for categories (between catalogues) and items (between categories)
- Add multilingual support for translatable fields via PhoenixKit's multilang system
- Add admin LiveViews: catalogues, categories, items, manufacturers, suppliers with forms
- Add centralized `Paths` module for route generation
- Add `css_sources/0` for Tailwind CSS scanning support
- Add behaviour compliance and catalogue context test suites
