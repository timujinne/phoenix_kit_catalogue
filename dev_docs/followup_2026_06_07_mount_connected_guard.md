# Follow-up: guard DB loads in the form LiveView `mount/3`s

Status: **deferred** (needs the DB-backed LiveView test suite to validate;
not runnable in the environment where this was scoped). Surfaced by the
wider code review on 2026-06-07.

## Problem

`mount/3` runs **twice** per page load — once for the disconnected/static
HTTP render, once for the WebSocket connect. Several LiveViews issue DB
queries directly in `mount/3`, so every load runs those queries twice. The
page LVs already avoid this (load in `handle_params/3` and/or gate on
`Phoenix.LiveView.connected?/1`); the **form** LVs do not.

## Affected files (unguarded queries in `mount/3`)

| File | What it queries in mount | Severity |
|------|--------------------------|----------|
| `web/item_form_live.ex:57` | heaviest: `load_item` + `mount_form` → categories (×2), parent catalogue, smart catalogues, manufacturers, rule state (`list_catalogue_rules` + `list_catalogues`) | HIGH |
| `web/catalogue_form_live.ex:50` | `:edit` → `get_catalogue` + `change_catalogue`; `Attachments.mount_attachments` (files query); `assign_ai_translation` | HIGH |
| `web/category_form_live.ex:41` | `:new` → `next_category_position` + `parent_options_for`→`list_category_tree`; `:edit` → `get_category` + `list_catalogues` + `list_category_tree` | MEDIUM |
| `web/manufacturer_form_live.ex:21` | `:edit` → `get_manufacturer` + `linked_supplier_uuids`; always `list_suppliers(status: "active")` | MEDIUM |
| `web/supplier_form_live.ex:21` | `:edit` → `get_supplier` + `linked_manufacturer_uuids`; always `list_manufacturers(status: "active")` | MEDIUM |
| `web/pdf_detail_live.ex:33` | `load_pdf` (`get_pdf` + preload) — note the subscribe IS already `connected?`-guarded, so this one is just inconsistent | MEDIUM |

`web/import_live.ex:48` also queries in mount, but it's deliberate, documented,
and cheap (5 small queries) — leave it. The note in `item_form_live` (~`:169`)
already acknowledges its mount "fires twice … tracked as a separate follow-up."

## The pattern to copy (already used by the page LVs)

`catalogue_detail_live`, `catalogues_live`, `pdf_library_live`, `events_live`:
`mount/3` sets only cheap shell assigns; the real loads run guarded by
`connected?/1` (in `handle_params/3` or a `load_*` helper). The disconnected
render shows a loading/empty shell, the connected mount loads for real.

For the forms specifically:
- `:new` actions need almost no DB (`change_*/1` is a pure changeset builder)
  — only the option lists (`list_suppliers`/`list_manufacturers`/category
  tree) are queries; guard those.
- `:edit` actions need the record to render. On the disconnected render, assign
  a **blank placeholder** (empty changeset/form, empty option lists) so the
  template can't `KeyError`; load the real record + lists on connect.
- Move the "not found → `push_navigate`" decision to the connected path (it
  already works there).

## Why it's deferred, not done

The fix is a behavior change to the static (disconnected) render. If any
template references an assign that's only set on connect, the **initial HTTP
render 500s** — an outward-facing regression. The repo's LiveView test suite
(`test/web/*form*`, `item_form_live_test`, `form_lv_branches*`, etc.) is the
right safety net, but it requires PostgreSQL + the test Endpoint, which weren't
available when this was scoped. Do this where `mix test` runs green, and add a
test asserting the disconnected render (`Phoenix.LiveViewTest` static render)
of each form doesn't query / doesn't crash.
