# PR 74 follow-up — Attribute sets rework

Triaged 2026-08-29 as part of the four-repo quality sweep. Every finding in
the review was re-verified against current code.

## Fixed (pre-existing)

- ~~**BUG-HIGH:** a stale `mix.lock` made the merged code uncompilable against
  Hex — `FieldInput` was absent from `phoenix_kit_entities` 0.4.2.~~ Lock now
  at 0.4.6; the import survives at `web/item_form_live.ex:28`.
- ~~**BUG-MEDIUM:** attribute-set mutations never broadcast, so the UI went
  stale across sessions.~~ `:attribute_set` is a `PubSub.kind()`
  (`catalogue/pub_sub.ex:43`), broadcasting is centralised in `tap_log/5`
  (`catalogue/attribute_sets.ex:1706`) and `reorder_values` (`:615`), item-side
  broadcasts fire on attach/detach/reorder/selection (`:814,:891,:926,:1443`),
  and both consumers listen (`web/catalogues_live.ex:177`,
  `web/catalogue_detail_live.ex:382`).
- ~~**IMPROVEMENT-MEDIUM:** `update_set/3` could persist a
  `default_value_slug` with no matching value.~~ `validate_default_slug/2` is
  in the `with` chain (`catalogue/attribute_sets.ex:241`, helper at
  `:1645-1647`).
- ~~**IMPROVEMENT-MEDIUM:** 12 new error atoms had no `Errors.message/1`
  clause or test pin.~~ All 12 are in `error_atom()` (`errors.ex:66-77`) with
  clauses at `:203-278`.

## Skipped (with rationale)

- **NITPICK: the `reorder_values` LiveView handler swallowed write failures.**
  Moot — `web/attribute_set_form_live.ex` was deleted in `640bc8c` ("Turn the
  attributes subtab into a viewer — editing lives in entities"), so the
  handler no longer exists.
- **IMPROVEMENT-MEDIUM (informational): no multilang UI for set/value names.**
  Also moot for this repo: set editing moved to entities in the same commit,
  so the translations are that module's concern now.
- **PROCESS: unrelated triage docs were bundled into the PR.** No code impact.

## Open

None.

## Verification

| Step | Result |
|---|---|
| `mix test` | 2 doctests, 2049 tests, 0 failures |
| `mix precommit` | passes |
