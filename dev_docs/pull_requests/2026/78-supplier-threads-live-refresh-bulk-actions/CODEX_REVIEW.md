# PR #78 — Codex review

**Reviewer**: Codex (gpt-5.6, `codex exec`, repo-anchored)
**Scope**: `upstream/main..main`, lib/ + tests
**Date**: 2026-08-24
**Method**: Read the diff and the surrounding code; asked for concrete defects only

Verbatim output; every claim was re-verified against the code before acting — see `FOLLOW_UP.md` for the verdict on each.

---

- `lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex:1038` — Bulk category deletion validates only UUID syntax; forged selections can trash a category from another catalogue, including descendants/items. Fix: pass the current `catalogue_uuid` into the context and reject every out-of-scope category before mutation.

- `lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex:938`, `:994` — Bulk category move and item/category duplication likewise trust client-supplied UUIDs. Foreign items can be duplicated while broadcasts are emitted only for the displayed catalogue, leaving its real catalogue stale. Fix: enforce source catalogue scope in context functions and broadcast every affected catalogue.

- `lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex:895` — Picker `phx-change` handlers update `nil`/empty modal maps and accept arbitrary target strings; stale events raise `KeyError`, while malformed UUIDs later raise `Ecto.Query.CastError` in `Repo.get/2`. Fix: no-op unless the expected modal is open and accept only UUIDs present in that modal’s target list.

- `lib/phoenix_kit_catalogue/catalogue/duplication.ex:566` — Duplicate placement reads and renumbers siblings without locking. Concurrent duplications can assign identical positions or overwrite each other’s ordering. Fix: acquire a transaction-scoped lock keyed by catalogue and sibling scope before inserting/renumbering.

- `lib/phoenix_kit_catalogue/catalogue/duplication.ex:553` — A duplicate category’s target parent is read without a lock. A concurrent parent move can leave the copy’s `catalogue_uuid` different from its parent’s catalogue. Fix: reload the parent with `FOR SHARE` inside the duplication transaction.

- `lib/phoenix_kit_catalogue/catalogue/item_supplier_infos.ex:281`, `:457` — Delete and revision check `valid_to` on stale structs without locking. Concurrent operations can resurrect a removed supplier or report deletion while a new current revision survives. Fix: lock and reload the current row, re-check currentness, then close/insert atomically.

- `lib/phoenix_kit_catalogue/catalogue/item_supplier_infos.ex:326` — `set_primary/2` permits closed historical rows, demoting current rows and leaving `primary_for_item/1` returning `nil`. Fix: lock/reload the target and require `valid_to == nil`.

- `lib/phoenix_kit_catalogue/catalogue/item_supplier_infos.ex:236` — Update casts `item_uuid` and `supplier_uuid` but preserves the existing comment-thread UUID, allowing comments to move/share across unrelated item-supplier pairs. Fix: make both identity fields immutable in the update changeset.

- `lib/phoenix_kit_catalogue/catalogue/item_supplier_infos.ex:54` — Cost ranges group `NULL` and `""` currencies separately, then normalize both to `nil`, producing duplicate, incorrect ranges. Fix: group by `NULLIF(currency, '')`.

- `test/web/live_surfaces_test.exs:377` — The import-monitor test only asserts the final task is `nil`; removing monitoring entirely still passes after a successful import. Fix: block the task and assert the intermediate `{pid, ref}` assignment.

- `test/catalogue/surface_broadcasts_test.exs:299` — The “post-commit” assertion receives only after the synchronous call, so an in-transaction broadcast also passes. Fix: have a subscriber query immediately upon receipt and assert committed data is already visible.
309 391
- `lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex:1038` — Bulk category deletion validates only UUID syntax; forged selections can trash a category from another catalogue, including descendants/items. Fix: pass the current `catalogue_uuid` into the context and reject every out-of-scope category before mutation.

- `lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex:938`, `:994` — Bulk category move and item/category duplication likewise trust client-supplied UUIDs. Foreign items can be duplicated while broadcasts are emitted only for the displayed catalogue, leaving its real catalogue stale. Fix: enforce source catalogue scope in context functions and broadcast every affected catalogue.

- `lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex:895` — Picker `phx-change` handlers update `nil`/empty modal maps and accept arbitrary target strings; stale events raise `KeyError`, while malformed UUIDs later raise `Ecto.Query.CastError` in `Repo.get/2`. Fix: no-op unless the expected modal is open and accept only UUIDs present in that modal’s target list.

- `lib/phoenix_kit_catalogue/catalogue/duplication.ex:566` — Duplicate placement reads and renumbers siblings without locking. Concurrent duplications can assign identical positions or overwrite each other’s ordering. Fix: acquire a transaction-scoped lock keyed by catalogue and sibling scope before inserting/renumbering.

- `lib/phoenix_kit_catalogue/catalogue/duplication.ex:553` — A duplicate category’s target parent is read without a lock. A concurrent parent move can leave the copy’s `catalogue_uuid` different from its parent’s catalogue. Fix: reload the parent with `FOR SHARE` inside the duplication transaction.

- `lib/phoenix_kit_catalogue/catalogue/item_supplier_infos.ex:281`, `:457` — Delete and revision check `valid_to` on stale structs without locking. Concurrent operations can resurrect a removed supplier or report deletion while a new current revision survives. Fix: lock and reload the current row, re-check currentness, then close/insert atomically.

- `lib/phoenix_kit_catalogue/catalogue/item_supplier_infos.ex:326` — `set_primary/2` permits closed historical rows, demoting current rows and leaving `primary_for_item/1` returning `nil`. Fix: lock/reload the target and require `valid_to == nil`.

- `lib/phoenix_kit_catalogue/catalogue/item_supplier_infos.ex:236` — Update casts `item_uuid` and `supplier_uuid` but preserves the existing comment-thread UUID, allowing comments to move/share across unrelated item-supplier pairs. Fix: make both identity fields immutable in the update changeset.

- `lib/phoenix_kit_catalogue/catalogue/item_supplier_infos.ex:54` — Cost ranges group `NULL` and `""` currencies separately, then normalize both to `nil`, producing duplicate, incorrect ranges. Fix: group by `NULLIF(currency, '')`.

- `test/web/live_surfaces_test.exs:377` — The import-monitor test only asserts the final task is `nil`; removing monitoring entirely still passes after a successful import. Fix: block the task and assert the intermediate `{pid, ref}` assignment.

- `test/catalogue/surface_broadcasts_test.exs:299` — The “post-commit” assertion receives only after the synchronous call, so an in-transaction broadcast also passes. Fix: have a subscriber query immediately upon receipt and assert committed data is already visible.
