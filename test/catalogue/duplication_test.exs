defmodule PhoenixKitCatalogue.Catalogue.DuplicationTest do
  @moduledoc """
  The Duplicate action: an item copy carries everything the item form
  edits (data, attribute sets, current supplier rows with a FRESH comment
  thread, catalogue rules, a linked files folder) and lands right after
  its source; a category copy brings its whole subtree with names and
  positions intact. Comments and history stay with the original.
  """
  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase,
    only: [fixture_catalogue: 1, fixture_category: 2, fixture_item: 1, fixture_supplier: 1]

  alias Ecto.Adapters.SQL
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.FolderLink
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.ItemSupplierInfos
  alias PhoenixKitCatalogue.Catalogue.PubSub, as: CataloguePubSub
  alias PhoenixKitCatalogue.Schemas.{CatalogueRule, Item, ItemSupplierInfo}
  alias PhoenixKitCatalogue.Test.Repo

  setup do
    cat = fixture_catalogue(%{name: "Dup"})
    alpha = fixture_category(cat, %{name: "Alpha", position: 0})
    beta = fixture_category(cat, %{name: "Beta", position: 1})

    a =
      fixture_item(%{catalogue_uuid: cat.uuid, category_uuid: alpha.uuid, name: "A", position: 0})

    b =
      fixture_item(%{catalogue_uuid: cat.uuid, category_uuid: alpha.uuid, name: "B", position: 1})

    c =
      fixture_item(%{catalogue_uuid: cat.uuid, category_uuid: alpha.uuid, name: "C", position: 2})

    %{catalogue: cat, alpha: alpha, beta: beta, a: a, b: b, c: c}
  end

  defp names_in(category_uuid) do
    Catalogue.list_items_for_category(category_uuid) |> Enum.map(&{&1.name, &1.position})
  end

  describe "duplicate_item/2" do
    test "copies the row, suffixes the name and slots the copy right after the source",
         %{alpha: alpha, a: a} do
      {:ok, _} =
        Catalogue.update_item(a, %{
          sku: "A-1",
          description: "desc",
          base_price: Decimal.new("12.50"),
          unit: "m2",
          data: %{
            "_primary_language" => "en",
            "en" => %{"name" => "A"},
            "et" => %{"_name" => "A-et"},
            "custom_fields" => %{"colour" => "red"},
            "featured_image_uuid" => "0192aaaa-0000-7000-8000-000000000001",
            "files_folder_uuid" => "0192aaaa-0000-7000-8000-000000000002"
          }
        })

      a = Catalogue.get_item!(a.uuid)
      {:ok, copy} = Catalogue.duplicate_item(a)

      assert copy.uuid != a.uuid
      assert copy.name == "A (copy)"
      assert copy.sku == "A-1"
      assert copy.description == "desc"
      assert Decimal.equal?(copy.base_price, Decimal.new("12.50"))
      assert copy.unit == "m2"
      assert copy.category_uuid == alpha.uuid
      assert copy.catalogue_uuid == a.catalogue_uuid
      # Translations, custom fields and the featured pointer travel; the
      # folder pointer belongs to one item only. Lists render the
      # translated name, so every language entry carries the suffix.
      # …each in its own language, not the acting admin's.
      assert copy.data["en"] == %{"name" => "A (copy)"}
      assert copy.data["et"] == %{"_name" => "A-et (koopia)"}
      assert copy.data["custom_fields"] == %{"colour" => "red"}
      assert copy.data["featured_image_uuid"] == "0192aaaa-0000-7000-8000-000000000001"
      refute Map.has_key?(copy.data, "files_folder_uuid")

      assert names_in(alpha.uuid) == [{"A", 1}, {"A (copy)", 2}, {"B", 3}, {"C", 4}]
    end

    test "a copy sent to another category is appended there", %{beta: beta, alpha: alpha, b: b} do
      {:ok, copy} = Catalogue.duplicate_item(b, category_uuid: beta.uuid)

      assert copy.category_uuid == beta.uuid
      assert names_in(beta.uuid) == [{"B (copy)", 1}]
      assert names_in(alpha.uuid) == [{"A", 0}, {"B", 1}, {"C", 2}]
    end

    test "supplier rows are copied with a fresh comment thread", %{a: a} do
      supplier = fixture_supplier(%{name: "Bolt AS"})

      {:ok, row} =
        Catalogue.create_supplier_info(%{
          item_uuid: a.uuid,
          supplier_uuid: supplier.uuid,
          unit_cost: Decimal.new("4.20"),
          currency: "EUR",
          is_primary: true
        })

      # A closed revision must stay with the original.
      {:ok, _} = ItemSupplierInfos.revise_unit_cost(row, Decimal.new("4.50"), [])

      {:ok, copy} = Catalogue.duplicate_item(a)
      [copied] = Catalogue.list_supplier_infos_for_item(copy.uuid)

      assert copied.supplier_uuid == supplier.uuid
      assert Decimal.equal?(copied.unit_cost, Decimal.new("4.50"))
      assert copied.is_primary
      assert is_nil(copied.valid_to)

      source_threads =
        Repo.all(from(i in ItemSupplierInfo, where: i.item_uuid == ^a.uuid))
        |> Enum.map(&Catalogue.supplier_comment_thread_uuid/1)

      refute Catalogue.supplier_comment_thread_uuid(copied) in source_threads

      assert Repo.aggregate(from(i in ItemSupplierInfo, where: i.item_uuid == ^copy.uuid), :count) ==
               1
    end

    test "catalogue rules are copied", %{a: a} do
      other = fixture_catalogue(%{name: "Referenced"})

      {:ok, _} =
        Catalogue.put_catalogue_rules(a, [
          %{referenced_catalogue_uuid: other.uuid, value: Decimal.new("15"), unit: "percent"}
        ])

      {:ok, copy} = Catalogue.duplicate_item(a)

      assert [%CatalogueRule{referenced_catalogue_uuid: ref, unit: "percent"}] =
               Repo.all(from(r in CatalogueRule, where: r.item_uuid == ^copy.uuid))

      assert ref == other.uuid
    end

    test "files are linked into the copy's own folder, never moved", %{a: a} do
      user_uuid = insert_user!()

      {:ok, folder} =
        Storage.create_folder(%{name: "catalogue-item-#{a.uuid}", user_uuid: user_uuid})

      file_uuid = insert_file!(user_uuid, folder.uuid, "photo.jpg")
      _trashed = insert_file!(user_uuid, folder.uuid, "old.jpg", status: "trashed")

      {:ok, _} = Catalogue.update_item(a, %{data: %{"files_folder_uuid" => folder.uuid}})
      a = Catalogue.get_item!(a.uuid)

      {:ok, copy} = Catalogue.duplicate_item(a, actor_uuid: user_uuid)

      new_folder = copy.data["files_folder_uuid"]
      assert is_binary(new_folder) and new_folder != folder.uuid
      assert Storage.get_folder(new_folder).name == "catalogue-item-#{copy.uuid}"

      assert [%FolderLink{file_uuid: ^file_uuid}] =
               Repo.all(from(l in FolderLink, where: l.folder_uuid == ^new_folder))

      assert Repo.get!(StorageFile, file_uuid).folder_uuid == folder.uuid
    end

    test "a 255-character name is trimmed so the suffix still fits", %{a: a} do
      {:ok, _} = Catalogue.update_item(a, %{name: String.duplicate("x", 255)})
      {:ok, copy} = Catalogue.duplicate_item(Catalogue.get_item!(a.uuid))

      assert String.length(copy.name) == 255
      assert String.ends_with?(copy.name, " (copy)")
    end

    test "an item without files gets no folder", %{a: a} do
      {:ok, copy} = Catalogue.duplicate_item(a)
      refute Map.has_key?(copy.data || %{}, "files_folder_uuid")
    end
  end

  describe "duplicate_category/2" do
    test "copies the subtree with names and positions intact, only the top renamed",
         %{catalogue: cat, alpha: alpha, beta: beta, a: a} do
      {:ok, _} =
        Catalogue.update_item(a, %{data: %{"_primary_language" => "en", "en" => %{"name" => "A"}}})

      a_uuid = a.uuid
      child = fixture_category(cat, %{name: "Alpha child", parent_uuid: alpha.uuid, position: 0})

      _ =
        fixture_item(%{
          catalogue_uuid: cat.uuid,
          category_uuid: child.uuid,
          name: "Deep",
          position: 0
        })

      trashed = fixture_item(%{catalogue_uuid: cat.uuid, category_uuid: alpha.uuid, name: "Gone"})
      {:ok, _} = Catalogue.trash_item(trashed)

      {:ok, %{category: copy, categories: 1, items: 4}} = Catalogue.duplicate_category(alpha)

      assert copy.name == "Alpha (copy)"
      assert copy.parent_uuid == nil
      assert copy.catalogue_uuid == cat.uuid

      roots = Catalogue.list_child_categories(cat.uuid, nil) |> Enum.map(& &1.name)
      assert roots == ["Alpha", "Alpha (copy)", "Beta"]
      assert Catalogue.get_category(beta.uuid).position == 3

      assert names_in(copy.uuid) == [{"A", 0}, {"B", 1}, {"C", 2}]
      # Nested copies keep their translations verbatim (no suffix).
      assert Catalogue.get_item!(hd(Catalogue.list_items_for_category(copy.uuid)).uuid).data ==
               Catalogue.get_item!(a_uuid).data

      [copied_child] = Catalogue.list_child_categories(cat.uuid, copy.uuid)
      assert copied_child.name == "Alpha child"
      assert names_in(copied_child.uuid) == [{"Deep", 0}]

      # Originals untouched.
      assert names_in(alpha.uuid) == [{"A", 0}, {"B", 1}, {"C", 2}]
      assert Catalogue.get_category(child.uuid).parent_uuid == alpha.uuid
    end
  end

  describe "duplicate_category/2 guards" do
    test "a parent from another catalogue is refused", %{alpha: alpha} do
      other = fixture_catalogue(%{name: "Elsewhere"})
      foreign = fixture_category(other, %{name: "Foreign"})

      assert {:error, :cross_catalogue} =
               Catalogue.duplicate_category(alpha, parent_uuid: foreign.uuid)

      assert {:error, :parent_not_found} =
               Catalogue.duplicate_category(alpha, parent_uuid: UUIDv7.generate())
    end
  end

  describe "bulk" do
    test "copies in position order, reports unknown uuids and broadcasts once",
         %{catalogue: cat, alpha: alpha, a: a, c: c} do
      CataloguePubSub.subscribe()
      ghost = UUIDv7.generate()

      assert {:ok, %{created: 2, errors: [{^ghost, :not_found}, {"forged", :invalid_uuid}]}} =
               Catalogue.bulk_duplicate_items([c.uuid, ghost, a.uuid, "forged"])

      assert names_in(alpha.uuid) ==
               [{"A", 1}, {"A (copy)", 2}, {"B", 3}, {"C", 4}, {"C (copy)", 5}]

      cat_uuid = cat.uuid
      assert_receive {:catalogue_data_changed, :item, nil, ^cat_uuid}
      refute_receive {:catalogue_data_changed, :item, _, _}, 100
    end

    test "a catalogue scope refuses rows from elsewhere", %{catalogue: cat, alpha: alpha, a: a} do
      other = fixture_catalogue(%{name: "Elsewhere"})
      foreign_cat = fixture_category(other, %{name: "Foreign"})
      foreign_item = fixture_item(%{catalogue_uuid: other.uuid, name: "Foreign item"})

      assert {:ok, %{created: 1, errors: [{fi, :wrong_catalogue_scope}]}} =
               Catalogue.bulk_duplicate_items([foreign_item.uuid, a.uuid],
                 catalogue_uuid: cat.uuid
               )

      assert fi == foreign_item.uuid
      assert Catalogue.list_items_for_catalogue(other.uuid) |> length() == 1

      assert {:ok, %{created: 1, errors: [{fc, :wrong_catalogue_scope}]}} =
               Catalogue.bulk_duplicate_categories([foreign_cat.uuid, alpha.uuid],
                 catalogue_uuid: cat.uuid
               )

      assert fc == foreign_cat.uuid
      assert Catalogue.list_child_categories(other.uuid, nil) |> length() == 1
    end

    test "the item bulk ops honour the same scope", %{catalogue: cat, a: a} do
      other = fixture_catalogue(%{name: "Elsewhere"})
      foreign = fixture_item(%{catalogue_uuid: other.uuid, name: "Foreign item"})

      assert {1, _} = Catalogue.bulk_trash_items([foreign.uuid, a.uuid], catalogue_uuid: cat.uuid)
      assert Catalogue.get_item!(a.uuid).status == "deleted"
      assert Catalogue.get_item!(foreign.uuid).status == "active"

      assert {1, _} =
               Catalogue.bulk_restore_items([foreign.uuid, a.uuid], catalogue_uuid: cat.uuid)

      assert Catalogue.get_item!(a.uuid).status == "active"
    end

    test "categories: one batch pair per catalogue", %{catalogue: cat, alpha: alpha, beta: beta} do
      CataloguePubSub.subscribe()

      assert {:ok, %{created: 2, errors: []}} =
               Catalogue.bulk_duplicate_categories([beta.uuid, alpha.uuid])

      roots = Catalogue.list_child_categories(cat.uuid, nil) |> Enum.map(& &1.name)
      assert roots == ["Alpha", "Alpha (copy)", "Beta", "Beta (copy)"]

      cat_uuid = cat.uuid
      assert_receive {:catalogue_data_changed, :category, nil, ^cat_uuid}
      assert_receive {:catalogue_data_changed, :item, nil, ^cat_uuid}
      refute_receive {:catalogue_data_changed, _, _, _}, 100
      assert Repo.aggregate(Item, :count) == 6
    end
  end

  # Files carry a CHECK (user_uuid OR parent_file_uuid); give them an owner.
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
        "dup-#{System.unique_integer([:positive])}@example.com",
        "$2b$12$0000000000000000000000000000000000000000000000000000."
      ]
    )

    user_uuid
  end

  defp insert_file!(user_uuid, folder_uuid, name, opts \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    uuid = UUIDv7.generate()

    Repo.insert!(%StorageFile{
      uuid: uuid,
      original_file_name: name,
      file_name: name,
      mime_type: "image/jpeg",
      file_type: "image",
      ext: "jpg",
      file_checksum: "chk-#{uuid}",
      user_file_checksum: "uchk-#{uuid}",
      size: 1,
      status: Keyword.get(opts, :status, "active"),
      system_managed: false,
      user_uuid: user_uuid,
      folder_uuid: folder_uuid,
      inserted_at: now,
      updated_at: now
    })

    uuid
  end
end
