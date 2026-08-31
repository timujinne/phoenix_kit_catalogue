# PR 40 follow-up — Catalogue table stack and PRO100 import

Triaged 2026-08-29 as part of the four-repo quality sweep. Every finding in
the review was re-verified against current code.

## Fixed (pre-existing)

All eight fixes verified present:

- ~~**HIGH:** `put_cfg/3` discarded `{:ok, updated_user}`, so a later save
  reverted another tab's.~~ `web/catalogues_live.ex:308-316` reassigns
  `:phoenix_kit_current_user`. (The same trap bit `save_view/2` in the
  2026-08-28 sweep — this is the call site whose comment documents it.)
- ~~**HIGH:** the Columns "Apply" reset sort away from `name`, and `Name` was
  missing from the sort dropdown.~~ Reimplemented: `live_update_columns/2`
  keeps `sort_by` when it is in `known_sortable_ids(scope)`
  (`web/catalogues_live.ex:293-296`), `"name"` is sortable in every scope
  (`web/table_config.ex:51-54,154,175`), and the toolbar passes
  `selected={["position", "name" | @cfg.columns]}` (`:3397`).
- ~~**HIGH:** switching source/format mid-wizard ran the wrong import path.~~
  `web/import_live.ex:2902-2917` calls `reset_parsed_file/1`.
- ~~**HIGH:** the mobile card showed raw `base_price`.~~
  `web/catalogue_detail_live.ex:4543` uses
  `Catalogue.item_pricing(item).sale_price`.
- ~~**MEDIUM:** no "Unfiled (root)" folder option, and a sentinel collision.~~
  `web/table_query.ex:11-14` `@unfiled_folder "__unfiled__"`.
- ~~**MEDIUM:** the PRO100 duplicate-item merge lost a revert-to-original
  row.~~ `import/pro100_plan.ex:167-168` groups by item and diffs
  `[last_row | earlier_rows]`.
- ~~**LOW:** ambiguous matches reported no SKU or name.~~
  `web/import_live.ex:3051`.
- ~~**LOW:** the desktop toggle exposed a card view without bulk-select or
  drag.~~ `web/catalogue_detail_live.ex:4491-4492`.

## Open — the review's own "noted but not fixed" list, all still live

- **A malformed PRO100 price is silently dropped.**
  `import/pro100_plan.ex:290-298`: a non-numeric `c4` becomes `nil` and falls
  to the catch-all `price_change(_item, _row), do: {%{}, :same}` — so a
  corrupt price column reads as "no change" rather than as a problem. The most
  worth fixing of these three: it is a wrong answer, not a missing feature.
- **BOM stripping is untested** — neither fixture starts with `EF BB BF`
  (`test/support/fixtures/pro100/{furniture_8,materials_3}.txt` both begin
  `23 20`), so the code path has never run in the suite.
- **PRO100 "Apply" runs synchronously in `handle_event`.**
  `web/import_live.ex:503-510` is a plain `Enum.reduce` with no `start_async`;
  the only feedback is `phx-disable-with="Applying..."` (`:2593`). A large plan
  blocks the LiveView process for its duration.

## Verification

| Step | Result |
|---|---|
| `mix test` | 2 doctests, 2049 tests, 0 failures |
| `mix precommit` | passes |
