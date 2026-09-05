# PR #90: Selector popup sweep — Claude review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/90
**Author**: @mdon
**Reviewer**: Claude (Opus 5) — independent post-merge pass
**Date**: 2026-08-31
**Status**: reviewed after merge; the two findings below are fixed on `main`

A four-seat AI panel already reviewed this PR before push and recorded its
findings in [`PANEL_REVIEW.md`](PANEL_REVIEW.md). This pass is deliberately
*not* a re-run of it: I re-derived the diff from the merge commit, read every
changed file with its surrounding context, and cross-checked the claims that
the panel's own write-up makes against the code they point at. Two of them
don't hold. Everything else in that document I could verify, I did verify.

## BUG - HIGH: `order: :position` is not the admin's document order once a listing spans several categories

`Search.search_items/2` gained an `:order` opt so the popup's browse listings
could read "in the admin's document order". The implementation ordered by
`i.position, i.name, i.uuid`, and the comment justified it as "the admin's
exact chain … `apply_item_order/2`'s default".

That citation points at the wrong function. `apply_item_order/2` orders the
item list *inside one level*, where the category is already fixed. The admin's
**catalogue-wide** read is `Search.search_items_in_catalogue/3`, and it leads
with `asc_nulls_last: c.position` — the *category's* position — before
`i.position`. It has to: `i.position` is scoped per `(catalogue_uuid,
category_uuid)`, so across categories the per-category ordinals interleave —
every category's item #1, then every category's item #2, and so on.

`BrowseState.put_browse_order/3` requests `order: :position` for *any* blank
search inside a single catalogue, and several of those listings do span
categories:

- `CatalogueBrowse` — the public browse widget — calls `BrowseState.init/1`
  without `:drill`, so it gets the struct default `drill: :subtree`
  (`browse_state.ex:65`). Every level it lists, root and drilled alike, covers
  a subtree of categories.
- The selector popup's opt-in `root_switcher: true` root in Items mode.
- Any scope naming several categories.

Before this PR those listings were name-ordered — arbitrary, but coherent.
After it they were ordinal-interleaved, which reads as noise. The one existing
pin (`search_coverage_test.exs`, "browse fetches read position order") uses a
single category, where the two chains are indistinguishable, so nothing caught
it.

**Fixed** — `apply_search_order(query, :position)` now uses
`search_items_in_catalogue/3`'s chain verbatim (`c.position` nulls-last,
`i.position`, `i.name`, `i.uuid`). For a single-category or category-less
scope the leading key is constant or NULL, so that case is byte-identical to
before; only the cross-category case moves, and it moves onto the admin's
order. Pinned with a two-category catalogue plus a loose item, asserting the
result equals `search_items_in_catalogue/3`'s.

## IMPROVEMENT - MEDIUM: the read-only picked quantity never reached card view

The either-or rework (click flavour + a visible `:qty` + `inline_qty: false`)
replaces the stepper with a read-only amount, so a host that hands in a
preselection at qty 3 can still see the 3. That span was added to the table
row's `<:qty>` slot only. The card grid's `<:footer>` got the new
`select_floor` / `zero_deselects` attrs on its stepper and nothing else — so in
card view the same preselection shows a checkmark and no number, and one view
toggle silently drops information the other shows.

**Fixed** — the card footer carries the same read-only amount, under the same
`:qty in visible_columns and not stepper?/2 and selected` gate. Pinned in
`item_selector_modal_test.exs`.

## NITPICK: dead API left behind by the retired search-mode switcher

`CataloguesLive`'s private `table_toolbar/1` still declares a `<:mode>` slot
and a `show_table_tools` attr. Both existed for the `Catalogues | Items`
switcher this PR removed; neither of the two remaining call sites (lines 2897,
3444) passes either, so `show_table_tools` is now permanently `true` and
`<:mode>` renders nothing. Likewise `item_result_path/2`'s second argument is
`_query` at the definition and still threaded from every caller.

Not fixed: it is inert private surface, and deleting it is a churn-only diff
across a component this PR already rewrote heavily. Recorded so the next pass
through that file can clear it in passing.

## NITPICK: `Browse.smart_fee/1` doesn't check the catalogue kind

`default_value` / `default_unit` are documented on the schema as "smart-only
fallbacks" (`schemas/item.ex:6-7`), but nothing in the changeset forbids them
on an item in a `kind: "standard"` catalogue. `smart_fee/1` matches on the
fields alone, so such a row would now display its fee as its price.

Not fixed: the catalogue *is* preloaded (`Helpers.merge_preloads([:catalogue,
…])`), so the guard is cheap — but it would be a branch for a state the forms
don't produce, and the panel already narrowed this function's doc for a
neighbouring ambiguity. Flagged rather than guessed at.

## Verified, not defects

Spot-checks I ran against the panel's claims and my own suspicions, all of
which held:

- **`normalize_uuid/1` key consistency** across `roots_by_catalogue`,
  `uncategorized_by_catalogue`, `counts` and `browse.catalogue_uuid` — it
  returns a plain string on every path (`browse.ex:207-217`), so the
  multi-catalogue tree's four maps agree on their keys.
- **`category_tree_base/4`'s `to_string(category.catalogue_uuid)`** —
  `list_categories_metadata_for_catalogue/2` returns full `Category` structs,
  so the field exists and the multi-catalogue clause doesn't silently fall into
  its own rescue.
- **`inject_media_order/2` clobbering `data`** — it follows
  `inject_featured_image/2`'s existing shape exactly (both always write a
  `"data"` key through `ensure_data_map/1`), so it introduces no new
  wipe-the-metadata path.
- **`tiles_only_level?/1`'s empty ingest** — `BrowseState.ingest/4` with `[]`
  sets `exhausted?: true`, so the sentinel and the Load-more button both stay
  inert on a tiles-only level, and `browse.total` is rendered nowhere, so the
  synthetic `0` is not user-visible.
- **Gettext catalogues** — every new msgid (`Computed`, `Back`, `Browse`,
  `Clear`, `Drag to reorder`, the manual-sort hint) is present by hand in
  `default.pot` and all three `.po` files, per AGENTS.md's hand-maintained
  rule, and pinned in `test/gettext_test.exs`.
- **The manual-sort hint's two render sites** are mutually exclusive
  (`@child_categories == []` in the page header vs `!@controls_in_page_header`
  in the items section), so it can never appear twice.

## Gate

`mix format` → `mix precommit` (compile `--warnings-as-errors`,
`deps.unlock --check-unused`, `hex.audit`, `format --check-formatted`,
`credo --strict`, `dialyzer`) clean, and the full suite green.

## Related PRs

- Previous: [#89](../89-selector-admin-parity-and-memory)
- Concurrent: [#91](../91-item-picker-icons-alt-asset-only)
