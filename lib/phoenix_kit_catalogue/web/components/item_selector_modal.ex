defmodule PhoenixKitCatalogue.Web.Components.ItemSelectorModal do
  @moduledoc """
  Catalogue item selector modal: the catalogue's analogue of core's
  `MediaSelectorModal`. A logged-in user browses the catalogue inside a
  modal — search, admin-style subcategory tiles, an admin-look table or
  photo-forward card grid — picks items, sets a quantity per item, and
  confirms.

  ## Browsing levels (admin-page semantics, 2026-08-31)

  Categories present exactly the way the admin detail page presents
  them, from the same shared definitions (`Components.category_card/1`
  tiles in card view, the `category_header_cells/1` columns as a compact
  table in table view). A root is just a level (Max, 2026-08-31): with
  categories it lists the pure outline — top-level categories plus an
  Uncategorized entry where the scope allows it — and items come from
  entering a folder or searching; page 1 is not even fetched there.
  Drilling into a category shows both sections, headed like the
  admin's: its child categories, an Up button, and the level's OWN
  items — while a non-empty search always covers the subtree of
  wherever you stand (`BrowseState`'s `drill: :direct`) and hides the
  level navigation. A category-less root simply lists the items. A
  MULTI-catalogue scope drills CATALOGUE-FIRST: the root lists the
  offered catalogues as tiles, choosing one lands on that catalogue's
  own root — its top categories, its Uncategorized bucket — and Up
  climbs back through the same chain. The catalogue choice narrows
  every fetch within the scope's offered list (`BrowseState`'s
  `{:set_catalogue, _}`, membership-checked like every narrowing).

  `root_switcher: true` restores the admin-style Categories | Items
  either-or at such roots (Catalogues | Items at a multi-catalogue
  root): Items is the flat no-query list of everything at that level.
  Off by default — the control read as a search-mode toggle while
  flipping the browse listing (both Max and the external UX review
  tripped over it), and search finds items better than the flat list
  browses them.

  Search is the admin's two-list surface: item results are the primary,
  default list, and categories whose name matches (in any language)
  render above them as navigation — a hit opens that category's page
  with the search cleared. Hits are filtered to the scoped category
  tree, cover only the drilled subtree when drilled, and stay away from
  the opt-in root Items mode (the admin's items-type search) and the
  Uncategorized drill.

  ## Usage

      # In the parent LiveView's template. Mount it with :if — unmounting
      # on close is what gives clean reopen semantics (fresh search, fresh
      # scroll, preselects re-read).
      <.live_component
        :if={@show_item_selector}
        module={PhoenixKitCatalogue.Web.Components.ItemSelectorModal}
        id="order-item-selector"
        scope={%{catalogue_uuids: [@catalogue.uuid]}}
        selected={@order_lines_by_uuid}
      />

  ## Required host wiring (do not skip — silent failure otherwise)

  This is a `LiveComponent`; it reports through process messages to the
  host LiveView, exactly like `MediaSelectorModal`. The host MUST handle
  both, or a confirmed selection is silently dropped:

    * `handle_info({:items_selected, %{id: id, mode: mode, picks: picks}}, socket)`
      — fired on Confirm, and only when at least one available pick
      exists: with nothing confirmable the event is refused server-side,
      exactly as the button is disabled client-side, so `picks` is never
      `[]`. Each pick is a map with `:uuid`, `:qty`
      (**always** a `Decimal`, integers included — hosts write one clause),
      `:unit`, and a display snapshot: `:name`, `:sku`, `:price`,
      `:line_total` (`price × qty`, nil when the item has no price),
      `:fee_note` (`Browse.smart_fee/1`'s display text — `"12%"` or a
      localized "Computed" — for a smart-catalogue fee with no numeric
      price; nil otherwise. `price: nil` + a `fee_note` means "fee,
      compute it order-side", not "free") and `:photo_url` (a signed
      URL — it expires, render it, never persist it). The snapshot is
      for rendering the host's own summary without a re-query; it is
      NOT an order record — re-read and re-price items server-side when
      the selection becomes something real.
    * `handle_info({:item_selector_closed, %{id: id}}, socket)` — fired on
      cancel/ESC/backdrop, AND after a confirm. Reset the `:if` assign
      here. One exception: with the item-details popup stacked open, the
      first cancel closes only the details — no message fires — and the
      next one closes the selector as usual. (Keeping Esc to the TOP
      popup client-side also needs the host's vendored core
      `phoenix_kit.js` from core > 2.13.17; on older bundles both
      dialogs close visually and this message still fires once.)

  ## Item details page

  `show_item_details` (default `true` since 2026-08-31) makes the
  photo/thumbnail a "look closer" affordance — the same gesture
  `ItemPicker` ships — opening the item's full details as its OWN
  `ProductCard` popup stacked over the selector (photo/file carousel,
  SKU, price, unit, description, metadata, attributes). The selector
  stays mounted underneath — search, tiles, scroll and selection are
  exactly where the user left them. A mode-aware selection control sits
  in the detail footer (Add/Remove in the checkbox flavour, the quantity
  input in quantity mode); opening never auto-selects.

  Pass `false` for embeds that must not expose the detail body —
  description, metadata and attached files go beyond what the columns
  contract granted, the same opt-out story as `show_prices`/`show_sku`
  (both of which the page honours). With columns omitting `:thumb` the
  table view has no entry point (cards keep theirs). Videos/FAQ sections
  are a planned extension once the item data model carries them.

  ## Header and tray

  With `context_header` (default true) the modal's title area shows WHAT
  is being browsed: when the scope names exactly one category (or,
  failing that, one catalogue), its featured image, translated name and
  description render as the header — the category wins as the more
  specific. An explicit `title` attr still names the modal (the context
  adds image/description around it); `context_header: false`, a
  multi-entry scope, or any resolution failure falls back to the plain
  title. Chrome, not data: nothing here widens what can be browsed.

  `show_tray` (default FALSE since 2026-08-31) controls the cart-count
  button and the expandable review list at the bottom. The quantity-first
  default already shows a number above 0 on every picked row, so the
  cart is opt-in chrome for hosts that want a review list. Cancel and
  Confirm always stay.

  ## Views and columns

  Two presentations over the same fetch: `view: "table"` (the default — a
  compact admin-look list) and `view: "card"` (the photo-forward grid). A
  toggle beside the search box switches them; the host attr only sets the
  STARTING view — like `scope`, it is read at init and not refreshed by
  later parent renders — and a user's own toggle wins over it on the next
  open when `current_user` is passed (see Per-user persistence).

  Table columns are a host contract, because the popup can be
  client-facing: pass `columns` as a non-empty list from
  `Browse.table_columns/0` (`:thumb :breadcrumb :name :sku :manufacturer
  :category :unit :price :base_price :qty`) in display order, and only
  those render. `:breadcrumb` is a headerless muted "Category /" prefix
  column beside Name (granted and hidden by default, like `:sku`). Unknown entries raise. `:price` is the customer-facing selling
  price (markup and discounts applied) shown as "6.40 / piece" — the
  default set carries it and NOT `:base_price`, the raw internal number,
  which an embed must ask for explicitly; `:unit` is the standalone
  column for price-free lists.
  Omitted, the full set applies minus what `show_sku: false` /
  `show_prices: false` already opt out of. Omitting `:qty` hides the
  inline stepper — quantities are then edited in the tray only (and the
  popup derives the checkbox flavour; see Selection modes).

  `hidden_columns` sets which GRANTED columns start hidden (the viewer
  re-shows them from the Columns dropdown): default `[:breadcrumb]` —
  SKU is visible by default since 2026-08-31 (the boss: the article
  number belongs on the list) — and `[]` starts everything visible.
  Unknown or ungranted entries are ignored — hiding less than asked
  never widens anything. The detail page follows the GRANT (plus the
  flags), not the visibility: hiding a granted `:price` doesn't strip it
  from details, un-granting it does.

  ## Per-user persistence

  Pass `current_user` (the `phoenix_kit_users` struct the host's
  live_session already assigns) and the selector remembers the view and
  column visibility each user last chose — stored beside the admin
  tables' preferences in `custom_fields` (`ViewConfig.load_selector/1`),
  one set per user across every selector embed. The saved choice beats
  the host's STARTING attrs (`view`, `hidden_columns`), never the grant:
  saved names outside `columns` are ignored, and quantity mode still
  forces `:qty` visible. No user, no persistence — every choice simply
  lives for the session.

  Granted columns are additionally staged by viewport so the modal never
  scrolls sideways: identity and the pick-driving numbers (thumb, name,
  price, qty) hold down to phone width; unit returns at `sm`, SKU at
  `md`, manufacturer and category at `lg`. The modal box itself widens on
  large viewports (`xl`/`2xl`) beyond core Modal's 4xl cap. On phones the
  card grid remains the roomier alternative, one toggle away.

  ## Selection modes — either quantities or checkboxes

  The two flavours are mutually exclusive, and the DEFAULT derives from
  the columns (2026-08-31): a visible `:qty` column makes the popup
  quantity-first — EVERY rendered row shows its quantity control at 0,
  entering a positive quantity (spinner arrows or typing) IS the
  selection, zero removes it, and rows/cards are not click-targets —
  while a popup without `:qty` is the checkbox flavour: the table leads
  with a checkbox column (unchecked on every selectable row, so the
  "you can pick these" affordance is visible before the first pick),
  clicking a row/card toggles it, and quantities are edited in the tray.
  A checked box and a quantity input never share a row — one selected
  signal, not two.

  `selection_mode: "click" | "quantity"` still forces a flavour
  explicitly, and the either-or holds even then (Max, 2026-08-31: a
  checkmark means no number entry, and the check sits in the leftmost
  column): forcing "click" with a visible `:qty` leads with the checkbox
  column and the qty cell shows the picked amount READ-ONLY — meaningful
  for preselects a host hands in at other quantities; user picks land at
  the minimum. A host that wants users EDITING quantities in this
  flavour must open a surface for it: `inline_qty: true` (below) or
  `show_tray: true` (off by default). `inline_qty: true` is the
  deliberate opt-in for hosts that really want both — it restores the
  legacy pairing (no checkbox column, check icon/badge plus a stepper
  once selected).
  Quantity mode ignores it. The tray, Confirm, and every guard behave
  identically in all flavours.

  ## Scope

  `scope` fixes what the user may browse: any of `:catalogue_uuids`,
  `:category_uuids`, `:only`, `:statuses`, `:include_descendants` (the
  `Catalogue.search_items/2` vocabulary). It is enforced in `BrowseState`
  — every fetch re-derives from it, and client events can only narrow
  within it, so a crafted event cannot browse or select outside what the
  host allowed. Selection events are additionally accepted only for uuids
  the component itself has rendered (or that arrived preselected).

  ## Preselection

  `selected` is `%{uuid => qty}` (string uuids, `Decimal` or integer
  quantities). Preselected items are hydrated at mount ignoring scope —
  the tray must be able to render what the host handed it. A hydrated item
  that falls OUTSIDE the scope renders in the tray marked unavailable and
  is excluded from the confirm picks, never silently dropped. A uuid that
  no longer resolves at all (deleted or unknown) IS dropped — there is
  nothing to render. Hydrated quantities are clamped like typed ones
  (min/max/precision and the absolute ceiling), and in `:single` mode at
  most one preselected entry survives (first by uuid).

  ## Quantities

  The control is a native `<input type="number">` (browser spinner
  arrows — 2026-08-30). `qty_precision: 0` (default) is whole numbers
  (step 1); a positive precision turns it decimal-capable ("2.5" of unit
  "L", step 0.1). Arrow clicks and settled typing apply live (debounced
  `qty_change`, which never resets in-progress text); blur/Enter is the
  authoritative commit that discards garbage. Decimal commas are accepted
  ("2,5" — ru/et keyboards); all limits re-clamped server-side.
  """

  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitCatalogue.Gettext

  import PhoenixKitWeb.Components.Core.Modal, only: [modal: 1]

  import PhoenixKitWeb.Components.Core.TableDefault,
    only: [
      table_default: 1,
      table_default_header: 1,
      table_default_header_cell: 1,
      table_default_body: 1,
      table_default_row: 1,
      table_default_cell: 1
    ]

  import PhoenixKitCatalogue.Web.Components.Browse

  alias PhoenixKit.Users.Auth
  require Logger

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.BrowseState
  alias PhoenixKitCatalogue.Catalogue.Tree
  alias PhoenixKitCatalogue.Web.Components, as: Shared
  alias PhoenixKitCatalogue.Web.Components.Browse
  alias PhoenixKitCatalogue.Web.Components.ProductCard
  alias PhoenixKitCatalogue.Web.ViewConfig

  # A hard ceiling even when the host sets no qty_max: Decimal.parse
  # accepts "1e1000000" as a full match, and an absurd exponent is a
  # process-DoS the moment it hits multiplication.
  @qty_ceiling Decimal.new(1_000_000)

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       initialized: false,
       tray_open: false,
       detail: nil,
       confirmed: false,
       root_mode: "categories",
       search_cat_hits: [],
       drafts: %{}
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, Map.take(assigns, [:id]))

    if socket.assigns.initialized do
      # A parent re-render must not clobber live selection state (the
      # classic LiveComponent update/2 trap) — after init, only cosmetic
      # props may refresh.
      prior_grants = Map.take(socket.assigns, [:show_prices, :show_sku])
      socket = assign(socket, Map.take(assigns, [:title, :show_prices, :show_sku]))

      # An open details page materialized its fields under the OLD
      # display grants — a host revoking show_prices/show_sku mid-view
      # must not leave the hidden values rendered (external review,
      # 2026-08-31). Rebuild only on an actual flag change: it re-reads
      # the item, and a parent render is not a reason for a query.
      socket =
        if socket.assigns.detail &&
             Map.take(socket.assigns, [:show_prices, :show_sku]) != prior_grants,
           do: open_detail(socket, socket.assigns.detail.uuid, :close),
           else: socket

      {:ok, socket}
    else
      {:ok, initialize(socket, assigns)}
    end
  end

  defp initialize(socket, assigns) do
    original_scope = assigns[:scope] || %{}
    assigns = Map.put(assigns, :current_user, refresh_user(assigns[:current_user]))

    # BrowseState.init/1 validates the scope keys (atoms, search_items/2
    # vocabulary) so a string-keyed map cannot silently widen browsing.
    browse =
      BrowseState.init(
        scope: expand_scope(original_scope),
        per_page: assigns[:per_page] || 24,
        # Admin-page semantics (2026-08-31): a drilled level lists its own
        # items; search still covers the subtree.
        drill: :direct,
        # The module's shared sort (client, 2026-09-01): the popup lists
        # items in the same order the admin detail page does. Read once at
        # init, like the tree — a modal open while an admin re-sorts
        # elsewhere keeps the order it opened with.
        order: Browse.global_items_order()
      )

    # A scope naming exactly ONE category means the popup OPENS standing
    # in it — a drilled level: its child tiles AND its own direct items
    # (boss, 2026-08-31: the trashcans category showed its subcategories
    # but not the items filed directly on it). Before the root switcher
    # retired, those items hid behind the Items flat mode; now the
    # drilled level is simply the floor. Back stays hidden there.
    scoped_root = scoped_root_category(original_scope)

    {browse, effect} =
      case scoped_root do
        nil -> BrowseState.command(browse, :reset)
        uuid -> BrowseState.command(browse, {:set_category, uuid})
      end

    locale = assigns[:locale] || Gettext.get_locale(PhoenixKitCatalogue.Gettext)
    qty_precision = assigns[:qty_precision] || 0
    mode = assigns[:mode] || :multiple
    scope = browse.scope

    limits = resolve_limits!(assigns, qty_precision)
    display = display_opts(assigns)
    presentation = resolve_presentation!(assigns, display)

    socket =
      socket
      |> assign(display)
      |> assign(presentation)
      |> assign(
        initialized: true,
        mode: mode,
        locale: locale,
        current_user: assigns[:current_user],
        context_header?: Map.get(assigns, :context_header, true),
        header_context: header_context(assigns, original_scope, locale),
        qty_precision: qty_precision,
        qty_min: limits.qty_min,
        qty_max: limits.qty_max,
        scoped_root_category: scoped_root,
        cat_tree: build_category_tree(scope, original_scope, locale),
        presented: %{},
        selection: hydrate_preselection(assigns[:selected] || %{}, scope, locale, limits, mode),
        browse: browse
      )

    run_fetch(socket, effect)
  end

  defp scoped_root_category(original_scope) do
    case List.wrap(original_scope[:category_uuids]) do
      [single] -> to_string(normalize_uuid(single))
      _ -> nil
    end
  end

  # Resolved from the ORIGINAL scope, before subtree expansion — the
  # host named a catalogue or category, and that record is the header.
  defp header_context(assigns, original_scope, locale) do
    if Map.get(assigns, :context_header, true),
      do: resolve_header_context(original_scope, locale),
      else: nil
  end

  # View / columns / selection flavour, as one resolution. Per-user saved
  # choices (2026-08-31): a host may pass current_user (the phoenix_kit
  # user struct) and the selector then remembers the view and column
  # visibility the user last chose — the saved choice beats the host's
  # STARTING attrs, never the grant. No user, no persistence, everything
  # still works.
  defp resolve_presentation!(assigns, display) do
    columns = Browse.resolve_columns!(assigns[:columns], display)
    prefs = ViewConfig.load_selector(assigns[:current_user])
    hidden = prefs_hidden(prefs.hidden, columns) || assigns[:hidden_columns]

    selection_mode =
      resolve_selection_mode!(assigns[:selection_mode], visible_columns(columns, hidden))

    %{
      view: prefs.view || Browse.resolve_view!(assigns[:view], "table"),
      columns: columns,
      visible_columns: resolve_visible_columns!(selection_mode, columns, hidden),
      selection_mode: selection_mode
    }
  end

  # Bounds are normalized to the precision once, here: clamp/2 applies
  # qty_max AFTER rounding, so a fractional max under qty_precision: 0
  # would reintroduce the fraction it just removed. Max floors, min ceils —
  # both stay inside the host's stated bound — and bounds that INVERT after
  # rounding raise: every quantity would silently collapse to the max.
  defp resolve_limits!(assigns, qty_precision) do
    limits = %{
      qty_min: Decimal.round(to_decimal(assigns[:qty_min] || 1), qty_precision, :ceiling),
      qty_max:
        assigns[:qty_max] && Decimal.round(to_decimal(assigns[:qty_max]), qty_precision, :floor),
      qty_precision: qty_precision
    }

    if limits.qty_max && Decimal.lt?(limits.qty_max, limits.qty_min) do
      raise ArgumentError,
            "ItemSelectorModal qty_max #{inspect(assigns[:qty_max])} rounds below " <>
              "qty_min #{inspect(assigns[:qty_min] || 1)} at precision #{qty_precision} — " <>
              "every quantity would silently collapse to the max"
    end

    if Decimal.gt?(limits.qty_min, @qty_ceiling) do
      raise ArgumentError,
            "ItemSelectorModal qty_min #{inspect(assigns[:qty_min])} exceeds the " <>
              "#{Decimal.to_string(@qty_ceiling, :normal)} safety ceiling — clamp/2 would " <>
              "silently violate the declared minimum"
    end

    limits
  end

  # The default derives from the columns (2026-08-31 — "it's either or"):
  # a visible :qty column IS the amount flavour — every row shows its
  # input at 0 and a number above zero is the selection — while a popup
  # without :qty is the checkbox flavour (row click toggles). A checked
  # box AND a quantity input on the same row said "selected" twice.
  # An explicit attr still forces either mode.
  defp resolve_selection_mode!(nil, visible),
    do: if(:qty in visible, do: "quantity", else: "click")

  defp resolve_selection_mode!(mode, _visible) when mode in ["click", "quantity"], do: mode

  defp resolve_selection_mode!(mode, _visible) when mode in [:click, :quantity],
    do: to_string(mode)

  defp resolve_selection_mode!(other, _visible),
    do:
      raise(
        ArgumentError,
        ~s(ItemSelectorModal selection_mode must be "click" or "quantity", got: #{inspect(other)})
      )

  # The granted set minus what starts hidden. SKU is hidden by default in
  # THIS picker — most embeds don't want it seen, though it stays granted
  # and one dropdown click away. Hosts override via hidden_columns
  # (unknown/ungranted entries are simply ignored: hiding less than asked
  # never widens anything).
  # Quantity-first without a :qty column is a contradiction — the stepper
  # IS the selector — so an ungranted :qty raises and a merely-hidden one
  # is forced visible (locked_columns already stops the viewer hiding it).
  defp resolve_visible_columns!("quantity", columns, hidden) do
    if :qty not in columns do
      raise ArgumentError,
            ~s(ItemSelectorModal selection_mode "quantity" requires the :qty column — ) <>
              "the stepper is the selector"
    end

    visible = visible_columns(columns, hidden)

    if :qty in visible,
      do: visible,
      else: Enum.filter(columns, &(&1 == :qty or &1 in visible))
  end

  defp resolve_visible_columns!(_mode, columns, hidden), do: visible_columns(columns, hidden)

  # Saved hidden-column strings -> the granted atoms they still name;
  # nil (never chosen) stays nil so the host attrs/defaults apply. An
  # empty saved list is a real choice ("hide nothing").
  defp prefs_hidden(nil, _granted), do: nil

  defp prefs_hidden(stored, granted) when is_list(stored) do
    Enum.filter(granted, &(to_string(&1) in stored))
  end

  # The host's current_user assign is a snapshot from the HOST's mount —
  # a choice saved in a previous open of this selector (same page visit)
  # is invisible to it, so a reopen would load yesterday's prefs and the
  # next save would write over today's. Re-read the row at init; keep the
  # snapshot when the re-read fails (a stub user in tests, no row).
  defp refresh_user(%Auth.User{uuid: uuid} = user) do
    Auth.get_user!(uuid)
  rescue
    _ -> user
  end

  defp refresh_user(other), do: other

  # Best-effort persistence: store what the user just chose and keep the
  # REFRESHED user on the socket — the save merges into the whole
  # custom_fields map, so a stale snapshot would clobber the previous
  # choice on the next save (the save_view_on/2 lesson in ViewConfig).
  defp persist_selector(socket, choices) do
    case ViewConfig.save_selector(socket.assigns.current_user, choices) do
      {:ok, updated} -> assign(socket, current_user: updated)
      _ -> socket
    end
  end

  # A column toggle both applies and persists: what is saved is the
  # HIDDEN set (granted minus visible, as strings), so the pref stays
  # meaningful if the host's grant changes later.
  defp put_visible_columns(socket, visible) do
    hidden = Enum.map(socket.assigns.columns -- visible, &to_string/1)

    socket
    |> assign(:visible_columns, visible)
    |> persist_selector(%{hidden: hidden})
  end

  defp visible_columns(granted, hidden) do
    # SKU ("article") starts VISIBLE since 2026-08-31 (boss) — only the
    # breadcrumb prefix stays default-hidden. Hosts opt out via
    # hidden_columns as before.
    hidden = if is_list(hidden), do: hidden, else: [:breadcrumb]
    Enum.reject(granted, &(&1 in hidden))
  end

  # Columns the viewer may NOT toggle at all: in quantity-first mode qty
  # IS the selector. Identity (:name) is guarded separately — the last
  # visible identity column refuses to hide, the way the admin tables
  # pin name.
  defp locked_columns(assigns) do
    if assigns.selection_mode == "quantity", do: [:qty], else: []
  end

  # The Uncategorized chip only makes sense where BrowseState would accept
  # the narrowing (see its {:set_category, :uncategorized} clause).
  defp offer_uncategorized?(scope) do
    scope[:only] == nil and scope[:category_uuids] in [nil, []]
  end

  @identity_columns [:name]

  defp last_identity?(col, visible) do
    col in @identity_columns and Enum.filter(@identity_columns, &(&1 in visible)) == [col]
  end

  # The popup is potentially client-facing, so columns are a host contract
  # (see Browse.resolve_columns!/2, shared with CatalogueBrowse).

  # Scope subtree expansion is shared with CatalogueBrowse — see
  # Browse.expand_scope/1 (imported).

  # ── Category tree (admin-style subcategory tiles, 2026-08-31) ────────
  #
  # The flat chip strip became one level of admin-look tiles: the level
  # you stand in shows its child categories (drill down) and its own
  # items. Built once at init from the categories-metadata read; any
  # failure degrades to the empty tree: tiles are navigation, not data.
  # A single-catalogue scope gets one flat root level; a MULTI-catalogue
  # scope (tim-dev's wide order picker — 2026-08-31, "check why the
  # categories and sub categories aren't showing") drills CATALOGUE-FIRST:
  # the root lists the catalogues as tiles, drilling into one shows its
  # top categories. Below that, drilling is catalogue-agnostic — category
  # uuids are global and the fetch still re-ANDs catalogue_uuids.
  @empty_cat_tree %{index: %{}, children: %{}, roots: [], counts: %{}}

  defp build_category_tree(scope, original, locale) do
    scope
    |> derive_tree_catalogues(original)
    |> do_build_category_tree(original, locale)
    |> order_tree_tiles(Browse.global_categories_order())
  end

  # Tiles follow the module's shared category sort (client, 2026-09-01:
  # one order everywhere) — the exact semantics of the admin detail
  # page's `sort_categories/4`, counts included. Manual keeps the query's
  # position order (and, like the admin's, has no direction). Catalogue
  # tiles at a multi-catalogue root follow the index's shared sort where
  # the tile carries the data; its data-less sorts (folder, description,
  # markup…) keep the admin index's manual baseline instead.
  defp order_tree_tiles(tree, {by, dir}) do
    counts = tree[:counts] || %{}

    sorted_roots = sort_tiles(tree.roots, by, dir, counts)

    tree
    |> Map.put(:roots, sorted_roots)
    |> Map.put(
      :children,
      Map.new(tree.children, fn {parent, kids} -> {parent, sort_tiles(kids, by, dir, counts)} end)
    )
    |> then(fn t ->
      # The multi-catalogue clause groups roots per catalogue for the
      # drilled level — regroup from the sorted list (group_by keeps
      # element order within groups).
      if Map.has_key?(t, :roots_by_catalogue) do
        Map.put(
          t,
          :roots_by_catalogue,
          Enum.group_by(sorted_roots, fn category -> to_string(category.catalogue_uuid) end)
        )
      else
        t
      end
    end)
    |> order_catalogue_tiles()
  end

  defp sort_tiles(categories, by, dir, counts) do
    sorted = tile_sorted(categories, by, counts)

    # Reverse, not a :desc sorter — byte-for-byte the admin detail page's
    # descend (Manual has no direction there, so none here either).
    if by != :position and dir == :desc, do: Enum.reverse(sorted), else: sorted
  end

  # Manual: the admin's exact key — position, lowercased-name tie-break
  # (`sort_categories/4`'s) — never the raw SQL order.
  defp tile_sorted(categories, :position, _counts),
    do: Enum.sort_by(categories, &{&1.position, String.downcase(&1.name || "")})

  defp tile_sorted(categories, :name, _counts),
    do: Enum.sort_by(categories, &String.downcase(&1.name || ""))

  defp tile_sorted(categories, :items, counts),
    do: Enum.sort_by(categories, &Map.get(counts, &1.uuid, 0))

  # The DateTime sorter, not term order — structurally, DateTime structs
  # compare field-alphabetically (day before month).
  defp tile_sorted(categories, :updated, _counts),
    do: Enum.sort_by(categories, & &1.updated_at, DateTime)

  defp tile_sorted(categories, _by, _counts), do: categories

  defp order_catalogue_tiles(%{catalogues: catalogues} = tree) do
    {by, dir} = ViewConfig.load_global_sort(:catalogues)
    %{tree | catalogues: sort_catalogue_tiles(catalogues, by, dir, tree[:counts] || %{})}
  end

  defp order_catalogue_tiles(tree), do: tree

  # Stable directional sorts, like the index's `TableQuery.sort/4` (which
  # passes the direction into `Enum.sort_by/3` — no reverse), with the
  # index's sort keys wherever the tile (a full Catalogue struct) carries
  # the data. Only the folder sort lives outside the struct — it and
  # Manual keep the index's manual baseline (position, lowercased name;
  # the index's Manual has no direction either).
  defp sort_catalogue_tiles(catalogues, "name", dir, _counts),
    do: Enum.sort_by(catalogues, &String.downcase(&1.name || ""), dir)

  defp sort_catalogue_tiles(catalogues, "items", dir, counts),
    do: Enum.sort_by(catalogues, &Map.get(counts, &1.uuid, 0), dir)

  defp sort_catalogue_tiles(catalogues, "status", dir, _counts),
    do: Enum.sort_by(catalogues, &String.downcase(&1.status || ""), dir)

  defp sort_catalogue_tiles(catalogues, "kind", dir, _counts),
    do: Enum.sort_by(catalogues, &String.downcase(&1.kind || ""), dir)

  defp sort_catalogue_tiles(catalogues, "description", dir, _counts),
    do: Enum.sort_by(catalogues, &String.downcase(&1.description || ""), dir)

  defp sort_catalogue_tiles(catalogues, "markup", dir, _counts),
    do: Enum.sort_by(catalogues, &decimal_key(&1.markup_percentage), dir)

  defp sort_catalogue_tiles(catalogues, "discount", dir, _counts),
    do: Enum.sort_by(catalogues, &decimal_key(&1.discount_percentage), dir)

  defp sort_catalogue_tiles(catalogues, "updated", dir, _counts),
    do: Enum.sort_by(catalogues, & &1.updated_at, {dir, DateTime})

  defp sort_catalogue_tiles(catalogues, "created", dir, _counts),
    do: Enum.sort_by(catalogues, & &1.inserted_at, {dir, DateTime})

  defp sort_catalogue_tiles(catalogues, _by, _dir, _counts),
    do: Enum.sort_by(catalogues, &{&1.position, String.downcase(&1.name || "")})

  defp decimal_key(%Decimal{} = d), do: Decimal.to_float(d)
  defp decimal_key(n) when is_number(n), do: n
  defp decimal_key(_), do: 0.0

  # A scope may name only CATEGORIES (tim-dev's per-category narrow
  # pickers pass category_uuids: [cat], catalogue_uuids: nil) — the
  # clauses below key the tree off catalogue_uuids, so that shape fell
  # through to the EMPTY tree and the popup showed no subcategory tiles
  # at all (error report, 2026-08-31: WASTE SORTERS' children missing
  # while the data was fine). The catalogue is implied by the scoped
  # categories themselves — derive it, for the TREE ONLY: the browse
  # scope, and every fetch derived from it, stays exactly what the host
  # passed. Only a single unambiguous catalogue is injected; a scope
  # whose categories span several keeps today's flat no-tree behaviour
  # rather than inventing a catalogue-first root the host never asked
  # for.
  defp derive_tree_catalogues(scope, original) do
    if scope[:catalogue_uuids] in [nil, []] do
      derived =
        original[:category_uuids]
        |> List.wrap()
        |> Enum.map(&Catalogue.get_category(normalize_uuid(&1)))
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&to_string(&1.catalogue_uuid))
        |> Enum.uniq()

      case derived do
        [catalogue_uuid] -> Map.put(scope, :catalogue_uuids, [catalogue_uuid])
        _ -> scope
      end
    else
      scope
    end
  rescue
    # Tiles are navigation, not data — garbage in the host scope crashes
    # elsewhere on its own terms, never here.
    _ -> scope
  end

  defp do_build_category_tree(%{only: :uncategorized_only}, _original, _locale),
    do: @empty_cat_tree

  defp do_build_category_tree(%{catalogue_uuids: uuids} = scope, original, locale)
       when is_list(uuids) and length(uuids) > 1 do
    catalogue_uuids = Enum.map(uuids, &normalize_uuid/1)
    base = category_tree_base(catalogue_uuids, scope, original, locale)

    # Catalogue-first drill (Max, 2026-08-31: "for multiple catalogues we
    # should first have the user choose a catalogue"): the ROOT level
    # lists the offered catalogues themselves as tiles; drilling into one
    # shows ITS top categories, exactly like a single-catalogue root.
    catalogues =
      catalogue_uuids
      |> Enum.map(fn catalogue_uuid ->
        case Catalogue.get_catalogue(catalogue_uuid) do
          nil ->
            nil

          catalogue ->
            catalogue
            |> Map.put(:name, translated_name(catalogue, locale) || catalogue.name)
            |> Map.put(:uuid, to_string(catalogue.uuid))
        end
      end)
      |> Enum.reject(&is_nil/1)

    category_counts =
      catalogue_uuids
      |> Enum.flat_map(fn catalogue_uuid ->
        catalogue_uuid
        |> Catalogue.item_counts_by_category_for_catalogue()
        |> Map.to_list()
      end)
      |> Map.new(fn {uuid, count} -> {to_string(uuid), count} end)

    # Catalogue tiles show their total item count out of the same map the
    # category tiles read — uuids never collide.
    catalogue_counts =
      Map.new(catalogue_uuids, fn catalogue_uuid ->
        {catalogue_uuid, Catalogue.count_items_for_catalogue(catalogue_uuid)}
      end)

    Map.merge(base, %{
      catalogues: catalogues,
      roots_by_catalogue:
        Enum.group_by(base.roots, fn category -> to_string(category.catalogue_uuid) end),
      counts: Map.merge(category_counts, catalogue_counts),
      # Uncategorized is offered per chosen catalogue, not on the
      # catalogue list itself.
      uncategorized_by_catalogue:
        if offer_uncategorized?(scope) do
          Map.new(
            catalogue_uuids,
            &{&1, Catalogue.uncategorized_count_for_catalogue(&1)}
          )
        else
          %{}
        end
    })
  rescue
    error -> degraded_tree(error, __STACKTRACE__)
  end

  defp do_build_category_tree(%{catalogue_uuids: [catalogue_uuid]} = scope, original, locale) do
    base = category_tree_base([catalogue_uuid], scope, original, locale)

    Map.merge(base, %{
      counts:
        catalogue_uuid
        |> Catalogue.item_counts_by_category_for_catalogue()
        |> Map.new(fn {uuid, count} -> {to_string(uuid), count} end),
      uncategorized:
        if(offer_uncategorized?(scope),
          do: Catalogue.uncategorized_count_for_catalogue(catalogue_uuid)
        )
    })
  rescue
    error -> degraded_tree(error, __STACKTRACE__)
  end

  defp do_build_category_tree(_scope, _original, _locale), do: @empty_cat_tree

  # The level maps both tree shapes build identically: translated
  # categories, the uuid index, the children grouping, and the root
  # tiles (the two clauses used to carry this verbatim twice —
  # external review, 2026-08-31).
  defp category_tree_base(catalogue_uuids, scope, original, locale) do
    categories =
      catalogue_uuids
      |> Enum.flat_map(&Catalogue.list_categories_metadata_for_catalogue/1)
      |> scope_categories(scope[:category_uuids])
      |> Enum.map(fn category ->
        category
        |> Map.put(:name, translated_name(category, locale) || category.name)
        |> Map.put(:uuid, to_string(category.uuid))
      end)

    children =
      Enum.group_by(categories, fn category ->
        category.parent_uuid && to_string(category.parent_uuid)
      end)

    %{
      index: Map.new(categories, &{&1.uuid, &1}),
      children: children,
      roots: tree_roots(categories, children, original)
    }
  end

  # Tiles are navigation, not data, so any tree-build failure degrades
  # to the empty tree — but LOGGED: a silent rescue here once made a
  # DB hiccup indistinguishable from the "categories aren't showing"
  # bug it degraded around (external review, 2026-08-31).
  defp degraded_tree(error, stacktrace) do
    Logger.warning(
      "ItemSelectorModal category tree degraded to empty: " <>
        Exception.format(:error, error, stacktrace)
    )

    @empty_cat_tree
  end

  defp scope_categories(categories, nil), do: categories
  defp scope_categories(categories, []), do: categories

  defp scope_categories(categories, allowed) do
    allowed = Enum.map(allowed, &to_string/1)
    Enum.filter(categories, &(to_string(&1.uuid) in allowed))
  end

  # What the popup's ROOT level lists as tiles. Unrestricted scope: the
  # catalogue's top-level categories. One scoped category: you are
  # standing IN it (the context header already presents it), so its
  # children. Several: the scoped categories themselves.
  defp tree_roots(categories, children, original) do
    case List.wrap(original[:category_uuids]) do
      [] ->
        Map.get(children, nil, [])

      [single] ->
        Map.get(children, to_string(single), [])

      several ->
        several = Enum.map(several, &to_string/1)
        Enum.filter(categories, &(&1.uuid in several))
    end
  end

  # The current level's tiles: category children when drilled, a chosen
  # catalogue's top categories, the CATALOGUE list at a multi-catalogue
  # root (catalogue-first drill), or a single-catalogue root's top
  # categories.
  defp level_entries(tree, browse) do
    cond do
      browse.category_uuid == :uncategorized -> []
      is_binary(browse.category_uuid) -> Map.get(tree.children, browse.category_uuid, [])
      is_binary(browse.catalogue_uuid) -> level_catalogue_roots(tree, browse.catalogue_uuid)
      tree[:catalogues] -> tree.catalogues
      true -> tree.roots
    end
  end

  defp level_catalogue_roots(tree, catalogue_uuid),
    do: Map.get(tree[:roots_by_catalogue] || %{}, catalogue_uuid, [])

  # Under the catalogue-first drill a crafted category event could wed
  # the drilled catalogue A to catalogue B's category — a contradictory
  # (empty, dead-end) level the UI never offers: tiles and search hits
  # are both narrowed to the drilled catalogue. BrowseState can't refuse
  # it (its allow-list is category-global); the component holds the
  # category→catalogue knowledge, so the gate lives here (external
  # review, 2026-08-31). Categories the tree doesn't know pass through —
  # BrowseState's own scope check owns those.
  defp cross_catalogue_category?(tree, browse, uuid) when is_binary(uuid) do
    is_binary(browse.catalogue_uuid) and
      case tree.index[uuid] do
        %{catalogue_uuid: catalogue_uuid} -> to_string(catalogue_uuid) != browse.catalogue_uuid
        _ -> false
      end
  end

  defp cross_catalogue_category?(_tree, _browse, _value), do: false

  # Whether the current level lists CATALOGUES (the multi-catalogue root).
  defp catalogues_level?(tree, browse) do
    tree[:catalogues] != nil and is_nil(browse.catalogue_uuid) and
      is_nil(browse.category_uuid)
  end

  # A tile's own children — drives the has-subs badge and the count.
  defp tile_children(tree, browse, uuid) do
    if catalogues_level?(tree, browse),
      do: level_catalogue_roots(tree, uuid),
      else: Map.get(tree.children, uuid, [])
  end

  # The Uncategorized offer for the CURRENT level: a single-catalogue
  # root, or a chosen catalogue's level (its own loose items) — never the
  # catalogue list.
  defp level_uncategorized(tree, browse) do
    cond do
      browse.category_uuid != nil ->
        nil

      is_binary(browse.catalogue_uuid) ->
        Map.get(tree[:uncategorized_by_catalogue] || %{}, browse.catalogue_uuid)

      tree[:catalogues] ->
        nil

      true ->
        tree[:uncategorized]
    end
  end

  defp level_up(_tree, :uncategorized), do: ""

  defp level_up(tree, uuid) when is_binary(uuid) do
    case tree.index[uuid] do
      %{parent_uuid: parent} when not is_nil(parent) ->
        parent = to_string(parent)

        # The popup root ("") whenever the parent is not a level this
        # popup can stand in: a root tile's parent by definition, and a
        # parent OUTSIDE the scope tree — a search hit can drill to a
        # scoped root category itself, whose real parent BrowseState
        # then refuses, leaving Up dead and the only way back with it.
        if Enum.any?(tree.roots, &(&1.uuid == uuid)) or not Map.has_key?(tree.index, parent),
          do: "",
          else: parent

      _ ->
        ""
    end
  end

  defp level_up(_tree, _), do: ""

  # A whitespace-only query is NO search — the fetch layer trims it to
  # no filter, and BrowseState's :direct drill treats it the same way
  # (see query_opts/1), so the navigation gates must agree or the level
  # tiles vanish for a query that lists exactly the level's own items
  # (external review, 2026-08-31).
  defp searching?(browse), do: String.trim(browse.search) != ""

  # Whether the browse region renders the level navigation at all: always
  # while drilled (the Up affordance must exist even in an empty level),
  # at root only when there are tiles to show — a category-less catalogue
  # keeps the plain flat list. Hidden while searching: search covers the
  # subtree, so level navigation would lie about what is listed.
  defp show_level_nav?(assigns) do
    not searching?(assigns.browse) and
      (assigns.browse.category_uuid != nil or
         assigns.browse.catalogue_uuid != nil or
         level_entries(assigns.cat_tree, assigns.browse) != [])
  end

  # Whether the level renders a categories BLOCK (tiles or rows) — the
  # Items section heading only makes sense when there is a categories
  # section above it to be separate from.
  defp level_has_section?(assigns) do
    level_entries(assigns.cat_tree, assigns.browse) != [] or
      (level_uncategorized(assigns.cat_tree, assigns.browse) || 0) > 0
  end

  # The root-level either-or: a level with an outline to show browses
  # EITHER that outline OR the flat item list. It applies wherever no
  # CATEGORY is drilled — the multi-catalogue root (listing catalogues)
  # and a chosen catalogue's level included; drilled category levels
  # always show both sections; a search shows results regardless of the
  # mode. The Items side is reachable only under the opt-in
  # root_switcher (Max, 2026-08-31 — a root is just a level); without
  # it root_mode is pinned to "categories", so the gate simply hides
  # the item block at tile levels, and tiles_only_level?/1 skips their
  # pointless page-1 fetch.
  defp root_mode_gate?(assigns) do
    not searching?(assigns.browse) and is_nil(assigns.browse.category_uuid) and
      level_entries(assigns.cat_tree, assigns.browse) != []
  end

  defp show_categories_block?(assigns) do
    show_level_nav?(assigns) and
      not (root_mode_gate?(assigns) and assigns.root_mode == "items")
  end

  defp show_items_block?(assigns) do
    not (root_mode_gate?(assigns) and assigns.root_mode == "categories")
  end

  # Both sections at once happens only on a drilled level — that is when
  # the Items heading separates them (the admin's section idiom).
  defp both_sections?(assigns) do
    show_categories_block?(assigns) and show_items_block?(assigns) and
      level_has_section?(assigns)
  end

  # One level of the admin pages' categories surface + the Up affordance.
  # Like the admin's, the level follows the view toggle: card = the
  # shared `Shared.category_card/1` tiles, table = a compact table drawing
  # the shared `Shared.category_header_cells/1`/`category_body_cells/1`
  # columns. A multi-catalogue scope drills CATALOGUE-FIRST (Max,
  # 2026-08-31): the root lists the offered catalogues as tiles
  # (`browse_catalogue`), a chosen catalogue's level then behaves exactly
  # like a single-catalogue root. Category drilling reuses the chips' old
  # `browse_category` event; scope enforcement lives in BrowseState for
  # both commands.
  # Back: a drilled category climbs the category chain (level_up); a
  # chosen catalogue's level climbs back to the catalogue list. Nil at
  # the root — nowhere further back — and at a SCOPED category's own
  # level, which is this popup's floor (the host said "this category";
  # a Back to a synthetic outline above it would loop the same tiles).
  # Rendered in the modal HEADER (Max, 2026-08-31: the header says
  # where you are, so the way back lives there too).
  defp back_target(assigns) do
    %{browse: browse, cat_tree: tree} = assigns

    cond do
      browse.category_uuid != nil and browse.category_uuid == assigns.scoped_root_category ->
        nil

      browse.category_uuid != nil ->
        # "" climbs to the popup root — which for a scoped popup IS the
        # scoped category's own level (the auto-drilled floor), not the
        # retired synthetic outline above it.
        case {level_up(tree, browse.category_uuid), assigns.scoped_root_category} do
          {"", floor} when is_binary(floor) -> {"browse_category", floor}
          {target, _} -> {"browse_category", target}
        end

      is_binary(browse.catalogue_uuid) ->
        {"browse_catalogue", ""}

      true ->
        nil
    end
  end

  attr(:id, :string, required: true)
  attr(:tree, :map, required: true)
  attr(:browse, :any, required: true)
  attr(:view, :string, required: true)
  attr(:target, :any, required: true)
  attr(:show_uncategorized, :boolean, required: true)

  @level_columns ["items"]

  defp subcategory_level(assigns) do
    tiles = level_entries(assigns.tree, assigns.browse)
    catalogues? = catalogues_level?(assigns.tree, assigns.browse)
    uncat_count = level_uncategorized(assigns.tree, assigns.browse)

    assigns =
      assigns
      |> assign(:tiles, tiles)
      |> assign(:catalogues?, catalogues?)
      |> assign(:tile_event, if(catalogues?, do: "browse_catalogue", else: "browse_category"))
      |> assign(:uncat?, assigns.show_uncategorized and (uncat_count || 0) > 0)
      |> assign(:uncat_count, uncat_count)
      |> assign(:photo_col?, Enum.any?(tiles, &Shared.featured_image_uuid/1))
      |> assign(:columns, @level_columns)

    ~H"""
    <div id={@id} class="flex flex-col gap-2 mb-4">
      <%!-- The way back lives in the modal HEADER now, beside the live
      context that names this level (Max, 2026-08-31). --%>
      <div :if={@tiles != [] or @uncat?}>
        <%!-- Only a drilled category level heads this block — a root's
        tiles need no heading (the pure-browser idiom; with the opt-in
        switcher its labels name the listing anyway). --%>
        <div
          :if={@browse.category_uuid}
          class="text-sm font-semibold text-base-content/70 mb-2"
        >
          {gettext("Subcategories")}
        </div>
        <div :if={@view == "card"} class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-3">
          <Shared.category_card
            :for={tile <- @tiles}
            category={tile}
            columns={@columns}
            count={Map.get(@tree.counts, tile.uuid, 0)}
            subcat_count={length(tile_children(@tree, @browse, tile.uuid))}
            has_subs={tile_children(@tree, @browse, tile.uuid) != []}
            phx_click={@tile_event}
            phx_target={@target}
          />
          <%!-- Uncategorized is a drill with no Category record — the
          shared tile takes the count directly. Offered on the level that
          OWNS the loose items (a single-catalogue root, or a chosen
          catalogue's level), hidden when the bucket is empty. --%>
          <Shared.uncategorized_card
            :if={@uncat?}
            count={@uncat_count}
            phx_click="browse_category"
            phx_target={@target}
          />
        </div>
        <%!-- The id lives on a wrapper: core's table_default drops :id
        in its classic (no items) mode. --%>
        <div :if={@view == "table"} id={"#{@id}-table"}>
          <.table_default size="sm" wrapper_class="overflow-x-auto shadow-none rounded-none">
            <.table_default_header>
              <.table_default_row>
                <.table_default_header_cell :if={@photo_col?} class="w-12 !pr-0 !py-1">
                </.table_default_header_cell>
                <.table_default_header_cell>{gettext("Name")}</.table_default_header_cell>
                <Shared.category_header_cells columns={@columns} />
              </.table_default_row>
            </.table_default_header>
            <.table_default_body>
              <.table_default_row :for={tile <- @tiles}>
                <%!-- The image enters the level exactly like the name
                (Max, 2026-08-31: "image and title... should be
                clickable to enter them"). --%>
                <.table_default_cell :if={@photo_col?} class="w-12 !pr-0 !py-1">
                  <button
                    type="button"
                    phx-click={@tile_event}
                    phx-value-uuid={tile.uuid}
                    phx-target={@target}
                    class="block cursor-pointer phx-click-loading:animate-pulse"
                    aria-label={tile.name}
                  >
                    <Shared.featured_thumb resource={tile} />
                  </button>
                </.table_default_cell>
                <.table_default_cell class="font-medium">
                  <div class="flex items-center gap-2 min-w-0">
                    <button
                      type="button"
                      phx-click={@tile_event}
                      phx-value-uuid={tile.uuid}
                      phx-target={@target}
                      class="link link-hover font-medium cursor-pointer phx-click-loading:animate-pulse"
                    >
                      {tile.name}
                    </button>
                    <span
                      :if={tile_children(@tree, @browse, tile.uuid) != []}
                      class="badge badge-ghost badge-xs"
                      title={gettext("Has subcategories")}
                    >
                      <span class="hero-rectangle-stack w-3 h-3"></span>
                    </span>
                  </div>
                </.table_default_cell>
                <Shared.category_body_cells
                  columns={@columns}
                  cat={tile}
                  child_counts={@tree.counts}
                />
              </.table_default_row>
              <.table_default_row :if={@uncat?}>
                <.table_default_cell :if={@photo_col?} class="w-12 !pr-0 !py-1">
                  <button
                    type="button"
                    phx-click="browse_category"
                    phx-value-uuid="__uncategorized__"
                    phx-target={@target}
                    class="cursor-pointer phx-click-loading:animate-pulse"
                    aria-label={gettext("Uncategorized")}
                  >
                    <span class="w-8 h-8 rounded bg-base-200 flex items-center justify-center">
                      <span class="hero-folder-open w-4 h-4 text-base-content/40"></span>
                    </span>
                  </button>
                </.table_default_cell>
                <.table_default_cell class="font-medium">
                  <button
                    type="button"
                    phx-click="browse_category"
                    phx-value-uuid="__uncategorized__"
                    phx-target={@target}
                    class="link link-hover font-medium cursor-pointer phx-click-loading:animate-pulse"
                  >
                    {gettext("Uncategorized")}
                  </button>
                </.table_default_cell>
                <.table_default_cell class="text-right tabular-nums">
                  {@uncat_count || 0}
                </.table_default_cell>
              </.table_default_row>
            </.table_default_body>
          </.table_default>
        </div>
      </div>
    </div>
    """
  end

  defp display_opts(assigns) do
    %{
      immediate: assigns[:immediate] || false,
      show_prices: Map.get(assigns, :show_prices, true),
      show_sku: Map.get(assigns, :show_sku, true),
      # The cart-count button + expandable review list. OFF by default
      # (boss, 2026-08-31): the qty-first default shows a number above 0
      # on every picked row, so the cart is opt-in chrome for hosts that
      # want a review list. Cancel/Confirm always stay.
      show_tray: Map.get(assigns, :show_tray, false),
      # The in-modal item details page (2026-08-30). ON by default per
      # Max, 2026-08-31 — inspecting before picking is the popup's
      # normal use. A client-facing embed that must not expose the
      # detail body (description, metadata, attached files) passes
      # false, the same opt-out story as show_prices/show_sku.
      show_item_details: Map.get(assigns, :show_item_details, true),
      # Click flavour + visible :qty is either-or by DEFAULT (checkbox
      # column, quantities in the tray, the qty cell read-only); this
      # opt-in restores the legacy checkmark+stepper pairing for hosts
      # that really want both (Max, 2026-08-31). Quantity mode ignores
      # it — the stepper is the selector there.
      inline_qty: Map.get(assigns, :inline_qty, false) == true,
      # The root Categories|Items (or Catalogues|Items) either-or,
      # OFF by default (Max, 2026-08-31): a root is just a level — it
      # lists its tiles, and items come from entering a folder or
      # searching. The switcher looked like the index's search-mode
      # control while doing something else entirely (both Max and the
      # panel's UX seat tripped over it), and its flat no-query list is
      # served better by search. Opt-in for hosts that want the flat
      # browse mode.
      root_switcher: Map.get(assigns, :root_switcher, false) == true,
      title: assigns[:title]
    }
  end

  # ── Fetching ─────────────────────────────────────────────────────────

  # Synchronous by design: LiveComponent events serialize, so there is no
  # stale-result race today. BrowseState still carries a generation, so
  # moving this into start_async later is a drop-in, not a redesign.
  defp run_fetch(socket, :noop), do: socket

  defp run_fetch(socket, {:fetch, _opts, gen} = effect) do
    # A tiles-only root (no switcher, no query, no drill) renders no item
    # block, so page 1 would be fetched only to be thrown away — the wart
    # the boss's #89 review recorded as the price of the instant Items
    # switch. No switch, no price: ingest an empty exhausted page and
    # keep the state machine's bookkeeping honest.
    if tiles_only_level?(socket.assigns) do
      %{browse: browse} = socket.assigns

      assign(socket,
        browse: BrowseState.ingest(browse, gen, [], 0),
        presented: %{},
        search_cat_hits: []
      )
    else
      run_item_fetch(socket, effect)
    end
  end

  defp tiles_only_level?(%{root_switcher: false, browse: browse} = assigns) do
    not searching?(browse) and is_nil(browse.category_uuid) and
      level_entries(assigns.cat_tree, browse) != []
  end

  defp tiles_only_level?(_assigns), do: false

  defp run_item_fetch(socket, {:fetch, opts, gen}) do
    %{browse: browse, locale: locale} = socket.assigns

    items = Catalogue.search_items(browse.search, opts)
    total = Catalogue.count_search_items(browse.search, opts)
    presented_page = Browse.present_items(items, locale)

    browse = BrowseState.ingest(browse, gen, presented_page, total)

    # `presented` gates card_click ("only items this component rendered"),
    # so it mirrors ingest/4's discipline: a fresh fetch (offset 0 — new
    # search, chip, or reset) replaces it rather than accreting pages from
    # every query this modal ever ran, and a stale gen (rejected by ingest,
    # so `browse.gen != gen`) contributes nothing — without that guard the
    # documented start_async migration would leak superseded pages in.
    # Load-more keeps accumulating, matching the grid.
    presented =
      if browse.gen == gen do
        base = if Keyword.get(opts, :offset, 0) == 0, do: %{}, else: socket.assigns.presented
        Enum.into(presented_page, base, fn item -> {item.uuid, item} end)
      else
        socket.assigns.presented
      end

    socket = assign(socket, browse: browse, presented: presented)

    # Only a FRESH fetch can have moved the question the category hits
    # answer: :load_more leaves search and level untouched, so paging a
    # long result list must not re-run the JSONB category search once
    # per scrolled page.
    if Keyword.get(opts, :offset, 0) == 0 do
      assign(socket, :search_cat_hits, search_category_hits(socket))
    else
      socket
    end
  end

  # Matching categories for the admin search's two-list surface (Max,
  # 2026-08-31: the popup search works like the admin's, items by
  # default): item results stay the primary list, category hits render
  # above as navigation. The same DB search the admin runs (every
  # translation, capped at @search_hit_cap like the admin's, the drilled
  # node's subtree when drilled) — but each hit must ALSO be in the
  # popup's category tree, so a scoped embed can never offer a category
  # outside its allow-list. Names and trails come from the tree, already
  # viewer-translated. The root's Items mode hides the hits at RENDER
  # (`visible_cat_hits/1`) — the mode toggle never refetches.
  @search_hit_cap 25

  defp search_category_hits(socket) do
    %{browse: browse, cat_tree: tree} = socket.assigns

    with true <- searching?(browse),
         true <- tree.index != %{},
         false <- browse.category_uuid == :uncategorized,
         uuids when is_list(uuids) and uuids != [] <-
           if(browse.catalogue_uuid,
             do: [browse.catalogue_uuid],
             else: browse.scope[:catalogue_uuids]
           ) do
      # One search per offered catalogue — narrowed to the chosen one
      # when the user drilled catalogue-first — capped like the admin's.
      uuids
      |> Enum.flat_map(fn catalogue_uuid ->
        Catalogue.search_categories(normalize_uuid(catalogue_uuid), browse.search,
          parent_uuid: browse.category_uuid
        )
      end)
      |> Enum.map(&to_string(&1.uuid))
      |> Enum.filter(&Map.has_key?(tree.index, &1))
      |> Enum.take(@search_hit_cap)
      |> Enum.map(fn uuid ->
        %{uuid: uuid, name: tree.index[uuid].name, trail: tree_trail(tree, uuid)}
      end)
    else
      _ -> []
    end
  rescue
    # Hits are navigation, not data — degrade like the tree build does.
    _ -> []
  end

  defp visible_cat_hits(assigns) do
    if is_nil(assigns.browse.category_uuid) and assigns.root_mode == "items",
      do: [],
      else: assigns.search_cat_hits
  end

  # "Doors / Fronts" — the hit's ancestors, root-first, so two
  # same-named subcategories stay distinguishable (the admin queries
  # them; the popup already holds the scoped tree in memory). Stops
  # naturally at the scope root: ancestors outside it are not in the
  # index.
  defp tree_trail(tree, uuid) do
    case tree_ancestors(tree, uuid, []) do
      [] -> nil
      names -> Enum.join(names, " / ")
    end
  end

  defp tree_ancestors(tree, uuid, acc) do
    with %{parent_uuid: parent} when not is_nil(parent) <- tree.index[uuid],
         parent = to_string(parent),
         %{} = cat <- tree.index[parent] do
      tree_ancestors(tree, parent, [cat.name | acc])
    else
      _ -> acc
    end
  end

  # ── Preselection hydration ───────────────────────────────────────────

  # The scope-exempt read: the tray must render whatever the host handed
  # in, so these uuids are fetched directly. Availability is then judged
  # against the scope so out-of-scope rows can be shown-but-excluded.
  # `list_items_by_uuids/2` is one query and already drops soft-deleted
  # rows, matching the fetch layer — a uuid that no longer resolves (deleted
  # or unknown) is dropped from the tray entirely.
  #
  # Hydrated quantities go through the same `clamp/2` as typed and stepped
  # ones — "all limits re-clamped server-side" covers the host's numbers
  # too, and an absurd host qty must not outlive mount. In `:single` mode
  # at most one entry survives (first by uuid, stable): the tray, the
  # confirm payload, and `select/2`'s replace-not-add all promise a single
  # pick, and a multi-entry `selected` must not be the one path around it.
  defp hydrate_preselection(selected, _scope, _locale, _limits, _mode) when selected == %{},
    do: %{}

  defp hydrate_preselection(selected, scope, locale, limits, mode) do
    expanded_categories = expand_scope_categories(scope)

    # Key hygiene (2026-08-31 sweep): a non-UUID key would raise
    # Ecto.Query.CastError out of the fetch and take the host LV down at
    # mount, and a raw 16-byte binary key queries fine but never matches
    # the string-keyed lookup below — the preselect silently vanished.
    # Normalize to canonical strings; garbage keys are "unresolvable"
    # and drop, exactly like a deleted uuid (documented behaviour).
    selected =
      selected
      |> Enum.flat_map(fn {uuid, qty} ->
        case Ecto.UUID.cast(uuid) do
          {:ok, canonical} -> [{canonical, qty}]
          :error -> []
        end
      end)
      |> Map.new()

    items_by_uuid =
      selected
      |> Map.keys()
      |> Catalogue.list_items_by_uuids()
      |> Map.new(&{to_string(&1.uuid), &1})

    selection =
      selected
      |> Enum.flat_map(fn {uuid, qty} ->
        uuid = to_string(uuid)

        case items_by_uuid[uuid] do
          nil ->
            []

          item ->
            [presented] = Browse.present_items([item], locale)

            [
              {uuid,
               %{
                 qty: clamp(to_decimal(qty), limits),
                 item: presented,
                 available: in_scope?(item, scope, expanded_categories)
               }}
            ]
        end
      end)
      |> Map.new()

    case {mode, map_size(selection)} do
      {:single, n} when n > 1 ->
        {uuid, entry} = Enum.min_by(selection, fn {uuid, _entry} -> uuid end)
        %{uuid => entry}

      _ ->
        selection
    end
  end

  # Mirrors every restriction `query_opts/1` sends to the fetch layer —
  # including `:only`, descendant-expanded `:category_uuids`, and the
  # deleted-parent joins — or a preselected row the browse itself could
  # never return would confirm as available.
  defp in_scope?(item, scope, expanded_categories) do
    parents_alive?(item) and
      allowed?(scope[:catalogue_uuids], item.catalogue_uuid) and
      category_in_scope?(expanded_categories, item.category_uuid) and
      allowed?(scope[:statuses], item.status) and
      only_ok?(scope[:only], item)
  end

  # The search joins exclude items under a soft-deleted catalogue or
  # category; `list_items_by_uuids/2` only filters the item's own status,
  # so the hydration path re-checks the parents it preloads. A NotLoaded
  # association has no :status key and falls through to true — absent
  # evidence is not exclusion.
  defp parents_alive?(item) do
    not match?(%{status: "deleted"}, item.catalogue) and
      not match?(%{status: "deleted"}, item.category)
  end

  defp allowed?(nil, _value), do: true
  defp allowed?([], _value), do: true
  defp allowed?(_list, nil), do: false
  defp allowed?(list, value), do: normalize_uuid(value) in Enum.map(list, &normalize_uuid/1)

  defp category_in_scope?(nil, _value), do: true
  defp category_in_scope?([], _value), do: true
  defp category_in_scope?(_expanded, nil), do: false

  defp category_in_scope?(expanded, value) do
    MapSet.member?(expanded, normalize_uuid(value))
  end

  # Same expansion Search.search_items/2 applies (Tree.subtree_uuids_for/1,
  # skipped when the host passed include_descendants: false).
  defp expand_scope_categories(scope) do
    case scope[:category_uuids] do
      nil ->
        nil

      [] ->
        []

      uuids ->
        raw =
          if scope[:include_descendants] == false,
            do: uuids,
            else: Tree.subtree_uuids_for(uuids)

        MapSet.new(Enum.map(raw, &normalize_uuid/1))
    end
  end

  defp only_ok?(:uncategorized_only, item), do: is_nil(item.category_uuid)
  defp only_ok?(:categorized_only, item), do: not is_nil(item.category_uuid)
  defp only_ok?(_other, _item), do: true

  # Presence-guarded ("" never wins) and rescue-safe via the canonical
  # helper — the ad-hoc copies of this chain let a stored blank override
  # blank the display (external review, 2026-08-31).
  defp translated_name(record, locale), do: Catalogue.translated_name(record, locale)

  # The scoped record IS the modal's subject, so the header shows it:
  # image + name + description (2026-08-30). The category wins over the
  # catalogue when the scope names exactly one of each — more specific is
  # what the user is looking at. Header chrome, not data: any failure
  # (unknown uuid, unloadable image, multi-entry scopes) resolves to nil
  # and the plain title renders instead.
  defp resolve_header_context(scope, locale) do
    scope = if is_map(scope), do: scope, else: Map.new(scope)

    record =
      case {scope[:category_uuids], scope[:catalogue_uuids]} do
        {[uuid], _} -> Catalogue.get_category(normalize_uuid(uuid))
        {_, [uuid]} -> Catalogue.get_catalogue(normalize_uuid(uuid))
        _ -> nil
      end

    case record do
      nil ->
        nil

      # A scope naming a soft-deleted record browses an empty list (the
      # search joins exclude it) — a header proudly naming it over that
      # emptiness reads as a bug, so fall back to the plain title.
      %{status: "deleted"} ->
        nil

      record ->
        %{
          name: translated_name(record, locale),
          description: Catalogue.translated_description(record, locale),
          image_url: Browse.featured_thumb_url(record)
        }
    end
  rescue
    _ -> nil
  end

  # ── Events: browsing ─────────────────────────────────────────────────

  @impl true
  def handle_event("set_view", %{"mode" => mode}, socket) when mode in ["table", "card"] do
    {:noreply, socket |> assign(:view, mode) |> persist_selector(%{view: mode})}
  end

  # The root's Categories | Items switcher (admin semantics). Pure
  # presentation: the fetch and the selection are untouched, so switching
  # never loses picks.
  def handle_event("set_root_mode", %{"mode" => mode}, socket)
      when mode in ["categories", "items"] do
    # Without the opt-in switcher there is no legal way to leave
    # "categories" — a crafted flip would reveal an item block whose
    # fetch was skipped (empty, dead). Refused like every other event
    # the UI never offered.
    if socket.assigns.root_switcher do
      {:noreply, assign(socket, :root_mode, mode)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_column", %{"col" => raw}, socket) do
    granted = socket.assigns.columns
    visible = socket.assigns.visible_columns
    col = Enum.find(granted, &(to_string(&1) == raw))

    cond do
      # Outside the host's pre-approved set, or locked: refused — the
      # dropdown only offers legal rows, but the server is the boundary.
      is_nil(col) or col in locked_columns(socket.assigns) ->
        {:noreply, socket}

      col in visible ->
        # The last visible identity column stays — a list where nothing
        # names the items is not a picker.
        if last_identity?(col, visible) do
          {:noreply, socket}
        else
          {:noreply, put_visible_columns(socket, visible -- [col])}
        end

      true ->
        # Re-show in the GRANTED order, not appended at the end.
        shown = [col | visible]
        {:noreply, put_visible_columns(socket, Enum.filter(granted, &(&1 in shown)))}
    end
  end

  # Catalogue-first drill on multi-catalogue scopes: "" climbs back to
  # the catalogue list. Scope enforcement is BrowseState's — a uuid
  # outside scope.catalogue_uuids is a :noop.
  def handle_event("browse_catalogue", %{"uuid" => uuid}, socket) do
    value = if uuid == "", do: nil, else: uuid
    {browse, effect} = BrowseState.command(socket.assigns.browse, {:set_catalogue, value})
    {:noreply, socket |> assign(browse: browse) |> run_fetch(effect)}
  end

  def handle_event("browse_search", %{"search" => q}, socket) do
    {browse, effect} = BrowseState.command(socket.assigns.browse, {:search, q})
    {:noreply, socket |> assign(browse: browse) |> run_fetch(effect)}
  end

  # A category hit from the search results: open that category's page
  # with the search CLEARED — the admin's "a hit opens the chapter's
  # content" semantics. Scope enforcement is set_category's as always;
  # a refused drill (crafted/stale uuid) falls back to just clearing
  # the search so state and list never diverge.
  def handle_event("open_category_hit", %{"uuid" => uuid}, socket) do
    {browse, cleared} = BrowseState.command(socket.assigns.browse, {:search, ""})

    {browse, effect} =
      if cross_catalogue_category?(socket.assigns.cat_tree, browse, uuid) do
        {browse, cleared}
      else
        case BrowseState.command(browse, {:set_category, uuid}) do
          {browse, :noop} -> {browse, cleared}
          drilled -> drilled
        end
      end

    {:noreply, socket |> assign(browse: browse) |> run_fetch(effect)}
  end

  def handle_event("browse_category", %{"uuid" => uuid}, socket) do
    value =
      case uuid do
        "" -> nil
        "__uncategorized__" -> :uncategorized
        other -> other
      end

    if cross_catalogue_category?(socket.assigns.cat_tree, socket.assigns.browse, value) do
      {:noreply, socket}
    else
      cmd = {:set_category, value}
      {browse, effect} = BrowseState.command(socket.assigns.browse, cmd)
      {:noreply, socket |> assign(browse: browse) |> run_fetch(effect)}
    end
  end

  def handle_event("load_more", _params, socket) do
    {browse, effect} = BrowseState.command(socket.assigns.browse, :load_more)
    {:noreply, socket |> assign(browse: browse) |> run_fetch(effect)}
  end

  # ── Events: item details page ────────────────────────────────────────

  def handle_event("show_detail", %{"uuid" => uuid}, socket) do
    # Same rendered-uuid rule as selection: details open only for rows
    # this component itself rendered, or AVAILABLE tray entries. An
    # unavailable preselect is scope-exempt by design — the tray may
    # show its name — but its detail body (description, metadata, signed
    # file URLs) is exactly what the host's scope excludes, so a crafted
    # push for one must no-op (external review, 2026-08-31). Refused
    # outright when the host didn't opt in.
    known? =
      is_map(socket.assigns.presented[uuid]) or
        match?(%{available: true}, socket.assigns.selection[uuid])

    if socket.assigns.show_item_details and known? do
      {:noreply, open_detail(socket, uuid)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_detail", _params, socket),
    do: {:noreply, assign(socket, detail: nil)}

  # ── Events: selection ────────────────────────────────────────────────

  def handle_event("card_click", %{"uuid" => uuid}, socket) do
    selection = socket.assigns.selection

    cond do
      # Quantity-first embeds have no click-selection: the stepper IS the
      # selector. The markup renders nothing clickable; a crafted click is
      # refused here for the same reason.
      socket.assigns.selection_mode == "quantity" ->
        {:noreply, socket}

      Map.has_key?(selection, uuid) ->
        {:noreply, deselect(socket, uuid)}

      # Only items this component itself rendered are selectable — an
      # event with a foreign uuid (crafted, or stale DOM) is refused.
      item = socket.assigns.presented[uuid] ->
        {:noreply, select(socket, item)}

      true ->
        {:noreply, socket}
    end
  end

  # Live update from the native number control (spinner arrows, settled
  # typing — debounced): apply what parses, silently ignore what doesn't.
  # The user may still be typing ("2." on the way to "2.5"), so this path
  # NEVER resets the input — no revision bump, no deselect-on-garbage.
  # qty_commit (blur/Enter) stays the authoritative commit that may reset.
  # Same presented/selection gates as qty_commit: crafted changes with
  # foreign uuids die here without touching state.
  def handle_event("qty_change", %{"uuid" => uuid, "value" => raw}, socket) do
    cond do
      Map.has_key?(socket.assigns.selection, uuid) ->
        {:noreply, change_selected_qty(socket, uuid, raw)}

      socket.assigns.selection_mode == "quantity" and is_map(socket.assigns.presented[uuid]) ->
        {:noreply, change_first_qty(socket, uuid, raw)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_event("qty_commit", %{"uuid" => uuid, "value" => raw}, socket) do
    # Only rows that are selected — or, quantity-first, RENDERED — get any
    # state at all: without the gate, crafted commits with unique foreign
    # uuids grow `drafts` without bound (put_qty/3 would no-op, but only
    # after the revision bump already stored a key).
    cond do
      Map.has_key?(socket.assigns.selection, uuid) ->
        {:noreply, commit_qty(socket, uuid, raw)}

      socket.assigns.selection_mode == "quantity" and is_map(socket.assigns.presented[uuid]) ->
        {:noreply, commit_first_qty(socket, uuid, raw)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_event("remove_pick", %{"uuid" => uuid}, socket),
    do: {:noreply, deselect(socket, uuid)}

  def handle_event("toggle_tray", _params, socket) do
    # No-op when the tray is disabled: the render gate already hides it,
    # this just keeps a crafted toggle from flipping invisible state.
    if socket.assigns.show_tray,
      do: {:noreply, assign(socket, tray_open: !socket.assigns.tray_open)},
      else: {:noreply, socket}
  end

  # ── Events: closing ──────────────────────────────────────────────────

  def handle_event("confirm", _params, socket) do
    # Same predicate that disables the button: a crafted confirm with
    # nothing confirmable must not deliver `{picks: []}` to a host that
    # trusts the button state. The modal simply stays open.
    # The `confirmed` latch closes the double-click window (2026-08-31
    # sweep): the second queued confirm event can reach this handler
    # before the host processes the close message and unmounts us —
    # without the latch the host received `{:items_selected, …}` twice
    # and an order sheet wrote its lines twice.
    if confirmable_selection?(socket.assigns.selection) and not socket.assigns.confirmed do
      send(self(), {:items_selected, confirm_payload(socket.assigns)})
      send(self(), {:item_selector_closed, %{id: socket.assigns.id}})
      {:noreply, assign(socket, confirmed: true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel", _params, socket) do
    if socket.assigns.detail do
      # Esc with the details popup stacked on top closes only the TOP
      # popup (Max, 2026-08-31). Core's PkDialog now swallows the outer
      # dialog's grouped cancel client-side; this is the server-side belt
      # for hosts on an older core — their outer dialog closed natively,
      # so keeping the selector assigned makes the hook's next sync
      # reopen it with search, scroll and selection intact.
      {:noreply, assign(socket, detail: nil)}
    else
      send(self(), {:item_selector_closed, %{id: socket.assigns.id}})
      {:noreply, socket}
    end
  end

  # A crafted payload with missing keys must degrade to a no-op, not a
  # FunctionClauseError that takes the whole LiveView down.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # Selected row, live path: apply what parses, ignore what doesn't. In
  # quantity mode zero deselects whatever qty_min says (see commit_qty).
  defp change_selected_qty(socket, uuid, raw) do
    if socket.assigns.selection_mode == "quantity" and zero_qty?(raw) do
      deselect(socket, uuid)
    else
      case parse_qty(raw, socket.assigns) do
        {:ok, qty} -> put_qty(socket, uuid, qty)
        :error -> socket
      end
    end
  end

  # Quantity-first, unselected row: a positive live value IS the
  # selection, exactly like commit_first_qty but without the revision
  # machinery — and WITHOUT the immediate notify (2026-08-31 sweep):
  # qty_commit is the authoritative commit, and confirming the whole
  # modal off a debounced mid-typing value closed it at qty 1 while the
  # user was still typing 15. Selection applies live; immediate mode
  # confirms on blur/Enter.
  defp change_first_qty(socket, uuid, raw) do
    case parse_qty(raw, socket.assigns) do
      {:ok, qty} ->
        if Decimal.gt?(qty, 0) do
          socket
          |> select_entry(socket.assigns.presented[uuid])
          |> put_qty(uuid, qty)
        else
          socket
        end

      :error ->
        socket
    end
  end

  # Selected row: bump the per-row revision so the input's id changes —
  # morphdom will not reset typed garbage (or "01") when the value attr is
  # unchanged — then re-clamp the parse.
  defp commit_qty(socket, uuid, raw) do
    socket = bump_qty_rev(socket, uuid)

    # Quantity-first: zero IS the unselected state, whatever qty_min says —
    # the native control's arrows stop at min="0" in this mode, so an
    # arrowed-or-typed zero must remove the line even when qty_min > 0
    # (parse_qty would reject it as below-minimum and strand the row).
    if socket.assigns.selection_mode == "quantity" and zero_qty?(raw) do
      deselect(socket, uuid)
    else
      case parse_qty(raw, socket.assigns) do
        {:ok, qty} ->
          # maybe_notify_immediate/1 self-gates on single+immediate and
          # the confirm latch — a no-op everywhere else. It sits on the
          # COMMIT path because the live path stopped notifying
          # (2026-08-31 sweep: a debounced mid-typing value must not
          # confirm-and-close the modal).
          socket |> put_qty(uuid, qty) |> maybe_notify_immediate()

        :error ->
          socket
      end
    end
  end

  # Quantity-first, unselected row: a typed POSITIVE quantity is the
  # selection ("0" stays unselected — in this mode zero IS the unselected
  # state, whatever qty_min says).
  defp commit_first_qty(socket, uuid, raw) do
    socket = bump_qty_rev(socket, uuid)

    case parse_qty(raw, socket.assigns) do
      {:ok, qty} ->
        if Decimal.gt?(qty, 0) do
          socket
          |> select_entry(socket.assigns.presented[uuid])
          |> put_qty(uuid, qty)
          |> maybe_notify_immediate()
        else
          socket
        end

      :error ->
        socket
    end
  end

  # ── Selection mechanics ──────────────────────────────────────────────

  defp select(socket, item) do
    socket |> select_entry(item) |> maybe_notify_immediate()
  end

  defp select_entry(socket, item) do
    entry = %{qty: clamp(item.default_qty, socket.assigns), item: item, available: true}

    case socket.assigns.mode do
      # Single mode replaces the previous pick — the map never grows.
      :single -> assign(socket, selection: %{item.uuid => entry})
      _ -> assign(socket, selection: Map.put(socket.assigns.selection, item.uuid, entry))
    end
  end

  # Split from select_entry/2 so quantity-first commits can put the TYPED
  # quantity in place first — notifying inside the entry placement sent the
  # default quantity and dropped what the user typed. Shares the confirm
  # latch: a second click racing the host's unmount must not double-send.
  defp maybe_notify_immediate(socket) do
    if socket.assigns.mode == :single and socket.assigns.immediate and
         not socket.assigns.confirmed do
      send(self(), {:items_selected, confirm_payload(socket.assigns)})
      send(self(), {:item_selector_closed, %{id: socket.assigns.id}})
      assign(socket, confirmed: true)
    else
      socket
    end
  end

  defp deselect(socket, uuid) do
    assign(socket,
      selection: Map.delete(socket.assigns.selection, uuid),
      drafts: Map.delete(socket.assigns.drafts, uuid)
    )
  end

  # One query, soft-deleted rows already excluded. On a miss, the caller
  # picks the behaviour: `:keep` (show_detail — an item deleted between
  # render and click quietly stays on the list, detail was nil anyway)
  # or `:close` (the grant-change rebuild — a detail materialized under
  # OLD grants must not survive a failed refresh; 2026-08-31 sweep).
  defp open_detail(socket, uuid, on_miss \\ :keep) do
    case Catalogue.list_items_by_uuids([uuid]) do
      [item] ->
        locale = socket.assigns.locale

        assign(socket,
          detail: %{
            uuid: uuid,
            name: ProductCard.resolve_name(item, locale),
            images: ProductCard.resolve_images(item),
            # The detail page honours the same display grants as the list —
            # the flags AND the columns contract: a host that granted
            # columns without :price (the client-safe embed) must not have
            # the price reappear one thumbnail-click away (2026-08-31
            # sweep). Granted columns, not visible ones: visibility is the
            # viewer's toggle, the grant is the host's contract.
            fields:
              ProductCard.build_fields(item, locale,
                include_price: socket.assigns.show_prices and :price in socket.assigns.columns,
                include_sku: socket.assigns.show_sku and :sku in socket.assigns.columns
              ),
            files: ProductCard.resolve_files(item)
          }
        )

      _ ->
        if on_miss == :close, do: assign(socket, detail: nil), else: socket
    end
  end

  # A lenient zero probe for the quantity-first paths: parse_qty compares
  # against qty_min, but in that mode zero is the UNSELECTED state and must
  # be recognisable whatever the minimum is. Only FINITE non-positives
  # qualify: Decimal.parse accepts "NaN" and "Infinity" as full matches,
  # and neither compares greater-than-zero — without the guards a crafted
  # NaN would deselect a row, mutating state from garbage input (external
  # review, 2026-08-31).
  defp zero_qty?(raw) when is_binary(raw) do
    case Decimal.parse(String.trim(String.replace(raw, ",", "."))) do
      {qty, ""} ->
        not Decimal.nan?(qty) and not Decimal.inf?(qty) and not Decimal.gt?(qty, 0)

      _ ->
        false
    end
  end

  defp zero_qty?(_), do: false

  defp put_qty(socket, uuid, qty) do
    case socket.assigns.selection[uuid] do
      nil ->
        socket

      entry ->
        qty = clamp(qty, socket.assigns)
        assign(socket, selection: Map.put(socket.assigns.selection, uuid, %{entry | qty: qty}))
    end
  end

  defp bump_qty_rev(socket, uuid) do
    update(socket, :drafts, fn drafts ->
      Map.update(drafts, uuid, 1, &(&1 + 1))
    end)
  end

  # A hard ceiling even when the host sets no qty_max: Decimal.parse
  # accepts "1e1000000" as a full match, and an absurd exponent is a
  # process-DoS the moment it hits multiplication.
  # Quantities arrive from the client and are clamped here, not trusted
  # from input attributes: min, max, precision AND the absolute ceiling are
  # all re-enforced. The ceiling lives here (not only in parse_qty/2) so
  # every inlet — typed, stepped, hydrated — is capped: a held/scripted
  # plus button walks past any softer bound one event at a time.
  defp clamp(qty, %{qty_min: min, qty_max: max, qty_precision: precision}) do
    qty
    |> Decimal.round(precision)
    |> Decimal.max(min)
    |> Decimal.min(@qty_ceiling)
    |> then(fn q -> if max, do: Decimal.min(q, max), else: q end)
  end

  defp parse_qty(raw, assigns) when is_binary(raw) do
    # ru/et keyboards produce a decimal comma; Decimal.parse wants a dot.
    # Plain digits only — exponent forms are rejected before parse.
    # Below-minimum input is rejected (field reverts) rather than silently
    # clamped up; with `qty_min: 0` that correctly admits a typed "0",
    # which the stepper's minus button could already reach.
    normalized = raw |> String.trim() |> String.replace(",", ".")

    with true <- Regex.match?(~r/^\d{1,12}(\.\d{1,6})?$/, normalized),
         {qty, ""} <- Decimal.parse(normalized),
         false <- Decimal.lt?(qty, assigns.qty_min) do
      {:ok, clamp(qty, assigns)}
    else
      _ -> :error
    end
  end

  defp parse_qty(_, _), do: :error

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)

  defp to_decimal(n) when is_binary(n) do
    case Decimal.parse(String.trim(n)) do
      {d, ""} -> d
      _ -> raise ArgumentError, "not a quantity: #{inspect(n)}"
    end
  end

  # Host-contract violations raise DESCRIBED errors everywhere else in
  # initialize/2 — an atom or nil quantity in `selected`/`qty_min` must
  # not surface as a bare FunctionClauseError (2026-08-31 sweep).
  defp to_decimal(other) do
    raise ArgumentError,
          "not a quantity: #{inspect(other)} — ItemSelectorModal quantities " <>
            "must be Decimals, integers, floats or numeric strings"
  end

  # ── Confirm payload ──────────────────────────────────────────────────

  defp confirm_payload(assigns) do
    picks =
      assigns.selection
      # An unavailable row (preselected, now outside scope) is shown in
      # the tray but must never reach the host as a pick — the host's
      # scope said no.
      |> Enum.filter(fn {_uuid, entry} -> entry.available end)
      |> Enum.sort_by(fn {_uuid, entry} -> entry.item.name || "" end)
      |> Enum.map(fn {uuid, %{qty: qty, item: item}} ->
        %{
          uuid: uuid,
          qty: qty,
          unit: item.unit,
          name: item.name,
          sku: item.sku,
          price: item.price,
          line_total: item.price && Decimal.mult(item.price, qty),
          # Without this a percent/computed fee pick arrived as
          # price: nil, line_total: nil — indistinguishable from a
          # free item (external review, 2026-08-31).
          fee_note: Map.get(item, :fee_note),
          photo_url: item.photo_url
        }
      end)

    %{id: assigns.id, mode: assigns.mode, picks: picks}
  end

  # ── Render helpers ───────────────────────────────────────────────────

  defp qty_display(assigns, uuid) do
    case assigns.selection[uuid] do
      nil -> ""
      %{qty: qty} -> format_qty(qty)
    end
  end

  # Either-or (2026-08-31): the checkbox column renders only when the
  # popup shows no :qty column — with a quantity input on every row, a
  # number above zero already reads "selected", and a checked box next
  # to it said the same thing twice.
  #
  # Click flavour with a visible :qty: the leftmost checkbox is the ONE
  # selected signal (Max, 2026-08-31: "if there is a checkmark then no
  # need for a number... the check should be in the most left column") —
  # only the explicit inline_qty opt-in trades it for the legacy
  # stepper-on-selected pairing.
  defp checkbox?(assigns) do
    assigns.selection_mode != "quantity" and
      not (assigns.inline_qty and :qty in assigns.visible_columns)
  end

  # Whether a rendered row/card shows its stepper. Quantity-first mode:
  # EVERY rendered row (rendered means in-scope by construction, and the
  # stepper at 0 IS the selector). Click mode: only under the inline_qty
  # opt-in, on selected available rows — by default the checkmark is the
  # signal and quantities live in the tray (the qty cell shows the picked
  # amount read-only).
  defp stepper?(assigns, uuid) do
    :qty in assigns.visible_columns and
      case assigns.selection[uuid] do
        %{available: available} ->
          available and (assigns.selection_mode == "quantity" or assigns.inline_qty)

        nil ->
          assigns.selection_mode == "quantity"
      end
  end

  # In quantity-first mode an unselected row's stepper reads 0 — zero is
  # the unselected state there, whatever qty_min says.
  defp qty_display_or_zero(assigns, uuid) do
    case qty_display(assigns, uuid) do
      "" -> "0"
      qty -> qty
    end
  end

  # See "qty_commit" — part of each stepper input's id, so bumping it
  # recreates the input and discards rejected garbage.
  defp qty_rev(assigns, uuid), do: assigns.drafts[uuid] || 0

  # The detail row's unit, read from what the component already holds —
  # the presented page (usual) or a tray entry (a preselect not on the
  # current page).
  defp detail_unit(%{presented: presented, selection: selection, detail: %{uuid: uuid}}) do
    case presented[uuid] || (selection[uuid] && selection[uuid].item) do
      %{unit: unit} -> unit
      _ -> nil
    end
  end

  # min/max attrs for the native number control: the down arrow stops at
  # the mode's floor — zero in quantity-first (zero IS deselection there),
  # the host's minimum otherwise. Shapes the arrows only; every limit is
  # still re-clamped server-side.
  defp qty_input_min(assigns) do
    if assigns.selection_mode == "quantity", do: "0", else: format_qty(assigns.qty_min)
  end

  defp qty_input_max(assigns) do
    assigns.qty_max && format_qty(assigns.qty_max)
  end

  defp format_qty(%Decimal{} = qty), do: Decimal.to_string(Decimal.normalize(qty), :normal)

  defp selection_count(selection), do: map_size(selection)

  defp confirmable_selection?(selection), do: confirmable_count(selection) > 0

  # With the cart off by default there was no running tally anywhere —
  # the Confirm button carries it (QoL sweep, 2026-08-31).
  defp confirmable_count(selection),
    do: Enum.count(selection, fn {_uuid, entry} -> entry.available end)

  defp selection_total(selection) do
    selection
    |> Enum.filter(fn {_u, e} -> e.available and e.item.price end)
    |> Enum.reduce(Decimal.new(0), fn {_u, e}, acc ->
      Decimal.add(acc, Decimal.mult(e.item.price, e.qty))
    end)
  end

  defp any_priced?(selection),
    do: Enum.any?(selection, fn {_u, e} -> e.available and e.item.price end)

  defp modal_title(nil), do: gettext("Select items")
  defp modal_title(title), do: title

  # At the root the host's explicit title keeps winning (the 2026-08-30
  # contract); a DRILLED level names itself — that is the whole point of
  # the live header.
  defp header_title(ctx, back, title) do
    cond do
      back && ctx && ctx.name -> ctx.name
      ctx -> title || ctx.name || modal_title(nil)
      true -> modal_title(title)
    end
  end

  # What the header names RIGHT NOW (Max, 2026-08-31: "use the header
  # to show where you are"): the drilled category, the Uncategorized
  # bucket, the chosen catalogue — falling back to the host-scoped
  # record from init when nothing is drilled. Records come from the
  # tree already in memory, so navigating costs no extra queries.
  defp live_header_context(assigns) do
    %{browse: browse, cat_tree: tree} = assigns

    cond do
      browse.category_uuid == :uncategorized ->
        %{name: gettext("Uncategorized"), description: nil, image_url: nil}

      is_binary(browse.category_uuid) ->
        record_header(tree.index[browse.category_uuid])

      is_binary(browse.catalogue_uuid) ->
        record_header(Enum.find(tree[:catalogues] || [], &(&1.uuid == browse.catalogue_uuid)))

      true ->
        assigns.header_context
    end
  end

  # Tree records carry viewer-translated names already; description and
  # thumb ride the same record. Chrome, not data — any surprise shape
  # degrades to the plain title, like resolve_header_context/2.
  defp record_header(nil), do: nil

  defp record_header(record) do
    %{
      name: record.name,
      description: Map.get(record, :description),
      image_url: Browse.featured_thumb_url(record)
    }
  rescue
    _ -> nil
  end

  # The table renders off the visible columns filtered by the LIVE
  # display flags, exactly as the card branch gates its price/SKU — so a
  # host revoking show_prices mid-open drops the table's price column
  # too, not only the cards' (2026-08-31 sweep). Grants stay init-time;
  # the flags are the cosmetic-live layer.
  defp effective_columns(assigns) do
    Enum.reject(assigns.visible_columns, fn
      :price -> not assigns.show_prices
      :base_price -> not assigns.show_prices
      :sku -> not assigns.show_sku
      _ -> false
    end)
  end

  # ── Render ───────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    # Row-invariant values, computed once per render instead of once per
    # row × call site (2026-08-31 sweep).
    assigns =
      assigns
      |> assign(:eff_columns, effective_columns(assigns))
      |> assign(:cbx, checkbox?(assigns))
      |> assign(:qmin, qty_input_min(assigns))
      |> assign(:qmax, qty_input_max(assigns))
      # The instant-highlight hook's accept-set inputs: the SERVER's
      # selection floor (qmin is "0" in quantity mode so the arrows can
      # reach deselect) and whether a typed 0 previews as deselected.
      |> assign(:qfloor, format_qty(assigns.qty_min))
      |> assign(:qzero_desel, assigns.selection_mode == "quantity")

    ~H"""
    <div id={@id}>
      <%!-- max_width caps at 4xl in core Modal; the responsive variants in
      `class` land AFTER the width class in its class list, widening the
      box where the viewport has room instead of forcing the table to
      scroll sideways next to empty margin. --%>
      <.modal
        show={true}
        id={"#{@id}-dialog"}
        on_close="cancel"
        max_width="4xl"
        class="xl:max-w-6xl 2xl:max-w-7xl"
        max_height="85vh"
      >
        <:title>
          <%!-- Context header, LIVE since 2026-08-31 (Max: "use the header
          to show where you are"): it names the level being browsed — the
          drilled category or chosen catalogue — falling back to the
          host-scoped record (2026-08-30) and then the plain title.
          context_header={false} keeps it static. The way back lives here
          too, as Back (Max: "the up button should be back instead"). --%>
          <% ctx = if @context_header?, do: live_header_context(assigns), else: @header_context %>
          <% back = if @context_header?, do: back_target(assigns) %>
          <div class="flex items-center gap-3 min-w-0">
            <button
              :if={back}
              type="button"
              id={"#{@id}-back"}
              class="btn btn-ghost btn-sm btn-circle shrink-0 phx-click-loading:animate-pulse"
              phx-click={elem(back, 0)}
              phx-value-uuid={elem(back, 1)}
              phx-target={@myself}
              aria-label={gettext("Back")}
              title={gettext("Back")}
            >
              <span class="hero-arrow-left w-5 h-5"></span>
            </button>
            <img
              :if={ctx && ctx.image_url}
              src={ctx.image_url}
              alt=""
              class="w-12 h-12 rounded-lg object-cover bg-base-200 shrink-0"
            />
            <div class="min-w-0">
              <div class="truncate">{header_title(ctx, back, @title)}</div>
              <div
                :if={ctx && ctx.description}
                class="text-sm font-normal text-base-content/60 truncate"
              >
                {ctx.description}
              </div>
            </div>
          </div>
        </:title>

        <div class="flex flex-col gap-3">
          <%!-- The browse region: search, chips, results. The item-details
          popup stacks OVER the whole selector as its own dialog (boss,
          2026-08-31), so nothing here is touched while it is open. --%>
          <div class="flex flex-col gap-3">
          <%!-- Header: search + chips. --%>
          <%!-- phx-submit is load-bearing: a phx-change form WITHOUT it is
          treated by LiveView's client as an external form — Enter would
          run a NATIVE submit (full page navigation) and destroy the modal
          and every pick in it. Routing submit at the same handler makes
          Enter a plain re-search. --%>
          <div class="flex items-center gap-2">
            <form
              id={"#{@id}-search-form"}
              class="flex-1"
              phx-change="browse_search"
              phx-submit="browse_search"
              phx-target={@myself}
            >
              <label class="input flex items-center gap-2 w-full">
                <span class="hero-magnifying-glass w-4 h-4 opacity-60"></span>
                <%!-- autofocus: a freshly opened native dialog focuses its
                first [autofocus] element — without one, focus lands on the
                dialog itself and the first keystrokes go nowhere. --%>
                <input
                  id={"#{@id}-search"}
                  type="text"
                  name="search"
                  value={@browse.search}
                  placeholder={gettext("Search items…")}
                  phx-debounce="250"
                  autocomplete="off"
                  autofocus
                  class="grow phx-change-loading:animate-pulse"
                />
                <button
                  :if={@browse.search != ""}
                  type="button"
                  class="btn btn-ghost btn-xs btn-circle"
                  phx-click="browse_search"
                  phx-value-search=""
                  phx-target={@myself}
                  aria-label={gettext("Clear")}
                  title={gettext("Clear")}
                >
                  <span class="hero-x-mark w-4 h-4"></span>
                </button>
              </label>
            </form>
            <%!-- What the root LISTS — the admin page's switcher, same
            either-or: the category outline, or every in-scope item as
            one flat list. Only at a root that has categories; drilled
            levels show both sections and a search always shows results. --%>
            <%!-- Opt-in only (root_switcher) — see display_opts/1. Its
            aria-label says Browse, not Search: it flips what the LEVEL
            lists, which is exactly the confusion that demoted it. --%>
            <div
              :if={@root_switcher and root_mode_gate?(assigns)}
              id={"#{@id}-root-mode"}
              class="join"
              role="group"
              aria-label={gettext("Browse")}
            >
              <button
                type="button"
                phx-click="set_root_mode"
                phx-value-mode="categories"
                phx-target={@myself}
                class={[
                  "btn btn-sm join-item phx-click-loading:animate-pulse",
                  @root_mode == "categories" && "btn-active"
                ]}
              >
                {if catalogues_level?(@cat_tree, @browse),
                  do: gettext("Catalogues"),
                  else: gettext("Categories")}
              </button>
              <button
                type="button"
                phx-click="set_root_mode"
                phx-value-mode="items"
                phx-target={@myself}
                class={[
                  "btn btn-sm join-item phx-click-loading:animate-pulse",
                  @root_mode == "items" && "btn-active"
                ]}
              >
                {gettext("Items")}
              </button>
            </div>
            <.column_toggle
              :if={@view == "table"}
              id={"#{@id}-column-toggle"}
              columns={@columns -- locked_columns(assigns)}
              visible={@visible_columns}
              target={@myself}
            />
            <.view_toggle
              id={"#{@id}-view-toggle"}
              modes={[
                %{mode: "table", icon: "hero-bars-3", label: gettext("List view")},
                %{mode: "card", icon: "hero-squares-2x2", label: gettext("Card view")}
              ]}
              current={@view}
              target={@myself}
            />
          </div>

          <%!-- The scrollable results region: ONE data path (@browse.items),
          two renderers. Only the active view's branch is server-rendered —
          both hidden in the DOM would duplicate qty-form ids. The level
          navigation (admin-style subcategory tiles, 2026-08-31 — replaces
          the flat chip strip) scrolls WITH the items, admin-page style. --%>
          <div
            id={"#{@id}-scroll"}
            class="overflow-y-auto min-h-[16rem] max-h-[48vh] pr-1"
            phx-hook=".ScrollTop"
            data-scroll-key={"#{@browse.catalogue_uuid}|#{@browse.category_uuid}|#{@browse.search}|#{@root_mode}|#{@view}"}
          >
            <%!-- A drill (catalogue or category), search, mode or view change
            lands the user on a NEW list — carrying the old scroll offset
            over showed its middle. Load-more keeps the offset (the key
            does not change). --%>
            <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollTop">
              export default {
                mounted() { this.key = this.el.dataset.scrollKey },
                updated() {
                  if (this.el.dataset.scrollKey !== this.key) {
                    this.key = this.el.dataset.scrollKey
                    this.el.scrollTop = 0
                  }
                }
              }
            </script>
            <.subcategory_level
              :if={show_categories_block?(assigns)}
              id={"#{@id}-levelnav"}
              tree={@cat_tree}
              browse={@browse}
              view={@view}
              target={@myself}
              show_uncategorized={offer_uncategorized?(@browse.scope)}
            />
            <%!-- The admin pages' section separation: on a drilled level
            both sections show, so the items get their own heading — in
            both views, categories and items are two sections, not one
            continuous grid. At the root the switcher shows one OR the
            other, so no heading is needed. --%>
            <div
              :if={both_sections?(assigns)}
              id={"#{@id}-items-heading"}
              class="text-sm font-semibold text-base-content/70 mb-2"
            >
              {gettext("Items")}
            </div>
            <%!-- Matching CATEGORIES above the item results — the admin
            search's two-list surface. Each hit opens that category's
            page with the search cleared; the muted trail is its
            ancestors, so two same-named subcategories stay apart. --%>
            <div
              :if={visible_cat_hits(assigns) != []}
              id={"#{@id}-search-cats"}
              class="flex flex-col gap-2 mb-3"
            >
              <h3 class="text-sm font-semibold text-base-content/70">
                {gettext("Categories")}
                <span class="text-xs font-normal text-base-content/40">
                  ({length(visible_cat_hits(assigns))})
                </span>
              </h3>
              <div class="flex flex-wrap gap-2">
                <button
                  :for={hit <- visible_cat_hits(assigns)}
                  type="button"
                  phx-click="open_category_hit"
                  phx-value-uuid={hit.uuid}
                  phx-target={@myself}
                  class="btn btn-sm btn-ghost gap-2 justify-start phx-click-loading:animate-pulse"
                >
                  <span class="font-medium">{hit.name}</span>
                  <span :if={hit.trail} class="text-xs text-base-content/40">{hit.trail}</span>
                </button>
              </div>
            </div>
            <div :if={show_items_block?(assigns)}>
            <.item_grid :if={@view == "card"} id={"#{@id}-grid"}>
              <%= if @browse.loading? and @browse.items == [] do %>
                <.grid_skeleton id={"#{@id}-skeleton"} count={8} />
              <% end %>
              <%= for item <- @browse.items do %>
                <%!-- Cards honor the same columns contract as the table —
                a host that granted no :price must not have prices reappear
                one view-toggle away, and default-hidden SKU stays hidden
                here too (visible ⊆ granted always). --%>
                <.item_card
                  id={"#{@id}-card-#{item.uuid}"}
                  item={item}
                  selected={Map.has_key?(@selection, item.uuid)}
                  clickable={@selection_mode != "quantity"}
                  show_price={@show_prices and :price in @visible_columns}
                  show_sku={@show_sku and :sku in @visible_columns}
                  selected_badge={@selection_mode != "quantity"}
                  photo_click={if(@show_item_details, do: "show_detail")}
                  target={@myself}
                >
                  <:footer>
                    <div :if={stepper?(assigns, item.uuid)} class="p-2 pt-0 flex justify-center">
                      <.qty_stepper
                        id={"#{@id}-qty-#{item.uuid}-r#{qty_rev(assigns, item.uuid)}"}
                        uuid={item.uuid}
                        qty={qty_display_or_zero(assigns, item.uuid)}
                        unit={if(@qty_precision > 0, do: item.unit)}
                        precision={@qty_precision}
                        min={@qmin}
                        max={@qmax}
                        select_floor={@qfloor}
                        zero_deselects={@qzero_desel}
                        target={@myself}
                        size="xs"
                      />
                    </div>
                    <%!-- Same read-only amount the table row carries in the
                    click flavour without inline_qty: the checkmark is the
                    selected signal, but a host that preselected at qty 3
                    must see the 3 in BOTH views (the row got this and the
                    card did not). --%>
                    <div
                      :if={
                        :qty in @visible_columns and not stepper?(assigns, item.uuid) and
                          Map.has_key?(@selection, item.uuid)
                      }
                      class="p-2 pt-0 text-center text-sm tabular-nums text-base-content/70"
                    >
                      {qty_display(assigns, item.uuid)}
                    </div>
                  </:footer>
                </.item_card>
              <% end %>
            </.item_grid>

            <.item_table
              :if={@view == "table" and (@browse.items != [] or @browse.loading?)}
              id={"#{@id}-table"}
              columns={@eff_columns}
              checkbox={@cbx}
            >
              <%= if @browse.loading? and @browse.items == [] do %>
                <tr :for={i <- 1..5} id={"#{@id}-row-skeleton-#{i}"}>
                  <td colspan={length(@eff_columns) + if(@cbx, do: 1, else: 0)}>
                    <div class="skeleton h-8 w-full"></div>
                  </td>
                </tr>
              <% end %>
              <%= for item <- @browse.items do %>
                <.item_row
                  id={"#{@id}-row-#{item.uuid}"}
                  item={item}
                  columns={@eff_columns}
                  selected={Map.has_key?(@selection, item.uuid)}
                  clickable={@selection_mode != "quantity"}
                  checkbox={@cbx}
                  selected_icon={@selection_mode != "quantity"}
                  thumb_click={if(@show_item_details, do: "show_detail")}
                  target={@myself}
                >
                  <:qty>
                    <.qty_stepper
                      :if={stepper?(assigns, item.uuid)}
                      id={"#{@id}-qty-#{item.uuid}-r#{qty_rev(assigns, item.uuid)}"}
                      uuid={item.uuid}
                      qty={qty_display_or_zero(assigns, item.uuid)}
                      unit={if(@qty_precision > 0, do: item.unit)}
                      precision={@qty_precision}
                      min={@qmin}
                      max={@qmax}
                      select_floor={@qfloor}
                      zero_deselects={@qzero_desel}
                      target={@myself}
                      size="xs"
                    />
                    <%!-- Click flavour, no inline_qty: the checkmark is the
                    selected signal; the picked amount shows read-only and
                    is edited in the tray or via the details popup. --%>
                    <span
                      :if={
                        not stepper?(assigns, item.uuid) and
                          Map.has_key?(@selection, item.uuid)
                      }
                      class="tabular-nums"
                    >
                      {qty_display(assigns, item.uuid)}
                    </span>
                  </:qty>
                </.item_row>
              <% end %>
            </.item_table>

            <div
              :if={
                @browse.items == [] and not @browse.loading? and
                  visible_cat_hits(assigns) == []
              }
              class="text-center py-12"
            >
              <div class="text-4xl mb-3 opacity-40">🔍</div>
              <p class="text-base-content/60">{gettext("No items match your search.")}</p>
            </div>

            <%!-- Auto-load sentinel. COLOCATED, not core's InfiniteScroll:
            that hook routes its push to the root LiveView on every
            published core (the CID-aware routing is unreleased), which
            crashes hosts without a load_more clause and silently drives
            hosts that have one (external review, 2026-08-31). This one
            pushes via pushEventTo(this.el), which resolves through the
            sentinel's own phx-target — the component — on every core.
            The button below stays as the no-JS / recovery fallback.
            Cursor = the full list identity (catalogue drill included) +
            length, so only a genuinely new page re-arms it; a no-op load
            releases the guard via the watchdog, worst case a brief stall
            the button recovers. --%>
            <div
              :if={not @browse.exhausted? and @browse.items != []}
              id={"#{@id}-scroll-sentinel"}
              phx-hook=".AutoLoad"
              phx-target={@myself}
              data-cursor={"#{@browse.catalogue_uuid}|#{@browse.category_uuid}|#{@browse.search}|#{length(@browse.items)}"}
            >
              <script :type={Phoenix.LiveView.ColocatedHook} name=".AutoLoad">
                export default {
                  maybeLoad() {
                    if (this.loading) return
                    this.loading = true
                    this.pushEventTo(this.el, "load_more", {})
                    clearTimeout(this.loadTimer)
                    this.loadTimer = setTimeout(() => { this.loading = false }, 2000)
                  },
                  mounted() {
                    this.intersecting = false
                    this.loading = false
                    this.lastCursor = this.el.dataset.cursor
                    this.observer = new IntersectionObserver((entries) => {
                      this.intersecting = entries[0].isIntersecting
                      if (this.intersecting) this.maybeLoad()
                    }, {rootMargin: "200px"})
                    this.observer.observe(this.el)
                  },
                  updated() {
                    if (this.el.dataset.cursor !== this.lastCursor) {
                      this.lastCursor = this.el.dataset.cursor
                      this.loading = false
                      clearTimeout(this.loadTimer)
                      if (this.intersecting) this.maybeLoad()
                    }
                  },
                  destroyed() {
                    clearTimeout(this.loadTimer)
                    if (this.observer) this.observer.disconnect()
                  }
                }
              </script>
            </div>
            <div :if={not @browse.exhausted? and @browse.items != []} class="flex justify-center py-3">
              <%!-- The spinner rides LiveView's phx-click-loading class —
              INSTANT, client-applied. The old server-assign gate never
              showed: the fetch is synchronous, so loading? is never true
              in an observable render. --%>
              <button
                type="button"
                class="btn btn-ghost btn-sm phx-click-loading:pointer-events-none"
                phx-click="load_more"
                phx-target={@myself}
              >
                <span class="loading loading-spinner loading-xs hidden phx-click-loading:inline-block">
                </span>
                {gettext("Load more")}
              </button>
            </div>
            </div>
          </div>

          <%!-- Item details as their OWN popup over the selector (boss,
          2026-08-31 — was a cover panel over the browse region). A
          stacked dialog: native top-layer ordering puts it above the
          selector, ESC/backdrop close only it, and the list underneath
          is never touched — scroll, search and selection all survive
          for free. The mode-aware control rides the modal's action row:
          inspection without "add" is a dead end, and the same events
          and uuid gates as the list apply. Never auto-selects on open. --%>
          <ProductCard.product_card
            :if={@detail}
            id={"#{@id}-detail"}
            show={true}
            target={@myself}
            item_name={@detail.name}
            images={@detail.images}
            fields={@detail.fields}
            files={@detail.files}
            on_close="close_detail"
          >
            <:extra_actions>
              <.qty_stepper
                :if={@selection_mode == "quantity"}
                id={"#{@id}-detail-qty-#{@detail.uuid}-r#{qty_rev(assigns, @detail.uuid)}"}
                uuid={@detail.uuid}
                qty={qty_display_or_zero(assigns, @detail.uuid)}
                unit={if(@qty_precision > 0, do: detail_unit(assigns))}
                precision={@qty_precision}
                min={@qmin}
                max={@qmax}
                select_floor={@qfloor}
                zero_deselects={@qzero_desel}
                target={@myself}
                size="sm"
              />
              <button
                :if={@selection_mode != "quantity"}
                type="button"
                class={[
                  "btn btn-sm",
                  if(Map.has_key?(@selection, @detail.uuid), do: "btn-ghost", else: "btn-primary")
                ]}
                phx-click="card_click"
                phx-value-uuid={@detail.uuid}
                phx-target={@myself}
              >
                <%= if Map.has_key?(@selection, @detail.uuid) do %>
                  {gettext("Remove from selection")}
                <% else %>
                  {gettext("Add to selection")}
                <% end %>
              </button>
            </:extra_actions>
          </ProductCard.product_card>
          </div>

          <%!-- Selection tray. --%>
          <div :if={@mode != :single or not @immediate} class="border-t border-base-300 pt-3">
            <div class="flex items-center justify-between gap-3">
              <%!-- show_tray={false}: no cart button, no review list — the
              host's rows already show the selection. The spacer keeps
              Cancel/Confirm on the right. --%>
              <span :if={!@show_tray}></span>
              <button
                :if={@show_tray}
                type="button"
                class="btn btn-ghost btn-sm gap-2"
                phx-click="toggle_tray"
                phx-target={@myself}
                disabled={@selection == %{}}
                aria-expanded={@tray_open}
              >
                <span class="hero-shopping-cart w-4 h-4"></span>
                {ngettext("%{count} item", "%{count} items", selection_count(@selection),
                  count: selection_count(@selection)
                )}
                <span :if={any_priced?(@selection)} class="text-base-content/60">
                  · {format_price(selection_total(@selection))}
                </span>
              </button>
              <div class="flex gap-2">
                <button
                  type="button"
                  class="btn btn-ghost btn-sm"
                  phx-click="cancel"
                  phx-target={@myself}
                >
                  {gettext("Cancel")}
                </button>
                <button
                  type="button"
                  class="btn btn-primary btn-sm phx-click-loading:pointer-events-none"
                  phx-click="confirm"
                  phx-target={@myself}
                  disabled={not confirmable_selection?(@selection)}
                >
                  <span class="loading loading-spinner loading-xs hidden phx-click-loading:inline-block">
                  </span>
                  {gettext("Confirm selection")}
                  <span :if={confirmable_count(@selection) > 0}>
                    ({confirmable_count(@selection)})
                  </span>
                </button>
              </div>
            </div>

            <div
              :if={@show_tray and @tray_open and @selection != %{}}
              class="mt-3 max-h-[26vh] overflow-y-auto"
            >
              <div
                :for={
                  {uuid, entry} <-
                    Enum.sort_by(@selection, fn {_u, e} -> e.item.name || "" end)
                }
                id={"#{@id}-tray-#{uuid}"}
                class={[
                  "flex items-center gap-3 py-2 border-b border-base-200 last:border-0",
                  !entry.available && "opacity-60"
                ]}
              >
                <img
                  :if={entry.item.thumb_url}
                  src={entry.item.thumb_url}
                  alt=""
                  class="w-10 h-10 rounded object-cover bg-base-200"
                />
                <div
                  :if={!entry.item.thumb_url}
                  class="w-10 h-10 rounded bg-base-200 flex items-center justify-center text-base-content/40 font-bold"
                >
                  {String.first(entry.item.name || "?")}
                </div>
                <div class="flex-1 min-w-0">
                  <div class="text-sm font-medium truncate">{entry.item.name}</div>
                  <div class="text-xs text-base-content/60 font-mono">{entry.item.sku}</div>
                  <div :if={!entry.available} class="text-xs text-warning">
                    {gettext("Not available in this selection")}
                  </div>
                </div>
                <.qty_stepper
                  :if={entry.available}
                  id={"#{@id}-tray-qty-#{uuid}-r#{qty_rev(assigns, uuid)}"}
                  uuid={uuid}
                  qty={qty_display(assigns, uuid)}
                  unit={if(@qty_precision > 0, do: entry.item.unit)}
                  precision={@qty_precision}
                  min={@qmin}
                  max={@qmax}
                  select_floor={@qfloor}
                  zero_deselects={@qzero_desel}
                  target={@myself}
                  size="xs"
                />
                <span :if={entry.available and entry.item.price} class="text-sm font-semibold w-20 text-right">
                  {format_price(Decimal.mult(entry.item.price, entry.qty))}
                </span>
                <button
                  type="button"
                  class="btn btn-ghost btn-xs"
                  phx-click="remove_pick"
                  phx-value-uuid={uuid}
                  phx-target={@myself}
                  aria-label={gettext("Remove")}
                >
                  <span class="hero-x-mark w-4 h-4"></span>
                </button>
              </div>
            </div>
          </div>
        </div>
      </.modal>
    </div>
    """
  end
end
