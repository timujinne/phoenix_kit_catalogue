# PR #119 follow-up

| Finding | Severity | Resolution |
|---|---|---|
| Nothing ran the plan through core's real engine | IMPROVEMENT - MEDIUM | Fixed: "end to end through core's Reorganizer engine" in `test/phoenix_kit_catalogue/media_reorganizer_test.exs` (skipped on a core without the engine) |
| "(N)" suffix rule looser than core's | NITPICK | Fixed: `suffixed_variant?/2` accepts only `N >= 2` without a leading zero, as core's `Action.matches_name?/2` does |
| Stale comments about core | NITPICK | Fixed: the moduledoc and `media_reorganizer/0` name 2.24.0 and core's `Source` moduledoc |
| Delete-guard test broke on entities 0.4.15 (release fix) | — | Fixed: the test clears guards in either storage form and checks them through `Managed.validate_delete/2` |
| No `@behaviour` / `@impl` | — | Skipped, as the review decided: the `phoenix_kit` floor (`>= 2.13.11`) predates the callback, and registry lookup is by function name. Revisit once the floor passes 2.24.0 |

Shipped in 0.33.0 (`d687dc8`). Re-verified against current `main` on
2026-09-17.

## Open

None.
