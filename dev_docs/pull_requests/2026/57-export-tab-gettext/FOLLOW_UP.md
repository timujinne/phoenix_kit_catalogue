# PR 57 follow-up — Export tab strings, and the gettext hazard

Triaged 2026-08-29 as part of the four-repo quality sweep. Every finding in
the review was re-verified against current code.

## Fixed (pre-existing)

- ~~The PR's own change: six msgids added across all four catalogues.~~ All
  four files carry them; `Export Items` and `Destination` are present in `et`.
- ~~`version/0` reported the wrong version.~~ `0.20.0` in both places, pinned
  by `test/phoenix_kit_catalogue_test.exs:214`.

## Fixed (Batch 1 — 2026-08-29, commit `65231b3`)

- ~~**The headline finding: "`gettext.extract`/`merge` would delete ~329
  translations", documented in `AGENTS.md` as a standing prohibition and left
  unfixed because the reviewer had no database to verify a conversion
  with.**~~ **Measured rather than assumed, and it is no longer true.**

  Against gettext 1.0.2 on the whole tree, extraction reproduced **959 of the
  960** committed msgids. Today's gettext extracts the runtime
  `Gettext.gettext(Backend, "…")` form too, which is how ~1100 of the call
  sites here are written — so the catastrophe the warning described does not
  happen, and the 891-call-site conversion it proposed as "the real fix" is
  not needed.

  The residual gap is **two msgids, not several hundred**: the runtime form is
  not extracted from inside a HEEx attribute interpolation
  (`title={Gettext.gettext(…)}`), which is exactly how `"Comfortable view"`
  and `"Compact view"` came to be in the catalogues but absent from a
  regenerated `.pot`. Both are now written as the macro, with
  `web/components.ex` carrying `use Gettext, backend:
  PhoenixKitCatalogue.Gettext`.

  With that closed, `extract` + `merge` ran clean: **0 removed, 0 fuzzy, 0
  obsolete, 0 translations lost** in `en`/`et`/`ru`.

- ~~The cost of the prohibition.~~ Treating the catalogues as hand-maintained
  is why `"Showing catalogues that contain matching items."` — added to
  `catalogues_live.ex` on 2026-08-28 — reached no catalogue at all and
  rendered English in Estonian and Russian. Extracted, translated and pinned.

- ~~`AGENTS.md` still told contributors never to run the commands.~~ Rewritten
  with the measured numbers, the one real caveat (attribute interpolation),
  and the correct workflow — including that a merge can guess a translation by
  similarity and mark it `fuzzy`, which gettext then **ignores at runtime**,
  so every fuzzy entry needs review.

## Files touched

| File | Change |
|---|---|
| `lib/phoenix_kit_catalogue/web/components.ex` | `use Gettext` + 4 attribute sites to the macro form |
| `priv/gettext/*` | regenerated; 1 new msgid, translated in `et`/`ru` |
| `AGENTS.md` | gettext guidance corrected |
| `test/gettext_test.exs` | runtime locale test pinning the three affected strings |

## Open

None.

## Verification

| Step | Result |
|---|---|
| `mix test` | 2 doctests, 2049 tests, 0 failures |
| `mix precommit` | passes |
