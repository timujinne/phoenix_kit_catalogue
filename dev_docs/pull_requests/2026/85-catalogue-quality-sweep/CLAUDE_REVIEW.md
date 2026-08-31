# PR #85: Quality sweep — silent form validation, an unlocked reorder, one-page infinite scroll, and a gettext correction

**Author**: @mdon
**Reviewer**: Claude (`elixir:phoenix-thinking` + `elixir:ecto-thinking` applied before reading source)
**Status**: Merged
**Commit**: `709630e` (merge of `d8ed07c..cac652f`)
**Date**: 2026-08-29
**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/85
**Reviewed as part of**: the 0.22.0 release sweep, together with [#86](/dev_docs/pull_requests/2026/86-search-modes-and-category-browser) and [#87](/dev_docs/pull_requests/2026/87-drilled-mixed-view-and-images).

## What changed

A codebase-wide quality sweep, plus triage of twenty untriaged PRs into per-PR `FOLLOW_UP.md` files. The substantive code changes: a race fix in the attribute-set attachment reorder, three N+1 fixes, two broadcasts that reported the wrong thing, silent form-validation failures on the item and category forms, a path-traversal hardening on upload filenames, and a correction to this repo's own claim that gettext extraction was unsafe here.

This PR already carries its own findings record in `dev_docs/QUALITY_SWEEP_2026-08-29.md` (including `cac652f`, "Record what the panel found, including where my diagnosis was wrong"), so this document only covers what a fresh post-merge read added.

## Findings

No defects found; no code changed for this PR.

## Not defects on verification

- **`reorder_attachments/3`'s widened return type.** The `@spec` went from `:ok` to `:ok | {:error, term()}` when the body moved inside `repo().transaction/1`. Widening a return type is the shape that silently breaks a caller that pattern-matched the narrow one, so I checked all of them: the single production caller (`item_form_live.ex:2341`, through the `Catalogue.reorder_attribute_sets/3` delegate) discards the result, which matches the stated "best-effort doctrine — a failure here is logged and skipped, never fails the item save" governing that whole block. The two test call sites use `:ok = …`, which is the right assertion for a test. Nothing crashes on the new branch.
- **The reorder fix is the right one.** It was a check-then-act on a non-primary-key column with no transaction: two saves of the same item interleaved their per-row `update_all`s, and a mid-loop failure left half the attachments renumbered with nothing to roll back. It now reads, compares and writes inside one transaction under a per-item advisory lock — the same mechanism `lock_set/1` already used, keyed by item instead of by set.
- **`broadcast: false` roll-up.** `maybe_broadcast_item/2` lets an item save attach, detach, reorder and write selections without firing an `:item` broadcast (and its own `item_catalogue_uuid/1` SELECT) per change, with one roll-up at the end gated on `sets_changed?/4`. The convention already existed in `import/executor.ex`. The gate matters: an unconditional roll-up handed every open detail LiveView a second `:item` event on a name-only save, on top of the one `update_item/3` had just sent — the comment records exactly that, so the fix was verified against the symptom, not assumed.
- **Upload filename hardening.** `entry.client_name` is browser-supplied and only checked against `:accept`, so `Path.basename/1` before it reaches `Storage.store_file_in_buckets/6` is correct. The accompanying comment is honest that `ext` was already safe (`Path.extname/1` cannot return a separator) rather than overstating the fix. Note this hardens the *filename*; `elixir:phoenix-thinking`'s related warning — that `%Plug.Upload{}.content_type` is user-provided and shouldn't be trusted for security decisions — still applies to `file_type_from_mime(entry.client_type)`, which is pre-existing and used for classification rather than as a security gate.
- **`list_values_for/2` becoming public.** The gating is right: it was private with one caller that had already checked `entities_enabled?()`, and promoting it to the public surface would have put a read there that answers with live data while every sibling read degrades to `[]`/`nil`/`%{}`/`0` with the feature off. The new `if entities_enabled?()` wrapper restores the module's documented contract and also guards the fallback branch from calling into `PhoenixKitEntities.EntityData` when it isn't loaded.

## Gate

Covered by the sweep-wide run recorded in [#87's review](/dev_docs/pull_requests/2026/87-drilled-mixed-view-and-images/CLAUDE_REVIEW.md): `mix precommit` clean after the credo fix recorded there, `mix test` 2110 tests / 0 failures with a live Postgres.

## Related

- Findings record: `dev_docs/QUALITY_SWEEP_2026-08-29.md`
- Follow-up: [#86](/dev_docs/pull_requests/2026/86-search-modes-and-category-browser)
