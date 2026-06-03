# Follow-up: PR #31 — Harden PDF library

Triaged 2026-06-03 (quality-sweep Phase 1). Source review: `CLAUDE_REVIEW.md`.

## Fixed (pre-existing)

All six substantive review findings were already implemented in current code before this triage:

- ~~MEDIUM: `bulk_requeue` count honesty (skipped/requeued/failed conflated)~~ — `pdf_library.ex:1376–1416` splits skipped vs enqueued; `do_bulk_enqueue/1` only counts `requeued` on `Oban.insert_all` success; `pdf_library_live.ex:154–196` flashes all four outcome combinations incl. "already running".
- ~~MEDIUM: requeue loop not batched (per-row inserts / live-job query)~~ — `live_extraction_job_file_uuids/1` (`:1426`) is a single query; `do_bulk_enqueue/1` uses one `Oban.insert_all`; queue availability checked once.
- ~~LOW: no index backs `extraction_job_pending?/1`~~ — documented PERF NOTE at `pdf_library.ex:1340–1349` + `AGENTS.md:233` with the exact partial-index SQL; intentionally deferred to a core migration until the jobs table grows.
- ~~LOW: `retry_extraction/2` unguarded against success-terminal rows~~ — guard at `:501–503` (`status in ["extracted","scanned_no_text"] and not force` → `{:error, :already_extracted}`); covered by tests.
- ~~LOW: DB queries in `mount/3`~~ — `PdfLibraryLive` moved the query to `handle_params/3` (connected-gated); `PdfDetailLive` keeps it in mount by design (commented: `:live_redirect` not-found semantics).
- ~~LOW: `extraction_badge/1` hand-built HTML~~ — now a HEEx function component (`pdf_library_live.ex:550–563`), auto-escaping for free.

## Fixed (Batch 1 — 2026-06-03)

- ~~NITPICK: redundant `import Ecto.Query, warn: false`~~ — `Ecto.Query` is used throughout the context, so the `warn: false` suppression was unnecessary; dropped to plain `import Ecto.Query` (`pdf_library.ex:41`). Compiles clean with no unused-import warning.

## Skipped (with rationale)

None.

## Files touched

| File | Change |
|------|--------|
| `lib/phoenix_kit_catalogue/catalogue/pdf_library.ex` | Drop redundant `, warn: false` from `import Ecto.Query` |

## Verification

`mix deps.compile phoenix_kit_catalogue --force` (via `phoenix_kit_parent`) — clean, no warnings.

## Open

None.
