defmodule PhoenixKitCatalogue.Web.Components.CatalogueBrowse do
  @moduledoc """
  Embeddable catalogue browse surface: search, category chips, and the
  item grid or admin-look table as one drop-in LiveComponent — the same
  `BrowseState` + `Browse.*` stack `ItemSelectorModal` runs on, minus the
  selection chrome. Put a catalogue (or a scoped slice of one) on any
  logged-in page:

      <.live_component
        module={PhoenixKitCatalogue.Web.Components.CatalogueBrowse}
        id="showroom"
        scope={%{catalogue_uuids: [@catalogue.uuid], statuses: ["active"]}}
      />

  ## Views and columns (2026-08-30)

  Two presentations over the same fetch, exactly like the modal:
  `view: "card"` (the default here — existing embeds keep their grid) and
  `view: "table"`, the admin-look list. A toggle beside the search box
  switches them; the attr only sets the starting view.

  `columns` is the same host contract the modal enforces
  (`Browse.table_columns/0`, unknown entries raise) and it is a GRANT:
  the cards read it too, so a column the host didn't grant can't
  reappear by flipping the view. Omitted, the default set applies minus
  what `show_sku`/`show_prices` opt out of, and minus `:qty` — selection
  chrome this surface doesn't have (a host that explicitly asks for
  `:qty` gets an empty cell).

  The TABLE additionally starts without the modal's default-hidden pair
  (`:sku`, `:breadcrumb`): without the modal's Columns dropdown they'd
  render outright, and `:breadcrumb` beside the `:category` column shows
  the category twice per row. That is visibility, not grant — the cards
  keep their SKU line, which is what `show_sku` has always controlled.
  An explicit `columns` list is taken verbatim on both surfaces.

  ## Messages to the host

  One generic message, so a host writes a single clause and switches on
  the event:

      handle_info({:catalogue_browse, %{id: id, event: :item_clicked, item: item}}, socket)

  `item` is a presented map (`Browse.present_items/2`): uuid, translated
  name, sku, price, unit, photo_url. Cards/rows are clickable only when
  the host opts in with `on_item_click: true` — a purely decorative
  embedding never receives (or needs to handle) anything.

  ## Scope

  Identical semantics to `ItemSelectorModal`: fixed at mount, every fetch
  re-derived from it, category narrowing only within it — including the
  subtree expansion a parent-category scope needs (`Browse.expand_scope/1`,
  shared with the modal since 2026-08-30; this surface previously hid
  descendant chips and rejected narrowing to them). See
  `PhoenixKitCatalogue.Catalogue.BrowseState`.
  """

  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitCatalogue.Gettext

  import PhoenixKitCatalogue.Web.Components.Browse

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.BrowseState
  alias PhoenixKitCatalogue.Web.Components.Browse

  @impl true
  def mount(socket) do
    {:ok, assign(socket, initialized: false)}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, Map.take(assigns, [:id]))

    if socket.assigns.initialized do
      {:ok, socket}
    else
      browse =
        BrowseState.init(
          scope: Browse.expand_scope(assigns[:scope] || %{}),
          per_page: assigns[:per_page] || 24,
          # The module's shared sort (client, 2026-09-01): this embed's
          # listings read in the same order the admin detail page does.
          order: Browse.global_items_order()
        )

      {browse, effect} = BrowseState.command(browse, :reset)
      locale = assigns[:locale] || Gettext.get_locale(PhoenixKitCatalogue.Gettext)

      display = %{
        show_prices: Map.get(assigns, :show_prices, true),
        show_sku: Map.get(assigns, :show_sku, true)
      }

      columns = resolve_columns(assigns[:columns], display)

      socket =
        socket
        |> assign(display)
        |> assign(
          initialized: true,
          locale: locale,
          on_item_click: assigns[:on_item_click] || false,
          show_search: Map.get(assigns, :show_search, true),
          view: Browse.resolve_view!(assigns[:view], "card"),
          columns: columns,
          visible_columns: visible_columns(assigns[:columns], columns),
          categories: order_chips(Browse.chip_categories(browse.scope, locale)),
          browse: browse
        )

      {:ok, run_fetch(socket, effect)}
    end
  end

  # The chip row follows the module's shared category sort where a chip
  # carries the data — name (chips are `%{uuid, name}` maps, so the
  # count/date sorts have nothing to read and keep the query's position
  # order, the same fallback the admin's manual baseline is).
  defp order_chips(chips) do
    case Browse.global_categories_order() do
      {:name, dir} ->
        sorted = Enum.sort_by(chips, &String.downcase(&1.name || ""))
        if dir == :desc, do: Enum.reverse(sorted), else: sorted

      _ ->
        chips
    end
  end

  # The GRANT — the shared contract minus :qty, which is selection chrome
  # this surface has none of. Cards and table both read from here, so a
  # view toggle can never widen what the host allowed. An explicit list
  # is taken verbatim (Browse.resolve_columns!/2 raises on unknown
  # entries either way).
  defp resolve_columns(nil, display), do: Browse.resolve_columns!(nil, display) -- [:qty]

  defp resolve_columns(columns, display), do: Browse.resolve_columns!(columns, display)

  # What the TABLE renders: the grant minus the modal's default-HIDDEN
  # pair (:sku, :breadcrumb — without the modal's Columns dropdown they'd
  # render outright, and :breadcrumb next to the :category column showed
  # the category twice per row; 2026-08-31 sweep). VISIBILITY, not grant:
  # subtracting them from the grant instead also stripped the cards' SKU
  # line, which show_sku has controlled since this component shipped and
  # which no host could restore without an explicit columns list.
  defp visible_columns(nil, granted), do: granted -- [:sku, :breadcrumb]

  defp visible_columns(_explicit, granted), do: granted

  # Same synchronous fetch discipline as ItemSelectorModal — see the note
  # there. The duplication of this small executor between the two LCs is
  # known and deliberate for now: pulling it into a shared behaviour is
  # cheap the day a third surface appears.
  defp run_fetch(socket, :noop), do: socket

  defp run_fetch(socket, {:fetch, opts, gen}) do
    %{browse: browse, locale: locale} = socket.assigns

    items = Catalogue.search_items(browse.search, opts)
    total = Catalogue.count_search_items(browse.search, opts)
    presented = Browse.present_items(items, locale)

    assign(socket, browse: BrowseState.ingest(browse, gen, presented, total))
  end

  @impl true
  def handle_event("browse_search", %{"search" => q}, socket) do
    {browse, effect} = BrowseState.command(socket.assigns.browse, {:search, q})
    {:noreply, socket |> assign(browse: browse) |> run_fetch(effect)}
  end

  def handle_event("browse_category", %{"uuid" => uuid}, socket) do
    cmd = {:set_category, if(uuid == "", do: nil, else: uuid)}
    {browse, effect} = BrowseState.command(socket.assigns.browse, cmd)
    {:noreply, socket |> assign(browse: browse) |> run_fetch(effect)}
  end

  def handle_event("load_more", _params, socket) do
    {browse, effect} = BrowseState.command(socket.assigns.browse, :load_more)
    {:noreply, socket |> assign(browse: browse) |> run_fetch(effect)}
  end

  def handle_event("set_view", %{"mode" => mode}, socket) when mode in ["table", "card"] do
    {:noreply, assign(socket, :view, mode)}
  end

  def handle_event("card_click", %{"uuid" => uuid}, socket) do
    # Same rule as the picker: only items this surface rendered exist.
    with true <- socket.assigns.on_item_click,
         %{} = item <- Enum.find(socket.assigns.browse.items, &(&1.uuid == uuid)) do
      send(
        self(),
        {:catalogue_browse, %{id: socket.assigns.id, event: :item_clicked, item: item}}
      )

      {:noreply, socket}
    else
      _ -> {:noreply, socket}
    end
  end

  # A crafted payload with missing keys must degrade to a no-op, not a
  # FunctionClauseError that takes the whole LiveView down.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="flex flex-col gap-3">
      <div class="flex items-center gap-2">
        <%!-- phx-submit is load-bearing: a phx-change form WITHOUT it is an
        "external form" to LiveView's client — Enter would run a NATIVE
        submit and navigate the whole page away. Same handler, so Enter is
        just a re-search. --%>
        <form
          :if={@show_search}
          id={"#{@id}-search-form"}
          class="flex-1"
          phx-change="browse_search"
          phx-submit="browse_search"
          phx-target={@myself}
        >
          <label class="input flex items-center gap-2 w-full">
            <span class="hero-magnifying-glass w-4 h-4 opacity-60"></span>
            <input
              id={"#{@id}-search"}
              type="text"
              name="search"
              value={@browse.search}
              placeholder={gettext("Search items…")}
              phx-debounce="250"
              autocomplete="off"
              class="grow"
            />
          </label>
        </form>
        <span :if={!@show_search} class="flex-1"></span>
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

      <.category_chips
        :if={@categories != []}
        id={"#{@id}-chips"}
        categories={@categories}
        active_uuid={@browse.category_uuid}
        target={@myself}
      />

      <.item_grid :if={@view == "card"} id={"#{@id}-grid"}>
        <%= if @browse.loading? and @browse.items == [] do %>
          <.grid_skeleton id={"#{@id}-skeleton"} count={8} />
        <% end %>
        <%= for item <- @browse.items do %>
          <%!-- Cards honour the GRANT, not the table's visibility list —
          a toggle must not resurrect a price the host didn't grant, and
          the table's default-hidden SKU must not vanish from the cards
          show_sku still asks for. --%>
          <.item_card
            id={"#{@id}-card-#{item.uuid}"}
            item={item}
            clickable={@on_item_click}
            show_price={@show_prices and :price in @columns}
            show_sku={@show_sku and :sku in @columns}
            target={@myself}
          />
        <% end %>
      </.item_grid>

      <.item_table
        :if={@view == "table" and (@browse.items != [] or @browse.loading?)}
        id={"#{@id}-table"}
        columns={@visible_columns}
      >
        <%= if @browse.loading? and @browse.items == [] do %>
          <tr :for={i <- 1..5} id={"#{@id}-row-skeleton-#{i}"}>
            <td colspan={length(@visible_columns)}><div class="skeleton h-8 w-full"></div></td>
          </tr>
        <% end %>
        <%= for item <- @browse.items do %>
          <.item_row
            id={"#{@id}-row-#{item.uuid}"}
            item={item}
            columns={@visible_columns}
            clickable={@on_item_click}
            target={@myself}
          />
        <% end %>
      </.item_table>

      <div :if={@browse.items == [] and not @browse.loading?} class="text-center py-12">
        <div class="text-4xl mb-3 opacity-40">🔍</div>
        <p class="text-base-content/60">{gettext("No items match your search.")}</p>
      </div>

      <div :if={not @browse.exhausted? and @browse.items != []} class="flex justify-center py-2">
        <button
          type="button"
          class="btn btn-ghost btn-sm"
          phx-click="load_more"
          phx-target={@myself}
          disabled={@browse.loading?}
        >
          <span :if={@browse.loading?} class="loading loading-spinner loading-xs"></span>
          {gettext("Load more")}
        </button>
      </div>
    </div>
    """
  end
end
