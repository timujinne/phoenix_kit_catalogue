# PR #149 — Import Windows-encoded CSV and PRO100 files through an encoding step; translate URL slug in Ukrainian

- **Reviewer:** Claude
- **Date:** 2026-10-15
- **Author:** Max Don (merged by Dmitri Don)
- **Scope:** `Import.Encoding` (code-page tables, `guess/2`, `preview/2`,
  `to_utf8/2`), the `encoding:` option through `Parser`, `Pro100Parser`,
  `Source.Universal` and `Source.Pro100`, the `:encoding` step in `ImportLive`,
  `:wrong_encoding` in `Errors`, gettext for all six locales, tests.

No defect found. What was checked, so the result is on record:

- **The tables.** All five upper halves were checked byte by byte against the
  vendor mappings for the undefined slots (1250: 81 83 88 90 98; 1251: 98;
  1252: 81 8D 8F 90 9D; 1257: 81 83 88 8A 8C 90 98 9A 9C 9F A1 A5) and the
  ISO-8859-15 departures from Latin-1 (A4 A6 A8 B4 B8 BC BD BE). Every page
  is asserted to hold exactly 128 entries at compile time.
- **Every parse of one upload passes the confirmed page.** `rg` over `lib/`
  finds six parse call sites (`Universal.parse`, `Parser.parse` in
  `select_sheet`, `Pro100Parser.parse`, `Source.Pro100.analyze`, and the two
  in `ImportLive`); all take `encoding:`. `file_encoding` is reset by
  `reset_encoding_state/1` on Back, Start over and a fresh upload, and set
  after the reset on success, in that order, in both the mapping and the sync
  path.
- **A page can never garble a file that names its own encoding.** `to_utf8/2`
  tries `to_utf8/1` first and only falls into the page for `:not_utf8`; a NUL
  byte stays `:not_utf8` (not text), so the parser's own message is kept.
- **Hostile input.** `choose_encoding` takes a value through
  `parse_code_page/1`, which answers `:error` for anything that is not one of
  the five atoms' names (no `String.to_atom`); both events are no-ops with no
  pending upload; `confirm_encoding` re-checks `encoding_undefined` server
  side, whatever the disabled button did. The hostile-upload test walks every
  page, a bogus value and a confirm after each.
- **Gettext.** The nine new msgids are in `default.pot` and all six `.po`
  files with non-empty translations (checked `de`, `fr`, `uk` by hand, which
  `gettext_test.exs` does not pin — it covers `en`/`et`/`ru`).
- **Core pin.** Nothing new is used from core.

## NITPICK — `to_utf8/2` validates the same bytes twice on a refused file

`to_utf8/2` calls `to_utf8/1`, then `needs_code_page?/1` calls it again (and
`ImportLive.ask_encoding?/3` calls `needs_code_page?/1` before that). A file is
bounded by the upload limit and the check is one `:unicode` pass, so this is
microseconds; **not changed**.

## NITPICK — a mostly-UTF-8 file with one stray byte lands on the encoding step

A UTF-8 file with a single Windows-1252 character is not valid UTF-8, so it is
offered a code page, and the preview shows its multi-byte letters as mojibake
under every page. The operator can see that and go back; there is no page that
helps. Guessing "UTF-8 with replacements" would import silently wrong letters,
which is exactly what the PR set out to avoid, so this is the right trade.
**Not changed.**
