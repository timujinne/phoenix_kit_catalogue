# PR #120 follow-up

How each finding in `CODEX_REVIEW.md` and `ZAI_REVIEW.md` was resolved, verified
against the code first.

## Fixed (Batch 1 — 2026-09-15, commit b6b3d82)

- ~~Codex 1 — the root's Active tree, built from rows it had already read, sorted
  its root group by translated names.~~ The saving was one query, so the tree
  read went back to `list_category_tree(uuid, mode: :active)`, which sorts by
  stored names in SQL as before.
- ~~Codex 3 — an importer update (`skip_derive: true`) that changed an item's
  `catalogue_uuid` without changing its category skipped the category check.~~
  Older than this PR, but the drift that check exists to stop. The check now
  also runs on the unchanged category when the catalogue changes. Pinned: "a
  skip_derive update that moves an item's catalogue away from its category is
  refused" (`test/catalogue_test.exs`).
- ~~Codex 4 — `ancestors_first/1` capped a walk at 1,000 steps, misordering a
  deeper chain.~~ The walk now stops only after more steps than there are
  categories, which only a cycle can reach.
- ~~Codex 6 — two sessions creating the same value label at once could both
  take its slug.~~ Older than this PR. `create_value/3` now takes the per-set
  advisory lock that attaching and deleting already take, so creations in one
  set run one at a time.
- ~~New finding while cleaning up — the catalogue's two entities delete guards
  raced at boot and one went missing (confirmed on max-dev and tim-dev), so every
  attribute-set delete failed closed with `:no_delete_guard`.~~ A single boot task,
  `PhoenixKitCatalogue.Catalogue.DeleteGuards`, now registers both guards in turn.
  The root cause is fixed in entities too (BeamLabEU/phoenix_kit_entities#48);
  this keeps the catalogue safe on entities releases before that. Pinned:
  `test/catalogue/delete_guards_test.exs` and the updated `children/0` test.

## Skipped (with rationale)

- **Codex 2 — drilled child counts read before a concurrent child insert.** The
  counts and the listing were always separate reads with a gap between them;
  this only moves the read earlier, and the page reloads on the insert's
  broadcast.
- **Codex 5** — reported sound.
- **Zai — the new and renamed strings are empty in de and fr.** The catalogue
  translates et and ru and leaves most de and fr strings empty (the msgid
  shows); earlier reviews recorded this as the convention.

## Fixed (Claude release review — 2026-09-15, release 0.32.0)

From `CLAUDE_REVIEW.md`.

- ~~IMPROVEMENT - MEDIUM — the supplier-fields guard was skipped when entities
  was off at boot.~~ `SupplierFields.startup/0` registers whenever entities'
  `Managed` is loaded, as the attribute-set guard does. Pinned: "register/0
  registers both guards while entities is disabled"
  (`test/catalogue/delete_guards_test.exs`).
- ~~NITPICK — the product card marked "(archived)" by key.~~ Hidden values are
  marked themselves, so a live value sharing a key with a hidden one keeps its
  plain label.
- **Correction** to Batch 1 above: the entities fix (#48) is not in any released
  entities. `register_delete_guard/2` in 0.4.14 is still a read-then-write on one
  shared map. `DeleteGuards` is what keeps the catalogue safe until it ships.

### Skipped (Claude release review)

- **The two registrations share one task.** Each call is a `Code.ensure_loaded?/1`
  and a `:persistent_term` write, and the supplier call already rescues. Isolating
  them adds code for a failure nobody has seen.
- **An attribute delete refused as `:in_use` flashes the generic message.** The
  refusal only happens on a constraint race with a concurrent insert, since the
  delete removes the attribute's values first. A dedicated message would add
  msgids in six catalogues for it.

## Files touched

| File | Change |
|------|--------|
| `lib/phoenix_kit_catalogue/catalogue/delete_guards.ex` | new boot task registering both guards |
| `lib/phoenix_kit_catalogue.ex` | `children/0` starts `DeleteGuards` instead of the two registration tasks |
| `lib/phoenix_kit_catalogue/catalogue/attribute_sets.ex` | startup no longer registers the guard; `create_value/3` locks the set |
| `lib/phoenix_kit_catalogue/catalogue/supplier_fields.ex` | no longer a boot child of its own |
| `lib/phoenix_kit_catalogue/catalogue.ex` | category check on catalogue changes; depth walk without a cap |
| `lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex` | tree read reverted |
| `test/catalogue/delete_guards_test.exs`, `test/phoenix_kit_catalogue_test.exs`, `test/catalogue_test.exs` | pins |

## Verification

- Full suite 2853 tests + 2 doctests, 0 failures; `mix precommit` clean.
- max-dev: after deploy and restart both guards are registered with no manual step, a throwaway attribute set was created and permanently deleted (`:ok`), and 7 pages checked with 0 failing.
- Claude release review batch (2026-09-15, release 0.32.0): full suite 2881 tests + 2 doctests, 0 failures; `mix precommit` clean, after `mix format` fixed the `category_facts/2` clause this PR left unformatted.

## Open

None.
