# Review — PR #50: PRO100 force-create, code+name matching, and the estimate-template layer

Merged as `7f731df` (`c30d351` + `97031c5` + `fe5506a`, author @timujinne).
Reviewed against the Phoenix and Ecto thinking skills, with every claim checked
against the producing code — `Import.Executor`, `Import.Pro100Parser`,
`Schemas.Item`, `Catalogue.Rules` — rather than against the commit messages.

**Overall: the matching work is the strong part of this PR and it is right.**
The lossy-code problem is real, the two-stage `{digits, name}` → `digits`
resolution is the correct shape for it, and the decision to place the
foreign-group guard *before* `Matcher.resolve/3` is well argued and pinned by a
synthetic test that no real export would produce. `Matcher.normalize_name/1`
being one public function used on both sides of the index is exactly the
discipline that keeps this kind of matcher from rotting.

The problems are all at the seams. This PR is two branches
(`feature/pro100-force-create`, then `feature/pro100-sync-key`) merged without
re-reading the first through the second, plus a third feature that arrived with
no caller. The result: force-create is dead for every prefixed row, the tests
that would have caught that assert the *old* behaviour and never run without a
database, and `mix precommit` — which AGENTS.md requires before every commit —
fails on merged `main` in three separate ways.

Five findings. Four fixed, one partially. Nothing here is a security issue; #1
is a data-shape issue that would have shown up in the operator's catalogue tree
on the first sync.

---

## 1. BUG - HIGH — the force-create path is unreachable for prefixed rows, and files the rest under a category duplicating the catalogue — fixed

`Pro100Plan.classify/3` splits the row name into `{group, name}`, refuses the
row when the group differs from the selected catalogue's name, and otherwise
passes the **group** through to `classify_unmatched/3` as the category to
create.

Read the guard and that hand-off together:

```elixir
defp foreign_group?(nil, _catalogue_name), do: false
defp foreign_group?(_group, nil), do: false
defp foreign_group?(group, catalogue_name),
  do: String.trim(group) != String.trim(catalogue_name)
```

With a real catalogue name — which `ImportLive` always supplies, via
`socket.assigns.selected_catalogue.name` — a non-nil group only survives the
guard when it *is* the catalogue name. So the group half carries no information
at that point, and the two possible outcomes were:

- group ≠ catalogue name → `:foreign_group`, never a create. The 40 % of the
  force-create feature that the PR's own tests exercise is unreachable.
- group = catalogue name → a category named exactly like the catalogue, holding
  every created row, while the unprefixed rows of the same export land at the
  catalogue root. Two placements for one file.

Confirmed against the merged code before fixing, using the fixture from the
PR's own LiveView test:

```
catalogue "PRO100 Test Cat", row "Acme Carcass / MP U741 ST9 16mm"
  creates: []   skipped: [%{reason: :foreign_group, group: "Acme Carcass"}]

catalogue "Acme Carcass", row "Acme Carcass / MP U741 ST9 16mm"
  creates: [{"MP U741 ST9 16mm", category: "Acme Carcass"}]
```

**Fixed** by `category_from_group/2`: a group that was checked against a real
catalogue name yields no category, so a created row lands at the catalogue root
exactly like an unprefixed one. The prefix is still stripped from the item name
— that part was always correct. A group is still turned into a category when
there was no catalogue name to check against, because `analyze/4`'s contract
explicitly lets a caller opt out of the group guard and for that caller the
prefix is the only structure the file has.

The deliberate consequence: `to_executor_plan/1` now returns
`categories_to_create: []` for every UI-driven sync. That removes, rather than
manages, the `_category_name`-must-appear-in-`categories_to_create` drift hazard
the author documented on that function — the executor drops an unlisted category
name silently, leaving items uncategorised with no diagnostic, and the safest
way to not hit that is to have no names.

What is *not* fixed, and is worth knowing before the next export: if PRO100 ever
emits a genuine sub-group (`Group / Sub / Item`), `split_name/1`'s `parts: 2`
puts `Sub / Item` in the name and nothing becomes a category. Nested grouping
needs a different split and a different guard, not a tweak to this one.

Pinned by `pro100_plan_test.exs` — "a group matching the selected catalogue
yields no category", which also asserts `categories_to_create == []`.

## 2. BUG - HIGH — the LiveView tests for force-create assert the pre-guard behaviour and cannot fail — fixed

The three tests in `import_live_pro100_test.exs`'s "force-creating unmatched
rows" block were written on `feature/pro100-force-create`, before the
foreign-group guard existed. They upload a row named
`"Acme Carcass / MP U741 ST9 16mm"` into a fixture catalogue named
`"PRO100 Test Cat"` and assert:

```elixir
assert [create] = assigns.import_plan.creates
assert create.category == "Acme Carcass"
...
refute is_nil(created.category_uuid)
```

Against the merged code that row is `:foreign_group` and `creates` is `[]`. All
three tests fail — and none of them ran: they are `LiveCase` integration tests,
auto-excluded without a database (`802 excluded` on this machine), and the
branch's gate was never run either (finding #5). A guard shipped with tests that
contradict it and a suite that reports green is the worst of both.

**Fixed:** the shared helper now prefixes with the fixture catalogue's own name,
so the tests exercise "prefix stripped, no category created" — the behaviour
after #1. Added a fourth test that uploads a genuinely foreign group and asserts
it reaches neither `:creates` nor the database, so the guard has LiveView-level
coverage and not just plan-level coverage.

These four tests still cannot run here (no PostgreSQL in this environment).
They were derived by executing the plan layer directly against the same inputs,
so the assertions match observed behaviour rather than assumed behaviour — but
they have not been executed end-to-end. **Run `mix test --include integration`
against a database before relying on them.**

## 3. BUG - MEDIUM — `Executor.execute/4`'s spec still forbids the `nil` the PR exists to pass — fixed

`fe5506a` taught `execute/4` to accept `notify_pid: nil` (`maybe_notify/2`) and
documented why at length in the moduledoc — `ImportLive` applies its plan
synchronously and a delivered `{:import_result, _}` would flip the operator onto
the universal import's `:done` screen. The `@spec` was left at `pid()`.

Dialyzer rejects the call outright:

```
lib/phoenix_kit_catalogue/web/import_live.ex:520:16:call
The function call will not succeed.
  PhoenixKitCatalogue.Import.Executor.execute(..., nil, ...)
breaks the contract (map(), String.t(), pid(), :elixir.keyword()) :: import_result()

lib/phoenix_kit_catalogue/web/import_live.ex:534:8:unused_fun
Function create_errors_to_skips/2 will never be called.
```

The second error is the first one's shadow: with the call declared impossible,
everything downstream of its result is unreachable, so the error-reporting
helper for created rows looks like dead code. **Fixed** — `pid() | nil`.

## 4. BUG - MEDIUM — two return types drifted from what the functions return — fixed

`Pro100TemplatePlan.build/2` puts `:problems` in its result map;
`@type t()` never listed it, and a closed map type means dialyzer flags the
mismatch:

```
lib/phoenix_kit_catalogue/import/pro100_template_plan.ex:72:invalid_contract
The @spec for the function does not match the success typing of the function.
```

Same class of drift in `Pro100TemplateLoader`: `run/2` returns a `:rules` key
that `@type report()` omits. Not flagged (the transaction wrapper erases it),
but wrong in the same way and misleading to the next reader. **Fixed** — both
types now list the key.

## 5. IMPROVEMENT - HIGH — the estimate-template layer has no caller, and the branch's gate was never run — partially addressed

`fe5506a` adds 913 lines across `Pro100TemplateParser`, `Pro100TemplatePlan` and
`Pro100TemplateLoader`, plus a new direct dependency on `saxy`. Nothing calls
any of it — no LiveView, no mix task, no test:

```
$ rg -l "Pro100Template" --glob '!deps'
lib/phoenix_kit_catalogue/import/pro100_template_loader.ex
lib/phoenix_kit_catalogue/import/pro100_template_parser.ex
lib/phoenix_kit_catalogue/import/pro100_template_plan.ex
```

Three modules that only reference each other. The code is unusually well
reasoned — the moduledocs record measurements against the real export (708 rows
across 10 tables; `//TableItem` yields 1876 because 584 rows are serialised
twice more under `SumTables`; `TableId` is `0` on 707 of 708 rows) and each
judgement is defended. That is exactly why it should not sit unreachable: those
measurements are the value, and an unreferenced module is the one that silently
drifts from the file it was measured against.

The same commit also shows the branch's gate was never run. On merged `main`,
`mix precommit` failed three ways, all inside this layer: two files unformatted,
three credo `--strict` nesting violations, and the dialyzer contract errors in
#3 and #4. AGENTS.md: *"`mix precommit` — run before every commit."*

**Addressed, partially:**

- Gate is green — `mix format` applied, the three deep-nesting sites extracted
  into named private functions (`run_or_rollback/1`, `resolve_item_by_name/2`,
  `walk_line/2`), types fixed per #4.
- `test/phoenix_kit_catalogue/import/pro100_template_test.exs` — 22 tests
  covering the pure half against a fixture shaped like the real export: the
  `SumTables` snapshot rows are not read as products, trailing-colon rows become
  sections, a zero-price dash row is a sub-heading while a priced one is a
  product, gross→net conversion, price recovery from the name, the computed row
  splitting off into its own smart catalogue with a percent rule, catalogue
  ordering, and `problems/1`. All pass, which independently confirms the layer
  behaves as its moduledocs claim.

**Not addressed, deliberately:** `Pro100TemplateLoader` remains untested — it is
pure database work and there is no PostgreSQL here, so any test written for it
would be as unrunnable as the ones in #2. And it stays unwired: choosing where
this belongs (a mix task? a fourth `Import.Source`? an admin screen?) is a
product decision, not a review fix. Left as-is with the limitation recorded.

---

## Notes, not fixed

- **`Pro100TemplateLoader` mutations carry no `actor_uuid`.** Every
  `Catalogue.create_*` / `update_item` call in the loader passes no activity
  opts, so a template load would land in the activity log with no actor —
  against the convention AGENTS.md states for every mutating context function.
  Wire an `actor_uuid:` opt through `apply_plan/2` when the layer gets a caller.
- **`{:ok, _} = Rules.put_catalogue_rules(item, payload)`** (loader,
  `apply_rules/3`) raises `MatchError` on `{:error, {:duplicate_referenced_catalogue, uuid}}`,
  which is a legitimate return for a plan whose file has two rules pointing at
  the same table. The module's own contract is "report, don't crash"
  (`:reported` + rollback); this one call site opts out of it.
- **`find_catalogue/2`'s by-guid branch has no `status != "deleted"` filter**,
  unlike the by-name branch beside it. A soft-deleted catalogue with a matching
  guid is reused, and stays deleted while items are written into it.
- **Created items get no `:language`.** `apply_pro100_creates/2` passes only
  `actor_uuid` to `Executor.execute/4`, so `apply_language/2` is a no-op and the
  new item has a bare `name` with no `_primary_language` and no per-language
  `_name` — unlike everything the universal importer creates. Fine while the
  catalogue is monolingual; worth a language selector on the sync screen if
  PRO100 catalogues ever get translated.
- **`@vat_divisor` is hard-coded at 1.24** in `Pro100TemplatePlan`. The
  moduledoc names the rate and the date it was valid, which is the right way to
  carry a constant like this, but it will need touching rather than configuring.

## Nitpicks

- `sync_skip_reason(%{reason: :unmatched, row: row})` in `ImportLive` is now
  dead — `Pro100Plan` classifies every unmatched row as `:no_id`, `:no_name`,
  `:foreign_group`, or a create. Its gettext string is still in the `.pot` and
  in three `.po` files, so translators keep paying for a message that cannot
  render.
- `Pro100Plan`'s moduledoc lists `:skipped` as "ambiguous matches, rows
  belonging to another group, and unmatched rows that cannot be created" — the
  `:not_imported` entries `ImportLive` appends when the operator leaves the box
  unchecked are a fourth kind, produced outside the plan.
