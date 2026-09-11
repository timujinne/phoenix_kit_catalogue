defmodule PhoenixKitCatalogue.Web.CategoryFormLive do
  @moduledoc "Create/edit form for categories within a catalogue."

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitCatalogue.Gettext
  use PhoenixKitAI.Components.AITranslate.Embed

  require Logger

  import PhoenixKitWeb.Components.MultilangForm
  import PhoenixKitWeb.Components.Core.Button, only: [button: 1]
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Input, only: [input: 1]
  import PhoenixKitWeb.Components.Core.Modal, only: [confirm_modal: 1]
  import PhoenixKitWeb.Components.Core.Select, only: [select: 1]
  import PhoenixKitCatalogue.Web.Components, only: [attachments_files_panel: 1]

  import PhoenixKitCatalogue.Web.Helpers,
    only: [
      actor_opts: 1,
      assign_ai_translation: 3,
      ai_translate_config: 1,
      data_owned_keys: 2
    ]

  import PhoenixKitAI.Components.AITranslate,
    only: [
      ai_multilang_tabs: 1,
      ai_translate_modal: 1
    ]

  alias PhoenixKit.Utils.Multilang
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.Utils.Values
  alias PhoenixKitCatalogue.Attachments
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.Slugs
  alias PhoenixKitCatalogue.Extensions
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Schemas.Category

  @translatable_fields ["name", "description", "seo_title", "seo_description"]

  # Primary-language columns survive validates/saves fired from a
  # secondary language tab (same shape as the attribute-group fix —
  # without this, filling all languages before the first save loses the
  # primary text on :new).
  @preserve_fields %{"name" => :name, "description" => :description}

  # Top-level `data` keys this form writes OUTSIDE the shared multilang/
  # extension pipeline `data_owned_keys/2` already covers — see
  # `Attachments.inject_attachment_data/2`. No metadata namespace on
  # categories (`PhoenixKitCatalogue.Metadata` only covers `:item` /
  # `:catalogue`). Threaded into `Catalogue.update_category/3`'s
  # `:data_owned_keys` option at the save call site below.
  @category_extra_owned_data_keys ~w(files_folder_uuid featured_image_uuid media_order)

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
      socket
      |> assign(:return_to, safe_return_to(params["return_to"]))
      |> mount_category_form(action, category, changeset, catalogue_uuid)
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
       parent_catalogue_name:
         catalogue_uuid && (Catalogue.get_catalogue(catalogue_uuid) || %{name: nil}).name,
       confirm_delete_all: false,
       other_catalogues: other_catalogues,
       parent_options: parent_options,
       parent_move_target: category && category.parent_uuid,
       move_target: nil
     )
     |> assign(current_tab: :details, extensions: Extensions.sections(:category))
     |> Attachments.mount_attachments(category)
     |> Attachments.allow_attachment_upload()
     |> assign_changeset(changeset)
     |> mount_multilang()
     |> assign_ai_translation("catalogue_category", if(action == :edit, do: category, else: nil))}
  end

  # Tree-flattened options for the parent picker. Root entry first,
  # then each category prefixed with indentation that matches its
  # depth. For edit mode, the category's own subtree is excluded so
  # the user can't pick itself or one of its descendants.
  defp safe_return_to(rt) when is_binary(rt) do
    if Routes.local_path?(rt), do: rt
  end

  defp safe_return_to(_), do: nil

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

  # See the identical helper in `PhoenixKitCatalogue.Web.ItemFormLive` —
  # `slug` is a flat `lang -> value` map and the form only ever renders
  # one language's input at a time, so a plain cast would drop every
  # other language's slug. Non-blank submitted values are merged onto
  # the existing map; a blank submission leaves the existing value alone
  # (write-once) and `Slugs.maybe_generate/3` fills any language present
  # in `data` that still has none.
  defp apply_slug(params, socket) do
    existing_slug = Ecto.Changeset.get_field(socket.assigns.changeset, :slug) || %{}

    merged_slug =
      case params["slug"] do
        incoming when is_map(incoming) ->
          incoming
          |> Enum.filter(fn {_lang, value} -> is_binary(value) and value != "" end)
          |> Enum.into(existing_slug)

        _ ->
          existing_slug
      end

    generated_slug =
      socket.assigns.category
      |> Catalogue.change_category(Map.put(params, "slug", merged_slug))
      |> Slugs.maybe_generate(:slug, from: :name)
      |> Ecto.Changeset.get_field(:slug)

    Map.put(params, "slug", generated_slug || merged_slug)
  end

  defp slug_lang(assigns), do: assigns.current_lang || Multilang.primary_language()

  defp translatable_param_name(assigns, form_prefix, field) do
    if assigns.current_lang == assigns.primary_language,
      do: "#{form_prefix}[#{field}]",
      else: "#{form_prefix}[lang_#{field}]"
  end

  # `seo_title`/`seo_description` have no DB column — they only ever live
  # under `data["_seo_title"]`/`data["_seo_description"]`. When multilang
  # is enabled, `merge_translatable_params/4` (via `@translatable_fields`)
  # already folds them in. When it's disabled, that helper leaves `params`
  # untouched entirely (it only writes `data` inside its `multilang_enabled`
  # branch), so on a single-language install the two fields would
  # otherwise be silently dropped by `cast/2` on every save. Mirrors
  # `extract_translatable_data/4`'s own logic for the primary-language case.
  defp merge_seo_params(params, socket) do
    if socket.assigns.multilang_enabled do
      params
    else
      data =
        Map.get(params, "data") ||
          Ecto.Changeset.get_field(socket.assigns.changeset, :data) || %{}

      data = Enum.reduce(["seo_title", "seo_description"], data, &put_seo_field(&1, &2, params))

      Map.put(params, "data", data)
    end
  end

  # One SEO field folded into the single-language `data` map, keyed with the
  # leading underscore the multilang reader expects. A field the form did not
  # submit leaves `data` untouched.
  defp put_seo_field(field, data, params) do
    case Map.get(params, field) do
      value when is_binary(value) -> Map.put(data, "_#{field}", value)
      _ -> data
    end
  end

  # See the identical helpers in `PhoenixKitCatalogue.Web.ItemFormLive` —
  # same extension-slot wiring, `:category` instead of `:item`.
  defp category_data(form), do: form[:data].value || %{}

  defp absorb_category_extensions(category_params, socket) do
    data =
      Map.get(category_params, "data") ||
        Ecto.Changeset.get_field(socket.assigns.changeset, :data) || %{}

    case Extensions.absorb(:category, category_params, data) do
      {:ok, merged} -> {Map.put(category_params, "data", merged), nil}
      {:error, {_mod, _errors} = error} -> {Map.put(category_params, "data", data), error}
    end
  end

  defp add_extension_error(changeset, nil), do: changeset

  defp add_extension_error(changeset, {mod, errors}) do
    Enum.reduce(errors, changeset, fn {field, msg}, cs ->
      Ecto.Changeset.add_error(cs, :data, msg, extension: mod.key(), field: field)
    end)
  end

  # AI-translate modal events handled by `use ...AITranslate.Embed`.

  # "switch_language" is handled by the core `mount_multilang/1` auto hook
  # (default `auto_switch_language: true`) — no clause needed here.

  @impl true
  def handle_event("validate", %{"category" => params}, socket) do
    params =
      params
      # `put/3`, not `put_new/3`: the catalogue is the SERVER's scope, taken
      # from the URL, and a client-supplied `catalogue_uuid` in the form
      # payload must not win it. `:catalogue_uuid` is in the cast allowlist,
      # so with `put_new` a forged submit could file the record under a
      # different catalogue than the one being edited.
      |> Map.put("catalogue_uuid", socket.assigns.catalogue_uuid)
      |> normalize_parent_uuid()
      |> merge_translatable_params(socket, @translatable_fields,
        changeset: socket.assigns.changeset,
        preserve_fields: @preserve_fields
      )
      |> merge_seo_params(socket)
      |> apply_slug(socket)

    {params, extension_error} = absorb_category_extensions(params, socket)

    changeset =
      socket.assigns.category
      |> Catalogue.change_category(params)
      |> Map.put(:action, :validate)
      |> add_extension_error(extension_error)

    {:noreply, assign_changeset(socket, changeset)}
  end

  def handle_event("save", params, socket) do
    category_params =
      params
      |> Map.get("category", %{})
      |> Map.put("catalogue_uuid", socket.assigns.catalogue_uuid)
      |> normalize_parent_uuid()
      |> merge_translatable_params(socket, @translatable_fields,
        changeset: socket.assigns.changeset,
        preserve_fields: @preserve_fields
      )
      |> merge_seo_params(socket)
      |> apply_slug(socket)

    {category_params, extension_error} = absorb_category_extensions(category_params, socket)

    case extension_error do
      nil ->
        category_params = Attachments.inject_attachment_data(category_params, socket)
        save_category(socket, socket.assigns.action, category_params, save_mode(params))

      error ->
        changeset =
          socket.assigns.category
          |> Catalogue.change_category(category_params)
          |> Map.put(:action, :validate)
          |> add_extension_error(error)

        {:noreply, assign_changeset(socket, changeset)}
    end
  end

  # ── Attachments (featured image modal only) ──────────────────────
  # Category has a featured image but no inline files grid — the
  # lightweight treatment my AGENTS.md comparison landed on.

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :current_tab, parse_tab(tab))}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket),
    do: Attachments.cancel_attachment_upload(socket, ref)

  def handle_event("reorder_files", %{"ordered_ids" => ids}, socket),
    do: {:noreply, Attachments.handle_reorder_files(socket, ids)}

  def handle_event("remove_file", %{"uuid" => uuid}, socket),
    do: Attachments.trash_file(socket, uuid)

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
         |> push_navigate(
           to: socket.assigns[:return_to] || Paths.catalogue_detail(socket.assigns.catalogue_uuid)
         )}

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

  # {:ai_translation, ...} events folded into the form by `use ...AITranslate.Embed`.
  @impl true
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

  defp save_category(socket, :new, params, mode) do
    case Catalogue.create_category(params, actor_opts(socket)) do
      {:ok, category} ->
        _ = Attachments.maybe_rename_pending_folder(socket, category)

        # "Save" (stay) continues on the new category's edit form; the
        # original return_to rides along so the eventual exit still goes
        # home. Exit honors return_to too (it used to fall straight back
        # to the catalogue root even when the form was opened deeper).
        target =
          case mode do
            :stay -> Paths.category_edit(category.uuid) <> return_to_suffix(socket)
            :exit -> exit_target(socket)
          end

        {:noreply,
         socket
         |> put_flash(:info, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category created."))
         |> push_navigate(to: target)}

      {:error, changeset} ->
        {:noreply, assign_changeset(socket, changeset)}
    end
  end

  defp save_category(socket, :edit, params, mode) do
    update_opts =
      actor_opts(socket) ++
        [data_owned_keys: data_owned_keys(socket, @category_extra_owned_data_keys)]

    case Catalogue.update_category(socket.assigns.category, params, update_opts) do
      {:ok, category} ->
        socket =
          put_flash(
            socket,
            :info,
            Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category updated.")
          )

        case mode do
          :stay -> {:noreply, refresh_after_edit(socket, category)}
          :exit -> {:noreply, push_navigate(socket, to: exit_target(socket))}
        end

      {:error, changeset} ->
        {:noreply, assign_changeset(socket, changeset)}
    end
  end

  # The clicked submit button ships its name/value with the form params.
  # Anything other than the explicit "stay" (absent, forged, or stale)
  # falls back to the exit behavior — same as before the split.
  defp parse_tab("files"), do: :files
  defp parse_tab(_), do: :details

  defp save_mode(%{"save_action" => "stay"}), do: :stay
  defp save_mode(_params), do: :exit

  defp exit_target(socket) do
    socket.assigns[:return_to] || Paths.catalogue_detail(socket.assigns.catalogue_uuid)
  end

  defp return_to_suffix(socket) do
    case socket.assigns[:return_to] do
      nil -> ""
      rt -> "?" <> URI.encode_query([{"return_to", rt}])
    end
  end

  # In-place refresh after a stay-save: no remount, so the current
  # language tab and scroll position survive. Only category-derived
  # assigns need re-deriving; parent_options is rebuilt in case the
  # save renamed categories shown in the Move panel's picker.
  defp refresh_after_edit(socket, category) do
    socket
    |> assign(:category, category)
    |> assign(
      :page_title,
      Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit %{name}", name: category.name)
    )
    |> assign(:parent_options, parent_options_for(:edit, category, category.catalogue_uuid))
    |> assign_changeset(Catalogue.change_category(category))
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
      page_section={@parent_catalogue_name}
      page_section_path={@catalogue_uuid && Paths.catalogue_detail(@catalogue_uuid)}
      page_subtitle={if @action == :new, do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Add a new category to organize items within this catalogue."), else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Update category details and ordering.")}
      current_path={assigns[:url_path] || Paths.catalogue_detail(@catalogue_uuid)}
      current_locale={assigns[:current_locale]}
    >
      <div class="container flex flex-col mx-auto px-4 py-6 gap-6">
      <%!-- Media selector — folder-scoped featured-image picker. --%>
      <.live_component
        module={PhoenixKitWeb.Live.Components.MediaSelectorModal}
        id="category-form-media-selector"
        show={@show_media_selector}
        mode={@media_selection_mode}
        file_type_filter={@media_filter}
        lock_file_type
        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Select Featured Image")}
        selected_uuids={@media_selected_uuids}
        scope_folder_id={@files_folder_uuid}
        phoenix_kit_current_user={assigns[:phoenix_kit_current_user]}
      />

      <%!-- Tab strip — same structure as the catalogue and item forms;
           each panel stays in the DOM (toggled by `hidden`) so the
           multilang wrapper and any user input survive tab flips. --%>
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

      <.form for={@form} id="category-form" action="#" phx-change="validate" phx-submit="save">
        <div class={"card bg-base-100 shadow-lg #{if @current_tab != :details, do: "hidden"}"}>
          <%!-- Bundled tabs + AI row (phoenix_kit_ai's canonical placement). --%>
          <.ai_multilang_tabs
            multilang_enabled={@multilang_enabled}
            language_tabs={@language_tabs}
            current_lang={@current_lang}
            ai_translate={ai_translate_config(assigns)}
          />

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

              <.input
                field={@form[:slug]}
                name={"category[slug][#{slug_lang(assigns)}]"}
                value={Map.get(@form[:slug].value || %{}, slug_lang(assigns), "")}
                type="text"
                label={gettext("URL slug")}
                placeholder={gettext("auto-generated from the name")}
                class="w-full"
              />

              <.translatable_field
                field_name="description" form_prefix="category" changeset={@changeset}
                schema_field={:description} multilang_enabled={@multilang_enabled}
                current_lang={@current_lang} primary_language={@primary_language}
                lang_data={@lang_data} label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Description")} type="textarea"
                placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "What kinds of items belong in this category...")}
                class="w-full"
              />

              <.input
                type="text"
                name={translatable_param_name(assigns, "category", "seo_title")}
                value={Map.get(@lang_data, "_seo_title") || ""}
                label={gettext("SEO title")}
                class="w-full"
              />

              <.input
                type="text"
                name={translatable_param_name(assigns, "category", "seo_description")}
                value={Map.get(@lang_data, "_seo_description") || ""}
                label={gettext("SEO description")}
                class="w-full"
              />
            </div>
          </.multilang_fields_wrapper>

          <div class="card-body flex flex-col gap-5 pt-0">
            <div class="divider my-0"></div>

            <div :if={@action == :new} class="fieldset">
              <.select
                field={@form[:parent_uuid]}
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Parent category")}
                prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "— Top level (no parent) —")}
                options={@parent_options}
                class="transition-colors focus-within:select-primary"
              />
              <span class="fieldset-label text-base-content/50 mt-1">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Pick a parent to nest this category inside, or leave blank to keep it at the top level. You can move it later.")}</span>
            </div>

            <%!-- No manual Position field: a new category appends to its
                 level (next_category_position at mount) and ordering is
                 drag-managed on the catalogue detail page — same as
                 catalogues and items. --%>

            <%!-- Extension slot (spec §2 principle 8, §4 row C4) — other
                 registered modules (e.g. phoenix_kit_ecommerce) add a
                 section here. Empty and invisible when nothing is
                 registered/enabled; catalogue never names an implementer. --%>
            <%= for ext <- @extensions do %>
              {ext.category_section(%{
                form: @form,
                category: @category,
                data: category_data(@form),
                current_language: @current_lang,
                # See the identical comment in `ItemFormLive` — this map is
                # a plain function-call argument, not built through
                # `<.component />`, so it needs its own change-tracking key.
                __changed__: %{}
              })}
            <% end %>

            <%!-- Actions --%>
            <div class="divider my-0"></div>

          </div>
        </div>

        <%!-- Files tab — featured image + inline files dropzone, the
             same shared panel the catalogue and item forms use. --%>
        <div class={"flex flex-col gap-6 mt-6 #{if @current_tab != :files, do: "hidden"}"}>
          <.attachments_files_panel
            uploads={@uploads}
            files_state={@files_state}
            featured_image_uuid={@featured_image_uuid}
            featured_image_file={@featured_image_file}
            featured_subtitle={
              Gettext.gettext(
                PhoenixKitCatalogue.Gettext,
                "Shown on catalogue listings and category landing pages."
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
                "Remove this file from the category? If it's not attached to any other resource, it will be moved to trash (admins can restore)."
              )
            }
            remove_title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Remove from category")}
          />
        </div>

        <%!-- Actions — outside the tab panels so Save works from any
             tab; disabled while uploads are mid-flight so the save
             can't race the post-upload write. "Save" keeps you on the
             form (also the Enter-key submitter, being first in the
             DOM); "Save & Exit" returns to where the form was opened
             from. "Save" keeps `class="btn-outline"` — a style modifier
             that composes with the component's default btn-primary,
             where `variant="outline"` would replace the colour. --%>
        <div class="flex justify-end gap-3 pt-6">
          <.button navigate={@return_to || Paths.catalogue_detail(@catalogue_uuid)} variant="ghost">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Cancel")}
          </.button>
          <.button
            type="submit"
            name="save_action"
            value="stay"
            class="btn-outline"
            disabled={@uploads.attachment_files.entries != []}
            phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Saving...")}
          >{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Save")}</.button>
          <.button
            type="submit"
            name="save_action"
            value="exit"
            disabled={@uploads.attachment_files.entries != []}
            phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Saving...")}
          >{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Save & Exit")}</.button>
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
              <div class="fieldset flex-1">
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
              <.button
                type="button"
                phx-click="move_under_parent"
                phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Moving...")}
                disabled={@parent_move_target == @category.parent_uuid}
                variant="outline"
                size="sm"
              >
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move")}
              </.button>
            </div>
          </div>

          <%!-- Move to another catalogue — only when other catalogues exist --%>
          <div :if={@other_catalogues != []} class="flex flex-col gap-3">
            <div>
              <p class="font-medium text-sm">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move to Another Catalogue")}</p>
              <p class="text-xs text-base-content/60">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move this category and all its items to a different catalogue.")}</p>
            </div>
            <div class="flex items-end gap-3">
              <div class="fieldset flex-1">
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
              <.button
                type="button"
                phx-click="move_category"
                phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Moving...")}
                disabled={is_nil(@move_target)}
                variant="outline"
                size="sm"
              >
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move")}
              </.button>
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
            <%!-- `variant="error"`, not `class="btn-error"` — the class form
                 leaves the default btn-primary on the element next to it. --%>
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
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
