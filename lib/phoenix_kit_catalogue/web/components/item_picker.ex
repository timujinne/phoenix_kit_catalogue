defmodule PhoenixKitCatalogue.Web.Components.ItemPicker do
  @moduledoc """
  Combobox LiveComponent for picking a single item from the catalogue
  via server-side search.

  Drop one into any LiveView — typically many, one per row in a picker
  table. Each instance owns its own search state; the parent LV only
  reacts to two messages:

      {:item_picker_select, id, %Item{}}  # user chose an item
      {:item_picker_clear,  id}           # user cleared the selection

  A third message fires only when the caller opts into a clickable photo
  thumbnail (`photo_clickable`), so consumers that don't set it never
  receive it:

      {:item_picker_photo_click, id, %Item{}}  # user clicked the thumbnail

  Clicking the thumbnail ALSO opens a self-contained product card
  (`ProductCard`) — no host wiring is needed for that. The
  `:item_picker_photo_click` message is only an extra hook for a host that
  wants to react (analytics, its own navigation). A host that sets
  `photo_clickable` MUST provide a matching `handle_info/2` clause (or a
  catch-all), or the message crashes its LiveView.

  ### API

      <.item_picker
        id="row-42-picker"
        category_uuids={[category.uuid]}
        selected_item={@chosen_item}
        excluded_uuids={@already_used_uuids}
        locale="en"
      />

  Attrs:

    * `:id` (required) — unique DOM/component id. The `:item_picker_*`
      messages echo this back so a parent with N pickers knows which
      fired.
    * `:category_uuids` — scope search to these categories. `nil` or
      `[]` means "all categories + uncategorized" (matches
      `Catalogue.search_items/2`).
    * `:catalogue_uuids` — scope search to these catalogues. Composes
      with `:category_uuids` (AND).
    * `:include_descendants` — when `true` (default), `:category_uuids`
      is expanded through the V103 tree; pass `false` for literal
      set semantics.
    * `:only` — `:uncategorized_only` restricts results to items without
      a category; `:categorized_only` restricts to items in some
      category; `nil` (default) is unrestricted. Forwards to
      `Catalogue.search_items/2`'s `:only` opt.
    * `:selected_item` — the `%Item{}` currently chosen (or `nil`).
      Drives the input text and the `aria-selected` / primary-border
      styling in the dropdown. When the chosen item carries a featured
      photo (`data["featured_image_uuid"]`), a small thumbnail of it is
      rendered to the left of the input; items without a photo render as
      before (input only).
    * `:excluded_uuids` — items in this list are rendered dim +
      `aria-disabled` and cannot be clicked. Use for "already picked in
      another row" state.
    * `:locale` (required) — locale string for translated display
      names (`"en"`, `"es"`, etc.). Resolved via
      `Catalogue.get_translation/2`.
    * `:placeholder` — input placeholder. Defaults to "Search items…".
    * `:empty_query_limit` — how many items to show when the query is
      empty (the "just focused" state). Defaults to `10`.
    * `:page_size` — max results fetched per query. Defaults to `20`.
      When the unbounded count exceeds this the dropdown shows a
      "Type to refine…" sentinel row so the user knows there's more.
    * `:disabled` — disables the input and hides the clear button.
    * `:format_price` — 1-arity function taking an `%Item{}` (with
      `:catalogue` preloaded — the search always does this) and
      returning a display string or `nil`. Defaults to a Decimal
      stringifier of `item_pricing(item).final_price`. Return `nil` to
      omit the price column entirely.
    * `:show_unit` — when `true`, renders the item's measurement unit
      (via `:format_unit`) as a small muted label next to the price in
      each dropdown row. Defaults to `false` (no unit) so existing
      consumers are unaffected.
    * `:format_unit` — 1-arity function taking the item's unit string and
      returning a display label (`""` to omit). Only used when
      `:show_unit` is `true`. Defaults to a built-in mapping of common
      abbreviations (`piece`→`pc`, `set`→`set`, `pair`→`pair`,
      `sheet`→`sheet`, `m2`→`m²`, `running_meter`→`rm`; unknown strings
      pass through). Supply your own to use a different unit vocabulary.
    * `:show_sku` — when `true`, renders the item's `:sku` between the
      category breadcrumb and the unit label on each dropdown row's
      second line (as an em dash when the item has no SKU on file, so a
      blank catalogue field doesn't read as a rendering bug). Defaults to
      `false` so existing consumers are unaffected.
    * `:highlight_selected` — when `true` (default), the input gets the
      `input-primary` border while an item is selected. Pass `false` to
      suppress that highlight. Default preserves existing behaviour.
    * `:photo_clickable` — when `true`, the main-image thumbnail rendered
      to the left of the input becomes a button that echoes
      `{:item_picker_photo_click, id, %Item{}}` upward (the navigation
      hook the product-card feature builds on). Defaults to `false`: the
      thumbnail still renders when the item has a photo, but as an inert
      image, so consumers without a handler are unaffected.
    * `:initial_query` — optional seed string for the search input. When
      provided (and nothing is selected and the user hasn't typed), the
      input is prefilled with this string and the dropdown opens with
      matching results on first render. Fires once; subsequent updates
      leave the query alone. Defaults to `nil` (no seeding).

  ### Keyboard / a11y

  Handled client-side by the colocated `ItemPicker` hook:

    * ArrowDown / ArrowUp cycle through enabled options (announced via
      `aria-activedescendant`; DOM focus stays on the input).
    * Home / End jump to first / last enabled option.
    * Enter activates the focused option (simulates a click so the
      normal `select` event fires).
    * Escape closes the dropdown and keeps focus on the input.
    * Clicking outside the picker closes it (`phx-click-away`).

  The dropdown is absolutely positioned and elevated with `z-50`; the
  parent container must allow overflow (`overflow: visible` or just
  don't set `overflow: hidden` on an ancestor that clips it).
  """

  use Phoenix.LiveComponent

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias Phoenix.LiveView.JS
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Schemas.Item
  alias PhoenixKitCatalogue.Web.Components.ProductCard

  @default_empty_query_limit 10
  @default_page_size 20

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       query: "",
       options: [],
       has_more: false,
       open: false,
       selected_item: nil,
       last_selected_uuid: nil,
       excluded_uuids: [],
       category_uuids: nil,
       catalogue_uuids: nil,
       include_descendants: true,
       only: nil,
       placeholder: nil,
       empty_query_limit: @default_empty_query_limit,
       page_size: @default_page_size,
       disabled: false,
       format_price: nil,
       format_unit: nil,
       show_unit: false,
       show_sku: false,
       highlight_selected: true,
       initial_query: nil,
       seeded_initial_query: false,
       searched?: false,
       photo_clickable: false,
       card_open: false,
       card_name: nil,
       card_images: [],
       card_fields: [],
       card_files: [],
       locale: "en",
       category_paths: %{}
     )}
  end

  @impl true
  def update(assigns, socket) do
    # If the selected_item UUID *changes* between updates, mirror the
    # new item's name into the input. No change (including first mount
    # with no selection) leaves `:query` alone so a mid-typing user
    # isn't clobbered by unrelated parent re-renders.
    incoming_uuid = uuid_of(assigns[:selected_item])
    prior_uuid = socket.assigns.last_selected_uuid

    socket =
      socket
      |> assign(assigns)
      |> assign(:last_selected_uuid, incoming_uuid)

    socket =
      if prior_uuid == incoming_uuid do
        socket
      else
        # Selection changed under us — mirror the new name and dismiss any
        # open product card so it can't show stale images/fields for the
        # previous item on a parent-driven reassignment.
        locale = socket.assigns.locale

        assign(socket,
          query: item_display_name(assigns[:selected_item], locale) || "",
          searched?: false,
          card_open: false
        )
      end

    {:ok, maybe_seed_initial_query(socket, incoming_uuid)}
  end

  # Opt-in: seed the input with an arbitrary search string the first time
  # `initial_query` is provided, and run the search so results appear
  # immediately. Only fires once (guarded by `:seeded_initial_query`) and
  # only when nothing is selected and the user hasn't typed yet, so it never
  # clobbers a real selection or mid-typing query.
  defp maybe_seed_initial_query(socket, incoming_uuid) do
    initial_query = socket.assigns.initial_query

    cond do
      socket.assigns.seeded_initial_query ->
        socket

      is_binary(initial_query) and initial_query != "" and is_nil(incoming_uuid) and
          String.trim(socket.assigns.query || "") == "" ->
        socket
        |> assign(:query, initial_query)
        |> assign(:seeded_initial_query, true)
        |> assign(:searched?, true)
        |> assign(:open, true)
        |> run_search()

      true ->
        socket
    end
  end

  defp uuid_of(%Item{uuid: u}), do: u
  defp uuid_of(_), do: nil

  # ─────────────────────────────────────────────────────────────────
  # Events
  # ─────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("query_change", %{"value" => value}, socket) do
    {:noreply,
     socket
     |> assign(:query, value)
     |> assign(:searched?, true)
     |> assign(:open, true)
     |> run_search()}
  end

  def handle_event("open", _params, socket) do
    # `options == []` alone (not also requiring an empty query) covers a
    # picker mounted with a `selected_item` that was never searched in this
    # process — `update/2` mirrors the item's name into `:query` on mount,
    # so a query-based guard here never re-triggers and focusing the input
    # opens an empty "No items found" dropdown instead of a replacement
    # list. A live selection doesn't hit this: `options` already holds the
    # results from the search that led to the pick.
    #
    # When that mount-mirrored name IS the query, searching it would return
    # just the already-chosen row — useless as a replacement list. Browse
    # instead: search the empty query (the first page) while leaving the
    # input text showing the item's name.
    #
    # A re-focus after a typed search that returned [] deliberately re-runs
    # the same query — an extra request, but the user who got nothing may
    # want exactly that retry.
    socket =
      cond do
        socket.assigns.options == [] and not socket.assigns.searched? and
            query_is_selection_name?(socket) ->
          run_search(assign(socket, :open, true), "")

        socket.assigns.options == [] ->
          run_search(assign(socket, :open, true))

        true ->
          assign(socket, :open, true)
      end

    {:noreply, socket}
  end

  def handle_event("close", _params, socket) do
    {:noreply, assign(socket, :open, false)}
  end

  def handle_event("select", %{"uuid" => uuid}, socket) do
    case Enum.find(socket.assigns.options, &(&1.uuid == uuid)) do
      nil ->
        {:noreply, socket}

      %Item{} = item ->
        send(self(), {:item_picker_select, socket.assigns.id, item})

        {:noreply,
         socket
         |> assign(:query, item_display_name(item, socket.assigns.locale) || "")
         |> assign(:open, false)}
    end
  end

  def handle_event("photo_click", _params, socket) do
    # Open the product card for the chosen item (L026.1): resolve its
    # gallery images + filled fields and show the modal. Still echo the
    # item upward so a host that wants to react (analytics, its own
    # navigation) can — the card opening is self-contained either way.
    #
    # Guard on `photo_clickable`: the thumbnail button only renders when it's
    # on, but a client can push the event regardless, and firing the upward
    # message at a host that never opted in (and so has no matching
    # handle_info) would crash that LiveView.
    # The item must also actually BE one. `open_card/2` already ignores a nil,
    # but the upward message fired first and unconditionally — so a forged
    # event with nothing selected delivered `{:item_picker_photo_click, id,
    # nil}` to a host whose handle_info matches `%Item{}`, crashing it. The
    # message's third element is now guaranteed to be an `%Item{}`, which is
    # what the moduledoc promises.
    case {socket.assigns.photo_clickable, socket.assigns.selected_item} do
      {true, %Item{} = item} ->
        send(self(), {:item_picker_photo_click, socket.assigns.id, item})

        {:noreply, open_card(socket, item)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("card_close", _params, socket) do
    {:noreply, assign(socket, :card_open, false)}
  end

  def handle_event("clear", _params, socket) do
    send(self(), {:item_picker_clear, socket.assigns.id})

    {:noreply,
     socket
     |> assign(:query, "")
     |> assign(:options, [])
     |> assign(:has_more, false)
     |> assign(:open, false)}
  end

  # ─────────────────────────────────────────────────────────────────
  # Search
  # ─────────────────────────────────────────────────────────────────

  # True when the current query is exactly the selected item's mirrored
  # display name — the post-reload state where a name search would only
  # find the item that's already chosen.
  defp query_is_selection_name?(socket) do
    name = item_display_name(socket.assigns.selected_item, socket.assigns.locale)
    is_binary(name) and name != "" and socket.assigns.query == name
  end

  # `query_override` searches something other than the input text without
  # touching the `:query` assign (the browse-on-reopen path).
  defp run_search(socket, query_override \\ nil) do
    %{
      query: assigns_query,
      category_uuids: category_uuids,
      catalogue_uuids: catalogue_uuids,
      include_descendants: include_descendants,
      only: only,
      page_size: page_size,
      empty_query_limit: empty_query_limit
    } = socket.assigns

    query = query_override || assigns_query

    limit =
      case String.trim(query || "") do
        "" -> empty_query_limit
        _ -> page_size
      end

    opts =
      [limit: limit, include_descendants: include_descendants]
      |> maybe_put(:category_uuids, category_uuids)
      |> maybe_put(:catalogue_uuids, catalogue_uuids)
      |> maybe_put(:only, only)

    options = Catalogue.search_items(query || "", opts)

    has_more =
      if length(options) >= limit do
        total = Catalogue.count_search_items(query || "", Keyword.delete(opts, :limit))
        total > length(options)
      else
        false
      end

    socket
    |> ensure_category_paths(options)
    |> assign(options: options, has_more: has_more)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, []), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # Batches ancestor-chain lookups by UNIQUE category uuid instead of one
  # query per item — a page can hold up to `page_size` items (default 500
  # for some callers) but almost always draws from a handful of distinct
  # categories. Memoized in `:category_paths` across the component's life
  # so a category looked up once stays cheap on the next search page too.
  defp ensure_category_paths(socket, items) do
    known = socket.assigns.category_paths

    new_uuids =
      items
      |> Enum.map(&category_uuid_of/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(known, &1))

    case new_uuids do
      [] ->
        socket

      uuids ->
        locale = socket.assigns.locale

        fresh =
          Map.new(uuids, fn uuid ->
            names =
              uuid
              |> Catalogue.list_category_ancestors()
              |> Enum.map(&translated_name(&1, locale))

            {uuid, names}
          end)

        assign(socket, :category_paths, Map.merge(known, fresh))
    end
  end

  defp category_uuid_of(%Item{category: %{__struct__: Ecto.Association.NotLoaded}}), do: nil
  defp category_uuid_of(%Item{category: nil}), do: nil
  defp category_uuid_of(%Item{category: %{uuid: uuid}}), do: uuid
  defp category_uuid_of(_), do: nil

  # ─────────────────────────────────────────────────────────────────
  # Display helpers
  # ─────────────────────────────────────────────────────────────────

  # The selected item's featured photo UUID (from the JSONB `data` map)
  # or nil. Drives the optional thumbnail rendered to the left of the
  # input; a blank or missing pointer renders no thumbnail, leaving the
  # layout unchanged for items without a photo.
  defp selected_photo_uuid(%Item{data: data}) when is_map(data) do
    case Map.get(data, "featured_image_uuid") do
      uuid when is_binary(uuid) and uuid != "" -> uuid
      _ -> nil
    end
  end

  defp selected_photo_uuid(_), do: nil

  # Resolves the product card's images + filled fields for `item` and
  # opens the modal. The main (featured) image is the first one, shown
  # expanded. Called from `photo_click`, which now matches `%Item{}` itself —
  # so the nil fallback this used to carry is unreachable and was removed
  # rather than left as a clause dialyzer reports can never match.
  defp open_card(socket, %Item{} = item) do
    assign(socket,
      card_open: true,
      card_name: ProductCard.resolve_name(item, socket.assigns.locale),
      card_images: ProductCard.resolve_images(item),
      card_fields: ProductCard.build_fields(item, socket.assigns.locale),
      card_files: ProductCard.resolve_files(item)
    )
  end

  defp item_display_name(nil, _locale), do: nil

  defp item_display_name(%Item{} = item, locale) do
    translation = safe_get_translation(item, locale)

    Map.get(translation, "_name") ||
      Map.get(translation, "name") ||
      item.name
  end

  # Full path: catalogue / every ancestor category (root → direct parent) /
  # the item's own category. `category_paths` (built by `ensure_category_paths/2`)
  # supplies the ancestor names — looking them up here would mean a DB query
  # inside render, once per rendered row.
  defp item_breadcrumb(%Item{} = item, locale, category_paths) do
    catalogue_name =
      case item.catalogue do
        %{__struct__: Ecto.Association.NotLoaded} ->
          nil

        nil ->
          nil

        catalogue ->
          translated_name(catalogue, locale)
      end

    {ancestor_names, category_name} =
      case item.category do
        %{__struct__: Ecto.Association.NotLoaded} ->
          {[], nil}

        nil ->
          {[], nil}

        category ->
          {Map.get(category_paths, category.uuid, []), translated_name(category, locale)}
      end

    ([catalogue_name] ++ ancestor_names ++ [category_name])
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" / ")
  end

  defp translated_name(record, locale) do
    translation = safe_get_translation(record, locale)

    Map.get(translation, "_name") ||
      Map.get(translation, "name") ||
      Map.get(record, :name)
  end

  defp safe_get_translation(record, locale) do
    Catalogue.get_translation(record, locale)
  rescue
    _ -> %{}
  end

  defp format_price_display(_item, nil), do: nil

  defp format_price_display(%Item{} = item, fun) when is_function(fun, 1) do
    fun.(item)
  end

  defp default_format_price(%Item{} = item) do
    pricing = Catalogue.item_pricing(item)

    case pricing.final_price do
      nil -> nil
      %Decimal{} = price -> Decimal.to_string(price, :normal)
    end
  rescue
    _ -> nil
  end

  # ─────────────────────────────────────────────────────────────────
  # Render
  # ─────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(
        :placeholder_text,
        assigns[:placeholder] || Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search items…")
      )
      |> assign(
        :price_fun,
        assigns[:format_price] || (&default_format_price/1)
      )
      |> assign(
        :unit_fun,
        assigns[:format_unit] || (&Item.unit_label/1)
      )
      |> assign(
        :selected_photo_uuid,
        selected_photo_uuid(assigns[:selected_item])
      )

    ~H"""
    <div
      id={@id}
      class="relative w-full"
      phx-hook=".ItemPicker"
      phx-click-away={JS.push("close", target: @myself)}
    >
      <div class="flex items-center gap-2">
        <%!--
        Main-image thumbnail, rendered before (to the left of) the position
        field when the chosen item carries a featured photo. When
        `photo_clickable` is on, it becomes a button that echoes
        `{:item_picker_photo_click, id, item}` upward — the navigation hook the
        product-card feature (L026.1) wires up. Off by default so existing
        consumers (no handler yet) render a plain, inert thumbnail.
        --%>
        <button
          :if={@selected_photo_uuid && @photo_clickable}
          type="button"
          phx-click="photo_click"
          phx-target={@myself}
          class="shrink-0"
          aria-label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "View item details")}
          title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "View item details")}
        >
          <img
            src={URLSigner.signed_url(@selected_photo_uuid, "thumbnail")}
            alt=""
            onerror="this.style.display='none'"
            class="w-8 h-8 shrink-0 rounded object-cover bg-base-200 border border-base-300"
          />
        </button>
        <img
          :if={@selected_photo_uuid && !@photo_clickable}
          src={URLSigner.signed_url(@selected_photo_uuid, "thumbnail")}
          alt=""
          onerror="this.style.display='none'"
          class="w-8 h-8 shrink-0 rounded object-cover bg-base-200 border border-base-300"
        />
        <div class="relative flex-1">
          <input
            id={"#{@id}-input"}
            type="text"
            role="combobox"
            aria-expanded={to_string(@open)}
            aria-controls={"#{@id}-listbox"}
            aria-autocomplete="list"
            autocomplete="off"
            value={@query}
            placeholder={@placeholder_text}
            disabled={@disabled}
            phx-target={@myself}
            phx-change="query_change"
            phx-debounce="300"
            phx-focus="open"
            class={[
              "input input-sm w-full pr-8",
              @highlight_selected && @selected_item && "input-primary"
            ]}
          />

          <button
            :if={@selected_item && !@disabled}
            type="button"
            phx-click="clear"
            phx-target={@myself}
            class="btn btn-xs btn-ghost absolute right-1 top-1/2 -translate-y-1/2"
            aria-label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Clear")}
          >
            <.icon name="hero-x-mark" class="w-3 h-3" />
          </button>

          <ul
            :if={@open and @options != []}
            id={"#{@id}-listbox"}
            role="listbox"
            class="absolute z-50 mt-1 w-full max-h-64 overflow-y-auto bg-base-100 border border-base-300 rounded-box shadow-lg"
          >
            <li
              :for={{item, idx} <- Enum.with_index(@options)}
              id={"#{@id}-option-#{idx}"}
              role="option"
              aria-selected={to_string(@selected_item && @selected_item.uuid == item.uuid)}
              aria-disabled={to_string(item.uuid in @excluded_uuids)}
              data-excluded={to_string(item.uuid in @excluded_uuids)}
              class={[
                "flex items-center justify-between px-3 py-2 cursor-pointer select-none",
                "data-[focused=true]:bg-base-200 hover:bg-base-200",
                "data-[excluded=true]:opacity-40 data-[excluded=true]:cursor-not-allowed",
                "data-[excluded=true]:hover:bg-transparent"
              ]}
              phx-click={if item.uuid in @excluded_uuids, do: nil, else: "select"}
              phx-value-uuid={item.uuid}
              phx-target={@myself}
            >
              <% price = format_price_display(item, @price_fun) %>
              <% unit = if @show_unit, do: @unit_fun.(item.unit), else: "" %>
              <% sku = if @show_sku, do: item.sku || "—", else: nil %>
              <div class="min-w-0 flex-1">
                <div class="font-medium text-sm truncate">
                  {item_display_name(item, @locale)}
                </div>
                <div
                  :if={item_breadcrumb(item, @locale, @category_paths) != ""}
                  class="text-xs text-base-content/50 truncate"
                >
                  {item_breadcrumb(item, @locale, @category_paths)}
                </div>
              </div>
              <div :if={sku} class="text-xs text-base-content/40 shrink-0 self-end px-2 truncate max-w-24">
                {sku}
              </div>
              <div :if={(price != nil and price != "") or unit != ""} class="text-right ml-4 shrink-0">
                <div :if={price != nil and price != ""} class="text-sm font-medium">
                  {price}
                </div>
                <div :if={unit != ""} class="text-xs text-base-content/50">
                  {unit}
                </div>
              </div>
            </li>
            <li
              :if={@has_more}
              role="option"
              aria-disabled="true"
              class="px-3 py-2 text-xs text-base-content/40 italic cursor-default select-none"
            >
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Type to refine search…")}
            </li>
          </ul>

          <div
            :if={@open and @options == [] and @query != ""}
            class="absolute z-50 mt-1 w-full bg-base-100 border border-base-300 rounded-box shadow-lg px-3 py-2 text-sm text-base-content/50"
          >
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No items found")}
          </div>
        </div>
      </div>

      <ProductCard.product_card
        :if={@photo_clickable}
        id={@id}
        show={@card_open}
        item_name={@card_name}
        images={@card_images}
        fields={@card_fields}
        files={@card_files}
        target={@myself}
        on_close="card_close"
      />

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ItemPicker">
        export default {
          mounted() {
            this.input = this.el.querySelector('input[role="combobox"]')
            this.focusedIdx = -1
            this._onKey = (e) => this.handleKey(e)
            this.input.addEventListener("keydown", this._onKey)
          },

          updated() {
            // Options re-rendered — clamp the highlight.
            const opts = this.enabledOptions()
            if (this.focusedIdx >= opts.length) {
              this.focusedIdx = opts.length - 1
            }
            this.syncActiveDescendant()
          },

          destroyed() {
            if (this.input && this._onKey) {
              this.input.removeEventListener("keydown", this._onKey)
            }
          },

          enabledOptions() {
            return Array.from(
              this.el.querySelectorAll('li[role="option"]:not([aria-disabled="true"])')
            )
          },

          handleKey(e) {
            const opts = this.enabledOptions()

            switch (e.key) {
              case "ArrowDown":
                if (opts.length === 0) return
                e.preventDefault()
                this.focusedIdx = Math.min(this.focusedIdx + 1, opts.length - 1)
                if (this.focusedIdx < 0) this.focusedIdx = 0
                this.syncActiveDescendant()
                break

              case "ArrowUp":
                if (opts.length === 0) return
                e.preventDefault()
                this.focusedIdx = Math.max(this.focusedIdx - 1, 0)
                this.syncActiveDescendant()
                break

              case "Home":
                if (opts.length === 0) return
                e.preventDefault()
                this.focusedIdx = 0
                this.syncActiveDescendant()
                break

              case "End":
                if (opts.length === 0) return
                e.preventDefault()
                this.focusedIdx = opts.length - 1
                this.syncActiveDescendant()
                break

              case "Enter":
                if (this.focusedIdx >= 0 && this.focusedIdx < opts.length) {
                  e.preventDefault()
                  opts[this.focusedIdx].click()
                }
                break

              case "Escape":
                e.preventDefault()
                this.pushEventTo(this.el, "close", {})
                break
            }
          },

          syncActiveDescendant() {
            this.el
              .querySelectorAll('li[data-focused="true"]')
              .forEach((el) => el.removeAttribute("data-focused"))

            const opts = this.enabledOptions()
            if (this.focusedIdx >= 0 && this.focusedIdx < opts.length) {
              const el = opts[this.focusedIdx]
              el.setAttribute("data-focused", "true")
              el.scrollIntoView({block: "nearest"})
              this.input.setAttribute("aria-activedescendant", el.id)
            } else {
              this.input.removeAttribute("aria-activedescendant")
            }
          }
        }
      </script>
    </div>
    """
  end
end
