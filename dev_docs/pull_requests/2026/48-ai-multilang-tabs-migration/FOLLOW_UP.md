# PR 48 follow-up — Migrate to phoenix_kit_ai's multilang tabs

Triaged 2026-08-29 as part of the four-repo quality sweep. Every finding in
the review was re-verified against current code.

## Fixed (pre-existing)

- ~~`version/0` had drifted from `mix.exs`'s `@version`.~~ Both read
  `"0.20.0"` (`mix.exs:4`, `lib/phoenix_kit_catalogue.ex:97`), pinned by an
  exact-equality assertion at `test/phoenix_kit_catalogue_test.exs:214`.
- ~~`phoenix_kit_ai` 0.16.0 lacked `ai_multilang_tabs/1`; the lock was bumped
  to 0.17.0.~~ Lock is now at 0.19.2 and the component is imported by all
  three form LiveViews (`web/catalogue_form_live.ex:28`,
  `web/category_form_live.ex:25`, `web/attribute_group_form_live.ex:45`).

## Skipped (with rationale)

- **No test asserts the changed markup.** Recorded by the review as
  informational rather than a defect, and still true. The migration swapped
  one tab component for another; the LiveView tests exercise the behaviour
  around them rather than the markup itself.

## Open

None.

## Verification

| Step | Result |
|---|---|
| `mix test` | 2 doctests, 2049 tests, 0 failures |
| `mix precommit` | passes |
