# PR #113 follow-up

Triaged 2026-09-15 in the deletion/restore quality sweep. Every finding from
`CLAUDE_REVIEW.md` was re-verified against current code.

## Fixed (pre-existing)

- ~~IMPROVEMENT - MEDIUM — a refused confirmed value delete failed silently.~~
  `confirm_delete_value` flashes "Failed to delete value." and reloads the group on
  `{:error, _}`. Fixed in the post-merge review pass.
- ~~IMPROVEMENT - MEDIUM — the test never touched the rewired button.~~ The test clicks
  `button[phx-click='request_delete_value'][phx-value-uuid=…]` and asserts the modal.
- ~~IMPROVEMENT - MEDIUM — no forgery test on the new path.~~ The foreign-uuid test
  requests and confirms another group's value delete and asserts it survives.

## Skipped (with rationale)

Decided in the post-merge review, recorded there.

- NITPICK — `request_delete_value` without a `"uuid"` key raises `FunctionClauseError`.
  A forged event crashing its own LiveView leaks nothing; the older handlers behave the
  same.
- NITPICK — the chip tooltip says "Remove value" while the modal says "Delete value".
  Both read fine; a rename means another msgid in every locale.

## Fixed (Batch 2 — 2026-09-15, commit c651dcc)

Max asked for the open items to be fixed.

- ~~The attribute delete's confirm still fails silently.~~ It was worse than silent: the
  confirm step finds the attribute in the group the editor loaded, so confirming the delete
  of one another session had already removed raised `Ecto.StaleEntryError` and crashed the
  editor. `delete_attribute/2` now returns `{:error, :not_found}` for it (the editor just
  reloads the group), and any other refusal flashes "Failed to delete attribute." (new
  string, et/ru) instead of closing the modal. Pinned in `test/attributes_test.exs` and
  `test/web/attribute_groups_live_test.exs`; the flash branch itself needs a concurrent
  constraint failure and is not reproduced by a LiveView test.

## Files touched

None in this pass (documentation only).

Batch 2: `lib/phoenix_kit_catalogue/catalogue/attributes.ex`, `lib/phoenix_kit_catalogue/web/attribute_group_form_live.ex`, `priv/gettext/*`, and the tests above.

## Verification

Each fix above was located in current code by name.

- Batch fixing the open items (2026-09-15, commit c651dcc): full suite 2850 tests + 2 doctests, 0 failures; `mix precommit` clean; checked on the dev server.

## Open

None.
