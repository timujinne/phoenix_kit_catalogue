# Follow-up — PR #84 (attributes viewer, honest search, honest filter)

Triage of `CLAUDE_REVIEW.md` (2026-08-28, reviewed together with #82/#83)
against current `main`, 2026-08-31.

## Fixed (pre-existing)

- ~~`<.icon class={[...]}>` list value failing `mix compile
  --warnings-as-errors` (finding 1, introduced by #83)~~ — fixed in the
  review pass itself; verified `item_picker.ex:712` now interpolates a
  single string.
- ~~`:show_sku` moduledoc describing a layout the markup doesn't render
  (finding 2)~~ — reworded in the review pass; verified the doc now
  matches the sibling-column markup.

## Skipped (with rationale)

Both were deferred **by the reviewer in the review itself** — recorded
here, not re-decided:

- **Duplicated JSONB string-search SQL fragment**
  (`Search.search_categories/3`, `Search.match_item_text/2`, plus the
  `Helpers.json_string_values_doc/0` stub). Turning the doc stub into a
  shared fragment-builder is a real refactor, not a bug fix; the review
  explicitly parked it as deliberate follow-up work. Trigger condition:
  the next edit to ANY copy of the fragment must do the dedup first.
- **Mild N+1 in `AttributeSets.filter_options/2`** (one `get_set/2` per
  distinct set uuid). Bounded by admin-curated set counts; no batched
  `get_sets/2` exists to swap in. Becomes worth fixing if set counts
  grow or a batch API appears.

## Files touched

| File | Change |
|------|--------|
| — | none in this follow-up; both fixes landed with the review |

## Verification

`mix precommit` clean and `mix test` green (2 doctests, 2133 tests, 0
failures) on the tree carrying these fixes, re-run 2026-08-31.

## Open

None (the two skipped items are recorded above with their triggers).
