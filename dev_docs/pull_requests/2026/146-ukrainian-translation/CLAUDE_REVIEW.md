# PR #146 — Add Ukrainian (uk) translation

- **Reviewer:** Claude
- **Date:** 2026-10-11
- **Author:** timujinne (merged by Dmitri Don)
- **Scope:** `priv/gettext/uk/LC_MESSAGES/default.po` (1160 msgids) and
  `test/phoenix_kit_catalogue/uk_locale_test.exs`.

No bugs found. The PR is a data-only change: no `lib/` code is touched.

## What was checked

- **Same msgids as `default.pot`**, singular and plural, in both directions
  (1160 entries in the template, `ru` and `uk`). The PR's own test pins this.
- **Plural rule** is the Slavic three-form rule, same as `ru`; the test pins
  1 / 2 / 5 / 11 / 21 / 22 / 25.
- **Bindings** — every `msgstr` form keeps its msgid's `%{...}` names.
- **Date formats** (`%b %d, %Y`, `%b %d, %Y %H:%M`) are localized the same way
  as `ru` (`%d.%m.%Y`), so a Ukrainian user no longer sees English month names.
- **No fuzzy or empty entries**; no Russian-only letters (`ы э ъ`) in any
  `msgstr`; only two `msgstr`s equal their msgid (`https://...`, `URL slug`),
  both reasonable as technical terms.
- **Core knows the code** — `phoenix_kit` already maps `uk` in its locale
  utilities, so no registration is needed here.
- `mix test test/phoenix_kit_catalogue/uk_locale_test.exs test/gettext_test.exs`
  passes (80 tests). The `missing Gettext bindings` log lines come from existing
  tests that call `gettext` without bindings on purpose.

## NITPICK — `URL slug` is left in English

`ru` renders it `URL-слаг`. Leaving the English term is defensible (the field is
a technical identifier) and a native speaker's call, so it is not changed.

## NITPICK — the locale test is not shared with `ru`/`et`/`de`/`fr`

The both-directions msgid check exists only for `uk`. Worth generalising to a
locale loop later; not worth a change in a patch release.
