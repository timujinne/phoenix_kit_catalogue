# PR #135 — ItemSelectorModal: qty stepper drops its unit suffix beside a `:unit` column — follow-up

Triage of `CLAUDE_REVIEW.md` (Claude Opus 5.5, post-merge, 2026-09-22). One NITPICK, plus one fix outside the PR.

## Fixed (pre-existing)

- ~~Outside the PR: the item-form snapshot went stale when core's `decimal_input` gained zero-clear handlers.~~ `test/fixtures/item_form_no_ext.html` carries the `onfocus` / `onblur` / `onkeydown` attributes on the three decimal inputs (`ac8a704`, 0.44.2).

## Skipped (with rationale)

- **NITPICK — a granted but hidden `:unit` column leaves no unit on screen.** The review kept the behaviour on purpose and pinned it. Still as reviewed: the stepper suffix and the price cell's `inline_unit` both test `:unit not in @columns` (`lib/phoenix_kit_catalogue/web/components/item_selector_modal.ex:2979`, `:2999`), and the pin is `test/web/item_selector_modal_test.exs:376` ("a granted but hidden :unit column still keeps the suffix off the stepper"). The price cell's matching trade-off is documented at `lib/phoenix_kit_catalogue/web/components/browse.ex:1024`.

## Files touched

None.

## Verification

Re-verified by reading `main` at `e8a969f` (0.46.1) on 2026-10-05 (quality sweep, Phase 1): each reference below was grepped and the lines read. No code changed, so no gate was run for this triage; `mix precommit` and `mix test` were not re-run.

## Open

None.
