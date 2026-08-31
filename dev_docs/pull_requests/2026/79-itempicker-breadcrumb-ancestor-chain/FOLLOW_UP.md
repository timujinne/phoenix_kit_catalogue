# PR 79 follow-up — Ancestor chain in the item picker breadcrumb

Triaged 2026-08-29 as part of the four-repo quality sweep. Every finding in
the review was re-verified against current code.

## Fixed (pre-existing)

- ~~**TEST:** the ancestor-chain feature shipped with zero coverage.~~
  `test/web/item_picker_test.exs:239` (the ancestor splice) and `:257` (the
  no-entry fallback); the implementation is intact at
  `web/components/item_picker.ex:458,471-498,553`.

## Skipped (with rationale)

Both were recorded by the review as deliberate, not defects, and both are
still exactly as described:

- **Locale staleness in the `:category_paths` cache.** Keyed by uuid only
  (`web/components/item_picker.ex:472-498`) with no invalidation — unreachable
  in practice because the locale is a URL segment, so a locale change is a
  fresh mount. The review suggested a `@moduledoc` note; that was never added,
  which is the only loose end and a cosmetic one.
- **N ancestor queries rather than one batched call.** `:492` still runs one
  `list_category_ancestors/1` per distinct uncached category. Deliberate: the
  cache makes it once-per-category-per-mount, and the breadcrumb is a handful
  of rows.

## Open

None.

## Verification

| Step | Result |
|---|---|
| `mix test` | 2 doctests, 2049 tests, 0 failures |
| `mix precommit` | passes |
