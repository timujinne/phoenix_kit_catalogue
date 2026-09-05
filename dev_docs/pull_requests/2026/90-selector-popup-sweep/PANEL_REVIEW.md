# PR #90: Selector popup sweep — panel + quality-sweep review

**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/90

**Author**: @mdon
**Reviewers**: 4-seat AI panel (codex/gpt-5.6, agy/Gemini, zai/GLM-5.3, grok — risk-sliced briefs) + 4 triage agents per `dev_docs`' quality-sweep playbook, all findings verified against code before acting
**Status**: reviewed pre-push; fixes are part of the PR
**Date**: 2026-08-31

## How the review ran

The diff (11 commits vs 0.24.0) was sliced by risk: codex took
BrowseState + the modal's state machine and scope security; zai took
Browse/ProductCard rendering, fees and hooks; agy took the core
PkDialog/InfiniteScroll JS (inline); grok took the UX design model
(no-tools brief). Four Explore triage agents covered the playbook
dimensions (security/async UX, translations/coverage, cleanliness/API,
host-integration boundaries). Roughly a third of the findings did not
survive verification — consistent with earlier sweeps.

## Fixed in this PR (finder in parentheses)

- **The auto-load sentinel routed `load_more` to the HOST LiveView on
  every published core** — core's InfiniteScroll pushes with no
  component target; the CID-aware routing exists only in unreleased
  core. A host without a `load_more` clause crashed and remounted,
  dropping the popup and every pick. Replaced with a colocated
  `.AutoLoad` hook pushing through the sentinel's own `phx-target` —
  correct on every core. (security + host-boundary agents,
  independently)
- **Both client-side list-identity keys omitted the catalogue drill** —
  `.ScrollTop`'s key and the sentinel cursor were written before
  `catalogue_uuid` existed, so drilling catalogues landed mid-list and
  could wedge auto-load on equal page lengths. (cleanliness, security,
  host-boundary agents)
- **`set_catalogue` accepted on singleton scopes**, contradicting its
  own documented "only when several" contract and rendering a bogus
  tile-less level. Refused now; unit pins added — the command
  previously had zero unit tests. (codex #7, coverage agent)
- **A whitespace-only query flipped `:direct` drill to subtree
  listing** while hiding the level nav — the fetch layer trims it to no
  filter, so the reducer and the nav gates now treat it as no search
  too. (codex #8)
- **A crafted `browse_category` naming another catalogue's category**
  while drilled created a contradictory dead-end level; the component
  now refuses the cross-catalogue mismatch (BrowseState can't — its
  allow-list is category-global). Crafted-only: tiles and search hits
  are both narrowed to the drilled catalogue. (codex #4)
- **The translated-name chains were unguarded against blank
  overrides** — `translated["_name"] || …` lets a stored `""` win
  (truthy), blanking list names. All six ad-hoc copies now route
  through presence-guarded `Translations.translated_name/2` /
  `translated_description/2`. (zai #6, coverage agent)
- **ItemPicker's locale fallback skipped explicit `locale={nil}`** —
  `Map.put_new_lazy` fires only on an absent key, and `locale={@locale}`
  with a nil assign is the common host shape. Now `||`. (host-boundary
  agent)
- **QtySignal could stick a wrong highlight** — flipping on `> 0` alone
  meant a server-rejected value (below qty_min) highlighted the row,
  and the rejection produces no diff to undo it; the rejected-commit
  revision bump recreates the input but never the holder. The hook now
  mirrors the accept set (`select_floor` / `zero_deselects` attrs) and
  leaves indeterminate values alone. (zai #1, security agent)
- **Flat-fee price diverged between the list and the detail card**
  ("49.51" vs "49.505") — `fee_value/1` now formats through
  `Browse.format_price/1` like the listing. Pinned with DB-scale
  decimals ("12.0000"), which the existing test never fed. (zai #2,
  coverage agent)
- **`fee_note` reached neither the documented presented-map shape nor
  the confirm payload** — a host following the docs silently lost the
  smart-fee display, and a percent-fee pick arrived indistinguishable
  from a free item. Both documented; the payload now carries
  `fee_note`. (host-boundary + cleanliness agents, zai #7)
- **The colocated-hook host import was documented nowhere a Hex
  consumer can see** (only AGENTS.md, excluded from the package). The
  README installation section now covers the `phoenix-colocated`
  import, the NODE_PATH note, and the failure signature. (host-boundary
  agent)
- **The multi-catalogue tree's blanket rescue was silent** — a DB
  hiccup degraded to "no categories", indistinguishable from the
  tim-dev report that motivated the feature. Now logged; the two tree
  clauses also share one `category_tree_base/4` instead of ~20
  duplicated lines. (security + cleanliness agents)
- **PkDialog (core)**: the stacked-cancel relay could double-push the
  child's close event when the child's own `close` echo does fire, and
  the child lookup missed a morphdom-stripped `open` attribute. Parent
  now flags the child to suppress the echo; lookup matches `:modal`.
  (agy #1, #2 — core commit)
- Polish: `smart_fee/1` doc narrowed (rule-priced items with no fee
  fields are indistinguishable from plain price-less at presentation
  time), competing tooltips on the title button, `@search_hit_cap`
  named, `confirmable_selection?` deduped, stale grouped-roots comment,
  QtySignal `destroyed()` guard, `inline_qty × quantity` and
  cancel-contract pins. (cleanliness + coverage agents, zai #8)

## Verified not defects

- codex #1–#3 (stale render/confirm authorization, "presented ≠
  rendered"): TOCTOU within a session on data the viewer already saw;
  the picker is a UI, the host owns the transaction boundary — its
  moduledoc already says re-read and re-price server-side. No scope
  leak in any of the three.
- codex #6: negative qty → deselect is the documented ≤0 contract.
- agy #5/#6 (morphdom re-showModal, sentinel wedge): both already
  handled (`_sync`'s attr restore; the watchdog + manual button).
- zai's debounce/blur and comma-decimal hypotheses: disproved by zai
  itself in verification.
- grok #2 (hiding qty flips the grammar): `:qty` is locked and forced
  visible in quantity mode.
- grok #5 (single-catalogue tile tax): singleton scopes skip the
  catalogue level by construction.

## Deferred (design/scale, for Max or a later pass)

- **Tile counts ignore `:statuses`/`:only`/category scope** — a scoped
  embed's tiles advertise more than drilling yields (count-only, no
  item leak; same behaviour the released single-catalogue tree ships).
  Honouring scope means per-catalogue scoped counts — a query-shape
  change. (security agent #6)
- **Table view is keyboard-inoperable / ARIA gaps** — bare `<td
  phx-click>` cells, `aria-selected` on plain rows, `aria-label`
  swallowing price/SKU on card buttons. Wants a deliberate a11y pass
  across both browse surfaces, not a drive-by. (zai #3/#5)
- **`resolve_images/files` silently cap at 50** (pre-existing detail
  work). (zai #4)
- **Qty-first has no selection review before Confirm** (count only) and
  **category hits clear the search** — design questions from grok's
  panel seat; both match current deliberate rulings.
- The dead-but-async-ready `loading?` skeleton branches stay — they are
  the surface BrowseState's async design lights up.
- `only: :uncategorized_only` + multi-catalogue scope skips catalogue
  tiles (no categories exist to browse; flat loose-item list is
  coherent). (codex #5)

## Gate

Full suite: 2 doctests, 2194 tests, 0 failures (PGUSER=maxdon).
`mix precommit` clean. Core JS: `node --check` clean (JS-only bundle
edits, no version bump — the boss releases).
