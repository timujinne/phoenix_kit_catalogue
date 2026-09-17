# PR #123: ItemSelectorModal: picks in selection order, localized unit labels, separate unit column — Claude review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/123
**Author**: timujinne
**Reviewer**: Claude (Opus 5), release review
**Date**: 2026-09-16
**Scope**: merge `5b98593` (`b825394..cc42793`): `Web.Components.Browse`
(`unit_label/1`, `unit_label_in/2`, `item_row` `inline_unit`),
`Web.Components.ItemSelectorModal` (`seq`, `entry_seq/1`, tray/confirm sort,
refresh re-hydration, `detail_unit/1`) and the two test files.

## Summary

Three changes: (1) selection entries carry a monotonic `seq`, and the tray
and the confirm payload sort by it instead of by name; (2) presented maps
gain `unit_label`, rendered everywhere the raw `unit` code used to show,
while the raw code stays in the host payload; (3) granting `:unit` as a
column removes the "/ pc" suffix from the price cell.

Checked:

- `seq` survives a live refresh: `refresh_selection` copies the old `seq`
  over the one `hydrate_preselection/5` just minted. `selection[uuid]`
  always exists there because `quantities` comes from `selection`.
- `System.unique_integer([:monotonic, :positive])` is fine, since the
  selection lives in one LiveView process.
- `inline_unit={:unit not in @columns}`: `@columns` is always a list
  (`Browse.resolve_columns!/2`), so `not in` can't raise. It keys off the
  *granted* columns, not the effective ones, which is intended: a viewer
  who hides the unit column gets a bare price.
- `detail_unit/1` now returns `nil` for a non-binary unit. It used to
  return that value as-is, and the callers treat `nil` as "no suffix".

## Findings

### BUG - MEDIUM — dialect locales rendered English unit labels (fixed)

`unit_label_in/2` called `Gettext.with_locale(PhoenixKitCatalogue.Gettext,
locale, …)` with the popup's `locale` attr as-is. That attr is a
content-language code, the same one `Catalogue.translated_name/2` takes, and
it is often a dialect ("ru-RU", "en-US"). The backend only has `de en et fr
ru`, and Gettext doesn't fall back from a dialect to its base language, so
"ru-RU" rendered "pc". The tray would say "pc" next to a Russian item name,
the exact mismatch this PR was fixing. Verified: `with_locale("ru-RU")` →
"pc", `with_locale("ru")` → "шт". The PR's tests only used bare "ru"/"en".

**Fix:** `unit_label_in/2` uses the locale when the backend knows it, else
its base language (same idiom as `Duplication.gettext_locale/1`). An
unknown base falls through to the msgid. Test added: "ru-RU" → "шт",
"en-US"/"ja-JP" → "pc".

### NITPICK — the new `@doc` split a comment from its function (fixed)

`unit_label/1` and its `@doc` were inserted between the "A flat standalone
fee IS the price…" comment and `presented_price_and_fee/1`, leaving that
comment above the wrong function. Moved back above its function.

### NITPICK — preselected entries get an arbitrary initial order (not fixed)

`selected` is a map, so preselected entries get their `seq` in map order
(uuid order for ≤32 keys), not the host's row order. User picks still append
after them in pick order, and nothing reorders them later. Fixing this means
accepting an ordered list in `selected`, which changes the API for little
gain. Left as is.
