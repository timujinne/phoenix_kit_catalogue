# PR #137 — Add the {{Glossary}} slot to both catalogue translation prompts

- **Author:** timujinne (Timujeen)
- **Merged:** 2026-09-23 (`b0741db`)
- **Reviewer:** Claude (post-merge)
- **Files:** `lib/phoenix_kit_catalogue/ai_prompt.ex`, two new tests
  (`ai_prompt_glossary_test.exs`, `ai_prompt_glossary_rollout_test.exs`)

## Summary

Both catalogue-owned translation templates gain a `{{Glossary}}` slot, gated
on whether the installed `phoenix_kit_ai` binds it
(`function_exported?(PhoenixKitAI.Translation, :build_variables, 4)`). The
prompts are content-addressed, so an upgrade or downgrade of `phoenix_kit_ai`
rewrites the stored row in place under the same uuid.

## Verified

- **The binding path fires for catalogue translations.** The sweep worker and
  the Translations page go through `PhoenixKitAI.Translations.enqueue/1` →
  `Translation.do_translate/6`, which calls
  `build_variables(..., resolve_glossary(target_lang, opts))`. The catalogue
  never passes `:glossary`, so it gets the settings glossary, per target
  language.
- **The capability probe is correct.** `build_variables/4` has a default arg,
  so 0.23.2 exports both `/3` and `/4`. 0.23.1 exports only `/3`.
- **An empty glossary renders as nothing.** `glossary_section(nil)` is `""`,
  so an install with no glossary gets one extra blank line and no
  instruction.
- **Rollout.** `maybe_update/2` compares the sha of the gated content, so a
  second call at the same capability does not write. The backdated
  `updated_at` test proves that properly.

## Findings

### IMPROVEMENT - MEDIUM — the repo's own lock never ran the supported branch

`mix.lock` pinned `phoenix_kit_ai` 0.23.1, which has no `build_variables/4`.
So in dev, in the test suite and in the pre-release check,
`glossary_slot_supported?/0` was `false`: the templates the suite provisioned
by default were the slot-less ones. The explicit-boolean tests covered both
branches, but "defaults to the detected capability" was only ever observed
answering `false`.

**Fixed:** `mix deps.update phoenix_kit_ai` → 0.23.2 (and `phoenix_kit`
2.37.4 → 2.37.5). The `~> 0.18` constraint in `mix.exs` stays loose on
purpose: the feature detection exists so that it can.

### NITPICK — Rollout moduledoc described the sha input wrongly

The doc said the sha is of "the module's template". It is now the sha of the
gated rendering, which is why an AI upgrade triggers a rewrite. **Fixed**
(reworded).

### NITPICK — two comment paragraphs ran together

In the comment above `content/1`, the "content-addressed" paragraph and "The
flag is an argument…" paragraph had no separating `#` line. **Fixed.**

### Not changed

- `ensure_prompt/1` and `ensure_sets_prompt/1` now take a test-driving boolean
  in their public signature. Defaults keep every caller unchanged, and the
  argument is the only way to observe the upgrade round trip. Left as is.
- A rolling deploy whose nodes run different `phoenix_kit_ai` versions would
  flip the stored row back and forth. Nodes of one release share one lock, so
  this cannot happen in practice. Recorded, not guarded.
