defmodule PhoenixKitCatalogue.Web.ItemFormUploadTest do
  @moduledoc """
  An upload through the item form's real file input: stored under its
  base name, typed by core, filed into the item's folder with the
  pointer written at once, and a byte-identical re-upload is reported
  instead of vanishing.
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitCatalogue.Attachments
  alias PhoenixKitCatalogue.Catalogue

  @base "/en/admin/catalogue"
  @buckets_cache :phoenix_kit_buckets_cache

  setup do
    :persistent_term.erase(@buckets_cache)
    # Stored files go to every enabled bucket; keep them all in this one.
    for bucket <- Storage.list_enabled_buckets(),
        do: {:ok, _} = Storage.update_bucket(bucket, %{enabled: false})

    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "catalogue_upload_#{n}")

    {:ok, _bucket} =
      Storage.create_bucket(%{
        name: "catalogue-upload-#{n}",
        provider: "local",
        endpoint: root,
        enabled: true,
        priority: 0
      })

    on_exit(fn ->
      :persistent_term.erase(@buckets_cache)
      File.rm_rf(root)
    end)

    :ok
  end

  # Variant jobs cannot be queued without Oban; that is logged, not raised.
  defp upload(view, name, content, type) do
    file =
      file_input(view, "#item-form", :attachment_files, [
        %{last_modified: 1_700_000_000_000, name: name, content: content, type: type}
      ])

    capture_log(fn -> render_upload(file, name) end)
    render(view)
  end

  test "an upload lands in the item's folder under its base name", %{conn: conn, scope: scope} do
    catalogue = fixture_catalogue(%{name: "Upload Range"})
    item = fixture_item(%{name: "Upload Item", catalogue_uuid: catalogue.uuid})
    {:ok, view, _html} = conn |> with_scope(scope) |> live("#{@base}/items/#{item.uuid}/edit")

    sheet = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    html = upload(view, "../../prices.xlsx", "prices #{item.uuid}", sheet)

    folder = Catalogue.get_item!(item.uuid).data["files_folder_uuid"]
    assert is_binary(folder)
    assert [file] = Attachments.list_folder_files(folder)
    assert file.original_file_name == "prices.xlsx"
    assert file.file_type == "document"
    assert html =~ "prices.xlsx"

    html = upload(view, "copy.xlsx", "prices #{item.uuid}", sheet)

    assert html =~
             "copy.xlsx is identical to prices.xlsx, which is already attached — nothing was added."

    assert [_only] = Attachments.list_folder_files(folder)
  end
end
