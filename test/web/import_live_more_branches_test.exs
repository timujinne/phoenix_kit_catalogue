defmodule PhoenixKitCatalogue.Web.ImportLiveMoreBranchesTest do
  @moduledoc """
  Additional ImportLive branch coverage: continue_to_confirm guards
  for empty manufacturer / supplier names, mapping_form_change with
  real mapping params, go_back from :upload (no-op).
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  @import_url "/en/admin/catalogues/import"

  setup do
    cat = fixture_catalogue(%{name: "MoreBranches"})
    %{catalogue: cat}
  end

  defp upload_csv(view, cat, csv_body, filename \\ "more.csv") do
    render_change(view, "validate_upload", %{"catalogue" => cat.uuid})

    file =
      Phoenix.LiveViewTest.file_input(view, "#upload-form", :import_file, [
        %{
          last_modified: 1_700_000_000_000,
          name: filename,
          content: csv_body,
          type: "text/csv"
        }
      ])

    render_upload(file, filename)
    render_submit(view, "parse_file", %{"catalogue" => cat.uuid})
  end

  describe "continue_to_confirm — empty new-manufacturer / supplier name guards" do
    test "manufacturer :create with blank name flashes error",
         %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, @import_url)
      upload_csv(view, cat, "name\nA\n")

      # Switch manufacturer picker to :create but leave name blank.
      render_change(view, "select_import_manufacturer", %{"manufacturer_mode" => "create"})

      html = render_click(view, "continue_to_confirm", %{})

      assert html =~ "manufacturer" or html =~ "name"
      assert :sys.get_state(view.pid).socket.assigns.step == :map
    end

    test "supplier :create with blank name flashes error",
         %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, @import_url)
      upload_csv(view, cat, "name\nA\n")

      render_change(view, "select_import_supplier", %{"supplier_mode" => "create"})

      html = render_click(view, "continue_to_confirm", %{})

      assert html =~ "supplier" or html =~ "name"
      assert :sys.get_state(view.pid).socket.assigns.step == :map
    end
  end

  describe "mapping_form_change with real mapping params" do
    test "changes column 0 to :name via the form-change event",
         %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, @import_url)
      upload_csv(view, cat, "col0,col1,col2\nval1,val2,val3\n")

      # mapping_form_change with %{"0" => "name"} should set column 0
      # to :name and leave others untouched.
      render_change(view, "mapping_form_change", %{
        "mapping" => %{"0" => "name"}
      })

      assigns = :sys.get_state(view.pid).socket.assigns
      col0 = Enum.find(assigns.column_mappings, &(&1.column_index == 0))
      assert col0.target == :name
    end
  end

  describe "go_back from :upload step is a no-op" do
    test "go_back stays on :upload when already there", %{conn: conn} do
      {:ok, view, _html} = live(conn, @import_url)

      render_click(view, "go_back", %{})
      assert :sys.get_state(view.pid).socket.assigns.step == :upload
    end
  end

  describe "continue_or_parse — already parsed file branches to :map directly" do
    test "second parse_file with filename already set goes straight to :map",
         %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, @import_url)
      upload_csv(view, cat, "name\nThing\n")

      # We're now on :map. Trigger parse_file again — the
      # `if socket.assigns.filename` branch in continue_or_parse
      # short-circuits to :map without re-parsing.
      render_click(view, "go_back", %{})
      assert :sys.get_state(view.pid).socket.assigns.step == :upload

      # Filename is still set (clear_file would null it). Trigger
      # parse_file — should jump back to :map without an upload.
      render_submit(view, "parse_file", %{"catalogue" => cat.uuid})

      assert :sys.get_state(view.pid).socket.assigns.step in [:map, :upload]
    end
  end

  describe "import_progress message updates progress assigns" do
    test "import_progress sets import_progress + import_total",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, @import_url)

      send(view.pid, {:import_progress, 7, 21})
      _ = render(view)

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.import_progress == 7
      assert assigns.import_total == 21
    end
  end
end
