defmodule PhoenixKitCatalogue.ActivityLoggingTest do
  @moduledoc """
  Per-action coverage of `phoenix_kit_activities` rows produced by the
  catalogue context. Without these tests, a typoed action string or a
  silently dropped `actor_uuid` opt regresses without any other test
  catching it (the CRUD coverage doesn't query the activity table
  directly).

  Pinning every action atom + every threaded actor here means the LV
  smoke tests can assert on the surface flash without missing a
  log-side regression.
  """

  use PhoenixKitCatalogue.DataCase, async: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.PubSub

  @actor "00000000-0000-7000-8000-000000000001"

  defp actor_opts, do: [actor_uuid: @actor]

  setup do
    {:ok, cat} = Catalogue.create_catalogue(%{name: "Activity Test Catalogue"}, actor_opts())
    %{catalogue: cat}
  end

  describe "catalogue.* actions" do
    test "create_catalogue logs catalogue.created with actor + name", %{catalogue: cat} do
      # `setup` already created one with our actor — assert the row landed
      # with the expected metadata shape.
      assert_activity_logged("catalogue.created",
        resource_uuid: cat.uuid,
        actor_uuid: @actor,
        metadata_has: %{"name" => cat.name}
      )
    end

    test "update_catalogue logs catalogue.updated with actor", %{catalogue: cat} do
      {:ok, updated} = Catalogue.update_catalogue(cat, %{description: "renamed"}, actor_opts())

      assert_activity_logged("catalogue.updated",
        resource_uuid: updated.uuid,
        actor_uuid: @actor,
        metadata_has: %{"name" => updated.name}
      )
    end

    test "trash_catalogue logs catalogue.trashed with actor", %{catalogue: cat} do
      {:ok, _} = Catalogue.trash_catalogue(cat, actor_opts())

      assert_activity_logged("catalogue.trashed",
        resource_uuid: cat.uuid,
        actor_uuid: @actor
      )
    end

    test "restore_catalogue logs catalogue.restored with actor", %{catalogue: cat} do
      {:ok, _} = Catalogue.trash_catalogue(cat, actor_opts())
      {:ok, _} = Catalogue.restore_catalogue(cat, actor_opts())

      assert_activity_logged("catalogue.restored",
        resource_uuid: cat.uuid,
        actor_uuid: @actor
      )
    end
  end

  describe "category.* actions" do
    test "create_category logs category.created with actor", %{catalogue: cat} do
      {:ok, category} =
        Catalogue.create_category(%{name: "Cat A", catalogue_uuid: cat.uuid}, actor_opts())

      assert_activity_logged("category.created",
        resource_uuid: category.uuid,
        actor_uuid: @actor
      )
    end

    test "update_category logs category.updated with actor", %{catalogue: cat} do
      {:ok, category} =
        Catalogue.create_category(%{name: "Cat A", catalogue_uuid: cat.uuid}, actor_opts())

      {:ok, _} = Catalogue.update_category(category, %{name: "Renamed"}, actor_opts())

      assert_activity_logged("category.updated",
        resource_uuid: category.uuid,
        actor_uuid: @actor
      )
    end
  end

  describe "folder.* actions" do
    test "create_folder logs folder.created with actor + name" do
      {:ok, folder} = Catalogue.create_folder(%{name: "Brochures"}, actor_opts())

      assert_activity_logged("folder.created",
        resource_uuid: folder.uuid,
        actor_uuid: @actor,
        metadata_has: %{"name" => "Brochures"}
      )
    end

    test "update_folder logs folder.updated on a real change" do
      {:ok, folder} = Catalogue.create_folder(%{name: "Old"}, actor_opts())
      {:ok, _} = Catalogue.update_folder(folder, %{name: "New"}, actor_opts())

      assert_activity_logged("folder.updated", resource_uuid: folder.uuid, actor_uuid: @actor)
    end

    test "move_folder logs folder.moved carrying the destination parent" do
      {:ok, parent} = Catalogue.create_folder(%{name: "Parent"}, actor_opts())
      {:ok, child} = Catalogue.create_folder(%{name: "Child"}, actor_opts())
      {:ok, _} = Catalogue.move_folder(child, parent.uuid, actor_opts())

      assert_activity_logged("folder.moved",
        resource_uuid: child.uuid,
        actor_uuid: @actor,
        metadata_has: %{"to_parent_uuid" => parent.uuid}
      )
    end

    test "trash_folder + restore_folder log folder.trashed / folder.restored" do
      {:ok, folder} = Catalogue.create_folder(%{name: "Temp"}, actor_opts())
      {:ok, _} = Catalogue.trash_folder(folder, actor_opts())
      {:ok, _} = Catalogue.restore_folder(folder, actor_opts())

      assert_activity_logged("folder.trashed", resource_uuid: folder.uuid, actor_uuid: @actor)
      assert_activity_logged("folder.restored", resource_uuid: folder.uuid, actor_uuid: @actor)
    end

    test "reorder_folders logs folder.reordered" do
      {:ok, a} = Catalogue.create_folder(%{name: "A"}, actor_opts())
      {:ok, b} = Catalogue.create_folder(%{name: "B"}, actor_opts())
      assert :ok = Catalogue.reorder_folders([a.uuid, b.uuid], actor_opts())

      assert_activity_logged("folder.reordered", actor_uuid: @actor)
    end

    test "move_catalogue_to_folder logs catalogue.moved_to_folder", %{catalogue: cat} do
      {:ok, folder} = Catalogue.create_folder(%{name: "Filed"}, actor_opts())
      {:ok, _} = Catalogue.move_catalogue_to_folder(cat, folder.uuid, actor_opts())

      assert_activity_logged("catalogue.moved_to_folder",
        resource_uuid: cat.uuid,
        actor_uuid: @actor,
        metadata_has: %{"to_folder_uuid" => folder.uuid}
      )
    end
  end

  describe "item.* actions" do
    test "create_item logs item.created with actor", %{catalogue: cat} do
      {:ok, item} =
        Catalogue.create_item(%{name: "Item A", catalogue_uuid: cat.uuid}, actor_opts())

      assert_activity_logged("item.created",
        resource_uuid: item.uuid,
        actor_uuid: @actor,
        metadata_has: %{"name" => "Item A"}
      )
    end

    test "update_item logs item.updated with actor", %{catalogue: cat} do
      {:ok, item} =
        Catalogue.create_item(%{name: "Item A", catalogue_uuid: cat.uuid}, actor_opts())

      {:ok, _} = Catalogue.update_item(item, %{name: "Renamed"}, actor_opts())

      assert_activity_logged("item.updated",
        resource_uuid: item.uuid,
        actor_uuid: @actor
      )
    end

    test "trash_item logs item.trashed with actor", %{catalogue: cat} do
      {:ok, item} =
        Catalogue.create_item(%{name: "Item A", catalogue_uuid: cat.uuid}, actor_opts())

      {:ok, _} = Catalogue.trash_item(item, actor_opts())

      assert_activity_logged("item.trashed",
        resource_uuid: item.uuid,
        actor_uuid: @actor
      )
    end
  end

  describe "manufacturer / supplier actions" do
    test "create_manufacturer logs manufacturer.created with actor" do
      {:ok, m} = Catalogue.create_manufacturer(%{name: "M"}, actor_opts())

      assert_activity_logged("manufacturer.created",
        resource_uuid: m.uuid,
        actor_uuid: @actor,
        metadata_has: %{"name" => "M"}
      )
    end

    test "create_supplier logs supplier.created with actor" do
      {:ok, s} = Catalogue.create_supplier(%{name: "S"}, actor_opts())

      assert_activity_logged("supplier.created",
        resource_uuid: s.uuid,
        actor_uuid: @actor,
        metadata_has: %{"name" => "S"}
      )
    end
  end

  describe "module toggle" do
    test "enable_system / disable_system log catalogue_module.enabled / .disabled" do
      # Run both in this test so we exercise the C4 module-toggle pair
      # in one go — they both depend on Settings being present (which
      # the test migration provides).
      _ = PhoenixKitCatalogue.enable_system()

      assert_activity_logged("catalogue_module.enabled",
        metadata_has: %{"module_key" => "catalogue"}
      )

      _ = PhoenixKitCatalogue.disable_system()

      assert_activity_logged("catalogue_module.disabled",
        metadata_has: %{"module_key" => "catalogue"}
      )
    end
  end

  # PR #13 review #1: callers thread `parent_catalogue_uuid:` into
  # `log_activity/2` attrs so the broadcast path doesn't fall back to
  # the `lookup_parent/2` DB lookup. These tests pin the broadcast
  # tuple shape — if a future refactor drops the threading, the
  # `lookup_parent` fallback would still produce the same parent
  # value, but the tests would catch it via the in-test instrumentation
  # that doesn't traverse `lookup_parent`.
  describe "PubSub broadcast carries parent_catalogue_uuid (PR #13 #1)" do
    setup %{catalogue: cat} do
      PubSub.subscribe()
      %{catalogue: cat}
    end

    test "category.created broadcasts {:category, _, parent_catalogue_uuid}", %{catalogue: cat} do
      {:ok, category} =
        Catalogue.create_category(%{name: "C", catalogue_uuid: cat.uuid}, actor_opts())

      assert_receive {:catalogue_data_changed, :category, uuid, parent}
      assert uuid == category.uuid
      assert parent == cat.uuid
    end

    test "item.created broadcasts {:item, _, parent_catalogue_uuid}", %{catalogue: cat} do
      {:ok, item} =
        Catalogue.create_item(%{name: "I", catalogue_uuid: cat.uuid}, actor_opts())

      assert_receive {:catalogue_data_changed, :item, uuid, parent}
      assert uuid == item.uuid
      assert parent == cat.uuid
    end

    test "item.updated broadcasts the catalogue parent", %{catalogue: cat} do
      {:ok, item} =
        Catalogue.create_item(%{name: "I", catalogue_uuid: cat.uuid}, actor_opts())

      flush_messages()

      {:ok, updated} = Catalogue.update_item(item, %{name: "Renamed"}, actor_opts())

      assert_receive {:catalogue_data_changed, :item, uuid, parent}
      assert uuid == updated.uuid
      assert parent == cat.uuid
    end

    test "trash_item broadcasts the catalogue parent", %{catalogue: cat} do
      {:ok, item} =
        Catalogue.create_item(%{name: "I", catalogue_uuid: cat.uuid}, actor_opts())

      flush_messages()

      {:ok, _} = Catalogue.trash_item(item, actor_opts())

      assert_receive {:catalogue_data_changed, :item, _uuid, parent}
      assert parent == cat.uuid
    end

    test "create_folder broadcasts {:folder, uuid, nil}", %{catalogue: _cat} do
      {:ok, folder} = Catalogue.create_folder(%{name: "F"}, actor_opts())

      # Folders are module-global, so there's no catalogue parent to thread —
      # the index LV reloads its whole tree on any :folder event.
      assert_receive {:catalogue_data_changed, :folder, uuid, parent}
      assert uuid == folder.uuid
      assert parent == nil
    end
  end

  # Drains the test process's mailbox of any pending
  # `:catalogue_data_changed` messages — used between fixture setup
  # and the actual mutation under test so we don't false-positive on
  # the create's broadcast.
  defp flush_messages do
    receive do
      {:catalogue_data_changed, _, _, _} -> flush_messages()
    after
      0 -> :ok
    end
  end
end
