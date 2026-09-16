# PR #117 follow-up

How each finding in `CLAUDE_REVIEW.md` was resolved, verified against the code
first.

## Fixed (2026-09-15, release 0.32.0)

- ~~BUG - MEDIUM — `CatalogueBrowse` accepted "comfy" and rendered nothing.~~
  - `CatalogueBrowse` now renders "comfy" as its table inside a `pk-comfy`
    wrapper, like the modal.
  - Its `set_view` guard accepts "comfy", and the moduledoc says so.
  - Its own toggle still offers only table and card.
  - Pinned: "comfy renders the table with the pk-comfy marker"
    (`test/web/catalogue_browse_test.exs`).
- ~~NITPICK — test names cite source line numbers.~~ Removed from both test
  files; the names describe the behaviour instead.

## Skipped (with rationale)

- **Two vocabularies for the same modes.** Aligning the labels means renaming
  msgids in six catalogues for a tooltip. Worth doing when the admin toggle and
  the selector toggle are unified.
- **The comfy skeleton rows keep the compact height.** Cosmetic, and only
  visible during the first page load.

## Files touched

| File | Change |
|------|--------|
| `lib/phoenix_kit_catalogue/web/components/catalogue_browse.ex` | renders and accepts "comfy" |
| `test/web/catalogue_browse_test.exs` | comfy pin |
| `test/web/set_view_guard_test.exs`, `test/web/item_selector_modal_comfy_test.exs` | line numbers dropped from names and docs |

## Verification

- The four affected test files: 99 tests, 0 failures.
- Full suite 2881 tests + 2 doctests, 0 failures; `mix precommit` clean
  (format, compile --warnings-as-errors, credo --strict, dialyzer).

## Open

None.
