# PR #99: Admin UI: full-width item form, core load_more on the Attributes tab — Claude review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/99
**Author**: @timujinne
**Reviewer**: Claude (Sonnet 5) — post-merge pass
**Date**: 2026-09-07
**Status**: reviewed; no issues found

## Scope

Two independent conformance fixes:

1. Swaps the fixed `max-w-2xl` wrapper on the three form LiveViews
   (`item_form_live.ex`, `category_form_live.ex`, `catalogue_form_live.ex`)
   for the host's `container` class (`px-4 py-6`, was `px-4 py-8`), matching
   the rest of the admin UI's full-width layout instead of clamping these
   three pages to a narrow column. Purely a CSS class change, applied
   identically to all three forms; the golden HTML fixture
   (`test/fixtures/item_form_no_ext.html`) was regenerated to match.
2. Replaces the attribute-sets tab's prev/next page-numbered pagination
   (`attr_sets_page` event with `dir: "prev"/"next"`, an `attr_sets_max_page`
   assign) with core's `<.load_more>` component — an append-only "Showing N
   of M" + button model matching how other lists in this LV/app already
   page (`<.load_more>`/`n`-style components elsewhere in
   `catalogues_live.ex`). `derive_attribute_sets_page/1` now takes the first
   `page * @attr_sets_page_size` rows (`Enum.take`) instead of a single page
   slice (`Enum.slice`), since load-more keeps earlier rows in the DOM.

## Review notes (no fix needed)

- `derive_attribute_sets_page/1` still clamps `page` into `[1, max_page]`
  before taking, so `attr_sets_load_more`'s unconditional `page + 1` can't
  run past the end (it re-derives immediately, which reclamps). Verified
  the search handler (`attr_sets_search`) resets `attr_sets_page` to `1` on
  every keystroke, so a load-more'd page correctly restarts at the top of a
  new filter instead of preserving a stale offset.
- `<.load_more>`'s own template already guards `:if={@total > 0}`
  internally; the call site's `:if={@attr_sets_total > 0}` wrapper is
  redundant but harmless (matches the component's documented non-`infinite`
  manual-button usage — no `id`/`cursor` misuse).
- No `mount/3` queries, no unscoped PubSub, no N+1 introduced — this PR
  doesn't touch data loading, only presentation and one pagination model.
- `test/web/attribute_sets_surfaces_test.exs` was updated in lockstep
  (asserts `#attribute-sets-load-more` renders, drives
  `attr_sets_load_more` instead of `attr_sets_page`) and passes.

## Gate

`mix precommit` (format, credo --strict, dialyzer) clean — the two
pre-existing credo "nested too deep" notes in `item_form_live.ex`/
`category_form_live.ex` (`merge_seo_params/2`, from #96/#97) are unrelated
to this PR's diff. Full suite: 2422 tests, 0 failures.
