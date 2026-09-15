# PR #114 follow-up

Triaged 2026-09-15 in the deletion/restore quality sweep. Every finding from
`CLAUDE_REVIEW.md` was re-verified against current code.

## Fixed (pre-existing)

- ~~IMPROVEMENT - MEDIUM — slugless values shared one swatch thumbnail.~~ `put_thumbs/1`
  skips nil keys and the chip reads its image through `chip_thumb/2`. Fixed in the
  post-merge review pass, with a two-slugless-values test.
- ~~NITPICK — the disabled chip kept the clickable styling.~~ Slugless chips render
  `opacity-60 cursor-not-allowed`.
- ~~NITPICK — a test comment contradicted the second commit.~~ Reworded.

## Skipped (with rationale)

Decided in the post-merge review, recorded there.

- NITPICK — "slug" is internal vocabulary in the tooltip. Still actionable for the admin
  who owns the data; rewording means another msgid in every locale.

## Files touched

None in this pass (documentation only).

## Verification

Each fix above was located in current code by name.

## Open

None.
