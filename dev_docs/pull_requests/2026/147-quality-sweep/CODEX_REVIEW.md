# PR #147 — Independent recheck of release 0.48.0

- Reviewer: Codex
- Date: 2026-10-13
- Scope: merged PR `61988cf`, release `723e85b`, and surrounding callers.

No additional defects confirmed in this PR. Rechecked text decoding, XLSX
exception boundaries, JSON shape validation, the export controller's permission
and parameter gates, redirect escaping, shared-sort subscribers, settings actor
attribution, repeated trash/restore logging, and import outcome logging in the
supervised task.

The multilingual test-site setup matches core's locale-routing contract;
serving both prefixes within one live session preserves patch navigation. The
unmodified release passed all 3,719 tests, with integration tests enabled.

## NITPICK — pagination test's async deadline is too short under load

The subsequent full run and a focused rerun both failed the pagination test's
default 100ms `render_async/1` wait. This is a database-backed 50-result search,
not a performance assertion. Both waits in that test now explicitly allow five
seconds; all page membership, row-count and duplicate-row assertions remain.
The focused test passes with the corrected wait. No pagination code changed.

Final validation: `mix test --seed 342308` passed 2 doctests and 3,724 tests with
zero failures, with integration tests enabled. `mix precommit` passed.

The additional release defects and fixes are documented in
[the #148 recheck](../148-media-folders/CODEX_REVIEW.md).
