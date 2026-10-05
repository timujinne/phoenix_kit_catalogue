# PR #130 — View for catalogues and categories, readable activity events — follow-up

Triage of `CLAUDE_REVIEW.md` (4 findings) against `main` at `e8a969f` (0.46.1).

## Fixed (pre-existing)

- ~~BUG HIGH — the PR needed a core that was not on Hex (`Activity.split_changes/1`, `humanize_metadata_key/1`, `swap=` on `bulk_select_scope`): the floor is `>= 2.38.0 and < 3.0.0` (`mix.exs:132`, with the 2.34.0 history in the comment above it), the lock is at 2.41.2 (`mix.lock:69`), and `test/core_pin_conformance_test.exs:41-42` rejects 2.34.0 and below — floor raised to 2.34.0 in commit `f774359`, to 2.38.0 in `45e7d6e`.~~
- ~~IMPROVEMENT MEDIUM — the link conformance test could not see a missing resource type: `test/activity_resource_links_test.exs:59-80` scans `lib/` for logged `resource_type`s and requires each to be linked or named in `@unlinked` — commit `b1c0f72`.~~

## Skipped (with rationale)

- NITPICK — the index's View card is not closed on navigation. The review asked for no change and recorded it "in case the index grows a way to navigate with the card open". Re-checked after the toolbar rework: `CataloguesLive` still sets `card_open` only in `show_catalogue_card` (`lib/phoenix_kit_catalogue/web/catalogues_live.ex:2292`) and clears it only in `card_close` (`:2310`), and the card is still a modal over the page, so nothing under it is reachable. **Trigger to revisit:** any way to patch or navigate the index while the card is open (a link inside the card that patches the same LiveView, or a non-modal card).

## Files touched

None — triage only, no code changed.

## Verification

Each finding re-read against `main` at `e8a969f` on 2026-10-05 (grep + reading the cited lines; `git log -S` for the commits). `mix precommit` and `mix test` were not run in this pass — nothing was changed.

## Open

Awaiting Max's decision:

- **NITPICK — `attribute_group.attribute_added` / `.attribute_removed` rows are titled with the attribute's name but link to the group.** `lib/phoenix_kit_catalogue/catalogue/attributes.ex:287-292` and `:359`: the row logs `resource_type: "attribute_group"`, `resource_uuid: group.uuid` and `metadata: %{"name" => attribute.name, ...}`, so the Events deep link reads as the attribute and opens the group. Usable, mislabelled. Fixing means logging the group's name as `"name"` and the attribute under its own key (e.g. `"attribute"`) in both rows, and updating whatever test pins the metadata; older rows keep the old shape.
