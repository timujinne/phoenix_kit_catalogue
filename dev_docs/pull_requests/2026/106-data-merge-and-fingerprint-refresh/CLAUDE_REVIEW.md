# PR #106: Stop the item/category form from clobbering data it never rendered — Claude review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/106
**Author**: @timujinne
**Reviewer**: Claude (Sonnet 5) — post-merge pass
**Date**: 2026-09-10
**Status**: reviewed; no issues found

## Scope

Fixes a real data-loss bug: an item/category form built from a page-load
snapshot of `data` would, on Save, overwrite the *whole* `data` map —
silently erasing anything another process wrote to it after the snapshot
(translation fingerprints from `Workers.TranslationSweepWorker`, an
in-flight AI-translate action, etc.). Two independent pieces:

1. **`Catalogue.update_item/3` / `update_category/3` gain `:data_owned_keys`.**
   `narrow_data_ownership/4` re-reads the row `FOR UPDATE` inside the same
   transaction and, for keys the caller doesn't claim to own, keeps the
   fresh DB value regardless of what stale copy `attrs["data"]` carries.
   For an owned key, an explicit `nil` in `attrs["data"]` is read as "clear
   this" (`Map.delete`), while a key simply absent from `attrs["data"]`
   (never touched by the form) falls back to the fresh row's value instead
   of being treated as a deletion — the distinction the whole feature turns
   on. `Web.Helpers.data_owned_keys/2` derives the owned-key set from live
   assigns (enabled languages + `_primary_language` when multilang is on,
   else `_seo_title`/`_seo_description`; every registered extension's
   `key()`) plus per-form `extra_keys`.
2. **`AITranslateBinding.apply_translation/4` re-reads fresh fingerprints**
   before folding a translation into the live changeset, so a Save shortly
   after a Translate no longer reverts `_translation_fingerprints` to the
   pre-translate snapshot.

Companion pieces: `Schemas.Item`/`Schemas.Category` changesets now strip
`nil`-valued top-level `data` keys (`drop_nil_data_values/1`) so an explicit
clear-marker never lands in storage as JSON `null`, and
`Attachments.inject_featured_image/2` / `inject_media_order/2` switched from
`Map.delete/2` to writing that `nil` marker (the previous code silently
relied on the map simply not mentioning the key, which the new
`:data_owned_keys` merge can't distinguish from "form never rendered this
field"). `TranslationStatus.stamp_preimage/3` is unrelated new API surface
(a sync-integration primitive) bundled into the same PR.

## Review notes (no fix needed)

- Cross-checked the `extra_keys` lists both call sites pass
  (`item_form_live.ex`: `meta`, `files_folder_uuid`, `featured_image_uuid`,
  `media_order`; `category_form_live.ex`: the same three minus `meta`,
  matching that categories have no metadata namespace) against every
  `Map.put(data, "...", ...)` site in `Attachments` and `Metadata` — no
  write site is missing from either list, so no key silently reverts to the
  form's stale snapshot.
- Verified the `fresh_fingerprints/2` resource-type literals
  (`"catalogue_item"` / `"catalogue_category"`) match the ones
  `AITranslatable.resource_type_for/1` and the form LiveViews'
  `assign_ai_translation/3` calls actually use — no drift between the two
  lists.
- `Ecto.Changeset.get_field(changeset, :uuid)` correctly reads `nil` for a
  `:new` (not-yet-inserted) resource, since UUIDv7 autogeneration only fires
  on `Repo.insert`, so `put_fresh_fingerprints/3` is a true no-op on create
  rather than an accidental DB round-trip.
- `narrow_data_ownership/4` runs inside the same `repo().transaction/1` as
  the eventual `repo().update/1`, both under `FOR UPDATE` — the lock
  actually protects the read-then-write against a concurrent writer, not
  just a same-process race.
- `Helpers.fetch_attr/2` / `put_attr/3` (pre-existing, atom/string
  key-agnostic) are reused rather than re-implemented, so the new merge
  path works whether `attrs["data"]` arrives string- or atom-keyed.
- Full suite green: `mix test` — 2572 tests, 0 failures (DB-backed
  `:integration` tests included). `mix precommit` clean (format, compile
  `--warnings-as-errors`, credo `--strict`, dialyzer).
