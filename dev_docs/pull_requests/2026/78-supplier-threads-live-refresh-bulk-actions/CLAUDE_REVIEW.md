# PR #78: Supplier comment threads, live refresh, and bulk Move / Duplicate / Supplier price

**Author**: @mdon
**Reviewers**: four Claude triage passes (security + error handling + async UX; translations + activity + tests; PubSub + cleanliness + API; host-integration boundaries), read-only over `upstream/main..main`, every claim re-read in the current code
**Date**: 2026-08-24
**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/78

## Findings (verified unless marked)

1. **BUG — client-captured uuids without a catalogue scope.** Category Move, Duplicate (both kinds) and category bulk trash accepted any uuid; item trash / restore / purge likewise, while the page re-broadcast only for its own catalogue (a foreign catalogue's pages stayed stale). The item Move path already enforced `:catalogue_uuid` / `:wrong_catalogue_scope`.
2. **BUG — modal handlers raise `KeyError` when the modal is closed** (`%{modal | …}` on `%{}`); six handlers, three pre-existing.
3. **BUG — activity logged inside the Duplication transaction**; core's `Activity.log/1` inserts and broadcasts pre-commit, and `parent_catalogue_uuid` reached core unstripped (dropped by cast). No summary row for a bulk run.
4. **BUG — "(copy)" rendered once in the acting admin's locale and stamped into every language entry.** Test enshrined it (`"A-et (copy)"`).
5. **BUG — `push_event("bulk_select:clear")` has no handler in core's `BulkSelectScope` hook** (JS byte-identical to v2.13.6); after Duplicate the originals kept their ticks. Everything else the toolkit relies on exists in the pinned core.
6. **BUG — `ItemSupplierInfos.delete/2` closes with `valid_to = today` even for a row dated to start in the future** (inverted window; changeset rule bypassed by `force_change`).
7. **IMPROVEMENT — sibling renumbering in Duplication reads then writes without a lock** (concurrent copies interleave).
8. **IMPROVEMENT — `bulk_trash_categories` fans out one event per category**, unlike every other bulk op.
9. **IMPROVEMENT — inconsistent bulk error shapes** (atoms, tagged tuples, changesets dumped into the operation log).
10. **NITPICK — duplicated shapes**: two identical duplicate handlers plus an inline copy in the category Move; three copy-pasted picker forms; `supplier_page_path/2` evaluated three times per supplier row; `item_edit_raw/2` without `@doc`/`@spec`; silent `rescue _ -> %{}` in the resolver.
11. **TEST — no test pinned the bulk-op event order** (bulk change before the batch `:item` event); the import-monitor test passed without `stop_import_monitor`; the permanent-delete test asserted a count that cannot move; delete-closes-row test present.
12. **Boundary traces (intact)**: `resource_links/0` → core registry → comments admin (raw paths, `prefixed: true` applied once); `?tab=sourcing`; `PhoenixKitCRM.Paths.company_raw/1` guarded and stubbed faithfully; `:item_supplier_info` (parent nil) handled on both pages; `{:comments_updated, :updated}` matched totally by every consumer.

## Not defects on verification

- Cost ranges grouping `NULL` and `""` separately (Gemini, Codex): Ecto's `cast` stores `""` as `nil`; a sabotage run with a plain `group_by` kept the test green.
- `format_supplier_costs/1` on `nil` min/max (Gemini): the query filters `not is_nil(unit_cost)`.
- Stale supplier prices in search results (Gemini, ZAI): the search grid renders a fixed column set without the supplier price.
- Every `:catalogue_data_changed` dropped during the bulk-change window (ZAI): the deferred apply reloads the level and its row maps; supplier costs have their own clause.
- Orphan-prune broadcast inside a transaction (ZAI): `delete_all` then broadcast, no transaction.
- `copy_supplier_rows/2` drops `valid_from` (ZAI): it is in `@supplier_fields`.
