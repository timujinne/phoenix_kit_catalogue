# Review: PR #33 — Use `AITranslate.Embed` macro in catalogue/category/item form LiveViews

Reviewed 2026-06-07 (post-merge, against `main`). Reviewed through the Elixir
`phoenix` thinking skill.

## Scope

Replaces the hand-wired AI-translate plumbing in the three form LiveViews
(`catalogue_form_live`, `category_form_live`, `item_form_live`) with
`use PhoenixKitWeb.Components.AITranslate.Embed` (new macro from core
[#585](https://github.com/BeamLabEU/phoenix_kit/pull/585), shipped in
`phoenix_kit 1.7.132`). Per file this drops the six `ai_*` `handle_event`
clauses + the `{:ai_translation}` `handle_info` clause and trims the `FormGlue`
import to the three helpers still called directly (`actor_opts`,
`assign_ai_translation`, `ai_translate_config`). Net −89/+12 across the three
files. This is the deferred "per-LiveView wiring duplication" follow-up from the
PR #32 review.

## Verdict

Clean, faithful refactor — **no findings, nothing to apply.** The macro's
mechanism (lifecycle hooks, not injected clauses) and its default form re-sync
both match what the hand-wired code did, so behavior is preserved while the
duplication is eliminated. Compiles warning-free.

---

## Verified correct (the parts most likely to harbor bugs)

- **No clause-grouping / clobbering risk.** The macro does **not** inject
  `handle_event`/`handle_info` clauses into the host. `__using__` only calls
  `on_mount/1`, which `attach_hook`s `:handle_event` and `:handle_info`
  lifecycle hooks (`deps/phoenix_kit/.../ai_translate/embed.ex:58–80`). The AI
  events are matched and `:halt`ed in the hook; everything else returns
  `{:cont, socket}` and falls through to the host's own clauses. So there is no
  "clauses with the same name should be grouped together" warning and no
  shadowing of the host's `switch_language`/`validate`/`save`/etc. ✅
- **Form re-sync is identical.** The hand-wired path passed `&assign_changeset/2`
  as the re-sync callback. In all three files `assign_changeset/2` is exactly
  `assign(:changeset, cs) |> assign(:form, to_form(cs))`
  (`catalogue_form_live.ex:103`, `category_form_live.ex:137`,
  `item_form_live.ex:159`). The macro's default `resync_form/2` sets the same
  two assigns (`embed.ex:113–123`), so dropping the explicit callback changes
  nothing. No host needs the `ai_translate_assign_form/2` override. ✅
- **Imports trimmed correctly, no dead/unused imports.** All three retained
  helpers are still referenced in every file (`actor_opts` 5–7×,
  `assign_ai_translation` 2×, `ai_translate_config` 5×). The eight removed
  imports were only used by the now-deleted clauses. Confirmed by a clean
  `mix compile --warnings-as-errors` (would flag any unused import). ✅
- **`mount`-time `assign_ai_translation/3` correctly retained.** The macro
  explicitly does *not* assume the resource (dynamic: loaded record on `:edit`,
  `nil` on `:new`), so the host still calls it itself — done. The mount-twice
  double-query trap remains avoided because core's `FormGlue` gates every DB
  lookup on `connected?/1` (verified in the PR #32 review; unchanged here). ✅
- **`@impl true` preserved.** The `@impl true` that annotated the removed
  `handle_info({:ai_translation, …})` now annotates the following
  `handle_info({:media_selected, …})` clause — no missing-`@impl` warning.

## Notes (non-blocking)

- The PR description's "do not merge before core release" gate was satisfied:
  `phoenix_kit` is pinned `~> 1.7 and >= 1.7.125` and locked at `1.7.132`, which
  contains the macro. Merge order was correct.
- Lifecycle hooks run *before* the host's own callbacks. This is behaviorally
  equivalent here (the host no longer defines AI clauses), but worth keeping in
  mind: a future host clause that tried to intercept an `ai_*` event or
  `{:ai_translation, …}` would be silently shadowed. The macro's moduledoc
  documents this; no action needed.
- `item_form_live` keeps the standing "data load in `mount/3` fires twice"
  follow-up note (`:159`+); untouched by this PR and out of scope.
