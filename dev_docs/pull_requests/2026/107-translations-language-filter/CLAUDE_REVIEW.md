# PR #107: Stop the translations page's language filter from queuing blank targets — Claude review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/107
**Author**: @timujinne
**Reviewer**: Claude (Sonnet 5) — post-merge pass
**Date**: 2026-09-11
**Status**: reviewed; one bug found and fixed

## Scope

Fixes a real bug on the translations admin page (`Web.TranslationsLive`):
the language filter's "All languages" option was rendered via `<select>`'s
`prompt` attribute, which forces the option's value to `""`. Picking it
therefore submitted `filter[lang]=""` instead of the intended `"all"`, and
that blank string flowed — unvalidated — all the way to
`Translations.enqueue/1`'s `target_lang`, queuing translation jobs for a
literal blank language.

The fix:

1. `lang_options/1` makes "All languages" a real option (`value="all"`),
   matching how `type_options/0` and the state chips already handle their
   own "all" case.
2. `normalize_lang/2` normalizes any `lang` reaching `handle_url_state/2`
   or the `filter` event — blank, `nil`, or a language that isn't
   currently enabled all fall back to `"all"` — closing the gap left by
   `UrlState`'s own `:in` validation, which can't cover `lang` since the
   enabled-language list is DB-settings-backed rather than a compile-time
   atom list.
3. `valid_target_lang?/2` guards the two places a client-controlled `lang`
   reaches `Translations.enqueue/1` directly: the per-row `phx-value-lang`
   (`enqueue_one/4`) and bulk enqueue (`do_bulk_enqueue/2`, defense in
   depth since bulk's `lang` already comes from the normalized filter).

Well covered: 9 new tests exercise the blank-option removal, blank/unknown
filter values, a crafted `?lang=` query param, the per-row/bulk enqueue
guards, and that an in-flight state isn't misreported as "missing" after a
blank filter.

## Bug found and fixed

**BUG - MEDIUM**: `handle_event("filter", ...)` crashes the LiveView with
`KeyError: key :languages not found` if it fires while AI translation is
not configured.

`:languages` is only assigned in `mount/3`'s `ai_available: true` branch;
when AI is unconfigured, `socket.assigns` never gets a `:languages` key at
all. The new `filter` handler unconditionally calls
`normalize_lang(lang, socket.assigns.languages)` — no `ai_available` guard,
unlike `handle_url_state/2` right above it, which does check it before
touching the same assign. Before this PR, `handle_event("filter", ...)`
only read `socket.assigns.lang` / `.type`, both always-present `UrlState`
params, so this crash path did not exist previously — it's a regression
introduced by this PR, not a pre-existing issue.

Reachability: the filter `<select>`/form isn't rendered at all on the
"AI not configured" page, so this needs a deliberately crafted
`phx-change`/`push_event("filter", …)` call rather than normal clicking —
but it's an admin-only surface already treating crafted events as a real
threat model (that's exactly why `enqueue_one/4`, `do_bulk_enqueue/2`, and
`row_type/1` all guard against them), so the same crash was worth closing
here for consistency, and it was one KeyError away from taking down an
admin's whole session.

Confirmed with a throwaway repro test before fixing:
```
{:ok, view, _html} = live(conn, @base)   # AI not configured, ai_available: false
render_change(view, "filter", %{"filter" => %{"lang" => "xx-XX"}})
# ** (KeyError) key :languages not found in: %{type: "all", search: "", lang: "all", ...}
```

**Fix**: added a `languages/1` helper (`socket.assigns[:languages] || []`)
and swapped every `socket.assigns.languages` read (`handle_url_state/2`,
the `filter` handler, `enqueue_one/4`, `do_bulk_enqueue/2`) to go through
it. With AI unconfigured, filtering now just no-ops through
`normalize_lang`'s `"all"` fallback instead of crashing, and a crafted
`translate`/bulk event now gets the existing graceful
"Unknown target language" flash instead of a `KeyError`.

Added a regression test (`test/web/translations_live_test.exs`, "AI
translation not configured" describe block): a crafted `filter` event
while unconfigured no longer kills the LiveView process.

## Review notes (no fix needed)

- `assign(:lang, lang)` inside `handle_url_state/2`, setting a param
  `UrlState` itself declared, is the documented-safe pattern from
  `UrlState`'s own moduledoc ("Setting a declared param outside an
  event") — the next `push_url_state/3` reads its merge base back from
  live assigns, not the stale bookkeeping state map, so the corrected
  value wins on the next filter interaction rather than being
  resurrected.
- `on_mount` ordering confirmed by reading `PhoenixKitWeb.Live.UrlState`:
  the URL-state `on_mount` hook decodes params before this module's own
  `mount/3` runs, and the `handle_params`-attached hook (which calls
  `handle_url_state/2`) fires after `mount/3` on both the disconnected
  and the connected render — so `socket.assigns[:ai_available]` is always
  set by the time `handle_url_state/2` reads it, matching the module's
  own doc comment.
- `do_bulk_enqueue/2`'s `valid_target_lang?` guard is genuinely
  unreachable via the UI today (`row.lang` always comes from
  `TranslationStatus.list(langs: target_langs(state.lang))`, fed only the
  already-normalized filter value) — the PR's own comment says as much;
  kept as defense-in-depth per that comment's stated rationale (a future
  `target_langs/1` change must fail loud per-row, not queue a broken job).
- Full suite green after the fix: `mix test` — 2581 tests, 0 failures
  (DB-backed `:integration` tests included, 17 in
  `translations_live_test.exs`). `mix precommit` clean (format, compile
  `--warnings-as-errors`, credo `--strict`, dialyzer).
