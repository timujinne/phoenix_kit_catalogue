defmodule PhoenixKitCatalogue.Web.ItemFormLive do
  @moduledoc "Create/edit form for catalogue items with multilang support."

  use Phoenix.LiveView
  use PhoenixKitAI.Components.AITranslate.Embed

  require Logger

  import PhoenixKitWeb.Components.MultilangForm
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Input, only: [input: 1]
  import PhoenixKitWeb.Components.Core.Select, only: [select: 1]
  import PhoenixKitWeb.Components.Core.Button, only: [button: 1]
  import PhoenixKitWeb.Components.Core.Modal, only: [modal: 1]
  import PhoenixKitWeb.Components.Core.PkLink, only: [pk_link: 1]

  import PhoenixKitWeb.Components.Core.TableRowMenu,
    only: [table_row_menu: 1, table_row_menu_button: 1, table_row_menu_divider: 1]

  # `<.input label=...>` renders its label as a plain `font-semibold` span
  # while `<.select>` and this component use daisyUI's `fieldset-legend`,
  # so the two sizes disagree wherever they sit side by side. The supplier
  # modal labels every field through this one component instead.
  import PhoenixKitWeb.Components.Core.FormFieldLabel, only: [label: 1]

  # Entities renders the control for every admin-defined supplier field,
  # so a type added to entities later works here without a change.
  import PhoenixKitEntities.Components.FieldInput, only: [field_input: 1]

  import PhoenixKitCatalogue.Web.Components,
    only: [
      attachments_files_panel: 1,
      catalogue_rules_picker: 1,
      metadata_editor: 1
    ]

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

  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.Multilang
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitCatalogue.Attachments
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.Helpers
  alias PhoenixKitCatalogue.Catalogue.ItemSupplierInfos
  alias PhoenixKitCatalogue.Catalogue.PubSub
  alias PhoenixKitCatalogue.Catalogue.Suppliers
  alias PhoenixKitCatalogue.Metadata
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Schemas.Item

  # Admin-defined extra fields on supplier rows (the entities-backed
  # feature built 2026-08-21). HIDDEN by owner decision the same day —
  # "simplify things", to be brought back later. Everything behind this
  # flag is intact and tested: the `SupplierFields` context, its managed
  # blueprint, the facade delegations, and the boot-time guard
  # registration. Flipping this to `true` is the whole restore — it
  # re-shows the Fields button, the per-field columns on the suppliers
  # table, and the Extra fields block in the supplier modal.
  #
  # Values already stored under `metadata["custom_fields"]` are NOT
  # touched while it is off: the edit path merges an empty map, which
  # preserves them, so a restore brings the data back with the UI.
  @supplier_custom_fields false

  # The BUILT-IN supplier terms — SKU, unit cost + currency, lead time,
  # minimum order quantity — and the two row actions that only make sense
  # alongside them (edit, price history). Hidden by owner decision
  # 2026-08-21: a supplier link is just a link for now, and when the
  # switch to entities happens these become entity fields rather than
  # columns, so the form should not teach two systems in the meantime.
  #
  # Columns, data and context are all untouched — this hides the UI only.
  # `phoenix_kit_cat_item_supplier_info` still carries every value already
  # written, `revise_unit_cost/3` still works, and warehouse still reads
  # what it always read.
  @supplier_terms_fields false

  # Comments on a supplier row are about THAT supplier on THIS item — one
  # thread per item × supplier, keyed on the row's thread uuid
  # (`Catalogue.SupplierComments`), never the CRM company's own thread: the
  # same company supplies other products, and "he promised a discount on
  # this one" must not land in its general notes. The company page keeps
  # its own comments; the modal only links to it.
  #
  # `phoenix_kit_comments` is a SOFT dependency here: the catalogue does
  # not declare it (CRM does), so every touchpoint is guarded and the
  # affordance simply does not render when the package is absent or the
  # module is switched off.
  @compile {:no_warn_undefined, PhoenixKitComments}
  @compile {:no_warn_undefined, PhoenixKitComments.Web.CommentsComponent}
  @compile {:no_warn_undefined, PhoenixKitCRM.Paths}

  @translatable_fields ["name", "description"]
  @preserve_fields %{
    # Translatable primaries: submitted only on the primary tab, so a
    # secondary-tab validate/save must re-inject them or :new loses them.
    "name" => :name,
    "description" => :description,
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

    case load_item(action, params) do
      {nil, _, _} ->
        {:ok,
         socket
         |> put_flash(:error, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Item not found."))
         |> push_navigate(to: Paths.index())}

      {item, changeset, catalogue_uuid} ->
        # Supplier rows, the files grid and the category options are read
        # from the DB, not owned by the form — follow other sessions' writes
        # to them (see the `:catalogue_data_changed` clauses).
        if connected?(socket), do: PubSub.subscribe()

        {:ok,
         socket
         |> assign(:return_to, safe_return_to(params["return_to"]))
         |> mount_form(action, item, changeset, catalogue_uuid)
         # `?tab=` deep-links land on a tab (the Comments admin's back-links
         # open the Suppliers tab); parse_tab/1 is an allowlist, anything
         # else is the default.
         |> assign(:current_tab, parse_tab(params["tab"]))}
    end
  end

  defp valid_origin_category(uuid, catalogue_uuid) when is_binary(uuid) and uuid != "" do
    case Catalogue.get_category(uuid) do
      %PhoenixKitCatalogue.Schemas.Category{catalogue_uuid: ^catalogue_uuid, status: "active"} ->
        uuid

      _ ->
        nil
    end
  end

  defp valid_origin_category(_, _), do: nil

  # Only ever navigate to a caller-supplied path after the core local-path
  # guard — return_to is user-influenced input.
  defp safe_return_to(rt) when is_binary(rt) do
    if Routes.local_path?(rt), do: rt
  end

  defp safe_return_to(_), do: nil

  defp load_item(:new, params) do
    catalogue_uuid = params["catalogue_uuid"]

    # "Add Item" carries the level it was clicked from (?category=...) so the
    # form opens with that category already selected. Validated — a forged or
    # stale uuid must not seed a category from another catalogue.
    item = %Item{
      catalogue_uuid: catalogue_uuid,
      category_uuid: valid_origin_category(params["category"], catalogue_uuid)
    }

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
          |> PhoenixKit.RepoHelper.repo().preload([:category])
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
      parent_catalogue_name: parent_catalogue && parent_catalogue.name,
      catalogue_kind: kind,
      catalogue_markup: markup_from_catalogue(parent_catalogue),
      catalogue_discount: discount_from_catalogue(parent_catalogue),
      categories: categories,
      manufacturers: Catalogue.list_all_manufacturers(status: "active"),
      all_suppliers: Suppliers.list_all(),
      supplier_infos: load_supplier_infos(action, item),
      supplier_company_links: %{},
      supplier_comment_threads: %{},
      # nil = closed. Open state carries its own mode/draft/error so the
      # modal reports failures inside itself rather than as a page flash
      # that lands behind it.
      supplier_form: nil,
      supplier_fields: load_supplier_fields(),
      supplier_fields_manageable: supplier_fields_manageable?(),
      supplier_terms_visible: supplier_terms_fields?(),
      supplier_comments_available: comments_available?(),
      supplier_comments: nil,
      supplier_comment_previews: %{},
      supplier_comment_subscriptions: MapSet.new(),
      supplier_field_manager: false,
      supplier_field_editor: nil,
      supplier_field_remove: nil,
      supplier_history_open: false,
      supplier_history_rows: [],
      supplier_history_name: nil,
      # `{item_uuid, supplier_uuid}` of the open history modal, so a price
      # revision landing from another session can re-read its rows.
      supplier_history_pair: nil,
      all_categories: all_categories,
      smart_move_targets: smart_move_targets,
      move_target: nil,
      current_tab: :details,
      meta_state: Metadata.build_state(:item, item),
      show_pdf_search: false
    )
    |> mount_supplier_rows(action, item)
    |> Attachments.mount_attachments(item)
    |> Attachments.allow_attachment_upload()
    |> assign_changeset(changeset)
    |> assign_rule_state(item, kind, catalogue_uuid)
    |> mount_multilang()
    |> adjust_multilang_for_item(item)
    |> assign_attribute_state(item, action)
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

  # "switch_language" is handled by the core `mount_multilang/1` auto hook
  # (default `auto_switch_language: true`) — no clause needed here.

  # AI-translate modal events handled by `use ...AITranslate.Embed`.

  @impl true
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
    socket =
      socket
      |> absorb_meta_params(params)
      |> absorb_attribute_selection(params)

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
    socket =
      socket
      |> absorb_meta_params(params)
      |> absorb_attribute_selection(params)

    item_params = Map.get(params, "item", %{})

    item_params =
      item_params
      |> merge_translatable_params(socket, @translatable_fields,
        changeset: socket.assigns.changeset,
        preserve_fields: @preserve_fields
      )
      |> Metadata.inject_into_data(socket.assigns.meta_state, :item)
      |> Attachments.inject_attachment_data(socket)

    save_item(socket, socket.assigns.action, item_params, save_mode(params))
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

  def handle_event("open_add_supplier", _params, socket) do
    {:noreply,
     assign(socket, :supplier_form, %{
       mode: :new,
       uuid: nil,
       draft: %{},
       custom: %{},
       error: nil
     })}
  end

  def handle_event("edit_supplier_info", %{"uuid" => uuid}, socket) do
    case owned_supplier_info(socket, uuid) do
      %{} = info ->
        {:noreply,
         assign(socket, :supplier_form, %{
           mode: :edit,
           uuid: info.uuid,
           draft: supplier_draft_from(info),
           # Only currently-DEFINED keys. A removed field's value stays in
           # the database on purpose, but seeding it here would fail the
           # save with :unknown_field and lock the row out of editing.
           custom: defined_custom_values(socket, info),
           error: nil
         })}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_add_supplier", _params, socket) do
    {:noreply, assign(socket, :supplier_form, nil)}
  end

  # The modal's inputs are namespaced `supplier_info[...]` and
  # `custom_fields[...]`; a change payload carries whichever the user
  # touched, so both merge independently into the open form's state.
  def handle_event("supplier_info_field_change", params, socket) do
    case socket.assigns.supplier_form do
      nil ->
        {:noreply, socket}

      form ->
        {:noreply,
         assign(socket, :supplier_form, %{
           form
           | draft: Map.merge(form.draft, Map.get(params, "supplier_info", %{})),
             custom: Map.merge(form.custom, Map.get(params, "custom_fields", %{})),
             error: nil
         })}
    end
  end

  def handle_event("save_supplier_info", params, socket) do
    case socket.assigns.supplier_form do
      nil ->
        {:noreply, socket}

      form ->
        form = %{
          form
          | draft: Map.merge(form.draft, Map.get(params, "supplier_info", %{})),
            custom: Map.merge(form.custom, Map.get(params, "custom_fields", %{}))
        }

        save_supplier_form(socket, form)
    end
  end

  def handle_event("set_primary_supplier", %{"uuid" => uuid}, socket) do
    item = socket.assigns.item

    case owned_supplier_info(socket, uuid) do
      nil ->
        {:noreply, socket}

      info ->
        case ItemSupplierInfos.set_primary(info, actor_opts(socket)) do
          {:ok, _} ->
            {:noreply, assign_supplier_infos(socket, item.uuid)}

          {:error, _} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to set primary supplier.")
             )}
        end
    end
  end

  def handle_event("open_supplier_history", %{"uuid" => uuid}, socket) do
    case owned_supplier_info(socket, uuid) do
      nil ->
        {:noreply, socket}

      info ->
        rows = ItemSupplierInfos.history_for_pair(info.item_uuid, info.supplier_uuid)
        name = supplier_display_name(info, socket.assigns.all_suppliers)

        {:noreply,
         assign(socket,
           supplier_history_open: true,
           supplier_history_rows: rows,
           supplier_history_name: name,
           supplier_history_pair: {info.item_uuid, info.supplier_uuid}
         )}
    end
  end

  # Opens this supplier's comment thread for THIS item. The thread and the
  # company behind the row are both resolved server-side from a row the
  # LiveView itself rendered, never taken from the payload — a crafted uuid
  # must not be able to address another item's thread or an arbitrary
  # company.
  def handle_event("open_supplier_comments", %{"uuid" => uuid}, socket) do
    with true <- socket.assigns.supplier_comments_available,
         %{} = info <- owned_supplier_info(socket, uuid),
         thread when is_binary(thread) <- socket.assigns.supplier_comment_threads[info.uuid] do
      {:noreply,
       assign(socket, :supplier_comments, %{
         thread_uuid: thread,
         company_uuid: socket.assigns.supplier_company_links[info.uuid],
         name: supplier_display_name(info, socket.assigns.all_suppliers)
       })}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("close_supplier_comments", _params, socket) do
    {:noreply, assign(socket, :supplier_comments, nil)}
  end

  def handle_event("close_supplier_history", _params, socket) do
    {:noreply,
     assign(socket,
       supplier_history_open: false,
       supplier_history_rows: [],
       supplier_history_name: nil,
       supplier_history_pair: nil
     )}
  end

  def handle_event("delete_supplier_info", %{"uuid" => uuid}, socket) do
    item = socket.assigns.item

    case owned_supplier_info(socket, uuid) do
      nil ->
        {:noreply, socket}

      info ->
        case ItemSupplierInfos.delete(info, actor_opts(socket)) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign_supplier_infos(item.uuid)
             |> put_flash(
               :info,
               Gettext.gettext(PhoenixKitCatalogue.Gettext, "Supplier removed.")
             )}

          {:error, _} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to remove supplier.")
             )}
        end
    end
  end

  # ── Supplier custom fields (entities-defined) ────────────────────────
  #
  # These edit the GLOBAL field set every item's suppliers share, not
  # this item's data — the modal copy says so. One modal, two modes,
  # rendered fresh per open so the type-specific block is server-driven;
  # the type is immutable after creation because stored values were cast
  # for it. Same contract as the attribute-set extras editor.

  # Gated on the server too, not just by hiding the button: a crafted
  # event must not open a manager the owner asked to remove.
  def handle_event("open_supplier_field_manager", _params, socket) do
    if supplier_custom_fields?() do
      # Re-read on open: another session may have changed the field set
      # since this page mounted.
      {:noreply,
       assign(socket, supplier_field_manager: true, supplier_fields: load_supplier_fields())}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_supplier_field_manager", _params, socket) do
    {:noreply, assign(socket, supplier_field_manager: false)}
  end

  def handle_event("open_supplier_field_editor", _params, socket) do
    {:noreply,
     assign(socket, :supplier_field_editor, %{
       mode: :new,
       key: nil,
       label: "",
       type: "text",
       choices: [],
       error: nil
     })}
  end

  def handle_event("edit_supplier_field", %{"key" => key}, socket) do
    case Enum.find(socket.assigns.supplier_fields, &(&1["key"] == key)) do
      %{} = field ->
        {:noreply,
         assign(socket, :supplier_field_editor, %{
           mode: :edit,
           key: key,
           label: field["label"],
           type: field["type"],
           choices: field["options"] || [],
           error: nil
         })}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("close_supplier_field_editor", _params, socket) do
    {:noreply, assign(socket, :supplier_field_editor, nil)}
  end

  def handle_event("validate_supplier_field_editor", params, socket) do
    case socket.assigns.supplier_field_editor do
      nil ->
        {:noreply, socket}

      editor ->
        {:noreply, assign(socket, :supplier_field_editor, merge_field_params(editor, params))}
    end
  end

  def handle_event("add_supplier_field_choice", _params, socket) do
    case socket.assigns.supplier_field_editor do
      nil ->
        {:noreply, socket}

      editor ->
        {:noreply,
         assign(socket, :supplier_field_editor, %{editor | choices: editor.choices ++ [""]})}
    end
  end

  def handle_event("remove_supplier_field_choice", %{"index" => raw}, socket) do
    with editor when not is_nil(editor) <- socket.assigns.supplier_field_editor,
         {index, ""} <- Integer.parse(raw) do
      {:noreply,
       assign(socket, :supplier_field_editor, %{
         editor
         | choices: List.delete_at(editor.choices, index)
       })}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("save_supplier_field_editor", params, socket) do
    case socket.assigns.supplier_field_editor do
      nil -> {:noreply, socket}
      editor -> save_supplier_field(socket, merge_field_params(editor, params))
    end
  end

  def handle_event("request_remove_supplier_field", %{"key" => key}, socket) do
    {:noreply, assign(socket, :supplier_field_remove, key)}
  end

  def handle_event("cancel_remove_supplier_field", _params, socket) do
    {:noreply, assign(socket, :supplier_field_remove, nil)}
  end

  def handle_event("confirm_remove_supplier_field", _params, socket) do
    with key when is_binary(key) <- socket.assigns.supplier_field_remove,
         {:ok, _} <- Catalogue.remove_supplier_field(key, actor_opts(socket)) do
      {:noreply,
       socket
       |> assign(supplier_field_remove: nil, supplier_fields: load_supplier_fields())
       |> put_flash(:info, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Field removed."))}
    else
      _ ->
        {:noreply,
         socket
         |> assign(:supplier_field_remove, nil)
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to remove the field.")
         )}
    end
  end

  # ── Attribute sets (staged; applied on save) ─────────────────────────
  #
  # The picker select sits INSIDE the main form (nested forms are
  # invalid), so it carries its own phx-change — which takes precedence
  # over the form's "validate" for this input — and its name is ignored
  # by the save params.

  def handle_event("attach_set", %{"attach_set_uuid" => set_uuid}, socket) do
    staged = socket.assigns.staged_set_uuids

    valid? =
      is_binary(set_uuid) and set_uuid != "" and
        set_uuid not in staged and
        Enum.any?(socket.assigns.available_sets, &(&1.uuid == set_uuid))

    if valid? do
      {:noreply,
       socket
       |> assign(:staged_set_uuids, staged ++ [set_uuid])
       |> assign_set_previews()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("detach_set", %{"uuid" => set_uuid}, socket) do
    {:noreply,
     socket
     |> assign(:staged_set_uuids, List.delete(socket.assigns.staged_set_uuids, set_uuid))
     |> assign(:staged_selections, Map.delete(socket.assigns.staged_selections, set_uuid))
     |> assign_set_previews()}
  end

  def handle_event("reorder_staged_sets", %{"ordered_ids" => ids}, socket) when is_list(ids) do
    staged = socket.assigns.staged_set_uuids
    # Only reorder what is actually staged — the client list is forgeable.
    reordered = Enum.filter(ids, &(&1 in staged))

    if Enum.sort(reordered) == Enum.sort(staged) do
      {:noreply, assign(socket, :staged_set_uuids, reordered)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("reorder_staged_sets", _params, socket), do: {:noreply, socket}

  # The boss's two modes (2026-08-19): checking values narrows what the
  # set says about THIS item — one check is "this exact object", several
  # are "the options it comes in", none is "the whole set applies". The
  # count IS the mode; nothing else is tracked.
  # phx-value-key, NOT phx-value-value: a click payload on an input
  # includes the element's own value attribute under "value" (a bare
  # checkbox submits "on"), which would clobber the param.
  def handle_event("toggle_value_selection", %{"set" => set_uuid, "key" => key}, socket) do
    with true <- set_uuid in socket.assigns.staged_set_uuids,
         %{values: values} <- socket.assigns.set_previews[set_uuid],
         true <- Enum.any?(values, &(&1.key == key)) do
      selections = socket.assigns.staged_selections
      current = Map.get(selections, set_uuid, MapSet.new())

      current =
        if MapSet.member?(current, key),
          do: MapSet.delete(current, key),
          else: MapSet.put(current, key)

      {:noreply, assign(socket, :staged_selections, Map.put(selections, set_uuid, current))}
    else
      _ -> {:noreply, socket}
    end
  end

  defp parse_tab("metadata"), do: :metadata
  defp parse_tab("sourcing"), do: :sourcing
  defp parse_tab("files"), do: :files
  defp parse_tab(_), do: :details

  defp absorb_meta_params(socket, params) do
    assign(socket, :meta_state, Metadata.absorb_params(socket.assigns.meta_state, params))
  end

  defp load_supplier_infos(:edit, %Item{uuid: uuid}) when not is_nil(uuid),
    do: ItemSupplierInfos.list_for_item(uuid)

  defp load_supplier_infos(_action, _item), do: []

  defp supplier_display_name(info, all_suppliers) do
    case Enum.find(all_suppliers, &(&1.uuid == info.supplier_uuid)) do
      nil -> info.supplier_name_snapshot || info.supplier_uuid
      s -> s.name
    end
  end

  # ── Supplier modal ───────────────────────────────────────────────────

  # Scope the lookup to the rows this item actually shows: a uuid from a
  # crafted payload must not reach another item's supplier row.
  defp owned_supplier_info(socket, uuid) do
    Enum.find(socket.assigns.supplier_infos, &(&1.uuid == uuid))
  end

  # The single choke point for the hidden feature: with @supplier_custom_fields
  # false every render site iterates an empty list, so the columns, the
  # modal block and the manager all disappear without a branch each.
  defp load_supplier_fields do
    if supplier_custom_fields?(), do: Catalogue.supplier_fields(), else: []
  end

  defp supplier_custom_fields?, do: @supplier_custom_fields

  defp supplier_terms_fields?, do: @supplier_terms_fields

  defp comments_available? do
    Code.ensure_loaded?(PhoenixKitComments) and PhoenixKitComments.enabled?()
  rescue
    _ -> false
  catch
    # An unreachable DB raises on an unowned checkout but EXITS on a dead
    # pool — the settings read behind enabled?/0 hits both.
    :exit, _ -> false
  end

  # Rows plus what hangs off them, built once per reload rather than per
  # render: the CRM company behind each row (the name link and the "open
  # the company" link — resolving a local row costs a query) and the
  # comment thread each row carries. EVERY row carries one: a local or
  # imported supplier has no company page, but "he promised a discount on
  # this product" is about the row, not the company. Runs after the main
  # assign block: the availability flag has to exist first.
  defp mount_supplier_rows(socket, :edit, %Item{uuid: uuid}) when not is_nil(uuid),
    do: assign_supplier_infos(socket, uuid)

  defp mount_supplier_rows(socket, _action, _item), do: socket

  defp assign_supplier_infos(socket, item_uuid) do
    infos = ItemSupplierInfos.list_for_item(item_uuid)

    links =
      infos
      |> Map.new(&{&1.uuid, Catalogue.supplier_crm_company_uuid(&1)})
      |> Map.filter(fn {_uuid, company} -> is_binary(company) end)

    threads =
      if socket.assigns[:supplier_comments_available],
        do: Map.new(infos, &{&1.uuid, Catalogue.supplier_comment_thread_uuid(&1)}),
        else: %{}

    socket
    |> assign(
      supplier_infos: infos,
      supplier_company_links: links,
      supplier_comment_threads: threads
    )
    |> assign(:supplier_comment_previews, comment_previews(threads))
    |> sync_comment_subscriptions(threads)
  end

  # Everything the Suppliers tab derives from the DB: the rows (+ CRM
  # links, threads, previews, subscriptions), the supplier names, and the
  # price-history modal if it is open.
  defp refresh_supplier_state(socket) do
    socket
    |> assign(:all_suppliers, Suppliers.list_all())
    |> assign_supplier_infos(socket.assigns.item.uuid)
    |> refresh_supplier_history()
  end

  defp refresh_supplier_history(
         %{assigns: %{supplier_history_open: true, supplier_history_pair: {item_uuid, sup_uuid}}} =
           socket
       ) do
    assign(
      socket,
      :supplier_history_rows,
      ItemSupplierInfos.history_for_pair(item_uuid, sup_uuid)
    )
  end

  defp refresh_supplier_history(socket), do: socket

  # Same source as mount_form/5: the catalogue's categories for an item
  # that has one, every category otherwise (a `:new` form without scope).
  defp refresh_category_options(socket) do
    catalogue_uuid = socket.assigns.catalogue_uuid

    categories =
      if catalogue_uuid,
        do: Catalogue.list_categories_for_catalogue(catalogue_uuid),
        else: Catalogue.list_all_categories()

    all_categories =
      if socket.assigns.action == :edit, do: Catalogue.list_all_categories(), else: []

    assign(socket, categories: categories, all_categories: all_categories)
  end

  # Re-reads the previews against the threads already resolved — a comment
  # changes no supplier row, so there is nothing else to reload.
  defp refresh_comment_previews(socket) do
    assign(
      socket,
      :supplier_comment_previews,
      comment_previews(socket.assigns.supplier_comment_threads)
    )
  end

  # One subscription per thread. PubSub delivers once PER subscription, so
  # only threads not yet subscribed are added — and threads no longer on
  # the item are dropped, or a removed supplier's broadcasts would keep
  # refreshing previews for the life of the socket. Subscribing is
  # decoration like the previews: a failure is logged and the tab stands.
  defp sync_comment_subscriptions(socket, threads) do
    if connected?(socket) and socket.assigns.supplier_comments_available do
      already = socket.assigns[:supplier_comment_subscriptions] || MapSet.new()
      wanted = MapSet.new(Map.values(threads))
      type = Catalogue.supplier_comment_resource_type()

      wanted
      |> MapSet.difference(already)
      |> Enum.each(&PhoenixKitComments.subscribe(type, &1))

      already
      |> MapSet.difference(wanted)
      |> Enum.each(&PhoenixKitComments.unsubscribe(type, &1))

      assign(socket, :supplier_comment_subscriptions, wanted)
    else
      socket
    end
  rescue
    error ->
      Logger.warning("supplier comment subscriptions unavailable: #{inspect(error)}")
      socket
  end

  # The CRM company page for a supplier row, or nil when there is no company
  # behind it (an unlinked local row, or a contact).
  #
  # `PhoenixKitCRM.Paths` is reached through a guard: CRM is an optional
  # runtime dependency here. The RAW helper on purpose: these paths go into
  # `<.pk_link navigate>`, which applies `Routes.path/1` itself — the
  # prefixed `company/1` rendered `/phoenix_kit/en/phoenix_kit/en/…`.
  defp supplier_page_path(links, %{uuid: uuid}),
    do: links |> Map.get(uuid) |> crm_company_path()

  defp supplier_page_path(_targets, _info), do: nil

  defp crm_company_path(company_uuid) when is_binary(company_uuid) do
    if Code.ensure_loaded?(PhoenixKitCRM.Paths) and
         function_exported?(PhoenixKitCRM.Paths, :company_raw, 1) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(PhoenixKitCRM.Paths, :company_raw, [company_uuid])
    end
  end

  defp crm_company_path(_company_uuid), do: nil

  # ── Inline comment previews ──────────────────────────────────────────

  attr(:preview, :map, required: true)
  attr(:uuid, :string, required: true)

  defp supplier_comment_preview(assigns) do
    ~H"""
    <div class="rounded-lg bg-base-200/50 px-3 py-2 flex flex-col gap-2">
      <div :if={@preview.latest == []} class="flex items-center justify-between gap-2">
        <span class="text-xs text-base-content/50 italic">
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No comments yet.")}
        </span>
        <.button
          type="button"
          phx-click="open_supplier_comments"
          phx-value-uuid={@uuid}
          variant="ghost"
          size="xs"
        >
          <.icon name="hero-chat-bubble-left-ellipsis" class="w-3.5 h-3.5" />
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Add a comment")}
        </.button>
      </div>

      <div :for={comment <- @preview.latest} class="flex flex-col gap-0.5">
        <div class="flex items-baseline gap-2">
          <span class="text-xs font-medium">{comment_author(comment)}</span>
          <span class="text-[0.65rem] text-base-content/40">
            {Calendar.strftime(comment.inserted_at, "%Y-%m-%d")}
          </span>
        </div>
        <p class="text-xs text-base-content/70 leading-snug">{comment_excerpt(comment)}</p>
      </div>

      <.button
        :if={@preview.latest != []}
        type="button"
        phx-click="open_supplier_comments"
        phx-value-uuid={@uuid}
        variant="ghost"
        size="xs"
        class="self-start"
      >
        {if @preview.count > length(@preview.latest),
          do:
            Gettext.gettext(PhoenixKitCatalogue.Gettext, "Show all %{count} comments",
              count: @preview.count
            ),
          else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Open comments")}
      </.button>
    </div>
    """
  end

  @comment_preview_count 2

  # One grouped count query for every supplier on the item, then a list
  # only for the ones that actually have comments — so an item whose
  # suppliers have none costs a single query.
  defp comment_previews(threads) when map_size(threads) == 0, do: %{}

  defp comment_previews(threads) do
    type = Catalogue.supplier_comment_resource_type()
    counts = PhoenixKitComments.count_comments(type, threads |> Map.values() |> Enum.uniq())

    Map.new(threads, fn {info_uuid, thread} ->
      count = Map.get(counts, thread, 0)

      {info_uuid, %{count: count, latest: latest_comments(type, thread, count)}}
    end)
  rescue
    # A preview is decoration; it must never take the sourcing tab down.
    error ->
      Logger.warning("supplier comment previews unavailable: #{inspect(error)}")
      %{}
  end

  defp latest_comments(_type, _thread, 0), do: []

  defp latest_comments(type, thread, _count) do
    type
    |> PhoenixKitComments.list_comments(thread, preload: [:user])
    |> Enum.take(-@comment_preview_count)
    |> Enum.reverse()
  end

  # Comment bodies are rich text. The preview strips markup and truncates;
  # HEEx escapes the result on the way out, so nothing a commenter wrote
  # can render as markup here.
  defp comment_excerpt(%{content: content}) when is_binary(content) do
    content
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 140)
  end

  defp comment_excerpt(_comment), do: ""

  # `author_display_name` is frozen on the row at write time — re-deriving
  # it would re-sign old comments when someone is renamed.
  defp comment_author(%{author_display_name: name}) when is_binary(name) and name != "", do: name

  defp comment_author(%{user: %User{} = user}), do: User.display_name(user)

  defp comment_author(_comment),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Unknown")

  # Header count must match the cells rendered per row, or the preview row
  # under each supplier misaligns the table.
  defp supplier_table_colspan(assigns) do
    # Supplier + Unit Cost + Primary + actions
    4 + if(assigns.supplier_terms_visible, do: 3, else: 0) + length(assigns.supplier_fields)
  end

  # Computed once at mount rather than inline in the template: with the
  # flag off the compiler folds the call to a constant and rejects the
  # `:if` as an always-false conditional.
  defp supplier_fields_manageable? do
    if supplier_custom_fields?(), do: Catalogue.supplier_fields_enabled?(), else: false
  end

  defp defined_custom_values(socket, info) do
    keys = MapSet.new(socket.assigns.supplier_fields, & &1["key"])

    info
    |> Catalogue.supplier_field_values()
    |> Map.filter(fn {key, _value} -> MapSet.member?(keys, key) end)
  end

  defp supplier_draft_from(info) do
    %{
      "supplier_uuid" => info.supplier_uuid,
      "supplier_sku" => info.supplier_sku,
      "unit_cost" => info.unit_cost && Decimal.to_string(info.unit_cost, :normal),
      "currency" => info.currency,
      "lead_time_days" => info.lead_time_days && Integer.to_string(info.lead_time_days),
      "min_order_qty" => info.min_order_qty && Decimal.to_string(info.min_order_qty, :normal)
    }
  end

  # Display name for the row being edited: the live supplier when it still
  # resolves, otherwise the row's tombstone snapshot.
  defp supplier_form_name(%{supplier_form: %{uuid: uuid}} = assigns) when is_binary(uuid) do
    case Enum.find(assigns.supplier_infos, &(&1.uuid == uuid)) do
      nil -> ""
      info -> supplier_display_name(info, assigns.all_suppliers)
    end
  end

  defp supplier_form_name(_assigns), do: ""

  defp save_supplier_form(socket, %{mode: :new} = form) do
    item = socket.assigns.item
    supplier_uuid = Map.get(form.draft, "supplier_uuid", "")

    with :ok <- require_supplier(supplier_uuid),
         {:ok, unit_cost} <- cast_unit_cost(form.draft),
         {:ok, custom} <- Catalogue.cast_supplier_field_values(form.custom) do
      selected = Enum.find(socket.assigns.all_suppliers, &(&1.uuid == supplier_uuid))

      attrs =
        form.draft
        |> supplier_column_attrs()
        |> Map.merge(%{
          "unit_cost" => unit_cost,
          "item_uuid" => item.uuid,
          "supplier_uuid" => supplier_uuid,
          # The dropdown mixes local and CRM suppliers; persist the source
          # of the chosen entry — a CRM party stored as "local" would
          # misroute the resolver and the audit task.
          "supplier_source" => if(selected, do: Atom.to_string(selected.source), else: "local"),
          "supplier_name_snapshot" => selected && selected.name,
          "metadata" => Catalogue.put_supplier_field_values(%{}, custom)
        })

      case ItemSupplierInfos.create(attrs, actor_opts(socket)) do
        {:ok, _info} ->
          {:noreply, close_supplier_form(socket, "Supplier added.")}

        # Named reasons reach the modal as themselves; a changeset is a
        # shape failure and stays generic.
        {:error, reason} when is_atom(reason) ->
          {:noreply, supplier_form_error(socket, form, reason)}

        {:error, _changeset} ->
          {:noreply, supplier_form_error(socket, form, :save_failed)}
      end
    else
      {:error, reason} -> {:noreply, supplier_form_error(socket, form, reason)}
    end
  end

  defp save_supplier_form(socket, %{mode: :edit} = form) do
    with %{} = info <- owned_supplier_info(socket, form.uuid) || {:error, :save_failed},
         {:ok, custom} <- Catalogue.cast_supplier_field_values(form.custom),
         attrs =
           form.draft
           |> supplier_column_attrs()
           |> Map.drop(["unit_cost", "currency"])
           |> Map.put("metadata", Catalogue.put_supplier_field_values(info.metadata, custom)),
         {:ok, updated} <- ItemSupplierInfos.update(info, attrs, actor_opts(socket)),
         {:ok, _} <- apply_cost_change(updated, form.draft, actor_opts(socket)) do
      {:noreply, close_supplier_form(socket, "Supplier updated.")}
    else
      {:error, reason} -> {:noreply, supplier_form_error(socket, form, reason)}
      _ -> {:noreply, supplier_form_error(socket, form, :save_failed)}
    end
  end

  defp require_supplier(""), do: {:error, :supplier_required}
  defp require_supplier(nil), do: {:error, :supplier_required}
  defp require_supplier(_uuid), do: :ok

  defp supplier_column_attrs(draft) do
    ~w(supplier_sku unit_cost currency lead_time_days min_order_qty)
    |> Map.new(&{&1, Map.get(draft, &1)})
    |> Map.update!("currency", &normalize_currency/1)
  end

  # `unit_cost` is a BUILT-IN entities field: cast it through the same
  # pipeline an admin-defined field uses, so the value reaching the
  # NUMERIC(14,4) column is an exact Decimal rather than whatever the
  # browser submitted. Returns nil when cleared.
  defp cast_unit_cost(draft) do
    case Catalogue.cast_supplier_builtin("unit_cost", Map.get(draft, "unit_cost")) do
      {:ok, cost} -> {:ok, cost}
      # Named so the modal says "Unit cost must be a number" rather than
      # the generic extra-fields message.
      {:error, _reason} -> {:error, :invalid_cost}
    end
  end

  # The input is uppercase by CSS only — the submitted value keeps
  # whatever case was typed, and the schema's ^[A-Z]{3}$ would reject it.
  defp normalize_currency(nil), do: nil

  defp normalize_currency(value) when is_binary(value),
    do: value |> String.trim() |> String.upcase()

  defp normalize_currency(value), do: value

  # A price CHANGE on a row that already had one is a revision, not an
  # overwrite: `revise_unit_cost/3` closes the current row and appends a
  # successor, which is what feeds the History dialog. Setting a price
  # for the first time (or clearing it) is an ordinary column write and
  # rides the update above.
  defp apply_cost_change(info, draft, opts) do
    currency = draft |> Map.get("currency") |> normalize_currency() |> blank_to_nil()

    # Cast through the entities decimal field, not Decimal.parse/1
    # directly: the field carries the scale and the `min: 0` bound, and
    # this is the one place a price enters the system from a form.
    case cast_unit_cost(draft) do
      {:ok, nil} ->
        ItemSupplierInfos.update(info, %{"unit_cost" => nil, "currency" => currency}, opts)

      {:ok, cost} when is_nil(info.unit_cost) ->
        ItemSupplierInfos.update(info, %{"unit_cost" => cost, "currency" => currency}, opts)

      {:ok, cost} ->
        ItemSupplierInfos.revise_unit_cost(info, cost, Keyword.put(opts, :currency, currency))

      {:error, _reason} ->
        {:error, :invalid_cost}
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp close_supplier_form(socket, message) do
    socket
    |> assign(:supplier_form, nil)
    |> assign_supplier_infos(socket.assigns.item.uuid)
    |> put_flash(:info, Gettext.gettext(PhoenixKitCatalogue.Gettext, message))
  end

  defp supplier_form_error(socket, form, reason) do
    assign(socket, :supplier_form, %{form | error: supplier_error_message(reason)})
  end

  defp supplier_error_message(:supplier_required),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Please select a supplier.")

  defp supplier_error_message(:unknown_field),
    do:
      Gettext.gettext(
        PhoenixKitCatalogue.Gettext,
        "A field was removed while this was open. Close and reopen the form."
      )

  defp supplier_error_message(:invalid_value),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "One of the extra fields has invalid input.")

  defp supplier_error_message(:already_linked),
    do:
      Gettext.gettext(
        PhoenixKitCatalogue.Gettext,
        "This supplier is already on the item. Edit the existing row instead."
      )

  defp supplier_error_message(:invalid_cost),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Unit cost must be a number.")

  defp supplier_error_message(:entities_disabled),
    do:
      Gettext.gettext(
        PhoenixKitCatalogue.Gettext,
        "Extra fields need the Entities module, which is turned off."
      )

  defp supplier_error_message(_other),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Could not save the supplier.")

  # ── Supplier field editor ────────────────────────────────────────────

  defp merge_field_params(editor, params) do
    type =
      if editor.mode == :new,
        do: validate_field_type(Map.get(params, "type", editor.type), editor.type),
        else: editor.type

    choices =
      cond do
        type != "select" -> []
        # Switching TO select seeds two empty inputs so the purpose is
        # visible without another click.
        editor.type != "select" -> ["", ""]
        true -> params |> Map.get("choices", editor.choices) |> List.wrap()
      end

    %{
      editor
      | label: Map.get(params, "label", editor.label),
        type: type,
        choices: choices,
        error: nil
    }
  end

  defp validate_field_type(candidate, fallback) do
    if candidate in Catalogue.supplier_field_types(), do: candidate, else: fallback
  end

  defp save_supplier_field(socket, editor) do
    label = String.trim(editor.label)

    result =
      case editor.mode do
        :new ->
          Catalogue.add_supplier_field(
            %{label: label, type: editor.type, options: editor.choices},
            actor_opts(socket)
          )

        :edit ->
          attrs =
            if editor.type == "select",
              do: %{label: label, options: editor.choices},
              else: %{label: label}

          Catalogue.update_supplier_field(editor.key, attrs, actor_opts(socket))
      end

    case result do
      {:ok, _} ->
        {:noreply,
         assign(socket,
           supplier_field_editor: nil,
           supplier_fields: load_supplier_fields()
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket, :supplier_field_editor, %{
           editor
           | error: supplier_field_error(reason)
         })}
    end
  end

  defp supplier_field_error(:label_required),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Name is required.")

  defp supplier_field_error(:options_required),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Add at least one choice.")

  defp supplier_field_error(:duplicate_key),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "A field with this name already exists.")

  defp supplier_field_error(:entities_disabled),
    do:
      Gettext.gettext(
        PhoenixKitCatalogue.Gettext,
        "Extra fields need the Entities module, which is turned off."
      )

  defp supplier_field_error(_other),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Failed to save the field.")

  defp supplier_field_type_label("text"),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Text")

  defp supplier_field_type_label("textarea"),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Text area")

  defp supplier_field_type_label("number"),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Number")

  defp supplier_field_type_label("boolean"),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Yes / No")

  defp supplier_field_type_label("date"),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Date")

  defp supplier_field_type_label("select"),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Select")

  defp supplier_field_type_label(type), do: type

  defp supplier_field_type_options do
    Enum.map(Catalogue.supplier_field_types(), &{supplier_field_type_label(&1), &1})
  end

  # Read-only rendering of a stored value for the suppliers table. Booleans
  # and dates arrive as the JSON scalars entities cast them to.
  defp supplier_field_display(info, field) do
    case Catalogue.supplier_field_values(info)[field["key"]] do
      nil -> "—"
      "" -> "—"
      true -> Gettext.gettext(PhoenixKitCatalogue.Gettext, "Yes")
      false -> Gettext.gettext(PhoenixKitCatalogue.Gettext, "No")
      value when is_list(value) -> Enum.join(value, ", ")
      value -> format_field_value(value)
    end
  end

  # Entities' `number` type casts through Float.parse/1, so a whole number
  # comes back as 24.0. Show it the way it was typed.
  defp format_field_value(value) when is_float(value) do
    if value == Float.round(value),
      do: value |> trunc() |> Integer.to_string(),
      else: Float.to_string(value)
  end

  defp format_field_value(value), do: to_string(value)

  # ── Attachments handle_info (delegated to Attachments module) ────

  # {:ai_translation, ...} events folded into the form by `use ...AITranslate.Embed`.
  @impl true
  def handle_info({:media_selected, file_uuids}, socket),
    do: Attachments.handle_media_selected(socket, file_uuids)

  def handle_info({:media_selector_closed}, socket),
    do: {:noreply, Attachments.close_media_selector(socket)}

  # The comment composer's rich-text editor reports its content to the
  # HOST via a process message — a LiveComponent has no handle_info of its
  # own — so without this hop "Post comment" silently no-ops. Resolved at
  # runtime because comments is a soft dep here; `use …Comments.Embed`
  # would need a compile-time dependency the catalogue does not declare.
  # Posting a comment must show up under the supplier without a page
  # reload. CommentsComponent sends this to its HOST on create/delete, and
  # the same shape arrives over PubSub when someone else comments on one
  # of this item's supplier threads — one contract covers both. Total on
  # purpose: a late broadcast for a thread that just left the item must
  # not crash the form.
  def handle_info({:comments_updated, _payload}, socket) do
    {:noreply, refresh_comment_previews(socket)}
  end

  def handle_info({:leaf_changed, _payload} = msg, socket) do
    case Code.ensure_loaded(PhoenixKitComments.Web.CommentsComponent) do
      {:module, module} ->
        case module.forward_leaf_event(msg, socket) do
          {:noreply, _socket} = handled -> handled
          # Not a comments editor — this LV has no other Leaf editor, so
          # there is nothing else to route it to.
          :pass -> {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:pdf_search_modal_closed}, socket),
    do: {:noreply, assign(socket, :show_pdf_search, false)}

  # ── Catalogue PubSub: writes from other sessions ──────────────────
  # Only state the form does NOT own is refreshed — the changeset, the
  # staged attribute sets, the rules picker and the featured-image
  # pointer are the user's unsaved input and are never touched here.

  # A supplier row of THIS item changed elsewhere (add / edit / remove /
  # primary flip / price revision — ItemSupplierInfos broadcasts all
  # five). The payload carries the ROW uuid: resolve it through the
  # context and match on item_uuid, so other items' rows are ignored.
  def handle_info(
        {:catalogue_data_changed, :item_supplier_info, uuid, _parent},
        %{assigns: %{item: %{uuid: item_uuid}}} = socket
      )
      when is_binary(uuid) and is_binary(item_uuid) do
    case Catalogue.get_supplier_info(uuid) do
      %{item_uuid: ^item_uuid} -> {:noreply, refresh_supplier_state(socket)}
      _ -> {:noreply, socket}
    end
  end

  # A supplier was renamed / removed: the rows show names from
  # `all_suppliers`, loaded once at mount.
  def handle_info({:catalogue_data_changed, :supplier, _uuid, _parent}, socket) do
    {:noreply, assign(socket, :all_suppliers, Suppliers.list_all())}
  end

  # This item changed elsewhere. What the form does not own and reads
  # from the DB is the files grid (an upload / removal in another tab —
  # Attachments announces the item); the item's own fields stay as the
  # user typed them.
  def handle_info(
        {:catalogue_data_changed, :item, uuid, _parent},
        %{assigns: %{item: %{uuid: item_uuid}}} = socket
      )
      when is_binary(uuid) and uuid == item_uuid do
    {:noreply, Attachments.refresh_files(socket)}
  end

  # A category came or went in this catalogue: refresh the select options
  # (the chosen value lives in the changeset and is left alone).
  def handle_info(
        {:catalogue_data_changed, :category, _uuid, parent},
        %{assigns: %{catalogue_uuid: catalogue_uuid}} = socket
      )
      when is_nil(catalogue_uuid) or parent == catalogue_uuid or is_nil(parent) do
    {:noreply, refresh_category_options(socket)}
  end

  def handle_info({:catalogue_data_changed, _kind, _uuid, _parent}, socket),
    do: {:noreply, socket}

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

  defp save_item(socket, :new, params, mode) do
    params =
      params
      |> Map.put_new("catalogue_uuid", socket.assigns.catalogue_uuid)
      |> put_manufacturer_source(socket.assigns.manufacturers)

    with {:ok, item} <- Catalogue.create_item(params, actor_opts(socket)),
         {:ok, _rules} <- maybe_put_rules(socket, item),
         :ok <- Attachments.maybe_rename_pending_folder(socket, item) do
      apply_attribute_assignment(socket, item)

      # "Save" (stay) on a new item lands on its edit form — the record
      # exists now, so staying means continuing to edit it. The original
      # return_to rides along so the eventual exit still goes home.
      target =
        case mode do
          :stay -> Paths.item_edit(item.uuid) <> return_to_suffix(socket)
          :exit -> redirect_target(socket, item)
        end

      {:noreply,
       socket
       |> put_flash(:info, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Item created."))
       |> push_navigate(to: target)}
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

  defp save_item(socket, :edit, params, mode) do
    # If item had a different primary language, rekey data to global primary on save
    params =
      if socket.assigns[:needs_primary_translation] && params["data"] do
        global_primary = socket.assigns.primary_language
        rekeyed = Multilang.rekey_primary(params["data"], global_primary)
        Map.put(params, "data", rekeyed)
      else
        params
      end

    params = put_manufacturer_source(params, socket.assigns.manufacturers)

    with {:ok, item} <- Catalogue.update_item(socket.assigns.item, params, actor_opts(socket)),
         {:ok, _rules} <- maybe_put_rules(socket, item) do
      apply_attribute_assignment(socket, item)

      socket =
        put_flash(socket, :info, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Item updated."))

      case mode do
        :stay -> {:noreply, refresh_after_edit(socket, item)}
        :exit -> {:noreply, push_navigate(socket, to: redirect_target(socket, item))}
      end
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

  # The clicked submit button ships its name/value with the form params.
  # Anything other than the explicit "stay" (absent, forged, or stale)
  # falls back to the exit behavior — same as before the split.
  defp save_mode(%{"save_action" => "stay"}), do: :stay
  defp save_mode(_params), do: :exit

  # ── Attribute group selection ───────────────────────────────────

  # {label, value} pairs for the kit <.select> (L029 conversion).
  #
  # The suffix marks the EXCEPTION, not the norm. A CRM company is what a
  # supplier normally is now that the catalogue's own directory is gone,
  # so tagging every one of them "(CRM)" labelled the entire list and said
  # nothing. What is worth flagging is a row that behaves differently:
  #
  #   * a CONTACT is a person, not a company — it carries no company page
  #     and therefore no comments (`crm_company_uuid/1` returns nil for it);
  #   * a LOCAL row came from an import, the only path that still mints
  #     them, and has no CRM record behind it at all.
  defp supplier_options(suppliers) do
    Enum.map(suppliers, fn s -> {party_option_label(s), s.uuid} end)
  end

  defp party_option_label(%{source: :crm_contact} = party),
    do: "#{party.name} (#{Gettext.gettext(PhoenixKitCatalogue.Gettext, "contact")})"

  defp party_option_label(%{source: :local} = party),
    do: "#{party.name} (#{Gettext.gettext(PhoenixKitCatalogue.Gettext, "imported")})"

  defp party_option_label(party), do: party.name

  # Suppliers already linked to this item are dropped from the Add picker:
  # a second CURRENT row for the same pair means the supplier listed twice
  # with two live prices. `create/2` refuses it too — this just stops the
  # user reaching for it in the first place. Editing an existing row still
  # sees its own supplier, since that path renders the name, not a select.
  defp available_supplier_options(suppliers, supplier_infos) do
    linked = MapSet.new(supplier_infos, & &1.supplier_uuid)

    suppliers
    |> Enum.reject(&MapSet.member?(linked, &1.uuid))
    |> supplier_options()
  end

  # Same shape for manufacturers since V179 made that reference federated too.
  defp manufacturer_options(manufacturers) do
    Enum.map(manufacturers, fn m -> {party_option_label(m), m.uuid} end)
  end

  # The picked uuid alone does not say WHICH side it came from, and storing a
  # CRM party under `manufacturer_source: "local"` would misroute the resolver
  # exactly the way the supplier card's own comment warns about. Derive the tag
  # from the entry the user actually chose, and stamp the tombstone name while
  # we have it.
  defp put_manufacturer_source(params, manufacturers) do
    case Map.get(params, "manufacturer_uuid") do
      uuid when is_binary(uuid) and uuid != "" ->
        tag_picked_manufacturer(params, Enum.find(manufacturers, &(&1.uuid == uuid)))

      _ ->
        params
        |> Map.put("manufacturer_source", "local")
        |> Map.put("manufacturer_name_snapshot", nil)
    end
  end

  defp tag_picked_manufacturer(params, nil), do: params

  defp tag_picked_manufacturer(params, picked) do
    source = if picked.source == :local, do: "local", else: "crm_company"

    params
    |> Map.put("manufacturer_source", source)
    |> Map.put("manufacturer_name_snapshot", picked.name)
  end

  defp attribute_group_options_for_select(groups) do
    Enum.map(groups, fn group ->
      label =
        if group.status == "archived" do
          "#{group.name} (#{Gettext.gettext(PhoenixKitCatalogue.Gettext, "archived")})"
        else
          group.name
        end

      {label, group.uuid}
    end)
  end

  # The Attributes tab's group select submits with the main form (name
  # "attribute_group_uuid", outside the item[...] namespace). Track the
  # selection in assigns so the read-only preview follows it live.
  defp absorb_attribute_selection(socket, params) do
    case Map.fetch(params, "attribute_group_uuid") do
      {:ok, raw} ->
        selected = if raw in [nil, ""], do: nil, else: raw

        if selected != socket.assigns.selected_attribute_group_uuid do
          socket
          |> assign(:selected_attribute_group_uuid, selected)
          |> assign_attribute_preview(selected)
        else
          socket
        end

      :error ->
        socket
    end
  end

  defp assign_attribute_state(socket, item, action) do
    socket = assign_attribute_sets_state(socket, item, action)

    if socket.assigns.sets_enabled do
      # Sets ARE the attribute system — the legacy group surface
      # doesn't load or render at all ("we shouldn't have legacy",
      # boss direction 2026-08-18). The stored assignment rows sit
      # untouched until the cutover drop migration.
      socket
      |> assign(:selected_attribute_group_uuid, nil)
      |> assign(:attribute_group_options, [])
      |> assign(:attribute_preview, nil)
    else
      assign_legacy_attribute_state(socket, item, action)
    end
  end

  defp assign_legacy_attribute_state(socket, item, action) do
    selected =
      if action == :edit and item.uuid,
        do: Catalogue.get_item_attribute_group_uuid(item.uuid),
        else: nil

    groups = Catalogue.list_attribute_groups(status: "active")

    # The stale-select rule: an archived group the item already holds
    # stays in the options (and keeps rendering) — it just can't be
    # newly chosen once deselected.
    groups =
      if selected && not Enum.any?(groups, &(&1.uuid == selected)) do
        case Catalogue.get_attribute_group(selected) do
          nil -> groups
          archived -> groups ++ [archived]
        end
      else
        groups
      end

    socket
    |> assign(:selected_attribute_group_uuid, selected)
    |> assign(:attribute_group_options, Catalogue.localize(groups, preview_lang(socket)))
    |> assign_attribute_preview(selected)
  end

  # SETS (2026-08-18 rework): the staged multi-set selection. Same
  # applied-on-save semantics as the legacy group select — attach/detach
  # /reorder live in assigns until the item saves, so Cancel abandons
  # everything and :new items work identically.
  defp assign_attribute_sets_state(socket, item, action) do
    if Catalogue.attribute_sets_enabled?() do
      attachments =
        if action == :edit and item.uuid,
          do: Catalogue.list_attribute_set_attachments(item.uuid),
          else: []

      socket =
        socket
        |> assign(:sets_enabled, true)
        |> assign(:available_sets, Catalogue.list_attribute_sets(lang: preview_lang(socket)))
        |> assign(:staged_set_uuids, Enum.map(attachments, & &1.set_uuid))
        |> assign_set_previews()

      # Per-set value selection (boss's two modes, 2026-08-19): the
      # checked value KEYS per set, staged like everything else on this
      # tab. Hydrated AFTER previews so stored slugs intersect with the
      # set's CURRENT values — a value deleted after being ticked must
      # not ghost the mode hint into a state the user can't untick
      # (panel finding).
      selections =
        Map.new(attachments, fn a ->
          {a.set_uuid, stored_selection(a, socket.assigns.set_previews[a.set_uuid])}
        end)

      socket
      |> assign(:staged_selections, selections)
    else
      socket
      |> assign(:sets_enabled, false)
      |> assign(:available_sets, [])
      |> assign(:staged_set_uuids, [])
      |> assign(:staged_selections, %{})
      |> assign(:set_previews, %{})
    end
  end

  defp assign_set_previews(socket) do
    previews =
      Map.new(socket.assigns.staged_set_uuids, fn uuid ->
        preview = Catalogue.resolve_attribute_set(uuid, lang: preview_lang(socket))
        {uuid, put_thumbs(preview)}
      end)

    assign(socket, :set_previews, previews)
  end

  # Precomputed once per preview build: the chip loop reads the thumb
  # twice per value (`:if` + `src`), and value_thumb/2 walks the
  # field list each call.
  defp put_thumbs(nil), do: nil

  defp put_thumbs(preview) do
    Map.put(preview, :thumbs, Map.new(preview.values, &{&1.key, value_thumb(preview, &1)}))
  end

  # Ghost intersection lives in ONE place — the context's
  # `valid_attribute_set_selection/2` — this just MapSets the result
  # for the staging assigns.
  defp stored_selection(attachment, preview) do
    attachment.data["selected_value_slugs"]
    |> Catalogue.valid_attribute_set_selection(preview)
    |> MapSet.new()
  end

  defp selection_for(assigns, set_uuid) do
    Map.get(assigns.staged_selections, set_uuid, MapSet.new())
  end

  # First image-type extra with a value — the chip's swatch thumbnail.
  # UUID-guarded before URLSigner (same guard as entities' FieldInput):
  # a type-swapped extra field can leave arbitrary text under an
  # image-typed key, and that must degrade to no thumb, never reach the
  # signed-URL path builder (panel finding, 2026-08-19 review).
  defp value_thumb(preview, value) do
    preview[:fields]
    |> List.wrap()
    |> Enum.filter(&(&1.type == "image"))
    |> Enum.find_value(fn field -> valid_thumb_uuid(value.extras[field.key]) end)
  end

  defp valid_thumb_uuid(uuid) when is_binary(uuid) do
    if match?({:ok, _}, Ecto.UUID.cast(uuid)), do: uuid, else: nil
  end

  defp valid_thumb_uuid(_), do: nil

  # Non-media extras as a tooltip ("Price per liter: 12.5 · Finish:
  # Gloss") — nil when the value carries none, so no empty title attr.
  defp value_extras_summary(preview, value) do
    summary =
      preview[:fields]
      |> List.wrap()
      |> Enum.reject(&(&1.type in ["image", "video"]))
      |> Enum.map(fn field ->
        case value.extras[field.key] do
          nil -> nil
          "" -> nil
          v -> "#{field.label}: #{v}"
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    if summary == "", do: nil, else: summary
  end

  defp staged_set_name(assigns, uuid) do
    case Enum.find(assigns.available_sets, &(&1.uuid == uuid)) do
      %{display_name: name} -> name
      _ -> Gettext.gettext(PhoenixKitCatalogue.Gettext, "Unknown set")
    end
  end

  defp attachable_set_options(assigns) do
    assigns.available_sets
    |> Enum.reject(&(&1.uuid in assigns.staged_set_uuids))
    |> Enum.map(&{&1.display_name, &1.uuid})
  end

  # The Attributes tab badge: staged sets once the rework is live,
  # falling back to the legacy group's attribute count.
  defp attribute_tab_count(assigns) do
    cond do
      assigns.sets_enabled and assigns.staged_set_uuids != [] ->
        length(assigns.staged_set_uuids)

      match?(%{}, assigns.attribute_preview) ->
        length(assigns.attribute_preview.attributes)

      true ->
        nil
    end
  end

  defp assign_attribute_preview(socket, selected) do
    assign(socket, :attribute_preview, Catalogue.resolved_group(selected, preview_lang(socket)))
  end

  defp preview_lang(socket) do
    socket.assigns[:current_locale] || socket.assigns[:primary_language] || "en"
  end

  # Persisting the assignment is best-effort alongside the item save:
  # the select only offers valid groups, so a rejected value can only be
  # a forged payload — skip it rather than fail the save.
  defp apply_attribute_assignment(socket, item) do
    # With sets live the legacy select never renders, so the loaded-nil
    # selection must NOT be written back — it would clear the item's
    # stored legacy assignment, which stays frozen until cutover.
    unless socket.assigns[:sets_enabled] do
      case Catalogue.set_item_attribute_group(
             item,
             socket.assigns.selected_attribute_group_uuid,
             actor_opts(socket)
           ) do
        {:error, reason} ->
          Logger.warning("ItemFormLive attribute assignment skipped: #{inspect(reason)}")
          :ok

        _ ->
          :ok
      end
    end

    apply_attribute_sets(socket, item)
  end

  # Diffs the staged set selection against the stored attachments —
  # same best-effort doctrine as the group assignment above: the picker
  # only offers real sets, so a failure here (set deleted mid-edit) is
  # logged and skipped, never fails the item save.
  defp apply_attribute_sets(socket, item) do
    if socket.assigns[:sets_enabled] do
      staged = socket.assigns.staged_set_uuids
      current = Enum.map(Catalogue.list_attribute_set_attachments(item.uuid), & &1.set_uuid)

      Enum.each(current -- staged, fn uuid ->
        Catalogue.detach_attribute_set(item.uuid, uuid, actor_opts(socket))
      end)

      Enum.each(staged -- current, &attach_staged_set(socket, item.uuid, &1))

      Catalogue.reorder_attribute_sets(item.uuid, staged, actor_opts(socket))

      # Selections write AFTER attach so new attachments exist; the
      # context validates keys against the set's current values.
      Enum.each(staged, fn set_uuid ->
        slugs =
          socket.assigns.staged_selections
          |> Map.get(set_uuid, MapSet.new())
          |> MapSet.to_list()

        Catalogue.set_attribute_set_selection(item.uuid, set_uuid, slugs, actor_opts(socket))
      end)
    end

    :ok
  end

  defp attach_staged_set(socket, item_uuid, set_uuid) do
    case Catalogue.attach_attribute_set(item_uuid, set_uuid, actor_opts(socket)) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("ItemFormLive set attach skipped: #{inspect(reason)}")
    end
  end

  defp return_to_suffix(socket) do
    case socket.assigns[:return_to] do
      nil -> ""
      rt -> "?" <> URI.encode_query([{"return_to", rt}])
    end
  end

  # In-place refresh after a stay-save: no remount, so the current tab,
  # language, scroll position, and live attachment state all survive.
  # meta_state and working_rules were just persisted verbatim, so they
  # stay as-is; only the item-derived assigns need re-deriving. A
  # successful save keys data to the global primary, so the imported-
  # language warning clears.
  defp refresh_after_edit(socket, item) do
    item =
      item
      |> PhoenixKit.RepoHelper.repo().preload([:category])
      |> normalize_display_decimals()

    socket
    |> assign(:item, item)
    |> assign(
      :page_title,
      Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit %{name}", name: item.name)
    )
    |> assign(:needs_primary_translation, false)
    |> assign_changeset(Catalogue.change_item(item))
  end

  defp redirect_target(socket, item) do
    cond do
      socket.assigns[:return_to] ->
        socket.assigns.return_to

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
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={@page_title}
      page_section={@parent_catalogue_name}
      page_section_path={@catalogue_uuid && Paths.catalogue_detail(@catalogue_uuid)}
      page_subtitle={
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
      current_path={assigns[:url_path] || (if @catalogue_uuid, do: Paths.catalogue_detail(@catalogue_uuid), else: Paths.index())}
      current_locale={assigns[:current_locale]}
    >
      <div class="flex flex-col mx-auto max-w-2xl px-4 py-8 gap-6">

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
        <.button type="button" phx-click="open_pdf_search" size="sm">
          <.icon name="hero-magnifying-glass" class="w-4 h-4" />
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search PDFs")}
        </.button>
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
          <.icon name="hero-swatch" class="w-4 h-4 mr-1" />
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Attributes")}
          <span :if={attribute_tab_count(assigns)} class="badge badge-sm badge-ghost ml-2">
            {attribute_tab_count(assigns)}
          </span>
        </button>
        <button
          type="button"
          phx-click="switch_tab"
          phx-value-tab="sourcing"
          class={"tab #{if @current_tab == :sourcing, do: "tab-active"}"}
        >
          <.icon name="hero-building-storefront" class="w-4 h-4 mr-1" />
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Suppliers and Manufacturer")}
          <span :if={@action == :edit and @supplier_infos != []} class="badge badge-sm badge-ghost ml-2">
            {length(@supplier_infos)}
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
        lock_file_type
        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Select Featured Image")}
        selected_uuids={@media_selected_uuids}
        scope_folder_id={@files_folder_uuid}
        phoenix_kit_current_user={assigns[:phoenix_kit_current_user]}
      />

      <.form for={@form} action="#" phx-change="validate" phx-submit="save">
        <div class={"card bg-base-100 shadow-lg #{if @current_tab != :details, do: "hidden"}"}>
          <%!-- Bundled tabs + AI row (phoenix_kit_ai's canonical placement). --%>
          <.ai_multilang_tabs
            multilang_enabled={@multilang_enabled}
            language_tabs={@language_tabs}
            current_lang={@current_lang}
            ai_translate={ai_translate_config(assigns)}
          />

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
                <div class="fieldset">
                  <.input
                    field={@form[:base_price]}
                    type="number"
                    label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Base Price")}
                    step="0.01"
                    min="0"
                    placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "0.00")}
                  />
                  <span class="fieldset-label text-base-content/50 mt-1">
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
                <div class="fieldset">
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
                  <span class="fieldset-label text-base-content/50 mt-1">
                    {Gettext.gettext(
                      PhoenixKitCatalogue.Gettext,
                      "Leave blank to inherit the catalogue's markup. Set (including 0) to override just this item."
                    )}
                  </span>
                </div>
                <div class="fieldset">
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
                  <span class="fieldset-label text-base-content/50 mt-1">
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
                <div class="fieldset">
                  <.input
                    field={@form[:default_value]}
                    type="number"
                    label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Default Value")}
                    step="0.0001"
                    min="0"
                    placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "e.g., 5")}
                  />
                  <span class="fieldset-label text-base-content/50 mt-1">
                    {Gettext.gettext(
                      PhoenixKitCatalogue.Gettext,
                      "Used for any selected catalogue that doesn't have its own value. If no catalogues are selected, this is the item's standalone fee (e.g. $50 flat)."
                    )}
                  </span>
                </div>
                <div class="fieldset">
                  <.select
                    field={@form[:default_unit]}
                    label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Default Unit")}
                    class="transition-colors focus-within:select-primary"
                    options={[
                      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Percent (%)"), "percent"},
                      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Flat amount"), "flat"}
                    ]}
                  />
                  <span class="fieldset-label text-base-content/50 mt-1">
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

              <div class="grid grid-cols-1 gap-4">
                <.select
                  field={@form[:category_uuid]}
                  label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category")}
                  class="transition-colors focus-within:select-primary"
                  prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "-- No category --")}
                  options={Enum.map(@categories, &{&1.name, &1.uuid})}
                />
              </div>
            </div>


            <div class="fieldset">
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
              <span class="fieldset-label text-base-content/50 mt-1">
                {Gettext.gettext(
                  PhoenixKitCatalogue.Gettext,
                  "Discontinued items are kept for reference but hidden from active listings."
                )}
              </span>
            </div>
          </div>
        </div>

        <%!-- Attributes tab — the reusable attribute-group system. The
             select submits with the main form (assignment persists on
             save); the preview follows the selection live via validate.
             The legacy hand-typed metadata survives underneath in a
             collapsed editor, rendered ONLY when this item actually has
             old values — never deleted, so a host's AI (or a human) can
             read them, build groups, and clear them at their own pace. --%>
        <div class={"flex flex-col gap-4 #{if @current_tab != :metadata, do: "hidden"}"}>
          <%!-- Attribute SETS (2026-08-18 rework) — the primary picker
               once entities is enabled. Staged in assigns, applied on
               save; the select carries its own phx-change (nested forms
               are invalid — this whole tab lives inside the main form). --%>
          <div :if={@sets_enabled} class="card bg-base-100 shadow-lg">
            <div class="card-body flex flex-col gap-4">
              <div class="flex items-center justify-between gap-4">
                <div class="flex flex-col gap-0.5 min-w-0">
                  <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
                    <.icon name="hero-swatch" class="w-4 h-4" />
                    {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Attribute sets")}
                  </h2>
                  <p class="text-xs text-base-content/50">
                    {Gettext.gettext(
                      PhoenixKitCatalogue.Gettext,
                      "Attach any number of sets — Ikea colors, HomeDepot trims. Applied when you save."
                    )}
                  </p>
                </div>
                <.link navigate={Paths.attribute_groups()} class="btn btn-ghost btn-xs shrink-0">
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Manage sets")}
                </.link>
              </div>

              <div
                :if={@staged_set_uuids != []}
                id="staged-set-rows"
                phx-hook="SortableGrid"
                data-sortable="true"
                data-sortable-event="reorder_staged_sets"
                data-sortable-items=".sortable-item"
                data-sortable-handle=".pk-drag-handle"
                class="flex flex-col gap-2"
              >
                <div
                  :for={uuid <- @staged_set_uuids}
                  class="sortable-item rounded-lg border border-base-content/10 bg-base-content/5 p-3 flex flex-col gap-2"
                  data-id={uuid}
                >
                  <% preview = @set_previews[uuid] %>
                  <div class="flex items-center gap-2">
                    <span class="pk-drag-handle cursor-grab inline-flex items-center text-base-content/40 hover:text-base-content/70">
                      <.icon name="hero-bars-3" class="w-4 h-4" />
                    </span>
                    <span class="font-medium text-sm flex-1 min-w-0 truncate">
                      {(preview && preview.name) || staged_set_name(assigns, uuid)}
                    </span>
                    <span :if={preview} class="badge badge-sm badge-ghost shrink-0">
                      {if preview.kind == :fixed,
                        do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Fixed value"),
                        else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Multiple values")}
                    </span>
                    <span :if={is_nil(preview)} class="badge badge-sm badge-warning shrink-0">
                      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "unavailable")}
                    </span>
                    <button
                      type="button"
                      phx-click="detach_set"
                      phx-value-uuid={uuid}
                      class="btn btn-ghost btn-xs px-1 text-base-content/40 hover:text-error shrink-0"
                      title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Detach set")}
                    >
                      <.icon name="hero-x-mark" class="w-4 h-4" />
                    </button>
                  </div>
                  <%!-- Value chips are CHECKBOXES (boss's two modes):
                       tick one — this exact item; tick several — the
                       options it comes in; tick none — the whole set
                       applies. The checkboxes carry no name, so the
                       main form never submits them; selection is
                       staged and applied on save. Swatch thumbnails
                       and an extras tooltip surface the set's data. --%>
                  <div :if={preview} class="flex flex-col gap-1.5 pl-6">
                    <div class="flex flex-wrap items-center gap-1.5">
                      <%!-- The highlight is PURE CSS off :checked (has-[]
                           variant) so ticking feels instant — no server
                           round trip gates the visual. The checkbox's
                           form attribute points at a non-existent id,
                           disassociating it from the surrounding item
                           form: without that, every tick ALSO bubbled a
                           change event into the form's phx-change and
                           ran the full validate cycle (the actual lag).
                           phx-click still stages the selection server-
                           side for save; the patch re-asserts checked,
                           so a rejected toggle snaps back. --%>
                      <label
                        :for={value <- preview.values}
                        class="flex items-center gap-1.5 rounded-full border border-base-content/20 bg-base-100 hover:border-base-content/40 has-[:checked]:border-primary has-[:checked]:bg-primary/10 pl-1.5 pr-2.5 py-0.5 cursor-pointer select-none transition-colors"
                        title={value_extras_summary(preview, value)}
                      >
                        <input
                          type="checkbox"
                          form="__detached-from-item-form__"
                          checked={MapSet.member?(selection_for(assigns, uuid), value.key)}
                          phx-click="toggle_value_selection"
                          phx-value-set={uuid}
                          phx-value-key={value.key}
                          class="checkbox checkbox-xs"
                        />
                        <img
                          :if={preview.thumbs[value.key]}
                          src={URLSigner.signed_url(preview.thumbs[value.key], "thumbnail")}
                          alt=""
                          class="w-5 h-5 rounded object-cover"
                        />
                        <span class="text-sm">{value.label}</span>
                      </label>
                      <span :if={preview.values == []} class="text-xs text-base-content/40">
                        {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No values defined yet.")}
                      </span>
                    </div>
                  </div>
                </div>
              </div>

              <%!-- id carries the staged count: after a pick the select
                   re-mounts fresh (a focused select is never patched, so
                   without this it would keep showing the picked option). --%>
              <.select
                :if={attachable_set_options(assigns) != []}
                id={"attach-set-select-#{length(@staged_set_uuids)}"}
                name="attach_set_uuid"
                value={nil}
                phx-change="attach_set"
                prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Attach a set...")}
                options={attachable_set_options(assigns)}
                class="w-full"
              />
              <p
                :if={@available_sets == []}
                class="text-sm text-base-content/50"
              >
                {Gettext.gettext(
                  PhoenixKitCatalogue.Gettext,
                  "No sets exist yet — create one under Manage sets."
                )}
              </p>
            </div>
          </div>

          <%!-- Legacy attribute group — only on hosts WITHOUT the
               entities module; with sets live the legacy surface is
               gone entirely (assignments auto-migrated). --%>
          <div :if={!@sets_enabled} class="card bg-base-100 shadow-lg">
            <div class="card-body flex flex-col gap-4">
              <div class="flex items-center justify-between gap-4">
                <div class="flex flex-col gap-0.5 min-w-0">
                  <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
                    <.icon name="hero-swatch" class="w-4 h-4" />
                    {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Attribute group")}
                  </h2>
                  <p class="text-xs text-base-content/50">
                    {Gettext.gettext(
                      PhoenixKitCatalogue.Gettext,
                      "Pick a group to give this item its options — colors, trims, surfaces. Applied when you save."
                    )}
                  </p>
                </div>
                <.link
                  navigate={Paths.attribute_groups()}
                  class="btn btn-ghost btn-xs shrink-0"
                >
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Manage groups")}
                </.link>
              </div>

              <.select
                name="attribute_group_uuid"
                value={@selected_attribute_group_uuid}
                prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "— No attribute group —")}
                options={attribute_group_options_for_select(@attribute_group_options)}
                class="w-full transition-colors focus-within:select-primary"
              />

              <%!-- Read-only preview of what the item inherits. Label in
                   its own fixed column so long value lists wrap under the
                   chips, not under the label; the default is marked with
                   the same star the group editor uses. --%>
              <%!-- Two-column grid: the label column is `auto`, sized by the
                   LONGEST attribute name — no fixed-width void after short
                   names, and every row stays aligned. --%>
              <div
                :if={@attribute_preview}
                class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-3 items-start"
              >
                <%= for attribute <- @attribute_preview.attributes do %>
                  <span class="text-sm font-medium pt-0.5 max-w-48 truncate" title={attribute.name}>{attribute.name}</span>
                  <div class="flex flex-wrap items-center gap-1.5 min-w-0">
                    <span
                      :for={value <- attribute.values}
                      class="badge badge-sm badge-ghost gap-1"
                    >
                      <.icon
                        :if={value.default?}
                        name="hero-star-solid"
                        class="w-3 h-3 text-warning shrink-0"
                      />
                      {value.value}
                    </span>
                    <span
                      :if={attribute.values == []}
                      class="text-xs text-base-content/40"
                    >
                      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No values defined yet.")}
                    </span>
                  </div>
                <% end %>
                <p
                  :if={@attribute_preview.attributes == []}
                  class="text-sm text-base-content/50 col-span-2"
                >
                  {Gettext.gettext(
                    PhoenixKitCatalogue.Gettext,
                    "This group has no attributes yet."
                  )}
                </p>
              </div>
            </div>
          </div>

          <%!-- Legacy metadata — global field list, values in
               `item.data["meta"]`. Collapsed and only rendered when old
               values exist; the inputs stay inside the main form so
               editing and clearing them still works exactly as before. --%>
          <details :if={@meta_state.attached != []} class="card bg-base-100 shadow-lg">
            <summary class="card-body py-3 cursor-pointer flex-row items-center gap-2 select-none">
              <.icon name="hero-tag" class="w-4 h-4 text-base-content/60" />
              <h3 class="font-semibold text-base">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "View old values (%{count})",
                  count: length(@meta_state.attached)
                )}
              </h3>
              <.icon name="hero-chevron-down" class="w-4 h-4 ml-auto text-base-content/40" />
            </summary>
            <.metadata_editor
              resource_type={:item}
              state={@meta_state}
              id_prefix="item"
              description={
                Gettext.gettext(
                  PhoenixKitCatalogue.Gettext,
                  "Hand-typed metadata from before attribute groups. Kept so nothing is lost — move what matters into a group, then clear these."
                )
              }
            />
          </details>
        </div>

        <%!-- Featured image — on the Files tab, matching the catalogue
             form (deliberate consistency call, 2026-08-15). Opens the
             scoped picker in single+image mode; the picker both browses
             this item's images and accepts new uploads (which get
             dropped into the item's folder automatically). --%>

        <%!-- Suppliers and Manufacturer panel. Kept in the DOM and toggled by
             `hidden` like the other panels, so the inline supplier draft form
             does not lose what has been typed into it when tabs are flipped.
             The price-history dialog lives in here too: left in the Details
             panel it would be hidden along with it. --%>
        <div class={"card bg-base-100 shadow-lg #{if @current_tab != :sourcing, do: "hidden"}"}>
          <div class="card-body flex flex-col gap-5">
            <div class="flex flex-col gap-3">
              <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
                <.icon name="hero-building-office" class="w-4 h-4" />
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Manufacturer")}
              </h2>
              <%!-- No field label: the section title above already says it. --%>
              <.select
                field={@form[:manufacturer_uuid]}
                class="transition-colors focus-within:select-primary"
                prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "-- No manufacturer --")}
                options={manufacturer_options(@manufacturers)}
              />
            </div>

          <%!-- Suppliers card — junction-based supplier-info table.
               Only rendered for existing items (new items need a UUID first). --%>
          <div :if={@action == :edit} class="flex flex-col gap-4">
            <div class="divider my-0"></div>
            <div class="flex items-center justify-between gap-2">
              <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
                <.icon name="hero-building-storefront" class="w-4 h-4" />
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Suppliers")}
              </h2>
              <div class="flex items-center gap-2">
                <%!-- Edits the GLOBAL supplier field set, not this item.
                     Hidden when entities is off — there is nothing to
                     define without it. --%>
                <.button
                  :if={@supplier_fields_manageable}
                  type="button"
                  phx-click="open_supplier_field_manager"
                  variant="ghost"
                  size="sm"
                  title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Extra fields")}
                >
                  <.icon name="hero-adjustments-horizontal" class="w-4 h-4" />
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Fields")}
                </.button>
                <.button type="button" phx-click="open_add_supplier" size="sm">
                  <.icon name="hero-plus" class="w-4 h-4" />
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Add Supplier")}
                </.button>
              </div>
            </div>

            <%!-- The add/edit form is a modal, rendered outside the item
                 form below: nested <form> elements are invalid HTML and
                 the browser drops the inner one, which would attach the
                 supplier inputs to the item form instead. --%>

            <%!-- Supplier-info rows --%>
            <div :if={@supplier_infos == []} class="text-sm text-base-content/50 italic py-2">
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No suppliers linked yet.")}
            </div>

            <div :if={@supplier_infos != []} class="overflow-x-auto">
              <table class="table table-sm w-full">
                <thead>
                  <tr>
                    <th>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Supplier")}</th>
                    <th :if={@supplier_terms_visible}>
                      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "SKU")}
                    </th>
                    <th>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Unit Cost")}</th>
                    <th :if={@supplier_terms_visible}>
                      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Lead (d)")}
                    </th>
                    <th :if={@supplier_terms_visible}>
                      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "MOQ")}
                    </th>
                    <th :for={field <- @supplier_fields}>{field["label"]}</th>
                    <th>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Primary")}</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <%= for info <- @supplier_infos do %>
                    <% page_path = supplier_page_path(@supplier_company_links, info) %>
                    <tr class={if info.is_primary, do: "bg-primary/5", else: ""}>
                      <td class="font-medium">
                        <%!-- The name links to the party's own page when there
                             is one, the same rule the CRM side follows for item
                             names. The PATH comes from CRM rather than being
                             assembled here — a module does not build another
                             module's URLs. --%>
                        <.pk_link
                          :if={page_path}
                          navigate={page_path}
                          class="link link-hover"
                        >
                          {supplier_display_name(info, @all_suppliers)}
                        </.pk_link>
                        <span :if={is_nil(page_path)}>
                          {supplier_display_name(info, @all_suppliers)}
                        </span>
                      </td>
                      <td :if={@supplier_terms_visible} class="font-mono text-xs">
                        {info.supplier_sku || "—"}
                      </td>
                      <td>
                        <%= if info.unit_cost do %>
                          {Decimal.to_string(info.unit_cost, :normal)} {info.currency || ""}
                        <% else %>
                          —
                        <% end %>
                      </td>
                      <td :if={@supplier_terms_visible}>{info.lead_time_days || "—"}</td>
                      <td :if={@supplier_terms_visible}>
                        <%= if info.min_order_qty do %>
                          {Decimal.to_string(info.min_order_qty, :normal)}
                        <% else %>
                          —
                        <% end %>
                      </td>
                      <td :for={field <- @supplier_fields} class="text-xs">
                        {supplier_field_display(info, field)}
                      </td>
                      <td>
                        <%!-- Primary is a STATUS here; promoting is an
                             action and lives in the row menu with the
                             rest. --%>
                        <span :if={info.is_primary} class="badge badge-sm badge-primary">
                          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Primary")}
                        </span>
                        <span :if={not info.is_primary} class="text-base-content/30">—</span>
                      </td>
                      <%!-- Every row action in one ⋮ menu (core's
                           TableRowMenu — it uses position:fixed via the
                           RowMenu hook so the panel escapes the table's
                           overflow clipping, which a plain daisyUI
                           dropdown does not). --%>
                      <td class="whitespace-nowrap text-right">
                        <.table_row_menu id={"supplier-actions-#{info.uuid}"}>
                          <.table_row_menu_button
                            :if={Map.has_key?(@supplier_comment_threads, info.uuid)}
                            phx-click="open_supplier_comments"
                            phx-value-uuid={info.uuid}
                            icon="hero-chat-bubble-left-ellipsis"
                            label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Comments")}
                          />
                          <.table_row_menu_button
                            phx-click="edit_supplier_info"
                            phx-value-uuid={info.uuid}
                            icon="hero-pencil"
                            label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit")}
                          />
                          <.table_row_menu_button
                            phx-click="open_supplier_history"
                            phx-value-uuid={info.uuid}
                            icon="hero-clock"
                            label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Price History")}
                          />
                          <.table_row_menu_button
                            :if={not info.is_primary}
                            phx-click="set_primary_supplier"
                            phx-value-uuid={info.uuid}
                            icon="hero-star"
                            label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Make primary")}
                          />
                          <.table_row_menu_divider />
                          <.table_row_menu_button
                            phx-click="delete_supplier_info"
                            phx-value-uuid={info.uuid}
                            data-confirm={
                              Gettext.gettext(
                                PhoenixKitCatalogue.Gettext,
                                "Remove this supplier link?"
                              )
                            }
                            icon="hero-trash"
                            label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Remove")}
                            variant="error"
                          />
                        </.table_row_menu>
                      </td>
                    </tr>

                    <%!-- The supplier's latest comments on THIS item, inline
                         — the row's own thread, not the CRM company's. --%>
                    <tr :if={Map.has_key?(@supplier_comment_previews, info.uuid)} class="border-0">
                      <td colspan={supplier_table_colspan(assigns)} class="pt-0 pb-3">
                        <.supplier_comment_preview
                          preview={@supplier_comment_previews[info.uuid]}
                          uuid={info.uuid}
                        />
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          </div>

          <%!-- Supplier price-history modal — read-only, compact. Shows closed
               revision rows for the selected item/supplier pair. --%>
          <dialog :if={@supplier_history_open} open class="modal">
            <div class="modal-box max-w-lg">
              <h3 class="font-bold text-lg mb-4">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Price History")}
                <span :if={@supplier_history_name} class="font-normal text-base-content/60 ml-1">
                  — {@supplier_history_name}
                </span>
              </h3>
              <div :if={@supplier_history_rows == []} class="text-sm text-base-content/50 italic py-2">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No price history.")}
              </div>
              <div :if={@supplier_history_rows != []} class="overflow-x-auto">
                <table class="table table-xs w-full">
                  <thead>
                    <tr>
                      <th>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Unit Cost")}</th>
                      <th>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Currency")}</th>
                      <th>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Valid From")}</th>
                      <th>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Valid To")}</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for row <- @supplier_history_rows do %>
                      <tr class={if is_nil(row.valid_to), do: "font-medium", else: "text-base-content/60"}>
                        <td class="tabular-nums">
                          <%= if row.unit_cost do %>
                            {Decimal.to_string(row.unit_cost, :normal)}
                          <% else %>
                            —
                          <% end %>
                        </td>
                        <td>{row.currency || "—"}</td>
                        <td>{if row.valid_from, do: Date.to_string(row.valid_from), else: "—"}</td>
                        <td>
                          <%= if is_nil(row.valid_to) do %>
                            <span class="badge badge-xs badge-primary">
                              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Current")}
                            </span>
                          <% else %>
                            {Date.to_string(row.valid_to)}
                          <% end %>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
              <div class="modal-action">
                <button type="button" phx-click="close_supplier_history" class="btn btn-sm">
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Close")}
                </button>
              </div>
            </div>
            <div class="modal-backdrop" phx-click="close_supplier_history"></div>
          </dialog>
          </div>
        </div>

        <div class={"mb-4 #{if @current_tab != :files, do: "hidden"}"}>
          <.attachments_files_panel
            uploads={@uploads}
            files_state={@files_state}
            featured_image_uuid={@featured_image_uuid}
            featured_image_file={@featured_image_file}
            featured_subtitle={
              Gettext.gettext(PhoenixKitCatalogue.Gettext, "Shown in lists and detail views.")
            }
            files_hint={
              Gettext.gettext(
                PhoenixKitCatalogue.Gettext,
                "Spec sheets, drawings, photos. Any file type is accepted."
              )
            }
            remove_confirm={
              Gettext.gettext(
                PhoenixKitCatalogue.Gettext,
                "Remove this file from the item? If it's not attached to any other item, it will be moved to trash (admins can restore)."
              )
            }
            remove_title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Remove from item")}
          />
        </div>

        <%!-- Actions — sit outside the tab panels so Save works from
             any tab; the form element wraps them all. Both saves are
             disabled while uploads are mid-flight so we don't race
             the post-upload `handle_progress` write against the save
             path (would drop the just-uploaded file from the
             resource). "Save" keeps you on the form (it's also the
             Enter-key submitter, being first in the DOM); "Save &
             Exit" returns to where the form was opened from. --%>
        <div class="flex justify-end gap-3 pt-2">
          <.button
            navigate={
              @return_to ||
                if @catalogue_uuid, do: Paths.catalogue_detail(@catalogue_uuid), else: Paths.index()
            }
            variant="ghost"
          >
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

      <%!-- AI translate modal — rendered OUTSIDE the form (its endpoint/
           prompt selectors are their own <form>; nested forms are invalid). --%>
      <.ai_translate_modal ai_translate={ai_translate_config(assigns)} />

      <%!-- Supplier add/edit — one modal, two modes. OUTSIDE the item
           form for the same reason as the AI modal above. Errors render
           inside it; a page flash would land behind the backdrop. --%>
      <.modal
        :if={@supplier_form != nil}
        id="supplier-form-modal"
        show
        on_close="cancel_add_supplier"
        max_width="lg"
      >
        <:title>
          {if @supplier_form.mode == :new,
            do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Add supplier"),
            else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit supplier")}
        </:title>

        <%!-- phx-submit is load-bearing even though phx-change tracks
             every field: a form with only phx-change is external to
             LiveView, so Enter inside a text input native-submits and
             navigates away, killing the socket. --%>
        <form
          id="supplier-form"
          phx-change="supplier_info_field_change"
          phx-submit="save_supplier_info"
          class="flex flex-col gap-4"
        >
          <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
            <div class="fieldset md:col-span-2">
              <%!-- The supplier is the identity of the pair and price
                   history keys on it, so editing a row cannot re-point
                   it at a different company — remove and re-add. --%>
              <.select
                :if={@supplier_form.mode == :new}
                name="supplier_info[supplier_uuid]"
                value={@supplier_form.draft["supplier_uuid"]}
                label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Supplier")}
                prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "-- Select supplier --")}
                options={available_supplier_options(@all_suppliers, @supplier_infos)}
                class="w-full"
              />
              <div :if={@supplier_form.mode == :edit}>
                <.label class="block mb-2">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Supplier")}</.label>
                <p class="text-sm font-medium">{supplier_form_name(assigns)}</p>
              </div>
            </div>

            <%!-- The built-in supplier terms, hidden together. Each labels
                 itself through `<.label>` rather than `<.input label=...>`:
                 the two render different type sizes, and side by side in
                 this grid the rows stopped lining up. --%>
            <div :if={@supplier_terms_visible}>
              <.label for="supplier-sku" class="block mb-2">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Supplier SKU")}
              </.label>
              <.input
                type="text"
                id="supplier-sku"
                name="supplier_info[supplier_sku]"
                value={@supplier_form.draft["supplier_sku"]}
                class="w-full font-mono"
                placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "e.g., ABC-001")}
              />
            </div>

            <%!-- Price is NOT behind the terms flag: the owner asked for
                 it back specifically, and it is the one field warehouse
                 reads. The cost control comes from entities' own renderer
                 for its `decimal` type — added for this — so the value is
                 exact rather than a float. --%>
            <div class="md:col-span-2">
              <.label class="block mb-2">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Unit Cost")}</.label>
              <%!-- Deliberately raw (L029): the kit input wraps each field
                   in its own feedback div, which would break the daisyUI
                   join grouping of these two inputs. --%>
              <div class="join w-full">
                <.field_input
                  field={Catalogue.supplier_builtin_field("unit_cost")}
                  id="supplier-unit-cost"
                  name="supplier_info[unit_cost]"
                  value={@supplier_form.draft["unit_cost"]}
                  form="supplier-form"
                  size="md"
                  class="join-item flex-1"
                />
                <input
                  type="text"
                  name="supplier_info[currency]"
                  value={@supplier_form.draft["currency"]}
                  class="input join-item w-16 font-mono uppercase"
                  placeholder="EUR"
                  maxlength="3"
                />
              </div>
              <p
                :if={@supplier_form.mode == :edit}
                class="text-xs text-base-content/50 pt-1"
              >
                {Gettext.gettext(
                  PhoenixKitCatalogue.Gettext,
                  "Changing the cost closes the current price and starts a new one, kept in History."
                )}
              </p>
            </div>

            <div :if={@supplier_terms_visible}>
              <.label for="supplier-lead-time" class="block mb-2">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Lead Time (days)")}
              </.label>
              <.input
                type="number"
                id="supplier-lead-time"
                name="supplier_info[lead_time_days]"
                value={@supplier_form.draft["lead_time_days"]}
                min="0"
                class="w-full"
              />
            </div>

            <div :if={@supplier_terms_visible}>
              <.label for="supplier-moq" class="block mb-2">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Min. Order Qty")}
              </.label>
              <.input
                type="number"
                id="supplier-moq"
                name="supplier_info[min_order_qty]"
                value={@supplier_form.draft["min_order_qty"]}
                step="0.0001"
                min="0"
                class="w-full"
              />
            </div>
          </div>

          <%!-- Admin-defined fields. Entities owns the definitions; the
               control per type comes from its own renderer. --%>
          <div :if={@supplier_fields != []} class="flex flex-col gap-3">
            <div class="divider my-0 text-xs text-base-content/50">
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Extra fields")}
            </div>
            <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
              <div :for={field <- @supplier_fields} class="flex flex-col gap-1">
                <span class="label-text font-medium">{field["label"]}</span>
                <.field_input
                  field={field}
                  id={"supplier-custom-#{field["key"]}"}
                  name={"custom_fields[#{field["key"]}]"}
                  value={@supplier_form.custom[field["key"]]}
                  form="supplier-form"
                />
              </div>
            </div>
          </div>

          <p :if={@supplier_form.error} class="text-sm text-error">{@supplier_form.error}</p>
        </form>

        <:actions>
          <.button type="button" variant="ghost" phx-click="cancel_add_supplier">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Cancel")}
          </.button>
          <.button
            form="supplier-form"
            type="submit"
            phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Saving...")}
          >
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Save")}
          </.button>
        </:actions>
      </.modal>

      <%!-- Supplier comments — one thread per attached supplier, keyed on
           the row's thread uuid (see Catalogue.SupplierComments). "He
           promised a discount on this product" belongs to the item ×
           supplier row: the same company supplies other products, and its
           own thread stays on its CRM page. --%>
      <.modal
        :if={@supplier_comments != nil}
        id="supplier-comments-modal"
        show
        on_close="close_supplier_comments"
        max_width="2xl"
      >
        <:title>
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Comments")}
          <span :if={@supplier_comments.name} class="font-normal text-base-content/60 ml-1">
            — {@supplier_comments.name}
          </span>
        </:title>

        <%!-- Say what this thread is NOT, and put the company's own page one
             click away when the row has one (a local row has none). --%>
        <p class="text-xs text-base-content/50 mb-3">
          {Gettext.gettext(
            PhoenixKitCatalogue.Gettext,
            "About this supplier for this item only. The company's own comments stay on its CRM page."
          )}
          <.pk_link
            :if={crm_company_path(@supplier_comments.company_uuid)}
            navigate={crm_company_path(@supplier_comments.company_uuid)}
            class="link link-hover ml-1"
          >
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Open the company")}
          </.pk_link>
        </p>

        <.live_component
          module={PhoenixKitComments.Web.CommentsComponent}
          id={"supplier-comments-#{@supplier_comments.thread_uuid}"}
          resource_type={Catalogue.supplier_comment_resource_type()}
          resource_uuid={@supplier_comments.thread_uuid}
          current_user={assigns[:phoenix_kit_current_user]}
        />

        <:actions>
          <.button type="button" phx-click="close_supplier_comments">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Close")}
          </.button>
        </:actions>
      </.modal>

      <%!-- Supplier field manager — the GLOBAL field set. --%>
      <.modal
        :if={@supplier_field_manager}
        id="supplier-field-manager-modal"
        show
        on_close="close_supplier_field_manager"
        max_width="lg"
      >
        <:title>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Supplier extra fields")}</:title>

        <div class="flex flex-col gap-4">
          <p class="text-sm text-base-content/60">
            {Gettext.gettext(
              PhoenixKitCatalogue.Gettext,
              "Extra info every supplier row carries — incoterm, carton quantity, certification expiry. These apply to every item, not just this one."
            )}
          </p>

          <div :if={@supplier_fields != []} class="flex flex-col gap-2">
            <div
              :for={field <- @supplier_fields}
              class="rounded-lg border border-base-content/10 bg-base-content/5 p-2 flex items-center gap-2"
            >
              <span class="font-medium text-sm shrink-0">{field["label"]}</span>
              <span class="badge badge-sm badge-ghost shrink-0">
                {supplier_field_type_label(field["type"])}
              </span>
              <span
                :if={field["type"] == "select"}
                class="text-xs text-base-content/50 truncate flex-1 min-w-0"
                title={Enum.join(field["options"] || [], ", ")}
              >
                {Enum.join(field["options"] || [], ", ")}
              </span>
              <span :if={field["type"] != "select"} class="flex-1"></span>
              <.button
                type="button"
                phx-click="edit_supplier_field"
                phx-value-key={field["key"]}
                variant="ghost"
                size="xs"
                class="px-1"
                title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit field")}
              >
                <.icon name="hero-pencil" class="w-4 h-4" />
              </.button>
              <.button
                type="button"
                phx-click="request_remove_supplier_field"
                phx-value-key={field["key"]}
                variant="ghost"
                size="xs"
                class="px-1 text-base-content/40 hover:text-error"
                title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Remove field")}
              >
                <.icon name="hero-trash" class="w-4 h-4" />
              </.button>
            </div>
          </div>

          <p :if={@supplier_fields == []} class="text-sm text-base-content/50 italic">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No extra fields yet.")}
          </p>

          <%!-- Confirmation is inline, not a nested modal: a <dialog>
               inside an open <dialog> is not reliably interactive. --%>
          <div
            :if={@supplier_field_remove}
            class="rounded-lg border border-error/30 bg-error/5 p-3 flex flex-col gap-2"
          >
            <p class="text-sm">
              {Gettext.gettext(
                PhoenixKitCatalogue.Gettext,
                "Remove this field? Values already saved on supplier rows stay in the database but stop being shown."
              )}
            </p>
            <div class="flex gap-2 justify-end">
              <.button
                type="button"
                variant="ghost"
                size="xs"
                phx-click="cancel_remove_supplier_field"
              >
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Cancel")}
              </.button>
              <.button
                type="button"
                size="xs"
                class="btn-error"
                phx-click="confirm_remove_supplier_field"
              >
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Remove")}
              </.button>
            </div>
          </div>

          <.button
            type="button"
            phx-click="open_supplier_field_editor"
            variant="outline"
            size="sm"
            class="self-start"
          >
            <.icon name="hero-plus" class="w-4 h-4" />
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Add field")}
          </.button>
        </div>

        <:actions>
          <.button type="button" phx-click="close_supplier_field_manager">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Done")}
          </.button>
        </:actions>
      </.modal>

      <%!-- Field editor — one modal, two modes; rendered fresh per open
           so the type-specific block is server-driven. --%>
      <.modal
        :if={@supplier_field_editor != nil}
        id="supplier-field-editor-modal"
        show
        on_close="close_supplier_field_editor"
        max_width="md"
      >
        <:title>
          {if @supplier_field_editor.mode == :new,
            do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Add extra field"),
            else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit extra field")}
        </:title>

        <form
          id="supplier-field-editor-form"
          phx-change="validate_supplier_field_editor"
          phx-submit="save_supplier_field_editor"
          class="flex flex-col gap-4"
        >
          <label class="form-control">
            <span class="label-text font-medium pb-1">
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Name")}
              <span class="text-error">*</span>
            </span>
            <input
              type="text"
              name="label"
              value={@supplier_field_editor.label}
              placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "e.g. Incoterm")}
              class="input input-bordered w-full"
            />
          </label>
          <p :if={@supplier_field_editor.mode == :edit} class="text-xs text-base-content/50 -mt-2">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Key: %{key}",
              key: @supplier_field_editor.key
            )}
          </p>

          <%= if @supplier_field_editor.mode == :new do %>
            <label class="form-control">
              <span class="label-text font-medium pb-1">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Type")}
              </span>
              <select name="type" class="select select-bordered w-full">
                <option
                  :for={{label, val} <- supplier_field_type_options()}
                  value={val}
                  selected={@supplier_field_editor.type == val}
                >
                  {label}
                </option>
              </select>
            </label>
          <% else %>
            <div class="flex flex-col gap-1">
              <span class="label-text font-medium">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Type")}
              </span>
              <p class="text-sm">{supplier_field_type_label(@supplier_field_editor.type)}</p>
              <p class="text-xs text-base-content/50">
                {Gettext.gettext(
                  PhoenixKitCatalogue.Gettext,
                  "Type can't be changed. Remove the field and add a new one if you need a different type."
                )}
              </p>
            </div>
          <% end %>

          <div :if={@supplier_field_editor.type == "select"} class="flex flex-col gap-2">
            <span class="label-text font-medium">
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Choices")}
            </span>
            <div
              :for={{choice, index} <- Enum.with_index(@supplier_field_editor.choices)}
              class="flex items-center gap-2"
            >
              <input
                type="text"
                name="choices[]"
                id={"supplier-field-choice-#{index}"}
                value={choice}
                class="input input-sm input-bordered flex-1"
              />
              <.button
                type="button"
                phx-click="remove_supplier_field_choice"
                phx-value-index={index}
                variant="ghost"
                size="xs"
                class="px-1 text-base-content/40 hover:text-error"
                title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Remove choice")}
              >
                <.icon name="hero-x-mark" class="w-4 h-4" />
              </.button>
            </div>
            <.button
              type="button"
              phx-click="add_supplier_field_choice"
              variant="outline"
              size="xs"
              class="self-start"
            >
              <.icon name="hero-plus" class="w-3.5 h-3.5" />
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Add choice")}
            </.button>
          </div>

          <p :if={@supplier_field_editor.error} class="text-sm text-error">
            {@supplier_field_editor.error}
          </p>
        </form>

        <:actions>
          <.button type="button" variant="ghost" phx-click="close_supplier_field_editor">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Cancel")}
          </.button>
          <.button
            form="supplier-field-editor-form"
            type="submit"
            phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Saving...")}
          >
            {if @supplier_field_editor.mode == :new,
              do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Add field"),
              else: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Save field")}
          </.button>
        </:actions>
      </.modal>

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
              <div class="fieldset flex-1">
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
              <.button
                type="button"
                phx-click="move_item"
                phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Moving...")}
                disabled={is_nil(@move_target)}
                variant="outline"
                size="sm"
              >
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Move")}
              </.button>
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
              <div class="fieldset flex-1">
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
              <.button
                type="button"
                phx-click="move_item"
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
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  defp lang_name(language_tabs, code) do
    case Enum.find(language_tabs, &(&1.code == code)) do
      %{name: name} -> name
      _ -> code
    end
  end
end
