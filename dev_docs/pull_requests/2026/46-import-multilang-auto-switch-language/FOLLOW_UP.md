# PR 46 follow-up — Opt the import wizard out of auto language switching

Triaged 2026-08-29 as part of the four-repo quality sweep. Every finding in
the review was re-verified against current code.

## Fixed (pre-existing)

- ~~Three form LiveViews carried `handle_event("switch_language", …)` clauses
  that `mount_multilang/1` had made unreachable.~~ Verified gone, each
  replaced by a comment recording why: `web/catalogue_form_live.ex:122`,
  `web/category_form_live.ex:171`, `web/item_form_live.ex:445`.
  `web/attribute_group_form_live.ex:360` follows the same pattern.
- ~~The PR's own change.~~ `ImportLive` still opts out explicitly —
  `mount_multilang(auto_switch_language: false)` at `web/import_live.ex:129`,
  with its own clause still reachable at `:384`.

## Open

None.

## Verification

| Step | Result |
|---|---|
| `mix test` | 2 doctests, 2049 tests, 0 failures |
| `mix precommit` | passes |
