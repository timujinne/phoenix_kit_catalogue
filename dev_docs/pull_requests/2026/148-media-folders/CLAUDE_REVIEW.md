# PR #148 — Add a default Catalogues/Category/Item media folder layout

- **Reviewer:** Claude
- **Date:** 2026-10-13
- **Author:** timujinne (merged by Dmitri Don)
- **Scope:** new `media_folders.ex` (+ 886-line test), `Catalogue` hooks
  (`follow/2`, `release_plan/1`, `release/1`, `moving_*`), `Attachments`
  (`ensure_folder_under/3`), `mix.exs` default hooks, README/AGENTS.

The design holds up: containers are built top-down without re-entering the
hook, a folder a person moved or renamed is left alone, bulk moves are one
`UPDATE`, hard deletes free the name, and every path that moves a record
(update, move, bulk move, trash dispositions, restore, permanent delete of a
parent) calls `follow/2`. One real defect, one inconsistency noted.

## BUG - MEDIUM — a refused folder move could roll back the caller's delete or trash

`follow/2` is documented as never failing the save, and it rescues exceptions.
But two context paths call it **inside their own transaction**:
`permanently_delete_category/2` (promoting a kept subcategory) and
`bulk_trash_categories/3` (through `trash_category/2`). `relocate/4` took
core's `Storage.update_folder/2`, which `rollback`s when it refuses. In a nested
Ecto transaction a rollback taints the outer one, so a folder that merely could
not follow (every candidate name taken in the destination: `free_name/3` fell
back to the last name, which is taken by construction) turned the whole delete
or bulk trash into `{:error, :rollback}`.

**Fixed.** `free_name/3` now answers `nil` when no name is free and `relocate/4`
leaves the folder where it is (logged, `:name_taken`) instead of attempting a
write that must fail. Regression test: "a folder that cannot follow its record
does not undo the transaction the context called it from".

## IMPROVEMENT - MEDIUM — a hard `delete_category` / `delete_catalogue` leaves the items' folders in the renamed container

Items survive both deletes (`ON DELETE SET NULL` on `category_uuid` /
`catalogue_uuid`), so only the category/catalogue folders are released
(renamed to the deterministic name); their items' folders stay inside them and
are no longer "where the hooks put them", so they are not followed afterwards.
This matches the documented "a hard delete leaves the folder and files", and
the files stay reachable by pointer, so it is **not changed**. The permanent
delete paths cascade the items and release them too.

## NITPICK — per-record cost of reading names without a settings cache

`base_name/1` asks `Languages.get_languages/0` once per record, which is a few
settings reads per item when core's cache is not running (the test env). In a
host it is ETS. The 100-item bulk-move test's query bound (400) was tight
enough to fail as soon as the test site became multilingual; it is now 800,
still far below the one-by-one cost (~6 extra queries per folder).
