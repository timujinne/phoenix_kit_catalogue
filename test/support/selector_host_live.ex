defmodule PhoenixKitCatalogue.Test.SelectorHostLive do
  @moduledoc """
  Test-only host for `ItemSelectorModal`: mounts the LiveComponent with a
  scope built from query params and renders every message the component
  sends back into inspectable DOM, so tests assert the REAL contract — the
  process messages a production host would receive — rather than component
  internals.

  Query params:

    * `c`         — catalogue uuid for `scope.catalogue_uuids`
    * `pre`       — preselection, `uuid:qty[,uuid:qty…]`
    * `mode`      — "single" for `mode: :single`
    * `immediate` — "true" with single mode
    * `precision` — qty_precision (default 0)
    * `min`       — qty_min
    * `max`       — qty_max
    * `view`      — starting view, "table" | "card" (nil = component default)
    * `sel`       — selection_mode, "click" | "quantity"
    * `hide`      — comma list for hidden_columns; empty string = hide nothing
    * `cols`      — comma list of table columns, e.g. "thumb,name,qty"
                    (unknown names map to :invalid_column so the modal's
                    own validation raise can be exercised)
    * `two`       — "true" mounts a SECOND picker (id-uniqueness tests)
    * `ch`        — "false" turns the context header off
    * `tray`      — "false" hides the cart button + review tray
    * `title`     — explicit modal title
  """

  use Phoenix.LiveView

  alias PhoenixKitCatalogue.Web.Components.CatalogueBrowse
  alias PhoenixKitCatalogue.Web.Components.ItemSelectorModal

  @impl true
  def mount(params, _session, socket) do
    scope = build_scope(params)

    selected =
      (params["pre"] || "")
      |> String.split(",", trim: true)
      |> Map.new(fn pair ->
        [uuid, qty] = String.split(pair, ":")
        {uuid, Decimal.new(qty)}
      end)

    {:ok,
     assign(socket,
       show: true,
       scope: scope,
       selected: selected,
       mode: if(params["mode"] == "single", do: :single, else: :multiple),
       immediate: params["immediate"] == "true",
       precision: String.to_integer(params["precision"] || "0"),
       min: params["min"] && String.to_integer(params["min"]),
       max: params["max"] && String.to_integer(params["max"]),
       view: params["view"],
       sel: params["sel"],
       cols: parse_cols(params["cols"]),
       hide: params["hide"] && parse_cols(params["hide"]) |> List.wrap(),
       show_prices: params["hide_prices"] != "true",
       context_header: params["ch"] != "false",
       show_tray: params["tray"] != "false",
       show_item_details: params["details"] != "false",
       title: params["title"],
       per_page: params["pp"] && String.to_integer(params["pp"]),
       two: params["two"] == "true",
       browse: params["browse"] == "true",
       browse_click: params["bclick"] != "false",
       clicked: nil,
       picked: nil,
       closed: false
     )}
  end

  defp build_scope(params) do
    %{}
    |> maybe_put_catalogue(params["c"])
    |> maybe_put_category(params["cat_scope"])
    |> maybe_put_only(params["only"])
    |> maybe_put_statuses(params["statuses"])
  end

  defp maybe_put_catalogue(scope, nil), do: scope
  defp maybe_put_catalogue(scope, uuid), do: Map.put(scope, :catalogue_uuids, [uuid])

  defp maybe_put_category(scope, nil), do: scope
  defp maybe_put_category(scope, uuid), do: Map.put(scope, :category_uuids, [uuid])

  defp maybe_put_only(scope, "uncategorized"), do: Map.put(scope, :only, :uncategorized_only)
  defp maybe_put_only(scope, "categorized"), do: Map.put(scope, :only, :categorized_only)
  defp maybe_put_only(scope, _), do: scope

  @col_atoms Map.new(
               ~w(thumb breadcrumb name sku manufacturer category unit price base_price qty),
               &{&1, String.to_atom(&1)}
             )

  defp parse_cols(nil), do: nil

  defp parse_cols(raw) do
    raw
    |> String.split(",", trim: true)
    |> Enum.map(&(@col_atoms[&1] || :invalid_column))
  end

  defp maybe_put_statuses(scope, nil), do: scope

  defp maybe_put_statuses(scope, raw),
    do: Map.put(scope, :statuses, String.split(raw, ",", trim: true))

  @impl true
  def handle_event("toggle_prices", _params, socket),
    do: {:noreply, assign(socket, :show_prices, !socket.assigns.show_prices)}

  # Unmount/remount the picker WITHOUT a fresh page mount — the host's
  # own assigns (current_user included) stay as stale as a real host's
  # would across a close + reopen.
  def handle_event("toggle_show", _params, socket),
    do: {:noreply, assign(socket, :show, !socket.assigns.show)}

  @impl true
  def handle_info({:items_selected, payload}, socket) do
    {:noreply,
     assign(socket,
       picked: payload,
       picked_count: (socket.assigns[:picked_count] || 0) + 1
     )}
  end

  def handle_info({:catalogue_browse, %{event: :item_clicked, item: item}}, socket),
    do: {:noreply, assign(socket, clicked: item)}

  def handle_info({:item_selector_closed, %{id: _}}, socket),
    do: {:noreply, assign(socket, closed: true)}

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.live_component
        :if={@browse}
        module={CatalogueBrowse}
        id="surface"
        scope={@scope}
        on_item_click={@browse_click}
      />
      <.live_component
        :if={@show and not @browse}
        module={ItemSelectorModal}
        id="picker"
        scope={@scope}
        selected={@selected}
        mode={@mode}
        immediate={@immediate}
        qty_precision={@precision}
        qty_min={@min}
        qty_max={@max}
        view={@view}
        selection_mode={@sel}
        columns={@cols}
        hidden_columns={@hide}
        show_prices={@show_prices}
        context_header={@context_header}
        show_tray={@show_tray}
        show_item_details={@show_item_details}
        title={@title}
        per_page={@per_page}
        current_user={Map.get(assigns, :phoenix_kit_current_user)}
      />
      <.live_component
        :if={@show and @two}
        module={ItemSelectorModal}
        id="picker2"
        scope={@scope}
        selected={%{}}
      />

      <%!-- The contract, made assertable. --%>
      <div :if={@clicked} id="clicked">{@clicked.name}|{@clicked.sku}</div>
      <div :if={@picked} id="picked">
        <span id="picked-count">{length(@picked.picks)}</span>
        <span id="picked-messages">{@picked_count}</span>
        <div :for={pick <- @picked.picks} id={"pick-#{pick.uuid}"}>
          {pick.name}|{pick.sku}|qty={Decimal.to_string(pick.qty, :normal)}|decimal={inspect(match?(%Decimal{}, pick.qty))}|line={pick.line_total && Decimal.to_string(pick.line_total, :normal)}
        </div>
      </div>
      <div :if={@closed} id="closed">closed</div>
    </div>
    """
  end
end
