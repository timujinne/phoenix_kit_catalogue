# PR #109: Stop the legacy migration resurrecting trashed values, and show set values in the Attributes column — Claude review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/109
**Author**: @timujinne
**Reviewer**: Claude (Opus 5) — post-merge pass
**Merge commit**: `9e5fc62`
**Date**: 2026-09-13
**Status**: reviewed; one MEDIUM correctness fix applied post-merge (an interaction with #108), one pre-existing bug recorded

## Scope

1. **No more resurrected values.** `auto_migrate_legacy/0` re-runs on boot
   and on every Attributes-tab mount for as long as the legacy group rows
   exist. Its value top-up decided existence through `list_values/2`, a
   display read that hides archived and trashed rows, so a value the user
   hid came back published on the next visit. Existence now reads the
   set's rows once per attribute in every status
   (`migrated_value_slugs/1`, `include_trashed: true`, no status
   exclusion).
2. **The Attributes list column.** `attribute_map` was built from the
   legacy `item_attribute_groups` table; it is now built from
   `resolve_attribute_sets/2` when the column is shown (selected labels,
   set name for "whole set applies", `; ` between sets) and from a
   one-query presence check (`attached_item_uuids/1`) when only the swatch
   needs it. Legacy groups are folded in for items without a set.
   Toggling the column rebuilds the map for rows on screen.

## Verification

- **The resurrection fix fires for the reported case.** `trash/2` sets
  `status: "trashed"`; `list_by_entities/2` with `include_trashed: true`
  and no `exclude_statuses` returns it, so its slug is in `known_slugs`
  and `create_value/3` is skipped. The fallback `list_by_entity/2` never
  excluded archived rows. Test re-runs the migration after trash + archive
  and asserts `values: 0` with statuses untouched.
- **Column refresh.** `live_update_detail_columns/3` only runs from event
  handlers after mount, so `socket.assigns.items` is always present when
  `refresh_attribute_map/1` reads it.
- **Entities off.** `resolve_for_items/2` and `attached_item_uuids/1` both
  degrade to empty; the legacy fold keeps the swatch working for a
  deployment that never enabled entities.

## Findings

### BUG - MEDIUM — the Attributes column dropped archived/trashed selections, and could flip the mode

`attribute_map_sets/1` looked selected slugs up in `set.values` only. After
#108, `:selected` deliberately keeps a value that was archived or trashed
after being picked — its label lives in `set.hidden_values`. So the column
silently dropped that label, and when every selected value was hidden it
fell back to the set's name, which is how the cell renders "whole set
applies": the item appeared to have no selection at all. The PR's test
pinned exactly that ("a selection whose values are all archived or trashed
shows the set's name (ghost rule)") — but a trashed value is not a ghost
under #108's rule; only a value deleted for good is.

**Fixed:** labels are looked up in `values ++ hidden_values` (the same pool
the product card, the Items popup and the item form use; `resolve_set`
already de-duplicates it). The test was split: a trashed + an archived
selected value keep their labels and the set name does not appear; a value
removed with `delete_attribute_set_value/2` still degrades to the set name.

### IMPROVEMENT - MEDIUM — `mix precommit` failed: dialyzer rejected `attached_item_uuids/1`'s spec

The function built its `MapSet.t()` result in three places (an empty-list
clause, a piped `MapSet.new/1`, and a `MapSet.new()` in the disabled
branch); dialyzer reported `contract_with_opaque` and the gate exited 2.
The PR verified with `format` + `credo` only, so this never surfaced.

**Fixed:** one `MapSet.new/1` over a list computed by a single `if`. Same
behaviour (empty list or entities off → empty set); `mix precommit` passes.

### BUG - MEDIUM (pre-existing) — `migrate_assignments/2` re-attaches a detached set

Same shape as the value bug, flagged by the PR itself as a follow-up: a
legacy `item_attribute_groups` row lives forever, and `attach_missing/3`
re-attached its migrated set on every Attributes-tab visit, so detaching
that set from the item form did not stick. The migration doctrine is
"top-up, not created-only" (a crash between creating a set and attaching
items must heal on the next run), so the fix needs persistent state.

**Fixed (follow-up commit, after 0.31.0):** no schema change and no write
to the read-only legacy table. Each migrated set stamps
`settings.catalogue.assignments_migrated_at` (the run's start) once every
attach for it succeeded; later runs attach a legacy assignment only when
the set has no marker or the assignment's `updated_at` is at or after it
(a group assigned while entities was off). A failed attach leaves the set
unmarked, so a partial run still heals. Marked re-runs also skip the
per-item attachment read. A set migrated before the marker existed gets
one more top-up pass on upgrade, then is marked. Pinned in
`test/catalogue/attribute_sets_test.exs` ("a migrated set detached from an
item is not re-attached on re-run").

### NITPICK — swatch presence differs slightly between the two branches

With the column hidden, presence comes from the join table, so an item
attached only to a broken-contract set shows the swatch; with the column
shown, `resolve_for_items/2` skips that set and the swatch disappears.
**Not changed:** rare (a tampered blueprint), and neither state is wrong
enough to warrant a second query.

### NITPICK — the swatch tooltip still says "Has attribute group"

Now means "has an attribute set". **Not changed:** a msgid change touches
every locale; worth folding into the next gettext pass.

## Gate

`mix format`, `mix precommit` and `mix test` — see the release commit.
