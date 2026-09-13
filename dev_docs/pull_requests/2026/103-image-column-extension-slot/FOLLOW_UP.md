# PR #103 — Managed Image column + shop-extension column slot on detail lists — follow-up

## Fixed (pre-existing)

- ~~BUG MEDIUM — the managed Image column duplicated the picture in card view: the `"image"` case is a no-op on both cards (`components.ex:863`, `catalogue_detail_live.ex:5451`); tests `test/web/catalogue_detail_image_column_test.exs:131-207` — commit `d1e22ec`.~~

## Files touched

| File | Change |
|---|---|


## Verification

Re-verified against `main` at `c50c4e3` (0.29.1) on 2026-09-13 as part of the quality sweep (`dev_docs/QUALITY_SWEEP_2026-09-13.md`). Gates for the sweep batch: `mix precommit` clean (compile --warnings-as-errors, format, credo --strict, dialyzer); full suite green with live Postgres (2620+ tests at the time of writing).

## Open

None.
