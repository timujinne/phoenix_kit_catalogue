defmodule PhoenixKitCatalogue.Web.Components.AttributeSetItemsModal do
  @moduledoc """
  Read-only popup previewing the items attached to ONE attribute set —
  opened from the sets listing's Items count (Max's 2026-08-28
  direction: the count is the button; the preview is a popup, not a
  page). Each row: photo, name (links to the item editor), catalogue /
  category, selling price, the item's SELECTED values of this set
  (ghost-filtered), and status.

  Mount with

      <.live_component
        module={AttributeSetItemsModal}
        id={"attr-set-items-modal-\#{set.uuid}"}
        set={set}
        locale={@current_locale}
      />

  and render it only while open — the id carries the set uuid and the
  parent drops the component on close, so every open mounts fresh
  (stale search/page from a previous open is the media-selector trap).
  `set` needs `:uuid`, `:name` (display) and `:key` (entities slug).
  Closes by sending `{:attr_set_items_modal_closed}` to the parent.

  Scale rules as everywhere: server-side trimmed search, 25/page —
  a thousand attached items stay flat.
  """

  use Phoenix.LiveComponent

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Web.Components.Browse

  @page_size 25

  @impl true
  def mount(socket) do
    {:ok, assign(socket, search: "", page: 1)}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, id: assigns.id, set: assigns.set, locale: assigns[:locale])

    # Parent re-renders re-run update/2; the modal's own search/page
    # must survive them, so load only on the first pass.
    {:ok, if(socket.assigns[:loaded], do: socket, else: load(socket))}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) when is_binary(q) do
    {:noreply,
     socket
     |> assign(search: String.slice(q, 0, 200), page: 1)
     |> load()}
  end

  def handle_event("page", %{"dir" => dir}, socket) when dir in ["prev", "next"] do
    delta = if dir == "next", do: 1, else: -1

    {:noreply,
     socket
     |> assign(:page, socket.assigns.page + delta)
     |> load()}
  end

  def handle_event("close", _params, socket) do
    send(self(), {:attr_set_items_modal_closed})
    {:noreply, socket}
  end

  # Client-sent payloads, so every event above needs somewhere to land
  # that isn't a crashed LiveView.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp load(socket) do
    set = socket.assigns.set
    locale = socket.assigns.locale

    # The FULL value list in one query: item selections reference value
    # slugs anywhere in the set, so label resolution needs the whole
    # slug → title map (the chip strip on the listing stays capped).
    label_map =
      set.uuid
      |> Catalogue.list_attribute_set_values(lang: locale)
      |> Map.new(&{&1.slug, &1.title})

    search = socket.assigns.search
    total = Catalogue.count_attribute_set_attached_items(set.uuid, search: search)
    max_page = max(ceil(total / @page_size), 1)
    page = socket.assigns.page |> max(1) |> min(max_page)

    rows =
      Catalogue.list_attribute_set_attached_items(set.uuid,
        search: search,
        limit: @page_size,
        offset: (page - 1) * @page_size
      )

    entries = Browse.present_items(Enum.map(rows, & &1.item), locale)

    item_rows =
      Enum.zip_with(rows, entries, fn %{item: item, selected_slugs: slugs}, entry ->
        Map.merge(entry, %{
          status: item.status,
          catalogue_name: catalogue_name(item, locale),
          # Ghost rule: slugs whose value no longer exists are dropped,
          # exactly like every other selection reader.
          selected: slugs |> Enum.filter(&Map.has_key?(label_map, &1)) |> Enum.map(&label_map[&1])
        })
      end)

    assign(socket,
      loaded: true,
      rows: item_rows,
      total: total,
      page: page,
      max_page: max_page
    )
  end

  defp catalogue_name(%{catalogue: %{name: _} = catalogue}, locale) do
    (Catalogue.localize_one(catalogue, locale) || catalogue).name
  end

  defp catalogue_name(_item, _locale), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} phx-window-keydown="close" phx-key="Escape" phx-target={@myself}>
      <div
        class="modal modal-open"
        role="dialog"
        aria-modal="true"
        aria-labelledby={"#{@id}-title"}
      >
        <div class="modal-box max-w-3xl flex flex-col gap-3">
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <h3 id={"#{@id}-title"} class="font-semibold text-lg truncate">{@set.name}</h3>
              <p class="text-xs text-base-content/60 mt-0.5">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Items")} ({@total})
              </p>
            </div>
            <button
              type="button"
              phx-click="close"
              phx-target={@myself}
              class="btn btn-sm btn-ghost btn-circle"
              aria-label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Close")}
            >
              <.icon name="hero-x-mark" class="w-5 h-5" />
            </button>
          </div>

          <%!-- phx-submit is load-bearing (Enter would native-submit). --%>
          <form id={"#{@id}-search"} phx-change="search" phx-submit="search" phx-target={@myself}>
            <label class="input input-sm w-full flex items-center gap-2">
              <span class="hero-magnifying-glass w-4 h-4 opacity-60"></span>
              <input
                type="text"
                name="q"
                value={@search}
                placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search items…")}
                phx-debounce="250"
                autocomplete="off"
                spellcheck="false"
                class="grow"
              />
            </label>
          </form>

          <p
            :if={@total == 0 and String.trim(@search) != ""}
            class="text-sm text-base-content/60 py-6 text-center"
          >
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No items match your search.")}
          </p>

          <p
            :if={@total == 0 and String.trim(@search) == ""}
            class="text-sm text-base-content/60 py-6 text-center border border-dashed border-base-content/20 rounded-lg"
          >
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No items attached.")}
          </p>

          <div :if={@rows != []} class="flex flex-col divide-y divide-base-content/10">
            <div :for={row <- @rows} id={"#{@id}-item-#{row.uuid}"} class="flex items-center gap-3 py-2">
              <img
                :if={row.thumb_url}
                src={row.thumb_url}
                alt=""
                class="w-12 h-12 rounded object-cover bg-base-200 shrink-0"
                loading="lazy"
              />
              <div
                :if={!row.thumb_url}
                class="w-12 h-12 rounded bg-base-200 flex items-center justify-center shrink-0"
              >
                <.icon name="hero-photo" class="w-6 h-6 text-base-content/30" />
              </div>

              <div class="min-w-0 flex-1">
                <div class="flex items-center gap-2">
                  <.link
                    navigate={Paths.item_edit(row.uuid)}
                    class="font-medium link link-hover truncate"
                  >
                    {row.name}
                  </.link>
                  <span :if={row.status != "active"} class="badge badge-ghost badge-xs shrink-0">
                    {row.status}
                  </span>
                </div>
                <div class="text-xs text-base-content/60 truncate">
                  <span :if={row.catalogue_name}>{row.catalogue_name}</span><span :if={
                    row.catalogue_name && row.category
                  }> / </span><span :if={row.category}>{row.category}</span>
                </div>
                <div :if={row.selected != []} class="flex flex-wrap gap-1 mt-1">
                  <span :for={label <- row.selected} class="badge badge-outline badge-xs">
                    {label}
                  </span>
                </div>
              </div>

              <div class="text-sm whitespace-nowrap shrink-0">
                <span :if={row.price} class="font-medium">
                  {Browse.format_price(row.price)}<span
                    :if={row.unit}
                    class="text-base-content/50 font-normal"
                  >/{row.unit}</span>
                </span>
                <span :if={!row.price} class="text-base-content/40">—</span>
              </div>
            </div>
          </div>

          <div :if={@max_page > 1} class="flex items-center justify-end gap-2">
            <span class="text-xs text-base-content/50">{@page} / {@max_page}</span>
            <div class="join">
              <button
                type="button"
                class="btn btn-xs join-item"
                disabled={@page <= 1}
                phx-click="page"
                phx-value-dir="prev"
                phx-target={@myself}
                aria-label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Previous page")}
              >
                «
              </button>
              <button
                type="button"
                class="btn btn-xs join-item"
                disabled={@page >= @max_page}
                phx-click="page"
                phx-value-dir="next"
                phx-target={@myself}
                aria-label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Next page")}
              >
                »
              </button>
            </div>
          </div>
        </div>
        <button
          type="button"
          class="modal-backdrop"
          phx-click="close"
          phx-target={@myself}
          aria-label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Close")}
        >
        </button>
      </div>
    </div>
    """
  end
end
