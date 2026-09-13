# Quality sweep — phoenix_kit_catalogue (2026-09-13)

Playbook: `~/Desktop/Elixir/dev_docs/quality_sweep.md`. Shape: re-validation
of the 135 commits since the 2026-08-31 pass (the selector arc, the
migration chain, slugs/SEO, translations, the popup sort, and the
2026-09-12 client-report day), plus Phase 1 catch-up for the eighteen PR
folders (#88–#111) that had no `FOLLOW_UP.md`. Everything landed on the
already-open [PR #112](https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/112)
(one PR per repo, the boss's rule).

## C0 — baseline

- Tests: 2620/0, `mix precommit` 0, ten consecutive runs stable before
  any sweep change (`scratchpad/stability10.log`: runs 1–7 at 2620/0;
  runs 8–10 picked up half-applied edits mid-loop and are not a signal).
- Visual: the localhost Chrome tab cannot screenshot (renderer timeouts,
  known), so the baseline is structural — every admin page's dead render
  fetched and its landmark counts recorded (`c0_baseline_2026-09-13.txt`
  in the session scratchpad): sidebar/nav/header/main present on all 15,
  form/table/button/input counts per page. The after-pass re-fetch is
  compared to it (see Gates).

## Phase 1 — PR catch-up (#88–#111)

`FOLLOW_UP.md` written for all eighteen folders. Every review was re-read
and every finding re-verified against `main` by three read-only
verification agents, then checked again where it mattered. Every BUG and
IMPROVEMENT across the eighteen reviews was already fixed on `main`
(with the fixing commit named in each file). Taken in this pass:

- **`SupplierFields` read-modify-write race** (2026-08-31 "recorded, not
  fixed"): every definition write now reads and writes the blueprint row
  under `FOR UPDATE` in one transaction, activity row and broadcast after
  the commit.
- Dead `table_toolbar` API (`:mode` slot, `show_table_tools` attr) and an
  unused `item_result_path/2` argument removed.
- A wrong test comment about `box-sizing`; the AGENTS.md tag ceiling.
- `mix hex.audit` now passes, so `mix precommit` runs as one command again
  (the `decimal` advisory in #110's review has cleared upstream).

Surfaced to Max, not decided here: the `de`/`fr` catalogues are ~95%
English (a translation pass, not a code fix); the keyboard/ARIA pass on
table cells; scope-aware tile counts in the popup; a catalogue-kind guard
in `Browse.smart_fee/1`; the folder-name race (needs core `Storage`);
`mix precommit` running no tests.

## Phase 2 — triage (four agents, C12 prompts verbatim) + deep dive

Every finding below was verified against the code before acting; every
fix carries a test that fails on the previous commit unless noted.

### Security + error handling + async UX (agent 1)

- **HIGH — `featured_image_uuid` reached a URL path unchecked in two of
  four readers** (`Components.featured_image_uuid/1`,
  `ItemPicker.selected_photo_uuid/1`); `Browse` had the canonical-form
  guard since 2026-08-31. Both now require equality with
  `Ecto.UUID.cast/1`'s result. Pinned.
- **HIGH — the import mapper parsed a hidden `data:<key>` target** the
  select never offers, letting a crafted mapping write verbatim cell
  content into reserved `data` keys (`featured_image_uuid`,
  `files_folder_uuid`, `media_order`). The clause is gone; column
  indexes come through `Integer.parse` with a guard; non-map `mapping` /
  `unit_map` payloads are ignored. Pinned through the wizard.
- MEDIUM — crash vectors on client payloads: `Integer.parse/1` on a
  non-binary (`remove_supplier_field_choice`), unguarded `String.trim/1`
  at eight sites across four LiveViews and the PDF search modal, a
  non-string `category_uuid`. `Web.Helpers.trim_param/1` neutralises
  the shape; the index handler has a fallback clause. Pinned.
- MEDIUM — **the create paths had no owned-key narrowing**: a new item /
  category / catalogue could seed any top-level `data` key (translation
  fingerprints included). `Web.Helpers.narrow_new_data/2` narrows the
  create payload to the same keys the edit path owns. Pinned.
- MEDIUM — eleven mutating `phx-click` buttons without `phx-disable-with`
  (PDF library card actions, the translations page's enqueue buttons, the
  item form's supplier actions). One new string, "Working...", in all
  five catalogues. Pinned on the translations page.
- LOW — `crm_link.ex`'s already-linked changeset now carries `:action`;
  `ExportController` filters `catalogue_uuids` to canonical uuids
  instead of 500ing; `EventsLive`'s two bare rescues log what failed.

### Translations + activity logging + tests (agent 2)

- **HIGH — one msgid in code and in no catalogue** ("Unknown target
  language — refresh the page and try again."). Added to the pot and all
  five locales.
- **HIGH — seven attribute/value mutations wrote no audit row**
  (`update_attribute`, `reorder_attributes`, `create/update/delete_attribute_value`,
  `set_default_value`, `reorder_attribute_values`); five could not even
  receive an actor. All take `opts` now, log with the actor and the
  caller's mode, and the form passes `actor_opts/1`. One pin per action.
- The events page: "System" was a bare text node; the mode and resource
  badges rendered raw keys; a duplicated date formatter with a hard-coded
  English date replaced by the shared `Helpers.format_time_ago/1`.
  `Components.status_label/1` was a byte-identical copy of the helper's;
  deduplicated. A literal NUL byte in a test source replaced by `<<0>>`.
- A rescued DB exception (`Attributes.run_reorder/1`) was `inspect`ed
  into a flash with its SQL and constraint names; `Errors.message/1` now
  renders exceptions through `Exception.message/1`, truncated. Pinned.
- `Attachments.trash_file/2`'s failure writes the `db_pending` audit row
  the module's convention promises. `ImportLive`'s direct
  `PhoenixKit.Activity.log/1` calls go through `ActivityLog.log/1`.

### PubSub + cleanliness + public API (agent 3)

- **HIGH — dead `move_item_and_reorder_destination/4`** (zero callers)
  broadcast from inside its own transaction; removed with its
  in-transaction helper.
- **HIGH — `:item_supplier_info` broadcasts carried no parent**, so every
  open detail page re-ran the supplier cost aggregate on any supplier
  edit anywhere; the five sites now carry the item's catalogue and the
  detail page ignores other catalogues' events.
- `Pro100TemplateLoader` replaced the whole `data` map from a snapshot;
  it writes only the `"pro100"` namespace as an owned key.
- The detail page's three custom PubSub families get explicit ignore
  clauses for other catalogues' traffic (no more debug line per event).
- `ItemFormLive`'s three error branches that dropped the reason now log
  it (`log_operation_error/3`). `bulk_restore_items/2`'s hard match on
  the transaction result became a `case`. A dead delegate and a dead
  mount-time query removed; six missing `@spec`s added.

### Host-integration boundaries (agent 4)

- README drift, all fixed: a documented `show` attr the
  `ItemSelectorModal` never had (the working pattern is `:if`); a
  documented `empty_state/1` component the module does not ship; two
  removed routes still listed and six real ones missing; the JS-hooks
  section silent about the two hooks shipped via `js_sources/0`;
  `CatalogueBrowse` absent. AGENTS.md's PubSub shape was wrong (the
  fourth element is the parent catalogue, and four more tuples share the
  topic) and its settings table listed a users-table key as a Settings
  key while missing the real `catalogue_sort_*` keys.
- `Components.item_picker/1` made `locale` required, contradicting the
  component it wraps; `item_table/1`'s doc stated the wrong `cards`
  default; the modal's moduledoc omitted `mode`, `immediate`, `per_page`,
  `locale`.
- Pins added: `js_sources/0` names an existing file registering every
  hook the templates use; the full documented pick payload reaches a host
  key by key; the extension slot's `current_language` is rendered by the
  fake extension.

### Deep dive (C12.5), done by hand

- FK columns vs indexes in the SQL chain: 19 FKs, all indexed.
- Rarely used components: the module's own page sections plus core's
  `draggable_list`, `file_upload`, `column_settings_modal`,
  `multilang_tabs`, `bulk_*` — sources read this session or in earlier
  sweeps.
- C14 greps: `IO.*`, `TODO/FIXME`, raw error strings, commented-out defs,
  `Task.start`, CDN assets, `@deprecated` — zero unexplained matches;
  `String.capitalize` appears only in comments forbidding it.

## Recorded, not fixed (surfaced; Max's call)

- Check-then-act in every item/category/value **reorder** path (the
  sibling-scope read is outside the write transaction, no lock) — the
  catalogues/folders domain has the advisory-lock pattern; a wider
  change with its own test design.
- `next_*_position` read outside the insert transaction in
  `create_item/2` and `create_category/2` (same-position race).
- The import executor's category get-or-create races two concurrent
  imports; it also matches names exactly (case and whitespace).
- `TranslationsLive`, `ExportLive`, `ImportLive` do not subscribe to the
  catalogue topic (stale rows/pickers until reload).
- 23 public delegates with no caller anywhere; ~988 lines of PRO100
  *template* import reachable only from tests (a feature, not deleted).
- Five different error atoms for "uuids outside the claimed scope".
- 141 stale msgids in the hand-maintained pot; `de`/`fr` ~95% English;
  `errors_test.exs` pins English only.
- Metadata carries filenames and truncated extraction errors into the
  audit feed.
- `AITranslatable` writes carry neither actor nor `mode: "auto"`.
- The three form LiveViews copy the seven-clause `Attachments` contract
  by hand (no `__using__`).
- No pin for the supplier-fields row lock (the sandbox serialises
  connections) or for the staged-sets dedupe.

## Gates

- `mix precommit` clean; full suite green with live Postgres — numbers in
  the PR body.
- C0 structural baseline re-fetched after the pass: same landmarks on
  every page.
- The whole PR diff went to the panel afterwards (Max's ask): GLM-5.3 on
  two slices (context side, web side), grok on the create-path
  narrowing and the supplier-fields lock; codex on its usage limit until
  the morning. Four real findings, all fixed in the review-round commit:
  `attach_files/3` wrote nil for pointers it had nothing to say about
  (an owned nil deletes); the blueprint get-or-create ran inside the
  lock transaction, so a lost provisioning race would have aborted it;
  the restore rollback's audit row was filed under the wrong action; the
  export controller silently dropped a malformed uuid. Refuted: that the
  create-path narrowing drops translation fingerprints (the worker
  writes them to the row; the form only re-reads them). Everything else
  in both slices was checked and found sound, including the owned-key
  delete semantics, the tree-memory round trip, transaction/broadcast
  ordering and every changed arity.
