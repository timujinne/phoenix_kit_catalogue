# PR #143 — Import/export source names in English

- **Author:** timujinne (Timujeen)
- **Merge:** `ff911cf` (head `3d46bec`)
- **Reviewer:** Claude
- **Date:** 2026-09-28

## Scope

Replaces the hard-coded bilingual labels of the import sources and export
destinations (`"Универсальный (Universal)"`, `"Фурнитура (Furniture)"`,
`"Материалы (Materials)"`, `"JSON (экспорт)"`) with English ones, and
rewrites one Russian word in a `Web.Components.Browse` comment in English.

## Verified

- Only the display half of each `{key, label}` pair changed. Every caller
  that validates a format (`Export.build/1`, `ExportLive`, `ImportLive`)
  matches on the atom key, never on the label, so no lookup broke.
- Tests only assert the keys, `"PRO100"`, and that the Universal label
  contains `"Universal"` — all still hold.
- The `browse.ex` change is comment-only.

## Findings

### IMPROVEMENT - MEDIUM — Russian admins lost the Russian labels

`ImportLive` and `ExportLive` render `label/0` and `formats/0` straight into
their selects (`import_live.ex:1863,1878`, `export_live.ex:128,144`), never
through gettext. The bilingual strings were the only way a Russian-locale
admin saw "Фурнитура" / "Материалы"; after the PR every locale shows the
English word, and the module's other four locales never had a translation
at all.

**Fixed.** The callbacks translate at call time with
`Gettext.gettext(PhoenixKitCatalogue.Gettext, …)` — they are called while
the LiveView renders, so the viewer's locale is already set. Doing it in
the callbacks rather than at the two render sites keeps any other consumer
of the registries translated too. `"Universal"`, `"Furniture"`,
`"Materials"` and `"JSON (export)"` are added by hand to `default.pot` and
all five locales (en, ru, et, de, fr). `"PRO100"` and `"XLSX / CSV"` are
names and stay untranslated. The `Source` / `Destination` behaviour docs
now say labels are translated at call time. Pinned in
`test/gettext_test.exs` ("import sources and export destinations label
themselves in the viewer's locale"), which calls the modules in `ru` and
`et` rather than asking the backend directly.

### NITPICK — comment wording

`browse.ex:138` now reads `the Russian "pcs"`, which says "pcs" was shown
when the Russian abbreviation was. Clear enough in context; left as is.
