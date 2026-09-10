# PR #104: Per-field translation fingerprints and write narrowing — Claude review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/104
**Author**: @timujinne
**Reviewer**: Claude (Sonnet 5) — post-merge pass
**Date**: 2026-09-10
**Status**: reviewed; no issues found

## Scope

Moves AI-translation freshness fingerprints from one sha256 per
(resource, language) to one per (resource, language, field), so
`put_translation/4` can decide field by field whether the AI's answer needs
to land: a field whose source hasn't changed since the last translation is
left untouched even when the same job also rewrites a sibling field whose
source did change. Previously every re-translate overwrote the whole
resource, clobbering a hand-corrected field regardless of whether its
source had moved.

Adds field-narrowed `stamp_fresh/3` and `reset_baseline/3` ("force this
field to be treated as stale again"); `state/2` stays resource-level
(worst-of-its-fields fold) for existing callers, `field_state/3` answers
per field. A legacy single-hash fingerprint (pre-per-field rollout) reads
as `:unknown` per field rather than `:stale`, deliberately avoiding an
unauthorized re-translation storm across every already-translated
resource on deploy.

## Review notes (no fix needed)

- Traced the two "current source fields" call paths that the write-narrowing
  logic depends on staying in lockstep: `merge_tracked_translation!/6`'s
  `writable_fields/3` computes eligibility via `TranslationStatus.field_state/3`
  (which reads `current_source_fields/1` → `AITranslatable.source_fields_pure/2`),
  and `put_field_fingerprints/4`'s `current_hashes` computes the actual
  stored hash via the *same* `source_fields_pure/2` call. Since
  `writable_fields/3` only lets through fields with a non-nil `field_state/3`
  (i.e., present in `current_source_fields/1`), the `Map.fetch!(current_hashes, field)`
  in `put_field_fingerprints/4` can't raise a `KeyError` — both reads are
  against the identical `fresh` struct within the same transaction. Confirmed
  `TranslationStatus.current_source_fields/1`'s doc explicitly calls out why
  it uses the *pure* variant (not the capturing `source_fields/2` an AI
  engine calls) to avoid corrupting an in-flight job's captured fingerprint.
- The "success without a write" path (`finish_write({:ok, {:skipped, fresh}})`)
  correctly skips both the DB write and the catalogue broadcast — verified
  against the "no broadcast, no version bump" test — and, since it never
  calls `update_fn`, also correctly skips activity logging for that call,
  consistent with "every mutating context function logs only on a real
  write."
- `Sets.decide_label/3` / `decide_title/3`'s `with {:ok, updated} <- merge_label(...), do: {:ok, {:written, updated}}` falls through an unmatched `{:error, reason}` from `merge_label`/`merge_title` unwrapped; traced this into `apply_locked_update/2`'s two-clause `case` (`{:ok, updated} -> updated` / `{:error, reason} -> repo().rollback(reason)`) and confirmed the bare `{:error, reason}` still matches correctly and rolls back — no error swallowed.
- The dialect/legacy-format edge cases are unusually well covered: legacy
  whole-resource string fingerprints reading as `:unknown` (not `:stale`)
  per field, a write over a legacy row replacing the string with a clean
  per-field map touching only the written field, and `stamp_fresh/2`
  upgrading a legacy row's storage shape. All exercised by tests, all
  behave as documented.
- No `mount/3` queries, no unscoped PubSub, no N+1 introduced — this PR is
  pure context/data-layer logic.

## Gate

`mix precommit` (format, credo --strict, dialyzer) clean. Full suite: 2535
tests, 0 failures.
