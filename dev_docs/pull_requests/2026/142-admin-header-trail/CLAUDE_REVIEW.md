# PR #142 — Fix the admin header trail

- **Author:** mdon (Dmitri Don)
- **Merge:** `7c591be` (head `e25892e`)
- **Reviewer:** Claude
- **Date:** 2026-09-25

## Scope

Every page under the module now hands core's admin header
`page_section = Catalogues` → the landing page, `page_crumbs` = every level
in between, and `page_title` = the page alone (`Edit`, `New item`). A new
`Web.HeaderTrail` builds the catalogue → category-chain crumbs for the forms
and the PDF page; `test/web/header_trail_test.exs` pins each page's shape.

## Verified

- `page_crumbs` (with optional `path`, plain-text crumbs) already exists in
  `LayoutWrapper.app_layout` at core **v2.38.0**, the declared floor — no
  floor bump needed.
- `"Edit"`, `"PDFs"`, `"Attributes"`, `"Catalogues"`, `"%{count} rows"` are in
  `default.pot` and all five locales.
- The browser tab now reads just `Edit` on every edit page. Deliberate:
  core's `dev_docs/guides/2026-09-25-admin-header-trail.md` (rule 1) says
  `page_title` feeds the tab and carries no trail. Not a finding.
- Item form's post-save refresh re-reads the catalogue from
  `item.catalogue_uuid`, so the trail follows a Location move on save.
- The new-item trail uses `valid_origin_category/2`'s result, which is
  already restricted to the URL's catalogue.

## Findings

### BUG - MEDIUM — New-category trail drew a parent the form had rejected — FIXED

`CategoryFormLive` builds the `:new` trail from the raw `?parent_uuid=`,
while `offered_parent/3` sends a parent the tree does not offer (a category
of another catalogue, one trashed since the link was rendered) back to the
top level. The header then showed a category chain the form was not
creating under — and for another catalogue's category, linked it as
`/<this catalogue>?category=<foreign uuid>`, a level page that does not
exist in this catalogue.

**Fix:** `parent_pick` is computed once in `mount_category_form/5` and the
`:new` trail is built from `PlaceTree.uuid(parent_pick)`, so the header and
the picker agree. As defence in depth, `HeaderTrail.place_crumbs/3` now
draws no category chain for a category whose `catalogue_uuid` is not the
catalogue's. Tests: a new-category page opened with another catalogue's
parent shows only the catalogue crumb; `place_crumbs/3` with a foreign
category returns the catalogue alone. Both fail on the merged code.

### NITPICK — Events and PDFs still prefixed their subtitle with `Catalogues · ` — FIXED

The PR removed that prefix from Translations (the section now says it) but
left it on `EventsLive` and `PdfLibraryLive`, so their header read
`Catalogues / Events · Catalogues · Events: 12`. Dropped the prefix on both.

## Gate

`mix precommit` clean. `mix test`: 3437 tests, 0 failures. One earlier full
run reported a single failure that did not reproduce on two reruns;
it was not captured, and the header-trail and touched LV suites pass
consistently.
