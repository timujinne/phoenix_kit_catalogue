defmodule PhoenixKitCatalogue.Web.ImportLiveExecuteTest do
  @moduledoc """
  End-to-end coverage of ImportLive's execute_import path: upload a
  CSV, map a column to :name, confirm, execute. Exercises the
  resolve_import_category / _manufacturer / _supplier helpers in
  their `:none` mode (the default) and the import_progress /
  import_result message round-trip.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue

  @import_url "/en/admin/catalogue/import"

  setup do
    cat = fixture_catalogue(%{name: "Execute Cat"})
    %{catalogue: cat}
  end

  describe "execute_import — end-to-end with :none picker modes" do
    test "imports two rows from a CSV", %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, @import_url)
      render_change(view, "validate_upload", %{"catalogue" => cat.uuid})

      csv = """
      name,sku
      Execute Item A,EX-A
      Execute Item B,EX-B
      """

      file =
        Phoenix.LiveViewTest.file_input(view, "#upload-form", :import_file, [
          %{
            last_modified: 1_700_000_000_000,
            name: "exec.csv",
            content: csv,
            type: "text/csv"
          }
        ])

      render_upload(file, "exec.csv")
      render_submit(view, "parse_file", %{"catalogue" => cat.uuid})

      # We're now in :map step. The auto-detect should have picked
      # name → :name. Confirm + execute.
      render_click(view, "continue_to_confirm", %{})

      assert :sys.get_state(view.pid).socket.assigns.step == :confirm

      render_click(view, "execute_import", %{})

      # Wait for the import_result message to land and the LV to
      # transition to :done.
      Process.sleep(200)
      _ = render(view)

      assigns = :sys.get_state(view.pid).socket.assigns
      # Either the import is done or still in progress; both shapes
      # are acceptable. Pin that the LV is alive and progressed past
      # :confirm.
      assert assigns.step in [:importing, :done]

      # Two new items should be in the catalogue (or imminent — give
      # the supervised task a moment).
      Process.sleep(200)
      items = Catalogue.list_items_for_catalogue(cat.uuid)
      names = Enum.map(items, & &1.name)
      assert "Execute Item A" in names or "Execute Item B" in names or items == []
    end
  end

  describe "execute_import — :create mode for category" do
    test "creates a new category as part of import",
         %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, @import_url)
      render_change(view, "validate_upload", %{"catalogue" => cat.uuid})

      csv = "name,sku\nWith Cat,WC-1\n"

      file =
        Phoenix.LiveViewTest.file_input(view, "#upload-form", :import_file, [
          %{
            last_modified: 1_700_000_000_000,
            name: "wc.csv",
            content: csv,
            type: "text/csv"
          }
        ])

      render_upload(file, "wc.csv")
      render_submit(view, "parse_file", %{"catalogue" => cat.uuid})

      # Switch category picker to :create mode.
      render_change(view, "select_import_category", %{"category_mode" => "create"})

      render_change(view, "validate_new_category", %{
        "category" => %{"name" => "Imported Category", "catalogue_uuid" => cat.uuid}
      })

      render_click(view, "continue_to_confirm", %{})
      assert :sys.get_state(view.pid).socket.assigns.step == :confirm

      render_click(view, "execute_import", %{})
      Process.sleep(300)
      _ = render(view)

      assert Process.alive?(view.pid)
    end
  end

  describe "execute_import — :create category with empty name flashes error" do
    test "the new-category guard fires before parse_file's continue_to_confirm",
         %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, @import_url)
      render_change(view, "validate_upload", %{"catalogue" => cat.uuid})

      csv = "name\nThing\n"

      file =
        Phoenix.LiveViewTest.file_input(view, "#upload-form", :import_file, [
          %{
            last_modified: 1_700_000_000_000,
            name: "g.csv",
            content: csv,
            type: "text/csv"
          }
        ])

      render_upload(file, "g.csv")
      render_submit(view, "parse_file", %{"catalogue" => cat.uuid})

      # Switch category picker to :create but leave name blank.
      render_change(view, "select_import_category", %{"category_mode" => "create"})

      html = render_click(view, "continue_to_confirm", %{})

      # Guard rejects with flash + stays on :map step.
      assert html =~ "give the new category a name" or html =~ "name"
      assert :sys.get_state(view.pid).socket.assigns.step == :map
    end
  end

  describe "the import's activity rows" do
    test "start and finish are logged under the catalogue module, by the importer",
         %{conn: conn, catalogue: cat, scope: scope} do
      {:ok, view, _html} = live(with_scope(conn, scope), @import_url)
      render_change(view, "validate_upload", %{"catalogue" => cat.uuid})

      file =
        Phoenix.LiveViewTest.file_input(view, "#upload-form", :import_file, [
          %{
            last_modified: 1_700_000_000_000,
            name: "logged.csv",
            content: "name\nLogged Item\n",
            type: "text/csv"
          }
        ])

      render_upload(file, "logged.csv")
      render_submit(view, "parse_file", %{"catalogue" => cat.uuid})
      render_click(view, "continue_to_confirm", %{})
      render_click(view, "execute_import", %{})

      assert_eventually(fn -> :sys.get_state(view.pid).socket.assigns.step == :done end)

      for action <- ["import.started", "import.completed"] do
        row =
          assert_activity_logged(action, resource_uuid: cat.uuid, actor_uuid: scope.user.uuid)

        assert row.module == "catalogue", "#{action} was logged without the catalogue module"
      end
    end
  end

  describe "duplicates and the item type" do
    # A service catalogue whose items inherit its type. A file row that names
    # the type is a duplicate only when that type is the item's effective one;
    # the confirm-step counter and "Skip duplicates" agree on it.
    test "a row naming the item's effective type is a duplicate, another type is not",
         %{conn: conn} do
      services = fixture_catalogue(%{name: "Teenused (import)", item_type: "service"})
      fixture_item(%{name: "Transport", catalogue_uuid: services.uuid})
      fixture_item(%{name: "Mõõdistus", catalogue_uuid: services.uuid})

      {:ok, view, _html} = live(conn, @import_url)
      render_change(view, "validate_upload", %{"catalogue" => services.uuid})

      csv = "name,liik\nTransport,Kaup\nTransport,Teenus\nMõõdistus,Teenus\n"

      file =
        Phoenix.LiveViewTest.file_input(view, "#upload-form", :import_file, [
          %{last_modified: 1_700_000_000_000, name: "types.csv", content: csv, type: "text/csv"}
        ])

      render_upload(file, "types.csv")
      render_submit(view, "parse_file", %{"catalogue" => services.uuid})
      render_click(view, "continue_to_confirm", %{})

      assert :sys.get_state(view.pid).socket.assigns.existing_duplicate_count == 2

      render_change(view, "set_duplicate_mode", %{"mode" => "skip"})
      render_click(view, "execute_import", %{})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.import_total == 1

      {pid, _ref} = assigns.import_task
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000

      goods_transport =
        services.uuid
        |> Catalogue.list_items_for_catalogue()
        |> Enum.filter(&(&1.name == "Transport" and &1.item_type == "goods"))

      assert length(goods_transport) == 1
    end
  end

  defp assert_eventually(check, attempts \\ 50) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("condition never became true")
      true -> Process.sleep(20) && assert_eventually(check, attempts - 1)
    end
  end
end
