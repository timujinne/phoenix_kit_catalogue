defmodule PhoenixKitCatalogue.Web.ManufacturerFormLive do
  @moduledoc "Create/edit form for manufacturers with supplier linking."

  use Phoenix.LiveView

  require Logger

  import PhoenixKitWeb.Components.Core.AdminPageHeader, only: [admin_page_header: 1]
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Input, only: [input: 1]
  import PhoenixKitWeb.Components.Core.Select, only: [select: 1]
  import PhoenixKitWeb.Components.Core.Textarea, only: [textarea: 1]

  import PhoenixKitCatalogue.Web.Helpers, only: [actor_opts: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Schemas.Manufacturer

  @impl true
  def mount(params, _session, socket) do
    action = socket.assigns.live_action

    {manufacturer, changeset, linked_supplier_uuids} =
      case action do
        :new ->
          m = %Manufacturer{}
          {m, Catalogue.change_manufacturer(m), []}

        :edit ->
          case Catalogue.get_manufacturer(params["uuid"]) do
            nil ->
              Logger.warning("Manufacturer not found for edit: #{params["uuid"]}")
              {nil, nil, []}

            m ->
              linked = Catalogue.linked_supplier_uuids(m.uuid)
              {m, Catalogue.change_manufacturer(m), linked}
          end
      end

    if is_nil(manufacturer) and action == :edit do
      {:ok,
       socket
       |> put_flash(
         :error,
         Gettext.gettext(PhoenixKitCatalogue.Gettext, "Manufacturer not found.")
       )
       |> push_navigate(to: Paths.manufacturers())}
    else
      all_suppliers = Catalogue.list_suppliers(status: "active")

      {:ok,
       socket
       |> assign(
         page_title:
           if(action == :new,
             do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "New Manufacturer"),
             else:
               Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit %{name}",
                 name: manufacturer.name
               )
           ),
         action: action,
         manufacturer: manufacturer,
         all_suppliers: all_suppliers,
         linked_supplier_uuids: MapSet.new(linked_supplier_uuids)
       )
       |> assign_changeset(changeset)}
    end
  end

  defp assign_changeset(socket, changeset) do
    socket
    |> assign(:changeset, changeset)
    |> assign(:form, to_form(changeset))
  end

  @impl true
  def handle_event("validate", %{"manufacturer" => params}, socket) do
    changeset =
      socket.assigns.manufacturer
      |> Catalogue.change_manufacturer(params)
      |> Map.put(:action, socket.assigns.changeset.action)

    {:noreply, assign_changeset(socket, changeset)}
  end

  def handle_event("toggle_supplier", %{"uuid" => uuid}, socket) do
    linked = socket.assigns.linked_supplier_uuids

    linked =
      if MapSet.member?(linked, uuid),
        do: MapSet.delete(linked, uuid),
        else: MapSet.put(linked, uuid)

    {:noreply, assign(socket, :linked_supplier_uuids, linked)}
  end

  def handle_event("save", %{"manufacturer" => params}, socket) do
    save_manufacturer(socket, socket.assigns.action, params)
  end

  # actor_opts/1 imported from PhoenixKitCatalogue.Web.Helpers

  defp save_manufacturer(socket, :new, params) do
    opts = actor_opts(socket)

    case Catalogue.create_manufacturer(params, opts) do
      {:ok, manufacturer} ->
        case Catalogue.sync_manufacturer_suppliers(
               manufacturer.uuid,
               MapSet.to_list(socket.assigns.linked_supplier_uuids),
               opts
             ) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               Gettext.gettext(PhoenixKitCatalogue.Gettext, "Manufacturer created.")
             )
             |> push_navigate(to: Paths.manufacturers())}

          {:error, _} ->
            {:noreply,
             socket
             |> put_flash(
               :warning,
               Gettext.gettext(
                 PhoenixKitCatalogue.Gettext,
                 "Manufacturer created but failed to link some suppliers."
               )
             )
             |> push_navigate(to: Paths.manufacturers())}
        end

      {:error, changeset} ->
        {:noreply, assign_changeset(socket, changeset)}
    end
  end

  defp save_manufacturer(socket, :edit, params) do
    opts = actor_opts(socket)

    case Catalogue.update_manufacturer(socket.assigns.manufacturer, params, opts) do
      {:ok, manufacturer} ->
        case Catalogue.sync_manufacturer_suppliers(
               manufacturer.uuid,
               MapSet.to_list(socket.assigns.linked_supplier_uuids),
               opts
             ) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               Gettext.gettext(PhoenixKitCatalogue.Gettext, "Manufacturer updated.")
             )
             |> push_navigate(to: Paths.manufacturers())}

          {:error, _} ->
            {:noreply,
             socket
             |> put_flash(
               :warning,
               Gettext.gettext(
                 PhoenixKitCatalogue.Gettext,
                 "Manufacturer updated but failed to sync supplier links."
               )
             )
             |> push_navigate(to: Paths.manufacturers())}
        end

      {:error, changeset} ->
        {:noreply, assign_changeset(socket, changeset)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-2xl px-4 py-8 gap-6">
      <%!-- Header --%>
      <.admin_page_header
        back={Paths.manufacturers()}
        title={@page_title}
        subtitle={if @action == :new, do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Add a new manufacturer to your catalogue system."), else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Update manufacturer details and supplier links.")}
      />

      <.form for={@form} action="#" phx-change="validate" phx-submit="save">
        <div class="card bg-base-100 shadow-lg">
          <div class="card-body flex flex-col gap-5">
            <.input
              field={@form[:name]}
              type="text"
              label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Name *")}
              placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "e.g., Blum, Hettich")}
              required
            />

            <.textarea
              field={@form[:description]}
              label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Description")}
              rows="3"
              placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Brief description of this manufacturer...")}
            />

            <div class="divider my-0"></div>

            <%!-- Contact & web --%>
            <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
              <.icon name="hero-envelope" class="h-4 w-4" />
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Contact & Web")}
            </h2>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <.input
                field={@form[:website]}
                type="url"
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Website")}
                placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "https://...")}
              />
              <.input
                field={@form[:contact_info]}
                type="text"
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Contact Info")}
                placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Email or phone")}
              />
            </div>

            <.input
              field={@form[:logo_url]}
              type="url"
              label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Logo URL")}
              placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "https://...")}
            />

            <.textarea
              field={@form[:notes]}
              label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Notes")}
              rows="2"
              class="min-h-[5rem]"
              placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Internal notes about this manufacturer...")}
            />

            <div class="divider my-0"></div>

            <div class="form-control">
              <.select
                field={@form[:status]}
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Status")}
                class="transition-colors focus-within:select-primary"
                options={[
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Active"), "active"},
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Inactive"), "inactive"}
                ]}
              />
              <span class="label-text-alt text-base-content/50 mt-1">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Inactive manufacturers won't appear in item dropdowns.")}
              </span>
            </div>

            <%!-- Supplier links --%>
            <div :if={@all_suppliers != []} class="flex flex-col gap-4">
              <div class="divider my-0"></div>

              <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
                <.icon name="hero-link" class="h-4 w-4" />
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Linked Suppliers")}
              </h2>
              <p class="text-sm text-base-content/50 -mt-2">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Click to toggle supplier associations.")}
              </p>

              <div class="flex flex-wrap gap-2">
                <label
                  :for={supplier <- @all_suppliers}
                  class={[
                    "badge badge-lg cursor-pointer gap-1.5 select-none transition-colors",
                    if(MapSet.member?(@linked_supplier_uuids, supplier.uuid),
                      do: "badge-primary",
                      else: "badge-ghost hover:badge-outline"
                    )
                  ]}
                  phx-click="toggle_supplier"
                  phx-value-uuid={supplier.uuid}
                >
                  <.icon
                    :if={MapSet.member?(@linked_supplier_uuids, supplier.uuid)}
                    name="hero-check"
                    class="h-3.5 w-3.5"
                  />
                  {supplier.name}
                </label>
              </div>
            </div>

            <%!-- Actions --%>
            <div class="divider my-0"></div>

            <div class="flex justify-end gap-3">
              <.link navigate={Paths.manufacturers()} class="btn btn-ghost">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Cancel")}</.link>
              <button
                type="submit"
                class="btn btn-primary phx-submit-loading:opacity-75"
                phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Saving...")}
              >
                {if @action == :new, do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Create Manufacturer"), else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Save Changes")}
              </button>
            </div>
          </div>
        </div>
      </.form>
    </div>
    """
  end
end
