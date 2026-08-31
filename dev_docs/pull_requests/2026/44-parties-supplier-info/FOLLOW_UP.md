# PR 44 follow-up — Supplier info and CRM parties

Triaged 2026-08-29 as part of the four-repo quality sweep. Every finding in
the review was re-verified against current code.

## Fixed (pre-existing)

- ~~**HIGH:** `list_crm_suppliers/0` called a `PartyRoles.list_suppliers/0`
  that does not exist.~~ `catalogue/suppliers.ex:453` / `:476` use
  `list_companies_with_role` / `list_contacts_with_role`.
- ~~**MEDIUM:** CRM contacts were always mislabelled `:crm_company`.~~ Tagged
  at the call site — `:crm_company` at `:463`, `:crm_contact` at `:488`.
- ~~**MEDIUM:** supplier-info mutations did not thread `actor_opts(socket)`.~~
  `web/item_form_live.ex:716` (set primary), `:792` (delete), `:1373` (create).
- ~~**MEDIUM:** the new context functions bypassed the `Catalogue` facade.~~
  All nine delegates present (`catalogue.ex:323,326,373-385`).
- ~~**LOW:** `PubSub.kind()` was missing `:item_supplier_info`.~~
  `catalogue/pub_sub.ex:41`.

## Fixed since, elsewhere

- ~~**CRITICAL (cross-repo, could not be fixed here):** the
  `phoenix_kit_cat_item_supplier_info` table lacked `supplier_source`,
  `is_primary` and the primary index.~~ Core `V151` ships exactly those
  (`v151.ex:58,82,86`) and the dep is at `phoenix_kit 2.13.11`.

## Open

- **An orphaned column: `Item.primary_supplier_uuid`.** Added by core V146
  (`v146.ex:37-51`, with its FK) and referenced **nowhere** in `lib/`. It was
  superseded by the `is_primary` flag on the supplier-info row. Dropping it
  needs a core migration, so it is core's to retire — worth raising there
  rather than leaving as a column that looks meaningful.
- **`create/2`'s auto-promote-to-primary is a post-commit step, not part of
  the insert transaction.** `catalogue/item_supplier_infos.ex:210-219`:
  `primary_for_item/1` runs after the insert has committed, so a failing
  `set_primary/2` returns `{:error, _}` for a row that **was** inserted — the
  caller sees a failure and the record exists. The pair-duplication half of
  the original finding is now DB-enforced (`already_linked_violation?/1`,
  `:169-174`); this half is not.

## Verification

| Step | Result |
|---|---|
| `mix test` | 2 doctests, 2049 tests, 0 failures |
| `mix precommit` | passes |
