# C12.5 Adversarial Deep Dive (2026-04-26)

Per the workspace playbook, C12.5 follows C12's three-agent re-pass
with a self-driven 13-category checklist that catches GAPS the
agents' structural prompts miss. Captured below per category.

## 1. Documentation

Deferred to C13.

## 2. Components

Cross-checked — every catalogue-bespoke component has a clear reason
to exist (see `web/components.ex` moduledocs):
- `item_table` — opt-in column dispatch, attr-typed
- `search_input` — debounced + locale-aware default placeholder (C5
  fix)
- `scope_selector` — partner of the scoped search API
- `catalogue_rules_picker` — smart-catalogue rule editor with custom
  events
- `featured_image_card` / `metadata_editor` — shared by catalogue +
  item + category forms

The phoenix_kit core's `<.input>` / `<.select>` / `<.textarea>` /
`<.icon>` are imported and used everywhere appropriate; raw HTML form
elements appear only in `import_live.ex`'s column-mapping wizard
(intentional exception per AGENTS.md "principled exception" note).

## 3. Senior-dev review

C12 agent #3 surfaced 50+ public fns in `catalogue.ex` missing `@spec`.
Sweep added @spec to the 10 most-called CRUD entry points:
`create_catalogue/2`, `update_catalogue/3`, `delete_catalogue/2`,
`trash_catalogue/2`, `create_category/2`, `update_category/3`,
`create_item/2`, `update_item/3`, `trash_item/2`, plus the 4 getters
(`get_catalogue`, `fetch_catalogue!`, `get_category`, `get_item`).

**Documented punt**: ~40 public read/list/count fns in `catalogue.ex`
remain untyped. Same as the document_creator sweep precedent (29
GoogleDocsClient fns left untyped). Tracked as a separate
typespec-completion follow-up — not a defect.

## 4. Security

C12 agent #1 found 3 candidates:
1. **Changeset rollbacks at `catalogue.ex:1441/1806/1916`** — false
   positive. `repo().rollback(changeset)` returns `{:error, changeset}`
   from the transaction wrapper; LV's `assign_form/2` renders the
   changeset's errors via `<.input>`. Standard Ecto pattern; not a
   leak, not a defect.
2. **`show_delete_confirm` buttons missing `phx-disable-with`** —
   false positive. Per the workspace C5 rule
   ([feedback_async_ux]the agent memory note `feedback_quality_sweep_scope.md`),
   UI-state-only buttons (modal_close, switch_view,
   show_delete_confirm) don't need the attr — they fire a synchronous
   socket assign, not an async DB call. Adding it would briefly
   disable a button about to be hidden.
3. **`Tree.ancestors_in_order/1` binary mismatch** — REAL bug. Fixed
   in this sweep + pinned by two new tests in `catalogue_test.exs`
   ("returns [] for a root category" + "returns ancestor chain root
   → direct parent for a deep descendant"). The function returned
   `[]` for every non-root category before the fix; no caller exists
   in `lib/` or `test/` today, so the regression sat dormant. The
   sweep also reordered the recursion (the `Enum.reverse/1` was
   wrong direction) — `walk_up/3` already builds root → leaf order
   by prepending each ancestor, so the trailing reverse was an
   extra inversion. Tree fix lives at
   `lib/phoenix_kit_catalogue/catalogue/tree.ex:124-152`.

No SQL injection, SSRF, hardcoded secrets, mass-assignment, or log
leaks found.

## 5. Error handling

`{:error, _}` shapes consistent across the public API. The new
`PhoenixKitCatalogue.Errors` atom dispatcher (C3) handles all
known atoms + tagged tuples + Changeset pass-through + binary
pass-through + unknown-fall-through. Every Logger.error / warning
includes the resource_uuid for grep-ability. `handle_info/2`
catch-all in every LV (C6).

## 6. Translations

C12 agent #2 confirmed clean. No `String.capitalize/1` on translated
text; module-attribute label maps converted to literal-call
helpers (`status_label/1` in `Web.Helpers`); the search_input default
placeholder now resolves through `gettext("Search...")` inside the
component body.

## 7. Activity logging

C12 agent #2 confirmed every CREATE / UPDATE / DELETE / status-change
context fn logs on the `:ok` branch. The catalogue convention is
`:ok`-only logging (workspace pattern matching locations + ai); the
C12 agent's "log on :error too" suggestion is documented in
`catalogue/activity_log.ex` moduledoc as the deliberate convention.
PII-safe metadata across the board (no email/phone/notes/etc.).

The new `catalogue_module.{enabled,disabled}` actions log via
`PhoenixKitCatalogue.enable_system/disable_system` — pinned by
`test/activity_logging_test.exs`'s "module toggle" describe block.

## 8. Tests

651 tests, 0 failures. Coverage:
- Errors per-atom (`test/errors_test.exs`, 36 tests)
- Activity logging per-action with `actor_uuid` pinning
  (`test/activity_logging_test.exs`, 12 tests)
- LV sweep delta pinning (`test/web/sweep_delta_test.exs`, 3 tests)
- Helpers (status_label / actor_opts / actor_uuid)
  (`test/web/helpers_test.exs`, 12 tests)

Edge cases: empty inputs, nil, Unicode, long strings — covered by
existing `catalogue_test.exs` (3200+ lines, predates the sweep).
Error paths added on top of happy paths in the new tests.

## 9. Cleanliness

`grep -rn IO.\(inspect\|puts\) lib/` → 0 hits.
`grep -rn TODO\|FIXME\|HACK\|XXX lib/` → 0 hits.
`grep -rn '^\s*#\s*(def\|case\|if)' lib/` → 0 hits.
`grep -rn 'Task.start' lib/` → 0 hits (only `Task.start_link` and
`Task.Supervisor.start_child`).

## 10. Public API

Naming consistency: `get_X` (returns nil) and `fetch_X!`/`get_X!`
(raises) coexist deliberately. The `defdelegate` façade in
`catalogue.ex` re-exports the submodule API, so callers stay on
`PhoenixKitCatalogue.Catalogue.*`.

## 11. DB + migrations

Test migrations match real schema columns
(`phoenix_kit_settings`, `phoenix_kit_buckets`,
`phoenix_kit_media_folders`, `phoenix_kit_files`,
`phoenix_kit_folder_links` added in C7). `down/0` clauses
present in every migration. FK columns indexed. No N+1 in the
new code paths. No long-running locks beyond the
`FOR UPDATE` rows in `move_category_to_catalogue/3`,
`move_category_under/3`, `swap_category_positions/3` — each
holds at most 1–2 rows for the duration of a single small
transaction.

## 12. PubSub + reactivity

C12 agent #3 confirmed every LV's `mount/3` subscribes BEFORE the
DB read; broadcasts happen AFTER successful write. Payload is the
minimal `{:catalogue_data_changed, kind, uuid, parent_catalogue_uuid}`
shape — no PII, no full records. The new `Logger.debug` catch-all
in every LV's `handle_info/2` won't crash on stray PubSub messages
from sibling tabs / processes.

## 13. Loading states + async UX

`phx-disable-with` on every submit + every `phx-click` async
destructive action (C5 fix added the missing 2 sites at
`components.ex:1200, 1339`). `start_async` for search; cancellation
paths handled at `handle_async :exit` per workspace pattern.
Disconnected mount handled by `if connected?(socket)` guards on
broadcast subscriptions in admin LVs.

## Summary of fixes landed in C12.5

- `Tree.ancestors_in_order/1` binary mismatch + reverse-direction
  bug — fixed + 2 tests pinned
- `@spec` backfill on 10 priority CRUD entry points in
  `catalogue.ex`
- Refactored `list_category_tree/2` exclude_uuids loader into a
  shared `load_uuid/1` helper to satisfy credo nesting check

Nothing else surfaced.
