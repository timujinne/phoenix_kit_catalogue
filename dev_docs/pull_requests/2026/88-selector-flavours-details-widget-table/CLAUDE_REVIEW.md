# PR #88: Item selector rework — derived selection flavours, in-modal details, widget list view

**Author**: @mdon
**Reviewer**: Claude (`elixir:phoenix-thinking` applied before reading source)
**Status**: Merged
**Commit**: `db1e663` (merge of `53155f2..20a8a14`)
**Date**: 2026-08-30 (with the 2026-08-31 sweep commits `2c209a7`, `20a8a14` inside the same PR)
**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/88
**Released in**: 0.23.0

## What changed

Five threads across the selector/browse stack, plus a self-review sweep
(`dev_docs/QUALITY_SWEEP_2026-08-31.md`) that landed inside the PR:

1. **Quantity control is a native `<input type="number">`** — the custom −/+ join
   stepper is gone. Three event paths, one vocabulary: debounced `qty_change`
   (live, never resets), `qty_commit` on blur/Enter (authoritative, may reset via
   the revision-bump id pattern), and the form's `phx-submit`. The built-in
   supplier `unit_cost` field gained `"step" => "0.01"` so the arrows walk in
   cents while the 4-place scale stays available to typed entry.
2. **Selection flavour derives from the columns** — a visible `:qty` column makes
   the popup quantity-first; without one it is the checkbox flavour, with a
   leading checkbox column. `selection_mode` still forces either explicitly. A
   checked box and a quantity input never share a row.
3. **In-modal item details page** (`show_item_details`, default `true`) — the
   photo/thumb becomes a "look closer" affordance covering the browse region with
   the `ProductCard` body and a mode-aware selection control. The list stays
   mounted underneath.
4. **Context header + tray flexibility** — `context_header` shows the scoped
   category/catalogue's image, name and description in the title area;
   `show_tray: false` drops the cart button and review list.
5. **`CatalogueBrowse` gained the modal's table view**, the shared column
   contract, and `Browse.expand_scope/1` / `Browse.chip_categories/2` — the
   subtree-expansion fix that had reached only the modal.

Shared helpers moved up into `Browse`: `expand_scope/1`, `chip_categories/2`,
`normalize_uuid/1`, `resolve_view!/2`, `resolve_columns!/2`, and a canonical-form
guard on `featured_photo_url/1` / `featured_thumb_url/1`.

## Findings

### 1. BUG — MEDIUM: `CatalogueBrowse` cards silently stopped showing the SKU

`CatalogueBrowse` resolved its column list as

```elixir
defp resolve_columns(nil, display),
  do: Browse.resolve_columns!(nil, display) -- [:qty, :sku, :breadcrumb]
```

and then fed that one list to **both** surfaces:

```elixir
show_sku={@show_sku and :sku in @columns}   # cards
columns={@columns}                          # table
```

The subtraction is right for the table — without the modal's Columns dropdown
`:sku` would render outright, and `:breadcrumb` beside the `:category` column
printed the category twice per row (the 2026-08-31 sweep's own "drift between the
two surfaces" item). But `:sku` was subtracted from the **grant**, and the cards
read the grant. Card view is this component's default view, so every existing
embed lost its SKU line on upgrade — verified by reverting the fix and rendering:
the pre-fix card body is `<span class="font-medium…">Widget</span>` and nothing
else, and even the no-photo placeholder tile's SKU line is gone.

There was no way back, either. `show_sku: true` is already the default, so a host
noticing the loss could only restore it by passing an explicit `columns` list —
which is taken verbatim and therefore *also* re-adds the SKU column to the table
the subtraction was meant to clean up. The moduledoc compounded the confusion by
describing the subtraction purely as *"Table columns …"*.

The PR's own stated goal for this component was "`view: "card"` (the default here
— existing embeds keep their grid)", which this contradicts.

**Fixed**: split grant from visibility, the same distinction the modal already
draws between `columns` and `visible_columns`.

- `columns` is the GRANT: the shared default minus `:qty` only. Cards read it, so
  a view toggle still cannot resurrect a column the host didn't grant.
- `visible_columns` is what the TABLE renders: the grant minus `[:sku,
  :breadcrumb]` when the host passed no explicit list, verbatim when it did.

Both the table, its skeleton `colspan` and the rows now read `visible_columns`;
the cards keep reading `columns`. The moduledoc states the grant-vs-visibility
split explicitly.

**Test added** (`test/web/catalogue_browse_test.exs`): the default card view
renders the SKU while the default table view starts without the column. Confirmed
red on the pre-fix tree (`assert html =~ "W-1"` failed), green after.

### 2. NITPICK: two msgids outlived the code that used them

Replacing the −/+ stepper with the native control removed the only call sites of
`"Decrease quantity"` and `"Increase quantity"`, but the four hand-maintained
catalogues kept both entries (with their et/ru translations and stale
`browse.ex:602` / `:634` source references). They are not pinned in
`test/gettext_test.exs`, so nothing was holding them.

**Fixed**: both entries removed from `default.pot` and all three `.po` files.
Per `AGENTS.md` this was done by hand — `mix gettext.extract` must not be run
against these catalogues.

## Verified, not changed

Places worth recording because they *look* like the bug they aren't:

- **`toggle_column` cannot strand the picker.** In quantity mode `:qty` is in
  `locked_columns/1`, so a viewer cannot hide the column that *is* the selector
  and leave a list with no checkbox, no clickable row and no input. (Derived
  `selection_mode` is init-time; live `visible_columns` is not — without the lock
  the two would drift into an unselectable state.)
- **The detail page's carousel is not a swallowed event.** `product_card_body`
  navigates entirely through inline `onclick`/`onscroll`, so the modal's
  catch-all `handle_event/3` — which would otherwise silently eat arrow clicks
  from an embedded component — never sees them.
- **`resolve_images/1` and `resolve_files/1` are not the path-traversal hole the
  sweep closed in `featured_photo_url/1`.** They look like they hand raw JSONB
  uuids to `URLSigner.signed_url/2`, but `valid_featured/1` returns its argument
  only after `Storage.get_file/1` matched a live image row, and
  `list_folder_images/1` maps over DB rows. Both are canonical by construction —
  which matters now that this PR routes them to a client-facing surface.
- **`resolve_selection_mode!/2` and `checkbox?/1` agree.** Forcing
  `selection_mode: "click"` with a visible `:qty` column yields no checkbox
  column, exactly as the moduledoc claims.
- **`CatalogueBrowse` has the catch-all `handle_event/3`** its guarded
  `set_view` clause needs; a crafted `mode` is a no-op, not a host crash.

## Known limitation carried forward

`test/web/item_form_live_test.exs` now asserts the supplier unit-cost step
through `PhoenixKitEntities.FieldTypes.decimal_step/1`, and the cent-stepping
arrows only appear on an entities release that reads the definition's `"step"`
key. `mix.exs` keeps `~> 0.4` (constraints stay loose here by convention), so on
an older 0.4.x the arrows silently fall back to deriving `0.0001` from the scale.
Noted in the 0.23.0 changelog rather than pinned.

The sweep doc's own "Recorded, not fixed" list (the `SupplierFields`
read-modify-write race, sync-fetch skeletons, `phx-click` table-cell keyboard
access, the live-subtree scope semantic) was re-read and not re-litigated.

## Gate

`mix precommit` clean (compile `--warnings-as-errors`, `deps.unlock --check-unused`,
`hex.audit`, format check, `credo --strict`, dialyzer). Full suite green against
live Postgres: 2 doctests, 2155 tests, 0 failures.

## Related PRs

- Previous: [#87](/dev_docs/pull_requests/2026/87-drilled-mixed-view-and-images),
  [#86](/dev_docs/pull_requests/2026/86-search-modes-and-category-browser)
- Builds on: [#80](/dev_docs/pull_requests/2026/80-item-selector-columns-quantity-picking),
  [#76](/dev_docs/pull_requests/2026/76-item-selector-and-browse-components)
