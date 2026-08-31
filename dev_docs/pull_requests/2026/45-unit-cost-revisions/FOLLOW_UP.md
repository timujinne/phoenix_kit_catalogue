# PR 45 follow-up — Unit cost revisions

Triaged 2026-08-29 as part of the four-repo quality sweep. Every finding in
the review was re-verified against current code.

## Fixed (pre-existing)

- ~~**BUG:** a currency-only revision silently no-oped.~~
  `catalogue/item_supplier_infos.ex:480-489` — `currency_unchanged` is ANDed
  into the no-op guard.

## Fixed since, elsewhere

- ~~**Not fixed at review time (needed a core migration):** concurrent
  revisions could leave two "current" rows for a non-primary pair.~~ Closed
  from both ends: core `V180` adds
  `phoenix_kit_cat_item_supplier_info_current_pair_uniq` (`v180.ex:206`), the
  schema registers the matching `unique_constraint`
  (`schemas/item_supplier_info.ex:87-90`), and `do_revise_unit_cost/3` now
  takes `FOR UPDATE` and re-checks `valid_to` inside the lock
  (`catalogue/item_supplier_infos.ex:504,523-529`).

## Open

- **NITPICK (still live): a redundant `unique_constraint/3`.**
  `catalogue/item_supplier_infos.ex:559-564` re-registers
  `…_primary_uniq` on the successor changeset, though
  `ItemSupplierInfo.changeset/2` already registers it
  (`schemas/item_supplier_info.ex:80-83`). Same duplication at `:408`
  (`promote_locked!/1`). Harmless — a duplicate registration just means the
  same constraint is matched twice — but it reads as if the base changeset
  does not cover it, which is the sort of thing that invites a wrong fix
  later.

## Verification

| Step | Result |
|---|---|
| `mix test` | 2 doctests, 2049 tests, 0 failures |
| `mix precommit` | passes |
