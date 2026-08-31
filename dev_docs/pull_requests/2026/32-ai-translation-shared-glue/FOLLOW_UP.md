# PR 32 follow-up — Shared glue for AI translation

Triaged 2026-08-29 as part of the four-repo quality sweep. Every finding in
the review was re-verified against current code.

## Fixed (pre-existing)

All five items the review applied are still in place:

- ~~Dead `_ = primary` discard in `force_put_language/3`.~~ Gone;
  `primary` is genuinely used (`lib/phoenix_kit_catalogue/ai_translatable.ex:198`).
- ~~Adapter tests missing for the `source_fields` override, the legacy key,
  and the `catalogue`/`category` round-trips.~~ Present at
  `test/phoenix_kit_catalogue/ai_translatable_test.exs:77,86,124,133`; the
  file grew 15 → 20 tests.
- ~~`column_value/2` used `String.to_existing_atom` behind a `rescue`.~~
  Replaced, and since refactored further: the compile-time map became
  per-shape `field_columns/1` clauses (`ai_translatable.ex:56-59`) and
  `column_value/2` is a total `Map.fetch!` (`:98-100`) — no
  `to_existing_atom`, no `rescue`.
- ~~`merge_translation!/6` extraction and the `Helpers` alias (credo).~~
  `ai_translatable.ex:159`, `ai_translate_binding.ex:17,49`.

## Skipped (with rationale)

- **Duplicated AI wiring across the three form LiveViews** (imports, six
  `handle_event` clauses, a `handle_info`), which the review flagged as LOW
  and deferred. **Resolved elsewhere since:** PR #33 folded it into
  `use PhoenixKitAI.Components.AITranslate.Embed`, which now owns those
  events. All three forms carry the macro
  (`web/catalogue_form_live.ex:5`, `web/category_form_live.ex:5`,
  `web/item_form_live.ex:5`).

## Open

None.

## Verification

| Step | Result |
|---|---|
| `mix test` | 2 doctests, 2049 tests, 0 failures |
| `mix precommit` | passes |
