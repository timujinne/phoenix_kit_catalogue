# Review: PR #32 — AI translation (shared-glue adoption) + detail-filter/reorder UX + quality

Reviewed 2026-06-04 (post-merge, against `main`). Reviewed through the Elixir
`ecto`/`phoenix`/`elixir` thinking skills.

## Scope

Brings the catalogue onto core's shared AI-translation pipeline (adapter +
form glue), two catalogue-detail UX fixes (status-filter scope, reorder
no-op handling), and a quality pass (PR #31 follow-up, redundant import drop,
adapter unit tests).

## Verdict

Solid, well-commented PR. The risky parts (multilang `data` merge semantics,
concurrent per-language writes, broadcast suppression) are handled correctly
and the design respects the relevant skill "iron laws". Findings below are
small. Most are applied in this pass (dead-code cleanup, `column_value/2`
de-exception-ing, expanded adapter tests, and two `credo --strict` /
`mix precommit` fixes); one (per-LiveView wiring duplication) is deferred by
recommendation.

---

## Verified correct (the parts most likely to harbor bugs)

- **No DB query in `mount/3`.** The three form LiveViews call
  `assign_ai_translation/3` in `mount`, but core's `FormGlue` gates every DB
  lookup (`list_endpoints/0`, `list_prompts/0`, `subscribe/2`,
  `default_*`) on `Phoenix.LiveView.connected?/1`
  (`deps/phoenix_kit/.../form_glue.ex:79,124`). So the mount-twice double-query
  trap is avoided. ✅
- **`broadcast: false` actually takes effect.** `update_*/3` forward `opts` into
  `log_activity/2`, which checks `Keyword.get(opts, :broadcast, true)` before
  calling `broadcast_for/2` (`catalogue.ex:90–96`). The suppression the
  AI-write path relies on is real, and normal admin edits still broadcast. ✅
- **Concurrent per-language jobs serialize correctly.** `put_translation/4`
  re-reads the row `FOR UPDATE` inside the txn and merges against the freshly
  committed `data`, so parallel `enqueue_all_missing` jobs can't drop each
  other's languages (`ai_translatable.ex:95–113`). ✅
- **`force_put_language/3` merges rather than replaces** the lang subtree, and
  force-stores values equal to the primary so untranslatable strings don't
  read as "translation failed". Covered by tests. ✅

---

## Findings

### 1. [APPLIED] Dead `_ = primary` discard in `force_put_language/3`

`ai_translatable.ex` had an explicit `_ = primary` plus a comment claiming
`primary` "is bound only to seed the marker above." That's misleading —
`primary` is genuinely used in the `base` else-branch
(`%{"_primary_language" => primary, primary => existing_data}`), so the discard
suppressed nothing. Removed the line and trimmed the comment. Recompiles clean
with `--warnings-as-errors`.

### 2. [APPLIED] Adapter test coverage gaps

`test/phoenix_kit_catalogue/ai_translatable_test.exs` (10 tests) covered the
`item` resource type well but left gaps that are now filled (15 tests):

- `source_fields/2` only exercised the **column-fallback** path. Added two
  tests for the more interesting branches of `field_value/3`
  (`ai_translatable.ex:64–70`): the `_`-prefixed multilang override winning
  over the column, and the legacy plain-key fallback.
- `fetch/2` and `put_translation/4` were only tested for `"catalogue_item"`.
  Added `fetch` coverage for `"catalogue"` and `"catalogue_category"`, plus
  `put_translation` round-trips for both — exercising the `persist_target/1`
  schema/updater mappings (a wrong pairing would now fail a test).

**Caveat:** the suite needs a live Postgres that isn't available in this
environment, so these new tests are **format-checked and syntax-valid but not
executed here**. They mirror the existing passing patterns and the
`%Item{}`-struct `source_fields` tests are pure (no DB). Run `mix test
test/phoenix_kit_catalogue/ai_translatable_test.exs` against a local
core/DB to confirm green before relying on them.

### 3. [LOW / optional] Duplicated AI-translate wiring across 3 LiveViews

`catalogue_form_live.ex`, `category_form_live.ex`, and `item_form_live.ex` each
repeat byte-for-byte:

- the `import PhoenixKitCatalogue.Web.Helpers, only: [...]` block (10 names)
- the `import PhoenixKitWeb.Components.AITranslate, only: [...]` block
- six `handle_event/3` clauses (`ai_toggle_modal`, `ai_select_endpoint`,
  `ai_select_prompt`, `ai_select_scope`, `ai_generate_prompt`,
  `ai_translate_lang`)
- one `handle_info({:ai_translation, …})` clause
- the button/progress/hint markup block (differs only by a margin class)

A `__using__` macro (e.g. `PhoenixKitCatalogue.Web.AITranslateForm`) could fold
the imports + event/info clauses into one `use`. **Tradeoff:** injecting
`handle_event`/`handle_info` clauses via macro tends to trigger the "clauses of
the same name/arity should be grouped together" compiler warning (each host LV
defines its own `handle_event`s elsewhere), and macros hide the wiring. The
current explicit delegation is verbose but greppable and warning-free. Net
recommendation: **leave as-is** unless a 4th consumer appears; revisit then
with a `@before_compile`-based injection that keeps clauses grouped.

### 5. [APPLIED] `mix precommit` (`credo --strict`) failures

The PR notes claimed `credo --strict` clean, but this repo's `mix precommit`
(`compile --warnings-as-errors`, `deps.unlock --check-unused`,
`format --check-formatted`, `credo --strict`, `dialyzer`) reported two
strict-mode issues in the new code — likely the PR author ran credo against
the integration app's looser config. Both fixed:

- **[F] nesting too deep** (`ai_translatable.ex` `put_translation/4`) — the
  `transaction → case → case` block hit depth 3 (max 2). Extracted the inner
  merge-and-persist branch into a private `merge_translation!/6`, so the
  transaction body is a flat `case` and the helper holds the update `case`.
- **[D] nested module not aliased** (`ai_translate_binding.ex`
  `actor_uuid/1`) — the fully-qualified
  `PhoenixKitCatalogue.Web.Helpers.actor_uuid/1` call now goes through an
  `alias … Web.Helpers` (`Helpers.actor_uuid/1`).

After the fixes `mix precommit` exits 0 (credo: "no issues"; dialyzer:
"passed successfully").

### 4. [APPLIED] `column_value/2` `String.to_existing_atom` + rescue

For the fixed field set, the runtime `String.to_existing_atom/1` +
`rescue ArgumentError` was an unnecessary use of exceptions for what is a
static mapping. Replaced with a compile-time `@field_columns` map
(`%{"name" => :name, "description" => :description}`), and derived
`@translatable_fields` from its keys so the two can't drift. `column_value/2`
is now a total `Map.fetch!/2` lookup with no `rescue`.

---

## Quality gates

- `mix precommit` — **passes** (exit 0): `compile --warnings-as-errors`,
  `deps.unlock --check-unused`, `format --check-formatted`, `credo --strict`
  ("no issues"), `dialyzer` ("passed successfully"). Core release with
  BeamLabEU/phoenix_kit#582 present.
- Test suite (ExUnit) not runnable in this environment (no local Postgres /
  `psql`); the new adapter tests are format-/syntax-verified only. PR notes
  report the original 10 adapter tests green against a local core.

## Applied in this pass

| File | Change |
|------|--------|
| `lib/phoenix_kit_catalogue/ai_translatable.ex` | Drop dead `_ = primary` discard + correct comment in `force_put_language/3` (Finding 1) |
| `lib/phoenix_kit_catalogue/ai_translatable.ex` | Replace `String.to_existing_atom` + `rescue` in `column_value/2` with a compile-time `@field_columns` map; derive `@translatable_fields` from it (Finding 4) |
| `test/phoenix_kit_catalogue/ai_translatable_test.exs` | Add `source_fields` override + legacy-key tests, and `fetch`/`put_translation` coverage for `catalogue` + `category` (Finding 2) — 10 → 15 tests |
| `lib/phoenix_kit_catalogue/ai_translatable.ex` | Extract `merge_translation!/6` to flatten `put_translation/4` nesting (Finding 5) |
| `lib/phoenix_kit_catalogue/ai_translate_binding.ex` | Alias `Web.Helpers` instead of a fully-qualified call in `actor_uuid/1` (Finding 5) |

Full `mix precommit` (`compile --warnings-as-errors`,
`deps.unlock --check-unused`, `format --check-formatted`, `credo --strict`,
`dialyzer`) passes — exit 0, credo "no issues", dialyzer "passed successfully".

## Open / recommended (not applied)

- **Run the expanded test suite against a DB** (Finding 2) — added tests are
  syntax-/format-verified but not executed in this environment.
- **Optional macro de-duplication of the per-LiveView AI wiring** (Finding 3)
  — deferred by recommendation; revisit only if a 4th consumer appears, using
  a `@before_compile` injection that keeps `handle_event`/`handle_info` clauses
  grouped (else `--warnings-as-errors` builds break on the "clauses should be
  grouped" warning).
