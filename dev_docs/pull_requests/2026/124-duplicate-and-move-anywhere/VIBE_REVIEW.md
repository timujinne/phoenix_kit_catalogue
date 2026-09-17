# PR #124: Duplicate a catalogue, move anything to any catalogue, and fix the picker's missing photos — Vibe review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/124
**Reviewer**: Vibe (Mistral Devstral 2), no tools; answered from a short brief
**Date**: 2026-09-17
**Scope**: two rounds: the design draft before `da871e4`; a UX review of the Duplicate dialog, the bulk Move modals and the edit forms' Move cards at `c2116b6`

## Round 1: design of Duplicate catalogue

1. **Archived until review.** Duplication is a large, fallible operation; starting archived prevents accidental use of an incomplete or incorrectly linked copy.

2. SKUs: **keep verbatim** (non-unique, acceptable). Slugs: **generate unique now** (empty slugs break URLs; a whole catalogue must be immediately usable).

3. **REPEATABLE READ snapshot without the lock.** Long transaction risks timeout; lock held for a minute blocks source operations. What breaks with others: one transaction may exceed timeouts; chunked commits leave partial, inconsistent state needing cleanup.

4. Hard-deleting a file breaks both catalogues; reordering affects both; featured image deletion affects both. Copying bytes is only worth it for true independence; FolderLinks with documented shared dependency are the practical choice.

5. **Nullify all references** that point inside the source catalogue (e.g., featured_item_uuid). The duplicator cannot understand sibling namespaces, so it must drop or nullify them; modules owning namespaces should provide callbacks for remapping if needed.

6. **Name collision** if "X (copy)" already exists; **shop misrouting** if the original is renamed to match the copy's name or vice versa.

7. Dangling internal references > slugs not generated > no name collision handling > no large-catalogue strategy.

## Round 2: UX review (`c2116b6`)

Questions: wording a non-technical user would misread; same status vs archived for a copy; missing affordances; anything else.

1.
- "Deleted items" → "Previously deleted items"
- "Removing one from the copy" → "Removing an image from the copy"
- "(this catalogue)" → "(current catalogue)"
- "Move to Another Parent" → "Move to another category"

2.
- Same status: matches user expectation of a true, ready-to-use copy.
- Hidden/archived: prevents accidental publication of unchecked duplicates.

3.
- No link from the success flash to the new copy.
- No undo for duplicate or bulk move.
- Bulk move doesn’t state whether items are moved (removed from source) or copied.

4.
1. Duplicate: warn that SKUs will be duplicated (risk of future conflicts).
2. Bulk move: add a dry-run preview showing exactly where each item will land.
3. Inconsistent capitalization: “Another Category” vs “another catalogue”.
