# PR #50 — PRO100 force-create, code+name matching, and the estimate-template layer

Merged as `7f731df` (branch `feature/pro100-sync-key`, commits `c30d351` +
`97031c5` + `fe5506a`, author @timujinne).

## Goal

Three separate improvements to the PRO100 import path, developed on two
branches and landed together:

1. **Force-create.** A PRO100 row that matches nothing in the target catalogue
   used to be a dead end — reported as `:unmatched` and dropped. It can now
   become a new item, behind an operator checkbox on the preview screen.
2. **Code + name matching.** The file identifies a row by a numeric code that is
   our SKU reduced to digits (`Pro100.Id.digits_only/1`). That reduction is
   lossy: `73.U767.18` and `73.U767.PM.18` both become `7376718`. On a real
   export, 28 codes were shared by 62 rows, none of which could ever be updated.
3. **The estimate-template layer.** A parser + plan + loader for PRO100's
   `configTables` export (the price template used to quote a project), which is
   XML despite its extension.

## What changed

| Area | Change |
|---|---|
| `Import.Matcher` | Index is now `%{digits: …, digits_name: …}`; `resolve/3` tries `{digits, name}` first and falls back to digits alone when unique. Public `normalize_name/1` is the single normalisation used on both sides. |
| `Import.Pro100Plan` | `build/3` takes the target catalogue's name. Rows are classified into `:updates` / `:creates` / `:skipped`; skip reasons grew `:no_id`, `:no_name`, `:foreign_group`. `to_executor_plan/1` converts creates into the shape `Executor.execute/4` wants. |
| `Import.Source.Pro100` | `analyze/4` — the catalogue name is threaded through for the group check. |
| `Import.Executor` | `notify_pid` may be `nil`; progress and result messages are then skipped. |
| `Web.ImportLive` | `create_unmatched` assign + `toggle_create_unmatched` event; the preview screen lists the rows offered for creation; `apply_pro100` runs the creates through `Executor.execute/4` with `notify_pid: nil`. |
| `Import.Pro100TemplateParser` | Saxy-based reader for `ArrayOfTable → Table → Items/TableItem`. |
| `Import.Pro100TemplatePlan` | Turns parsed tables into folder / catalogues / categories / items / smart rules. Pure. |
| `Import.Pro100TemplateLoader` | Applies that plan, idempotently, with `dry_run: true` by default. |
| `mix.exs` | New direct dep `{:saxy, "~> 1.6"}` — xmerl rejects the export (no encoding declaration + Estonian and Cyrillic text). |

## Group prefix

PRO100 prefixes an item name with its group: `Acme Carcass / MP U741 ST9 16mm`.
The separator must be whitespace-padded, because article codes contain bare
slashes (`MP U767 PM/ST9 18mm`).

A row whose group is not the selected catalogue's name is refused
(`:foreign_group`) — a single export can span several groups while the sync
targets one catalogue. That guard runs **before** `Matcher.resolve/3`, so a
foreign row can never quietly update a local item whose lossy code happens to
collide.

## Review outcome

Five findings; see [CLAUDE_REVIEW.md](CLAUDE_REVIEW.md). Three were fixed
post-merge, including one that made the force-create feature unreachable for
every prefixed row and one that broke `mix precommit`.

## Related PRs

- Previous: [#49](/dev_docs/pull_requests/2026/49-url-state-search)
- Companion: [#51](/dev_docs/pull_requests/2026/51-core-version-floor)
- Earlier PRO100 work: [#40](/dev_docs/pull_requests/2026/40-catalogue-table-stack-pro100-import)
