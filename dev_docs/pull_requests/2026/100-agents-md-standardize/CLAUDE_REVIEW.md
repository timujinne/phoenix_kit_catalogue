# PR #100: Standardize AGENTS.md onto the shared module skeleton

**Author**: @mdon
**Reviewer**: Claude (`elixir:phoenix-thinking` + `elixir:ecto-thinking` applied before reading source)
**Status**: Merged (`a4e6297`)
**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/100
**Date reviewed**: 2026-09-08

## What changed

Three commits: `1eda8f0` rewrites `AGENTS.md` onto the shared eleven-heading
skeleton used across `phoenix_kit_*` repos and extracts the duplicated SEO
field-fold anonymous function in `category_form_live.ex` / `item_form_live.ex`
into a named `put_seo_field/3`; `7917ce7` runs `phoenix_kit_entities`'
migration chain in the test harness so a future entities schema change
doesn't fail as an unrelated `undefined_column`; `9698daa` fixes a real
intermittent-flaky test (`function_exported?/3` reads a merely-unloaded
module the same as one lacking the function).

## Verified

- `put_seo_field/3` extraction is a pure refactor — `Enum.reduce/3` calls
  `fun(elem, acc)`, `&put_seo_field(&1, &2, params)` binds `field, data`
  correctly, output identical to the inline anonymous function it replaces.
  Applied identically to both `category_form_live.ex` and `item_form_live.ex`.
- `version/0` now reads `Mix.Project.config()[:version]` at compile time
  instead of a hand-duplicated string literal — removes the two-places-in-sync
  footgun the old AGENTS.md warned about.
- The entities migration replay in `test_helper.exs` hardcodes prefix
  `"public"`, matching the existing call to
  `PhoenixKitCatalogue.Migrations.up_statements("public")` right below it —
  consistent, not a new pattern.
- 18 schemas in `lib/phoenix_kit_catalogue/schemas/` — matches the rewritten
  AGENTS.md's count.
- The gettext trap counts in the new `dev_docs/guides/gettext-catalogue.md`
  (~1020 msgids, ~110 `elixir-autogen`) check out against
  `priv/gettext/default.pot` (1032 / 114 — close enough, worded as "~").
  The "already macro-form" file list (`table_config.ex`, `catalogues_live.ex`,
  `components.ex`, `item_form_live.ex`, `category_form_live.ex`,
  `catalogue_detail_live.ex`, `translations_live.ex`) all carry
  `use Gettext, backend: PhoenixKitCatalogue.Gettext` — confirmed.
- Full gate: `mix compile --warnings-as-errors`, `mix format --check-formatted`,
  `mix credo --strict`, `mix dialyzer` all clean; `mix test` — 2431 tests, 0
  failures (a few expected `[error]` GenServer crash logs are
  `ItemSelectorModal`/`Browse` tests deliberately exercising `raise` guard
  clauses, not regressions).

## Finding

### IMPROVEMENT - MEDIUM: rewrite dropped the verified "no GitHub release" fact, reopening the exact ambiguity it replaced

**Before** (old AGENTS.md, deleted by this PR):

> Recent releases do not create a GitHub release (no `gh release create`);
> the CHANGELOG entry is the release note.

**After** (this PR, was live in AGENTS.md/CLAUDE.md until this review):

> 6. GitHub release via `gh release create` if the repo does those (`gh
>    release list` shows whether it does).

The old line was itself a hard-won correction — the file's own history notes
it "previously say[ing] bare version numbers, which was only ever true through
v0.19.x." The rewrite's generic step 6 tells a future agent to run
`gh release list` and infer practice from what it finds. Checked what it
finds: `gh release list` returns releases up to `0.19.0 - 2026-08-24`, while
tags run to `v0.28.1` — nine tagged releases with no GitHub release. A
sub-agent skimming the list without noticing the tag/release version gap
could reasonably read "the repo does those" and create one for the current
release, which is exactly the drift the deleted sentence had already fixed
once.

This is the standardization PR's own risk made concrete: the skeleton
generalizes per-repo specifics, and a specific, previously-verified fact
(this repo stopped cutting GitHub releases after v0.19.0) is exactly the kind
of thing that generalization silently drops.

**Fixed** — restored the specific, verified fact in `AGENTS.md` §Versioning &
releases step 6, naming the v0.19.0/v0.28.1 gap so a future reader doesn't
have to re-derive it from `gh release list` and can't misread a nonempty list
as "yes, do it":

```markdown
6. No GitHub release. `gh release list` stops at v0.19.0 (2026-08-24) even
   though tags have continued through v0.28.1 — releases since then have
   never gotten a `gh release create`, and the CHANGELOG entry is the release
   note instead. Don't create one from the mere presence of older releases in
   the list; that's the same regression this file previously carried before
   being generalized away.
```

No test pins this (it's a documentation fact, not code), so nothing to add to
the suite; `mix precommit` stays green after the edit (docs-only change,
verified via `mix format --check-formatted` / `credo --strict`).

## Not changed

The rest of the AGENTS.md rewrite (Overview, What this module does NOT do,
Conventions, Landmines, Architecture, Database & migrations, Testing, Feature
notes, TODOs) was spot-checked against the current code (dependency floors in
`mix.exs`, schema list, gettext macro-form file list, migration chain
comments) and reads as accurate — no other regressions found.
