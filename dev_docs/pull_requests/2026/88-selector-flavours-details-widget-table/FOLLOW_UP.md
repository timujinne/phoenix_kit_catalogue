# PR #88 — Item selector rework: derived selection flavours, in-modal details, widget list view — follow-up

## Fixed (pre-existing)

- ~~BUG MEDIUM — `CatalogueBrowse` cards lost the SKU (grant vs visibility conflated): `web/components/catalogue_browse.ex:138-151` splits `resolve_columns` (minus `:qty`) from `visible_columns` (minus `[:sku, :breadcrumb]`) — commit `6801dc2`.~~
- ~~NITPICK — orphaned msgids `Decrease quantity` / `Increase quantity`: zero hits in `priv/gettext`, `lib`, `test`.~~
- ~~Known limitation — cent-stepping arrows depended on an entities release reading `"step"`: superseded, `catalogue/supplier_fields.ex` now sets `"step" => "any"` (commit `dbdab4d`), pinned in `test/web/item_form_live_test.exs:415-423`.~~

## Fixed (Batch 1 — 2026-09-13)

- ~~2026-08-31 sweep note — `SupplierFields` read-modify-write race on `fields_definition`: every definition write (`add_field/2`, `update_field/3`, `remove_field/2`) now reads and writes the blueprint row under `FOR UPDATE` inside one transaction (`with_locked_blueprint/2`), with the activity row and broadcast after the commit. No direct concurrency pin: the sandbox serialises connections, so the lock cannot be observed from a test; the existing `supplier_fields_test.exs` covers every path through the new wrapper.~~

## Skipped (surfaced to Max on 2026-09-13; his call, not decided here)

- Keyboard access to `phx-click` table cells (`web/components/browse.ex:928-937`; `aria-selected` on a plain row at `:908`; card `aria-label` swallowing price/SKU at `:532, :563`) — the a11y pass both #88 and #90 defer. Needs a real `<button>` per cell or `tabindex`/`role`/`phx-keydown`; a pass, not a one-liner.
- Sync fetch keeps the skeleton/spinner branches unreachable (`item_selector_modal.ex:2529, 2589, 2707`) — the documented pre-wiring for the deferred async migration.
- Live-subtree scope semantic (`catalogue/browse_state.ex:294, 323`) — deliberate since 2026-08-25; flipping it breaks chip narrowing.

## Files touched

| File | Change |
|---|---|
| `lib/phoenix_kit_catalogue/catalogue/supplier_fields.ex` | definition writes under a row lock; log + broadcast after commit |

## Verification

Re-verified against `main` at `c50c4e3` (0.29.1) on 2026-09-13 as part of the quality sweep (`dev_docs/QUALITY_SWEEP_2026-09-13.md`). Gates for the sweep batch: `mix precommit` clean (compile --warnings-as-errors, format, credo --strict, dialyzer); full suite green with live Postgres (2620+ tests at the time of writing).

## Open

None.
