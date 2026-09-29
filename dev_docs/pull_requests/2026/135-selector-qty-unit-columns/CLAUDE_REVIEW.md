# PR #135: ItemSelectorModal: with a :unit column the qty stepper drops its unit suffix — Claude review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/135
**Author**: @timujinne
**Reviewer**: Claude Opus 5.5, post-merge pass
**Date**: 2026-09-22
**Merge**: `c7e0abd`, 3 files, +47 / −3
**Status**: reviewed; no bugs; one test added to pin the hidden-column case; released as 0.44.2

## Scope

In the item selector's table and comfy views, a decimal-precision
`qty_stepper` carried the item's unit as a `join-item` suffix ("pc", "m").
Suffixes of different widths shifted every input, so a column of quantities
zig-zagged. When the host grants a `:unit` column the suffix is now dropped,
using the same `:unit not in @columns` grant test the price cell's
`inline_unit` has used since 2026-09-16. The `:price` and `:base_price`
cells also get `tabular-nums`.

## Verification

- `@columns` is the granted set (`Browse.resolve_columns!/2`), not the
  visible set (`@visible_columns` / `@eff_columns`). The stepper and the
  price cell now read the same assign, so they cannot disagree.
- The change is only in the table/comfy `<:qty>` slot. The card-view
  footer, the tray and the details popup steppers keep their suffix, which
  is right: none of those surfaces has a unit column.
- Integer precision (`decimal_qty?/1` false) never had a suffix, so nothing
  changes there.
- `qty_stepper` renders the suffix only `:if={@unit}`, so passing `nil` removes
  the whole `span.join-item`. The input keeps its fixed `qty_width/1`, so the
  inputs line up.

## Findings

### NITPICK: a hidden-but-granted `:unit` column leaves no unit on screen (kept, pinned)

If the viewer hides a granted `:unit` column with the column toggle (or the
host starts it hidden through `hidden_columns`), the table shows neither the
unit column nor the stepper suffix. For a free-decimal quantity, "0.5" then
has no unit next to it. This is the same trade-off the price cell made on
2026-09-16 (`item_row`'s `inline_unit` doc: "hiding it leaves a bare
price"), and the viewer did ask for the unit to go away. Switching the test
to `:unit in @visible_columns` would make the suffix come and go with the
toggle, and would split the stepper from the price cell. I left the
behaviour alone and added a test that pins it:
`a granted but hidden :unit column still keeps the suffix off the stepper`.

## Outside the PR: stale item-form snapshot (fixed)

The full suite had one failure that is not from this PR:
`extension_slot_test.exs` "the item form renders exactly as before the
extension slot existed". The `libs` commit (`3ec08be`) moved the lock to
phoenix_kit 2.37.4, and that release adds zero-clear `onfocus` / `onblur` /
`onkeydown` handlers to core's `decimal_input`. The item form's base price,
markup and discount inputs therefore render three new attributes. I added
exactly those attributes to `test/fixtures/item_form_no_ext.html` and
changed nothing else in it.

## Gate

`mix format`, `mix precommit` clean; `mix test` 3366 tests + 2 doctests, 0 failures on two consecutive runs. One earlier run had a single intermittent failure that neither `--failed` nor two full reruns reproduced.
