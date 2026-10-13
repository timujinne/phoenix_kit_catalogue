# Follow-up — PR #147 and #148

| Finding | Resolution |
|---|---|
| #148 BUG - MEDIUM: nested rollback from a refused folder move | Fixed: `free_name/3` returns `nil`, `relocate/4` skips the write. Test added in `media_folders_test.exs`. |
| #148 IMPROVEMENT - MEDIUM: items' folders after hard `delete_category`/`delete_catalogue` | Not changed — documented behaviour, files stay reachable by pointer. |
| #148 NITPICK: bulk-move query bound | Raised 400 → 800 with the reason in the test comment. |
| Suite red on HEAD (core 2.62.2 drops the locale segment on single-language sites) | `test/test_helper.exs` turns the test site multilingual with the prefix kept; `Test.Router` serves both `/en/admin/...` and `/admin/...` in one live session. 3719 tests green. |
| #147 | No findings. |

## Codex independent recheck — 2026-10-13

Details: [CODEX_REVIEW.md](CODEX_REVIEW.md).

| Finding | Resolution |
|---|---|
| Refused folder cycle still aborts bulk category trash | Fixed: validate under the tree lock and return refusals without nested rollback; statement savepoints protect writes. |
| Occupied deterministic release name leaves deleted files adoptable | Fixed: choose a free UUID-suffixed name and preserve intervening manual folder changes. |
| Translated namesakes with different base names miss SKU suffixes | Fixed: include translation names in scoped candidates and confirm through the canonical resolver. |
| Name plus SKU can exceed core's folder-name length limit | Fixed: use the deterministic name when the generated name exceeds 255 characters. |
| Explicit naming hook does not follow or release root folders | Fixed: allow a nil parent when only naming is managed by this module. |
| Bulk-move query ceiling depends on locale/settings reads | Strengthened: separately assert one media-folder UPDATE for 100 items. |
| Pagination test's 100ms async wait fails under load | Fixed: explicit five-second waits retain all pagination assertions. |

Validation: `mix test --seed 342308` passed 2 doctests and 3,724 tests with zero
failures, integration tests enabled. `mix precommit` passed. Recorded under
Unreleased; no new Hex release or tag was created.
