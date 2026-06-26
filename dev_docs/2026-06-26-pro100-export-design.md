# Catalogue Export (PRO100 + Universal JSON) — Design Spec

Date: 2026-06-26
Module: `phoenix_kit_catalogue`
Status: implemented (updated 2026-06-26 to reflect post-feedback rework)

## Goal

Add a new **Export** feature to the catalogue admin, mirroring the existing
**Import** feature. A user selects an export *destination* (target application),
one or more *catalogues*, and a *format*, then downloads a generated file.
The first destination is **PRO100** (a furniture-design app); the second is
**Universal** (generic JSON). The feature is built so more destinations/formats
can be added later.

## Non-goals (YAGNI)

- No persistence of generated files anywhere on the server (see Download).
- No per-item field customization UI. Field mapping is fixed (below).
- No background jobs — export is synchronous and small.
- No category filtering (removed in the rework).

## Sidebar icons

Import tab uses `hero-arrow-down-tray` (inbound).
Export tab uses `hero-arrow-up-tray` (outbound).

## UI flow (single LiveView `PhoenixKitCatalogue.Web.ExportLive`, action `:index`)

Route/nav: **Export** tab in `lib/phoenix_kit_catalogue.ex`
(`id: :admin_catalogue_export`, `label: "Export"`,
`path: "catalogue/export"`, `live_view: {…ExportLive, :index}`).

Form fields:
1. **Destination** — select. Options come from the destination registry.
   `PRO100` and `Универсальный (Universal)`.
2. **Catalogues** — checkbox list (multi-select). One checkbox per catalogue;
   displayed inside a bordered scrollable box (max-h-64 overflow-y-auto).
   At least one catalogue must be checked for the Export button to be active.
3. **Format** — select; options come from the chosen destination.
   - PRO100: `Фурнитура (Furniture)`, `Материалы (Materials)`
   - Universal: `JSON`
4. **Export** button → triggers a file download.
   Rendered as `<a href=...>` only when destination + format + ≥1 catalogue
   are all selected; otherwise a `disabled` button.

## Download mechanism (REQUIREMENT: no server-side storage)

The generated file is streamed to the user in-memory with
`content-disposition: attachment` and never written to disk / never persisted.

Controller GET route `catalogue/export/download` builds the content in-memory
from params (`destination`, `format`, `catalogue_uuids[]`) and sends it as
an attachment via `send_download/3`. Completely stateless.

## Output formats

Common encoding rules for the PRO100 text formats:
- Field separator: TAB (`\t`).
- Line terminator: CRLF (`\r\n`).
- Encoding: **UTF-8**.
- `index` = `System.os_time(:second)` (unix timestamp).
- `base_price` → 2-decimal string (e.g. `2222.00`); `nil` ⇒ `0.00`.
- Sanitize `name` / `sku` / `unit`: strip TAB and CR/LF.

### PRO100 — Furniture (header `# Parts`)

```
# Parts\t<index>\r\n
\t\t<name>\t<sku>\t0\t<base_price>\t1.0\t\t0.0\r\n
…one row per item, flat across all selected catalogues merged…
```

Per-item row (after two leading TABs):
`name ⇥ sku ⇥ 0 ⇥ base_price ⇥ 1.0 ⇥ <empty> ⇥ 0.0`

Items from all selected catalogues are merged into a single flat list under
ONE `# Parts` header. No grouping by catalogue.

Filename: `Furniture.txt`.

### PRO100 — Materials (header `# Materials`)

```
# Materials\t<index>\r\n
\t\t<name>\t<sku>\t0\t<base_price>\t1.0\t<unit>\r\n
…
```

Per-item row: `name ⇥ sku ⇥ 0 ⇥ base_price ⇥ 1.0 ⇥ unit`
- `unit` → mapped via `PhoenixKitCatalogue.Schemas.Item.unit_label/1`
  (`piece→pc`, `m2→m²`, `running_meter→rm`, others pass through).

Items from all selected catalogues merged flat under ONE `# Materials` header.

Filename: `Materials.txt`.

### Universal JSON

Filename: `<catalogue-name>.json` for a single catalogue, `Catalogues.json` for
multiple. Content-type `application/json`, UTF-8, pretty-printed.

```json
{
  "catalogues": [{"uuid": "...", "name": "..."}, ...],
  "exported_at": "2026-06-26T16:00:00Z",
  "index": 1111111111,
  "items": [
    {"name": "...", "sku": "...", "base_price": "2222.00", "unit": "piece", "catalogue": "<catalogue name>"}
  ]
}
```

Note: no `category` field on items; no top-level `category`/`catalogue` (singular).
Per-item `catalogue` = `item.catalogue.name` (preloaded).

## Item selection

`PhoenixKitCatalogue.Export.list_export_items(catalogue_uuids)`:
- Accepts a list of catalogue UUIDs.
- Returns all non-deleted items where `catalogue_uuid in ^catalogue_uuids`.
- Ordered by catalogue UUID, then category position, then item position, then name.
- Preloads `:catalogue` and `:category` on every item.
- Returns `[]` when the list is empty.

## Code structure (all in `phoenix_kit_catalogue`)

- `PhoenixKitCatalogue.Export` — context. `destinations/0`, `destination_by_key/1`,
  `list_export_items(catalogue_uuids)`, `build(%{destination, format, catalogue_uuids})`.
- `PhoenixKitCatalogue.Export.Destination` — behaviour: `key/0`, `label/0`,
  `formats/0` (`[{key, label}]`), `render(format_key, ctx)` →
  `{filename, iodata, mime}`, where `ctx` = `%{items, index, catalogues}`.
- `PhoenixKitCatalogue.Export.Pro100` — implements `Destination`; formats
  `:furniture`, `:materials`.
- `PhoenixKitCatalogue.Export.Universal` — implements `Destination`; format `:json`;
  delegates rendering to `UniversalJson`.
- `PhoenixKitCatalogue.Export.UniversalJson` — JSON encoder; multi-catalogue ctx.
- `PhoenixKitCatalogue.Web.ExportLive` — the LiveView.
- `PhoenixKitCatalogue.Web.ExportController` — stateless download endpoint.

## URL / param shape

Download URL: `/admin/catalogue/export/download?destination=<key>&format=<key>&catalogue_uuids[]=<uuid>&catalogue_uuids[]=<uuid>...`

Built by `PhoenixKitCatalogue.Paths.export_download(%{destination, format, catalogue_uuids: [...]})`.

## Testing

- **Pure formatter tests (no DB):**
  - `test/phoenix_kit_catalogue/export/pro100_test.exs` — Furniture & Materials
    byte-exact assertions; no JSON tests (JSON moved to Universal).
  - `test/phoenix_kit_catalogue/export/universal_json_test.exs` — Universal JSON
    shape, single-catalogue filename, multi-catalogue filename, per-item
    catalogue field, edge cases; also tests the Universal destination module.
- DB-backed query tests (`list_export_items/1`) verified live via Tidewave
  on the dev DB when needed.
- `mix format` + `mix quality` must pass.

## Live verification

1. Recompile catalogue + restart elixir (path-dep is boot-time).
2. Open `/admin/catalogue/export`, pick PRO100 + one or more catalogues + a format.
3. Download Furniture & Materials; assert TABs/CRLF/UTF-8, correct headers and rows.
4. Pick Universal + JSON; download; inspect JSON structure.
5. Confirm nothing is written to disk.
