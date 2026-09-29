defmodule PhoenixKitCatalogue.AttachmentsParentFolderTest do
  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase, only: [fixture_item: 1]

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitCatalogue.Attachments
  alias PhoenixKitCatalogue.Schemas.{Category, Item}

  defmodule Hook do
    def parent(:item, _actor), do: {:ok, Process.get(:items_container)}
    def parent(_, _), do: nil
  end

  defmodule Hook3 do
    def parent(:item, _actor, %Item{}), do: {:ok, Process.get(:items_container)}
    def parent(_, _, _), do: nil
    def name(%Item{name: n, sku: s}, _actor), do: {:ok, "#{n} [#{s}]"}
    def name(_, _), do: nil
  end

  defmodule RaisingHook do
    def parent(_kind, _actor, _resource), do: raise("host lookup down")
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:phoenix_kit_catalogue, :attachments_parent_folder)
      Application.delete_env(:phoenix_kit_catalogue, :attachments_folder_name)
    end)

    :ok
  end

  test "parent_folder_uuid is nil without config" do
    assert Attachments.parent_folder_uuid(%Item{uuid: Ecto.UUID.generate()}, nil) == nil
  end

  test "parent_folder_uuid consults the hook per resource kind" do
    {:ok, container} = Storage.create_folder(%{name: "Catalogue items"})
    Process.put(:items_container, container.uuid)
    Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook, :parent})

    assert Attachments.parent_folder_uuid(%Item{uuid: Ecto.UUID.generate()}, nil) ==
             container.uuid

    assert Attachments.parent_folder_uuid(%Category{uuid: Ecto.UUID.generate()}, nil) == nil
  end

  test "3-arity hook is preferred over 2-arity and receives the record" do
    {:ok, container} = Storage.create_folder(%{name: "Köök"})
    Process.put(:items_container, container.uuid)
    Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook3, :parent})

    assert Attachments.parent_folder_uuid(%Item{uuid: Ecto.UUID.generate()}, nil) ==
             container.uuid
  end

  test "folder_name uses the host name hook and falls back to the deterministic name" do
    item = %Item{uuid: Ecto.UUID.generate(), name: "Käepide", sku: "RK-1"}
    assert Attachments.folder_name(item, nil) == "catalogue-item-#{item.uuid}"
    Application.put_env(:phoenix_kit_catalogue, :attachments_folder_name, {Hook3, :name})
    assert Attachments.folder_name(item, nil) == "Käepide [RK-1]"
  end

  test "a renamed folder without pointer is found by host name and not duplicated" do
    {:ok, container} = Storage.create_folder(%{name: "Köök"})
    Process.put(:items_container, container.uuid)
    Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook3, :parent})
    Application.put_env(:phoenix_kit_catalogue, :attachments_folder_name, {Hook3, :name})
    item = %Item{uuid: Ecto.UUID.generate(), name: "Käepide", sku: "RK-1"}
    {:ok, renamed} = Storage.create_folder(%{name: "Käepide [RK-1]", parent_uuid: container.uuid})

    assert %{uuid: uuid} = Attachments.find_resource_folder(item, nil)
    assert uuid == renamed.uuid
  end

  test "lookup falls back to the deterministic name under parent, then root" do
    {:ok, container} = Storage.create_folder(%{name: "Köök"})
    Process.put(:items_container, container.uuid)
    Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook3, :parent})
    item = %Item{uuid: Ecto.UUID.generate(), name: "X", sku: nil}
    {:ok, at_root} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})
    assert %{uuid: r} = Attachments.find_resource_folder(item, nil)
    assert r == at_root.uuid

    {:ok, under} =
      Storage.create_folder(%{name: "catalogue-item-#{item.uuid}", parent_uuid: container.uuid})

    assert %{uuid: u} = Attachments.find_resource_folder(item, nil)
    assert u == under.uuid
  end

  test "maybe_rename_pending_folder renames a pending upload folder to the host name under the host parent" do
    {:ok, container} = Storage.create_folder(%{name: "Köök"})
    Process.put(:items_container, container.uuid)
    Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook3, :parent})
    Application.put_env(:phoenix_kit_catalogue, :attachments_folder_name, {Hook3, :name})

    {:ok, pending} =
      Storage.create_folder(%{name: "catalogue-attachment-pending-#{Ecto.UUID.generate()}"})

    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, phoenix_kit_current_user: nil, files_folder_uuid: pending.uuid}
    }

    saved_item = %Item{uuid: Ecto.UUID.generate(), name: "Käepide", sku: "RK-1"}

    assert :ok = Attachments.maybe_rename_pending_folder(socket, saved_item)

    renamed = Storage.get_folder(pending.uuid)
    assert renamed.name == "Käepide [RK-1]"
    assert renamed.parent_uuid == container.uuid
  end

  defp pending_socket(folder_uuid) do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, phoenix_kit_current_user: nil, files_folder_uuid: folder_uuid}
    }
  end

  defp hooks_on(container) do
    Process.put(:items_container, container.uuid)
    Application.put_env(:phoenix_kit_catalogue, :attachments_parent_folder, {Hook3, :parent})
    Application.put_env(:phoenix_kit_catalogue, :attachments_folder_name, {Hook3, :name})
  end

  test "a raising parent hook falls back to the root instead of crashing the form" do
    Application.put_env(
      :phoenix_kit_catalogue,
      :attachments_parent_folder,
      {RaisingHook, :parent}
    )

    ExUnit.CaptureLog.capture_log(fn ->
      assert Attachments.parent_folder_uuid(%Item{uuid: Ecto.UUID.generate()}, nil) == nil
    end)
  end

  test "a same-named item's host-named folder is not adopted" do
    {:ok, container} = Storage.create_folder(%{name: "Köök"})
    hooks_on(container)
    {:ok, theirs} = Storage.create_folder(%{name: "Käepide [RK-1]", parent_uuid: container.uuid})

    _their_item =
      fixture_item(%{name: "Käepide", sku: "RK-1", data: %{"files_folder_uuid" => theirs.uuid}})

    mine = fixture_item(%{name: "Käepide", sku: "RK-1"})
    assert Attachments.find_resource_folder(mine, nil) == nil
  end

  test "the pending rename leaves a folder that is not pending alone" do
    {:ok, container} = Storage.create_folder(%{name: "Köök"})
    hooks_on(container)

    {:ok, source_folder} =
      Storage.create_folder(%{name: "catalogue-item-#{Ecto.UUID.generate()}"})

    saved_item = %Item{uuid: Ecto.UUID.generate(), name: "Käepide", sku: "RK-1"}

    assert :ok =
             Attachments.maybe_rename_pending_folder(
               pending_socket(source_folder.uuid),
               saved_item
             )

    kept = Storage.get_folder(source_folder.uuid)
    assert {kept.name, kept.parent_uuid} == {source_folder.name, nil}
  end

  test "the pending rename falls back to the deterministic name when the host name is taken" do
    {:ok, container} = Storage.create_folder(%{name: "Köök"})
    hooks_on(container)
    {:ok, _theirs} = Storage.create_folder(%{name: "Käepide [RK-1]", parent_uuid: container.uuid})

    {:ok, pending} =
      Storage.create_folder(%{name: "catalogue-attachment-pending-#{Ecto.UUID.generate()}"})

    saved_item = %Item{uuid: Ecto.UUID.generate(), name: "Käepide", sku: "RK-1"}
    assert :ok = Attachments.maybe_rename_pending_folder(pending_socket(pending.uuid), saved_item)

    renamed = Storage.get_folder(pending.uuid)

    assert {renamed.name, renamed.parent_uuid} ==
             {"catalogue-item-#{saved_item.uuid}", container.uuid}
  end

  test "the pending rename never moves the folder to the root on a failed hook" do
    {:ok, container} = Storage.create_folder(%{name: "Köök"})

    Application.put_env(
      :phoenix_kit_catalogue,
      :attachments_parent_folder,
      {RaisingHook, :parent}
    )

    {:ok, pending} =
      Storage.create_folder(%{
        name: "catalogue-attachment-pending-#{Ecto.UUID.generate()}",
        parent_uuid: container.uuid
      })

    saved_item = %Item{uuid: Ecto.UUID.generate(), name: "Käepide", sku: "RK-1"}

    ExUnit.CaptureLog.capture_log(fn ->
      assert :ok =
               Attachments.maybe_rename_pending_folder(pending_socket(pending.uuid), saved_item)
    end)

    renamed = Storage.get_folder(pending.uuid)

    assert {renamed.name, renamed.parent_uuid} ==
             {"catalogue-item-#{saved_item.uuid}", container.uuid}
  end

  test "opening the picker records the folder as the item's at once, so a same-named item cannot take it" do
    {:ok, container} = Storage.create_folder(%{name: "Köök"})
    hooks_on(container)
    first = fixture_item(%{name: "Käepide", sku: "RK-1"})
    second = fixture_item(%{name: "Käepide", sku: "RK-1"})

    socket_for = fn item ->
      Attachments.mount_attachments(%Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}, item)
    end

    {:noreply, socket} = Attachments.open_featured_image_picker(socket_for.(first))
    folder_uuid = socket.assigns.files_folder_uuid
    assert Storage.get_folder(folder_uuid).name == "Käepide [RK-1]"

    assert PhoenixKitCatalogue.Catalogue.get_item!(first.uuid).data["files_folder_uuid"] ==
             folder_uuid

    {:noreply, other} = Attachments.open_featured_image_picker(socket_for.(second))
    refute other.assigns.files_folder_uuid == folder_uuid

    assert Storage.get_folder(other.assigns.files_folder_uuid).name ==
             "catalogue-item-#{second.uuid}"
  end
end
