# PR #152 — follow-up

Triage of `CLAUDE_REVIEW.md` (Claude).

## Fixed

- BUG - HIGH — `phoenix_kit` floor raised from `>= 2.38.0` to `>= 2.63.0`, the
  first core that ships `PhoenixKit.API.Tool`, `api_tools/0` and
  `Activity.log_many/2` (`mix.exs`, `test/core_pin_conformance_test.exs`,
  `AGENTS.md`).

- IMPROVEMENT - MEDIUM — dialyzer `call_without_opaque` on the `MapSet` in
  `API.DeleteCategories.subtree/3` (gate red): seen-set is now a plain map
  (`lib/phoenix_kit_catalogue/api/delete_categories.ex`).
- Not a finding of the PR, found while running the suite: the "libs" bump
  (core 2.62.2 → 2.63.0) made
  `ExtensionSlotTest` ("the item form renders exactly as before the extension
  slot existed") fail on `main`. Core 2.63.0 dropped the extra `block` class from
  a `<.select>` label (`select.ex`), so the snapshot's three select labels
  (Unit, Item type, Status) changed from `label mb-2 block` to `label mb-2 `.
  `test/fixtures/item_form_no_ext.html` updated; it is only valid from 2.63.0
  on, which is now the floor.

## Skipped (with rationale)

- NITPICK — process-dictionary move accumulator in `API.UpdateProducts`:
  correct today and tested; a rewrite adds risk for no behaviour change.
- NITPICK — arbitrary `existing_id` for an ambiguous sku in
  `API.CreateProducts.existing_index/2`: the row is skipped either way.

## Files touched

`mix.exs`, `test/core_pin_conformance_test.exs`, `AGENTS.md`,
`lib/phoenix_kit_catalogue/api/delete_categories.ex`,
`test/fixtures/item_form_no_ext.html`.

## Verification

See the gate result in the commit that carries this file.

## Open

None.
