# PR #109 follow-up

Triaged 2026-09-15 in the deletion/restore quality sweep. Every finding from
`CLAUDE_REVIEW.md` was re-verified against current code.

## Fixed (pre-existing)

- ~~BUG - MEDIUM — the Attributes column dropped archived/trashed selections, and could
  flip the mode.~~ Labels are looked up in `values ++ hidden_values`; the split tests
  in the detail page's attribute column tests pin both halves. Fixed in the
  post-merge review pass.
- ~~IMPROVEMENT - MEDIUM — dialyzer rejected `attached_item_uuids/1`'s spec.~~ One
  `MapSet.new/1` over a single computed list; `mix precommit` passes.
- ~~BUG - MEDIUM (pre-existing) — `migrate_assignments/2` re-attached a detached set.~~
  Each migrated set stamps `settings.catalogue.assignments_migrated_at`. Pinned by
  "a migrated set detached from an item is not re-attached on re-run" in
  `test/catalogue/attribute_sets_test.exs`. Fixed in a follow-up commit after 0.31.0.

## Skipped (with rationale)

Decided in the post-merge review, recorded there.

- NITPICK — swatch presence differs slightly between the column-shown and column-hidden
  branches for an item attached only to a broken-contract set. Rare (a tampered
  blueprint), and neither state is wrong enough for a second query.

## Files touched

None in this pass (documentation only).

## Verification

Each fix above was located in current code by name, with its pinning test present.

## Open

For Max to decide (not deferred by this triage):

- **The swatch tooltip still says "Has attribute group"** where it now means an
  attribute set (four call sites). The review suggested folding the msgid change into
  the next gettext pass.
