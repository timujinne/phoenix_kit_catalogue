# PR #147 — Quality sweep: import survives any file, language picker saves, export is permission-gated, audit rows carry their actor

- **Reviewer:** Claude
- **Date:** 2026-10-13
- **Author:** mdon (merged by Dmitri Don)
- **Scope:** 62 files; `import/{encoding,parser,executor,source/universal}`,
  `web/{export_controller,legacy_path_controller,view_config,settings,
  settings_live,import_live,catalogues_live,catalogue_detail_live}`,
  `catalogue.ex` activity-log fixes, `pub_sub.ex`, gettext, tests.

No bugs found in the PR itself.

## What was checked

- **`Import.Encoding`** — UTF-8 BOM, UTF-16 LE/BE BOM, and a NUL byte are all
  settled before a parser sees the text. A UTF-32 LE file (`FF FE 00 00`) is
  read as UTF-16, comes out with NULs and is refused by the same NUL check, so
  it is not mis-imported. Windows code pages are refused rather than guessed.
- **Parse entry guards** — every `XlsxReader` call is inside a guard, so a corrupt
  worksheet returns the existing read-failed error (pinned by the new XLSX
  fixture tests).
- **Export download** — `require_module_access/2` runs after the admin plug;
  unknown destination/format and non-canonical uuids answer 400 instead of
  reaching `Export.build/1`, which raises on them.
- **Legacy redirects** — the unsafe characters `Phoenix.Controller.redirect/2`
  raises on are encoded in the query and refused (404) in the path; no
  `Location` header can carry a line break.
- **Shared sort** — written only when it changed, with the acting admin and
  `source: "settings"`; the pages re-read the stored sort on a broadcast, so a
  late broadcast cannot override it.
- **Activity rows** — repeated trash/restore logs nothing; import completed/failed
  rows are written by the task, not the page.

## NITPICK — gate was red on HEAD for an unrelated reason

The `libs` commit (core 2.61.0 → 2.62.2) made the suite fail in 52 places: core
now leaves the locale segment out of admin paths on a single-language site, and
the test router and ~240 expectations assume `/en/admin/...`. Not this PR's
doing; fixed in the release commit (see `148-media-folders/FOLLOW_UP.md`).
