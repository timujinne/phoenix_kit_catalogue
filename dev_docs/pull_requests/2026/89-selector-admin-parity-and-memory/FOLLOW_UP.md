# PR #89 — Follow-up

Review: [CLAUDE_REVIEW.md](CLAUDE_REVIEW.md) (Claude via the boss,
post-merge, 2026-08-30). All three findings were fixed by the reviewer
in the same pass (`d8e545d`, shipped with 0.24.0), so this follow-up
records resolution rather than new work.

## Fixed (pre-existing)

- ~~BUG MEDIUM: a card could lose its only select target~~ — the select
  toggle keeps a `min-h-[1.5rem]` hit area while clickable
  (`browse.ex`, commit `d8e545d`); pinned both directions in
  `browse_components_test.exs`.
- ~~BUG MEDIUM: `Up` could point outside the scope and strand the
  user~~ — an unreachable parent climbs to the popup root
  (`item_selector_modal.ex` `level_up/2`, commit `d8e545d`); pinned in
  `item_selector_modal_test.exs`.
- ~~IMPROVEMENT MEDIUM: the category search re-ran on every scrolled
  page~~ — hits recompute only on a fresh fetch (`offset == 0`), commit
  `d8e545d`.

All three verified still present after the 2026-08-31 local batch
merged upstream (`c4e14f1`): the min-h class carries the batch's
loading-pulse addition alongside it, `level_up/2` keeps the
out-of-scope clamp under the catalogue-first level model, and the
fresh-fetch gate survived the multi-catalogue hits rewrite.

## Skipped (with rationale)

The review's own "Not fixed (deliberate)" list, kept deliberate:

- **The root's first fetch is thrown away** in `root_mode:
  "categories"` — keeps the Items switch instant; avoiding it would
  teach `BrowseState` a presentation mode. (Also true at the new
  catalogue-first root.)
- **The popup level table's uncategorized row hardcodes one trailing
  cell** — correct while `@level_columns == ["items"]`. Trigger to
  revisit: that list growing.
- **The index's auto mode engages on a whitespace-only query** —
  cosmetic; trimming must agree with the toolbar's debounce semantics.

## Files touched

| File | Change |
|---|---|
| `lib/phoenix_kit_catalogue/web/components/browse.ex` | select-toggle min hit area (`d8e545d`) |
| `lib/phoenix_kit_catalogue/web/components/item_selector_modal.ex` | Up clamp + fresh-fetch hits gate (`d8e545d`) |
| `test/web/browse_components_test.exs`, `test/web/item_selector_modal_test.exs` | pins (`d8e545d`) |

## Verification

Reviewer's gate: `mix precommit` clean, 2173 tests green (0.24.0).
Post-merge into the local batch (`c4e14f1`): `mix precommit` clean,
2 doctests + 2184 tests, 0 failures.

## Open

None.
