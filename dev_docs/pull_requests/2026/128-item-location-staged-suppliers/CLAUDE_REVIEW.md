# PR #128: Item form Location and staged suppliers, PDFs tab, breadcrumb switchers, fitted tables, and one module name — Claude review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/128
**Author**: @mdon (Max Don)
**Reviewer**: Claude (Opus 5) — post-merge pass
**Date**: 2026-09-19
**Merge**: `b9d998c` (19 commits, `9a548bb..12c4e6b`), 46 files, +4649 / −1749
**Status**: reviewed; 1 defect fixed, 1 consistency gap closed, 2 issues
documented and deliberately not fixed

## Scope

Seven independent threads landed together:

1. **Item form Location** (`Web.ItemLocation`, new) — where an item lives is
   picked from a folder › catalogue › category tree in the Details tab and
   applied on Save through the move functions. `category_uuid` is dropped
   from the form payload so a forged one cannot carry the item elsewhere.
2. **Staged suppliers** (`Web.SupplierDraft`, new, 620 lines) — adds, costs,
   removes, primary and the row dialog are staged in a pure struct keyed by
   SUPPLIER (a price revision replaces the row's uuid) and written by
   `apply/5` after the item saves, in the order removals → edits → adds →
   explicit primary.
3. **PDFs tab** — `PdfSearchModal` gained a `variant: :inline` rendering and
   a shared `results/1`; the item form mounts it on first visit to the tab
   and keeps it hidden (not dropped) on the others.
4. **Level switchers** (`Web.LevelSwitchers`, new) — GitHub-style ▾ on the
   detail page's title and crumbs, spread into the layout so an older core
   without `page_title_switcher` still compiles.
5. **Non-UUID URL keys** — `Catalogue.Helpers.get_by_uuid/2` + `uuid?/1`;
   the by-uuid getters answer "not found" instead of raising
   `Ecto.Query.CastError`, which in a UrlState LiveView was an endless
   spinner (render → crash → reload → crash).
6. **Fitted tables** — `column_fit_class/1`, `prose_cell_class/0`,
   `actions_header_cell/1`, `category_cell_ids/2`,
   `uncategorized_category_cells/1`; `default_columns/1` now reads
   `managed_columns/1` so unmanaged "name" can never reach a per-id cell
   loop; an empty columns list is now an honoured choice rather than a
   snap-back to the defaults.
7. **Module name** — `module_name/0`, the permission label and the sidebar
   parent are "Catalogues"; the first subtab is "All catalogues".

## Findings

### BUG - MEDIUM — the "Unsaved changes" badge fired on a row dialog opened and closed without an edit (FIXED)

`lib/phoenix_kit_catalogue/web/supplier_draft.ex` — `changed?/2` asked
whether the draft *held* anything for a row, not whether it *differed*
from the row:

```elixir
cost_changed? or currency_changed? or Map.has_key?(draft.custom, supplier_uuid) or
  Enum.any?(@term_keys, &Map.has_key?(values, &1))
```

`ItemFormLive.supplier_form_values/2` seeds the row dialog from the saved
row (`supplier_draft_from/1` — sku, unit cost, currency, lead time, MOQ),
and `save_supplier_info` merges that seed back into the payload before
`put_details/5` stages it. `put_details/5` also sets `custom`
unconditionally, even to `%{}`. So opening a supplier row's dialog and
pressing Done with no edit staged the row's own values, both keys were
present, `dirty?/2` went true, and the form advertised "Unsaved changes"
for a save that would write nothing — `update_terms/4` short-circuits on
`changes == %{}` and `write_cost/4` on an equal cost.

Fixed by making `changed?/2` compare instead of probe:

- `terms_changed?/2` builds the same attrs `update_terms/4` writes through
  and asks `ItemSupplierInfo.changeset/2` whether anything changed, so the
  badge now means exactly "a save would write something". The changeset is
  pure — no DB call enters the render path (`dirty?/2` is called from the
  template).
- `custom_changed?/2` compares the staged extra values against
  `Catalogue.supplier_field_values/1` (a pure `metadata` read) and treats
  "nothing staged" as unchanged.

Regression test: `test/web/item_form_live_test.exs` — "the row dialog
closed without an edit leaves the row clean" (fails on the merge commit,
passes after).

**Residual, deliberately not chased:** a supplier extra field whose stored
value is not a string (a `decimal`/`number`/`date` entities field) still
reads as changed after a no-op Done, because the dialog's inputs return
strings while the stored value is cast. Comparing them properly needs
`Catalogue.cast_supplier_field_values/1`, which resolves the entities
blueprint — a DB read, and `changed?/2` runs on every render. The badge is
wrong in the conservative direction only; nothing is written either way.

### IMPROVEMENT - MEDIUM — the non-UUID getter sweep skipped two attribute getters (FIXED)

`Catalogue.Attributes.get_attribute/1` and `get_attribute_value/1` were
left on raw `repo().get/2` while `get_attribute_group/1` and
`get_attribute_group_full/1` in the same file moved to
`Helpers.get_by_uuid/2`. No in-repo caller feeds them a URL key today (a
grep of `lib/phoenix_kit_catalogue/web/` finds none), so this was not a
live crash — but AGENTS.md now states the convention as "the context's
getters answer not-found for a string that is not a UUID", and two public
getters did not. Converted both and added them to the existing enumeration
in `test/web/malformed_url_keys_test.exs`.

The remaining raw `repo().get/2` call sites were checked one by one and
all take a uuid off an already-loaded struct (`item.uuid`, `group.uuid`,
`first.pdf_uuid`, …) or a value the changeset already cast — none can
receive a hand-edited URL segment.

### IMPROVEMENT - MEDIUM — `assign_level_switchers/5` loads every catalogue on every detail-page navigation (NOT fixed)

`lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex:2822` —
`Catalogue.list_catalogues()` runs unconditionally on every drill, patch
and reload of the detail page, and `LevelSwitchers.catalogue_switcher/2`
renders every returned catalogue into the header dropdown. The list is
unbounded: an install with a few hundred catalogues pays a full-table load
plus that many DOM nodes on each navigation, for a menu that is usually
never opened. The switcher's search box filters client-side, so there is
no server-side narrowing to lean on.

Not fixed: the header switcher is core's component and it takes a
materialised `items:` list — making it lazy needs a core-side contract
this module does not own. Worth raising upstream before catalogue counts
grow. The per-navigation cost is one extra query on a path that already
runs several, so it is a scaling concern, not a regression today.

### IMPROVEMENT - MEDIUM — a multi-row supplier save fans out into N self-delivered refreshes (NOT fixed)

`Catalogue.PubSub.broadcast/3` goes through `PhoenixKit.PubSubHelper` and
the message reaches the sender too, and `ItemFormLive` subscribes in
`mount/3`. `SupplierDraft.apply/5` can now perform several writes in one
Save (removals, edits, adds, primary) where before this PR each write was
its own user event. Each broadcast lands back in the form's mailbox and
runs `refresh_supplier_state/1` in full: `Suppliers.list_all/0`,
`ItemSupplierInfos.list_for_item/1`, a CRM company resolve and a comment
thread resolve per row, the previews, and the subscription sync. Saving
four supplier changes therefore reloads the whole supplier tab four times
after `land_after_save/5` has already reconciled it.

Correctness is fine — `SupplierDraft.reconcile/2` is idempotent and the
staged state survives each pass — so this is cost, not breakage. The clean
fix is a `from` element on `{:catalogue_data_changed, …}` so a sender can
skip its own echo (the topic's other messages —
`:catalogue_view_sort_changed`, `:catalogue_category_reorder`,
`:catalogue_bulk_change` — already carry one), which is a module-wide
message-shape change and too broad to fold into a post-merge review.

## Verified, no change needed

- **`SupplierDraft.apply/5` ordering and the primary repair.** `intended`
  is computed from the pre-apply snapshot and set explicitly at the end, so
  a price revision that replaces a row's uuid, or a failed removal that
  stops the context promoting a successor, still leaves the item with the
  primary the table showed. Traced `ItemSupplierInfos.delete/2` (closes,
  never promotes) and `revise_unit_cost/3` to confirm.
- **`drop_location_params/1` + `scope_to_catalogue/2`.** A forged
  `item[category_uuid]` is dropped on both validate and save, and `:new`
  re-resolves the place through `ItemLocation.resolve/2` (kind and
  liveness re-checked at save time), so the tree being minutes old cannot
  file an item into a deleted or wrong-kind catalogue.
- **`ItemLocation.tree/1` orphan promotion.** The moduledoc promises a row
  under a trashed parent moves up rather than vanishing;
  `catalogues_by_folder/0` already re-homes catalogues under a trashed
  folder to the `nil` bucket, and `normalized_folder_rows/2` rewrites an
  orphan folder's `parent_uuid` to `nil` before `list_folder_tree/1`
  returns it, so grouping on the raw `parent_uuid` in `ItemLocation` is
  correct. `category_nodes/1` walks down from roots, so a corrupt parent
  cycle is unreachable rather than an infinite loop.
- **`category_cell_ids/2` header/body symmetry.** Header, body and the new
  `uncategorized_category_cells/1` all iterate the same filtered id list,
  and `default_columns/1` reading `managed_columns/1` keeps unmanaged
  "name" out of it. Checked the one other caller,
  `Components.ItemSelectorModal` — it pins `@level_columns ["items"]` and
  both sides default `extension_columns` to `%{}`, so its hand-written
  Uncategorized cell still lines up.
- **`live_update_columns/2` sort fallback.** Replacing `List.first(ids)`
  with `elem(TableConfig.default_sort(scope), 0)` is what makes the
  "remove the last column" path safe — `List.first([])` would have set
  `sort_by: nil`.
- **`PdfSearchModal.stale_item_search?/2`.** Guarded on `mode == :item`, so
  a query the operator typed survives the parent's re-renders; `item_titles/1`
  is pure enough for the update path (settings read, no query).
- **Malformed-URL sweep, probed live.** Beyond the merged test, drove
  `?folder=junk?page=5` and `?folder=not-a-uuid` on the index, a garbage
  PDF detail uuid and a garbage attribute-group edit uuid through
  `LiveCase`; none crashed.
- **`Errors.message/1`.** All six atoms `move_error_message/1` delegates
  (`category_not_found`, `catalogue_not_found`, `kind_mismatch`,
  `not_found`, `same_catalogue`, `catalogue_moved`) have clauses; no new
  atom was introduced, so `test/errors_test.exs` needed no pin.
- **Singular "Catalogue" left in place** in `humanize_resource_type/1`, the
  hidden `:admin_catalogue_detail` tab label and the `:catalogue` column
  label — all of those name one catalogue, which is what AGENTS.md now
  requires.

## Gate

- `mix precommit` (compile --warnings-as-errors, format, credo --strict,
  dialyzer) — clean, both before and after the fixes. Dialyzer: 15 errors,
  15 skipped via `.dialyzer_ignore.exs`, 0 unnecessary skips.
- `mix test` — 2 doctests, 3143 tests (3144 after this review's addition),
  0 failures.

**One unexplained flake.** The first full run of the merge commit reported
`3143 tests, 1 failure`; the failure block scrolled out of the captured
output before it could be identified, `mix test --failed` then re-ran the
single test green, and three consecutive full runs after it were clean. It
is recorded here rather than hidden: something in the suite is
order-dependent, and it was not reproduced in four subsequent runs.
