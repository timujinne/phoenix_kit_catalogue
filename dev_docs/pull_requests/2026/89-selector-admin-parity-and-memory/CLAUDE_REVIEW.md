# PR #89: Item selector rework — admin parity, new defaults, per-user memory

**Author**: @mdon
**Reviewer**: Claude (`elixir:phoenix-thinking` applied before reading source)
**Status**: Merged
**Commit**: `620474e` (merge of `6801dc2..59bebbc`)
**Date**: 2026-08-30
**URL**: https://github.com/BeamLabEU/phoenix_kit_catalogue/pull/89
**Released in**: 0.24.0

## What changed

Six threads, all pulling the item-selector popup toward the admin pages it
mirrors:

1. **Admin-style browsing levels** — the flat chip strip is gone. `BrowseState`
   gained `drill: :direct` (fixed at init, like the scope): a drilled level lists
   its OWN items while a non-empty search still covers the subtree. The popup
   renders one level of the admin's category surface — `Components.category_card/1`
   tiles in card view, the shared `category_header_cells/1` columns as a compact
   table in table view — plus an Up button, section headings, and the admin's
   `Categories | Items` either-or switcher at a root that has categories.
2. **Shared category presentation** — `category_card/1`, `uncategorized_card/1`,
   `category_header_cells/1` and `category_body_cells/1` moved out of
   `CatalogueDetailLive` into `Web.Components`, so the detail page's flat table,
   its tree table, its card tiles and the popup's level all draw one definition.
   Admin-only chrome (bulk checkbox, drag handle, row menu, tree-DnD attributes)
   stays with the admin page via `:overlay` / `:menu` slots and `:rest`.
3. **Two-list search** — a search in the popup renders matching categories above
   the item results as navigation (`search_categories/3`, filtered to the popup's
   own tree so a scoped embed can never offer a category outside its allow-list);
   a hit opens that category with the search cleared.
4. **New defaults** — `show_tray` flips to `false`, `hidden_columns` drops `:sku`
   (article numbers now visible by default), and the catalogues index's search
   default ("" = auto) now answers a query with ITEM results, with
   `?mode=catalogues` as the explicit opt-out. The `Uncategorized` bucket is back
   as an entry in both category browsers when it holds anything.
5. **Per-user memory** — `ViewConfig.load_selector/1` / `save_selector/2` store
   the view and hidden-column choices under a `"__selector__"` key in
   `phoenix_kit_users.custom_fields`. The selector re-reads the user row at init
   (`refresh_user/1`) so a reopen in the same page visit sees choices saved
   moments ago rather than the host's stale mount snapshot.
6. **Smaller corrections** — item details became their own stacked
   `ProductCard` modal (with an `:extra_actions` slot for the mode-aware
   Add/quantity control), the title joined the photo as a "look closer" gesture
   in both card and table, `qty_stepper`'s form got `novalidate` (step/min/max
   are browser validation constraints that were silently killing Enter), the
   supplier `unit_cost` step became `"any"`, and `"set"` (kmpl) joined the item
   unit options.

## Verification of the risky claims

Checked against the producing code rather than the PR description:

- `"set"` is already in `Item`'s `@units` allow-list and has a `unit_label/1`
  clause — the new form option saves.
- `search_categories/3`'s `:parent_uuid` really does scope to the subtree and
  exclude the node itself, which is what the drilled two-list surface needs.
- Category hits are intersected with `cat_tree.index`, which is built from the
  **expanded** scope — a scoped embed cannot navigate outside its allow-list.
  Confirmed by the PR's own test plus the `level_up` finding below.
- `Auth.get_user!/1` takes a uuid binary, and `update_user_custom_fields/3`
  accepts the `ensure_definitions:` / `broadcast:` opts `save_selector/2` passes.
- `assigns.search_query` is fresh inside `handle_url_state/2`: `UrlState`'s
  `apply_state/3` calls `assign_state/3` *before* the callback, so the index's
  new auto-mode gate reads the current query, not the previous one. (Worth
  pinning: the gate would be off by one keystroke if that order ever changed.)
- `prefs_hidden/2` returning `[]` is a real "hide nothing" choice and correctly
  survives the `||` fallback — `[]` is truthy in Elixir.

## Findings

### 1. BUG — MEDIUM: a card could lose its only select target (`browse.ex`)

With `photo_click` set — the default now that `show_item_details` is `true` —
`item_card/1` splits the body: the title dispatches the details event, and "the
rest of the body" carries the select toggle. But that rest is only two
conditional spans:

```elixir
<span :if={@show_sku && @item.sku}>…</span>
<span :if={@show_price && @item.price}>…</span>
```

When neither renders — an embed that granted no `:price` over items with no SKU,
or `show_prices: false` plus blank SKUs — the select button renders **empty**.
It carries `flex-1`, so it is only saved by a grid row stretched by a taller
sibling; a row where every card lacks both collapses it to zero height. In the
checkbox flavour (`clickable: true`, no checkbox column in card view — that
column exists only in the table) the card then cannot be selected at all: the
photo and the title both open details, and there is nothing else to click.

**Fixed**: the toggle keeps a minimum hit area while it is clickable.

```elixir
class={[
  "text-left w-full flex-1 flex flex-col gap-0.5 cursor-pointer disabled:cursor-default",
  @clickable && "min-h-[1.5rem]"
]}
```

Gated on `@clickable` so the quantity flavour's disabled button adds no blank
strip to every card. Pinned in `browse_components_test.exs` ("the select toggle
keeps a hit area when sku and price both hide"), both directions.

The table view is not affected: `checkbox?/1` is `selection_mode != "quantity"
and :qty not in visible_columns`, which is true by construction in the checkbox
flavour, so a table row always has its checkbox.

### 2. BUG — MEDIUM: `Up` could point outside the scope and strand the user

`level_up/2` returned the standing category's `parent_uuid` unless that category
was one of the popup's root tiles. For a scope naming a single category, the
popup's roots are that category's *children* — but the scoped category itself is
in `cat_tree.index` (the expanded scope includes the node), so the new search
surface can offer it as a hit. Clicking that hit drills to it, and `Up` then
names its real parent, which `BrowseState.command/2` refuses as out of scope
(`category_allowed?/2`). The button renders, does nothing, and is the only way
back — the user is stuck one level below the popup root until they close it.

Reachable in exactly the shape the PR's own `hits respect the scope allow-list`
test builds, one level deeper: scope a category that itself has a parent, search
its own name, click the hit.

**Fixed**: an unreachable parent climbs to the popup root instead.

```elixir
if Enum.any?(tree.roots, &(&1.uuid == uuid)) or not Map.has_key?(tree.index, parent),
  do: "",
  else: parent
```

`tree.index` is the scope-filtered set, so "not in the index" is exactly "not a
level this popup can stand in". Pinned in `item_selector_modal_test.exs` ("a hit
on the scoped root itself leaves Up alive") — verified to fail against the
pre-fix `level_up/2`.

### 3. IMPROVEMENT — MEDIUM: the category search re-ran on every scrolled page

`run_fetch/2` ended with an unconditional
`assign(socket, :search_cat_hits, search_category_hits(socket))`. `:load_more`
changes neither the search string nor the level, so every infinite-scroll page
re-ran the category query — an `ILIKE` plus a `jsonb_path_query` over every
translation in the catalogue — for a result that cannot have changed.

**Fixed**: the hits are recomputed only on a fresh fetch (`offset == 0`), the
same discipline the `presented` map already uses two lines above. No behaviour
change, so no new test.

## Not fixed (deliberate)

- **The root's first fetch is thrown away.** A root with categories opens in
  `root_mode: "categories"`, which hides the items block, but `:reset` has
  already fetched page 1. Left alone: it makes the `Items` switch instant, and
  skipping it would mean teaching `BrowseState` about a presentation mode it has
  no business knowing.
- **The uncategorized row in the popup's level table hardcodes one trailing
  cell**, which is correct only because `@level_columns` is `["items"]`. A
  nitpick today; it becomes a real drift risk if that list ever grows.
- **The index's auto mode engages on a whitespace-only query** (`search_query !=
  ""` is untrimmed, while `current_search/1` is what actually gets searched).
  Cosmetic, and trimming here would need to agree with the toolbar's own
  debounce semantics.

## Gate

`mix precommit` (compile `--warnings-as-errors`, `deps.unlock --check-unused`,
`hex.audit`, format check, `credo --strict`, dialyzer) clean, and `mix test`
green with a database attached: 2 doctests, 2173 tests, 0 failures.

## Related PRs

- Previous: [#88](/dev_docs/pull_requests/2026/88-selector-flavours-details-widget-table)
