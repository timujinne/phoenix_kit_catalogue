# PR #148 — Independent recheck of release 0.48.0

- Reviewer: Codex
- Date: 2026-10-13
- Scope: merged PR `fe9ce40`, release fix `723e85b`, attachment resolution,
  context mutation callers, and core storage implementations.

Five additional bugs reproduced and fixed. Claude's name-exhaustion fix is
correct, but does not cover every refused folder operation.

## BUG - HIGH — a refused cycle still rolls back bulk category trash

Move the target category's media folder inside an item's folder, then bulk-trash
the item's source category with `items: {:move_to, target_uuid}`. Core refuses
the folder cycle by rolling back its transaction. Because `follow/2` runs inside
the bulk-trash transaction, the result is `{:error, :rollback}` and the intended
catalogue mutation is lost. Rescue/catch cannot make a tainted transaction usable.

Fixed: single-folder moves take core's folder-tree lock before name locks, check
the live parent, library and cycle invariants, and return refusals as values.
The folder changeset write uses a statement savepoint for constraint failures.
The existing bulk path still moves folders with one UPDATE. The regression
asserts the actual bulk-trash operation commits while the refused folder stays.

## BUG - HIGH — an occupied release name leaves old files adoptable

Create a folder using the deleted item's deterministic name under the same
parent. `release/1` previously attempted that name once, logged the uniqueness
error, and left the old folder named after the deleted item. A new item of the
same name could then resolve that now-unclaimed folder and inherit its files.

Fixed: release chooses a free name under the tree/name locks: the deterministic
name, then a folder-UUID suffix, then a fresh UUID suffix. It rechecks the folder
against the plan to preserve an intervening manual rename/move, and uses the same
savepoint-backed write. The regression verifies the occupied folder is untouched
and a replacement item gets a separate folder.

## BUG - MEDIUM — translated namesakes are filtered out before comparison

An English `Bolt` and an Estonian `Polt` translated to `Bolt` are namesakes in
the site's language. The SQL prefilter compared only base columns, so neither
received its documented SKU suffix.

Fixed: the scoped candidate query includes stored translation names, then uses
the canonical translation resolver to confirm the match. It retains the live
status, catalogue and category scope. The regression checks both naming results.

## BUG - MEDIUM — a valid item name plus SKU exceeds the folder limit

A 255-character item name is valid, but appending ` (<sku>)` exceeds core's
255-character folder-name limit. The hook returned a name storage could not
create and could also refuse during a move.

Fixed: generated readable names respect the storage limit and fall back to the
deterministic name. This applies to translated names and category/catalogue
names too. Move candidates also skip overlength names. The regression verifies
the naming result and an actual attachment write.

## BUG - MEDIUM — explicit name hooks skip folders at the media root

With the explicit `MediaFolders.folder_name` hook and a host parent hook returning
`nil`, `hooked?/4` required a binary parent UUID. Such folders neither followed a
rename nor released their names after deletion.

Fixed: root folders qualify when only the naming hook is managed by this module.
The regression checks rename and delete behavior for that supported configuration.

## IMPROVEMENT - MEDIUM — prove batching independently of settings-query cost

The 800-query bound remains, and telemetry now separately requires exactly one
UPDATE of the media-folder table for the 100-item bulk move. Settings-cache and
locale changes can no longer hide a regression to one folder write per item.

## Compatibility and retained behavior

Verified the storage APIs used by the original code and these fixes against
core's `v2.38.0` source; the dependency floor remains valid. Hard parent deletion
continues to retain surviving items' media folders and files, as documented.
Compared all 120 published source files (including `mix.exs`) in Hex's 0.48.0
tarball with `v0.48.0`; they match the tagged release exactly.
The published `0.48.0` package and tag remain unchanged; these are follow-up fixes.

## Validation

The unmodified release passed 3,719 tests. The four initial new regressions failed
before their fixes; the release-name collision failed separately before its fix.
All 55 media-folder tests pass after the fixes, including the one-UPDATE bulk
move assertion. The first full follow-up run found one unrelated 100ms async
pagination-test timeout, reproduced in isolation and corrected without changing
pagination code (see the #147 review).

Final verification:

- `mix test --seed 342308`: 2 doctests, 3,724 tests, zero failures; integration
  tests enabled. This is the same seed as the run that exposed the async timeout.
- `mix precommit`: passed compilation with warnings as errors, unused-lock
  checks, Hex audit, formatting, strict Credo and Dialyzer.
- `git diff --check`: passed.
