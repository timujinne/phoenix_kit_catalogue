# Catalogue Import Rework (PRO100 round-trip + Universal JSON + Source registry) — Design Spec

Date: 2026-06-28
Module: `phoenix_kit_catalogue`
Status: approved (pending implementation)
Companion doc: `dev_docs/2026-06-26-pro100-export-design.md` (the export this mirrors)

## Goal

Make **import** symmetric with the existing **export**. Today export has a
`Destination` registry (`Pro100`, `Universal`); import is a single XLSX/CSV
column-mapping wizard with no PRO100 support and no JSON. This rework:

1. Introduces an **`Import.Source` registry** mirroring `Export.Destination`.
2. Lets the user pick an import **Source** + **Format** (like export picks a
   Destination + Format), always into an explicitly chosen **target catalogue**.
3. Adds a **PRO100 import** that mirrors the PRO100 export: reads the
   `# Parts` (Фурнитура) / `# Materials` (Материалы) text formats, matches rows
   to existing items by the **digits-only id** (`"76.0026.12"` ↔ `"76002612"`),
   and **updates** them. Rows that can't be identified/updated are surfaced in a
   **report** (their raw line content), not silently dropped.
4. Adds **round-trip** fidelity: the PRO100 "service" columns the export
   currently hardcodes (`0 / 1.0 / <empty> / 0.0`) are **preserved per item** in
   `data["pro100"]` on import and **re-emitted** by the export, so a catalogue
   edited in PRO100 can be re-imported without losing data.
5. Adds **Universal JSON import** so the Universal JSON export round-trips.

## Background: what real PRO100 files look like

Reference files (`app/.claude/tmp/export_examples/`) exported from PRO100 show
that the "service" columns carry **real per-item data** our export currently
overwrites with constants.

**Furniture (`# Parts`)** — 7 data columns after two leading TABs:

| col | sample values            | maps to                                   |
|-----|--------------------------|-------------------------------------------|
| c1  | `Second 1 furniture 222` | `item.name`                               |
| c2  | `1111` / `911` / `111`   | match key = digits-only `item.sku`        |
| c3  | `0` / `0` / `0`          | round-trip `data["pro100"]["c3"]`         |
| c4  | `2222.00`                | `item.base_price`                         |
| c5  | `1.0` / `1.0` / `1.0`    | round-trip `data["pro100"]["c5"]` (markup candidate — stage 2) |
| c6  | `222.00` / `` / ``       | round-trip `data["pro100"]["c6"]`         |
| c7  | `1.0` / `0.0` / `2.0`    | round-trip `data["pro100"]["c7"]`         |

**Materials (`# Materials`)** — 6 data columns:

| col | sample values        | maps to                              |
|-----|----------------------|--------------------------------------|
| c1  | name                 | `item.name`                          |
| c2  | id                   | match key = digits-only `item.sku`   |
| c3  | `0`                  | round-trip `data["pro100"]["c3"]`    |
| c4  | `2222.00`            | `item.base_price`                    |
| c5  | `1.0`                | round-trip `data["pro100"]["c5"]`    |
| c6  | `pc`/`m`/`m³`/`m²`   | `item.unit` (via aliases)            |

Column `c5` (the `1.0` flagged as a likely per-item markup) is identical in both
formats. Promoting it to `item.markup_percentage` is **stage 2** — deferred
until verified against a file where it actually varies — because `markup = 0`
≠ `nil`: writing `0` would override catalogue-inherited markup. Stage 1 only
round-trips it.

## Decisions (locked)

- Architecture: **Source registry** (`Import.Source`) mirroring `Export.Destination`.
- PRO100 import = **update existing only**, matched by digits-only id **within
  the selected catalogue**. No auto-create. Unmatched / ambiguous / failed rows
  → **report with raw line content**.
- Round-trip via `data["pro100"]`; export reads it with fallback to today's
  constants (items never touched by PRO100 export byte-identically to today).
- Markup mapping (c5) deferred to stage 2.
- No new tables, no nested BOM, no XML, no background jobs.

## UI flow

Single existing LiveView `PhoenixKitCatalogue.Web.ImportLive`. Step-1 (upload)
gains two selects above the file picker, mirroring `ExportLive`:

1. **Source** — select, from `Import.sources/0` (`Universal`, `PRO100`).
2. **Format** — select, options from the chosen source's `formats/0`:
   - Universal: `XLSX / CSV`, `JSON (экспорт)`.
   - PRO100: `Фурнитура (Furniture)`, `Материалы (Materials)`.
3. **Target catalogue** — required (already present). Items are matched/created
   only within this catalogue.
4. **File** — `allow_upload` `accept` comes from the source (`.xlsx .csv` /
   `.txt` / `.json`).

The chosen source decides the downstream step sequence:

- **Universal** → existing flow: `upload → map → confirm → importing → done`
  (column mapping + duplicate detection + create). JSON skips manual mapping
  (known keys, auto-mapped) but otherwise reuses the same create-oriented path.
- **PRO100** → `upload → preview → applying → report` (no column-mapping step;
  layout is fixed). See below.

## `Import.Source` behaviour + registry

New `PhoenixKitCatalogue.Import.Source` (mirrors `Export.Destination`):

```elixir
@callback key() :: atom()                       # :universal | :pro100
@callback label() :: String.t()
@callback formats() :: [{atom(), String.t()}]   # [{format_key, label}]
@callback accept() :: [String.t()]              # upload extensions, e.g. ~w(.txt)
@callback flow() :: :mapping | :sync            # which wizard branch to render
@callback analyze(path :: String.t(), ctx :: map()) ::
            {:ok, analysis :: map()} | {:error, term()}
```

- `PhoenixKitCatalogue.Import.sources/0 → [Source.Universal, Source.Pro100]`,
  `source_by_key/1` — copies the `Export.destination_by_key/1` pattern.
- `ctx` carries `%{format, catalogue_uuid, ...}`.

### `Import.Source.Universal`
- `formats → [{:spreadsheet, "XLSX / CSV"}, {:json, "JSON (экспорт)"}]`,
  `accept → ~w(.xlsx .csv .tsv .json)`, `flow → :mapping`.
- `:spreadsheet` delegates to the **current** `Import.Parser` unchanged.
- `:json` parses the Universal export shape
  `%{"items" => [%{"name","sku","base_price","unit","catalogue"}]}` into the
  same `{headers, rows}` the mapper consumes, with mappings auto-detected.

### `Import.Source.Pro100`
- `formats → [{:furniture, "Фурнитура (Furniture)"}, {:materials, "Материалы (Materials)"}]`,
  `accept → ~w(.txt)`, `flow → :sync`.
- `analyze/2` runs `Pro100Parser` → `Matcher` → `Pro100Plan`, returning the
  diff/report analysis the preview step renders.

## `Import.Pro100Parser`

Pure module. Input: raw file binary + format atom. Steps:
- Strip leading UTF-8 BOM (`EF BB BF`) if present.
- Split on CRLF (tolerate bare LF).
- Validate header line: `# Parts\t<index>` for `:furniture`,
  `# Materials\t<index>` for `:materials`; mismatch → `{:error, :bad_header}`.
- Each data row: split on TAB, **drop the two leading empty fields**, then map
  positionally to `c1..c7` (furniture) / `c1..c6` (materials).
- Emit `%{line_no, raw_line, id: digits_only(c2), name: c1,
  base_price: parse_price(c4), unit: c6_or_nil, service: %{"c3"=>..,"c5"=>..,...},
  format: :furniture|:materials}`.
- Reuse the export's normalizers where possible: digits-only is
  `String.replace(c2, ~r/\D/, "")` (same as `Export.Pro100.pro100_id/1` — extract
  to a shared helper). Price parsing reuses `Import.Mapper.normalize_price/1`.

## `Import.Matcher`

- Load all non-deleted items of the selected catalogue; build
  `%{digits_only(sku) => [item]}`.
- Resolve a parsed row's `id`:
  - exactly one item → `{:matched, item}`
  - none → `{:unmatched, row}`
  - several → `{:ambiguous, row, items}`
  - blank id → `{:unmatched, row}`

## `Import.Pro100Plan`

For each `:matched` row, builds a per-field change set:
- `base_price`: `old → new` when differing.
- `unit` (materials): normalize via extended `@unit_aliases` (`m → running_meter`,
  `m² → m2`, `pc → piece`, `m³` → unknown). On unknown unit, keep `item.unit`,
  store raw in `data["original_unit"]`, flag `unit_unrecognized` in the report.
- `data["pro100"]`: merge `%{"format" => ..., "c3"/"c5"/"c6"/"c7" => raw}` (only
  present columns). A change here alone does **not** count as a user-visible diff
  row but is persisted.
- Row status: `:update` (≥1 real field change), `:nochange`, `:unmatched`,
  `:ambiguous`, `:error` (changeset invalid → message).

Returns `%{updates: [...], skipped: [...], stats: %{...}}`.

## Preview + report (PRO100 sync flow)

**Preview step** renders a table: *item · field · was → will be · status*.
`Apply` touches only `:update` rows. **Report step** (after apply): counts of
updated, plus a list of `:unmatched / :ambiguous / :error / unit_unrecognized`
rows showing **the raw file line** and the reason (fulfils "вывести содержание
сообщения").

Updates run through `Catalogue.update_item/2` (per-item changeset) inside one
transaction; a per-row failure demotes that row to `:error` in the report
without aborting the batch.

## Export change (round-trip read-back)

`Export.Pro100` reads `item.data["pro100"]` and emits stored values, falling
back to today's constants when absent:

- furniture: `c3 = pro100["c3"] || "0"`, `c5 = pro100["c5"] || "1.0"`,
  `c6 = pro100["c6"] || ""`, `c7 = pro100["c7"] || "0.0"`.
- materials: `c3 = pro100["c3"] || "0"`, `c5 = pro100["c5"] || "1.0"`;
  `c6` stays the real `unit` field (`Item.unit_label/1`).

The header `index` is still freshly generated per export (catalogue version, not
per-item data). Round-trip is byte-exact only when re-exporting in the same
format the item was imported from; `data["pro100"]["format"]` records origin.
Items never imported from PRO100 export byte-identically to today.

## Code structure

New:
- `PhoenixKitCatalogue.Import.Source` (behaviour)
- `PhoenixKitCatalogue.Import.Source.Universal`
- `PhoenixKitCatalogue.Import.Source.Pro100`
- `PhoenixKitCatalogue.Import.Pro100Parser`
- `PhoenixKitCatalogue.Import.Matcher`
- `PhoenixKitCatalogue.Import.Pro100Plan`
- shared `digits_only/1` helper (extracted; used by parser + export)

Modified:
- `PhoenixKitCatalogue.Import` context — `sources/0`, `source_by_key/1`, `analyze/…`
- `Web.ImportLive` — Source/Format selects; branch `:mapping` vs `:sync`;
  preview + report steps + events
- `Import.Mapper` — extended `@unit_aliases`; JSON header support
- `Import.Parser` — JSON detection passthrough (or handled in Source.Universal)
- `Export.Pro100` — read `data["pro100"]` with constant fallback

Untouched: `Import.Executor` (Universal create path), all schemas/migrations
(everything lives in the existing `data` JSONB map).

## Testing

Pure (no DB):
- `Pro100Parser` — byte-level against the real `Furniture 8.txt` /
  `Materials 3.txt` fixtures (BOM, TAB, CRLF, 6 vs 7 columns, blank fields).
- `Matcher` — digits normalization, none/one/many, blank id.
- `Pro100Plan` — price/unit diffs, unknown unit, `data["pro100"]` merge,
  status derivation.
- `Export.Pro100` round-trip read-back — item with `data["pro100"]` re-emits
  stored service columns; item without → today's constants (existing byte tests
  must still pass unchanged).
- **Round-trip**: parse fixture → build item attrs → render export → assert
  **byte-identical** to the fixture (minus the freshly-generated header index).
- Universal JSON parse → mapper rows.

DB-backed (verified via Tidewave on dev when local Postgres is unavailable):
- `Matcher` against seeded catalogue items; `update_item` application; report
  contents for unmatched/ambiguous/error.

`mix format` + `mix quality` must pass (compile via `cd <host-app> && mix compile`).

## Live verification

1. Recompile catalogue + restart elixir (path-dep is boot-time).
2. `/admin/catalogue/import` → Source PRO100 → Format Фурнитура → pick catalogue
   → upload `Furniture 8.txt` → confirm preview shows matched/updated rows and a
   report of unmatched lines → apply → verify items updated and
   `data["pro100"]` populated.
3. `/admin/catalogue/export` → PRO100 → Фурнитура → download → assert the
   service columns now reflect the imported values (round-trip).
4. Universal → JSON: export a catalogue, re-import the JSON, confirm parity.
5. Confirm existing XLSX/CSV import and existing PRO100 export byte-output are
   unchanged for items never touched by PRO100 import.

## Non-goals (YAGNI)

Nested BOM / sub-items inside an item; XML; auto-creating items from PRO100;
background jobs; promoting c5/c7 to real catalogue fields (stage 2, after
verifying against a file where they vary); new DB columns or indexes (digits
matching is computed in-memory over the selected catalogue).
