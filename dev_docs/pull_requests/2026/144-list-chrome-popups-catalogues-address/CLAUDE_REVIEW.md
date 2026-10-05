# PR #144 — List pages: Filters and View options pop-ups, fitted tables, `/admin/catalogues`

- **Author:** mdon (Dmitri Don)
- **Merge:** `cbc0e17` (head `17dcbfa`)
- **Reviewer:** Claude
- **Date:** 2026-10-05

## Scope

- The admin address moves from `/admin/catalogue` to `/admin/catalogues`
  (tabs, `Paths`, activity-log record links, the attribute sets' managed
  path, the settings page), with `Web.LegacyPathController` 301-ing the old
  addresses — gated as admin-only and aware of a renamed admin area.
- Every list's loose controls fold into two pop-ups: Filters beside the search
  (`search_filters/1`) and View options beside the create buttons
  (`view_options/1`, `push_closing/2`). A catalogue level that lists
  categories and items shares ONE sort (`sort_level`).
- Tables are fitted with core's `<.table_default fit>` and a
  `column_priority/1` per header cell; the bulk bar docks under its list.
- The subcategory tree is re-laid with a rail and an elbow per level.
- The `FOLLOW_UP.md` files for PRs 126–143 and the AGENTS.md/README updates.

## Verified

- **The old addresses.** `target/2` moves only a whole segment and only the
  first occurrence, runs both moves through `Routes.apply_admin_segment/1`
  (so a host with `admin_path: "/backoffice"` is redirected, not looped), and
  the controller answers `:unchanged` with a 404 rather than a redirect to
  itself. No `/admin/catalogue` literal is left in `lib/` outside the
  redirect module and its routes. The managed-path backfill
  (`AttributeSets.backfill_managed_path/0`) rejects rows already on the new
  path, so existing attribute-set blueprints are re-stamped with it.
- **Both lists' sort persists.** `sort_level` goes through
  `apply_categories_sort/3` (persists `:detail_categories`) and
  `apply_items_sort/3` + `persist_detail_sort(:detail_items)`, so both shared
  sorts are saved and broadcast; `level_sort/1` reads them back consistently.
- **Gettext.** The six new msgids (`View options`, `Filters`, `Sort by`,
  `Layout`, `Reorder all categories`, `Reorder all items`) are in
  `default.pot` and all five locales, and pinned in `test/gettext_test.exs`.
- **Column fitting degrades.** `table_fit/0` is passed as a dynamic attribute,
  so a core without `fit` ignores it. Verified by running the suite against
  the locked Hex core (2.53.0): everything passes except the four tests
  below; against `../phoenix_kit` (2.54.0) all pass.

## Findings

### IMPROVEMENT - MEDIUM — four tests fail on any core older than 2.54.0

`<.table_default fit>` first ships in `phoenix_kit` 2.54.0, which is not yet on
Hex (the latest is 2.53.0, and `mix.lock` resolves to it). The module is meant
to keep working on the older core — `Components.table_fit/0` says so — but
`ListChromeTest` looks for the `TableFit` hook unconditionally, so `mix test`
failed four tests (`list_chrome_test.exs:145` ×2, `:299`, `:322`) for anyone
not running with `PHOENIX_KIT_PATH`.

**Fixed.** The tests that need a fitted table carry `@tag skip: @needs_fit`,
which is `false` when the loaded core declares the `fit` attribute and a
reason string when it does not. The row-alignment checks still run on 2.54.0.
The `mix.exs` floor is left alone: the feature degrades, and the floor is not
tightened for it (see the CHANGELOG note).

### IMPROVEMENT - MEDIUM — a `//host/admin/catalogue` request crashed the redirect

The router ignores empty path segments, so `//evil.example/admin/catalogue`
reaches `forward/2` with `request_path` still starting `//`. `target/2` kept
the prefix, and `redirect(to: "//evil.example/admin/catalogues")` raised
`ArgumentError` (Phoenix refuses a protocol-relative target) — a 500. Not an
open redirect, and behind the admin gate, but a crafted URL should not 500.

**Fixed.** `target/2` collapses leading slashes first, so the answer is a
301 to `/evil.example/admin/catalogues` (a path on this host, which then
404s). Pinned in `test/web/legacy_path_test.exs`.

### NITPICK — stale comment

The `:admin_catalogue` tab's comment still gave `"catalogue/:uuid/edit"` as
its example path. Updated to `catalogues/`.

### NITPICK — formatting left behind (not fixed in the PR)

`view_options/1`'s `slot :row, doc: …` was not in `mix format` shape on
Elixir 1.19; formatted. (AGENTS.md notes 1.18 and 1.19 disagree on wrapped
`, do:` continuations — this one is a `slot` line, not a `, do:`.)

## Not changed

- `view_options/1` now shows in the Deleted view of a catalogue level (the
  right-hand cluster used to be gated on `@view_mode == "active"`). Its sort
  and layout rows still apply there, so this reads as intended.
