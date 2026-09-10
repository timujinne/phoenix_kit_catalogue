# Follow-up Items for PR #7

Triaged against `main` on 2026-04-26. Three reviews on file (CLAUDE,
PINCER, AGGREGATED). PR #7 was the big "items belong directly to
catalogues" refactor and surfaced the most findings of any catalogue
PR. Many were addressed by PRs #10/#11; the rest are either cross-
cutting Phase 2 sweep targets on this branch, or out-of-scope perf
projects.

Items numbered per the CLAUDE_REVIEW (sections 1.x / 2.x / 3.x / 4.x /
5.x / 6.x).

## Fixed (pre-existing)

- ~~**1.1** `next_category_position` called outside transaction in
  `move_category_to_catalogue/3`~~ — PR #11 moved the call inside the
  transaction *after* the subtree move + `FOR UPDATE` lock. See
  `lib/phoenix_kit_catalogue/catalogue.ex:1240` and the inline comment
  block at `:1234-1240`.
- ~~**1.3** `move_item_to_category` missing `FOR SHARE` lock~~ — fixed
  in PR #10/#11. `resolve_move_attrs/1` (`catalogue.ex:2073`) now runs
  the lookup with `lock: "FOR SHARE"` (`catalogue.ex:1830`).
  Cross-checked: `create_item/2` and `update_item/3` use the same
  `put_catalogue_from_effective_category/2` helper at `:1734-1736`.
- ~~**1.4** `confirm_delete!` MatchError crash~~ — closed by PR #10's
  `unexpected_confirm_event/2` safe fallback. Verified at
  `catalogue_detail_live.ex:277, 385, 408` and
  `catalogues_live.ex:328, 360, 391`.
- ~~**2.2** `log_activity` silently discards all errors~~ — addressed
  by PR #10's `Catalogue.ActivityLog.log/1` which wraps the call in a
  `try/rescue` + `Logger.warning`. The Phase 2 sweep on this branch
  formalises this further with the canonical `log_activity/5` +
  `maybe_log_activity/5` helper shape (C4) and per-action
  ActivityLogAssertions tests (C9) so a regression in the rescue-path
  surfaces in CI.
- ~~**3.4** `swap_category_positions` doesn't re-fetch stale positions~~ —
  PR #11 moved the swap inside a transaction with the `:not_siblings`
  rejection. The reviewer's lock concern (concurrent swaps interleaving)
  is the same family as `move_category_under` TOCTOU — see PR #11's
  `FOLLOW_UP.md` for the joint resolution.

## Fixed (Batch 1 — handled by Phase 2 sweep on this branch)

The Phase 2 sweep on this branch is the right home for the cross-
cutting items below — extracting them as standalone Phase-1 commits
would force the same code through two passes.

- **3.2** `InfiniteScroll` JS hook duplicated inline across LVs
  (`catalogue_detail_live`, `events_live`, `catalogues_live`). Phase 2
  C6 converts to a `Phoenix.LiveView.ColocatedHook` shared by all
  three call sites — same pattern as `web/components/item_picker.ex`
  in PR #11.
- **5.2** `:deleted` mode misleading name in
  `list_categories_metadata_for_catalogue` — Phase 2 C6 either renames
  to `:with_deleted` or documents the intent in the @doc. Resolution
  decided during the sweep.

## Skipped (with rationale)

- **1.2** `restore_catalogue` / `restore_category` over-restores items
  individually deleted before the catalogue was trashed — INTENTIONAL
  per PR #11's restore semantics (the upward-cascade is documented as
  the contract). Distinguishing cascade-deleted from individually-
  deleted records would require a `deleted_by_cascade` boolean migration
  in core phoenix_kit, which is out of scope for the catalogue module
  sweep. Documented behavior, not a defect.
- **1.5** `deleted_count_for_catalogue` issues two queries — minor perf
  on a path that already fires 5+ queries per `reset_and_load`. The
  consolidation belongs to a broader detail-page query batching pass,
  not a per-PR follow-up. See item 3.3 below.
- **2.1** No authorization enforcement at the context layer — by design.
  Authorization happens at the LV `live_session :phoenix_kit_admin`
  on_mount hook + role check. The context module accepts an `actor_uuid`
  for activity logging only. Documented in the module @moduledoc; no
  change.
- **2.3** JSONB `?::text ILIKE ?` searches are unindexable — performance
  concern, not correctness. A real GIN/`pg_trgm` solution requires a
  core phoenix_kit migration (the underlying tables live in core). Out
  of scope per the
  [quality-sweep memory]the agent memory note `feedback_quality_sweep_scope.md`:
  "refactor existing paths; don't add missing features".
- **3.1** `load_filter_options` fetches up to 1000 rows — same family as
  2.3 (perf). The LV's filter dropdown surface today is small; if event
  volume grows past the 1000 threshold the symptom is "incomplete
  dropdown", not "incorrect data". Tracked but not fixed in this sweep.
- **3.3** `reset_and_load` fires 5+ sequential DB queries — perf concern
  matching 1.5 + 3.1. Consolidation into a single context fn
  (`catalogue_detail_summary/2`) is a refactor candidate but the
  current 5-query shape is not corrupting; out-of-scope for the quality
  sweep which is about pinning behaviour.
- **4.1** No concurrency tests for locking strategy — same pattern as
  PR #1 #12 (concurrency tests don't compose with Sandbox). Resolution
  is the ongoing transactional + DB-constraint approach, not a parallel
  test suite.
- **5.1** `next_category_position/1` is public but unsafe to call
  without a transaction — Phase 2 C6 / C13 documents this in the
  @doc + moduledoc. The function stays public because it's used by
  the form path to display the next available position before the
  user submits. Documenting the contract is the right fix.
- **5.3** `ok_or_rollback` exception-based rollback non-obvious — minor
  doc concern. The function is two lines and its behaviour follows
  Ecto's published rollback pattern. Adding a comment is bikeshedding.
- **5.4** `item_pricing/1` silently falls back to 0% markup — by design.
  The fallback is `Logger.warning`-logged and only triggers when the
  catalogue association can't be loaded (DB error during preload). The
  alternative is "price unavailable" which is worse UX. Documented
  behavior.
- **5.5** `set_translation/5` arity dispatch via `opts == []` — minor
  cleanup. Fixing it would require re-spreading `opts` through a
  handful of update functions; mechanical churn for no behaviour
  change.
- **6.x (nitpicks)** — `defp repo` indirection (testing concern, not a
  code defect), `summarize_metadata` truncation (UX, not data),
  `string_keyed?/1` on mixed-key maps (real-world impossible),
  `per_page` constants (intentional difference between item and event
  densities).

### Test gaps from §4 — handled by Phase 2 sweep

- **4.2** No `search_items` tests — Phase 2 C8 adds Search module tests.
- **4.3** `restore_catalogue` over-restore not tested — Phase 2 C8 adds
  a test that pins the documented "all deleted items in the catalogue
  come back" semantics, so the documented behaviour is the contract.
- **4.4** `item_pricing` fallback path not covered — Phase 2 C8 adds a
  unit test using a manually unloaded association.
- **4.5** `events_live` filter UI roundtrip — Phase 2 C10 adds an LV
  smoke test asserting filter values survive a `push_patch` round-trip.

## Files touched

None in this Phase 1 batch — all actionable items either resolved
upstream by PRs #10/#11 (verified above) or carried into the Phase 2
sweep where they get a coherent, sweep-wide fix rather than a
piecemeal per-PR commit.

## Verification

- All "Fixed (pre-existing)" claims grep-checked against current `lib/`.
- Carryover items mapped to specific Phase 2 C-steps.

## Open

None.
