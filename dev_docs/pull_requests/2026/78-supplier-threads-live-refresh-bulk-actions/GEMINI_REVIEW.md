# PR #78 — Gemini review

**Reviewer**: Gemini (Antigravity `agy`, default model)
**Scope**: Two slices of the lib/ diff: Duplication + supplier threads + cost ranges; catalogue_detail_live + components + table_config
**Date**: 2026-08-24
**Method**: Diff inlined in the prompt; concrete defects only

Verbatim output; every claim was re-verified against the code before acting — see `FOLLOW_UP.md` for the verdict on each.

---

## Slice 1 — Duplication, supplier comment threads, cost ranges

### 1. `PhoenixKitCatalogue.Catalogue.ItemSupplierInfos.cost_ranges/1`

* **What breaks**: Wrong results / duplicate range entries for `nil` currency instead of aggregated min/max/count.
* **Concrete scenario**: If an item has multiple current priced suppliers where some rows store `currency` as `""` (empty string) and others as `NULL`, PostgreSQL's `GROUP BY i.currency` separates them into distinct groups. `blank_to_nil/1` maps both to `nil`, producing multiple `%{currency: nil, ...}` range objects for that item instead of aggregating them into one range.
* **One-line fix**: Group by sanitized currency in the query via `group_by: [i.item_uuid, fragment("NULLIF(?, '')", i.currency)]` and select `fragment("NULLIF(?, '')", i.currency)`.

---

### 2. `PhoenixKitCatalogue.Catalogue.ItemSupplierInfos.cost_ranges/1`

* **What breaks**: Crash on client-forgeable input (`Ecto.Query.CastError`).
* **Concrete scenario**: Passing unvalidated/malformed UUID strings (e.g. from client query parameters) directly into `cost_ranges/1` causes `where: i.item_uuid in ^item_uuids` to raise a query casting error and crash the calling LiveView process.
* **One-line fix**: Sanitize input beforehand using `item_uuids = Enum.filter(item_uuids, &match?({:ok, _}, Ecto.UUID.cast(&1)))`.

## Slice 2 — catalogue_detail_live, components, table_config

### 1. Crash on Client Event When Modal Is Closed
- **File + Function:** [`catalogue_detail_live.ex`](file:///Users/maxdon/.gemini/antigravity-cli/scratch/lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex#L955-L972) – `handle_event("set_bulk_move_categories_disposition", ...)` & `handle_event("select_bulk_move_categories_target", ...)`
- **What breaks:** `KeyError` crashes the LiveView process.
- **Concrete scenario:** A client sends `set_bulk_move_categories_disposition` or `select_bulk_move_categories_target` when `socket.assigns.bulk_move_categories_modal` is `nil` (e.g. out-of-order event after cancellation). `modal || %{}` produces `%{}`; Elixir's map update syntax `%{modal | key: value}` raises `KeyError` because keys do not exist in `%{}`.
- **One-line fix:** Guard both handlers with `if socket.assigns.bulk_move_categories_modal, do: ..., else: {:noreply, socket}`.

---

### 2. Crash on Unpriced Supplier Rows
- **File + Function:** [`components.ex`](file:///Users/maxdon/.gemini/antigravity-cli/scratch/lib/phoenix_kit_catalogue/web/components.ex#L1681-L1697) – `format_supplier_costs/1`
- **What breaks:** `FunctionClauseError` crash when `min` or `max` is `nil`.
- **Concrete scenario:** An item has supplier rows without a price set (`unit_cost` is NULL in the database), returning `%{min: nil, max: nil}` in ranges. `Decimal.equal?(min, max)` and `Decimal.round(min, 2)` fail pattern matching on `nil`.
- **One-line fix:** Pattern match on `%Decimal{}`: `fn %{min: %Decimal{} = min, max: %Decimal{} = max} = range -> ...; _ -> "—" end`.

---

### 3. Stale Supplier Prices During Active Search
- **File + Function:** [`catalogue_detail_live.ex`](file:///Users/maxdon/.gemini/antigravity-cli/scratch/lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex#L2144-L2155) – `refresh_supplier_costs/1`
- **What breaks:** Visible search results display stale supplier pricing.
- **Concrete scenario:** An admin is viewing active search results (`search_results`). A supplier price changes, triggering `handle_info({:catalogue_data_changed, :item_supplier_info, ...})`. `refresh_supplier_costs` queries only `socket.assigns.items`, leaving `@supplier_costs` for the displayed `search_results` un-updated.
- **One-line fix:** Change `item_uuids` to `Enum.map((if socket.assigns.search_query != "", do: socket.assigns.search_results || [], else: socket.assigns.items), & &1.uuid)`.

---

### 4. Cross-Catalogue Category Move via Client-Captured UUIDs
- **File + Function:** [`catalogue_detail_live.ex`](file:///Users/maxdon/.gemini/antigravity-cli/scratch/lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex#L1750-L1815) – `category_move_targets/1` & `do_bulk_move_categories/3`
- **What breaks:** Unscoped category reparenting allows tenant/catalogue boundary bypass.
- **Concrete scenario:** Client sends foreign catalogue category UUIDs in `request_bulk_move_categories`. `category_move_targets` fetches them via unscoped `Catalogue.get_category/1`, and `do_bulk_move_categories` calls `Catalogue.bulk_move_categories_under` without passing `:catalogue_uuid` in opts (unlike `do_bulk_move_items`).
- **One-line fix:** Filter `uuids` by `socket.assigns.catalogue_uuid` and pass `Keyword.put(actor_opts(socket), :catalogue_uuid, socket.assigns.catalogue_uuid)`.

---

### 5. Race Condition on Overlapping Bulk Change Animations
- **File + Function:** [`catalogue_detail_live.ex`](file:///Users/maxdon/.gemini/antigravity-cli/scratch/lib/phoenix_kit_catalogue/web/catalogue_detail_live.ex#L480-L511) – `handle_info({:bulk_change_apply, ...})`
- **What breaks:** Leaving-row flash animation is skipped/broken for concurrent bulk operations.
- **Concrete scenario:** Two bulk change broadcasts arrive within `@bulk_change_apply_delay_ms`. When the first timer fires, it sets `bulk_change_pending: false`. The second operation's batch `:item` broadcast is then processed immediately by `handle_catalogue_data_changed` instead of being held back, interrupting the flash animation.
- **One-line fix:** Replace the boolean `:bulk_change_pending` with an integer counter decremented on `:bulk_change_apply`.
