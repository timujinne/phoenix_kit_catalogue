defmodule PhoenixKitCatalogue.AttachmentsParentFolderTest do
  use PhoenixKitCatalogue.DataCase, async: false

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

  test "find_folder_by_name looks under the parent first, then at root" do
    {:ok, container} = Storage.create_folder(%{name: "Catalogue items"})
    uuid = Ecto.UUID.generate()
    name = "catalogue-item-#{uuid}"
    {:ok, at_root} = Storage.create_folder(%{name: name})

    assert %{uuid: found} = Attachments.find_folder_by_name(name, container.uuid)
    assert found == at_root.uuid

    {:ok, nested} = Storage.create_folder(%{name: name, parent_uuid: container.uuid})
    assert %{uuid: found2} = Attachments.find_folder_by_name(name, container.uuid)
    assert found2 == nested.uuid
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
end
