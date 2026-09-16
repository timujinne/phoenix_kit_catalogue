# PR #121: ItemSelectorModal: qty_precision :any (free decimals, text control, no rounding) — Claude review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/121
**Author**: timujinne
**Reviewer**: Claude (Opus 5), release review
**Date**: 2026-09-16
**Scope**: merge `47eba76` (`d687dc8..47eba76`): `Web.Components.Browse.qty_stepper/1`,
`Web.Components.ItemSelectorModal` (limits, clamp, parse, unit suffix),
`test/support/selector_host_live.ex` and the two test files.

## Summary

A small, well-scoped PR. `qty_precision: :any` threads through every place
the precision is used: limit rounding (`round_limit/3`), clamping
(`round_qty/2`), the parse pattern (12 decimals instead of 6), the unit
suffix (`decimal_qty?/1`), and the control (`type="text"`,
`inputmode="decimal"`, no `step`/`min`/`max`). The server guards all still
apply in free mode: the digits-only regex, the exponent/NaN refusal, the
`qty_min` floor, `qty_max` and the 1,000,000 ceiling. The tests cover each of
these, and the grep over `qty_precision` found no call site the PR missed.
`min={@precision != :any && @min}` is correct: `false` drops the attribute
and `true && nil` stays `nil`. No server-side correctness bugs.

## Findings

### BUG - MEDIUM — the instant-highlight hook could stick on input the server refuses (fixed)

`QtySignal` read the value with `parseFloat`, which accepts a numeric
prefix. With the new text control, "2.5.1", "2abc" or "1e9" parse as a
positive number, so the hook marks the row `data-selected="true"`, but
`parse_qty/2` rejects them. A rejected `qty_change` changes no state, so
the server sends no diff, and the highlight stays wrong until some other
change re-renders the row. That is exactly what the hook's own comment says
must not happen ("the flip mirrors the ACCEPT SET"). A number input
already turned most garbage into `""`, which is why this was mostly latent
before. Even so, a number input still returns "1e3" as-is, and the server
rejects that too.

**Fix:** after trimming and swapping commas for dots, the hook now requires
`^-?\d+(\.\d+)?$` before it flips anything. The optional sign keeps the
path where a negative or zero value deselects (`zero_qty?/1` accepts those).
There is no JS test harness in this repo, so this is covered by review only.

### IMPROVEMENT - MEDIUM — an invalid `qty_precision` failed late, or not at all (fixed)

With `:any` now a legal atom, a host is more likely to pass the wrong type,
like `"any"` from a params map, a misspelled atom, or a negative integer.
Before the fix, a string crashed with a `FunctionClauseError` inside
`Decimal.round` at init. An unknown atom was worse: `decimal_qty?/1` falls
back to `precision > 0`, which is `true` for any atom under Erlang term
ordering, and the crash only came later. `resolve_limits!/2` now raises an
`ArgumentError` at init unless the value is `:any` or a non-negative
integer. This matches the other `!` config validators. Pinned by
"a qty_precision that is neither a non-negative integer nor :any raises at
init".

### NITPICK — `round_limit/3` landed inside an unrelated comment block (fixed)

The helper was inserted between the "granted set minus what starts hidden"
comment and the `resolve_visible_columns!` comment, which cut the
column-visibility commentary in two. Moved it directly under
`resolve_limits!/2`, its only caller.

### Not changed

- In free mode, `qty_min`/`qty_max` are taken unrounded. A host limit with
  more than 12 decimal places could never be typed exactly. No real unit
  needs that, so it is left as documented.
- The unit suffix now also shows in free mode for count-like units. This
  is intended, per the PR's `decimal_qty?/1` comment.
