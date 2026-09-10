# Follow-up Items for PR #9

Triaged against `main` on 2026-04-26. CLAUDE_REVIEW finding numbering
preserved (1–9 in the "Issues" section). The reviewer themselves
addressed correctness items #1 and #2 with two follow-up commits on
the branch before merge.

## Fixed (in-PR — already noted in the review)

- ~~**#1** `load_next_search_batch` synchronous~~ — reviewer's local
  fix moved both `catalogue_detail_live.ex` and `catalogues_live.ex`
  scroll-page paths onto `start_async(:search_page, …)` with a
  `(query, offset)` guard. Verified at
  `catalogue_detail_live.ex:761` (page result handler) and
  `catalogues_live.ex:537`.
- ~~**#2** Executor phase 1 not transactional~~ — reviewer's local fix
  wrapped the three get-or-create loops in a single `Repo.transaction`.
  Verified at `lib/phoenix_kit_catalogue/import/executor.ex` (current
  `execute/4`).

## Skipped (with rationale)

All remaining items are perf or polish observations the reviewer
explicitly classified as "suggestions, not blockers" and offered to
file as followups. Per the
[quality-sweep memory]the agent memory note `feedback_quality_sweep_scope.md`:
"refactor existing paths; don't add missing features even if PR
reviews flagged them. Classify each finding explicitly."

- **#3** `Mapper.detect_existing_duplicates/3` O(N × M) — perf concern
  for 20k-item catalogues with 5k-row imports. Today's volume is well
  below this threshold. The hashed-lookup-map refactor is a clean win
  but introduces hashing-key shape complexity. Tracked, not fixed.
- **#4** Search against `i.data::text` (no GIN) — same family as PR #7
  2.3 / PR #11 #6. Requires a core phoenix_kit migration for the
  `pg_trgm` index. Out of scope for the catalogue module sweep.
- **#5** `Parser.reject_empty_columns` O(rows × cols × col_idx) — perf
  for 100k+ row imports. Out-of-band of typical catalogue imports
  (XLSX is normally ≤10k rows). Not corrupting.
- **#6** `file_binary` retained in socket assigns — memory concern for
  30MB XLSX uploads. The current LV pattern is conservative on memory
  vs. simpler-state. Refactoring to keep the temp file path is
  reasonable but not driven by an observed incident.
- **#7** Search query body duplication — pure cleanup. The duplication
  lives across six functions in `catalogue/search.ex`. Phase 2 C6
  considered consolidating; declined because the WHERE clauses differ
  in subtle scope (catalogue vs category vs unscoped) and pulling
  them into a single composer harms readability for negligible
  reduction.
- **#8** `Parser.detect_csv_separator` quoted-fields edge — low-
  priority CSV corner case. The XLSX path (which most users take) is
  unaffected.
- **#9** `validate_item_attrs` first-error-only — minor UX. Reporting
  all errors per row would change the import-result UI shape and
  isn't a sweep concern.

## Files touched

None in this Phase 1 batch.

## Verification

- Reviewer's two follow-up commits verified in current code (search
  is async-paginated; Executor phase 1 is in a transaction).

## Open

None.
