# Item selector modal + embeddable browse components

2026-08-22. Two deliverables in one architecture: a client-facing "pick
items with quantities" modal (the catalogue's `MediaSelectorModal`
analogue), and the embeddable components it is assembled from, exposed so
hosts can compose their own catalogue surfaces. First integrator: a consuming host app
(host app). Designed via a 3-model brainstorm + adversarial plan review;
the decisions below record what was chosen and why.

## Architecture

One stack, three layers, so the picker and any embedded browse can never
drift apart:

| Layer | Module | Role |
|---|---|---|
| State | `Catalogue.BrowseState` | Pure reducer: scope, search, category, offset paging, generation counter. No process, no queries — callers run the fetch it requests and hand results to `ingest/4`. |
| Looks | `Web.Components.Browse` | Pure function components: `item_card`, `item_grid`, `category_chips`, `qty_stepper`, `grid_skeleton`, plus `present_items/2` (translation + signed photo URL, resolved once per fetch). All take `target` so they work inside any LiveComponent. |
| Surfaces | `ItemSelectorModal`, `CatalogueBrowse` | LiveComponents: modal picker (selection map, tray, confirm) and plain browse (no selection). Both are thin glue over the two layers above. |

Nested LiveComponents were rejected: `send(self(), …)` from a nested LC
lands in the root LiveView, so a picker wrapping a browse-LC could never
intercept its events without host forwarding — which kills the drop-in
contract.

## Decisions that will be asked about later

- **Scope is a security boundary.** Fixed at `init`, every fetch re-derives
  from it, category commands are rejected outside `scope.category_uuids`,
  and selection accepts only uuids the component itself rendered (or
  hydrated preselects). Pinned by adversarial tests that were verified to
  FAIL when either clamp is removed.
- **Quantities are Decimal end to end.** Integer default (`precision: 0`);
  a positive precision makes the same stepper decimal-capable ("2.5 L" of
  paint — `Item.default_value`/`unit` already exist for this). Commit on
  blur/Enter only; decimal comma accepted; min/max/precision re-clamped
  server-side because qty is client input too. An invalid commit bumps a
  per-row revision that recreates the input — re-assigning an unchanged
  value would leave the typed garbage in the DOM (morphdom sees no diff).
- **Preselects are hydrated ignoring scope** (the tray must render what
  the host handed in) but out-of-scope rows are excluded from confirm —
  shown, flagged, never silently dropped, never emitted.
- **Button-first paging.** "Load more" works everywhere; an
  IntersectionObserver enhancement can come later (colocated-hook
  precedent exists in `ItemPicker`). Offset paging over a live catalogue
  can re-serve rows, so `ingest` de-dups by uuid.
- **Category chips only render when the scope names exactly one
  catalogue**; chips have no counts (a counts facet engine is a
  fast-follow). "All" clears to the scope restriction, not to everything.
- **Photos**: featured image only, `medium` variant, URL computed in
  `present_items/2`. `URLSigner.signed_url/2` is pure HMAC — no Storage
  roundtrip — so the feared N+1 does not exist for signing.
- **Modal**: core `<.modal>`; PkDialog routes `data-close-event` back to
  the LC via `pushEventTo(this.el, …)`, so ESC/backdrop reach the
  component. Host mounts with `:if={@show}` — unmount-on-close is the
  reopen-reset semantic, and avoids keep_in_dom show-state desync.
- **No nested ProductCard in v1** (`detail_view` deferred): stacking a
  second `<dialog>` over the picker risks focus/scroll-lock fights; a
  slide-over inside the same dialog is the likely fast-follow shape.

## Deferred (recorded so they aren't re-litigated)

Paste-a-list bulk add (two models independently proposed it — parse
"40x M8 screw" lines into prefilled picks; the strongest future idea);
category counts; ProductCard detail view from cards; an
IntersectionObserver sentinel; a shared fetch-executor once a third
surface exists; url_sync for `CatalogueBrowse`; an ItemPicker "browse…"
affordance opening the selector.

## Test map

`browse_state_test` (pure reducer incl. the {command, scope-shape}
product), `browse_components_test` (render contracts),
`item_selector_modal_test` + `catalogue_browse_test` (full LC loop through
`Test.SelectorHostLive`, asserting the process-message contract a real
host consumes, plus the adversarial cases). Security clamps and qty
clamps were sabotaged to confirm the tests actually bite.
