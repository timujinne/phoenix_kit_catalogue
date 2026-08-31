# PR 50 follow-up — PRO100 sync key

Triaged 2026-08-29 as part of the four-repo quality sweep. Every finding in
the review was re-verified against current code.

## Fixed (pre-existing)

- ~~**BUG - HIGH:** the force-create path was unreachable for prefixed rows and
  filed the rest under a category duplicating the catalogue.~~
  `import/pro100_plan.ex:87-89` (`category_from_group/2` returns nil when a
  real catalogue name was checked) with the guard at `:95-98`.
- ~~**BUG - HIGH:** the force-create LiveView tests asserted the pre-guard
  behaviour and could not fail.~~ `test/web/import_live_pro100_test.exs:290-292`
  plus a dedicated foreign-group test at `:397-406`.
- ~~**BUG - MEDIUM:** `Executor.execute/4`'s spec forbade the `nil` the PR
  existed to pass.~~ `import/executor.ex:60` — `pid() | nil`.
- ~~**BUG - MEDIUM:** two return types had drifted from what the functions
  return.~~ `import/pro100_template_plan.ex:55`,
  `import/pro100_template_loader.ex:48`.

## Open — the estimate-template layer, and what hangs off it

- **IMPROVEMENT - HIGH (still live): the estimate-template layer has no
  caller.** `Pro100Template{Parser,Plan,Loader}` are referenced only by each
  other and by their tests. No LiveView, controller or mix task reaches them,
  so the branch's gate has still never run against a real invocation. This is
  the root of the five below — none of them can be exercised, let alone
  regress visibly, until something calls this layer.
- **Loader mutations carry no `actor_uuid`** — `pro100_template_loader.ex:43`
  threads only `@muted [broadcast: false]`, so every row it writes is
  unattributed.
- **`{:ok, _} = Rules.put_catalogue_rules(…)`** at `:434` raises a `MatchError`
  on a legitimate error return.
- **`find_catalogue/2`'s by-guid branch has no `status != "deleted"` filter**
  (`:185-191`), while the by-name branch at `:196` does — so a deleted
  catalogue can be matched by guid.
- **PRO100-created items get no `:language`** — `web/import_live.ex:531-538`
  passes only `actor_uuid`.
- **`@vat_divisor` is hard-coded to 1.24** (`pro100_template_plan.ex:37`),
  i.e. Estonian VAT baked into a shared import path.
- **NITPICK:** `sync_skip_reason(%{reason: :unmatched, …})`
  (`web/import_live.ex:3021`) is dead — `classify_unmatched/3` only ever emits
  `:no_id`, `:no_name` or a create — and the moduledoc at
  `import/pro100_plan.ex:10` still omits the `:not_imported` skip kind it
  produces at `web/import_live.ex:547`.

## Verification

| Step | Result |
|---|---|
| `mix test` | 2 doctests, 2049 tests, 0 failures |
| `mix precommit` | passes |
