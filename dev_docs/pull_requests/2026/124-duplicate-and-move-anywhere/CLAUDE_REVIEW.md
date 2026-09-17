# PR #124: Duplicate a catalogue, move anything to any catalogue, and fix the picker's missing photos — Claude review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/124
**Reviewer**: Claude (Opus 5), four read-only review agents following the quality-sweep playbook (C12); no tests run
**Date**: 2026-09-17
**Scope**: `upstream/main..a5cb9ee`, `lib/` (agent 2 also `test/` and `priv/`, agent 4 also the ecommerce companion change). Line numbers refer to that commit.

## Agent 1: security, error handling and async UX

I found no high or medium bugs. There are 2 low bugs, and the rest are improvements or nitpicks. Every finding below is verified by reading the code unless it says otherwise.

### Findings

1. **BUG - LOW. A forged uuid crashes the catalogues LiveView** — `web/catalogues_live.ex:2232` (`request_duplicate_catalogue`).
   - **Trigger:** `phx-value-uuid="x"`. `Catalogue.get_catalogue/1` is a bare `repo().get` (`catalogue.ex:588`), so it raises `Ecto.Query.CastError`. An event with no `"uuid"` key raises `FunctionClauseError`.
   - The existing `trash_catalogue` handler has the same pattern. Fix: run `Ecto.UUID.cast` first.
   - Verified.

2. **BUG - LOW. A long catalogue copy can crash other admins' LiveViews** — `catalogue/duplication.ex:196`, `:247`, `:347`.
   - `duplicate_catalogue` runs with `timeout: :infinity`. It holds the source's `lock_catalogue!` and the global `"catalogue:copy-names"` lock until it commits.
   - **Trigger:** any other call that takes `lock_catalogue!` on the source. That includes trash/restore, the now-locked `move_category_under`, `move_item_to_catalogue`, `bulk_move_items` and bulk trash. These wait under the default 15 s timeout, then raise `DBConnection.ConnectionError` inside `handle_event`, which crashes the LiveView.
   - A second copy of a different catalogue holds its own source lock while it waits on copy-names. That catalogue is then blocked for the whole of the first copy too.
   - Unsure whether real copies run long enough: the docstring says about 1 s for a few thousand items.

3. **IMPROVEMENT - LOW. The duplicate task can stop reporting back** — `web/catalogues_live.ex:3909-3942`, `:2284`.
   - `run_duplicate` rescues exceptions and catches `:exit`, but has no `throw` clause and no monitor. If the task is killed or throws, no message ever arrives.
   - The uuid then stays in `duplicating` for good. `confirm_duplicate_catalogue` silently closes the dialog with no flash.
   - `duplicating` is never rendered, so clicking Duplicate again while a copy runs also shows nothing. Suggest flashing `Errors.message(:already_duplicating)` there, and monitoring the task (or using `start_async`).

4. **IMPROVEMENT - LOW. The broad `rescue` clauses are justified but log too little** — `catalogues_live.ex:3936`, `extensions.ex:96-117`.
   - Catching everything is fine in both places: the task must always report back, and third-party extension code must not abort a copy.
   - But both log only `inspect(e.__struct__)`, with no message and no stacktrace. Skipping the message is reasonable for `Ecto.InvalidChangesetError`, whose message includes params; for other exceptions, log `Exception.message` plus the stacktrace.
   - NITPICK: `extensions.ex:104` logs `inspect(other)`, which may contain the very external ids the callback exists to drop.
   - Unsure: `Extensions.run_duplicate` has no `catch :exit`, so an exiting callback in the synchronous per-item or bulk duplicate paths would crash the detail LiveView.

5. **IMPROVEMENT - LOW. Category-form move errors are not logged** — `web/category_form_live.ex:185-186` (`move_to_other_catalogue`) and `:536` (`move_under_parent`).
   - Neither calls `log_operation_error`; the item form does.
   - `move_under_parent` also shows the generic "Failed to move category." for the newly returned `:not_found`, `:parent_not_found` and `:catalogue_moved`.

6. **IMPROVEMENT - LOW. Bulk-move errors are hard to find in the logs** — `web/catalogue_detail_live.ex:2106-2115`, `:2118`, `:2403`.
   - The new refusal branches (`:category_not_found`, `:catalogue_not_found`, `:kind_mismatch`, `:catalogue_moved`) show a flash but are not logged.
   - The log labels are out of date: `"bulk_move_items_to_category"` and `"bulk_move_categories_under"` now cover `bulk_move_items` and `bulk_move_categories_to_catalogue`, so grepping the new names misses them.

7. **IMPROVEMENT - LOW (defence in depth). The scope check in `bulk_move_categories_to_catalogue` is optional** — `catalogue.ex:6343-6365`.
   - The check only runs `when is_binary(scope)`. `bulk_move_items` instead refuses a missing scope with `:missing_catalogue_scope`. The LiveView always passes the scope, so this is not exploitable today.
   - Nested ("inner") entries skip the scope check. A forged selection of a target-catalogue category plus its parent returns `{:ok, :carried}` and reports "Moved 1" although nothing moved. Only the count is wrong.

8. **NITPICK. Forged-only crashes in the new change handlers.**
   - `set_duplicate_choices` with `choices` sent as a string raises `BadMapError` (`catalogues_live.ex:2262`).
   - `select_bulk_move_catalogue` / `select_bulk_move_categories_catalogue` without `"catalogue_uuid"` while the modal is open raise `FunctionClauseError`.

9. **NITPICK. Possible whole-row log.** `flash_bulk_result` (existing code) logs `errors` with `inspect(limit: :infinity)`. On the same-catalogue path an entry's reason can be a full Category changeset (`reparent!` rollback). Unsure this is reachable, since a row loaded from the DB rarely fails validation.

### Checked and sound
- **Secrets:** none in the diff.
- **SQL:** both new `SQL.query!` calls (the advisory locks) pass the uuid as a bound `$1`, and there are no new `fragment` calls. No HTTP calls, so no SSRF.
- **URL paths:** `Paths.catalogue_detail/1` only ever receives uuids from the offered options or from the DB.
- **Picker events** (`select_move_target` in the item and category forms, `select_bulk_move_catalogue`, `select_bulk_move_categories_catalogue`): each keeps only a value the server offered. `offered_catalogue?` is limited to live catalogues of the same kind, and `picker_has_target?` is re-checked on confirm.
- **Move handlers and context guards:**
  - `move_item`, `move_category` and both bulk confirms act only on server-held assigns.
  - The context validates uuids (`valid_uuid?`), refuses trashed rows, checks the destination is live and the same kind under locks, checks the parent is in the target and would not create a cycle, and scopes `bulk_move_items` all-or-nothing.
- **Error atoms:** every one the LiveViews map has an `Errors.message/1` clause.
- **Mass assignment:** changesets cast explicit allowlists (the Catalogue changeset casts `:kind`), and the copy and move attrs are built on the server.
- **Duplicate options:** the choices are rebuilt from `@duplicate_defaults` only.
- **`create_category`:** the transaction rollback returns a changeset with `:action` set.
- **`phx-disable-with`:** present on the item and category Move buttons and the reparent button. `confirm_modal` (core `modal.ex:377`) sets it on the bulk-move and Duplicate confirm buttons.
- **`handle_info` catch-alls:** present in all four LiveViews.
- **Duplicate failure reporting:** failures are logged with `log_operation_error` and shown as a flash, and the advisory lock blocks concurrent copies of one source.
- **`PhoenixKit.TaskSupervisor`:** exists (core `supervisor.ex:117`).
- **CSS fix:** `browse.ex` is a class-only change.

## Agent 2: translations, activity logging and tests

Re-check of translations, activity logging and tests for `upstream/main..HEAD` (lib/test/priv only; nothing edited, no tests run). The translation catalogues are complete, but there are four real problems: copy names come out in the default language (1), moves have no activity-log tests (2), move error messages have no UI tests (3), and the bulk-move page broadcast has no test (4).

### Findings

1. **`lib/phoenix_kit_catalogue/web/catalogues_live.ex:3909-3915` with `catalogue/duplication.ex:642-650`** — **MEDIUM, verified.**
   - The copy runs in a `Task.Supervisor` child, and a Gettext locale lives in the process dictionary, which the child does not get. Nothing in lib calls `put_locale`.
   - So the copy's name column (and the `free_copy_number` check at `duplication.ex:347`) uses the backend's default language. A ru admin gets "Name (copy)", while the dialog promised «(копия)». Per-language `data` entries are fine: they use `with_locale`.
   - The "Created “%{name}”" flash (`catalogues_live.ex:175`) shows that raw `copy.name`. The "Duplicating" flash uses `localize_one`.
   - No test runs this in ru or et. Fix: capture `Gettext.get_locale(PhoenixKitCatalogue.Gettext)` before starting the task and set it inside.

2. **`test/activity_logging_test.exs`** — **MEDIUM, verified.**
   - AGENTS.md asks for one pinned test per action. No test anywhere asserts `item.moved`, `category.moved` or `item.bulk_moved` (grep finds only a mode-label test).
   - These functions log them, with `actor_uuid` passed through: `move_item_to_category`, `move_item_to_catalogue`, `move_category_to_catalogue`, `move_category_under`, and the new `bulk_move_items` (`catalogue.ex:6227`). Their metadata changed (from/to catalogue and parent), and none of it is pinned.
   - `bulk_move_categories_to_catalogue` logs per move through `move_category_to_catalogue`; that is also unpinned.
   - `catalogue.duplicated` is pinned with its actor. The `"archived" => true` value is not.

3. **Move error messages in the UI have no tests** — **MEDIUM, verified.** Nothing in `test/` contains "Failed to move item/category", "Parent category not found", the kind-mismatch text or "Target category not found". Each of these could be reverted with no test failing:
   - `item_form_live.ex:2078` `move_error_message/1`.
   - `category_form_live.ex:163-201`: the `"category:"` branch where the parent is gone gives `:parent_not_found`, and there is `move_error_message/1`.
   - `catalogue_detail_live.ex:2114`: the new clause. Removing it gives a `CaseClauseError` crash, not a failing test. Scenario: the target catalogue is trashed after the modal opened.

4. **`catalogue_detail_live.ex:2090-2094`** — **MEDIUM, verified.** The broadcast to the destination catalogue is the only one it gets, because the context call is muted. No test subscribes to check it.

5. **`catalogues_live.ex:2284, 3944-3948`** — **LOW, verified.** No tests for:
   - the in-flight guard: a second confirm while that source is still being copied;
   - the generic "Failed to duplicate the catalogue." (`:failed` after a raise or exit);
   - the `:not_found` path, which shows "Not found." where the request path says "Catalogue not found.";
   - `set_duplicate_choices` when no dialog is open.

   `:already_duplicating` (`duplication.ex:333`) is only covered by sending the finish message by hand. A real test needs two DB connections, so it probably can't run in the sandbox.

6. **`extensions.ex:101`** — **LOW, verified.** The "returned a non-map" branch and a `nil` return (namespace dropped) are untested; only the raise path is. `duplicate_category` through the hook and the catalogue row with `files: false` are also untested.

7. **`category_form_live.ex:209`, `item_form_live.ex:1381-1394`** — **LOW, verified.**
   - No test sends an unoffered value to the category form's `select_move_target`; the item form has one.
   - The "%{catalogue} — top level" / "— no category" labels are never asserted.
   - Leaving out the item's own category, and its own no-category slot when it has no category, is untested.
   - The option names are not localized (unlike the detail modal), same as before this branch.

8. **Open-state fix for the collapsible sections** — **LOW, verified.** The fix is pinned for `#category-move-section` and `#item-move-section` only. The same change on `#category-danger-zone` (`category_form_live.ex:1025`) and `#item-meta-section` (`item_form_live.ex:3542`) is unpinned.

9. **Test smells** — **LOW.**
   - `catalogues_live_duplicate_test.exs:95`: `refute … "(copy)"` can never fail, since no copy was started.
   - `item_form_live_extra_test.exs:78`: `assert Process.alive?` (older code).
   - `catalogue_detail_cross_catalogue_move_test.exs`: confirm, disposition and line 76 are sent as events by name. The catalogue and target selects do go through their real forms.

### Checked and sound

- **Catalogues vs code:** every Gettext string on the added lib lines is in `default.pot` and all five `.po` files. All 1084 msgids match across the six files.
  - All 23 new or changed msgids have non-empty, sensible et and ru translations, and all 23 are pinned in `test/gettext_test.exs`.
  - Reused strings ("Catalogue", "Duplicate", "Moving...", "-- Select catalogue/category --") are translated in et and ru.
  - Nothing is stale: "Move this category … to a different catalogue." was reworded in place, and every other string removed from code is still used elsewhere.
  - ru "товары" matches the existing Duplicate strings.
- **Wrapping:** every user-facing string in the changed web code goes through Gettext: flashes, labels, prompts, option labels, the "(this catalogue)" suffix, the dialog, choices and hints. No `String.capitalize` on translated text, and no new label maps kept in module attributes.
- **Error messages:** `:kind_mismatch` and `:already_duplicating` have `message/1` clauses and exact-string pins. Every other atom the UI passes to `Errors.message` (`:catalogue_not_found`, `:catalogue_moved`, `:not_found`, `:same_catalogue`, `:parent_not_found`, `:would_create_cycle`, `:category_not_found`) is already covered. `:invalid_uuid` can't reach the detail page because selections are validated first (`sanitize_uuids`).
- **Activity metadata:** only uuids, counts, choice keys and row names; no PII. Logging happens only on success.
- **Context tests:** the error paths are well covered: trashed or unknown destination, malformed uuid, other kind, trashed row, out-of-scope rows, and a selected child moving with (or without) its selected parent. `create_category` validation errors still return a changeset (`catalogue_test.exs:587-619`). The duplicate choices are tested in the context and through the dialog form (`form/3`). The browse CSS fix is pinned.

## Agent 3: PubSub, cleanliness and public API

I checked every item on your list against the lib diff (upstream/main..HEAD). No tests were run. I found 2 low-severity bugs, and the rest are improvements and nitpicks. Paths below are relative to `lib/phoenix_kit_catalogue/`.

### Findings

1. **`catalogue.ex:2551` and `2580` — BUG (low), verified against Ecto's source.** `valid_uuid?/1` relies on `Ecto.UUID.cast/1`, which accepts any 16-byte binary.
   - `check_move_parent!` then runs `{:ok, raw} = Ecto.UUID.dump(parent_uuid)`. `dump/1` rejects raw 16-byte input, so a raw `parent_uuid` passed to `move_category_to_catalogue/3` or the bulk move raises a `MatchError`.
   - The advisory-lock keys are also built from `to_string(raw)`, which differs from the canonical uuid. `check_move_destination!` refuses those moves later, so no data goes wrong.
   - The LiveViews never send raw uuids, so only direct callers of the context are exposed. The rest of the codebase uses the `{:ok, ^uuid}` canonical check (`browse.ex:230`, `item_picker.ex:600`); this helper should too.

2. **`web/item_form_live.ex` `perform_move` (~2045), with `catalogue.ex` `move_item_to_catalogue` — BUG (low), verified by reading.** `socket.assigns.item` is never refreshed when another tab moves the item (the `:item` handler at ~2013 only refreshes files).
   - If the item was moved from A to B, picking "A — no category" matches `uuid == item.catalogue_uuid`. The item is then uncategorized in B instead of moved to A, and the page still shows "Item moved."
   - The public guard `catalogue_uuid == item.catalogue_uuid -> :same_catalogue` has the same stale-struct problem. It is redundant, because the locked path checks this again.

3. **`catalogue/duplication.ex` `copy_catalogue` / `free_copy_number` — IMPROVEMENT; the logic is verified, the real-world impact is unsure.**
   - The source catalogue's lock is taken before the global `"catalogue:copy-names"` lock, and that lock is held until commit (`timeout: :infinity`).
   - A second copy of catalogue Y therefore holds Y's lock for the whole of the first copy's run. During that time, trash, restore, move and reparent on Y all wait. Reparent now takes `lock_catalogue!`, so this includes tree drag-and-drop.
   - A long wait could hit the query timeout inside a LiveView event.
   - Fix: choose the name at the end of the copy, or take the name lock first.

4. **`catalogue.ex:6125` — IMPROVEMENT (dead code), verified.**
   - `bulk_move_items_to_category/3`, `log_bulk_move/4`, `move_items_locked/3` and `resolve_move_target/2` are now called only from tests.
   - `log_bulk_move` nearly duplicates `log_bulk_item_move`. Either make the old function a wrapper around `bulk_move_items/3` or remove it.
   - Two error-log labels in the detail page still use the old names: `web/catalogue_detail_live.ex:2118` says `"bulk_move_items_to_category"` and `:2403` says `"bulk_move_categories_under"`.
   - The flash "Items can only be moved within this catalogue." is now misleading.

5. **`catalogue.ex:6745` `same_kind/2` vs `:2557` `check_move_destination!/2` — IMPROVEMENT.** These are two separate kind checks. `same_kind` reads without a catalogue lock. A catalogue's kind can still change through `update_catalogue` (this predates the branch).

6. **Move-option helpers repeated across the two forms — IMPROVEMENT, verified.**
   - `item_form_live` `item_move_options` (standard branch) nearly duplicates `category_form_live` `catalogue_move_options`.
   - `move_option_values` and `move_error_message` also exist in both files, in slightly different forms. A shared helper in `Web.Helpers` would cover all three.
   - `list_all_categories` already returns labels like "Catalogue / A", so the catalogue name repeats inside its own option group. It also loads categories from catalogues of the other kind.

7. **`catalogue/duplication.ex` calls `PhoenixKitCatalogue.Catalogue.lock_catalogue!` — IMPROVEMENT.** A submodule now calls back into the parent context. The lock helpers could move into their own submodule.

8. **`catalogue.ex:~2340`, bulk category move — IMPROVEMENT, unsure.** Nested selections are processed in input order.
   - Example: A > B > C all selected, and A's move is refused. If C comes before B in the list, C is detached and lands at the top level, and B then moves without it.
   - Sorting the nested ones by depth fixes this.

9. **`catalogue.ex:~2425` — NITPICK.** An invalid `parent_uuid:` returns `:catalogue_not_found`; it should be `:parent_not_found`.

10. **Specs — NITPICK.**
    - `move_item_to_catalogue`'s `@spec` omits `:catalogue_moved`, which `locked_transaction` can return after three attempts.
    - `lock_catalogue!/1` is now public but has no `@spec`.

11. **`catalogue.ex:2546` `broadcast_moved_out/1` — NITPICK.** The same pair of broadcasts is written out again inline in `do_bulk_move_categories_to_catalogue` (6309).

12. **Duplication locking style — NITPICK.**
    - `claim_copy_of!` and `free_copy_number` use the single-key `hashtext` advisory lock (the global key space). `lock_catalogue!` uses the two-key form with a class key.
    - They call `SQL.query!` where `lock_catalogue!` uses `repo().query!`.
    - `1..10_000` and the lock-name strings are inline magic values.

13. **Docs out of step with code — NITPICK.**
    - The `bulk_move_items` doc says every uuid must be a live item or nothing moves, and also says trashed items are skipped. The code does not check status.
    - The Duplication moduledoc says every copy path goes through the extension callback, but the catalogue row skips it (`copy_data`, line 664).

14. **`web/catalogues_live.ex` — NITPICK.**
    - Line 192: the finished handler reloads the index even when another tab is active, and the `:catalogue` broadcast already reloads it.
    - Line 3914: `{:ok, _pid} =` is a hard match on `start_child`, so an error return crashes the page.
    - `duplicate_error_message(:not_found)` shows "Not found." instead of "Catalogue not found."
    - `@duplicate_defaults` sits above the `import`s.

### Checked and sound

- **PubSub helper and topic:** every broadcast goes through `Catalogue.PubSub`, and the topic string appears only in `pub_sub.ex`.
- **Broadcasts after commit:** all happen after the transaction returns.
- **Both catalogues told about cross-catalogue moves:**
  - Single item move: the log names the target, plus a source broadcast.
  - Single category move: the log names the target, plus `:category`/`:item` broadcasts to the source.
  - Bulk item move: the page mutes the context and broadcasts both catalogues itself.
  - Bulk category move: per-row broadcasts are muted, then one batch event goes to each touched catalogue.
- **Duplicate:** broadcasts once for the copy, honours `broadcast: false`, and writes one activity row.
- **Payloads:** only uuid or nil.
- **handle_info:** all four touched pages have a catch-all, and the duplicate-finished clause (line 175) comes before it (line 210).
- **Task:** the copy runs under `Task.Supervisor.start_child`, not `Task.start`, and the runner catches raises and exits.
- **Cleanliness:** no `IO.inspect`/`IO.puts`, no TODO/FIXME/HACK/XXX, no commented-out code.
- **@spec/@doc and delegates:** present on `bulk_move_items/3`, `bulk_move_categories_to_catalogue/4`, the `move_*` functions, `duplicate_catalogue/2`, `catalogue_copy_counts/1` and `Extensions.duplicate_data/2`. Both Duplication functions are re-exported from `Catalogue`, and the pages call only the context.
- **New error atoms:** `:already_duplicating` and `:kind_mismatch` have `Errors` clauses and test pins.
- **Module attributes:** all new ones are used.
- **Lock ordering:** item-move and subtree-move ordering cannot deadlock, and the known guards (subtree row locks, `FOR SHARE` on the parent in `create_category`, items-then-tree read under the lock) are in place.
- **Quadratic list work:** the log lists are fixed with `in_order`; no other O(n²) found.
- **Client input on the pages:** item uuids are sanitized, and catalogue and category choices are checked against what the page offered.

## Agent 4: host-integration boundaries

I audited the four boundaries by reading code only; nothing was edited or run. No boundary breaks today. There are four low-severity gaps (one of them a test gap).

### Broken or under-tested boundaries

**1. Ecommerce keeps Shopify collection ids on category copies. Low, verified.**
- **Consumer:** `phoenix_kit_ecommerce/lib/phoenix_kit_ecommerce/catalogue/extension.ex:65` returns category data unchanged. Its doc at `:60` says "Category fields hold no such ids", which is wrong.
- **Where the ids come from:** `phoenix_kit_ecommerce/lib/phoenix_kit_ecommerce/shopify/collection_sync.ex:309-331` writes `data["ecommerce"]["shopify"]["collection_id"]` on categories. `CategoryCommerce.cast/2` keeps unknown keys (`Map.merge(current, storage)`), so the id survives form saves.
- **Producer:** `phoenix_kit_catalogue/lib/phoenix_kit_catalogue/catalogue/duplication.ex:876` → `extensions.ex:76`.
- **Why nothing breaks yet:** collection sync matches categories by slug, then by name (`collection_sync.ex:295-307`), and nothing else reads `collection_id`. A copy therefore just carries a stale id.
- **Fix:** drop `"shopify"` for `:category` too, or at least correct the doc.

**2. A malformed extension registration makes every copy crash. Low, verified.**
- `extensions.ex:89-91`: `copy_aware?/1` calls `Code.ensure_loaded?(ext)` without a `rescue`.
- I confirmed that `Code.ensure_loaded?("x")` raises `FunctionClauseError`. So if any registered module's `catalogue_extensions/0` list contains a non-atom, the error is raised inside the copy transaction and every Duplicate fails.
- `all/0` doesn't have this problem because `enabled?/1` (`:161`) rescues first. The docs promise per-extension resilience.
- Minor, same area: `run_duplicate/3` (`:96-117`) rescues raises only, not throws or exits (the `absorb` path's doc covers all three).

**3. Ecommerce's integration test assumes the new catalogue. Low (test infrastructure), verified.**
- `phoenix_kit_ecommerce/test/phoenix_kit_ecommerce/catalogue/duplicate_data_catalogue_integration_test.exs` calls `Catalogue.duplicate_catalogue/1`, which only this branch adds (`catalogue.ex:397`), and expects the hook.
- `test/test_helper.exs:251-262` skips `:catalogue` tests only when catalogue isn't loaded at all. With `PHOENIX_KIT_CATALOGUE_PATH` pointing at an older catalogue checkout, the test fails instead of being skipped. The moduledoc says it is "excluded ... whenever the optional dependency isn't present", which doesn't cover this case.
- **Coverage gap:** the test copies only an uncategorized item. The single `duplicate_category` path and items inside a copied category aren't covered with ecommerce. Catalogue's own test (`test/catalogue/duplicate_catalogue_test.exs:424`) covers the shared code path with a fake extension.

**4. Three-letter extension keys get treated as language entries. Low, verified by reading the regexes; no current extension is affected.**
- `duplication.ex:657` treats any key matching `^[a-z]{2,3}(-…)?$` as a language entry and adds the "(copy)" suffix to its `"name"`/`"_name"`.
- `extensions.ex:41` only rejects two-letter keys. An extension keyed `"crm"`, `"erp"` or `"pos"` would get its own `name` field renamed on copy. `"ecommerce"` is safe.

**Note, unsure whether intended:** a single-category Duplicate doesn't re-point `featured_item_uuid`; only whole-catalogue copies do (`duplication.ex:400`). The copied category keeps showing the source item.

### Checked and sound
- **Hook reached on every copy path:**
  - Item: `duplication.ex:575`.
  - Category: `:876`, including items nested inside it.
  - Whole catalogue: its categories and items (including uncategorized items via `copy_loose_items`) go through the same functions; the catalogue row itself is skipped on purpose (`:368`, `:664`).
  - Bulk duplicates delegate to `duplicate_item`/`duplicate_category`.
  - The hook runs before the reference re-pointing step, so the dropped `legacy_product_uuid` is never re-pointed.
- **Contract match:** ecommerce handles only `:item`/`:category` and returns a map. It drops `shopify` (handle, product_id, variant_ids, image_ids, set_slugs) and `legacy_product_uuid`, which are exactly the keys that collection sync, media sync and product diff match on.
- **Discovery:** it covers disabled extensions via `ModuleRegistry.all_modules/0`. `catalogue_extensions` is defined only in ecommerce (`phoenix_kit_ecommerce.ex:811`) among the sibling repos.
- **Older catalogue:** ecommerce's extension references no catalogue module, so it compiles fine. An older catalogue simply never calls `duplicate_data/2`, so copies keep the Shopify link as they did before this branch.
- **`css_sources/0`** (`lib/phoenix_kit_catalogue.ex:132`) returns `[:phoenix_kit_catalogue]`, so the whole package is scanned. `max-w-none` is a standard utility written as a literal in `browse.ex:1003`, so hosts pick it up on their next CSS build.
- **Sibling API calls:** among the functions you listed, the only sibling call is `Catalogue.create_category` at `collection_sync.ex:317`.
  - It passes `parent_uuid: nil`, so the new `FOR SHARE` parent read never runs.
  - The return shape is still `{:ok, _} | {:error, changeset}`, and the sync runs outside any transaction.
  - Placement goes through `update_item`, which this branch didn't change; its handling of a refused category (`:486-497`) is unaffected.
  - No sibling calls the move, duplicate or bulk-move functions, so the new `:kind_mismatch`, `:not_found` and `:catalogue_not_found` refusals can't reach one.
- **PubSub:** new broadcasts reuse `{:catalogue_data_changed, kind, uuid, parent}` with the existing kinds `:item`, `:category` and `:catalogue`. The only subscriber, CRM (`phoenix_kit_crm/lib/phoenix_kit_crm/web/company_show_live.ex:285-303`), matches those kinds and has a catch-all. No new message shapes are emitted.

---

# Release review (post-merge)

**Reviewer**: Claude (Opus 5), release review of merge `0b671e4` plus the lock-only `0b3427d`. Two read-only agents covered the fix commits that landed after the review above (`ab9b2eb` and `f2cffb1` for duplication; `ad159af` and `d9c5ff8` for moves and restores). Every finding below was re-checked against the code, and the bugs were reproduced with a failing test before they were fixed.
**Date**: 2026-09-17

## Findings

### BUG - MEDIUM: a category move carried trashed rows stamped for a root it left behind

- **Trigger:** R > C > D, with item I in D. Trash R, then restore C on its own; D and I stay trashed, stamped `root: R`. Move C to another catalogue (`move_category_to_catalogue`) or under another parent (`move_category_under`).
- **Effect:** R's restore walks R's *current* subtree, which no longer holds D or I, so no Restore brings them back together. D's Deleted card counts 0 items, and restoring D leaves I trashed inside it. This breaks the "a restore undoes exactly the trash" invariant. The reparent case is older than this PR; the cross-catalogue case makes it permanent.
- **Why the randomized test missed it:** it had no move op, and no invariant checked that a stamp's root still covers its row.

### BUG - MEDIUM: an upper-case uuid crashed the detail page's bulk item move (introduced by `ad159af`)

- `ad159af` narrowed the context's `valid_uuid?/1` to the canonical form, so `bulk_move_items` returns `{:error, :invalid_uuid}` for an upper-case or raw 16-byte uuid. `sanitize_uuids/1` in `catalogue_detail_live.ex` still let those through (`Ecto.UUID.cast/1` accepts them), and `do_bulk_move_items/3` had no clause for that error. Result: `CaseClauseError`, and the LiveView crashes. Forged input only.

### IMPROVEMENT - MEDIUM: the bulk category move checked its scope without a lock

- `move_one_category_to_catalogue/3` compared the scope on an unlocked `get_category`, and `move_category_to_catalogue/3` never re-checked it under the lock. If another admin moved the category from A to X in between, the bulk run moved it out of X, and the batch broadcast named A, so pages open on X heard nothing.

### NITPICK: crash logs could still carry values (`catalogues_live.ex`)

- The `:DOWN` clause logged `inspect(reason)`; a throw's reason holds the thrown value.
- `Exception.format_stacktrace/1` prints a `FunctionClauseError`'s arguments in the top frame. A1.4 set out to keep both out of the log.

### NITPICK: an extension `key/0` that throws or exits aborted every copy

`copy_aware?/1` and `valid_key?/1` in `extensions.ex` only `rescue`, so A4.2's "throws and exits are caught" held for `duplicate_data/2` but not for `key/0`. The `Extension.duplicate_data/2` callback doc also still said only "a raise drops the namespace".

### NITPICK: a forged non-string `parent_uuid` crashed the category form

`select_parent_move_target` stored any value, and `move_category_under/3` has no clause for a non-binary parent. Older than this PR.

### Stale test after the lock bump (not a PR bug)

`0b3427d` moved to phoenix_kit_entities 0.4.16, which renders decimal fields with core's `<.decimal_input>` (text + `inputmode="decimal"`, no `step`). `item_form_live_test.exs` still asserted `step="any"`, so `mix test` failed 1 of 3068.

### Declined

- **`move_category_under/3`'s same-parent clause decides from the caller's struct.** A stale form can flash "moved" without writing anything; nothing is lost, and the page shows the real tree on reload.
- **Item `position` is kept on a move**, so it can collide in the destination bucket. Older than this PR; ordering falls back to name.
- **`:invalid` and `:missing_catalogue_scope` have no `Errors.message/1` clause.** Both only reach the bulk errors list that is logged, never a flash.
- **`owned_keys/0` computed per copied row; `free_copy_number/1` returns `nil` past 10,000 copies; runtime `Gettext.gettext` in the new HEEx attributes.** Negligible cost, unreachable, and covered by the existing TODO and the hand-maintained `.pot`, respectively.

## Checked and sound

- **The duplicate task:** `async_nolink` under `PhoenixKit.TaskSupervisor`, which core's supervisor starts in hosts. The success and `:DOWN` clauses both clear the tracking map, and `demonitor(:flush)` runs on success. After a remount, the database try-lock still refuses a second copy.
- **Lock order:** a copy takes the per-source try-lock, then copy-names, then the source lock, and no other caller takes copy-names. Moves take both catalogue locks in sorted order before any row locks.
- **`d9c5ff8`'s `restamp_left_behind!`** and `ad159af`'s shallowest-first ordering are correct.
- **Gettext:** every new msgid is in the `.pot` and all five locales, and is pinned.
