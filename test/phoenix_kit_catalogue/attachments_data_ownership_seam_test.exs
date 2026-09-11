defmodule PhoenixKitCatalogue.AttachmentsDataOwnershipSeamTest do
  @moduledoc """
  Seam coverage between `PhoenixKitCatalogue.Attachments` and
  `PhoenixKitCatalogue.Catalogue.update_item/3` /
  `update_category/3`'s `:data_owned_keys` splicing.

  Each layer alone tests fine and disagrees with the other: `Attachments`
  signals "clear this" by OMITTING the key
  (`inject_featured_image/2`/`inject_media_order/2` used to
  `Map.delete/2` it), while `:data_owned_keys` splicing reads an owned
  key's ABSENCE from the caller's attrs as "this form never touched it,
  leave the DB row's value alone" — the exact opposite meaning on the
  same signal. `Attachments` now writes an explicit `nil` marker instead,
  and both `apply_owned_data/2` (`Catalogue`) and the `Item`/`Category`
  changesets treat a `nil` top-level `data` value as "drop this key",
  never as a value to store.

  These tests exercise the REAL composition production code runs: the
  real `Attachments.inject_attachment_data/2` output, the real
  `PhoenixKitCatalogue.Web.Helpers.data_owned_keys/2` derivation, fed
  into the real `Catalogue.update_item/3` / `update_category/3`.
  """

  use PhoenixKitCatalogue.DataCase, async: true

  alias PhoenixKitCatalogue.Attachments
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Web.Helpers

  defp create_item(attrs \\ %{}) do
    {:ok, cat} = Catalogue.create_catalogue(%{name: "Cat"})

    {:ok, item} =
      Catalogue.create_item(Map.merge(%{name: "Widget", catalogue_uuid: cat.uuid}, attrs))

    item
  end

  defp create_category(attrs \\ %{}) do
    {:ok, cat} = Catalogue.create_catalogue(%{name: "Cat"})

    {:ok, category} =
      Catalogue.create_category(Map.merge(%{name: "Cards", catalogue_uuid: cat.uuid}, attrs))

    category
  end

  # Same fake-socket-via-assigns pattern as `Web.HelpersTest` /
  # `HelpersDataOwnedKeysTest` — no LiveView process needed, both
  # `Attachments.inject_attachment_data/2` and `Helpers.data_owned_keys/2`
  # only read `socket.assigns`.
  defp socket(assigns) do
    %Phoenix.LiveView.Socket{
      assigns:
        Map.merge(
          %{multilang_enabled: false, language_tabs: [], files_folder_uuid: nil},
          assigns
        )
    }
  end

  defp item_owned_keys(socket) do
    Helpers.data_owned_keys(socket, ~w(meta files_folder_uuid featured_image_uuid media_order))
  end

  defp category_owned_keys(socket) do
    Helpers.data_owned_keys(socket, ~w(files_folder_uuid featured_image_uuid media_order))
  end

  describe "item — seam" do
    test "clearing the featured image survives a real save (key is gone, not null)" do
      item = create_item()
      {:ok, item} = Catalogue.update_item(item, %{data: %{"featured_image_uuid" => "old-uuid"}})

      s = socket(%{featured_image_uuid: nil, files_state: %{files: []}})
      params = Attachments.inject_attachment_data(%{"data" => %{}}, s)

      assert {:ok, updated} =
               Catalogue.update_item(item, params, data_owned_keys: item_owned_keys(s))

      refute Map.has_key?(updated.data, "featured_image_uuid")
    end

    test "clearing the media order (no files left) survives a real save" do
      item = create_item()
      {:ok, item} = Catalogue.update_item(item, %{data: %{"media_order" => ["a", "b"]}})

      s = socket(%{featured_image_uuid: nil, files_state: %{files: []}})
      params = Attachments.inject_attachment_data(%{"data" => %{}}, s)

      assert {:ok, updated} =
               Catalogue.update_item(item, params, data_owned_keys: item_owned_keys(s))

      refute Map.has_key?(updated.data, "media_order")
    end

    test "setting the featured image still works through the same seam" do
      item = create_item()
      uuid = Ecto.UUID.generate()

      s = socket(%{featured_image_uuid: uuid, files_state: %{files: []}})
      params = Attachments.inject_attachment_data(%{"data" => %{}}, s)

      assert {:ok, updated} =
               Catalogue.update_item(item, params, data_owned_keys: item_owned_keys(s))

      assert updated.data["featured_image_uuid"] == uuid
    end

    test "setting the media order still works through the same seam" do
      item = create_item()
      file_uuid = Ecto.UUID.generate()

      s = socket(%{featured_image_uuid: nil, files_state: %{files: [%{uuid: file_uuid}]}})
      params = Attachments.inject_attachment_data(%{"data" => %{}}, s)

      assert {:ok, updated} =
               Catalogue.update_item(item, params, data_owned_keys: item_owned_keys(s))

      assert updated.data["media_order"] == [file_uuid]
    end

    test "a key the form never touched at all still survives (absence stays absence)" do
      item = create_item()
      {:ok, item} = Catalogue.update_item(item, %{data: %{"meta" => %{"color" => "red"}}})

      s = socket(%{featured_image_uuid: nil, files_state: %{files: []}})
      params = Attachments.inject_attachment_data(%{}, s)

      assert {:ok, updated} =
               Catalogue.update_item(item, params, data_owned_keys: item_owned_keys(s))

      assert updated.data["meta"] == %{"color" => "red"}
    end
  end

  describe "category — seam" do
    test "clearing the featured image survives a real save (key is gone, not null)" do
      category = create_category()

      {:ok, category} =
        Catalogue.update_category(category, %{data: %{"featured_image_uuid" => "old-uuid"}})

      s = socket(%{featured_image_uuid: nil, files_state: %{files: []}})
      params = Attachments.inject_attachment_data(%{"data" => %{}}, s)

      assert {:ok, updated} =
               Catalogue.update_category(category, params,
                 data_owned_keys: category_owned_keys(s)
               )

      refute Map.has_key?(updated.data, "featured_image_uuid")
    end

    test "setting the featured image still works through the same seam" do
      category = create_category()
      uuid = Ecto.UUID.generate()

      s = socket(%{featured_image_uuid: uuid, files_state: %{files: []}})
      params = Attachments.inject_attachment_data(%{"data" => %{}}, s)

      assert {:ok, updated} =
               Catalogue.update_category(category, params,
                 data_owned_keys: category_owned_keys(s)
               )

      assert updated.data["featured_image_uuid"] == uuid
    end
  end

  describe "the invariant holds even without :data_owned_keys" do
    test "create_item/1 never stores a literal null for an Attachments clear-marker" do
      {:ok, cat} = Catalogue.create_catalogue(%{name: "Cat"})
      s = socket(%{featured_image_uuid: nil, files_state: %{files: []}})

      params =
        Attachments.inject_attachment_data(%{"name" => "New", "catalogue_uuid" => cat.uuid}, s)

      assert {:ok, item} = Catalogue.create_item(params)

      refute Map.has_key?(item.data, "featured_image_uuid")
      refute Map.has_key?(item.data, "media_order")
    end
  end
end
