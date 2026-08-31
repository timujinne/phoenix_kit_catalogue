# PR 76 follow-up — Item selector and browse components

Triaged 2026-08-29 as part of the four-repo quality sweep. Every finding in
the review was re-verified against current code.

## Fixed (pre-existing)

Thirteen of the fifteen findings in `GROK_REVIEW.md` were fixed at review time
and all are still in place:

- ~~**HIGH ×6:** `:statuses` documented then ignored (`catalogue/search.ex:254,269,358-364`);
  `in_scope?/2` crashed on `category_uuid: nil` (`web/components/item_selector_modal.ex:490,495`);
  `:categorized_only` missing from hydration (`:533`); hydration ignored
  descendant expansion (`:351,501-515`); cards showed `base_price` rather than
  the selling price (`web/components/browse.ex:95`); `default_value` used as
  the starting pick quantity (`browse.ex:75`).~~
- ~~**MEDIUM ×5:** the documented morphdom qty-revision was never implemented
  (`item_selector_modal.ex:846-848,955,1079,1115,1221`); category chips
  preloaded every item (`:552`, `catalogue_browse.ex:93`); preselect hydration
  was an N+1 including deleted rows (`:429`); `CatalogueBrowse` had no event
  catch-all and skipped scope validation (`catalogue_browse.ex:146`,
  `browse_state.ex:83,90-98`); the LiveComponents called `Catalogue.Search`
  directly instead of the facade.~~
- ~~**LOW:** Confirm stayed enabled when every pick was unavailable —
  now `disabled={not confirmable_selection?(@selection)}` with the same
  predicate re-checked server-side (`item_selector_modal.ex:1180,703`).~~
- ~~**NITPICK:** `include_descendants` missing from `@scope_keys`
  (`browse_state.ex:57`).~~

## Open

- **NITPICK (still live, and now half-fixed): category chips in
  `CatalogueBrowse` use the primary-language column rather than
  `translated_name/2`.** `web/components/catalogue_browse.ex:92-108` returns
  raw category structs and `browse.ex:151` renders `{category.name}`.
  `ItemSelectorModal` **has** since been fixed
  (`item_selector_modal.ex:567-569`), which makes this a visible inconsistency
  rather than a uniform limitation: the same chips are translated in one
  surface and not the other.
- **NITPICK (still live): `chip_categories/1` is duplicated across the two
  LiveComponents — and has now diverged**, exactly as the review predicted,
  because only one copy gained the locale handling above. One helper, used by
  both, would close both nitpicks at once.
- **Recorded, not done: no starting-quantity field.** `default_qty` is still
  hard-coded to `1` (`browse.ex:75`). A deliberate omission, not a defect.

## Verification

| Step | Result |
|---|---|
| `mix test` | 2 doctests, 2049 tests, 0 failures |
| `mix precommit` | passes |
