# PR #90 — Selector popup sweep — follow-up

## Fixed (pre-existing)

- ~~BUG HIGH — `order: :position` interleaved per-category ordinals across categories: `catalogue/search.ex:99-108` now orders `cat.position, c.position, i.position, i.name, i.uuid` — commit `2926b16` (0.25.0).~~
- ~~IMPROVEMENT MEDIUM — read-only picked quantity missing from card view: `item_selector_modal.ex:2564-2574` (card footer) — commit `2926b16`.~~
- ~~Panel's thirteen "fixed in this PR" items (`.AutoLoad` hook, list-identity keys, `set_catalogue` singleton refusal, whitespace query, cross-catalogue `browse_category`, presence-guarded `translated_name`, ItemPicker `||` locale, QtySignal accept set, `fee_value` formatting, `fee_note` in payload, README colocated docs, logged tree rescue, PkDialog core) — all spot-verified still in place on `main`.~~
- ~~Panel — `resolve_images/files` silently capped at 50: moved to `Attachments.list_folder_files/2`, one documented cap of 200 (`attachments.ex` `@files_grid_limit`).~~

## Fixed (Batch 1 — 2026-09-13)

- ~~NITPICK — dead API: `table_toolbar`'s `:mode` slot and `show_table_tools` attr (declared, never passed by either call site) and `item_result_path/2`'s unused `_query` argument, removed (`web/catalogues_live.ex`).~~

## Skipped (surfaced to Max on 2026-09-13; his call, not decided here)

- Tile counts ignore `:statuses` / `:only` / category scope (`item_selector_modal.ex:767, 776, 790, 806, 810`) — user-visible wrong numbers on a scoped embed. `count_items_for_catalogue/2` and `uncategorized_count_for_catalogue/2` already take `statuses:`; the per-category counts (`item_counts_by_category_for_catalogue/2`) need a query change. Doing only the two easy halves would make the levels disagree with each other, so it is all-or-nothing — the panel called it design/scale.
- `Browse.smart_fee/1` has no catalogue-kind guard (`web/components/browse.ex:87-97`): a standard-catalogue item carrying `default_*` would show the fee as its price. The forms never produce that state; the guard's home (changeset rule vs render guard) is a design call.
- Table view keyboard-inoperable / ARIA gaps — see PR #88's a11y item.
- Qty-first has no selection review before Confirm (`show_tray` default false since 2026-08-31) and a category hit clears the search (`browse_state.ex:172`) — both rulings recorded at the time.
- `only: :uncategorized_only` + multi-catalogue scope skips the catalogue tiles (`item_selector_modal.ex:736`) — accepted (codex #5).

## Files touched

| File | Change |
|---|---|
| `lib/phoenix_kit_catalogue/web/catalogues_live.ex` | dead toolbar slot/attr and unused argument removed |

## Verification

Re-verified against `main` at `c50c4e3` (0.29.1) on 2026-09-13 as part of the quality sweep (`dev_docs/QUALITY_SWEEP_2026-09-13.md`). Gates for the sweep batch: `mix precommit` clean (compile --warnings-as-errors, format, credo --strict, dialyzer); full suite green with live Postgres (2620+ tests at the time of writing).

## Open

None.
