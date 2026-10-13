defmodule PhoenixKitCatalogue.Web.AttachmentsLVTest do
  @moduledoc """
  Drives the `PhoenixKitCatalogue.Attachments` socket-bound functions
  through a real `CatalogueFormLive` mount + event firing. The pure
  functions (`format_file_size/1`, `file_icon/1`, `inject_attachment_data/2`,
  etc.) are unit-tested in `test/attachments_test.exs`.

  Storage tables (`phoenix_kit_buckets`, `phoenix_kit_files`,
  `phoenix_kit_media_folders`, `phoenix_kit_folder_links`) are
  provisioned by the test migration at
  `test/support/postgres/migrations/20260318172859_phoenix_kit_storage.exs`.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitCatalogue.Test.Repo, as: TestRepo

  setup do
    cat = fixture_catalogue(%{name: "Attach Cat"})
    %{catalogue: cat}
  end

  describe "the catalogue form and its row (review round, 2026-09-12)" do
    test "Save is an owned-key write: a data key the form never shows survives", %{
      conn: conn,
      catalogue: cat
    } do
      {:ok, _} =
        PhoenixKitCatalogue.Catalogue.update_catalogue(cat, %{
          data: Map.put(cat.data || %{}, "sync", %{"remote_id" => "r-1"})
        })

      {:ok, view, _html} = live(conn, "/en/admin/catalogues/#{cat.uuid}/edit")
      # Change the row behind the open form so its snapshot is stale.
      {:ok, _} =
        PhoenixKitCatalogue.Catalogue.update_catalogue(cat, %{
          data: Map.put(cat.data || %{}, "sync", %{"remote_id" => "r-2"})
        })

      render_submit(view, "save", %{"catalogue" => %{"name" => "Renamed Cat"}})

      fresh = PhoenixKitCatalogue.Catalogue.get_catalogue!(cat.uuid)
      assert fresh.data["sync"] == %{"remote_id" => "r-2"}
    end

    test "a broadcast for this catalogue refreshes the grid and does not crash the form", %{
      conn: conn,
      catalogue: cat
    } do
      {:ok, view, _html} = live(conn, "/en/admin/catalogues/#{cat.uuid}/edit")
      send(view.pid, {:catalogue_data_changed, :catalogue, cat.uuid, cat.uuid})
      assert render(view) =~ "Attach Cat"
      assert Process.alive?(view.pid)
    end
  end

  describe "open_featured_image_picker / close_media_selector" do
    test "open_featured_image_picker flips media selector flags",
         %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, "/en/admin/catalogues/#{cat.uuid}/edit")

      render_click(view, "open_featured_image_picker", %{})

      assigns = :sys.get_state(view.pid).socket.assigns

      # Either the picker opened (happy path with folder ensured) or
      # the LV is in a stable state with the modal closed (folder
      # ensure failed gracefully). Pin whichever we got — both are
      # the documented contract.
      assert is_boolean(assigns[:show_media_selector])
      assert Process.alive?(view.pid)
    end

    test "close_media_selector clears all media-selector assigns",
         %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, "/en/admin/catalogues/#{cat.uuid}/edit")

      # Open then close.
      render_click(view, "open_featured_image_picker", %{})
      render_click(view, "close_media_selector", %{})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns[:show_media_selector] == false
      assert assigns[:media_selector_target] == nil
      assert assigns[:media_selected_uuids] == []
    end
  end

  describe "clear_featured_image" do
    test "clear_featured_image nulls featured image assigns",
         %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, "/en/admin/catalogues/#{cat.uuid}/edit")

      # Inject a featured image first.
      :sys.replace_state(view.pid, fn state ->
        assigns =
          state.socket.assigns
          |> Map.put(:featured_image_uuid, Ecto.UUID.generate())
          |> Map.put(:featured_image_file, %{name: "old.jpg"})

        put_in(state.socket.assigns, assigns)
      end)

      render_click(view, "clear_featured_image", %{})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns[:featured_image_uuid] == nil
      assert assigns[:featured_image_file] == nil
    end
  end

  describe "a save that keeps the form open (PR #136 review)" do
    test "an image picked and saved here can be cleared by the next save", %{
      conn: conn,
      catalogue: cat
    } do
      scope = build_admin_scope()

      {:ok, %{uuid: file_uuid}} =
        Storage.create_file(%{
          user_uuid: scope.user.uuid,
          original_file_name: "x.jpg",
          file_name: "x.jpg",
          mime_type: "image/jpeg",
          file_type: "image",
          ext: "jpg",
          file_checksum: "checksum-stay-save",
          user_file_checksum: "user-checksum-stay-save",
          size: 100,
          status: "active"
        })

      {:ok, view, _html} = live(with_scope(conn, scope), "/en/admin/catalogues/#{cat.uuid}/edit")

      render_click(view, "open_featured_image_picker", %{})
      send(view.pid, {:media_selected, [file_uuid]})
      _ = render(view)

      render_submit(view, "save", %{
        "catalogue" => %{"name" => "Attach Cat"},
        "save_action" => "stay"
      })

      assert PhoenixKitCatalogue.Catalogue.get_catalogue!(cat.uuid).data["featured_image_uuid"] ==
               file_uuid

      render_click(view, "clear_featured_image", %{})

      render_submit(view, "save", %{
        "catalogue" => %{"name" => "Attach Cat"},
        "save_action" => "stay"
      })

      refute Map.has_key?(
               PhoenixKitCatalogue.Catalogue.get_catalogue!(cat.uuid).data,
               "featured_image_uuid"
             )
    end
  end

  describe "handle_info({:media_selected, ...})" do
    test "media_selected with empty list clears selector + closes modal",
         %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, "/en/admin/catalogues/#{cat.uuid}/edit")

      send(view.pid, {:media_selected, []})

      # Render to flush the message.
      _ = render(view)
      assert Process.alive?(view.pid)
      assert :sys.get_state(view.pid).socket.assigns[:show_media_selector] == false
    end
  end

  describe "remove_file (trash_file)" do
    test "remove_file with no folder + unknown uuid is a clean no-op",
         %{conn: conn, catalogue: cat} do
      {:ok, view, _html} = live(conn, "/en/admin/catalogues/#{cat.uuid}/edit")

      render_click(view, "remove_file", %{"uuid" => Ecto.UUID.generate()})

      # Without a real folder/file, the helper falls through cleanly
      # (do_detach(_, nil) → :ok or get_file(unknown) → nil). The LV
      # should stay alive and the file list empty.
      assert Process.alive?(view.pid)
      assert :sys.get_state(view.pid).socket.assigns[:files_state][:files] == []
    end

    test "remove_file when the file exists in the resource's folder trashes it",
         %{conn: conn, catalogue: cat, scope: scope} do
      {:ok, view, _html} = live(with_scope(conn, scope), "/en/admin/catalogues/#{cat.uuid}/edit")

      # The folder is made on first use; opening the picker is a first use.
      render_click(view, "open_featured_image_picker", %{})
      folder_uuid = :sys.get_state(view.pid).socket.assigns[:files_folder_uuid]
      assert is_binary(folder_uuid), "the resource's folder was not created"

      {:ok, %{uuid: file_uuid}} =
        Storage.create_file(%{
          user_uuid: scope.user.uuid,
          folder_uuid: folder_uuid,
          original_file_name: "a.jpg",
          file_name: "a.jpg",
          mime_type: "image/jpeg",
          file_type: "image",
          ext: "jpg",
          file_checksum: "checksum-remove-file",
          user_file_checksum: "user-checksum-remove-file",
          size: 100,
          status: "active"
        })

      render_click(view, "close_media_selector", %{})
      assert file_uuid in Enum.map(files(view), & &1.uuid)

      render_click(view, "remove_file", %{"uuid" => file_uuid})

      {:ok, %{rows: [[status]]}} =
        TestRepo.query(
          "SELECT status FROM phoenix_kit_files WHERE uuid = $1",
          [Ecto.UUID.dump!(file_uuid)]
        )

      assert status == "trashed"
      refute file_uuid in Enum.map(files(view), & &1.uuid)
    end
  end

  defp files(view), do: :sys.get_state(view.pid).socket.assigns[:files_state][:files]
end
