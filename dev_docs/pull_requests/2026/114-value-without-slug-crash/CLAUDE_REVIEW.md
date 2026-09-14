# PR #114: Keep the item form alive when an attribute value has no slug — Claude review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/114
**Author**: @timujinne
**Reviewer**: Claude (Opus 5) — post-merge pass
**Merge commit**: `6c8bb3b` (2 commits, `3563913`, `084bf16`)
**Date**: 2026-09-14
**Status**: reviewed; fix is correct, one MEDIUM improvement and two nitpicks fixed post-merge

## Scope

An attribute-set value with a NULL `slug` resolves to `%{key: nil}`
(`AttributeSets.value_shape/1`). The item form rendered its chip checkbox
with no `phx-value-key`, so a click sent `%{"set" => uuid, "value" => "on"}`.
The only `toggle_value_selection` clause matches `%{"set" => _, "key" => _}`,
so the LiveView crashed with `FunctionClauseError` and remounted, discarding
every unsaved staged selection. The PR renders a slugless chip with a
disabled checkbox that has no `phx-click` and an explanatory tooltip. It also
adds a catch-all `toggle_value_selection` clause. One new msgid goes to the
`.pot` and every locale (ru/et translated, en identity, de/fr empty), pinned
in `gettext_test.exs`. Two LiveView tests cover the payload and the render.

## Verification

- **The trigger is real.** `PhoenixKitEntities.EntityData.validate_slug_format/1`
  accepts `nil` and `""`, so a row saved through the generic entities admin
  can carry no slug. The catalogue's own `create_attribute_set_value/2`
  always generates one. The second commit's wording ("seen in live data")
  matches this.
- **Catch-all is grouped and harmless.** It sits directly after the real
  clause, and every other malformed payload (non-staged set, unknown key) was
  already a no-op through the `with`. Selections only ever hold binaries, so
  a nil key can't sneak into `staged_selections` through any other path.
- **Hidden (archived) chips are unaffected.** `hidden_selected_values/2`
  filters by selection membership, and a nil key is never selected, so a
  slugless hidden value never renders a × button with an empty key.
- **Sibling surfaces checked.** The attribute filter dropdown
  (`Components`, `phx-value-slug={value.slug}`) already has catch-all
  `toggle_attribute_filter` clauses in `CataloguesLive` and
  `CatalogueDetailLive`. A nil-slug value there counts as dead (no count
  under `nil`), so it renders disabled. The attribute-group editor addresses
  values by uuid. `AttributeSetItemsModal`'s `label_map` is only read for
  selected keys.
- **de/fr empty msgstr** is the established convention (986 empty entries
  each), not a gap.

## Findings

### IMPROVEMENT - MEDIUM — slugless values shared one swatch thumbnail (fixed)

`put_thumbs/1` built `%{value.key => thumb}` over `values ++ hidden_values`.
Every slugless value maps to the same `nil` key, so the last one written
wins. Take a set with two slugless values where only the first has a swatch:
the second value's `nil` thumb overwrote the first's, and the first chip
rendered no image. With both carrying swatches, a chip would show the other
value's image. The PR made these chips visible-but-disabled, so they are
exactly the ones affected.

**Fix:** `put_thumbs/1` skips nil keys, and the active chip reads its image
through `chip_thumb/2`, which computes `value_thumb/2` directly for a nil key.
New test: two slugless values, one with a swatch. It asserts the thumbs map
has no `nil` entry and that only Red's chip renders an `<img>`.

### NITPICK — disabled chip kept the clickable styling (fixed)

The `<label>` kept `cursor-pointer` and `hover:border-base-content/40` for a
chip whose checkbox is disabled. It looked clickable and did nothing. The
class is now a list: clickable chips keep the hover/`has-[:checked]`
highlight, and slugless chips get `opacity-60 cursor-not-allowed`.

### NITPICK — test comment contradicted the second commit (fixed)

`084bf16` restated the NULL-slug origin as "observed" rather than a claim
about the entities editor. The render test's comment still said "slug column
emptied via the entities editor". Reworded to match.

### NITPICK — "slug" is internal vocabulary in the tooltip (not fixed)

"This value has no slug and cannot be selected" names a column an editor may
not know. It is still actionable for the admin who owns the data (give the
value a slug in the entities admin), and rewording means another msgid in
every locale.
