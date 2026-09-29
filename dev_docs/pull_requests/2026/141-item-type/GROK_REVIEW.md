# PR #141 — Item type goods / service

- **Author:** timujinne (Tymofii Shapovalov)
- **Merge:** `87e3d23` (head `c158eac`)
- **Reviewer:** Grok
- **Date:** 2026-09-26

## Scope

A catalogue has a default item type (`goods` or `service`); an item's
`item_type` is `nil` (as in the catalogue) or its own value. Migration
V4 adds both columns on the module's chain. `Item.effective_type/1,2`
and `Catalogue.effective_item_type/1` resolve it. `item_types` filters
search, the paged listings, the counts, `BrowseState` and the item
selector by that effective type. The admin UI, copy, import, export and
the activity log carry the field.

## Verified

- V4 is idempotent (`ADD COLUMN IF NOT EXISTS`, guarded CHECKs), leaves
  V1's `CREATE TABLE` untouched, and `down/1` only restamps the marker.
  An extra column on the two manifested tables matches the V2 `slug`
  precedent: core's `ExpectedSchema` does not reject undeclared columns.
  Existing catalogues read as goods; existing items stay `NULL` and
  inherit.
- Effective type matches the markup rule: the item's own value wins,
  including an explicit `"goods"` inside a service catalogue; `nil`
  inherits; no catalogue at all reads as goods. `effective_type/1`
  raises without a preload; `effective_item_type/1` loads and does not.
- The filter SQL agrees with that function. An override is not pulled
  along when the catalogue default changes; an inheriting item is.
  Atoms and a bare `"goods"` are accepted. `nil` and `[]` do not filter.
- Search, the paged listings, both counters, the uncategorized listing,
  `BrowseState.query_opts/1`, the selector's scope check (including a
  preselected uuid and the detail popup) and the picker's scope
  invalidation all thread `item_types`.
- Copy keeps the item's own value (`nil` stays `nil`) and the
  catalogue's default. Export writes the item's own type, empty when it
  inherits, so a re-import does not freeze the catalogue default onto
  the row. Duplicate detection compares a named type to the effective
  type and ignores a blank cell. The activity log stores the words, and
  an item's `nil` shows blank.
- The item form offers the select for smart catalogues too, outside the
  pricing block. The "As in catalogue (…)" hint follows the Location
  picker and a reset. The Service badge is absent for goods. The items
  table column is off by default.

## Findings

### BUG - MEDIUM — The unpaged item lists ignored `item_types` — FIXED

`list_catalogue_items_paged/2`, `list_items_for_category_paged/2`,
`count_items_for_catalogue/2` and `item_count_for_category/2` all apply
`filter_by_item_types/2`. Their unpaged twins,
`list_items_for_catalogue/2` and `list_items_for_category/2`, take the
same `opts` keyword and dropped `:item_types` on the floor. A count and
the list beside it then disagreed, and the import's "load this
catalogue's items" path (`list_items_for_catalogue/2`) could not be
scoped. Nothing in the repo passed the option, so the suite stayed
green.

**Fix:** both queries name the `:item` binding and call
`filter_by_item_types/2`. Absent the option, the query is unchanged.
`test/catalogue/item_type_test.exs` covers a goods catalogue (an
override stays out) and a service category (an inheriting service stays
out of a goods filter).

### BUG - MEDIUM — A stay-save left "As in catalogue (…)" stale — FIXED

The hint is an assign, set at mount and when Location is picked.
`refresh_after_edit/2` re-reads the trail and the saved place, then
clears the staged location, and did not re-read the catalogue's type.
A catalogue whose default changed while the form was open — saved with
"stay" — kept showing the type from when the form opened.

**Fix:** `refresh_after_edit/2` calls `assign_catalogue_item_type/1`
after the saved place is what Location shows. The item-form test
changes the catalogue to service underneath an open goods item, stays
on save, and expects the hint to say Service.

### NITPICK — `create_item/2` did not document `:item_type` — FIXED

The optional-attributes list now names it, next to the corrected
`:unit` line (see the #140 review).
