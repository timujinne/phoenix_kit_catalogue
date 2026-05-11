defmodule PhoenixKitCatalogue.Web.Components.ItemPicker do
  @moduledoc """
  Combobox LiveComponent for picking a single item from the catalogue
  via server-side search.

  Drop one into any LiveView — typically many, one per row in a picker
  table. Each instance owns its own search state; the parent LV only
  reacts to two messages:

      {:item_picker_select, id, %Item{}}  # user chose an item
      {:item_picker_clear,  id}           # user cleared the selection

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
      styling in the dropdown.
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
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Schemas.Item

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
       locale: "en"
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
        locale = socket.assigns.locale
        assign(socket, :query, item_display_name(assigns[:selected_item], locale) || "")
      end

    {:ok, socket}
  end

  defp uuid_of(%Item{uuid: u}), do: u
  defp uuid_of(_), do: nil

  # ─────────────────────────────────────────────────────────────────
  # Events
  # ─────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("query_change", %{"value" => value}, socket) do
    {:noreply, socket |> assign(:query, value) |> assign(:open, true) |> run_search()}
  end

  def handle_event("open", _params, socket) do
    socket =
      if socket.assigns.options == [] and socket.assigns.query == "" do
        run_search(assign(socket, :open, true))
      else
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

  defp run_search(socket) do
    %{
      query: query,
      category_uuids: category_uuids,
      catalogue_uuids: catalogue_uuids,
      include_descendants: include_descendants,
      only: only,
      page_size: page_size,
      empty_query_limit: empty_query_limit
    } = socket.assigns

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

    assign(socket, options: options, has_more: has_more)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, []), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # ─────────────────────────────────────────────────────────────────
  # Display helpers
  # ─────────────────────────────────────────────────────────────────

  defp item_display_name(nil, _locale), do: nil

  defp item_display_name(%Item{} = item, locale) do
    translation = safe_get_translation(item, locale)

    Map.get(translation, "_name") ||
      Map.get(translation, "name") ||
      item.name
  end

  defp item_breadcrumb(%Item{} = item, locale) do
    catalogue_name =
      case item.catalogue do
        %{__struct__: Ecto.Association.NotLoaded} ->
          nil

        nil ->
          nil

        catalogue ->
          translated_name(catalogue, locale)
      end

    category_name =
      case item.category do
        %{__struct__: Ecto.Association.NotLoaded} ->
          nil

        nil ->
          nil

        category ->
          translated_name(category, locale)
      end

    [catalogue_name, category_name]
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

    ~H"""
    <div
      id={@id}
      class="relative w-full"
      phx-hook=".ItemPicker"
      phx-click-away={JS.push("close", target: @myself)}
    >
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
          @selected_item && "input-primary"
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
          <div class="min-w-0 flex-1">
            <div class="font-medium text-sm truncate">
              {item_display_name(item, @locale)}
            </div>
            <div
              :if={item_breadcrumb(item, @locale) != ""}
              class="text-xs text-base-content/50 truncate"
            >
              {item_breadcrumb(item, @locale)}
            </div>
          </div>
          <div
            :if={(price = format_price_display(item, @price_fun)) && price != ""}
            class="text-sm font-medium ml-4 shrink-0"
          >
            {price}
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
