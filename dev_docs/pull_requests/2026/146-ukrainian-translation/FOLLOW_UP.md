# Follow-up

Findings from `CLAUDE_REVIEW.md` (no bugs, two nitpicks), re-verified against
current code.

## Fixed (Batch 1 — 2026-10-13)

- ~~The both-directions msgid check against `default.pot` existed for `uk`
  only~~ — the test now loops over every locale directory under
  `priv/gettext` and passes for all six
  (`test/phoenix_kit_catalogue/uk_locale_test.exs`).

## Files touched

| File | Change |
|---|---|
| `test/phoenix_kit_catalogue/uk_locale_test.exs` | Parity check runs for every locale |

## Verification

`mix test` 3659 tests + 2 doctests, 0 failures. `mix precommit` clean.

## Open

- `priv/gettext/uk/LC_MESSAGES/default.po` keeps `msgid "URL slug"` /
  `msgstr "URL slug"` (ru has `URL-слаг`). The reviewer called it a native
  speaker's choice; it waits for the maintainer's fix-or-skip decision.
