# PR #153 — Internal catalogues, notes for AI and item dependencies

- **Reviewer:** Claude
- **Date:** 2026-10-18
- **Author:** Max Don (merged by Dmitri Don)
- **Scope:** migration V6 (`categories.internal`, `ai_notes` on three tables,
  `phoenix_kit_cat_item_dependencies`); `Catalogue.Dependencies`,
  `Schemas.ItemDependency`, `Catalogue.AiNotes`; the internal-category rule in
  `Search`, `Browse`, `CatalogueBrowse`, `ItemPicker`, `ItemSelectorModal`;
  the item form's Dependencies tab (`DependencyDraft`, `DependenciesPanel`,
  `PlaceTree` items); duplication, import (`DependencyCell`, `Executor`
  phase 4) and Universal JSON export; 66 files, ~3.7k lines of source.

Read in full: `Dependencies`, `ItemDependency`, `DependencyDraft`,
`DependencyCell`, the V6 migration, and the diffs of `ItemFormLive`,
`PlaceTree`, `Search`, `Categories`, `Duplication`, `Executor`, `Mapper`,
`UniversalJson`, `Browse`, `CatalogueBrowse`, `ItemPicker`, `BrowseState`,
`ItemSelectorModal`, `CatalogueDetailLive`, `CataloguesLive`. Not read line by
line: `DependenciesPanel` (markup), the gettext files, `ImportLive`'s report.

**No defect found.** What was checked:

- **Internal rule is a boundary, and it holds where it should.**
  `Browse.put_internal_rule/2` is applied *after* the host's scope is read, so a
  host can reach internal categories only through `include_internal`, never by
  naming them. `search_items` / `search_categories` filter with
  `exclude_internal` and keep uncategorized items (`is_nil(category_uuid) or …
  not in ^hidden`). The hidden set includes trashed rows, so a live
  subcategory of a trashed internal category stays hidden. The modal fails
  closed when it cannot read the set (`put_hidden_categories/1` empties
  `catalogue_uuids`). Tile counts subtract hidden categories' *direct* counts,
  so nothing is subtracted twice. The shop API (#152) is admin-keyed and rightly
  does not apply the rule.
- **V6 is idempotent and non-destructive.** Every constraint goes through
  `guarded_constraint`, indexes use `IF NOT EXISTS`, nothing is dropped;
  `internal` is `NOT NULL DEFAULT false`. The table's `quantity numeric(12,4)`
  matches `ItemDependency`'s `@max_quantity` and scale check, and the
  `num_nonnulls = 1` / not-self CHECKs are mirrored by changeset validations and
  `check_constraint`.
- **`put_item_dependencies/3`** takes the item row `FOR UPDATE`, compares
  contents (decimals normalized) before deciding `:unchanged`, refuses a stale
  `expected:` with `:dependencies_changed`, and rolls back on the first bad row.
  The item form looks for that conflict *before* `update_item/3`
  (`check_dependency_conflict/1`), so a stale list does not leave half a save.
- **Item form.** The picker's selection is re-read from the database on Add
  (`dependency_target_from_place/1`; the getters answer `nil` for a non-UUID),
  the self-pick and trashed/gone targets are refused, a bad row blocks the whole
  save and opens its tab, and a create that cannot save its dependencies lands
  on the edit form with a flash instead of dropping them silently.
- **Duplication / import / export.** A copy points targets copied in the same
  operation at their copies (`remap_dependencies!/2`) and leaves outside targets
  alone; the import resolves after every row exists, reports unresolved lines by
  the *file's* row (`:_row`), and still creates the item; `DependencyCell`
  bounds a cell (100k chars, 200 refs) and rejects quantities the column cannot
  hold, so a row's whole list does not fail later.

## IMPROVEMENT - MEDIUM — the Dependencies picker builds a tree of every live item per open

`dependency_open_picker` calls `PlaceTree.places(items: true)`, which loads all
live items of all catalogues (`list_live_items/1`) and holds the whole tree in
the LiveView's assigns while the pop-up is open. The comment says why it is built
on open rather than at mount, and at today's volumes it is fine. At tens of
thousands of items the open click becomes a multi-second query plus a large
socket diff, per admin. **Not changed:** the right fix is a search-driven picker
(the `ItemPicker` already exists, with `clear_on_select` added in this PR for
exactly that), which is a UI decision rather than a defect. Trigger: an install
where opening the pop-up is visibly slow.

## IMPROVEMENT - MEDIUM — import resolves each dependency reference with its own queries

`Executor.link_dependencies/3` calls `Catalogue.resolve_import_ref/2` once per
reference (up to two queries each, 200 references per row). A large import of
rows that each carry a long list is `rows × refs × 2` round trips after the
rows are created. **Not changed:** the per-cell cap bounds one row, the common
list is a handful of lines, and batching by SKU/name needs a new lookup shape.

## NITPICK — `resolve_import_ref/2` relies on its caller for a valid `type`

`String.to_existing_atom(type)` is rescued for `ArgumentError`, but an existing
atom that is not a kind (say `"ok"`) with a uuid would reach `live_query/1` and
raise `FunctionClauseError`. The only caller (`Executor`) passes types that
`DependencyCell` has already limited to `item | category | catalogue`, so it is
unreachable today. **Not changed.**
