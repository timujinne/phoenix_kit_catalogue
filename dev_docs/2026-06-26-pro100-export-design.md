# Catalogue Export (PRO100 + Universal JSON) — Design Spec

Date: 2026-06-26
Module: `phoenix_kit_catalogue`
Status: approved, ready for implementation

## Goal

Add a new **Export** feature to the catalogue admin, mirroring the existing
**Import** feature. A user selects an export *source* (target application),
a *catalogue*, optionally a *category*, and a *format*, then downloads a
generated file. The first source is **PRO100** (a furniture-design app); the
feature is built so more sources/formats can be added later.

## Non-goals (YAGNI)

- No persistence of generated files anywhere on the server (see Download).
- No multi-source UI complexity yet — one source (PRO100), behaviour-based so
  adding another later is a single module + registry entry.
- No per-item field customization UI. Field mapping is fixed (below).
- No background jobs — export is synchronous and small.

## UI flow (single LiveView `PhoenixKitCatalogue.Web.ExportLive`, action `:index`)

Route/nav: new **Export** tab in `lib/phoenix_kit_catalogue.ex`, mirroring the
Import tab (`id: :admin_catalogue_export`, `label: "Export"`,
`path: "catalogue/export"`, `live_view: {…ExportLive, :index}`). Also add
`export` to the catalogue-index tab regex exclusion (currently excludes
`manufacturers|suppliers|import|events|pdfs`).

Form fields:
1. **Источник / Source** — select. Options come from the source registry.
   Only `PRO100` for now.
2. **Каталог / Catalogue** — select (required).
3. **Категория / Category** — select (optional). Empty ⇒ whole catalogue.
   Selected ⇒ that category **and its descendant subcategories**.
4. **Формат / Format** — select; options come from the chosen source. For
   PRO100: `Фурнитура (Furniture)`, `Материалы (Materials)`,
   `Универсальный JSON (Universal JSON)`.
5. **Экспортировать / Export** button → triggers a file download.

Use the catalogue admin's existing form/layout components and gettext, matching
ImportLive's look & feel.

## Download mechanism (REQUIREMENT: no server-side storage)

The generated file MUST be streamed to the user in-memory with
`content-disposition: attachment` and never written to disk / never persisted.

Implementation: reuse the catalogue module's existing file-serving pattern (the
module already serves PDFs/attachments — find and reuse that download path). The
export content is rebuilt on demand from the request params (source, format,
catalogue_uuid, category_uuid) so the download endpoint is stateless and stores
nothing. A controller GET route (e.g. `catalogue/export/download`) that builds
the content in-memory and sends it as an attachment is the expected shape; the
research phase confirms the exact mechanism supported by the module's route
injection.

## Output formats

Common encoding rules for the PRO100 text formats:
- Field separator: TAB (`\t`).
- Line terminator: CRLF (`\r\n`).
- Encoding: **UTF-8**.
- `index` = `System.os_time(:second)` (unix timestamp; matches the sample
  header numbers, which are valid 2005-era unix seconds).
- `base_price` → 2-decimal string (e.g. `2222.00`); `nil` ⇒ `0.00`.
- Sanitize `name` / `sku` / `unit`: strip TAB and CR/LF so they never break the
  row structure.

### PRO100 — Furniture (header `# Parts`)

```
# Parts\t<index>\r\n
\t\t<name>\t<sku>\t0\t<base_price>\t1.0\t\t0.0\r\n
…one row per item, flat (no category sub-grouping)…
```

Per-item row (after two leading TABs):
`name ⇥ sku ⇥ 0 ⇥ base_price ⇥ 1.0 ⇥ <empty> ⇥ 0.0`

Field meanings (confirmed with user):
- `name` → `item.name`
- `sku` → `item.sku`
- `0` → constant
- `base_price` → `item.base_price` (2 dp)
- `1.0` → constant
- field 6 (empty) → constant empty string
- `0.0` → constant

Filename: `Furniture.txt`.

### PRO100 — Materials (header `# Materials`)

```
# Materials\t<index>\r\n
\t\t<name>\t<sku>\t0\t<base_price>\t1.0\t<unit>\r\n
…
```

Per-item row: `name ⇥ sku ⇥ 0 ⇥ base_price ⇥ 1.0 ⇥ unit`
- `unit` → mapped from `item.unit` via the module's existing
  `PhoenixKitCatalogue.Schemas.Item` abbreviation function
  (`piece→pc`, `m2→m²`, `running_meter→rm`, others pass through). Exact PRO100
  unit codes are tunable later during live testing.

Filename: `Materials.txt`.

### Universal JSON

A generic, source-agnostic dump. Filename `<catalogue-name>.json`,
content-type `application/json`, UTF-8, pretty-printed.

```json
{
  "catalogue": {"uuid": "...", "name": "..."},
  "category": {"uuid": "...", "name": "..."},   // null if whole catalogue
  "exported_at": "2026-06-26T16:00:00Z",
  "index": 1111111111,
  "items": [
    {"name": "...", "sku": "...", "base_price": "2222.00", "unit": "piece", "category": "..."}
  ]
}
```

## Item selection

`PhoenixKitCatalogue.Export.list_export_items(catalogue_uuid, category_uuid \\ nil)`:
- No category ⇒ all (non-trashed/active) items of the catalogue.
- Category given ⇒ items of that category **and all descendant categories**
  (reuse the catalogue's existing descendant-expansion logic; the module already
  scopes categories "through descendants by default").
- Stable ordering (e.g. by category position then item position then name).

## Code structure (all in `phoenix_kit_catalogue`)

- `PhoenixKitCatalogue.Export` — context. `sources/0`, `list_export_items/2`,
  `build(%{source, format, catalogue, category})` → `{filename, content, mime}`.
- `PhoenixKitCatalogue.Export.Source` — behaviour: `key/0`, `label/0`,
  `formats/0` (`[{key, label}]`), `render(format_key, ctx)` →
  `{filename, iodata, mime}`, where `ctx` = `%{items, index, catalogue, category}`.
- `PhoenixKitCatalogue.Export.Pro100` — implements `Source`; formats
  `:furniture`, `:materials`, `:json`. Furniture/Materials emit the tab text;
  `:json` delegates to the universal JSON encoder. (Single source for now;
  registry returns `[Pro100]`.)
- `PhoenixKitCatalogue.Web.ExportLive` — the LiveView; uses the source registry
  to drive the source/format selects, loads catalogues/categories for the
  selects, and on Export triggers the stateless download.
- Download route/controller per the Download section.

## Testing

- **Pure formatter tests (no DB):** formatters take plain item data and produce
  exact bytes. Assert byte-for-byte structure for Furniture & Materials
  (header line, TAB layout, CRLF, constants, price formatting, unit mapping)
  and JSON shape. Structure verified against the provided samples
  `Materials 3.txt` / `Furniture 8.txt` (note: samples are format references,
  not literal golden files — their item data is unknown).
- DB-backed query tests (`list_export_items/2` incl. descendant expansion) only
  if the test DB is available; otherwise verify live via Tidewave on the dev DB.
  (Project note: DB-backed tests need a real PostgreSQL; not always available.)
- `mix format` + `mix quality` must pass in the catalogue repo.

## Live verification (done by orchestrator after implementation)

1. Recompile catalogue + restart elixir (path-dep is boot-time).
2. Open `/admin/catalogue/export`, pick PRO100 + a catalogue + a format.
3. Download Furniture & Materials; assert TABs/CRLF/UTF-8, header `# Parts` /
   `# Materials` + unix index, rows match the documented layout.
4. Confirm nothing is written to disk (no temp files).

## Extensibility

A new export source = new module implementing `Export.Source` + one registry
entry; the source/format selects pick it up automatically.
