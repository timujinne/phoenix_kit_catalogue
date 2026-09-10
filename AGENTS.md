# AGENTS.md

Guidance for AI agents working on `phoenix_kit_catalogue`.

## Overview

Product catalogue management as a pluggable PhoenixKit module: manufacturers,
suppliers, catalogues, nested categories and items, with soft-delete,
multilingual names/descriptions, move operations, attribute sets, a PDF library
and import/export. Admin-only LiveView UI; no public API surface. Deep feature
semantics live in module `@moduledoc`s and `dev_docs/` — this file holds
conventions, contracts and non-obvious boundaries.

- **Depends on:** `phoenix_kit` `>= 2.13.11 and < 3.0.0` (Hex, patch-precise
  floor — see the comment in `mix.exs` and `test/core_pin_conformance_test.exs`),
  `phoenix_kit_ai` `~> 0.18` (hard dep; the AI-translate integration is
  duck-typed through `ai_translatables/0`), `phoenix_kit_entities` `~> 0.4`
  (hard dep; attribute sets and supplier fields report `:entities_disabled`
  rather than crash when the module is off or too old),
  `phoenix_kit_comments` `~> 0.4` (**test-only** dep — every call in `lib/` is
  guarded with `Code.ensure_loaded?/1` and `lib/` must keep compiling without
  the package). Non-kit deps: `phoenix_live_view`, `xlsx_reader`, `nimble_csv`,
  `saxy`, `ex_pdfium`, and `rustler` (optional, only for source builds of
  `mdex_native`).
- **Consumed by:** `phoenix_kit_ecommerce`, through the duck-typed catalogue
  extension slot (`PhoenixKitCatalogue.Extension` / `.Extensions`) — neither
  side declares a dependency on the other. A few siblings reference the module
  name behind `Code.ensure_loaded?/1` guards only.
- **Admin surface:** parent tab `:admin_catalogue` at `/admin/catalogue`, with
  subtabs Catalogues, Attributes, Import, Export, Events, PDFs, Translations,
  plus hidden form/detail tabs. One stateless HTTP route:
  `GET /admin/catalogue/export/download`.
- **Module key** `"catalogue"`; settings prefix `catalogue_`.

## What this module does NOT do

- **No authorization in the context.** Mutating functions accept `actor_uuid`
  only for activity logging. Permission gating happens at the LiveView mount
  layer (`live_session :phoenix_kit_admin`, `:catalogue` permission key).
- **Admin-only.** No public routes, JSON endpoints, or webhook receivers. The
  single HTTP endpoint is the admin-gated, stateless export download, behind
  `:phoenix_kit_require_admin`.
- **No per-item versioning.** Soft-delete (`status`) is the only history
  mechanism; the activity log is the audit trail.
- **No always-on background work.** Two jobs, both opt-in by config:
  `Workers.PdfExtractor` on Oban queue `:catalogue_pdf` (the host must configure
  that queue) and `Workers.TranslationSweepWorker` on queue `:default`
  (self-rescheduling; only seeds its chain when an operator enables the
  AI-translation sweep setting via `Web.Settings`). Everything else runs inline
  — imports via `start_async/1` from the LiveView, change propagation via
  PubSub.
- **Does not own supplier/manufacturer identity.** Those are CRM companies
  holding the `supplier` / `manufacturer` role; this module keeps only the
  per-item sourcing facts (cost, SKU, lead time) and resolves identity through
  `Catalogue.Suppliers`. Core's chain deliberately dropped the manufacturer and
  manufacturer-supplier foreign keys (core carries them as `:legacy_optional` in
  `ExpectedSchema`) — never re-add one, it would pin an item's manufacturer and
  both sides of the M:N graph back to a local row and undo the CRM federation.
- **Does not name an extension implementer.** Discovery is duck-typed via
  `PhoenixKit.ModuleRegistry`; an unregistered or disabled host must change
  nothing about how the item/category forms render.

## Commands

```bash
mix deps.get
createdb phoenix_kit_catalogue_test   # once; DB-backed tests are tagged :integration and auto-skip without it
mix test
mix precommit                # compile --warnings-as-errors + format + credo --strict + dialyzer; run before every commit
```

`phoenix_kit*` deps resolve from Hex. To run against a local checkout, export
`<APP>_PATH` (the dep's app name upper-cased plus `_PATH`); `pk_dep/3` in
`mix.exs` swaps the Hex pin for a `path:` dep at resolve time. Unset means the
Hex pin, so `mix hex.publish` is unaffected. Run `mix deps.get` with the var
exported before the first `mix test` (a stale lock aborts on the optional
`igniter` dep), and never commit a hand-edited `path:` tuple.

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix deps.get && PHOENIX_KIT_PATH=../phoenix_kit mix test
PHOENIX_KIT_AI_PATH=../phoenix_kit_ai mix test
PHOENIX_KIT_ENTITIES_PATH=../phoenix_kit_entities mix test
PHOENIX_KIT_COMMENTS_PATH=../phoenix_kit_comments mix test
```

Repo-local aliases:

- `mix quality` — `format` + `credo --strict` + `dialyzer` (applies formatting).
- `mix quality.ci` — `format --check-formatted` + `credo --strict` + `dialyzer`: it CHECKS formatting rather than applying it, so run `mix format` first.

## Conventions

- **Module key** `"catalogue"` everywhere (`module_key/0`, settings keys); admin
  tab IDs are `:admin_catalogue` (parent) and `:admin_catalogue_*` (subtabs).
  URL segments use hyphens, never underscores.
- **Paths** — never hardcode URLs. Use `PhoenixKitCatalogue.Paths` helpers,
  which wrap `PhoenixKit.Utils.Routes.path/1` for prefix/locale handling.
- **Routing** — admin pages come from `admin_tabs/0` (each tab carries its
  `live_view:`); `route_module/0` → `Web.Routes` adds only the stateless
  export-download GET, declared in both `admin_routes/0` and
  `admin_locale_routes/0`. PhoenixKit injects both into its own
  `live_session :phoenix_kit_admin` / router — never hand-register plugin routes
  in a host router (loses the admin layout, crashes cross-session navigation).
  In `admin_tabs/0`, declare static paths **before** wildcard `:uuid` paths, and
  use `match:` to control sidebar highlighting.
- **Single public context** — all business logic goes through
  `PhoenixKitCatalogue.Catalogue`. Internal submodules (`Catalogue.{Rules,
  SmartPricing, Search, Tree, Slugs, Manufacturers, Suppliers, Links,
  ItemSupplierInfos, Counts, Translations, Duplication, AttributeSets,
  SupplierFields, SupplierComments, CrmLink, PdfLibrary, PdfEngines, PubSub,
  ActivityLog, Helpers}`) are an implementation detail re-exported via
  `defdelegate`; LiveViews and external consumers must not call them directly.
- **LiveViews `use Phoenix.LiveView` directly** — no `use PhoenixKitWeb,
  :live_view` in this standalone package. Four LVs layer
  `use PhoenixKitWeb.Live.UrlState` on top for URL-backed state; the export
  controller is the one `use PhoenixKitWeb, :controller`.
- **Most admin LVs self-wrap the layout.** Core auto-applies its admin chrome
  via `socket.private[:live_layout]`; a view that needs to push its own
  title/subtitle into the global admin header opts out with an `on_mount` that
  resets `live_layout` to `{PhoenixKitWeb.Layouts, :app}` and renders inside
  `<PhoenixKitWeb.Components.LayoutWrapper.app_layout>`. Match the surrounding
  file rather than mixing the two styles in one view.
- **Errors API** — context failures return plain atoms, tagged tuples, or
  changesets; the UI boundary translates via `Errors.message/1` (gettext). A new
  error atom requires a `message/1` clause plus a pin in `test/errors_test.exs`.
- **Activity logging** — every mutating context function takes `opts` with
  `actor_uuid:` and logs via `Catalogue.ActivityLog`, which logs only on the
  `{:ok, _}` branch and must never crash the operation. LiveViews obtain the
  actor via `actor_opts/1` from `Web.Helpers`. `test/activity_logging_test.exs`
  pins one test per action atom — extend it for new actions.
- **PubSub** — mutations broadcast `{:catalogue_data_changed, kind, uuid, nil}`
  on the `"phoenix_kit_catalogue"` topic via `Catalogue.PubSub`.
- **Multilang forms** — name/description go through PhoenixKit `Multilang`. Form
  LVs use `to_form(changeset)` plus a private `assign_changeset/2` (assigns both
  `:changeset` and `:form`) with component-style `<.input field={@form[:x]}>`.
  Only translatable fields render inside `<.multilang_fields_wrapper>`.
  `import_live.ex` is a deliberate exception (runtime-constructed field names).
- **`enabled?/0` must rescue everything** *and* `catch :exit`, returning `false`
  — the DB may be unavailable at boot, and a sandbox owner can exit mid-checkout
  before `rescue` is reached.
- **UUIDv7 primary keys** on every entity schema, and every table-backed schema
  carries `use PhoenixKit.SchemaPrefix` (pinned by
  `test/schema_prefix_conformance_test.exs`). The content-addressed PDF
  cache/join tables are the only PK exception.
- **Soft-delete via `status`** for catalogues/categories/items (`"deleted"`);
  PDFs use `"active" | "trashed"`; manufacturers and suppliers are hard-delete
  only.
- **Gettext** — the module has its own backend, `PhoenixKitCatalogue.Gettext`;
  use it, not `PhoenixKitWeb.Gettext`, for new strings. Three rules, because the
  catalogues are not machine-generated:
  - `priv/gettext/default.pot` is **hand-maintained**. Add new msgids by hand to
    `default.pot` and to every locale under `priv/gettext/`, and pin them in
    `test/gettext_test.exs`.
  - **Never regenerate the `.pot` from scratch**, and never run
    `mix gettext.merge` against a regenerated one. Almost every string uses the
    runtime call `Gettext.gettext(PhoenixKitCatalogue.Gettext, "…")`, which the
    extractor cannot see, so a from-scratch extraction keeps only a small
    fraction of the file and a following merge deletes the rest from every
    `.po`.
  - The runtime form is **not** extracted from inside a HEEx attribute
    interpolation (`title={Gettext.gettext(…)}`) even in a module carrying
    `use Gettext` — use the macro form there.

  Details: `dev_docs/guides/gettext-catalogue.md`.
- **Tailwind** — `css_sources/0` returns `[:phoenix_kit_catalogue]` so the
  host's `app.css` scans this module's templates.
- **JS hooks** — shared hooks (RowMenu, SortableGrid, InfiniteScroll, …) come
  from core's `window.PhoenixKitHooks`. This module also ships two of its own,
  `CatalogueTreeDnD` and `ViewPref`, in
  `priv/static/assets/phoenix_kit_catalogue.js`, declared by `js_sources/0`
  under the global `PhoenixKitCatalogueHooks`; a host that skips the
  `:phoenix_kit_js_sources` compiler entry loses tree drag-and-drop and
  view-preference persistence with `unknown hook found for "…"` and nothing
  else. A hook must reach the LiveSocket at construction, so **never register
  one from an inline `<script>`**: morphdom does not execute an inserted script
  tag, so it works on a hard load and silently does nothing on a LiveView
  navigation. The item picker, the item-selector modal and the browse
  component instead use colocated hooks (`Phoenix.LiveView.ColocatedHook`),
  which the host reaches via
  `phoenix-colocated/phoenix_kit_catalogue`; that import only exists because
  `mix.exs` prepends the `:phoenix_live_view` compiler, which must run before
  `:elixir` to attach at all.

### Landmines

- A `<select phx-change=…>` outside a `<form>` never reaches the server. Wrap it
  in a form, and drive it in tests via `render_change` through the form.
- A client-side echo of a stale param can freeze a derived field (a slug that
  stops following the name). Keep derived-field ownership in server assigns and
  test with stale params.
- Component preferences persisted against a record must be re-read at component
  init — the host LiveView's assign snapshot goes stale, and a fresh-mount test
  cannot see the bug.
- `PhoenixKitWeb.Live.UrlState` params are auto-assigned *before*
  `handle_url_state`, so a "did it change?" check against them never fires; keep
  `prior_*` trackers.
- `<style>{@css}</style>` in HEEx ships the literal text — use `<%= raw %>`.

## Architecture

```
lib/phoenix_kit_catalogue.ex          PhoenixKit.Module implementation (tabs, callbacks, children/0)
lib/phoenix_kit_catalogue/
  catalogue.ex                        the single public context (defdelegates)
  catalogue/                          Rules, SmartPricing, Search, Tree, Slugs, AttributeSets,
                                      SupplierFields, SupplierComments, CrmLink, PdfLibrary,
                                      PdfEngines, PubSub, ActivityLog, Duplication, …
  schemas/                            18 Ecto schemas, one per phoenix_kit_cat_* table
  migrations.ex                       module-owned versioned chain
  paths.ex  errors.ex  metadata.ex  attachments.ex
  extension.ex  extensions.ex         the duck-typed item/category form extension slot
  import/  export/  pro100/           source + destination registries
  ai_translatable*.ex  ai_prompt.ex   phoenix_kit_ai integration
  workers/                            PdfExtractor, TranslationSweepWorker
  web/                                LiveViews, components, table stack, ExportController
lib/mix/tasks/                        phoenix_kit_catalogue.audit_supplier_refs
```

Schemas (all `@primary_key {:uuid, UUIDv7, autogenerate: true}`):

- `Catalogue` — top-level grouping. `kind: "standard" | "smart"`,
  catalogue-wide `markup_percentage` / `discount_percentage`, status
  active/archived/deleted. Optional `folder_uuid` files it under a `Folder`.
- `Folder` — module-global, self-nesting tree for organizing catalogues on the
  admin index (unrelated to media folders). New deletes are empty-only and
  permanent (`delete_empty_folder/2`); `trash_folder/2` remains for legacy rows
  and `permanently_delete_folder/2` is the promote-contents escape hatch for
  those.
- `Category` — belongs to a catalogue; self-nests via nullable `parent_uuid`;
  position scoped to siblings `(catalogue_uuid, parent_uuid)`.
- `Item` — belongs **directly to a catalogue** (`catalogue_uuid` required) with
  optional `category_uuid`. Nullable per-item markup/discount overrides: `NULL`
  inherits the catalogue value, any Decimal (**including `0`**) overrides.
- `ItemSupplierInfo` — per-item supplier purchase info (cost, currency, lead
  time, primary flag). `supplier_uuid` is a soft reference (no FK) so suppliers
  can come from other PhoenixKit modules.
- `Manufacturer`, `Supplier`, `ManufacturerSupplier` (M:N join) — hard-delete
  only.
- `CatalogueRule` — smart-catalogue rule row, `UNIQUE(item_uuid,
  referenced_catalogue_uuid)`.
- Attribute schemas: `AttributeGroup`, `Attribute`, `AttributeValue`,
  `ItemAttributeGroup`, `ItemAttributeSet`.
- PDF library tables (`Pdf`, `PdfExtraction`, `PdfPage`, `PdfPageContent`) layer
  on core `phoenix_kit_files`; their cache/join tables use content-derived
  primary keys, not UUIDv7.

Key invariants to preserve:

- `create_item` / `update_item` derive `catalogue_uuid` from `category_uuid`, so
  an item's category and catalogue can never drift; an empty-string
  `category_uuid` normalizes to `nil`.
- Soft-delete trash/restore cascade rules intentionally **differ per entity**
  (catalogue cascades, category restore does not, item restore may
  uncategorize). Read the existing `Catalogue` functions before touching them —
  do not "simplify" them.
- Smart-catalogue rules may only reference `kind: "standard"` catalogues (guard
  in `Rules.build_rule_changeset/2`). Smart items do not use
  `base_price`/markup/discount — the fee lives in `default_value` /
  `default_unit` plus rules, and `Catalogue.evaluate_smart_rules/2`
  (`Catalogue.SmartPricing`) is the canonical evaluator consumers call rather
  than reimplementing the math.
- Tree/position semantics (orphan promotion, cycle guards, sibling-scoped swap)
  live in `Catalogue` and `Catalogue.Tree` — reuse them, never hand-write
  recursive queries in LiveViews.

Settings keys (`PhoenixKit.Settings`):

| key | type | note |
|---|---|---|
| `catalogue_enabled` | bool | module enable flag |
| `catalogue_translation_sweep_enabled` | bool | default `false`; seeds the worker chain |
| `catalogue_translation_sweep_interval_minutes` | int | default `60` |
| `catalogue_translation_sweep_langs` | json | `%{"codes" => [...]}`; a bare list is rejected by the `:map` column |
| `catalogue_translation_sweep_max_per_run` | int | default `200` |
| `catalogue_view_configs` | json | per-user table/view preferences |

Permission: one key, `"catalogue"` (`permission_metadata/0`), no sub-permissions.
PubSub topic: `"phoenix_kit_catalogue"`.

## Database & migrations

Owns a versioned chain: `PhoenixKitCatalogue.Migrations` via
`migration_module/0`, marker `pkc_schema:<N>` as a `COMMENT ON TABLE
phoenix_kit_cat_catalogues`, currently V2. `mix phoenix_kit.update` applies it
in hosts; tests replay `up_statements/2` directly through the repo (`up/1` uses
`execute/1`, which only works inside an `Ecto.Migration` run).

- **V1 is purely ADOPTIVE.** All eighteen `phoenix_kit_cat_*` tables already
  exist on live installs, created by core's chain and reshaped by later core
  versions, so V1 changes no shape and only stamps the marker. Never edit it.
- **A new column now means a new chain version here (V2+), not a core
  migration.** Core's `ExpectedSchema` manifest still audits these tables, so a
  version that changes the shape of an object the manifest *declares* must
  follow the excluded-object protocol before it ships. Adding an undeclared
  column, or a table core's manifest never names, is outside the resolver's
  reach and needs no core release — V2 (the `slug` jsonb columns, the two slug
  projection tables plus their sync triggers, and the attribute-set GIN index)
  is that case.
- Statements stay idempotent (`CREATE TABLE IF NOT EXISTS`, guarded
  `DO $$ … pg_constraint … $$`). Adoption is a presence check only: it cannot
  repair a table whose columns drifted, which is why the core pin floor exists —
  core's chain always runs first, so every adopted table is at core's current
  shape by the time this one runs.
- **`down/1` drops nothing.** It unstamps the marker and nothing else. The
  ownership test scans every statement the module can emit and refuses `DROP` /
  `TRUNCATE` / `DELETE` outside three carve-outs: the FK drops transcribed from
  core's dump, `DROP TRIGGER IF EXISTS` before a recreate, and a slug
  projection's own sync function deleting only projection rows it is about to
  re-insert.
- UUIDv7 PKs and `use PhoenixKit.SchemaPrefix` on every table-backed schema.

## Testing

- Test DB `phoenix_kit_catalogue_test`. `config/test.exs` sets
  `config :phoenix_kit, repo: PhoenixKitCatalogue.Test.Repo` — without it every
  DB call through `PhoenixKit.RepoHelper` crashes.
- Unit tests run with no Postgres; DB-backed tests (via `DataCase` / `LiveCase`)
  are tagged `:integration` and excluded automatically when the database is
  missing or unreachable.
- `test/test_helper.exs` builds the schema with
  `PhoenixKit.Migration.ensure_current/2`, then replays this module's own chain
  via `Migrations.up_statements/2` when `migrated_version_runtime/1` is behind.
  Do **not** replace `ensure_current/2` with
  `Ecto.Migrator.run([{0, PhoenixKit.Migration}])` — that pattern caches version
  `0` in `schema_migrations` and silently stops applying core migrations added
  later. The helper also `Code.require_file`s the support modules (Elixir
  1.19 no longer auto-loads them), pins the URL prefix, and starts the test
  Endpoint, `PhoenixKit.PubSub`, `PhoenixKit.PubSub.Manager` and
  `PhoenixKit.TaskSupervisor`.
- Test support: `test/support/data_case.ex`, `live_case.ex` (Test.Endpoint plus
  a router scoped at `/en/admin/catalogue`), `activity_log_assertions.ex`,
  `test_repo.ex`, `test_router.ex`, `test_layouts.ex`.
- `PGUSER` / `PGPASSWORD` / `PGHOST` are honoured. `PGDATABASE` and `PGPOOL`
  override the database name and pool size, so the suite can point at a database
  it does not own and cannot `CREATEDB` for itself, e.g.
  `PGDATABASE=migration_test_db PGPOOL=6 mix test`.
- **Caution:** if `PGDATABASE` points at a database other modules also use, do
  not combine it with `PHOENIX_KIT_PATH=../phoenix_kit` — `ensure_current/2`
  would run *that* core's migration chain against the shared database, moving
  its schema for every module pointed at the same `PGDATABASE`.

## Feature notes

Pointers, not docs — the moduledocs are the contract.

- **Pricing** — chain is `base → markup → discount`.
  `Catalogue.item_pricing/1` is the one-stop API for UIs; pure helpers live on
  `Item`.
- **Smart catalogues** — `Catalogue.put_catalogue_rules/3` (replace-all,
  transactional, one `smart_rules.synced` activity), `list_catalogue_rules/1`,
  `list_items_referencing_catalogue/1` (warn before deleting a referenced
  catalogue). Narrative: `guides/smart_catalogues.md` (ships in the package,
  pinned by `test/smart_catalogues_guide_test.exs`).
- **Search** — `Catalogue.search_items/2` + `count_search_items/2` and scoped
  wrappers; `:include_descendants` (default true) expands category subtrees.
  Known perf tradeoff: ILIKE over JSONB, no trigram index — acceptable at
  current volumes.
- **Attachments** — `PhoenixKitCatalogue.Attachments` wires the featured image
  and per-resource file folder into the catalogue/item forms (category form:
  featured image only). LVs must call `Attachments.inject_attachment_data/2`
  before save.
- **Metadata** — opt-in fields on items/catalogues stored in `data["meta"]`;
  definitions in `PhoenixKitCatalogue.Metadata`, whose labels are gettext-wrapped
  at call time — do not cache them. Unknown stored keys pass through as legacy
  rows.
- **Attribute sets** — one dimension from one vendor, stored as a MANAGED
  entities blueprint named `catalogue_set_<slug>` with `locked_keys`; items
  attach sets through the catalogue-owned join table. `contract/1` validates the
  blueprint on every resolve and surfaces `{:error, :contract_broken}` rather
  than guessing. Writes fail loudly with `:entities_disabled` when entities is
  off; reads degrade quietly to `[]` / `nil` / `%{}` / `0`.
- **Supplier fields** — admin-defined extra fields on supplier rows, one
  singleton blueprint (`catalogue_supplier_fields`) under its own owner key.
  Entities owns the field *definitions*, the catalogue owns the *values*; the
  blueprint is not an attribute set and must never land in the set registries.
- **Import** — `PhoenixKitCatalogue.Import` is a source registry
  (`Import.Source.Universal` for CSV/XLSX, `Import.Source.Pro100` for Pro100
  cabinet-software data); execution goes through `Import.{Mapper, Executor}` and
  the `ImportLive` wizard (ETS buffering).
- **Export** — `PhoenixKitCatalogue.Export.build/1` with a
  destination/format registry (Universal JSON, Pro100); UI in `ExportLive`,
  download via the admin-gated `ExportController`. Inbound mirror of the import
  sources.
- **PDF library** — `Catalogue.PdfLibrary` + `Workers.PdfExtractor`.
  Content-hash dedup on core `phoenix_kit_files`; search is literal ILIKE with a
  trigram fallback. `enqueue_extraction/1` fails visibly when the host Oban
  queue is missing; `requeue_stuck_extractions/1` is the operator-driven heal
  for stuck rows. Engine selection lives in `Catalogue.PdfEngines` (pdfium as a
  precompiled NIF, poppler as fallback when installed).
- **Item picker** — `<.item_picker>` LiveComponent; the parent LV needs
  `handle_info/2` clauses for `{:item_picker_select, id, item}` and
  `{:item_picker_clear, id}`.
- **Item selector + browse stack** — `Components.{ItemSelectorModal,
  CatalogueBrowse, Browse}` over `Catalogue.BrowseState` (a pure reducer). Scope
  is a security boundary fixed at init; selection is only ever for rendered
  uuids; host messages are `{:items_selected, …}`, `{:item_selector_closed, …}`,
  `{:catalogue_browse, …}`. Read the moduledocs before touching selection,
  quantities (native number input, `qty_change` / `qty_commit`), the checkbox
  column, the context header, `show_tray`, or the `show_item_details` page
  (on by default; `false` is the opt-out for exposure-sensitive embeds).
- **Supplier comments** — one `phoenix_kit_comments` thread per item × supplier
  row (`"catalogue_item_supplier"`), keyed on the thread uuid in
  `item_supplier_info.metadata["comment_thread_uuid"]`. Server-owned, survives
  price revisions and removal — removal CLOSES the row, never deletes it. Never
  the CRM company's thread. The admin/activity back-link resolver self-registers
  via `resource_links/0`, so no host config is needed. See
  `Catalogue.SupplierComments`.
- **Catalogue folders** — `Catalogue.list_folder_tree/1`, `move_folder/3`,
  `move_catalogue_to_folder/3` and friends drive the Finder-style tree on the
  index page; soft-delete, plus `delete_empty_folder/2` for a folder with no
  live children.
- **AI translation** — `ai_translatables/0` plus
  `PhoenixKitCatalogue.AITranslatable` integrate with `phoenix_kit_ai`; the
  operator-facing sweep is `Workers.TranslationSweepWorker` driven by
  `Web.Settings` and the Translations page.
- **Extension slot** — `PhoenixKitCatalogue.Extension` is the behaviour a
  sibling implements to add a section to the item/category forms and own a
  namespace under `data`. Discovery is duck-typed through
  `PhoenixKit.ModuleRegistry` (`catalogue_extensions/0`), so an implementer
  never has to depend on this package at compile time and forms without a
  registered extension must render exactly as before.
- **Table stack** — `Web.{TableQuery, TableConfig, TableToolbar, ViewConfig}`
  back the sortable/filterable admin tables; reuse them instead of hand-rolling
  table state in a new LV.

## Versioning & releases

SemVer. The version is single-sourced in `mix.exs` (`@version`); `version/0`
reads it at compile time and the behaviour test asserts against
`Mix.Project.config()[:version]`, so nothing else needs bumping.

Release procedure (the steps the maintainer runs):

1. Bump `@version` in `mix.exs`; add a `CHANGELOG.md` entry headed `## x.y.z - YYYY-MM-DD`.
2. `mix precommit` clean.
3. Commit (`"Bump version to x.y.z"`) and push; verify the push landed.
4. `mix hex.publish`.
5. Tag, matching the form of the newest existing tag (`git tag --sort=-creatordate | head -1` shows it), and push the tag.
6. No GitHub release. `gh release list` stops at v0.19.0 (2026-08-24) even
   though tags have continued through v0.28.1 — releases since then have
   never gotten a `gh release create`, and the CHANGELOG entry is the release
   note instead. Don't create one from the mere presence of older releases in
   the list; that's the same regression this file previously carried before
   being generalized away.

Tags are immutable pointers: never tag before the commit is pushed and the
publish has succeeded.

## Pull requests & commits

- Commit messages start with an action verb (`Add`, `Update`, `Fix`, `Remove`, `Merge`). No AI attribution and no `Co-Authored-By` trailers.
- Version bumps and CHANGELOG entries land with the release commit on upstream, not in feature PRs.
- Review files live in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/{AGENT}_REVIEW.md`, one file per reviewing agent, never edited by another agent; `FOLLOW_UP.md` records how each finding was resolved. Severities: `BUG - CRITICAL/HIGH/MEDIUM`, `IMPROVEMENT - HIGH/MEDIUM`, `NITPICK`.

## TODOs

- Convert the runtime `Gettext.gettext(Backend, "…")` call sites to the macro
  form with `use Gettext, backend: PhoenixKitCatalogue.Gettext` per module.
  Once no runtime-form strings remain, extraction works normally and the
  hand-maintained `.pot` rules above can be dropped.
- Item search uses ILIKE over JSONB with no trigram index. Add one when
  catalogue volumes make the scan visible in page timings.
