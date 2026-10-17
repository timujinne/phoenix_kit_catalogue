# PR #151 — Split the Gettext backend, and split the catalogue context into section modules

- **Reviewer:** Claude
- **Date:** 2026-10-15
- **Author:** Max Don (merged by Dmitri Don)
- **Scope:** `catalogue.ex` 7 714 → 775 lines (facade: moduledoc +
  `defdelegate`s); new `Catalogue.{Catalogues, Categories, Folders, Items,
  Shared, Trash}`; `split_module_by: [:locale, :domain]` on the Gettext
  backend; AGENTS.md and the trash guide.

A move this size is only reviewable by proving it is a move, so that is what
was done. No defect found.

- **The public surface is identical.** Every `def` head of the old
  `catalogue.ex` (112 heads, every arity a default argument produces) was
  parsed from `git show 0ff1c7b:…` and checked with `function_exported?/3`
  against the compiled new `PhoenixKitCatalogue.Catalogue`: none missing.
- **The code is the same code.** The sorted multiset of whitespace-stripped,
  comment-stripped lines of the old file was diffed against the six new
  section modules plus the facade. What differs is, in full: private helpers
  that more than one section needs became `def … ` in `Shared` / `Trash`
  (`@doc false`), and their call sites gained a `Shared.` / `Trash.` prefix
  (`log_activity`, `valid_uuid?`, `next_level_position`, `lock_*`,
  `locked_transaction`, `stamp_trashed*`, `restore_trashed`, `trashed_by*`,
  `outside_trashed_categories`, …); calls to another section's public
  function go through `PhoenixKitCatalogue.Catalogue.…`, as the AGENTS.md
  rule says. No condition, query or argument order changed.
- **No section reaches into a sibling.** `rg` for `Catalogues.` / `Categories.`
  / `Folders.` / `Items.` call syntax inside the six modules finds none.
- **Gettext.** `split_module_by` needs gettext 1.0; core already requires
  `~> 1.0` and the lock is on 1.0.2. Lookups, including the runtime
  `Gettext.gettext(PhoenixKitCatalogue.Gettext, …)` form, are unchanged;
  the hand-maintained `.pot` is untouched.

## NITPICK — the trash guide and AGENTS.md name `Catalogue.Trash` for helpers that live in two modules

The provenance helpers (`stamp_trashed/4`, `restore_trashed/3`,
`lock_catalogue!/1`) are in `Trash`; `keep_trash_status/3` and
`stamp_created_deleted/1`, which the same rule is about ("plain `update_*`
never moves a row into or out of `deleted`"), are in `Shared`. Accurate as
written, a reader following "go through `Catalogue.Trash`" for a new path
may miss them. **Not changed**; the combination test in
`test/catalogue/trash_restore_test.exs` is the net.
