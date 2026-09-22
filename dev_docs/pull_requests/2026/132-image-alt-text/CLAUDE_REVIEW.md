# PR #132: Add real alt text to catalogue thumbnails and chip previews — Claude review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/132
**Author**: @timujinne
**Reviewer**: Claude Opus 5 — post-merge pass
**Date**: 2026-09-22
**Merge**: `83822de` (closes #93), 11 files, +120 / −7
**Status**: reviewed; no bugs; one nitpick on record; released as 0.44.0

## Scope

Seven `<img>` sites that hardcoded `alt=""` now carry the entity's name:
`featured_thumb/1` → `thumb_visual/1` (new `name` attr), `image_column_cell/1`,
the attribute-set items modal row, `Browse`'s `:thumb` cell and card figure,
the item selector's tray row, and the item form's archived attribute-value
chip. Two stay `alt=""` on purpose, each with a comment and a pinning test: the
selector header image (inside the dialog's labelling `<h3>`) and the selectable
chip (inside a `<label>` that already names it).

## Checked and fine

- `name` is a `:string` on every schema that reaches `featured_thumb`
  (catalogue, category, item), and every list feeding it is run through
  `Catalogue.localize/2` first, so the alt is in the page's language, not the
  primary one.
- `featured_thumb` with `on_click`: the button used to take its accessible
  name from `title="View item details"` (the image contributed nothing); now
  the name is the item's and the title becomes its description. An
  improvement, not a regression.
- The category card's picture sits in its own `category_card_trigger`, apart
  from the name trigger — before this it was a link with no accessible name.
- `nil` names fall back to `""` everywhere; no `alt="nil"` path.
- Tests assert each alt scoped to its element (the tray test scopes to the
  tray row, since the browse list renders the same item).

## Findings

### NITPICK — redundant alt next to identical visible text (not changed)

The tray row, the archived chip and the attribute-set modal row render the
image directly beside text that repeats the name, with no shared control in
between. W3C's alt decision tree calls that a redundant image and prefers
`alt=""`, so a screen reader reads "Oak, Oak". The PR weighed this and kept
the name for users navigating by graphic, which matches the #91 precedent for
`item_picker`. Left as is: both readings are defensible, and changing only
these sites would split the convention.
