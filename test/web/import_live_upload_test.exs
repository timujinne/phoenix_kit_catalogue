defmodule PhoenixKitCatalogue.Web.ImportLiveUploadTest do
  @moduledoc """
  Drives ImportLive's upload pipeline (parse_file → handle_parsed_file
  → :map step) using `Phoenix.LiveViewTest.file_input/3`, which is
  built into phoenix_live_view (no external test deps). Together
  with `import_live_wizard_test.exs` (state-injected mapping/confirm
  branches) this brings the upload-driven branches under test.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  @import_url "/en/admin/catalogue/import"

  setup do
    cat = fixture_catalogue(%{name: "Upload Test Cat"})
    %{catalogue: cat}
  end

  describe "parse_file — happy path with a CSV upload" do
    test "valid CSV transitions LV from :upload to :map step",
         %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, @import_url)

      # Select the catalogue first so parse_file isn't blocked.
      render_change(view, "validate_upload", %{"catalogue" => cat.uuid})

      csv = """
      name,description,sku
      Item A,first description,SKU1
      Item B,second description,SKU2
      Item C,,SKU3
      """

      file = build_file_input(view, "items.csv", "text/csv", csv)
      render_upload(file, "items.csv")

      # Trigger the parse_file event with the catalogue param.
      render_submit(view, "parse_file", %{"catalogue" => cat.uuid})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.step == :map
      assert assigns.headers == ~w(name description sku)
      assert assigns.row_count == 3
      assert assigns.filename == "items.csv"
    end

    test "auto-detects column mappings on upload", %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, @import_url)
      render_change(view, "validate_upload", %{"catalogue" => cat.uuid})

      csv = "Name,Article Code,Base Price\nThing,SKU1,9.99\n"
      file = build_file_input(view, "auto.csv", "text/csv", csv)
      render_upload(file, "auto.csv")
      render_submit(view, "parse_file", %{"catalogue" => cat.uuid})

      mappings = :sys.get_state(view.pid).socket.assigns.column_mappings
      # Auto-detect should map "Name" → :name, "Article Code" → :sku,
      # "Base Price" → :base_price (case-insensitive header match).
      assert Enum.any?(mappings, &(&1.target == :name))
      assert Enum.any?(mappings, &(&1.target == :sku))
      assert Enum.any?(mappings, &(&1.target == :base_price))
    end
  end

  describe "parse_file — guard branches" do
    test "parse_file with no selected catalogue flashes error",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, @import_url)

      # No catalogue selected. parse_file's guard fires before any
      # upload-consume.
      html = render_submit(view, "parse_file", %{})

      assert html =~ "Please select a catalogue first"
    end

    test "parse_file without an uploaded entry flashes 'please upload a file'",
         %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, @import_url)
      render_change(view, "validate_upload", %{"catalogue" => cat.uuid})

      html = render_submit(view, "parse_file", %{"catalogue" => cat.uuid})

      assert html =~ "Please upload a file"
    end
  end

  describe "Parser.parse — invalid binary surfaces a flash error" do
    test "header-only CSV (no rows) survives without crashing",
         %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, @import_url)
      render_change(view, "validate_upload", %{"catalogue" => cat.uuid})

      # Header line only, no data rows. Parser may return :ok with 0
      # rows or {:error, _}; the structural guarantee we pin is that
      # the LV doesn't crash.
      file = build_file_input(view, "headers_only.csv", "text/csv", "name,sku\n")
      render_upload(file, "headers_only.csv")

      html = render_submit(view, "parse_file", %{"catalogue" => cat.uuid})

      assert is_binary(html)
      assert Process.alive?(view.pid)
    end

    test "garbage XLSX bytes flash a parse error",
         %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, @import_url)
      render_change(view, "validate_upload", %{"catalogue" => cat.uuid})

      # XLSX-extension file with garbage contents — Parser returns
      # an error tuple that translate_error/1 routes through
      # PhoenixKitCatalogue.Errors.message/1.
      garbage = "not a real xlsx file"

      file =
        build_file_input(
          view,
          "broken.xlsx",
          "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
          garbage
        )

      render_upload(file, "broken.xlsx")

      html = render_submit(view, "parse_file", %{"catalogue" => cat.uuid})

      # The test is named for the flash, so assert the flash. `is_binary/1`
      # over `render_submit`'s return is true for any outcome, including one
      # where the error is swallowed and nothing is shown — which is the
      # failure this is supposed to catch.
      assert html =~ PhoenixKitCatalogue.Errors.message({:xlsx_open_failed, :invalid})

      # And it stays on :upload rather than transitioning to :map.
      assert :sys.get_state(view.pid).socket.assigns.step == :upload
    end
  end

  # ── helpers ─────────────────────────────────────────────────────

  defp build_file_input(view, filename, content_type, contents) do
    Phoenix.LiveViewTest.file_input(view, "#upload-form", :import_file, [
      %{
        last_modified: 1_700_000_000_000,
        name: filename,
        content: contents,
        type: content_type
      }
    ])
  end
end
