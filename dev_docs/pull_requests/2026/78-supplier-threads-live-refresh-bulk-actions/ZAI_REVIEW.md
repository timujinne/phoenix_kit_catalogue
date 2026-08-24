# PR #78 — ZAI review

**Reviewer**: GLM-5.3 (Z.ai, `zai -p`)
**Scope**: Full lib/ diff of `upstream/main..main`
**Date**: 2026-08-24
**Method**: Diff piped on stdin; concrete defects only

Verbatim output; every claim was re-verified against the code before acting — see `FOLLOW_UP.md` for the verdict on each.

---

## Defects

**1. `import_live.ex` — `handle_info({:import_result, result}, socket)` (unguarded clause).**
`stop_import_monitor/1` (reset path, added with the comment "the button pressed while a task was running") demonitors and clears `import_task`, but the task still holds `lv_pid` and delivers its result. The clause has no step/task guard, so after abandoning a running import the wizard is later yanked to `step: :done` with the stale report (and logs an activity entry) from whatever step the user has reached. Fix: guard the clause with `%{assigns: %{step: :importing}}` (or match a task ref tag).

**2. `catalogue_detail_live.ex` — `do_bulk_trash_items/2`, `do_bulk_restore_items/2`, `do_bulk_permanent_delete_items/2`, `do_bulk_move_items/2`, `do_bulk_duplicate_items/2`.**
These mute the context (`muted_actor_opts`), which discards the per-touched-catalogue set the context computed (`broadcast_item_batch/2` in `catalogue.ex`), then re-emit only `broadcast_item_batch(socket)` for `socket.assigns.catalogue_uuid`. The uuid lists are client-captured and never validated to belong to the current catalogue, so a mixed/foreign list trashes items in catalogue B while only catalogue A's pages are notified — B's open index/detail tabs stay stale indefinitely. Fix: drop the mute and let the context broadcast its full catalogue set (ordering concern is already handled by mailbox ordering on the same topic), or return the set and broadcast it.

**3. `catalogue_detail_live.ex` — `refresh_supplier_costs/1`.**
It re-derives costs only from `socket.assigns.items`. While a search is active the page renders `search_results`, so a supplier-price edit in another tab broadcasts `:item_supplier_info`, the handler runs, and the visible search grid keeps the old price. Fix: merge `Catalogue.supplier_cost_ranges` over `search_results`' uuids too when `search_query != ""`.

**4. `catalogue_detail_live.ex` — `handle_catalogue_data_changed/1` pending skip is over-broad.**
While `bulk_change_pending: true` (the flash-delay window), *every* `:catalogue_data_changed` is dropped, not deferred — a concurrent `:category` or `:item_supplier_info` write landing in that window is lost permanently (the deferred `:bulk_change_apply` reloads the level but never refreshes supplier costs, and category fan-out from another op isn't re-run for open forms). Fix: only suppress the `:item`/`:category` kinds the apply path reloads; pass others through.

**5. `attribute_sets.ex` — orphan prune `PubSub.broadcast(:attribute_set, set_uuid)`.**
The prune is machine-originated and PubSub-driven; if `prune_orphans` runs inside `repo().transaction` (as the sibling destructive paths do), this is a pre-commit broadcast — the exact class commit 7534a54 fixed for the PRO100 loader. Verify and move it after commit if so.

**6. Gettext — new msgids with no `priv/` additions in this diff.**
`"%{name} (copy)"` (written into stored `data` — every copy name in every language), `"Supplier price"`, `"Import Failed"`, `"Attribute group not found."`, `"The import stopped unexpectedly before it finished. Rows written before the failure were kept. Check the server log for details."`, `"About this supplier for this item only. The company's own comments stay on its CRM page."`, `"Each copy is named after its original with \"(copy)\" added and placed right after it."`, plus the bulk-move/duplicate modal strings. If any is absent from `priv/gettext/*/LC_MESSAGES/default.po` it renders raw English (and `"%{name} (copy)"` bakes untranslated suffixes into item data). Fix: add all to the `.po` files in this PR.

**7. Test gap — `item_supplier_infos.ex` `delete/2`.**
Any existing test asserting `{:ok, _}` passes unchanged whether the row is hard-deleted or closed, i.e. it would pass if the change regressed to `Repo.delete`. Tests must assert `Repo.get!(ItemSupplierInfo, uuid).valid_to != nil` and that re-creating the pair resumes the thread (`inherited_thread/2` returns the old thread uuid).

**8. `duplication.ex` — `copy_supplier_rows/2` drops `valid_from`.**
`@supplier_fields` omits it, so every copied current row resets its price validity to the changeset default (today) — wrong result for a row valid since last year. Fix: add `:valid_from` (and `:valid_to` semantics are already filtered by `is_nil`) to `@supplier_fields`.
_broadcast(uuid, opts)`.

8. **`attachments.ex` `refresh_files` is a no-op when this tab has no folder pointer.** `handle_info(:item)` in `item_form_live` routes to `Attachments.refresh_files/1`, which re-reads `files_folder_uuid`. If the first-ever upload happened in *another* tab (folder created there), this tab's assign is still `nil`, so the grid never picks the files up until reload. Fix: on refresh, resolve the folder by the deterministic `catalogue-item-<uuid>` fallback the same way `source_folder_uuid/1` does.

Items 1–4 are regressions/ships in this PR; 5–8 are verify-then-fix. No test files were included in the diff, so regression coverage for the fan-out ordering (muted-context → `broadcast_bulk_change` → batch `:item`) couldn't be assessed.
