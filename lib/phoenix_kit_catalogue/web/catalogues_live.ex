defmodule PhoenixKitCatalogue.Web.CataloguesLive do
  @moduledoc """
  Landing page for the Catalogue module.

  Handles three actions via tabs:
  - `:index` — list of catalogues
  - `:manufacturers` — list of manufacturers
  - `:suppliers` — list of suppliers
  """

  use Phoenix.LiveView

  require Logger

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Modal, only: [confirm_modal: 1]
  import PhoenixKitWeb.Components.Core.TableDefault
  import PhoenixKitWeb.Components.Core.TableRowMenu

  import PhoenixKitCatalogue.Web.Components

  import PhoenixKitCatalogue.Web.Helpers,
    only: [actor_opts: 1, actor_uuid: 1, log_operation_error: 3, status_label: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.PubSub
  alias PhoenixKitCatalogue.Paths

  @per_page 100

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: PubSub.subscribe()

    {:ok,
     assign(socket,
       page_title: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue"),
       catalogues: [],
       item_counts: %{},
       manufacturers: [],
       suppliers: [],
       confirm_delete: nil,
       catalogue_view_mode: "active",
       deleted_catalogue_count: 0,
       search_query: "",
       search_results: nil,
       search_offset: 0,
       search_total: 0,
       search_has_more: false,
       search_loading: false
     )}
  end

  # PubSub: re-load whichever tab is active when relevant data changes
  # in another LV process. Catch-all is required since the topic is
  # shared across all catalogue resources — we ignore events we don't
  # care about for the current tab.
  @impl true
  def handle_info({:catalogue_data_changed, kind, _uuid, _parent}, socket) do
    cond do
      socket.assigns.active_tab == :index and kind in [:catalogue, :item, :category] ->
        {:noreply, load_data(socket, :index)}

      socket.assigns.active_tab == :manufacturers and kind in [:manufacturer, :links] ->
        {:noreply, load_data(socket, :manufacturers)}

      socket.assigns.active_tab == :suppliers and kind in [:supplier, :links] ->
        {:noreply, load_data(socket, :suppliers)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info(msg, socket) do
    Logger.debug("CataloguesLive ignored unhandled message: #{inspect(msg)}")
    {:noreply, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    action = socket.assigns.live_action || :index

    socket =
      socket
      |> assign(:active_tab, action)
      |> assign(:page_title, tab_title(action))
      |> clear_search()
      |> load_data(action)

    {:noreply, socket}
  end

  defp tab_title(:index), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogues")

  defp tab_title(:manufacturers),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Manufacturers")

  defp tab_title(:suppliers), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Suppliers")

  # Graceful handler for a delete event that fires while `confirm_delete`
  # is nil (e.g. someone pushed the event without first opening the
  # modal). Clears the state, flashes a warning, and logs a warning
  # instead of crashing the LV.
  defp unexpected_confirm_event(socket, event_name) do
    Logger.warning(
      "CataloguesLive: #{event_name} fired without confirm_delete — assigns=#{inspect(socket.assigns.confirm_delete)} actor_uuid=#{inspect(actor_uuid(socket))}"
    )

    {:noreply,
     socket
     |> assign(:confirm_delete, nil)
     |> put_flash(
       :error,
       Gettext.gettext(PhoenixKitCatalogue.Gettext, "Unexpected request. Please try again.")
     )}
  end

  # actor_opts/1, actor_uuid/1, and log_operation_error/3 imported from
  # PhoenixKitCatalogue.Web.Helpers.

  defp load_data(socket, :index) do
    if connected?(socket) do
      mode = socket.assigns.catalogue_view_mode

      catalogues =
        if mode == "deleted",
          do: Catalogue.list_catalogues(status: "deleted"),
          else: Catalogue.list_catalogues()

      deleted_count = Catalogue.deleted_catalogue_count()

      # Auto-switch to active if no deleted catalogues
      mode = if deleted_count == 0 && mode == "deleted", do: "active", else: mode

      catalogues =
        if mode != socket.assigns.catalogue_view_mode,
          do: Catalogue.list_catalogues(),
          else: catalogues

      assign(socket,
        catalogues: catalogues,
        item_counts: Catalogue.item_counts_by_catalogue(),
        deleted_catalogue_count: deleted_count,
        catalogue_view_mode: mode
      )
    else
      socket
    end
  end

  defp load_data(socket, :manufacturers) do
    if connected?(socket),
      do: assign(socket, :manufacturers, Catalogue.list_manufacturers()),
      else: socket
  end

  defp load_data(socket, :suppliers) do
    if connected?(socket),
      do: assign(socket, :suppliers, Catalogue.list_suppliers()),
      else: socket
  end

  # ── Event handlers ──────────────────────────────────────────────

  @impl true
  def handle_event("switch_catalogue_view", %{"mode" => mode}, socket)
      when mode in ~w(active deleted) do
    {:noreply,
     socket
     |> assign(:catalogue_view_mode, mode)
     |> assign(:confirm_delete, nil)
     |> load_data(:index)}
  end

  def handle_event("reorder_catalogues", %{"ordered_ids" => ordered_ids}, socket)
      when is_list(ordered_ids) do
    case Catalogue.reorder_catalogues(ordered_ids, actor_opts(socket)) do
      :ok ->
        {:noreply, load_data(socket, :index)}

      {:error, reason} ->
        log_operation_error(socket, "reorder_catalogues", %{reason: reason})

        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to save the new order.")
         )}
    end
  end

  def handle_event("trash_catalogue", %{"uuid" => uuid}, socket) do
    with %{} = catalogue <- Catalogue.get_catalogue(uuid),
         {:ok, _} <- Catalogue.trash_catalogue(catalogue, actor_opts(socket)) do
      {:noreply,
       socket
       |> put_flash(
         :info,
         Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue moved to deleted.")
       )
       |> assign(:confirm_delete, nil)
       |> load_data(:index)}
    else
      nil ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue not found.")
         )
         |> load_data(:index)}

      {:error, reason} ->
        log_operation_error(socket, "trash_catalogue", %{
          entity_type: "catalogue",
          entity_uuid: uuid,
          reason: reason
        })

        {:noreply,
         socket
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to delete catalogue.")
         )
         |> load_data(:index)}
    end
  end

  def handle_event("restore_catalogue", %{"uuid" => uuid}, socket) do
    with %{} = catalogue <- Catalogue.get_catalogue(uuid),
         {:ok, _} <- Catalogue.restore_catalogue(catalogue, actor_opts(socket)) do
      {:noreply,
       socket
       |> put_flash(:info, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue restored."))
       |> assign(:confirm_delete, nil)
       |> load_data(:index)}
    else
      nil ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue not found.")
         )
         |> load_data(:index)}

      {:error, reason} ->
        log_operation_error(socket, "restore_catalogue", %{
          entity_type: "catalogue",
          entity_uuid: uuid,
          reason: reason
        })

        {:noreply,
         socket
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to restore catalogue.")
         )
         |> load_data(:index)}
    end
  end

  def handle_event("show_delete_confirm", %{"uuid" => uuid, "type" => type}, socket) do
    {:noreply, assign(socket, :confirm_delete, {type, uuid})}
  end

  def handle_event("permanently_delete_catalogue", _params, socket) do
    case socket.assigns.confirm_delete do
      {"catalogue", uuid} ->
        with %{} = catalogue <- Catalogue.get_catalogue(uuid),
             {:ok, _} <-
               Catalogue.permanently_delete_catalogue(catalogue, actor_opts(socket)) do
          {:noreply,
           socket
           |> put_flash(
             :info,
             Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue permanently deleted.")
           )
           |> assign(:confirm_delete, nil)
           |> load_data(:index)}
        else
          nil ->
            {:noreply,
             socket
             |> assign(:confirm_delete, nil)
             |> put_flash(
               :error,
               Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue not found.")
             )
             |> load_data(:index)}

          {:error, reason} ->
            log_operation_error(socket, "permanently_delete_catalogue", %{
              entity_type: "catalogue",
              entity_uuid: uuid,
              reason: reason
            })

            {:noreply,
             socket
             |> assign(:confirm_delete, nil)
             |> put_flash(
               :error,
               Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to delete catalogue.")
             )
             |> load_data(:index)}
        end

      _ ->
        unexpected_confirm_event(socket, "permanently_delete_catalogue")
    end
  end

  def handle_event("delete_manufacturer", _params, socket) do
    case socket.assigns.confirm_delete do
      {"manufacturer", uuid} ->
        with %{} = manufacturer <- Catalogue.get_manufacturer(uuid),
             {:ok, _} <- Catalogue.delete_manufacturer(manufacturer, actor_opts(socket)) do
          {:noreply,
           assign(socket, manufacturers: Catalogue.list_manufacturers(), confirm_delete: nil)}
        else
          nil ->
            {:noreply, assign(socket, :confirm_delete, nil)}

          {:error, reason} ->
            log_operation_error(socket, "delete_manufacturer", %{
              entity_type: "manufacturer",
              entity_uuid: uuid,
              reason: reason
            })

            {:noreply,
             socket
             |> put_flash(
               :error,
               Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to delete manufacturer.")
             )
             |> assign(:confirm_delete, nil)}
        end

      _ ->
        unexpected_confirm_event(socket, "delete_manufacturer")
    end
  end

  def handle_event("delete_supplier", _params, socket) do
    case socket.assigns.confirm_delete do
      {"supplier", uuid} ->
        with %{} = supplier <- Catalogue.get_supplier(uuid),
             {:ok, _} <- Catalogue.delete_supplier(supplier, actor_opts(socket)) do
          {:noreply, assign(socket, suppliers: Catalogue.list_suppliers(), confirm_delete: nil)}
        else
          nil ->
            {:noreply, assign(socket, :confirm_delete, nil)}

          {:error, reason} ->
            log_operation_error(socket, "delete_supplier", %{
              entity_type: "supplier",
              entity_uuid: uuid,
              reason: reason
            })

            {:noreply,
             socket
             |> put_flash(
               :error,
               Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to delete supplier.")
             )
             |> assign(:confirm_delete, nil)}
        end

      _ ->
        unexpected_confirm_event(socket, "delete_supplier")
    end
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :confirm_delete, nil)}
  end

  def handle_event("search", %{"query" => query}, socket) do
    query = String.trim(query)

    if query == "" do
      {:noreply, clear_search(socket)}
    else
      {:noreply, run_search(socket, query)}
    end
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply, clear_search(socket)}
  end

  def handle_event("load_more", _params, socket) do
    if socket.assigns.search_results != nil and socket.assigns.search_has_more and
         not socket.assigns.search_loading do
      {:noreply, start_search_page(socket)}
    else
      {:noreply, socket}
    end
  end

  # ── Search helpers ──────────────────────────────────────────────

  # Runs a fresh search query asynchronously. If a prior search is still
  # in flight, `start_async/3` cancels it — so fast typing (type-pause-
  # type-pause) doesn't flash stale intermediate results as each old
  # request lands out of order. The actual assign happens in
  # `handle_async(:search, ...)`, guarded by a query equality check.
  defp run_search(socket, query) do
    socket
    |> assign(search_query: query, search_loading: true)
    |> start_async(:search, fn ->
      results = Catalogue.search_items(query, limit: @per_page, offset: 0)
      total = Catalogue.count_search_items(query)
      {query, results, total}
    end)
  end

  @impl true
  def handle_async(:search, {:ok, {query, results, total}}, socket) do
    # Only apply if the user is still asking for this query. A late
    # response for a query the user has already superseded gets dropped.
    if socket.assigns.search_query == query do
      {:noreply,
       assign(socket,
         search_results: results,
         search_offset: length(results),
         search_total: total,
         search_has_more: length(results) < total,
         search_loading: false
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:search, {:exit, reason}, socket) do
    # Cancellations (reason `:shutdown` / `:killed` / `{:shutdown, _}`) are
    # expected when a newer query supersedes a pending one — the newer
    # handler owns `search_loading`, so leave the socket alone. For any
    # other exit (crashed DB query, timeout, raise in the task fn) clear
    # loading and flash the user so they don't stare at a perpetual
    # spinner, and log so we can debug without reproducing.
    case reason do
      r when r in [:shutdown, :killed] ->
        {:noreply, socket}

      {:shutdown, _} ->
        {:noreply, socket}

      other ->
        Logger.warning(
          "CataloguesLive search task exited unexpectedly: reason=#{inspect(other)} query=#{inspect(socket.assigns.search_query)} actor_uuid=#{inspect(actor_uuid(socket))}"
        )

        {:noreply,
         socket
         |> assign(:search_loading, false)
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search failed. Please try again.")
         )}
    end
  end

  def handle_async(:search_page, {:ok, {query, offset, page}}, socket) do
    if socket.assigns.search_query == query and socket.assigns.search_offset == offset do
      new_offset = offset + length(page)
      has_more = page != [] and new_offset < socket.assigns.search_total

      {:noreply,
       assign(socket,
         search_results: (socket.assigns.search_results || []) ++ page,
         search_offset: new_offset,
         search_has_more: has_more,
         search_loading: false
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:search_page, {:exit, reason}, socket) do
    case reason do
      r when r in [:shutdown, :killed] ->
        {:noreply, socket}

      {:shutdown, _} ->
        {:noreply, socket}

      other ->
        Logger.warning(
          "CataloguesLive search_page task exited unexpectedly: reason=#{inspect(other)} query=#{inspect(socket.assigns.search_query)} offset=#{socket.assigns.search_offset} actor_uuid=#{inspect(actor_uuid(socket))}"
        )

        {:noreply,
         socket
         |> assign(:search_loading, false)
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search failed. Please try again.")
         )}
    end
  end

  # Global-search paging runs off-process for the same reason the
  # per-catalogue detail view does: the ILIKE-against-jsonb-as-text
  # query doesn't hit an index and can take hundreds of ms on large
  # datasets. `handle_async(:search_page, …)` guards on `{query, offset}`
  # so a superseding new search or a stale page can't double-append.
  defp start_search_page(socket) do
    %{search_query: query, search_offset: offset} = socket.assigns

    socket
    |> assign(:search_loading, true)
    |> start_async(:search_page, fn ->
      page = Catalogue.search_items(query, limit: @per_page, offset: offset)
      {query, offset, page}
    end)
  end

  defp clear_search(socket) do
    assign(socket,
      search_query: "",
      search_results: nil,
      search_offset: 0,
      search_total: 0,
      search_has_more: false,
      search_loading: false
    )
  end

  # ── Render ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-5xl px-4 py-6 gap-6">
      <%!-- Tab navigation --%>
      <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3">
        <div role="tablist" class="tabs tabs-bordered">
          <.link
            patch={Paths.index()}
            class={["tab", @active_tab == :index && "tab-active"]}
          >
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogues")}
          </.link>
          <.link
            patch={Paths.manufacturers()}
            class={["tab", @active_tab == :manufacturers && "tab-active"]}
          >
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Manufacturers")}
          </.link>
          <.link
            patch={Paths.suppliers()}
            class={["tab", @active_tab == :suppliers && "tab-active"]}
          >
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Suppliers")}
          </.link>
        </div>

        <div class="self-end sm:self-auto">
          <.link :if={@active_tab == :index && @catalogue_view_mode == "active"} navigate={Paths.catalogue_new()} class="btn btn-primary btn-sm">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "New Catalogue")}
          </.link>
          <.link :if={@active_tab == :manufacturers} navigate={Paths.manufacturer_new()} class="btn btn-primary btn-sm">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "New Manufacturer")}
          </.link>
          <.link :if={@active_tab == :suppliers} navigate={Paths.supplier_new()} class="btn btn-primary btn-sm">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "New Supplier")}
          </.link>
        </div>
      </div>

      <%!-- Global search (only on catalogues tab) --%>
      <.search_input :if={@active_tab == :index} query={@search_query} placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search items across all catalogues...")} />

      <%!-- Search results (visible when the user has typed a query) --%>
      <div :if={@search_results != nil or @search_loading} class="flex flex-col gap-4">
        <%!-- Status line: spinner while loading, "X of Y results" when settled --%>
        <div class="flex items-center gap-2">
          <%= if @search_loading and is_nil(@search_results) do %>
            <span class="text-sm text-base-content/60">
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Searching for \"%{query}\"...", query: @search_query)}
            </span>
          <% else %>
            <.search_results_summary :if={@search_results != nil} count={@search_total} query={@search_query} loaded={length(@search_results)} />
          <% end %>
          <span :if={@search_loading} class="loading loading-spinner loading-xs text-base-content/40"></span>
        </div>

        <.empty_state :if={@search_results == [] and not @search_loading} message={Gettext.gettext(PhoenixKitCatalogue.Gettext, "No items match your search.")} />

        <%!-- Stale results are dimmed while a newer query is in flight to
             signal that the list is about to update. --%>
        <div :if={@search_results not in [nil, []]} class={["transition-opacity", @search_loading && "opacity-50"]}>
          <.item_table
            items={@search_results}
            columns={[:name, :sku, :base_price, :catalogue, :category, :manufacturer, :status]}
            variant="zebra"
            edit_path={&Paths.item_edit/1}
            catalogue_path={&Paths.catalogue_detail/1}
            cards={true}
            id="global-search-items"
          />
        </div>

        <%!-- Infinite-scroll sentinel for global search --%>
        <div
          :if={@search_has_more and not @search_loading}
          id="catalogues-search-load-more-sentinel"
          phx-hook="InfiniteScroll"
          data-cursor={"global-search-#{@search_offset}"}
          class="py-4"
        >
          <div class="flex justify-center">
            <span class="loading loading-spinner loading-sm text-base-content/30"></span>
          </div>
        </div>
      </div>

      <%!-- Catalogue tab content --%>
      <div :if={@active_tab == :index and is_nil(@search_results) and not @search_loading} class="flex flex-col gap-4">
        <%!-- Status sub-tabs for catalogues --%>
        <div :if={@deleted_catalogue_count > 0} class="flex items-center gap-0.5 border-b border-base-200">
          <button
            type="button"
            phx-click="switch_catalogue_view"
            phx-value-mode="active"
            class={[
              "px-3 py-1.5 text-xs font-medium border-b-2 transition-colors cursor-pointer",
              if(@catalogue_view_mode == "active",
                do: "border-primary text-primary",
                else: "border-transparent text-base-content/50 hover:text-base-content"
              )
            ]}
          >
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Active")}
          </button>
          <button
            type="button"
            phx-click="switch_catalogue_view"
            phx-value-mode="deleted"
            class={[
              "px-3 py-1.5 text-xs font-medium border-b-2 transition-colors cursor-pointer",
              if(@catalogue_view_mode == "deleted",
                do: "border-error text-error",
                else: "border-transparent text-base-content/50 hover:text-base-content"
              )
            ]}
          >
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Deleted")} ({@deleted_catalogue_count})
          </button>
        </div>

        <.catalogues_table catalogues={@catalogues} item_counts={@item_counts} view_mode={@catalogue_view_mode} />
      </div>

      <div :if={@active_tab == :manufacturers and is_nil(@search_results)}>
        <.manufacturers_table manufacturers={@manufacturers} />
      </div>

      <div :if={@active_tab == :suppliers and is_nil(@search_results)}>
        <.suppliers_table suppliers={@suppliers} />
      </div>

      <.confirm_modal
        show={match?({"catalogue", _}, @confirm_delete)}
        on_confirm="permanently_delete_catalogue"
        on_cancel="cancel_delete"
        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Permanently Delete Catalogue")}
        title_icon="hero-trash"
        messages={[{:warning, Gettext.gettext(PhoenixKitCatalogue.Gettext, "This will permanently delete this catalogue, all its categories, and all items. This cannot be undone.")}]}
        confirm_text={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete Forever")}
        danger={true}
      />

      <.confirm_modal
        show={match?({"manufacturer", _}, @confirm_delete)}
        on_confirm="delete_manufacturer"
        on_cancel="cancel_delete"
        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete Manufacturer")}
        title_icon="hero-trash"
        messages={[{:warning, Gettext.gettext(PhoenixKitCatalogue.Gettext, "This will permanently delete this manufacturer. Items referencing it will lose the association.")}]}
        confirm_text={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")}
        danger={true}
      />

      <.confirm_modal
        show={match?({"supplier", _}, @confirm_delete)}
        on_confirm="delete_supplier"
        on_cancel="cancel_delete"
        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete Supplier")}
        title_icon="hero-trash"
        messages={[{:warning, Gettext.gettext(PhoenixKitCatalogue.Gettext, "This will permanently delete this supplier. Manufacturer links will be removed.")}]}
        confirm_text={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")}
        danger={true}
      />
    </div>

    <script>
      window.PhoenixKitHooks = window.PhoenixKitHooks || {};
      window.PhoenixKitHooks.InfiniteScroll = window.PhoenixKitHooks.InfiniteScroll || {
        mounted() {
          this.intersecting = false;
          this.observer = new IntersectionObserver((entries) => {
            this.intersecting = entries[0].isIntersecting;
            if (this.intersecting) {
              this.pushEvent("load_more", {});
            }
          }, { rootMargin: "200px" });
          this.observer.observe(this.el);
        },
        updated() {
          // IntersectionObserver only fires on state transitions. When the
          // viewport is tall or the user jumped via Page Down / resize, the
          // sentinel stays continuously in view across batches — so the
          // observer goes silent after the first fire. Re-trigger explicitly
          // whenever the server patches us while we're still on-screen.
          // The server's `loading` guard dedupes duplicate events.
          if (this.intersecting) {
            this.pushEvent("load_more", {});
          }
        },
        destroyed() {
          this.observer.disconnect();
        }
      };
    </script>
    """
  end

  defp build_catalogue_card_fields("active", item_counts) do
    fn c ->
      [
        %{
          label: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Items"),
          value: Map.get(item_counts, c.uuid, 0)
        },
        %{
          label: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Status"),
          value: status_label(c.status)
        },
        %{
          label: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Updated"),
          value: Calendar.strftime(c.updated_at, "%Y-%m-%d %H:%M")
        }
      ]
    end
  end

  defp build_catalogue_card_fields("deleted", _item_counts) do
    fn c ->
      [
        %{
          label: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Status"),
          value: status_label(c.status)
        },
        %{
          label: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Updated"),
          value: Calendar.strftime(c.updated_at, "%Y-%m-%d %H:%M")
        }
      ]
    end
  end

  defp catalogues_table(assigns) do
    ~H"""
    <div :if={@catalogues == []} class="card bg-base-100 shadow">
      <div class="card-body items-center text-center py-12">
        <p class="text-base-content/60">
          {if @view_mode == "deleted", do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "No deleted catalogues."), else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "No catalogues yet.")}
        </p>
      </div>
    </div>

    <div :if={@catalogues != []}>
      <.table_default
        variant="zebra" size="sm" toggleable={true}
        id={"catalogues-#{@view_mode}"} items={@catalogues}
        on_reorder="reorder_catalogues"
        item_id={fn cat -> cat.uuid end}
        card_fields={build_catalogue_card_fields(@view_mode, @item_counts)}
      >
        <.table_default_header>
          <.table_default_row>
            <.table_default_header_cell :if={length(@catalogues) > 1} class="w-8"></.table_default_header_cell>
            <.table_default_header_cell>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Name")}</.table_default_header_cell>
            <.table_default_header_cell :if={@view_mode == "active"} class="text-right">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Items")}</.table_default_header_cell>
            <.table_default_header_cell>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Status")}</.table_default_header_cell>
            <.table_default_header_cell>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Updated")}</.table_default_header_cell>
            <.table_default_header_cell class="text-right whitespace-nowrap">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Actions")}</.table_default_header_cell>
          </.table_default_row>
        </.table_default_header>
        <tbody
          id={"catalogues-tbody-#{@view_mode}"}
          data-sortable="true"
          data-sortable-event="reorder_catalogues"
          data-sortable-items=".sortable-item"
          data-sortable-hide-source="false"
          data-sortable-handle=".pk-drag-handle"
          phx-hook="SortableGrid"
        >
          <.table_default_row :for={catalogue <- @catalogues} class="sortable-item" data-id={catalogue.uuid}>
            <.table_default_cell
              :if={length(@catalogues) > 1}
              class="pk-drag-handle cursor-grab active:cursor-grabbing text-base-content/40"
            >
              <.icon name="hero-bars-3" class="w-4 h-4" />
            </.table_default_cell>
            <.table_default_cell>
              <.link :if={@view_mode == "active"} navigate={Paths.catalogue_detail(catalogue.uuid)} class="link link-hover font-medium">
                {catalogue.name}
              </.link>
              <span :if={@view_mode == "deleted"} class="font-medium text-base-content/50">{catalogue.name}</span>
            </.table_default_cell>
            <.table_default_cell :if={@view_mode == "active"} class="text-right tabular-nums">
              {Map.get(@item_counts, catalogue.uuid, 0)}
            </.table_default_cell>
            <.table_default_cell><.status_badge status={catalogue.status} size={:sm} /></.table_default_cell>
            <.table_default_cell class="text-sm text-base-content/60">
              {Calendar.strftime(catalogue.updated_at, "%Y-%m-%d %H:%M")}
            </.table_default_cell>
            <%!-- Active mode actions --%>
            <.table_default_cell :if={@view_mode == "active"} class="text-right whitespace-nowrap">
              <.table_row_menu mode="auto" id={"cat-menu-#{catalogue.uuid}"}>
                <.table_row_menu_link navigate={Paths.catalogue_detail(catalogue.uuid)} icon="hero-eye" label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "View")} />
                <.table_row_menu_link navigate={Paths.catalogue_edit(catalogue.uuid)} icon="hero-pencil" label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit")} variant="secondary" />
                <.table_row_menu_divider />
                <.table_row_menu_button phx-click="trash_catalogue" phx-value-uuid={catalogue.uuid} phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Deleting...")} icon="hero-trash" label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")} variant="error" />
              </.table_row_menu>
            </.table_default_cell>
            <%!-- Deleted mode actions --%>
            <.table_default_cell :if={@view_mode == "deleted"} class="text-right whitespace-nowrap">
              <.table_row_menu mode="auto" id={"cat-del-menu-#{catalogue.uuid}"}>
                <.table_row_menu_button phx-click="restore_catalogue" phx-value-uuid={catalogue.uuid} phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restoring...")} icon="hero-arrow-path" label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restore")} variant="success" />
                <.table_row_menu_divider />
                <.table_row_menu_button phx-click="show_delete_confirm" phx-value-uuid={catalogue.uuid} phx-value-type="catalogue" icon="hero-trash" label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete Forever")} variant="error" />
              </.table_row_menu>
            </.table_default_cell>
          </.table_default_row>
        </tbody>
        <:card_header :let={catalogue}>
          <.link :if={@view_mode == "active"} navigate={Paths.catalogue_detail(catalogue.uuid)} class="font-medium text-sm link link-hover">{catalogue.name}</.link>
          <span :if={@view_mode == "deleted"} class="font-medium text-sm text-base-content/50">{catalogue.name}</span>
        </:card_header>
        <:card_actions :let={catalogue} :if={@view_mode == "active"}>
          <.link navigate={Paths.catalogue_detail(catalogue.uuid)} class="btn btn-ghost btn-xs">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "View")}</.link>
          <.link navigate={Paths.catalogue_edit(catalogue.uuid)} class="btn btn-ghost btn-xs">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit")}</.link>
          <button phx-click="trash_catalogue" phx-value-uuid={catalogue.uuid} phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Deleting...")} class="btn btn-ghost btn-xs text-error">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")}</button>
        </:card_actions>
        <:card_actions :let={catalogue} :if={@view_mode == "deleted"}>
          <button phx-click="restore_catalogue" phx-value-uuid={catalogue.uuid} phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restoring...")} class="btn btn-ghost btn-xs text-success">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restore")}</button>
          <button phx-click="show_delete_confirm" phx-value-uuid={catalogue.uuid} phx-value-type="catalogue" class="btn btn-ghost btn-xs text-error">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete Forever")}</button>
        </:card_actions>
      </.table_default>
    </div>
    """
  end

  defp manufacturers_table(assigns) do
    ~H"""
    <div :if={@manufacturers == []} class="card bg-base-100 shadow">
      <div class="card-body items-center text-center py-12">
        <p class="text-base-content/60">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "No manufacturers yet.")}</p>
      </div>
    </div>

    <div :if={@manufacturers != []}>
      <.table_default
        variant="zebra" size="sm" toggleable={true}
        id="manufacturers-list" items={@manufacturers}
        card_fields={fn m -> [
          %{label: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Website"), value: m.website || "—"},
          %{label: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Status"), value: status_label(m.status)}
        ] end}
      >
        <.table_default_header>
          <.table_default_row>
            <.table_default_header_cell>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Name")}</.table_default_header_cell>
            <.table_default_header_cell>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Website")}</.table_default_header_cell>
            <.table_default_header_cell>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Status")}</.table_default_header_cell>
            <.table_default_header_cell class="text-right whitespace-nowrap">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Actions")}</.table_default_header_cell>
          </.table_default_row>
        </.table_default_header>
        <.table_default_body>
          <.table_default_row :for={m <- @manufacturers}>
            <.table_default_cell class="font-medium">
              <.link navigate={Paths.manufacturer_edit(m.uuid)} class="link link-hover">
                {m.name}
              </.link>
            </.table_default_cell>
            <.table_default_cell class="text-sm text-base-content/60">{m.website}</.table_default_cell>
            <.table_default_cell><.status_badge status={m.status} size={:sm} /></.table_default_cell>
            <.table_default_cell class="text-right whitespace-nowrap">
              <.table_row_menu mode="auto" id={"mfg-menu-#{m.uuid}"}>
                <.table_row_menu_link navigate={Paths.manufacturer_edit(m.uuid)} icon="hero-pencil" label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit")} />
                <.table_row_menu_divider />
                <.table_row_menu_button phx-click="show_delete_confirm" phx-value-uuid={m.uuid} phx-value-type="manufacturer" icon="hero-trash" label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")} variant="error" />
              </.table_row_menu>
            </.table_default_cell>
          </.table_default_row>
        </.table_default_body>
        <:card_header :let={m}>
          <.link navigate={Paths.manufacturer_edit(m.uuid)} class="font-medium text-sm link link-hover">{m.name}</.link>
        </:card_header>
        <:card_actions :let={m}>
          <.link navigate={Paths.manufacturer_edit(m.uuid)} class="btn btn-ghost btn-xs">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit")}</.link>
          <button phx-click="show_delete_confirm" phx-value-uuid={m.uuid} phx-value-type="manufacturer" class="btn btn-ghost btn-xs text-error">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")}</button>
        </:card_actions>
      </.table_default>
    </div>
    """
  end

  defp suppliers_table(assigns) do
    ~H"""
    <div :if={@suppliers == []} class="card bg-base-100 shadow">
      <div class="card-body items-center text-center py-12">
        <p class="text-base-content/60">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "No suppliers yet.")}</p>
      </div>
    </div>

    <div :if={@suppliers != []}>
      <.table_default
        variant="zebra" size="sm" toggleable={true}
        id="suppliers-list" items={@suppliers}
        card_fields={fn s -> [
          %{label: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Website"), value: s.website || "—"},
          %{label: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Status"), value: status_label(s.status)}
        ] end}
      >
        <.table_default_header>
          <.table_default_row>
            <.table_default_header_cell>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Name")}</.table_default_header_cell>
            <.table_default_header_cell>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Website")}</.table_default_header_cell>
            <.table_default_header_cell>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Status")}</.table_default_header_cell>
            <.table_default_header_cell class="text-right whitespace-nowrap">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Actions")}</.table_default_header_cell>
          </.table_default_row>
        </.table_default_header>
        <.table_default_body>
          <.table_default_row :for={s <- @suppliers}>
            <.table_default_cell class="font-medium">
              <.link navigate={Paths.supplier_edit(s.uuid)} class="link link-hover">
                {s.name}
              </.link>
            </.table_default_cell>
            <.table_default_cell class="text-sm text-base-content/60">{s.website}</.table_default_cell>
            <.table_default_cell><.status_badge status={s.status} size={:sm} /></.table_default_cell>
            <.table_default_cell class="text-right whitespace-nowrap">
              <.table_row_menu mode="auto" id={"supplier-menu-#{s.uuid}"}>
                <.table_row_menu_link navigate={Paths.supplier_edit(s.uuid)} icon="hero-pencil" label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit")} variant="secondary" />
                <.table_row_menu_divider />
                <.table_row_menu_button phx-click="show_delete_confirm" phx-value-uuid={s.uuid} phx-value-type="supplier" icon="hero-trash" label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")} variant="error" />
              </.table_row_menu>
            </.table_default_cell>
          </.table_default_row>
        </.table_default_body>
        <:card_header :let={s}>
          <.link navigate={Paths.supplier_edit(s.uuid)} class="font-medium text-sm link link-hover">{s.name}</.link>
        </:card_header>
        <:card_actions :let={s}>
          <.link navigate={Paths.supplier_edit(s.uuid)} class="btn btn-ghost btn-xs">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit")}</.link>
          <button phx-click="show_delete_confirm" phx-value-uuid={s.uuid} phx-value-type="supplier" class="btn btn-ghost btn-xs text-error">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")}</button>
        </:card_actions>
      </.table_default>
    </div>
    """
  end
end
