# PR #94: the popup follows the module's shared sort

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/94
**Author**: @mdon
**Merged**: 2026-09-01 (`00c408f`)

One order for the whole module (client, 2026-09-01): the item-selector popup
and the `CatalogueBrowse` embed now read the same `catalogue_sort_*` settings
the admin pages sort by, instead of keeping their own hardcoded order.

- **`BrowseState` gained `:order`** — a `{field, :asc | :desc}` fixed at init
  like the scope, validated against `@order_fields` (the sortable
  `:detail_items` column ids). It rides blank-search browse fetches only; a
  live search stays name-ordered, which is what the admin's own search does
  (`CatalogueDetailLive.search_in_scope/7` passes no `sort_by`).
  `{:position, _}` keeps the pre-existing single-catalogue guard and ignores
  the direction, like the admin's Manual sort.
- **`Search.apply_search_order/2` learned the directional shapes** —
  `{:position, _}` folds into the existing category-position chain, and
  `{field, dir}` for `name`/`sku`/`base_price`/`status` reproduces
  `Catalogue.item_order_by/3`, uuid tie-break included.
- **`Browse.global_items_order/0` and `global_categories_order/0`** are the
  new shared-sort readers, over `ViewConfig.load_global_sort/1`. The popup's
  listings, its category tiles, its catalogue tiles and the embed's chip row
  all order through them.
- **Tile ordering in `ItemSelectorModal`** reproduces the admin detail page's
  `sort_categories/4` semantics (counts included, Manual direction-less) and,
  for the multi-catalogue root's catalogue tiles, the index's
  `TableQuery.sort/4` keys wherever the tile carries the data.
- **A structural-DateTime sort bug swept out** — `Enum.sort_by/2`'s default
  term order compares `DateTime` structs field-alphabetically (day before
  month), so a bare `& &1.updated_at` sort key put Jan 2nd after Feb 1st.
  Fixed in four `TableConfig` sort keys (via a new `epoch/1`) and in
  `sort_categories/4`.

## Post-merge fixes (this pass)

- The same structural-DateTime bug survived in `Catalogue.item_strategy_order/2`'s
  `:created_asc` / `:created_desc` — the one place that *persists* the order.
- The shared-sort read is a `Settings` (DB) call that landed outside the
  popup's tree-degradation guard; it now falls back to Manual.
- A pin that crosses `TableConfig`'s sortable `:detail_items` ids through
  `BrowseState.init/1`, so the two lists cannot drift into a raise.

See [`CLAUDE_REVIEW.md`](CLAUDE_REVIEW.md).

## Related PRs

- Previous: [#90](../90-selector-popup-sweep), [#91](../91-item-picker-icons-alt-asset-only)
