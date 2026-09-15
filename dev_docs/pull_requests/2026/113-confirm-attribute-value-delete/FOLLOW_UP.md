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

## Files touched

None in this pass (documentation only).

## Verification

Each fix above was located in current code by name.

## Open

For Max to decide (not deferred by this triage):

- **The attribute delete's confirm still fails silently.** `confirm_delete_attribute` in
  `lib/phoenix_kit_catalogue/web/attribute_group_form_live.ex` sends every error,
  including an attribute still in use, to the same branch that just closes the modal.
  The review noted it predates this PR. The value delete's fix would apply as is.
