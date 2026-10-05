# PR #144 — follow-up

Triage of `CLAUDE_REVIEW.md` (Claude, 2026-10-05). Two IMPROVEMENT, two NITPICK.

## Fixed

- ~~IMPROVEMENT - MEDIUM — four `ListChromeTest` tests fail on a core older than 2.54.0.~~ `test/web/list_chrome_test.exs`: `@core_fit?` / `@needs_fit` and `@tag skip: @needs_fit` on the four tests.
- ~~IMPROVEMENT - MEDIUM — `//host/admin/catalogue` raised in `redirect/2`.~~ `lib/phoenix_kit_catalogue/web/legacy_path_controller.ex` (`target/2` collapses leading slashes); pinned in `test/web/legacy_path_test.exs`.
- ~~NITPICK — stale `catalogue/:uuid/edit` comment.~~ `lib/phoenix_kit_catalogue.ex`.
- ~~NITPICK — `slot :row` formatting.~~ `lib/phoenix_kit_catalogue/web/components.ex`.

## Skipped (with rationale)

None.

## Files touched

`lib/phoenix_kit_catalogue.ex`, `lib/phoenix_kit_catalogue/web/components.ex`, `lib/phoenix_kit_catalogue/web/legacy_path_controller.ex`, `test/web/legacy_path_test.exs`, `test/web/list_chrome_test.exs`.

## Verification

See the release commit: `mix precommit` and `mix test` (Hex core 2.53.0, and `PHOENIX_KIT_PATH=../phoenix_kit` for the fitted-table tests).

## Open

Column fitting takes effect only on `phoenix_kit` >= 2.54.0, which is unreleased on Hex.

## Codex release recheck — 2026-10-05

- Fixed `CODEX_REVIEW.md`'s IMPROVEMENT - MEDIUM: row alignment and Image-column
  tree layout are checked on older cores too. Only hook-presence assertions
  depend on core support; all four formerly skipped tests now run.
- Fixed the NITPICK about suffix preservation: one replacement across both
  configured legacy addresses, with regressions for both pattern orders.
- See `CODEX_REVIEW.md` for the combined release-sweep validation.
