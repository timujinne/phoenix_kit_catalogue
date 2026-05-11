defmodule PhoenixKitCatalogue.Web.SupplierFormLive do
  @moduledoc "Create/edit form for suppliers with manufacturer linking."

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
  alias PhoenixKitCatalogue.Schemas.Supplier

  @impl true
  def mount(params, _session, socket) do
    action = socket.assigns.live_action

    {supplier, changeset, linked_manufacturer_uuids} =
      case action do
        :new ->
          s = %Supplier{}
          {s, Catalogue.change_supplier(s), []}

        :edit ->
          case Catalogue.get_supplier(params["uuid"]) do
            nil ->
              Logger.warning("Supplier not found for edit: #{params["uuid"]}")
              {nil, nil, []}

            s ->
              linked = Catalogue.linked_manufacturer_uuids(s.uuid)
              {s, Catalogue.change_supplier(s), linked}
          end
      end

    if is_nil(supplier) and action == :edit do
      {:ok,
       socket
       |> put_flash(:error, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Supplier not found."))
       |> push_navigate(to: Paths.suppliers())}
    else
      all_manufacturers = Catalogue.list_manufacturers(status: "active")

      {:ok,
       socket
       |> assign(
         page_title:
           if(action == :new,
             do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "New Supplier"),
             else:
               Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit %{name}", name: supplier.name)
           ),
         action: action,
         supplier: supplier,
         all_manufacturers: all_manufacturers,
         linked_manufacturer_uuids: MapSet.new(linked_manufacturer_uuids)
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
  def handle_event("validate", %{"supplier" => params}, socket) do
    changeset =
      socket.assigns.supplier
      |> Catalogue.change_supplier(params)
      |> Map.put(:action, socket.assigns.changeset.action)

    {:noreply, assign_changeset(socket, changeset)}
  end

  def handle_event("toggle_manufacturer", %{"uuid" => uuid}, socket) do
    linked = socket.assigns.linked_manufacturer_uuids

    linked =
      if MapSet.member?(linked, uuid),
        do: MapSet.delete(linked, uuid),
        else: MapSet.put(linked, uuid)

    {:noreply, assign(socket, :linked_manufacturer_uuids, linked)}
  end

  def handle_event("save", %{"supplier" => params}, socket) do
    save_supplier(socket, socket.assigns.action, params)
  end

  # actor_opts/1 imported from PhoenixKitCatalogue.Web.Helpers

  defp save_supplier(socket, :new, params) do
    opts = actor_opts(socket)

    case Catalogue.create_supplier(params, opts) do
      {:ok, supplier} ->
        case Catalogue.sync_supplier_manufacturers(
               supplier.uuid,
               MapSet.to_list(socket.assigns.linked_manufacturer_uuids),
               opts
             ) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               Gettext.gettext(PhoenixKitCatalogue.Gettext, "Supplier created.")
             )
             |> push_navigate(to: Paths.suppliers())}

          {:error, _} ->
            {:noreply,
             socket
             |> put_flash(
               :warning,
               Gettext.gettext(
                 PhoenixKitCatalogue.Gettext,
                 "Supplier created but failed to link some manufacturers."
               )
             )
             |> push_navigate(to: Paths.suppliers())}
        end

      {:error, changeset} ->
        {:noreply, assign_changeset(socket, changeset)}
    end
  end

  defp save_supplier(socket, :edit, params) do
    opts = actor_opts(socket)

    case Catalogue.update_supplier(socket.assigns.supplier, params, opts) do
      {:ok, supplier} ->
        case Catalogue.sync_supplier_manufacturers(
               supplier.uuid,
               MapSet.to_list(socket.assigns.linked_manufacturer_uuids),
               opts
             ) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               Gettext.gettext(PhoenixKitCatalogue.Gettext, "Supplier updated.")
             )
             |> push_navigate(to: Paths.suppliers())}

          {:error, _} ->
            {:noreply,
             socket
             |> put_flash(
               :warning,
               Gettext.gettext(
                 PhoenixKitCatalogue.Gettext,
                 "Supplier updated but failed to sync manufacturer links."
               )
             )
             |> push_navigate(to: Paths.suppliers())}
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
        back={Paths.suppliers()}
        title={@page_title}
        subtitle={if @action == :new, do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Add a new supplier to your catalogue system."), else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Update supplier details and manufacturer links.")}
      />

      <.form for={@form} action="#" phx-change="validate" phx-submit="save">
        <div class="card bg-base-100 shadow-lg">
          <div class="card-body flex flex-col gap-5">
            <.input
              field={@form[:name]}
              type="text"
              label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Name *")}
              placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "e.g., Regional Distributors Inc.")}
              required
            />

            <.textarea
              field={@form[:description]}
              label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Description")}
              rows="3"
              placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Brief description of this supplier...")}
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

            <.textarea
              field={@form[:notes]}
              label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Notes")}
              rows="2"
              class="min-h-[5rem]"
              placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Internal notes about this supplier...")}
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
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Inactive suppliers won't appear in manufacturer linking.")}
              </span>
            </div>

            <%!-- Manufacturer links --%>
            <div :if={@all_manufacturers != []} class="flex flex-col gap-4">
              <div class="divider my-0"></div>

              <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
                <.icon name="hero-link" class="h-4 w-4" />
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Linked Manufacturers")}
              </h2>
              <p class="text-sm text-base-content/50 -mt-2">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Click to toggle manufacturer associations.")}
              </p>

              <div class="flex flex-wrap gap-2">
                <label
                  :for={m <- @all_manufacturers}
                  class={[
                    "badge badge-lg cursor-pointer gap-1.5 select-none transition-colors",
                    if(MapSet.member?(@linked_manufacturer_uuids, m.uuid),
                      do: "badge-primary",
                      else: "badge-ghost hover:badge-outline"
                    )
                  ]}
                  phx-click="toggle_manufacturer"
                  phx-value-uuid={m.uuid}
                >
                  <.icon
                    :if={MapSet.member?(@linked_manufacturer_uuids, m.uuid)}
                    name="hero-check"
                    class="h-3.5 w-3.5"
                  />
                  {m.name}
                </label>
              </div>
            </div>

            <%!-- Actions --%>
            <div class="divider my-0"></div>

            <div class="flex justify-end gap-3">
              <.link navigate={Paths.suppliers()} class="btn btn-ghost">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Cancel")}</.link>
              <button
                type="submit"
                class="btn btn-primary phx-submit-loading:opacity-75"
                phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Saving...")}
              >
                {if @action == :new, do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Create Supplier"), else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Save Changes")}
              </button>
            </div>
          </div>
        </div>
      </.form>
    </div>
    """
  end
end
