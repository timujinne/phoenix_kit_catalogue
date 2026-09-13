# PR #95 — Module-owned V1 migration chain (adoptive) — follow-up

## Fixed (pre-existing)

- ~~IMPROVEMENT HIGH — nothing pinned the chain to core's `ExpectedSchema` manifest: `test/phoenix_kit_catalogue/migrations_test.exs:312-341` — commit `09cf9d1`.~~
- ~~BUG MEDIUM — moduledoc named 4 of 9 shaping core versions: `migrations.ex:24-40` lists V146/V151/V178/V179/V180 and the `:legacy_optional` reasoning.~~
- ~~BUG MEDIUM — `AGENTS.md` said "no migrations in this repo": `AGENTS.md` Database & migrations section states the V2+ chain protocol (survived the #100 rewrite).~~
- ~~BUG MEDIUM — `version/0` shipped 0.26.0 reporting 0.25.0: `lib/phoenix_kit_catalogue.ex:102` reads `@version` (single source, commit `1eda8f0`), pinned in `test/phoenix_kit_catalogue_test.exs:208-211`; the two-places drift can no longer happen.~~

## Skipped (surfaced to Max on 2026-09-13; his call, not decided here)

- `mix precommit` runs no tests (`mix.exs:69-77`) — a process decision (the suite needs a live DB); the specific drift it let through is now structurally impossible. If Max wants a DB-free subset in the gate, that is a separate decision.
- Eight CHECK constraints render differently from core's (equivalent) — not statically verifiable from source (the review compared a DB render); harmless, core compares by catalogue name, never text.

## Files touched

| File | Change |
|---|---|


## Verification

Re-verified against `main` at `c50c4e3` (0.29.1) on 2026-09-13 as part of the quality sweep (`dev_docs/QUALITY_SWEEP_2026-09-13.md`). Gates for the sweep batch: `mix precommit` clean (compile --warnings-as-errors, format, credo --strict, dialyzer); full suite green with live Postgres (2620+ tests at the time of writing).

## Open

None.
