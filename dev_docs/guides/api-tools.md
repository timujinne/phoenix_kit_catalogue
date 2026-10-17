# Shop API tools

The catalogue's part of the shop API: nine admin tools that core's API layer (keys, scopes, rate limits, JSON Schema validation, the confirmation flow for dangerous operations, the REST and MCP transports) serves. This module declares the tools and owns the data rules; it does no authentication of its own.

## The tools

| Tool | Scope | What it does |
|---|---|---|
| `catalogue.list_products` | `catalogue.products:read` | One catalogue's items, oldest change first, keyset pages (`cursor`), exact `count`, filters `category_id` `status` `q` (name, description, sku) `updated_since` (inclusive) `include_deleted` |
| `catalogue.get_products` | `catalogue.products:read` | Up to 50 items by reference; `fields` picks what comes back; shop fields only with `ecommerce.prices:read` |
| `catalogue.create_products` | `catalogue.products:write` | Up to 500 items; never overwrites (`skipped` + `already_exists`); no price, not visible in the shop |
| `catalogue.update_products` | `catalogue.products:write` | `{ref, changes}` pairs: name, description, sku, external_id, category, status, unit, attribute values |
| `catalogue.set_translations` | `catalogue.products:write` | Per language: name, description, slug, SEO title and description |
| `catalogue.delete_products` | `catalogue.products:delete` | To the trash, never hard delete; **always** needs confirmation |
| `catalogue.list_categories` | `catalogue.categories:read` | The category tree |
| `catalogue.upsert_categories` | `catalogue.categories:write` | Create or update by id or external_id, in order; an id with `external_id: null` clears the link |
| `catalogue.delete_categories` | `catalogue.categories:delete` | By id or external_id, to the trash, never hard delete; takes the subtree with it; **always** needs confirmation |

All need the role permission `catalogue` as well; core checks both on every request.

A category is created `active` and listed on the public shop at once; `catalogue.delete_categories` is how an agent takes one back. It has its own `:delete` scope like `delete_products` (a key that may create and rename categories cannot trash them), so a key issued before the tool existed needs `catalogue.categories:delete` added.

`update_products` can set `status` to `inactive` or `discontinued`, which e-commerce reads as archived (hidden from the shop), under the plain write scope and without a confirmation; moving an item to the trash needs the delete scope and a confirmation code.

## References, catalogues, batches

- A **reference** is `{"id"}`, `{"sku"}` (items) or `{"external_id"}`; exactly one key. `sku` is not unique: several matches answer `ambiguous_ref` with the candidate ids. `external_id` lives at `data["api"]["external_id"]` and is unique per catalogue among live rows (the V5 indexes). Resolution is `PhoenixKitCatalogue.API.resolve_refs/2` (sibling modules use it too). Nothing else belongs under `data["api"]`: `Duplication` reads any short key there as a language bucket.
- A tool works in one **catalogue**: `catalogue_id`, required when the install has more than one active standard catalogue (`API.resolve_catalogue/2`). Smart catalogues are not available.
- A batch answers `{"results": [row], "summary": {action => n}}`; a row is `{"ref", "action", "id"}` plus `"error": {"code", "message", "context"}` when it failed. Actions: `created updated unchanged skipped removed found error`. **A bad row never stops the others.**
- Hard caps: 500 rows per write, 50 references for `get_products`, 100 per page.
- **Dry run.** With `ctx.dry_run?` a write handler changes nothing and returns `{:preview, %{"rows" => ..., "summary" => ...}, fingerprint}`; the fingerprint follows the current values the operation touches, so the confirmation flow can tell that state moved between preview and confirm.

## Confirmation

`delete_products` and `delete_categories` always, and any write call with more than `api_confirm_batch_over` rows (default 50), answers `{"executed": false, "status": "confirmation_required", "preview": {...}, "confirm_token": ..., "expires_at": ..., "expires_in_seconds": ...}` (the code lives `api_confirm_ttl_seconds`, default 120 s); the same call plus `confirm_token` runs. `dry_run: true` on any write tool answers `{"executed": false, "dry_run": true, "preview": {...}}` and never creates a code. The preview of a tool that always needs a confirmation (`delete_products`, `delete_categories`) carries `"requires_confirmation": true`, so a dry run tells the caller that the real call will be held (the flag is also in the preview of a `confirmation_required` answer, where it only repeats the status: it does not ask for another dry run); the batch threshold is core's rule and no preview of a threshold tool says whether it would trip it. A key with `requires_approval` gets `status: "pending_approval"` and an `approval_id` instead (`system.get_approval`). A 500-row import therefore takes two calls with the default setting. The threshold is core's: the tools declare only `danger: :always` on the two delete tools.

## Trashing a category

`delete_categories` takes what the admin's delete button takes by default (`items: :cascade`, the choice the admin's modal pre-selects and the one a restore undoes): the category, every subcategory below it and every live item in that subtree go to the trash together, each stamped as taken by this category, so `Catalogue.restore_category/2` brings back exactly that set (see `trash-and-restore.md`). The tool offers no other disposition (`uncategorize`, `move_to`) and invents no cascade of its own. An item trashed on its own earlier stays where it was after a restore.

- The dry run of each row says how much goes with it: `subcategories` and `items` (live items in the subtree). The counts cover the whole subtree the write walks, trashed categories included (a live category restored on its own below a trashed one is taken too), and only the live rows that go. The fingerprint holds which subcategories and items they are, not only how many, so a confirmation code is refused (`reason: changed`) when one was added, removed or replaced in the subtree after the preview.
- A category listed together with its own descendant takes it, whatever the order of the request: the writes run ancestors first (like `bulk_trash_categories/3`), so the descendant is stamped as taken by the ancestor. The descendant's row answers `unchanged` (in the preview too); the answers stay in request order.
- A reference to a category already in the trash answers `unchanged` (by `external_id` only while at most one trashed category carries it); one that names nothing in this catalogue is `not_found`. References are `{id}` or `{external_id}` (no sku). Rows are independent and nothing is hard-deleted.
- `Catalogue.trash_category_outcome/2` tells whether this call trashed anything (`:trashed`) or found the category in the trash already (`:already_trashed`), so a concurrent trash is answered `unchanged`, not `removed`; `trash_category/2` is it without the tag. Both take `:log_metadata`, so the `category.trashed` entry carries `via: "api"`. The tool announces the batch once (`Catalogue.broadcast_categories_trashed/1`) after the last row.
- A trashed category frees its `external_id` (V5 indexes cover live rows only): `upsert_categories` can create a new category under it, and restoring the old one is then refused with `external_id_taken`.

## What the tools never touch

`base_price`, markup, discount and raw `data` are not in any input schema, at any depth (a test walks them). In the catalogue source `base_price` is the shop price and is written only by the e-commerce tools. Writes own **paths**, not whole keys: `update_item/3`'s `:data_owned_paths` deep-merges only the named leaves under a row lock, so a price write and a Shopify sync cannot lose each other's keys.

## Context features the tools are built on

All are options of the ordinary context functions and are useful without the API:

- `Catalogue.update_item/3` and `update_category/3`: `:data_owned_paths` (apply the update to the row locked `FOR UPDATE`; copy only these `data` paths), `:logged_data_paths` (these paths appear in the entry's `changes` as `data.a.b`), `:log_metadata` (merged into the entry's metadata; the entry's own keys win). `create_item/2`, `trash_item/2`, `restore_item/2`, `create_category/2`, `trash_category/2`, `move_item_to_category/3` take `:log_metadata` too.
- `slug` is a logged field: `changes` has `slug.<lang>` entries, so a changed slug leaves the old one in the log.
- `Catalogue.update_items/2`: many rows, one transaction, rows independent (savepoints), one `Activity.log_many/2` insert, one `{:catalogue_bulk_change, catalogue, :updated, uuids, from}` broadcast; after the commit the media folders of the rows that changed follow their renames and moves in one pass (`MediaFolders.follow/2`), and a row that failed leaves its folder alone. Inside a caller's own transaction (the price, availability and image writes of the e-commerce API do this) the activity entries, their announcement and the bulk events go out before that transaction commits (`broadcast: false` holds back the catalogue events), and a failing activity insert or folder statement, which run without a savepoint, can abort the caller's transaction while the call still answers `{:ok, _}`.
- `Catalogue.move_item_to_category_deferred/3` leaves the folder step to the caller: it returns the `{before, moved}` pair (`before` is the row the move locked), and the caller passes the pairs of all its moves to `Catalogue.follow_moved_items/2` once, which re-reads the moved rows first. `update_products` moves its items that way, so N moves are one folder pass, and it runs the pass in an `after`, so a row that raises does not leave the earlier moves' folders behind.
- A rename costs about 12 queries and 2 advisory locks per record in the folder pass (`MediaFolders.follow/2` renames one folder at a time); a plain move is one `UPDATE` for the group. 100 renames through `update_items/2`: 1,209 queries, 187 ms, against 206 and 37 ms with the layout off (settings cache running). A 500-row rename, the cap, is some 6,000 queries after the commit, inside the request.
- `Catalogue.trash_item_outcome/2` tells whether this call trashed the item (`:trashed`) or found it in the trash already (`:already_trashed`); `delete_products` answers `unchanged` for the latter (by sku or external_id a retry is `unchanged` only while no new live item has taken that sku or external_id and at most one trashed item carries it; an `id` reference always is). A trash (`delete_products`) leaves an item's folder where it is, as in the admin; creating a record makes no folder.
- `Catalogue.preview_item_update/3`: the diff `update_item/3` would log, without writing.
- `Catalogue.list_items_keyset/1`, `count_items_matching/1`, `decode_items_cursor/1`: keyset paging for exports.
- `update_products` refuses a `sku` change to a value another live (not trashed) item of the same catalogue already holds: the row answers `sku_taken` with the holder's `existing_id` (in the preview too) and writes nothing, as `create_products` skips such a row. A sku is not unique in the database (there is no index), so this check is the only guard: the rows of one request are walked in order (a sku one row releases can be taken by a later one), an item that keeps its own sku is no conflict even when a twin already shares it, and two requests racing for one sku can still both win. A row that fails at write time (an `external_id` already held, including one held by another row of the same request, or a database error) has already released its sku for the rows after it, so such a later row can still take it, and the preview shows the failing row yet still answers the later one `updated`: split a request that hands a sku over and changes an `external_id` in the same breath.
- `{:error, :external_id_taken}` from `restore_item/2`, `restore_category/2`, `restore_catalogue/2` when a live row took the id of a trashed one; `bulk_restore_items/2` restores none of such a batch and answers `{:error, :external_id_taken}` (and writes no audit entry); so do `move_item_to_catalogue/3`, `move_category_to_catalogue/3` and `bulk_move_items/3`. `bulk_move_categories_to_catalogue/4` reports it per row: `{:ok, %{moved: n, errors: [{uuid, :external_id_taken}]}}`. Inside a caller's own transaction these functions raise the `Postgrex.Error` instead of answering a tuple, because Postgres has already aborted that transaction. Copies (`duplicate_*`) never carry `data["api"]["external_id"]`.

## The log

Every API write is logged by the context, with the key owner as actor, `mode: "auto"` and metadata `via: "api"`, `key_prefix`, `request_id`, `tool` (and `approved_by_uuid` for an approved operation). The diff has the usual shape `changes: %{field => %{from, to}}`. Entries follow the install's Activity retention (90 days by default).

## Adding a tool

1. A schema in `API.Schemas` (only the keywords core's validator implements; close every object), a handler `API.<Verb>.call/2`, an entry in `API.Tools.all/0`.
2. Resolve the catalogue with `API.resolve_catalogue/2` and references with `API.resolve_refs/2`; write through the `Catalogue` facade with `Common.write_opts/3`; never pass `base_price`, markup or raw `data`.
3. A write handler supports `ctx.dry_run?` (preview + fingerprint) and answers per-row results.
4. Tests through `PhoenixKitCatalogue.Test.ApiCase.call/3`, which validates the input like the executor does. Add the tool to `tools_conformance_test.exs`.
