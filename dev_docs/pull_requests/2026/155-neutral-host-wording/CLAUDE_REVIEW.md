# PR #155 — Use neutral host-application wording in comments, docs and test data

- **Reviewer:** Claude
- **Date:** 2026-10-22
- **Author:** timujinne (merged by Dmitri Don)
- **Scope:** PRO100 importer comments, PRO100/duplicate/repro test fixtures,
  test comments, CHANGELOG, `dev_docs` plans and two review notes.

No behavioural change: every `lib/` hunk is a comment or moduledoc example, and
the test hunks swap fixture strings and keep their assertions. What was
checked:

- **Fixtures are consistent.** The renamed group names (`Acme Carcass`) appear
  in both the data and the assertion in each touched test (`foreign_group`,
  `meta["brand"]`), so none can pass against a stale string.
- **The CHANGELOG line** keeps the `#50` reference and the separator
  explanation; only the example group name changed.

## Findings

- IMPROVEMENT - MEDIUM — the sweep missed the host's deployment name. After the
  PR, `tim-dev` still appeared 20 times in `lib/` and `test/` comments and
  `describe` titles (`browse.ex`, `item_picker.ex`, `item_selector_modal.ex`,
  `pdf_engines.ex`, five tests), plus `Nordic Line` (a client's name) in
  `browse.ex`. `tim-dev` is the host the PR just rewrote ("the Andi/tim-dev
  shape"), so the goal of the PR was only half met. **Fixed**: replaced by
  "a host" wording in `lib/`, `test/`, `dev_docs/2026-08-16-pdf-extraction-engines.md`
  and the two review notes that named it; assertions untouched.
- NITPICK — `max-dev` (the maintainers' own dev box) and the attributions to
  "Max" / "boss via Max" in comments remain. They name the maintainers'
  environment and team, not the private host, so they are outside what the PR
  set out to remove. Not changed; say so if they should go too.
