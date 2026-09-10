# PR #97: translations — SEO/summary fields, attribute-set adapters, freshness states, opt-in sweep, admin page, slug after translation — Claude review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/97
**Author**: @timujinne
**Reviewer**: Claude (Sonnet 5) — post-merge pass
**Date**: 2026-09-07
**Status**: reviewed; one Iron Law violation fixed, one doc-drift fixed, one gap documented (not fixed — see rationale)

## Scope

Builds on #96. Adds AI-translation adapters for items/categories/attribute
sets, a fingerprint-based freshness model (`TranslationStatus`), an opt-in
`Workers.TranslationSweepWorker` Oban job, an admin page
(`TranslationsLive`) to review/bulk-translate stale content, and moves
slug generation to run after translation. Two "address review findings"
commits (`86cb8bd`, `f0c9ec3`) already landed inside the PR branch before
merge — this pass checked those fixes held under later commits, not just
that they existed.

## BUG - MEDIUM: `TranslationsLive.mount/3` did unconditional DB reads/writes, inconsistent with this PR's own established safe pattern

`lib/phoenix_kit_catalogue/web/translations_live.ex:102-125` (pre-fix)

`mount/3` unconditionally called `TranslationSweepWorker.endpoint_and_prompts/0`,
which chains a settings read, a DB read
(`Translations.default_endpoint_uuid/0`), and two upserts
(`AIPrompt.ensure_prompt/0`, `AIPrompt.ensure_sets_prompt/0` — each does a
read-then-insert-or-update on first boot or after a template edit).
`mount/3` runs on both the disconnected HTTP render and the WebSocket
connect, so a single page visit ran this — including the writes — twice.
This is the Phoenix Iron Law (no DB work in `mount`), and it's
inconsistent within this very PR: `lib/phoenix_kit_catalogue/web/helpers.ex:261-276`
(`maybe_preselect_catalogue_prompt/2`) calls the exact same
`AIPrompt.ensure_prompt/0` but correctly guards it behind
`Phoenix.LiveView.connected?(socket)`. Not corrupting (the upsert's
create-race path re-reads on conflict), but wasteful, and a genuine
double-write hazard was only avoided by that idempotency, not by design.

**Fixed** — `mount/3` now gates the entire `endpoint_and_prompts/0` call
(and the `Translations.subscribe()` call) behind `connected?(socket)`,
matching `helpers.ex`'s guard. The disconnected render assigns
`ai_available: false` as a placeholder; the connected re-mount replaces
it with the real state. `handle_url_state/2` already no-ops when
`ai_available` is false, so no row-loading path was affected. Verified
against `test/web/translations_live_test.exs`, which drives the page
through `live/2` (always ends up connected) — unaffected by the change.

## BUG - MEDIUM (not fixed — documented): newly-added `de`/`fr` locales are ~96% untranslated, with no test coverage protecting them

`priv/gettext/de/LC_MESSAGES/default.po`, `priv/gettext/fr/LC_MESSAGES/default.po`

All 6 gettext files (`default.pot` + 5 locales) carry identical 1020-msgid
parity. Empty-`msgstr` counts: `en` 533 (expected — English is the source
language), `et` 1, `ru` 1 (matching AGENTS.md's "hand-maintained, fully
translated" claim) — but **`de` 976, `fr` 976**. The ~44 msgids that *do*
carry a real translation in `de`/`fr` are exactly the ~31 new strings this
PR itself introduces for the Translations admin page; every pre-existing
string (item/category forms, PDF library, import/export, attributes, …)
is blank. `test/gettext_test.exs` — built specifically to catch exactly
this failure class (its own header: "`gettext/1` returns the msgid when a
string is missing... no test fails") — only exercises `ru`/`et`, never
`de`/`fr`.

Not a crash: `Gettext.gettext/2` falls back to the msgid, so a host that
enables `de`/`fr` sees readable English rather than blanks or errors. But
it is a materially incomplete feature (two "supported" locales that are,
functionally, English) shipped with no regression protection.

**Not fixed.** Translating ~976 short UI strings each into German and
French to a quality bar this codebase can stand behind (AGENTS.md treats
this catalogue as hand-maintained, entry by entry, specifically because a
bulk/scripted pass has burned this repo before — see the gettext trap
section) is a dedicated-translation-pass task, not something to bulk-fill
as a drive-by in an unrelated review pass without a native/fluent
reviewer to check the output. Filling in even the visible admin-page
subset without doing the rest would not close the gap the finding is
about. Recommend, as follow-up: either (a) commission/complete a real
`de`/`fr` translation pass and then extend `gettext_test.exs` with the
same non-English-fallback smoke assertions `ru`/`et` already have, or
(b) don't ship `de`/`fr` as enabled/selectable locales until that pass
happens, so a host can't unknowingly turn on a locale that's 96% English.

## IMPROVEMENT - MEDIUM: AGENTS.md's "Only one background job" hard boundary was false and unupdated

`AGENTS.md:38` (pre-fix, untouched by any commit in this PR's range)

The line read "Only one background job: `Workers.PdfExtractor`..." under
"Hard boundaries (deliberate — do not add)" — the section that exists
specifically to stop an agent from adding a second one. This PR adds
`Workers.TranslationSweepWorker`, a second, permanent, self-rescheduling
Oban worker on queue `:default`. Same doc-drift class as the finding in
this repo's own PR #95 review
(`dev_docs/pull_requests/2026/95-module-owned-migration-chain/CLAUDE_REVIEW.md`) —
a hard boundary stating the opposite of the truth is expensive here
specifically because AGENTS.md loads into every session.

**Fixed** — the bullet now names both jobs/queues and notes both are
opt-in by config (PdfExtractor needs the host to configure its queue;
TranslationSweepWorker only seeds its reschedule chain once an operator
enables the sweep setting via `Web.Settings`).

## Checked and correct (no action)

- **Sweep opt-in is real**: `TranslationSweepWorker.child_spec/1`'s boot
  task only seeds the reschedule chain `if` the setting is already
  enabled; `Web.Settings.update_sweep_enabled/1` seeds it exactly once on
  the flip. A host that never opts in gets no ticking job row.
- **`schedule_next_tick/0` reschedules itself before doing work** — a
  crashed/slow tick doesn't break the chain.
- **Per-row enqueue failures in `sweep/0` are logged and skipped**, not
  swallowed as a disguised job failure — the sweep job itself always
  returns `:ok` by design (self-healing via the next tick), which is the
  correct Oban pattern here, not the "catch everything, return `{:ok,_}`"
  anti-pattern.
- **Slug write-once invariant holds under translation**:
  `generate_slug/5`'s guard only fills a still-blank per-language slug,
  never overwrites an existing one.
- **Fingerprint capture/consumption split** verified: read-only paths
  (`TranslationStatus.state/2`, `list/2`, both adapters' write-time
  fallback) call the pure variant; `put_translation/4` in both
  `AITranslatable` and `AITranslatable.Sets` reads back the captured
  fingerprint before falling back to a fresh hash. Process-dictionary use
  here is justified (avoids threading an extra param through a generic
  third-party `Translatable` behaviour) despite normally being a red flag.
- **`AITranslatable.Sets` avoids double-broadcast-inside-transaction**:
  bypasses the generic entity-translation helpers (which broadcast+log+
  export *inside* the still-open `FOR UPDATE` transaction) in favor of a
  bare changeset update, broadcasting once after commit — a real
  concurrency bug avoided, carried over correctly from the earlier
  in-PR review round.
- **Permission gating stays at the Tab layer** (`permission: module_key()`
  on `:admin_catalogue_translations`) — no authorization logic added to
  the context.
- **Route ordering**: `catalogue/translations` is declared before the
  `catalogue/:uuid` wildcard in both `admin_tabs/0` and the test router.
- **`resources_for(:set_value)` batches via `list_values_for/2`** — no
  N+1, a fix carried over correctly from the earlier in-PR review round.
- **Optional `phoenix_kit_ai` dependency concern doesn't apply**:
  `mix.exs` pins it as a required (non-optional) `pk_dep`, so there's no
  "must not crash when phoenix_kit_ai is absent" path to check.
- **`unique_slug/3`'s unbounded retry loop on collision**: not a realistic
  risk given the proactive check is backed by a DB unique constraint;
  noted, not flagged.

## Related

- Sibling PR: [#96](/dev_docs/pull_requests/2026/96-per-language-slugs-seo-extension-slot)
