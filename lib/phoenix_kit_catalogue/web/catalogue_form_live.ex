defmodule PhoenixKitCatalogue.Web.CatalogueFormLive do
  @moduledoc "Create/edit form for catalogues with multilang support."

  use Phoenix.LiveView

  require Logger

  import PhoenixKitWeb.Components.MultilangForm
  import PhoenixKitWeb.Components.Core.AdminPageHeader, only: [admin_page_header: 1]
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Modal, only: [confirm_modal: 1]
  import PhoenixKitWeb.Components.Core.Input, only: [input: 1]
  import PhoenixKitWeb.Components.Core.Select, only: [select: 1]

  import PhoenixKitCatalogue.Web.Components,
    only: [featured_image_card: 1, metadata_editor: 1]

  import PhoenixKitCatalogue.Web.Helpers, only: [actor_opts: 1]

  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKitCatalogue.Attachments
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Metadata
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Schemas.Catalogue, as: CatalogueSchema

  @translatable_fields ["name", "description"]
  @preserve_fields %{
    "status" => :status,
    "kind" => :kind,
    "markup_percentage" => :markup_percentage,
    "discount_percentage" => :discount_percentage
  }

  @impl true
  def mount(params, _session, socket) do
    action = socket.assigns.live_action

    {catalogue, changeset} =
      case action do
        :new ->
          cat = %CatalogueSchema{}
          {cat, Catalogue.change_catalogue(cat)}

        :edit ->
          case Catalogue.get_catalogue(params["uuid"]) do
            nil ->
              Logger.warning("Catalogue not found for edit: #{params["uuid"]}")
              {nil, nil}

            cat ->
              {cat, Catalogue.change_catalogue(cat)}
          end
      end

    if is_nil(catalogue) and action == :edit do
      {:ok,
       socket
       |> put_flash(:error, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue not found."))
       |> push_navigate(to: Paths.index())}
    else
      {:ok,
       socket
       |> assign(
         page_title:
           if(action == :new,
             do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "New Catalogue"),
             else:
               Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit %{name}", name: catalogue.name)
           ),
         action: action,
         catalogue: catalogue,
         confirm_delete: false,
         current_tab: :details,
         meta_state: Metadata.build_state(:catalogue, catalogue)
       )
       |> Attachments.mount_attachments(catalogue)
       |> Attachments.allow_attachment_upload()
       |> assign_changeset(changeset)
       |> mount_multilang()}
    end
  end

  # Single source of truth for form state: we keep both `:changeset` (for
  # `<.translatable_field>`, which still reads the raw changeset) and
  # `:form` (for `<.input>` / `<.select>` field bindings). Assigning both
  # here means validate/save-error paths can't accidentally desync them.
  defp assign_changeset(socket, changeset) do
    socket
    |> assign(:changeset, changeset)
    |> assign(:form, to_form(changeset))
  end

  @impl true
  def handle_event("switch_language", %{"lang" => lang_code}, socket) do
    {:noreply, handle_switch_language(socket, lang_code)}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :current_tab, parse_tab(tab))}
  end

  def handle_event("add_meta_field", %{"key" => key}, socket) do
    case Metadata.definition(:catalogue, key) do
      nil ->
        # Unknown key from a stale client — ignore instead of writing data
        # the save path can't round-trip.
        {:noreply, socket}

      _def ->
        state = socket.assigns.meta_state

        new_state =
          if key in state.attached do
            state
          else
            %{
              attached: state.attached ++ [key],
              values: Map.put_new(state.values, key, "")
            }
          end

        {:noreply, assign(socket, :meta_state, new_state)}
    end
  end

  def handle_event("remove_meta_field", %{"key" => key}, socket) do
    state = socket.assigns.meta_state

    new_state = %{
      attached: Enum.reject(state.attached, &(&1 == key)),
      values: Map.delete(state.values, key)
    }

    {:noreply, assign(socket, :meta_state, new_state)}
  end

  def handle_event("validate", params, socket) do
    socket = absorb_meta_params(socket, params)
    catalogue_params = Map.get(params, "catalogue", %{})

    catalogue_params =
      merge_translatable_params(catalogue_params, socket, @translatable_fields,
        changeset: socket.assigns.changeset,
        preserve_fields: @preserve_fields
      )

    changeset =
      socket.assigns.catalogue
      |> Catalogue.change_catalogue(catalogue_params)
      |> Map.put(:action, socket.assigns.changeset.action)

    {:noreply, assign_changeset(socket, changeset)}
  end

  def handle_event("save", params, socket) do
    socket = absorb_meta_params(socket, params)
    catalogue_params = Map.get(params, "catalogue", %{})

    catalogue_params =
      catalogue_params
      |> merge_translatable_params(socket, @translatable_fields,
        changeset: socket.assigns.changeset,
        preserve_fields: @preserve_fields
      )
      |> Metadata.inject_into_data(socket.assigns.meta_state, :catalogue)
      |> Attachments.inject_attachment_data(socket)

    save_catalogue(socket, socket.assigns.action, catalogue_params)
  end

  # ── Attachments (featured image modal + inline files dropzone) ──

  def handle_event("open_featured_image_picker", _params, socket),
    do: Attachments.open_featured_image_picker(socket)

  def handle_event("close_media_selector", _params, socket),
    do: {:noreply, Attachments.close_media_selector(socket)}

  def handle_event("cancel_upload", %{"ref" => ref}, socket),
    do: Attachments.cancel_attachment_upload(socket, ref)

  def handle_event("remove_file", %{"uuid" => uuid}, socket),
    do: Attachments.trash_file(socket, uuid)

  def handle_event("clear_featured_image", _params, socket),
    do: Attachments.clear_featured_image(socket)

  def handle_event("show_delete_confirm", _params, socket) do
    {:noreply, assign(socket, :confirm_delete, true)}
  end

  def handle_event("delete_catalogue", _params, socket) do
    case Catalogue.permanently_delete_catalogue(socket.assigns.catalogue, actor_opts(socket)) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           Gettext.gettext(
             PhoenixKitCatalogue.Gettext,
             "Catalogue and all its contents permanently deleted."
           )
         )
         |> push_navigate(to: Paths.index())}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:confirm_delete, false)
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to delete catalogue.")
         )}
    end
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :confirm_delete, false)}
  end

  @impl true
  def handle_info({:media_selected, file_uuids}, socket),
    do: Attachments.handle_media_selected(socket, file_uuids)

  def handle_info({:media_selector_closed}, socket),
    do: {:noreply, Attachments.close_media_selector(socket)}

  # Catch-all so stray monitor signals or unrelated PubSub traffic
  # can't crash the form mid-edit.
  def handle_info(msg, socket) do
    Logger.debug("CatalogueFormLive ignored unhandled message: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp parse_tab("metadata"), do: :metadata
  defp parse_tab("files"), do: :files
  defp parse_tab(_), do: :details

  defp absorb_meta_params(socket, params) do
    assign(socket, :meta_state, Metadata.absorb_params(socket.assigns.meta_state, params))
  end

  # actor_opts/1 imported from PhoenixKitCatalogue.Web.Helpers

  defp save_catalogue(socket, :new, params) do
    case Catalogue.create_catalogue(params, actor_opts(socket)) do
      {:ok, catalogue} ->
        _ = Attachments.maybe_rename_pending_folder(socket, catalogue)

        {:noreply,
         socket
         |> put_flash(:info, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue created."))
         |> push_navigate(to: Paths.catalogue_detail(catalogue.uuid))}

      {:error, changeset} ->
        {:noreply, assign_changeset(socket, changeset)}
    end
  end

  defp save_catalogue(socket, :edit, params) do
    case Catalogue.update_catalogue(socket.assigns.catalogue, params, actor_opts(socket)) do
      {:ok, catalogue} ->
        {:noreply,
         socket
         |> put_flash(:info, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue updated."))
         |> push_navigate(to: Paths.catalogue_detail(catalogue.uuid))}

      {:error, changeset} ->
        {:noreply, assign_changeset(socket, changeset)}
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :lang_data,
        get_lang_data(assigns.changeset, assigns.current_lang, assigns.multilang_enabled)
      )

    ~H"""
    <div class="flex flex-col mx-auto max-w-2xl px-4 py-8 gap-6">
      <%!-- Media selector — folder-scoped featured-image picker.
           Reconfigured per open; the Files tab below hosts the
           inline dropzone for everything else. --%>
      <.live_component
        module={PhoenixKitWeb.Live.Components.MediaSelectorModal}
        id="catalogue-form-media-selector"
        show={@show_media_selector}
        mode={@media_selection_mode}
        file_type_filter={@media_filter}
        selected_uuids={@media_selected_uuids}
        scope_folder_id={@files_folder_uuid}
        phoenix_kit_current_user={assigns[:phoenix_kit_current_user]}
      />

      <%!-- Header --%>
      <.admin_page_header back={Paths.index()} title={@page_title} subtitle={if @action == :new, do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Create a new product catalogue to organize categories and items."), else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Update catalogue details and settings.")} />

      <%!-- Tab strip — each panel stays in the DOM (toggled by `hidden`)
           so the multilang wrapper + any user input don't lose state
           when flipping tabs. --%>
      <div role="tablist" class="tabs tabs-bordered">
        <button
          type="button"
          phx-click="switch_tab"
          phx-value-tab="details"
          class={"tab #{if @current_tab == :details, do: "tab-active"}"}
        >
          <.icon name="hero-document-text" class="w-4 h-4 mr-1" />
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Details")}
        </button>
        <button
          type="button"
          phx-click="switch_tab"
          phx-value-tab="metadata"
          class={"tab #{if @current_tab == :metadata, do: "tab-active"}"}
        >
          <.icon name="hero-tag" class="w-4 h-4 mr-1" />
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Metadata")}
          <span :if={@meta_state.attached != []} class="badge badge-sm badge-ghost ml-2">
            {length(@meta_state.attached)}
          </span>
        </button>
        <button
          type="button"
          phx-click="switch_tab"
          phx-value-tab="files"
          class={"tab #{if @current_tab == :files, do: "tab-active"}"}
        >
          <.icon name="hero-paper-clip" class="w-4 h-4 mr-1" />
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Files")}
          <span :if={@files_state.files != []} class="badge badge-sm badge-ghost ml-2">
            {length(@files_state.files)}
          </span>
        </button>
      </div>

      <.form for={@form} action="#" phx-change="validate" phx-submit="save">
        <%!-- Details tab — name, description, kind, pricing, status --%>
        <div class={"card bg-base-100 shadow-lg #{if @current_tab != :details, do: "hidden"}"}>
          <.multilang_tabs
            multilang_enabled={@multilang_enabled}
            language_tabs={@language_tabs}
            current_lang={@current_lang}
            class="card-body pb-0 pt-4"
          />

          <.multilang_fields_wrapper
            multilang_enabled={@multilang_enabled}
            current_lang={@current_lang}
            skeleton_class="card-body pt-0 flex flex-col gap-5"
          >
            <:skeleton>
              <%!-- Name --%>
              <div class="form-control">
                <div class="label">
                  <div class="skeleton h-4 w-14"></div>
                </div>
                <div class="skeleton h-12 w-full rounded-lg"></div>
              </div>
              <%!-- Description --%>
              <div class="form-control">
                <div class="label">
                  <div class="skeleton h-4 w-24"></div>
                </div>
                <div class="skeleton h-20 w-full rounded-lg"></div>
              </div>
            </:skeleton>
            <div class="card-body pt-0 flex flex-col gap-5">
              <.translatable_field
                field_name="name"
                form_prefix="catalogue"
                changeset={@changeset}
                schema_field={:name}
                multilang_enabled={@multilang_enabled}
                current_lang={@current_lang}
                primary_language={@primary_language}
                lang_data={@lang_data}
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Name")}
                placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "e.g., Kitchen Furniture")}
                required
                class="w-full"
              />

              <.translatable_field
                field_name="description"
                form_prefix="catalogue"
                changeset={@changeset}
                schema_field={:description}
                multilang_enabled={@multilang_enabled}
                current_lang={@current_lang}
                primary_language={@primary_language}
                lang_data={@lang_data}
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Description")}
                type="textarea"
                placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Brief description of what this catalogue contains...")}
                class="w-full"
              />
            </div>
          </.multilang_fields_wrapper>

          <div class="card-body flex flex-col gap-5 pt-0">
            <div class="divider my-0"></div>

            <div class="form-control">
              <.select
                field={@form[:kind]}
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Kind")}
                class="transition-colors focus-within:select-primary"
                options={[
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Standard — items priced directly"), "standard"},
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Smart — items reference other catalogues"), "smart"}
                ]}
              />
              <span class="label-text-alt text-base-content/50 mt-1">
                <%= if Ecto.Changeset.get_field(@changeset, :kind) == "smart" do %>
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Smart catalogues hold items like \"Delivery\" whose cost is a per-catalogue %/flat rule picked from other catalogues. Items here reference other catalogues instead of carrying a base price of their own.")}
                <% else %>
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Standard catalogues hold items priced directly — each item has its own base price, markup, and discount. This is the normal flow for materials, products, or anything with a fixed price tag.")}
                <% end %>
              </span>
            </div>

            <div class="form-control">
              <.input
                field={@form[:markup_percentage]}
                type="number"
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Markup Percentage")}
                step="0.01"
                min="0"
                placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "e.g., 15.0")}
              />
              <span class="label-text-alt text-base-content/50 mt-1">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Applied to all item base prices to calculate sale prices. Leave blank for no markup.")}
              </span>
            </div>

            <div class="form-control">
              <.input
                field={@form[:discount_percentage]}
                type="number"
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Discount Percentage")}
                step="0.01"
                min="0"
                max="100"
                placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "e.g., 10.0")}
              />
              <span class="label-text-alt text-base-content/50 mt-1">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Applied on top of the sale price to compute the final price. 0..100. Individual items can override this.")}
              </span>
            </div>

            <div class="form-control">
              <.select
                field={@form[:status]}
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Status")}
                class="transition-colors focus-within:select-primary"
                options={[
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Active"), "active"},
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Archived"), "archived"}
                ]}
              />
              <span class="label-text-alt text-base-content/50 mt-1">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Archived catalogues are hidden from active views.")}
              </span>
            </div>
          </div>
        </div>

        <%!-- Metadata tab — global field list, user opts in per catalogue.
             Values live in `catalogue.data["meta"]`; legacy keys (stored
             but no longer in Metadata.definitions(:catalogue)) render
             with a "Legacy" pill and a remove-only action. --%>
        <div class={"card bg-base-100 shadow-lg #{if @current_tab != :metadata, do: "hidden"}"}>
          <.metadata_editor
            resource_type={:catalogue}
            state={@meta_state}
            id_prefix="catalogue"
            description={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Attach any metadata fields that apply to this catalogue. Blank values are dropped on save.")}
          />
        </div>

        <%!-- Files tab — featured image + inline files dropzone. --%>
        <div class={"flex flex-col gap-6 #{if @current_tab != :files, do: "hidden"}"}>
          <.featured_image_card
            featured_image_uuid={@featured_image_uuid}
            featured_image_file={@featured_image_file}
            subtitle={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Shown on catalogue listings and detail views.")}
          />

          <div class="card bg-base-100 shadow-lg">
            <div class="card-body flex flex-col gap-4">
              <div class="flex flex-col gap-0.5">
                <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
                  <.icon name="hero-paper-clip" class="w-4 h-4" />
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Attached Files")}
                  <span :if={@files_state.files != []} class="badge badge-sm badge-ghost ml-1">
                    {length(@files_state.files)}
                  </span>
                </h2>
                <p class="text-xs text-base-content/50">
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Brochures, spec sheets, datasheets. Any file type is accepted.")}
                </p>
              </div>

              <label
                for={@uploads.attachment_files.ref}
                class="flex flex-col items-center justify-center gap-2 py-6 border-2 border-dashed border-base-300 rounded-md bg-base-200/20 hover:bg-base-200/40 transition-colors cursor-pointer"
                phx-drop-target={@uploads.attachment_files.ref}
              >
                <.icon name="hero-cloud-arrow-up" class="w-8 h-8 text-base-content/40" />
                <div class="text-sm text-base-content/60">
                  <span class="font-medium text-primary">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Click to upload")}</span>
                  <span>{Gettext.gettext(PhoenixKitCatalogue.Gettext, " or drag & drop")}</span>
                </div>
                <.live_file_input upload={@uploads.attachment_files} class="hidden" />
              </label>

              <div :if={@uploads.attachment_files.entries != []} class="flex flex-col gap-2">
                <div
                  :for={entry <- @uploads.attachment_files.entries}
                  class="flex items-center gap-3 rounded-md border border-base-300 bg-base-100 p-2"
                >
                  <.icon name="hero-cloud-arrow-up" class="w-4 h-4 text-base-content/60 shrink-0" />
                  <div class="flex-1 min-w-0">
                    <p class="text-sm truncate">{entry.client_name}</p>
                    <progress
                      class="progress progress-primary w-full h-1 mt-1"
                      value={entry.progress}
                      max="100"
                    >
                    </progress>
                  </div>
                  <span class="text-xs text-base-content/50 tabular-nums">{entry.progress}%</span>
                  <button
                    type="button"
                    phx-click="cancel_upload"
                    phx-value-ref={entry.ref}
                    class="btn btn-ghost btn-xs btn-square"
                    title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Cancel")}
                  >
                    <.icon name="hero-x-mark" class="w-4 h-4" />
                  </button>
                </div>
              </div>

              <p
                :for={err <- upload_errors(@uploads.attachment_files)}
                class="text-xs text-error"
              >
                {Attachments.upload_error_message(err)}
              </p>

              <%= if @files_state.files == [] do %>
                <div class="flex flex-col items-center gap-2 py-10 text-center border border-dashed border-base-300 rounded-md">
                  <.icon name="hero-paper-clip" class="w-8 h-8 text-base-content/30" />
                  <p class="text-sm text-base-content/50">
                    {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No files attached yet.")}
                  </p>
                </div>
              <% else %>
                <ul class="grid grid-cols-1 md:grid-cols-2 gap-3">
                  <li
                    :for={file <- @files_state.files}
                    class="flex items-center gap-3 rounded-md border border-base-300 bg-base-200/30 p-3"
                  >
                    <%= if file.file_type == "image" do %>
                      <a
                        href={URLSigner.signed_url(file.uuid, "original")}
                        target="_blank"
                        rel="noopener"
                        class="shrink-0"
                      >
                        <img
                          src={URLSigner.signed_url(file.uuid, "thumbnail")}
                          alt={file.original_file_name}
                          class="w-14 h-14 rounded object-cover bg-base-200 border border-base-300"
                        />
                      </a>
                    <% else %>
                      <a
                        href={URLSigner.signed_url(file.uuid, "original")}
                        target="_blank"
                        rel="noopener"
                        class="shrink-0 flex items-center justify-center w-14 h-14 rounded bg-base-200 border border-base-300 text-base-content/60"
                        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Download")}
                      >
                        <.icon name={Attachments.file_icon(file)} class="w-6 h-6" />
                      </a>
                    <% end %>
                    <div class="flex-1 min-w-0">
                      <p class="text-sm font-medium truncate" title={file.original_file_name}>
                        {file.original_file_name}
                      </p>
                      <p class="text-xs text-base-content/50">
                        {Attachments.format_file_size(file.size)} · {file.file_type}
                      </p>
                    </div>
                    <button
                      type="button"
                      phx-click="remove_file"
                      phx-value-uuid={file.uuid}
                      phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Removing...")}
                      data-confirm={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Remove this file from the catalogue? If it's not attached to any other resource, it will be moved to trash (admins can restore).")}
                      class="btn btn-ghost btn-xs btn-square"
                      title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Remove from catalogue")}
                    >
                      <.icon name="hero-x-mark" class="w-4 h-4" />
                    </button>
                  </li>
                </ul>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- Actions — sit outside the tab panels so Save works from any
             tab. Save is disabled while uploads are mid-flight so we
             don't race the post-upload handle_progress write against
             the save path. --%>
        <div class="flex justify-end gap-3 pt-2">
          <.link navigate={Paths.index()} class="btn btn-ghost">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Cancel")}
          </.link>
          <button
            type="submit"
            class="btn btn-primary phx-submit-loading:opacity-75"
            disabled={@uploads.attachment_files.entries != []}
            phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Saving...")}
          >
            {cond do
              @uploads.attachment_files.entries != [] ->
                Gettext.gettext(PhoenixKitCatalogue.Gettext, "Waiting for uploads...")

              @action == :new ->
                Gettext.gettext(PhoenixKitCatalogue.Gettext, "Create Catalogue")

              true ->
                Gettext.gettext(PhoenixKitCatalogue.Gettext, "Save Changes")
            end}
          </button>
        </div>
      </.form>

      <%!-- Danger zone — collapsed by default to match the integrations
           page pattern; user clicks to reveal the destructive action. --%>
      <details :if={@action == :edit} class="card bg-base-100 border-2 border-error/30">
        <summary class="card-body py-3 cursor-pointer flex-row items-center gap-2 select-none">
          <.icon name="hero-exclamation-triangle" class="w-4 h-4 text-error" />
          <h3 class="font-semibold text-error text-base">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Danger Zone")}</h3>
          <.icon name="hero-chevron-down" class="w-4 h-4 ml-auto text-base-content/40" />
        </summary>

        <div class="card-body pt-0 space-y-4">
          <div class="flex items-center justify-between gap-4">
            <div>
              <p class="font-medium text-sm">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Permanently Delete Catalogue")}</p>
              <p class="text-xs text-base-content/60">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "This will permanently delete this catalogue, all its categories, and all items within them. This cannot be undone.")}
              </p>
            </div>
            <button phx-click="show_delete_confirm" class="btn btn-outline btn-error btn-sm shrink-0">
              <.icon name="hero-trash" class="w-4 h-4" />
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete Forever")}
            </button>
          </div>
        </div>
      </details>

      <.confirm_modal
        show={@confirm_delete}
        on_confirm="delete_catalogue"
        on_cancel="cancel_delete"
        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Permanently Delete Catalogue")}
        title_icon="hero-trash"
        messages={[{:warning, Gettext.gettext(PhoenixKitCatalogue.Gettext, "This will permanently delete this catalogue, all its categories, and all items within them.")}]}
        confirm_text={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete Forever")}
        danger={true}
      />
    </div>
    """
  end
end
