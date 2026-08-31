# Quality sweep — phoenix_kit_catalogue (2026-08-31)

Playbook: `~/Desktop/Elixir/dev_docs/quality_sweep.md`. Re-validation
shape: the full C0–C16 sweep ran 2026-08-29; this pass covers the
selector/browse rework landed since (`53155f2..`), plus Phase 1 catch-up
for the four PR folders the 0.22.0 release created.

## Phase 1

`FOLLOW_UP.md` written for #84, #85, #86, #87 — all findings were fixed
in the release commits themselves (verified against current `main`); the
three reviewer-deferred items (JSONB fragment dedup, `filter_options/2`
N+1, facet-counts-twice) are transcribed with their trigger conditions,
not re-decided.

## Phase 2 — four triage agents (C12 prompts verbatim) + delta audit

Every finding below was verified before being acted on.

### Fixed

**Correctness / contract**

- **A double-clicked Confirm delivered `{:items_selected, …}` twice** —
  the second queued event ran before the host unmounted the modal, and
  the selection wasn't cleared. A `confirmed` latch now makes confirm
  (and immediate-mode notify) once-only; pinned by a message-count test
  through the host harness.
- **`mode: :single` + `immediate` confirmed off the DEBOUNCED live
  value** — a slow typist's "15" closed the modal at qty 1. The live
  `qty_change` path no longer notifies; the authoritative `qty_commit`
  (blur/Enter) carries the self-gating notify instead.
- **The detail page honoured the display flags but not the columns
  GRANT** — a client-safe `columns: [:thumb, :name, :qty]` embed leaked
  price and SKU one thumbnail-click away, against the module's own
  "must not reappear" comment. `build_fields` opts now AND the flag with
  the grant.
- **The table view ignored a mid-open `show_prices`/`show_sku`
  revocation** the cards and detail page honoured — `effective_columns/1`
  filters the visible set by the live flags, matching the card gating.
- **A stale detail could survive a failed grant-change rebuild** (item
  deleted meanwhile) with fields materialized under the OLD grants —
  the rebuild path now closes the detail on a miss.
- **Garbage preselect keys crashed the host LV at mount**
  (`Ecto.Query.CastError` from a non-UUID key) and raw 16-byte keys
  silently vanished from the tray — keys now normalize through
  `Ecto.UUID.cast/1`; garbage drops like any unresolvable uuid, with a
  test.
- **`to_decimal/1` had no fallback clause** — an atom/nil quantity in
  `selected`/`qty_min` was a bare `FunctionClauseError` where every
  sibling host-contract violation raises a described `ArgumentError`.

**Hardening**

- **`featured_image_uuid` reached a URL path shape-unchecked** — free
  JSONB, so `../../etc/passwd` became a same-origin GET path for every
  viewer. Both signed-URL builders now require the CANONICAL uuid form
  (equality with `Ecto.UUID.cast/1`'s result — cast alone accepts any
  16-byte binary, which is exactly what the traversal string is).
  Pinned by a test.
- **`resolve_columns!/2` accepted duplicate entries** while raising on
  unknown ones — duplicates now raise too.

**Drift between the two surfaces**

- **CatalogueBrowse rendered the category twice per row** (`:breadcrumb`
  prefix + `:category` column) and showed SKU the modal hides — the
  widget default now subtracts the modal's default-hidden pair.

**i18n**

- **The built-in supplier field's "Unit cost" label was never
  translated** — a compile-time map rendered raw. `builtin_fields/0`
  now translates at call time; msgid hand-added to `.pot` + en/et/ru
  and pinned (incl. the call-time resolution itself).
- **"Back" (details page) was in every catalogue but had no pin** —
  its two sibling msgids from the same feature did. Pinned.

**Cleanliness / cost**

- `cell_event/2` ran four times per cell (≈960 calls/render) — one
  evaluation per cell, sites in sync by construction.
- Row-invariant helpers (`qty_input_min/max`, `checkbox?`,
  `effective_columns`) computed once per render instead of per row ×
  call site.
- Vestigial `item.uuid &&` in the card stepper's unit expression.
- `@spec` on all 11 non-component public functions in `Browse`.
- The one unexplained broad rescue (`ProductCard.format_price/1`) now
  carries its chrome-not-data justification.

**Docs**

- `Browse`'s documented presented-item shape was missing `thumb_url`,
  `category`, `base_price` — keys `item_row`'s default columns read; a
  host hand-building maps to the doc's shape got a `KeyError`.
- "Event names are fixed" overstated — `view_toggle`/`column_toggle`
  take an `event` attr, the details events are host-named, and the
  search box / load-more are hand-rolled markup, all now stated.
- `hidden_columns` was a live host attr documented only in a private
  comment; now in the moduledoc with its grant-vs-visibility semantics.
- The `checkbox` attr doc claimed the cell is always click-bound; it is
  inert with `clickable: false`, and the table/row lockstep requirement
  is stated.
- The `Browse.item_table`/`view_toggle` name collision with
  `Web.Components`' same-named admin components is now flagged where
  hosts are told to import both.
- `qty_stepper`'s revision-bump garbage-reset pattern is now explained
  in its doc (a stable id leaves typed garbage stuck).
- `AGENTS.md` still called `show_item_details` "opt-in" after the
  default flipped.

**Test coverage (delta audit + agent findings)**

- `load_more` had ZERO LiveComponent coverage — the presented-gate
  accretion (page-2 rows selectable) is the load-bearing new test.
- `remove_pick` — the tray's only removal control — was never clicked.
- The widget's decorative default (`on_item_click: false` sends
  nothing) and its rendered-uuid gate were untested.
- Direct render contracts for `item_table`/`item_row` (qty cell never
  click-bound, thumb_click placement, checkbox lockstep), the
  photo_click split on cards, the shared resolvers' raises, the
  build_fields grants, the Unit-label markup, and core-side pins for
  the label harmonisation (FormFieldLabel + translatable_field).

### Recorded, not fixed (pre-existing or deliberate)

- **`SupplierFields` read-modify-write race** on `fields_definition`
  (two admins adding fields concurrently can drop one definition; the
  fresh re-read narrows but does not close the window). Pre-existing
  from the 2026-08-21 arc; joins the standing races entry in the
  2026-08-29 sweep's Open list.
- **Sync fetch keeps the skeletons/spinner unreachable** — the
  documented design; `BrowseState`'s generation counter is the
  pre-wiring for the deferred async migration (2026-08-22 deferred
  list). The per-keystroke two-query cost rides the same item.
- **Keyboard access to `phx-click` table cells** (select + details in
  table view) — pre-existing pattern from 0.20; cards keep a real
  button path. A11y follow-up alongside title-only accessible names on
  the toggle buttons.
- **The live-subtree scope semantic** (`include_descendants` stays true
  at query time after init expansion) — deliberate since 2026-08-25;
  flipping it breaks chip narrowing. A tree mutation between mount and
  query can widen beyond the init snapshot — rework-territory note.
- **Forged process messages** (`{:items_selected, …}`) are inherent to
  the LiveComponent pattern; the moduledoc's re-read-and-re-price
  advice is the mitigation.
- **`show_item_details` default-on** is Max's 2026-08-31 decision;
  called out in the PR body since it changes exposure for existing
  embeds that granted restrictive columns.
- `detail_unit/1`'s precision>0 branches, the msgids only pinned (not
  DOM-rendered) in tests, and the four `supplier_field.*` activity
  actions without per-action pins — coverage debt, listed for the next
  pass.

## Gates

- `mix precommit` clean (compile --warnings-as-errors, format, credo
  --strict, dialyzer).
- Full suite with live Postgres green; 10 consecutive runs stable.
- C14 stale-ref greps + ast-grep patterns: zero unexplained matches.
- Browser verification against the box (max-dev) was done feature-by-
  feature during the 2026-08-30/31 arc, including the deploy of every
  fix above.
