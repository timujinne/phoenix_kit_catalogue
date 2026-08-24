defmodule PhoenixKitCatalogue.Web.AttributeGroupFormLive do
  @moduledoc """
  Create/edit form for attribute groups, with the inline attribute/value
  editor on :edit.

  The editor is deliberately event-driven, not one nested changeset form
  (panel finding): the group's NAME saves through a small form like every
  other resource, while attributes and values persist immediately per
  action — add, rename-on-blur, kind change, default star, drag reorder,
  delete. Each mutation is atomic in the context, so there is no staged
  tree to lose, and the DOM stays flat no matter how many values a group
  holds.

  One page-level language switch drives everything: with a secondary
  language active, the same inputs read/write that language's overrides
  (blank clears the override), with the primary text as placeholder.
  """

  use Phoenix.LiveView

  require Logger

  import PhoenixKitWeb.Components.MultilangForm
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Modal, only: [confirm_modal: 1]
  import PhoenixKitWeb.Components.Core.Button, only: [button: 1]
  import PhoenixKitWeb.Components.Core.Select, only: [select: 1]

  import PhoenixKitCatalogue.Web.Helpers,
    only: [
      actor_opts: 1,
      actor_uuid: 1,
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

  import PhoenixKitAI.Components.AITranslate,
    only: [ai_multilang_tabs: 1, ai_translate_modal: 1]

  alias Phoenix.LiveView.JS
  alias PhoenixKit.Utils.Multilang
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitAI.Translations
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.PubSub
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Schemas.AttributeGroup

  @translatable_fields ["name"]

  # The primary-language NAME must survive a validate/save fired from a
  # secondary language tab: there the form submits only `lang_name`, and
  # rebuilding the changeset from the pristine struct would drop the
  # name typed earlier — on :new that loses it entirely ("name it in all
  # languages right away" bug, 2026-08-16 user report).
  @preserve_fields %{"name" => :name}

  on_mount({__MODULE__, :self_wrapped_layout})

  def on_mount(:self_wrapped_layout, _params, _session, socket) do
    {:cont, put_in(socket.private[:live_layout], {PhoenixKitWeb.Layouts, :app})}
  end

  @impl true
  def mount(params, _session, socket) do
    # Subscribe before the group is read so a write landing in between
    # (a "Translate all" job, a colleague's edit) isn't missed.
    if connected?(socket), do: PubSub.subscribe()

    if Catalogue.attribute_sets_enabled?() do
      # Groups are retired once sets are live — legacy data auto-migrates
      # and this editor (multiple attributes per group) is the wrong
      # mental model. Old bookmarks land on the sets listing instead.
      {:ok,
       socket
       |> put_flash(
         :info,
         Gettext.gettext(
           PhoenixKitCatalogue.Gettext,
           "Attribute groups have been replaced by sets — your groups were migrated automatically."
         )
       )
       |> push_navigate(to: Paths.attribute_groups())}
    else
      mount_legacy(params, socket)
    end
  end

  defp mount_legacy(params, socket) do
    action = socket.assigns.live_action

    group =
      case action do
        :new -> %AttributeGroup{}
        :edit -> Catalogue.get_attribute_group_full(params["uuid"])
      end

    if is_nil(group) do
      {:ok,
       socket
       |> put_flash(
         :error,
         Gettext.gettext(PhoenixKitCatalogue.Gettext, "Attribute group not found.")
       )
       |> push_navigate(to: Paths.attribute_groups())}
    else
      {:ok,
       socket
       |> assign(
         page_title:
           if(action == :new,
             do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "New Attribute Group"),
             else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit %{name}", name: group.name)
           ),
         action: action,
         group: group,
         confirm_delete_attribute: nil,
         draft_generation: %{},
         refocus_key: nil,
         return_to: safe_return_to(params["return_to"])
       )
       |> assign_changeset(Catalogue.change_attribute_group(group))
       |> mount_multilang()
       |> assign_ai_translation(
         "catalogue_attribute_group",
         if(action == :edit, do: group, else: nil)
       )}
    end
  end

  defp safe_return_to(rt) when is_binary(rt) do
    if Routes.local_path?(rt), do: rt
  end

  defp safe_return_to(_), do: nil

  defp assign_changeset(socket, changeset) do
    socket
    |> assign(:changeset, changeset)
    |> assign(:form, to_form(changeset))
  end

  # ── Group name form ────────────────────────────────────────────────

  @impl true
  def handle_event("validate", %{"attribute_group" => params}, socket) do
    params =
      merge_translatable_params(params, socket, @translatable_fields,
        changeset: socket.assigns.changeset,
        preserve_fields: @preserve_fields
      )

    changeset =
      socket.assigns.group
      |> Catalogue.change_attribute_group(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_changeset(socket, changeset)}
  end

  def handle_event("save", params, socket) do
    group_params =
      params
      |> Map.get("attribute_group", %{})
      |> merge_translatable_params(socket, @translatable_fields,
        changeset: socket.assigns.changeset,
        preserve_fields: @preserve_fields
      )

    save_group(socket, socket.assigns.action, group_params, save_mode(params))
  end

  # ── Attributes ─────────────────────────────────────────────────────

  def handle_event("add_attribute", %{"attr_name" => name} = params, socket) do
    name = String.trim(name)

    if name == "" do
      {:noreply, socket}
    else
      attrs = %{"name" => name, "kind" => Map.get(params, "attr_kind", "multi")}

      case Catalogue.create_attribute(socket.assigns.group, attrs, actor_opts(socket)) do
        {:ok, _} ->
          {:noreply, socket |> clear_draft("attr") |> reload_group()}

        {:error, _changeset} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to add attribute.")
           )}
      end
    end
  end

  def handle_event("rename_attribute", %{"uuid" => uuid, "value" => raw}, socket) do
    case owned_attribute(socket, uuid) do
      %{} = attribute ->
        apply_rename(
          socket,
          attribute,
          raw,
          "_name",
          &Catalogue.update_attribute/2,
          %{"name" => String.trim(raw)}
        )

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("set_attribute_kind", %{"uuid" => uuid, "kind" => kind}, socket)
      when kind in ["fixed", "multi"] do
    with %{} = attribute <- owned_attribute(socket, uuid),
         {:ok, _} <- Catalogue.update_attribute(attribute, %{"kind" => kind}) do
      {:noreply, reload_group(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("set_attribute_kind", _params, socket), do: {:noreply, socket}

  def handle_event("request_delete_attribute", %{"uuid" => uuid}, socket) do
    {:noreply, assign(socket, :confirm_delete_attribute, uuid)}
  end

  def handle_event("cancel_delete_attribute", _params, socket) do
    {:noreply, assign(socket, :confirm_delete_attribute, nil)}
  end

  def handle_event("confirm_delete_attribute", _params, socket) do
    with uuid when is_binary(uuid) <- socket.assigns.confirm_delete_attribute,
         %{} = attribute <- owned_attribute(socket, uuid),
         {:ok, _} <- Catalogue.delete_attribute(attribute, actor_opts(socket)) do
      {:noreply, socket |> assign(:confirm_delete_attribute, nil) |> reload_group()}
    else
      _ ->
        {:noreply, assign(socket, :confirm_delete_attribute, nil)}
    end
  end

  def handle_event("reorder_attributes", %{"ordered_ids" => ids}, socket) when is_list(ids) do
    :ok = Catalogue.reorder_attributes(socket.assigns.group, Enum.filter(ids, &is_binary/1))
    {:noreply, reload_group(socket)}
  end

  def handle_event("reorder_attributes", _params, socket), do: {:noreply, socket}

  # ── Values ─────────────────────────────────────────────────────────

  def handle_event("add_value", %{"attribute_uuid" => uuid, "value" => raw}, socket) do
    text = String.trim(raw)

    with true <- text != "",
         %{} = attribute <- owned_attribute(socket, uuid),
         {:ok, _} <- Catalogue.create_attribute_value(attribute, %{"value" => text}) do
      {:noreply, socket |> clear_draft(attribute.uuid) |> reload_group()}
    else
      false ->
        {:noreply, socket}

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to add value.")
         )}
    end
  end

  def handle_event("rename_value", %{"uuid" => uuid, "value" => raw}, socket) do
    case owned_value(socket, uuid) do
      %{} = value ->
        apply_rename(
          socket,
          value,
          raw,
          "_value",
          &Catalogue.update_attribute_value/2,
          %{"value" => String.trim(raw)}
        )

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_value", %{"uuid" => uuid}, socket) do
    with %{} = value <- owned_value(socket, uuid),
         {:ok, _} <- Catalogue.delete_attribute_value(value) do
      {:noreply, reload_group(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("make_default", %{"uuid" => uuid}, socket) do
    with %{} = value <- owned_value(socket, uuid),
         {:ok, _} <- Catalogue.set_default_value(value) do
      {:noreply, reload_group(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("reorder_values", %{"ordered_ids" => ids, "attributeUuid" => uuid}, socket)
      when is_list(ids) do
    case owned_attribute(socket, uuid) do
      %{} = attribute ->
        :ok = Catalogue.reorder_attribute_values(attribute, Enum.filter(ids, &is_binary/1))
        {:noreply, reload_group(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("reorder_values", _params, socket), do: {:noreply, socket}

  # ── AI translate (modal events, handled here instead of the Embed) ─
  #
  # One entry point: the standard AI row + modal. The Embed would bind the
  # Translate action to the group name only, so this LV owns the six modal
  # events itself and fans the dispatch out — group name through the
  # standard machinery, every attribute name and value text as background
  # jobs for the same scope.

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

  def handle_event("ai_translate_lang", %{"lang" => lang}, socket) do
    socket = dispatch_ai_translate(socket, lang)
    {:noreply, maybe_enqueue_children(socket, lang)}
  end

  # "switch_language" is handled by the core `mount_multilang/1` auto hook.
  # The ai_* modal events are handled by the AITranslate.Embed hook.

  @impl true
  def handle_info({:ai_translation, event, payload}, socket) do
    {:noreply, handle_ai_translation_event(socket, event, payload, &resync_changeset/2)}
  end

  # Another process changed THIS group: a colleague's edit, or one of the
  # child-translation jobs queued by "Translate all" landing
  # (`AITranslatable.put_translation/4` announces the owning group).
  # Re-read the attributes/values; the name form is owned by the
  # `:ai_translation` handler above and by the user's own typing.
  def handle_info(
        {:catalogue_data_changed, :attribute_group, uuid, _parent},
        %{assigns: %{action: :edit, group: %{uuid: uuid}}} = socket
      ) do
    {:noreply, reload_group(socket)}
  end

  # Catch-all so stray PubSub traffic can't crash the editor mid-session.
  def handle_info(msg, socket) do
    Logger.debug("AttributeGroupFormLive ignored unhandled message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # ── Save / helpers ─────────────────────────────────────────────────

  # The clicked submit button ships its name/value with the form params.
  defp save_mode(%{"save_action" => "stay"}), do: :stay
  defp save_mode(_params), do: :exit

  # Accepts either the socket (handlers) or bare assigns (render).
  defp exit_target(%Phoenix.LiveView.Socket{} = socket), do: exit_target(socket.assigns)
  defp exit_target(assigns), do: assigns[:return_to] || Paths.attribute_groups()

  defp save_group(socket, :new, params, mode) do
    case Catalogue.create_attribute_group(params, actor_opts(socket)) do
      {:ok, group} ->
        target =
          case mode do
            # Stay lands on the created group's edit form — that's where
            # attributes get added, so it's the natural next step.
            :stay -> Paths.attribute_group_edit(group.uuid)
            :exit -> exit_target(socket)
          end

        {:noreply,
         socket
         |> put_flash(
           :info,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Attribute group created.")
         )
         |> push_navigate(to: target)}

      {:error, changeset} ->
        {:noreply, assign_changeset(socket, changeset)}
    end
  end

  defp save_group(socket, :edit, params, mode) do
    case Catalogue.update_attribute_group(socket.assigns.group, params, actor_opts(socket)) do
      {:ok, _} ->
        socket =
          put_flash(
            socket,
            :info,
            Gettext.gettext(PhoenixKitCatalogue.Gettext, "Attribute group updated.")
          )

        case mode do
          :stay -> {:noreply, reload_group(socket, rebuild_changeset: true)}
          :exit -> {:noreply, push_navigate(socket, to: exit_target(socket))}
        end

      {:error, changeset} ->
        {:noreply, assign_changeset(socket, changeset)}
    end
  end

  # Fan the modal's Translate action out to the children. Scope follows
  # the modal exactly: "*" fills only missing languages per child, "**"
  # re-translates all non-primary, a concrete code targets that language.
  # Skips silently when the dispatch already flashed an endpoint/prompt
  # error, or on :new (no children yet).
  defp maybe_enqueue_children(socket, scope) do
    endpoint = socket.assigns[:ai_selected_endpoint] || Translations.default_endpoint_uuid()
    prompt = socket.assigns[:ai_selected_prompt] || Translations.default_prompt_uuid()
    all_targets = for tab <- socket.assigns.language_tabs, not tab.is_primary, do: tab.code

    cond do
      socket.assigns.action != :edit -> socket
      endpoint in [nil, ""] or prompt in [nil, ""] -> socket
      scope in [nil, "", socket.assigns.primary_language] -> socket
      true -> enqueue_children(socket, scope, all_targets, endpoint, prompt)
    end
  end

  defp enqueue_children(socket, scope, all_targets, endpoint, prompt) do
    group = socket.assigns.group
    actor = actor_uuid(socket)

    children =
      Enum.flat_map(group.attributes, fn attribute ->
        [
          {"catalogue_attribute", attribute}
          | Enum.map(attribute.values, &{"catalogue_attribute_value", &1})
        ]
      end)

    # The jobs land in the background; each write announces the group on
    # the catalogue topic and the `:catalogue_data_changed` clause pulls
    # the results in as they arrive.
    Enum.each(children, fn {type, record} ->
      targets =
        case scope do
          "*" -> all_targets -- translated_langs(record.data)
          "**" -> all_targets
          lang -> Enum.filter(all_targets, &(&1 == lang))
        end

      enqueue_child(type, record, targets, endpoint, prompt, actor)
    end)

    socket
  end

  # Applies the group's own translation results to the name form.
  defp resync_changeset(socket, changeset), do: assign_changeset(socket, changeset)

  defp enqueue_child(_type, _record, [], _endpoint, _prompt, _actor), do: 0

  defp enqueue_child(type, record, targets, endpoint, prompt, actor) do
    base = %{
      resource_type: type,
      resource_uuid: record.uuid,
      endpoint_uuid: endpoint,
      prompt_uuid: prompt,
      source_lang: Multilang.primary_language(),
      actor_uuid: actor
    }

    case Translations.enqueue_all_missing(base, targets) do
      {:ok, %{enqueued: n}} -> n
      _ -> 0
    end
  end

  # A language counts as translated when its subtree holds at least one
  # non-empty "_"-prefixed override (the multilang key shape).
  defp translated_langs(data) do
    (data || %{})
    |> Map.drop(["_primary_language"])
    |> Enum.filter(fn
      {k, v} when is_binary(k) and is_map(v) ->
        Enum.any?(v, fn
          {fk, fv} when is_binary(fk) and is_binary(fv) ->
            String.starts_with?(fk, "_") and String.trim(fv) != ""

          _ ->
            false
        end)

      _ ->
        false
    end)
    |> Enum.map(&elem(&1, 0))
  end

  # The add-attribute / add-value inputs are UNCONTROLLED (no server
  # value), so unrelated re-renders never wipe a draft someone is still
  # typing in another row. Clearing the one form that DID submit works by
  # bumping its generation — the input's id changes, morphdom mounts a
  # fresh empty node, and phx-mounted refocuses it for rapid entry.
  defp clear_draft(socket, key) do
    socket
    |> assign(
      :draft_generation,
      Map.update(socket.assigns.draft_generation, key, 1, &(&1 + 1))
    )
    |> assign(:refocus_key, key)
  end

  defp draft_gen(draft_generation, key), do: Map.get(draft_generation, key, 0)

  # Every re-read goes through here, so a group deleted in another session
  # between two reads (the delete broadcast, then any event that reloads)
  # bounces to the list instead of dereferencing nil.
  defp reload_group(socket, opts \\ []) do
    case Catalogue.get_attribute_group_full(socket.assigns.group.uuid) do
      nil -> group_gone(socket)
      group -> assign_reloaded_group(socket, group, opts)
    end
  end

  defp group_gone(socket) do
    socket
    |> put_flash(
      :error,
      Gettext.gettext(PhoenixKitCatalogue.Gettext, "Attribute group not found.")
    )
    |> push_navigate(to: safe_return_to(socket.assigns.return_to) || Paths.attribute_groups())
  end

  defp assign_reloaded_group(socket, group, opts) do
    socket =
      socket
      |> assign(:group, group)
      |> assign(
        :page_title,
        Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit %{name}", name: group.name)
      )

    if opts[:rebuild_changeset] do
      assign_changeset(socket, Catalogue.change_attribute_group(group))
    else
      socket
    end
  end

  # Events carry client-forgeable uuids — resolve them only within the
  # group this editor owns.
  defp owned_attribute(socket, uuid) when is_binary(uuid) do
    Enum.find(socket.assigns.group.attributes || [], &(&1.uuid == uuid))
  end

  defp owned_attribute(_socket, _), do: nil

  defp owned_value(socket, uuid) when is_binary(uuid) do
    (socket.assigns.group.attributes || [])
    |> Enum.flat_map(&(&1.values || []))
    |> Enum.find(&(&1.uuid == uuid))
  end

  defp owned_value(_socket, _), do: nil

  # Rename in the ACTIVE language: primary writes the schema column
  # (blank ignored — identity text can't be emptied); a secondary
  # language writes/clears that language's override.
  defp apply_rename(socket, record, raw, data_field, update_fn, primary_attrs) do
    text = String.trim(raw)
    primary? = socket.assigns.current_lang == socket.assigns.primary_language

    result =
      cond do
        primary? and text == "" ->
          :noop

        primary? ->
          update_fn.(record, primary_attrs)

        text == "" ->
          Catalogue.set_translation(record, socket.assigns.current_lang, %{}, update_fn)

        true ->
          Catalogue.set_translation(
            record,
            socket.assigns.current_lang,
            %{data_field => text},
            update_fn
          )
      end

    case result do
      :noop -> {:noreply, reload_group(socket)}
      {:ok, _} -> {:noreply, reload_group(socket)}
      {:error, _} -> {:noreply, reload_group(socket)}
    end
  end

  # Text shown in an editor input for the active language: the schema
  # column for the primary, the RAW override (not the merged fallback)
  # for secondaries — an empty input with the primary as placeholder is
  # how the admin sees "not translated yet".
  defp lang_text(record, column, socket_assigns) do
    if socket_assigns.current_lang == socket_assigns.primary_language do
      Map.get(record, column)
    else
      raw = Multilang.get_raw_language_data(record.data || %{}, socket_assigns.current_lang)
      raw["_" <> to_string(column)] || ""
    end
  end

  defp kind_options do
    [
      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Multiple values"), "multi"},
      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Fixed value"), "fixed"}
    ]
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
      page_section={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Attributes")}
      page_section_path={Paths.attribute_groups()}
      page_subtitle={if @action == :new, do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Define a reusable set of options — colors, trims, surfaces — that items can inherit."), else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Manage this group's attributes, values, and translations.")}
      current_path={assigns[:url_path] || Paths.attribute_groups()}
      current_locale={assigns[:current_locale]}
    >
      <div class="flex flex-col mx-auto max-w-3xl px-4 py-8 gap-6">
        <%!-- ONE card: language tabs + AI row on top, then the name form
             and the attributes editor as connected sections. The multilang
             wrapper spans BOTH sections, so a language switch skeletons
             and re-mounts the whole editor together (name, attribute
             names, value chips) — one region, one loading state. The
             <.form> holds only the name; the attribute editor's
             mini-forms are its siblings inside the wrapper, and the
             page-bottom Save buttons reach the form via form=. --%>
        <div class="card bg-base-100 shadow-lg">
          <.ai_multilang_tabs
            multilang_enabled={@multilang_enabled}
            language_tabs={@language_tabs}
            current_lang={@current_lang}
            ai_translate={ai_translate_config(assigns)}
          />

          <.multilang_fields_wrapper multilang_enabled={@multilang_enabled} current_lang={@current_lang} skeleton_class="card-body flex flex-col gap-6">
            <:skeleton>
              <div class="space-y-2">
                <div class="bg-base-content/15 rounded h-4 w-20 animate-pulse"></div>
                <div class="bg-base-content/15 rounded h-12 w-full animate-pulse"></div>
              </div>
              <div :if={@action == :edit} class="space-y-3">
                <div class="bg-base-content/15 rounded h-4 w-28 animate-pulse"></div>
                <div class="bg-base-content/15 rounded-lg h-20 w-full animate-pulse"></div>
                <div class="bg-base-content/15 rounded-lg h-20 w-full animate-pulse"></div>
              </div>
            </:skeleton>

            <.form id="attribute-group-form" for={@form} action="#" phx-change="validate" phx-submit="save">
              <div class={["card-body flex flex-col gap-5", @action == :edit && "pb-0"]}>
                <.translatable_field
                  field_name="name" form_prefix="attribute_group" changeset={@changeset}
                  schema_field={:name} multilang_enabled={@multilang_enabled}
                  current_lang={@current_lang} primary_language={@primary_language}
                  lang_data={@lang_data} label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Name")}
                  placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "e.g., Idea doors")}
                  required class="w-full"
                />
              </div>
            </.form>

            <%!-- Attributes — :edit only (the group must exist first).
                 Discrete events, immediate persistence; no nested form.
                 Inputs follow @current_lang: a secondary language edits
                 that language's overrides (primary text as placeholder). --%>
            <div :if={@action == :edit} class="card-body flex flex-col gap-4 pt-4">
              <div class="divider my-0"></div>

              <div class="flex items-center gap-2">
                <.icon name="hero-swatch" class="w-5 h-5 text-base-content/60" />
                <h3 class="font-semibold text-base">
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Attributes")}
                </h3>
              </div>

              <p :if={@group.attributes == []} class="text-sm text-base-content/60">
                {Gettext.gettext(
                  PhoenixKitCatalogue.Gettext,
                  "No attributes yet. Add one below — e.g. Color, Trim, Surface."
                )}
              </p>

              <div
                :if={@group.attributes != []}
                id="attribute-rows"
                phx-hook="SortableGrid"
                data-sortable="true"
                data-sortable-event="reorder_attributes"
                data-sortable-items=".sortable-item"
                data-sortable-handle=".pk-drag-handle"
                class="flex flex-col gap-3"
              >
                <%!-- The inline per-row editors below stay on RAW inputs/
                     selects deliberately (L029 triage, AI-panel reviewed):
                     the kit primitives wrap every field in a feedback div,
                     which breaks these compact flex rows, and the rows are
                     draft-map single-field forms with no changeset to wire
                     feedback to. Labeled, changeset/draft-backed fields
                     elsewhere in this module DO use the kit. --%>
                <div
                  :for={attribute <- @group.attributes}
                  class="sortable-item rounded-lg border border-base-content/10 bg-base-content/5 p-3 flex flex-col gap-3"
                  data-id={attribute.uuid}
                >
                  <div class="flex items-center gap-2">
                    <span class="pk-drag-handle cursor-grab inline-flex items-center text-base-content/40 hover:text-base-content/70">
                      <.icon name="hero-bars-3" class="w-4 h-4" />
                    </span>
                    <input
                      id={"attr-name-#{attribute.uuid}-#{@current_lang}"}
                      type="text"
                      value={lang_text(attribute, :name, assigns)}
                      placeholder={attribute.name}
                      phx-blur="rename_attribute"
                      phx-value-uuid={attribute.uuid}
                      class="input input-sm input-bordered bg-base-100 font-medium flex-1 min-w-0"
                    />
                    <form id={"attr-kind-form-#{attribute.uuid}"} phx-change="set_attribute_kind" class="contents">
                      <input type="hidden" name="uuid" value={attribute.uuid} />
                      <%!-- Width lives on this wrapper, NOT on `<.select>`'s
                           class: the component hardcodes `w-full` on its own
                           label, which wins the Tailwind cascade over a
                           narrower utility passed in via `class` (both are
                           single-class selectors — whichever the compiled
                           stylesheet emits later wins, and `w-full` sorts
                           after `w-36`). Constraining the wrapper instead
                           lets `w-full` just fill it. --%>
                      <div class="w-36 shrink-0">
                        <.select
                          name="kind"
                          value={attribute.kind}
                          options={kind_options()}
                          class="select-sm bg-base-100 phx-change-loading:opacity-50 phx-change-loading:animate-pulse"
                        />
                      </div>
                    </form>
                    <.button
                      type="button"
                      phx-click="request_delete_attribute"
                      phx-value-uuid={attribute.uuid}
                      variant="ghost"
                      size="xs"
                      class="text-error shrink-0"
                      title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete attribute")}
                    >
                      <.icon name="hero-trash" class="w-4 h-4 phx-click-loading:hidden" />
                      <span class="loading loading-spinner w-4 h-4 hidden phx-click-loading:inline-block"></span>
                    </.button>
                  </div>

                  <%!-- Values: draggable chips; star = default. --%>
                  <div
                    id={"value-chips-#{attribute.uuid}"}
                    phx-hook="SortableGrid"
                    data-sortable="true"
                    data-sortable-event="reorder_values"
                    data-sortable-items=".sortable-item"
                    data-sortable-handle=".pk-value-handle"
                    data-sortable-scope-attribute-uuid={attribute.uuid}
                    class="flex flex-wrap items-center gap-2 pl-6"
                  >
                    <div
                      :for={value <- attribute.values}
                      class="sortable-item flex items-center gap-1 rounded-full border border-base-content/20 bg-base-100 pl-1 pr-1 py-0.5 shadow-sm"
                      data-id={value.uuid}
                    >
                      <span class="pk-value-handle cursor-grab inline-flex items-center text-base-content/30 hover:text-base-content/60">
                        <.icon name="hero-bars-2" class="w-3 h-3" />
                      </span>
                      <input
                        id={"value-text-#{value.uuid}-#{@current_lang}"}
                        type="text"
                        value={lang_text(value, :value, assigns)}
                        placeholder={value.value}
                        phx-blur="rename_value"
                        phx-value-uuid={value.uuid}
                        size={max(String.length(lang_text(value, :value, assigns) || value.value), 4)}
                        class="input input-xs bg-transparent border-0 focus:outline-none px-1 field-sizing-content min-w-10 max-w-56"
                      />
                      <.button
                        type="button"
                        phx-click="make_default"
                        phx-value-uuid={value.uuid}
                        variant="ghost"
                        size="xs"
                        class={["px-1", value.is_default && "text-warning"]}
                        title={
                          if value.is_default,
                            do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Default value"),
                            else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Make default")
                        }
                      >
                        <.icon
                          name={if value.is_default, do: "hero-star-solid", else: "hero-star"}
                          class="w-3.5 h-3.5 phx-click-loading:hidden"
                        />
                        <span class="loading loading-spinner w-3.5 h-3.5 hidden phx-click-loading:inline-block"></span>
                      </.button>
                      <.button
                        type="button"
                        phx-click="delete_value"
                        phx-value-uuid={value.uuid}
                        variant="ghost"
                        size="xs"
                        class="px-1 text-base-content/40 hover:text-error"
                        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Remove value")}
                      >
                        <.icon name="hero-x-mark" class="w-3.5 h-3.5 phx-click-loading:hidden" />
                        <span class="loading loading-spinner w-3.5 h-3.5 hidden phx-click-loading:inline-block"></span>
                      </.button>
                    </div>

                    <%!-- phx-update="ignore": unrelated patches must never
                         touch someone's in-progress draft (LiveView re-syncs
                         input values on every node patch). Clearing after a
                         successful add replaces the WHOLE form via the
                         generation-bumped id, which mounts fresh and
                         refocuses. --%>
                    <form
                      id={"add-value-form-#{attribute.uuid}-g#{draft_gen(@draft_generation, attribute.uuid)}"}
                      phx-submit="add_value"
                      phx-update="ignore"
                      class="flex items-center gap-1"
                    >
                      <input type="hidden" name="attribute_uuid" value={attribute.uuid} />
                      <input
                        id={"add-value-input-#{attribute.uuid}-g#{draft_gen(@draft_generation, attribute.uuid)}"}
                        type="text"
                        name="value"
                        placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Add value...")}
                        class="input input-xs input-bordered bg-base-100 w-28"
                        phx-mounted={@refocus_key == attribute.uuid && JS.focus()}
                      />
                      <.button
                        type="submit"
                        variant="outline"
                        size="xs"
                        class="btn-square shrink-0"
                        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Add value")}
                        aria-label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Add value")}
                      >
                        <%!-- literal spans, NOT <.icon>: component subtrees
                             inside this phx-update="ignore" form arrive as
                             data-phx-skip stubs when the id-bump replaces
                             it, leaving an empty button. --%>
                        <span class="hero-plus w-3.5 h-3.5 phx-submit-loading:hidden"></span>
                        <span class="loading loading-spinner w-3.5 h-3.5 hidden phx-submit-loading:inline-block"></span>
                      </.button>
                    </form>
                  </div>
                </div>
              </div>

              <%!-- Add attribute — its own form so Enter adds. --%>
              <form
                id={"add-attribute-form-g#{draft_gen(@draft_generation, "attr")}"}
                phx-submit="add_attribute"
                phx-update="ignore"
                class="flex items-center gap-2 pt-1"
              >
                <input
                  id={"add-attribute-input-g#{draft_gen(@draft_generation, "attr")}"}
                  type="text"
                  name="attr_name"
                  placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "New attribute name...")}
                  class="input input-sm input-bordered flex-1 min-w-0"
                  phx-mounted={@refocus_key == "attr" && JS.focus()}
                />
                <%!-- Width on the wrapper, not `<.select>`'s class — see the
                     same note at the attr-kind mini-form above. `<.select>`
                     requires a `value` (unlike the raw `<select>` this
                     replaces, which had no `selected` and fell back to the
                     browser's first-option default) — derived from
                     `kind_options()` itself rather than hardcoded, so it
                     can't drift if the list's order ever changes. --%>
                <div class="w-36 shrink-0">
                  <.select
                    name="attr_kind"
                    value={kind_options() |> List.first() |> elem(1)}
                    options={kind_options()}
                    class="select-sm"
                  />
                </div>
                <.button type="submit" variant="outline" size="sm" class="shrink-0">
                  <%!-- literal spans — see the add-value button. --%>
                  <span class="hero-plus w-4 h-4 phx-submit-loading:hidden"></span>
                  <span class="loading loading-spinner w-4 h-4 hidden phx-submit-loading:inline-block"></span>
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Add")}
                </.button>
              </form>
            </div>
          </.multilang_fields_wrapper>
        </div>

        <%!-- Bottom action bar — outside the card, wired back via form=.
             "Save" stays; "Save & Exit" returns to the groups list. --%>
        <div class="flex justify-end gap-3">
          <.button navigate={exit_target(assigns)} variant="ghost">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Cancel")}
          </.button>
          <%!-- "Save" keeps `class="btn-outline"` — a style modifier that
               composes with the component's default btn-primary, where
               `variant="outline"` would replace the colour (same trap
               documented in category_form_live.ex). --%>
          <.button
            form="attribute-group-form"
            type="submit"
            name="save_action"
            value="stay"
            class="btn-outline"
            phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Saving...")}
          >
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Save")}
          </.button>
          <.button
            form="attribute-group-form"
            type="submit"
            name="save_action"
            value="exit"
            phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Saving...")}
          >
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Save & Exit")}
          </.button>
        </div>

        <%!-- AI translate modal — outside the form (its selectors are
             their own <form>; nested forms are invalid). --%>
        <.ai_translate_modal ai_translate={ai_translate_config(assigns)} />

        <.confirm_modal
          show={@confirm_delete_attribute != nil}
          on_confirm="confirm_delete_attribute"
          on_cancel="cancel_delete_attribute"
          title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete attribute")}
          title_icon="hero-trash"
          messages={[{:warning, Gettext.gettext(PhoenixKitCatalogue.Gettext, "This removes the attribute and all its values from the group.")}]}
          confirm_text={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")}
          danger={true}
        />
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
