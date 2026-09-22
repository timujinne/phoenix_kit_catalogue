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
  import PhoenixKitWeb.Components.Core.Select, only: [select: 1]
  import PhoenixKitCatalogue.Web.Components, only: [attachments_files_panel: 1]

  import PhoenixKitCatalogue.Web.Helpers,
    only: [
      open_on_viewing_language: 2,
      narrow_new_data: 2,
      actor_opts: 1,
      assign_ai_translation: 3,
      ai_translate_config: 1,
      data_owned_keys: 2,
      log_operation_error: 3
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
  alias PhoenixKitCatalogue.Catalogue.PubSub
  alias PhoenixKitCatalogue.Catalogue.Slugs
  alias PhoenixKitCatalogue.Errors
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

    # Subscribe before the read so a write landing in between is not
    # dropped; the files grid follows the resource's broadcasts.
    if connected?(socket), do: PubSub.subscribe()

    {category, changeset, catalogue_uuid} =
      case action do
        :new ->
          catalogue_uuid = params["catalogue_uuid"]
          parent_uuid = Values.blank_to_nil(params["parent_uuid"])

          # No position here: the form renders no position field and
          # `create_category/2` computes it at insert time, so a mount-time
          # query was thrown away on every render.
          cat = %Category{catalogue_uuid: catalogue_uuid, parent_uuid: parent_uuid}

          # The catalogue in the URL is checked first: an unknown one — or
          # a hand-edited path that is not a UUID — would otherwise reach a
          # query further down the mount and raise instead of saying
          # "not found".
          if Catalogue.get_catalogue(catalogue_uuid),
            do: {cat, Catalogue.change_category(cat), catalogue_uuid},
            else: {nil, nil, nil}

        :edit ->
          case Catalogue.get_category(params["uuid"]) do
            nil ->
              Logger.warning("Category not found for edit: #{params["uuid"]}")
              {nil, nil, nil}

            cat ->
              {cat, Catalogue.change_category(cat), cat.catalogue_uuid}
          end
      end

    if is_nil(category) do
      message =
        if action == :edit,
          do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category not found."),
          else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue not found.")

      {:ok,
       socket
       |> put_flash(:error, message)
       |> push_navigate(to: Paths.index())}
    else
      socket
      |> assign(:return_to, safe_return_to(params["return_to"]))
      |> mount_category_form(action, category, changeset, catalogue_uuid)
    end
  end

  defp mount_category_form(socket, action, category, changeset, catalogue_uuid) do
    parent_catalogue = catalogue_uuid && Catalogue.get_catalogue(catalogue_uuid)

    other_catalogues =
      if action == :edit,
        do: catalogue_move_options(parent_catalogue),
        else: []

    parent_options = parent_options_for(action, category, catalogue_uuid)

    {:ok,
     socket
     |> assign(
       page_title:
         if(action == :new,
           do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "New category"),
           else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit %{name}", name: category.name)
         ),
       action: action,
       category: category,
       catalogue_uuid: catalogue_uuid,
       parent_catalogue_name: parent_catalogue && parent_catalogue.name,
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
     |> open_on_viewing_language(action)
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

  # "catalogue:<uuid>" lands at that catalogue's top level;
  # "category:<uuid>" under that category, in its catalogue.
  defp move_to_other_catalogue(socket, target) do
    {catalogue_uuid, opts} =
      case target do
        "catalogue:" <> uuid ->
          {uuid, actor_opts(socket)}

        "category:" <> uuid ->
          parent = Catalogue.get_category(uuid)
          {parent && parent.catalogue_uuid, Keyword.put(actor_opts(socket), :parent_uuid, uuid)}
      end

    with uuid when is_binary(uuid) <- catalogue_uuid,
         {:ok, _} <-
           Catalogue.move_category_to_catalogue(socket.assigns.category, uuid, opts) do
      {:noreply,
       socket
       |> put_flash(
         :info,
         Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category moved to another catalogue.")
       )
       |> push_navigate(to: Paths.catalogue_detail(uuid))}
    else
      nil ->
        {:noreply, move_failed(socket, "move_category_to_catalogue", :parent_not_found)}

      {:error, reason} ->
        {:noreply, move_failed(socket, "move_category_to_catalogue", reason)}
    end
  end

  defp move_failed(socket, operation, reason) do
    log_operation_error(socket, operation, %{
      entity_type: "category",
      entity_uuid: socket.assigns.category.uuid,
      reason: reason
    })

    put_flash(socket, :error, move_error_message(reason))
  end

  defp move_error_message(reason)
       when reason in [
              :catalogue_not_found,
              :kind_mismatch,
              :not_found,
              :parent_not_found,
              :would_create_cycle,
              :catalogue_moved
            ],
       do: Errors.message(reason)

  defp move_error_message(_reason),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to move category.")

  # Every other live catalogue of this one's kind, as a `<select>` group:
  # its top level, then its categories (a category can land under one).
  # Values say what they are — `"catalogue:<uuid>"` / `"category:<uuid>"`.
  defp catalogue_move_options(nil), do: []

  defp catalogue_move_options(%{uuid: own_uuid, kind: kind}) do
    categories = Enum.group_by(Catalogue.list_all_categories(), & &1.catalogue_uuid)

    [kind: kind]
    |> Catalogue.list_catalogues()
    |> Enum.reject(&(&1.uuid == own_uuid))
    |> Enum.map(fn catalogue ->
      top =
        {Gettext.gettext(PhoenixKitCatalogue.Gettext, "%{catalogue} — top level",
           catalogue: catalogue.name
         ), "catalogue:" <> catalogue.uuid}

      under =
        for cat <- Map.get(categories, catalogue.uuid, []),
            do: {cat.name, "category:" <> cat.uuid}

      {catalogue.name, [top | under]}
    end)
  end

  defp move_option_values(options) do
    Enum.flat_map(options, fn {_group, entries} -> Enum.map(entries, &elem(&1, 1)) end)
  end

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

    # `taken?` — see the item form: a generated slug another category
    # (or a trashed one) already holds gets a `-2` suffix.
    own_uuid = socket.assigns.category.uuid

    generated_slug =
      socket.assigns.category
      |> Catalogue.change_category(Map.put(params, "slug", merged_slug))
      |> Slugs.maybe_generate(:slug,
        from: :name,
        taken?: &Catalogue.category_slug_taken?(&1, &2, exclude_uuid: own_uuid)
      )
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

  # Only a value the select offered is kept (see catalogue_move_options/1).
  def handle_event("select_move_target", params, socket) do
    value = params["move_target"]

    target =
      if is_binary(value) and value in move_option_values(socket.assigns.other_catalogues),
        do: value

    {:noreply, assign(socket, :move_target, target)}
  end

  def handle_event("move_category", _params, socket) do
    case socket.assigns.move_target do
      nil -> {:noreply, socket}
      target -> move_to_other_catalogue(socket, target)
    end
  end

  def handle_event("select_parent_move_target", %{"parent_uuid" => uuid}, socket)
      when is_binary(uuid) do
    target = Values.blank_to_nil(uuid)
    {:noreply, assign(socket, :parent_move_target, target)}
  end

  # A forged non-string value would reach `move_category_under/3`, which
  # has no clause for it.
  def handle_event("select_parent_move_target", _params, socket), do: {:noreply, socket}

  def handle_event("move_under_parent", _params, socket) do
    target = socket.assigns.parent_move_target

    case Catalogue.move_category_under(socket.assigns.category, target, actor_opts(socket)) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:category, updated)
         |> assign(:parent_options, parent_options_for(:edit, updated, updated.catalogue_uuid))
         |> put_flash(:info, moved_flash(socket, target))}

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

      {:error, reason} ->
        {:noreply, move_failed(socket, "move_category_under", reason)}
    end
  end

  # {:ai_translation, ...} events folded into the form by `use ...AITranslate.Embed`.
  @impl true
  def handle_info({:media_selected, file_uuids}, socket),
    do: Attachments.handle_media_selected(socket, file_uuids)

  def handle_info({:media_selector_closed}, socket),
    do: {:noreply, Attachments.close_media_selector(socket)}

  # This category changed elsewhere (an upload, a removal, a photo
  # reorder in another tab): re-read the files grid, which is the one
  # thing this form shows from the DB; typed fields stay as they are.
  def handle_info(
        {:catalogue_data_changed, :category, uuid, _parent},
        %{assigns: %{category: %{uuid: category_uuid}}} = socket
      )
      when is_binary(uuid) and uuid == category_uuid do
    {:noreply, Attachments.refresh_files(socket)}
  end

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

  # Name the destination: "moved" alone left the client hunting for
  # the category on the level she came from (2026-08-31). The name is
  # localized like the detail page's flash, not the primary-language
  # column.
  defp moved_flash(_socket, nil),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category moved to the top level.")

  defp moved_flash(socket, target_uuid) do
    case Catalogue.get_category(target_uuid) do
      nil ->
        Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category moved.")

      target ->
        Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category moved into %{name}.",
          name: Catalogue.localize_one(target, socket.assigns[:current_locale]).name
        )
    end
  end

  defp save_category(socket, :new, params, mode) do
    params = narrow_new_data(params, data_owned_keys(socket, @category_extra_owned_data_keys))

    case Catalogue.create_category(params, actor_opts(socket)) do
      {:ok, category} ->
        # See the item form: translations in hand at create are fresh
        # against this source, not `:unknown`.
        category = PhoenixKitCatalogue.TranslationStatus.stamp_all_translated(category)
        _ = Attachments.maybe_rename_pending_folder(socket, category)

        # "Save" (stay) continues on the new category's edit form, with the
        # original return_to riding along for its Cancel. "Save & exit"
        # opens the saved category, as the catalogue form opens the saved
        # catalogue (Max, 2026-09-14); Cancel is what returns to where the
        # form was opened.
        target =
          case mode do
            :stay -> Paths.category_edit(category.uuid) <> return_to_suffix(socket)
            :exit -> Paths.category_browse(category.catalogue_uuid, category.uuid)
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
          :stay ->
            {:noreply, refresh_after_edit(socket, category)}

          :exit ->
            {:noreply,
             push_navigate(socket,
               to: Paths.category_browse(category.catalogue_uuid, category.uuid)
             )}
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

  # What an SEO field holds. Core's `get_lang_data/3` answers %{} whenever
  # multilang is off, while a single-language save stores these flat under
  # `data` — so they read blank and the next save erased them. Same fix as
  # the item form's `seo_value/2`.
  defp seo_value(%{multilang_enabled: true} = assigns, field),
    do: Map.get(assigns.lang_data, "_" <> field) || ""

  defp seo_value(assigns, field) do
    data = Ecto.Changeset.get_field(assigns.changeset, :data) || %{}
    Map.get(Multilang.get_primary_data(data), "_" <> field) || ""
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
        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Select featured image")}
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
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Photos and files")}
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
                placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "What kinds of items belong in this category…")}
                class="w-full"
              />

              <.input
                type="text"
                name={translatable_param_name(assigns, "category", "seo_title")}
                value={seo_value(assigns, "seo_title")}
                label={gettext("SEO title")}
                class="w-full"
              />

              <.input
                type="text"
                name={translatable_param_name(assigns, "category", "seo_description")}
                value={seo_value(assigns, "seo_description")}
                label={gettext("SEO description")}
                class="w-full"
              />
            </div>
          </.multilang_fields_wrapper>

          <div class="card-body flex flex-col gap-5 pt-0">
            <div class="divider my-0"></div>

            <div :if={@action == :new}>
              <.select
                field={@form[:parent_uuid]}
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Parent category")}
                prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "— Top level (no parent) —")}
                options={@parent_options}
                class="transition-colors focus-within:select-primary"
              />
              <span class="block text-xs text-base-content/50 mt-1">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Pick a parent to nest this category inside, or leave blank to keep it at the top level. You can move it later.")}</span>
            </div>

            <%!-- No manual Position field: a new category appends to its
                 level (the position is computed at insert) and ordering is
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
             DOM); "Save & exit" opens the saved category; Cancel returns to
             where the form was opened from. "Save" keeps `class="btn-outline"` — a style modifier
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
            phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Saving…")}
          >{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Save")}</.button>
          <.button
            type="submit"
            name="save_action"
            value="exit"
            disabled={@uploads.attachment_files.entries != []}
            phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Saving…")}
          >{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Save & exit")}</.button>
        </div>
      </.form>

      <%!-- AI translate modal — outside the form (its selectors are their
           own <form>; nested forms are invalid). --%>
      <.ai_translate_modal ai_translate={ai_translate_config(assigns)} />

      <%!-- Move actions — collapsed by default to keep destructive +
           low-frequency actions out of the primary edit flow.
           Native <details> handles toggle; `open` is client-owned, or the
           re-render a select change causes would fold the section shut. --%>
      <details
        :if={@action == :edit}
        id="category-move-section"
        phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["open"])}
        class="card bg-base-100 shadow-lg"
      >
        <summary class="card-body py-3 cursor-pointer flex-row items-center gap-2 select-none">
          <.icon name="hero-arrows-right-left" class="w-4 h-4 text-base-content/60" />
          <h3 class="font-semibold text-base">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move")}</h3>
          <.icon name="hero-chevron-down" class="w-4 h-4 ml-auto text-base-content/40" />
        </summary>

        <div class="card-body pt-0 space-y-6">
          <%!-- Move to a different parent — within the same catalogue --%>
          <div class="flex flex-col gap-3">
            <div>
              <p class="font-medium text-sm">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move to another parent")}</p>
              <p class="text-xs text-base-content/60">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Reparent this category within its catalogue. Its subtree comes along.")}</p>
            </div>
            <div class="flex items-end gap-3">
              <form
                id="category-parent-move-form"
                phx-change="select_parent_move_target"
                class="flex-1"
              >
                <.select
                  name="parent_uuid"
                  id="category-parent-move-target"
                  value={@parent_move_target}
                  prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "— Top level (no parent) —")}
                  options={@parent_options}
                  class="select-sm transition-colors focus-within:select-primary"
                />
              </form>
              <.button
                type="button"
                phx-click="move_under_parent"
                phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Moving…")}
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
              <p class="font-medium text-sm">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move to another catalogue")}</p>
              <p class="text-xs text-base-content/60">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move this category and all its items to a different catalogue — at its top level or under one of its categories.")}</p>
            </div>
            <div class="flex items-end gap-3">
              <form id="category-move-form" phx-change="select_move_target" class="flex-1">
                <.select
                  name="move_target"
                  id="category-move-target"
                  value={@move_target}
                  prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "— Select destination —")}
                  options={@other_catalogues}
                  class="select-sm transition-colors focus-within:select-primary"
                />
              </form>
              <.button
                type="button"
                phx-click="move_category"
                phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Moving…")}
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
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
