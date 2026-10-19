# PR #150 — follow-up

Triage of `CLAUDE_REVIEW.md` (Claude). No bugs; one IMPROVEMENT and one
NITPICK, re-verified against current code.

## Fixed (pre-existing)

None.

## Skipped (with rationale)

- NITPICK — the module reads core's `FileInstance` table directly
  (`lib/phoenix_kit_catalogue/attachments.ex:306-312`,
  `thumbnail_versions/1`). The finding is conditional: it should be replaced
  by a core batch reader once one exists. Core's storage context still has only
  per-file readers (`list_file_instances/1`, `get_file_instance_by_name/2`), so
  the precondition is not met. Trigger: core ships a batch instance reader;
  switch `thumbnail_versions/1` to it then.

## Files touched

None — triage only.

## Verification

Findings re-verified against current `main` at commit `899fa9c`.

## Open

Awaiting the maintainer's decision (fix, skip, or punt):

- IMPROVEMENT - MEDIUM — a rotated or annotated image keeps its old thumbnail
  in an already-open form until reload: only
  `{:phoenix_kit_file_processed, uuid}` is handled, core's `thumbnail_updated`
  falls through to the catch-all
  (`lib/phoenix_kit_catalogue/attachments.ex:259-263`,
  `handle_file_event/2`). Suggested fix: add a `handle_file_event/2` clause for
  core's thumbnail-updated message that calls the same
  `refresh_thumb_version/2`, and update the comment at `:256-258`.
