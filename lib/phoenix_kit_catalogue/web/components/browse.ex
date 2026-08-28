defmodule PhoenixKitCatalogue.Web.Components.Browse do
  @moduledoc """
  Embeddable, selection-agnostic building blocks for browsing catalogue
  items — the pieces `ItemSelectorModal` is assembled from, exposed so a
  host LiveView can compose its own browse surface (a storefront section,
  a picker, a read-only category wall) without copying markup.

  Everything here is a pure function component: state in, events out. Each
  interactive component takes a `target` (`phx-target`) so it works inside
  a LiveComponent as well as straight in a LiveView — leave it `nil` and
  events go to the host LV. Event names are fixed (documented per
  component) so one `handle_event/3` vocabulary serves every embedding.

  The data these render is a *presented item* — a plain map produced by
  `present_items/2`, which resolves translations and the featured-photo URL
  once per fetch rather than on every render:

      items
      |> Browse.present_items(locale)
      # => [%{uuid: "…", name: "…", sku: "…", price: %Decimal{}|nil,
      #       unit: "piece", photo_url: "/…/medium/…"|nil,
      #       manufacturer: "…"|nil, default_qty: %Decimal{1}}]

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
  """
  def featured_photo_url(item) do
    case item.data["featured_image_uuid"] do
      uuid when is_binary(uuid) and uuid != "" -> URLSigner.signed_url(uuid, @photo_variant)
      _ -> nil
    end
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
      <button
        type="button"
        class="text-left w-full cursor-pointer disabled:cursor-default"
        phx-click={@clickable && "card_click"}
        phx-value-uuid={@item.uuid}
        phx-target={@target}
        disabled={!@clickable}
        aria-pressed={@selected}
        aria-label={@item.name}
      >
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
  def table_columns, do: @table_columns

  @doc "The default column set — selling price with inline unit, no raw base price."
  def default_table_columns, do: @default_table_columns

  @doc """
  The table twin of `item_grid`: an admin-look list for the same presented
  maps. Hosts configure which columns render (and their order) via
  `columns` — the popup is potentially client-facing, so nothing is shown
  that the host didn't ask for. Rows go inside via `item_row/1` with the
  SAME `columns` value.
  """
  attr(:id, :string, required: true)
  attr(:columns, :list, required: true, doc: "subset of table_columns/0, display order")
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

  The `:thumb` cell honors a `pk-comfy` class on an ANCESTOR element (the
  same density-toggle idiom `components.ex`'s admin tables use): wrap the
  table in a container with that class to switch its thumbnail — and only
  its thumbnail — to a larger size. No prop on this component itself; it's
  a pure CSS hook, off by default.
  """
  attr(:id, :string, required: true)
  attr(:item, :map, required: true, doc: "a presented item (see present_items/2)")
  attr(:columns, :list, required: true, doc: "the same list the item_table got")
  attr(:selected, :boolean, default: false)
  attr(:clickable, :boolean, default: true)
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
        :for={col <- @columns}
        class={[
          row_cell_class(col),
          col_responsive_class(col),
          col != :qty and @clickable && "cursor-pointer"
        ]}
        phx-click={if col != :qty and @clickable, do: "card_click"}
        phx-value-uuid={if col != :qty and @clickable, do: @item.uuid}
        phx-target={if col != :qty and @clickable, do: @target}
      >
        <%= case col do %>
          <% :thumb -> %>
            <img
              :if={@item.photo_url}
              src={@item.photo_url}
              alt=""
              class="w-8 h-8 [.pk-comfy_&]:w-16 [.pk-comfy_&]:h-16 rounded object-cover bg-base-200"
              loading="lazy"
            />
            <div
              :if={!@item.photo_url}
              class="w-8 h-8 [.pk-comfy_&]:w-16 [.pk-comfy_&]:h-16 rounded bg-base-200 flex items-center justify-center text-base-content/40 font-bold"
            >
              {String.first(@item.sku || @item.name || "?")}
            </div>
          <% :name -> %>
            <div class="flex items-center gap-1.5 font-medium">
              <.icon :if={@selected} name="hero-check" class="w-4 h-4 text-primary shrink-0" />
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

  defp row_cell_class(:thumb), do: "w-10 [.pk-comfy_&]:w-20"
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
  Quantity stepper: minus / text input / plus. The input commits on blur or
  Enter (`qty_commit` with `%{"uuid" =>, "value" =>}`) — never on keystroke,
  so typing "2." on the way to "2.5" is not fought. The buttons dispatch
  `qty_dec` / `qty_inc` immediately.

  Integer mode is `precision: 0` (the default); a decimal item is the same
  component with `precision > 0` and a `unit` suffix — no redesign, which
  is the point. All limits are re-enforced server-side; these attrs only
  shape the keyboard.
  """
  attr(:id, :string, required: true)
  attr(:uuid, :string, required: true)
  attr(:qty, :string, required: true, doc: "display string, already formatted")
  attr(:unit, :string, default: nil)
  attr(:precision, :integer, default: 0)
  attr(:target, :any, default: nil)
  attr(:size, :string, default: "sm", values: ~w(xs sm))

  def qty_stepper(assigns) do
    ~H"""
    <%!-- The form WRAPS the join (Enter still commits via phx-submit;
         phx-blur commits on focus loss; the +/− are type="button" so they
         never submit). With the input nested inside a join-item form
         instead, the inline form aligned to the text BASELINE and the
         input rendered with a visible offset below the buttons, its
         corners unmerged. Direct join children keep everything flush. --%>
    <form id={@id} phx-submit="qty_commit" phx-target={@target}>
      <input type="hidden" name="uuid" value={@uuid} />
      <div class="join" role="group" aria-label={gettext("Quantity")}>
        <button
          type="button"
          class={["btn join-item", btn_size(@size)]}
          phx-click="qty_dec"
          phx-value-uuid={@uuid}
          phx-target={@target}
          aria-label={gettext("Decrease quantity")}
        >
          −
        </button>
        <input
          id={"#{@id}-input"}
          type="text"
          name="value"
          value={@qty}
          inputmode={if @precision > 0, do: "decimal", else: "numeric"}
          class={["input join-item w-14 text-center px-1", input_size(@size)]}
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
        <button
          type="button"
          class={["btn join-item", btn_size(@size)]}
          phx-click="qty_inc"
          phx-value-uuid={@uuid}
          phx-target={@target}
          aria-label={gettext("Increase quantity")}
        >
          +
        </button>
      </div>
    </form>
    """
  end

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
  def format_price(%Decimal{} = d), do: Decimal.to_string(Decimal.round(d, 2), :normal)
  def format_price(_), do: nil
end
