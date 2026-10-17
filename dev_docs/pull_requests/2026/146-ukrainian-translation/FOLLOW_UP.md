# Follow-up

Findings from `CLAUDE_REVIEW.md` (no bugs, two nitpicks), re-verified against
current code.

## Fixed (Batch 1 — 2026-10-13)

- ~~The both-directions msgid check against `default.pot` existed for `uk`
  only~~ — the test now loops over every locale directory under
  `priv/gettext` and passes for all six
  (`test/phoenix_kit_catalogue/uk_locale_test.exs`).

## Fixed (Batch 2 — 2026-10-14)

- ~~`priv/gettext/uk/LC_MESSAGES/default.po` kept `msgid "URL slug"` /
  `msgstr "URL slug"`~~ — now `URL-слаг`, as in the Russian file. The two
  other Ukrainian strings that spelled the word in Latin letters follow it
  (`Показувати URL-слаг і поля SEO`, `У цього значення немає слага, …`), so
  the settings switch names the field the way the form labels it.

## Files touched

| File | Change |
|---|---|
| `test/phoenix_kit_catalogue/uk_locale_test.exs` | Parity check runs for every locale |
| `priv/gettext/uk/LC_MESSAGES/default.po` | `slug` → `слаг` in three msgstrs |

## Verification

`mix test` 3659 tests + 2 doctests, 0 failures. `mix precommit` clean.

## Open

None.
