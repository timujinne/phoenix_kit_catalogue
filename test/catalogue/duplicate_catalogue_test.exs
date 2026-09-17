defmodule PhoenixKitCatalogue.Catalogue.DuplicateCatalogueTest do
  @moduledoc """
  Duplicating a whole catalogue: the row (renamed, same status and
  folder), every live category with its tree and every live item, the
  items' own extras, references between copied rows pointed at the copy,
  and extension data passed through each extension's `duplicate_data/2`.
  The original is left exactly as it was.
  """
  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase,
    only: [fixture_catalogue: 1, fixture_category: 2, fixture_item: 1, fixture_supplier: 1]

  alias Ecto.Adapters.SQL
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.FolderLink
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.PubSub, as: CataloguePubSub
  alias PhoenixKitCatalogue.Schemas.Catalogue, as: CatalogueSchema
  alias PhoenixKitCatalogue.Schemas.{CatalogueRule, Category, Item}
  alias PhoenixKitCatalogue.Test.{CopyAwareModule, Repo}

  defp categories_of(catalogue_uuid) do
    Repo.all(
      from(c in Category,
        where: c.catalogue_uuid == ^catalogue_uuid,
        order_by: [asc: c.position, asc: c.name]
      )
    )
  end

  defp items_of(catalogue_uuid) do
    Repo.all(from(i in Item, where: i.catalogue_uuid == ^catalogue_uuid, order_by: [asc: i.name]))
  end

  defp snapshot(catalogue_uuid) do
    {Enum.map(
       categories_of(catalogue_uuid),
       &Map.take(&1, [:uuid, :name, :status, :parent_uuid])
     ),
     Enum.map(items_of(catalogue_uuid), &Map.take(&1, [:uuid, :name, :status, :category_uuid]))}
  end

  describe "the catalogue row" do
    test "is renamed in every language and keeps status, folder, kind and pricing" do
      {:ok, folder} = Catalogue.create_folder(%{name: "Filed here"})

      source =
        fixture_catalogue(%{
          name: "Kitchen",
          description: "Cabinets",
          status: "archived",
          folder_uuid: folder.uuid,
          markup_percentage: Decimal.new("12.5"),
          discount_percentage: Decimal.new("5"),
          data: %{
            "et-EE" => %{"_name" => "Köök"},
            "meta" => %{"brand" => "Andi"},
            "_trash" => %{"via" => "self"}
          }
        })

      assert {:ok, %{catalogue: copy, categories: 0, items: 0}} =
               Catalogue.duplicate_catalogue(source)

      assert copy.uuid != source.uuid
      assert copy.name == "Kitchen (copy)"
      assert copy.description == "Cabinets"
      assert copy.status == "archived"
      assert copy.folder_uuid == folder.uuid
      assert copy.kind == "standard"
      assert Decimal.equal?(copy.markup_percentage, Decimal.new("12.5"))
      assert Decimal.equal?(copy.discount_percentage, Decimal.new("5"))
      assert copy.data["et-EE"] == %{"_name" => "Köök (koopia)"}
      assert copy.data["meta"] == %{"brand" => "Andi"}
      refute Map.has_key?(copy.data, "_trash")
    end

    test "the name column's suffix is in the content's primary language" do
      source = fixture_catalogue(%{name: "Köök", data: %{"_primary_language" => "et-EE"}})

      {:ok, %{catalogue: first}} = Catalogue.duplicate_catalogue(source)
      {:ok, %{catalogue: second}} = Catalogue.duplicate_catalogue(source)

      assert first.name == "Köök (koopia)"
      assert second.name == "Köök (koopia 2)"
    end

    test "a taken copy name moves on to (copy 2); a trashed one is free" do
      source = fixture_catalogue(%{name: "Bathroom"})

      assert {:ok, %{catalogue: first}} = Catalogue.duplicate_catalogue(source)
      assert {:ok, %{catalogue: second}} = Catalogue.duplicate_catalogue(source)
      assert first.name == "Bathroom (copy)"
      assert second.name == "Bathroom (copy 2)"

      {:ok, _} = Catalogue.trash_catalogue(first)
      assert {:ok, %{catalogue: third}} = Catalogue.duplicate_catalogue(source)
      assert third.name == "Bathroom (copy)"
    end

    test "a trashed source is refused" do
      source = fixture_catalogue(%{name: "Binned"})
      {:ok, _} = Catalogue.trash_catalogue(source)

      assert {:error, :not_found} = Catalogue.duplicate_catalogue(source)
    end

    test "a smart catalogue's items keep their rules on the same standard catalogues" do
      standard = fixture_catalogue(%{name: "Referenced"})
      smart = fixture_catalogue(%{name: "Fees", kind: "smart"})
      fee = fixture_item(%{name: "Delivery", catalogue_uuid: smart.uuid})

      {:ok, _} =
        Catalogue.put_catalogue_rules(fee, [
          %{referenced_catalogue_uuid: standard.uuid, value: Decimal.new("10"), unit: "percent"}
        ])

      {:ok, %{catalogue: copy}} = Catalogue.duplicate_catalogue(smart)
      [copied_fee] = items_of(copy.uuid)

      assert copy.kind == "smart"

      assert [%CatalogueRule{referenced_catalogue_uuid: ref}] =
               Repo.all(from(r in CatalogueRule, where: r.item_uuid == ^copied_fee.uuid))

      assert ref == standard.uuid
    end
  end

  describe "the contents" do
    setup do
      source = fixture_catalogue(%{name: "Wardrobes"})
      doors = fixture_category(source, %{name: "Doors", position: 2})
      frames = fixture_category(source, %{name: "Frames", position: 1})
      hinges = fixture_category(source, %{name: "Hinges", parent_uuid: doors.uuid, position: 0})

      fixture_item(%{name: "Oak door", category_uuid: doors.uuid, sku: "OAK-1", position: 3})
      fixture_item(%{name: "Soft hinge", category_uuid: hinges.uuid, sku: "H-1"})
      fixture_item(%{name: "Loose knob", catalogue_uuid: source.uuid, sku: "K-1"})

      %{source: source, doors: doors, frames: frames, hinges: hinges}
    end

    test "every live category keeps its place in the tree, every live item its category",
         %{source: source} do
      assert {:ok, %{catalogue: copy, categories: 3, items: 3}} =
               Catalogue.duplicate_catalogue(source)

      cats = categories_of(copy.uuid)

      assert Enum.map(cats, &{&1.name, &1.position}) |> Enum.sort() ==
               [{"Doors", 2}, {"Frames", 1}, {"Hinges", 0}]

      by_name = Map.new(cats, &{&1.name, &1})
      assert by_name["Hinges"].parent_uuid == by_name["Doors"].uuid
      assert by_name["Doors"].parent_uuid == nil

      items = Map.new(items_of(copy.uuid), &{&1.name, &1})
      assert items["Oak door"].category_uuid == by_name["Doors"].uuid
      assert items["Oak door"].sku == "OAK-1"
      assert items["Oak door"].position == 3
      assert items["Soft hinge"].category_uuid == by_name["Hinges"].uuid
      assert items["Loose knob"].category_uuid == nil

      # Nested rows keep their names: only the catalogue is renamed.
      refute Enum.any?(Map.keys(items) ++ Map.keys(by_name), &String.contains?(&1, "(copy)"))
    end

    test "leaves the original exactly as it was", %{source: source} do
      before = snapshot(source.uuid)
      {:ok, _} = Catalogue.duplicate_catalogue(source)
      assert snapshot(source.uuid) == before
    end

    test "trashed rows stay behind; a live category under a trashed parent becomes top level",
         %{source: source, doors: doors, hinges: hinges} do
      binned = fixture_item(%{name: "Binned item", catalogue_uuid: source.uuid})
      {:ok, _} = Catalogue.trash_item(binned)
      {:ok, _} = Catalogue.trash_category(doors, items: :cascade)
      {:ok, _} = Catalogue.restore_category(Catalogue.get_category(hinges.uuid))

      # The doors cascade stamped the hinge with Doors as its root, so
      # restoring Hinges leaves it in the bin; its own restore brings it
      # back into the live Hinges.
      [hinge] = Enum.filter(items_of(source.uuid), &(&1.name == "Soft hinge"))
      {:ok, _} = Catalogue.restore_item(hinge)

      {:ok, %{catalogue: copy, categories: categories, items: items}} =
        Catalogue.duplicate_catalogue(source)

      names = categories_of(copy.uuid) |> Enum.map(&{&1.name, &1.parent_uuid})
      assert Enum.sort(names) == [{"Frames", nil}, {"Hinges", nil}]
      assert categories == 2

      copied_items = items_of(copy.uuid) |> Enum.map(& &1.name)
      assert Enum.sort(copied_items) == ["Loose knob", "Soft hinge"]
      assert items == 2
      assert Enum.all?(items_of(copy.uuid), &(&1.status == "active"))
    end

    test "a live item whose category is gone is copied uncategorized", %{source: source} do
      orphan_home = fixture_category(source, %{name: "Orphan home"})
      orphan = fixture_item(%{name: "Orphan", category_uuid: orphan_home.uuid})

      # Legacy shape the trash invariant no longer allows: the item stayed
      # live while its category went to the bin.
      Repo.update_all(from(c in Category, where: c.uuid == ^orphan_home.uuid),
        set: [status: "deleted"]
      )

      {:ok, %{catalogue: copy}} = Catalogue.duplicate_catalogue(source)

      [copied] = Enum.filter(items_of(copy.uuid), &(&1.name == orphan.name))
      assert copied.category_uuid == nil
    end

    test "item extras come along: supplier rows with a fresh thread", %{source: source} do
      supplier = fixture_supplier(%{name: "Hinge Co"})
      [knob] = Enum.filter(items_of(source.uuid), &(&1.name == "Loose knob"))

      {:ok, _} =
        Catalogue.create_supplier_info(%{
          item_uuid: knob.uuid,
          supplier_uuid: supplier.uuid,
          unit_cost: Decimal.new("2.00"),
          currency: "EUR"
        })

      {:ok, %{catalogue: copy}} = Catalogue.duplicate_catalogue(source)
      [copied_knob] = Enum.filter(items_of(copy.uuid), &(&1.name == "Loose knob"))
      [row] = Catalogue.list_supplier_infos_for_item(copied_knob.uuid)
      [original_row] = Catalogue.list_supplier_infos_for_item(knob.uuid)

      assert row.supplier_uuid == supplier.uuid

      refute Catalogue.supplier_comment_thread_uuid(row) ==
               Catalogue.supplier_comment_thread_uuid(original_row)
    end

    test "references between copied rows point at the copies; others stay",
         %{source: source, doors: doors} do
      [oak] = Enum.filter(items_of(source.uuid), &(&1.name == "Oak door"))
      outside = fixture_item(%{name: "Elsewhere"})
      file_uuid = UUIDv7.generate()

      Repo.update_all(from(c in Category, where: c.uuid == ^doors.uuid),
        set: [
          data: %{
            "shop" => %{"featured_item_uuid" => oak.uuid, "related" => [outside.uuid]},
            "featured_image_uuid" => file_uuid
          }
        ]
      )

      {:ok, %{catalogue: copy}} = Catalogue.duplicate_catalogue(source)

      [copied_doors] = Enum.filter(categories_of(copy.uuid), &(&1.name == "Doors"))
      [copied_oak] = Enum.filter(items_of(copy.uuid), &(&1.name == "Oak door"))

      assert copied_doors.data["shop"]["featured_item_uuid"] == copied_oak.uuid
      assert copied_doors.data["shop"]["related"] == [outside.uuid]
      assert copied_doors.data["featured_image_uuid"] == file_uuid
    end

    test "a single category copy re-points references inside its subtree", %{doors: doors} do
      [oak] = Enum.filter(items_of(doors.catalogue_uuid), &(&1.name == "Oak door"))

      Repo.update_all(from(c in Category, where: c.uuid == ^doors.uuid),
        set: [data: %{"shop" => %{"featured_item_uuid" => oak.uuid}}]
      )

      {:ok, %{category: copy}} = Catalogue.duplicate_category(Catalogue.get_category(doors.uuid))

      copied_oak =
        Repo.one!(from(i in Item, where: i.category_uuid == ^copy.uuid and i.name == "Oak door"))

      assert copy.data["shop"]["featured_item_uuid"] == copied_oak.uuid
      assert Catalogue.get_category(doors.uuid).data["shop"]["featured_item_uuid"] == oak.uuid
    end

    test "tells the pages once, for the copy", %{source: source} do
      CataloguePubSub.subscribe()
      {:ok, %{catalogue: copy}} = Catalogue.duplicate_catalogue(source)

      copy_uuid = copy.uuid
      assert_receive {:catalogue_data_changed, :catalogue, ^copy_uuid, ^copy_uuid}
      refute_receive {:catalogue_data_changed, :item, _, _}, 50
    end
  end

  describe "choices" do
    setup do
      source = fixture_catalogue(%{name: "Choices"})
      shelf = fixture_category(source, %{name: "Shelf"})
      supplier = fixture_supplier(%{name: "Choice supplier"})
      item = fixture_item(%{name: "Knob", category_uuid: shelf.uuid, sku: "KN-1"})

      {:ok, _} =
        Catalogue.create_supplier_info(%{
          item_uuid: item.uuid,
          supplier_uuid: supplier.uuid,
          unit_cost: Decimal.new("3.00"),
          currency: "EUR"
        })

      user_uuid = insert_user!()
      {:ok, folder} = Storage.create_folder(%{name: "knob-files", user_uuid: user_uuid})
      file_uuid = insert_file!(user_uuid, folder.uuid)

      pointers = %{
        "files_folder_uuid" => folder.uuid,
        "featured_image_uuid" => file_uuid,
        "media_order" => [file_uuid]
      }

      Repo.update_all(from(i in Item, where: i.uuid == ^item.uuid), set: [data: pointers])
      Repo.update_all(from(c in Category, where: c.uuid == ^shelf.uuid), set: [data: pointers])

      Repo.update_all(from(c in CatalogueSchema, where: c.uuid == ^source.uuid),
        set: [data: Map.drop(pointers, ["files_folder_uuid"])]
      )

      %{source: source, item: item, file_uuid: file_uuid, user_uuid: user_uuid}
    end

    defp only_item(catalogue_uuid), do: hd(items_of(catalogue_uuid))

    test "by default everything comes along, files as links", %{
      source: source,
      file_uuid: file_uuid,
      user_uuid: user_uuid
    } do
      {:ok, %{catalogue: copy}} = Catalogue.duplicate_catalogue(source, actor_uuid: user_uuid)
      copied = only_item(copy.uuid)

      assert copied.sku == "KN-1"
      assert copied.data["featured_image_uuid"] == file_uuid
      assert [_] = Catalogue.list_supplier_infos_for_item(copied.uuid)

      assert [%FolderLink{file_uuid: ^file_uuid}] =
               Repo.all(
                 from(l in FolderLink, where: l.folder_uuid == ^copied.data["files_folder_uuid"])
               )

      assert copy.status == "active"
    end

    test "each one can be switched off, and the copy can start archived", %{
      source: source,
      item: item,
      file_uuid: file_uuid
    } do
      {:ok, %{catalogue: copy}} =
        Catalogue.duplicate_catalogue(source,
          skus: false,
          files: false,
          suppliers: false,
          archived: true
        )

      copied = only_item(copy.uuid)
      [copied_shelf] = categories_of(copy.uuid)

      assert copy.status == "archived"
      assert copied.sku == nil
      assert Catalogue.list_supplier_infos_for_item(copied.uuid) == []

      for data <- [copied.data, copied_shelf.data, copy.data] do
        refute Map.has_key?(data, "files_folder_uuid")
        refute Map.has_key?(data, "featured_image_uuid")
        refute Map.has_key?(data, "media_order")
      end

      # The original keeps all of it.
      original = Catalogue.get_item(item.uuid)
      assert original.sku == "KN-1"
      assert original.data["featured_image_uuid"] == file_uuid
      assert [_] = Catalogue.list_supplier_infos_for_item(item.uuid)
      assert Catalogue.get_catalogue(source.uuid).status == "active"
    end

    test "the activity row says what was left out", %{source: source} do
      {:ok, %{catalogue: copy}} =
        Catalogue.duplicate_catalogue(source, skus: false, suppliers: false)

      assert_activity_logged("catalogue.duplicated",
        resource_uuid: copy.uuid,
        metadata_has: %{"without" => ["skus", "suppliers"], "archived" => false}
      )
    end
  end

  defp insert_user! do
    user_uuid = UUIDv7.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO phoenix_kit_users
        (uuid, email, hashed_password, account_type, is_active, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'person', true, NOW(), NOW())
      """,
      [
        Ecto.UUID.dump!(user_uuid),
        "copy-choices-#{System.unique_integer([:positive])}@example.com",
        "$2b$12$0000000000000000000000000000000000000000000000000000."
      ]
    )

    user_uuid
  end

  defp insert_file!(user_uuid, folder_uuid) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    uuid = UUIDv7.generate()

    Repo.insert!(%StorageFile{
      uuid: uuid,
      original_file_name: "knob.jpg",
      file_name: "knob.jpg",
      mime_type: "image/jpeg",
      file_type: "image",
      ext: "jpg",
      file_checksum: "chk-#{uuid}",
      user_file_checksum: "uchk-#{uuid}",
      size: 1,
      status: "active",
      system_managed: false,
      user_uuid: user_uuid,
      folder_uuid: folder_uuid,
      inserted_at: now,
      updated_at: now
    })

    uuid
  end

  describe "extension data" do
    setup do
      start_supervised!(PhoenixKit.ModuleRegistry)
      :ok = PhoenixKit.ModuleRegistry.register(CopyAwareModule)

      on_exit(fn ->
        :persistent_term.put(
          {PhoenixKit, :registered_modules},
          List.delete(PhoenixKit.ModuleRegistry.all_modules(), CopyAwareModule)
        )
      end)

      :ok
    end

    # ThrowingKeyExtension's `key/0` exits on every call: the copy skips it
    # rather than rolling back.
    test "each namespace goes through its extension, disabled or not; a raise drops it" do
      source = fixture_catalogue(%{name: "Shop catalogue"})
      category = fixture_category(source, %{name: "Shelf"})

      data = %{
        "copyaware" => %{"external_id" => "gid://shop/1", "status" => "active"},
        "raisingcopy" => %{"anything" => 1},
        "nilcopy" => %{"anything" => 2},
        "badcopy" => %{"anything" => 3},
        "pos" => %{"name" => "Till"},
        "untouched" => %{"external_id" => "stays"}
      }

      item = fixture_item(%{name: "Product", category_uuid: category.uuid})
      Repo.update_all(from(i in Item, where: i.uuid == ^item.uuid), set: [data: data])
      Repo.update_all(from(c in Category, where: c.uuid == ^category.uuid), set: [data: data])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{catalogue: copy}} = Catalogue.duplicate_catalogue(source)
          send(self(), {:copy, copy})
        end)

      assert_received {:copy, copy}
      assert log =~ "duplicate_data/2 failed (error RuntimeError)"
      assert log =~ "BadCopyExtension.duplicate_data/2 returned neither a map nor nil"
      refute log =~ "secret-external-id"

      [copied_item] = items_of(copy.uuid)
      [copied_category] = categories_of(copy.uuid)

      for copied <- [copied_item, copied_category] do
        assert copied.data["copyaware"] == %{"status" => "active"}
        refute Map.has_key?(copied.data, "raisingcopy")
        refute Map.has_key?(copied.data, "nilcopy")
        refute Map.has_key?(copied.data, "badcopy")
        # An extension key shaped like a language is not renamed.
        assert copied.data["pos"] == %{"name" => "Till"}
        assert copied.data["untouched"] == %{"external_id" => "stays"}
      end

      # The single-item and single-category Duplicate go through the same hook.
      {:ok, item_copy} = Catalogue.duplicate_item(Catalogue.get_item(item.uuid))
      assert item_copy.data["copyaware"] == %{"status" => "active"}

      {:ok, %{category: category_copy}} =
        Catalogue.duplicate_category(Catalogue.get_category(category.uuid))

      assert category_copy.data["copyaware"] == %{"status" => "active"}
      assert category_copy.data["pos"] == %{"name" => "Till"}

      # The original is untouched.
      assert Catalogue.get_item(item.uuid).data == data
    end
  end
end
