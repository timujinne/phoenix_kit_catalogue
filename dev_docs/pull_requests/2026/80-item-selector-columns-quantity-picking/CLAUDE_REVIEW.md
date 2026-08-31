# PR #80: Item selector table/card views with a host columns contract, quantity-first picking, and the stuck-in-trash detail fix

**Author**: @mdon
**Reviewer**: Claude (post-merge diff review, `elixir:phoenix-thinking` applied), every claim independently re-verified against current `main`
**Date**: 2026-08-26
**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/80

## What changed

`ItemSelectorModal` grows a table view (default, built from core's `table_default` family) alongside the existing photo-card grid, gated by a host-granted `columns` contract on `Browse` (`:price` selling vs opt-in raw `:base_price`, headerless `:breadcrumb` prefix, viewer-facing Columns dropdown with pinned identity/`:qty` columns). Adds `selection_mode: "quantity"` (order-sheet flavour — entering a positive quantity is the selection, zero removes the line) and an `Uncategorized` chip so category chips add up when loose items exist. `catalogue_detail_live.ex` stops dumping the admin into the Deleted view when a category's last active item is removed (the populated-tab auto-pick no longer overrides an explicit tab choice on reload).

The PR also carries its own separate hardening pass, recorded in `dev_docs/design/2026-08-25-popup-components-quorum-review.md`: a multi-agent quorum review (codex, zai, gemini, grok) that found and fixed 20 real defects with tests before merge — native-submit-on-Enter, server-side enforcement of excluded/disabled rows, non-UUID scope crashes, contradictory `:only` narrowings, confirm-with-nothing-selected, unclamped preselect quantities, `:single`-mode multi-preselect, soft-deleted-parent re-checks, and more.

## Review approach

Given the PR already shipped with an unusually thorough internal review, this pass treated the quorum doc's claims as hypotheses to re-verify, not facts to trust, and independently traced the highest-risk areas end to end against the actual code (not the doc's description of it):

- **Columns contract** — `Browse.table_columns/0` / `resolve_columns!/2` (raise-on-unknown) vs every in-repo caller; no call site can pass an unlisted column, so no leak is possible today.
- **Gettext parity** — `default.pot`/en/et/ru have identical msgid counts (953 each); spot-checked all new viewer-facing strings (Qty, Base price, Category prefix, Photo, List view, Uncategorized, No items found, Not available in this selection) exist with real translations in all three `.po` files, not just the template.
- **Quantity state machine** — traced `commit_qty` / `commit_first_qty` / `step_qty` / `clamp` / `parse_qty` end to end for the zero-invariant, ceiling, and precision-rounding paths.
- **Stuck-in-trash fix** — traced `load_url_state_level` vs `switch_view` against `pick_view_mode` / `level_node_key`: entering a new node re-triggers auto-pick, reloading the same node (delete/restore/reorder) preserves the user's tab, manual tab switches stick. Matches `catalogue_detail_empty_category_test.exs` exactly.
- **ItemPicker contract** — `test/support/selector_host_live.ex` and `item_picker_guards_test.exs`'s `HostLive` both implement the real `{:item_picker_select, id, item}` / `{:item_picker_clear, id}` clauses the component actually sends; not a simplified stand-in.
- **Iron Law / PubSub / N+1** — no DB queries added to any `mount/3`; no PubSub topic changes; `presented_category/2` relies on `category` being preloaded, confirmed via `Search.search_items/2` (`[:catalogue, category: :catalogue]`) and `list_items_by_uuids/2` (`[:catalogue, :category]`) — not a silent `NotLoaded` swallow.
- Confirmed the two "closing" commits referenced by the quorum doc (`fb5c28d`, `8dc2a9f`) are inside this PR's own merged range, so the shipped diff already reflects them.

## Findings

None. No correctness bugs, contract leaks, or convention violations found. This is a clean pass on top of an already-hardened PR.

## Gate

`mix precommit` clean (see below). `mix test` clean (see below).
