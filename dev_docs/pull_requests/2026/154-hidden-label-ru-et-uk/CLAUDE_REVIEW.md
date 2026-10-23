# PR #154 — Call the category flag "hidden" in ru, et and uk

- **Reviewer:** Claude
- **Date:** 2026-10-22
- **Author:** timujinne (merged by Dmitri Don)
- **Scope:** the `msgstr` of `msgid "Internal"` in `ru`, `et` and `uk`,
  `test/gettext_test.exs`.

No defect found. What was checked:

- **Both call sites stay in step.** `msgid "Internal"` is read in exactly two
  places, the category form checkbox (`category_form_live.ex`) and
  `internal_badge/1` (`components.ex`); both are about a category, so the
  feminine ru/uk forms ("Скрытая", "Прихована") agree with the noun. "Peidetud"
  does not inflect.
- **Nothing else carries the old word.** The only other "Внутренн-/Внутрішн-"
  strings are "Internal notes about this manufacturer/supplier...", an
  unrelated msgid.
- **The explanation under the checkbox** ("Kept out of the item pickers and
  browse pop-ups…") and the badge tooltip never used the old word, so the new
  label and its explanation read together.
- **The pins** now cover ru, et and uk.

## Findings

- NITPICK — English, de and fr still say "Internal" / "Intern" / "Interne",
  the reading the PR found misleading in the other three. Not changed: the
  msgid is shared by every locale and the `.pot` is hand-maintained, so
  renaming it is a product call (and a hand edit of every `.po`), not a
  review fix.
