# PR #128 — Item form Location and staged suppliers, PDFs tab, breadcrumb switchers, fitted tables, one module name — follow-up

Triage of `CLAUDE_REVIEW.md` (4 findings, 1 residual, 1 soft observation) against `main` at `e8a969f` (0.46.1).

## Fixed (pre-existing)

- ~~BUG MEDIUM — the "Unsaved changes" badge fired on a supplier row dialog opened and closed without an edit: `changed?/2` compares instead of probing — `terms_changed?/2` asks the same changeset `update_terms/4` writes through, `custom_changed?/2` compares against the stored values (`lib/phoenix_kit_catalogue/web/supplier_draft.ex:555-593`). Pinned by `test/web/item_form_live_test.exs:1033` — commit `ae32517`.~~ (One residual case remains — see Open.)
- ~~IMPROVEMENT MEDIUM — the non-UUID getter sweep skipped two attribute getters: `get_attribute/1` and `get_attribute_value/1` go through `Helpers.get_by_uuid/2` (`lib/phoenix_kit_catalogue/catalogue/attributes.ex:246-250`, `:431-435`), both enumerated in `test/web/malformed_url_keys_test.exs:28-29` — commit `ae32517`.~~

## Skipped (with rationale)

None.

## Files touched

None — triage only, no code changed.

## Verification

Each finding re-read against `main` at `e8a969f` on 2026-10-05 (grep + reading the cited lines; `git log -S` for the commits). `mix precommit` and `mix test` were not run in this pass — nothing was changed, and the suite shares a database with work in flight.

## Open

Awaiting Max's decision:

- **BUG MEDIUM, residual (partially fixed) — a supplier extra field stored as a non-string still reads as changed after a no-op Done.** `lib/phoenix_kit_catalogue/web/supplier_draft.ex:588-593`: `custom_changed?/2` compares the dialog's strings against `Catalogue.supplier_field_values/1`, so a `decimal`/`number`/`date` entities field shows "Unsaved changes" with nothing to write (the code comment says so). Nothing wrong is saved. Fixing means casting the staged values through `Catalogue.cast_supplier_field_values/1` before comparing — a DB read (the entities blueprint), so it has to be done once when the dialog closes and cached on the draft, not in `changed?/2`, which runs on every render.
- **IMPROVEMENT MEDIUM — the detail page loads every catalogue on every navigation for the header switcher.** `lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex:2775` (`assign_level_switchers/5`): `Catalogue.list_catalogues() |> Catalogue.localize(...)` runs on each drill, patch and reload, and every row is rendered into a menu that is usually not opened. Unbounded with the catalogue count. Fixing means either a lazy `items` contract on core's header switcher (a core change) or, locally, loading the list once at mount and refreshing it on the `:catalogue` broadcast instead of per navigation.
- **IMPROVEMENT MEDIUM — a multi-row supplier Save reloads the supplier tab once per write.** `lib/phoenix_kit_catalogue/catalogue/pub_sub.ex:85-89` broadcasts `{:catalogue_data_changed, kind, uuid, parent}` with no sender, so `lib/phoenix_kit_catalogue/web/item_form_live.ex:2009-2019` cannot tell its own echo and runs `refresh_supplier_state/1` in full for each of the writes `SupplierDraft.apply/5` made. Cost only; the result is correct. Fixing means adding a `from` element to that message (the topic's other three messages already carry one) and updating every `handle_info` clause that matches it across the module — a message-shape change.
- **Soft observation — one unexplained, unreproduced suite flake** (1 failure in the first full run of the merge commit, green on four later runs). Could not be verified in this pass: the suite was not run. No file:line exists for it. Chasing it means repeated full runs with fixed seeds until the order-dependent test shows itself.
