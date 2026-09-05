defmodule PhoenixKitCatalogue.Web.CatalogueFormLive do
  @moduledoc "Create/edit form for catalogues with multilang support."

  use Phoenix.LiveView
  use PhoenixKitAI.Components.AITranslate.Embed

  require Logger

  import PhoenixKitWeb.Components.MultilangForm
  import PhoenixKitWeb.Components.Core.Button, only: [button: 1]
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Modal, only: [confirm_modal: 1]
  import PhoenixKitWeb.Components.Core.Input, only: [input: 1]
  import PhoenixKitWeb.Components.Core.Select, only: [select: 1]

  import PhoenixKitCatalogue.Web.Components,
    only: [attachments_files_panel: 1, metadata_editor: 1]

  import PhoenixKitCatalogue.Web.Helpers,
    only: [
      actor_opts: 1,
      assign_ai_translation: 3,
      ai_translate_config: 1
    ]

  import PhoenixKitAI.Components.AITranslate,
    only: [
      ai_multilang_tabs: 1,
      ai_translate_modal: 1
    ]

  alias PhoenixKitCatalogue.Attachments
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Metadata
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Schemas.Catalogue, as: CatalogueSchema

  @translatable_fields ["name", "description"]
  @preserve_fields %{
    # Translatable primaries: submitted only on the primary tab, so a
    # secondary-tab validate/save must re-inject them or :new loses them.
    "name" => :name,
    "description" => :description,
    "status" => :status,
    "kind" => :kind,
    "markup_percentage" => :markup_percentage,
    "discount_percentage" => :discount_percentage
  }

  # PhoenixKit auto-applies its admin chrome layout to external module admin
  # views via socket.private[:live_layout]. Opt out here so this view can
  # self-wrap with LayoutWrapper.app_layout and push its title/subtitle into
  # the global admin header (same pattern as /admin/media and orders/index).
  on_mount({__MODULE__, :self_wrapped_layout})

  def on_mount(:self_wrapped_layout, _params, _session, socket) do
    {:cont, put_in(socket.private[:live_layout], {PhoenixKitWeb.Layouts, :app})}
  end

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
       |> mount_multilang()
       |> assign_ai_translation("catalogue", if(action == :edit, do: catalogue, else: nil))}
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

  # AI-translate modal events handled by `use ...AITranslate.Embed`.

  # "switch_language" is handled by the core `mount_multilang/1` auto hook
  # (default `auto_switch_language: true`) — no clause needed here.

  @impl true
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
      # `:validate`, not whatever the previous changeset carried. The seed
      # changeset comes from `Catalogue.change_catalogue/1` in mount, whose
      # action is nil — and `to_form/1` drops errors entirely on a nil-action
      # changeset. Copying it forward meant EVERY inline validation error on
      # this form was invisible until the first failed save handed back a repo
      # changeset carrying :insert/:update. Every sibling form here already
      # hardcodes :validate.
      |> Map.put(:action, :validate)

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

    save_catalogue(socket, socket.assigns.action, catalogue_params, save_mode(params))
  end

  # ── Attachments (featured image modal + inline files dropzone) ──

  def handle_event("open_featured_image_picker", _params, socket),
    do: Attachments.open_featured_image_picker(socket)

  def handle_event("close_media_selector", _params, socket),
    do: {:noreply, Attachments.close_media_selector(socket)}

  def handle_event("cancel_upload", %{"ref" => ref}, socket),
    do: Attachments.cancel_attachment_upload(socket, ref)

  def handle_event("reorder_files", %{"ordered_ids" => ids}, socket),
    do: {:noreply, Attachments.handle_reorder_files(socket, ids)}

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

  # {:ai_translation, ...} events folded into the form by `use ...AITranslate.Embed`.
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

  defp save_catalogue(socket, :new, params, mode) do
    case Catalogue.create_catalogue(params, actor_opts(socket)) do
      {:ok, catalogue} ->
        _ = Attachments.maybe_rename_pending_folder(socket, catalogue)

        # "Save" (stay) continues on the new catalogue's edit form; exit
        # goes to its detail page as before.
        target =
          case mode do
            :stay -> Paths.catalogue_edit(catalogue.uuid)
            :exit -> Paths.catalogue_detail(catalogue.uuid)
          end

        {:noreply,
         socket
         |> put_flash(:info, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue created."))
         |> push_navigate(to: target)}

      {:error, changeset} ->
        {:noreply, assign_changeset(socket, changeset)}
    end
  end

  defp save_catalogue(socket, :edit, params, mode) do
    case Catalogue.update_catalogue(socket.assigns.catalogue, params, actor_opts(socket)) do
      {:ok, catalogue} ->
        socket =
          put_flash(
            socket,
            :info,
            Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue updated.")
          )

        case mode do
          :stay -> {:noreply, refresh_after_edit(socket, catalogue)}
          :exit -> {:noreply, push_navigate(socket, to: Paths.catalogue_detail(catalogue.uuid))}
        end

      {:error, changeset} ->
        {:noreply, assign_changeset(socket, changeset)}
    end
  end

  # The clicked submit button ships its name/value with the form params.
  # Anything other than the explicit "stay" (absent, forged, or stale)
  # falls back to the exit behavior — same as before the split.
  defp save_mode(%{"save_action" => "stay"}), do: :stay
  defp save_mode(_params), do: :exit

  # In-place refresh after a stay-save: no remount, so the current tab,
  # language, scroll position, and live attachment state all survive.
  # meta_state was just persisted verbatim, so it stays as-is.
  defp refresh_after_edit(socket, catalogue) do
    socket
    |> assign(:catalogue, catalogue)
    |> assign(
      :page_title,
      Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit %{name}", name: catalogue.name)
    )
    |> assign_changeset(Catalogue.change_catalogue(catalogue))
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
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={@page_title}
      page_section={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogues")}
      page_section_path={Paths.index()}
      page_subtitle={if @action == :new, do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Create a new product catalogue to organize categories and items."), else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Update catalogue details and settings.")}
      current_path={assigns[:url_path] || Paths.index()}
      current_locale={assigns[:current_locale]}
    >
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
        lock_file_type
        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Select Featured Image")}
        selected_uuids={@media_selected_uuids}
        scope_folder_id={@files_folder_uuid}
        phoenix_kit_current_user={assigns[:phoenix_kit_current_user]}
      />

      <%!-- Tab strip — each panel stays in the DOM (toggled by `hidden`)
           so the multilang wrapper + any user input don't lose state
           when flipping tabs. --%>
      <div role="tablist" class="tabs tabs-border">
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
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Photos and Files")}
          <span :if={@files_state.files != []} class="badge badge-sm badge-ghost ml-2">
            {length(@files_state.files)}
          </span>
        </button>
      </div>

      <.form for={@form} id="catalogue-form" action="#" phx-change="validate" phx-submit="save">
        <%!-- Details tab — name, description, kind, pricing, status --%>
        <div class={"card bg-base-100 shadow-lg #{if @current_tab != :details, do: "hidden"}"}>
          <%!-- Bundled tabs + AI row (phoenix_kit_ai's canonical placement;
            hint moves inline with the button — conscious convergence). --%>
          <.ai_multilang_tabs
            multilang_enabled={@multilang_enabled}
            language_tabs={@language_tabs}
            current_lang={@current_lang}
            class="card-body pb-0 pt-4"
            ai_translate={ai_translate_config(assigns)}
          />

          <.multilang_fields_wrapper
            multilang_enabled={@multilang_enabled}
            current_lang={@current_lang}
            skeleton_class="card-body pt-0 flex flex-col gap-5"
          >
            <:skeleton>
              <%!-- Name --%>
              <div class="fieldset">
                <div class="label">
                  <div class="skeleton h-4 w-14"></div>
                </div>
                <div class="skeleton h-12 w-full rounded-lg"></div>
              </div>
              <%!-- Description --%>
              <div class="fieldset">
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

            <div class="fieldset">
              <.select
                field={@form[:kind]}
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Kind")}
                class="transition-colors focus-within:select-primary"
                options={[
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Standard — items priced directly"), "standard"},
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Smart — items reference other catalogues"), "smart"}
                ]}
              />
              <span class="fieldset-label text-base-content/50 mt-1">
                <%= if Ecto.Changeset.get_field(@changeset, :kind) == "smart" do %>
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Smart catalogues hold items like \"Delivery\" whose cost is a per-catalogue %/flat rule picked from other catalogues. Items here reference other catalogues instead of carrying a base price of their own.")}
                <% else %>
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Standard catalogues hold items priced directly — each item has its own base price, markup, and discount. This is the normal flow for materials, products, or anything with a fixed price tag.")}
                <% end %>
              </span>
            </div>

            <div class="fieldset">
              <.input
                field={@form[:markup_percentage]}
                type="number"
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Markup Percentage")}
                step="0.01"
                min="0"
                placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "e.g., 15.0")}
              />
              <span class="fieldset-label text-base-content/50 mt-1">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Applied to all item base prices to calculate sale prices. Leave blank for no markup.")}
              </span>
            </div>

            <div class="fieldset">
              <.input
                field={@form[:discount_percentage]}
                type="number"
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Discount Percentage")}
                step="0.01"
                min="0"
                max="100"
                placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "e.g., 10.0")}
              />
              <span class="fieldset-label text-base-content/50 mt-1">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Applied on top of the sale price to compute the final price. 0..100. Individual items can override this.")}
              </span>
            </div>

            <div class="fieldset">
              <.select
                field={@form[:status]}
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Status")}
                class="transition-colors focus-within:select-primary"
                options={[
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Active"), "active"},
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Archived"), "archived"}
                ]}
              />
              <span class="fieldset-label text-base-content/50 mt-1">
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
          <.attachments_files_panel
            uploads={@uploads}
            files_state={@files_state}
            featured_image_uuid={@featured_image_uuid}
            featured_image_file={@featured_image_file}
            featured_subtitle={
              Gettext.gettext(
                PhoenixKitCatalogue.Gettext,
                "Shown on catalogue listings and detail views."
              )
            }
            files_hint={
              Gettext.gettext(
                PhoenixKitCatalogue.Gettext,
                "Brochures, spec sheets, datasheets. Any file type is accepted."
              )
            }
            remove_confirm={
              Gettext.gettext(
                PhoenixKitCatalogue.Gettext,
                "Remove this file from the catalogue? If it's not attached to any other resource, it will be moved to trash (admins can restore)."
              )
            }
            remove_title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Remove from catalogue")}
          />
        </div>

        <%!-- Actions — sit outside the tab panels so Save works from any
             tab. Both saves are disabled while uploads are mid-flight so
             we don't race the post-upload handle_progress write against
             the save path. "Save" keeps you on the form (also the
             Enter-key submitter, being first in the DOM); "Save & Exit"
             goes to the catalogue's detail page. "Save" carries
             `class="btn-outline"` on purpose — btn-outline is a style
             modifier, not a colour, so it composes with the component's
             default btn-primary; `variant="outline"` would REPLACE the
             colour and leave the button uncoloured. --%>
        <div class="flex justify-end gap-3 pt-2">
          <.button navigate={Paths.index()} variant="ghost">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Cancel")}
          </.button>
          <.button
            type="submit"
            name="save_action"
            value="stay"
            class="btn-outline"
            disabled={@uploads.attachment_files.entries != []}
            phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Saving...")}
          >
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Save")}
          </.button>
          <.button
            type="submit"
            name="save_action"
            value="exit"
            disabled={@uploads.attachment_files.entries != []}
            phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Saving...")}
          >
            {if @uploads.attachment_files.entries != [],
              do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Waiting for uploads..."),
              else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Save & Exit")}
          </.button>
        </div>
      </.form>

      <%!-- AI translate modal — outside the form (its selectors are their
           own <form>; nested forms are invalid). --%>
      <.ai_translate_modal ai_translate={ai_translate_config(assigns)} />

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
            <%!-- `variant="error"` rather than `class="btn-error"`: variant
                 REPLACES the base colour, so the class form would leave both
                 btn-primary and btn-error on the element and let stylesheet
                 order pick the winner. --%>
            <.button
              phx-click="show_delete_confirm"
              variant="error"
              size="sm"
              class="btn-outline shrink-0"
            >
              <.icon name="hero-trash" class="w-4 h-4" />
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete Forever")}
            </.button>
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
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
