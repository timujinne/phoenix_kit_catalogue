# PR #137 — Add the {{Glossary}} slot to both catalogue translation prompts — follow-up

Triage of `CLAUDE_REVIEW.md` (Claude, post-merge). One IMPROVEMENT, two NITPICKs, two "Not changed" notes.

## Fixed (pre-existing)

- ~~IMPROVEMENT - MEDIUM — the repo's own lock never ran the supported branch.~~ `mix.lock` holds `phoenix_kit_ai` 0.24.1 and the floor is `~> 0.24` (`mix.exs:140`), so `glossary_slot_supported?/0` (`lib/phoenix_kit_catalogue/ai_prompt.ex:329-332`) is true in dev, test and release. The default-capability test is `test/phoenix_kit_catalogue/ai_prompt_glossary_test.exs:83`.
- ~~NITPICK — the Rollout moduledoc described the sha input wrongly.~~ It reads "sha256 hex of the template as `content/2`/`sets_content/2` render it for the installed `phoenix_kit_ai`" (`ai_prompt.ex:66-68`).
- ~~NITPICK — two comment paragraphs ran together.~~ The comment above `content/2` has a `#` line between every paragraph (`ai_prompt.ex:276-307`).

## Skipped (with rationale)

- **`ensure_prompt` / `ensure_sets_prompt` take a test-driving boolean in their public signature.** The review left it: the defaults keep every caller unchanged and the argument is the only way to observe the upgrade round trip. Still so (`ai_prompt.ex:228-237`, `:257`).
- **A rolling deploy with mixed `phoenix_kit_ai` versions would flip the stored row.** The review recorded it without a guard, because nodes of one release share one lock. With the floor at `~> 0.24` both capabilities are true on every supported install, so the flip can no longer happen at all.

## Files touched

None.

## Verification

Re-verified by reading `main` at `e8a969f` (0.46.1) on 2026-10-05 (quality sweep, Phase 1): each reference below was grepped and the lines read. No code changed, so no gate was run for this triage; `mix precommit` and `mix test` were not re-run.

## Open

None. (The now-unreachable capability branches are tracked in PR #138's follow-up.)
