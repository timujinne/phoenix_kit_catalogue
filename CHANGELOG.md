## 0.19.0 - 2026-08-24

### Added

- **Per item × supplier comment threads** (#78) — a comment on an attached
  supplier is filed on its own `phoenix_kit_comments` thread
  (`"catalogue_item_supplier"`), not the CRM company's. The thread uuid
  lives in `item_supplier_info.metadata["comment_thread_uuid"]`, survives
  price revisions, and is resumed when the same supplier is re-attached.
  Removing a supplier **closes** the row (`valid_to`) instead of deleting
  it. `resource_links/0` registers the Comments-admin / Activity back-link
  resolver with core — no host config line. Requires
  `phoenix_kit_comments` at runtime for the UI; it is a test-only Mix dep
  so the library still compiles without the package.
- **Bulk Move and Duplicate for categories and items** on the catalogue
  page, plus a **Supplier price** column (min–max of current supplier
  rows, currencies listed separately). `Catalogue.Duplication` copies an
  item with its multilang data (names suffixed per language), current
  supplier rows (fresh comment thread), attribute-set attachments,
  catalogue rules, and a new Storage folder of `FolderLink`s to the
  source's files. A category copy brings its subtree.
- **Live refresh** of remaining stale surfaces: bulk ops on other tabs,
  attachment uploads/removals, AI translations, the import wizard's crash
  path, orphan-attachment prunes, the PRO100 loader (broadcasts after
  commit), supplier-row writes, and the item form (supplier rows, files,
  categories).

### Fixed

- **Bulk actions accepted a uuid from another catalogue** — every bulk
  path on the catalogue page now takes the page's catalogue as a scope
  (`:wrong_catalogue_scope` per entry).
- **Modal disposition/target handlers crashed with `KeyError`** after the
  modal closed (`%{modal | …}` on `%{}`).
- **Duplication logged activity inside the transaction** (core's
  `Activity.log/1` inserts and broadcasts at once) and stamped `"(copy)"`
  in the acting admin's locale into every language. Logs are flushed
  after commit; the suffix is rendered per language (`"(koopia)"`,
  `"(копия)"`).
- **`push_event("bulk_select:clear")` is a no-op in core's
  `BulkSelectScope` hook** — the scope id carries a `bulk_epoch` that
  remounts it after every bulk op. Core follow-up: add the handler.
- **`<select phx-change>` pickers sat outside a `<form>`**, which
  LiveView 1.2's JS rejects — the choice never reached the server.
- **`set_primary/2` / `revise_unit_cost/3` raced a concurrent close** —
  both now lock-reload under `FOR UPDATE`. Category Duplicate takes
  `FOR SHARE` on the target parent, matching `create_item`.
- **`trash_category(items: {:move_to, child})` left live items in a
  deleted category** — refused as `:move_target_in_subtree`; pickers
  accept only offered targets.
- **A first file upload in another tab did not appear** on a form that
  had no `files_folder_uuid` yet — `Attachments.refresh_files/1` now
  resolves the deterministic folder name.
- **Item-form delete / set-primary / history accepted a uuid from
  another item's supplier row** — scoped to rows this form rendered,
  same as the comments action.

See [PR #78](dev_docs/pull_requests/2026/78-supplier-threads-live-refresh-bulk-actions/GROK_REVIEW.md)
for the full findings.

## 0.18.0 - 2026-08-22

### Added

- **Item selector modal and embeddable browse components** (#76) — a
  client-facing "pick items with quantities" modal (the catalogue's
  `MediaSelectorModal` analogue) plus the stack it is assembled from:
  `Catalogue.BrowseState` (pure reducer, no process), `Web.Components.Browse`
  (card / grid / chips / qty stepper), `ItemSelectorModal`, and
  `CatalogueBrowse` for a scoped catalogue surface on any logged-in page.
  Scope is a security boundary (`search_items/2` vocabulary, including
  `:statuses` and `:include_descendants`); quantities are Decimal end to
  end; confirm hands the host a display snapshot (re-price server-side).

### Fixed

- **`:statuses` on `search_items/2` was documented and then ignored** —
  `BrowseState` forwarded it, Search never read it, so
  `statuses: ["active"]` still listed inactive/discontinued items and the
  picker would select them. Search now filters; atoms stringify;
  soft-deleted rows stay excluded.
- **Picker hydration crashed on an uncategorized preselect** against a
  `category_uuids` / `:categorized_only` scope (`to_string(nil)`), and
  `:categorized_only` itself was missing from the availability check —
  the hole `:uncategorized_only` already had a pin for.
- **Descendant-category preselects were marked unavailable** even though
  Search expands parent scopes by default, so an order line in a nested
  category silently dropped on confirm.
- **Cards showed `base_price`, not the selling price** — `present_items/2`
  now uses `Catalogue.item_pricing/1`'s `final_price`, matching
  `ItemPicker`. Starting qty is 1; `Item.default_value` is the
  smart-catalogue fee fallback, not a pick quantity.
- **Invalid quantity commits did not recreate the input** — the
  documented per-row revision that forces morphdom to drop typed garbage
  was never incremented.
- **Category chips preloaded every item in the catalogue**; preselect
  hydration was N+1 `get_item/1` and could confirm a deleted row.
  Chips now use the metadata listing; hydration uses
  `list_items_by_uuids/2`.
- **`CatalogueBrowse` lacked the picker's event catch-all and scope-key
  validation** — a crafted payload or a string-keyed scope could crash
  the host LV or silently widen browsing. Both live in `BrowseState.init/1`
  now.
- **Declare `rustler` as an optional Hex dep** (#77) so `mdex_native`
  can force-build its NIF from source (`MDEX_NATIVE_BUILD=1`) on OTP 28,
  which ships no precompiled artefact. Same declaration core
  `phoenix_kit` already carries.

See [PR #76](dev_docs/pull_requests/2026/76-item-selector-and-browse-components/GROK_REVIEW.md)
and [PR #77](dev_docs/pull_requests/2026/77-rustler-declare/GROK_REVIEW.md)
reviews for the full findings.

## 0.17.0 - 2026-08-19

### Added

- **Attribute sets** (#74) — replaces the old group→attribute→value
  hierarchy with **sets**: one dimension from one vendor ("Ikea colors"),
  stored as managed `phoenix_kit_entities` blueprints. Items attach any
  number of sets (a door can carry "Ikea colors" + "Ikea widths") through a
  new catalogue-owned join table (`phoenix_kit_cat_item_attribute_sets`,
  shipped in core `phoenix_kit`; this repo adds no migration). A per-value
  extras mechanism (`fields_definition` on the blueprint — "price per
  liter", "drying time", ...) lets admins add fields to a set without code
  or a migration. New `Catalogue.AttributeSets` context, `AttributeSetFormLive`
  editor, multi-set attach/detach/reorder UI in the item form, and a
  product card that renders N sets instead of one group. Legacy groups
  auto-migrate to sets on boot; the old group tables and UI stay in place,
  read-only, as a fallback. Requires `phoenix_kit_entities ~> 0.4`
  (`entities_enabled` setting must be turned on).
- **Catalogues toolbar**: the card/comfy/table view-mode toggle moved from
  the Active/Deleted trash-tabs row into the toolbar's view-tools cluster,
  next to "Columns" (#73) — it's a "how am I viewing this list" control, not
  a trash-visibility one, and previously only showed up paired with the
  trash tabs.

### Fixed

- **Attribute-set mutations didn't broadcast PubSub** — every other context
  module in this library fans out a `Catalogue.PubSub` event on every write;
  `AttributeSets` shipped with none, so a second open admin session (or a
  second tab) never saw live updates to sets, values, or item attachments
  without a full page reload. Set/value/field CRUD now broadcasts
  `:attribute_set`; item attach/detach/reorder/selection changes now
  broadcast `:item` scoped to the item's catalogue, matching the legacy
  group-assignment broadcast this replaces.
- **`update_attribute_set/3` could persist a default value pointing at
  nothing** — a stale form resubmit (or any future non-UI caller) could set
  `default_value_slug` to a slug with no matching value record, and the
  resolved read path would hand every consumer (product card, order-line
  resolution) a ghost default with no error. The write now validates the
  slug against the set's current values and returns
  `{:error, :contract_broken}` instead.
- **The set editor silently swallowed a failed value-reorder write** —
  `reorder_values` now flashes an error like every other mutation in the
  same LiveView, instead of just snapping the drag back to the stored order.
- 12 new attribute-set error atoms (`:contract_broken`, `:set_in_use`,
  `:not_attached`, etc.) now have central `Errors.message/1` translations
  and test pins, per this library's error-atom convention — previously only
  covered by ad hoc local flash text in the two call sites that happened to
  handle them.

### Changed

- `phoenix_kit_entities` bumped `0.4.2` → `0.4.3` in `mix.lock` — `0.4.2`
  doesn't ship `Components.FieldInput`, which the new set editor imports, so
  a clean `mix deps.get` from Hex failed to compile. `mix.exs`'s `~> 0.4`
  constraint already allowed it; this is a lock-file update only.

See [PR #73](dev_docs/pull_requests/2026/73-view-toggle-toolbar/CLAUDE_REVIEW.md)
and [PR #74](dev_docs/pull_requests/2026/74-attribute-sets-rework/CLAUDE_REVIEW.md)
reviews for the full findings.

## 0.16.2 - 2026-08-16

### Added

- **PDF content search** (#70) — `Catalogue.PdfLibrary.search_pdf_contents/2`
  searches the extracted text of every PDF, not just filenames, grouped by
  PDF with match snippets; `more_pdf_content_matches/3` paginates within a
  single PDF's pages. Reachable from a dedicated search modal on the PDF
  library page, kept separate from the existing filename search.

### Fixed

- **Multilang forms dropped typed-but-unsaved primary-language text** when
  `validate`/`save` fired from a secondary-language tab (#70) — primary
  `name`/`description` fields are only submitted from the primary tab, so a
  secondary-tab event was rebuilding the changeset without them. Fixed in
  the attribute group, catalogue, and category forms via `@preserve_fields`
  threaded into `merge_translatable_params/4`; locked in by a source-scan
  conformance test asserting every call site passes it.
- **PDF search snippets could be off-center on multi-byte text** (#70) — the
  match offset from `:binary.match/2` is a byte offset, but the snippet
  slice counted graphemes; for Cyrillic/accented text this centered the
  window past the actual match. Snippet building now converts to a
  grapheme offset first.
- **The item form's Attributes-tab group dropdown always showed the
  primary-language name**, not the viewer's locale, even after #70 fixed
  the same class of bug for catalogue/category/item lists. Missed
  `Catalogue.localize/2` pass in `assign_attribute_state/3`; see
  [PR #70 review](dev_docs/pull_requests/2026/70-pdf-content-search-multilang-handover/CLAUDE_REVIEW.md).

### Changed

- Core `phoenix_kit` dependency bumped to `2.8.1` in `mix.lock`.
- **Handover close-out** (#70) — `CatalogueTreeDnD`'s folder drag/drop moved
  from an inline template `<script>` (which dies on LiveView navigation)
  into `priv/static/assets/phoenix_kit_catalogue.js`, shipped via a new
  `js_sources/0` under a `PhoenixKitCatalogueHooks` global. Combobox
  template indentation cleaned up in `item_picker.ex`.

## 0.16.1 - 2026-08-16

### Changed

- **Form action buttons use core's `<.button>`** (#69/#68) in the
  manufacturer, supplier, catalogue, and category forms, replacing
  hand-written `class="btn …"` markup so sizing, disabled state, and the
  focus ring track the component. `item_form_live` and
  `attribute_group_form_live` are deliberately untouched — both tune
  styling per place. Requires core `phoenix_kit` `~> 2.8`, where
  `<.button>`'s `navigate` / `variant` / `size` attrs and the status
  variants live (already the pinned floor).

### Fixed

- **The "Delete Forever" buttons rendered `btn-primary` and `btn-error`
  together** on the catalogue and category danger zones. `variant`
  replaces the base colour rather than being suppressed by `class`, so
  `class="btn-error"` left both colour classes on the element and the
  compiled stylesheet's ordering — not the markup — decided which won.
  Both now pass `variant="error"`. Pinned in
  `test/web/form_lives_test.exs`, alongside a check that the core
  button's `:rest` global keeps forwarding the submits'
  `name="save_action"` / `value`.

## 0.16.0 - 2026-08-16

### Added

- **Folders as a file explorer** on the catalogues index (#67). Inline
  tree with drill, chevrons, Up row, and drop-anywhere drag-and-drop;
  card view mirrors the tree as folder group boxes. Folders and
  catalogues share one interleaved manual order per level
  (`place_level_rows/2`). New folders sort to the front of their level;
  empty folders delete permanently (`delete_empty_folder/2`).
- **In-app PDF text extraction** via pdfium (`ex_pdfium` precompiled
  NIF) with poppler as a fallback when installed. Hosts no longer need
  system packages for PDF search. The winning engine is recorded on the
  `pdf.extracted` activity.

### Changed

- **Admin headers** use the core breadcrumb (`page_crumbs`). The detail
  page trail lives in the header; the in-page slot is the level
  description. Add Category is root-only; categories append at creation;
  columns editors are live (no Apply).
- **Item picker reopen** browses the empty-query first page when the
  input still holds the selected item's name (#63 follow-up).
- Catalogue/folder position writers share one `pg_advisory_xact_lock`
  (issue #56), including create/move/delete — not only the three
  reorder functions.
- **Minimum `phoenix_kit` raised to `~> 2.8`** — headers, live columns,
  and UrlState (#719) live there. 2.3–2.7 fail `warnings-as-errors`.

### Fixed

- **Oban PDF retries were a no-op.** `fail/2` marked the row `failed`
  and the next attempt short-circuited as success, so `max_attempts: 3`
  never re-ran. Failed rows stay retryable until the last attempt;
  `mark_extracted` / `mark_scanned_no_text` errors now propagate.
- **`page_count == 0` was stored as a successful extraction**, which
  blocked retry. pdfium/poppler now treat an empty document as an open
  failure and continue the chain.
- **New folders/catalogues ignored the other type** when picking a
  position, so a catalogue filed into a folder-only level (or a folder
  created on a catalogue-only level) landed in the middle of the
  interleaved order.
- **`category_uuids_with_children(:deleted)` counted active children**,
  lighting a chevron whose deleted-view child list was empty.
- **`place_level_rows/2`** rejected nothing: mixed-level payloads
  rewrote another level's positions, and an unknown type crashed the
  LiveView inside the transaction.
- **“Reorder all” in the folder tree** rewrote a global catalogue
  `1..N` and undid the interleaved per-level order. The button and
  handler are flat-list only now.
- **Detail-page column editor** overwrote the other table's columns on
  the next save (`custom_fields` is a whole-column write; the user
  snapshot was stale).
- **A stale folder filter** after deleting or watching another tab
  hide the tree and empty the flat list.

## 0.15.1 - 2026-08-15

### Fixed

- **Reopening the item picker for an already-loaded item showed an empty
  list** (#63 / L027). `handle_event("open", …)` only re-ran search when both
  `options` and `query` were empty. After a page reload `update/2` mirrors the
  selected item's name into `:query`, so the guard never fired and focus
  opened "No items found" instead of a list. Search now re-runs whenever
  `options == []`. A live pick in the same process was unaffected (`options`
  still held the search that led to the selection). After reload the list is
  a name-search (typically the current item); edit or clear the input to
  browse replacements.

- **Price-less option rows crashed with `BadBooleanError`.** The row's
  `:if` used `price && price != ""` as the left operand of `or`; a `nil`
  price is not a strict boolean. Unreachable while reopen left `options`
  empty; reachable for any item without a `base_price` once that path
  filled the list. The guard is now `(price != nil and price != "")`.

### Documentation

- **`HANDOVER.md`** (#62). Status of the LAISK-loop work, the consumer
  contract for `photo_clickable` (a host that opts in must handle
  `{:item_picker_photo_click, …}` or the click crashes its LiveView), and
  what was designed but not built: product attributes / characteristics
  (L028) and a PhoenixKit form-component pass (L029). Those stay for a
  later version.

## 0.15.0 - 2026-08-14

### Added

- **Item photo preview in the item picker.** When a picked catalogue item has
  a featured (main) image, `<.item_picker>` now renders its thumbnail to the
  left of the input — the per-position preview for the sub-order positions
  list. Items without a photo render as before. The thumbnail is an opt-in
  navigation hook via the new `photo_clickable` attr (default `false`).
- **Product card opened from the preview.** Clicking the thumbnail opens a
  read-only product card entirely inside the picker (opt in with
  `photo_clickable={true}`; the host must also handle the upward
  `{:item_picker_photo_click, …}` message with a `handle_info/2` clause or a
  catch-all, or the click crashes its LiveView): a core `<.modal>` with a
  "one expanded" image
  gallery (main image large, a thumbnail strip of the item's other images,
  switching on click) and the item's filled fields (SKU, price, unit,
  description, metadata); empty fields are hidden. Exposed as the function
  component `PhoenixKitCatalogue.Web.Components.ProductCard.product_card/1`
  with public `resolve_images/1`, `resolve_name/2`, `build_fields/2` helpers.

### Fixed

- **PRO100 re-import could clobber a photo attached mid-flight.** The Apply
  step wrote the item's `data` from the plan snapshot taken at preview time, so
  a `featured_image_uuid` (or `files_folder_uuid`) attached between preview and
  Apply was lost. Apply now re-reads the item and merges only the plan's own
  `data` changes onto its current `data`, matching the merge-under-`"pro100"`
  pattern already used by the PRO100 template loader.

- **A `photo_click` with nothing selected sent `{:item_picker_photo_click, id,
  nil}` upward.** The handler guarded on `photo_clickable` but not on there
  being an item, and the message fired before the card-opening path (which was
  already nil-safe) could ignore it — so a host matching the documented
  `%Item{}` shape crashed. The event is now inert unless both hold, which makes
  the message's third element the `%Item{}` the moduledoc promises.

- Removed two clauses dialyzer reported as unreachable (`open_card/2`'s nil
  fallback, made dead by the fix above, and `read_uuid/2`'s non-map fallback,
  already dead since both call sites sit under an `is_map/1` guard). `mix
  precommit` now exits 0.

### Changed

- **Minimum `phoenix_kit` raised to `~> 2.3`** — the product card uses
  `Core.Modal`/`PkDialog` and `Storage.list_files_in_scope/2`, which ship in
  2.3.

## 0.14.1 - 2026-08-12

### Fixed

- **`PhoenixKitCatalogue.version/0` reported `0.13.0` in the 0.14.0 release.**
  The version lives in both `mix.exs` and a hardcoded `version/0`, and 0.14.0
  moved only the first — so the published package reported a version it was
  not. Both move together here. The repo's own
  `version/0 stays in sync with mix.exs @version` test catches this and is not
  database-gated, so it was already failing on `main`; run `mix test` (not only
  `mix precommit`, which runs no tests) before publishing.
- **Missing translations on the Export page** (#57). `Export Items` had `en`
  and `ru` entries but no `et` one, and four further strings — `Destination`,
  `Format`, `Select a format...`, and `Add the catalogue name to the item
  name` — were in no locale at all, leaving Russian and Estonian admins with
  raw English on that page. `Format` and `Select a format...` are shared with
  the Import page. The `en` entry for the pre-existing `Manual order` strings
  was also missing; harmless while the English text matches the msgid, but a
  trap the moment the source string changes.

### Added

- **`PGDATABASE` / `PGPOOL` overrides for the test suite** (#58).
  `config/test.exs` reads both from the environment, falling back to the
  previous hardcoded database name and `System.schedulers_online() * 2`.
  Without them the only way to run the `:integration` half of the suite was a
  Postgres role holding `CREATEDB`, which shared and managed instances
  withhold. Same mechanism core `phoenix_kit` already uses; CI and local runs
  are unaffected.

### Documentation

- `AGENTS.md` now warns that **`mix gettext.extract` / `mix gettext.merge` must
  not be run in this repo.** Nearly every string here uses the runtime
  `Gettext.gettext(PhoenixKitCatalogue.Gettext, "…")` form (~891 call sites)
  rather than the `gettext("…")` macro (~7), and extraction only sees macro
  calls — so a regenerated `.pot` would hold ~7 entries instead of 336, and a
  following `merge` (which defaults to `on_obsolete: :delete`) would strip the
  other ~329 from all three locales. The catalogues are hand-maintained until
  the call sites are converted to the macro form.

### Changed

- Dependency updates: `phoenix_kit_ai` 0.19.0, `phoenix` 1.8.11,
  `beamlab_ex_aws_sqs` 5.0.1, `xai` 0.2.1, `hackney` 4.7.4.

## 0.14.0 - 2026-08-11

### Added

- **Manual ordering is back on the catalogues index** (#53). It was lost in
  `5a01d13`, which replaced the folder tree (and its reordering) with a flat
  sortable table: `Catalogue.reorder_catalogues/2` survived that commit but lost
  its only caller, so the `position` column kept existing with nothing able to
  write it. It returns as a sort option rather than a separate mode — "Manual
  order" is a sort-only pseudo column (`managed?: false`), so it appears in the
  sort dropdown without ever becoming a grid column.

  Drag handles appear only in the unfiltered, unsearched "active" view, because
  `reorder_catalogues/2` re-indexes exactly the list it is handed into `1..N`
  with no scope check — reordering a filtered subset would renumber only the
  visible rows and collide with everything outside the filter.

### Fixed

- **`priv/` is now shipped in the Hex package.** It never was, which broke two
  things for anyone installing from Hex rather than from a checkout: every
  string rendered in English because `priv/gettext` was absent, and the PDF
  viewer failed to load because both delivery routes for `priv/static/pdfjs/`
  (the host's `Plug.Static` mount and core's `PdfViewerController` fallback)
  read those assets out of the installed package. Same defect as
  `phoenix_kit_manufacturing` #9 and `phoenix_kit_warehouse` #17.

- **Reordering was only guarded on the way in, not on the way back.** The drag
  handles were correctly hidden outside manual order, but
  `handle_event("reorder_catalogues", …)` acted on whatever it received. A hook
  event is a client message — it can be pushed directly, and it can arrive after
  the user has applied a filter or switched view — so the renumbering could still
  run against a subset and produce exactly the duplicate `position` values the
  handle restriction exists to prevent. The handler re-checks the same condition
  before writing.

- **Applying a column selection no longer drops the active sort.** It reset
  `sort_by` whenever the sorted column wasn't among the *displayed* ones;
  sorting doesn't require a column to be displayed, and both "name" and
  "position" are deliberately never in that list.

## 0.13.0 - 2026-08-10

### Changed

- **⚠️ Requires `phoenix_kit ~> 2.0`.** The core pin moved to `~> 2.0`, so this
  release no longer resolves against core 1.7.

  Core 2.0.0 squashes the migration chain into a single `V135` baseline and makes
  V135 the chain's floor: `mix ecto.migrate` now *refuses* on a database below it
  rather than migrating. Check `mix phoenix_kit.status` **before** upgrading. A
  host below V135 must install `phoenix_kit 1.7.236` — the migration bridge, the
  last release carrying the full pre-squash chain — migrate until the reported
  version is at least V135, and only then move to 2.0.

  This package does not call migration internals, so the change is the pin
  itself.

- `phoenix_kit_ai` raised to `~> 0.18` in step. Its 0.18.0 is the first release
  requiring core 2.0, so the old `~> 0.4` pin could only have resolved an ai
  that still required core 1.7 — an unsatisfiable set alongside `phoenix_kit ~> 2.0`.

## 0.12.5 - 2026-08-06

### Added
- **PRO100 rows that match nothing can now be created instead of dropped** (#50) — the sync preview lists every unmatched row with its name, SKU, price and category alongside `price?` / `unit?` flags, behind a checkbox that defaults on only when there is nothing to update (the fresh-price-list case). Creates run through the universal `Import.Executor`, so category get-or-create, activity logging and the roll-up PubSub event behave exactly as in a normal import. Rows left uncreated are still accounted for in the report as `:not_imported` rather than vanishing.
- **PRO100 rows are matched by code *and* name** (#50) — the file's numeric code is our SKU reduced to digits, which is lossy: `73.U767.18` and `73.U767.PM.18` both become `7376718`, and on a real export 28 codes were shared by 62 rows that could therefore never be updated. `Import.Matcher` now indexes both `{digits, name}` and `digits`, resolving on the pair first and falling back to the code alone when it is unique — the name decides when the code cannot, the code still decides when the name has drifted. Items whose SKU carries no digits are skipped in both indexes, so a code-less file row can never match a SKU-less item by name alone.
- **A PRO100 export spanning several groups no longer bleeds across catalogues** (#50) — rows are prefixed with their group (`Andi Karkass / MP U741 …`); one whose group is not the selected catalogue's name is refused as `:foreign_group` *before* matching runs, so a foreign row can never resolve onto a local item through a colliding lossy code. The separator must be whitespace-padded, because article codes contain bare slashes (`MP U767 PM/ST9 18mm`).
- **PRO100 estimate-template layer** (#50) — `Import.Pro100TemplateParser` (Saxy; xmerl rejects the export, which declares no encoding and carries Estonian and Cyrillic text), `Import.Pro100TemplatePlan` and `Import.Pro100TemplateLoader` read PRO100's `configTables` price template into folder / catalogues / categories / items / smart rules, idempotently and with `dry_run: true` by default. New direct dependency: `{:saxy, "~> 1.6"}`. **Not yet wired to any caller** — see Notes.

### Changed
- **`phoenix_kit` floor raised to 1.7.231** (#51) — three LiveViews `use PhoenixKitWeb.Live.UrlState`, which first shipped in that release; the declared requirement still named 1.7.189, a range that admits a core with no such module and a consumer build that fails to compile. Contract correction only — `mix.lock` already carried a newer core. Constraints stay loose above the floor.
- **`Import.Executor.execute/4` accepts `notify_pid: nil`** (#50) — for callers that run it inline and read the returned result map. Both `{:import_progress, _, _}` and `{:import_result, _}` are then skipped; `ImportLive`'s PRO100 branch needs this, since a delivered `{:import_result, _}` would flip the operator onto the universal import's `:done` screen instead of the sync report.

### Fixed
- **PRO100 force-create was unreachable for every prefixed row, and misfiled the rest** (#50 post-merge) — the group prefix was passed through as the category to create, but a group only survives the foreign-group guard when it *is* the selected catalogue's name. So a prefixed row either went to `:foreign_group` and was never created, or was created inside a category duplicating the catalogue's own name — while the unprefixed rows of the same export landed at the catalogue root. A checked group now yields no category, so created rows sit at the root exactly like unprefixed ones; the prefix is still stripped from the item name. This also removes the `_category_name`-must-appear-in-`categories_to_create` drift hazard for the UI path, since that list is now always empty.
- **`Executor.execute/4`'s `@spec` still forbade the `nil` the change exists to pass** (#50 post-merge) — dialyzer rejected the `ImportLive` call outright and declared the created-row error reporter unreachable as a consequence.
- **Two return types drifted from what the functions return** (#50 post-merge) — `Pro100TemplatePlan.build/2` returns a `:problems` key absent from `@type t()` (a dialyzer `invalid_contract`), and `Pro100TemplateLoader`'s `@type report()` omitted `:rules`.
- **`mix precommit` failed on merged `main`** (#50 post-merge) — two of the new files were unformatted and three functions tripped credo `--strict`'s nesting check, on top of the two dialyzer errors above. Formatting applied; the nesting sites extracted into named private functions.

### Notes
- **The PRO100 estimate-template layer has no caller yet.** `Pro100TemplateParser` / `Pro100TemplatePlan` / `Pro100TemplateLoader` reference only each other — no LiveView, no mix task. It ships because the measurements encoded in it (708 rows across 10 tables; `//TableItem` yields 1876 because 584 rows are serialised twice under `SumTables`; `TableId` is `0` on 707 of 708 rows) are worth preserving with the code, but nothing in the app reaches it. Where it belongs — a mix task, a fourth `Import.Source`, an admin screen — is still open.
- **Tests added:** 22 for the template parser and plan (`test/phoenix_kit_catalogue/import/pro100_template_test.exs`), pinning the `SumTables`-snapshot exclusion, section/sub-heading detection, gross→net conversion, price recovery from the name, the computed row splitting into its own smart catalogue, and `problems/1`. `Pro100TemplateLoader` remains untested — it is pure database work.
- **The PRO100 LiveView integration tests were asserting the pre-guard behaviour** and could not fail, being auto-excluded without a database. They now match the merged code and a fourth test pins the foreign-group refusal end to end. They have **not** been executed — see Verification.
- Reviews: `dev_docs/pull_requests/2026/50-pro100-sync-key/CLAUDE_REVIEW.md`, `dev_docs/pull_requests/2026/51-core-version-floor/CLAUDE_REVIEW.md`.
- Verification: `mix precommit` is clean (compile `--warnings-as-errors`, `deps.unlock --check-unused`, `hex.audit`, `format --check-formatted`, `credo --strict`, `dialyzer`). `mix test` runs 572 tests + 2 doctests with 803 `:integration` tests excluded — no Postgres in this environment — so the four `import_live_pro100_test.exs` force-create tests are unverified end to end. Get a Postgres-backed run before treating the PRO100 create path as validated.

## 0.12.4 - 2026-08-05

### Added
- **The catalogue list search and filters now live in the URL** (#49) — `CatalogueDetailLive`, `CataloguesLive` and `PdfLibraryLive` adopt core's `PhoenixKitWeb.Live.UrlState` (`:patch` mode), so a filtered list is a real link: `?q=` on all three, `?category=` on the detail drill-down (already there, now joined by the search), and `?filter=active|trashed` on the PDF library. Filtered lists are shareable, bookmarkable, survive a reload, and the Back button leaves the query instead of the page. Debounced search boxes push with `replace: true`, so Back doesn't walk the query backwards a few characters at a time.

### Fixed
- **`mix test` aborted outright on any machine without `psql`** — `test/test_helper.exs` probed for the test database with `System.cmd("psql", …)`, which *raises* `ErlangError :enoent` when the binary isn't on `PATH` rather than returning a tuple its `case` could fall through on. A missing libpq client therefore killed the whole run before a single test loaded, instead of taking the documented path of excluding `:integration` and running the rest — which is why the last three releases all shipped with "`mix test` could not be run in this environment" in these notes. Now probed with `System.find_executable/1` first; the suite completes (525 tests, 787 integration excluded) with no database present.
- **An empty `?category=` on the catalogue detail page left `""` in the assign** (#49 follow-up) — `handle_url_state/2` normalized the value into a local but not back into `@current_category_uuid`, so the root-level item-list DOM ids came out `items-body-` instead of `items-body-root`, and because `push_url_state/3` reads its merge base back from the assigns, the empty `?category=` was re-written into the URL on every subsequent search patch.
- **Search results could be stranded on screen with no way to clear them** (#49 follow-up) — now that `?q=` survives the level load, a deep link into a category whose Active tab is empty settles the level on the Deleted view, where `<.search_input>` was hidden — leaving the rendered results (usually the empty state, since the context search excludes deleted rows) with no visible clear control. The input now also renders whenever a search is on screen.

### Notes
- Review: `dev_docs/pull_requests/2026/49-url-state-search/CLAUDE_REVIEW.md`.
- **Dependency lockfile advances** (no `mix.exs` constraint changes): eight orphaned `mix.lock` entries left behind by the dependency bump in `242bad9` (`ex_ast`, `glob_ex`, `igniter`, `owl`, `rewrite`, `sourceror`, `spitfire`, `text_diff`) were pruned — they were failing `mix precommit`'s `deps.unlock --check-unused` step. Constraints stay loose.
- Verification: `mix precommit` is clean (compile `--warnings-as-errors`, `deps.unlock --check-unused`, `hex.audit`, `format --check-formatted`, `credo --strict`, `dialyzer`). `mix test` runs but excludes the `:integration` suite — no Postgres in this environment — so the new `?q=` round-trip tests on all three LiveViews have not been executed; get a Postgres-backed CI run before treating the URL round-trip as verified.

## 0.12.3 - 2026-07-22

### Changed
- **Catalogue/category/item forms migrated to `phoenix_kit_ai`'s bundled `<.ai_multilang_tabs>`** (#48) — the hand-placed AI-translate row (button + progress bar + hint) under each form's language tabs is now rendered by the shared component instead of three near-identical copies. Same config (`ai_translate_config/1`), same events; the component additionally hides the row on single-language sites (previously the row could show without a `<.multilang_tabs>` at all). Requires `phoenix_kit_ai` >= 0.17.0 (first Hex release shipping `ai_multilang_tabs/1`); the lockfile was bumped accordingly.

### Fixed
- **`PhoenixKitCatalogue.version/0` lagged the 0.12.2 release bump** — the 0.12.2 release commit updated `mix.exs` but missed the `lib/phoenix_kit_catalogue.ex` callback, so it still reported `"0.12.1"`; `test/phoenix_kit_catalogue_test.exs` pins the two together but wasn't run against a Postgres-backed suite before that release shipped. Fixed as part of this release's version bump.

### Notes
- **Dependency lockfile advances** (no `mix.exs` constraint changes): `phoenix_kit` 1.7.199 → 1.7.208, `phoenix_kit_ai` 0.16.0 → 0.17.0 (ships `ai_multilang_tabs/1`), plus routine transitive bumps (`beamlab_countries`, `elixir_make`, `etcher`, `fresco`, `lazy_html`, `tessera`) and the `beamlab_ex_aws_sqs` → `ex_aws_sqs` rename picked up from core. Constraints stay loose.
- Verification: `mix format`, `mix compile --warnings-as-errors`, `mix credo --strict`, and `mix dialyzer` are all clean (`mix precommit`). `mix test` could not be run in this environment (`psql` is not installed, not just DB-unavailable) — the migrated templates are render-only changes with no test coverage gap identified; get a real CI/Postgres run before treating this release as fully verified.

## 0.12.2 - 2026-07-20

### Fixed
- **`mix precommit` was failing `credo --strict`** — `mix.tasks.phoenix_kit_catalogue.audit_supplier_refs`'s `audit_junction_rows/2` exceeded the nesting-depth and cyclomatic-complexity limits; split into per-source-pattern-matched `resolve_junction_row/3` and a `bucket_junction_result/2` reducer, same behavior. The remaining `apply/2,3` calls to the optional `PhoenixKitCRM.PartyRoles` module (in this task and in `Catalogue.Suppliers`) are intentional — they avoid a hard compile-time reference to a soft dependency that may not be present — so they're marked `credo:disable-for-next-line` instead of being rewritten.

### Notes
- Verification: `mix format`, `mix compile --warnings-as-errors`, `mix credo --strict`, and `mix dialyzer` are all clean. `mix test` could not be run in this environment (no local Postgres).

## 0.12.1 - 2026-07-17

### Fixed
- **Import screen's language picker would have been double-handled by core's new auto hook** (#46) — `phoenix_kit` 1.7.199 (core PR #643) made `mount_multilang/2` auto-attach a `"switch_language"` event hook via a debounced skeleton UX. `ImportLive` intentionally switches language immediately (no debounce) through its own `handle_event("switch_language", …)` clause, so it now opts out with `mount_multilang(auto_switch_language: false)` to keep that clause reachable.
- **Three other form LiveViews carried a now-dead `switch_language` clause** — `CatalogueFormLive`, `ItemFormLive`, and `CategoryFormLive` still defined their own `handle_event("switch_language", …)` clause even though they call `mount_multilang()` with the default `auto_switch_language: true`, so the clause was unreachable (the core hook halts before it) as of the `phoenix_kit` 1.7.199 pin. Not a behavior bug — the hook calls the same helper the dead clauses called — but misleading dead code; removed in all three files. See `dev_docs/pull_requests/2026/46-import-multilang-auto-switch-language/CLAUDE_REVIEW.md`.

### Notes
- Verification: `mix format`, `mix compile --warnings-as-errors`, `mix credo --strict`, and `mix dialyzer` are all clean. `mix test` could not be run in this environment (no local Postgres) — the affected code paths are exercised end-to-end (through the real LiveView hook dispatch) by the existing `test/web/form_lv_branches_test.exs` switch_language tests; get a real CI/Postgres run before treating this release as fully verified.

## 0.12.0 - 2026-07-17

### Added
- **Unit-cost revisions with validity-window price history** (#45) — `phoenix_kit_cat_item_supplier_info` rows now carry a non-destructive price history via their existing `valid_from`/`valid_to` date fields. `Catalogue.revise_supplier_info_cost/3` (`ItemSupplierInfos.revise_unit_cost/3`) closes the current junction row (`valid_to: today`, `is_primary: false`) and inserts a successor with the new cost, `valid_from: today`, `valid_to: nil`, freeing the partial-unique primary index inside the same transaction so the successor can inherit `is_primary`. A row is "current" when `valid_to` is `nil`; `list_for_item/1`, `primary_for_item/1`, and `mix phoenix_kit_catalogue.audit_supplier_refs` were all updated to filter on that predicate so closed history rows no longer surface as active links. New `Catalogue.supplier_info_history_for_pair/2` / `active_supplier_info_for/2` round out the read side — the latter is the function intended for warehouse/goods-receipt integrations to check whether a receipt's unit price diverges from the catalogued cost. The item edit form's Suppliers card gained a read-only "Price History" column/modal showing the full validity-window history for a supplier.

### Fixed
- **`revise_unit_cost/3` silently no-op'd a currency-only correction** — the no-op guard only compared the new cost to the row's existing `unit_cost`, so calling it with the *same* cost but a different `opts[:currency]` (e.g. correcting a mis-recorded currency without a price change) returned `{:ok, info}` without creating a revision row, logging the change, or updating the currency — despite the function's own docs describing currency correction as supported. The guard now also requires the currency to be unchanged before treating the call as a no-op. See `dev_docs/pull_requests/2026/45-unit-cost-revisions/CLAUDE_REVIEW.md`.

### Known limitation (not fixed — needs a core migration)
- **No guard against two concurrent `revise_unit_cost/3` calls producing two simultaneous "current" rows for the same non-primary item/supplier pair.** The primary case self-corrects via the existing partial-unique `is_primary` index (a race errors loudly instead of double-writing), but a non-primary junction row has no equivalent — the schema intentionally carries no uniqueness on `(item_uuid, supplier_uuid)`. Closing this needs a partial unique index (`WHERE valid_to IS NULL`) added in a core `phoenix_kit` migration; out of scope for this repo alone per its own "no DB migrations of its own" rule. Full detail in the review doc above.

### Notes
- **Dependency lockfile advances** (no `mix.exs` constraint changes): `phoenix_kit` 1.7.194 → 1.7.199 (pulls in core's `V151` migration — `supplier_source`/`is_primary` columns + the partial-unique index — already required by the #44 feature; the migration-gap "Known blocker" noted in 0.11.0 is resolved as of this pin), `phoenix_kit_ai` 0.12.2 → 0.16.0, `hackney` 4.5.2 → 4.6.0, `etcher` 0.7.2 → 0.8.0, `fresco` 0.8.0 → 0.9.0, `mdex_native` 0.2.5 → 0.2.6, `mint` 1.9.2 → 1.9.3 (`EEF-CVE-2026-59249`), `quic` 1.7.0 → 1.7.1, `req` 0.6.2 → 0.6.3, `tessera` 0.3.2 → 0.3.3. Constraints stay loose.
- Verification: `mix format`, `mix compile --warnings-as-errors`, `mix credo --strict`, and `mix dialyzer` are all clean. `mix test` could not be run in this environment (no local Postgres) — the new no-op-guard regression test was reviewed by manual trace against the transaction logic rather than executed; get a real CI/Postgres run before treating this release as fully verified.

## 0.11.0 - 2026-07-16

### Added
- **Supplier×item info layer** (#44) — a new `phoenix_kit_cat_item_supplier_info` junction table lets an item be sourced from several suppliers (local or CRM), each with its own SKU, unit cost/currency, lead time, and MOQ, plus a per-item "primary supplier" flag. The item edit form gained a Suppliers card (add/remove, make-primary) replacing the old single `primary_supplier_uuid` dropdown. `Catalogue.Suppliers.resolve/1` and `.list_all/1` provide a unified local+CRM supplier view, guarded so the catalogue module compiles and runs without `phoenix_kit_crm` present. `mix phoenix_kit_catalogue.audit_supplier_refs` reports unresolvable supplier UUIDs. See ADR `dev_docs/adr/0001-cross-module-references.md` for the soft-UUID-reference pattern this introduces for cross-module data.

### ⚠ Known blocker — Suppliers card does not work yet
- **The new Suppliers card cannot save.** The core `phoenix_kit` migration this feature depends on (V149, shipped in `phoenix_kit` 1.7.194) creates `phoenix_kit_cat_item_supplier_info` without the `supplier_source` / `is_primary` columns or the partial unique index the new Ecto schema requires — every "Add Supplier" click fails with a Postgres `undefined_column` error. Confirmed still present through `phoenix_kit` 1.7.196 (latest at release time); no follow-up migration has shipped. **Do not rely on this feature in production** until a `phoenix_kit` migration adds the missing columns/index and this repo's `mix.lock` is bumped to depend on it. Full detail: `dev_docs/pull_requests/2026/44-parties-supplier-info/CLAUDE_REVIEW.md`.

### Fixed
- **CRM suppliers never appeared in the item form's supplier picker** — `Suppliers.list_all/1` called a `PhoenixKitCRM.PartyRoles.list_suppliers/0` function that doesn't exist anywhere in `phoenix_kit_crm`; the guarded lookup silently and permanently returned `[]`. Now backed by the role-scoped `list_companies_with_role/2` / `list_contacts_with_role/2` functions that actually exist.
- **CRM contacts were always mislabeled `crm_company`** — the source-type heuristic checked for a `:company_uuid` key that `PhoenixKitCRM.PartyRoles.get_supplier/1` never returns for either party type. Company/contact entries from `list_all/1` are now tagged correctly at the source; `resolve/1`'s single-party lookup reports the honest generic `:crm` tag instead of guessing.
- **Adding/promoting/removing a supplier link never recorded who did it** — the three new `ItemFormLive` handlers didn't thread `actor_opts(socket)` into the `ItemSupplierInfos` calls, unlike every other mutating call in that LiveView, so `item_supplier_info.*` activity rows always had `actor_uuid: nil`.
- **`Catalogue.PubSub`'s `kind()` typespec was never extended** for the new `:item_supplier_info` broadcast — no runtime crash (every subscriber matches `kind` loosely), but it broke the type contract badly enough that a from-scratch `mix dialyzer` run flagged 7 of its 8 total warnings from this one gap (cascading into false "unreachable `{:ok, _}` branch" warnings on the three new `ItemFormLive` handlers). `mix dialyzer` is now a clean pass.
- **New context functions bypassed the `Catalogue` facade** — `ItemSupplierInfos` and the new `Suppliers.resolve/1` / `.list_all/1` had no `defdelegate` on `PhoenixKitCatalogue.Catalogue`, contradicting the module's own documented "one-stop facade" convention. Added `resolve_supplier/1`, `list_all_suppliers/1`, and the full `*_supplier_info` CRUD surface.

### Notes
- Dependency lockfile advances (no `mix.exs` constraint changes): `phoenix_kit` 1.7.189 → 1.7.194 (this is the version that first pulls in core's `V149` migration — see the known blocker above), `phoenix_kit_ai` 0.11.0 → 0.12.2 (adds a transitive `xai`/`grpc`/`protobuf`/`googleapis` chain), `ex_ast` 0.12.9 → 0.12.10, `phoenix_live_view` 1.2.6 → 1.2.7. `mint` bumped to 1.9.3, patching `EEF-CVE-2026-59249` (chunk-size parser response-smuggling advisory) flagged by `mix hex.audit`. Constraints stay loose.
- Verification: `mix format`, `mix compile --warnings-as-errors`, `mix dialyzer` are clean. `mix credo --strict` is at parity with the pre-existing baseline (see the review doc). `mix test` could not be run in this environment (no local Postgres) — the same condition that let the migration gap above ship unnoticed in #44; the new/updated tests were reviewed by manual trace and should get a real CI/Postgres run before this release is considered fully verified.

## 0.10.0 - 2026-07-03

### Added
- **PRO100 round-trip import** (#40) — mirrors the existing PRO100 export. A new `Import.Source` registry (`Universal` / `PRO100`) lets you pick a Source + Format alongside the target catalogue on the upload step; PRO100 (Фурнитура / Материалы) reads the `# Parts` / `# Materials` text formats, matches rows to existing items in the target catalogue by digits-only id, and **updates** them (no auto-create) via a `preview → apply → report` flow — unmatched/ambiguous/failed rows surface with the raw file line, not silently dropped. Round-trip fidelity: the PRO100 "service" columns the export used to hardcode are preserved per item in `data["pro100"]` on import and re-emitted by the export. Universal JSON import (mirroring the Universal JSON export) is also new; existing XLSX/CSV import is untouched.
- **Catalogue admin table stack** (#40) — the catalogues/suppliers/manufacturers admin lists gained a shared toolbar (search, per-column filters, sort, table/card view toggle, column show/hide), with the user's column/sort/filter/view choices persisted per-user across sessions (`phoenix_kit_users.custom_fields`, no new table). The catalogues index converted to a flat table with a Folder filter + Folder column; the inline folder tree + drag-and-drop was replaced by a "Folders…" modal preserving full folder CRUD. `PdfLibraryLive` migrated to the shared admin-header + `table_default` pattern. `CatalogueDetailLive`'s active items table gained a mobile card fallback.

### Fixed
- **Per-user view-config writes for one admin tab could silently revert another tab's earlier save in the same session** — `CataloguesLive` wrote the whole `custom_fields` column from a snapshot it never refreshed after a save, so switching tabs and changing a second tab's view settings would revert the first tab's just-saved change.
- **Clicking "Apply" on the Columns modal could silently reset the table's sort away from "Name"** (and "Name" never appeared as a sort option), because the always-visible `name` column was excluded from the id list used for the sort-preserving check.
- **Switching Import Source/Format after a file was already parsed could silently run the wrong import path** — going back to the upload step and picking PRO100 over an already-parsed Universal spreadsheet (or vice versa) reused the stale parse instead of re-parsing under the new selection.
- **`CatalogueDetailLive`'s new mobile card showed the raw base price instead of the marked-up sale price**, disagreeing with the desktop table for any item/catalogue with a non-zero markup.
- **Folder filter never offered "Unfiled (root)"**, and an incomplete `PRO100` duplicate-item merge (from a prior fix) could keep an earlier row's stale price change when the last colliding row reasserted the item's original value.
- Ambiguous PRO100 matches now list the colliding items' SKU/name in the report instead of just "multiple items match"; the new mobile card/table toggle on `CatalogueDetailLive`'s active list no longer offers a desktop card view missing bulk-select/drag-reorder.
- Full findings, rationale, and what was verified-but-not-changed: `dev_docs/pull_requests/2026/40-catalogue-table-stack-pro100-import/CLAUDE_REVIEW.md`.

### Notes
- **Dependency lockfile advances** (no `mix.exs` constraint changes): `phoenix_kit` 1.7.169 → 1.7.171, `phoenix_live_view` 1.2.4 → 1.2.5, `plug` 1.20.1 → 1.20.2, `mdex` 0.13.2 → 0.13.3, `mdex_native` 0.2.3 → 0.2.4, `makeup` 1.2.1 → 1.2.2. Constraints stay loose.
- Verification: `mix format`, `mix compile --warnings-as-errors`, and `mix dialyzer` are clean. `mix credo --strict` is at parity with the pre-existing baseline (see the review doc — baseline `main` already carries 14 Design/Readability/Refactor-level suggestions unrelated to this release). `mix test` could not be run in this environment (no local Postgres); the new pure-logic fixes (PRO100 plan, table-query folder filter) have dedicated unit tests, the LiveView-level fixes were verified by manual trace and should get DB-backed regression coverage in a follow-up.

## 0.9.0 - 2026-06-29

### Added
- **PRO100 / Universal JSON catalogue export** (#35) — a new export pipeline that produces PRO100-compatible and Universal JSON output. Lets you pick a Destination (PRO100 / Universal), export multiple catalogues at once, and optionally drop the category level. PRO100 output writes a UTF-8 BOM on Furniture/Materials exports (Cyrillic detection) and keeps the ID column (column 2) digits-only; an option prefixes each item name with its catalogue name. Export filenames now carry the export date (`YYYY-MM-DD`) and local time (`HH-MM`), and JSON filenames are Unicode-safe. The catalogue lookup behind the export uses a lightweight query.

### Changed
- **Catalogue admin headers moved into the global admin header bar** (#36) — the 8 catalogue admin LiveViews that rendered an in-content `<.admin_page_header>` now adopt the core `/admin/media` self-wrap pattern: a per-module `on_mount` resets `socket.private[:live_layout]` from the auto-applied admin chrome back to the passthrough `:app`, and `render/1` wraps in `LayoutWrapper.app_layout`, so each page's title/subtitle land in the global admin header (breadcrumb) instead of an in-content header. Action buttons and the rich catalogue breadcrumb relocate to in-body toolbars.
- **Export form UI** (#35) — reordered the fields (Catalogues → Destination → Format) and tidied/enlarged the catalogue list.
- **`mix precommit`** now runs `hex.audit` to scan for retired Hex dependencies.

### Fixed
- **Events tab counter showed the wrong plural form** (#36) — the inline counter called `Gettext.gettext/3` on the `"%{count} events"` msgid, which cannot express plural agreement and rendered the Russian singular form for every value (e.g. "208 событие"). The count now appears in the header subtitle as `"<module> · Events: %{count}"` via a new agreement-free `"Events: %{count}"` msgid, translated for en/ru/et.
- **`PhoenixKitCatalogue.version/0` drift** — the runtime `PhoenixKit.Module` `version/0` callback reported a stale `0.2.0` while the package was `0.8.0`; it is now synced to the released version. The `version/0` compliance test no longer accepts any `\d+.\d+.\d+` shape (a regex is what let the drift slip through) — it asserts equality with `mix.exs`'s `@version`, so the three-places sync rule in AGENTS.md is actually enforced.

### Notes
- **Dependency lockfile advances** (no `mix.exs` constraint changes): `phoenix_kit` 1.7.133 → 1.7.169, `phoenix_kit_ai` 0.4.0 → 0.10.0, `phoenix_live_view` 1.1.31 → 1.2.4, `phoenix` 1.8.7 → 1.8.8, `req` 0.6.1 → 0.6.2 (plus `phoenix_kit` transitive deps: `leaf` 0.2 → 0.3, `etcher` 0.6 → 0.7, `tessera` 0.2 → 0.3, `mdex` added, `earmark` dropped). Constraints stay loose; pin `phoenix_kit >= 1.7.169` in the parent app if you depend on the latest admin-chrome behavior.
- Removed the now-unused `earmark` entry from `mix.lock` (`mix deps.unlock --unused`) after the `phoenix_kit` upgrade dropped it — required for `mix deps.unlock --check-unused` / `mix precommit` to pass.
- Verification: `mix precommit` is clean (compile `--warnings-as-errors` + `deps.unlock --check-unused` + `hex.audit` + `format --check-formatted` + `credo --strict` + `dialyzer`). ExUnit is DB-gated — run `mix test` against a host with PostgreSQL.
- Post-merge review of #36: `dev_docs/pull_requests/2026/36-admin-headers-global-bar/CLAUDE_REVIEW.md`.

## 0.8.0 - 2026-06-08

### Changed
- **AI translation moved to the `phoenix_kit_ai` plugin** (#34) — the AI-translation pipeline and AI-translate UI moved out of core into the standalone `phoenix_kit_ai` plugin (core now keeps only the AI table migrations). Catalogue's consumer was rewired accordingly: the `AITranslatable`/`AITranslateBinding` behaviours and the form-LiveView macro/imports moved `PhoenixKit.Modules.AI.{Translatable,Translations}` + `PhoenixKitWeb.Components.AITranslate.{…}` → `PhoenixKitAI.{Translatable,Translations}` + `PhoenixKitAI.Components.AITranslate.{…}`. `ai_translatables/0` is now a plain public function — core dropped the `PhoenixKit.Module` callback, and the plugin discovers the function by duck-typing — so the `@impl PhoenixKit.Module` was removed. No behavior change; the moved adapter logic (multilang `_`-prefix mapping, `FOR UPDATE` merge, force-put) is untouched.
- **Dependency upgrades** — `phoenix_kit` 1.7.132 → 1.7.133, `req` 0.5 → 0.6.

### Added
- **Local cross-repo development via `<APP>_PATH`** — `mix.exs` gained an env-gated `pk_dep/3` helper: export e.g. `PHOENIX_KIT_PATH=../phoenix_kit` or `PHOENIX_KIT_AI_PATH=../phoenix_kit_ai` to build/test against a local checkout of a `phoenix_kit*` dep (Mix swaps the Hex pin for a `path:` + `override: true` dep at resolve time). Unset = the published pin, so `mix deps.get` / `mix hex.publish` / CI resolve exactly as before. Documented in `AGENTS.md`.

### Notes
- **Adds `phoenix_kit_ai ~> 0.4` as a direct dependency.** AI translation (the embed macro + translation pipeline: `PhoenixKitAI.{Translatable,Translations}`, `PhoenixKitAI.Components.AITranslate.{Embed,FormBinding,FormGlue}`) now lives in the AI plugin and first shipped in **0.4.0** — the 0.3.x line does not contain it. The constraint is `~> 0.4` (loose, `< 1.0`); pin `phoenix_kit_ai >= 0.4.0` in the parent app.
- Verification: `mix precommit` is clean (compile `--warnings-as-errors` + `format --check-formatted` + `credo --strict` + `deps.unlock --check-unused` + `dialyzer`) against the published dependency set — no local-path overrides. The full ExUnit suite is DB-gated — run `mix test` against a host with PostgreSQL.

## 0.7.0 - 2026-06-07

### Fixed
- **European number formats in price import** — `Import.Mapper.normalize_price/1` mis-parsed the European `"1.234,56"` convention (dot thousands, comma decimal): it stripped the comma and read the value as `1.23456` — silently off by ~1000×. It now decides the decimal separator by whichever of `.`/`,` appears last, so both `"1,234.56"` (US/UK) and `"1.234,56"` (EU) parse correctly, including multi-group values and currency-prefixed strings.
- **CSV delimiter mis-detection on quoted headers** — `Import.Parser` chose the delimiter by counting raw `,`/`;`/`\t` characters on the first line, so a quoted header cell containing a comma (e.g. `"Name, full";…`) picked the comma parser and collapsed every row to a single column, silently importing garbage. Detection now parses a sampled set of lines with each candidate parser and scores by column count + consistency, which is immune to delimiters inside quotes.
- **PDF extraction enqueue could be silently dropped** — the post-insert enqueue was gated on a 1-second wall-clock "was I the inserter?" heuristic; under DB/GC latency the inserting caller could arrive later and skip the enqueue, leaving a `pending` extraction with no job (only the manual *Retry stuck* path would heal it). It now (re-)enqueues on any `pending` observation — `enqueue_extraction/1` is already idempotent against live jobs, so this is safe and self-healing.
- **One bad PDF page no longer fails the whole document** — `Workers.PdfExtractor` halted extraction on the first page error and marked the entire PDF `failed`, discarding every successfully-extracted page and burning all retries on a single corrupt page. It now continues past per-page failures, keeps the usable partial result (logging the unreadable pages), and only fails — for retry — when *every* page fails.

### Changed
- **Import upload guards** — `Import.Parser.parse/3` and `list_sheets/1` now reject oversized inputs up front (`:file_too_large` above 25 MB, `:too_many_rows` above 50 000) instead of materializing a pathological upload into memory. Both atoms have user-facing `Errors.message/1` copy.
- **Bounded duplicate-detection query** — `Import.Mapper.detect_existing_duplicates/3` narrows its existence query to items whose name appears in the import (a match requires name equality) instead of loading every non-deleted item in the catalogue into memory.
- **AI-translate LiveView wiring via the `AITranslate.Embed` macro** (#33) — the catalogue/category/item form LiveViews replaced their hand-wired AI-translate handlers (six `ai_*` `handle_event` clauses + the `{:ai_translation}` `handle_info`) with `use PhoenixKitWeb.Components.AITranslate.Embed` from core, which attaches the modal/dispatch/PubSub handlers as lifecycle hooks. Requires the macro shipped in core (BeamLabEU/phoenix_kit#585).
- **`nimble_csv` declared as a direct dependency** — the CSV import parser uses it directly (`NimbleCSV.define/2`); it was only pulled transitively via `phoenix_kit`. Loosely constrained (`~> 1.2`).

### Docs
- Fixed a stale "SKU is unique" note in the `create_item/update_item` docs — core V123 dropped that index; item SKUs are non-unique by design.

### Notes
- **Requires a phoenix_kit release containing `PhoenixKitWeb.Components.AITranslate.Embed`** (BeamLabEU/phoenix_kit#585) — the macro the form LiveViews now `use`. Developed and locked against core **1.7.132**; the `mix.exs` constraint stays loose (`~> 1.7 and >= 1.7.125`), so pin a `phoenix_kit >= 1.7.132` in the parent app.
- Verification: `mix precommit` is clean (compile `--warnings-as-errors` + `format --check-formatted` + `credo --strict` + `deps.unlock --check-unused` + `dialyzer`). The new pure-function behavior (price normalization, delimiter detection, size/row caps) is covered by added unit tests. The full ExUnit suite is DB-gated — run `mix test` against a host with PostgreSQL.
- Deferred follow-up: several form LiveViews still issue DB queries directly in `mount/3` (which runs twice). Documented in `dev_docs/followup_2026_06_07_mount_connected_guard.md`; deferred because validating the disconnected-render change needs the DB-backed LiveView test suite.

## 0.6.1 - 2026-06-04

### Fixed
- **Docs build warning** — the `PhoenixKitCatalogue.AITranslatable` moduledoc auto-linked `PhoenixKitCatalogue.ai_translatables/0`, an `@impl PhoenixKit.Module` callback ExDoc treats as hidden, so `mix docs` / `hex.publish` warned about a reference to a hidden function. Reworded to point at the `PhoenixKitCatalogue` module instead of the hidden callback; docs now build clean. No functional change.

## 0.6.0 - 2026-06-04

### Added
- **AI translation for catalogue resources** (#32) — catalogues, categories, and items can machine-translate their `name` + `description` into the multilang `data` JSONB via core's shared AI-translation pipeline. A `PhoenixKitCatalogue.AITranslatable` adapter (registered through the new `ai_translatables/0` module callback for `"catalogue"` / `"catalogue_category"` / `"catalogue_item"`) handles fetch / source-field extraction / persist for all three resource types, and `PhoenixKitCatalogue.AITranslateBinding` supplies the form-side storage glue; the translate button, modal, progress bar, and "taking a while" hint render on each form LiveView. Per-language overrides are written under the multilang `_`-prefixed keys the form reads, and a result is **force-stored even when identical to the source** (a product code, text already in the target language) so a field never reads as a failed translation. No new `phoenix_kit_ai` dependency — the enqueue, AI call, retry policy, broadcasts, and audit log all live in core.

### Changed
- **Catalogue-detail status filter scoped to inside categories** (#32) — the category drill step is pure navigation, so the active / inactive / discontinued / deleted tab strip now renders only alongside an actual item list and only when more than one status is populated; a node auto-opens on its first populated status instead of an empty Active.
- **Item reorder affordances skip no-ops** (#32) — the drag handle is hidden for a single-item list and a same-position drop short-circuits the DB write / broadcast / flash. The handle's column space is reserved (empty spacer cell) so deleting down to one row doesn't shift the layout.
- **AI-translate LiveView glue delegates to core `FormGlue`** (#32) — ~570 lines of inline modal / dispatch / PubSub state collapsed into nine delegators plus the small catalogue-specific `AITranslateBinding`.
- **Quieter AI-translation writes** (#32) — the per-row resource PubSub fan-out is suppressed on AI-translation `update_*` writes (they run inside a `FOR UPDATE` transaction and would otherwise fire pre-commit and look like a user edit); the `broadcast: false` opt is now forwarded through `update_catalogue/3`, `update_category/3`, and `update_item/3` so it actually takes effect. Normal admin edits still broadcast.

### Quality
- Post-merge review of #32 (writeup in `dev_docs/pull_requests/2026/32-ai-translation-shared-glue/CLAUDE_REVIEW.md`): dropped a dead `_ = primary` discard; replaced a runtime `String.to_existing_atom/1` + `rescue` with a compile-time field→column map in the AI adapter; flattened `put_translation/4` nesting (extracted `merge_translation!/6`) and aliased a fully-qualified `Web.Helpers` call to satisfy `credo --strict`; expanded the adapter unit tests 10 → 15 (source-field override / legacy-key paths, catalogue + category round-trips). Also dropped a redundant `import Ecto.Query, warn: false` from the PDF library context.

### Notes
- **Requires the shared AI-translation pipeline** — catalogue now plugs into PhoenixKitAI (`PhoenixKitAI.{Translatable,Translations}` and `PhoenixKitAI.Components.AITranslate.{FormGlue,FormBinding}`). Catalogue compiles and `mix precommit` (compile `--warnings-as-errors` + `format --check-formatted` + `credo --strict` + `dialyzer`) is clean against the corresponding local dependency set.
- Verification: ExUnit suites are DB-gated and run against a host whose schema is at core V111+; the new adapter tests pass against a local core (not exercised in CI without a database).

## 0.5.0 - 2026-06-01

### Added
- **PDF viewer fallback** (#31) — a persistent **"Open"** link on the PDF detail page points at the always-present signed `/file/` route, so the document is reachable in the browser's native viewer even when the embedded `/_pdfjs` frame can't load. Pairs with a core router-served `/_pdfjs` fallback, but the catalogue side works independently.
- **PDF extraction self-heal** (#31) — `Catalogue.requeue_stuck_extractions/1` re-drives every `pending` extraction plus `extracting` rows orphaned past `:stale_after_seconds` (default 900), and `Catalogue.retry_extraction/2` resets a single row to `pending` and re-enqueues so a terminal `failed` row runs again. Surfaced in the UI as a per-row **Retry** button, a detail-page Retry on the failed alert, and a **"Retry stuck"** header action. New `pdf.extraction_retried` activity action. Both functions re-exported from `Catalogue` via `defdelegate`.

### Changed
- **App-level Oban enqueue dedup** (#31) instead of Oban's built-in `unique:` — satisfying the `unique` compile check forces listing `:suspended`, an `oban_job_state` enum value absent on hosts that upgraded the Oban *lib* ahead of its *migration* (querying it raises `22P02` and kills every enqueue). The app guard skips the insert when a non-terminal `PdfExtractor` job already exists for the `file_uuid`, querying only the four always-present states (`available`/`scheduled`/`executing`/`retryable`) and proceeding on any query error. The worker name is derived via `inspect/1` so a rename is a compile error, not a silently-broken query.
- **Guarded, atomic extraction status transitions** (#31) — `mark_failed/2` and `mark_extracting/1` only advance from a non-terminal state (`UPDATE … WHERE status IN ('pending','extracting')`), so a concurrent worker can no longer clobber a success terminal (`extracted` / `scanned_no_text`) back to `failed` — silent data loss that broke search — nor pull a finished extraction back to `extracting`. Success markers stay last-writer-wins.
- **Honest, batched `requeue_stuck_extractions/1`** — returns `%{requeued, skipped, failed}` (capped at 1000 rows/call) where `skipped` is rows a live job already covers, so "Re-queued N" never takes credit for no-ops; the **"Retry stuck"** flash is a *warning* (not "success") when enqueues were refused — the exact queue-missing case the button targets. The whole selection is de-duped against live jobs in **one** query and enqueued with **one** `Oban.insert_all/1` rather than ~2k per-row round-trips at the cap.
- **`retry_extraction/2` refuses a success-terminal row** with `{:error, :already_extracted}` unless `force: true` is passed, so a stray programmatic caller can't reset a good extraction to `pending` and drop the PDF out of search mid-re-extract.
- **Bulk-action bars folded onto core `<.bulk_actions_bar>`** (#31) on the catalogue detail page (categories + deleted-items lists) — removes ~50 lines of duplicate component markup while keeping the sticky styling and `clear_selection` behaviour.
- `PdfLibraryLive` loads its list in `handle_params/3` (not `mount`, which runs twice) and now honours a `?filter=active|trashed` deep-link; the extraction-status badge is a HEEx component with auto-escaping instead of hand-built `Phoenix.HTML.raw` markup.

### Fixed
- The `permanently_delete_pdf/2` refcount-then-handoff sequence runs inside a `Repo.transaction(_, isolation: :serializable)` so a concurrent upload of the same content can't orphan a reference between the count and `Storage.trash_file/1`.

### Notes
- **No new core requirement** — still `phoenix_kit ~> 1.7 and >= 1.7.125`. The PDF `oban_jobs` dedup filters on `args ->> 'file_uuid'`, which has no index; since this module ships no migrations and `oban_jobs` is core/host-owned, a partial expression index belongs in a future core migration once the job table grows large (tracked in `AGENTS.md` and on `PdfLibrary.extraction_job_pending?/1`).
- Verification: `mix precommit` clean (compile + format + credo --strict + dialyzer). The Web/context test suites that exercise the new guards are DB-gated and run against a host whose schema is at core V111+.

## 0.4.0 - 2026-05-30

### Added
- **ItemPicker display options** (#29) — four backward-compatible attrs on `<.item_picker>` and the underlying `ItemPicker` LiveComponent, all defaulting to current behaviour: `show_unit` (opt-in; render the item's measurement unit beside the price in each dropdown row), `format_unit` (1-arity `unit -> label` function, mirroring `format_price`; defaults to the shared abbreviation map, return `""` to omit), `highlight_selected` (default `true`; pass `false` to drop the `input-primary` border on always-rendered pickers), and `initial_query` (optional seed string that prefills the search input and opens matching results once on first render, never clobbering a real selection or mid-typing query).

### Changed
- `ItemPicker` `category_uuids` / `catalogue_uuids` attrs relaxed from `:list` to `:any` so callers can pass an explicit `nil` (the documented "all categories" scope) without a Phoenix attr-type warning.
- Unit-abbreviation labels (`piece`→`pc`, `m2`→`m²`, `running_meter`→`rm`, …) are now centralised in `PhoenixKitCatalogue.Schemas.Item.unit_label/1` — a single source of truth shared by the items table and the item picker, instead of two divergent copies.

### Fixed
- **PDF extraction enqueue** refuses to enqueue when the `:catalogue_pdf` Oban queue isn't running (not configured, or Oban not started). Instead of piling up never-processed jobs it flips the extraction to a terminal failed status with an actionable message + activity row.

## 0.3.0 - 2026-05-29

### Added
- **Catalogue folders** — an inline, nested folder tree-table on `/admin/catalogue` (Finder-style): disclosure chevrons, native drag-and-drop filing, an Actions "Move to folder" picker, and front-insertion so new folders surface at the top. Folders are **module-global** (a dedicated `phoenix_kit_cat_folders` table; **requires core V123**) and unrelated to the media-folder system. New schema `PhoenixKitCatalogue.Schemas.Folder` and `cat_catalogues.folder_uuid` (`ON DELETE SET NULL`). New context API: `list_folder_tree/1`, `catalogues_by_folder/1`, `folder_uuids_with_children/1`, `get_folder/1`, `create_folder/2`, `update_folder/3`, `move_folder/3`, `trash_folder/2`, `restore_folder/2`, `permanently_delete_folder/2`, `reorder_folders/2`, `move_catalogue_to_folder/3`. Folder mutations broadcast a `:folder` PubSub event so the tree converges across open sessions.
- **Per-status item tabs** on the catalogue detail page — Active / Inactive / Discontinued / Deleted (empty Inactive hidden); discontinued items are no longer mixed into Active.
- **Detail drill-down rework** — the detail page is now a category drill-down built on the core list-UI toolkit (sortable / bulk-select / `load_more`), replacing the old per-card expand mechanism. The current category is carried in `?category=` for deep-linkable, back-button-friendly navigation.

### Changed
- **Full-width, sidebar-driven layout** for the catalogue admin pages — the three redundant top tabs are replaced by a sidebar-driven header.
- **Duplicate SKUs are now accepted** — core V123 drops the global unique `cat_items.sku` index.
- Housekeeping: catalogue search-empty states use core `<.empty_state>`; blank-string normalization migrated to `PhoenixKit.Utils.Values.blank_to_nil`.

### Fixed
- **Reorder no longer re-slots a trashed item into the active sequence** — `item_scope_check/3` now excludes `status = "deleted"` (parity with the active-only `:all` reorder path), closing a cross-tab race where an item selected client-side then trashed elsewhere could still be repositioned.
- **Folder moves are now serialized** — the cycle check + validation + update run inside a transaction with `FOR UPDATE` on the moved row (parity with category moves), so concurrent reparents can't commit a cycle that would vanish from the tree view.
- **Test suite repaired** — the suite had been silently uncompilable since the PDF sweep (a `with_scope/2` helper that never existed); added the missing LiveView scope test-infra + PDF routes and folder / PubSub / status-count coverage.
- De-brittled the smart-pricing float-qty test (assert behavior, not version-dependent `Decimal` internals).
- Trimmed redundant work on the index render (duplicate folder-tree / count queries) and the detail `load_level` (fetched both `:active` and `:deleted` child-category lists and discarded one; ran a per-category count `GROUP BY` even on the status tabs where no cards render).

### Removed
- Cross-category drag-move on the detail page — superseded by the explicit bulk "Move" modal in the single-node drill view.
- Dead code: `list_child_folders/2` and `folder_catalogue_counts/0`.

### Notes
- **Requires core V123** (catalogue folders + dropping the global unique `cat_items.sku` index), first shipped in `phoenix_kit 1.7.125`. The dep constraint is now `~> 1.7 and >= 1.7.125` — floored at the V123 release while keeping the `< 2.0.0` upper bound loose. Run migrations against a `phoenix_kit` ≥ 1.7.125 host.

## 0.2.0 - 2026-05-11

### Added
- **Per-module gettext backend** — `PhoenixKitCatalogue.Gettext` (`lib/phoenix_kit_catalogue/gettext.ex`). The module now owns its translations instead of borrowing `PhoenixKitWeb.Gettext` from the host app.
- **i18n-aware tab registration** — all 19 `%Tab{}` structs in `admin_tabs/0` carry `gettext_backend: PhoenixKitCatalogue.Gettext` and `gettext_domain: "default"`. Tab labels are now translated at render-time via `Tab.localized_label/1` (requires `phoenix_kit >= 1.7.107`).
- **Translation files** — `priv/gettext/{en,ru,et}/LC_MESSAGES/default.po` with complete translations for tab labels, page titles, status strings, error messages, flash messages, and UI copy. Russian uses 3 plural forms per CLDR; Estonian uses 2.
- **Smoke test** — `test/gettext_test.exs` verifies backend compilation, Russian/Estonian tab-label translation, fallback for tabs without a backend, and fallback to msgid for untranslated strings.

### Changed
- All `Gettext.gettext(PhoenixKitWeb.Gettext, ...)` and `Gettext.ngettext(PhoenixKitWeb.Gettext, ...)` calls replaced with `PhoenixKitCatalogue.Gettext`. Affects 18 files in `lib/`. This is a transparent change for end users — behaviour is identical as long as translations are kept in sync.
- Version bumped `0.1.17` → `0.2.0` (minor: tab labels are now locale-dependent, which is a visible behaviour change for downstream callers relying on raw English strings from `Tab.label`).

### Notes
- `{:phoenix_kit, "~> 1.7"}` constraint kept as-is (core is at 1.7.107 locally). A bump to `~> 1.8` is gated on the core hex release; `Tab.gettext_backend` and `Tab.localized_label/1` are already present at 1.7.107.

## 0.1.17 - 2026-05-09

### Added
- **Items / Categories tabs on the catalogue detail page** — reflected to URL via `?tab=items|categories`. Each tab keeps its own Active / Deleted counts and per-tab Active/Deleted switcher. The Items tab Deleted view is a flat recency-ordered list (`list_deleted_items_for_catalogue/2`, capped at 500) instead of category-grouped cards. Auto-flip back to Active when the per-tab Deleted bucket empties — no more landing in an empty Deleted view of one tab while the other still has rows.
- **Bulk select + actions** — row checkboxes (table + card view) with a sticky action bar. Items: Delete / Restore / Move (Move opens a same-catalogue target picker). Categories: Delete (opens the disposition modal in bulk mode) / Restore. New context fns `bulk_trash_items/2`, `bulk_restore_items/2`, `bulk_permanently_delete_items/2`, `bulk_move_items_to_category/3`, `bulk_trash_categories/3`. The bulk-move fn requires a `:catalogue_uuid` opt and validates both items + target stay in scope (mirrors the single-item DnD guard so a crafted client request can't silently flip a `catalogue_uuid` cross-catalogue).
- **Per-card pagination** — replaced the global infinite-scroll cursor with a PdfSearchModal-style 25-row preview + per-card "Show N more" button. `expand_card` is deferred (event handler returns immediately, button renders the loading state, fetch runs on the next mailbox tick) with an 8s `:expand_timeout` recovery so a network hiccup mid-click restores the button + flashes a retry message.
- **Cross-tab live updates** via PubSub — reorders, bulk operations, and category position changes broadcast to all open detail pages on the same catalogue. Bulk operations get a two-step receiver animation (red flash on leaving rows → 800ms delay → state refresh → green flash on arriving rows). New `Catalogue.PubSub` broadcasts: `broadcast_card_refresh/5`, `broadcast_category_reorder/4`, `broadcast_bulk_change/4`. All include `from \\ self()` so the originator's own broadcast is filtered on receive.
- **Item-disposition modal** when trashing a category that still has items — Cascade / Uncategorize / Move-to (with same-catalogue target picker via `list_move_target_categories/1`). `trash_category/2` accepts an `:items` opt: `:cascade` (default), `:uncategorize`, or `{:move_to, target_uuid}`. Activity metadata grows `items_handled` + `items_disposition`.
- **`active_item_count_in_subtree/1`** — admin "delete category" modal gate; counts items in the category and every V103 descendant.
- **`list_move_target_categories/1`** — same-catalogue active categories that can receive items from a category about to be deleted (the category itself and its V103 descendants are excluded). Used by the disposition modal's move-target dropdown.
- **`:parent_catalogue_deleted` error reason** with gettext message — surfaced when restoring a category or item whose parent catalogue is itself deleted.
- **Drag-handle-only DnD** across all catalogue admin views — `pk-drag-handle` class wired through `data-sortable-handle` on catalogues table, category rows, item tables, and smart-rule rows. The row body is no longer a drag affordance.

### Changed
- **Soft-delete is decoupled — each entity owns its own status.** `restore_category/2` no longer cascades up or down; only the target category's status flips back to `"active"`. Refuses with `{:error, :parent_catalogue_deleted}` when the parent catalogue is itself deleted (the operator must restore the catalogue first). Items that came down via `:cascade` stay deleted; descendants stay deleted; ancestor categories stay at whatever status they were. `restore_item/2` refuses if the parent catalogue is deleted; when the parent **category** is deleted, the item is uncategorized on restore (`category_uuid: nil`) so it surfaces in the catalogue's Uncategorized bucket without auto-reviving the category structure. Activity metadata grows `"detached_from_category" => true` in that case. **Behaviour change** for callers that relied on the old cascading restore — call `restore_catalogue/2` first, or restore items individually after the parent.
- `category.restored` activity metadata no longer carries `subtree_size` / `items_cascaded` (always 0 under the no-cascade rule); `category.trashed` carries `subtree_size`, `items_handled`, and `items_disposition` (`"cascade"` / `"uncategorize"` / `"move_to:<uuid>"`).
- `bulk_restore_items/2` now wraps the read-then-partition-then-write pipeline in `repo().transaction/1` so a concurrent parent-status flip can't push the partition off-by-one (would otherwise either detach an item that should have stayed attached or vice versa). Single-item `restore_item/2` was already transactional; the bulk path now matches.
- `do_bulk_move/4` (both clauses) gained `where: i.status != "deleted"` for surface consistency with `bulk_trash_items` / `bulk_restore_items` — defence against a stale tab submitting a deleted UUID.

### Fixed
- `restore_category/2` docstring rewritten to match the no-cascade behaviour (was still describing the prior cascade-both-directions semantics).
- 6 unwrapped flash strings in the catalogue-detail bulk handlers — all now wrapped in `Gettext.gettext`. Two `inspect(reason)` flashes that leaked raw Elixir terms replaced with gettext-wrapped user messages; raw reason routes to `log_operation_error/3` for engineer visibility.
- `Catalogue.PdfLibrary.sha256_file/1` — `File.stream!(path, [], 65_536)` was the pre-Elixir-1.16 signature (modes at arg 2, byte-count at arg 3). Modern signature is `File.stream!(path, line_or_bytes, modes)`. Fixed via swap to `File.stream!(path, 65_536, [])`. The contract violation was cascading into `no_local_return` on `sha256_file/1` + 7 "function will never be called" warnings across `existing_active_file/1`, `ensure_extraction/1`, `resolve_extraction_after_insert/1`, `insert_pdf_row/5`, `enqueue_extraction/1`, and `store_via_core/4` — all clear now that dialyzer can trace the call graph again.

### Removed
- `move_category_up` / `move_category_down` LV events — category reorder is drag-only via the SortableGrid hook now. The `apply_category_reorder/3` path is exercised end-to-end by the DnD wire.
- Global infinite-scroll cursor + `:has_more` / `:loading` mount-default assigns — superseded by per-card expand.
- Dead `_scopes` payload on `broadcast_bulk_change/5` — was always `[]` from every call site, always `_`-bound by every receiver. Dropped (signature is now `/4`).
- Old `subtree_size` / `items_cascaded` cascade in `restore_category` activity metadata — see Changed.

## 0.1.16 - 2026-05-05

### Added
- **`Catalogue.evaluate_smart_rules/2` (issue #20)** — public smart-pricing evaluator. Standard entries pass through; smart items get a computed price written to a configurable key (default `:smart_price`). Single consumer-policy injection point: `:line_total` lambda (default `base_price × qty`). Lives in new `PhoenixKitCatalogue.Catalogue.SmartPricing` submodule. Loud `ArgumentError` raises when `:catalogue` or `:catalogue_rules` is `%NotLoaded{}` on any entry — better than silent zero-pricing.
- **`Catalogue.list_items_by_uuids/2` (issue #19)** — order-preserving, soft-delete excluded, deduped, no `nil` placeholders for missing UUIDs. Designed for order-snapshot rehydration without leaking `Repo` to consumers.
- **`Catalogue.category_summary_for_catalogue/2` (issue #21)** — returns `%{categories:, item_counts:, uncategorized_count:}` in two queries. Replaces the three-roundtrip pattern (`list_categories_metadata_for_catalogue` + `item_counts_by_category_for_catalogue` + `uncategorized_count_for_catalogue`) lazy-load consumers had to write.
- **`:preload` opt on bulk fetchers (issue #19)** — `search_items/2`, `search_items_in_catalogue/3`, `list_items_for_category/2`, `list_items_for_catalogue/2`, `list_uncategorized_items/2`, `list_items_for_category_paged/2`, `list_uncategorized_items_paged/2`, `get_item/2`, `get_item!/2`, and `list_items_by_uuids/2` all accept `:preload`, concatenating onto each function's defaults. Pass `[catalogue_rules: :referenced_catalogue]` for smart-pricing.
- `Catalogue.Helpers.merge_preloads/2` — single-source preload concat helper (was duplicated in `catalogue.ex` and `search.ex`).

### Changed
- **`get_item!/2` default preloads expanded** to `[:catalogue, :category, :manufacturer]`. The previous arity-1 form silently omitted `:catalogue`, which downstream smart-pricing callers had to add via a separate `Repo.preload`. Pure addition for callers that didn't access `.catalogue`.
- **`list_uncategorized_items/2` default preload widened** from `[:manufacturer]` to `[:catalogue, :manufacturer]`. Pure addition.
- `guides/smart_catalogues.md` §4 rewritten to call `evaluate_smart_rules/2` directly. The 100-line copy-paste reference impl is gone; one source of truth lives in the package now. §5 (preload pitfall) updated to reference the new `:preload` opt.
- Test infrastructure switched from `Ecto.Migrator.run([{0, PhoenixKit.Migration}])` to `PhoenixKit.Migration.ensure_current/2`. The old pattern was idempotent at the outer Ecto.Migrator layer (version `0` cached in `schema_migrations`) so newly-shipped Vxxx migrations silently never applied. Requires `phoenix_kit ~> 1.7.105` for the test suite; runtime constraint unchanged.
- Test-helper rescue narrowed to `[DBConnection.ConnectionError, Postgrex.Error]` only — code/version bugs (`UndefinedFunctionError`, etc.) now propagate loudly instead of dark-running the `:integration` suite under a misleading "DB unavailable" banner.

### Fixed
- `evaluate_smart_rules/2` `%NotLoaded{}` raise message for `:catalogue` no longer points readers at `:catalogue_rules` (separate raise below already names that one).
- `Catalogue.Helpers.merge_preloads/2` docstring now matches the pinning test in `catalogue_test.exs` — bare-atom + nested-keyword collision merges (parent loads AND nested child loads), not "silently prefers nested" as the doc previously claimed.
- `lib/phoenix_kit_catalogue.ex` `version/0` and the `version/0` test were stuck at `"0.1.13"` since the 0.1.13 release — now match the package version.
- Closes #16, #17 — already shipped in 0.1.14 (PR #18) but didn't auto-close on GitHub.

## 0.1.15 - 2026-05-02

### Added
- **Drag-and-drop reorder** — catalogues, categories, items, and smart-rule rows can be reordered via DnD. Position writes use a two-pass (negative-then-positive) strategy to avoid unique-index collisions. Cap enforced via `Application.compile_env(:phoenix_kit_catalogue, :reorder_max_uuids, 1000)`.
- **`reorder_categories_groups/3`** — atomic reorder across multiple parent groups in a single outer transaction (cross-parent partial-commit protection).
- **`Helpers.dedupe_keep_last/1`** — shared last-wins deduplication for DnD payloads, replacing ad-hoc `Enum.uniq` calls.

### Changed
- **Audit-trail integrity on cross-category item moves** — rejection and DB-error log rows from `reorder_items/4` inside `move_item_and_reorder_destination/4` now survive outer-transaction rollbacks (split into unlogged inner + logged outer).
- **`refresh_card_items/3`** — gains explicit `delta` param (default `0`). In-scope reorder no longer inflates the limit by `+1` on every drag.
- **`@reorder_max_uuids`** consolidated to `Application.compile_env/3` — single config source shared by `Catalogue` and `Rules`.
- **Global `search_items/2` `order_by`** — reverted to `name + uuid` only. `position` is per-scope and meaningless across catalogues; catalogue-scoped search keeps it.

### Fixed
- Duplicate `list_catalogue_rules` query on smart-item mount eliminated — single fetch derives both `working_rules` and `rule_candidate_order`.
- Smart-rule DnD now uses `dedupe_keep_last` (last-wins) matching catalogue/category/item reorder semantics.

## 0.1.14 - 2026-04-28

### Added
- **Smart-chain guard (issue #16)** — `CatalogueRule` now rejects rules whose `referenced_catalogue` is itself `kind: "smart"`, with the error `"must reference a standard catalogue, not a smart catalogue"` on `:referenced_catalogue_uuid` (`validation: :smart_chain`). Self-references fall under the same guard. Applied to `create_catalogue_rule/2`, `update_catalogue_rule/3`, `put_catalogue_rules/3`, and `change_catalogue_rule/2`. The item-form rule picker now lists only standard catalogues so the user is never offered an option that would fail on save.
- **`:only` scope on `search_items/2` + `count_search_items/2` + `<.item_picker>` (issue #15)** — `:uncategorized_only` restricts to items with no `category_uuid`, `:categorized_only` restricts to items in some category, `nil` (default) is unrestricted.
- **`PhoenixKitCatalogue.Errors`** — central atom-to-string dispatcher (13 plain atoms + 9 tagged tuples) for UI flashes. Plus per-atom pinning tests.
- **Smart Catalogues guide** (`guides/smart_catalogues.md`) — concepts, schema diagram, worked example, host-side reference implementation, pitfalls. Wired into `mix.exs` `package.files` and `docs.extras`.
- `@spec` backfill on the 14 most-called CRUD entry points + 26 specs across `Catalogue`.
- `Test.Endpoint` / `Test.Router` / `Test.Layouts` / `LiveCase` test infra so the suite actually runs (598 → 869 tests).

### Changed
- `search_items/2` and `count_search_items/2` now raise `ArgumentError` on two foot-guns that previously yielded silent empty results: `category_uuids: [nil]` (use `:only => :uncategorized_only` instead) and `:only => :uncategorized_only` combined with non-empty `:category_uuids` (logical contradiction).
- Activity logging — `enable_system` / `disable_system` log `catalogue_module.{enabled,disabled}`. `enabled?/0` adds `catch :exit, _` for sandbox-owner shutdowns. `ActivityLog` rescue narrowed to `Postgrex.Error :undefined_table` for the host-without-V90 case before logging a warning.
- Failure-side audit rows — LV layer writes `metadata.db_pending: true` rows on every LV-visible failure via `Helpers.log_operation_error/3`. Context layer stays success-only.
- `Tree.subtree_uuids_for/1` and `ancestor_uuids/1` cast `^uuid` / `^roots` via `type(_, UUIDv7)` (CTE was losing type info). `ancestors_in_order/1` rewritten — previously returned `[]` for every non-root category.
- `Task.start/1` → `Task.Supervisor.start_child(PhoenixKit.TaskSupervisor, ...)` for the supervised import task.
- `phx-disable-with="Deleting..."` on the two permanent-delete buttons in `components.ex`.

### Removed
- Dead `Catalogue.broadcast_for/2` clauses (`"manufacturer"` / `"supplier"` / `"smart_rule"`) and the orphan `lookup_parent(:smart_rule, _)`. The submodules (`Manufacturers`, `Suppliers`, `Rules`) call `PubSub.broadcast/3` directly and never reached the helper.

### Fixed
- `change_catalogue_rule/2` smart-chain guard no longer issues a DB lookup on every form keystroke — switched to `Ecto.Changeset.get_change/2` so the lookup only fires when `:referenced_catalogue_uuid` actually changes.

## 0.1.13 - 2026-04-26

### Added
- `parent_catalogue_uuid` on PubSub broadcasts for scoped detail-view updates
- `refresh_in_place/1` — updates counts/category tree without wiping scroll state
- Smart items can now be assigned categories and manufacturers for organization
- Import executor emits single roll-up broadcast instead of per-row events

### Changed
- `PubSub.broadcast/3` now accepts optional `parent_catalogue_uuid` (backward-compatible)
- `log_activity/2` supports `broadcast: false` opt for bulk operations

## 0.1.12 - 2026-04-24

### Added
- **Catalogue form tabs** — `CatalogueFormLive` gains Details / Metadata / Files tabs (mirrors `ItemFormLive`). Featured image + attached files live under the Files tab; metadata under Metadata. Panels stay in the DOM (toggled via `hidden`) so multilang state and in-progress input survive tab switches. Save sits outside the tab panels and works from any tab.
- **Catalogue metadata** — `Metadata.definitions(:catalogue)` ships five opt-in fields (`brand`, `collection`, `season`, `region`, `vendor_ref`) stored under `catalogue.data["meta"]`.
- **Category featured image** — `CategoryFormLive` gains a featured-image card (no tabs, no file grid; a category is a taxonomy node). `Attachments.folder_name_for/1` picks up a `%Category{}` clause (`catalogue-category-<uuid>`). Folders are created lazily on first picker open, so categories without a featured image never materialize one.
- `Components.featured_image_card/1` — shared featured-image card (thumbnail + name + size, or dashed empty state with primary button) used by catalogue / category / item forms.
- `Components.metadata_editor/1` — shared metadata tab body (per-key text input + remove button + add-picker dropdown; legacy keys render disabled with a "Legacy" pill).

### Changed
- **`PhoenixKitCatalogue.ItemMetadata` → `PhoenixKitCatalogue.Metadata`** with resource-type-scoped `definitions/1`. Items keep `color / weight / width / height / depth / material / finish`; catalogues get the five new keys above. Upstream consumers of the `ItemMetadata` module (introduced in 0.1.11) need to update the alias and pass `:item` to `definitions/1`.
- Extracted the three-phase form helpers — `Metadata.build_state/2`, `absorb_params/2`, `inject_into_data/3` — out of `ItemFormLive` and into the shared module so `CatalogueFormLive` uses the same plumbing (~150 lines of duplication removed across the three form LVs).

### Notes
- No migrations. All three schemas (`Item`, `Catalogue`, `Category`) already carry JSONB `data`; `featured_image_uuid`, `files_folder_uuid`, and `meta` all live under that column.
- 27 unit tests for the pure `Metadata` helpers + 7 component-render tests for `featured_image_card/1` and `metadata_editor/1`.

## 0.1.11 - 2026-04-22

### Added
- **Nested categories** (requires phoenix_kit 1.7.103+ for the V103 `parent_uuid` self-FK migration). New `PhoenixKitCatalogue.Catalogue.Tree` module with recursive-CTE helpers (`subtree_uuids/1`, `descendant_uuids/1`, `ancestor_uuids/1`, `ancestors_in_order/1`) plus pure in-memory walkers (`build_children_index/1`, `walk_subtree/3`) for preloaded trees. CTEs use `UNION` (not `UNION ALL`) for defense-in-depth cycle safety.
- `Catalogue.move_category_under/3` — same-catalogue reparent with `:would_create_cycle` / `:cross_catalogue` / `:parent_not_found` rejection; `nil` promotes to root.
- `Catalogue.list_category_tree/2` returns `[{category, depth}]` with orphan promotion (deleted-ancestor children surface as roots) and an `:exclude_subtree_of` option for parent pickers.
- `Catalogue.list_category_ancestors/1` (delegates to `Tree.ancestors_in_order/1`) for breadcrumbs.
- `search_items/2` gains `:include_descendants` (default `true`) so a category-scoped search also matches items in descendant categories. Pass `false` for the literal-set semantics.
- **Attachments** — new `PhoenixKitCatalogue.Attachments` module shared by item + catalogue forms. Folder-per-resource, featured-image pointer, inline files dropzone (20 files / 100 MB / `auto_upload: true`), pending-folder rename on first save. Smart detach splits home-folder vs `FolderLink` files; `list_files_in_folder/1` capped at 200 rows. Save button disabled while uploads are in flight.
- **Item metadata** — new `PhoenixKitCatalogue.ItemMetadata` module with a global opt-in list of fields stored on `item.data["meta"]`. Labels are gettext-wrapped; legacy keys (dropped from code but still held by an item) surface as "Legacy" rows with a remove-only action so deleting a definition never wipes stored data.
- **Item picker** — new `PhoenixKitCatalogue.Web.Components.ItemPicker` combobox LiveComponent with server-side search, `:category_uuids` / `:catalogue_uuids` scoping, `:include_descendants` toggle, `:excluded_uuids` dim-and-disable, colocated keyboard hook (ArrowUp/Down, Home/End, Enter, Escape), `has_more` "type to refine" sentinel, and render-shape tests.

### Changed
- Category position scoping moved from `catalogue_uuid` to `(catalogue_uuid, parent_uuid)` — `next_category_position/2` now takes a `parent_uuid` arg (default `nil` for root).
- `swap_category_positions/3` refuses `{:error, :not_siblings}` when the two categories live under different parents or in different catalogues.
- `trash_category` / `restore_category` / `permanently_delete_category` walk the whole subtree in one transaction. `restore_category` also restores deleted ancestors + the parent catalogue so the restored node is reachable. Activity metadata carries `subtree_size` + `items_cascaded`.
- `move_category_to_catalogue` carries the subtree along in a transaction; takes `SELECT … FOR UPDATE` on the moved row and computes the target position *after* the subtree has moved — closes the stale-position race flagged in prior reviews.
- `list_all_categories/0` renders full breadcrumbs (`"Catalogue / Parent / Child"`) and loads in two queries instead of N+1 per catalogue.
- `Category.changeset` rejects self-parent; `create_category/2` and `update_category/3` additionally guard against cross-catalogue and descendant-as-parent (cycle) cases at the context level, so raw API / form callers can't bypass `move_category_under/3`.

### Fixed
- Catch-all `handle_info/2` on `CatalogueFormLive` and `ItemFormLive` — stray monitor signals used to crash these forms.
- `phx-disable-with` on every Move button (category-under-parent, category-to-catalogue, item-to-category, item-to-smart-catalogue).
- `Attachments.soft_trash_file/1` is inlined to avoid depending on the unreleased `PhoenixKit.Modules.Storage.trash_file/1`.
- Credo / dialyzer clean after refactors: nested-too-deep in meta handlers, cyclomatic-10 `file_type_from_mime`, opaque MapSet in `list_category_tree`, unreachable `read_string/2` fallback.

## 0.1.10 - 2026-04-20

### Added
- **Smart catalogues** (`kind: "smart"`) — catalogues whose items are priced as a rule-driven function of other catalogues. New `CatalogueRule` schema (`phoenix_kit_cat_item_catalogue_rules`) and `put_catalogue_rules/3` replace-all API with duplicate detection, per-leg `value`/`unit` inheritance via `CatalogueRule.effective/2`, and `smart_rules.synced` activity logging (added/updated/removed counts). Requires phoenix_kit 1.7.102+ for the V102 migration.
- **Per-item discount override** — nullable `Item.discount_percentage` (`nil` inherits the catalogue's discount, any value including `0` overrides). Pricing chain is now `base → markup → discount`, exposed via `Item.final_price/3`, `Item.effective_discount/2`, `Item.discount_amount/3`, and the expanded `Catalogue.item_pricing/1`.
- **Smart-item defaults** — `Item.default_value` / `Item.default_unit` as fallbacks when a `CatalogueRule` row has `nil` value/unit (lets a user set "5% across everything" once and override specific catalogues).
- `list_items_referencing_catalogue/1` + `catalogue_reference_count/1` for warn-before-delete flows; `permanently_delete_catalogue/2` now refuses with `{:error, {:referenced_by_smart_items, count}}` when smart items still reference the catalogue, unless `force: true` is passed.
- `list_catalogues(kind: :smart)` filter; `Catalogue.move_item_to_catalogue/3` for moving smart items across catalogues (categories don't apply to smart items).
- Scoped search: `search_items/2` accepts `:catalogue_uuids` / `:category_uuids` filters composed via `where dynamic`; new `scope_selector` component pairs with it.
- `category_counts_by_catalogue/0` grouped-query helper.

### Changed
- **Context split** — extracted the monolithic `catalogue.ex` into 10 focused submodules (`Rules`, `Search`, `Manufacturers`, `Suppliers`, `Links`, `Counts`, `PubSub`, `Translations`, `Helpers`, `ActivityLog`). Public surface is unchanged — every caller still goes through `Catalogue.*` via `defdelegate`.
- All form LiveViews (catalogue / category / item / manufacturer / supplier) migrated to Phoenix 1.7 component-style `<.input>` / `<.select>` / `<.textarea>` / `<.checkbox>` bindings. The multilang wrapper now scopes only translatable fields (name / description) — pricing, classification, and actions render as siblings so a language switch doesn't re-mount them.

### Fixed
- Replace raising `confirm_delete!/1` with a safe `case`-match + `unexpected_confirm_event/2` fallback across all 5 delete handlers (item / category / catalogue / manufacturer / supplier). Malformed push events flash + log instead of crashing the LV.
- `Catalogue.ActivityLog.log/1` now rescues — activity-logging failures no longer crash the primary mutation, matching the AGENTS.md contract.
- New `log_operation_error/3` helper in both admin LVs — structured logs carrying `actor_uuid`, `entity_type`, `entity_uuid`, and `Ecto.Changeset.traverse_errors`-expanded field/message pairs so production incidents can be debugged from the log alone.
- Search task-exit logs now include query, offset, and `catalogue_uuid`.
- `phx-disable-with` on 9 destructive-action buttons (trash / restore on catalogue + category + item tables and cards) to prevent double-mutation on slow networks.

## 0.1.9 - 2026-04-15

### Added
- Paged search with infinite scroll across global, per-catalogue, and per-category views (`:limit`/`:offset` on all three search functions; `count_search_items*` companions for "X of Y" totals)
- Per-item markup override — nullable `markup_percentage` on items (`nil` inherits the catalogue's markup, any value including `0` overrides it); requires phoenix_kit 1.7.96+ for the V97 migration
- `Item.effective_markup/2` and `Catalogue.item_pricing/1` expose which markup applies (catalogue vs item) for pricing UI
- Import wizard: markup override column with multilingual synonym detection (markup/margin/naceenka/juurdehindlus/aufschlag/...)
- Import wizard: manufacturer and supplier pickers (four-mode vocabulary `:none`/`:column`/`:create`/`:existing`), shared `<.party_picker>` and `<.new_party_form>` components
- Import wizard: language-aware category get-or-create with "match across all languages" toggle; inline category creation in `:create` mode
- Import wizard: empty-pool warning when a picker column is exhausted by a sibling picker's mapping

### Changed
- Search uses `start_async` with a query-equality guard in `handle_async`, so out-of-order or superseded responses are dropped; scroll paging also runs off the LV process via `start_async(:search_page, …)` guarded on `{query, offset}`
- Import executor phase 1 (get-or-create categories / manufacturers / suppliers) wrapped in a single `Repo.transaction` so a mid-phase crash rolls back any entities earlier loops persisted
- Three `:create`-mode resolutions in the wizard wrap in `Repo.transaction` at the LV layer so a failure on the second/third doesn't leave the first as an orphan
- `Catalogue.item_pricing/1` now returns `catalogue_markup`, `item_markup`, and effective `markup_percentage` so callers stay internally consistent
- `IntersectionObserver` hook re-fires on `updated()` — fixes the "loads forever" bug on tall viewports / Page Down

### Fixed
- Upload button stays disabled while the upload XHR is in flight (server-side guard in `parse_file`) — fixes the "click during upload erases the file" race
- Parser strips fully-empty columns (blank header AND every data cell blank) — fixes phantom mapping cards on FENIX-style spreadsheets with leading/trailing empty columns
- Catalogue picker loads on first HTTP mount (no empty-dropdown flash); options show counts (`Kitchen · 5 categories · 47 items`)
- Sample data table: `#` row-number column, truncation tooltips, stable collapse `id` so morphdom preserves open state

## 0.1.8 - 2026-04-12

### Fixed
- Add routing anti-pattern warning to AGENTS.md

## 0.1.7 - 2026-04-11

### Added
- Items belong directly to catalogues via catalogue_uuid FK (requires phoenix_kit 1.7.95+)
- Infinite scroll on catalogue detail page with cursor-based pagination
- Activity logging with Events tab (actor tracking on all mutations)
- Item counts on catalogue list view
- Clickable entity names (manufacturers, suppliers)
- Comprehensive test suite: LiveCase, LiveView tests, schema tests

### Changed
- Removed safe_nested_assoc/2 in favour of direct catalogue association on items
- Category and item mutations now accept actor_uuid for activity logging

## 0.1.6 - 2026-04-09

### Added
- Dynamic file import system (CSV/Excel with multi-sheet support)
- Auto-detect column→field mappings
- Unit normalization and duplicate detection
- Full import LiveView (upload → parse → map → confirm → execute)

### Changed
- Updated phoenix_kit dependency to 1.7.93

## 0.1.5 - 2026-04-08

### Added
- **Dynamic file import** — upload XLSX or CSV files, auto-detect column mappings, map columns to item fields via drag-down UI
- **Import language support** — select which language the file data is in, stored in multilang JSONB
- **Import category support** — import into existing category, create categories from column values, or import without category
- **Unit mapping** — auto-detect and map file unit values (TK, KMPL, LEHT, PAAR) to system units (piece, set, pair, sheet, m2, running_meter)
- **Duplicate detection** — detect identical rows within file and items already in catalogue, with skip/import choice
- **New unit types** — added `set`, `pair`, `sheet` to allowed item units
- **Multilang search** — search now matches translated content in JSONB `data` field across all languages

### Changed
- Removed unique constraint on item SKU field to allow duplicate article codes
- Item edit form now detects imported items with non-primary language and shows rekey warning

### Fixed
- Search across translated content in `data` JSONB field

## 0.1.4 - 2026-04-06

### Changed
- Wrap all user-visible strings in Gettext for i18n

## 0.1.3 - 2026-03-31

### Added
- **Pricing system** — rename `price` to `base_price` on items, add `markup_percentage` to catalogues (default 0%), computed sale price via `Item.sale_price/2` and `Catalogue.item_pricing/1`
- **Search** — `search_items/2` for global cross-catalogue search, `search_items_in_catalogue/3` for catalogue-scoped search, `search_items_in_category/3` for category-scoped search; matches name, description, SKU via case-insensitive ILIKE with special character sanitization
- **Reusable components** (`PhoenixKitCatalogue.Web.Components`):
  - `item_table/1` — configurable data-driven table with selectable columns, opt-in actions, card view toggle
  - `search_input/1` — search bar with debounce and clear button
  - `search_results_summary/1` — result count display
  - `empty_state/1` — centered empty state card
  - `view_mode_toggle/1` — global table/card toggle syncing multiple tables via shared storage key
- **Card view** — all tables (catalogues, manufacturers, suppliers, items) support table/card view toggle with localStorage persistence; card titles are clickable links
- **Inline actions** — table row actions render as inline buttons on desktop, collapse to dropdown menu on mobile (via `table_row_menu` `mode="auto"`)
- `Catalogue.swap_category_positions/2` — atomic position swap in a transaction
- `Catalogue.list_items/1` — global item listing with status filter and limit
- `Catalogue.item_count_for_catalogue/1` and `category_count_for_catalogue/1` — active counts
- **Gettext localization** — all component text (column headers, actions, tooltips, result counts) localizable via PhoenixKit's Gettext backend
- **Graceful error handling** — components never crash; unknown columns, unloaded associations, nil values, and bad path functions produce "—" placeholders and Logger warnings
- All item list/search functions now consistently preload `category: :catalogue` and `:manufacturer`

### Fixed
- Category reorder now atomic (wrapped in transaction instead of two separate updates)
- `sync_manufacturer_suppliers/2` and `sync_supplier_manufacturers/2` now return `{:ok, :synced}` or `{:error, reason}` instead of silently swallowing errors
- `restore_item/1` now cascades upward to both parent category AND parent catalogue (was only restoring category)
- `deleted_item_count_for_catalogue/1` uses single JOIN query instead of two separate queries
- Removed misleading `list_uncategorized_items_for_catalogue/2` (ignored catalogue param), replaced with `list_uncategorized_items/1`
- Confirm-delete flows use modal dialogs instead of broken inline two-step pattern
- Forms use `action="#"` to prevent HTTP POST fallback before LiveView connects
- Added `:phoenix_kit` to `extra_applications` for module discovery

### Changed
- All LiveViews migrated to use PhoenixKit core components (`table_default`, `table_row_menu`, `status_badge`, `admin_page_header`, `confirm_modal`, `icon`)
- Removed all inline HTML tables, SVG icons, and local badge/format helpers in favour of shared components
- Manufacturer/supplier form save flows now handle sync errors with warning flash messages

## 0.1.2 - 2026-03-27

### Changed
- Bump Elixir requirement from ~> 1.15 to ~> 1.18 (align with sibling modules)
- Bump ex_doc from ~> 0.34 to ~> 0.39
- Update AGENTS.md: reorganize commands, add critical conventions, commit message rules, external dependencies section, and PR docs templates

## 0.1.1 - 2026-03-25

### Changed
- Remove all migration references — database and migrations are managed by the parent `phoenix_kit` project
- Add "Database & Migrations" section to README and AGENTS.md explaining where DB lives
- Remove `test.setup` and `test.reset` mix aliases (no longer needed)
- Remove test-only migration file and migration runner from test helper

## 0.1.0 - 2026-03-25

### Added
- Extract Catalogue module from PhoenixKit into standalone `phoenix_kit_catalogue` package
- Implement `PhoenixKit.Module` behaviour with all required callbacks
- Add `Catalogue`, `Category`, `Item`, `Manufacturer`, `Supplier`, and `ManufacturerSupplier` schemas with UUIDv7 primary keys
- Add `PhoenixKitCatalogue.Catalogue` context with full CRUD for all schemas
- Add soft-delete system with cascading trash/restore for catalogues, categories, and items
- Add move operations for categories (between catalogues) and items (between categories)
- Add multilingual support for translatable fields via PhoenixKit's multilang system
- Add admin LiveViews: catalogues, categories, items, manufacturers, suppliers with forms
- Add centralized `Paths` module for route generation
- Add `css_sources/0` for Tailwind CSS scanning support
- Add behaviour compliance and catalogue context test suites
