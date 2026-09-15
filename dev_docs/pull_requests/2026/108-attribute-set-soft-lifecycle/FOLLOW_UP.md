# PR #108 follow-up

Triaged 2026-09-15 in the deletion/restore quality sweep. Every finding from
`CLAUDE_REVIEW.md` was re-verified against current code.

## Fixed (pre-existing)

- ~~IMPROVEMENT - MEDIUM — "a hidden value cannot be added" was enforced in the LiveView only.~~
  The context keeps a hidden slug only when the attachment already holds it
  (`keep_only_stored_hidden/2` in `lib/phoenix_kit_catalogue/catalogue/attribute_sets.ex`).
  Pinned by "set_attachment_selection keeps a stored hidden slug but refuses to ADD one"
  in `test/catalogue/attribute_sets_test.exs`. Fixed in the post-merge review pass.
- ~~IMPROVEMENT - MEDIUM — seven new msgids were not pinned in `test/gettext_test.exs`.~~
  Pinned by the "attribute set soft-lifecycle strings" test. Fixed in the post-merge
  review pass.
- ~~Recorded: `EntityData.bulk_delete/2` emits no event.~~ `phoenix_kit_entities`
  now broadcasts `:data_deleted` per row from `bulk_delete/2`
  (`lib/phoenix_kit_entities/entity_data.ex`), so the pruner hears multi-select
  deletes too.

## Skipped (with rationale)

Decided in the post-merge review, recorded there; re-verified still as described.

- NITPICK — the archive/restore handlers read the set twice. The context read is the
  security check and the handler read gives a clean `nil` branch; one extra lookup
  per click.
- NITPICK — `resolve_for_items/2` does one `get_set/2` per distinct set. Needs a
  batched `get_entity` in entities; the docstring says so.
- Recorded — the pruner hears every entity's data events. Only `:data_deleted` does
  work; fine at admin write volumes.

## Files touched

None in this pass (documentation only).

## Verification

Each fix above was located in current code by name, with its pinning test present.

## Open

For Max to decide (not deferred by this triage):

- **An archived set still offers browse facets.** `filter_options/2` reads attachments
  without looking at the set's status. The review called this a product decision.
- **Hidden values are only marked by a tooltip in the Items popup, and not at all on the
  product card.** Cosmetic.
- **Slug uniqueness inside a set is not enforced.** The dedup rule contains the damage;
  a unique index would belong in `phoenix_kit_entities`.
