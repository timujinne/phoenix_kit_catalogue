# PR #125 follow-up

How each finding in `CLAUDE_REVIEW.md` was resolved. Applied on `main` after
the merge, shipped in 0.37.0.

| # | Finding | Resolution |
|---|---|---|
| 1 | BUG - HIGH. The merged branch fails `mix precommit` (dialyzer `call_without_opaque` on `category_path/3`'s `MapSet`) | **Fixed.** `visited` is now a plain map used as a set — one uuid per level of category nesting, so no worse — and the parent uuid is derived with `if` rather than `&&`, which widened to `false \| nil \| binary()` on an untyped map field. Cycle-guard semantics unchanged; `mix dialyzer` back to the repo's 15/15 baseline. Confirmed against the pristine merge that this was the branch's own regression. |
| 2 | BUG - MEDIUM. NULL item `position` sorted first, not last | **Fixed.** `Browse.present_items/2` no longer coerces `nil -> 0`; `position_key/1` now actually sees the null and applies Postgres-style nulls-last, matching `Search.apply_search_order/2`'s `asc: i.position`. Presented-map doc updated to `position: 0\|nil`. |
| 3 | IMPROVEMENT - MEDIUM. `catalogue_sort_key/2` missing the uuid tie-break | **Fixed.** Key is now `{position, name, uuid}`, as `Search.apply_search_order/2` has it. All three return paths are 3-tuples — Erlang compares tuples by size first, so a mixed arity would dominate the key instead of tie-breaking inside it. |
| 4 | BUG - MEDIUM. Category-only scope spanning several catalogues loses tree order | **Not fixed; documented.** A correct fix needs both a derived sort index and a catalogue list, without growing tiles the host never asked for and without listing every category of every catalogue for an unrestricted scope — feature work, and the shape has no caller here. It is also the only shape where the popup draws no tree at all. The moduledoc now states the limitation and the workaround (pass `:catalogue_uuids` too). |
| 5 | NITPICK. Moduledoc inaccuracies in the pick-order contract | **Fixed.** The bucket is per catalogue, not per category; the third ("category gone") bucket and the null-position rule are now stated; the catalogue key reads `{position, name, uuid}`. |

## Tests added

Both in `test/web/item_selector_modal_test.exs`, in the PR's own
`"confirm payload follows the catalogue's own tree order (2026-09-17)"`
describe block. Each was verified to **fail** against the pre-fix code and pass
after:

- `"an item whose position is NULL sorts LAST, not first"` — NULLs the
  earlier-positioned, alphabetically-first item behind the changeset, so both a
  `nil -> 0` default and a name sort fail it.
- `"two catalogues tied on position AND name still arrive as one block each"` —
  two same-named catalogues forced to position 0, two items each; asserts the
  picks are contiguous per catalogue and that the blocks follow uuid order.

## Gate

`mix test` 2 doctests / 3080 tests / 0 failures. `mix precommit` clean — run it
**unpiped**: `mix precommit | tail` swallows dialyzer's non-zero exit, which is
how the merge's failing gate went unnoticed.
