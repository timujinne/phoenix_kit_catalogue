# PR #152 — Add the shop API tools and the context features behind them

- **Reviewer:** Claude
- **Date:** 2026-10-18
- **Author:** timujinne (merged by Dmitri Don)
- **Scope:** nine `catalogue.*` tools (`API.*`, `api_tools/0`), migration V5
  (`external_id` unique indexes), `Catalogue.update_items/2`,
  `:data_owned_paths` / `:slug_owned_langs` on `update_item/3`,
  `RefLookup`, keyset paging, trash/restore `external_id` guard,
  `ActivityLog.log_many/1`; 91 files, ~5k lines of source.

Read in full: `api.ex`, `Common`, `CatalogueScope`, `Refs`, `RefLookup`,
`CreateProducts`, `UpdateProducts`, `DeleteProducts`, `DeleteCategories`,
`UpsertCategories`, `SetTranslations`, `Presenter`, `ListProducts`, `Gate`, the
`Items` / `Shared` / `ActivityLog` / `Trash` / `Migrations` diffs. Not read line
by line: `Schemas`, `Tools`, `Attributes`, `ItemPaging`, `GetProducts`,
`ListCategories` (input schemas and read paths; covered by their tests).

## BUG - HIGH — the package needs core 2.63.0 but the floor stayed at 2.38.0

The tools build on `PhoenixKit.API.Tool` (`API.Tools` calls `Tool.new!`,
`API.tools/1` specs `PhoenixKit.API.Tool.t()`), the optional
`PhoenixKit.Module.api_tools/0` callback and `PhoenixKit.Activity.log_many/2`
(`ActivityLog.log_many/1`, called by `Items.update_items/2`). Core's CHANGELOG
puts all three in **2.63.0** ("A machine API for modules to plug tools into
(#934)", "`Activity.log_many/2`"); `git tag --contains` on the commit that adds
`api_tools` lists only `v2.63.0`. `mix.exs` still said
`>= 2.38.0 and < 3.0.0`, so a host on core 2.38–2.62 resolves this release
fine and then gets a package that compiles only with "undefined module
`PhoenixKit.API.Tool`" warnings (it fails `mix compile --warnings-as-errors`;
no code pattern-matches the struct, so a plain compile survives) and whose
`Catalogue.update_items/2` raises `UndefinedFunctionError` from
`PhoenixKit.Activity.log_many/2` after its transaction has committed. An old
core never calls `api_tools/0`, so the tools themselves stay dormant; the
failure is `update_items/2` and the build. `API.Gate` fail-closes the
*dangerous tools*, but it cannot help either.

AGENTS.md already said "raise the `phoenix_kit` floor in `mix.exs` to the first
release that ships the shop API"; the PR did not.

**Fixed:** floor is now `>= 2.63.0 and < 3.0.0` in `mix.exs` (with the history
comment), `test/core_pin_conformance_test.exs` (`@must_admit` /
`@must_reject` moved, 2.38.0 and 2.62.2 now rejected) and AGENTS.md (both the
"Depends on" line and the Shop API bullet). `mix.lock` already resolves 2.63.0.

## IMPROVEMENT - MEDIUM — `mix precommit` was red: dialyzer on `DeleteCategories.subtree/3`

`API.DeleteCategories.subtree/3` threads a `MapSet` through a recursion and
dialyzer (OTP 28.4 / Elixir 1.19) answers `call_without_opaque` on the
`MapSet.to_list/1` and `MapSet.member?/2` calls (lines 59 and 62), the only
two unskipped warnings of the run, so the gate that AGENTS.md asks for before
every commit failed on `main`.

**Fixed:** the seen-set is a plain map (`%{uuid => true}`, `Map.keys/1` at the
end), the shape `ancestors/3` next to it already avoids the problem with. Every
caller sorts or de-duplicates the result (`taken_by/4` sorts; the preview's
`uniq: true` feeds a query), so the unordered list changes nothing observable.

## What was checked and held up

- **Reality of the V5 guard.** `Trash.guard_external_id/1` rescues
  `Postgrex.Error` *outside* the `repo().transaction/1` it wraps, so by the time
  `in_transaction?/0` is asked the inner transaction has unwound; it only turns
  the two V5 index names into `{:error, :external_id_taken}` and re-raises
  everything else, and re-raises inside a caller's own transaction (25P02).
  Correct.
- **`update_items/2` row isolation.** Each row's UPDATE runs with
  `mode: :savepoint`, only `write_item/2` rescues, and only in that mode, so a
  failed read around it still aborts the batch instead of being swallowed.
  Locks are taken categories-then-items, each sorted, matching the trash order.
- **Status values.** `create_products` / `update_products` take
  `active | inactive | discontinued` only (`Schemas`), so the API can neither
  create a row in `deleted` nor move one out of it; `keep_trash_status/3` covers
  the race with a concurrent trash and `finish/4` reports it as
  `trashed_row/3`.
- **`:data_owned_paths`.** `splice_owned_paths/3` applies the owned leaves to
  the *locked* row, prunes emptied maps on `nil`, and `external_id: null` clears
  the key so the partial index frees the id. `preview_item_update/3` models the
  same splice, so dry run and write agree.
- **Dangerous tools.** `delete_products` / `delete_categories` trash only, are
  `danger: :always`, answer `requires_confirmation: true` on a dry run and put
  the affected uuids (not just counts) in the fingerprint. Ancestors are trashed
  first so descendants carry the ancestor's stamp and restore with it.
- **Presenter.** No `base_price` / markup / discount; `shop` fields are gated on
  the `ecommerce.prices:read` scope and the sync bookkeeping keys are dropped.
- **Input trust.** Every id goes through `Refs` / `Common.parse_uuid` /
  `category_verdict` before reaching a query (no `CastError` path), NUL bytes
  are filtered, blank texts are per-row errors, `position` is capped below the
  integer column limit.

## NITPICK — `UpdateProducts` keeps the collected media-folder moves in the process dictionary

`@moves_key` via `Process.put/get/delete` ties correctness to the handler
running in one process for the whole call. It does (core's executor calls the
handler synchronously) and `discard_moves/0` / the `after` clause make it
leak-free, but an accumulator threaded through `finish/4` would not depend on
that. **Not changed:** the behaviour is covered by
`update_items_media_folders_test.exs` and rewriting it is churn.

## NITPICK — `existing_index/2` in `CreateProducts` picks the first of several skus

For a sku held by several live items it reports `existing_id` of the first
candidate (`{:ambiguous_ref, [first | _]}`). The row is skipped either way
(`already_exists`), so only the echoed `existing_id` is arbitrary. **Not
changed.**
