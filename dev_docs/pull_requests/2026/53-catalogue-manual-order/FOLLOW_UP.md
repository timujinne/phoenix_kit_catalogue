# PR 53 follow-up — Manual ordering for catalogues

Triaged 2026-08-29 as part of the four-repo quality sweep. Every finding in
the review was re-verified against current code.

## Fixed (pre-existing)

- ~~**BUG - HIGH:** the reorder guard was render-side only — the handler
  itself accepted a reorder in any sort mode.~~ Fixed on main and since
  strengthened: `web/catalogues_live.ex:1874-1891` re-checks
  `manual_order_draggable?/2` **and** that the folder tree is empty, logs
  `:not_in_manual_order`, flashes, and reloads.
- ~~**BUG - MEDIUM (not from this PR):** `priv/` was never shipped to Hex, so
  consumers got the package without its static assets.~~ `mix.exs:159`
  declares `files: ~w(lib priv guides …)`.
- ~~The "keep `sort_by` when it is still sortable" behaviour.~~ Moved rather
  than lost: it now lives in `live_update_columns/2`
  (`web/catalogues_live.ex:293-296`), and `"position"` is
  `sortable?: true, managed?: false` in the config
  (`web/table_config.ex:155,176`).

## Open

None.

## Verification

| Step | Result |
|---|---|
| `mix test` | 2 doctests, 2049 tests, 0 failures |
| `mix precommit` | passes |
