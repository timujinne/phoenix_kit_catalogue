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
        metadata_has: %{
          "changes" => %{
            "parent" => %{
              "from" => %{"label" => "All catalogues"},
              "to" => %{"uuid" => parent.uuid, "label" => "Parent"}
            }
          }
        }
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

    test "delete_empty_folder logs folder.deleted" do
      {:ok, folder} = Catalogue.create_folder(%{name: "Gone"}, actor_opts())
      assert {:ok, _} = Catalogue.delete_empty_folder(folder, actor_opts())

      assert_activity_logged("folder.deleted",
        resource_uuid: folder.uuid,
        actor_uuid: @actor
      )
    end

    test "permanently_delete_folder logs folder.permanently_deleted" do
      {:ok, folder} = Catalogue.create_folder(%{name: "Legacy purge"}, actor_opts())
      assert {:ok, _} = Catalogue.permanently_delete_folder(folder, actor_opts())

      assert_activity_logged("folder.permanently_deleted",
        resource_uuid: folder.uuid,
        actor_uuid: @actor
      )
    end

    test "place_level_rows logs catalogue.level_reordered" do
      {:ok, folder} = Catalogue.create_folder(%{name: "Level"}, actor_opts())
      assert :ok = Catalogue.place_level_rows([{"folder", folder.uuid}], actor_opts())

      assert_activity_logged("catalogue.level_reordered",
        resource_uuid: folder.uuid,
        actor_uuid: @actor
      )
    end

    test "move_catalogue_to_folder logs catalogue.moved_to_folder", %{catalogue: cat} do
      {:ok, folder} = Catalogue.create_folder(%{name: "Filed"}, actor_opts())
      {:ok, _} = Catalogue.move_catalogue_to_folder(cat, folder.uuid, actor_opts())

      assert_activity_logged("catalogue.moved_to_folder",
        resource_uuid: cat.uuid,
        actor_uuid: @actor,
        metadata_has: %{
          "changes" => %{
            "folder" => %{
              "from" => %{"label" => "All catalogues"},
              "to" => %{"uuid" => folder.uuid, "label" => "Filed"}
            }
          }
        }
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

    # The entry has to say WHAT changed, not just that something did: the
    # owner opened an event and could not tell (boss via Max, 2026-09-20).
    test "update_item records the fields that moved, from and to", %{catalogue: cat} do
      {:ok, item} =
        Catalogue.create_item(
          %{
            name: "Item A",
            sku: "A-1",
            base_price: Decimal.new("8.50"),
            catalogue_uuid: cat.uuid
          },
          actor_opts()
        )

      {:ok, _} =
        Catalogue.update_item(
          item,
          %{name: "Renamed", base_price: Decimal.new("9.10")},
          actor_opts()
        )

      assert_activity_logged("item.updated",
        resource_uuid: item.uuid,
        metadata_has: %{
          # identity stays a plain string; the diff sits beside it
          "name" => "Renamed",
          "changes" => %{
            "name" => %{"from" => "Item A", "to" => "Renamed"},
            "base_price" => %{"from" => "8.50", "to" => "9.10"}
          }
        }
      )
    end

    test "an update that changes nothing records no diff", %{catalogue: cat} do
      {:ok, item} =
        Catalogue.create_item(
          %{name: "Item A", sku: "A-1", catalogue_uuid: cat.uuid},
          actor_opts()
        )

      {:ok, _} = Catalogue.update_item(item, %{name: "Item A"}, actor_opts())

      row = assert_activity_logged("item.updated", resource_uuid: item.uuid)

      # The identity stays so the row is still readable and linkable; only
      # the from/to pairs are absent, because nothing moved.
      assert row.metadata["name"] == "Item A"
      assert Enum.reject(row.metadata, fn {_k, v} -> is_binary(v) end) == []
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

    test "duplicate_item logs item.duplicated with actor", %{catalogue: cat} do
      {:ok, item} =
        Catalogue.create_item(%{name: "Item A", catalogue_uuid: cat.uuid}, actor_opts())

      {:ok, copy} = Catalogue.duplicate_item(item, actor_opts())

      assert_activity_logged("item.duplicated",
        resource_uuid: copy.uuid,
        actor_uuid: @actor,
        metadata_has: %{"source_uuid" => item.uuid, "name" => copy.name}
      )
    end

    test "duplicate_catalogue logs one catalogue.duplicated and no per-row entries",
         %{catalogue: cat} do
      {:ok, _item} =
        Catalogue.create_item(%{name: "Item A", catalogue_uuid: cat.uuid}, actor_opts())

      {:ok, %{catalogue: copy}} = Catalogue.duplicate_catalogue(cat, actor_opts())

      assert_activity_logged("catalogue.duplicated",
        resource_uuid: copy.uuid,
        actor_uuid: @actor,
        metadata_has: %{
          "source_uuid" => cat.uuid,
          "items" => 1,
          "categories" => 0,
          "without" => [],
          "archived" => false
        }
      )

      refute_activity_logged("item.duplicated")
    end

    test "bulk_duplicate_items logs item.bulk_duplicated with actor", %{catalogue: cat} do
      {:ok, item} =
        Catalogue.create_item(%{name: "Item A", catalogue_uuid: cat.uuid}, actor_opts())

      assert {:ok, %{created: 1}} = Catalogue.bulk_duplicate_items([item.uuid], actor_opts())

      assert_activity_logged("item.bulk_duplicated",
        actor_uuid: @actor,
        metadata_has: %{"count" => 1}
      )
    end
  end

  describe "move actions" do
    setup %{catalogue: cat} do
      {:ok, other} = Catalogue.create_catalogue(%{name: "Activity Move Target"})
      {:ok, home} = Catalogue.create_category(%{name: "Home", catalogue_uuid: cat.uuid})
      {:ok, away} = Catalogue.create_category(%{name: "Away", catalogue_uuid: other.uuid})
      {:ok, item} = Catalogue.create_item(%{name: "Mover", category_uuid: home.uuid})
      %{other: other, home: home, away: away, item: item}
    end

    test "move_item_to_category logs item.moved with actor and both places",
         %{catalogue: cat, other: other, home: home, away: away, item: item} do
      {:ok, _} = Catalogue.move_item_to_category(item, away.uuid, actor_opts())

      assert_activity_logged("item.moved",
        resource_uuid: item.uuid,
        actor_uuid: @actor,
        metadata_has: %{
          "changes" => %{
            "category" => %{
              "from" => %{"uuid" => home.uuid, "label" => home.name},
              "to" => %{"uuid" => away.uuid, "label" => away.name}
            },
            "catalogue" => %{
              "from" => %{"uuid" => cat.uuid, "label" => cat.name},
              "to" => %{"uuid" => other.uuid, "label" => other.name}
            }
          }
        }
      )
    end

    test "move_item_to_catalogue logs item.moved with actor",
         %{catalogue: cat, other: other, home: home, item: item} do
      {:ok, _} = Catalogue.move_item_to_catalogue(item, other.uuid, actor_opts())

      assert_activity_logged("item.moved",
        resource_uuid: item.uuid,
        actor_uuid: @actor,
        metadata_has: %{
          "changes" => %{
            "catalogue" => %{
              "from" => %{"uuid" => cat.uuid, "label" => cat.name},
              "to" => %{"uuid" => other.uuid, "label" => other.name}
            },
            # The item lands uncategorized in its new catalogue, and the
            # label says so rather than leaving the arrow half empty.
            "category" => %{
              "from" => %{"uuid" => home.uuid, "label" => home.name},
              "to" => %{"label" => "Uncategorized"}
            }
          }
        }
      )
    end

    test "move_category_to_catalogue logs category.moved with actor, parent and sizes",
         %{catalogue: cat, other: other, home: home, away: away} do
      {:ok, _} =
        Catalogue.move_category_to_catalogue(
          home,
          other.uuid,
          [parent_uuid: away.uuid] ++ actor_opts()
        )

      assert_activity_logged("category.moved",
        resource_uuid: home.uuid,
        actor_uuid: @actor,
        metadata_has: %{
          "subtree_size" => 1,
          "items_cascaded" => 1,
          "changes" => %{
            "catalogue" => %{
              "from" => %{"uuid" => cat.uuid, "label" => cat.name},
              "to" => %{"uuid" => other.uuid, "label" => other.name}
            },
            "parent" => %{
              "from" => %{"label" => "Uncategorized"},
              "to" => %{"uuid" => away.uuid, "label" => away.name}
            }
          }
        }
      )
    end

    test "move_category_under logs category.moved with actor", %{catalogue: cat, home: home} do
      {:ok, parent} = Catalogue.create_category(%{name: "New parent", catalogue_uuid: cat.uuid})
      {:ok, _} = Catalogue.move_category_under(home, parent.uuid, actor_opts())

      assert_activity_logged("category.moved",
        resource_uuid: home.uuid,
        actor_uuid: @actor,
        metadata_has: %{
          "catalogue_uuid" => cat.uuid,
          "changes" => %{
            "parent" => %{
              "from" => %{"label" => "Uncategorized"},
              "to" => %{"uuid" => parent.uuid, "label" => "New parent"}
            }
          }
        }
      )
    end

    test "bulk_move_items logs one item.bulk_moved with actor and destination",
         %{catalogue: cat, other: other, away: away, item: item} do
      {:ok, 1} =
        Catalogue.bulk_move_items(
          [item.uuid],
          {:category, away.uuid},
          [catalogue_uuid: cat.uuid] ++ actor_opts()
        )

      assert_activity_logged("item.bulk_moved",
        actor_uuid: @actor,
        metadata_has: %{
          "count" => 1,
          "uuids" => [item.uuid],
          # A bulk move gathers items from many categories, so it records
          # WHERE they landed rather than inventing one source.
          "moved_to" => %{
            "catalogue" => %{"uuid" => other.uuid, "label" => other.name},
            "category" => %{"uuid" => away.uuid, "label" => away.name}
          }
        }
      )
    end
  end

  describe "category.duplicated actions" do
    test "duplicate_category logs category.duplicated with actor", %{catalogue: cat} do
      {:ok, category} =
        Catalogue.create_category(%{name: "Cat A", catalogue_uuid: cat.uuid}, actor_opts())

      {:ok, %{category: copy}} = Catalogue.duplicate_category(category, actor_opts())

      assert_activity_logged("category.duplicated",
        resource_uuid: copy.uuid,
        actor_uuid: @actor,
        metadata_has: %{"source_uuid" => category.uuid}
      )
    end

    test "bulk_duplicate_categories logs category.bulk_duplicated with actor", %{catalogue: cat} do
      {:ok, category} =
        Catalogue.create_category(%{name: "Cat A", catalogue_uuid: cat.uuid}, actor_opts())

      assert {:ok, %{created: 1}} =
               Catalogue.bulk_duplicate_categories([category.uuid], actor_opts())

      assert_activity_logged("category.bulk_duplicated",
        actor_uuid: @actor,
        metadata_has: %{"count" => 1}
      )
    end
  end

  describe "trash / restore / permanent delete actions" do
    test "trash_category logs category.trashed with the items' disposition", %{catalogue: cat} do
      {:ok, category} = Catalogue.create_category(%{name: "Gone", catalogue_uuid: cat.uuid})
      {:ok, _} = Catalogue.create_item(%{name: "Inside", category_uuid: category.uuid})
      {:ok, _} = Catalogue.trash_category(category, [items: :cascade] ++ actor_opts())

      assert_activity_logged("category.trashed",
        resource_uuid: category.uuid,
        actor_uuid: @actor,
        metadata_has: %{
          "items_disposition" => "cascade",
          "items_handled" => 1,
          "subtree_size" => 1
        }
      )
    end

    test "restore_category logs category.restored with what came back", %{catalogue: cat} do
      {:ok, parent} = Catalogue.create_category(%{name: "Parent", catalogue_uuid: cat.uuid})

      {:ok, child} =
        Catalogue.create_category(%{
          name: "Child",
          catalogue_uuid: cat.uuid,
          parent_uuid: parent.uuid
        })

      {:ok, _} = Catalogue.create_item(%{name: "Deep", category_uuid: child.uuid})
      {:ok, _} = Catalogue.trash_category(parent, items: :cascade)
      {:ok, _} = Catalogue.restore_category(Catalogue.get_category(parent.uuid), actor_opts())

      assert_activity_logged("category.restored",
        resource_uuid: parent.uuid,
        actor_uuid: @actor,
        metadata_has: %{"descendants_restored" => 1, "items_restored" => 1}
      )
    end

    test "permanently_delete_category logs what it removed and what it kept", %{catalogue: cat} do
      {:ok, parent} = Catalogue.create_category(%{name: "Parent", catalogue_uuid: cat.uuid})

      {:ok, child} =
        Catalogue.create_category(%{
          name: "Child",
          catalogue_uuid: cat.uuid,
          parent_uuid: parent.uuid
        })

      {:ok, _} = Catalogue.create_item(%{name: "In parent", category_uuid: parent.uuid})
      {:ok, _} = Catalogue.trash_category(parent, items: :cascade)
      {:ok, _} = Catalogue.restore_category(Catalogue.get_category(child.uuid))

      {:ok, _} =
        Catalogue.permanently_delete_category(Catalogue.get_category(parent.uuid), actor_opts())

      assert_activity_logged("category.permanently_deleted",
        resource_uuid: parent.uuid,
        actor_uuid: @actor,
        metadata_has: %{
          "subtree_size" => 1,
          "items_cascaded" => 1,
          "kept_live_subcategories" => 1
        }
      )
    end

    test "restore_catalogue logs how many categories and items came back", %{catalogue: cat} do
      {:ok, category} = Catalogue.create_category(%{name: "Shelf", catalogue_uuid: cat.uuid})
      {:ok, _} = Catalogue.create_item(%{name: "On shelf", category_uuid: category.uuid})
      {:ok, _} = Catalogue.create_item(%{name: "Loose", catalogue_uuid: cat.uuid})
      {:ok, _} = Catalogue.trash_catalogue(cat)
      {:ok, _} = Catalogue.restore_catalogue(cat, actor_opts())

      assert_activity_logged("catalogue.restored",
        resource_uuid: cat.uuid,
        actor_uuid: @actor,
        metadata_has: %{"categories_restored" => 1, "items_restored" => 2}
      )
    end

    test "permanently_delete_catalogue logs catalogue.permanently_deleted", %{catalogue: cat} do
      {:ok, _} = Catalogue.trash_catalogue(cat)
      {:ok, _} = Catalogue.permanently_delete_catalogue(cat, actor_opts())

      assert_activity_logged("catalogue.permanently_deleted",
        resource_uuid: cat.uuid,
        actor_uuid: @actor,
        metadata_has: %{"name" => cat.name}
      )
    end

    test "restore_item logs item.restored, marking an item taken out of its trashed category",
         %{catalogue: cat} do
      {:ok, category} = Catalogue.create_category(%{name: "Shelf", catalogue_uuid: cat.uuid})
      {:ok, item} = Catalogue.create_item(%{name: "On shelf", category_uuid: category.uuid})
      {:ok, _} = Catalogue.trash_category(category, items: :cascade)
      {:ok, _} = Catalogue.restore_item(Catalogue.get_item(item.uuid), actor_opts())

      assert_activity_logged("item.restored",
        resource_uuid: item.uuid,
        actor_uuid: @actor,
        metadata_has: %{"detached_from_category" => true}
      )
    end

    test "bulk trash, restore and permanent delete log their item.bulk_* actions",
         %{catalogue: cat} do
      {:ok, a} = Catalogue.create_item(%{name: "A", catalogue_uuid: cat.uuid})
      {:ok, b} = Catalogue.create_item(%{name: "B", catalogue_uuid: cat.uuid})
      opts = [catalogue_uuid: cat.uuid] ++ actor_opts()

      assert {2, nil} = Catalogue.bulk_trash_items([a.uuid, b.uuid], opts)

      assert_activity_logged("item.bulk_trashed",
        actor_uuid: @actor,
        metadata_has: %{"count" => 2}
      )

      assert {1, nil} = Catalogue.bulk_restore_items([a.uuid], opts)

      assert_activity_logged("item.bulk_restored",
        actor_uuid: @actor,
        metadata_has: %{"count" => 1}
      )

      assert {1, nil} = Catalogue.bulk_permanently_delete_items([b.uuid], opts)

      assert_activity_logged("item.bulk_permanently_deleted",
        actor_uuid: @actor,
        metadata_has: %{"count" => 1}
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
