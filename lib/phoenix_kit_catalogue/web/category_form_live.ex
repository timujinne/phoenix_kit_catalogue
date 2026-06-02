defmodule PhoenixKitCatalogue.Web.CategoryFormLive do
  @moduledoc "Create/edit form for categories within a catalogue."

  use Phoenix.LiveView

  require Logger

  import PhoenixKitWeb.Components.MultilangForm
  import PhoenixKitWeb.Components.Core.AdminPageHeader, only: [admin_page_header: 1]
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Modal, only: [confirm_modal: 1]
  import PhoenixKitWeb.Components.Core.Input, only: [input: 1]
  import PhoenixKitWeb.Components.Core.Select, only: [select: 1]
  import PhoenixKitCatalogue.Web.Components, only: [featured_image_card: 1]

  import PhoenixKitCatalogue.Web.Helpers,
    only: [
      actor_opts: 1,
      assign_ai_translation: 3,
      ai_translate_config: 1,
      toggle_ai_modal: 1,
      select_ai_endpoint: 2,
      select_ai_prompt: 2,
      select_ai_scope: 2,
      generate_ai_prompt: 1,
      dispatch_ai_translate: 2,
      handle_ai_translation_event: 4
    ]

  import PhoenixKitWeb.Components.AITranslate,
    only: [
      ai_translate_button: 1,
      ai_translate_modal: 1,
      ai_translate_progress: 1,
      ai_translate_hint: 1
    ]

  alias PhoenixKit.Utils.Values
  alias PhoenixKitCatalogue.Attachments
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Schemas.Category

  @translatable_fields ["name", "description"]

  @impl true
  def mount(params, _session, socket) do
    action = socket.assigns.live_action

    {category, changeset, catalogue_uuid} =
      case action do
        :new ->
          catalogue_uuid = params["catalogue_uuid"]
          parent_uuid = Values.blank_to_nil(params["parent_uuid"])
          next_pos = Catalogue.next_category_position(catalogue_uuid, parent_uuid)

          cat = %Category{
            catalogue_uuid: catalogue_uuid,
            parent_uuid: parent_uuid,
            position: next_pos
          }

          {cat, Catalogue.change_category(cat), catalogue_uuid}

        :edit ->
          case Catalogue.get_category(params["uuid"]) do
            nil ->
              Logger.warning("Category not found for edit: #{params["uuid"]}")
              {nil, nil, nil}

            cat ->
              {cat, Catalogue.change_category(cat), cat.catalogue_uuid}
          end
      end

    if is_nil(category) and action == :edit do
      {:ok,
       socket
       |> put_flash(:error, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category not found."))
       |> push_navigate(to: Paths.index())}
    else
      mount_category_form(socket, action, category, changeset, catalogue_uuid)
    end
  end

  defp mount_category_form(socket, action, category, changeset, catalogue_uuid) do
    other_catalogues =
      if action == :edit do
        Catalogue.list_catalogues()
        |> Enum.reject(&(&1.uuid == catalogue_uuid))
      else
        []
      end

    parent_options = parent_options_for(action, category, catalogue_uuid)

    {:ok,
     socket
     |> assign(
       page_title:
         if(action == :new,
           do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "New Category"),
           else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit %{name}", name: category.name)
         ),
       action: action,
       category: category,
       catalogue_uuid: catalogue_uuid,
       confirm_delete_all: false,
       other_catalogues: other_catalogues,
       parent_options: parent_options,
       parent_move_target: category && category.parent_uuid,
       move_target: nil
     )
     |> Attachments.mount_attachments(category, files_grid: false)
     |> assign_changeset(changeset)
     |> mount_multilang()
     |> assign_ai_translation("catalogue_category", if(action == :edit, do: category, else: nil))}
  end

  # Tree-flattened options for the parent picker. Root entry first,
  # then each category prefixed with indentation that matches its
  # depth. For edit mode, the category's own subtree is excluded so
  # the user can't pick itself or one of its descendants.
  defp parent_options_for(:new, _category, catalogue_uuid) do
    Catalogue.list_category_tree(catalogue_uuid)
    |> format_parent_options()
  end

  defp parent_options_for(:edit, %Category{uuid: uuid}, catalogue_uuid) do
    catalogue_uuid
    |> Catalogue.list_category_tree(exclude_subtree_of: uuid)
    |> format_parent_options()
  end

  defp parent_options_for(_, _, _), do: []

  defp format_parent_options(entries) do
    Enum.map(entries, fn {category, depth} ->
      {String.duplicate("— ", depth) <> category.name, category.uuid}
    end)
  end

  defp assign_changeset(socket, changeset) do
    socket
    |> assign(:changeset, changeset)
    |> assign(:form, to_form(changeset))
  end

  @impl true
  def handle_event("ai_toggle_modal", _params, socket),
    do: {:noreply, toggle_ai_modal(socket)}

  def handle_event("ai_select_endpoint", %{"endpoint_uuid" => uuid}, socket),
    do: {:noreply, select_ai_endpoint(socket, uuid)}

  def handle_event("ai_select_prompt", %{"prompt_uuid" => uuid}, socket),
    do: {:noreply, select_ai_prompt(socket, uuid)}

  def handle_event("ai_select_scope", %{"scope" => scope}, socket),
    do: {:noreply, select_ai_scope(socket, scope)}

  def handle_event("ai_generate_prompt", _params, socket),
    do: {:noreply, generate_ai_prompt(socket)}

  def handle_event("ai_translate_lang", %{"lang" => lang}, socket),
    do: {:noreply, dispatch_ai_translate(socket, lang)}

  def handle_event("switch_language", %{"lang" => lang_code}, socket) do
    {:noreply, handle_switch_language(socket, lang_code)}
  end

  def handle_event("validate", %{"category" => params}, socket) do
    params =
      params
      |> Map.put_new("catalogue_uuid", socket.assigns.catalogue_uuid)
      |> normalize_parent_uuid()
      |> merge_translatable_params(socket, @translatable_fields,
        changeset: socket.assigns.changeset
      )

    changeset =
      socket.assigns.category
      |> Catalogue.change_category(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_changeset(socket, changeset)}
  end

  def handle_event("save", %{"category" => params}, socket) do
    params =
      params
      |> Map.put_new("catalogue_uuid", socket.assigns.catalogue_uuid)
      |> normalize_parent_uuid()
      |> merge_translatable_params(socket, @translatable_fields,
        changeset: socket.assigns.changeset
      )
      |> Attachments.inject_attachment_data(socket)

    save_category(socket, socket.assigns.action, params)
  end

  # ── Attachments (featured image modal only) ──────────────────────
  # Category has a featured image but no inline files grid — the
  # lightweight treatment my AGENTS.md comparison landed on.

  def handle_event("open_featured_image_picker", _params, socket),
    do: Attachments.open_featured_image_picker(socket)

  def handle_event("close_media_selector", _params, socket),
    do: {:noreply, Attachments.close_media_selector(socket)}

  def handle_event("clear_featured_image", _params, socket),
    do: Attachments.clear_featured_image(socket)

  def handle_event("show_delete_confirm", _params, socket) do
    {:noreply, assign(socket, :confirm_delete_all, true)}
  end

  def handle_event("delete_category", _params, socket) do
    case Catalogue.permanently_delete_category(socket.assigns.category, actor_opts(socket)) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           Gettext.gettext(
             PhoenixKitCatalogue.Gettext,
             "Category and all its items permanently deleted."
           )
         )
         |> push_navigate(to: Paths.catalogue_detail(socket.assigns.catalogue_uuid))}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:confirm_delete_all, false)
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to delete category.")
         )}
    end
  end

  def handle_event("select_move_target", %{"catalogue_uuid" => uuid}, socket) do
    target = if uuid == "", do: nil, else: uuid
    {:noreply, assign(socket, :move_target, target)}
  end

  def handle_event("move_category", _params, socket) do
    target = socket.assigns.move_target

    if target do
      case Catalogue.move_category_to_catalogue(
             socket.assigns.category,
             target,
             actor_opts(socket)
           ) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category moved to another catalogue.")
           )
           |> push_navigate(to: Paths.catalogue_detail(target))}

        {:error, _} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to move category.")
           )}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("select_parent_move_target", %{"parent_uuid" => uuid}, socket) do
    target = Values.blank_to_nil(uuid)
    {:noreply, assign(socket, :parent_move_target, target)}
  end

  def handle_event("move_under_parent", _params, socket) do
    target = socket.assigns.parent_move_target

    case Catalogue.move_category_under(socket.assigns.category, target, actor_opts(socket)) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:category, updated)
         |> assign(:parent_options, parent_options_for(:edit, updated, updated.catalogue_uuid))
         |> put_flash(
           :info,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category moved.")
         )}

      {:error, :would_create_cycle} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(
             PhoenixKitCatalogue.Gettext,
             "Cannot move a category under itself or one of its descendants."
           )
         )}

      {:error, :cross_catalogue} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(
             PhoenixKitCatalogue.Gettext,
             "Parent must live in the same catalogue."
           )
         )}

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to move category.")
         )}
    end
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :confirm_delete_all, false)}
  end

  @impl true
  def handle_info({:ai_translation, event, payload}, socket) do
    {:noreply, handle_ai_translation_event(socket, event, payload, &assign_changeset/2)}
  end

  def handle_info({:media_selected, file_uuids}, socket),
    do: Attachments.handle_media_selected(socket, file_uuids)

  def handle_info({:media_selector_closed}, socket),
    do: {:noreply, Attachments.close_media_selector(socket)}

  # Catch-all so stray monitor signals or unrelated PubSub traffic
  # can't crash the form mid-edit.
  def handle_info(msg, socket) do
    Logger.debug("CategoryFormLive ignored unhandled message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # Form-submitted empty string means "no parent" — normalize so the
  # changeset treats it as NULL rather than attempting a malformed FK.
  defp normalize_parent_uuid(%{"parent_uuid" => ""} = params),
    do: Map.put(params, "parent_uuid", nil)

  defp normalize_parent_uuid(params), do: params

  # actor_opts/1 imported from PhoenixKitCatalogue.Web.Helpers

  defp save_category(socket, :new, params) do
    case Catalogue.create_category(params, actor_opts(socket)) do
      {:ok, category} ->
        _ = Attachments.maybe_rename_pending_folder(socket, category)

        {:noreply,
         socket
         |> put_flash(:info, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category created."))
         |> push_navigate(to: Paths.catalogue_detail(socket.assigns.catalogue_uuid))}

      {:error, changeset} ->
        {:noreply, assign_changeset(socket, changeset)}
    end
  end

  defp save_category(socket, :edit, params) do
    case Catalogue.update_category(socket.assigns.category, params, actor_opts(socket)) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category updated."))
         |> push_navigate(to: Paths.catalogue_detail(socket.assigns.catalogue_uuid))}

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
           No inline files grid on Category forms; featured image only. --%>
      <.live_component
        module={PhoenixKitWeb.Live.Components.MediaSelectorModal}
        id="category-form-media-selector"
        show={@show_media_selector}
        mode={@media_selection_mode}
        file_type_filter={@media_filter}
        selected_uuids={@media_selected_uuids}
        scope_folder_id={@files_folder_uuid}
        phoenix_kit_current_user={assigns[:phoenix_kit_current_user]}
      />

      <%!-- Header --%>
      <.admin_page_header back={Paths.catalogue_detail(@catalogue_uuid)} title={@page_title} subtitle={if @action == :new, do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Add a new category to organize items within this catalogue."), else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Update category details and ordering.")} />

      <%!-- Featured image — opens the scoped picker. Uuid stored on
           `category.data["featured_image_uuid"]`. The folder is lazily
           created on first open, so categories without a featured image
           never materialize one. --%>
      <.featured_image_card
        featured_image_uuid={@featured_image_uuid}
        featured_image_file={@featured_image_file}
        subtitle={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Shown on catalogue listings and category landing pages.")}
      />

      <.form for={@form} action="#" phx-change="validate" phx-submit="save">
        <div class="card bg-base-100 shadow-lg">
          <.multilang_tabs multilang_enabled={@multilang_enabled} language_tabs={@language_tabs} current_lang={@current_lang} />

          <div :if={@ai_translation_available?} class="px-6 -mt-1 mb-2">
            <div class="flex items-center gap-3">
              <.ai_translate_button ai_translate={ai_translate_config(assigns)} />
              <.ai_translate_progress ai_translate={ai_translate_config(assigns)} />
            </div>
            <.ai_translate_hint ai_translate={ai_translate_config(assigns)} />
          </div>

          <%!-- Only translatable fields live inside the wrapper so a
               language switch only re-mounts name + description, not
               the whole form. Everything else renders as a sibling. --%>
          <.multilang_fields_wrapper multilang_enabled={@multilang_enabled} current_lang={@current_lang} skeleton_class="card-body flex flex-col gap-5 pb-0">
            <:skeleton>
              <%!-- Name --%>
              <div class="space-y-2">
                <div class="skeleton h-4 w-20"></div>
                <div class="skeleton h-12 w-full"></div>
              </div>
              <%!-- Description --%>
              <div class="space-y-2">
                <div class="skeleton h-4 w-28"></div>
                <div class="skeleton h-24 w-full"></div>
              </div>
            </:skeleton>
            <div class="card-body flex flex-col gap-5 pb-0">
              <.translatable_field
                field_name="name" form_prefix="category" changeset={@changeset}
                schema_field={:name} multilang_enabled={@multilang_enabled}
                current_lang={@current_lang} primary_language={@primary_language}
                lang_data={@lang_data} label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Name")} placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "e.g., Cabinet Frames")}
                required class="w-full"
              />

              <.translatable_field
                field_name="description" form_prefix="category" changeset={@changeset}
                schema_field={:description} multilang_enabled={@multilang_enabled}
                current_lang={@current_lang} primary_language={@primary_language}
                lang_data={@lang_data} label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Description")} type="textarea"
                placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "What kinds of items belong in this category...")}
                class="w-full"
              />
            </div>
          </.multilang_fields_wrapper>

          <div class="card-body flex flex-col gap-5 pt-0">
            <div class="divider my-0"></div>

            <div :if={@action == :new} class="form-control">
              <.select
                field={@form[:parent_uuid]}
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Parent category")}
                prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "— Top level (no parent) —")}
                options={@parent_options}
                class="transition-colors focus-within:select-primary"
              />
              <span class="label-text-alt text-base-content/50 mt-1">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Pick a parent to nest this category inside, or leave blank to keep it at the top level. You can move it later.")}</span>
            </div>

            <div class="form-control">
              <.input
                field={@form[:position]}
                type="number"
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Position")}
                class="w-28"
                min="0"
              />
              <span class="label-text-alt text-base-content/50 mt-1">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Lower numbers appear first. You can also reorder from the catalogue detail page.")}</span>
            </div>

            <%!-- Actions --%>
            <div class="divider my-0"></div>

            <div class="flex justify-end gap-3">
              <.link navigate={Paths.catalogue_detail(@catalogue_uuid)} class="btn btn-ghost">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Cancel")}</.link>
              <button
                type="submit"
                class="btn btn-primary phx-submit-loading:opacity-75"
                phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Saving...")}
              >{if @action == :new, do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Create Category"), else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Save Changes")}</button>
            </div>
          </div>
        </div>
      </.form>

      <%!-- AI translate modal — outside the form (its selectors are their
           own <form>; nested forms are invalid). --%>
      <.ai_translate_modal ai_translate={ai_translate_config(assigns)} />

      <%!-- Move actions — collapsed by default to keep destructive +
           low-frequency actions out of the primary edit flow.
           Native <details> handles toggle; no JS needed. --%>
      <details :if={@action == :edit} class="card bg-base-100 shadow-lg">
        <summary class="card-body py-3 cursor-pointer flex-row items-center gap-2 select-none">
          <.icon name="hero-arrows-right-left" class="w-4 h-4 text-base-content/60" />
          <h3 class="font-semibold text-base">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move")}</h3>
          <.icon name="hero-chevron-down" class="w-4 h-4 ml-auto text-base-content/40" />
        </summary>

        <div class="card-body pt-0 space-y-6">
          <%!-- Move to a different parent — within the same catalogue --%>
          <div class="flex flex-col gap-3">
            <div>
              <p class="font-medium text-sm">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move to Another Parent")}</p>
              <p class="text-xs text-base-content/60">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Reparent this category within its catalogue. Its subtree comes along.")}</p>
            </div>
            <div class="flex items-end gap-3">
              <div class="form-control flex-1">
                <.select
                  name="parent_uuid"
                  id="category-parent-move-target"
                  value={@parent_move_target}
                  prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "— Top level (no parent) —")}
                  options={@parent_options}
                  class="select-sm transition-colors focus-within:select-primary"
                  phx-change="select_parent_move_target"
                />
              </div>
              <button
                type="button"
                phx-click="move_under_parent"
                phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Moving...")}
                disabled={@parent_move_target == @category.parent_uuid}
                class="btn btn-sm btn-outline"
              >
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move")}
              </button>
            </div>
          </div>

          <%!-- Move to another catalogue — only when other catalogues exist --%>
          <div :if={@other_catalogues != []} class="flex flex-col gap-3">
            <div>
              <p class="font-medium text-sm">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move to Another Catalogue")}</p>
              <p class="text-xs text-base-content/60">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move this category and all its items to a different catalogue.")}</p>
            </div>
            <div class="flex items-end gap-3">
              <div class="form-control flex-1">
                <.select
                  name="catalogue_uuid"
                  id="category-move-target"
                  value={@move_target}
                  prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "-- Select catalogue --")}
                  options={Enum.map(@other_catalogues, &{&1.name, &1.uuid})}
                  class="select-sm transition-colors focus-within:select-primary"
                  phx-change="select_move_target"
                />
              </div>
              <button
                type="button"
                phx-click="move_category"
                phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Moving...")}
                disabled={is_nil(@move_target)}
                class="btn btn-sm btn-outline"
              >
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move")}
              </button>
            </div>
          </div>
        </div>
      </details>

      <%!-- Danger zone — collapsed by default; matches the integrations
           page Danger Zone pattern (red border, exclamation-triangle,
           confirm modal on click). --%>
      <details :if={@action == :edit} class="card bg-base-100 border-2 border-error/30">
        <summary class="card-body py-3 cursor-pointer flex-row items-center gap-2 select-none">
          <.icon name="hero-exclamation-triangle" class="w-4 h-4 text-error" />
          <h3 class="font-semibold text-error text-base">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Danger Zone")}</h3>
          <.icon name="hero-chevron-down" class="w-4 h-4 ml-auto text-base-content/40" />
        </summary>

        <div class="card-body pt-0 space-y-4">
          <div class="flex items-center justify-between gap-4">
            <div>
              <p class="font-medium text-sm">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Permanently Delete Category")}</p>
              <p class="text-xs text-base-content/60">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "This will permanently delete this category and all its items. This cannot be undone.")}</p>
            </div>
            <button phx-click="show_delete_confirm" class="btn btn-outline btn-error btn-sm shrink-0">
              <.icon name="hero-trash" class="w-4 h-4" />
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete Forever")}
            </button>
          </div>
        </div>
      </details>

      <.confirm_modal
        show={@confirm_delete_all}
        on_confirm="delete_category"
        on_cancel="cancel_delete"
        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Permanently Delete Category")}
        title_icon="hero-trash"
        messages={[{:warning, Gettext.gettext(PhoenixKitCatalogue.Gettext, "This will permanently delete this category and all its items.")}]}
        confirm_text={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete Forever")}
        danger={true}
      />
    </div>
    """
  end
end
