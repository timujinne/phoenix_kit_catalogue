# Catalogue admin table stack — design

**Date:** 2026-06-27
**Module:** `phoenix_kit_catalogue`
**Scope:** `/admin/catalogue` (catalogues index), `/admin/catalogue/suppliers`, `/admin/catalogue/manufacturers` — all rendered by `PhoenixKitCatalogue.Web.CataloguesLive`.

## Goal

Bring the three catalogue admin lists up to the "orders-style" table stack the rest of the app uses: a control toolbar (search + filters + sort + view toggle + column management + action buttons), a table↔card view toggle, per-column show/hide, and column sorting — with the user's choices persisted **per user, across sessions**.

The page title/subtitle already moved to the global admin header (prior task). The action buttons that were left in a bare top toolbar ("noise/junk") move **into** the table control row.

## Decisions (locked with the user)

1. **Catalogues index becomes a flat table** with a **folder filter** (+ a "Folder" column). The inline folder **tree + drag-and-drop is removed**. "Move to folder" stays in each catalogue's row menu.
2. **Per-user persistence** of column selection, sort, filters, and view mode.
3. **Full folder management** is preserved via a dedicated **"Folders" modal** (create / rename / new subfolder / move / trash / restore) opened from the toolbar.
4. The page's **global cross-catalogue item search is removed**. The single toolbar search filters the *current table's rows by name*.
5. The **"Active / Deleted" sub-tabs** for catalogues are kept, above the control row.

## Non-goals

- No changes to `/admin/catalogue/events`, the catalogue detail page, or any form pages.
- No new DB table or migration (see Persistence).
- No server-side pagination — lists are small; sort/filter/search are in-memory (same as orders).
- Suppliers/manufacturers get **no** "deleted" sub-tab (they use active/inactive status + hard delete, unchanged).

## Architecture — a self-contained mini-toolkit inside the module

`phoenix_kit_catalogue` is a standalone library and **must not** depend on host-app modules (the orders stack lives in the host app). So the pattern is replicated locally, reusing only phoenix_kit **core** components (`<.table_default>`, `Modal`, `SortableGrid` hook, icons).

New modules (all under `lib/phoenix_kit_catalogue/web/`):

### `PhoenixKitCatalogue.Web.TableConfig`
Pure column metadata, keyed by scope atom (`:catalogues | :suppliers | :manufacturers`). One module, scope-keyed functions (avoids three near-identical files):

- `columns(scope) :: [column]` — declaration order.
- `default_columns(scope) :: [id]` — visible-by-default ids.
- `column_map(scope) :: %{id => column}` — fast lookup.
- `validate_columns(scope, ids)` / `sortable_visible(scope, ids)` helpers.

A `column` is a map:
```
%{
  id: "items",
  label: fn -> Gettext.gettext(PhoenixKitCatalogue.Gettext, "Items") end,  # lazy → current locale
  default?: true,
  managed?: true,        # false for name/actions (always shown, never in the modal)
  sortable?: true,
  sort_key: fn row -> ... end,
  align: :right,         # :left | :right
  filterable?: true,
  filter_type: :enum,    # :enum | nil
  filter_options: fn -> [{value, label}] end   # enum only
}
```
Cell/card rendering stays in the LiveView (`render_cell/3`, `render_card_value/3`); only structural metadata lives here.

### `PhoenixKitCatalogue.Web.ViewConfig`
Per-user persistence over `phoenix_kit_users.custom_fields["catalogue_view_configs"]` — **no new table**. Precedent: `PhoenixKit.Notifications.Prefs`.

- `get(user, scope) :: map` — reads `user.custom_fields["catalogue_view_configs"][scope]` (already loaded on the socket; zero DB cost), merged over defaults.
- `put(user, scope, cfg) :: {:ok, user} | {:error, _}` — merge-then-write via
  `PhoenixKit.Users.Auth.update_user_custom_fields(user, merged, ensure_definitions: false, broadcast: false)`.
  (`ensure_definitions: false` is mandatory — otherwise the key auto-registers as a user-visible profile field.)

Persisted per-scope shape:
```json
{ "columns": ["name","folder","items","status","updated"],
  "sort_by": "name", "sort_dir": "asc",
  "filters": {"status": "active"},
  "view": "table" }
```
Filter *values* persist (unlike orders, which resets them) — small and useful here. `view` ("table"/"card") persists server-side via `view_mode=` controlled mode on `<.table_default>` so it survives across devices.

### `column_settings_modal/1` (function component, in `CataloguesLive` or a small components module)
- Inputs: scope, all columns (managed only), current selected (ordered), temp selected.
- Left: ordered selected columns, reorderable via the existing **`SortableGrid`** hook (already bundled in the module's JS), each with a remove (×) toggle.
- Right: available (hidden) columns, click to add.
- Footer: "Reset to defaults" + "Apply". Built on core `<.modal>` (keep_in_dom).

### Sorting / filtering / search — in-memory
All applied in the LiveView over the already-loaded list (catalogues/suppliers/manufacturers counts are modest). `sort_key` from `TableConfig`; `Enum.sort_by/3` with `:asc/:desc`. Search = case-insensitive substring on `name`. Filters = `status`, plus `folder` (catalogues only).

## Toolbar (one control row, under the Active/Deleted sub-tabs)

Rendered via the `<.table_default>` toolbar slots (`:toolbar_title` left, `:toolbar_actions` right); the view toggle is appended by `table_default` itself.

```
[🔍 Поиск…]  [Папка ▾] [Статус ▾]   |   Сорт: [колонка ▾][↑↓]  [⛭ Колонки]  [☰/▦]  [+ действие]
```
- Catalogues: search · Folder filter · Status filter · sort · Columns · view toggle · **+Папка**, **+Каталог**, **Папки…** (opens folder modal).
- Suppliers / Manufacturers: search · Status filter · sort · Columns · view toggle · **+Поставщик / +Производитель**.

Sort is also available by clicking sortable table headers (table view); the toolbar sort select is the primary control in card view.

## Per-scope columns / filters / defaults

**Catalogues** (`:catalogues`)
| id | label | default | sortable | filter | align |
|----|-------|---------|----------|--------|-------|
| name | Name | ✓ (always) | ✓ | — | left |
| folder | Folder | ✓ | ✓ (folder name) | enum (folder) | left |
| items | Items | ✓ | ✓ | — | right |
| status | Status | ✓ | ✓ | enum | left |
| kind | Kind | — | ✓ | enum (standard/smart) | left |
| markup | Markup % | — | ✓ | — | right |
| discount | Discount % | — | ✓ | — | right |
| updated | Updated | ✓ | ✓ | — | left |
| created | Created | — | ✓ | — | left |
| actions | — | ✓ (always) | — | — | right |

Default sort: `name asc`. Filters: Status, Folder, Kind. Item count from `Catalogue.item_counts_by_catalogue/0` (already loaded). Folder name from a `%{folder_uuid => Folder}` lookup built from `list_folder_tree/0` (already loaded).

**Suppliers** (`:suppliers`)
name (always, link to edit) · website ✓ · status ✓ (filter enum active/inactive) · contact_info (hidden) · updated (hidden) · actions. Default sort: `name asc`. Filter: Status.

**Manufacturers** (`:manufacturers`)
Same shape as suppliers (name · website ✓ · status ✓ · contact_info hidden · updated hidden · actions). Default sort: `name asc`. Filter: Status.

## Catalogues index — flat conversion details

- Replace `folder_tree_table/1` with a flat `<.table_default toggleable view_mode=...>` driven by the visible columns. Rows = catalogues for the active status view (active vs deleted).
- **Active/Deleted sub-tabs** stay above the toolbar (`switch_catalogue_view`), unchanged. Deleted view = flat list of trashed catalogues with Restore / Delete-forever row actions.
- **Folder filter** dropdown: "All folders" / "Unfiled (root)" / each folder (indented). Filters by exact `folder_uuid`.
- **Folder column**: folder name or "—".
- **Removed:** `CatalogueTreeDnD` hook + tree markup + global item-search block and its state/handlers (`search`, `search_results`, infinite-scroll for global search). Verify no orphaned assigns/handlers remain.

## Folders modal (preserve full folder management)

Toolbar **"Папки…"** button opens a `<.modal>` listing the folder tree (`list_folder_tree/0`) with actions wired to existing context functions:
`create_folder/2`, `update_folder/3` (rename), `move_folder/3`, `trash_folder/2`, `restore_folder/2`, `permanently_delete_folder/2`, plus active/trash toggle inside the modal. Reuses the existing `new_folder` / `start_rename_folder` / `rename_folder` / `trash_folder` / etc. event names where possible. This is the home for everything the inline tree used to do except DnD (DnD replaced by per-catalogue "Move to folder").

## Per-tab state on the single LiveView

`CataloguesLive` serves all three tabs. View state is per scope:
- `@view_configs :: %{catalogues: cfg, suppliers: cfg, manufacturers: cfg}` loaded from `ViewConfig.get/2` on mount.
- Column-modal/sort/filter/search/view events operate on the **active tab's** scope, mutate that entry, persist via `ViewConfig.put/3`, and re-derive the displayed rows.
- New events: `show_column_modal`, `hide_column_modal`, `add_column`, `remove_column`, `reorder_columns`, `reset_columns`, `apply_columns`, `set_sort`, `toggle_sort` (header), `set_filter`/`clear_filter`, `set_view` (table/card), and `search` (re-purposed to filter the table).

## Internationalization

New gettext strings (Columns, Reset, Apply, Sort by, Folder, Kind, Markup %, Discount %, Created, Unfiled, All folders, Manage folders, etc.) added manually to `.pot` + en/ru/et `.po` (no `gettext.merge` — avoids fuzzy pollution). Labels via lazy `fn -> gettext(...) end`.

## Implementation phasing (for the plan)

1. **Toolkit:** `TableConfig` + `ViewConfig` + `column_settings_modal` + shared sort/filter/search helpers. Unit-testable in isolation.
2. **Suppliers + Manufacturers:** wire the toolbar + dynamic columns + sort/filter/search + card view + move action buttons into the toolbar. (Simplest — already `table_default`.)
3. **Catalogues index:** flat conversion, folder filter + folder column, Active/Deleted retained, remove tree/DnD + global item search.
4. **Folders modal:** full folder CRUD.
5. gettext, `mix format`, compile via `<host-app>`, restart, runtime verify.

## Verification

- Compile via `cd <host-app> && mix compile` (catalogue can't compile standalone — stale deps).
- Restart elixir (path-dep, no hot reload); confirm clean boot + HTTP 200.
- Runtime checks: column show/hide persists across a reconnect and across users; sort + filter + search work in both table and card view; folder filter narrows; folder modal CRUD works; Active/Deleted toggle intact; "Move to folder" still works; no leftover global-search crashes.
- daisyUI 5 mobile check via headless browser (per project memory — no eyeballing).

## Risks / watch-items

- **Single LiveView, three scopes** — keep the active-scope plumbing clean so events don't cross-contaminate tabs.
- **`custom_fields` write on every toggle** — acceptable (notification prefs do the same); keep writes coarse (on Apply / sort / filter change, not per keystroke).
- **Folder management regression** — the modal must cover every action the tree offered (except DnD); enumerate against the old `folder_tree_table` row menus.
- **Removing global item search** — ensure all its assigns/handlers/hook are removed without breaking mount.
