# PR #120: Fix the open items from the #108, #109, #113 and #118 follow-ups — Claude review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/120
**Reviewer**: Claude (Opus 5), release review. One agent read the diff, and
every finding was re-checked against HEAD before it was acted on.
**Date**: 2026-09-15
**Scope**: merge `a88fe6a` (commits `c651dcc`, `b6b3d82`), looking for what the
Codex and Zai reviews did not cover

## Findings

### IMPROVEMENT - MEDIUM — the supplier-fields guard still went missing when entities was off at boot

- **The gap:** `SupplierFields.startup/0` registered its delete guard only
  `if enabled?()`, and `enabled?/0` requires `PhoenixKitEntities.enabled?()`.
  `AttributeSets.register_deletion_guard/0` registers whenever `Managed` is
  loaded.
- **Symptom:** a host that booted with entities disabled and turned it on later
  had the attribute-set guard but not the `catalogue_supplier` one. Every
  delete of the supplier-fields blueprint failed closed with
  `:no_delete_guard` until a restart, which is the symptom #120 set out to fix.
- **Why no test caught it:** `delete_guards_test.exs` enables entities in its
  `setup`. The gap predates the PR.

### NITPICK — FOLLOW_UP says the root cause is fixed in entities

`FOLLOW_UP.md` says the race "is fixed in entities too
(BeamLabEU/phoenix_kit_entities#48)". No released entities carries that fix:
`register_delete_guard/2` in 0.4.14 (now locked here) is still a read-then-write
on one shared `:persistent_term` map. `DeleteGuards` is enough while the
catalogue is the only owner that registers guards. A second owner elsewhere
would bring the race back.

### NITPICK — the two registrations share one task without isolation

`DeleteGuards.register/0` does `:ok = AttributeSets.register_deletion_guard()`,
which has no rescue. If it raised, the supplier guard would never register.
Before the PR each guard had its own task. The risk is low: the call is a
`Code.ensure_loaded?/1` and a `:persistent_term` write, and the child is
`:temporary`, so the supervisor is not affected.

### NITPICK — the product card marked "(archived)" by key

`selected_values/1` in `product_card.ex` marked any value whose key appeared
among the hidden values. A legacy set can hold a live and a hidden value under
the same key; the new `value_slug` check only stops new duplicates. With both
selected, both chips read "Red (archived)".

### NITPICK — deleting an attribute that is in use says only "Failed to delete attribute."

`delete_attribute/2` returns `{:error, :in_use}` on a constraint error. The form
flashes the generic message, while the group delete in `catalogues_live.ex`
says why.

### NITPICK — the merged branch was not formatted

`catalogue.ex`'s `category_facts/2` clause came in with `b6b3d82` indented the
way the formatter does not want, so `mix precommit` fails its
`format --check-formatted` step on `main` as merged, although the follow-up
records it as clean. Fixed by `mix format` in the release commit.

## Checked and sound

- **`DeleteGuards` child spec:** a `:temporary` Task that runs once, does not
  block boot, and cannot restart-loop the host supervisor. `children/0` and its
  test agree.
- **`create_value/3` lock:**
  - `lock_set` takes `pg_advisory_xact_lock` inside the transaction, with the
    same key as attach and delete, and holds it until commit.
  - `value_slug` is read after the lock.
- **Item category check:**
  - Create with no category skips it, and so does clearing a category.
  - A `skip_derive` update that keeps the category but changes the catalogue
    now reads the category `FOR SHARE`.
  - The reuse clause matches only the category the derive step read.
- **`ancestors_first/1`:** runs under `lock_catalogues_of!`. It reads the
  parent links once, and the walk is bounded by `map_size(parents)`, so a cycle
  ends.
- **Root Deleted tab counts:** every card listed gets both count maps from
  `trash_unit_counts/5`.
- **`StaleEntryError` rescue:** it is raised inside the transaction, so the
  value deletes roll back.
- **Items modal "(archived)" marker:** display only, gated on `v.hidden?`, in
  the HEEx body.
