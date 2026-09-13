# PR #110 — Make Manual the default item order everywhere — follow-up

## Fixed (pre-existing)

- ~~BUG HIGH — `list_items/1`'s INNER catalogue join dropped orphaned items: `catalogue.ex:4279` `left_join` with `asc_nulls_last` — commit `7dc81f4`, test `test/catalogue_test.exs:2229`.~~
- ~~BUG MEDIUM — shared sort clamped at 1 of 3 call sites: `web/components/browse.ex:270-292` `clamp_to_browse_vocabulary/1`, all three consumers route through it.~~
- ~~IMPROVEMENT HIGH — nothing pinned the three sort vocabularies together: `test/browse_sort_vocabulary_conformance_test.exs`.~~
- ~~IMPROVEMENT MEDIUM — `list_items_for_catalogue/2` lacked the `i.uuid` tie-break: `catalogue.ex:4348`.~~
- ~~Gate note — `mix hex.audit` failed on `decimal 3.1.1`'s advisory: `mix hex.audit` now reports "No retired packages found" and `mix precommit` passes as one command (verified 2026-09-13).~~

## Skipped (surfaced to Max on 2026-09-13; his call, not decided here)

- No expression index behind `lower(cat.name)` in the default item order chain (`catalogue.ex:4285`; catalogue indexes are `folder_uuid`, `kind`, `status`) — deliberately deferred on volume; a one-migration `(position, lower(name), uuid)` index if the sort ever shows in timings.

## Files touched

| File | Change |
|---|---|


## Verification

Re-verified against `main` at `c50c4e3` (0.29.1) on 2026-09-13 as part of the quality sweep (`dev_docs/QUALITY_SWEEP_2026-09-13.md`). Gates for the sweep batch: `mix precommit` clean (compile --warnings-as-errors, format, credo --strict, dialyzer); full suite green with live Postgres (2620+ tests at the time of writing).

## Open

None.
