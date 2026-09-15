# PR #118 — Zai review — catalogue detail page and counts

**Reviewer**: Zai (GLM-5.3), from a diff of `catalogue_detail_live.ex` and `catalogue/counts.ex` plus a written domain brief, no test runs
**Date**: 2026-09-15
**Scope**: commits `94b8cb6..210e0a2`

The answer arrived after `bbd0aed` had been written; the reviewer noticed uncommitted edits appearing mid-review and says its findings are against the committed diff.

Review of `94b8cb6..210e0a2` (phoenix_kit_catalogue: catalogue_detail_live.ex + counts.ex). Note: the working tree picked up uncommitted edits mid-review (file mtime 04:34, helpers like `item_in_catalogue` appeared between reads) — findings below are against the committed diff and verified against the pasted diff as ground truth.

**Areas checked and sound:**

- `counts.ex :restorable` mode — mirrors `restore_catalogue`'s filters exactly (stamped-with-catalogue/unstamped, blocked by a category that stays trashed, live legacy items kept); left join on `c.uuid` cannot fan out; no stale `mode: :all` callers remain.
- `trashed_item_counts_by_root` — grouping/types fine; a root trash card's Items/Subcats match what `restore_category` (stamped-root rows only, blocked by stays-trashed categories) really brings back.
- `resolve_node` rejecting trashed categories — the `:invalid` branch patches back to root with a flash; no crash or dead URL.
- Root Deleted listing vs counts — loose items (`outside_trashed_categories`) both listed and counted, has-more math consistent; tab = loose + top-level trashed categories.
- `top_level/2` partition — agrees with `normalized_category_rows`' orphan promotion; live children of trashed parents stay reachable at root.
- Opening-tab pick (`pick_counts`/`pick_view_mode`/`effective_view_mode`/`maybe_auto_flip_to_active`) — no-live-item → Active via categories; same-node reload keeps the tab; flip-to-active only fires when nothing is listed; no stranded no-tab state found.
- Deleted-tab search — `trashed: true` covers every trashed item per spec; `switch_view` clears the search so no active-mode grid strands on the trash tab; stamp guards drop stale async replies; later pages bake the same mode.
- Bulk-selection wiring — static scope ids, module JS presses `data-bulk-clear` on `phx:bulk_select:clear` (works on hidden toolbars), core hook prunes vanished rows; active/deleted toolbar wrappers are `:if`-gated; reorder hidden via the `data-bulk-action*=reorder` selector.
- Trash modal cascade default — `confirm_trash_category` maps it to `items: :cascade`; copy matches; bulk path snapshots uuids correctly.
- Category bulk restore / permanent-delete guards — catalogue + status enforced, parent-then-child batches counted honestly.
- Query budget — root reads one all-status tree shared by tabs/trash cards/counts; bounded extra counts; no per-row queries introduced.
- Deleted-tab rendering — `category_card` handles `patch: nil` inert (span fallback); column vocabulary includes "status" in header/body/card; the box branch is unreachable for trashed categories in deleted mode; DnD/reorder suppressed in the trash.

**Findings (most severe first):**

1. `catalogue_detail_live.ex:2717` (with 2582, `level_count_maps`) — open a live category's Deleted tab listing a trashed child card. Expected: card counts what its Restore brings back (stamped rows, same rule as root's `trash_unit_counts` at 2701). Actual: `level_count_maps(:deleted)` gives it *all* deleted items (`item_counts_by_category_for_catalogue` catalogue.ex:1409) and *all* deleted children — so the same card shows different, larger Items/Subcats than at root, and Restore restores fewer than promised.
2. `catalogue_detail_live.ex:6013` and `:5838` — in the Deleted tab's browse list, click a trashed item's name (table row via `item_pricing_cell edit_path={@edit_path_fn}`, card body link). Expected: inert name (the diff gates `edit_path` exactly this way on the search grid at 3941, and swaps the row menus to Restore/Delete Forever). Actual: navigates to the item Edit form of a trashed item (featured thumb also still opens the product card) — the trash isn't the closed unit the rest of the diff builds.
3. `catalogue_detail_live.ex:2012` / `:1989` / `:1358` — from the Deleted tab, bulk Restore / Delete Forever on items, or single Delete Forever on a category, with client-captured uuids (the toolbar pushes `%{"uuids" => [...]}`). Expected: rows outside the current catalogue rejected — the diff adds exactly that guard to bulk category restore/permanent-delete (2325, 2381). Actual: `bulk_restore_items`/`bulk_permanently_delete_items` pass raw uuids straight to the context, and the single `permanently_delete_category` has neither the catalogue nor a `status: "deleted"` check — a forged phx payload restores or hard-deletes rows of another catalogue.
4. `catalogue_detail_live.ex:847` — in the Deleted tab, search (matches trashed items), then Restore one row from the results grid. Expected: the row leaves the trash grid. Actual: `remove_item_locally` only edits `@items` and `refresh_counts` never re-runs the search — the restored (now live) item stays listed with a working Restore menu until the query is retyped.
5. `catalogue_detail_live.ex:3546` (headers at ~5958-5988) — in the Deleted tab's items table, click the Name/SKU/Price/Status sort headers. Expected: the list re-orders. Actual: `items_sort_opts` drops `sort_by`/`sort_dir` in deleted mode, so the arrow flips and the order never changes — a dead control the old deleted table didn't have.
6. `catalogue_detail_live.ex:3144` (chips at ~3876) — in the Deleted tab at root, search, then switch the result-type chip to "Categories". Expected: either the chip is hidden in the trash or it searches trash categories. Actual: `trashed?` hard-wires category results to `[]`, so every query answers "Nothing matches your search."

One caveat on severity: 3 is admin-surface-only (events are forgeable but the UI can't produce cross-catalogue uuids), and parts of it may already be being fixed in the concurrent uncommitted edits (`item_in_catalogue` appeared during this review) — worth re-checking those handlers against whatever lands next.
