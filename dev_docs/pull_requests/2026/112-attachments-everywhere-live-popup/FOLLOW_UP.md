# PR #112 follow-up

Triaged 2026-09-15 in the deletion/restore quality sweep. Every finding from
`CLAUDE_REVIEW.md` was re-verified against current code.

## Fixed (pre-existing)

- ~~BUG - MEDIUM — the paperclip count could double-count a re-homed file.~~ The link-rows
  query excludes rows naming the file's own home folder
  (`f.folder_uuid != fl.folder_uuid`). Pinned by "a link row naming the file's own home
  folder counts it once" in `test/web/product_card_db_test.exs`. Fixed in the
  post-merge review pass.
- ~~NITPICK — the category form's "moved into" flash was not localized.~~
  `CategoryFormLive` localizes the destination with `Catalogue.localize_one/2`.

## Skipped (with rationale)

Decided in the post-merge review, recorded there.

- NITPICK — the pinned capture inside `match?/2` in the export controller. Correct,
  pinned by three controller tests; a rewrite would be taste.
- Recorded — one `item_catalogue_uuid/1` query per supplier broadcast. Correct and cheap
  at current volumes.
- Recorded — an abandoned `ComponentRelay` lives until the next relevant event after its
  15 s ack window. Bounded and documented in the moduledoc and README.

## Files touched

None in this pass (documentation only).

## Verification

Each fix above was located in current code, with its pinning test present.

## Open

None.
