# PR 75 follow-up — CRM party integration

Triaged 2026-08-29 as part of the four-repo quality sweep. Every finding in
the review was re-verified against current code.

## Fixed (pre-existing)

- ~~**BUG-HIGH:** unguarded CRM soft-dependency calls could crash the item
  listing pages when the CRM module was absent.~~ Every call site now carries
  both `rescue` and `catch` — `catalogue/manufacturers.ex:290,292 / 344,346 /
  358,360` and `catalogue/suppliers.ex:323,325 / 433,435 / 469,471 / 494,496`.
  (Worth noting: this module got the `catch` right, which is exactly what
  `phoenix_kit_comments` and several `phoenix_kit_entities` guards were
  missing — an unreachable DB raises on an unowned checkout but *exits* on a
  dead pool.)
- ~~**IMPROVEMENT-MEDIUM:** `:already_linked` had no `Errors.message/1`
  clause.~~ `errors.ex:78` (type) and `:229` (clause).
- ~~**BUG-HIGH:** the test router still routed to a deleted
  `ManufacturerFormLive` and to removed `CataloguesLive` actions.~~ Zero
  matches for `ManufacturerFormLive`, `SupplierFormLive`, `:manufacturers` or
  `:suppliers` in `test/support/test_router.ex`.
- ~~**NITPICK:** two dead empty `describe` blocks.~~ Gone; the file now has
  four non-empty describes.

## Open

- **IMPROVEMENT-MEDIUM (still live): `SupplierFields.add_field/2` has a
  non-atomic duplicate-key race.** `catalogue/supplier_fields.ex:303-322` does
  `ensure_blueprint` → `validate_unique_key` → write with no transaction and
  no advisory lock, so two concurrent adds of the same key both pass
  validation. Still gated off in the UI
  (`web/item_form_live.ex:76` `@supplier_custom_fields false`, `:89`
  `@supplier_terms_fields false`), so the impact stays theoretical until that
  flag flips — which is the right moment to fix it, in one transaction with a
  unique index behind it.

## Verification

| Step | Result |
|---|---|
| `mix test` | 2 doctests, 2049 tests, 0 failures |
| `mix precommit` | passes |
