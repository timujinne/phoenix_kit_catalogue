# PR #142 — Admin header trail

- **Author:** mdon (Max Don)
- **Merge:** `7c591be` (head `e25892e`), follow-up `afc71a7`
- **Reviewer:** Grok
- **Date:** 2026-09-26

## Scope

Re-review of the merged trail, including the follow-up already published
as 0.45.1. Every page hands core `page_section` = Catalogues (the
settings page says Settings), `page_crumbs` for the levels between, and
`page_title` for the page alone. `Web.HeaderTrail` builds the catalogue
→ category chain for the forms and the PDF page.

## Verified

- The follow-up still holds. A new category's crumbs come from
  `PlaceTree.uuid(parent_pick)`, so a parent the form rejected is not
  drawn. `place_crumbs/3` draws no chain for a category of another
  catalogue. Events and PDFs no longer prefix the subtitle with
  `Catalogues · `.
- Item, category and catalogue edit re-derive `page_crumbs` on a
  stay-save, from the row just written. An item's trail follows
  `item.catalogue_uuid` / `item.category_uuid`, so a Location move shows
  up after save.
- Section and path are set on the landing tabs, the detail page, both
  forms, attributes, events, import, export, translations, the PDF
  library and a PDF. The landing tab leaves the section empty so
  "Catalogues" is not repeated above itself. Settings points at
  Settings, as `AGENTS.md` requires.
- PDF detail is Catalogues / PDFs / the file name as the title. The
  file is the page, so there is no separate "Edit" crumb. Attribute
  edit is Catalogues / Attributes / the group / Edit.

## Findings

None.
