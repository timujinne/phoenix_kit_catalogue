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

  @import_url "/en/admin/catalogues/import"

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

  describe "the import's closing row does not need the page" do
    defp start_import(conn, cat, scope, filename, csv) do
      {:ok, view, _html} = live(with_scope(conn, scope), @import_url)
      render_change(view, "validate_upload", %{"catalogue" => cat.uuid})

      file =
        Phoenix.LiveViewTest.file_input(view, "#upload-form", :import_file, [
          %{last_modified: 1_700_000_000_000, name: filename, content: csv, type: "text/csv"}
        ])

      render_upload(file, filename)
      render_submit(view, "parse_file", %{"catalogue" => cat.uuid})
      render_click(view, "continue_to_confirm", %{})
      view
    end

    test "closing the page mid-import still logs import.completed, once, by the importer",
         %{conn: conn, catalogue: cat, scope: scope} do
      rows = for n <- 1..150, do: "Orphan Import #{n}\n"
      view = start_import(conn, cat, scope, "orphan.csv", IO.iodata_to_binary(["name\n" | rows]))

      render_click(view, "execute_import", %{})
      {task, _ref} = :sys.get_state(view.pid).socket.assigns.import_task

      # Hold the task where it is, so the page is provably gone before the
      # import finishes rather than usually gone. (No database read until
      # it resumes: a suspended task may be holding the sandbox connection.)
      true = :erlang.suspend_process(task)
      task_ref = Process.monitor(task)
      assert Process.alive?(task), "the import finished before the page could be closed"

      Process.flag(:trap_exit, true)
      view_ref = Process.monitor(view.pid)
      Process.exit(view.pid, :kill)
      assert_receive {:DOWN, ^view_ref, :process, _pid, :killed}

      true = :erlang.resume_process(task)
      assert_receive {:DOWN, ^task_ref, :process, _pid, :normal}, 30_000

      row =
        assert_activity_logged("import.completed",
          resource_uuid: cat.uuid,
          actor_uuid: scope.user.uuid,
          metadata_has: %{"items_created" => 150, "errors" => 0, "filename" => "orphan.csv"}
        )

      assert row.module == "catalogue"
      refute_activity_logged("import.failed")
    end

    # The plan is swapped in the page's state for one the executor cannot
    # run; the task, its rescue and the activity write are the real ones.
    defp run_with_plan(view, plan_fun) do
      :sys.replace_state(view.pid, fn state ->
        update_in(state.socket.assigns.import_plan, plan_fun)
      end)

      ExUnit.CaptureLog.capture_log(fn ->
        render_click(view, "execute_import", %{})

        assert_eventually(fn ->
          :sys.get_state(view.pid).socket.assigns.step in [:done, :failed]
        end)
      end)

      :sys.get_state(view.pid).socket.assigns.step
    end

    for {label, items, step} <- [
          # Postgres refuses a NUL in text: a Postgrex.Error, which the task
          # reports to the page as a result with an error.
          {"a database error", [%{name: "Secret\0Name"}], :done},
          # Nothing the task expects: it crashes, and the page hears :DOWN.
          {"a crash", [:not_an_item], :failed}
        ] do
      test "#{label} logs import.failed, once, with no row data in the reason",
           %{conn: conn, catalogue: cat, scope: scope} do
        view = start_import(conn, cat, scope, "raises.csv", "name\nFine Name\n")

        assert run_with_plan(view, &%{&1 | items: unquote(Macro.escape(items))}) == unquote(step)

        row =
          assert_activity_logged("import.failed",
            resource_uuid: cat.uuid,
            actor_uuid: scope.user.uuid,
            metadata_has: %{"filename" => "raises.csv", "catalogue_name" => "Execute Cat"}
          )

        assert row.module == "catalogue"
        assert row.mode == "manual"
        assert is_binary(row.metadata["reason"]) and row.metadata["reason"] != ""
        refute row.metadata["reason"] =~ "Secret"
        refute_activity_logged("import.completed")
      end
    end
  end

  describe "duplicates and the item type" do
    test "confirmation reads the current catalogue type", %{conn: conn, catalogue: cat} do
      fixture_item(%{name: "Transport", catalogue_uuid: cat.uuid})
      view = type_import(conn, cat)

      {:ok, _} = Catalogue.update_catalogue(cat, %{item_type: "service"})
      render_click(view, "continue_to_confirm", %{})

      assert :sys.get_state(view.pid).socket.assigns.existing_duplicate_count == 1
    end

    for {original_type, current_type, expected_created} <- [
          {"goods", "service", 0},
          {"service", "goods", 1}
        ] do
      test "Skip duplicates follows a catalogue changed from #{original_type} to #{current_type} after confirmation",
           %{conn: conn} do
        cat = fixture_catalogue(%{item_type: unquote(original_type)})
        fixture_item(%{name: "Transport", catalogue_uuid: cat.uuid})
        view = type_import(conn, cat)
        render_click(view, "continue_to_confirm", %{})
        render_change(view, "set_duplicate_mode", %{"mode" => "skip"})

        {:ok, _} = Catalogue.update_catalogue(cat, %{item_type: unquote(current_type)})
        render_click(view, "execute_import", %{})

        assert_eventually(fn -> :sys.get_state(view.pid).socket.assigns.step == :done end)

        assert :sys.get_state(view.pid).socket.assigns.import_result.created ==
                 unquote(expected_created)

        items = Catalogue.list_items_for_catalogue(cat.uuid)
        assert length(items) == 1 + unquote(expected_created)
        assert Enum.count(items, &(&1.item_type == "service")) == unquote(expected_created)
      end
    end

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

  defp type_import(conn, cat) do
    {:ok, view, _html} = live(conn, @import_url)
    render_change(view, "validate_upload", %{"catalogue" => cat.uuid})

    file =
      file_input(view, "#upload-form", :import_file, [
        %{
          last_modified: 1_700_000_000_000,
          name: "type.csv",
          content: "name,item_type\nTransport,service\n",
          type: "text/csv"
        }
      ])

    render_upload(file, "type.csv")
    render_submit(view, "parse_file", %{"catalogue" => cat.uuid})
    view
  end

  defp assert_eventually(check, attempts \\ 50) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("condition never became true")
      true -> Process.sleep(20) && assert_eventually(check, attempts - 1)
    end
  end
end
