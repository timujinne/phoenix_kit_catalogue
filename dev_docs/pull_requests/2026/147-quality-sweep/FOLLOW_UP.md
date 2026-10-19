# PR #147 — follow-up

Triage of `CLAUDE_REVIEW.md` (Claude) and `CODEX_REVIEW.md` (Codex). No bugs;
two NITPICKs, both already resolved by the release work, re-verified against
current code.

## Fixed (pre-existing)

- ~~NITPICK — suite red on HEAD after the core bump: core leaves the locale
  segment out of admin paths on a single-language site, while the test router
  and expectations assume `/en/admin/...`.~~ `test/test_helper.exs` makes the
  test site multilingual with the prefix kept
  (`set_default_language_no_prefix(false)`), and `test/support` `Test.Router`
  serves both `/en/admin/...` and `/admin/...` in one live session. Recorded in
  `../148-media-folders/FOLLOW_UP.md`.
- ~~NITPICK — the pagination test's default 100ms `render_async/1` wait is too
  short under load.~~ Both waits now allow five seconds
  (`test/web/catalogues_live_test.exs`, `render_async(view, 5_000)`); fixed in
  the Codex recheck itself.

## Skipped (with rationale)

None.

## Files touched

None — triage only.

## Verification

Findings re-verified against current `main` at commit `899fa9c`.

## Open

None.
