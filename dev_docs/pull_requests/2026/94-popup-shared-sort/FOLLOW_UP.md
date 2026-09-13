# PR #94 — The popup follows the module's shared sort — follow-up

## Fixed (pre-existing)

- ~~BUG MEDIUM — `:created_asc`/`:created_desc` item reorder sorted `DateTime` structurally: `catalogue.ex:4211-4222` sorts with `{:asc, DateTime}` / `{:desc, DateTime}` — commit `841b68f`.~~
- ~~IMPROVEMENT HIGH — shared-sort DB read outside the popup's degradation guard: `web/components/browse.ex:310-321` `read_global_sort/1` rescues to `{:position, :asc}` with a warning, used by both global readers — commit `841b68f`.~~
- ~~IMPROVEMENT HIGH — nothing pinned `@order_fields` to `TableConfig`'s sortable ids: `test/phoenix_kit_catalogue/catalogue/browse_state_test.exs:380` — commit `841b68f`.~~

## Skipped (surfaced to Max on 2026-09-13; his call, not decided here)

- `decimal_key/1` duplicates `TableConfig.dec/1` (three identical clauses) — the reviewer judged the coupling not worth six lines; left as is.
- `tile_sorted/3` catch-all vs `sort_categories/4` exhaustive `case` disagree on an unknown field — the lenient side is the client-facing one; left as is.
- The popup reads the shared sort once at init; `broadcast_view_sort_changed/4` exists if a client ever wants it to follow live — conditional on the ask.

## Files touched

| File | Change |
|---|---|


## Verification

Re-verified against `main` at `c50c4e3` (0.29.1) on 2026-09-13 as part of the quality sweep (`dev_docs/QUALITY_SWEEP_2026-09-13.md`). Gates for the sweep batch: `mix precommit` clean (compile --warnings-as-errors, format, credo --strict, dialyzer); full suite green with live Postgres (2620+ tests at the time of writing).

## Open

None.
