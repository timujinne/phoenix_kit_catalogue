# PR #113: Confirm before permanently deleting an attribute value — Claude review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/113
**Author**: @mdon
**Reviewer**: Claude (Opus 5) — post-merge pass
**Merge commit**: `1c4ea61` (1 commit, `1ca5a6b`)
**Date**: 2026-09-13
**Status**: reviewed; no bugs, two MEDIUM improvements and one test gap fixed post-merge

## Scope

The attribute-group editor's value chip deleted its value on the first
click of the `x` button. The PR routes that button through a confirm modal:
`delete_value` becomes `request_delete_value` (stores the uuid in
`:confirm_delete_value`), `cancel_delete_value`, and `confirm_delete_value`
(resolves the stored uuid through `owned_value/2`, then
`Catalogue.delete_attribute_value/2`). A second `<.confirm_modal>` joins the
existing attribute one. Two new msgids go to the `.pot` and every locale
(ru/et translated, en identity, de/fr empty) and are pinned in
`gettext_test.exs`; a LiveView test covers request → cancel → confirm.

## Verification

- **Mirrors the attribute flow exactly.** Same three-event shape as
  `request/cancel/confirm_delete_attribute`, including the ownership check
  at confirm time. The uuid that reaches `delete_attribute_value/2` is still
  the one resolved from `socket.assigns.group`, so the forgery guard the old
  single-click handler had is preserved.
- **No stale callers.** `rg '"delete_value"'` finds no remaining emitter or
  test for the removed event; `AttributeSets.delete_value/3` is an unrelated
  function.
- **Modal not rendered while hidden.** Core `<.modal>` renders only when
  `@show or @keep_in_dom`, so the warning text is a usable render assertion.
- **Stale confirm.** If the value is deleted in another session while the
  modal is open, the PubSub reload drops it from the group, `owned_value/2`
  returns `nil` on confirm, and the modal just closes. Correct.
- **Wording.** "permanently removes … cannot be undone" is accurate:
  `delete_attribute_value/2` is a hard `delete_all` (archive is the
  in-use path per the `Attributes` moduledoc).
- **de/fr empty msgstr** is the catalogue's established convention for
  these editor strings (e.g. "Failed to delete attribute group."), not a gap.

## Findings

### IMPROVEMENT - MEDIUM — a refused confirmed delete failed silently (fixed)

`confirm_delete_value` sent every non-success branch to
`assign(socket, :confirm_delete_value, nil)`. `delete_attribute_value/2`
can return `{:error, :conflict}` (a concurrent default flip trips the
partial unique index at commit). The user just confirmed a step labelled
"cannot be undone", then saw the modal close on a value still present, with
no explanation. That was tolerable for the old one-click button; it is not
after an explicit confirmation.

**Fix:** a `{:error, _reason}` branch flashes "Failed to delete value." and
reloads the group; the `nil`-owned branch still just closes. New msgid added
to the `.pot` and every locale, pinned in `gettext_test.exs`. The race is
not reproducible from a LiveView test, so the branch itself is untested.

The attribute delete's confirm handler has the same silent `{:error,
:in_use}` branch. It predates this PR and was left as is.

### IMPROVEMENT - MEDIUM — the test never touched the rewired button (fixed)

The new test pushed `request_delete_value` by name with `render_click/3`.
The change the PR actually makes is the template's `phx-click`, and a
template left on the old `delete_value` (now unhandled, so a
`FunctionClauseError` crash on click) would have passed. It also never
checked that the modal renders.

**Fix:** the test clicks the chip's own button via
`element("button[phx-click='request_delete_value'][phx-value-uuid=…]")`,
asserts the warning text appears on request and disappears on cancel and
confirm, and that the chip is gone after the delete.

### IMPROVEMENT - MEDIUM — no forgery test on the new path (fixed)

The ownership check moved from the click handler to `confirm_delete_value`
(the request handler stores any uuid). The existing
"foreign uuids are ignored" test covered only `rename_attribute`.

**Fix:** that test now requests and confirms the delete of another
group's value and asserts it survives.

### NITPICK — `request_delete_value` without a `"uuid"` key crashes (not fixed)

A crafted payload missing `"uuid"` raises `FunctionClauseError`. The old
`delete_value` and `request_delete_attribute` do the same; a forged event
crashing its own LiveView leaks nothing. A non-binary uuid only opens the
modal, and confirm then rejects it through the `is_binary/1` guard.

### NITPICK — "Remove value" button vs "Delete value" modal (not fixed)

The chip's tooltip says "Remove value", the modal says "Delete value". Both
read fine; renaming a tooltip means another msgid in every locale.
