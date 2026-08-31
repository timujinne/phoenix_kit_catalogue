# AGENTS.md

Guidance for AI agents working with code in this repository.

## Project Overview

PhoenixKit Catalogue — an Elixir module for product catalogue management, built as a pluggable module for the PhoenixKit framework. Manages manufacturers, suppliers, catalogues, (nested) categories, and items with soft-delete, multilingual names/descriptions, and move operations. Admin-only LiveView UI; no public API surface.

Deep feature documentation lives in module `@moduledoc`s and `dev_docs/` — read the code for semantics; this file only holds conventions and non-obvious boundaries.

## Commands

```bash
mix deps.get                        # install dependencies
mix test                            # all tests (integration auto-excluded without DB)
mix test test/catalogue_test.exs:42 # single test by line
mix precommit                       # compile + format + credo --strict + dialyzer — run before every commit
```

## Dependencies & local cross-repo dev

This is a **library**, not a standalone app. It depends on `phoenix_kit` (core) for Repo, Settings, the Module behaviour, Dashboard tabs, Multilang, and Activity.

`phoenix_kit*` deps resolve from Hex by default. To build/test against a **local checkout** of a sibling dep, export `<APP>_PATH` (dep app name upper-cased + `_PATH`):

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix test
```

Implemented via `pk_dep/3` in `mix.exs` — **never hand-edit a `phoenix_kit*` dep into a `path:` tuple** (a committed path dep ships a broken package); set the env var instead.

## Hard boundaries (deliberate — do not add)

- **No DB migrations in this repo.** Every table is created by versioned migrations in core `phoenix_kit`. Adding a column means a core migration first, then schema + changeset here.
- **No authorization in the context.** Mutating functions accept `actor_uuid` only for activity logging. Permission gating happens at the LiveView mount layer (`live_session :phoenix_kit_admin`, `:catalogue` permission key).
- **Admin-only.** No public routes, JSON endpoints, or webhook receivers. The single HTTP endpoint is the admin-gated, stateless export download (`get /admin/catalogue/export/download`, behind `:phoenix_kit_require_admin`).
- **Soft-delete is the only history mechanism** (`status` field). The activity log is the audit trail; there is no per-item versioning.
- **Only one background job:** `Workers.PdfExtractor` on Oban queue `:catalogue_pdf` (the host must configure that queue). Everything else runs inline — imports via `start_async/1` from the LiveView, change propagation via PubSub.

## Architecture in one minute

Schemas (all use `@primary_key {:uuid, UUIDv7, autogenerate: true}`):

- `Catalogue` — top-level grouping. `kind: "standard" | "smart"`, catalogue-wide `markup_percentage` / `discount_percentage`, status active/archived/deleted. Optional `folder_uuid` files it under a `Folder`.
- `Folder` — module-global, self-nesting tree for organizing catalogues on the admin index (unrelated to media folders). New deletes are empty-only and permanent (`delete_empty_folder/2`); `trash_folder/2` remains for legacy rows and `permanently_delete_folder/2` is the promote-contents escape hatch for those.
- `Category` — belongs to a catalogue; self-nests via nullable `parent_uuid`; position scoped to siblings `(catalogue_uuid, parent_uuid)`.
- `Item` — belongs **directly to a catalogue** (`catalogue_uuid` required) with optional `category_uuid`. Nullable per-item markup/discount overrides: `NULL` inherits the catalogue value, any Decimal (**including `0`**) overrides.
- `ItemSupplierInfo` — per-item supplier purchase info (cost, currency, lead time, primary flag). `supplier_uuid` is a soft reference (no FK) so suppliers can come from other PhoenixKit modules.
- `Manufacturer`, `Supplier`, `ManufacturerSupplier` (M:N join) — hard-delete only.
- `CatalogueRule` — smart-catalogue rule row, `UNIQUE(item_uuid, referenced_catalogue_uuid)`.
- PDF library tables (`Pdf`, extraction, pages, page_contents) layer on core `phoenix_kit_files`; their cache/join tables use content-derived primary keys, not UUIDv7.

Key invariants to preserve:

- `create_item`/`update_item` derive `catalogue_uuid` from `category_uuid` so an item's category and catalogue can never drift; empty-string `category_uuid` normalizes to `nil`.
- Soft-delete trash/restore cascade rules intentionally **differ per entity** (catalogue cascades, category restore doesn't, item restore may uncategorize). Read the existing `Catalogue` functions before touching them — do not "simplify" them.
- Smart-catalogue rules may only reference `kind: "standard"` catalogues (guard in `Rules.build_rule_changeset/2`). Smart items don't use `base_price`/markup/discount — the fee lives in `default_value`/`default_unit` + rules, and `Catalogue.evaluate_smart_rules/2` (`Catalogue.SmartPricing`) is the canonical evaluator consumers should call rather than reimplementing the math.
- Tree/position semantics (orphan promotion, cycle guards, sibling-scoped swap) live in `Catalogue` + `Catalogue.Tree` — reuse them, never hand-write recursive queries in LiveViews.

## Critical conventions

- **Module key** `"catalogue"` everywhere (`module_key/0`, settings keys); admin tab IDs are `:admin_catalogue` (parent) and `:admin_catalogue_*` (subtabs).
- **Single public context** — all business logic goes through `PhoenixKitCatalogue.Catalogue`. Internal submodules (`Catalogue.{Rules, SmartPricing, Search, Tree, Manufacturers, Suppliers, Links, ItemSupplierInfos, Counts, Translations, PubSub, ActivityLog, Helpers, PdfLibrary}`) are an implementation detail re-exported via `defdelegate`; LiveViews and external consumers must not call them directly.
- **Paths** — never hardcode URLs. Use `PhoenixKitCatalogue.Paths` helpers and `PhoenixKit.Utils.Routes.path/1`. URL segments use hyphens, never underscores.
- **Admin routes come from `admin_tabs/0` plus `route_module/0`.** PhoenixKit injects both into its own `live_session :phoenix_kit_admin` / router — never hand-register plugin routes in a host router (loses the admin layout, crashes cross-session navigation). `admin_tabs/0` carries the LiveViews (declare static paths before wildcard `:uuid` paths; `match:` controls sidebar highlighting); `Web.Routes` adds only the stateless export-download GET.
- **Errors API** — context failures return plain atoms, tagged tuples, or changesets; the UI boundary translates via `Errors.message/1` (gettext). A new error atom requires a `message/1` clause plus a pin in `test/errors_test.exs`.
- **Activity logging** — every mutating context function takes `opts` with `actor_uuid:` and logs via `Catalogue.ActivityLog`, which logs only on the `{:ok, _}` branch and must never crash the operation. LiveViews obtain the actor via `actor_opts/1` from `Web.Helpers`. `test/activity_logging_test.exs` pins one test per action atom — extend it for new actions.
- **PubSub** — mutations broadcast `{:catalogue_data_changed, kind, uuid, nil}` on the `"phoenix_kit_catalogue"` topic via `Catalogue.PubSub`.
- **Multilang forms** — name/description go through PhoenixKit `Multilang`. Form LVs use `to_form(changeset)` + a private `assign_changeset/2` (assigns both `:changeset` and `:form`) with component-style `<.input field={@form[:x]}>`. Only translatable fields render inside `<.multilang_fields_wrapper>`. `import_live.ex` is a deliberate exception (runtime-constructed field names).
- **`enabled?/0` must rescue everything** and return `false` (DB may be unavailable at boot).
- **LiveViews use `Phoenix.LiveView` directly** — no `use PhoenixKitWeb` macros in this standalone package.
- **UUIDv7 primary keys** on every entity schema (the content-addressed PDF cache/join tables are the only exception).
- **Soft-delete via `status`** for catalogues/categories/items (`"deleted"`); PDFs use `"active" | "trashed"`; manufacturers/suppliers are hard-delete only.

## Feature areas (pointers, not docs)

- **Pricing** — chain is `base → markup → discount`. `Catalogue.item_pricing/1` is the one-stop API for UIs; pure helpers live on `Item`.
- **Smart catalogues** — `Catalogue.put_catalogue_rules/3` (replace-all, transactional, one `smart_rules.synced` activity), `list_catalogue_rules/1`, `list_items_referencing_catalogue/1` (warn before deleting a referenced catalogue).
- **Search** — `Catalogue.search_items/2` + `count_search_items/2` and scoped wrappers; `:include_descendants` (default true) expands category subtrees. Known perf tradeoff: ILIKE over JSONB, no trigram index — acceptable at current volumes.
- **Attachments** — `PhoenixKitCatalogue.Attachments` wires featured image + per-resource file folder into the catalogue/item forms (category form: featured image only). LVs call `Attachments.inject_attachment_data/2` before save.
- **Metadata** — opt-in fields on items/catalogues stored in `data["meta"]`; definitions in `PhoenixKitCatalogue.Metadata` (labels gettext-wrapped at call time — don't cache them). Unknown stored keys pass through as legacy rows.
- **Import** — `PhoenixKitCatalogue.Import` is a source registry (`Import.Source.Universal` for CSV/XLSX, `Import.Source.Pro100` for Pro100 cabinet-software data); execution goes through `Import.{Mapper, Executor}` + the `ImportLive` wizard (ETS buffering).
- **Export** — `PhoenixKitCatalogue.Export.build/1` with destination/format registry (Universal JSON, Pro100); UI in `ExportLive`, download via the admin-gated `ExportController`. Inbound mirror of the import sources.
- **PDF library** — `Catalogue.PdfLibrary` + `Workers.PdfExtractor`. Content-hash dedup on core `phoenix_kit_files`; search = literal ILIKE then trigram fallback. `enqueue_extraction/1` fails visible when the host Oban queue is missing; `requeue_stuck_extractions/1` is the operator-driven heal for stuck rows.
- **Item picker** — `<.item_picker>` LiveComponent; the parent LV needs `handle_info/2` clauses for `{:item_picker_select, id, item}` / `{:item_picker_clear, id}`.
- **Item selector + browse stack** — `Components.{ItemSelectorModal, CatalogueBrowse, Browse}` over `Catalogue.BrowseState` (pure reducer). Scope is a security boundary fixed at init; selection only for rendered uuids; host messages `{:items_selected, …}` / `{:item_selector_closed, …}` / `{:catalogue_browse, …}`. The moduledocs are the contract — read them before touching selection, quantities (native number input, `qty_change`/`qty_commit`), the checkbox column, the context header, `show_tray`, or the `show_item_details` page (ON by default since 2026-08-31; `false` is the opt-out for exposure-sensitive embeds).
- **Supplier comments** — one `phoenix_kit_comments` thread per item × supplier row (`"catalogue_item_supplier"`), keyed on the thread uuid in `item_supplier_info.metadata["comment_thread_uuid"]` — server-owned, survives price revisions and removal (removal CLOSES the row, never deletes it). Never the CRM company's thread. The admin/activity back-link resolver is self-registered via `resource_links/0` — no host config. See `Catalogue.SupplierComments`.
- **Catalogue folders** — `Catalogue.list_folder_tree/1`, `move_folder/3`, `move_catalogue_to_folder/3` etc. drive the Finder-style tree on the index page; soft-delete, plus `delete_empty_folder/2` hard-deletes a folder with no live children.
- **AI translation** — `ai_translatables/0` + `PhoenixKitCatalogue.AITranslatable` integrate with the optional `phoenix_kit_ai` sibling (override with `PHOENIX_KIT_AI_PATH` for local dev).
- **Table stack** — `Web.{TableQuery, TableConfig, TableToolbar, ViewConfig}` back the sortable/filterable admin tables; reuse them instead of hand-rolling table state in new LVs.

## Testing

- `config/test.exs` sets `config :phoenix_kit, repo: PhoenixKitCatalogue.Test.Repo` — without it, all DB calls through `PhoenixKit.RepoHelper` crash.
- `test/test_helper.exs` runs `PhoenixKit.Migration.ensure_current/2` for schema setup — do **not** replace it with `Ecto.Migrator.run([{0, PhoenixKit.Migration}])` (silently goes stale).
- Integration tests (via `DataCase` / `LiveCase`, tagged `:integration`) are automatically excluded when no database is available.
- Test support: `support/data_case.ex`, `support/live_case.ex` (Test.Endpoint + router scoped at `/en/admin/catalogue`), `support/activity_log_assertions.ex`.
- `database:` / `pool_size:` in `config/test.exs` read `PGDATABASE` / `PGPOOL`, falling back to the hardcoded `phoenix_kit_catalogue_test` name and `System.schedulers_online() * 2` when unset — same mechanism core `phoenix_kit`'s `config/test.exs` uses. Set both to point this suite at a database it doesn't own and can't `CREATEDB` for itself (e.g. a shared instance also used by sibling `phoenix_kit_*` modules): `PGDATABASE=migration_test_db PGPOOL=6 mix test`.
- **Caution:** if `PGDATABASE` points at a database other modules also use, don't combine it with `PHOENIX_KIT_PATH=../phoenix_kit` (local core checkout) — `test/test_helper.exs`'s `ensure_current/2` call would then run *that* core's migration chain against the shared database, moving its schema for every other module pointed at the same `PGDATABASE`, not just this suite.

## Versioning & releases

SemVer. The version lives in **two places** — bump both: `mix.exs` `@version` and `PhoenixKitCatalogue.version/0`. `test/phoenix_kit_catalogue_test.exs` pins them equal, so a missed bump fails the test.

- Update `CHANGELOG.md` before releasing, using [Keep a Changelog](https://keepachangelog.com/) categories (`Added`, `Changed`, `Fixed`, `Removed`).
- Tags are bare version numbers (`git tag 0.1.1`). Create the GitHub release with `gh release create` titled `<version> - <date>`, notes from the changelog section. Never tag before all changes are committed **and pushed**.
- Commit messages start with `Add`, `Update`, `Fix`, `Remove`, or `Merge`.
- Run `mix precommit` before committing.
- PR review files go in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/{AGENT}_REVIEW.md` (see `dev_docs/pull_requests/README.md`).

## Misc

- **Tailwind:** `css_sources/0` returns `[:phoenix_kit_catalogue]` so the host's `app.css` scans this module's templates.
- **JS hooks:** shared hooks (RowMenu, SortableGrid, InfiniteScroll, …) come
  from phoenix_kit core's `window.PhoenixKitHooks`. **This module also ships
  two of its own** — `CatalogueTreeDnD` and `ViewPref`, in
  `priv/static/assets/phoenix_kit_catalogue.js`, declared by `js_sources/0`
  under the global `PhoenixKitCatalogueHooks`. (This line used to say the
  module ships none, which would lead a host to skip the
  `:phoenix_kit_js_sources` compiler entry — at which point tree
  drag-and-drop and view-preference persistence die with
  `unknown hook found for "…"` and nothing else.) A hook must reach the
  LiveSocket at construction, so never register one from an inline
  `<script>`: morphdom does not execute an inserted script tag, so it works
  on a hard load and silently does nothing on a LiveView navigation. The
  item picker uses a colocated hook (`Phoenix.LiveView.ColocatedHook`)
  instead, which the host reaches via `phoenix-colocated/phoenix_kit_catalogue`.
- **Gettext:** the module has its own backend, `PhoenixKitCatalogue.Gettext` — use it (not `PhoenixKitWeb.Gettext`) for new strings.

  ⚠️ **Do not regenerate `priv/gettext/default.pot` from scratch — it is
  hand-maintained, and a from-scratch extraction produces 47 of its 961
  msgids.** Almost every string here is the *runtime function* call
  `Gettext.gettext(PhoenixKitCatalogue.Gettext, "…")` (~1100 sites) rather
  than the `gettext("…")` macro, and the extractor only sees macros. Add new
  msgids **by hand** to `default.pot` and to each of `en`/`et`/`ru`, and pin
  them in `test/gettext_test.exs`.

  **The trap that makes this worth spelling out** (measured 2026-08-29, and I
  got it wrong the first time): `mix gettext.extract` **merges into** an
  existing `.pot` rather than replacing it. Run it with the committed file in
  place and it reports a near-identical catalogue — 959 of 960 msgids
  "extracted" — because it *kept* them. That looks like proof the warning is
  stale. It isn't: delete the `.pot` first and the same command yields 47.
  Only 46 of the committed entries carry `#, elixir-autogen`, which is the
  honest count of what extraction actually contributes.

  So `mix gettext.merge priv/gettext` is safe **only** while the `.pot` still
  holds the hand-added entries. Against a freshly regenerated one it would
  strip ~914 msgids from all three `.po` files, since `on_obsolete: :delete`
  is the default.

  One narrower gap worth knowing: the runtime form is **not** extracted from
  inside a HEEx attribute interpolation (`title={Gettext.gettext(…)}`) even
  when the module carries `use Gettext`. `web/components.ex` now uses the
  macro there for that reason.

  The real fix remains converting the call sites to the macro form and adding
  `use Gettext, backend: PhoenixKitCatalogue.Gettext` per module, at which
  point extraction works normally. Six files already do
  (`web/table_config.ex`, `web/catalogues_live.ex`, `web/components.ex`, and
  the three browse/selector components). Until then, treat the catalogues as
  hand-edited files.

- **Settings keys:** `catalogue_enabled`.
