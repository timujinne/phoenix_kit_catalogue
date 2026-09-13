# PR #96 — Per-language slugs, SEO fields, form extension slot, `attach_files/3` (chain V2) — follow-up

## Fixed (pre-existing)

- ~~BUG HIGH — SEO title/description silently discarded when multilang is disabled: `merge_seo_params/2` in both forms (`item_form_live.ex:382`, `category_form_live.ex:234`), called on validate and save — commit `37922f9`.~~
- ~~IMPROVEMENT MEDIUM — `attach_files/3` dropped `actor_uuid`: `attachments.ex` passes `actor_uuid: opts[:actor_uuid]` (and, since 2026-09-12, writes its keys as owned keys) — commit `37922f9`.~~
- ~~NITPICK — moduledoc cited a non-existent `:info` finding classification: `migrations.ex:85-87` — commit `37922f9`.~~

## Skipped (surfaced to Max on 2026-09-13; his call, not decided here)

- Folder-name race in `find_or_create_named_folder` (check-then-create, `attachments.ex:855-861` and `:982-998`) — needs a uniqueness guarantee in core `Storage` (`ON CONFLICT` / unique index); cross-repo, conditional on concurrent scripted imports.

## Files touched

| File | Change |
|---|---|


## Verification

Re-verified against `main` at `c50c4e3` (0.29.1) on 2026-09-13 as part of the quality sweep (`dev_docs/QUALITY_SWEEP_2026-09-13.md`). Gates for the sweep batch: `mix precommit` clean (compile --warnings-as-errors, format, credo --strict, dialyzer); full suite green with live Postgres (2620+ tests at the time of writing).

## Open

None in this repo (the folder-name race is a core `Storage` change).
