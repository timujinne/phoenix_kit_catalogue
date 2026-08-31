defmodule PhoenixKitCatalogue.Web.Components.Browse do
  @moduledoc """
  Embeddable, selection-agnostic building blocks for browsing catalogue
  items — the pieces `ItemSelectorModal` is assembled from, exposed so a
  host LiveView can compose its own browse surface (a storefront section,
  a picker, a read-only category wall) without copying markup.

  Everything here is a pure function component: state in, events out. Each
  interactive component takes a `target` (`phx-target`) so it works inside
  a LiveComponent as well as straight in a LiveView — leave it `nil` and
  events go to the host LV. Most event names are fixed (documented per
  component) so one `handle_event/3` vocabulary serves every embedding;
  `view_toggle`/`column_toggle` take an `event` attr and
  `item_card`/`item_row` let the host name the details event
  (`photo_click`/`thumb_click`). The search box and the load-more button
  are NOT components here — the two shipped surfaces hand-roll that
  markup (see their templates for the copyable shape).

  The data these render is a *presented item* — a plain map produced by
  `present_items/2`, which resolves translations and the featured-photo URL
  once per fetch rather than on every render:

      items
      |> Browse.present_items(locale)
      # => [%{uuid: "…", name: "…", sku: "…", price: %Decimal{}|nil,
      #       base_price: %Decimal{}|nil, unit: "piece",
      #       photo_url: "/…/medium/…"|nil, thumb_url: "/…/thumbnail/…"|nil,
      #       manufacturer: "…"|nil, category: "…"|nil,
      #       default_qty: %Decimal{1}}]

  `item_row/1`'s default columns read `thumb_url`, `category` and
  `base_price` too — a host hand-building presented maps needs the full
  shape above, not a subset.

  Pair them with `PhoenixKitCatalogue.Catalogue.BrowseState` for the
  fetch/paging state machine; the moduledoc there shows the loop.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitCatalogue.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  import PhoenixKitWeb.Components.Core.TableDefault,
    only: [
      table_default: 1,
      table_default_header: 1,
      table_default_header_cell: 1,
      table_default_body: 1,
      table_default_row: 1,
      table_default_cell: 1
    ]

  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.Translations
  alias PhoenixKitCatalogue.Schemas.Item

  @photo_variant "medium"

  @doc """
  Denormalizes schema items into presented maps: translated name, signed
  featured-photo URL, selling price (`Catalogue.item_pricing/1`'s
  `final_price`, matching `ItemPicker`), and a starting quantity of 1.

  `Item.default_value` is the smart-catalogue fee fallback (percent/flat),
  not a pick quantity — do not use it as a stepper default.

  Runs once per fetched page — never call translation or URL helpers from
  a template; a quantity keystroke re-renders every card.
  """
  @spec present_items([map() | struct()], String.t() | nil) :: [map()]
  def present_items(items, locale) do
    Enum.map(items, fn item ->
      translated = Translations.get_translation(item, locale)

      %{
        uuid: to_string(item.uuid),
        name: translated["name"] || item.name,
        sku: item.sku,
        price: presented_price(item),
        base_price: Map.get(item, :base_price),
        unit: item.unit,
        manufacturer: item.manufacturer_name || item.manufacturer_name_snapshot,
        category: presented_category(item, locale),
        photo_url: featured_photo_url(item),
        thumb_url: featured_thumb_url(item),
        default_qty: Decimal.new(1)
      }
    end)
  end

  # The item's category display name for the viewer's locale, or nil for
  # uncategorized items (and for maps without the preload — test doubles).
  # Goes through Translations.translated_name/2 — the "_name" multilang key
  # the chips honor applies to the category columns too.
  defp presented_category(item, locale) do
    case Map.get(item, :category) do
      %{__struct__: Ecto.Association.NotLoaded} -> nil
      nil -> nil
      category -> Translations.translated_name(category, locale) || Map.get(category, :name)
    end
  end

  # Selling price for a real item (markup → discount). Test doubles and
  # other maps fall back to `base_price` so render-shape tests stay
  # DB-free.
  defp presented_price(%Item{} = item), do: Catalogue.item_pricing(item).final_price
  defp presented_price(%{base_price: price}), do: price
  defp presented_price(_), do: nil

  @doc """
  Signed URL for an item's featured photo (`#{@photo_variant}` variant), or
  nil. Signing is pure computation — no Storage roundtrip — so this is safe
  per item; it lives here so every surface resolves photos one way.

  The pointer comes from free-form JSONB, so it is shape-checked before
  it reaches a URL path: a non-UUID value (import garbage, a crafted
  admin write) renders no image instead of sending every viewer's
  browser a GET to an attacker-shaped path (2026-08-31 sweep).
  """
  @spec featured_photo_url(map()) :: String.t() | nil
  def featured_photo_url(item), do: signed_featured_url(item, @photo_variant)

  @doc """
  Signed URL for the 150px `thumbnail` variant, or nil — for the 32-48px
  row cells that were shipping the 800px `medium` into a thumb-sized img
  (bandwidth, not quality; 2026-08-29 image sweep). Same shape check as
  `featured_photo_url/1`.
  """
  @spec featured_thumb_url(map()) :: String.t() | nil
  def featured_thumb_url(item), do: signed_featured_url(item, "thumbnail")

  # Canonical-form-only: Ecto.UUID.cast/1 also accepts ANY 16-byte
  # binary ("../../etc/passwd" is one), so equality with the cast result
  # is the actual guard — JSONB only ever stores the dashed string form.
  defp signed_featured_url(item, variant) do
    with uuid when is_binary(uuid) and uuid != "" <- item.data["featured_image_uuid"],
         {:ok, ^uuid} <- Ecto.UUID.cast(uuid) do
      URLSigner.signed_url(uuid, variant)
    else
      _ -> nil
    end
  end

  @doc """
  Normalizes a uuid to its canonical string form. `Tree.subtree_uuids_for/1`
  returns Postgres' raw 16-byte binaries; chips render and client events
  carry strings, and comparing the two shapes silently never matches.
  """
  @spec normalize_uuid(term()) :: String.t() | nil
  def normalize_uuid(nil), do: nil

  def normalize_uuid(bin) when is_binary(bin) and byte_size(bin) == 16 do
    case Ecto.UUID.load(bin) do
      {:ok, uuid} -> uuid
      :error -> bin
    end
  end

  def normalize_uuid(other), do: to_string(other)

  @doc """
  Expands a scope's `:category_uuids` through the category tree, once, at
  init — so chips, `BrowseState.category_allowed?/2` and preselect checks
  all compare the same literal list the fetch layer queries. A
  parent-category scope means "that category and its subtree"
  (`include_descendants` defaults to true across the search vocabulary),
  but every consumer compares literally — without this, descendant chips
  vanish and narrowing to one is rejected as out of scope (2026-08-25
  quorum review, finding 4; shared here 2026-08-30 so `CatalogueBrowse`
  stops missing the fix the modal got).

  Anything not shaped like an expandable scope passes through untouched
  for `BrowseState.init/1` to validate loudly. Re-expanding is
  idempotent, and a member's subtree cannot escape the root's subtree, so
  narrowing stays inside the allow-list.
  """
  @spec expand_scope(map() | keyword()) :: map()
  def expand_scope(scope) do
    scope = if is_map(scope), do: scope, else: Map.new(scope)

    case scope[:category_uuids] do
      uuids when is_list(uuids) and uuids != [] ->
        if Map.get(scope, :include_descendants, true) do
          expanded = Enum.map(Catalogue.category_subtree_uuids(uuids), &normalize_uuid/1)
          Map.put(scope, :category_uuids, expanded)
        else
          scope
        end

      _ ->
        scope
    end
  end

  @doc """
  The chip row's categories for a scope, translated for the viewer.
  Only meaningful when the scope names exactly one catalogue — with
  several (or all), a flat chip row of every category across catalogues
  is noise, and search does the narrowing instead. An
  `:uncategorized_only` scope contradicts every category narrowing
  (`search_items/2` raises on the combination), so it gets no chips.

  Metadata-only read (`list_categories_metadata_for_catalogue/1`) — the
  full listing preloads every item just to render chips. Any failure
  degrades to `[]`: chips are navigation, not data.
  """
  @spec chip_categories(map(), String.t() | nil) :: [%{uuid: String.t(), name: String.t() | nil}]
  def chip_categories(scope, locale)

  def chip_categories(%{only: :uncategorized_only}, _locale), do: []

  def chip_categories(%{catalogue_uuids: [catalogue_uuid]} = scope, locale) do
    categories = Catalogue.list_categories_metadata_for_catalogue(catalogue_uuid)

    categories =
      case scope[:category_uuids] do
        nil ->
          categories

        [] ->
          categories

        allowed ->
          allowed = Enum.map(allowed, &to_string/1)
          Enum.filter(categories, fn category -> to_string(category.uuid) in allowed end)
      end

    Enum.map(categories, fn category ->
      %{uuid: to_string(category.uuid), name: chip_name(category, locale)}
    end)
  rescue
    _ -> []
  end

  def chip_categories(_scope, _locale), do: []

  defp chip_name(record, locale) do
    translation =
      try do
        Catalogue.get_translation(record, locale)
      rescue
        _ -> %{}
      end

    Map.get(translation, "_name") ||
      Map.get(translation, "name") ||
      Map.get(record, :name)
  end

  @doc """
  Horizontally scrollable category filter chips: "All" plus one per
  category. Dispatches `browse_category` with `phx-value-uuid` ("" for All).
  """
  attr(:id, :string, required: true)
  attr(:categories, :list, required: true, doc: "[%{uuid:, name:}]")
  attr(:active_uuid, :any, default: nil)
  attr(:target, :any, default: nil)

  attr(:show_uncategorized, :boolean,
    default: false,
    doc:
      "Adds an Uncategorized chip (value \"__uncategorized__\") after the " <>
        "category chips — for scopes where items without a category exist " <>
        "and the chips would otherwise never add up."
  )

  def category_chips(assigns) do
    ~H"""
    <div id={@id} class="flex gap-1.5 overflow-x-auto pb-1" role="group" aria-label={gettext("Categories")}>
      <button
        type="button"
        class={["btn btn-xs rounded-full", if(@active_uuid, do: "btn-ghost", else: "btn-primary")]}
        phx-click="browse_category"
        phx-value-uuid=""
        phx-target={@target}
      >
        {gettext("All")}
      </button>
      <button
        :for={category <- @categories}
        type="button"
        class={[
          "btn btn-xs rounded-full whitespace-nowrap",
          if(@active_uuid == to_string(category.uuid), do: "btn-primary", else: "btn-ghost")
        ]}
        phx-click="browse_category"
        phx-value-uuid={category.uuid}
        phx-target={@target}
      >
        {category.name}
      </button>
      <button
        :if={@show_uncategorized}
        type="button"
        class={[
          "btn btn-xs rounded-full whitespace-nowrap",
          if(@active_uuid == :uncategorized, do: "btn-primary", else: "btn-ghost")
        ]}
        phx-click="browse_category"
        phx-value-uuid="__uncategorized__"
        phx-target={@target}
      >
        {gettext("Uncategorized")}
      </button>
    </div>
    """
  end

  @doc """
  The responsive card grid. Cards come in through the default slot so the
  caller decides what a card is — this component owns only the layout.
  """
  attr(:id, :string, required: true)
  attr(:class, :string, default: nil)
  slot(:inner_block, required: true)

  def item_grid(assigns) do
    ~H"""
    <div id={@id} class={["grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-3", @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  One product card: photo-forward (square, `object-cover`, lazy), then
  name / sku / price. Selection chrome is NOT built in — the picker layers
  it through the `:footer` slot and the `selected` ring, so a plain browse
  embedding renders the same card with neither.

  Dispatches `card_click` with `phx-value-uuid` when `clickable`.
  """
  attr(:id, :string, required: true)
  attr(:item, :map, required: true, doc: "a presented item (see present_items/2)")
  attr(:selected, :boolean, default: false)
  attr(:clickable, :boolean, default: true)
  attr(:show_price, :boolean, default: true)
  attr(:show_sku, :boolean, default: true)

  attr(:selected_badge, :boolean,
    default: true,
    doc:
      "the corner check badge on a selected card. Off in quantity mode " <>
        "(2026-08-31): a number above zero already says selected, and " <>
        "the extra check chrome read as \"checkboxes are still there\"."
  )

  attr(:photo_click, :string,
    default: nil,
    doc:
      "event name for a click on the photo area OR the title — the " <>
        "\"view details\" affordance (2026-08-30; the title joined the " <>
        "photo 2026-08-31: clicking it means the same as clicking the " <>
        "image). When set, figure and name become their own buttons " <>
        "dispatching this with the uuid, and only the REST of the body " <>
        "carries the select toggle. Nil keeps the whole face one target."
  )

  attr(:target, :any, default: nil)
  slot(:footer)

  def item_card(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "card bg-base-100 border transition-shadow overflow-hidden",
        if(@selected,
          do: "border-primary ring-2 ring-primary/40",
          else: "border-base-300 hover:shadow-md"
        )
      ]}
      data-selected={to_string(@selected)}
    >
      <%!-- Details affordance split (2026-08-30): with photo_click set the
      figure is its own button ("photo means look closer") and the body
      keeps the select toggle — the two gestures never share a target. --%>
      <button
        :if={@photo_click}
        type="button"
        class="w-full cursor-pointer"
        phx-click={@photo_click}
        phx-value-uuid={@item.uuid}
        phx-target={@target}
        aria-label={gettext("View item details")}
        title={gettext("View item details")}
      >
        <.item_card_figure
          item={@item}
          selected={@selected and @selected_badge}
          show_sku={@show_sku}
        />
      </button>
      <%!-- With the details affordance on, the TITLE dispatches the same
      event as the photo (Max, 2026-08-31: "clicking the title of an
      image should be the same as clicking the image") — the two always
      mean "look closer" together — and only the rest of the body keeps
      the select toggle. --%>
      <div :if={@photo_click} class="card-body p-3 gap-0.5">
        <button
          type="button"
          class="text-left cursor-pointer"
          phx-click={@photo_click}
          phx-value-uuid={@item.uuid}
          phx-target={@target}
          title={gettext("View item details")}
        >
          <span class="font-medium text-sm leading-snug line-clamp-2" title={@item.name}>
            {@item.name}
          </span>
        </button>
        <%!-- The min height is load-bearing: sku and price are both
        conditional, so with neither shown (an embed that granted no
        :price over items with no SKU) this button renders EMPTY, and a
        card whose row isn't stretched then has no select target at all
        — the title only opens details. Only while clickable, so the
        quantity flavour's disabled button adds no blank strip. --%>
        <button
          type="button"
          class={[
            "text-left w-full flex-1 flex flex-col gap-0.5 cursor-pointer disabled:cursor-default",
            @clickable && "min-h-[1.5rem]"
          ]}
          phx-click={@clickable && "card_click"}
          phx-value-uuid={@item.uuid}
          phx-target={@target}
          disabled={!@clickable}
          aria-pressed={@selected}
          aria-label={@item.name}
        >
          <span :if={@show_sku && @item.sku} class="font-mono text-xs text-base-content/60">
            {@item.sku}
          </span>
          <span :if={@show_price && @item.price} class="text-sm font-semibold">
            {format_price(@item.price)}
            <span :if={@item.unit} class="text-xs font-normal text-base-content/60">
              / {@item.unit}
            </span>
          </span>
        </button>
      </div>
      <button
        :if={!@photo_click}
        type="button"
        class="text-left w-full cursor-pointer disabled:cursor-default"
        phx-click={@clickable && "card_click"}
        phx-value-uuid={@item.uuid}
        phx-target={@target}
        disabled={!@clickable}
        aria-pressed={@selected}
        aria-label={@item.name}
      >
        <.item_card_figure
          item={@item}
          selected={@selected and @selected_badge}
          show_sku={@show_sku}
        />
        <div class="card-body p-3 gap-0.5">
          <span class="font-medium text-sm leading-snug line-clamp-2" title={@item.name}>
            {@item.name}
          </span>
          <span :if={@show_sku && @item.sku} class="font-mono text-xs text-base-content/60">
            {@item.sku}
          </span>
          <span :if={@show_price && @item.price} class="text-sm font-semibold">
            {format_price(@item.price)}
            <span :if={@item.unit} class="text-xs font-normal text-base-content/60">
              / {@item.unit}
            </span>
          </span>
        </div>
      </button>
      {render_slot(@footer)}
    </div>
    """
  end

  attr(:item, :map, required: true)
  attr(:selected, :boolean, required: true)
  attr(:show_sku, :boolean, required: true)

  defp item_card_figure(assigns) do
    ~H"""
    <figure class="relative aspect-square bg-base-200">
      <img
        :if={@item.photo_url}
        src={@item.photo_url}
        alt={@item.name}
        class="w-full h-full object-cover"
        loading="lazy"
        decoding="async"
      />
      <%!-- No photo: a deliberate tile (SKU initial), not a broken image.
      The SKU line honors show_sku — the placeholder must not leak what
      the card body hides. --%>
      <div
        :if={!@item.photo_url}
        class="w-full h-full flex flex-col items-center justify-center text-base-content/40"
      >
        <span class="text-4xl font-bold">{String.first(@item.sku || @item.name || "?")}</span>
        <span :if={@show_sku && @item.sku} class="font-mono text-xs mt-1">{@item.sku}</span>
      </div>
      <span
        :if={@selected}
        class="absolute top-2 right-2 badge badge-primary badge-sm gap-1"
        aria-hidden="true"
      >
        <.icon name="hero-check" class="w-3 h-3" />
      </span>
    </figure>
    """
  end

  @doc """
  A server-driven segmented view toggle: one button per mode, the active
  one highlighted, pushing `event` (default `"set_view"`) with
  `%{"mode" => mode}` to `target`. Presentation only — the caller owns the
  state and any persistence. (The admin pages' `view_mode_toggle` is the
  localStorage/client-side sibling; this one is for LiveComponents that
  hold their view in assigns.)
  """
  attr(:id, :string, required: true)
  attr(:modes, :list, required: true, doc: "[%{mode:, icon:, label:}] in display order")
  attr(:current, :string, required: true)
  attr(:event, :string, default: "set_view")
  attr(:target, :any, default: nil)

  def view_toggle(assigns) do
    ~H"""
    <div id={@id} class="join" role="group" aria-label={gettext("View")}>
      <button
        :for={m <- @modes}
        type="button"
        phx-click={@event}
        phx-value-mode={m.mode}
        phx-target={@target}
        class={["btn btn-sm join-item", @current == m.mode && "btn-active"]}
        title={m.label}
        aria-pressed={to_string(@current == m.mode)}
      >
        <span class={[m.icon, "w-4 h-4"]}></span>
      </button>
    </div>
    """
  end

  @doc """
  A columns-visibility dropdown: one checkbox row per TOGGLEABLE column,
  pushing `event` (default `"toggle_column"`) with `%{"col" => col}` to
  `target` on each row click. Presentation only — the caller owns which
  columns are toggleable at all (its pre-approved set minus pinned ones)
  and what is currently visible. Focus-based dropdown, so several columns
  can be flipped before it closes on blur.
  """
  attr(:id, :string, required: true)
  attr(:columns, :list, required: true, doc: "toggleable columns, display order")
  attr(:visible, :list, required: true)
  attr(:event, :string, default: "toggle_column")
  attr(:target, :any, default: nil)

  def column_toggle(assigns) do
    ~H"""
    <div id={@id} class="dropdown dropdown-end">
      <div tabindex="0" role="button" class="btn btn-sm" title={gettext("Columns")}>
        <span class="hero-view-columns w-4 h-4"></span>
      </div>
      <ul
        tabindex="0"
        class="dropdown-content menu bg-base-100 rounded-box border border-base-300 shadow-lg z-50 w-48 p-2"
      >
        <li :for={col <- @columns}>
          <button
            type="button"
            phx-click={@event}
            phx-value-col={col}
            phx-target={@target}
            class="justify-start gap-2"
          >
            <input
              type="checkbox"
              class="checkbox checkbox-xs pointer-events-none"
              checked={col in @visible}
              tabindex="-1"
            />
            {column_label(col)}
          </button>
        </li>
      </ul>
    </div>
    """
  end

  # Dropdown labels: same as the headers except :thumb, whose header is
  # deliberately blank.
  defp column_label(:thumb), do: gettext("Photo")
  defp column_label(:breadcrumb), do: gettext("Category prefix")
  defp column_label(col), do: column_header(col)

  # The column vocabulary for `item_table`/`item_row`. Hosts pick a subset
  # in display order; anything else raises at init (config is a contract).
  # `:price` is the customer-facing SELLING price (markup and discount
  # applied — `item_pricing/1`'s final_price) rendered as "6.40 / piece";
  # `:base_price` is the raw column for internal embeds; `:unit` is the
  # standalone unit for lists that show no price at all; `:breadcrumb` is
  # a headerless muted "Category /" prefix cell that sits flush against
  # the Name column, keeping names clean in their own column.
  @table_columns ~w(thumb breadcrumb name sku manufacturer category unit price base_price qty)a

  # What renders when the host doesn't pass columns: unit lives inside the
  # price cell, and the raw base price is opt-in only — a client-facing
  # default must never leak it.
  @default_table_columns ~w(thumb breadcrumb name sku manufacturer category price qty)a

  @doc "The legal `item_table`/`item_row` column atoms, in canonical order."
  @spec table_columns() :: [atom()]
  def table_columns, do: @table_columns

  @doc "The default column set — selling price with inline unit, no raw base price."
  @spec default_table_columns() :: [atom()]
  def default_table_columns, do: @default_table_columns

  @doc """
  Validates a host-supplied view attr — `"table" | "card"` (atoms accepted),
  raising on anything else. Both browse surfaces call this at init; each
  passes its own default for nil.
  """
  @spec resolve_view!(term(), String.t()) :: String.t()
  def resolve_view!(nil, default), do: default
  def resolve_view!(view, _default) when view in ["table", "card"], do: view
  def resolve_view!(view, _default) when view in [:table, :card], do: to_string(view)

  def resolve_view!(other, _default),
    do: raise(ArgumentError, ~s(view must be "table" or "card", got: #{inspect(other)}))

  @doc """
  Resolves the granted column list — the host contract both browse
  surfaces enforce. `nil` yields the default set minus what the
  `show_sku`/`show_prices` display flags already opt out of; an explicit
  non-empty list is taken verbatim, in order, and unknown entries raise —
  a silently-dropped column is how a price ends up shown to the wrong
  audience's sibling.
  """
  @spec resolve_columns!(term(), %{
          :show_sku => boolean(),
          :show_prices => boolean(),
          optional(atom()) => term()
        }) :: [atom()]
  def resolve_columns!(nil, display) do
    Enum.reject(
      @default_table_columns,
      &((&1 == :sku and not display.show_sku) or (&1 == :price and not display.show_prices))
    )
  end

  def resolve_columns!(columns, _display) when is_list(columns) and columns != [] do
    case Enum.reject(columns, &(&1 in @table_columns)) do
      [] ->
        # Duplicates render the column twice (two cells dispatching the
        # same click) — a contract that raises on unknown atoms must not
        # silently accept that shape either.
        if Enum.uniq(columns) != columns do
          raise ArgumentError, "columns has duplicate entries: #{inspect(columns)}"
        end

        columns

      bad ->
        raise ArgumentError,
              "columns has unknown entries #{inspect(bad)} — " <>
                "use #{inspect(@table_columns)}"
    end
  end

  def resolve_columns!(other, _display),
    do: raise(ArgumentError, "columns must be a non-empty list of atoms, got: #{inspect(other)}")

  @doc """
  The table twin of `item_grid`: an admin-look list for the same presented
  maps. Hosts configure which columns render (and their order) via
  `columns` — the popup is potentially client-facing, so nothing is shown
  that the host didn't ask for. Rows go inside via `item_row/1` with the
  SAME `columns` value.
  """
  attr(:id, :string, required: true)
  attr(:columns, :list, required: true, doc: "subset of table_columns/0, display order")

  attr(:checkbox, :boolean,
    default: false,
    doc: "renders a leftmost selection-checkbox column — pair with item_row's"
  )

  slot(:inner_block, required: true)

  def item_table(assigns) do
    ~H"""
    <%!-- Composed from core's table_default family — the components the
    admin tables are built on — so the picker list is literally the admin
    look, and improvements there flow here. The id lives on our wrapper:
    the classic table branch doesn't render one. --%>
    <div id={@id}>
      <.table_default variant="zebra" size="sm">
        <.table_default_header>
          <tr>
            <.table_default_header_cell :if={@checkbox} class="w-8"></.table_default_header_cell>
            <.table_default_header_cell
              :for={col <- @columns}
              class={[col_shape_class(col), col_responsive_class(col)]}
            >
              {column_header(col)}
            </.table_default_header_cell>
          </tr>
        </.table_default_header>
        <.table_default_body>
          {render_slot(@inner_block)}
        </.table_default_body>
      </.table_default>
    </div>
    """
  end

  defp column_header(:thumb), do: ""
  # Deliberately headerless, like :thumb — the content is its own label.
  defp column_header(:breadcrumb), do: ""
  defp column_header(:name), do: gettext("Name")
  defp column_header(:sku), do: gettext("SKU")
  defp column_header(:manufacturer), do: gettext("Manufacturer")
  defp column_header(:category), do: gettext("Category")
  defp column_header(:unit), do: gettext("Unit")
  defp column_header(:price), do: gettext("Price")
  defp column_header(:base_price), do: gettext("Base price")
  defp column_header(:qty), do: gettext("Qty")

  @doc """
  One selectable row for `item_table`. Every cell except `:qty` carries the
  same `card_click` toggle the card face uses — one event vocabulary, two
  views — while the `:qty` cell (the `:qty` slot, typically a
  `qty_stepper`) is deliberately not click-bound so stepping a quantity
  can never toggle the row underneath it.
  """
  attr(:id, :string, required: true)
  attr(:item, :map, required: true, doc: "a presented item (see present_items/2)")
  attr(:columns, :list, required: true, doc: "the same list the item_table got")
  attr(:selected, :boolean, default: false)
  attr(:clickable, :boolean, default: true)

  attr(:checkbox, :boolean,
    default: false,
    doc:
      "leftmost selection checkbox (2026-08-30): unchecked on every " <>
        "selectable row so the affordance is visible before the first pick. " <>
        "Display-only — while the row is clickable the CELL carries the " <>
        "same card_click toggle as the rest of the row (no second " <>
        "selection pathway to guard); with clickable={false} it is inert " <>
        "chrome. Pass the same value to item_table's checkbox attr or the " <>
        "header and body column counts skew."
  )

  attr(:thumb_click, :string,
    default: nil,
    doc:
      "event name for a click on the :thumb OR :name cell — the \"view " <>
        "details\" affordance (2026-08-30; the name joined the thumb " <>
        "2026-08-31: clicking the title means the same as clicking the " <>
        "image). When set, those two cells stop carrying the row's select " <>
        "toggle and dispatch this instead, with the uuid. Nil keeps them " <>
        "plain select cells like every other."
  )

  attr(:selected_icon, :boolean,
    default: true,
    doc:
      "the name-cell check icon on a selected row (already absent when a " <>
        "checkbox column shows it instead). Off in quantity mode " <>
        "(2026-08-31): the number above zero is the selected signal."
  )

  attr(:target, :any, default: nil)
  slot(:qty, doc: "rendered in the :qty cell when that column is present")

  def item_row(assigns) do
    ~H"""
    <.table_default_row
      id={@id}
      data-selected={to_string(@selected)}
      aria-selected={to_string(@selected)}
      class={@selected && "bg-primary/10"}
    >
      <.table_default_cell
        :if={@checkbox}
        class={["w-8", @clickable && "cursor-pointer"]}
        phx-click={if @clickable, do: "card_click"}
        phx-value-uuid={if @clickable, do: @item.uuid}
        phx-target={if @clickable, do: @target}
      >
        <input
          type="checkbox"
          class="checkbox checkbox-sm pointer-events-none align-middle"
          checked={@selected}
          tabindex="-1"
          aria-hidden="true"
        />
      </.table_default_cell>
      <%!-- One cell_event/2 evaluation per cell, not four — the class,
      click, value and target below must stay in sync by construction. --%>
      <.table_default_cell
        :for={{col, event} <- Enum.map(@columns, &{&1, cell_event(&1, assigns)})}
        class={[
          row_cell_class(col),
          col_responsive_class(col),
          event && "cursor-pointer"
        ]}
        phx-click={event}
        phx-value-uuid={if event, do: @item.uuid}
        phx-target={if event, do: @target}
        aria-label={col == :thumb && @thumb_click && @item.name}
      >
        <%= case col do %>
          <% :thumb -> %>
            <img
              :if={@item.thumb_url}
              src={@item.thumb_url}
              alt=""
              class="w-8 h-8 rounded object-cover bg-base-200"
              loading="lazy"
            />
            <div
              :if={!@item.thumb_url}
              class="w-8 h-8 rounded bg-base-200 flex items-center justify-center text-base-content/40 font-bold"
            >
              {String.first(@item.sku || @item.name || "?")}
            </div>
          <% :name -> %>
            <div class="flex items-center gap-1.5 font-medium">
              <%!-- With a checkbox column the check icon would say the same
              thing twice one cell apart. --%>
              <.icon
                :if={@selected and not @checkbox and @selected_icon}
                name="hero-check"
                class="w-4 h-4 text-primary shrink-0"
              />
              <%!-- line-clamp, not truncate: nowrap would hand a long name
              the whole table width back and resurrect sideways scroll. --%>
              <span class="line-clamp-2">{@item.name}</span>
            </div>
          <% :breadcrumb -> %>
            <%!-- nowrap but width-capped: a long category must not hand the
            table sideways scroll back. --%>
            <span
              :if={@item.category}
              class="text-base-content/60 whitespace-nowrap truncate inline-block max-w-40 align-bottom"
            >
              {@item.category} /
            </span>
          <% :sku -> %>
            <span class="font-mono text-xs text-base-content/60">{@item.sku}</span>
          <% :manufacturer -> %>
            <span class="text-base-content/70">{@item.manufacturer}</span>
          <% :category -> %>
            <span class="text-base-content/70">{@item.category}</span>
          <% :unit -> %>
            <span class="text-base-content/70">{@item.unit}</span>
          <% :price -> %>
            <span :if={@item.price} class="font-semibold whitespace-nowrap">
              {format_price(@item.price)}
              <span :if={@item.unit} class="text-xs font-normal text-base-content/60">
                / {@item.unit}
              </span>
            </span>
            <span :if={!@item.price && @item.unit} class="text-base-content/60">
              {@item.unit}
            </span>
          <% :base_price -> %>
            <span class="whitespace-nowrap">{format_price(@item.base_price)}</span>
          <% :qty -> %>
            <div class="flex justify-end">{render_slot(@qty)}</div>
        <% end %>
      </.table_default_cell>
    </.table_default_row>
    """
  end

  # Which event a row cell dispatches: the thumb AND the name carry the
  # details affordance when the host enabled one (Max, 2026-08-31:
  # "clicking the title of an image should be the same as clicking the
  # image"); every other cell (bar :qty, whose stepper must never toggle
  # the row underneath) carries the select toggle while the row is
  # clickable.
  defp cell_event(:qty, _assigns), do: nil
  defp cell_event(:thumb, %{thumb_click: event}) when is_binary(event), do: event
  defp cell_event(:name, %{thumb_click: event}) when is_binary(event), do: event
  defp cell_event(_col, %{clickable: true}), do: "card_click"
  defp cell_event(_col, _assigns), do: nil

  defp row_cell_class(:thumb), do: "w-10"
  defp row_cell_class(:name), do: "w-full"
  defp row_cell_class(:breadcrumb), do: "text-right whitespace-nowrap pr-0"
  defp row_cell_class(:price), do: "text-right whitespace-nowrap"
  defp row_cell_class(:base_price), do: "text-right whitespace-nowrap"
  defp row_cell_class(:qty), do: "text-right whitespace-nowrap"
  defp row_cell_class(_), do: "whitespace-nowrap"

  # Header twins of the shape classes: the NAME column is the one rubber
  # column — it absorbs all slack width so the data columns pack together
  # at content width and the qty stepper sits beside the price instead of
  # drifting to the far edge with dead space before it. Numeric columns
  # right-align.
  defp col_shape_class(:name), do: "w-full"
  defp col_shape_class(:price), do: "text-right"
  defp col_shape_class(:base_price), do: "text-right"
  defp col_shape_class(:qty), do: "text-right"
  defp col_shape_class(_), do: nil

  # Small screens drop low-priority columns instead of forcing a modal to
  # scroll sideways: identity (thumb/name) and the numbers that drive the
  # pick (price/qty) survive down to phone width; unit returns at sm, SKU
  # at md, manufacturer and category at lg. Presence stays the host's
  # columns contract — this only stages WHEN a granted column shows.
  defp col_responsive_class(:breadcrumb), do: "hidden sm:table-cell"
  defp col_responsive_class(:unit), do: "hidden sm:table-cell"
  defp col_responsive_class(:sku), do: "hidden md:table-cell"
  defp col_responsive_class(:base_price), do: "hidden md:table-cell"
  defp col_responsive_class(:manufacturer), do: "hidden lg:table-cell"
  defp col_responsive_class(:category), do: "hidden lg:table-cell"
  defp col_responsive_class(_), do: nil

  @doc """
  Quantity input: a native `<input type="number">` — the browser's own
  spinner arrows, the same control the rest of the kit uses for numbers
  (2026-08-30, replacing the custom −/+ join stepper).

  Three event paths, one server vocabulary:

    * `qty_change` (form `phx-change`, debounced) — fires for spinner
      clicks and settled typing. Consumers should treat it as a LIVE
      update: apply valid values, silently ignore incomplete ones
      ("2." on the way to "2.5") — never reset the input from here, the
      user may still be typing.
    * `qty_commit` (blur / Enter) — the authoritative commit; a consumer
      may reset rejected garbage here via the revision-bump pattern: put
      a per-row revision counter in the `id` you pass (the shipped
      surfaces use `"...-qty-\#{uuid}-r\#{rev}"`) and bump it on commit —
      the id change makes morphdom recreate the input with the server
      value, which a plain re-assign cannot do when the value attr is
      unchanged. A stable `id` leaves typed garbage stuck in the field.
    * Both carry `%{"uuid" =>, "value" =>}`.

  Integer mode is `precision: 0` (the default; step 1); a decimal item is
  the same control with `precision > 0` (step 0.1 / 0.01 / …) and a `unit`
  suffix. `min`/`max`/`step` shape the arrows and keyboard ONLY — the
  form is `novalidate`, so they never gate the submit (a browser
  validation failure would leave Enter silently dead), and every limit
  is re-enforced server-side, exactly as before.
  """
  attr(:id, :string, required: true)
  attr(:uuid, :string, required: true)
  attr(:qty, :string, required: true, doc: "display string, already formatted")
  attr(:unit, :string, default: nil)
  attr(:precision, :integer, default: 0)
  attr(:min, :string, default: nil, doc: "min attr for the control (arrows stop here)")
  attr(:max, :string, default: nil)
  attr(:target, :any, default: nil)
  attr(:size, :string, default: "sm", values: ~w(xs sm))

  def qty_stepper(assigns) do
    ~H"""
    <%!-- The form wraps the join (Enter commits via phx-submit; phx-blur
         commits on focus loss). phx-change catches what blur never sees:
         a spinner-arrow click changes the value without ever blurring,
         and a modal closed right after would lose it.

         novalidate is load-bearing (2026-08-31): step/min/max are browser
         VALIDATION constraints, and a phx-submit form never reaches
         LiveView while an input fails one — so a typed "2.5" at
         precision 0, or a value above max, left Enter silently dead
         while blur committed fine. The server owns rounding and
         clamping; the attrs stay purely to shape the arrows and the
         mobile keyboard, which is what the doc promises. --%>
    <form
      id={@id}
      phx-submit="qty_commit"
      phx-change="qty_change"
      phx-target={@target}
      novalidate
    >
      <input type="hidden" name="uuid" value={@uuid} />
      <div class="join" role="group" aria-label={gettext("Quantity")}>
        <input
          id={"#{@id}-input"}
          type="number"
          name="value"
          value={@qty}
          min={@min}
          max={@max}
          step={qty_step(@precision)}
          inputmode={if @precision > 0, do: "decimal", else: "numeric"}
          class={["input join-item text-center px-1", qty_width(@size), input_size(@size)]}
          phx-debounce="400"
          phx-blur="qty_commit"
          phx-value-uuid={@uuid}
          phx-target={@target}
          aria-label={gettext("Quantity")}
        />
        <span
          :if={@unit}
          class={[
            "btn join-item pointer-events-none font-normal text-base-content/60",
            btn_size(@size)
          ]}
          aria-hidden="true"
        >
          {@unit}
        </span>
      </div>
    </form>
    """
  end

  # Same derivation entities uses for decimal fields: one unit of the
  # last displayed place.
  defp qty_step(precision) when is_integer(precision) and precision > 0,
    do: "0." <> String.duplicate("0", precision - 1) <> "1"

  defp qty_step(_), do: "1"

  # The native control renders its own spinner arrows inside the field,
  # so it needs more room than the old bare text input.
  defp qty_width("xs"), do: "w-16"
  defp qty_width(_), do: "w-20"

  defp btn_size("xs"), do: "btn-xs"
  defp btn_size(_), do: "btn-sm"
  defp input_size("xs"), do: "input-xs"
  defp input_size(_), do: "input-sm"

  @doc """
  Placeholder cards with the exact geometry of `item_card/1`, so the grid
  does not reflow when real items arrive.
  """
  attr(:id, :string, required: true)
  attr(:count, :integer, default: 8)

  def grid_skeleton(assigns) do
    ~H"""
    <div :for={i <- 1..@count} id={"#{@id}-#{i}"} class="card border border-base-300 overflow-hidden">
      <div class="skeleton aspect-square rounded-none"></div>
      <div class="card-body p-3 gap-2">
        <div class="skeleton h-4 w-3/4"></div>
        <div class="skeleton h-3 w-1/3"></div>
      </div>
    </div>
    """
  end

  @doc """
  Formats a Decimal price for the card/tray. Bare number, no currency
  symbol — the same convention as the module's item table (`format_price`
  in `Web.Components`): which currency a price is in is host business the
  catalogue has never decided.
  """
  @spec format_price(term()) :: String.t() | nil
  def format_price(%Decimal{} = d), do: Decimal.to_string(Decimal.round(d, 2), :normal)
  def format_price(_), do: nil
end
