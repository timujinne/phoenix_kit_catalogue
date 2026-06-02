defmodule PhoenixKitCatalogue.Web.ItemFormLive do
  @moduledoc "Create/edit form for catalogue items with multilang support."

  use Phoenix.LiveView

  require Logger

  import PhoenixKitWeb.Components.MultilangForm
  import PhoenixKitWeb.Components.Core.AdminPageHeader, only: [admin_page_header: 1]
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Input, only: [input: 1]
  import PhoenixKitWeb.Components.Core.Select, only: [select: 1]

  import PhoenixKitCatalogue.Web.Components,
    only: [catalogue_rules_picker: 1, featured_image_card: 1, metadata_editor: 1]

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

  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitCatalogue.Attachments
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.Helpers
  alias PhoenixKitCatalogue.Metadata
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Schemas.Item

  @translatable_fields ["name", "description"]
  @preserve_fields %{
    "sku" => :sku,
    "base_price" => :base_price,
    "markup_percentage" => :markup_percentage,
    "discount_percentage" => :discount_percentage,
    "default_value" => :default_value,
    "default_unit" => :default_unit,
    "unit" => :unit,
    "status" => :status,
    "category_uuid" => :category_uuid,
    "manufacturer_uuid" => :manufacturer_uuid
  }

  @impl true
  def mount(params, _session, socket) do
    action = socket.assigns.live_action

    case load_item(action, params) do
      {nil, _, _} ->
        {:ok,
         socket
         |> put_flash(:error, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Item not found."))
         |> push_navigate(to: Paths.index())}

      {item, changeset, catalogue_uuid} ->
        {:ok, mount_form(socket, action, item, changeset, catalogue_uuid)}
    end
  end

  defp load_item(:new, params) do
    catalogue_uuid = params["catalogue_uuid"]
    item = %Item{catalogue_uuid: catalogue_uuid}
    {item, Catalogue.change_item(item), catalogue_uuid}
  end

  defp load_item(:edit, params) do
    case Catalogue.get_item(params["uuid"]) do
      nil ->
        Logger.warning("Item not found for edit: #{params["uuid"]}")
        {nil, nil, nil}

      item ->
        item =
          item
          |> PhoenixKit.RepoHelper.repo().preload([:category, :manufacturer])
          |> normalize_display_decimals()

        {item, Catalogue.change_item(item), item.catalogue_uuid}
    end
  end

  # DB-stored decimals keep the column's scale (e.g. DECIMAL(12, 4) gives
  # back `#Decimal<5.0000>` for what the user typed as `5`). Strip the
  # insignificant trailing zeros once at load time so the initial form
  # render shows `5`; user-typed values during validate are left alone.
  defp normalize_display_decimals(%Item{} = item) do
    %{item | default_value: normalize_decimal(item.default_value)}
  end

  defp normalize_decimal(nil), do: nil
  defp normalize_decimal(%Decimal{} = d), do: Decimal.normalize(d)
  defp normalize_decimal(other), do: other

  defp mount_form(socket, action, item, changeset, catalogue_uuid) do
    categories =
      if catalogue_uuid,
        do: Catalogue.list_categories_for_catalogue(catalogue_uuid),
        else: Catalogue.list_all_categories()

    all_categories = if action == :edit, do: Catalogue.list_all_categories(), else: []
    parent_catalogue = load_parent_catalogue(catalogue_uuid)
    kind = catalogue_kind(parent_catalogue)

    # Smart items move between smart catalogues (no category concept);
    # standard items use the existing "pick a category anywhere" flow.
    smart_move_targets =
      if action == :edit and kind == "smart" do
        Catalogue.list_catalogues(kind: :smart) |> Enum.reject(&(&1.uuid == catalogue_uuid))
      else
        []
      end

    socket
    |> assign(
      page_title:
        if(action == :new,
          do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "New Item"),
          else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit %{name}", name: item.name)
        ),
      action: action,
      item: item,
      catalogue_uuid: catalogue_uuid,
      catalogue_kind: kind,
      catalogue_markup: markup_from_catalogue(parent_catalogue),
      catalogue_discount: discount_from_catalogue(parent_catalogue),
      categories: categories,
      manufacturers: Catalogue.list_manufacturers(status: "active"),
      all_categories: all_categories,
      smart_move_targets: smart_move_targets,
      move_target: nil,
      current_tab: :details,
      meta_state: Metadata.build_state(:item, item),
      show_pdf_search: false
    )
    |> Attachments.mount_attachments(item)
    |> Attachments.allow_attachment_upload()
    |> assign_changeset(changeset)
    |> assign_rule_state(item, kind, catalogue_uuid)
    |> mount_multilang()
    |> adjust_multilang_for_item(item)
    |> assign_ai_translation("catalogue_item", if(action == :edit, do: item, else: nil))
  end

  # Keeps both :changeset (for <.translatable_field>) and :form (for
  # <.input>/<.select> bindings) in sync — validate and save-error paths
  # go through this helper so they can't drift apart.
  defp assign_changeset(socket, changeset) do
    socket
    |> assign(:changeset, changeset)
    |> assign(:form, to_form(changeset))
  end

  # Smart-catalogue picker state: only populated when the parent
  # catalogue is kind: "smart". For standard catalogues we still assign
  # empty defaults so the render path can reference the keys unconditionally.
  #
  # Note: this runs in `mount/3` and therefore fires twice per page
  # load (HTTP + WebSocket). Moving the data load to `handle_params/3`
  # is tracked as a separate follow-up; here we just make sure the
  # smart branch issues a *single* `list_catalogue_rules/1` query
  # instead of the two it used to (one for the working_rules map and a
  # second for the display order).
  defp assign_rule_state(socket, _item, "smart" = _kind, catalogue_uuid) do
    # Smart-chain guard: a smart catalogue cannot be the referenced
    # target of another smart item (issue #16). The changeset rejects
    # writes; filtering here keeps the picker honest so the user is
    # never offered an option that would fail on save.
    candidates =
      Catalogue.list_catalogues(kind: :standard)
      |> Enum.reject(&(&1.uuid == catalogue_uuid))

    rules =
      case socket.assigns.item do
        %Item{uuid: nil} -> []
        %Item{} = item -> Catalogue.list_catalogue_rules(item)
      end

    existing =
      Map.new(rules, fn rule ->
        to_working_entry({rule.referenced_catalogue_uuid, rule})
      end)

    # Initial display order: existing rules first (by their stored
    # position from `list_catalogue_rules/1`), then the remaining
    # candidates that haven't been turned into rules yet, in
    # catalogue.name order.
    rule_uuids = Enum.map(rules, & &1.referenced_catalogue_uuid)

    rest_uuids =
      candidates
      |> Enum.map(& &1.uuid)
      |> Enum.reject(&(&1 in rule_uuids))

    rule_order = rule_uuids ++ rest_uuids

    assign(socket,
      rule_candidates: candidates,
      working_rules: existing,
      rule_candidate_order: rule_order
    )
  end

  defp assign_rule_state(socket, _item, _kind, _catalogue_uuid) do
    assign(socket, rule_candidates: [], working_rules: %{}, rule_candidate_order: [])
  end

  # Reorders `candidates` to match `rule_candidate_order`. Candidates
  # not in the order list (e.g. catalogues added since mount) are
  # appended at the end. Candidates listed in the order but no longer
  # present are silently dropped.
  defp sort_candidates(candidates, order) when is_list(candidates) and is_list(order) do
    by_uuid = Map.new(candidates, &{&1.uuid, &1})

    ordered =
      order
      |> Enum.flat_map(fn uuid ->
        case Map.fetch(by_uuid, uuid) do
          {:ok, c} -> [c]
          :error -> []
        end
      end)

    leftovers = Enum.reject(candidates, fn c -> c.uuid in order end)

    ordered ++ leftovers
  end

  # Coerce nil units to "percent" on load. Persisted NULL units are a
  # legacy of the earlier "inherit from item.default_unit" behavior;
  # now that the picker no longer inherits, surfacing NULL as "percent"
  # keeps the dropdown honest (what you see is what will be saved).
  defp to_working_entry({uuid, %{value: value, unit: unit}}),
    do: {uuid, %{value: normalize_decimal(value), unit: unit || "percent"}}

  # If the item's embedded primary language differs from the global primary,
  # start on the item's language tab and flag that the global primary needs filling in.
  #
  # Always assigns `needs_primary_translation` and `item_primary_language`
  # — even when multilang is disabled — so the render path can reference
  # them unconditionally without crashing on a missing key.
  # Loads the parent catalogue once so the form can surface markup,
  # discount, kind, and (for smart catalogues) the candidate reference
  # list. Returns nil if the item isn't scoped to a catalogue yet, in
  # which case every derived field is nil and the render path omits
  # kind-specific sections.
  defp load_parent_catalogue(nil), do: nil
  defp load_parent_catalogue(catalogue_uuid), do: Catalogue.get_catalogue(catalogue_uuid)

  defp catalogue_kind(%{kind: kind}) when is_binary(kind), do: kind
  defp catalogue_kind(_), do: "standard"

  defp markup_from_catalogue(%{markup_percentage: markup}), do: markup
  defp markup_from_catalogue(_), do: nil

  defp discount_from_catalogue(%{discount_percentage: discount}), do: discount
  defp discount_from_catalogue(_), do: nil

  defp adjust_multilang_for_item(socket, item) do
    if socket.assigns.multilang_enabled do
      check_item_primary_language(socket, item)
    else
      assign(socket, needs_primary_translation: false, item_primary_language: nil)
    end
  end

  defp check_item_primary_language(socket, item) do
    item_data = item.data || %{}
    item_primary = item_data["_primary_language"]
    global_primary = socket.assigns.primary_language

    if item_primary && item_primary != global_primary do
      global_data = Multilang.get_language_data(item_data, global_primary)
      global_has_data = global_data["_name"] != nil and global_data["_name"] != ""

      assign(socket,
        current_lang: item_primary,
        needs_primary_translation: not global_has_data,
        item_primary_language: item_primary
      )
    else
      assign(socket,
        needs_primary_translation: false,
        item_primary_language: nil
      )
    end
  end

  @impl true
  def handle_event("switch_language", %{"lang" => lang_code}, socket) do
    {:noreply, handle_switch_language(socket, lang_code)}
  end

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

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :current_tab, parse_tab(tab))}
  end

  def handle_event("add_meta_field", %{"key" => key}, socket) do
    case Metadata.definition(:item, key) do
      nil ->
        # Unknown key arriving from a stale client — ignore rather than
        # inserting data the save path can't round-trip.
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

  # ── Attachments (featured image modal + inline files dropzone) ──
  # Delegated to `PhoenixKitCatalogue.Attachments`; shared with
  # `CatalogueFormLive` so both forms behave identically.

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

  def handle_event("open_pdf_search", _params, socket),
    do: {:noreply, assign(socket, :show_pdf_search, true)}

  def handle_event("validate", params, socket) do
    socket = absorb_meta_params(socket, params)
    item_params = Map.get(params, "item", %{})

    item_params =
      merge_translatable_params(item_params, socket, @translatable_fields,
        changeset: socket.assigns.changeset,
        preserve_fields: @preserve_fields
      )

    changeset =
      socket.assigns.item
      |> Catalogue.change_item(item_params)
      |> Map.put(:action, :validate)

    {:noreply, assign_changeset(socket, changeset)}
  end

  def handle_event("save", params, socket) do
    socket = absorb_meta_params(socket, params)
    item_params = Map.get(params, "item", %{})

    item_params =
      item_params
      |> merge_translatable_params(socket, @translatable_fields,
        changeset: socket.assigns.changeset,
        preserve_fields: @preserve_fields
      )
      |> Metadata.inject_into_data(socket.assigns.meta_state, :item)
      |> Attachments.inject_attachment_data(socket)

    save_item(socket, socket.assigns.action, item_params)
  end

  # ── Smart-catalogue rule picker events ──────────────────────────
  # All four events mutate `socket.assigns.working_rules`; actual
  # persistence happens during save via `put_catalogue_rules/3`.

  def handle_event("toggle_catalogue_rule", %{"uuid" => uuid}, socket) do
    rules = socket.assigns.working_rules

    working_rules =
      if Map.has_key?(rules, uuid) do
        Map.delete(rules, uuid)
      else
        # Unit is always explicit per rule — it does not inherit from the
        # item's default_unit. Value is left nil so it can still inherit
        # via the "Inherit: N" placeholder flow.
        Map.put(rules, uuid, %{value: nil, unit: "percent"})
      end

    {:noreply, assign(socket, :working_rules, working_rules)}
  end

  def handle_event("set_catalogue_rule_value", %{"uuid" => uuid, "value" => raw}, socket) do
    rules = socket.assigns.working_rules

    case Map.get(rules, uuid) do
      nil ->
        {:noreply, socket}

      entry ->
        new_value = parse_decimal_or_nil(raw)
        working_rules = Map.put(rules, uuid, %{entry | value: new_value})
        {:noreply, assign(socket, :working_rules, working_rules)}
    end
  end

  def handle_event("set_catalogue_rule_unit", %{"uuid" => uuid, "unit" => unit}, socket) do
    rules = socket.assigns.working_rules

    case Map.get(rules, uuid) do
      nil ->
        {:noreply, socket}

      entry ->
        new_unit = if unit in ["", nil], do: nil, else: unit
        working_rules = Map.put(rules, uuid, %{entry | unit: new_unit})
        {:noreply, assign(socket, :working_rules, working_rules)}
    end
  end

  def handle_event("clear_catalogue_rules", _params, socket) do
    {:noreply, assign(socket, :working_rules, %{})}
  end

  def handle_event("reorder_catalogue_rules", %{"ordered_ids" => ordered_ids}, socket)
      when is_list(ordered_ids) do
    # Build the new candidate order: incoming UUIDs first (deduped),
    # then any candidates the DOM didn't surface (defensive — keeps
    # rows from disappearing if the client only sent a partial list).
    # Use the shared `dedupe_keep_last/1` so a stale-DOM duplicate
    # surfaces the *latest* drop position, matching the catalogue /
    # category / item reorder paths.
    current = socket.assigns.rule_candidate_order
    incoming = Helpers.dedupe_keep_last(ordered_ids)
    rest = Enum.reject(current, &(&1 in incoming))
    {:noreply, assign(socket, :rule_candidate_order, incoming ++ rest)}
  end

  def handle_event("select_move_target", params, socket) do
    # Accept the UUID under either key depending on which select fired —
    # standard forms use `category_uuid`, smart forms use `catalogue_uuid`.
    uuid = params["category_uuid"] || params["catalogue_uuid"]
    target = if uuid in [nil, ""], do: nil, else: uuid
    {:noreply, assign(socket, :move_target, target)}
  end

  def handle_event("move_item", _params, socket) do
    target = socket.assigns.move_target

    if target do
      perform_move(socket, target)
    else
      {:noreply, socket}
    end
  end

  defp parse_tab("metadata"), do: :metadata
  defp parse_tab("files"), do: :files
  defp parse_tab(_), do: :details

  defp absorb_meta_params(socket, params) do
    assign(socket, :meta_state, Metadata.absorb_params(socket.assigns.meta_state, params))
  end

  # ── Attachments handle_info (delegated to Attachments module) ────

  @impl true
  def handle_info({:ai_translation, event, payload}, socket) do
    {:noreply, handle_ai_translation_event(socket, event, payload, &assign_changeset/2)}
  end

  def handle_info({:media_selected, file_uuids}, socket),
    do: Attachments.handle_media_selected(socket, file_uuids)

  def handle_info({:media_selector_closed}, socket),
    do: {:noreply, Attachments.close_media_selector(socket)}

  def handle_info({:pdf_search_modal_closed}, socket),
    do: {:noreply, assign(socket, :show_pdf_search, false)}

  # Catch-all so stray monitor signals or unrelated PubSub traffic
  # can't crash the form mid-edit.
  def handle_info(msg, socket) do
    Logger.debug("ItemFormLive ignored unhandled message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # Routes on the parent catalogue's kind: smart items move across
  # catalogues (categories don't apply), standard items move between
  # categories (the catalogue is derived from the target category).
  defp perform_move(socket, target) do
    result =
      case socket.assigns.catalogue_kind do
        "smart" ->
          Catalogue.move_item_to_catalogue(socket.assigns.item, target, actor_opts(socket))

        _ ->
          Catalogue.move_item_to_category(socket.assigns.item, target, actor_opts(socket))
      end

    case result do
      {:ok, item} ->
        {:noreply,
         socket
         |> put_flash(:info, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Item moved."))
         |> push_navigate(to: redirect_target(socket, item))}

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to move item.")
         )}
    end
  end

  # actor_opts/1 imported from PhoenixKitCatalogue.Web.Helpers

  defp save_item(socket, :new, params) do
    params = Map.put_new(params, "catalogue_uuid", socket.assigns.catalogue_uuid)

    with {:ok, item} <- Catalogue.create_item(params, actor_opts(socket)),
         {:ok, _rules} <- maybe_put_rules(socket, item),
         :ok <- Attachments.maybe_rename_pending_folder(socket, item) do
      {:noreply,
       socket
       |> put_flash(:info, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Item created."))
       |> push_navigate(to: redirect_target(socket, item))}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_changeset(socket, changeset)}

      {:error, {:duplicate_referenced_catalogue, _uuid}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(
             PhoenixKitCatalogue.Gettext,
             "Each catalogue can only appear once in the rules list."
           )
         )}
    end
  end

  defp save_item(socket, :edit, params) do
    # If item had a different primary language, rekey data to global primary on save
    params =
      if socket.assigns[:needs_primary_translation] && params["data"] do
        global_primary = socket.assigns.primary_language
        rekeyed = Multilang.rekey_primary(params["data"], global_primary)
        Map.put(params, "data", rekeyed)
      else
        params
      end

    with {:ok, item} <- Catalogue.update_item(socket.assigns.item, params, actor_opts(socket)),
         {:ok, _rules} <- maybe_put_rules(socket, item) do
      {:noreply,
       socket
       |> put_flash(:info, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Item updated."))
       |> push_navigate(to: redirect_target(socket, item))}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_changeset(socket, changeset)}

      {:error, {:duplicate_referenced_catalogue, _uuid}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(
             PhoenixKitCatalogue.Gettext,
             "Each catalogue can only appear once in the rules list."
           )
         )}
    end
  end

  # Only persist rules when the parent catalogue is smart. On standard
  # catalogues the picker is never rendered, `working_rules` stays `%{}`,
  # and we skip the context call entirely.
  defp maybe_put_rules(socket, item) do
    case socket.assigns.catalogue_kind do
      "smart" ->
        rules =
          working_rules_to_specs(
            socket.assigns.working_rules,
            socket.assigns.rule_candidate_order
          )

        Catalogue.put_catalogue_rules(item, rules, actor_opts(socket))

      _ ->
        {:ok, :skipped}
    end
  end

  # Walks the user-defined display order and emits one spec per active
  # rule, with `position` reflecting the visible row index. UUIDs in
  # `working_rules` that aren't in the order list (defensive — should
  # never happen) get appended at the end so we never silently drop a
  # rule the user toggled on.
  defp working_rules_to_specs(working_rules, candidate_order) do
    ordered =
      candidate_order
      |> Enum.filter(&Map.has_key?(working_rules, &1))

    leftovers =
      working_rules
      |> Map.keys()
      |> Enum.reject(&(&1 in ordered))

    (ordered ++ leftovers)
    |> Enum.with_index()
    |> Enum.map(fn {uuid, idx} ->
      %{value: v, unit: u} = Map.fetch!(working_rules, uuid)
      %{referenced_catalogue_uuid: uuid, value: v, unit: u, position: idx}
    end)
  end

  # Accepts the blur-event string, returns a Decimal or nil (for blank /
  # unparseable). Lets the user clear the field to revert to "inherit
  # from item default".
  defp parse_decimal_or_nil(""), do: nil
  defp parse_decimal_or_nil(nil), do: nil

  defp parse_decimal_or_nil(s) when is_binary(s) do
    case Decimal.parse(s) do
      {decimal, ""} -> decimal
      {decimal, _rest} -> decimal
      :error -> nil
    end
  end

  defp redirect_target(socket, item) do
    cond do
      item.catalogue_uuid ->
        Paths.catalogue_detail(item.catalogue_uuid)

      socket.assigns.catalogue_uuid ->
        Paths.catalogue_detail(socket.assigns.catalogue_uuid)

      true ->
        Paths.index()
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
      <%!-- Header --%>
      <.admin_page_header
        back={if @catalogue_uuid, do: Paths.catalogue_detail(@catalogue_uuid), else: Paths.index()}
        title={@page_title}
        subtitle={
          if @action == :new,
            do:
              Gettext.gettext(
                PhoenixKitCatalogue.Gettext,
                "Add a new product or material to the catalogue."
              ),
            else:
              Gettext.gettext(
                PhoenixKitCatalogue.Gettext,
                "Update item details, pricing, and classification."
              )
        }
      />

      <%!-- PDF search button — visible on edit only. Opens a modal that
           searches the PDF library for any page mentioning the item's
           translated names. --%>
      <div :if={@action == :edit} class="flex items-center justify-between bg-base-200 rounded-lg p-3 gap-3">
        <div class="text-sm">
          <div class="font-medium">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Find this item in PDFs")}
          </div>
          <div class="text-xs text-base-content/60">
            {Gettext.gettext(
              PhoenixKitCatalogue.Gettext,
              "Searches the entire PDF library for the item's name across all enabled languages."
            )}
          </div>
        </div>
        <button type="button" phx-click="open_pdf_search" class="btn btn-sm btn-primary">
          <.icon name="hero-magnifying-glass" class="w-4 h-4" />
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search PDFs")}
        </button>
      </div>

      <.live_component
        :if={@action == :edit}
        module={PhoenixKitCatalogue.Web.Components.PdfSearchModal}
        id="pdf-search-modal"
        item={@item}
        show={@show_pdf_search}
      />

      <%!-- Primary language warning --%>
      <div :if={@needs_primary_translation} class="alert alert-warning">
        <.icon name="hero-exclamation-triangle" class="w-5 h-5 shrink-0" />
        <div>
          <p class="text-sm font-medium">
            {Gettext.gettext(
              PhoenixKitCatalogue.Gettext,
              "This item was imported in %{lang}. Please fill in the %{primary} translation and save to set it as the primary language.",
              lang: lang_name(@language_tabs, @item_primary_language),
              primary: lang_name(@language_tabs, @primary_language)
            )}
          </p>
        </div>
      </div>

      <%!-- Tab strip — persists across tab switches; each panel stays in
           the DOM (toggled by `hidden`) so the multilang wrapper and
           any user input don't lose state when flipping tabs. --%>
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
        </button>
      </div>

      <%!-- Media selector — single instance, reconfigured per click
           via @media_selector_target. Scoped to this item's folder
           so browse and new uploads never spill into other items. --%>
      <.live_component
        module={PhoenixKitWeb.Live.Components.MediaSelectorModal}
        id="item-form-media-selector"
        show={@show_media_selector}
        mode={@media_selection_mode}
        file_type_filter={@media_filter}
        selected_uuids={@media_selected_uuids}
        scope_folder_id={@files_folder_uuid}
        phoenix_kit_current_user={assigns[:phoenix_kit_current_user]}
      />

      <.form for={@form} action="#" phx-change="validate" phx-submit="save">
        <%!-- Featured image: opens the scoped picker in single+image
             mode. The picker both browses this item's images and
             accepts new uploads (which get dropped into the item's
             folder automatically). --%>
        <div class={"mb-4 #{if @current_tab != :details, do: "hidden"}"}>
          <.featured_image_card
            featured_image_uuid={@featured_image_uuid}
            featured_image_file={@featured_image_file}
            subtitle={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Shown in lists and detail views.")}
          />
        </div>

        <div class={"card bg-base-100 shadow-lg #{if @current_tab != :details, do: "hidden"}"}>
          <.multilang_tabs
            multilang_enabled={@multilang_enabled}
            language_tabs={@language_tabs}
            current_lang={@current_lang}
          />

          <div :if={@ai_translation_available?} class="px-6 -mt-2 mb-2">
            <div class="flex items-center gap-3">
              <.ai_translate_button ai_translate={ai_translate_config(assigns)} />
              <.ai_translate_progress ai_translate={ai_translate_config(assigns)} />
            </div>
            <.ai_translate_hint ai_translate={ai_translate_config(assigns)} />
          </div>

          <%!-- Only translatable fields live inside the wrapper. When the
               user switches languages, the wrapper's ID changes and
               morphdom remounts its children — so we keep the scope as
               small as possible (name + description), not the whole
               form. Everything else renders as a sibling below. --%>
          <.multilang_fields_wrapper
            multilang_enabled={@multilang_enabled}
            current_lang={@current_lang}
            skeleton_class="card-body flex flex-col gap-5 pb-0"
          >
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
                field_name="name"
                form_prefix="item"
                changeset={@changeset}
                schema_field={:name}
                multilang_enabled={@multilang_enabled}
                current_lang={@current_lang}
                primary_language={@primary_language}
                lang_data={@lang_data}
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Name")}
                placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "e.g., Oak Panel 18mm")}
                required
                class="w-full"
              />

              <.translatable_field
                field_name="description"
                form_prefix="item"
                changeset={@changeset}
                schema_field={:description}
                multilang_enabled={@multilang_enabled}
                current_lang={@current_lang}
                primary_language={@primary_language}
                lang_data={@lang_data}
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Description")}
                type="textarea"
                placeholder={
                  Gettext.gettext(
                    PhoenixKitCatalogue.Gettext,
                    "Product specifications, dimensions, materials..."
                  )
                }
                class="w-full"
              />
            </div>
          </.multilang_fields_wrapper>

          <div class="card-body flex flex-col gap-5 pt-0">
            <%!-- Pricing & identification — hidden for smart catalogues,
                   whose items are priced entirely by the rules picker below. --%>
            <div :if={@catalogue_kind != "smart"} class="flex flex-col gap-5">
              <div class="divider my-0"></div>

              <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  class="h-4 w-4"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M7 7h.01M7 3h5c.512 0 1.024.195 1.414.586l7 7a2 2 0 010 2.828l-7 7a2 2 0 01-2.828 0l-7-7A1.994 1.994 0 013 12V7a4 4 0 014-4z"
                  />
                </svg>
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Pricing & Identification")}
              </h2>

              <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
                <.input
                  field={@form[:sku]}
                  type="text"
                  label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "SKU")}
                  class="font-mono"
                  placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "e.g., KF-001")}
                />
                <div class="form-control">
                  <.input
                    field={@form[:base_price]}
                    type="number"
                    label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Base Price")}
                    step="0.01"
                    min="0"
                    placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "0.00")}
                  />
                  <span class="label-text-alt text-base-content/50 mt-1">
                    {Gettext.gettext(
                      PhoenixKitCatalogue.Gettext,
                      "Cost/purchase price before catalogue markup."
                    )}
                  </span>
                </div>
                <.select
                  field={@form[:unit]}
                  label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Unit")}
                  class="transition-colors focus-within:select-primary"
                  options={[
                    {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Piece"), "piece"},
                    {Gettext.gettext(PhoenixKitCatalogue.Gettext, "m² (square meter)"), "m2"},
                    {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Running meter"), "running_meter"}
                  ]}
                />
                <div class="form-control">
                  <.input
                    field={@form[:markup_percentage]}
                    type="number"
                    label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Markup Override (%)")}
                    step="0.01"
                    min="0"
                    placeholder={
                      if @catalogue_markup,
                        do:
                          Gettext.gettext(PhoenixKitCatalogue.Gettext, "Inherit: %{markup}%",
                            markup: Decimal.to_string(@catalogue_markup, :normal)
                          ),
                        else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Inherit catalogue markup")
                    }
                  />
                  <span class="label-text-alt text-base-content/50 mt-1">
                    {Gettext.gettext(
                      PhoenixKitCatalogue.Gettext,
                      "Leave blank to inherit the catalogue's markup. Set (including 0) to override just this item."
                    )}
                  </span>
                </div>
                <div class="form-control">
                  <.input
                    field={@form[:discount_percentage]}
                    type="number"
                    label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Discount Override (%)")}
                    step="0.01"
                    min="0"
                    max="100"
                    placeholder={
                      if @catalogue_discount,
                        do:
                          Gettext.gettext(PhoenixKitCatalogue.Gettext, "Inherit: %{discount}%",
                            discount: Decimal.to_string(@catalogue_discount, :normal)
                          ),
                        else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Inherit catalogue discount")
                    }
                  />
                  <span class="label-text-alt text-base-content/50 mt-1">
                    {Gettext.gettext(
                      PhoenixKitCatalogue.Gettext,
                      "Leave blank to inherit the catalogue's discount. Set (including 0) to override just this item."
                    )}
                  </span>
                </div>
              </div>
            </div>

            <%!-- Smart-catalogue rules (only for kind: "smart") --%>
            <div :if={@catalogue_kind == "smart"} class="flex flex-col gap-4">
              <div class="divider my-0"></div>
              <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
                <.icon name="hero-link" class="w-4 h-4" />
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue Rules")}
              </h2>
              <p class="text-sm text-base-content/60 -mt-2">
                {Gettext.gettext(
                  PhoenixKitCatalogue.Gettext,
                  "Pick which catalogues this item applies to and set a value + unit per catalogue. Rows left blank inherit the defaults below."
                )}
              </p>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div class="form-control">
                  <.input
                    field={@form[:default_value]}
                    type="number"
                    label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Default Value")}
                    step="0.0001"
                    min="0"
                    placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "e.g., 5")}
                  />
                  <span class="label-text-alt text-base-content/50 mt-1">
                    {Gettext.gettext(
                      PhoenixKitCatalogue.Gettext,
                      "Used for any selected catalogue that doesn't have its own value. If no catalogues are selected, this is the item's standalone fee (e.g. $50 flat)."
                    )}
                  </span>
                </div>
                <div class="form-control">
                  <.select
                    field={@form[:default_unit]}
                    label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Default Unit")}
                    class="transition-colors focus-within:select-primary"
                    options={[
                      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Percent (%)"), "percent"},
                      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Flat amount"), "flat"}
                    ]}
                  />
                  <span class="label-text-alt text-base-content/50 mt-1">
                    {Gettext.gettext(
                      PhoenixKitCatalogue.Gettext,
                      "Used for any selected catalogue that doesn't have its own unit."
                    )}
                  </span>
                </div>
              </div>

              <.catalogue_rules_picker
                catalogues={sort_candidates(@rule_candidates, @rule_candidate_order)}
                rules={@working_rules}
                item_default_value={Ecto.Changeset.get_field(@changeset, :default_value)}
                on_reorder={if length(@rule_candidates) > 1, do: "reorder_catalogue_rules"}
              />
            </div>

            <%!-- Classification — available for both standard and smart
                   items. Smart items use category/manufacturer purely for
                   organization; the rule-based pricing is unaffected. --%>
            <div class="flex flex-col gap-5">
              <div class="divider my-0"></div>

              <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  class="h-4 w-4"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M19 11H5m14 0a2 2 0 012 2v6a2 2 0 01-2 2H5a2 2 0 01-2-2v-6a2 2 0 012-2m14 0V9a2 2 0 00-2-2M5 11V9a2 2 0 012-2m0 0V5a2 2 0 012-2h6a2 2 0 012 2v2M7 7h10"
                  />
                </svg>
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Classification")}
              </h2>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <.select
                  field={@form[:category_uuid]}
                  label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category")}
                  class="transition-colors focus-within:select-primary"
                  prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "-- No category --")}
                  options={Enum.map(@categories, &{&1.name, &1.uuid})}
                />
                <.select
                  field={@form[:manufacturer_uuid]}
                  label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Manufacturer")}
                  class="transition-colors focus-within:select-primary"
                  prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "-- No manufacturer --")}
                  options={Enum.map(@manufacturers, &{&1.name, &1.uuid})}
                />
              </div>
            </div>

            <div class="form-control">
              <.select
                field={@form[:status]}
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Status")}
                class="transition-colors focus-within:select-primary"
                options={[
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Active"), "active"},
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Inactive"), "inactive"},
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Discontinued"), "discontinued"}
                ]}
              />
              <span class="label-text-alt text-base-content/50 mt-1">
                {Gettext.gettext(
                  PhoenixKitCatalogue.Gettext,
                  "Discontinued items are kept for reference but hidden from active listings."
                )}
              </span>
            </div>
          </div>
        </div>

        <%!-- Metadata tab — global field list, user opts in per item.
             Values live in `item.data["meta"]`; legacy keys (stored
             but no longer in Metadata.definitions(:item)) render with a
             "Legacy" pill and a remove-only action so data isn't lost
             silently. --%>
        <div class={"card bg-base-100 shadow-lg #{if @current_tab != :metadata, do: "hidden"}"}>
          <.metadata_editor
            resource_type={:item}
            state={@meta_state}
            id_prefix="item"
            description={
              Gettext.gettext(
                PhoenixKitCatalogue.Gettext,
                "Attach any metadata fields that apply to this item. Blank values are dropped on save."
              )
            }
          />
        </div>

        <%!-- Files tab — direct upload, per-item scope. Files are
             discoverable via the item's folder
             (`item.data["files_folder_uuid"]`); the grid is refreshed
             from that folder after each upload. No list to track
             on the item — the folder is the single source of truth. --%>
        <div class={"card bg-base-100 shadow-lg #{if @current_tab != :files, do: "hidden"}"}>
          <div class="card-body flex flex-col gap-4">
            <div class="flex items-center justify-between gap-4">
              <div class="flex flex-col gap-0.5 min-w-0">
                <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
                  <.icon name="hero-paper-clip" class="w-4 h-4" />
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Attached Files")}
                  <span
                    :if={@files_state.files != []}
                    class="badge badge-sm badge-ghost ml-1"
                  >
                    {length(@files_state.files)}
                  </span>
                </h2>
                <p class="text-xs text-base-content/50">
                  {Gettext.gettext(
                    PhoenixKitCatalogue.Gettext,
                    "Spec sheets, drawings, photos. Any file type is accepted."
                  )}
                </p>
              </div>
            </div>

            <%!-- Inline dropzone — uploads land in this item's folder
                 and appear in the grid below. No popup, no selection
                 ceremony. --%>
            <label
              for={@uploads.attachment_files.ref}
              class="flex flex-col items-center justify-center gap-2 py-6 border-2 border-dashed border-base-300 rounded-md bg-base-200/20 hover:bg-base-200/40 transition-colors cursor-pointer"
              phx-drop-target={@uploads.attachment_files.ref}
            >
              <.icon name="hero-cloud-arrow-up" class="w-8 h-8 text-base-content/40" />
              <div class="text-sm text-base-content/60">
                <span class="font-medium text-primary">
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Click to upload")}
                </span>
                <span>{Gettext.gettext(PhoenixKitCatalogue.Gettext, " or drag & drop")}</span>
              </div>
              <.live_file_input upload={@uploads.attachment_files} class="hidden" />
            </label>

            <%!-- In-flight uploads: one row per active entry. --%>
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

            <%!-- Phoenix.LiveView upload errors (too_large, not_accepted, too_many_files). --%>
            <p :for={err <- upload_errors(@uploads.attachment_files)} class="text-xs text-error">
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
                    data-confirm={
                      Gettext.gettext(
                        PhoenixKitCatalogue.Gettext,
                        "Remove this file from the item? If it's not attached to any other item, it will be moved to trash (admins can restore)."
                      )
                    }
                    class="btn btn-ghost btn-xs btn-square"
                    title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Remove from item")}
                  >
                    <.icon name="hero-x-mark" class="w-4 h-4" />
                  </button>
                </li>
              </ul>
            <% end %>
          </div>
        </div>

        <%!-- Actions — sit outside the tab panels so Save works from
             any tab; the form element wraps them all. Save is
             disabled while uploads are mid-flight so we don't race
             the post-upload `handle_progress` write against the save
             path (would drop the just-uploaded file from the
             resource). --%>
        <div class="flex justify-end gap-3 pt-2">
          <.link
            navigate={
              if @catalogue_uuid, do: Paths.catalogue_detail(@catalogue_uuid), else: Paths.index()
            }
            class="btn btn-ghost"
          >
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
                Gettext.gettext(PhoenixKitCatalogue.Gettext, "Create Item")

              true ->
                Gettext.gettext(PhoenixKitCatalogue.Gettext, "Save Changes")
            end}
          </button>
        </div>
      </.form>

      <%!-- AI translate modal — rendered OUTSIDE the form (its endpoint/
           prompt selectors are their own <form>; nested forms are invalid). --%>
      <.ai_translate_modal ai_translate={ai_translate_config(assigns)} />

      <%!-- Move — collapsed by default. Standard items move to a
           category anywhere; smart items move across smart catalogues
           (no category). Each block only renders when its own target
           list is non-empty so we never show an empty-dropdown dead
           end; the outer <details> only renders when at least one
           branch is available. --%>
      <details
        :if={
          @action == :edit &&
            ((@catalogue_kind != "smart" && @all_categories != []) ||
               (@catalogue_kind == "smart" && @smart_move_targets != []))
        }
        class="card bg-base-100 shadow-lg"
      >
        <summary class="card-body py-3 cursor-pointer flex-row items-center gap-2 select-none">
          <.icon name="hero-arrows-right-left" class="w-4 h-4 text-base-content/60" />
          <h3 class="font-semibold text-base">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move")}</h3>
          <.icon name="hero-chevron-down" class="w-4 h-4 ml-auto text-base-content/40" />
        </summary>

        <div class="card-body pt-0 space-y-6">
          <%!-- Standard items: move to any category --%>
          <div :if={@catalogue_kind != "smart" && @all_categories != []} class="flex flex-col gap-3">
            <div>
              <p class="font-medium text-sm">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move to Another Category")}</p>
              <p class="text-xs text-base-content/60">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move this item to a category in any catalogue.")}
              </p>
            </div>
            <div class="flex items-end gap-3">
              <div class="form-control flex-1">
                <.select
                  name="category_uuid"
                  id="item-move-category"
                  value={@move_target}
                  prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "-- Select category --")}
                  options={Enum.map(@all_categories, &{&1.name, &1.uuid})}
                  class="select-sm transition-colors focus-within:select-primary"
                  phx-change="select_move_target"
                />
              </div>
              <button
                type="button"
                phx-click="move_item"
                phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Moving...")}
                disabled={is_nil(@move_target)}
                class="btn btn-sm btn-outline"
              >
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move")}
              </button>
            </div>
          </div>

          <%!-- Smart items: move to a different smart catalogue --%>
          <div :if={@catalogue_kind == "smart" && @smart_move_targets != []} class="flex flex-col gap-3">
            <div>
              <p class="font-medium text-sm">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move to Another Smart Catalogue")}</p>
              <p class="text-xs text-base-content/60">
                {Gettext.gettext(
                  PhoenixKitCatalogue.Gettext,
                  "Move this item into a different smart catalogue. Its catalogue rules stay attached."
                )}
              </p>
            </div>
            <div class="flex items-end gap-3">
              <div class="form-control flex-1">
                <.select
                  name="catalogue_uuid"
                  id="item-move-smart-catalogue"
                  value={@move_target}
                  prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "-- Select catalogue --")}
                  options={Enum.map(@smart_move_targets, &{&1.name, &1.uuid})}
                  class="select-sm transition-colors focus-within:select-primary"
                  phx-change="select_move_target"
                />
              </div>
              <button
                type="button"
                phx-click="move_item"
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
    </div>
    """
  end

  defp lang_name(language_tabs, code) do
    case Enum.find(language_tabs, &(&1.code == code)) do
      %{name: name} -> name
      _ -> code
    end
  end
end
