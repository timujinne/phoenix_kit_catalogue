# PR #96: per-language slugs, SEO fields, form extension slot, attach_files/3 (chain V2) — Claude review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/96
**Author**: @timujinne
**Reviewer**: Claude (Sonnet 5) — post-merge pass
**Date**: 2026-09-07
**Status**: reviewed; one bug fixed (SEO fields on single-language installs), one audit-trail gap fixed, one moduledoc claim corrected

## Scope

Adds a V2 migration to the module-owned chain (per-language `slug` jsonb
column + two lookup/uniqueness projection tables + sync triggers), SEO
title/description fields on items and categories, a form extension slot
(`Extension`/`Extensions`) that lets a sibling module contribute a form
section without this repo knowing about it, and `Attachments.attach_files/3`
— a non-LiveView API to link already-uploaded files to an item.

## BUG - HIGH: SEO title/description silently discarded when multilang is disabled

`lib/phoenix_kit_catalogue/web/item_form_live.ex`,
`lib/phoenix_kit_catalogue/web/category_form_live.ex`

`seo_title`/`seo_description` have **no DB column** — they only ever live
under `data["_seo_title"]`/`data["_seo_description"]`, written there
exclusively by core's `PhoenixKitWeb.Components.MultilangForm.
merge_translatable_params/4`, which only touches `params["data"]` at all
inside its `if assigns[:multilang_enabled]` branch
(`deps/phoenix_kit/lib/phoenix_kit_web/components/multilang_form.ex:342-349`).
`multilang_enabled` reflects a host-wide DB setting that is off by default
on a single-language install. The SEO inputs render unconditionally
(`multilang_fields_wrapper` renders its children regardless of
`multilang_enabled`), so on a single-language install a user types into
the SEO fields, submits, and the values vanish with no error — every
time — because they never reach `data`, and `Item`/`Category`'s
`cast/3` doesn't know a `:seo_title` field to keep them as a top-level
param either.

This wasn't speculative: `test/web/item_form_seo_test.exs`'s own
moduledoc names the exact gap ("without it `@multilang_enabled` stays
`false` and `merge_translatable_params/4` never touches `data` at all")
and worked around it by force-enabling multilang in **every** test —
so the single-language case shipped with zero coverage.

**Fixed** — added `merge_seo_params/2` to both LiveViews: when
`multilang_enabled` is false it folds `params["seo_title"]` /
`params["seo_description"]` directly into `data["_seo_title"]` /
`data["_seo_description"]` (mirroring `extract_translatable_data/4`'s
own primary-language logic), called right after `merge_translatable_params/4`
in both the `validate` and `save` clauses of both LiveViews. Added a
regression test to each of `item_form_seo_test.exs` and
`category_form_seo_test.exs` that saves without enabling multilang and
asserts the SEO fields round-trip via `Translations.translated_seo_title/2`.

## IMPROVEMENT - MEDIUM: `Attachments.attach_files/3` dropped `actor_uuid`, breaking the activity-log audit trail

`lib/phoenix_kit_catalogue/attachments.ex:561` (pre-fix)

`attach_files/3` called `Catalogue.update_item(item, %{data: data})` with
no `opts`, so the mutation's `log_activity/2` call always recorded
`actor_uuid: nil`. AGENTS.md states this as a hard convention: "every
mutating context function takes `opts` with `actor_uuid:`." This function
is explicitly documented as the "Non-LiveView API" for scripted/external
use — exactly where an audit trail matters most, since there's no LiveView
session to fall back on. No test exercised or asserted an actor.

**Fixed** — `attach_files/3` now forwards `actor_uuid: opts[:actor_uuid]`
to `Catalogue.update_item/3`. Added a test in `attachments_api_test.exs`
asserting the `item.updated` activity row carries the passed actor.

## NITPICK: moduledoc's justification for skipping a core release named a classification that doesn't exist

`lib/phoenix_kit_catalogue/migrations.ex` (V2 doc comment, pre-fix)

The moduledoc claimed core's `ExpectedSchema` "treats an extra,
unmanifested column as an `:info` finding, never a mismatch to repair
away." Checked `deps/phoenix_kit/lib/phoenix_kit/migrations/
expected_schema/{resolver,object}.ex` — there is no `:info`-finding path
at all; the resolver only ever iterates the manifest's *declared* objects
and never enumerates a table's actual columns to notice an undeclared
one. The practical conclusion (adding `slug` needs no core release) is
still correct, just for a blunter reason (never looked at, vs. looked at
and classified as info).

**Fixed** — moduledoc now says the resolver "never enumerates a table's
actual columns to notice one that isn't manifested," not that it
classifies the extra column as `:info`.

## NITPICK (pre-existing pattern, not fixed): folder-name race in `ensure_item_folder`

`lib/phoenix_kit_catalogue/attachments.ex` — `find_or_create_named_folder`
is check-then-create (`find_folder_by_name` then `Storage.create_folder`),
so two concurrent callers with no existing folder both create one. This
pattern already existed for the LiveView mount path; `attach_files/3`
exposes it to concurrent import/bulk scripts, which makes the race more
likely to actually be hit than a single-user LiveView session. **Not
fixed** — pre-existing, low-frequency (one folder-per-item, created once),
and fixing it (e.g. `ON CONFLICT` on folder name) is a `phoenix_kit`
core `Storage` change, out of scope for this repo. Recorded so a future
reviewer doesn't re-derive it.

## Checked and correct (no action)

- **Extension slot** (`extension.ex`/`extensions.ex`): duck-typed via
  `PhoenixKit.ModuleRegistry.all_modules/0`, a `:persistent_term` read —
  no DB query, no process. `Extensions.sections/1` is called from `mount/3`
  but does zero I/O — consistent with the Phoenix Iron Law.
- **Slug uniqueness**: the projection tables' `PRIMARY KEY (lang, value)`
  is what the trigger-raised Postgres error surfaces, and both schemas
  declare `unique_constraint(:slug, name: "...pkey")` so Ecto maps the
  violation to a changeset error regardless of which table raised it.
- **Trigger delete-then-insert** avoids self-conflict on re-save; the
  one-time backfill uses `ON CONFLICT DO NOTHING`.
- **`present_languages/1`** filters `data` keys to the `xx-YY` shape
  before generating slugs, so non-language namespaces (`"meta"`, an
  extension's own `data["ecommerce"]`) can't collide with slug generation.
- **`create_item`/`create_category` invariant preserved**: `maybe_generate/3`
  is only called explicitly by the form LiveViews, not wired into the
  schema changesets — `duplicate_category`/bulk import/other internal
  callers are unaffected.
- **`mix.exs` floor tightening** (`~> 2.8` → `>= 2.13.11 and < 3.0.0`) is
  justified by a real crash in phoenix_kit 2.13.4–2.13.10's V180
  migration, and pinned by `CorePinConformanceTest` — not gratuitous.
- **No SQL injection**: the only interpolated values in slug lookup
  queries are module constants / config-derived table names; `slug`/`lang`
  go through parameterized placeholders.

## Related

- Sibling PR: [#97](/dev_docs/pull_requests/2026/97-ai-translation-freshness-sweep)
