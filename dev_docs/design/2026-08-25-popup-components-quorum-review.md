# 2026-08-25 — Quorum review of the popup components (ItemPicker / ItemSelectorModal / BrowseState)

Pre-rework hardening pass: the components are slated for a rework, so this
review's charter was "make the CURRENT version solid" — genuine defects only,
no redesign. Panel: codex (gpt-5.6, repo-anchored), zai (GLM-5.3,
repo-anchored), agy (Gemini 3.7 Flash, inline), grok (inline,
browse_state + modal halves only). kimi and m2 were down (quota/balance).
Every claim below was re-verified against source before acting — including
the bundled `phoenix_live_view.js` for the client-side ones.

## Fixed (all with tests)

1. **Enter in a browse search box ran a NATIVE form submit** — full page
   navigation, modal and picks destroyed. A `phx-change` form with no
   `phx-submit` takes LiveView's external-form path (`bindForms`: prevent,
   then `e.target.submit()`). Fixed in `ItemSelectorModal` AND the same
   pattern in `CatalogueBrowse`. (zai; verified in the LV client source.)
2. **Crafted `browse_category` with a non-UUID string crashed the host LV**
   — on an unrestricted scope the value reached `Tree.subtree_uuids_for/1`
   and raised `Ecto.Query.CastError`. `BrowseState.category_allowed?/2` now
   validates UUID shape on the unscoped path; host allow-lists are trusted
   as-is. (zai.)
3. **`only: :uncategorized_only` scope + any chip click raised ArgumentError**
   — contradictory opts by `search_items/2` contract. Chips are suppressed
   for that scope and the reducer rejects the narrowing. (codex.)
4. **A parent-category scope hid all descendant chips and rejected narrowing
   to them** — chips and `category_allowed?` compared literally while the
   query expanded the subtree. The modal now expands the scope once at init
   (`Tree.subtree_uuids_for/1`, normalized from raw 16-byte to string form)
   and hands every consumer the same literal list. (agy — best find of the
   round.)
5. **ItemPicker `select` ignored `excluded_uuids`/`disabled` server-side**
   — enforcement was markup-only; an in-flight click racing the re-render
   that excluded its target (or a crafted push) delivered the pick anyway.
   (all seats + own pass.)
6. **Preselects under a soft-deleted catalogue/category confirmed as
   available** — `in_scope?/3` now re-checks the preloaded parents the way
   the search joins do. (codex.)
7. **Hydrated preselect quantities bypassed every clamp** — now go through
   the same `clamp/2` as typed/stepped ones; the absolute `@qty_ceiling`
   moved INTO `clamp/2` so stepping can't walk past it either; `qty_min`/
   `qty_max` are normalized to the precision once at init. (grok + codex.)
8. **`mode: :single` accepted multi-entry preselections** — hydration keeps
   at most one (first by uuid). (grok.)
9. **Crafted `confirm` with nothing confirmable sent `{picks: []}`** — now
   refused with the same predicate that disables the button. ⚠️ Contract
   change: `:items_selected` never carries empty picks; tests that used
   "confirm → picked-count 0" as an empty-selection probe were updated.
   (grok + codex.)
10. **ItemPicker had no catch-all event clause and no `is_binary` guard on
    `query_change`** — malformed payloads were a `FunctionClauseError` in
    the host LV; queries are now also capped at 200 chars like
    BrowseState's. (zai + codex.)
11. **Parent scope changes left stale options selectable** — new scope
    assigns (`category_uuids`/`catalogue_uuids`/`include_descendants`/
    `only`/`statuses`) now invalidate options and close the dropdown.
    (codex.)
12. **`presented` accreted across every query and ignored the gen guard** —
    now reset on fresh fetches and gen-gated, keeping the documented
    "async is a drop-in" claim honest. (grok + codex.)
13. **`qty_commit` for unselected uuids grew `drafts` without bound** —
    membership check first. (codex.)
14. **`parse_qty` hard-rejected "0" even with `qty_min: 0`** — now compares
    against `qty_min`. (grok.)
15. **`per_page: 0` never exhausted** — floored at 1. (grok.)
16. **Locale-blind `category_paths` memo** — cleared when the parent's
    `locale` changes. (zai + codex; PR #79 review had deemed it
    unreachable, the clear is cheap insurance.)
17. **ARIA**: `aria-selected` rendered `""` with no selection; the listbox
    didn't exist while `aria-expanded="true"` promised it (empty state is
    now a status row inside the listbox). (codex + zai.)
18. **JS hook kept a stale highlight across result swaps** — `focusedIdx`
    resets when the option uuid-set changes (ids are positional and
    useless as a signature). (zai.)
19. **Chips ignored the viewer's locale** (PR #76 review, finding 14 —
    "one-line change later"); names now go through `translated_name/2`.
20. **ItemPicker gained the `:statuses` scope attr** for parity with the
    modal's vocabulary (the wrapper in `web/components.ex` forwards it —
    note the wrapper's fixed forward list, an easy place to lose an attr).

## Panel claims refuted on verification (do not "fix" these)

- `item.default_qty` nil/integer crash in `select/2` (agy critical, grok
  high): `Browse.present_items/2` always sets `default_qty: Decimal.new(1)`.
- ItemPicker's formless input never fires `query_change` (agy high): an
  input's OWN `phx-change` binding dispatches with the input as dispatcher —
  verified in `bindForms` in the bundled LV client.
- `Decimal.compare(qty, 0)` clause error (grok): fine on decimal 3.1.1.
- `[]` scope "widens" (grok): `[]` is the documented unrestricted alias
  across the whole `search_items/2` vocabulary, consistently — now stated in
  BrowseState's moduledoc too.
- `count_search_items/2` honouring `:limit` (grok): the base builder never
  applies paging.
- Duplicate DOM id from ProductCard (agy): internals are `-card`-suffixed;
  the doc example passes the namespace.
- `in_scope?` statuses-default mismatch (grok): search's no-statuses default
  is "all non-deleted", which `allowed?(nil, _) == true` mirrors exactly.

## Deliberately not done (rework territory / accepted)

- The `data::text ILIKE` JSONB match also matches KEYS (searching "name"
  matches everything) — real quality itch, but changing match semantics
  belongs to the rework.
- Escape-then-queued-debounce can reopen the picker dropdown for one beat
  (codex): cosmetic, self-heals on the next interaction.
- Unknown/deleted preselect uuids are dropped from the tray (nothing to
  render); now stated in the moduledoc instead of stubbed.
- The deferred list in `2026-08-22-item-selector-and-browse-components.md`
  stands untouched.

## Gate

`mix test` full suite + `mix precommit`, both checked by exit code
(see the PR that lands this for the final counts).
