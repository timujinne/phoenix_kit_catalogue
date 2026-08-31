# PR 49 follow-up — Put search and category in the URL

Triaged 2026-08-29 as part of the four-repo quality sweep. Every finding in
the review was re-verified against current code.

## Fixed (pre-existing)

- ~~**BUG - MEDIUM:** an empty `?category=` left `""` in the assign, mangling
  DOM ids and re-writing itself into the URL.~~ Fixed and still in place —
  `web/catalogue_detail_live.ex:262`, with the explanatory comment at
  `:253-261`.
- ~~**BUG - MEDIUM:** search results could be stranded on screen with no way
  to clear them.~~ `web/catalogue_detail_live.ex:3051` — the input renders
  while `@search_results != nil or @search_loading`, not only in the active
  view.
- ~~**IMPROVEMENT - MEDIUM:** `CataloguesLive`'s `tab_changed?` guard is
  load-bearing on the tab links being `navigate`, and the comment above it
  described behaviour that never existed.~~ Comment corrected and the
  invariant plus its failure mode recorded at `web/catalogues_live.ex:191-199`,
  guard at `:204`.
- ~~**BUG - HIGH (pre-existing, outside the diff):** `mix test` aborted
  outright on any machine without `psql`.~~ `test/test_helper.exs:29-31`
  checks `System.find_executable("psql")` first.

## Skipped (with rationale)

- **`view_mode` is still not in the URL on the detail page.** Recorded by the
  review as a known limitation rather than a defect: the detail page declares
  `current_category_uuid`, the search terms and `attribute_filter` as URL
  state, but not the view. Still true. Since the sweep of 2026-08-28 the view
  is a per-user preference stored server-side and applied module-wide, so
  putting it in the URL would now give two sources of truth for the same
  choice — worth a deliberate decision rather than a drive-by fix.

## Open

None beyond the above.

## Verification

| Step | Result |
|---|---|
| `mix test` | 2 doctests, 2049 tests, 0 failures |
| `mix precommit` | passes |
