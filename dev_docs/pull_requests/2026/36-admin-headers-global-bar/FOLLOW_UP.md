# PR 36 follow-up — Admin headers and the global bar

Triaged 2026-08-29 as part of the four-repo quality sweep. Every finding in
the review was re-verified against current code.

## Fixed (pre-existing)

- ~~**MEDIUM (pre-existing):** `version/0` had drifted from `mix.exs`'s
  `@version`.~~ Both read `"0.20.0"`, and the test is now exact equality
  rather than a loose match (`test/phoenix_kit_catalogue_test.exs:214`).
- ~~**NITPICK:** `catalogues_live` rendered an empty toolbar wrapper.~~ Moot —
  that div no longer exists; the page was rebuilt around `table_toolbar` and
  `app_layout` (`web/catalogues_live.ex:2626-2634`).

## Open — small, deliberate leftovers

The review filed these as LOW / NITPICK and they are all still true. None is a
defect; each is a consistency gap worth closing when the file is next open.

- **Three admin LiveViews are not on the self-wrap pattern.**
  `web/pdf_library_live.ex` has migrated since; `web/export_live.ex`,
  `web/import_live.ex` and `web/pdf_detail_live.ex` still rely on the
  auto-chrome path.
- **Form views have no explicit back affordance** (`catalogue_form_live`,
  `category_form_live`, `item_form_live`). Deliberate under the pattern the PR
  introduced, but worth confirming that is still the intent now that
  `admin_page_header` has a proper `back` control.
- **`project_title` is never threaded to `app_layout`** — zero occurrences in
  `lib/phoenix_kit_catalogue/web/`. Harmless because `LayoutWrapper` falls back
  to `PhoenixKit.Settings.get_project_title()`, so the cost is one settings
  read per mount rather than a wrong title.
- **Orphaned msgid `"%{count} events"`** in all four catalogues
  (`priv/gettext/default.pot:834` and the three `.po` files). Now that
  extraction is safe here (see PR #57's follow-up), a regenerate would drop it
  cleanly.

## Verification

| Step | Result |
|---|---|
| `mix test` | 2 doctests, 2049 tests, 0 failures |
| `mix precommit` | passes |
