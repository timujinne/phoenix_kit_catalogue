# PR #140 — Units for services and more goods units — follow-up

Triage of `GROK_REVIEW.md` (Grok, 2026-09-26). One BUG, one NITPICK.

## Fixed (pre-existing)

- ~~BUG - MEDIUM — new unit codes and several of their labels imported as pieces.~~ `@unit_aliases` (`lib/phoenix_kit_catalogue/import/mapper.ex:39` onward) maps every new code to itself (`"hour"` `:68`, `"service"` `:74`, `"visit"` `:79`, `"pack"` `:90`, `"roll"` `:95`), adds `"liter"` (`:105`) and the German and French labels (`"std."` `:69`, `"leistung"` `:75`, `"prestation"` `:76`, `"anfahrt"` `:80`, `"déplacement"` `:81`, `"pkg."` `:91`, `"paquet"` `:92`, `"rolle"` `:96`, `"rouleau"` `:97`). Tests: `test/import/mapper_test.exs:217` (every allowed code and its English label) and `:224` (translated labels of the new units). Commit `a2e92ea` (0.46.0).
- ~~NITPICK — `create_item/2` and the item picker described the old unit list.~~ `create_item/2` documents `:unit` as "one of `Item.allowed_units/0`" (`lib/phoenix_kit_catalogue/catalogue.ex:5707`); the picker's `:format_unit` doc points at the default, `Item.unit_label/1` (`lib/phoenix_kit_catalogue/web/components/item_picker.ex:95`, default at `:732`). Commit `a2e92ea`.

## Skipped (with rationale)

None.

## Files touched

None.

## Verification

Re-verified by reading `main` at `e8a969f` (0.46.1) on 2026-10-05 (quality sweep, Phase 1): each reference below was grepped and the lines read. No code changed, so no gate was run for this triage; `mix precommit` and `mix test` were not re-run.

## Open

None.
