defmodule PhoenixKitCatalogue.Web.ExportLive do
  @moduledoc """
  Export tab LiveView.

  Lets the user select a destination, one or more catalogues, and a format,
  then download the generated file in-memory via a stateless controller GET.
  """

  use Phoenix.LiveView

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Select, only: [select: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Export
  alias PhoenixKitCatalogue.Paths

  @impl true
  def mount(_params, _session, socket) do
    destinations = Export.destinations()
    selected_destination = List.first(destinations)
    catalogues = Catalogue.list_catalogues()

    {:ok,
     socket
     |> assign(
       page_title: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Export"),
       destinations: destinations,
       selected_destination: selected_destination,
       catalogues: catalogues,
       selected_catalogue_uuids: [],
       selected_format: nil
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("change_form", params, socket) do
    {:noreply, apply_form_params(socket, params)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col w-full px-4 py-6 gap-6">
      <div class="card bg-base-100 shadow-sm">
        <div class="card-body gap-6">
          <h2 class="card-title">
            <.icon name="hero-arrow-up-tray" class="w-5 h-5" />
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Export Items")}
          </h2>

          <form id="export-form" phx-change="change_form" class="flex flex-col gap-4">
            <%!-- Destination select --%>
            <div class="form-control w-full max-w-md">
              <span class="block mb-2 text-sm font-medium">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Destination")}
              </span>
              <.select
                name="destination"
                id="export-destination"
                value={@selected_destination && @selected_destination.key() |> Atom.to_string()}
                options={Enum.map(@destinations, &{&1.label(), Atom.to_string(&1.key())})}
              />
            </div>

            <%!-- Catalogues checkbox list --%>
            <div class="form-control w-full max-w-md">
              <span class="block mb-2 text-sm font-medium">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogues")}
              </span>
              <div class="max-h-64 overflow-y-auto border border-base-300 rounded-box p-3 flex flex-col gap-2">
                <%= for catalogue <- @catalogues do %>
                  <label class="flex items-center gap-2 cursor-pointer">
                    <input
                      type="checkbox"
                      name="catalogue_uuids[]"
                      value={catalogue.uuid}
                      checked={catalogue.uuid in @selected_catalogue_uuids}
                      class="checkbox checkbox-sm"
                    />
                    <span class="text-sm">{catalogue.name}</span>
                  </label>
                <% end %>
              </div>
            </div>

            <%!-- Format select --%>
            <div class="form-control w-full max-w-md">
              <span class="block mb-2 text-sm font-medium">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Format")}
              </span>
              <.select
                name="format"
                id="export-format"
                value={@selected_format}
                prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Select a format...")}
                options={
                  if @selected_destination do
                    Enum.map(@selected_destination.formats(), fn {k, label} ->
                      {label, Atom.to_string(k)}
                    end)
                  else
                    []
                  end
                }
              />
            </div>
          </form>

          <%!-- Export button — plain <a> so the browser triggers a file download --%>
          <%= if download_url(assigns) do %>
            <a href={download_url(assigns)} class="btn btn-primary w-fit">
              <.icon name="hero-arrow-down-tray" class="w-4 h-4" />
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Export")}
            </a>
          <% else %>
            <button class="btn btn-primary w-fit btn-disabled" disabled>
              <.icon name="hero-arrow-down-tray" class="w-4 h-4" />
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Export")}
            </button>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp download_url(%{
         selected_catalogue_uuids: [_ | _] = uuids,
         selected_destination: destination,
         selected_format: format
       })
       when not is_nil(destination) and not is_nil(format) do
    Paths.export_download(%{
      destination: Atom.to_string(destination.key()),
      format: format,
      catalogue_uuids: uuids
    })
  end

  defp download_url(_), do: nil

  defp apply_form_params(socket, params) do
    destination_key = Map.get(params, "destination")
    catalogue_uuids = Map.get(params, "catalogue_uuids", [])
    format_str = presence(Map.get(params, "format"))

    selected_destination =
      if destination_key do
        Enum.find(socket.assigns.destinations, fn mod ->
          Atom.to_string(mod.key()) == destination_key
        end)
      else
        socket.assigns.selected_destination
      end

    # Validate that the selected uuids are known catalogues
    known_uuids = Enum.map(socket.assigns.catalogues, & &1.uuid)

    selected_catalogue_uuids =
      catalogue_uuids
      |> List.wrap()
      |> Enum.filter(fn uuid -> uuid in known_uuids end)

    # Reset format if the destination changed and the format is no longer valid
    selected_format =
      if selected_destination && format_str &&
           Enum.any?(selected_destination.formats(), fn {k, _} ->
             Atom.to_string(k) == format_str
           end) do
        format_str
      else
        nil
      end

    assign(socket,
      selected_destination: selected_destination,
      selected_catalogue_uuids: selected_catalogue_uuids,
      selected_format: selected_format
    )
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(str) when is_binary(str), do: str
end
