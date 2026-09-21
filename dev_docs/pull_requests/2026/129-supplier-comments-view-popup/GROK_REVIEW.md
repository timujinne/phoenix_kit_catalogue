# PR #129: The owner's 2026-09-19 list — Grok review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/129
**Author**: @mdon (Max Don)
**Reviewer**: Grok 4.6 — post-merge pass
**Date**: 2026-09-20
**Merge**: `089f8fb` (11 commits, `1c7b2c6..68e551f`), 54 files, +2070 / −1575
**Status**: reviewed; 1 defect fixed, 1 test gap closed, 2 issues documented
and deliberately not fixed

## Scope

Eleven commits, four threads:

1. **Supplier comments before Save** (`1c7b2c6`, `b55ffb4`). A pair's
   thread is known before its row exists (`thread_for_pair/2`: inherited,
   else a name-based v5 uuid of the item × supplier). The item form keys
   threads by supplier like the staged rows, so a picked-but-unsaved
   supplier can be commented on; Save stamps the same uuid.
   Duplication stamps the copy's own pair thread, never the source's.
2. **Wording** (`ac91125`, `3b9d648`). Unset selects say "— X not set —";
   empty states say "Suppliers not set." / "Metadata not set."
3. **UI conventions sweep** (`29e36df`, `36e6c2b`). daisyUI `.fieldset`
   was shrinking labels to 12px; every field now uses core's label.
   Sentence case, one ellipsis, one prompt style. Rules in
   `dev_docs/guides/ui-conventions.md`, enforced by
   `test/web/ui_conventions_test.exs`.
4. **View popup** (`5ab84b3`, `c606928`, `6ffa3aa`, `68e551f`). View is
   on the item menus and opens the read-only product card with operator
   rows (`admin: true` — status, location, manufacturer, primary
   supplier) that client-facing embeds leave off. PDF search left the
   catalogue page (`6c00fc9`). Review-pass scoping: the popup goes
   through `item_in_catalogue/2`; a hard-deleted supplier falls back to
   `supplier_name_snapshot`; name and cost rescue separately.

## Findings

### BUG - MEDIUM — Deleted-tab item menus dropped View (FIXED)

`lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex` —
`trash_row_menu/1`.

The PR added `preview_event` to the four *active* item menus
(`item_card_menu`, `item_row_menu`, `item_actions`, `card_action_buttons`)
and passed it unconditionally to search's `<.item_table>`. The Deleted
tab's listing does not use those menus: it swaps in `trash_row_menu/1`
(Restore / Delete forever), which never learned about View.

So on one page:

| Surface | Deleted tab |
|---|---|
| Search `item_table` | View present |
| Photo thumb (`on_click="show_product_card"`) | opens the card |
| Listing row / card ⋮ | View missing |

The handler and the PR's own test already view a deleted item (no Edit
on that card). The listing menus were the dropped case of swapping the
active menu for an explicit trash whitelist.

Fixed by an optional `preview_event` on `trash_row_menu/1` (categories
leave it off) and passing `"show_product_card"` from the two item
call sites.

### IMPROVEMENT - MEDIUM — View tests did not uniquely pin the card's Edit (FIXED)

`test/web/catalogue_detail_live_test.exs`.

`assert html =~ "/items/#{item.uuid}/edit"` is already true from the
listing row's Edit, so it did not prove the *card* offered Edit or that
that link carried `return_to`. The deleted-tab refute happened to work
because that tab hides Edit everywhere.

The card Edit now has `id="catalogue-detail-product-edit"`. The test
asserts that id, `return_to` on its href, and that View is actually on
the listing menus (`phx-click="show_product_card"` — the fixture has no
photo, so that event is the menu, not a thumb).

### NITPICK — `|| UUIDv7.generate()` after `thread_for_pair/2` is dead for valid pairs (not fixed)

`duplication.ex` and `item_supplier_infos.ex` both write
`thread_for_pair(...) || UUIDv7.generate()`. For two binary uuids
`thread_for_pair/2` always returns inherited or `pair_thread/2`; the
fallback only fires on a missing/malformed uuid, which `create/2` and
the copier do not pass. Harmless safety net; leaving it.

### NITPICK — de/fr msgstr empty for "View" and "Primary supplier" (not fixed)

`priv/gettext/{de,fr}/LC_MESSAGES/default.po`. ru and et are filled and
pinned in `test/gettext_test.exs`; de/fr fall back to English, which is
how a large fraction of this catalogue already behaves. Not a new hole
and not a translation pass this review owns.

## Verified, not findings

- `thread_for_pair/2` is the same answer before and after `create/2`;
  the form test comments on a staged row and Save keeps that thread.
  A new item has no uuid, so staged rows get no thread until it exists
  (tested). Duplication stamps the copy's pair thread, not the source's.
- UUID v5 bit packing overwrites version/variant in the SHA-1 hash
  (RFC 4122 §4.3); tests pin version `5` and variant `8–b`.
- `build_fields/3`'s `admin: true` is opt-in. Item picker and item
  selector still call it without, so client embeds do not gain status /
  location / manufacturer / cost.
- `show_product_card` is scoped with `item_in_catalogue/2` (same as
  delete/restore). `get_by_uuid/2` answers nil for a non-UUID, so a
  crafted param cannot `CastError` the connected LiveView.
- Supplier name and cost rescue separately; a hard-deleted supplier
  falls back to `supplier_name_snapshot`.
- `item_in_catalogue/2` does not filter status, so a deleted item still
  opens. `card_edit_path` is `false` when `status == "deleted"`.
- Location is `ancestors_in_order/1` (root → parent, excludes self) plus
  the category, matching the form's Location section.
- PDF search is gone from the catalogue page; `pdf_search_event` remains
  on the shared menus for a one-attribute return. The item form's PDFs
  tab and the library page are untouched. Catch-all `handle_info/2`
  absorbs a stray `{:pdf_search_modal_closed}`.
- Conventions test scans `lib/**/*.ex` gettext literals for sentence
  case, `...`, `.fieldset` class names, and `— Select X —` prompts.

## Testing

- [x] `test/web/catalogue_detail_live_test.exs` — View on every listing
      mode; card Edit is the card's own link with `return_to`; deleted
      listing menus offer View; deleted card has no Edit
- [x] Existing pins: `test/catalogue/supplier_comments_test.exs`,
      `test/web/item_form_supplier_comments_test.exs`,
      `test/web/product_card_db_test.exs`, `test/web/ui_conventions_test.exs`,
      `test/gettext_test.exs`
