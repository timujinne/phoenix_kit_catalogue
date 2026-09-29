# PR #140 — Units for services and more goods units

- **Author:** timujinne (Tymofii Shapovalov)
- **Merge:** `16fc286` (head `e71631a`)
- **Reviewer:** Grok
- **Date:** 2026-09-26

## Scope

`Item.allowed_units/0` grows from six codes to fifteen: `hour`, `service`,
`visit`, `km` for services and `pack`, `roll`, `kg`, `litre`, `m3` for
goods. `unit_groups/0` feeds the item form's grouped select.
`unit_label/1` and the gettext catalogues (en, et, ru, de, fr) cover the
new codes. `Import.Mapper` learns Estonian and Russian aliases. No
migration: `items.unit` has no CHECK.

`CatalogueRule.allowed_units/0` (`percent` / `flat`) is a different
vocabulary and was correctly left alone.

## Verified

- The item form builds both optgroups from `unit_groups/0`, and every
  code `allowed_units/0` returns appears in exactly one group (pinned in
  `test/schemas_test.exs`).
- `unit_label/1` has a clause per code; unknown strings still pass
  through. The new msgids are in `default.pot` and all five locales.
- PRO100 resolves through the same alias map and still returns `:unknown`
  for a label with no alias, rather than coercing it to `piece`.
- The item-form snapshot normaliser only reorders the `JS.dispatch`
  payload keys. It does not drop fields.

## Findings

### BUG - MEDIUM — New unit codes and several of their labels imported as pieces — FIXED

`normalize_unit/2` returns `"piece"` for anything not in `@unit_aliases`.
The six older codes are keys in that map (`"piece"`, `"m2"`,
`"running_meter"`, …). The nine new codes were not, except where the code
happens to equal a short label already added (`"km"`, `"kg"`, `"m3"`).

The universal JSON export writes the code (`"unit": "hour"`). The import
wizard seeds its mapping dropdown from `normalize_unit/2`, so a file that
is not hand-corrected stores hours, visits, packs and rolls as pieces.
The same hole hits the abbreviation `unit_label/1` shows in the tables
when that abbreviation is not the code: English `service`, `visit`,
`pack`, `roll`, and the German and French translations (`Std.`,
`Leistung`, `Anfahrt`, `Pkg.`, `Rolle`, `prestation`, `déplacement`,
`paquet`, `rouleau`). Estonian and Russian short labels were already
aliased.

**Fix:** every `Item.allowed_units/0` code is an alias of itself, plus
`liter` and the de/fr `unit_label/1` strings for the new codes.
`test/import/mapper_test.exs` now asserts the code and the English label
of every allowed unit round-trip, and the et/ru/de/fr label of each new
code.

### NITPICK — `create_item/2` and the item picker still described the old unit list — FIXED

`create_item/2` documented `:unit` as `"piece"`, `"m2"` or
`"running_meter"`. The picker's `:format_unit` docs listed six
abbreviations and said anything else passes through, while the default
is `Item.unit_label/1`, which labels the new codes (`hour` → `h`). Both
now point at that source.
