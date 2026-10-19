# PR #153 — follow-up

Triage of `CLAUDE_REVIEW.md` (Claude). No bugs; two IMPROVEMENTs and one
NITPICK, none changed.

## Fixed

None.

## Skipped (with rationale)

- IMPROVEMENT - MEDIUM — the dependency pop-up's full-item tree
  (`ItemFormLive` `dependency_open_picker`, `PlaceTree.places(items: true)`):
  fine at current volumes; the replacement is a search-driven picker, a UI
  decision. Trigger: opening the pop-up is slow on a large install.
- IMPROVEMENT - MEDIUM — per-reference queries in
  `Import.Executor.link_dependencies/3`: bounded per row by `DependencyCell`'s
  200-reference cap; batching needs a new lookup shape.
- NITPICK — `Dependencies.resolve_import_ref/2` trusts the caller's `type`:
  unreachable, `DependencyCell` limits it first.

## Files touched

None — triage only.

## Verification

Findings re-verified against `main` at the commit that carries this file.

## Open

None.
