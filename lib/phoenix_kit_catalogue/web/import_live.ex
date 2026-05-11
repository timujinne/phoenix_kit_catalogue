defmodule PhoenixKitCatalogue.Web.ImportLive do
  @moduledoc """
  Multi-step import wizard for catalogue items.

  Steps: upload → map → confirm → importing → done
  """

  use Phoenix.LiveView

  require Logger

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Select, only: [select: 1]

  import PhoenixKitWeb.Components.MultilangForm,
    only: [
      mount_multilang: 1,
      multilang_tabs: 1,
      merge_translatable_params: 4,
      translatable_field: 1,
      multilang_fields_wrapper: 1,
      get_lang_data: 3
    ]

  import PhoenixKitCatalogue.Web.Helpers, only: [actor_uuid: 1]

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:ets_table] do
      try do
        :ets.delete(socket.assigns.ets_table)
      rescue
        ArgumentError -> :ok
      end
    end
  end

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Import.{Executor, Mapper, Parser}
  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Schemas.{Category, Item, Manufacturer, Supplier}

  @max_file_size 10_000_000
  @preview_rows 5
  @category_translatable_fields ["name", "description"]

  @impl true
  def mount(_params, _session, socket) do
    # Load on both the HTTP and WebSocket mounts so the picker is
    # populated on first paint. The three queries (catalogues + two
    # `GROUP BY catalogue_uuid` count aggregates) are cheap — both
    # aggregates are single-table scans on indexed columns. If picker
    # data ever grows expensive, swap to `assign_async` here without
    # changing the template (it already consumes `catalogues`,
    # `catalogue_item_counts`, and `catalogue_category_counts`
    # separately).
    catalogues = Catalogue.list_catalogues()
    catalogue_item_counts = Catalogue.item_counts_by_catalogue()
    catalogue_category_counts = Catalogue.category_counts_by_catalogue()
    manufacturers = Catalogue.list_manufacturers(status: "active")
    suppliers = Catalogue.list_suppliers(status: "active")

    {:ok,
     socket
     |> assign(
       page_title: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Import"),
       step: :upload,
       catalogues: catalogues,
       catalogue_item_counts: catalogue_item_counts,
       catalogue_category_counts: catalogue_category_counts,
       manufacturers: manufacturers,
       suppliers: suppliers,
       selected_catalogue: nil,
       # File data

       headers: [],
       preview_rows: [],
       row_count: 0,
       sheets: [],
       selected_sheet: nil,
       filename: nil,
       file_binary: nil,
       # Mapping
       column_mappings: [],
       unit_values: [],
       unit_map: %{},
       import_category_mode: :none,
       import_category_uuid: nil,
       category_match_across_languages: false,
       new_category: nil,
       new_category_changeset: nil,
       catalogue_categories: [],
       import_manufacturer_mode: :none,
       import_manufacturer_uuid: nil,
       new_manufacturer: nil,
       new_manufacturer_changeset: nil,
       import_supplier_mode: :none,
       import_supplier_uuid: nil,
       new_supplier: nil,
       new_supplier_changeset: nil,
       # Import
       import_plan: nil,
       import_result: nil,
       duplicate_row_count: 0,
       existing_duplicate_count: 0,
       duplicate_mode: :import,
       import_progress: 0,
       import_total: 0,
       # ETS
       ets_table: nil
     )
     |> mount_multilang()
     |> allow_upload(:import_file,
       accept: ~w(.xlsx .csv),
       max_entries: 1,
       max_file_size: @max_file_size,
       auto_upload: true
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  # ── Step 1: Upload ──────────────────────────────────────────────

  @impl true
  def handle_event("validate_upload", %{"catalogue" => uuid} = _params, socket) when uuid != "" do
    catalogue = Enum.find(socket.assigns.catalogues, &(&1.uuid == uuid))
    socket = if catalogue, do: assign(socket, :selected_catalogue, catalogue), else: socket
    {:noreply, socket}
  end

  def handle_event("validate_upload", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :import_file, ref)}
  end

  def handle_event("clear_file", _params, socket) do
    if socket.assigns.ets_table, do: :ets.delete(socket.assigns.ets_table)

    {:noreply,
     socket
     |> assign(
       filename: nil,
       file_binary: nil,
       headers: [],
       preview_rows: [],
       row_count: 0,
       sheets: [],
       column_mappings: [],
       unit_values: [],
       unit_map: %{},
       ets_table: nil,
       import_plan: nil
     )
     |> reset_picker_state()}
  end

  def handle_event("parse_file", params, socket) do
    # Read catalogue from form params
    socket =
      case params["catalogue"] do
        uuid when is_binary(uuid) and uuid != "" ->
          catalogue = Enum.find(socket.assigns.catalogues, &(&1.uuid == uuid))
          if catalogue, do: assign(socket, :selected_catalogue, catalogue), else: socket

        _ ->
          socket
      end

    if socket.assigns.selected_catalogue == nil do
      {:noreply,
       put_flash(
         socket,
         :error,
         Gettext.gettext(PhoenixKitCatalogue.Gettext, "Please select a catalogue first.")
       )}
    else
      continue_or_parse(socket)
    end
  end

  # ── Sheet Selection ─────────────────────────────────────────────

  def handle_event("select_sheet", %{"sheet" => sheet_name}, socket) do
    case Parser.parse(socket.assigns.file_binary, socket.assigns.filename, sheet: sheet_name) do
      {:ok, data} ->
        # Clear and reload ETS
        if socket.assigns.ets_table, do: :ets.delete_all_objects(socket.assigns.ets_table)

        Enum.with_index(data.rows)
        |> Enum.each(fn {row, idx} -> :ets.insert(socket.assigns.ets_table, {idx, row}) end)

        mappings = Mapper.auto_detect_mappings(data.headers)
        {unit_values, unit_map} = detect_unit_values(mappings, data.rows)

        {:noreply,
         socket
         |> assign(
           headers: data.headers,
           preview_rows: Enum.take(data.rows, @preview_rows),
           row_count: data.row_count,
           selected_sheet: sheet_name,
           column_mappings: mappings,
           unit_values: unit_values,
           unit_map: unit_map
         )
         |> reset_picker_state()}

      {:error, reason} ->
        Logger.warning("Import sheet parse error: #{inspect(reason)}")

        {:noreply, put_flash(socket, :error, PhoenixKitCatalogue.Errors.message(reason))}
    end
  end

  # ── Step 3: Map Columns ────────────────────────────────────────

  def handle_event("mapping_form_change", params, socket) do
    socket = apply_mapping_changes(socket, params["mapping"] || %{})
    socket = apply_unit_map_changes(socket, params["unit_map"] || %{})

    {:noreply, socket}
  end

  # Keep old handlers as fallbacks for any standalone selects
  def handle_event("update_mapping", %{"column" => col_str, "target" => target_str}, socket) do
    col_idx = String.to_integer(col_str)
    target = parse_target(target_str)

    # Unique targets: if another column already has this target (except :skip and :data),
    # reset the old column to :skip
    unique_targets = [
      :name,
      :description,
      :sku,
      :base_price,
      :markup_percentage,
      :unit,
      :category
    ]

    mappings =
      Enum.map(socket.assigns.column_mappings, fn m ->
        cond do
          m.column_index == col_idx -> %{m | target: target}
          target in unique_targets and m.target == target -> %{m | target: :skip}
          true -> m
        end
      end)

    # Update unit values if unit column changed
    rows = ets_to_rows(socket.assigns.ets_table)
    {unit_values, unit_map} = detect_unit_values(mappings, rows)

    {:noreply,
     assign(socket,
       column_mappings: mappings,
       unit_values: unit_values,
       unit_map:
         if(unit_values == socket.assigns.unit_values,
           do: socket.assigns.unit_map,
           else: unit_map
         )
     )}
  end

  def handle_event("update_unit_map", %{"source" => source, "target" => target}, socket) do
    unit_map = Map.put(socket.assigns.unit_map, source, target)
    {:noreply, assign(socket, :unit_map, unit_map)}
  end

  def handle_event("continue_to_confirm", _params, socket) do
    cond do
      not Enum.any?(socket.assigns.column_mappings, &(&1.target == :name)) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(
             PhoenixKitCatalogue.Gettext,
             "You must map at least one column to 'Item Name'. Scroll down to the column mapping section and pick the column that holds item names."
           )
         )}

      socket.assigns.import_category_mode == :create and
          not new_record_valid?(socket.assigns.new_category_changeset) ->
        cs = Map.put(socket.assigns.new_category_changeset, :action, :validate)

        {:noreply,
         socket
         |> assign(:new_category_changeset, cs)
         |> put_flash(
           :error,
           Gettext.gettext(
             PhoenixKitCatalogue.Gettext,
             "Please give the new category a name before continuing."
           )
         )}

      socket.assigns.import_manufacturer_mode == :create and
          not new_record_valid?(socket.assigns.new_manufacturer_changeset) ->
        cs = Map.put(socket.assigns.new_manufacturer_changeset, :action, :validate)

        {:noreply,
         socket
         |> assign(:new_manufacturer_changeset, cs)
         |> put_flash(
           :error,
           Gettext.gettext(
             PhoenixKitCatalogue.Gettext,
             "Please give the new manufacturer a name before continuing."
           )
         )}

      socket.assigns.import_supplier_mode == :create and
          not new_record_valid?(socket.assigns.new_supplier_changeset) ->
        cs = Map.put(socket.assigns.new_supplier_changeset, :action, :validate)

        {:noreply,
         socket
         |> assign(:new_supplier_changeset, cs)
         |> put_flash(
           :error,
           Gettext.gettext(
             PhoenixKitCatalogue.Gettext,
             "Please give the new supplier a name before continuing."
           )
         )}

      true ->
        build_confirm_step(socket)
    end
  end

  # ── Step 4: Confirm ─────────────────────────────────────────────

  def handle_event("select_import_category", params, socket) do
    {category_mode, category_uuid} = parse_picker_mode(params["category_mode"])

    socket =
      socket
      |> maybe_clear_picker_column(:import_category_mode, category_mode)
      |> maybe_set_picker_column(:import_category_mode, params["category_column"])
      |> assign(
        import_category_mode: category_mode,
        import_category_uuid: category_uuid,
        category_match_across_languages:
          params["category_match_across_languages"] in ["true", "on", true]
      )
      |> sync_new_category_for_mode(category_mode)

    {:noreply, socket}
  end

  def handle_event("validate_new_category", %{"category" => params}, socket) do
    {:noreply, apply_new_category_params(socket, params)}
  end

  def handle_event("select_import_manufacturer", params, socket) do
    {mode, uuid} = parse_picker_mode(params["manufacturer_mode"])

    socket =
      socket
      |> maybe_clear_picker_column(:import_manufacturer_mode, mode)
      |> maybe_set_picker_column(:import_manufacturer_mode, params["manufacturer_column"])
      |> assign(import_manufacturer_mode: mode, import_manufacturer_uuid: uuid)
      |> sync_new_manufacturer_for_mode(mode)

    {:noreply, socket}
  end

  def handle_event("validate_new_manufacturer", %{"manufacturer" => params}, socket) do
    {:noreply, apply_new_manufacturer_params(socket, params)}
  end

  def handle_event("select_import_supplier", params, socket) do
    {mode, uuid} = parse_picker_mode(params["supplier_mode"])

    socket =
      socket
      |> maybe_clear_picker_column(:import_supplier_mode, mode)
      |> maybe_set_picker_column(:import_supplier_mode, params["supplier_column"])
      |> assign(import_supplier_mode: mode, import_supplier_uuid: uuid)
      |> sync_new_supplier_for_mode(mode)

    {:noreply, socket}
  end

  def handle_event("validate_new_supplier", %{"supplier" => params}, socket) do
    {:noreply, apply_new_supplier_params(socket, params)}
  end

  def handle_event("switch_language", %{"lang" => lang_code}, socket) do
    {:noreply, assign(socket, :current_lang, lang_code)}
  end

  def handle_event("set_duplicate_mode", %{"mode" => mode}, socket) do
    mode = if mode == "skip", do: :skip, else: :import
    {:noreply, assign(socket, :duplicate_mode, mode)}
  end

  def handle_event("back_to_mapping", _params, socket) do
    {:noreply, assign(socket, step: :map, import_plan: nil)}
  end

  def handle_event("execute_import", _params, socket) do
    catalogue_uuid = socket.assigns.selected_catalogue.uuid
    import_lang = if socket.assigns.multilang_enabled, do: socket.assigns.current_lang, else: nil

    # Wrap the three :create-mode resolutions in a single transaction
    # so a failure on the second or third doesn't leave the first as
    # an orphan record. Modes other than :create are read-only inside
    # the transaction (they just look up the picked uuid), so this is
    # a no-op cost when nobody is creating anything.
    txn =
      PhoenixKit.RepoHelper.repo().transaction(fn ->
        with {:ok, c_uuid, s1} <- resolve_import_category(socket, catalogue_uuid, import_lang),
             {:ok, m_uuid, s2} <- resolve_import_manufacturer(s1),
             {:ok, s_uuid, s3} <- resolve_import_supplier(s2) do
          {c_uuid, m_uuid, s_uuid, s3}
        else
          {:error, message, socket} ->
            PhoenixKit.RepoHelper.repo().rollback({:error, message, socket})
        end
      end)

    case txn do
      {:ok, {category_uuid, manufacturer_uuid, supplier_uuid, socket}} ->
        start_import(
          socket,
          catalogue_uuid,
          category_uuid,
          manufacturer_uuid,
          supplier_uuid,
          import_lang
        )

      {:error, {:error, message, socket}} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  # ── Step 6: Done ────────────────────────────────────────────────

  def handle_event("import_another", _params, socket) do
    # Clean up ETS
    if socket.assigns.ets_table, do: :ets.delete(socket.assigns.ets_table)

    {:noreply,
     socket
     |> assign(
       step: :upload,
       headers: [],
       preview_rows: [],
       row_count: 0,
       sheets: [],
       filename: nil,
       file_binary: nil,
       column_mappings: [],
       unit_values: [],
       unit_map: %{},
       import_plan: nil,
       import_result: nil,
       import_progress: 0,
       import_total: 0,
       ets_table: nil
     )
     |> reset_picker_state()
     |> allow_upload(:import_file,
       accept: ~w(.xlsx .csv),
       max_entries: 1,
       max_file_size: @max_file_size,
       auto_upload: true
     )}
  end

  # ── Navigation helpers ──────────────────────────────────────────

  def handle_event("go_back", _params, socket) do
    prev_step =
      case socket.assigns.step do
        :map -> :upload
        :confirm -> :map
        _ -> socket.assigns.step
      end

    {:noreply, assign(socket, :step, prev_step)}
  end

  # ── Step 5: Importing ──────────────────────────────────────────

  @impl true
  def handle_info({:import_progress, current, total}, socket) do
    {:noreply, assign(socket, import_progress: current, import_total: total)}
  end

  def handle_info({:import_result, result}, socket) do
    log_import_activity(socket, result)
    {:noreply, assign(socket, step: :done, import_result: result)}
  end

  def handle_info(msg, socket) do
    Logger.debug("ImportLive ignored unhandled message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # ── Private helpers ─────────────────────────────────────────────

  defp continue_or_parse(socket) do
    if socket.assigns.filename do
      catalogue_categories =
        Catalogue.list_categories_for_catalogue(socket.assigns.selected_catalogue.uuid)

      {:noreply, assign(socket, step: :map, catalogue_categories: catalogue_categories)}
    else
      parse_uploaded_file(socket)
    end
  end

  defp parse_uploaded_file(socket) do
    cond do
      # User picked a file but it hasn't finished uploading yet. Don't
      # call `consume_uploaded_entries` — non-done entries are skipped
      # but the form submit can disrupt the in-flight XHR, making the
      # file appear to vanish. Tell the user to wait and leave the
      # upload alone.
      Enum.any?(socket.assigns.uploads.import_file.entries, &(not &1.done?)) ->
        {:noreply,
         put_flash(
           socket,
           :info,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Still uploading — please wait a moment.")
         )}

      socket.assigns.uploads.import_file.entries == [] ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Please upload a file.")
         )}

      true ->
        consume_and_parse(socket)
    end
  end

  defp consume_and_parse(socket) do
    uploaded_files =
      consume_uploaded_entries(socket, :import_file, fn %{path: path}, entry ->
        binary = File.read!(path)
        {:ok, {binary, entry.client_name}}
      end)

    case uploaded_files do
      [{binary, filename}] ->
        handle_parsed_file(socket, binary, filename)

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitCatalogue.Gettext, "Please upload a file.")
         )}
    end
  end

  defp handle_parsed_file(socket, binary, filename) do
    case Parser.parse(binary, filename) do
      {:ok, data} ->
        # Store in ETS
        ets_table = :ets.new(:import_data, [:ordered_set, :private])

        Enum.with_index(data.rows)
        |> Enum.each(fn {row, idx} -> :ets.insert(ets_table, {idx, row}) end)

        # Auto-detect mappings
        mappings = Mapper.auto_detect_mappings(data.headers)

        # Find unit column and extract unique values
        {unit_values, unit_map} = detect_unit_values(mappings, data.rows)

        # Load existing categories for the selected catalogue
        catalogue_categories =
          if socket.assigns.selected_catalogue do
            Catalogue.list_categories_for_catalogue(socket.assigns.selected_catalogue.uuid)
          else
            []
          end

        {:noreply,
         socket
         |> assign(
           step: :map,
           headers: data.headers,
           preview_rows: Enum.take(data.rows, @preview_rows),
           row_count: data.row_count,
           sheets: data.sheets,
           selected_sheet: List.first(data.sheets),
           filename: filename,
           file_binary: binary,
           column_mappings: mappings,
           ets_table: ets_table,
           unit_values: unit_values,
           unit_map: unit_map,
           catalogue_categories: catalogue_categories
         )}

      {:error, reason} ->
        Logger.warning("Import file parse error: #{inspect(reason)}")

        {:noreply, put_flash(socket, :error, PhoenixKitCatalogue.Errors.message(reason))}
    end
  end

  defp apply_mapping_changes(socket, mapping_params) when map_size(mapping_params) == 0,
    do: socket

  defp apply_mapping_changes(socket, mapping_params) do
    old_mappings = socket.assigns.column_mappings

    changed_col =
      Enum.find(old_mappings, fn m ->
        new_val = Map.get(mapping_params, to_string(m.column_index))
        new_val != nil and parse_target(new_val) != m.target
      end)

    if changed_col == nil do
      socket
    else
      new_target = parse_target(Map.get(mapping_params, to_string(changed_col.column_index)))
      mappings = update_column_mappings(old_mappings, changed_col.column_index, new_target)
      recalculate_unit_values(socket, mappings)
    end
  end

  @unique_targets [
    :name,
    :description,
    :sku,
    :base_price,
    :markup_percentage,
    :unit,
    :category,
    :manufacturer,
    :supplier
  ]

  defp update_column_mappings(mappings, changed_idx, new_target) do
    Enum.map(mappings, fn m ->
      cond do
        m.column_index == changed_idx -> %{m | target: new_target}
        new_target in @unique_targets and m.target == new_target -> %{m | target: :skip}
        true -> m
      end
    end)
  end

  defp maybe_deduplicate(plan, :import, _catalogue_uuid, _opts), do: plan

  defp maybe_deduplicate(plan, :skip, catalogue_uuid, opts) do
    unique_items = Enum.uniq(plan.items)

    existing_items = Catalogue.list_items_for_catalogue(catalogue_uuid)

    unique_items =
      Enum.reject(unique_items, fn import_item ->
        Enum.any?(existing_items, &Mapper.item_matches_existing?(import_item, &1, opts))
      end)

    %{plan | items: unique_items, stats: %{plan.stats | valid: length(unique_items)}}
  end

  defp recalculate_unit_values(socket, mappings) do
    rows = ets_to_rows(socket.assigns.ets_table)
    {unit_values, unit_map} = detect_unit_values(mappings, rows)

    assign(socket,
      column_mappings: mappings,
      unit_values: unit_values,
      unit_map:
        if(unit_values == socket.assigns.unit_values,
          do: socket.assigns.unit_map,
          else: unit_map
        )
    )
  end

  defp apply_unit_map_changes(socket, unit_params) when map_size(unit_params) == 0, do: socket

  defp apply_unit_map_changes(socket, unit_params) do
    unit_map = Map.merge(socket.assigns.unit_map, unit_params)
    assign(socket, :unit_map, unit_map)
  end

  # Resets every picker's mode/uuid/inline-create state back to its
  # initial defaults. Called whenever the underlying file or sheet
  # changes (sheet switch, file replace, "Import another"), because the
  # picker assigns reference column-mapping shapes specific to the
  # previously-loaded data — leaving them in place after a fresh parse
  # would either point at columns that no longer exist or surface
  # stale `:column`-mode UI tied to the old sheet.
  defp reset_picker_state(socket) do
    assign(socket,
      import_category_mode: :none,
      import_category_uuid: nil,
      category_match_across_languages: false,
      new_category: nil,
      new_category_changeset: nil,
      import_manufacturer_mode: :none,
      import_manufacturer_uuid: nil,
      new_manufacturer: nil,
      new_manufacturer_changeset: nil,
      import_supplier_mode: :none,
      import_supplier_uuid: nil,
      new_supplier: nil,
      new_supplier_changeset: nil,
      duplicate_row_count: 0,
      existing_duplicate_count: 0,
      duplicate_mode: :import
    )
  end

  # Generic mode parser used by all three pickers (category,
  # manufacturer, supplier) — they share the same `none / column /
  # create / existing:<uuid>` vocabulary, so one parser suffices.
  defp parse_picker_mode("none"), do: {:none, nil}
  defp parse_picker_mode("column"), do: {:column, nil}
  defp parse_picker_mode("create"), do: {:create, nil}
  defp parse_picker_mode("existing:" <> uuid), do: {:existing, uuid}
  defp parse_picker_mode(_), do: {:none, nil}

  # Seeds a fresh new-category struct + changeset when the user switches
  # *into* `:create` mode, so the inline form has something to bind to.
  # Clears them when switching *away* so we don't leak draft input across
  # mode changes (and so a half-typed category can't accidentally get
  # created if the user later runs the import in a different mode).
  defp sync_new_category_for_mode(socket, :create) do
    if socket.assigns.new_category do
      socket
    else
      catalogue_uuid = socket.assigns.selected_catalogue && socket.assigns.selected_catalogue.uuid

      next_pos =
        if catalogue_uuid, do: Catalogue.next_category_position(catalogue_uuid), else: 0

      category = %Category{catalogue_uuid: catalogue_uuid, position: next_pos}

      assign(socket,
        new_category: category,
        new_category_changeset: Catalogue.change_category(category)
      )
    end
  end

  defp sync_new_category_for_mode(socket, _other) do
    if socket.assigns.new_category,
      do: assign(socket, new_category: nil, new_category_changeset: nil),
      else: socket
  end

  defp apply_new_category_params(socket, params) do
    catalogue_uuid = socket.assigns.selected_catalogue && socket.assigns.selected_catalogue.uuid

    params =
      params
      |> Map.put_new("catalogue_uuid", catalogue_uuid)
      |> merge_translatable_params(socket, @category_translatable_fields,
        changeset: socket.assigns.new_category_changeset
      )

    changeset =
      socket.assigns.new_category
      |> Catalogue.change_category(params)
      |> Map.put(:action, :validate)

    assign(socket, :new_category_changeset, changeset)
  end

  # ── Manufacturer / Supplier inline-create state ─────────────────

  # Same idea as `sync_new_category_for_mode/2` but for the
  # manufacturer picker. Manufacturers aren't multilingual so the
  # changeset starts empty and we don't need any
  # `merge_translatable_params` machinery on validate.
  defp sync_new_manufacturer_for_mode(socket, :create) do
    if socket.assigns.new_manufacturer do
      socket
    else
      manufacturer = %Manufacturer{}

      assign(socket,
        new_manufacturer: manufacturer,
        new_manufacturer_changeset: Catalogue.change_manufacturer(manufacturer)
      )
    end
  end

  defp sync_new_manufacturer_for_mode(socket, _other) do
    if socket.assigns.new_manufacturer,
      do: assign(socket, new_manufacturer: nil, new_manufacturer_changeset: nil),
      else: socket
  end

  defp apply_new_manufacturer_params(socket, params) do
    changeset =
      socket.assigns.new_manufacturer
      |> Catalogue.change_manufacturer(params)
      |> Map.put(:action, :validate)

    assign(socket, :new_manufacturer_changeset, changeset)
  end

  defp sync_new_supplier_for_mode(socket, :create) do
    if socket.assigns.new_supplier do
      socket
    else
      supplier = %Supplier{}

      assign(socket,
        new_supplier: supplier,
        new_supplier_changeset: Catalogue.change_supplier(supplier)
      )
    end
  end

  defp sync_new_supplier_for_mode(socket, _other) do
    if socket.assigns.new_supplier,
      do: assign(socket, new_supplier: nil, new_supplier_changeset: nil),
      else: socket
  end

  defp apply_new_supplier_params(socket, params) do
    changeset =
      socket.assigns.new_supplier
      |> Catalogue.change_supplier(params)
      |> Map.put(:action, :validate)

    assign(socket, :new_supplier_changeset, changeset)
  end

  defp new_record_valid?(nil), do: false

  defp new_record_valid?(changeset) do
    changeset |> Map.put(:action, :validate) |> Map.get(:valid?)
  end

  defp build_confirm_step(socket) do
    rows = ets_to_rows(socket.assigns.ets_table)

    import_plan =
      Mapper.build_import_plan(socket.assigns.column_mappings, rows,
        unit_map: socket.assigns.unit_map
      )

    file_duplicates = Mapper.detect_file_duplicates(rows)

    # `:create` mode produces a category at execute time, so its uuid
    # isn't known yet — duplicate detection happens against "no category"
    # since the new one will be empty by definition.
    import_category =
      if socket.assigns.import_category_mode == :existing,
        do: socket.assigns.import_category_uuid,
        else: nil

    import_lang =
      if socket.assigns.multilang_enabled, do: socket.assigns.current_lang, else: nil

    existing_duplicates =
      Mapper.detect_existing_duplicates(import_plan, socket.assigns.selected_catalogue.uuid,
        category_uuid: import_category,
        language: import_lang
      )

    {:noreply,
     assign(socket,
       step: :confirm,
       import_plan: import_plan,
       duplicate_row_count: file_duplicates,
       existing_duplicate_count: existing_duplicates,
       duplicate_mode: :import
     )}
  end

  # Resolves the category to pin imported items to, based on the
  # current `import_category_mode`. For `:create` mode this is where
  # the actual category record gets persisted — deferring creation to
  # execute time means cancelling out of the confirm step doesn't
  # leave an orphan category behind.
  defp resolve_import_category(socket, catalogue_uuid, import_lang) do
    case socket.assigns.import_category_mode do
      :existing ->
        {:ok, socket.assigns.import_category_uuid, socket}

      :create ->
        attrs =
          socket.assigns.new_category_changeset
          |> Ecto.Changeset.apply_changes()
          |> Map.from_struct()
          |> Map.take([:name, :description, :position, :data])
          |> Map.put(:catalogue_uuid, catalogue_uuid)
          |> apply_category_language(import_lang)

        case Catalogue.create_category(attrs, actor_opts(socket)) do
          {:ok, category} ->
            {:ok, category.uuid, socket}

          {:error, changeset} ->
            socket =
              socket
              |> assign(:new_category_changeset, Map.put(changeset, :action, :validate))
              |> assign(:step, :map)

            {:error,
             Gettext.gettext(
               PhoenixKitCatalogue.Gettext,
               "Could not create the new category. Please check the form and try again."
             ), socket}
        end

      _ ->
        {:ok, nil, socket}
    end
  end

  # Wraps the import language onto category attrs the same way
  # `Executor.apply_language/2` does for items / column-created
  # categories, so the explicitly-created category lands in the right
  # `_primary_language` bucket.
  defp apply_category_language(attrs, nil), do: attrs

  defp apply_category_language(attrs, language) do
    translatable = %{}

    translatable =
      if attrs[:name], do: Map.put(translatable, "_name", attrs[:name]), else: translatable

    translatable =
      if attrs[:description],
        do: Map.put(translatable, "_description", attrs[:description]),
        else: translatable

    if map_size(translatable) > 0 do
      existing_data = attrs[:data] || %{}

      new_data = %{
        "_primary_language" => language,
        language => translatable
      }

      new_data = Map.merge(new_data, Map.drop(existing_data, ["_primary_language"]))
      Map.put(attrs, :data, new_data)
    else
      attrs
    end
  end

  # Import wizard threads `mode: "auto"` so the executor's CRUD ops are
  # tagged accordingly in the activity log; for that reason it can't
  # use the shared `actor_opts/1` directly.
  defp actor_opts(socket) do
    case actor_uuid(socket) do
      nil -> [mode: "auto"]
      uuid -> [actor_uuid: uuid, mode: "auto"]
    end
  end

  # ── Manufacturer / Supplier resolution at execute time ─────────

  # Same `:create` deferral pattern as `resolve_import_category/3`:
  # the inline-create form's record isn't persisted until the user
  # actually clicks Run, so cancelling the confirm step doesn't leave
  # an orphan manufacturer.
  defp resolve_import_manufacturer(socket) do
    case socket.assigns.import_manufacturer_mode do
      :existing ->
        {:ok, socket.assigns.import_manufacturer_uuid, socket}

      :create ->
        attrs =
          socket.assigns.new_manufacturer_changeset
          |> Ecto.Changeset.apply_changes()
          |> Map.from_struct()
          |> Map.take([:name, :description, :website, :contact_info, :logo_url, :notes])

        case Catalogue.create_manufacturer(attrs, actor_opts(socket)) do
          {:ok, manufacturer} ->
            {:ok, manufacturer.uuid, socket}

          {:error, changeset} ->
            socket =
              socket
              |> assign(:new_manufacturer_changeset, Map.put(changeset, :action, :validate))
              |> assign(:step, :map)

            {:error,
             Gettext.gettext(
               PhoenixKitCatalogue.Gettext,
               "Could not create the new manufacturer. Please check the form and try again."
             ), socket}
        end

      _ ->
        {:ok, nil, socket}
    end
  end

  defp resolve_import_supplier(socket) do
    case socket.assigns.import_supplier_mode do
      :existing ->
        {:ok, socket.assigns.import_supplier_uuid, socket}

      :create ->
        attrs =
          socket.assigns.new_supplier_changeset
          |> Ecto.Changeset.apply_changes()
          |> Map.from_struct()
          |> Map.take([:name, :description, :website, :contact_info, :notes])

        case Catalogue.create_supplier(attrs, actor_opts(socket)) do
          {:ok, supplier} ->
            {:ok, supplier.uuid, socket}

          {:error, changeset} ->
            socket =
              socket
              |> assign(:new_supplier_changeset, Map.put(changeset, :action, :validate))
              |> assign(:step, :map)

            {:error,
             Gettext.gettext(
               PhoenixKitCatalogue.Gettext,
               "Could not create the new supplier. Please check the form and try again."
             ), socket}
        end

      _ ->
        {:ok, nil, socket}
    end
  end

  defp start_import(
         socket,
         catalogue_uuid,
         category_uuid,
         manufacturer_uuid,
         supplier_uuid,
         import_lang
       ) do
    import_plan = socket.assigns.import_plan
    lv_pid = self()

    import_plan =
      maybe_deduplicate(import_plan, socket.assigns.duplicate_mode, catalogue_uuid,
        category_uuid: category_uuid,
        language: import_lang
      )

    log_import_started(socket, import_plan)

    match_across_languages = socket.assigns.category_match_across_languages

    # Supervised under PhoenixKit.TaskSupervisor so the import survives a
    # transient LV crash (the user's browser will reconnect to a new LV
    # process; we still want the import to finish and surface its result
    # in the activity feed via the executor's own logging) and so a task
    # crash here can't leave an orphan process running indefinitely.
    {:ok, _pid} =
      Task.Supervisor.start_child(PhoenixKit.TaskSupervisor, fn ->
        try do
          Executor.execute(import_plan, catalogue_uuid, lv_pid,
            language: import_lang,
            category_uuid: category_uuid,
            manufacturer_uuid: manufacturer_uuid,
            supplier_uuid: supplier_uuid,
            match_categories_across_languages: match_across_languages,
            actor_uuid: extract_actor_uuid(socket)
          )
        rescue
          # Narrow to the exception families we actually expect from
          # the import path: changeset / SQL errors from Executor's
          # inserts, ArgumentError/RuntimeError from Mapper or row
          # parsing, and Postgrex.Error if a constraint trips. A bare
          # `rescue _` would also swallow programmer-error exceptions
          # like KeyError / FunctionClauseError from a future
          # refactor — those should crash the supervised task so the
          # supervisor logs the full stacktrace.
          e in [
            ArgumentError,
            RuntimeError,
            Ecto.InvalidChangesetError,
            Ecto.QueryError,
            Postgrex.Error
          ] ->
            Logger.error("Import failed: #{Exception.message(e)}")

            send(
              lv_pid,
              {:import_result,
               %{
                 created: 0,
                 errors: [{0, Exception.message(e)}],
                 categories_created: 0,
                 manufacturers_created: 0,
                 suppliers_created: 0,
                 manufacturer_supplier_links_created: 0
               }}
            )
        end
      end)

    {:noreply,
     assign(socket,
       step: :importing,
       import_progress: 0,
       import_total: length(import_plan.items)
     )}
  end

  # Whenever a picker leaves `:column` mode, clear any column that was
  # previously assigned to that picker's target so it doesn't keep
  # carrying that role into the import plan. (The category picker
  # historically did this; same logic applies to manufacturer/supplier.)
  defp maybe_clear_picker_column(socket, _picker_mode_assign, :column), do: socket

  defp maybe_clear_picker_column(socket, picker_mode_assign, _new_mode) do
    if socket.assigns[picker_mode_assign] == :column do
      target = picker_target(picker_mode_assign)
      mappings = clear_target_from_mappings(socket.assigns.column_mappings, target)
      assign(socket, :column_mappings, mappings)
    else
      socket
    end
  end

  defp clear_target_from_mappings(mappings, target) do
    Enum.map(mappings, fn m ->
      if m.target == target, do: %{m | target: :skip}, else: m
    end)
  end

  defp maybe_set_picker_column(socket, picker_mode_assign, col)
       when is_binary(col) and col != "" do
    col_idx = String.to_integer(col)
    target = picker_target(picker_mode_assign)
    mappings = update_column_mappings(socket.assigns.column_mappings, col_idx, target)
    assign(socket, :column_mappings, mappings)
  end

  defp maybe_set_picker_column(socket, _picker_mode_assign, _), do: socket

  defp picker_target(:import_category_mode), do: :category
  defp picker_target(:import_manufacturer_mode), do: :manufacturer
  defp picker_target(:import_supplier_mode), do: :supplier

  # ── Render ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-5xl px-4 py-6 gap-6">
      <%!-- Step indicator --%>
      <div class="flex items-center justify-center gap-2 text-sm">
        <.step_badge step={:upload} current={@step} label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Upload")} />
        <.icon name="hero-chevron-right" class="w-4 h-4 text-base-content/30" />
        <.step_badge step={:map} current={@step} label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Map")} />
        <.icon name="hero-chevron-right" class="w-4 h-4 text-base-content/30" />
        <.step_badge step={:confirm} current={@step} label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Confirm")} />
        <.icon name="hero-chevron-right" class="w-4 h-4 text-base-content/30" />
        <.step_badge step={:importing} current={@step} label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Import")} />
      </div>

      <%!-- Step content --%>
      <.upload_step :if={@step == :upload} {assigns} />
      <.map_step :if={@step == :map} {assigns} />
      <.confirm_step :if={@step == :confirm} {assigns} />
      <.importing_step :if={@step == :importing} {assigns} />
      <.done_step :if={@step == :done} {assigns} />
    </div>
    """
  end

  # ── Step Components ─────────────────────────────────────────────

  # Generic picker block for manufacturer / supplier — same vocabulary
  # as the category picker (none / column / create / existing) but
  # without multilang noise. The component is a thin renderer over the
  # mode + chosen-uuid + column-mapping state held by the LiveView; the
  # caller wires the labels and event names so the same shell drives
  # both pickers.
  attr(:label, :string, required: true)
  attr(:form_id, :string, required: true)
  attr(:on_change, :string, required: true)
  attr(:mode_field, :string, required: true)
  attr(:column_field, :string, required: true)
  attr(:mode, :atom, required: true)
  attr(:uuid, :string, default: nil)
  attr(:options, :list, required: true)
  attr(:column_mappings, :list, required: true)
  attr(:ets_table, :any, required: true)
  attr(:target, :atom, required: true)
  attr(:none_label, :string, required: true)
  attr(:column_label, :string, required: true)
  attr(:create_label, :string, required: true)
  attr(:column_picker_prompt, :string, required: true)
  attr(:preview_label, :string, required: true)

  defp party_picker(assigns) do
    ~H"""
    <div class="form-control w-full max-w-md">
      <span class="block mb-2 text-sm font-medium">{@label}</span>
      <form id={@form_id} phx-change={@on_change} class="space-y-3">
        <.select
          name={@mode_field}
          id={"#{@form_id}-mode"}
          value={
            case @mode do
              :existing -> "existing:#{@uuid}"
              mode -> to_string(mode)
            end
          }
          options={
            [
              {@none_label, "none"},
              {@column_label, "column"},
              {@create_label, "create"}
            ] ++ Enum.map(@options, &{&1.name, "existing:#{&1.uuid}"})
          }
        />

        <div :if={@mode == :column} class="pl-4 border-l-2 border-secondary/20">
          <% available = available_picker_columns(@column_mappings, @target) %>
          <span class="block mb-1 text-xs text-base-content/60">{@column_picker_prompt}</span>
          <%= if available == [] do %>
            <p class="text-xs text-warning bg-warning/10 border border-warning/30 rounded-lg px-3 py-2">
              {Gettext.gettext(
                PhoenixKitCatalogue.Gettext,
                "All columns are already mapped. Free one up by setting it to '— Skip —' in the column mapping section below, or by switching another picker (Category, Manufacturer, or Supplier) out of 'Use a column' mode."
              )}
            </p>
          <% else %>
            <% selected_col =
              Enum.find_value(available, fn m ->
                if m.target == @target, do: m.column_index
              end) %>
            <%!-- Only offer columns that are unmapped (`:skip`),
                 already this picker's target, or used as a custom
                 `{:data, _}` field. Hiding columns already mapped
                 to another unique target (`:name`, `:sku`, etc.)
                 prevents the picker from silently clobbering an
                 auto-detected mapping the user still relies on. --%>
            <.select
              name={@column_field}
              id={"#{@form_id}-column"}
              value={selected_col}
              prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Select a column...")}
              options={Enum.map(available, &{&1.header, &1.column_index})}
              class="select-sm"
            />
          <% end %>
          <div :if={has_mapping?(@column_mappings, @target)} class="mt-2">
            <span class="text-xs text-base-content/60">{@preview_label}</span>
            <div class="flex flex-wrap gap-1 mt-1">
              <% picked = Enum.find(@column_mappings, &(&1.target == @target)) %>
              <span
                :for={val <- unique_column_values_from_ets(@ets_table, picked.column_index)}
                class="badge badge-secondary badge-outline badge-xs"
              >
                {val}
              </span>
            </div>
          </div>
        </div>
      </form>
    </div>
    """
  end

  # Inline create form for manufacturer / supplier. Both schemas have
  # the same shape (plain `name` + a few optional text fields), so one
  # component covers both via `form_prefix` switching between
  # `manufacturer` and `supplier`.
  attr(:form_id, :string, required: true)
  attr(:form_prefix, :string, required: true)
  attr(:on_change, :string, required: true)
  attr(:changeset, :map, required: true)
  attr(:name_placeholder, :string, required: true)

  defp new_party_form(assigns) do
    ~H"""
    <form
      id={@form_id}
      phx-change={@on_change}
      phx-submit="continue_to_confirm"
      class="mt-2 pl-4 border-l-2 border-secondary/20 max-w-md"
    >
      <div class="flex flex-col gap-4">
        <div class="form-control">
          <span class="label-text font-semibold mb-2">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Name")} *
          </span>
          <input
            type="text"
            name={"#{@form_prefix}[name]"}
            value={Ecto.Changeset.get_field(@changeset, :name) || ""}
            placeholder={@name_placeholder}
            class="input input-bordered w-full transition-colors focus:input-primary"
            required
          />
          <span :for={err <- field_errors(@changeset, :name)} class="text-error text-xs mt-1">
            {err}
          </span>
        </div>

        <div class="form-control">
          <span class="label-text font-semibold mb-2">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Description")}
          </span>
          <textarea
            name={"#{@form_prefix}[description]"}
            class="textarea textarea-bordered w-full transition-colors focus:textarea-primary"
            rows="2"
          >{Ecto.Changeset.get_field(@changeset, :description) || ""}</textarea>
        </div>

        <div class="form-control">
          <span class="label-text font-semibold mb-2">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Website")}
          </span>
          <input
            type="url"
            name={"#{@form_prefix}[website]"}
            value={Ecto.Changeset.get_field(@changeset, :website) || ""}
            placeholder="https://..."
            class="input input-bordered w-full transition-colors focus:input-primary"
          />
        </div>
      </div>
    </form>
    """
  end

  defp field_errors(changeset, field) do
    changeset
    |> Map.get(:errors, [])
    |> Keyword.get_values(field)
    |> Enum.map(fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # Inline category-creation form, shown when the user picks
  # "Create a new category" in the Import Into Category dropdown.
  # Mirrors the standalone CategoryFormLive view but omits its language
  # tabs (the import wizard already has a top-level switcher) and its
  # action buttons (the wizard's Continue/Run buttons drive the flow).
  attr(:changeset, :map, required: true)
  attr(:multilang_enabled, :boolean, required: true)
  attr(:current_lang, :string, required: true)
  attr(:primary_language, :string, required: true)

  defp new_category_form(assigns) do
    assigns =
      assign(
        assigns,
        :lang_data,
        get_lang_data(assigns.changeset, assigns.current_lang, assigns.multilang_enabled)
      )

    ~H"""
    <form
      id="new-category-form"
      phx-change="validate_new_category"
      phx-submit="continue_to_confirm"
      class="mt-4 pl-4 border-l-2 border-secondary/20"
    >
      <%!-- Only translatable fields live inside the wrapper. Position
           stays outside so a language switch doesn't remount it. --%>
      <.multilang_fields_wrapper
        multilang_enabled={@multilang_enabled}
        current_lang={@current_lang}
        skeleton_class="flex flex-col gap-6"
        fields_class="flex flex-col gap-6"
      >
        <:skeleton>
          <div class="space-y-2">
            <div class="skeleton h-4 w-20"></div>
            <div class="skeleton h-12 w-full"></div>
          </div>
          <div class="space-y-2">
            <div class="skeleton h-4 w-28"></div>
            <div class="skeleton h-24 w-full"></div>
          </div>
        </:skeleton>

        <.translatable_field
          field_name="name"
          form_prefix="category"
          changeset={@changeset}
          schema_field={:name}
          multilang_enabled={@multilang_enabled}
          current_lang={@current_lang}
          primary_language={@primary_language}
          lang_data={@lang_data}
          label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Name")}
          placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "e.g., Cabinet Frames")}
          required
          class="w-full"
        />

        <.translatable_field
          field_name="description"
          form_prefix="category"
          changeset={@changeset}
          schema_field={:description}
          multilang_enabled={@multilang_enabled}
          current_lang={@current_lang}
          primary_language={@primary_language}
          lang_data={@lang_data}
          label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Description")}
          placeholder={
            Gettext.gettext(
              PhoenixKitCatalogue.Gettext,
              "What kinds of items belong in this category..."
            )
          }
          type="textarea"
          class="w-full"
        />
      </.multilang_fields_wrapper>

      <div class="form-control mt-6">
        <span class="label-text font-semibold mb-2">
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Position")}
        </span>
        <input
          type="number"
          name="category[position]"
          value={Ecto.Changeset.get_field(@changeset, :position)}
          class="input input-bordered w-28 transition-colors focus:input-primary"
          min="0"
        />
        <span class="label-text-alt text-base-content/50 mt-1">
          {Gettext.gettext(
            PhoenixKitCatalogue.Gettext,
            "Lower numbers appear first."
          )}
        </span>
      </div>
    </form>
    """
  end

  defp step_badge(assigns) do
    steps = [:upload, :map, :confirm, :importing]
    current_idx = Enum.find_index(steps, &(&1 == assigns.current)) || 0
    step_idx = Enum.find_index(steps, &(&1 == assigns.step)) || 0

    status =
      cond do
        assigns.current == :done -> :completed
        step_idx < current_idx -> :completed
        step_idx == current_idx -> :active
        true -> :pending
      end

    assigns = assign(assigns, :status, status)

    ~H"""
    <span class={[
      "px-3 py-1 rounded-full font-medium",
      @status == :active && "bg-primary text-primary-content",
      @status == :completed && "bg-success/20 text-success",
      @status == :pending && "bg-base-200 text-base-content/40"
    ]}>
      {@label}
    </span>
    """
  end

  # ── Upload Step ─────────────────────────────────────────────────

  defp upload_step(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm">
      <div class="card-body gap-6">
        <h2 class="card-title">
          <.icon name="hero-arrow-up-tray" class="w-5 h-5" />
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Import Items")}
        </h2>

        <%!-- Upload form (catalogue + file in one form) --%>
        <form id="upload-form" phx-submit="parse_file" phx-change="validate_upload" class="space-y-6">
          <%!-- Catalogue selector --%>
          <div class="form-control w-full max-w-md">
            <span class="block mb-2 text-sm font-medium">
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Target Catalogue")}
            </span>
            <.select
              name="catalogue"
              id="upload-catalogue"
              value={@selected_catalogue && @selected_catalogue.uuid}
              prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Select a catalogue...")}
              options={
                Enum.map(
                  @catalogues,
                  &{catalogue_picker_label(&1, @catalogue_item_counts, @catalogue_category_counts), &1.uuid}
                )
              }
            />
            <p :if={@catalogues == []} class="text-sm text-base-content/50 mt-1">
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No catalogues yet.")}
              <.link navigate={Paths.catalogue_new()} class="link link-primary">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Create one first")}
              </.link>
            </p>
          </div>

          <%!-- Already parsed file --%>
          <div :if={@filename} class="flex items-center gap-3 p-4 border border-success/30 bg-success/5 rounded-lg">
            <.icon name="hero-document-check" class="w-5 h-5 text-success" />
            <div class="flex-1">
              <p class="font-medium text-sm">{@filename}</p>
              <p class="text-xs text-base-content/60">{@row_count} {Gettext.gettext(PhoenixKitCatalogue.Gettext, "rows")} — {length(@headers)} {Gettext.gettext(PhoenixKitCatalogue.Gettext, "columns")}</p>
            </div>
            <button
              type="button"
              phx-click="clear_file"
              phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Clearing...")}
              class="btn btn-xs btn-ghost text-base-content/50"
            >
              <.icon name="hero-x-mark" class="w-4 h-4" />
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Replace")}
            </button>
          </div>

          <%!-- File upload with drag-and-drop (only when no file parsed yet) --%>
          <div :if={@filename == nil} class="form-control">
            <label class="block mb-2 text-sm font-medium">
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "File")}
            </label>
            <div
              class="border-2 border-dashed border-base-300 rounded-lg p-8 text-center transition-colors cursor-pointer hover:border-primary hover:bg-primary/5"
              phx-drop-target={@uploads.import_file.ref}
            >
              <label for={@uploads.import_file.ref} class="cursor-pointer block">
                <div class="flex flex-col items-center gap-2">
                  <.icon name="hero-cloud-arrow-up" class="w-8 h-8 text-primary" />
                  <div>
                    <p class="font-semibold text-base-content">
                      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Drag file here or click to browse")}
                    </p>
                    <p class="text-sm text-base-content/70 mt-1">
                      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Supports .xlsx and .csv files (max 10MB)")}
                    </p>
                  </div>
                </div>
              </label>
              <.live_file_input upload={@uploads.import_file} class="hidden" />
            </div>

            <%!-- Selected file with progress --%>
            <div :for={entry <- @uploads.import_file.entries} class="flex items-center gap-3 p-3 mt-3 border border-base-300 rounded-lg">
              <div class="flex-1">
                <p class="font-medium text-sm truncate">{entry.client_name}</p>
                <div class="flex gap-2 items-center mt-1">
                  <progress value={entry.progress} max="100" class="progress progress-primary progress-sm flex-1">
                    {entry.progress}%
                  </progress>
                  <span class="text-xs text-base-content/60">{entry.progress}%</span>
                </div>
              </div>
              <button type="button" phx-click="cancel_upload" phx-value-ref={entry.ref} class="btn btn-xs btn-ghost text-error">
                <.icon name="hero-x-mark" class="w-4 h-4" />
              </button>
            </div>

            <%!-- Upload errors --%>
            <%= for entry <- @uploads.import_file.entries do %>
              <p :for={err <- upload_errors(@uploads.import_file, entry)} class="text-error text-sm mt-1">
                {error_to_string(err)}
              </p>
            <% end %>
          </div>

          <%!-- Action button. Stays disabled while the upload XHR is in
               flight — clicking submit before the entry is `done?` makes
               `consume_uploaded_entries` return [] and disrupts the
               in-flight upload, which looks to the user like the file
               vanished. --%>
          <% upload_in_progress? = Enum.any?(@uploads.import_file.entries, &(not &1.done?)) %>
          <button
            type="submit"
            class="btn btn-primary"
            disabled={
              cond do
                @selected_catalogue == nil -> true
                @filename -> false
                @uploads.import_file.entries == [] -> true
                upload_in_progress? -> true
                true -> false
              end
            }
          >
            <%= cond do %>
              <% @filename -> %>
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Continue")}
                <.icon name="hero-arrow-right" class="w-4 h-4" />
              <% upload_in_progress? -> %>
                <span class="loading loading-spinner loading-xs"></span>
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Uploading...")}
              <% true -> %>
                <.icon name="hero-arrow-up-tray" class="w-4 h-4" />
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Upload & Parse")}
            <% end %>
          </button>
        </form>
      </div>
    </div>
    """
  end

  # ── Map Step ────────────────────────────────────────────────────

  defp map_step(assigns) do
    all_targets =
      Mapper.available_targets()
      |> Enum.reject(fn {t, _} -> t in [:category, :manufacturer, :supplier] end)
      |> Enum.map(fn {target, label} -> {target, translate_target(label)} end)

    allowed_units = Item.allowed_units()

    assigns =
      assigns
      |> assign(:all_targets, all_targets)
      |> assign(:allowed_units, allowed_units)

    ~H"""
    <div class="card bg-base-100 shadow-sm">
      <div class="card-body gap-6">
        <h2 class="card-title">
          <.icon name="hero-arrows-right-left" class="w-5 h-5" />
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Map Columns")}
        </h2>

        <div class="flex flex-wrap items-center gap-3 text-sm text-base-content/60">
          <span>
            <.icon name="hero-document-text" class="w-4 h-4 inline" />
            {@filename}
          </span>
          <span class="badge badge-ghost badge-sm">{@row_count} {Gettext.gettext(PhoenixKitCatalogue.Gettext, "rows")}</span>
          <span :if={@selected_catalogue} class="badge badge-primary badge-sm badge-outline">{@selected_catalogue.name}</span>
        </div>

        <%!-- Sheet selector --%>
        <form :if={length(@sheets) > 1} id="sheet-form" phx-change="select_sheet" class="flex items-center gap-2">
          <span class="text-sm font-medium">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Sheet:")}</span>
          <.select
            name="sheet"
            id="import-sheet"
            value={@selected_sheet}
            options={Enum.map(@sheets, &{&1, &1})}
            class="select-sm"
          />
        </form>

        <%!-- Language selector --%>
        <div :if={@multilang_enabled}>
          <div class="flex items-center gap-2 mb-3">
            <.icon name="hero-language" class="w-5 h-5 text-primary" />
            <h2 class="card-title text-lg m-0">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Import Language")}</h2>
          </div>
          <.multilang_tabs multilang_enabled={@multilang_enabled} language_tabs={@language_tabs} current_lang={@current_lang} show_info={false} show_header={false} />
        </div>

        <%!-- Category selector --%>
        <div class="form-control w-full max-w-md">
          <span class="block mb-2 text-sm font-medium">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Import Into Category")}</span>
          <form id="category-form" phx-change="select_import_category" class="space-y-3">
            <.select
              name="category_mode"
              id="import-category-mode"
              value={
                case @import_category_mode do
                  :existing -> "existing:#{@import_category_uuid}"
                  mode -> to_string(mode)
                end
              }
              options={
                [
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No category — import items without a category"), "none"},
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Use a column — create categories from column values"), "column"},
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Create a new category — fill in the details below"), "create"}
                ] ++
                  Enum.map(@catalogue_categories, &{&1.name, "existing:#{&1.uuid}"})
              }
            />

            <%!-- Column picker for category --%>
            <div :if={@import_category_mode == :column} class="pl-4 border-l-2 border-secondary/20">
              <%!-- Cross-language match toggle. Only meaningful when
                   multilang is on — without it there's only ever one
                   language so "across languages" is a no-op. --%>
              <label
                :if={@multilang_enabled}
                class="flex items-center gap-2 mb-3 cursor-pointer text-xs text-base-content/70"
              >
                <input
                  type="checkbox"
                  name="category_match_across_languages"
                  value="true"
                  checked={@category_match_across_languages}
                  class="checkbox checkbox-xs checkbox-primary"
                />
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Match across all languages")}
                <span
                  class="tooltip tooltip-right tooltip-info"
                  data-tip={
                    Gettext.gettext(
                      PhoenixKitCatalogue.Gettext,
                      "By default the importer only matches existing categories by their name in the current import language. Turn this on to also match translations in any other language — useful for multilingual catalogues where the same category is named differently in each language."
                    )
                  }
                >
                  <.icon name="hero-information-circle" class="w-3.5 h-3.5 text-base-content/40 hover:text-base-content/70" />
                </span>
              </label>

              <% available_category_cols = available_picker_columns(@column_mappings, :category) %>
              <span class="block mb-1 text-xs text-base-content/60">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Which column contains the category names?")}</span>
              <%= if available_category_cols == [] do %>
                <p class="text-xs text-warning bg-warning/10 border border-warning/30 rounded-lg px-3 py-2">
                  {Gettext.gettext(
                    PhoenixKitCatalogue.Gettext,
                    "All columns are already mapped. Free one up by setting it to '— Skip —' in the column mapping section below, or by switching another picker (Category, Manufacturer, or Supplier) out of 'Use a column' mode."
                  )}
                </p>
              <% else %>
                <% selected_category_col =
                  Enum.find_value(available_category_cols, fn m ->
                    if m.target == :category, do: m.column_index
                  end) %>
                <.select
                  name="category_column"
                  id="import-category-column"
                  value={selected_category_col}
                  prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Select a column...")}
                  options={Enum.map(available_category_cols, &{&1.header, &1.column_index})}
                  class="select-sm"
                />
              <% end %>
              <%!-- Show preview of categories that will be created --%>
              <div :if={has_mapping?(@column_mappings, :category)} class="mt-2">
                <span class="text-xs text-base-content/60">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Categories that will be created:")}</span>
                <div class="flex flex-wrap gap-1 mt-1">
                  <% cat_mapping = Enum.find(@column_mappings, &(&1.target == :category)) %>
                  <span :for={val <- unique_column_values_from_ets(@ets_table, cat_mapping.column_index)} class="badge badge-secondary badge-outline badge-xs">{val}</span>
                </div>
              </div>
            </div>
          </form>

          <%!-- Inline new-category form (mirrors the standalone Category
               creation screen, minus its own buttons + language switcher
               since the import wizard already provides both at the top).
               Sits OUTSIDE the mode-picker form so its phx-change doesn't
               re-fire mode selection on every keystroke. --%>
          <.new_category_form
            :if={@import_category_mode == :create and @new_category_changeset}
            changeset={@new_category_changeset}
            multilang_enabled={@multilang_enabled}
            current_lang={@current_lang}
            primary_language={@primary_language}
          />
        </div>

        <%!-- Manufacturer selector --%>
        <.party_picker
          label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Set Manufacturer")}
          form_id="manufacturer-form"
          on_change="select_import_manufacturer"
          mode_field="manufacturer_mode"
          column_field="manufacturer_column"
          mode={@import_manufacturer_mode}
          uuid={@import_manufacturer_uuid}
          options={@manufacturers}
          column_mappings={@column_mappings}
          ets_table={@ets_table}
          target={:manufacturer}
          none_label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "No manufacturer — items imported without a maker")}
          column_label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Use a column — create or match manufacturers from column values")}
          create_label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Create a new manufacturer — fill in the details below")}
          column_picker_prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Which column contains the manufacturer names?")}
          preview_label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Manufacturers that will be created or matched:")}
        />

        <.new_party_form
          :if={@import_manufacturer_mode == :create and @new_manufacturer_changeset}
          form_id="new-manufacturer-form"
          form_prefix="manufacturer"
          on_change="validate_new_manufacturer"
          changeset={@new_manufacturer_changeset}
          name_placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "e.g., Blum")}
        />

        <%!-- Supplier selector --%>
        <.party_picker
          label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Link to Supplier")}
          form_id="supplier-form"
          on_change="select_import_supplier"
          mode_field="supplier_mode"
          column_field="supplier_column"
          mode={@import_supplier_mode}
          uuid={@import_supplier_uuid}
          options={@suppliers}
          column_mappings={@column_mappings}
          ets_table={@ets_table}
          target={:supplier}
          none_label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "No supplier — leave manufacturers unlinked")}
          column_label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Use a column — link per-row supplier to row's manufacturer")}
          create_label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Create a new supplier — link to all touched manufacturers")}
          column_picker_prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Which column contains the supplier names?")}
          preview_label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Suppliers that will be created or matched:")}
        />

        <.new_party_form
          :if={@import_supplier_mode == :create and @new_supplier_changeset}
          form_id="new-supplier-form"
          form_prefix="supplier"
          on_change="validate_new_supplier"
          changeset={@new_supplier_changeset}
          name_placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "e.g., Acme Distributors")}
        />

        <p class="text-sm text-base-content/60">
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Choose where each column should be imported to.")}
        </p>

        <form id="mapping-form" phx-change="mapping_form_change" phx-submit="continue_to_confirm">
        <%!-- Column mapping cards --%>
        <div class="grid gap-3">
          <%= for mapping <- @column_mappings do %>
            <div class="p-3 bg-base-200/50 rounded-lg">
              <div class="flex flex-col sm:flex-row sm:items-center gap-2">
                <div class="font-medium min-w-[180px] flex items-center gap-2">
                  <.icon name="hero-document-text" class="w-4 h-4 text-base-content/40" />
                  {mapping.header}
                </div>
                <.icon name="hero-arrow-right" class="w-4 h-4 text-base-content/30 hidden sm:block" />
                <.select
                  name={"mapping[#{mapping.column_index}]"}
                  id={"mapping-#{mapping.column_index}"}
                  value={target_to_string(mapping.target)}
                  options={Enum.map(@all_targets, fn {target, label} -> {label, target_to_string(target)} end)}
                  class="select-sm flex-1"
                />
              </div>

              <%!-- Inline unit value mapping (shows when this column is mapped to Unit) --%>
              <div :if={mapping.target == :unit and @unit_values != []} class="mt-3 ml-6 pl-4 border-l-2 border-primary/20">
                <p class="text-xs text-base-content/60 mb-2">
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Map each value to a system unit:")}
                </p>
                <div class="grid gap-1.5">
                  <div :for={value <- @unit_values} class="flex items-center gap-2">
                    <span class="badge badge-outline badge-sm min-w-[60px] justify-center">{value}</span>
                    <.icon name="hero-arrow-right" class="w-3 h-3 text-base-content/30" />
                    <.select
                      name={"unit_map[#{value}]"}
                      id={"unit-map-#{value}"}
                      value={Map.get(@unit_map, value, "piece")}
                      options={Enum.map(@allowed_units, &{&1, &1})}
                      class="select-xs"
                    />
                  </div>
                </div>
              </div>

            </div>
          <% end %>
        </div>

        </form>

        <%!-- Data preview. The collapse `<input>` carries an `id` so
             morphdom preserves the open/closed state across LiveView
             patches; without it the panel snaps shut on every diff. --%>
        <div class="collapse collapse-arrow bg-base-200/30 border border-base-300">
          <input type="checkbox" id="sample-data-collapse" />
          <div class="collapse-title text-sm font-medium">
            <.icon name="hero-table-cells" class="w-4 h-4 inline" />
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Sample Data (first 5 rows)")}
          </div>
          <div class="collapse-content overflow-x-auto">
            <table class="table table-sm table-zebra [&_th]:border-r [&_th]:border-base-300 [&_td]:border-r [&_td]:border-base-300 [&_th:last-child]:border-r-0 [&_td:last-child]:border-r-0">
              <thead>
                <tr>
                  <th class="bg-base-200 font-semibold text-xs w-8 text-base-content/40">#</th>
                  <th :for={header <- @headers} class="bg-base-200 font-semibold text-xs">{header}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={{row, idx} <- Enum.with_index(@preview_rows, 1)}>
                  <td class="text-xs text-base-content/40 tabular-nums">{idx}</td>
                  <td :for={cell <- row} title={cell} class="max-w-[200px] truncate text-xs">{cell}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div class="flex gap-2">
          <button class="btn btn-ghost btn-sm" phx-click="go_back">
            <.icon name="hero-arrow-left" class="w-4 h-4" />
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Back")}
          </button>
          <button
            class="btn btn-primary btn-sm"
            phx-click="continue_to_confirm"
            phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Validating...")}
          >
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Continue to Confirm")}
            <.icon name="hero-arrow-right" class="w-4 h-4" />
          </button>
        </div>
      </div>
    </div>
    """
  end

  # ── Confirm Step ────────────────────────────────────────────────

  defp confirm_step(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm">
      <div class="card-body gap-4">
        <h2 class="card-title">
          <.icon name="hero-clipboard-document-check" class="w-5 h-5" />
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Confirm Import")}
        </h2>

        <%!-- Stats --%>
        <div class="stats shadow">
          <div class="stat">
            <div class="stat-title">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Items")}</div>
            <div class="stat-value text-primary">{@import_plan.stats.valid}</div>
          </div>
          <div :if={@import_plan.categories_to_create != []} class="stat">
            <div class="stat-title">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "New Categories")}</div>
            <div class="stat-value text-secondary">{length(@import_plan.categories_to_create)}</div>
          </div>
          <div :if={@import_plan.stats.invalid > 0} class="stat">
            <div class="stat-title">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Errors")}</div>
            <div class="stat-value text-error">{@import_plan.stats.invalid}</div>
          </div>
        </div>

        <%!-- Categories to create --%>
        <div :if={@import_plan.categories_to_create != []} class="text-sm">
          <h3 class="font-semibold mb-1">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Categories to create:")}</h3>
          <div class="flex flex-wrap gap-1">
            <span :for={cat <- @import_plan.categories_to_create} class="badge badge-secondary badge-outline badge-sm">{cat}</span>
          </div>
        </div>

        <%!-- Preview table --%>
        <div class="overflow-x-auto">
          <table class="table table-sm table-zebra">
            <thead>
              <tr>
                <th class="bg-base-200">#</th>
                <th :if={has_mapping?(@column_mappings, :name)} class="bg-base-200">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Name")}</th>
                <th :if={has_mapping?(@column_mappings, :sku)} class="bg-base-200">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Article Code")}</th>
                <th :if={has_mapping?(@column_mappings, :base_price)} class="bg-base-200">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Price")}</th>
                <th :if={has_mapping?(@column_mappings, :markup_percentage)} class="bg-base-200">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Markup %")}</th>
                <th :if={has_mapping?(@column_mappings, :unit)} class="bg-base-200">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Unit")}</th>
                <th :if={has_mapping?(@column_mappings, :category)} class="bg-base-200">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{item, idx} <- @import_plan.items |> Enum.take(20) |> Enum.with_index(1)}>
                <td class="text-base-content/40">{idx}</td>
                <td :if={has_mapping?(@column_mappings, :name)}>{item[:name]}</td>
                <td :if={has_mapping?(@column_mappings, :sku)}>{item[:sku]}</td>
                <td :if={has_mapping?(@column_mappings, :base_price)}>{item[:base_price]}</td>
                <td :if={has_mapping?(@column_mappings, :markup_percentage)}>{item[:markup_percentage]}</td>
                <td :if={has_mapping?(@column_mappings, :unit)}>{item[:unit]}</td>
                <td :if={has_mapping?(@column_mappings, :category)}>{item[:_category_name]}</td>
              </tr>
            </tbody>
          </table>
          <p :if={length(@import_plan.items) > 20} class="text-sm text-base-content/50 mt-2">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Showing first 20 of %{count} items.", count: length(@import_plan.items))}
          </p>
        </div>

        <%!-- Errors --%>
        <div :if={@import_plan.errors != []} class="alert alert-warning">
          <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
          <div>
            <h3 class="font-bold">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Rows with errors (will be skipped):")}</h3>
            <div class="text-sm mt-1">
              <p :for={{row_idx, reason} <- Enum.take(@import_plan.errors, 10)}>
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Row %{row}: %{reason}", row: row_idx, reason: translate_error(reason))}
              </p>
            </div>
          </div>
        </div>

        <%!-- Duplicate warnings --%>
        <div :if={@duplicate_row_count > 0 or @existing_duplicate_count > 0} class="alert alert-warning">
          <.icon name="hero-exclamation-triangle" class="w-5 h-5 shrink-0" />
          <div class="flex-1">
            <div class="text-sm font-medium space-y-1">
              <p :if={@duplicate_row_count > 0}>
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "%{count} rows in your file are identical duplicates.", count: @duplicate_row_count)}
              </p>
              <p :if={@existing_duplicate_count > 0}>
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "%{count} items already exist in this catalogue with identical data.", count: @existing_duplicate_count)}
              </p>
            </div>
            <form id="duplicate-form" phx-change="set_duplicate_mode" class="mt-2 flex flex-col gap-1.5">
              <label class="flex items-center gap-2 cursor-pointer">
                <input type="radio" name="mode" class="radio radio-sm radio-warning" value="import" checked={@duplicate_mode == :import} />
                <span class="text-sm">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Import all — create everything including duplicates")}</span>
              </label>
              <label class="flex items-center gap-2 cursor-pointer">
                <input type="radio" name="mode" class="radio radio-sm radio-warning" value="skip" checked={@duplicate_mode == :skip} />
                <span class="text-sm">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Skip duplicates — only import new, unique items")}</span>
              </label>
            </form>
          </div>
        </div>

        <div class="flex gap-2">
          <button class="btn btn-ghost btn-sm" phx-click="back_to_mapping">
            <.icon name="hero-arrow-left" class="w-4 h-4" />
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Back to Mapping")}
          </button>
          <button
            class="btn btn-primary btn-sm"
            phx-click="execute_import"
            phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Starting import...")}
          >
            <.icon name="hero-play" class="w-4 h-4" />
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Import %{count} Items", count: @import_plan.stats.valid)}
          </button>
        </div>
      </div>
    </div>
    """
  end

  # ── Importing Step ──────────────────────────────────────────────

  defp importing_step(assigns) do
    pct =
      if assigns.import_total > 0,
        do: round(assigns.import_progress / assigns.import_total * 100),
        else: 0

    assigns = assign(assigns, :pct, pct)

    ~H"""
    <div class="card bg-base-100 shadow-sm">
      <div class="card-body items-center gap-4 py-12">
        <span class="loading loading-spinner loading-lg text-primary"></span>
        <h2 class="text-lg font-semibold">
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Importing...")}
        </h2>
        <progress class="progress progress-primary w-full max-w-md" value={@pct} max="100"></progress>
        <p class="text-sm text-base-content/60">
          {@import_progress} / {@import_total} {Gettext.gettext(PhoenixKitCatalogue.Gettext, "items")}
        </p>
      </div>
    </div>
    """
  end

  # ── Done Step ───────────────────────────────────────────────────

  defp done_step(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm">
      <div class="card-body items-center gap-4 py-12">
        <div class="text-success">
          <.icon name="hero-check-circle" class="w-16 h-16" />
        </div>
        <h2 class="text-xl font-bold">
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Import Complete")}
        </h2>

        <div :if={@import_result} class="stats shadow">
          <div class="stat">
            <div class="stat-title">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Created")}</div>
            <div class="stat-value text-success">{@import_result.created}</div>
          </div>
          <div :if={@import_result.categories_created > 0} class="stat">
            <div class="stat-title">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Categories")}</div>
            <div class="stat-value text-secondary">{@import_result.categories_created}</div>
          </div>
        </div>

        <div :if={@import_result && @import_result.errors != []} class="alert alert-error max-w-md">
          <div class="text-sm">
            <p :for={{row_idx, reason} <- Enum.take(@import_result.errors, 10)}>
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Row %{row}: %{reason}", row: row_idx, reason: translate_error(reason))}
            </p>
          </div>
        </div>

        <div class="flex gap-2 mt-4">
          <.link :if={@selected_catalogue} navigate={Paths.catalogue_detail(@selected_catalogue.uuid)} class="btn btn-primary btn-sm">
            <.icon name="hero-eye" class="w-4 h-4" />
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "View Catalogue")}
          </.link>
          <button class="btn btn-ghost btn-sm" phx-click="import_another">
            <.icon name="hero-arrow-path" class="w-4 h-4" />
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Import Another")}
          </button>
        </div>
      </div>
    </div>
    """
  end

  # ── Private helpers ─────────────────────────────────────────────

  # Builds the label shown for one catalogue in the Target Catalogue
  # picker. Counts are passed in as separate `%{uuid => count}` maps so
  # the picker stays a thin renderer over data the LiveView already
  # has — no per-option DB lookups, no N+1.
  defp catalogue_picker_label(cat, item_counts, category_counts) do
    items = Map.get(item_counts, cat.uuid, 0)
    categories = Map.get(category_counts, cat.uuid, 0)

    items_label =
      Gettext.ngettext(PhoenixKitCatalogue.Gettext, "%{count} item", "%{count} items", items,
        count: items
      )

    categories_label =
      Gettext.ngettext(
        PhoenixKitCatalogue.Gettext,
        "%{count} category",
        "%{count} categories",
        categories,
        count: categories
      )

    "#{cat.name} · #{categories_label} · #{items_label}"
  end

  defp translate_target("— Skip —"), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "— Skip —")

  defp translate_target("Item Name"),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Item Name")

  defp translate_target("Description"),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Description")

  defp translate_target("Article Code"),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Article Code")

  defp translate_target("Base Price"),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Base Price")

  defp translate_target("Markup Override (%)"),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Markup Override (%)")

  defp translate_target("Unit of Measure"),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Unit of Measure")

  defp translate_target("Manufacturer"),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Manufacturer")

  defp translate_target("Supplier"), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Supplier")

  defp translate_target("Create Categories"),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Create Categories")

  defp translate_target(label), do: label

  defp translate_error(reason), do: PhoenixKitCatalogue.Errors.message(reason)

  defp unique_column_values_from_ets(nil, _col_idx), do: []

  defp unique_column_values_from_ets(ets_table, col_idx) do
    rows = ets_to_rows(ets_table)
    Mapper.unique_column_values(rows, col_idx)
  end

  defp detect_unit_values(mappings, rows) do
    unit_mapping = Enum.find(mappings, &(&1.target == :unit))

    case unit_mapping do
      nil ->
        {[], %{}}

      %{column_index: idx} ->
        values = Mapper.unique_column_values(rows, idx)
        default_map = Map.new(values, fn v -> {v, Mapper.normalize_unit(v)} end)
        {values, default_map}
    end
  end

  defp ets_to_rows(nil), do: []

  defp ets_to_rows(ets_table) do
    :ets.tab2list(ets_table)
    |> Enum.sort_by(fn {idx, _} -> idx end)
    |> Enum.map(fn {_, row} -> row end)
  end

  defp target_to_string(:skip), do: "skip"
  defp target_to_string(:name), do: "name"
  defp target_to_string(:description), do: "description"
  defp target_to_string(:sku), do: "sku"
  defp target_to_string(:base_price), do: "base_price"
  defp target_to_string(:markup_percentage), do: "markup_percentage"
  defp target_to_string(:unit), do: "unit"
  defp target_to_string(:category), do: "category"
  defp target_to_string(:manufacturer), do: "manufacturer"
  defp target_to_string(:supplier), do: "supplier"
  defp target_to_string({:data, name}), do: "data:#{name}"

  defp parse_target("skip"), do: :skip
  defp parse_target("name"), do: :name
  defp parse_target("description"), do: :description
  defp parse_target("sku"), do: :sku
  defp parse_target("base_price"), do: :base_price
  defp parse_target("markup_percentage"), do: :markup_percentage
  defp parse_target("unit"), do: :unit
  defp parse_target("category"), do: :category
  defp parse_target("manufacturer"), do: :manufacturer
  defp parse_target("supplier"), do: :supplier
  defp parse_target("data:" <> name), do: {:data, name}
  defp parse_target(_), do: :skip

  defp has_mapping?(mappings, target) do
    Enum.any?(mappings, &(&1.target == target))
  end

  # Columns the picker is allowed to offer in its column dropdown.
  # We hide columns already mapped to *another* unique target so a
  # picker selection can't silently steal a column from `:name` /
  # `:sku` / etc. — losing those mappings would surface as a
  # "must map at least one column to 'Item Name'" error at the
  # confirm step with no clue why.
  #
  # We always keep:
  #   - the column already mapped to this picker's target (so it
  #     stays visible/selectable for re-selection)
  #   - unmapped columns (`:skip`) — the natural candidates
  #   - custom-data columns (`{:data, _}`) — non-unique by definition
  defp available_picker_columns(mappings, picker_target) do
    Enum.filter(mappings, fn m ->
      cond do
        m.target == picker_target -> true
        m.target == :skip -> true
        match?({:data, _}, m.target) -> true
        true -> false
      end
    end)
  end

  defp error_to_string(:too_large),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "File is too large (max 10MB)")

  defp error_to_string(:too_many_files),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Only one file allowed")

  defp error_to_string(:not_accepted),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "File type not supported. Use .xlsx or .csv")

  defp error_to_string(err), do: inspect(err)

  defp log_import_started(socket, import_plan) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      catalogue = socket.assigns[:selected_catalogue]

      PhoenixKit.Activity.log(%{
        action: "import.started",
        module: "catalogue",
        mode: "manual",
        actor_uuid: extract_actor_uuid(socket),
        resource_type: "catalogue",
        resource_uuid: catalogue && catalogue.uuid,
        metadata: %{
          "catalogue_name" => (catalogue && catalogue.name) || "",
          "items_planned" => length(import_plan.items || []),
          "categories_planned" => length(import_plan.categories_to_create || []),
          "filename" => socket.assigns[:filename] || ""
        }
      })
    end
  rescue
    e ->
      Logger.warning("[Catalogue.Import] Failed to log import.started: #{Exception.message(e)}")
  end

  defp log_import_activity(socket, result) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      PhoenixKit.Activity.log(build_import_log(socket, result))
    end
  rescue
    e ->
      Logger.warning("[Catalogue.Import] Failed to log import.completed: #{Exception.message(e)}")
  end

  defp build_import_log(socket, result) do
    catalogue = socket.assigns[:selected_catalogue]

    %{
      action: "import.completed",
      module: "catalogue",
      mode: "manual",
      actor_uuid: extract_actor_uuid(socket),
      resource_type: "catalogue",
      resource_uuid: catalogue && catalogue.uuid,
      metadata: import_log_metadata(socket, catalogue, result)
    }
  end

  defp import_log_metadata(socket, catalogue, result) do
    %{
      "catalogue_name" => catalogue_name(catalogue),
      "filename" => socket.assigns[:filename] || "",
      "items_created" => count_field(result, :created),
      "categories_created" => count_field(result, :categories_created),
      "manufacturers_created" => count_field(result, :manufacturers_created),
      "suppliers_created" => count_field(result, :suppliers_created),
      "manufacturer_supplier_links_created" =>
        count_field(result, :manufacturer_supplier_links_created),
      "errors" => length(result[:errors] || [])
    }
  end

  defp catalogue_name(nil), do: ""
  defp catalogue_name(%{name: name}) when is_binary(name), do: name
  defp catalogue_name(_), do: ""

  defp count_field(result, key), do: result[key] || 0

  defp extract_actor_uuid(socket) do
    case socket.assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} -> uuid
      _ -> nil
    end
  end
end
