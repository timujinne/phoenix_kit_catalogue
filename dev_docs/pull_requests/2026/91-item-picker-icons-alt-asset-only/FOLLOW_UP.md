# PR #91 — item_picker: placeholder sizing, alt text, asset type, show_photo toggle — follow-up

## No findings

Verdict was "no changes required". Reviewer: Claude (post-merge). Current code was re-verified on 2026-09-13 (sweep, Phase 1): every note the review left still holds.

One cosmetic item from the review's soft notes was taken in Batch 1 (2026-09-13): the test comment at `test/web/item_picker_test.exs:747` claimed the extra `p-1.5` "shrinks the visible box by 12px", which is wrong under `box-sizing: border-box`; it now says what actually happens (the outer box is unchanged, the glyph's area shrinks). `photo_asset_type` staying an unescaped developer literal in the signed URL is the documented contract, same as `:photo_size`.

## Verification

Re-verified against `main` at `c50c4e3` (0.29.1) on 2026-09-13 as part of the quality sweep (`dev_docs/QUALITY_SWEEP_2026-09-13.md`). Gates for the sweep batch: `mix precommit` clean (compile --warnings-as-errors, format, credo --strict, dialyzer); full suite green with live Postgres (2620+ tests at the time of writing).

## Open

None.
