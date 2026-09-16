# PR #120: Fix the open items from the #108, #109, #113 and #118 follow-ups — Codex review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/120
**Reviewer**: Codex (gpt-5.6), read-only repo access, no test runs
**Date**: 2026-09-15
**Scope**: commit `c651dcc`, six numbered questions (tree order, counts, the item category check, bulk trash order, the attribute delete rescue, value slugs and archived filters)

1. Failing input — `catalogue_detail_live.ex:2817-2822`: two root categories at the same position, stored names `Alpha`/`Beta`, localized names `Zulu`/`Able`. Parent order: `Alpha, Beta` because SQL sorts before localization; actual: `Beta, Alpha` because the new root-only sort uses localized names. Rows and parent normalization otherwise match.

2. Failing concurrent sequence — `catalogue_detail_live.ex:2783-2787,3000-3007`: while loading category P, cache active counts showing child C has zero children; then another session creates G beneath C before the later listing queries. Parent commit’s later count read shows `1`; this commit reuses `0`, while its listing/chevron includes G. The same applies to active/inactive/discontinued and analogously deleted; without concurrent writes, all root/category/uncategorized branches match.

3. Failing input — `catalogue.ex:5351-5359,5256-5274`: item belongs to category C/catalogue A; call `update_item(item, %{category_uuid: C, catalogue_uuid: B}, skip_derive: true)`. Because C equals the stored category, `get_change(:category_uuid)` is nil and validation is skipped. Expected: cross-catalogue error; actual: `{:ok, item}` with category C and catalogue B. Non-skip derivation and genuinely changed categories are correctly locked and checked.

4. Failing input — `catalogue.ex:6060-6068`: create a valid chain with ancestor A 1,000 edges below the root and descendant D beneath A; submit `[D, A]`. Both depths cap at `1001`, so stable sorting keeps D first. Expected: A first, as in the parent commit; actual: D receives its own trash stamp and restoring A leaves D deleted. Multiple catalogues, nonexistent UUIDs, and malformed UUIDs otherwise behave as before.

5. checked, sound — `attributes.ex:343-355`: transaction exceptions are re-raised after rollback into the enclosing `try`; only `delete!` can raise `Ecto.StaleEntryError` here, and `Attribute` has no optimistic-lock field that could give it another meaning.

6. Failing action sequence — `attribute_sets.ex:508-520`: two sessions concurrently create `"Red"` in the same set, both completing the live/hidden reads before either insert. Both compute `"red"` and both inserts succeed because entity-data has no `(entity_uuid, slug)` unique index. Expected: distinct keys; actual: duplicate `"red"` slugs. For committed-state reads, hidden-value collision checking and archived-set filtering are sound.
