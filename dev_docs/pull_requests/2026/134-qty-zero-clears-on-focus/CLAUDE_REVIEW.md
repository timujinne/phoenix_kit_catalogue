# PR #134: qty_stepper: a zero clears itself on focus — Claude review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/134
**Author**: @timujinne
**Reviewer**: Claude Opus 5, post-merge pass
**Date**: 2026-09-22
**Merge**: `62a0d2f`, 2 files, +102 / −1
**Status**: reviewed; 3 findings fixed with regression tests; released as 0.44.1

## Scope

`Browse.qty_stepper/1` (the item selector modal's quantity control, in both
number and free-decimal modes) gets inline `onfocus`/`onblur` handlers. A
field showing a zero (`0`, `0.0`, `0,00`) empties on focus, so typing `8`
gives `8` rather than `08`. Leaving it empty puts the zero back. The PR
copies core's `decimal_input` zero-clear (BeamLabEU/phoenix_kit#859), but it
copied that PR's first cut. Core's own review then fixed three holes and
released the result as phoenix_kit 2.37.4 (`fb393135`), and all three holes
are still in this copy.

The approach is sound. Inline handlers need no hook, which avoids the
inline-`<script>` landmine. LiveView binds `phx-blur` to `focusout` on the
window, which fires after the element's own `blur`, so `qty_commit` sees
the restored zero. And a value set in code fires no `input` event, so the
swap stays invisible to `qty_change` and to the `.QtySignal` hook.

## Findings

### BUG - MEDIUM: the remembered zero lived in `dataset` (fixed)

`this.dataset.pkZero` is a `data-pk-zero` attribute. When LiveView patches
a focused input, `DOM.mergeFocusedInput` → `mergeAttrs` removes every
attribute the server did not render. So if the component re-rendered while
the emptied field had focus (a `ComponentRelay` refresh from another admin's
change, or any selection diff), the zero was lost. The blur then left `""`
and `qty_commit` sent `""`. Inside the modal the revision bump rebuilt the
input from the server value, so the field healed. The component is public
(`Web.Components` exports it), though, and a host with a stable `id` was
left with an empty field.

**Fix:** the zero is now stored in element properties (`this.__pkZero`),
which a patch leaves alone. These are core 2.37.4's handlers, copied
verbatim. A test asserts that no handler touches `dataset`.

### BUG - MEDIUM: typed then erased, the restore went unannounced (fixed)

In quantity mode: focus a `0` (it empties), type `5`, and the debounced
`qty_change` selects the row at 5. Erase the `5`: `qty_change` gets `""`,
which does not parse and is ignored, so the row stays selected. Blur put
back `0`, but nothing announced it, so the server and the selected-state
hook both kept the 5 until the blur's `qty_commit` arrived. If the user
pressed Enter instead of leaving the field, see the next finding.

**Fix:** the focus handler watches for `input` events while the field is
emptied. If the user typed anything, the restore sends its own bubbling
`input` event, so the form's `phx-change` delivers `qty_change "0"` and the
hook flips the highlight back.

### BUG - MEDIUM: Enter in the emptied field submitted `""` (fixed)

Enter fires `phx-submit="qty_commit"` before any blur, so the form sent
`""` rather than the zero. `commit_qty`/`commit_first_qty` then bumped the
revision and ignored the unparseable value. In the typed-then-erased case
above, that left the row selected at the erased quantity.

**Fix:** an `onkeydown` handler puts the zero back on Enter before the
submit fires.

### NITPICK: readonly fields (fixed with the port)

Core's zero test also skips `readOnly` fields. `qty_stepper` never renders
one, but keeping the handler identical to core's is cheaper than
maintaining a variant.

## Tests

`test/web/browse_components_test.exs` now uses the same node harness as
core's `decimal_input_test.exs`. It builds a stand-in `EventTarget` element,
counts the `input` events the handlers dispatch on their own, and covers
three flows: focus then blur, typing then erasing (exactly one
announcement), and Enter. The harness also decodes `&gt;`/`&amp;` in the
rendered attribute, because the new handlers contain `=>` and `&&`. The
node tests are skipped when node is not on PATH.

## Gate

`mix precommit` passes. `mix test` runs 3363 tests with 0 failures.
