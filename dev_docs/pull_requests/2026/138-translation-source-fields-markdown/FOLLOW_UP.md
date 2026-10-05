# PR #138 — Build the translation prompts from {{SourceFields}}, keep Markdown in its field — follow-up

Triage of `CLAUDE_REVIEW.md` (Claude, post-merge). Two NITPICKs, one post-merge snapshot fix, one cleanup suggestion in the release note.

## Fixed (pre-existing)

- ~~NITPICK — stale `content/1` reference in the `ensure_prompt/2` comment.~~ It reads "for the same reason `content/2`'s does" (`lib/phoenix_kit_catalogue/ai_prompt.ex:228`); no `content/1` is left in the file. Commit `cdbdae2`.
- ~~Post-merge, not from the PR: the item-form snapshot failed after core dropped the trailing space in `<.input>`'s class.~~ `test/fixtures/item_form_no_ext.html` has no `focus:input-primary "` left. Commit `cdbdae2`.
- ~~Release note: PR #136's release blocker.~~ Resolved; see PR #136's follow-up, finding 1.

## Skipped (with rationale)

- **NITPICK — the Markdown rule says "inside that field's section" on the legacy SOURCE block.** The review left it: the output is sectioned either way, and the wording only reaches an engine older than 0.23.0, which the `~> 0.24` floor no longer admits. The rule is at `ai_prompt.ex:133-135`.

## Files touched

None.

## Verification

Re-verified by reading `main` at `e8a969f` (0.46.1) on 2026-10-05 (quality sweep, Phase 1): each reference below was grepped and the lines read. No code changed, so no gate was run for this triage; `mix precommit` and `mix test` were not re-run.

## Open

- **Cleanup suggestion — the legacy capability branches are unreachable.** Awaiting Max's decision. With `phoenix_kit_ai ~> 0.24` both probes are always true, yet the code keeps `glossary_slot_supported?/0` and `source_fields_supported?/0` (`lib/phoenix_kit_catalogue/ai_prompt.ex:329-342`), the per-field `template/3` clause (`:346-347`) and the slot-removing `with_glossary_slot/2` clause (`:351`). The review said they "can be removed in a later cleanup". Removing them means dropping both probes, the two boolean arguments of `content` / `sets_content` / `ensure_prompt` / `ensure_sets_prompt`, `@unbound_slot_rule`, `@per_field_block` and the slot lists, and rewriting the tests that drive the old branches (`test/phoenix_kit_catalogue/ai_prompt_glossary*_test.exs`, `ai_prompt_source_fields*_test.exs`).
