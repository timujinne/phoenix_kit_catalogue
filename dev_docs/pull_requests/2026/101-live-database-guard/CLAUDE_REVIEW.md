# PR #101: Refuse to run the test suite against a known live database

**Author**: @timujinne
**Reviewer**: Claude (`elixir:ecto-thinking` applied before reading source)
**Status**: Merged (`93a2ddd`)
**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/101
**Date reviewed**: 2026-09-08

## What changed

Test-only, no `lib/` changes. Adds
`PhoenixKitCatalogue.Test.LiveDatabaseGuard.check!/1`, called from
`test_helper.exs` immediately after the database name is resolved and before
anything touches Postgres. It raises `LiveDatabaseError` if the resolved name
exactly matches one of three hardcoded live database names
(`phoenix_kit_dev`, `decor_3d_print_dev`, `phoenixkit_hello_world_dev`) this
maintainer's container's shell environment is known to leak `PGDATABASE` for.
Ported from the same pattern already in `phoenix_kit_crm` /
`phoenix_kit_warehouse`. Two test files: a pure unit suite
(`live_database_guard_test.exs`) and a wiring suite
(`live_database_guard_wiring_test.exs`) that runs `test_helper.exs` for real
as a `mix test` subprocess with `PGHOST` pointed at an unreachable loopback
address, so it proves the guard is actually reachable from the real boot
sequence rather than only correct in isolation.

## Verified

- Exact-match only, not substring — `check!/1` uses `database in
  @known_live_databases`, and the "looks like it" test cases
  (`not_phoenix_kit_dev_but_looks_like_it`, `phoenix_kit_dev_backup`) confirm
  a scratch DB deliberately named near a live one is not refused.
- The guard call in `test_helper.exs` sits before the `psql -lqt` probe and
  before `Repo.start_link/0` — genuinely fires before any connection attempt,
  matching the PR's "before" claim.
- `Code.require_file` ordering in `test_helper.exs`: `live_database_guard.ex`
  is loaded before `check!/1` is called two lines later — no load-order bug.
- The wiring test's safety argument holds up: `PGHOST=127.0.0.1`,
  `PGPORT=1` on a container where nothing listens on port 1 makes any actual
  connection attempt fail fast (`ECONNREFUSED`) rather than reach a real
  server — even a cut wiring call can't accidentally touch the named live
  databases through this subprocess.
- The "isolated DB is not refused" wiring test inherits the parent process's
  ambient `PGDATABASE`/host/user/password rather than hardcoding a
  password — reasoning given (this process is itself already a working `mix
  test` run) is sound and avoids committing a credential.
- Full gate: `mix compile --warnings-as-errors`, `mix format
  --check-formatted`, `mix credo --strict`, `mix dialyzer` all clean; `mix
  test` — 2431 tests, 0 failures, including the new guard/wiring tests.

## Not a finding, noted for the record

The three hardcoded database names are specific to this maintainer's
container and other sibling apps (`decor_3d_print_dev`,
`phoenixkit_hello_world_dev`) rather than anything generic to
`phoenix_kit_catalogue`. That's a deliberate, already-explained tradeoff (the
moduledoc: `pk-test` is the generic wrapper that lives *outside* the repo on
purpose; this guard is the same refusal duplicated *inside* it so a bare `mix
test` is safe "regardless of how it's invoked") and matches the pattern
already shipped in `phoenix_kit_crm` / `phoenix_kit_warehouse`. Not asking for
a change — just recording that a name-list guard is inherently
environment-specific and a new container/maintainer would need its own names
added, the same as the sibling repos.

## Verdict

Clean. No bugs found, nothing changed.
