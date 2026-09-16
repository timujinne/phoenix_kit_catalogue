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

## Fixed (Batch 2 — 2026-09-15, commit c651dcc)

Max asked for the open items to be fixed.

- ~~An archived set still offers browse facets.~~ `filter_options/2` leaves archived sets
  out. Pinned: "an archived set is not offered as a filter"
  (`test/catalogue/attribute_filter_test.exs`).
- ~~Hidden values are only marked by a tooltip in the Items popup, and not at all on the
  product card.~~ Both say "(archived)" after the label. Pinned in
  `test/web/product_card_db_test.exs`, `test/web/attribute_sets_surfaces_test.exs` and
  `test/web/attribute_set_items_modal_test.exs`.
- ~~Slug uniqueness inside a set is not enforced.~~ The gap was the catalogue's own
  `value_slug/3`, which compared a new value's slug against live values only, so it could
  reuse an archived or trashed value's slug. It now checks those too. Entities' own editor
  already checks candidate slugs across trashed rows (`get_by_slug/2`). No database index
  was added: legacy rows may already share a slug, and the dedup rule still contains them.
  Pinned: "a new value never reuses the slug of an archived value"
  (`test/catalogue/attribute_sets_test.exs`).

## Files touched

None in this pass (documentation only).

Batch 2: `lib/phoenix_kit_catalogue/catalogue/attribute_sets.ex`, `lib/phoenix_kit_catalogue/web/components/product_card.ex`, `lib/phoenix_kit_catalogue/web/components/attribute_set_items_modal.ex`, `priv/gettext/*` ("%{value} (archived)", et/ru), and the tests above.

## Verification

Each fix above was located in current code by name, with its pinning test present.

- Batch fixing the open items (2026-09-15, commit c651dcc): full suite 2850 tests + 2 doctests, 0 failures; `mix precommit` clean; checked on the dev server.

## Open

None.
