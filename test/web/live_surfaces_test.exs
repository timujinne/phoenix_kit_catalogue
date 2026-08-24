defmodule PhoenixKitCatalogue.Web.LiveSurfacesTest do
  @moduledoc """
  Cross-session liveness of the admin surfaces (2026-08 "as live as we
  can" batch): a mutation performed by ANOTHER process (the test process
  stands in for a second browser tab) must show up on an already-open
  page without a reload. Each test fails without its fix.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitCatalogue.AITranslatable
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.PubSub
  alias PhoenixKitCatalogue.Test.Repo, as: TestRepo

  @base "/en/admin/catalogue"

  # A live, non-image document row in `folder_uuid` — what the paperclip
  # counts. Inserted raw like attachments_lv_test does (no bucket needed).
  defp insert_document!(folder_uuid, %{user: %{uuid: user_uuid}}, name \\ "spec.pdf") do
    uuid = Ecto.UUID.generate()

    {:ok, _} =
      TestRepo.query("""
      INSERT INTO phoenix_kit_files
        (uuid, file_name, original_file_name, mime_type, file_type, ext,
         file_checksum, user_file_checksum, size, file_path, folder_uuid, user_uuid,
         status, metadata, inserted_at, updated_at)
      VALUES
        ('#{uuid}', '#{name}', '#{name}', 'application/pdf', 'document', 'pdf',
         '#{uuid}', '#{uuid}', 100, 'k', '#{folder_uuid}', '#{user_uuid}',
         'active', '{}'::jsonb, NOW(), NOW())
      """)

    uuid
  end

  defp folder!(name) do
    {:ok, folder} = Storage.create_folder(%{name: name})
    folder
  end

  defp files_state_uuids(view) do
    :sys.get_state(view.pid).socket.assigns.files_state.files |> Enum.map(& &1.uuid)
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # Async work (start_async searches) lands a tick later — poll instead of
  # sleeping a fixed amount.
  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  defp search_uuids(view) do
    _ = render(view)
    (assigns(view).search_results || []) |> Enum.map(& &1.uuid)
  end

  defp index_row(view, uuid) do
    :sys.get_state(view.pid).socket.assigns.catalogue_rows
    |> Enum.find(&(&1.uuid == uuid))
  end

  defp detail_item_uuids(view) do
    :sys.get_state(view.pid).socket.assigns.items |> Enum.map(& &1.uuid)
  end

  describe "F3 — attachment writes announce the owning resource" do
    test "removing a file from an item broadcasts :item with its catalogue", %{
      conn: conn,
      scope: scope
    } do
      folder = folder!("catalogue-item-f3")
      cat = fixture_catalogue()

      item =
        fixture_item(%{
          name: "Doc holder",
          catalogue_uuid: cat.uuid,
          data: %{"files_folder_uuid" => folder.uuid}
        })

      file_uuid = insert_document!(folder.uuid, scope)
      {:ok, view, _html} = live(conn, "#{@base}/items/#{item.uuid}/edit")
      assert file_uuid in files_state_uuids(view)

      PubSub.subscribe()
      render_click(view, "remove_file", %{"uuid" => file_uuid})

      assert_receive {:catalogue_data_changed, :item, uuid, parent}
      assert uuid == item.uuid
      assert parent == cat.uuid
      refute file_uuid in files_state_uuids(view)
    end

    test "removing a file from a catalogue broadcasts :catalogue", %{conn: conn, scope: scope} do
      folder = folder!("catalogue-f3")
      cat = fixture_catalogue(%{data: %{"files_folder_uuid" => folder.uuid}})
      file_uuid = insert_document!(folder.uuid, scope)
      {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}/edit")

      PubSub.subscribe()
      render_click(view, "remove_file", %{"uuid" => file_uuid})

      assert_receive {:catalogue_data_changed, :catalogue, uuid, parent}
      assert uuid == cat.uuid
      assert parent == cat.uuid
    end

    # A file that exists but was never linked into this resource's folder:
    # the detach deletes zero rows and must not announce a change.
    test "removing a file this resource never held stays silent", %{conn: conn, scope: scope} do
      folder = folder!("catalogue-item-f3-mine")
      elsewhere = folder!("catalogue-item-f3-elsewhere")
      cat = fixture_catalogue()

      item =
        fixture_item(%{
          name: "Doc holder",
          catalogue_uuid: cat.uuid,
          data: %{"files_folder_uuid" => folder.uuid}
        })

      foreign_file = insert_document!(elsewhere.uuid, scope, "theirs.pdf")
      {:ok, view, _html} = live(conn, "#{@base}/items/#{item.uuid}/edit")

      PubSub.subscribe()
      render_click(view, "remove_file", %{"uuid" => foreign_file})

      refute_receive {:catalogue_data_changed, _, _, _}, 100
    end

    test "a miss (unknown file) writes nothing and stays silent", %{conn: conn} do
      cat = fixture_catalogue()
      {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}/edit")

      PubSub.subscribe()
      render_click(view, "remove_file", %{"uuid" => Ecto.UUID.generate()})
      refute_receive {:catalogue_data_changed, _, _, _}
    end

    test "the catalogues index paperclip count follows the removal", %{conn: conn, scope: scope} do
      folder = folder!("catalogue-f3-index")
      cat = fixture_catalogue(%{data: %{"files_folder_uuid" => folder.uuid}})
      file_uuid = insert_document!(folder.uuid, scope)

      {:ok, index, _} = live(conn, @base)
      assert :sys.get_state(index.pid).socket.assigns.catalogue_file_counts[cat.uuid] == 1

      {:ok, form, _} = live(conn, "#{@base}/#{cat.uuid}/edit")
      render_click(form, "remove_file", %{"uuid" => file_uuid})

      _ = render(index)

      refute Map.has_key?(
               :sys.get_state(index.pid).socket.assigns.catalogue_file_counts,
               cat.uuid
             )
    end
  end

  describe "F4 — closing the media selector re-reads the folder" do
    test "a file that landed while the modal was open shows up on close", %{
      conn: conn,
      scope: scope
    } do
      folder = folder!("catalogue-f4")
      cat = fixture_catalogue(%{data: %{"files_folder_uuid" => folder.uuid}})
      {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}/edit")
      assert files_state_uuids(view) == []

      render_click(view, "open_featured_image_picker", %{})
      # The core modal stored an upload straight into the folder…
      file_uuid = insert_document!(folder.uuid, scope)
      # …and the user closed it without confirming.
      PubSub.subscribe()
      send(view.pid, {:media_selector_closed})
      _ = render(view)

      assert files_state_uuids(view) == [file_uuid]
      refute :sys.get_state(view.pid).socket.assigns.show_media_selector
      # The folder changed under this resource: other surfaces hear it.
      assert_receive {:catalogue_data_changed, :catalogue, uuid, _}
      assert uuid == cat.uuid
    end

    test "closing with nothing new is silent", %{conn: conn} do
      folder = folder!("catalogue-f4-quiet")
      cat = fixture_catalogue(%{data: %{"files_folder_uuid" => folder.uuid}})
      {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}/edit")

      PubSub.subscribe()
      render_click(view, "close_media_selector", %{})
      refute_receive {:catalogue_data_changed, _, _, _}
    end
  end

  describe "F2 — detail indicators clear when the last file / the group goes away" do
    test "clearing an item's attribute group drops the swatch", %{conn: conn} do
      cat = fixture_catalogue()
      item = fixture_item(%{name: "Swatched", catalogue_uuid: cat.uuid})
      {:ok, group} = Catalogue.create_attribute_group(%{name: "Doors"})
      {:ok, :assigned} = Catalogue.set_item_attribute_group(item, group.uuid)

      {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}")
      assert Map.has_key?(assigns(view).attribute_map, item.uuid)
      assert render(view) =~ "Has attribute group"

      {:ok, :cleared} = Catalogue.set_item_attribute_group(item, nil)
      refute render(view) =~ "Has attribute group"
      refute Map.has_key?(assigns(view).attribute_map, item.uuid)
    end

    test "removing an item's last document drops the paperclip count",
         %{conn: conn, scope: scope} do
      folder = folder!("catalogue-item-f2")
      cat = fixture_catalogue()

      item =
        fixture_item(%{
          name: "Clipped",
          catalogue_uuid: cat.uuid,
          data: %{"files_folder_uuid" => folder.uuid}
        })

      file_uuid = insert_document!(folder.uuid, scope)
      {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}")
      assert assigns(view).file_counts[item.uuid] == 1

      # The other tab trashed the file (what Attachments.trash_file does)
      # and announced the item.
      {:ok, _} =
        TestRepo.query("UPDATE phoenix_kit_files SET status = 'trashed' WHERE uuid = $1", [
          Ecto.UUID.dump!(file_uuid)
        ])

      PubSub.broadcast(:item, item.uuid, cat.uuid)
      _ = render(view)
      assert Map.get(assigns(view).file_counts, item.uuid, 0) == 0
    end
  end

  describe "F7 — an active search follows writes and tab switches" do
    setup do
      cat = fixture_catalogue()
      alpha = fixture_item(%{name: "Alpha Bolt", catalogue_uuid: cat.uuid})
      beta = fixture_item(%{name: "Beta Nut", catalogue_uuid: cat.uuid})
      %{catalogue: cat, alpha: alpha, beta: beta}
    end

    test "a rename elsewhere re-runs the search", %{conn: conn, catalogue: cat, alpha: a, beta: b} do
      {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}?q=Alpha")
      eventually(fn -> search_uuids(view) == [a.uuid] end)

      {:ok, _} = Catalogue.update_item(b, %{name: "Alpha Nut"})
      eventually(fn -> Enum.sort(search_uuids(view)) == Enum.sort([a.uuid, b.uuid]) end)
    end

    test "switching the status tab clears the search grid", %{
      conn: conn,
      catalogue: cat,
      alpha: a
    } do
      {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}?q=Alpha")
      eventually(fn -> search_uuids(view) == [a.uuid] end)

      render_click(view, "switch_view", %{"mode" => "deleted"})
      _ = render(view)

      # (The empty Deleted tab auto-flips back to Active, where "Alpha
      # Bolt" is a normal level row again — the search grid is what's gone.)
      assert assigns(view).search_results == nil
      assert assigns(view).search_query == ""
      refute has_element?(view, "form[phx-submit=search] input[value='Alpha']")
    end
  end

  describe "F8 — a crashed import task surfaces a failed step instead of freezing" do
    @import_url "/en/admin/catalogue/import"

    # A real, monitored task: the fun runs INSIDE the LiveView process, so
    # the monitor belongs to it and `Process.info(view.pid, :monitors)` can
    # tell whether the wizard released it.
    defp fake_import_task(view) do
      pid = spawn(fn -> Process.sleep(:infinity) end)

      :sys.replace_state(view.pid, fn state ->
        ref = Process.monitor(pid)

        assigns =
          state.socket.assigns
          |> Map.put(:step, :importing)
          |> Map.put(:import_task, {pid, ref})

        put_in(state.socket.assigns, assigns)
      end)

      {pid, elem(:sys.get_state(view.pid).socket.assigns.import_task, 1)}
    end

    test "an unrescued crash lands on Import Failed with the exception message", %{conn: conn} do
      cat = fixture_catalogue()
      {:ok, view, _html} = live(conn, "#{@import_url}?catalogue_uuid=#{cat.uuid}")
      {pid, ref} = fake_import_task(view)

      send(view.pid, {:DOWN, ref, :process, pid, {%KeyError{key: :sku, term: %{}}, []}})
      html = render(view)

      assert assigns(view).step == :failed
      assert assigns(view).import_task == nil
      assert html =~ "Import Failed"
      assert html =~ "key :sku not found"
      assert html =~ "Import Another"
    end

    test "a second execute_import while a task runs is ignored", %{conn: conn} do
      cat = fixture_catalogue()
      {:ok, view, _html} = live(conn, "#{@import_url}?catalogue_uuid=#{cat.uuid}")
      {pid, ref} = fake_import_task(view)

      render_click(view, "execute_import", %{})

      assert assigns(view).import_task == {pid, ref}
      assert assigns(view).step == :importing
    end

    test "import_another releases a monitor that is still held", %{conn: conn} do
      cat = fixture_catalogue()
      {:ok, view, _html} = live(conn, "#{@import_url}?catalogue_uuid=#{cat.uuid}")
      {pid, ref} = fake_import_task(view)

      monitored = fn ->
        Process.info(view.pid, :monitors) |> elem(1) |> Keyword.get_values(:process)
      end

      assert pid in monitored.()

      render_click(view, "import_another", %{})

      assert assigns(view).import_task == nil
      assert assigns(view).step == :upload
      # The monitor is released, not just forgotten.
      refute pid in monitored.()
      # A late :DOWN from the old task no longer flips the fresh wizard.
      send(view.pid, {:DOWN, ref, :process, pid, :killed})
      _ = render(view)
      assert assigns(view).step == :upload
    end

    test "a result from an abandoned task does not yank the fresh wizard", %{conn: conn} do
      cat = fixture_catalogue()
      {:ok, view, _html} = live(conn, "#{@import_url}?catalogue_uuid=#{cat.uuid}")
      _ = fake_import_task(view)

      render_click(view, "import_another", %{})
      send(view.pid, {:import_result, %{created: 1, updated: 0, skipped: 0, errors: []}})
      _ = render(view)

      assert assigns(view).step == :upload
    end

    test "a :DOWN for a task that is not ours is ignored", %{conn: conn} do
      cat = fixture_catalogue()
      {:ok, view, _html} = live(conn, "#{@import_url}?catalogue_uuid=#{cat.uuid}")
      {_pid, _ref} = fake_import_task(view)

      send(view.pid, {:DOWN, make_ref(), :process, self(), :killed})
      _ = render(view)

      assert assigns(view).step == :importing
    end

    test "a result that arrived before the exit wins and the monitor is dropped", %{conn: conn} do
      cat = fixture_catalogue()
      {:ok, view, _html} = live(conn, "#{@import_url}?catalogue_uuid=#{cat.uuid}")
      {pid, ref} = fake_import_task(view)

      result = %{
        created: 1,
        errors: [],
        categories_created: 0,
        manufacturers_created: 0,
        suppliers_created: 0,
        manufacturer_supplier_links_created: 0
      }

      send(view.pid, {:import_result, result})
      send(view.pid, {:DOWN, ref, :process, pid, :normal})
      _ = render(view)

      assert assigns(view).step == :done
      assert assigns(view).import_task == nil
    end

    test "a real import is monitored and the monitor is released on completion",
         %{conn: conn} do
      cat = fixture_catalogue()
      {:ok, view, _html} = live(conn, @import_url)
      render_change(view, "validate_upload", %{"catalogue" => cat.uuid})

      file =
        Phoenix.LiveViewTest.file_input(view, "#upload-form", :import_file, [
          %{
            last_modified: 1_700_000_000_000,
            name: "mon.csv",
            content: "name,sku\nMonitored Item,MON-1\n",
            type: "text/csv"
          }
        ])

      render_upload(file, "mon.csv")
      render_submit(view, "parse_file", %{"catalogue" => cat.uuid})
      render_click(view, "continue_to_confirm", %{})
      render_click(view, "execute_import", %{})

      eventually(fn ->
        _ = render(view)
        assigns(view).step == :done
      end)

      assert assigns(view).import_task == nil
      assert [%{name: "Monitored Item"}] = Catalogue.list_items_for_catalogue(cat.uuid)
    end
  end

  describe "F10 — the item form follows supplier-row writes from other sessions" do
    setup do
      cat = fixture_catalogue()
      item = fixture_item(%{name: "Sourced", catalogue_uuid: cat.uuid})
      supplier = fixture_supplier(%{name: "Acme Metals"})
      %{catalogue: cat, item: item, supplier: supplier}
    end

    defp supplier_info!(item, supplier, extra \\ %{}) do
      {:ok, info} =
        Catalogue.create_supplier_info(
          Map.merge(
            %{
              "item_uuid" => item.uuid,
              "supplier_uuid" => supplier.uuid,
              "supplier_source" => "local",
              "supplier_name_snapshot" => supplier.name,
              "unit_cost" => "10.00"
            },
            extra
          )
        )

      info
    end

    defp supplier_row_uuids(view), do: Enum.map(assigns(view).supplier_infos, & &1.uuid)

    test "a row added elsewhere appears with its name and the tab badge",
         %{conn: conn, item: item, supplier: supplier} do
      {:ok, view, _html} = live(conn, "#{@base}/items/#{item.uuid}/edit?tab=sourcing")
      assert supplier_row_uuids(view) == []

      info = supplier_info!(item, supplier)
      html = render(view)

      assert supplier_row_uuids(view) == [info.uuid]
      assert html =~ "Acme Metals"
    end

    test "another item's rows are ignored", %{conn: conn, item: item, supplier: supplier} do
      other = fixture_item(%{name: "Other", catalogue_uuid: item.catalogue_uuid})
      {:ok, view, _html} = live(conn, "#{@base}/items/#{item.uuid}/edit")

      _ = supplier_info!(other, supplier)
      _ = render(view)

      assert supplier_row_uuids(view) == []
    end

    test "crafted uuids cannot act on another item's supplier row",
         %{conn: conn, item: item, supplier: supplier} do
      other = fixture_item(%{name: "Other", catalogue_uuid: item.catalogue_uuid})
      foreign = supplier_info!(other, supplier)
      _mine = supplier_info!(item, supplier)
      {:ok, view, _html} = live(conn, "#{@base}/items/#{item.uuid}/edit?tab=sourcing")

      render_click(view, "set_primary_supplier", %{"uuid" => foreign.uuid})
      render_click(view, "open_supplier_history", %{"uuid" => foreign.uuid})
      render_click(view, "delete_supplier_info", %{"uuid" => foreign.uuid})

      refute assigns(view).supplier_history_open
      assert Catalogue.get_supplier_info(foreign.uuid).valid_to == nil
      assert Catalogue.primary_supplier_info_for_item(other.uuid).uuid == foreign.uuid
    end

    test "a primary flip and a removal elsewhere are reflected",
         %{conn: conn, item: item, supplier: supplier} do
      second = fixture_supplier(%{name: "Beta Parts"})
      first_info = supplier_info!(item, supplier)
      second_info = supplier_info!(item, second)
      {:ok, view, _html} = live(conn, "#{@base}/items/#{item.uuid}/edit")

      {:ok, _} = Catalogue.set_primary_supplier_info(second_info)
      _ = render(view)
      primary = Enum.find(assigns(view).supplier_infos, & &1.is_primary)
      assert primary.uuid == second_info.uuid

      {:ok, _} = Catalogue.delete_supplier_info(first_info)
      _ = render(view)
      assert supplier_row_uuids(view) == [second_info.uuid]
    end

    test "an open price-history modal picks up a revision made elsewhere",
         %{conn: conn, item: item, supplier: supplier} do
      info = supplier_info!(item, supplier)
      {:ok, view, _html} = live(conn, "#{@base}/items/#{item.uuid}/edit")

      render_click(view, "open_supplier_history", %{"uuid" => info.uuid})
      assert length(assigns(view).supplier_history_rows) == 1

      {:ok, _} = Catalogue.revise_supplier_info_cost(info, Decimal.new("12.50"))
      _ = render(view)
      assert length(assigns(view).supplier_history_rows) == 2

      render_click(view, "close_supplier_history", %{})
      assert assigns(view).supplier_history_pair == nil
    end

    test "a supplier renamed elsewhere shows its new name",
         %{conn: conn, item: item, supplier: supplier} do
      _ = supplier_info!(item, supplier)
      {:ok, view, _html} = live(conn, "#{@base}/items/#{item.uuid}/edit")
      assert render(view) =~ "Acme Metals"

      {:ok, _} = Catalogue.update_supplier(supplier, %{name: "Acme Alloys"})
      assert render(view) =~ "Acme Alloys"
    end
  end

  describe "F10 — the item form follows its item / categories without clobbering input" do
    test "a file attached elsewhere shows in the grid; typed input survives",
         %{conn: conn, scope: scope} do
      folder = folder!("catalogue-item-f10")
      cat = fixture_catalogue()

      item =
        fixture_item(%{
          name: "Original",
          catalogue_uuid: cat.uuid,
          data: %{"files_folder_uuid" => folder.uuid}
        })

      {:ok, view, _html} = live(conn, "#{@base}/items/#{item.uuid}/edit")
      render_change(view, "validate", %{"item" => %{"name" => "Typed but unsaved"}})

      file_uuid = insert_document!(folder.uuid, scope)
      PubSub.broadcast(:item, item.uuid, cat.uuid)
      _ = render(view)

      assert file_uuid in files_state_uuids(view)
      assert Ecto.Changeset.get_change(assigns(view).changeset, :name) == "Typed but unsaved"
      assert Catalogue.get_item(item.uuid).name == "Original"
    end

    test "a first upload in another tab is picked up when this tab has no folder pointer",
         %{conn: conn, scope: scope} do
      cat = fixture_catalogue()
      item = fixture_item(%{name: "No pointer", catalogue_uuid: cat.uuid})
      {:ok, view, _html} = live(conn, "#{@base}/items/#{item.uuid}/edit")
      assert assigns(view).files_folder_uuid in [nil, ""]
      assert files_state_uuids(view) == []

      folder = folder!("catalogue-item-#{item.uuid}")
      file_uuid = insert_document!(folder.uuid, scope)
      PubSub.broadcast(:item, item.uuid, cat.uuid)
      _ = render(view)

      assert assigns(view).files_folder_uuid == folder.uuid
      assert file_uuid in files_state_uuids(view)
    end

    test "a category added elsewhere becomes selectable", %{conn: conn} do
      cat = fixture_catalogue()
      item = fixture_item(%{name: "Cat aware", catalogue_uuid: cat.uuid})
      {:ok, view, _html} = live(conn, "#{@base}/items/#{item.uuid}/edit")
      assert assigns(view).categories == []

      sec = fixture_category(cat, %{name: "Late Section"})
      _ = render(view)

      assert Enum.map(assigns(view).categories, & &1.uuid) == [sec.uuid]
    end
  end

  describe "F6 — the attribute-group editor follows child writes from other processes" do
    setup do
      {:ok, group} = Catalogue.create_attribute_group(%{name: "Idea doors"})
      {:ok, attribute} = Catalogue.create_attribute(group, %{"name" => "Color"})
      %{group: group, attribute: attribute}
    end

    test "a translation job's write shows up without a timer",
         %{conn: conn, group: group, attribute: attribute} do
      {:ok, view, _html} = live(conn, "#{@base}/attributes/#{group.uuid}/edit")

      {:ok, _} = AITranslatable.put_translation(attribute, "et", %{"name" => "Värv"}, [])
      _ = render(view)

      [loaded] = :sys.get_state(view.pid).socket.assigns.group.attributes
      assert loaded.data["et"]["_name"] == "Värv"
    end

    test "a colleague adding an attribute appears in the list", %{conn: conn, group: group} do
      {:ok, view, _html} = live(conn, "#{@base}/attributes/#{group.uuid}/edit")
      refute render(view) =~ "Material"

      {:ok, _} = Catalogue.create_attribute(group, %{"name" => "Material"})
      assert render(view) =~ "Material"
    end

    test "another group's events are ignored", %{conn: conn, group: group} do
      {:ok, view, _html} = live(conn, "#{@base}/attributes/#{group.uuid}/edit")
      {:ok, other} = Catalogue.create_attribute_group(%{name: "Other"})
      {:ok, _} = Catalogue.create_attribute(other, %{"name" => "Finish"})

      refute render(view) =~ "Finish"
    end

    test "the group being deleted elsewhere bounces to the list", %{conn: conn, group: group} do
      {:ok, view, _html} = live(conn, "#{@base}/attributes/#{group.uuid}/edit")

      {:ok, _} = Catalogue.delete_attribute_group(group)
      assert_redirect(view, "#{@base}/attributes")
    end
  end

  describe "F1 — catalogues index Items column follows bulk item ops from another tab" do
    setup do
      cat = fixture_catalogue(%{name: "Bulk Cat"})
      a = fixture_item(%{name: "A", catalogue_uuid: cat.uuid})
      b = fixture_item(%{name: "B", catalogue_uuid: cat.uuid})
      %{catalogue: cat, a: a, b: b}
    end

    test "bulk trash / restore / permanent delete", %{conn: conn, catalogue: cat, a: a, b: b} do
      {:ok, view, _html} = live(conn, @base)
      assert index_row(view, cat.uuid).item_count == 2

      {2, nil} = Catalogue.bulk_trash_items([a.uuid, b.uuid], [])
      _ = render(view)
      assert index_row(view, cat.uuid).item_count == 0

      {1, nil} = Catalogue.bulk_restore_items([a.uuid], [])
      _ = render(view)
      assert index_row(view, cat.uuid).item_count == 1

      # b is already trashed, so the count cannot move — pin the broadcast the
      # index reacts to instead of a number that stays 1 either way.
      PubSub.subscribe()
      {1, nil} = Catalogue.bulk_permanently_delete_items([b.uuid], [])
      cat_uuid = cat.uuid
      assert_receive {:catalogue_data_changed, :item, nil, ^cat_uuid}
      _ = render(view)
      assert index_row(view, cat.uuid).item_count == 1
      assert Catalogue.get_item(b.uuid) == nil
    end

    test "detail page of the same catalogue drops bulk-trashed items",
         %{conn: conn, catalogue: cat, a: a, b: b} do
      {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}")
      assert Enum.sort(detail_item_uuids(view)) == Enum.sort([a.uuid, b.uuid])

      {1, nil} = Catalogue.bulk_trash_items([a.uuid], [])
      _ = render(view)
      assert detail_item_uuids(view) == [b.uuid]
    end

    # The batch `:item` event is held back while the flash plays, so the
    # apply step has to re-run an active search itself — otherwise the
    # results grid (the only thing on screen) kept the trashed row.
    test "the apply step re-runs an active search", %{conn: conn, catalogue: cat, a: a, b: b} do
      {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}?q=A")
      eventually(fn -> a.uuid in search_uuids(view) end)

      {1, nil} = Catalogue.bulk_trash_items([a.uuid], broadcast: false)
      other = spawn(fn -> :ok end)
      send(view.pid, {:catalogue_bulk_change, cat.uuid, :trashed, [a.uuid], other})
      PubSub.broadcast(:item, nil, cat.uuid)

      Process.sleep(900)
      eventually(fn -> a.uuid not in search_uuids(view) end)
      _ = b
    end

    test "the catalogue being deleted during the flash bounces to the index instead of crashing",
         %{conn: conn, catalogue: cat, a: a} do
      {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}")

      other = spawn(fn -> :ok end)
      send(view.pid, {:catalogue_bulk_change, cat.uuid, :trashed, [a.uuid], other})
      _ = render(view)
      assert assigns(view).bulk_change_pending

      {:ok, _} = Catalogue.permanently_delete_catalogue(cat)

      Process.sleep(900)
      assert_redirect(view, @base)
    end

    test "a pending cross-tab bulk flash holds the reload until the apply step",
         %{conn: conn, catalogue: cat, a: a, b: b} do
      {:ok, view, _html} = live(conn, "#{@base}/#{cat.uuid}")

      # The other tab: mutate muted, announce the flash, then the batch
      # event — the order the detail LV's bulk handlers use.
      {1, nil} = Catalogue.bulk_trash_items([a.uuid], broadcast: false)
      other = spawn(fn -> :ok end)
      send(view.pid, {:catalogue_bulk_change, cat.uuid, :trashed, [a.uuid], other})
      PubSub.broadcast(:item, nil, cat.uuid)

      _ = render(view)
      assert :sys.get_state(view.pid).socket.assigns.bulk_change_pending
      # Still on screen: the red "leaving" flash gets to play first.
      assert a.uuid in detail_item_uuids(view)

      Process.sleep(900)
      _ = render(view)
      refute :sys.get_state(view.pid).socket.assigns.bulk_change_pending
      assert detail_item_uuids(view) == [b.uuid]
    end
  end
end
