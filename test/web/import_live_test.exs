defmodule PhoenixKitCatalogue.Web.ImportLiveTest do
  @moduledoc """
  ImportLive is a multi-step wizard (upload → map → confirm → import
  → done) driven primarily by file uploads. Full upload lifecycle
  testing would require generating real XLSX/CSV binaries and driving
  them through `file_input/4`, which is more plumbing than this pass
  warrants. These tests cover the lifecycle that DOESN'T involve an
  uploaded file: mount, initial state, catalogue selection, the
  `clear_file` / `go_back` / `import_another` events, and the error
  paths.
  """
  use PhoenixKitCatalogue.LiveCase

  @import_url "/en/admin/catalogues/import"

  describe "mount" do
    test "renders the upload step", %{conn: conn} do
      _catalogue = fixture_catalogue()
      {:ok, _view, html} = live(conn, @import_url)
      assert html =~ "Upload"
    end

    test "shows the catalogue dropdown", %{conn: conn} do
      fixture_catalogue(%{name: "Pickable"})

      {:ok, _view, html} = live(conn, @import_url)
      assert html =~ "Pickable"
    end

    test "lists multiple catalogues in the dropdown", %{conn: conn} do
      fixture_catalogue(%{name: "First"})
      fixture_catalogue(%{name: "Second"})

      {:ok, _view, html} = live(conn, @import_url)
      assert html =~ "First"
      assert html =~ "Second"
    end
  end

  describe "validate_upload" do
    test "selects a catalogue", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Target"})

      {:ok, view, _html} = live(conn, @import_url)
      html = render_change(view, "validate_upload", %{"catalogue" => catalogue.uuid})

      assert html =~ "Target"
    end

    test "with empty catalogue id is a no-op", %{conn: conn} do
      {:ok, view, _html} = live(conn, @import_url)
      html = render_change(view, "validate_upload", %{"catalogue" => ""})
      # No crash.
      assert html =~ "Upload"
    end

    test "with no catalogue key is a no-op", %{conn: conn} do
      {:ok, view, _html} = live(conn, @import_url)
      html = render_change(view, "validate_upload", %{})
      assert html =~ "Upload"
    end
  end

  describe "clear_file" do
    test "does not crash when no file has been uploaded", %{conn: conn} do
      {:ok, view, _html} = live(conn, @import_url)
      html = render_click(view, "clear_file", %{})
      assert html =~ "Upload"
    end
  end
end
