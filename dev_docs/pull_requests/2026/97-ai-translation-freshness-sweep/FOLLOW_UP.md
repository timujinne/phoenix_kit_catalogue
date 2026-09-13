# PR #97 — Translations: SEO/summary fields, attribute-set adapters, freshness states, opt-in sweep, admin page, slug after translation — follow-up

## Fixed (pre-existing)

- ~~BUG MEDIUM — `TranslationsLive.mount/3` did DB reads+writes on the disconnected render: `translations_live.ex:112` guards with `connected?/1` — commit `37922f9`, survived three later commits.~~
- ~~IMPROVEMENT MEDIUM — AGENTS.md's "only one background job" boundary was false: both workers named at `AGENTS.md:46-47`, `:214`, `:414` — commit `37922f9`.~~

## Skipped (surfaced to Max on 2026-09-13; his call, not decided here)

- `de`/`fr` locales are ~95% English (975 of 1024 msgids empty in each; `test/gettext_test.exs` exercises only `et`/`ru`). A dedicated translation pass for two locales plus `de`/`fr` assertions — or the decision not to advertise `de`/`fr` until then. Multi-hour, needs a fluent reviewer per the hand-maintained-catalogue rule.
- Uncapped retry in `unique_slug/3` (`ai_translatable.ex:436-446`) — practically bounded, DB-constraint-backed; noted by the reviewer, not flagged.

## Files touched

| File | Change |
|---|---|


## Verification

Re-verified against `main` at `c50c4e3` (0.29.1) on 2026-09-13 as part of the quality sweep (`dev_docs/QUALITY_SWEEP_2026-09-13.md`). Gates for the sweep batch: `mix precommit` clean (compile --warnings-as-errors, format, credo --strict, dialyzer); full suite green with live Postgres (2620+ tests at the time of writing).

## Open

None (the `de`/`fr` gap is Max's call).
