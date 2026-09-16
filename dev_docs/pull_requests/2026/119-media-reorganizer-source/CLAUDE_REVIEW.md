# PR #119: Media reorganizer source: plan legacy folder moves from the attachment hooks — Claude review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/119
**Author**: timujinne
**Reviewer**: Claude (Opus 5), release review
**Date**: 2026-09-16
**Scope**: merge `e69d70a` (`2a19405..e69d70a`): `MediaReorganizer`,
`PhoenixKitCatalogue.media_reorganizer/0`, `Attachments.legacy_folder_name/1`
and the test file. Checked against core's `Reorganizer.Source` moduledoc and
engine as shipped in phoenix_kit 2.24.0, which the `lib upgrades` commit
(`329dd05`) locked.

PR #120 was already reviewed and shipped in 0.32.0
(`120-open-follow-up-items/`), so this release adds no new review of it.

## Summary

The PR went through five review rounds before it merged, and it shows. Every
rule in core's `Source` contract has a matching clause and a test: parent-hook
failures versus an explicit root answer, the `nil`-root guard, claims that
don't depend on a hook, a full-row reload before any hook call, batched
lookups, deterministic order, and counts that include trashed files. The
PDF-hook call shape (`[:pdf, actor, :pdf]`) matches
`Attachments.parent_folder_uuid/2`. The pointer back-fill locks the row, skips
a record that was deleted in the meantime, and writes only
`data["files_folder_uuid"]`. No correctness bugs found.

## Findings

### IMPROVEMENT - MEDIUM — nothing ran the plan through core's real engine

Every test inspected `plan/2`'s raw maps. None checked that they pass
`Action.new!/1`, that the engine applies the move and runs `after_move` in its
transaction, or that a second run is a no-op. The PR was written before core
shipped the engine, so it couldn't have. Core 2.24.0 is now locked.

**Fixed:** a new test, "end to end through core's Reorganizer engine", runs
`Reorganizer.run(nil, apply?: true, sources: [MediaReorganizer])` on a legacy
root folder. It checks the move to the parent the hook returns, the rename,
the pointer back-fill, and that a follow-up dry run plans nothing for the
item. It is skipped on a core without the engine, because the pin floor is
older.

### NITPICK — "(N)" suffix rule looser than core's

`suffixed_variant?/2` accepted any `\d+`. Core's `Action.matches_name?/2`
accepts only `N >= 2` with no leading zero, because that is all
`on_conflict: :suffix` generates. **Fixed** to use core's rule. In practice
this branch can't be reached (the folder it checks is either the exact host
name or the legacy `catalogue-<kind>-<uuid>` name), so no test pins it.

### NITPICK — stale comments about core

The moduledoc and `media_reorganizer/0` comment said core "2.23.x does not ship
the engine yet". The moduledoc also cited
`2026-09-15-media-reorganizer-design.md`, which exists in neither this repo nor
core. **Fixed:** the comments now name 2.24.0 and point to core's `Source`
moduledoc.

### Release fix (not #119) — delete-guard test broke on entities 0.4.15

The `lib upgrades` lock bump brought in phoenix_kit_entities 0.4.15. That
release stores each owner's delete guard under its own `:persistent_term` key
(`{Managed, :delete_guard, owner}`) instead of one shared map, which is the
fix for the #120 race. "register/0 registers both guards while entities is
disabled" read the old shared map directly, so it saw `[]` and failed. The
guards themselves still register. **Fixed:** the test clears guards in either
storage form, asserts `:no_delete_guard` first, then checks both owners
through the public `Managed.validate_delete/2`.

### Not changed — no `@behaviour` / `@impl`

With 2.24.0 available it's tempting to declare
`@behaviour PhoenixKit.Modules.Storage.Reorganizer.Source` and
`@impl PhoenixKit.Module`. The `phoenix_kit` floor is still `>= 2.13.11`, and on
an older core both would give compile warnings in a host. Registry lookup is by
function name, so nothing is lost. Leave it until the floor passes 2.24.0.
Raising the floor just for this isn't worth it.
