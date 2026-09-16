# PR #117: Item selector comfy view — Claude review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/117
**Author**: Timujeen (`timujinne/i132/comfy-finish`)
**Reviewer**: Claude (Opus 5)
**Date**: 2026-09-15
**Scope**: merge `2c70918`, commits `8c5c410`..`b90be0f`

The PR adds a third "comfy" mode to the item selector's view toggle. It is the
compact table with a larger thumbnail column, switched by a `pk-comfy` class
on a wrapper that `Browse.item_row/1`'s `[.pk-comfy_&]:…` classes react to.
It also accepts "comfy" in the shared validator, the `set_view` guard and the
per-user selector preference, adds two labels in every locale, and adds
Postgres-free render tests.

## Findings

### BUG - MEDIUM — `CatalogueBrowse` accepted "comfy" and rendered nothing

`Browse.resolve_view!/2` is the init-time validator of **both** browse surfaces.
The PR widened it for the modal, but `CatalogueBrowse` rendered only
`@view == "card"` (grid) and `@view == "table"` (table).

- A host embedding `CatalogueBrowse` with `view: "comfy"` used to get an
  `ArgumentError` at init.
- Now it passed validation and rendered neither the grid nor the table. With
  items present, the empty state was hidden too, so the surface was silently
  blank.
- The moduledoc line "a host that doesn't offer it just never passes it" relied
  on the host reading the doc.

### NITPICK — test names cite source line numbers

`set_view_guard_test.exs` and `item_selector_modal_comfy_test.exs` name lines
such as `item_selector_modal.ex:1689` and `browse.ex:479`. Those were already
wrong at merge (the guard is at 1702 and the thumb at 951).

### NITPICK — two vocabularies for the same three modes

- The selector says "Comfy list view" / "Compact list view".
- The admin tables' toggle in `components.ex` says "Comfortable view" /
  "Compact view".

### NITPICK — the comfy skeleton rows keep the compact height

The loading skeleton is `h-8` in both list modes.

## Checked and sound

- **No leak from admin pages:** the `[.pk-comfy_&]` hooks match any ancestor,
  but core only puts `pk-comfy` on a `table_default` wrapper (server-side, or
  toggled on the table element by the ViewPref JS). A selector opened from an
  admin page in comfy mode therefore does not inherit it.
- **The view lists agree:** the modal's `set_view` guard,
  `ViewConfig.load_selector/1` and `Browse.resolve_view!/2` all accept
  "comfy". `save_selector/2` stores whatever passed the guard.
- **Tailwind:** `w-22` and `[.pk-comfy_&]:!py-1.5` are the exact classes the
  admin tables already ship, so a host's Tailwind build already emits them.
- **DOM ids:** `#{id}-levelnav-table` (the subcategory level) and `#{id}-table`
  (the items) stay distinct.
- **Gettext:**
  - Both new msgids are in `default.pot` and all five `.po` files, with et and
    ru translated and pinned.
  - "List view" is still used by `CatalogueBrowse`, so keeping it is right.
- **Rows and toolbar:** the column toggle shows in comfy, and row click, qty
  stepper and checkbox wiring are unchanged because both list modes render the
  same `item_row`.
