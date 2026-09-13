# PR #108: Give attribute sets a soft lifecycle, and stop losing hidden values — Claude review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/108
**Author**: @timujinne
**Reviewer**: Claude (Opus 5) — post-merge pass
**Merge commit**: `9d992f8`
**Date**: 2026-09-13
**Status**: reviewed; one IMPROVEMENT enforced in the context, one missing test pin added

## Scope

1. **Set lifecycle.** `archive_set/2` / `restore_set/2` flip the blueprint's
   status through the owner bypass, re-reading the set first and refusing a
   uuid that is not a catalogue set. `list_sets/1` takes `:status`
   (default excludes archived; `:all`, `:archived`; anything else raises).
   The Attributes tab gets Archive/Restore row actions, a "Show archived"
   toggle and badges; the item form stops offering an archived set for a
   new attachment.
2. **Hidden values survive.** A resolved set carries `hidden_values`
   (archived + trashed) next to active-only `values`; `valid_selection/2`
   accepts both, so a value hidden after being picked stays selected. The
   product card, the Items popup and the item form render it; the popup
   and form mark it. `drop_hidden_duplicates/2` is the one dedup rule for
   slug collisions (live beats hidden, hidden collapses among itself).
3. **Pruner.** `OrphanPruner` also subscribes to entities' data topic and
   runs `prune_orphan_value_slugs/1` on `:data_deleted`, keeping every slug
   a record still holds in any status, pruning each orphan with the same
   atomic per-slug `UPDATE` `delete_value/3` uses.
4. **`managed_path`.** `create_set/2` stamps it; `startup/0` backfills it
   onto older sets, one rescued write per set. `update_value/4` now passes
   `on_behalf_of`.
5. The translation dashboard includes archived sets and hidden values.

## Verification

- **Boot backfill writes raw settings.** `backfill_managed_path/0` calls
  `list_sets(status: :all)` with no `:lang`, and entities'
  `maybe_resolve_langs/2` is a no-op for `lang: nil`, so the
  `Map.put(set.settings, …)` write-back cannot persist a locale-resolved
  struct over the stored settings.
- **`exclude_statuses:`** on `EntityData.list_by_entities/2` shipped in
  entities 0.4.7 together with the function itself (and
  `list_values_for/2` already relied on it). An older `~> 0.4` pin takes
  the `function_exported?` fallback, which filters hidden statuses in
  Elixir. No constraint change needed.
- **Disjoint listings.** `list_values_for/2` excludes `archived` (and
  trashed by default); `list_hidden_values_for/2` excludes
  `draft`/`published` with `include_trashed: true`. Draft lands in
  `values`, archived/trashed in `hidden_values`; the translation dashboard's
  concatenation cannot double-list a row.
- **Owner bypass is not a hole.** `archive_set/2` / `restore_set/2`
  re-read via `get_set/2`, which returns `nil` for a blueprint not owned by
  the catalogue, before writing `status` on behalf of the owner.
- **Idempotency.** Archiving an archived set / restoring a non-archived
  set returns `{:ok, set}` with no activity row or broadcast; `tap_log/5`
  broadcasts `:attribute_set` on the write path, so other admins' tabs
  refresh.
- **Activity log.** `attribute_set.archived`, `attribute_set.restored` and
  `attribute_set.orphans_pruned` are each asserted in
  `test/catalogue/attribute_sets_test.exs`.

## Findings

### IMPROVEMENT - MEDIUM — "a hidden value cannot be added" was enforced in the LiveView only

The item form refuses a forged `toggle_value_selection` that ticks an
archived value, but `set_attachment_selection/4` validated slugs against
`values ++ hidden_values`. Any other caller of
`Catalogue.set_attribute_set_selection/4` (an import, a sibling module, a
future form) could attach a value the UI deliberately no longer offers.
The PR left this for the maintainer's call.

**Fixed:** the context now keeps a hidden slug only when the attachment
row already holds it (`keep_only_stored_hidden/2` narrows `hidden_values`
to the stored selection before `valid_selection/2`). A value hidden after
being picked still survives every save; a hidden value the row never held
is dropped like an unknown slug. Pinned in
`test/catalogue/attribute_sets_test.exs` ("set_attachment_selection keeps a
stored hidden slug but refuses to ADD one").

### IMPROVEMENT - MEDIUM — seven new msgids were not pinned in `test/gettext_test.exs`

AGENTS.md requires every hand-added msgid to be pinned. The `.pot` and all
five locales were updated correctly, but no pin was added.

**Fixed:** new "attribute set soft-lifecycle strings" test pins the seven
msgids against et/ru and asserts the en entry exists (en leaves `msgstr ""`
for these, as it does for about half the file — gettext falls back to the
msgid).

### NITPICK — the archive/restore handlers read the set twice

`CataloguesLive` calls `Catalogue.get_attribute_set/1` and the context
re-reads it again. **Not changed:** the context read is the authoritative
one (it is the security check), the handler read gives a clean
`nil` → error-flash branch, and it is one extra lookup per click.

### NITPICK — `resolve_for_items/2` still does one `get_set/2` per distinct set

Values and hidden values are batched; the blueprint lookup is not (entities
has no batched `get_entity`). The docstring now says so honestly.
**Not changed:** needs an entities API.

### Recorded, not fixed

- **The pruner hears every entity's data events.** `subscribe_to_all_data/0`
  routes creates/updates/deletes for every blueprint through one GenServer;
  only `:data_deleted` does work, and a non-set uuid costs a `get_set/2`
  miss. Fine at admin write volumes.
- **`EntityData.bulk_delete/2` emits no event**, so a value destroyed from
  the entities data admin's multi-select leaves a dead slug in stored
  selections until the paired entities PR lands. Reads stay correct (the
  ghost rule drops it).
- **An archived set still offers browse facets** (`filter_options/2` reads
  attachments). Product decision, open.
- **The popup's "Archived value" marker is tooltip-only** and the product
  card does not mark hidden values at all (it renders a comma-joined text
  row). Cosmetic.
- **Slug uniqueness inside a set is not enforced upstream** — the dedup
  rule contains the damage; a unique index belongs in entities.

## Gate

`mix format`, `mix precommit` and `mix test` — see the release commit.
