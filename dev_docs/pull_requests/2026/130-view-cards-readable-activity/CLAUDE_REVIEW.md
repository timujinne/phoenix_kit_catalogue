# PR #130: View for catalogues and categories, readable activity events — Claude review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/130
**Author**: @mdon (Max Don)
**Reviewer**: Claude Fable 5.1 — post-merge pass
**Date**: 2026-09-20
**Merge**: `cf6df93` (`80944aa..f7a98bf`), 25 files, +1549 / −134
**Status**: reviewed; 1 test gap closed; finding 1 resolved in 0.42.0 (core floor raised to 2.34.0)

## Scope

1. **View cards one level up.** `ProductCard` takes a `%Catalogue{}` and a
   `%Category{}` as well as an `%Item{}`: one render, three field builders,
   all behind the same `:admin` opt-in. `show_catalogue_card` on the index,
   `show_category_card` on the detail page (scoped through
   `category_in_catalogue`); the old "View" link to the detail page is now
   "Open". A drill closes the card.
2. **Activity that says what changed.** `.updated` rows carry a reserved
   `"changes"` map (`ActivityLog.with_changes/4`), moves carry snapshotted
   `{uuid, label}` refs instead of bare uuids, bulk moves cap their uuid
   list, supplier rows name the pair they are about. `resource_links/0`
   adds path templates for seven resource types. `EventsLive` summarizes
   through core's `Activity.split_changes/1` + `humanize_metadata_*`.
3. **Row names at `text-base`** through one `name_cell_class/0`.
4. **Bulk bar swaps the controls row** (`swap=` on `bulk_select_scope`)
   instead of pushing rows down.

## Findings

### 1. BUG - HIGH — the PR needs a core that is not on Hex

`EventsLive` calls `PhoenixKit.Activity.split_changes/1` and
`humanize_metadata_key/1`, the detail page passes `swap=` to
`bulk_select_scope`, and `test/events_summary_test.exs` asserts core renders
a `{uuid, label}` ref as its label. All of that is phoenix_kit **#837**,
merged to core `main` (`7ecb0b29`) on 2026-09-20 but unreleased — Hex latest
is 2.33.0, and core's `@version` is still 2.33.0 with no CHANGELOG entry.

Against the locked Hex core (2.33.0), verified:

- `mix compile --warnings-as-errors` fails: two undefined `Activity`
  functions, two undefined `swap` attributes. So `mix precommit` fails.
- `mix test test/events_summary_test.exs test/web/events_live_test.exs`:
  **6 of 10 fail** — the Events page raises `UndefinedFunctionError` on
  mount for any entry that has metadata. On a host this is the whole
  Events tab down, on every core the current floor (`>= 2.13.11`) admits.
- The bulk bar silently keeps its old behaviour (unknown attr is ignored).

Against core `main` (`PHOENIX_KIT_PATH=../phoenix_kit`): 3195 tests, 0
failures.

**Not fixed here, deliberately.** A `function_exported?` fallback in
`EventsLive` would fight the design — the tests, the ref shape and the bulk
swap all assume the new core, and a second rendering path for old cores is
code nobody would exercise. The right fix is the pin: raise the floor in
`mix.exs` (and `@must_admit` / `@must_reject` plus the moduledoc in
`test/core_pin_conformance_test.exs`) to the core release that carries
#837. That version number does not exist yet, so the change belongs to the
release commit. **Order: release core → `mix deps.update phoenix_kit` →
raise the floor → precommit + test → publish the catalogue.** Until then
the catalogue must not be published: 0.41.x from this tree would crash the
Events page for every host.

**Resolved 2026-09-20.** Core 2.34.0 shipped #837. The lock moved to 2.34.0
and the floor is now `>= 2.34.0 and < 3.0.0` (`mix.exs`,
`test/core_pin_conformance_test.exs`, AGENTS.md); released as 0.42.0.

### 2. IMPROVEMENT - MEDIUM — the link conformance test could not see a missing type (fixed)

"every catalogue resource type a person can open has a path" iterates
`record_link_types/0`, i.e. the map's own keys, so a logged type that was
never added passes trivially. The module logs thirteen resource types and
links seven. Added a test that scans `lib/` for `resource_type: "…"` and
requires each to be linked or named in an explicit `@unlinked` list
(`manufacturer`, `supplier`, `smart_rule`, `attribute_set`,
`supplier_field`, `module` — none has a page of its own here), and that
neither list names a type no longer logged.

### 3. NITPICK — `attribute_group.attribute_added/removed` title

Those rows log `resource_uuid: group.uuid` with `"name" => attribute.name`,
so the new deep link reads as the ATTRIBUTE's name and opens the GROUP. It
lands on the page that shows the attribute, so it is usable; a `"group"`
name in the metadata would make the title honest. Left alone.

### 4. NITPICK — index card is not closed on navigation

The detail page resets `card_open` when the level changes; `CataloguesLive`
only clears it on `card_close`. A modal blocks the page under it and core
#837 fixes the dismissal the server never heard about, so nothing is
reachable today. On record in case the index grows a way to navigate with
the card open.

## Checked and fine

- Identity `"name"` stays a scalar under a rename (`"changes"` is a
  reserved key), so the `:metadata.name` title template never sees a map;
  an empty supplier-row name falls back to core's `<type> <short-uuid>`.
- Ref labels are resolved after the transaction returns, so the rescued
  getters cannot poison one. Cost is 2–4 point reads per move and one per
  supplier-row log; no bulk path goes through `identity_metadata/1`.
- No reader of the dropped flat keys (`from_*_uuid`, `old_cost`, …) remains
  in `lib/` or `test/`; older rows still render through `summarize_rest/1`.
- `show_catalogue_card` / `show_category_card` take client uuids through
  the context getters / `category_in_catalogue`, and offer no Edit for a
  deleted row. Card counts are paid per click, not per row.
- New msgids are in the `.pot`, all five locales and `gettext_test.exs`.
