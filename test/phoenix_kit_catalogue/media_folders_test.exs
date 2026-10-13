defmodule PhoenixKitCatalogue.MediaFoldersTest do
  @moduledoc """
  The default folder layout — `Catalogues/<catalogue>/<category…>/<item>`
  — installed by `mix.exs`, its step-back when a host configures hooks,
  the reorganizer's plan for the flat folders that predate it, and
  folders following their records' renames and moves.
  """

  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase,
    only: [fixture_catalogue: 1, fixture_category: 2, fixture_item: 1]

  alias Ecto.Adapters.SQL
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitCatalogue.Attachments
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.MediaFolders
  alias PhoenixKitCatalogue.MediaReorganizer
  alias PhoenixKitCatalogue.Schemas.Item
  alias PhoenixKitCatalogue.Test.MediaHooks
  alias PhoenixKitCatalogue.Test.Repo

  @app :phoenix_kit_catalogue

  defmodule HostHook do
    def parent(:item, _actor, %Item{}), do: {:ok, Process.get(:host_container)}
    def parent(_kind, _actor, _subject), do: nil
    def name(%Item{name: name}, _actor), do: {:ok, "host #{name}"}
    def name(_subject, _actor), do: nil
  end

  setup do
    MediaHooks.restore_on_exit()
    %{user_uuid: insert_user!()}
  end

  describe "defaults" do
    test "mix.exs installs the layout as both attachment hooks" do
      assert Application.get_env(@app, :attachments_parent_folder) ==
               {MediaFolders, :default_parent_for}

      assert Application.get_env(@app, :attachments_folder_name) ==
               {MediaFolders, :default_folder_name}
    end

    test "an item's photos land in Catalogues/<catalogue>/<category>/<subcategory>/<item>",
         %{user_uuid: user_uuid} do
      catalogue = fixture_catalogue(%{name: "Hardware"})
      tools = fixture_category(catalogue, %{name: "Tools"})
      hand = fixture_category(catalogue, %{name: "Hand tools", parent_uuid: tools.uuid})

      item =
        fixture_item(%{catalogue_uuid: catalogue.uuid, category_uuid: hand.uuid, name: "Hammer"})

      {:ok, updated} = Attachments.attach_files(item, [insert_file!(user_uuid)])

      folder_uuid = updated.data["files_folder_uuid"]
      assert path(folder_uuid) == ["Catalogues", "Hardware", "Tools", "Hand tools", "Hammer"]
      assert Repo.get!(StorageFile, hd(updated.data["media_order"])).folder_uuid == folder_uuid

      # The containers are their records' own folders.
      assert pointer(Catalogue.get_category(hand.uuid)) ==
               Storage.get_folder(folder_uuid).parent_uuid

      assert path(pointer(Catalogue.get_category(tools.uuid))) == [
               "Catalogues",
               "Hardware",
               "Tools"
             ]

      assert path(pointer(Catalogue.get_catalogue(catalogue.uuid))) == ["Catalogues", "Hardware"]
    end

    test "an item without a category sits in its catalogue's folder", %{user_uuid: user_uuid} do
      catalogue = fixture_catalogue(%{name: "Loose"})
      item = fixture_item(%{catalogue_uuid: catalogue.uuid, name: "Washer"})

      {:ok, updated} = Attachments.attach_files(item, [insert_file!(user_uuid)])

      assert path(updated.data["files_folder_uuid"]) == ["Catalogues", "Loose", "Washer"]
    end

    test "the second catalogue reuses the one Catalogues folder", %{user_uuid: user_uuid} do
      a = fixture_item(%{catalogue_uuid: fixture_catalogue(%{name: "A"}).uuid, name: "One"})
      b = fixture_item(%{catalogue_uuid: fixture_catalogue(%{name: "B"}).uuid, name: "Two"})

      {:ok, a} = Attachments.attach_files(a, [insert_file!(user_uuid)])
      {:ok, b} = Attachments.attach_files(b, [insert_file!(user_uuid)])

      [root_a | _] = ancestry(a.data["files_folder_uuid"])
      [root_b | _] = ancestry(b.data["files_folder_uuid"])
      assert root_a.uuid == root_b.uuid
      assert root_a.name == "Catalogues"
    end

    test "folders are named in the site's primary language" do
      primary = Multilang.primary_language()

      catalogue =
        fixture_catalogue(%{
          name: "Köök",
          data: %{"_primary_language" => "et-EE", primary => %{"_name" => "Kitchen"}}
        })

      assert MediaFolders.folder_name(catalogue, nil) == {:ok, "Kitchen"}
    end

    test "the name does not follow the language of the request being served" do
      {:ok, _} = Languages.enable_system()
      {:ok, _} = Languages.add_language("fr-FR")
      Languages.put_request_default_language("fr-FR")
      on_exit(fn -> Languages.put_request_default_language(nil) end)

      # The request override really does move the language everything else uses.
      assert Multilang.primary_language() == "fr-FR"

      catalogue =
        fixture_catalogue(%{
          name: "Kitchen",
          data: %{"_primary_language" => "en-US", "fr-FR" => %{"_name" => "Cuisine"}}
        })

      assert MediaFolders.folder_name(catalogue, nil) == {:ok, "Kitchen"}
    end

    test "a SKU with spaces round the edges is trimmed in the name and when following it",
         %{user_uuid: user_uuid} do
      catalogue = fixture_catalogue(%{name: "Padded"})
      a = fixture_item(%{catalogue_uuid: catalogue.uuid, name: "Bolt", sku: " B-1 "})
      b = fixture_item(%{catalogue_uuid: catalogue.uuid, name: "Bolt", sku: "B-2"})

      assert MediaFolders.folder_name(a, nil) == {:ok, "Bolt (B-1)"}

      {:ok, a} = Attachments.attach_files(a, [insert_file!(user_uuid)])
      assert List.last(path(pointer(a))) == "Bolt (B-1)"

      # The folder is still where and as the hook put it, so it follows.
      {:ok, a} = Catalogue.update_item(a, %{name: "Screw", sku: " B-1 "})
      assert List.last(path(pointer(a))) == "Screw"
      assert b.uuid != a.uuid
    end

    test "a catalogue named PDF does not take over Catalogues/PDF", %{user_uuid: user_uuid} do
      assert {:ok, pdf_folder} = Attachments.parent_folder_uuid(:pdf, nil) |> wrap()

      catalogue = fixture_catalogue(%{name: "pdf"})
      assert MediaFolders.folder_name(catalogue, nil) == nil

      item = fixture_item(%{catalogue_uuid: catalogue.uuid, name: "Manual"})
      {:ok, item} = Attachments.attach_files(item, [insert_file!(user_uuid)])

      assert path(pointer(item)) == [
               "Catalogues",
               "catalogue-#{catalogue.uuid}",
               "Manual"
             ]

      assert pointer(Catalogue.get_catalogue(catalogue.uuid)) != pdf_folder
    end

    test "namesakes in one place are told apart by SKU; without one, the deterministic name" do
      catalogue = fixture_catalogue(%{name: "ERP"})
      a = fixture_item(%{catalogue_uuid: catalogue.uuid, name: "Bolt", sku: "B-1"})
      b = fixture_item(%{catalogue_uuid: catalogue.uuid, name: "Bolt", sku: "B-2"})
      c = fixture_item(%{catalogue_uuid: catalogue.uuid, name: "Bolt"})
      lone = fixture_item(%{catalogue_uuid: catalogue.uuid, name: "Nut", sku: "N-1"})

      assert MediaFolders.folder_name(a, nil) == {:ok, "Bolt (B-1)"}
      assert MediaFolders.folder_name(b, nil) == {:ok, "Bolt (B-2)"}
      assert MediaFolders.folder_name(c, nil) == nil
      assert Attachments.folder_name(c, nil) == "catalogue-item-#{c.uuid}"
      assert MediaFolders.folder_name(lone, nil) == {:ok, "Nut"}
    end

    test "a trashed namesake does not count" do
      catalogue = fixture_catalogue(%{name: "Bin"})
      a = fixture_item(%{catalogue_uuid: catalogue.uuid, name: "Bolt", sku: "B-1"})
      b = fixture_item(%{catalogue_uuid: catalogue.uuid, name: "Bolt", sku: "B-2"})
      {:ok, _} = Catalogue.trash_item(b)

      assert MediaFolders.folder_name(a, nil) == {:ok, "Bolt"}
    end

    test "namesakes are compared in the site's language even with different base names" do
      catalogue = fixture_catalogue(%{name: "Translated"})
      primary = Multilang.primary_language()
      a = fixture_item(%{catalogue_uuid: catalogue.uuid, name: "Bolt", sku: "B-1"})

      b =
        fixture_item(%{
          catalogue_uuid: catalogue.uuid,
          name: "Polt",
          sku: "B-2",
          data: %{"_primary_language" => "et-EE", primary => %{"_name" => "Bolt"}}
        })

      assert MediaFolders.folder_name(a, nil) == {:ok, "Bolt (B-1)"}
      assert MediaFolders.folder_name(b, nil) == {:ok, "Bolt (B-2)"}
    end

    test "a namesake whose name plus SKU exceeds the folder limit uses its deterministic name",
         %{user_uuid: user_uuid} do
      catalogue = fixture_catalogue(%{name: "Long names"})
      name = String.duplicate("x", 255)
      a = fixture_item(%{catalogue_uuid: catalogue.uuid, name: name, sku: "B-1"})
      fixture_item(%{catalogue_uuid: catalogue.uuid, name: name, sku: "B-2"})

      assert MediaFolders.folder_name(a, nil) == nil
      assert {:ok, attached} = Attachments.attach_files(a, [insert_file!(user_uuid)])
      assert Storage.get_folder(pointer(attached)).name == "catalogue-item-#{a.uuid}"
    end

    test "PDFs go to Catalogues/PDF" do
      assert {:ok, folder_uuid} = Attachments.parent_folder_uuid(:pdf, nil) |> wrap()
      assert path(folder_uuid) == ["Catalogues", "PDF"]
      assert Attachments.parent_folder_uuid(:pdf, nil) == folder_uuid
    end

    test "a new item's pending upload folder moves into its category on save",
         %{user_uuid: user_uuid} do
      catalogue = fixture_catalogue(%{name: "Pending"})
      category = fixture_category(catalogue, %{name: "Shelf"})

      {:ok, pending} =
        Storage.create_folder(%{name: "catalogue-attachment-pending-#{Ecto.UUID.generate()}"})

      item =
        fixture_item(%{catalogue_uuid: catalogue.uuid, category_uuid: category.uuid, name: "Box"})

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          phoenix_kit_current_user: nil,
          files_folder_uuid: pending.uuid
        }
      }

      assert :ok = Attachments.maybe_rename_pending_folder(socket, item)
      assert path(pending.uuid) == ["Catalogues", "Pending", "Shelf", "Box"]
      _ = user_uuid
    end
  end

  describe "a host's own hooks" do
    test "a host parent hook alone: the default name steps back", %{user_uuid: user_uuid} do
      {:ok, container} = Storage.create_folder(%{name: "Host items"})
      Process.put(:host_container, container.uuid)
      Application.put_env(@app, :attachments_parent_folder, {HostHook, :parent})

      item = fixture_item(%{catalogue_uuid: fixture_catalogue(%{}).uuid, name: "Clamp"})
      {:ok, updated} = Attachments.attach_files(item, [insert_file!(user_uuid)])

      folder = Storage.get_folder(updated.data["files_folder_uuid"])
      assert folder.name == "catalogue-item-#{item.uuid}"
      assert folder.parent_uuid == container.uuid
    end

    test "a host name hook alone: the default parent steps back to the root",
         %{user_uuid: user_uuid} do
      Application.put_env(@app, :attachments_folder_name, {HostHook, :name})

      item = fixture_item(%{catalogue_uuid: fixture_catalogue(%{}).uuid, name: "Clamp"})
      {:ok, updated} = Attachments.attach_files(item, [insert_file!(user_uuid)])

      folder = Storage.get_folder(updated.data["files_folder_uuid"])
      assert folder.name == "host Clamp"
      assert folder.parent_uuid == nil
    end

    test "both keys nil: the deterministic name at the root, as before", %{user_uuid: user_uuid} do
      MediaHooks.without_hooks()

      item = fixture_item(%{catalogue_uuid: fixture_catalogue(%{}).uuid, name: "Clamp"})
      {:ok, updated} = Attachments.attach_files(item, [insert_file!(user_uuid)])

      folder = Storage.get_folder(updated.data["files_folder_uuid"])
      assert folder.name == "catalogue-item-#{item.uuid}"
      assert folder.parent_uuid == nil
    end

    test "an explicit ready-made name hook works beside a host parent hook" do
      {:ok, container} = Storage.create_folder(%{name: "Host items"})
      Process.put(:host_container, container.uuid)
      Application.put_env(@app, :attachments_parent_folder, {HostHook, :parent})
      Application.put_env(@app, :attachments_folder_name, {MediaFolders, :folder_name})

      item = fixture_item(%{catalogue_uuid: fixture_catalogue(%{}).uuid, name: "Clamp"})
      assert Attachments.folder_name(item, nil) == "Clamp"
    end
  end

  describe "an explicit name hook at the media root" do
    test "follows renames and releases deleted records' names", %{user_uuid: user_uuid} do
      Application.put_env(@app, :attachments_parent_folder, {HostHook, :parent})
      Application.put_env(@app, :attachments_folder_name, {MediaFolders, :folder_name})
      catalogue = fixture_catalogue(%{name: "Root naming"})
      item = fixture_item(%{catalogue_uuid: catalogue.uuid, name: "Before"})
      {:ok, item} = Attachments.attach_files(item, [insert_file!(user_uuid)])
      folder_uuid = pointer(item)

      assert %{parent_uuid: nil, name: "Before"} = Storage.get_folder(folder_uuid)
      assert {:ok, item} = Catalogue.update_item(item, %{name: "After"})
      assert %{parent_uuid: nil, name: "After"} = Storage.get_folder(folder_uuid)
      assert {:ok, _} = Catalogue.delete_item(item)
      assert Storage.get_folder(folder_uuid).name == "catalogue-item-#{item.uuid}"
    end
  end

  describe "media reorganizer" do
    test "plans the flat catalogue-item-<uuid> folders into the layout" do
      catalogue = fixture_catalogue(%{name: "Flat"})
      category = fixture_category(catalogue, %{name: "Chairs"})

      item =
        fixture_item(%{
          catalogue_uuid: catalogue.uuid,
          category_uuid: category.uuid,
          name: "Stool"
        })

      loose = fixture_item(%{catalogue_uuid: catalogue.uuid, name: "Cushion"})

      flat = flat_folder!(item)
      flat_loose = flat_folder!(loose)

      actions = MediaReorganizer.plan(nil, [])

      move = Enum.find(actions, &(&1.kind == :item and &1.folder.uuid == flat.uuid))
      assert move.op == :move
      assert move.name == "Stool"
      assert path(move.parent_uuid) == ["Catalogues", "Flat", "Chairs"]

      move_loose = Enum.find(actions, &(&1.kind == :item and &1.folder.uuid == flat_loose.uuid))
      assert move_loose.name == "Cushion"
      assert path(move_loose.parent_uuid) == ["Catalogues", "Flat"]
    end

    test "with both keys nil it plans nothing for them, as before" do
      MediaHooks.without_hooks()
      item = fixture_item(%{catalogue_uuid: fixture_catalogue(%{}).uuid, name: "Stool"})
      flat = flat_folder!(item)

      refute Enum.any?(
               MediaReorganizer.plan(nil, []),
               &(&1[:folder] && &1.folder.uuid == flat.uuid)
             )
    end
  end

  describe "folders follow their records" do
    setup %{user_uuid: user_uuid} do
      catalogue = fixture_catalogue(%{name: "Shop"})
      chairs = fixture_category(catalogue, %{name: "Chairs"})
      tables = fixture_category(catalogue, %{name: "Tables"})

      item =
        fixture_item(%{catalogue_uuid: catalogue.uuid, category_uuid: chairs.uuid, name: "Stool"})

      {:ok, item} = Attachments.attach_files(item, [insert_file!(user_uuid)])

      %{catalogue: catalogue, chairs: chairs, tables: tables, item: item}
    end

    test "a renamed item's folder is renamed", %{item: item} do
      {:ok, renamed} = Catalogue.update_item(item, %{name: "Bar stool"})
      assert path(pointer(renamed)) == ["Catalogues", "Shop", "Chairs", "Bar stool"]
    end

    test "an item moved to another category takes its folder along", %{item: item, tables: tables} do
      {:ok, moved} = Catalogue.move_item_to_category(item, tables.uuid)
      assert path(pointer(moved)) == ["Catalogues", "Shop", "Tables", "Stool"]
    end

    test "an item moved out of its category goes to the catalogue's folder", %{item: item} do
      {:ok, moved} = Catalogue.move_item_to_category(item, nil)
      assert path(pointer(moved)) == ["Catalogues", "Shop", "Stool"]
    end

    test "an item moved to another catalogue", %{item: item} do
      other = fixture_catalogue(%{name: "Outlet"})
      {:ok, moved} = Catalogue.move_item_to_catalogue(item, other.uuid)
      assert path(pointer(moved)) == ["Catalogues", "Outlet", "Stool"]
    end

    test "a bulk move takes every folder along", %{catalogue: catalogue, tables: tables} = ctx do
      second =
        fixture_item(%{
          catalogue_uuid: catalogue.uuid,
          category_uuid: ctx.chairs.uuid,
          name: "Bench"
        })

      {:ok, second} = Attachments.attach_files(second, [insert_file!(ctx.user_uuid)])

      {:ok, 2} =
        Catalogue.bulk_move_items([ctx.item.uuid, second.uuid], {:category, tables.uuid},
          catalogue_uuid: catalogue.uuid
        )

      assert path(pointer(Catalogue.get_item(ctx.item.uuid))) == [
               "Catalogues",
               "Shop",
               "Tables",
               "Stool"
             ]

      assert path(pointer(Catalogue.get_item(second.uuid))) == [
               "Catalogues",
               "Shop",
               "Tables",
               "Bench"
             ]
    end

    test "a category moved under another moves its folder once, subtree included",
         %{catalogue: catalogue, chairs: chairs, tables: tables, item: item} do
      office = fixture_category(catalogue, %{name: "Office", parent_uuid: chairs.uuid})

      deep =
        fixture_item(%{
          catalogue_uuid: catalogue.uuid,
          category_uuid: office.uuid,
          name: "Swivel"
        })

      {:ok, deep} = Attachments.attach_files(deep, [insert_file!(insert_user!())])
      chairs_folder = pointer(Catalogue.get_category(chairs.uuid))

      {:ok, _} = Catalogue.move_category_under(Catalogue.get_category(chairs.uuid), tables.uuid)

      assert pointer(Catalogue.get_category(chairs.uuid)) == chairs_folder
      assert path(chairs_folder) == ["Catalogues", "Shop", "Tables", "Chairs"]
      assert path(pointer(item)) == ["Catalogues", "Shop", "Tables", "Chairs", "Stool"]
      assert path(pointer(deep)) == ["Catalogues", "Shop", "Tables", "Chairs", "Office", "Swivel"]
    end

    test "a category moved to another catalogue", %{chairs: chairs, item: item} do
      other = fixture_catalogue(%{name: "Outlet"})

      {:ok, _} =
        Catalogue.move_category_to_catalogue(Catalogue.get_category(chairs.uuid), other.uuid)

      assert path(pointer(item)) == ["Catalogues", "Outlet", "Chairs", "Stool"]
    end

    test "renamed category and catalogue folders follow", %{
      catalogue: catalogue,
      chairs: chairs,
      item: item
    } do
      {:ok, _} =
        Catalogue.update_category(Catalogue.get_category(chairs.uuid), %{name: "Seating"})

      {:ok, _} =
        Catalogue.update_catalogue(Catalogue.get_catalogue(catalogue.uuid), %{name: "Store"})

      assert path(pointer(item)) == ["Catalogues", "Store", "Seating", "Stool"]
    end

    test "a folder a person moved stays put", %{item: item, tables: tables} do
      {:ok, elsewhere} = Storage.create_folder(%{name: "Mine"})

      {:ok, _} =
        Storage.update_folder(Storage.get_folder(pointer(item)), %{parent_uuid: elsewhere.uuid})

      {:ok, moved} = Catalogue.move_item_to_category(item, tables.uuid)
      {:ok, renamed} = Catalogue.update_item(moved, %{name: "Bar stool"})

      assert path(pointer(renamed)) == ["Mine", "Stool"]
    end

    test "a folder a person renamed stays put", %{item: item, tables: tables} do
      {:ok, _} = Storage.update_folder(Storage.get_folder(pointer(item)), %{name: "Stool photos"})

      {:ok, renamed} = Catalogue.update_item(item, %{name: "Bar stool"})
      {:ok, moved} = Catalogue.move_item_to_category(renamed, tables.uuid)

      assert path(pointer(moved)) == ["Catalogues", "Shop", "Chairs", "Stool photos"]
    end

    test "a name taken in the new place falls back to the SKU form, then the deterministic one",
         %{catalogue: catalogue, tables: tables} = ctx do
      {:ok, item} = Catalogue.update_item(ctx.item, %{sku: "S-1"})

      other =
        fixture_item(%{
          catalogue_uuid: catalogue.uuid,
          category_uuid: tables.uuid,
          name: "Stool",
          sku: "S-2"
        })

      {:ok, _other} = Attachments.attach_files(other, [insert_file!(ctx.user_uuid)])

      {:ok, moved} = Catalogue.move_item_to_category(item, tables.uuid)
      assert path(pointer(moved)) == ["Catalogues", "Shop", "Tables", "Stool (S-1)"]
    end

    test "an item without a folder is left alone", %{catalogue: catalogue, tables: tables} do
      bare = fixture_item(%{catalogue_uuid: catalogue.uuid, name: "Bare"})
      {:ok, moved} = Catalogue.move_item_to_category(bare, tables.uuid)
      assert pointer(moved) == nil

      refute Storage.get_folder(
               pointer(Catalogue.get_category(tables.uuid)) || Ecto.UUID.generate()
             )
    end

    test "with a host's hooks nothing follows", %{item: item, tables: tables} do
      {:ok, container} = Storage.create_folder(%{name: "Host items"})
      Process.put(:host_container, container.uuid)
      Application.put_env(@app, :attachments_parent_folder, {HostHook, :parent})
      Application.put_env(@app, :attachments_folder_name, {HostHook, :name})
      before = path(pointer(item))

      {:ok, moved} = Catalogue.move_item_to_category(item, tables.uuid)
      {:ok, renamed} = Catalogue.update_item(moved, %{name: "Bar stool"})

      assert path(pointer(renamed)) == before
    end

    test "a bulk move of a hundred items moves their folders in one batch",
         %{catalogue: catalogue, chairs: chairs, tables: tables, user_uuid: user_uuid} do
      uuids =
        for n <- 1..100 do
          item =
            fixture_item(%{
              catalogue_uuid: catalogue.uuid,
              category_uuid: chairs.uuid,
              name: "Chair #{n}"
            })

          {:ok, item} = Attachments.attach_files(item, [insert_file!(user_uuid)])
          item.uuid
        end

      queries = :counters.new(2, [])
      test_pid = self()
      handler = "media-folders-bulk-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:phoenix_kit_catalogue, :test, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if self() == test_pid do
            :counters.add(queries, 1, 1)

            if String.starts_with?(meta.query, "UPDATE ") and
                 String.contains?(meta.query, "phoenix_kit_media_folders") do
              :counters.add(queries, 2, 1)
            end
          end
        end,
        nil
      )

      assert {:ok, 100} =
               Catalogue.bulk_move_items(uuids, {:category, tables.uuid},
                 catalogue_uuid: catalogue.uuid
               )

      :telemetry.detach(handler)

      # One-by-one moves cost ~6 queries a folder (core's tree lock, cycle,
      # trash and library checks each); the batch is one lock, one check set
      # and one UPDATE. The rest is reading each record's name in the
      # primary language, which the test env (no settings cache) pays a
      # few queries for.
      assert :counters.get(queries, 1) < 800
      assert :counters.get(queries, 2) == 1

      assert Enum.all?(uuids, fn uuid ->
               uuid |> Catalogue.get_item() |> pointer() |> path() |> Enum.take(3) ==
                 ["Catalogues", "Shop", "Tables"]
             end)
    end

    test "a bulk move never puts a folder inside its own subtree",
         %{catalogue: catalogue, chairs: chairs, tables: tables, user_uuid: user_uuid} do
      one =
        fixture_item(%{catalogue_uuid: catalogue.uuid, category_uuid: chairs.uuid, name: "One"})

      {:ok, one} = Attachments.attach_files(one, [insert_file!(user_uuid)])

      two =
        fixture_item(%{catalogue_uuid: catalogue.uuid, category_uuid: chairs.uuid, name: "Two"})

      {:ok, two} = Attachments.attach_files(two, [insert_file!(user_uuid)])
      {:ok, _} = Catalogue.update_category(tables, %{name: "Tables"})

      {:ok, _} =
        Attachments.attach_files(
          fixture_item(%{
            catalogue_uuid: catalogue.uuid,
            category_uuid: tables.uuid,
            name: "Seed"
          }),
          [insert_file!(user_uuid)]
        )

      # A person nested the Tables folder inside item "One"'s folder.
      tables_folder = Storage.get_folder(pointer(Catalogue.get_category(tables.uuid)))
      {:ok, _} = Storage.update_folder(tables_folder, %{parent_uuid: pointer(one)})
      # Keep the destination where the hooks look for it.
      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, 2} =
          Catalogue.bulk_move_items([one.uuid, two.uuid], {:category, tables.uuid},
            catalogue_uuid: catalogue.uuid
          )
      end)

      # The folder tree is still a tree: no folder is its own ancestor.
      assert length(ancestry(pointer(Catalogue.get_item(one.uuid)))) < 10

      assert pointer(Catalogue.get_item(one.uuid))
             |> Storage.get_folder()
             |> Map.get(:parent_uuid) !=
               pointer(Catalogue.get_item(one.uuid))
    end

    test "a bulk move gives a namesake in the new place its own name, never two folders alike",
         %{catalogue: catalogue, chairs: chairs, tables: tables, user_uuid: user_uuid} do
      mine =
        fixture_item(%{
          catalogue_uuid: catalogue.uuid,
          category_uuid: chairs.uuid,
          name: "Dup",
          sku: "D-1"
        })

      {:ok, mine} = Attachments.attach_files(mine, [insert_file!(user_uuid)])

      other =
        fixture_item(%{
          catalogue_uuid: catalogue.uuid,
          category_uuid: tables.uuid,
          name: "Dup",
          sku: "D-2"
        })

      {:ok, other} = Attachments.attach_files(other, [insert_file!(user_uuid)])

      third =
        fixture_item(%{catalogue_uuid: catalogue.uuid, category_uuid: chairs.uuid, name: "Other"})

      {:ok, third} = Attachments.attach_files(third, [insert_file!(user_uuid)])

      {:ok, 2} =
        Catalogue.bulk_move_items([mine.uuid, third.uuid], {:category, tables.uuid},
          catalogue_uuid: catalogue.uuid
        )

      names =
        [mine, other, third]
        |> Enum.map(&path(pointer(Catalogue.get_item(&1.uuid))))
        |> Enum.map(&List.last/1)

      assert length(Enum.uniq(names)) == 3
      assert "Other" in names
    end
  end

  describe "a hard-deleted record's folder" do
    setup %{user_uuid: user_uuid} do
      catalogue = fixture_catalogue(%{name: "Shop"})
      chairs = fixture_category(catalogue, %{name: "Chairs"})

      bolt =
        fixture_item(%{catalogue_uuid: catalogue.uuid, category_uuid: chairs.uuid, name: "Bolt"})

      {:ok, bolt} = Attachments.attach_files(bolt, [insert_file!(user_uuid)])

      %{catalogue: catalogue, chairs: chairs, bolt: bolt}
    end

    # A new record of the same name, in the same place, must get a folder
    # of its own — never the deleted record's files.
    defp assert_fresh_bolt(catalogue, chairs, old_folder, user_uuid) do
      new =
        fixture_item(%{catalogue_uuid: catalogue.uuid, category_uuid: chairs.uuid, name: "Bolt"})

      {:ok, new} = Attachments.attach_files(new, [insert_file!(user_uuid)])

      assert pointer(new) != old_folder
      assert path(pointer(new)) == ["Catalogues", "Shop", "Chairs", "Bolt"]
      assert Storage.get_folder(old_folder)
    end

    test "permanently deleting an item", ctx do
      folder = pointer(ctx.bolt)
      {:ok, _} = Catalogue.permanently_delete_item(ctx.bolt)

      assert Storage.get_folder(folder).name == "catalogue-item-#{ctx.bolt.uuid}"
      assert_fresh_bolt(ctx.catalogue, ctx.chairs, folder, ctx.user_uuid)
    end

    test "deleting an item", ctx do
      folder = pointer(ctx.bolt)
      {:ok, _} = Catalogue.delete_item(ctx.bolt)

      assert Storage.get_folder(folder).name == "catalogue-item-#{ctx.bolt.uuid}"
      assert_fresh_bolt(ctx.catalogue, ctx.chairs, folder, ctx.user_uuid)
    end

    test "a taken deterministic name still releases the deleted record's files", ctx do
      folder = Storage.get_folder(pointer(ctx.bolt))
      name = "catalogue-item-#{ctx.bolt.uuid}"
      {:ok, occupied} = Storage.create_folder(%{name: name, parent_uuid: folder.parent_uuid})

      assert {:ok, _} = Catalogue.delete_item(ctx.bolt)
      assert Storage.get_folder(folder.uuid).name != "Bolt"
      assert Storage.get_folder(occupied.uuid).name == name
      assert_fresh_bolt(ctx.catalogue, ctx.chairs, folder.uuid, ctx.user_uuid)
    end

    test "bulk-deleting items", ctx do
      folder = pointer(ctx.bolt)
      assert {1, nil} = Catalogue.bulk_permanently_delete_items([ctx.bolt.uuid], [])

      assert Storage.get_folder(folder).name == "catalogue-item-#{ctx.bolt.uuid}"
      assert_fresh_bolt(ctx.catalogue, ctx.chairs, folder, ctx.user_uuid)
    end

    test "permanently deleting a category releases its folder and its items'", ctx do
      folder = pointer(ctx.bolt)
      chairs_folder = pointer(Catalogue.get_category(ctx.chairs.uuid))
      {:ok, _} = Catalogue.permanently_delete_category(ctx.chairs)

      assert Storage.get_folder(folder).name == "catalogue-item-#{ctx.bolt.uuid}"
      assert Storage.get_folder(chairs_folder).name == "catalogue-category-#{ctx.chairs.uuid}"

      # A new category of the same name starts a new folder.
      again = fixture_category(ctx.catalogue, %{name: "Chairs"})

      item =
        fixture_item(%{
          catalogue_uuid: ctx.catalogue.uuid,
          category_uuid: again.uuid,
          name: "Bolt"
        })

      {:ok, item} = Attachments.attach_files(item, [insert_file!(ctx.user_uuid)])

      assert path(pointer(item)) == ["Catalogues", "Shop", "Chairs", "Bolt"]
      assert pointer(Catalogue.get_category(again.uuid)) != chairs_folder
    end

    test "deleting a category", ctx do
      chairs_folder = pointer(Catalogue.get_category(ctx.chairs.uuid))
      {:ok, _} = Catalogue.delete_category(ctx.chairs)

      assert Storage.get_folder(chairs_folder).name == "catalogue-category-#{ctx.chairs.uuid}"
    end

    test "permanently deleting a catalogue releases the whole tree", ctx do
      folder = pointer(ctx.bolt)
      chairs_folder = pointer(Catalogue.get_category(ctx.chairs.uuid))
      catalogue_folder = pointer(Catalogue.get_catalogue(ctx.catalogue.uuid))
      {:ok, _} = Catalogue.permanently_delete_catalogue(ctx.catalogue)

      assert Storage.get_folder(folder).name == "catalogue-item-#{ctx.bolt.uuid}"
      assert Storage.get_folder(chairs_folder).name == "catalogue-category-#{ctx.chairs.uuid}"
      assert Storage.get_folder(catalogue_folder).name == "catalogue-#{ctx.catalogue.uuid}"
    end

    test "deleting a catalogue", ctx do
      catalogue_folder = pointer(Catalogue.get_catalogue(ctx.catalogue.uuid))
      {:ok, _} = Catalogue.delete_catalogue(ctx.catalogue)

      assert Storage.get_folder(catalogue_folder).name == "catalogue-#{ctx.catalogue.uuid}"
    end

    test "a folder a person renamed keeps its name", ctx do
      folder = Storage.get_folder(pointer(ctx.bolt))
      {:ok, _} = Storage.update_folder(folder, %{name: "Fasteners"})
      {:ok, _} = Catalogue.permanently_delete_item(ctx.bolt)

      assert Storage.get_folder(folder.uuid).name == "Fasteners"
    end

    test "with a host's hooks the folder is left alone", ctx do
      folder = pointer(ctx.bolt)
      Application.put_env(@app, :attachments_parent_folder, {HostHook, :parent})
      Application.put_env(@app, :attachments_folder_name, {HostHook, :name})
      {:ok, _} = Catalogue.permanently_delete_item(ctx.bolt)

      assert Storage.get_folder(folder).name == "Bolt"
    end
  end

  describe "folders follow records the trash and restore paths move" do
    setup %{user_uuid: user_uuid} do
      catalogue = fixture_catalogue(%{name: "Shop"})
      chairs = fixture_category(catalogue, %{name: "Chairs"})
      tables = fixture_category(catalogue, %{name: "Tables"})

      stool =
        fixture_item(%{catalogue_uuid: catalogue.uuid, category_uuid: chairs.uuid, name: "Stool"})

      {:ok, stool} = Attachments.attach_files(stool, [insert_file!(user_uuid)])
      %{catalogue: catalogue, chairs: chairs, tables: tables, stool: stool}
    end

    test "a category trashed with its items uncategorized", ctx do
      {:ok, _} = Catalogue.trash_category(ctx.chairs, items: :uncategorize)

      assert path(pointer(Catalogue.get_item(ctx.stool.uuid))) == ["Catalogues", "Shop", "Stool"]
    end

    test "a category trashed with its items moved to another", ctx do
      {:ok, _} = Catalogue.trash_category(ctx.chairs, items: {:move_to, ctx.tables.uuid})

      assert path(pointer(Catalogue.get_item(ctx.stool.uuid))) ==
               ["Catalogues", "Shop", "Tables", "Stool"]
    end

    test "a category trashed with its items cascaded leaves the folder", ctx do
      {:ok, _} = Catalogue.trash_category(ctx.chairs)

      assert path(pointer(Catalogue.get_item(ctx.stool.uuid))) ==
               ["Catalogues", "Shop", "Chairs", "Stool"]
    end

    test "an item restored into a trashed category goes to the catalogue's folder", ctx do
      {:ok, _} = Catalogue.trash_category(ctx.chairs)
      {:ok, _} = Catalogue.restore_item(Catalogue.get_item(ctx.stool.uuid))

      assert path(pointer(Catalogue.get_item(ctx.stool.uuid))) == ["Catalogues", "Shop", "Stool"]
    end

    test "items bulk-restored into a trashed category go to the catalogue's folder", ctx do
      {:ok, _} = Catalogue.trash_category(ctx.chairs)
      assert {1, nil} = Catalogue.bulk_restore_items([ctx.stool.uuid], [])

      assert path(pointer(Catalogue.get_item(ctx.stool.uuid))) == ["Catalogues", "Shop", "Stool"]
    end

    test "a live subcategory kept by a permanent delete moves to the top level, folders along",
         %{user_uuid: user_uuid} = ctx do
      seating = fixture_category(ctx.catalogue, %{name: "Seating"})
      bench = fixture_category(ctx.catalogue, %{name: "Benches", parent_uuid: seating.uuid})

      item =
        fixture_item(%{
          catalogue_uuid: ctx.catalogue.uuid,
          category_uuid: bench.uuid,
          name: "Pew"
        })

      {:ok, item} = Attachments.attach_files(item, [insert_file!(user_uuid)])
      seating_folder = pointer(Catalogue.get_category(seating.uuid))

      {:ok, _} = Catalogue.trash_category(seating)
      {:ok, _} = Catalogue.restore_category(Catalogue.get_category(bench.uuid))
      {:ok, _} = Catalogue.permanently_delete_category(Catalogue.get_category(seating.uuid))

      assert path(pointer(Catalogue.get_category(bench.uuid))) == [
               "Catalogues",
               "Shop",
               "Benches"
             ]

      assert path(pointer(Catalogue.get_item(item.uuid))) ==
               ["Catalogues", "Shop", "Benches", "Pew"]

      assert Storage.get_folder(seating_folder).name == "catalogue-category-#{seating.uuid}"
    end
  end

  describe "a folder that cannot follow its record" do
    test "a refused cycle does not roll back a bulk category trash", %{user_uuid: user_uuid} do
      catalogue = fixture_catalogue(%{name: "Cycle"})
      source = fixture_category(catalogue, %{name: "Source"})
      target = fixture_category(catalogue, %{name: "Target"})
      item = fixture_item(%{catalogue_uuid: catalogue.uuid, category_uuid: source.uuid})
      {:ok, item} = Attachments.attach_files(item, [insert_file!(user_uuid)])

      {:ok, target_folder} =
        MediaFolders.parent_for(:item, user_uuid, %{item | category_uuid: target.uuid})

      {:ok, _} =
        Storage.update_folder(Storage.get_folder(target_folder), %{parent_uuid: pointer(item)})

      assert {:ok, _} =
               Catalogue.bulk_trash_categories([source.uuid], {:move_to, target.uuid}, [])

      assert Catalogue.get_category(source.uuid).status == "deleted"
      assert Catalogue.get_item(item.uuid).category_uuid == target.uuid
      assert Storage.get_folder(pointer(item)).parent_uuid != target_folder
      assert length(ancestry(pointer(item))) < 10
    end

    test "does not undo the transaction the context called it from",
         %{user_uuid: user_uuid} do
      catalogue = fixture_catalogue(%{name: "Shop"})
      chairs = fixture_category(catalogue, %{name: "Chairs"})
      tables = fixture_category(catalogue, %{name: "Tables"})

      stool =
        fixture_item(%{catalogue_uuid: catalogue.uuid, category_uuid: chairs.uuid, name: "Stool"})

      {:ok, stool} = Attachments.attach_files(stool, [insert_file!(user_uuid)])
      folder = Storage.get_folder(pointer(stool))

      # The destination already holds a folder under each name the stool's
      # could take, so the update is refused.
      {:ok, tables_folder} =
        MediaFolders.parent_for(:item, user_uuid, %Item{
          catalogue_uuid: catalogue.uuid,
          category_uuid: tables.uuid
        })

      for name <- ["Stool", "catalogue-item-#{stool.uuid}", "Stool (#{stool.sku})"] do
        Storage.create_folder(%{name: name, parent_uuid: tables_folder})
      end

      moved = %{stool | category_uuid: tables.uuid}

      assert {:ok, :done} =
               Repo.transaction(fn ->
                 assert :ok = MediaFolders.follow([{stool, moved}], user_uuid)
                 :done
               end)

      # The folder found no free name and stayed where it was.
      assert %{parent_uuid: parent, name: "Stool"} = Storage.get_folder(folder.uuid)
      refute parent == tables_folder
    end
  end

  # ── helpers ──

  defp wrap(uuid) when is_binary(uuid), do: {:ok, uuid}
  defp wrap(other), do: other

  defp pointer(%{data: data}), do: data["files_folder_uuid"]
  defp pointer(nil), do: nil

  defp flat_folder!(item) do
    {:ok, folder} = Storage.create_folder(%{name: "catalogue-item-#{item.uuid}"})

    {:ok, _} =
      Catalogue.update_item(item, %{
        data: Map.put(item.data || %{}, "files_folder_uuid", folder.uuid)
      })

    folder
  end

  defp path(nil), do: nil
  defp path(folder_uuid), do: folder_uuid |> ancestry() |> Enum.map(& &1.name)

  defp ancestry(folder_uuid, acc \\ [])
  defp ancestry(nil, acc), do: acc

  # A folder cycle must fail the test, not hang it.
  defp ancestry(_folder_uuid, acc) when length(acc) > 20,
    do: flunk("the folder tree loops: #{inspect(Enum.map(acc, & &1.name))}")

  defp ancestry(folder_uuid, acc) do
    folder = Storage.get_folder(folder_uuid)
    ancestry(folder.parent_uuid, [folder | acc])
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
        "media-folders-#{System.unique_integer([:positive])}@example.com",
        "$2b$12$0000000000000000000000000000000000000000000000000000."
      ]
    )

    user_uuid
  end

  defp insert_file!(user_uuid) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    uuid = UUIDv7.generate()

    Repo.insert!(%StorageFile{
      uuid: uuid,
      original_file_name: "photo.jpg",
      file_name: "photo.jpg",
      mime_type: "image/jpeg",
      file_type: "image",
      ext: "jpg",
      file_checksum: "chk-#{uuid}",
      user_file_checksum: "uchk-#{uuid}",
      size: 1,
      status: "active",
      system_managed: false,
      user_uuid: user_uuid,
      inserted_at: now,
      updated_at: now
    })

    uuid
  end
end
