# PR #94: the popup follows the module's shared sort — Claude review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/94
**Author**: @mdon
**Reviewer**: Claude (Opus 5) — post-merge pass
**Date**: 2026-09-01
**Status**: reviewed; three changes applied

## Verdict

The feature itself is right, and unusually well pinned — the two shapes that
could have been fudged (a `{:sku, :asc}` order satisfied by the name
fallback; category tiles that only *look* sorted because the SQL already
ordered them) are both tested with distinguishing fixtures. The findings are
at the edges: one place the DateTime sweep did not reach, one guard the new
DB read stepped outside of, and one pair of lists that agree today with a
`raise` waiting between them.

---

## BUG - MEDIUM: `:created_asc` / `:created_desc` item reorder still sorts DateTimes structurally

`lib/phoenix_kit_catalogue/catalogue.ex:4074` (pre-fix)

The PR correctly identified that `Enum.sort_by/2`'s default term order
compares `DateTime` structs field-alphabetically — `:day` sorts before
`:month`, so `~U[2026-01-02]` compares *greater* than `~U[2026-02-01]` — and
swept it out of four `TableConfig` sort keys and
`CatalogueDetailLive.sort_categories/4`. The category-side reorder strategies
(`order_categories_for_strategy/2`) and the index's
(`CataloguesLive.order_rows_for_strategy/2`) already used `{dir, DateTime}`.

The **item** side did not:

```elixir
defp item_strategy_order(rows, :created_asc),
  do: rows |> Enum.sort_by(& &1.uuid) |> Enum.sort_by(& &1.inserted_at) |> Enum.map(& &1.uuid)
```

This is the detail page's "Sort items by → Newest first / Oldest first" bulk
reorder. It is worse than the display bugs the PR fixed, because it *writes
positions*: a wrong order is persisted into `position` and then becomes the
Manual order everyone sees, including the printed document order.

**Failure scenario.** A catalogue whose items were created either side of a
month boundary — say `Widget` on 2026-01-02 and `Anvil` on 2026-02-01. Pick
"Oldest first". Expected `Widget, Anvil`; you get `Anvil, Widget`, written to
`position`.

The existing pin (`":all + :created_asc / :created_desc reindex by insertion
order"`) cannot see it: `backdate_item/2` moves timestamps by *seconds*, and
with day/hour/minute equal the structural comparison falls through to
`:second` and gets the right answer by accident.

**Fixed** — both clauses now use `{:asc, DateTime}` / `{:desc, DateTime}`,
with the same comment the PR used elsewhere. Pinned by
`":created_* order chronologically, not structurally"` in `catalogue_test.exs`,
using two dates that straddle a month boundary with inverted days (the shape
the old test lacked).

---

## IMPROVEMENT - HIGH: the shared-sort read is a DB call outside the popup's degradation guard

`lib/phoenix_kit_catalogue/web/components/item_selector_modal.ex:586`,
`:328`; `web/components/catalogue_browse.ex:83`

`ItemSelectorModal`'s tree build carries an explicit contract, stated in its
own comments and enforced by a `rescue` on each `do_build_category_tree/3`
clause: *tiles are navigation, not data* — a DB failure degrades to
`@empty_cat_tree` (logged, since #90's review) rather than taking the popup
down. `Browse.chip_categories/2` rescues for the same reason.

The PR appended the ordering step **after** that pipeline:

```elixir
scope
|> derive_tree_catalogues(original)
|> do_build_category_tree(original, locale)   # rescues live in here
|> order_tree_tiles(Browse.global_categories_order())   # …and this is outside them
```

`global_categories_order/0` reaches `ViewConfig.load_global_sort/1` →
`Settings.get_setting/2`, i.e. the database. The same read also fronts
`BrowseState.init`'s `:order` in both the modal (`:328`) and `CatalogueBrowse`
(`:83`), where it runs before anything is assigned — so the failure mode is a
crashed `LiveComponent` on a surface the moduledoc calls "potentially
client-facing", in exchange for a *sort preference*.

This is the same instinct the module already documents for `enabled?/0`
("must rescue everything — the DB may be unavailable at boot").

**Fixed** in the one place that covers all three call sites: `global_items_order/0`
and `global_categories_order/0` now share a `read_global_sort/1` that rescues
to `{:position, :asc}` — Manual, which is `TableConfig.default_sort/1` for both
scopes, so the fallback is the module's own default rather than an invented
one — and logs, so a settings failure can never masquerade as "the sort
setting isn't sticking".

---

## IMPROVEMENT - HIGH: two lists that must stay in sync, with a `raise` between them

`lib/phoenix_kit_catalogue/catalogue/browse_state.ex:59`

`@order_fields ~w(position name sku base_price status)a` is a hand-copied
duplicate of the `sortable?: true` ids in `TableConfig.columns(:detail_items)`,
and `init/1` **raises `ArgumentError`** on anything else. The strictness is
right (the PR's own comment: a bad field must not sail into the fetch layer as
a no-op sort) — but it turns drift into a crash, and nothing fails when the
lists diverge.

They agree today. The trap is that adding one `sortable?: true` column to
`:detail_items` — an entirely local-looking edit in `TableConfig` — would pass
every test, and then crash **every** selector popup and `CatalogueBrowse` embed
the first time an admin picked that column in the detail page's sort selector.
Nothing in the diff points from one list to the other except a comment.

**Fixed** by a pin, not by collapsing the lists (the atom list is also
`Search.apply_search_order/2`'s vocabulary, and the two are deliberately
separate concerns): `"every sortable :detail_items column is an accepted
browse order"` in `browse_state_test.exs` crosses every sortable id × both
directions through `init/1`. A new sortable column now fails in CI, at the
list that needs updating.

---

## What I checked and found correct

- **`@order_fields` vs. the registry.** Sortable `:detail_items` ids are
  exactly `name`, `position`, `base_price`, `sku`, `status`; `@order_fields`
  matches, and `Search.apply_search_order/2` has a clause for each (`:position`
  via the fold, the other four via the guarded `{field, dir}` clause). The
  `String.to_existing_atom/1` claim holds — every id is a compiled-in atom.
- **"A live search stays name-ordered, like the admin's."** Verified against
  the emitter, not the description: `CatalogueDetailLive.search_in_scope/7`
  passes `limit`/`offset`/`value_slugs` and no `sort_by`, so admin search
  results really are name-ordered. The claim is true of the admin, not just
  asserted about it.
- **Catalogue tiles' `items` sort is not a silent no-op.** It reads
  `tree.counts`, and the multi-catalogue clause merges `catalogue_counts`
  (keyed by the same stringified uuid the tile carries) into the category
  counts before the tiles are sorted. This was the most likely place for a
  sort that renders but does nothing.
- **The name sorts agree in every locale.** The popup sorts tiles by their
  *translated* names; so does the admin — `child_categories` is put through
  `Catalogue.localize/2` (`catalogue_detail_live.ex:2479`) before
  `sort_categories/4`, and the index localizes rows before
  `TableQuery.apply/3`. "One order everywhere" survives a locale switch.
- **The new `DateTime` sorters can't hit the `NaiveDateTime` gap.** Every
  schema involved declares `timestamps(type: :utc_datetime)`, and
  `list_categories_metadata_for_catalogue/1` returns full `%Category{}`
  structs (not a `select`ed map), so `:updated` tiles always have a real
  `DateTime`. `TableConfig.epoch/1` covers the naive case anyway.
- **`{:position, _}`'s single-catalogue guard is unchanged.** The refactor
  from `if` to `cond` preserves the old behaviour exactly for `order: nil`,
  which is what every existing caller passes.
- **`base_price` NULL ordering** matches `item_order_by/3` (Postgres default:
  nulls last on ASC, first on DESC) — the popup and the admin agree on where
  price-less items land.

## NITPICK (not fixed)

- **`decimal_key/1` duplicates `TableConfig`'s private `dec/1`**, three clauses
  each. Exporting `dec/1` for one caller buys more coupling than the six lines
  save — `TableConfig` is the sort-key vocabulary, not a helpers module.
  Recorded so the next hand adding a Decimal column knows both exist.
- **`tile_sorted/3` has a catch-all where `sort_categories/4` has an exhaustive
  `case`.** An unknown `:detail_categories` sort field keeps query order in the
  popup and raises `CaseClauseError` on the admin page. The lenient side is the
  right one for a client-facing surface; noting that the two now disagree about
  what "unknown field" means.
- **The shared sort is read once at init** and does not follow a live re-sort
  elsewhere, which the PR documents as deliberate. Worth remembering that
  `ViewConfig.broadcast_view_sort_changed/4` already exists if the client later
  asks for the popup to follow along.

## Gate

`mix format` → `mix precommit` (`compile --force --warnings-as-errors`,
`deps.unlock --check-unused`, `hex.audit`, `format --check-formatted`,
`credo --strict`, `dialyzer`) clean, plus `mix test` against a live database.
