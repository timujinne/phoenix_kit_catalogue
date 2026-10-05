# PR #126 — ProductCard delegates its render to core PreviewCard — follow-up

Triage of `CLAUDE_REVIEW.md` (5 findings) against `main` at `e8a969f` (0.46.1).

## Fixed (pre-existing)

- ~~BUG CRITICAL — `mix.lock` predated the core release that ships `PreviewCard`, so the merged tree did not compile: the lock is at phoenix_kit 2.41.2 (`mix.lock:69`) — first moved in commit `89b348a`.~~
- ~~BUG HIGH — `product_card_body/1` forwarded a `:target` attr core's body does not declare: the delegation passes only `title`/`images`/`fields`/`files` (`lib/phoenix_kit_catalogue/web/components/product_card.ex:145-153`); the attr stays declared and optional (`:130`). Pinned by `test/web/product_card_test.exs:248` and `:259` — commit `89b348a`.~~
- ~~BUG MEDIUM — the nameless-item title changed from "Item" to core's "Preview": `card_title/1` restores the catalogue's own "Item" for `nil` and `""` (`product_card.ex:159-161`), used by both `product_card/1` (`:113`) and `product_card_body/1` (`:148`). Pinned by `test/web/product_card_test.exs:273` — commit `89b348a`.~~
- ~~IMPROVEMENT MEDIUM — the `:phoenix_kit` floor (`>= 2.13.11`) no longer described what the code needs (2.30.0 for `PreviewCard`): the floor is `>= 2.38.0 and < 3.0.0` (`mix.exs:132`), and `test/core_pin_conformance_test.exs:41-42` admits 2.38.0 and rejects 2.13.11 / 2.34.0 / 2.37.5 — raised to 2.34.0 in `f774359`, to 2.38.0 in `45e7d6e`.~~

## Skipped (with rationale)

None.

## Files touched

None — triage only, no code changed.

## Verification

Each finding re-read against `main` at `e8a969f` on 2026-10-05 (grep + reading the cited lines; `git log -S` for the commits). `mix precommit` and `mix test` were not run in this pass — nothing was changed.

## Open

Awaiting Max's decision:

- **NITPICK — three msgids in the hand-maintained catalogue have no caller left in `lib/`.** `"Previous"`, `"Next"` and `"Show image %{number}"` are still in `priv/gettext/default.pot:1171`, `:1174`, `:1177` and every locale, and still pinned with their `et`/`ru` strings in `test/gettext_test.exs:580`, `:586`, `:728`; a grep of `lib/` finds no call site (core's backend renders them now). The review left them on purpose (the `.pot` is hand-maintained). Fixing means hand-deleting the three entries from the `.pot` and the five `.po` files and dropping the three pins from the test.
