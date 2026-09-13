defmodule PhoenixKitCatalogue.Web.ImportLiveWizardTest do
  @moduledoc """
  Drives ImportLive past the upload step via state injection so the
  mapping / confirm / execute event branches actually run. The
  upload step is exercised separately by `import_live_test.exs`
  (mount + catalogue selection + clear_file paths).

  ImportLive has no `:sync_complete`-style DB-reload handler that
  would clobber injected state (the Drive-bound LV trap from
  document_creator's Batch 5 doesn't apply here), so
  `:sys.replace_state/3` works cleanly.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  @import_url "/en/admin/catalogue/import"

  setup do
    cat = fixture_catalogue(%{name: "Wizard Test Cat"})
    %{catalogue: cat}
  end

  describe "mapping step — update_mapping / mapping_form_change" do
    test "a crafted column, a data: target, and a non-map mapping are all ignored (sweep 2026-09-13)",
         %{conn: conn, catalogue: cat} do
      view = mount_at_map_step(conn, cat)

      render_change(view, "update_mapping", %{"column" => "x", "target" => "name"})

      render_change(view, "update_mapping", %{
        "column" => "0",
        "target" => "data:featured_image_uuid"
      })

      render_change(view, "update_mapping", %{"column" => ["0"], "target" => "name"})
      render_change(view, "mapping_form_change", %{"mapping" => "x", "unit_map" => "y"})
      render_change(view, "select_import_category", %{"category_column" => "nope"})

      assert Process.alive?(view.pid)
      mappings = current_assigns(view).column_mappings
      refute Enum.any?(mappings, &match?({:data, _}, &1.target))
      assert Enum.find(mappings, &(&1.column_index == 0)).target == :skip
    end

    test "update_mapping sets a column to :name", %{conn: conn, catalogue: cat} do
      view = mount_at_map_step(conn, cat)

      render_change(view, "update_mapping", %{"column" => "0", "target" => "name"})

      mappings = current_assigns(view).column_mappings
      assert Enum.any?(mappings, &(&1.column_index == 0 and &1.target == :name))
    end

    test "update_mapping resets a previous column when target is unique",
         %{conn: conn, catalogue: cat} do
      # Two columns claim :name; the second should win, the first reset to :skip.
      view = mount_at_map_step(conn, cat, headers: ~w(c0 c1 c2))

      render_change(view, "update_mapping", %{"column" => "0", "target" => "name"})
      render_change(view, "update_mapping", %{"column" => "1", "target" => "name"})

      mappings = current_assigns(view).column_mappings
      col0 = Enum.find(mappings, &(&1.column_index == 0))
      col1 = Enum.find(mappings, &(&1.column_index == 1))

      assert col1.target == :name

      assert col0.target == :skip,
             "Expected the prior :name column to reset to :skip, got #{inspect(col0.target)}"
    end

    test "mapping_form_change is a no-op with empty params", %{conn: conn, catalogue: cat} do
      view = mount_at_map_step(conn, cat)
      before = current_assigns(view).column_mappings

      render_change(view, "mapping_form_change", %{})

      assert current_assigns(view).column_mappings == before
    end

    test "update_unit_map records the source-to-target mapping", %{conn: conn, catalogue: cat} do
      view = mount_at_map_step(conn, cat)

      render_change(view, "update_unit_map", %{"source" => "kg", "target" => "kilogram"})

      assert current_assigns(view).unit_map == %{"kg" => "kilogram"}
    end
  end

  describe "continue_to_confirm — guard branches" do
    test "without a :name mapping flashes an error", %{conn: conn, catalogue: cat} do
      view = mount_at_map_step(conn, cat)

      html = render_click(view, "continue_to_confirm", %{})

      assert html =~ "must map at least one column"
      assert current_assigns(view).step == :map
    end
  end

  describe "back_to_mapping" do
    test "returns to :map step from :confirm", %{conn: conn, catalogue: cat} do
      view = mount_at_confirm_step(conn, cat)

      render_click(view, "back_to_mapping", %{})

      assert current_assigns(view).step == :map
      assert current_assigns(view).import_plan == nil
    end
  end

  describe "category / manufacturer / supplier picker modes" do
    test "select_import_category — :none mode clears uuid", %{conn: conn, catalogue: cat} do
      view = mount_at_map_step(conn, cat)

      render_change(view, "select_import_category", %{"category_mode" => "none"})

      assert current_assigns(view).import_category_mode == :none
      assert current_assigns(view).import_category_uuid == nil
    end

    test "select_import_category — :create mode clears uuid + builds changeset",
         %{conn: conn, catalogue: cat} do
      view = mount_at_map_step(conn, cat)

      render_change(view, "select_import_category", %{"category_mode" => "create"})

      assigns = current_assigns(view)
      assert assigns.import_category_mode == :create
      assert assigns.import_category_uuid == nil
      assert match?(%Ecto.Changeset{}, assigns.new_category_changeset)
    end

    test "validate_new_category updates the changeset", %{conn: conn, catalogue: cat} do
      view = mount_at_map_step(conn, cat)

      render_change(view, "select_import_category", %{"category_mode" => "create"})

      render_change(view, "validate_new_category", %{
        "category" => %{"name" => "Imported", "catalogue_uuid" => cat.uuid}
      })

      cs = current_assigns(view).new_category_changeset
      assert Ecto.Changeset.get_field(cs, :name) == "Imported"
    end

    test "select_import_manufacturer flips to :create + builds changeset",
         %{conn: conn, catalogue: cat} do
      view = mount_at_map_step(conn, cat)

      render_change(view, "select_import_manufacturer", %{"manufacturer_mode" => "create"})

      assigns = current_assigns(view)
      assert assigns.import_manufacturer_mode == :create
      assert match?(%Ecto.Changeset{}, assigns.new_manufacturer_changeset)
    end

    test "select_import_supplier flips to :create + builds changeset",
         %{conn: conn, catalogue: cat} do
      view = mount_at_map_step(conn, cat)

      render_change(view, "select_import_supplier", %{"supplier_mode" => "create"})

      assigns = current_assigns(view)
      assert assigns.import_supplier_mode == :create
      assert match?(%Ecto.Changeset{}, assigns.new_supplier_changeset)
    end

    test "validate_new_manufacturer updates the changeset", %{conn: conn, catalogue: cat} do
      view = mount_at_map_step(conn, cat)
      render_change(view, "select_import_manufacturer", %{"manufacturer_mode" => "create"})

      render_change(view, "validate_new_manufacturer", %{"manufacturer" => %{"name" => "Acme"}})

      cs = current_assigns(view).new_manufacturer_changeset
      assert Ecto.Changeset.get_field(cs, :name) == "Acme"
    end

    test "validate_new_supplier updates the changeset", %{conn: conn, catalogue: cat} do
      view = mount_at_map_step(conn, cat)
      render_change(view, "select_import_supplier", %{"supplier_mode" => "create"})

      render_change(view, "validate_new_supplier", %{"supplier" => %{"name" => "Wholesale"}})

      cs = current_assigns(view).new_supplier_changeset
      assert Ecto.Changeset.get_field(cs, :name) == "Wholesale"
    end
  end

  describe "language + duplicate mode toggles" do
    test "switch_language sets the active language", %{conn: conn, catalogue: cat} do
      view = mount_at_map_step(conn, cat)

      render_change(view, "switch_language", %{"lang" => "fi"})

      assert current_assigns(view).current_lang == "fi"
    end

    test "set_duplicate_mode :skip", %{conn: conn, catalogue: cat} do
      view = mount_at_map_step(conn, cat)

      render_change(view, "set_duplicate_mode", %{"mode" => "skip"})

      assert current_assigns(view).duplicate_mode == :skip
    end

    test "set_duplicate_mode :import", %{conn: conn, catalogue: cat} do
      view = mount_at_map_step(conn, cat)
      render_change(view, "set_duplicate_mode", %{"mode" => "skip"})

      render_change(view, "set_duplicate_mode", %{"mode" => "import"})

      assert current_assigns(view).duplicate_mode == :import
    end
  end

  describe "navigation events" do
    test "import_another resets back to upload", %{conn: conn, catalogue: cat} do
      view = mount_at_map_step(conn, cat)

      render_click(view, "import_another", %{})

      assigns = current_assigns(view)
      assert assigns.step == :upload
      assert assigns.filename == nil
    end

    test "go_back from :map returns to :upload", %{conn: conn, catalogue: cat} do
      view = mount_at_map_step(conn, cat)

      render_click(view, "go_back", %{})

      assert current_assigns(view).step == :upload
    end

    test "go_back from :confirm returns to :map", %{conn: conn, catalogue: cat} do
      view = mount_at_confirm_step(conn, cat)

      render_click(view, "go_back", %{})

      assert current_assigns(view).step == :map
    end
  end

  # ── helpers ─────────────────────────────────────────────────────

  defp current_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # Mounts the LV and uses :sys.replace_state to push it past the
  # upload step into :map with a tiny synthetic file. ImportLive
  # doesn't reload its state from the DB on broadcasts, so injection
  # is stable.
  defp mount_at_map_step(conn, catalogue, opts \\ []) do
    headers = Keyword.get(opts, :headers, ~w(name description sku))
    rows = [["Item A", "desc", "SKU1"], ["Item B", "desc2", "SKU2"]]

    {:ok, view, _html} = live(conn, @import_url <> "?catalogue=#{catalogue.uuid}")

    ets_name = String.to_atom("test_import_rows_#{System.unique_integer([:positive])}")
    ets_table = :ets.new(ets_name, [:public, :ordered_set])

    Enum.with_index(rows)
    |> Enum.each(fn {row, idx} -> :ets.insert(ets_table, {idx, row}) end)

    column_mappings =
      headers
      |> Enum.with_index()
      |> Enum.map(fn {label, idx} ->
        %{column_index: idx, header: label, target: :skip}
      end)

    :sys.replace_state(view.pid, fn state ->
      socket = state.socket

      assigns =
        socket.assigns
        |> Map.put(:step, :map)
        |> Map.put(:selected_catalogue, catalogue)
        |> Map.put(:headers, headers)
        |> Map.put(:preview_rows, rows)
        |> Map.put(:row_count, length(rows))
        |> Map.put(:filename, "test.csv")
        |> Map.put(:column_mappings, column_mappings)
        |> Map.put(:ets_table, ets_table)

      put_in(state.socket.assigns, assigns)
    end)

    view
  end

  defp mount_at_confirm_step(conn, catalogue) do
    view = mount_at_map_step(conn, catalogue)
    # Force into confirm step with a minimal import_plan to satisfy
    # render. back_to_mapping clears it.
    :sys.replace_state(view.pid, fn state ->
      assigns =
        state.socket.assigns
        |> Map.put(:step, :confirm)
        |> Map.put(:import_plan, %{items: []})
        |> Map.put(:duplicate_row_count, 0)

      put_in(state.socket.assigns, assigns)
    end)

    view
  end
end
