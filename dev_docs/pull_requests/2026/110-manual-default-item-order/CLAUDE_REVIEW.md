# PR #110: Make Manual the default item order everywhere — Claude review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/110
**Author**: @mdon
**Reviewer**: Claude (Opus 5) — post-merge pass
**Merge commit**: `8f32fef` (`8128593`, `5b15c85`, `26c287c`)
**Date**: 2026-09-12
**Status**: reviewed; one bug found and fixed, one latent crash path closed, two conformance/determinism gaps filled

## Scope

The PR turns Manual (document) order into the fetch layer's default for
items, so the per-row picker, the browse embed and the item-selector popup
stop listing a category A→Z while the admin shows the hand-arranged order
(client report, 2026-09-12).

Mechanically:

1. `Search.search_items/2`'s `:order` default flips from `:name` to
   `:position`, and the `:position` chain is re-led with the catalogue —
   `cat.position, lower(cat.name), cat.uuid, c.position, i.position,
   i.name, i.uuid` — so the chain is coherent for ANY scope rather than
   only for a single catalogue.
2. `apply_search_order/2`'s lenient catch-all (which silently sorted a
   misspelt `:order` by name) becomes a raising clause.
3. `search_items_in_catalogue/3` stops carrying its own copy of the chain
   and delegates to `search_items/2` with `order: :position` pinned.
4. `BrowseState.put_browse_order/3` drops the "one catalogue in scope"
   gate — the gate is exactly what dropped Manual for a host's
   per-category picker (`category_uuids: [cat]`, `catalogue_uuids: nil`).
5. `Catalogue.list_items/1` and `list_catalogues/1` are re-ordered to
   match (`list_catalogues/1` also moves to `lower(name)`, which is what
   the admin index's own `sort_key` already used).
6. `ItemPicker` asks for the shared browse sort on a blank query;
   `BrowseState.order_fields/0` is exposed so the picker can validate it.

The reasoning in the moduledocs and inline comments is unusually good, the
new tests are pointed (positions deliberately run against the alphabet so
name order cannot pass by accident), and the `search_items_in_catalogue/3`
de-duplication is a real simplification. The findings below are about
edges the PR's own reach exposed.

## Findings

### BUG - HIGH — `list_items/1`'s new catalogue join silently drops orphaned items

`lib/phoenix_kit_catalogue/catalogue.ex:4246`

To order by the catalogue, `list_items/1` gained

```elixir
join: cat in Catalogue,
on: i.catalogue_uuid == cat.uuid,
```

— an INNER join, which changes the ROW SET, not just the order.
`phoenix_kit_cat_items.catalogue_uuid` is nullable
(`migrations.ex:434`) and its FK is `ON DELETE SET NULL`
(`migrations.ex:782`), while `Catalogue.delete_catalogue/2`
(`catalogue.ex:702`) is a real hard delete. So an item whose catalogue was
hard-deleted keeps `status: "active"` and gets `catalogue_uuid: NULL` —
and after this PR it vanishes from `list_items/1` entirely.

`list_items/1` has exactly one caller in `lib/`:
`TranslationStatus.resources_for(:item, nil)` — the Translations page's and
the sweep worker's item enumeration. A silently missing row there does not
read as an error; it reads as "nothing left to translate". The affected
items are also the ones most likely to still want translating, since
nothing else in the admin lists them either.

Worth noting how narrow the upside was: `resources_for/2`'s result is
immediately re-sorted with `Enum.sort_by(&{&1.name, &1.lang})`, so for the
only caller in the repo the new `ORDER BY` is discarded and the join was
pure regression.

**Fixed**: the catalogue join is now a `left_join`. `asc_nulls_last:
cat.position` (and Postgres's NULLS-LAST default on the `lower(cat.name)`
and `cat.uuid` keys) files orphans at the end, which is where they belong.
Regression test: `test/catalogue_test.exs` — "still lists an item whose
catalogue was hard-deleted, last". Verified it fails (`["Filed"]` vs
`["Filed", "Orphan"]`) against the merged inner join.

`Search.search_items_base/2` keeps its inner join deliberately — its
documented contract is "excludes items in deleted catalogues", and an
orphan has no catalogue to scope against. Only `list_items/1`, whose
contract is "all non-deleted items", needed the left join.

### BUG - MEDIUM — the shared sort is validated at one of three call sites

`lib/phoenix_kit_catalogue/web/components/item_picker.ex:526`,
`catalogue_browse.ex:86`, `item_selector_modal.ex:332`

`Browse.global_items_order/0` returns whatever
`ViewConfig.load_global_sort(:detail_items)` reads back, which is validated
only against `TableConfig.columns(:detail_items)`'s `sortable?` ids. Three
places consume it:

| Call site | What it does with an out-of-vocabulary field |
|---|---|
| `ItemPicker` | guarded by this PR (`field in BrowseState.order_fields()`) → Manual |
| `CatalogueBrowse.update/2` | hands it to `BrowseState.init/1`, which **raises** |
| `ItemSelectorModal.update/2` | hands it to `BrowseState.init/1`, which **raises** |

The two lists agree today, so nothing is broken right now. But the guard
the PR added proves the author saw the hazard, and it was added to the one
call site that degrades gracefully anyway rather than to the two that take
the embed and the popup down on OPEN — for every user in the host, because
of a sort preference one admin set on an unrelated page. Making any
`:detail_items` column sortable (`supplier_price` and `unit` are the
obvious candidates) is all it takes.

**Fixed**: the clamp moves into `Browse.global_items_order/0`, so there is
one owner and all three call sites are covered. It logs before falling back
to `{:position, :asc}`, matching `read_global_sort/1`'s existing "degrade,
but never silently" stance. `ItemPicker.shared_browse_order/1` keeps only
the part that is genuinely its own — Manual's direction-less `:position`
opt.

### IMPROVEMENT - HIGH — nothing pinned the three sort vocabularies against each other

Three lists have to stay one list, and the PR made the consequence of
drift worse (the fetch layer now raises where it used to fall back to
name):

1. `TableConfig.columns(:detail_items)` `sortable?` ids — the only values
   `load_global_sort/1` will return.
2. `BrowseState.order_fields/0` — what `BrowseState.init/1` admits.
3. `Search.apply_search_order/2`'s clauses — what the fetch layer can
   build an `ORDER BY` for.

The clamp above is a backstop. The test is what keeps the backstop from
ever being the thing that fires.

**Added**: `test/browse_sort_vocabulary_conformance_test.exs` pins (1) ==
(2) and that Manual is in both; `test/catalogue/search_coverage_test.exs`
gains "every field the browse vocabulary offers is one the fetch layer
accepts", which runs each `{field, dir}` pair plus the bare `:position` /
`:name` atoms through the real query builder.

### IMPROVEMENT - MEDIUM — `list_items_for_catalogue/2` lacks the uuid tie-break it is now compared against

`lib/phoenix_kit_catalogue/catalogue.ex:4310`

The PR's revised cross-check asserts that
`search_items_in_catalogue/3` and `list_items_for_catalogue/1` produce the
same walk, and the comment calls it "a real cross-check, not a tautology"
— correct, but the two chains are not actually identical:
`search_items/2`'s `:position` chain ends `i.name, i.uuid` while
`list_items_for_catalogue/2` ends at `i.name`. Two items tying on
(category, position, name) leave the unpaged read free to disagree with
the paged one, and the new test free to flake.

**Fixed**: added `asc: i.uuid`, so the unpaged chain is byte-for-byte the
tail of the paged one.

## Considered and deliberately not changed

- **`search_items/2`'s default flip is a public-API behaviour change for
  hosts**, not just an internal one: any host calling
  `Catalogue.search_items/2` without `:order` moves from name to Manual.
  That is the stated intent of the PR ("one order for the whole module"),
  the README says so, and hosts that want the old behaviour pass
  `order: :name`. Called out in the CHANGELOG rather than softened.
- **The raising catch-all in `apply_search_order/2`** is a
  behaviour change for a host passing junk — but it replaces a silent
  wrong-order, and `{:position, :bogus}` is still accepted (direction is
  ignored for Manual by contract). Left as the PR has it.
- **`lower(cat.name)` in the order chain has no supporting index**, and the
  7-key sort spans three tables. This is the same tradeoff `AGENTS.md`
  already records for item search (ILIKE over JSONB, no trigram index) and
  it is not worth an index at current catalogue volumes. Not changed.
- **`search_items_in_catalogue/3` now overrides a caller's `:order`.** The
  pre-PR version hardcoded its `order_by` and ignored `:order` too, so
  this is documented, not new.

## Gate

`mix format --check-formatted`, `mix deps.unlock --check-unused`,
`mix compile --force --warnings-as-errors`, `mix credo --strict`,
`mix dialyzer` and `mix test` all clean — 2593 tests, 0 failures (2588 on
the merged tree; 5 added here).

`mix hex.audit` is skipped: it fails on `decimal` 3.1.1's unfixed advisory
with no newer release available, so `mix precommit` cannot pass as a single
command in this repo. The remaining gate steps were run individually.
