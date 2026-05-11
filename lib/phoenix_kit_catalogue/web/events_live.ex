defmodule PhoenixKitCatalogue.Web.EventsLive do
  @moduledoc """
  LiveView for the catalogue activity events subtab.

  Displays a filterable, infinite-scroll list of activity entries
  scoped to the "catalogue" module using LiveView streams.
  """

  use Phoenix.LiveView

  require Logger

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Select, only: [select: 1]

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitCatalogue.Paths

  @per_page 20

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Events"),
       total: 0,
       page: 1,
       has_more: false,
       loading: false,
       filter_action: nil,
       filter_resource_type: nil,
       action_types: [],
       resource_types: []
     )
     |> stream(:entries, [], dom_id: &"entry-#{&1.uuid}")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      if connected?(socket) do
        socket
        |> apply_params(params)
        |> assign(:page, 1)
        |> load_filter_options()
        |> reset_and_load()
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter", params, socket) do
    filter = Map.get(params, "filter", %{})

    query_params =
      %{}
      |> maybe_put("action", filter["action"])
      |> maybe_put("resource_type", filter["resource_type"])

    path =
      case URI.encode_query(query_params) do
        "" -> Paths.events()
        query -> Paths.events() <> "?#{query}"
      end

    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: Paths.events())}
  end

  @impl true
  def handle_event("load_more", _params, socket) do
    if socket.assigns.has_more and not socket.assigns.loading do
      {:noreply, socket |> assign(:loading, true) |> load_next_page()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(msg, socket) do
    Logger.debug("EventsLive ignored unhandled message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # ── Private ──────────────────────────────────────────────────────

  defp apply_params(socket, params) do
    socket
    |> assign(:filter_action, blank_to_nil(params["action"]))
    |> assign(:filter_resource_type, blank_to_nil(params["resource_type"]))
  end

  defp load_filter_options(socket) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      all = PhoenixKit.Activity.list(module: "catalogue", per_page: 1000, preload: [])

      action_types =
        all.entries |> Enum.map(& &1.action) |> Enum.uniq() |> Enum.sort()

      resource_types =
        all.entries
        |> Enum.map(& &1.resource_type)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()

      assign(socket, action_types: action_types, resource_types: resource_types)
    else
      socket
    end
  rescue
    _ -> socket
  end

  defp reset_and_load(socket) do
    socket
    |> assign(:page, 1)
    |> stream(:entries, [], reset: true, dom_id: &"entry-#{&1.uuid}")
    |> load_next_page()
  end

  defp load_next_page(socket) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      result =
        PhoenixKit.Activity.list(
          module: "catalogue",
          page: socket.assigns.page,
          per_page: @per_page,
          action: socket.assigns.filter_action,
          resource_type: socket.assigns.filter_resource_type,
          preload: [:actor]
        )

      socket
      |> stream(:entries, result.entries)
      |> assign(
        total: result.total,
        page: socket.assigns.page + 1,
        has_more: result.page < result.total_pages,
        loading: false
      )
    else
      assign(socket, loading: false)
    end
  rescue
    _ -> assign(socket, loading: false)
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(val), do: val

  # Translates the raw resource_type string for the filter dropdown.
  # `resource_types` is built from DB content and may surface unknown
  # types in the future — fall through to capitalize so they still
  # render readably.
  defp humanize_resource_type("item"), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Item")

  defp humanize_resource_type("category"),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category")

  defp humanize_resource_type("catalogue"),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue")

  defp humanize_resource_type("manufacturer"),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Manufacturer")

  defp humanize_resource_type("supplier"),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Supplier")

  defp humanize_resource_type("smart_rule"),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Smart rule")

  # Unknown resource types fall back to the raw key. Wrapping in
  # `String.capitalize/1` would pin English casing on a value the
  # gettext extractor can't see — better to surface the raw key so a
  # new resource_type triggers an obvious "we should add a literal
  # clause above" follow-up.
  defp humanize_resource_type(other) when is_binary(other), do: other
  defp humanize_resource_type(_), do: ""

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @action_color_keywords [
    {"created", "badge-success"},
    {"restored", "badge-info"},
    {"deleted", "badge-error"},
    {"trashed", "badge-error"},
    {"updated", "badge-warning"},
    {"changed", "badge-warning"},
    {"moved", "badge-info"},
    {"synced", "badge-info"},
    {"import", "badge-accent"}
  ]

  defp action_badge_color(action) do
    Enum.find_value(@action_color_keywords, "badge-ghost", fn {keyword, color} ->
      if String.contains?(action, keyword), do: color
    end)
  end

  defp mode_badge_class(mode) do
    case mode do
      "manual" -> "badge-warning"
      "auto" -> "badge-info"
      "cron" -> "badge-secondary"
      _ -> "badge-ghost"
    end
  end

  defp summarize_metadata(nil), do: nil

  defp summarize_metadata(meta) do
    meta
    |> Map.drop(["actor_role"])
    |> Enum.reject(fn {_k, v} -> v == nil or v == "" end)
    |> case do
      [] -> nil
      entries -> Enum.map_join(entries, ", ", fn {k, v} -> "#{k}: #{v}" end)
    end
  end

  defp format_time_ago(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 ->
        Gettext.gettext(PhoenixKitCatalogue.Gettext, "just now")

      diff < 3600 ->
        Gettext.gettext(PhoenixKitCatalogue.Gettext, "%{count}m ago", count: div(diff, 60))

      diff < 86_400 ->
        Gettext.gettext(PhoenixKitCatalogue.Gettext, "%{count}h ago", count: div(diff, 3600))

      diff < 604_800 ->
        Gettext.gettext(PhoenixKitCatalogue.Gettext, "%{count}d ago", count: div(diff, 86_400))

      true ->
        Calendar.strftime(datetime, "%b %d, %Y")
    end
  end

  # ── Render ───────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-5xl px-4 py-6 gap-4">
      <div class="flex items-center justify-between">
        <div class="text-sm text-base-content/60">
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "%{count} events", count: @total)}
        </div>
      </div>

      <%!-- Filters --%>
      <div class="bg-base-200 rounded-lg p-3">
        <.form for={%{}} phx-change="filter" class="flex flex-wrap gap-3 items-end">
          <div class="form-control">
            <.select
              name="filter[action]"
              id="events-filter-action"
              label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Action")}
              value={@filter_action}
              prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "All Actions")}
              options={Enum.map(@action_types, &{&1, &1})}
              class="select-sm"
            />
          </div>

          <div class="form-control">
            <.select
              name="filter[resource_type]"
              id="events-filter-resource"
              label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Resource")}
              value={@filter_resource_type}
              prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "All Types")}
              options={Enum.map(@resource_types, &{humanize_resource_type(&1), &1})}
              class="select-sm"
            />
          </div>

          <button type="button" phx-click="clear_filters" class="btn btn-ghost btn-sm">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Clear")}
          </button>
        </.form>
      </div>

      <%!-- Events Feed --%>
      <div id="events-feed" phx-update="stream" class="flex flex-col gap-2">
        <div
          :for={{dom_id, entry} <- @streams.entries}
          id={dom_id}
          class="card card-compact bg-base-100 shadow-sm border border-base-200"
        >
          <div class="card-body flex-row items-center gap-3 py-2 px-4">
            <%!-- Action badge --%>
            <div class="min-w-[140px]">
              <span class={"badge badge-sm #{action_badge_color(entry.action)}"}>
                {entry.action}
              </span>
            </div>

            <%!-- Mode --%>
            <div class="min-w-[60px]">
              <%= if entry.mode do %>
                <span class={"badge badge-xs #{mode_badge_class(entry.mode)}"}>
                  {entry.mode}
                </span>
              <% end %>
            </div>

            <%!-- Resource + name --%>
            <div class="flex-1 min-w-0">
              <%= if entry.resource_type do %>
                <span class="badge badge-ghost badge-xs">{entry.resource_type}</span>
                <%= if entry.metadata["name"] do %>
                  <span class="text-sm ml-1 font-medium">{entry.metadata["name"]}</span>
                <% end %>
              <% end %>
              <% summary = summarize_metadata(entry.metadata) %>
              <%= if summary do %>
                <span
                  class="text-xs text-base-content/50 ml-2 truncate inline-block max-w-[200px] align-bottom"
                  title={summary}
                >
                  {summary}
                </span>
              <% end %>
            </div>

            <%!-- Actor --%>
            <div class="text-sm text-base-content/70 hidden sm:block">
              <%= if entry.actor do %>
                {entry.actor.email}
              <% else %>
                <span class="text-base-content/40">System</span>
              <% end %>
            </div>

            <%!-- Time --%>
            <div class="text-xs text-base-content/50 min-w-[70px] text-right">
              {format_time_ago(entry.inserted_at)}
            </div>

            <%!-- Detail link --%>
            <.link
              navigate={Routes.path("/admin/activity/#{entry.uuid}")}
              class="btn btn-ghost btn-xs btn-square"
              title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "View details")}
            >
              <.icon name="hero-arrow-top-right-on-square" class="w-3.5 h-3.5" />
            </.link>
          </div>
        </div>
      </div>

      <%!-- Empty state --%>
      <%= if @total == 0 and not @loading do %>
        <div class="text-center py-12 text-base-content/60">
          <.icon name="hero-bell-slash" class="w-12 h-12 mx-auto mb-2 opacity-50" />
          <p>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "No events recorded yet")}</p>
        </div>
      <% end %>

      <%!-- Infinite scroll sentinel --%>
      <%= if @has_more do %>
        <div id="load-more-sentinel" phx-hook="InfiniteScroll" data-page={@page} class="py-4">
          <div class="flex justify-center">
            <span class="loading loading-spinner loading-sm text-base-content/30"></span>
          </div>
        </div>
      <% end %>

      <%= if not @has_more and @total > 0 do %>
        <div class="text-center text-xs text-base-content/40 py-2">
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "All events loaded")}
        </div>
      <% end %>
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
end
