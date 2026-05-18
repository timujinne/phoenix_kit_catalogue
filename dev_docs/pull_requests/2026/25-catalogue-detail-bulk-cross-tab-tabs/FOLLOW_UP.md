# FOLLOW_UP — PR #25 (Catalogue detail bulk + cross-tab)

Triaged 2026-05-18 against the post-merge state.

The CLAUDE_REVIEW.md already documents a "Follow-up commit (this
review's scope)" block listing what closed and what was deferred to
follow-on PRs. Re-verified each closure against current code in this
sweep.

## Fixed (pre-existing — closed by the review's own follow-up commit)

- ~~#1 (HIGH) — `restore_category/2` docstring rewritten~~ to match
  the no-cascade behaviour, mirroring the rewritten `restore_item/2`
  shape. Describes the no-cascade rule, the `:parent_catalogue_deleted`
  refusal, and that descendants / ancestors / items keep their
  statuses.
- ~~#2 (MEDIUM) — `bulk_restore_items/2` wrapped in
  `repo().transaction/1`~~. Body extracted to
  `do_bulk_restore_items/1` (`catalogue.ex:3115`); read +
  partition + writes now live in one transaction so the TOCTOU
  window vs `category.status` flips is closed. Verified at
  `catalogue.ex:3092-3097`.
- ~~#5 (LOW) — `do_bulk_move/4` filters `i.status != "deleted"`~~ on
  both clauses, restoring surface consistency with the other bulk
  fns and defending against a stale tab submitting a deleted UUID.
- ~~#6 (LOW) — `_scopes` payload dropped~~ from
  `broadcast_bulk_change`, which is now `/4` (was `/5`) — verified
  at `pub_sub.ex:163`. Receivers were already discarding the field
  via `_scopes`; the receiver-side `reset_and_load` semantics are
  documented on the broadcast fn instead.
- ~~#7 (NIT) — `loading: false` removed~~ from mount default assigns
  in `catalogue_detail_live.ex`. Only `search_loading` survives,
  which is alive. Verified — no bare `loading:` assign in the file.

## Skipped (with rationale)

- **#3 (MEDIUM) — N queries in `build_loaded_cards/5`** — deferred
  to its own PR per the review's follow-up table. Replacement is a
  single window-function query (`ROW_NUMBER() OVER (PARTITION BY
  category_uuid …)`) that touches the `Catalogue` query surface +
  introduces a new context fn. Real but not urgent at current
  admin sizes (~10 categories); linear in category count.
- **#4 (MEDIUM) — PubSub topic is a single global string** —
  deferred to its own PR. Migration touches `subscribe` + 4
  broadcast fns + 4 receivers + cross-tab tests, and has a
  back-compat angle if any external consumer subscribes to the
  legacy topic. Not a data leak today (the `cat_uuid` filter
  catches cross-catalogue traffic); the fix is messaging
  efficiency, not correctness.
- **#8 (LOW) — redundant `^target_uuid` pin** on the `:move_to`
  disposition match — stylistic only.
- **#9 (LOW) — `Process.sleep(1100)` in
  `list_deleted_items_for_catalogue/2` test** — suite-perf nit;
  cleanest fix is direct `Repo.update_all` on `updated_at` to
  fabricate the timestamp gap. Leave for the next test-suite
  pass.
- **#10 (LOW) — `:sys.replace_state/2` in `expand_timeout` test**
  — bypasses the actor model. Acceptable as a test-only workaround
  for this PR; flagged for the next refactor.
- **#11 (NIT) — `categories_bulk_bar` and `items_bulk_actions`
  could be unified** — note: a workspace-shared `<.bulk_actions_bar>`
  primitive now exists at `phoenix_kit/lib/phoenix_kit_web/components/core/bulk_actions_bar.ex`
  (added 2026-05-18 as part of the second-pass utility lift). Both
  catalogue bars could plug into it; tracking as a future migration
  rather than landing here so the test-touching surface stays
  small.
- **#12 (NIT) — `flash_reorder/3` naming** — `push_row_flash/3`
  would be clearer. Defer.

## Files touched

No new file changes in this triage pass — all closures had already
been committed by the post-merge follow-up. New entry: the workspace
gained a `<.bulk_actions_bar>` core component since this PR merged,
so the #11 unification path is unblocked when someone wants to fold
it in.

## Verification

Re-verified by code inspection 2026-05-18:

| Check | Result |
|---|---|
| `restore_category/2` docstring rewritten | confirmed in `catalogue.ex` |
| `bulk_restore_items/2` transactional | confirmed at `catalogue.ex:3092-3097` |
| `do_bulk_move/4` filters `status != "deleted"` | confirmed (multiple sites in `catalogue.ex`) |
| `broadcast_bulk_change/4` (was `/5`) | confirmed at `pub_sub.ex:163` |
| `loading: false` removed | confirmed; only `search_loading` remains |

`mix test` not re-run in this sweep — the post-merge tests cover the
closed paths; no new code introduced here.

## Open

- **#3** — window-function query for `build_loaded_cards/5`. Wants
  its own PR.
- **#4** — per-catalogue PubSub topic. Wants its own PR (broadcast
  + subscribe + receiver edits + cross-tab tests).
- **#11** — fold catalogue's two bulk bars onto the new core
  `<.bulk_actions_bar>` when convenient. Test surface modest.
