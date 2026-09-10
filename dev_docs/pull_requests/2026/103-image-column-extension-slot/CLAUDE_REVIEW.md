# PR #103: Managed Image column + shop-extension column slot on detail lists — Claude review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/103
**Author**: @timujinne
**Reviewer**: Claude (Sonnet 5) — post-merge pass
**Date**: 2026-09-10
**Status**: reviewed; one bug found and fixed post-merge

## Scope

Two additions to the catalogue detail page's item/category tables (`TableConfig`
`:detail_items` / `:detail_categories`):

1. An opt-in, off-by-default "image" managed column (small storage variant,
   empty space instead of a broken-image glyph when unset).
2. A duck-typed `item_columns/0` / `category_columns/0` slot on
   `PhoenixKitCatalogue.Extension`, discovered via
   `PhoenixKitCatalogue.Extensions.columns/1` with the same resilience
   contract as the existing form-section slot — contributed ids namespaced
   under the extension's own `key/0`.

The PR shipped in two commits: the feature, then a same-day "Fix review
findings" commit that already hardened per-row `label`/`render` failures
(raise/throw/exit/non-safe-HTML degrade to a blank cell, logged once per
render via a process-dictionary latch), suppressed the automatic thumbnail
column once the managed "Image" column is on (table view), rendered
extension columns in card view too, and rejected a `":"` in a column id or
extension key. That prior round of review was thorough — the following is
what it missed.

## Findings

### BUG - MEDIUM: the managed "Image" column duplicates the picture in card view (fixed)

The "Fix review findings" commit added `and "image" not in assigns.*_columns`
guards so the *table* view's automatic thumbnail column disappears once the
managed "Image" column is turned on — explicitly "so a row never shows the
same picture twice." That guard only covers the desktop table.

Every card (`category_card` in `components.ex`, and the item card body in
`catalogue_detail_live.ex`) renders a media band (`<.featured_thumb>` /
`<.card_media>`) **unconditionally** — it shows the resource's
`featured_image_uuid` at the top of the card regardless of which managed
columns are selected. Both the item and category card templates are present
in the DOM on every page load (CSS/JS toggles which of the desktop table vs.
mobile card is visible, not the server), so this band isn't itself the bug.
The bug: the same card's facts grid *also* had an `"image"` case that called
`image_column_cell/1` when an admin turned the managed column on — so a
single visible card showed the picture twice at once (once "medium" in the
band, once "small" in the facts grid), the exact duplication this PR's own
fix commit set out to prevent, just missed for the card layout.

**Fix**: the `"image"` case in both card facts-grid templates (`components.ex`'s
`category_card/1`, `catalogue_detail_live.ex`'s item card body) is now a
no-op — the card's own media band already shows the picture, so the managed
column contributes nothing extra there (it's still meaningful on the table,
which has no such band). Updated
`test/web/catalogue_detail_image_column_test.exs`'s "never both show the
same picture" tests: the "small" variant count when the column is on drops
from 2 (table + card facts grid) to 1 (table only), plus a new assertion
that the card's own "medium"-variant band still renders untouched.

## Review notes (no fix needed)

- The render-failure guard (`Extensions.guarded_label/3` /
  `guarded_render/3`) forces `Phoenix.HTML.Safe.to_iodata/1` on the result
  before returning it, mirroring what the real template does when it embeds
  `{ext.render.(record)}` — this is what lets a bare, non-safe return value
  (a PID, in the `HostileRenderExtension` test fixture) get caught here
  rather than surfacing later inside the template's own conversion.
- The per-(column, render pass) log latch is a process-dictionary flag keyed
  by the namespaced column id, cleared every time `namespace_column/2` runs
  (i.e., every time `Extensions.columns/1` recomputes the list — once per
  page render of a table, per `TableConfig.extension_columns/1`'s
  documented contract). Verified this actually fires once per render, not
  once per row, and fires again on a later render if the column is still
  broken.
- The `":"` namespace-delimiter guard on both `key/0` and a contributed
  column `id` is necessary and sufficient: `valid_column?/1` rejects a
  delimiter-carrying id, and `extension_columns/2` rejects the whole
  extension's columns when its `key/0` itself carries one — verified via
  `BadIdExtension`/`BadKeyExtension` in `test/support/fake_extension.ex`
  that `"badid" <> ":" <> "a:b"` and `"badid:a" <> ":" <> "b"` can no longer
  collide.
- `contributed_columns/1`'s `render:` field is `nil` for every catalogue-
  native column and set for every extension column; `extension_columns/1`
  filters on `& &1.render` to build the id-keyed dispatch map — confirmed
  this can't accidentally pick up a catalogue-native column that later
  grows a `render:` for an unrelated reason, since no catalogue-native
  `col/2` call passes that option today.
- No `mount/3` queries, no unscoped PubSub, no N+1 introduced.

## Gate

`mix precommit` (format, credo --strict, dialyzer) clean after the fix.
Full suite: 2535 tests, 0 failures.
