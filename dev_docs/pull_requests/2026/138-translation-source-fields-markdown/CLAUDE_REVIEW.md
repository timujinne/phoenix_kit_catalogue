# PR #138 — Build the translation prompts from {{SourceFields}}, keep Markdown in its field

- **Author:** Timujeen (`timujinne/fix/translation-markdown-sections`)
- **Merged:** 2026-09-24 (`ba5a646`; commits `912f7ce`, `a86d8c1`)
- **Reviewer:** Claude (post-merge)
- **Scope:** 4 files, +345 / −63. `AIPrompt` builds both templates from
  pieces: the prompt's own rules, shared rules and a SOURCE block. On a
  `phoenix_kit_ai` that binds `{{SourceFields}}`, the SOURCE block is that
  one slot. On an older engine it is one slot per field, plus the rule
  to skip unbound slots. Two new shared rules: don't continue a field cut
  off mid-sentence, and keep a value's Markdown headings inside its field
  instead of turning them into marker lines.

## Verified

- **The capability probe matches the engine's history.** In
  `phoenix_kit_ai`, `build_variables/3` and the `"SourceFields"` binding
  both first appear in v0.23.0, and v0.22.0 has neither. From 0.23.2 the
  function is `build_variables/4` with a default glossary, so it still
  exports `/3`. `function_exported?(…, :build_variables, 3)` is therefore
  true exactly when `{{SourceFields}}` is bound. The glossary probe (`/4`)
  implies the SourceFields probe, so of the four capability combinations
  only `glossary && !source_fields` can't happen on a real install, and it
  still renders a valid template.
- **Markers agree end to end.** The engine's `source_fields_section/1`
  uses the same `marker/1` that `parse_response/2` reads back, so
  `---NAME---`-style input sections match the output format the template
  asks for.
- **Blank fields never reach the block.** `AITranslatable.source_fields_pure/2`
  drops blank values, and the engine rejects an empty map, so the new
  "emit exactly those marker lines" wording cannot ask for a marker with
  no source text. The old "non-blank value" qualifier isn't needed.
- **Rollout.** The template change changes `content_sha`, so
  `maybe_update/2` rewrites each stored prompt in place on the next
  `ensure_*` call, keeping the uuid. The new rollout test covers that for
  both prompts.
- **Glossary removal still works on the new layout.** `{{Glossary}}\n\n`
  now lives in `@shared_rules`, and `with_glossary_slot(_, false)` removes it
  cleanly from both SOURCE-block variants. I checked this by rendering
  `sets_content(false, false)`.

## Findings

### NITPICK — stale `content/1` reference in the `ensure_prompt/2` comment

`content/1` became `content/2` here, and the PR updated the moduledoc but
not the comment above `ensure_prompt/2` ("for the same reason
`content/1`'s does"). **Fixed.**

### NITPICK — Markdown rule speaks of "sections" on the legacy SOURCE block

On an engine older than 0.23.0, the SOURCE block uses `Name: …` labels,
not marker sections, and the Markdown rule says "inside that field's
section". The rule is still correct there because the *output* is
sectioned, and the path only applies to `phoenix_kit_ai` < 0.23.0 (the
lock is at 0.24.0). **Left as is.**

## Post-merge, not from this PR

`test/web/extension_slot_test.exs` (the "renders exactly as before" item-form
snapshot) failed after the `libs` commit moved `phoenix_kit` 2.37.5 → 2.38.1.
Core's `<.input>` no longer leaves a trailing space in its class string
(`focus:input-primary "` → `focus:input-primary"`), and that was the only
difference in the page. **Fixed** by updating the three affected inputs in
`test/fixtures/item_form_no_ext.html`.

## Validation

`mix test` passes: 3424 tests, the one failure being the snapshot above,
now fixed. `mix precommit` is clean.

## Release (0.45.0)

This release also ships #136. Its review's release blocker (finding 1)
is now resolved: `phoenix_kit` 2.38.0 carries #860 and `phoenix_kit_ai`
0.24.0 carries `TranslationSweep`, and the suite compiles and passes
against those Hex releases with no `_PATH` overrides. The floors are raised
to `>= 2.38.0 and < 3.0.0` and `~> 0.24`, and `test/core_pin_conformance_test.exs`
and AGENTS.md are updated to match.

With `~> 0.24`, both `AIPrompt` capability probes (glossary and
SourceFields) are always true on a supported install, so the legacy
branches are unreachable. They are kept for now: they cost nothing, and
the tests still exercise them directly. They can be removed in a later
cleanup.
