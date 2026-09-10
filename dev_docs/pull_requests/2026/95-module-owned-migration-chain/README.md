# PR #95: module-owned V1 migration chain (adoptive)

**Author**: @timujinne
**Reviewer**: Claude (Opus 5) — post-merge pass
**Status**: Merged
**Commit**: `55c0f8b` (merge `5de2587`)
**Date**: 2026-09-05

## Goal

Move ownership of the eighteen `phoenix_kit_cat_*` tables from core
`phoenix_kit`'s monolithic migration chain to this module, using the
decentralized-migrations protocol core's `mix phoenix_kit.update` discovers
via `c:PhoenixKit.Module.migration_module/0`. Same step `phoenix_kit_crm`
(ten tables) and `phoenix_kit_inbox`/`phoenix_kit_boards` took before it.

## What Was Changed

| File | Change |
|------|--------|
| `lib/phoenix_kit_catalogue/migrations.ex` | New. The V01 chain: `current_version/0`, `migrated_version/1`, `migrated_version_runtime/1`, `up/1`, `down/1`, plus `up_statements/1` / `down_statements/2` as the testable data form. |
| `lib/phoenix_kit_catalogue.ex` | Registers the chain: `migration_module/0` returns `PhoenixKitCatalogue.Migrations`. |
| `test/phoenix_kit_catalogue/migrations_test.exs` | New. Structural pins on the emitted SQL. |

## Implementation Details

V01 is **purely adoptive**. On every live install all eighteen tables already
exist (core V135/V149/V173/V177 create them; V146/V151/V178/V179/V180 reshape
them), so each `CREATE TABLE IF NOT EXISTS`, each guarded
`DO $$ … pg_constraint … $$` block and each `CREATE INDEX IF NOT EXISTS` is a
no-op and the only new object is the `pkc_schema:1` marker — a
`COMMENT ON TABLE` on `phoenix_kit_cat_catalogues`. On a hypothetical fresh
install whose core baseline no longer creates these tables, the same 96
statements build them, shape-identical to core's live schema and with core's
exact object names.

`down/1` only rewrites the marker. It never drops a table: most of the data is
core-created and none of it is this chain's to destroy.

Because V01 changes no shape, core's `ExpectedSchema` manifest — which still
audits these tables — stays accurate, and no core release is needed for it.
The first version that *does* change shape (V2+) must follow the
excluded-object protocol first.

## Testing

- [x] Unit tests added (structural pins + the manifest drift lock added post-merge)
- [x] Gate passes (`mix precommit`)
- [x] DDL executed against a real Postgres schema and diffed against the
      core-built schema — see `CLAUDE_REVIEW.md` for the method and results
- [x] Backward compatibility verified (replay is fully idempotent)

## Related

- Review: [`CLAUDE_REVIEW.md`](CLAUDE_REVIEW.md)
- Sibling precedent: `phoenix_kit_crm`'s `PhoenixKitCRM.Migrations`
- Core protocol: `PhoenixKit.Migrations.Modules`, `mix phoenix_kit.update`
