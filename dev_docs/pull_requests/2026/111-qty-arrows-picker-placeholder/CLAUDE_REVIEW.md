# PR #111: Fit the quantity field's arrows in the box, and paint the picker's placeholder glyph visibly — Claude review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/111
**Author**: @mdon
**Reviewer**: Claude (Opus 5) — post-merge pass
**Merge commit**: `9fb38fe` (`7bba029`, `5c2a899`)
**Date**: 2026-09-12
**Status**: reviewed; no defects found, no post-merge code changes

## Scope

Two visual fixes from client reports on 2026-09-12:

1. `Browse.qty_stepper/1` — the native `<input type="number">` had `px-1`
   (4px each side), so Chrome drew the spin button flush against the right
   border and clipped the arrows. Now `pl-1 pr-2`: daisyUI's own 8px on the
   arrows' side, 4px on the other.
2. `ItemPicker` photo placeholder — the `hero-photo` icon carried
   `bg-base-200` itself. A hero icon is a CSS mask whose visible colour is
   its `background-color`, so the glyph was painted in the tile's surface
   colour and the placeholder rendered as an empty bordered box. The tile
   is now a wrapping `<span>` with the image's box classes plus
   `text-base-content/40`; the icon inside carries only `h-1/2 w-1/2`.

## Verification

- **Mechanism checked against core.** `PhoenixKitWeb.Components.Core.Icon`
  renders `<span class={[@name, @class]} />` with no default sizing, and the
  host's heroicons plugin (Phoenix's generator: `matchComponents`, which
  sets `background-color: currentColor`) lives in the components layer. So
  the span's `text-base-content/40` reaches the glyph through
  `currentColor`, and the `h-1/2 w-1/2` utilities override the plugin's
  default size. The percentage height resolves because the tile span has
  a definite `@photo_size` height.
- **Box parity.** The placeholder span now carries exactly the `<img>`'s
  box classes (`@photo_size shrink-0 rounded bg-base-200 border
  border-base-300`) minus `object-cover`. The old `opacity-40` also faded
  the border, so the placeholder's frame no longer looks lighter than a
  real thumbnail's. The two "placeholder box matches the image box"
  tests pin both sizes.
- **Same bug elsewhere?** A multi-line sweep of every `<.icon>` in `lib/`
  finds no other icon carrying a `bg-*` class. The other `hero-photo`
  placeholders (`Components.card_media_visual/1`,
  `AttributeSetItemsModal`) already colour the glyph with `text-*` inside a
  wrapper.
- **Width budget.** `qty_width("xs")` is `w-16`. With 12px of padding and
  the spin button there is still room for a 4–5 character quantity at
  `input-xs`. Losing 4px on the right does not truncate realistic values.
- **Tests.** `test/web/browse_components_test.exs` and
  `test/web/item_picker_test.exs` pass (82 tests). The full suite and
  `mix precommit` were run for the release.

## Findings

### NITPICK — physical padding sides on the number input

`pl-1 pr-2` names physical sides. Under `dir="rtl"` Chrome moves the spin
button to the left, so the 8px would sit on the wrong side. **Not changed:**
neither this module nor core uses logical padding (`ps-*`/`pe-*`) anywhere
or ever sets `dir="rtl"`, so switching one input would break a
repo-wide convention for a layout that cannot occur today. Revisit when core
gains RTL support.

### NITPICK — substring refutes scan the whole render

`refute html =~ "px-1"` and `refute html =~ ~r/hero-photo[^>]*bg-base-200/`
match against the whole rendered component, including the qty stepper's
inline hook script. A future unrelated `px-1` elsewhere in the component
would fail the first. **Not changed:** the exact `class="…"` pins beside
them already lock the intended markup, so the refutes are belt-and-braces
and tightening them adds nothing now.
