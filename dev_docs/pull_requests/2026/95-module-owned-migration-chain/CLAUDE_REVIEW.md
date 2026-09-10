# PR #95: module-owned V1 migration chain — Claude review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/95
**Author**: @timujinne
**Reviewer**: Claude (Opus 5) — post-merge pass
**Date**: 2026-09-05
**Status**: reviewed; one test added, two docs corrected, no DDL changed

## Verdict

The DDL is right. That is not a reading-based judgement: I executed all 96
statements against a real Postgres schema and diffed the result, object by
object, against the schema core's own chain built in the same database. **167
columns identical, 58 indexes identical, 160 constraints — 152 byte-identical
and the other 8 semantically identical.** A second replay over the populated
schema was a complete no-op, so the idempotency claim holds too. The three
foreign keys core's V179/V180 deliberately dropped are correctly *absent*, and
nothing required is missing.

So the findings are not about what the chain does. They are about the two
things that keep it right *later*: nothing pinned it against core's manifest,
and the two documents a maintainer would read before touching it both pointed
somewhere wrong.

---

## How the DDL was verified (method, so it can be repeated)

Worth recording, because "I read it and it looks right" is not a useful
review of 746 lines of DDL, and the repo's own suite cannot reach this.

1. `Migrations.up_statements("pkc_ddl_probe")` → 96 statements, written to a
   file.
2. A scratch schema seeded with only what the chain needs from outside it: a
   stub `phoenix_kit_files(uuid)` (three FKs target it), a stub
   `uuid_generate_v7()`, and `pg_trgm` in `public`.
3. `psql -v ON_ERROR_STOP=1 -f probe.sql` — applied clean, first try. This is
   the check no test in the repo performs: the DDL is **valid SQL**, the
   statement ordering satisfies every FK (PK guards run before FK guards), and
   nothing depends on a table declared later.
4. Replayed the same file over the now-populated schema: 18 `CREATE TABLE`
   skipped, 40 `CREATE INDEX` skipped, 37 `DO` blocks no-op, 1 `COMMENT`.
   Fully idempotent.
5. Diffed `pkc_ddl_probe` against `public` — the same database's cat tables as
   built by core's chain (`phoenix_kit` marker `181`) — on
   `information_schema.columns` + `pg_get_constraintdef` + `pg_indexes`.
6. Cross-checked the emitted object set against core's `ExpectedSchema`
   manifest (`objects("public")` filtered to `owner: :catalogue`): 275
   `:required` objects, all emitted; 3 `:legacy_optional`, none emitted.

Step 6 is now a test (below). Steps 1–5 need a database and are recorded here
rather than automated.

---

## IMPROVEMENT - HIGH: nothing pinned the chain to core's schema manifest

`test/phoenix_kit_catalogue/migrations_test.exs`

The seven tests the PR shipped are all *structural*: the chain is V1, the
marker lands on `phoenix_kit_cat_catalogues`, every table gets a
`CREATE TABLE`, indexes carry `IF NOT EXISTS`, constraints sit inside a
`DO $$` guard, `down` only rewrites the marker, parents precede children.
Good pins, and they hold. But every one of them would still pass if the
column list inside a `CREATE TABLE` were wrong, short, or stale.

That is the failure this chain is uniquely exposed to. V01's whole premise is
"identical to what core builds", and the moment core ships a V183 that adds a
column to an adopted table, this chain silently keeps building the older shape
on fresh installs — with the existing suite green. The drift is invisible
until someone installs fresh and an insert fails on an undefined column.

Core already publishes the authority: `PhoenixKit.Migrations.ExpectedSchema`
tags every tracked object with `owner: :catalogue`. So the two lists that must
stay in sync can simply be compared.

**Fixed** — added a `describe "core's ExpectedSchema manifest"` block with two
tests:

- *every required catalogue-owned object is emitted by `up_statements/1`* —
  resolves the manifest, filters to `owner: :catalogue` and
  `presence: :required` (275 objects: 18 tables, 167 columns, 40 indexes, 50
  constraints), and asserts each one appears in the emitted SQL, reporting the
  missing ids by name.
- *the constraints core's own chain dropped are NOT re-created* — the mirror
  assertion over the 3 `:legacy_optional` objects.

Resolved through `PhoenixKit.Migrations.ExpectedSchema.Resolver` rather than
the manifest module directly, because `mix.exs` floors core at `~> 2.8` and
the manifest only ships in later releases; `{:error, :not_generated}` is an
ordinary condition there, not a failure.

Both tests were mutation-checked: deleting
`items.manufacturer_name_snapshot` from the DDL fails the first, and adding
back `phoenix_kit_cat_items_manufacturer_uuid_fkey` fails the second.

---

## BUG - MEDIUM: the moduledoc names four of the nine core versions that shape these tables

`lib/phoenix_kit_catalogue/migrations.ex:12-18` (pre-fix)

The moduledoc presented V135/V149/V173/V177 as the authority for the adopted
shape. Those four only **create** the tables. Five more reshape them, and the
committed DDL correctly reflects all five:

| core version | what it does to the shape |
|---|---|
| V146 | `items.primary_supplier_uuid` + partial index + FK |
| V151 | `item_supplier_info.supplier_source`, `is_primary` + CHECK + primary-uniq |
| V178 | `manufacturers.crm_company_uuid` + both `crm_company_uuid` partial uniques |
| V179 | `items.manufacturer_source`, `manufacturer_name_snapshot` + CHECK; **DROPS** `phoenix_kit_cat_items_manufacturer_uuid_fkey` |
| V180 | `manufacturer_suppliers.manufacturer_source`, `supplier_source` + CHECKs + current-pair uniq; **DROPS** both `manufacturer_suppliers_*_uuid_fkey` |

Why this matters more than a normal doc slip: the moduledoc is the *audit
map*. It exists so the next person can re-derive the shape. Sent to V135
alone, they would find three foreign keys that V135 creates and this chain
does not, conclude the chain has a gap, and "fix" it — re-pinning every item's
manufacturer and both sides of the M:N graph back to a local row, which is
precisely the CRM federation V179/V180 performed. The omission converts a
correct decision into one that looks like a bug.

**Fixed** — the moduledoc now lists all nine versions with what each
contributes, and states explicitly why `foreign_keys/2` does not mirror V135
(the three are `:legacy_optional` in core's manifest) with a pointer to the
test that now pins it in both directions. The `# ── CREATE TABLE (core …)`
section comment was updated to match.

---

## BUG - MEDIUM: `AGENTS.md`'s hard boundary now says the opposite of the truth

`AGENTS.md:34` (pre-fix)

> **No DB migrations in this repo.** Every table is created by versioned
> migrations in core `phoenix_kit`. Adding a column means a core migration
> first, then schema + changeset here.

This sat under "Hard boundaries (deliberate — do not add)" — the section whose
whole purpose is to stop an agent from adding the thing it names. As of this
PR the repo owns a migration chain, and the instruction now actively
misdirects: the next agent asked to add a column would go write a core V183,
leaving this chain's fresh-install DDL stale — the exact drift the new test
exists to catch, introduced on purpose by following the docs.

`AGENTS.md` is loaded into context at the start of every session in this repo,
so a stale hard boundary is the most expensive kind of doc rot here.

**Fixed** — the bullet now states that the module owns
`PhoenixKitCatalogue.Migrations`, that V01 is adoptive and changes no shape,
that **a new column means a new chain version here (V2+), not a core
migration**, that a shape-changing version must clear the excluded-object
protocol because core's manifest still audits these tables, and that
statements stay idempotent and `down/1` never drops.

---

## BUG - MEDIUM (pre-existing): `version/0` shipped 0.26.0 reporting `0.25.0`

`lib/phoenix_kit_catalogue.ex:100` (pre-fix)

Not from this PR — found while cutting the release that carries it, and worth
recording because the mechanism will repeat.

`AGENTS.md` states the version lives in two places and both must be bumped:
`mix.exs`'s `@version` and `PhoenixKitCatalogue.version/0`. It also says
`test/phoenix_kit_catalogue_test.exs` pins them equal "so a missed bump fails
the test". At the 0.26.0 release only `mix.exs` was bumped, and **0.26.0 went
to Hex with `PhoenixKitCatalogue.version/0` returning `"0.25.0"`**.

The safety net did not fire because `mix precommit` — the gate `AGENTS.md`
tells you to run before every commit — is `compile --warnings-as-errors` +
`deps.unlock --check-unused` + `hex.audit` + `format` + `credo --strict` +
`dialyzer`. It does not run `mix test`. So the one assertion written to catch
this drift is not in the path anything actually runs before publishing.

It matters because `version/0` is the `PhoenixKit.Module` callback the host
reads: `mix phoenix_kit.status` and the admin module list would have shown
this module a minor version behind what was installed.

**Fixed** — both sources now read `0.27.0`, and the full suite (not just
`precommit`) was run before this release.

---

## NITPICK: eight CHECK constraints render differently from core's (equivalent)

Fresh installs built by this chain produce, for eight CHECKs:

```sql
CHECK (((status)::text = ANY (ARRAY[('active'::character varying)::text, …])))
```

where core's chain produces

```sql
CHECK (((status)::text = ANY ((ARRAY['active'::character varying, …])::text[])))
```

Same accepted value sets — the difference is only how Postgres renders the
constraint depending on how the literals were cast when it was written, and
the chain's form is what the `pg_dump` authority the author worked from
carried. The affected constraints are `attribute_groups_status_check`,
`attribute_values_status_check`, `attributes_kind_check`,
`attributes_status_check`, `item_supplier_info_supplier_source_check`,
`items_manufacturer_source_check`, and both
`manufacturer_suppliers_*_source_check`.

**Not changed.** Core's verifier probes constraints by name through
`pg_constraint` (`check: {:catalog, %{kind: :constraint}}`), never by
comparing definition text — the manifest's own header says structural
comparison, "never by raw text equality across PG majors". So nothing flags
it, and rewriting eight literals to chase a rendering artifact would add risk
for no behaviour. Recorded here so a future reader diffing the two schemas by
hand is not surprised by it.

---

## Checked and correct (no action)

Recording these so the next reviewer does not re-derive them:

- **`migrated_version/1`** looked like dead code — public, unused, untested,
  duplicating `migrated_version_runtime/1` with the migration-time `repo()`.
  It is not: `phoenix_kit_inbox` and `phoenix_kit_boards` both carry the same
  pair. It is protocol convention; leaving it.
- **The `ArgumentError` re-raise** in `migrated_version_runtime/1` is a real
  improvement over the CRM precedent's bare `rescue _ -> 0`, which would
  swallow a bad prefix into "not installed".
- **Protocol shape matches what core actually calls**:
  `PhoenixKit.Migrations.Modules` calls `migrated_version_runtime(prefix: …)`,
  and the migration `mix phoenix_kit.update` generates calls
  `up(prefix: …, version: …)` / `down(prefix: …, version: …)` — keyword lists,
  which `validated_prefix/1` and `down/1` both handle. `up/1` ignoring
  `:version` is correct while the chain is V1-only, and matches CRM.
- **`public.gin_trgm_ops` hardcoded** in the trgm index while everything else
  is prefix-qualified: this is verbatim what core's manifest carries.
- **`#{p}uuid_generate_v7()`** matches core's V135 qualification exactly.
- **Statement ordering**: tables → PKs → FKs → indexes → marker. FK guards
  need their target's PK to exist; PKs are added first. Confirmed against a
  real fresh schema.
- **Every statement is a single command**, so Ecto's extended protocol (which
  rejects multi-statement strings) is satisfied — including the 37 `DO $$`
  blocks.
- **The `pkc_schema:` marker** cannot collide with core's own version marker,
  which lives on the `phoenix_kit` table.

## Related

- Summary: [`README.md`](README.md)
