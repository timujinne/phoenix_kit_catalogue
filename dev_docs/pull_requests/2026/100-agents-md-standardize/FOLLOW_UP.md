# PR #100 — Standardize AGENTS.md onto the shared module skeleton — follow-up

## Fixed (pre-existing)

- ~~IMPROVEMENT MEDIUM — the rewrite dropped the "no GitHub release" fact: restored at `AGENTS.md` Versioning & releases — commit `70ae53a`.~~

## Fixed (Batch 1 — 2026-09-13)

- ~~The restored sentence quoted the tag ceiling as v0.28.1; tags run to v0.29.1. Refreshed.~~

## Files touched

| File | Change |
|---|---|
| `AGENTS.md` | tag ceiling refreshed to v0.29.1 |

## Verification

Re-verified against `main` at `c50c4e3` (0.29.1) on 2026-09-13 as part of the quality sweep (`dev_docs/QUALITY_SWEEP_2026-09-13.md`). Gates for the sweep batch: `mix precommit` clean (compile --warnings-as-errors, format, credo --strict, dialyzer); full suite green with live Postgres (2620+ tests at the time of writing).

## Open

None.
