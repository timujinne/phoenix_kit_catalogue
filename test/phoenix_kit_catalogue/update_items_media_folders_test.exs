defmodule PhoenixKitCatalogue.UpdateItemsMediaFoldersTest do
  @moduledoc """
  A batch write follows the same media-folder lifecycle as the single-item
  write it replaces: a renamed or moved item's folder goes with it, after the
  commit, in one pass for the whole batch; a row that failed leaves its folder
  where it is; the options the shop API adds (`:log_metadata`, `:broadcast`,
  `:data_owned_paths`) change nothing about it.
  """

  use PhoenixKitCatalogue.DataCase, async: false

  import ExUnit.CaptureLog

  import PhoenixKitCatalogue.LiveCase,
    only: [fixture_catalogue: 1, fixture_category: 2, fixture_item: 1]

  import PhoenixKitCatalogue.Test.MediaFixtures

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Test.{MediaHooks, QueryHook, Repo}

  @meta %{"via" => "api", "tool" => "catalogue.update_products"}

  # The actor owns the folders a move has to create, so it is a real user.
  defp opts(%{user_uuid: user_uuid}, extra \\ []),
    do: Keyword.merge([actor_uuid: user_uuid, mode: "auto", log_metadata: @meta], extra)

  setup do
    MediaHooks.restore_on_exit()
    user_uuid = insert_user!()

    catalogue = fixture_catalogue(%{name: "Shop"})
    chairs = fixture_category(catalogue, %{name: "Chairs"})
    tables = fixture_category(catalogue, %{name: "Tables"})

    stool =
      %{catalogue_uuid: catalogue.uuid, category_uuid: chairs.uuid, name: "Stool"}
      |> fixture_item()
      |> with_folder!(user_uuid)

    bench =
      %{catalogue_uuid: catalogue.uuid, category_uuid: chairs.uuid, name: "Bench"}
      |> fixture_item()
      |> with_folder!(user_uuid)

    %{
      user_uuid: user_uuid,
      catalogue: catalogue,
      chairs: chairs,
      tables: tables,
      stool: stool,
      bench: bench
    }
  end

  defp folder_path(item_uuid), do: item_uuid |> Catalogue.get_item!() |> pointer() |> path()

  describe "update_items/2" do
    test "the folders of renamed rows are renamed", %{stool: stool, bench: bench} = ctx do
      assert {:ok, [{_, {:updated, _}}, {_, {:updated, _}}]} =
               Catalogue.update_items(
                 [{stool.uuid, %{name: "Bar stool"}}, {bench.uuid, %{name: "Long bench"}}],
                 opts(ctx)
               )

      assert folder_path(stool.uuid) == ["Catalogues", "Shop", "Chairs", "Bar stool"]
      assert folder_path(bench.uuid) == ["Catalogues", "Shop", "Chairs", "Long bench"]
    end

    test "a row moved to another category takes its folder along",
         %{stool: stool, tables: tables} = ctx do
      assert {:ok, [{_, {:updated, _}}]} =
               Catalogue.update_items([{stool.uuid, %{category_uuid: tables.uuid}}], opts(ctx))

      assert folder_path(stool.uuid) == ["Catalogues", "Shop", "Tables", "Stool"]
    end

    test "rows moved together move their folders in one UPDATE",
         %{
           catalogue: catalogue,
           chairs: chairs,
           tables: tables,
           user_uuid: user_uuid
         } = ctx do
      uuids =
        for n <- 1..20 do
          %{catalogue_uuid: catalogue.uuid, category_uuid: chairs.uuid, name: "Chair #{n}"}
          |> fixture_item()
          |> with_folder!(user_uuid)
          |> Map.fetch!(:uuid)
        end

      {result, queries} =
        QueryHook.queries(fn ->
          Catalogue.update_items(
            Enum.map(uuids, &{&1, %{category_uuid: tables.uuid}}),
            opts(ctx)
          )
        end)

      assert {:ok, outcomes} = result
      assert Enum.all?(outcomes, &match?({_, {:updated, _}}, &1))

      folder_updates =
        Enum.count(queries, fn query ->
          String.starts_with?(query, "UPDATE ") and
            String.contains?(query, "phoenix_kit_media_folders")
        end)

      assert folder_updates == 1

      assert Enum.all?(
               uuids,
               &(Enum.take(folder_path(&1), 3) == ["Catalogues", "Shop", "Tables"])
             )
    end

    test "a row that fails leaves its folder; the rows that went through follow", ctx do
      %{catalogue: catalogue, chairs: chairs, user_uuid: user_uuid} = ctx

      plain =
        %{catalogue_uuid: catalogue.uuid, category_uuid: chairs.uuid, name: "Plain"}
        |> fixture_item()
        |> with_folder!(user_uuid)

      rows = [
        {ctx.stool.uuid, %{name: "Bar stool"}},
        # the database refuses the value: answered :database_error
        {ctx.bench.uuid, %{name: "a" <> <<0>> <> "b"}},
        # a new name, but the changeset refuses another value of the row
        {plain.uuid, %{name: "Plain 2", status: "bogus"}}
      ]

      capture_log(fn ->
        assert {:ok,
                [
                  {_, {:updated, _}},
                  {_, {:error, :database_error}},
                  {_, {:error, %Ecto.Changeset{}}}
                ]} = Catalogue.update_items(rows, opts(ctx))
      end)

      assert folder_path(ctx.stool.uuid) == ["Catalogues", "Shop", "Chairs", "Bar stool"]
      assert folder_path(ctx.bench.uuid) == ["Catalogues", "Shop", "Chairs", "Bench"]
      assert folder_path(plain.uuid) == ["Catalogues", "Shop", "Chairs", "Plain"]
    end

    test "a row moved to a category that does not exist leaves its folder", ctx do
      assert {:ok, [{_, {:error, %Ecto.Changeset{}}}]} =
               Catalogue.update_items(
                 [{ctx.stool.uuid, %{category_uuid: Ecto.UUID.generate()}}],
                 opts(ctx)
               )

      assert folder_path(ctx.stool.uuid) == ["Catalogues", "Shop", "Chairs", "Stool"]
    end

    test "a row that changes nothing leaves its folder, and so does a rename of another field",
         %{stool: stool} = ctx do
      assert {:ok, [{_, {:unchanged, _}}]} =
               Catalogue.update_items([{stool.uuid, %{name: "Stool"}}], opts(ctx))

      assert {:ok, [{_, {:updated, _}}]} =
               Catalogue.update_items([{stool.uuid, %{description: "Wooden"}}], opts(ctx))

      assert folder_path(stool.uuid) == ["Catalogues", "Shop", "Chairs", "Stool"]
    end

    test "a folder a person renamed stays put", %{stool: stool} = ctx do
      {:ok, _} =
        stool |> pointer() |> Storage.get_folder() |> Storage.update_folder(%{name: "Photos"})

      assert {:ok, [{_, {:updated, _}}]} =
               Catalogue.update_items([{stool.uuid, %{name: "Bar stool"}}], opts(ctx))

      assert folder_path(stool.uuid) == ["Catalogues", "Shop", "Chairs", "Photos"]
    end

    test "an item without a folder is left alone, and costs the folder table nothing", ctx do
      %{catalogue: catalogue, chairs: chairs} = ctx

      uuids =
        for n <- 1..5 do
          fixture_item(%{
            catalogue_uuid: catalogue.uuid,
            category_uuid: chairs.uuid,
            name: "Bare #{n}"
          }).uuid
        end

      {result, queries} =
        QueryHook.queries(fn ->
          Catalogue.update_items(Enum.map(uuids, &{&1, %{name: "Renamed #{&1}"}}), opts(ctx))
        end)

      assert {:ok, outcomes} = result
      assert Enum.all?(outcomes, &match?({_, {:updated, _}}, &1))
      refute Enum.any?(queries, &String.contains?(&1, "phoenix_kit_media_folders"))
    end

    test "with the layout switched off nothing follows", %{stool: stool} = ctx do
      MediaHooks.without_hooks()

      assert {:ok, [{_, {:updated, _}}]} =
               Catalogue.update_items([{stool.uuid, %{name: "Bar stool"}}], opts(ctx))

      assert folder_path(stool.uuid) == ["Catalogues", "Shop", "Chairs", "Stool"]
    end

    test "the options the shop API adds do not change what follows", %{stool: stool} = ctx do
      assert {:ok, [{_, {:updated, _}}]} =
               Catalogue.update_items(
                 [
                   {stool.uuid, %{name: "Bar stool", data: %{"api" => %{"external_id" => "E-1"}}},
                    [data_owned_paths: [["api", "external_id"]]]}
                 ],
                 opts(ctx, broadcast: false)
               )

      item = Catalogue.get_item!(stool.uuid)
      assert path(pointer(item)) == ["Catalogues", "Shop", "Chairs", "Bar stool"]
      assert item.data["api"] == %{"external_id" => "E-1"}
    end

    test "in a transaction that is rolled back the names and the folders go back together",
         %{stool: stool, tables: tables} = ctx do
      assert {:error, :undo} =
               Repo.transaction(fn ->
                 assert {:ok, [{_, {:updated, _}}]} =
                          Catalogue.update_items(
                            [{stool.uuid, %{name: "Bar stool", category_uuid: tables.uuid}}],
                            opts(ctx)
                          )

                 assert folder_path(stool.uuid) == ["Catalogues", "Shop", "Tables", "Bar stool"]
                 Repo.rollback(:undo)
               end)

      assert Catalogue.get_item!(stool.uuid).name == "Stool"
      assert folder_path(stool.uuid) == ["Catalogues", "Shop", "Chairs", "Stool"]
    end
  end

  describe "the row lock decides what follows" do
    test "update_item follows the locked row, not a stale copy of the caller's",
         %{stool: stool} do
      # Another writer renames the item first; its folder follows.
      {:ok, _} = Catalogue.update_item(Catalogue.get_item!(stool.uuid), %{name: "Stool v2"})
      assert folder_path(stool.uuid) == ["Catalogues", "Shop", "Chairs", "Stool v2"]

      # The caller still holds the item as it was.
      assert {:ok, _} =
               Catalogue.update_item(stool, %{name: "Stool v3"},
                 data_owned_paths: [["api", "external_id"]]
               )

      assert folder_path(stool.uuid) == ["Catalogues", "Shop", "Chairs", "Stool v3"]
    end

    test "update_category follows the locked row, not a stale copy of the caller's", ctx do
      %{chairs: chairs, stool: stool} = ctx
      {:ok, _} = Catalogue.update_category(Catalogue.get_category(chairs.uuid), %{name: "Seats"})
      assert folder_path(stool.uuid) == ["Catalogues", "Shop", "Seats", "Stool"]

      assert {:ok, _} =
               Catalogue.update_category(chairs, %{name: "Seating"},
                 data_owned_paths: [["api", "external_id"]]
               )

      assert folder_path(stool.uuid) == ["Catalogues", "Shop", "Seating", "Stool"]
    end
  end

  describe "trash_item/2 and restore_item/2 with the shop API's options" do
    test "the folder stays where it is while the item is in the trash", %{stool: stool} = ctx do
      assert {:ok, %{status: "deleted"}} =
               Catalogue.trash_item(stool, opts(ctx, broadcast: false))

      assert folder_path(stool.uuid) == ["Catalogues", "Shop", "Chairs", "Stool"]

      assert {:ok, %{status: "active"}} =
               Catalogue.restore_item(
                 Catalogue.get_item!(stool.uuid),
                 opts(ctx, broadcast: false)
               )

      assert folder_path(stool.uuid) == ["Catalogues", "Shop", "Chairs", "Stool"]
    end

    test "an item restored out of a trashed category takes its folder to the catalogue's", ctx do
      {:ok, _} = Catalogue.trash_category(ctx.chairs)

      assert {:ok, _} =
               Catalogue.restore_item(
                 Catalogue.get_item!(ctx.stool.uuid),
                 opts(ctx, broadcast: false)
               )

      assert folder_path(ctx.stool.uuid) == ["Catalogues", "Shop", "Stool"]

      log = assert_activity_logged("item.restored", resource_uuid: ctx.stool.uuid)
      assert log.metadata["via"] == "api"
      assert log.metadata["detached_from_category"] == true
    end

    test "trashing an item already in the trash logs nothing more", %{stool: stool} = ctx do
      {:ok, _} = Catalogue.trash_item(stool, opts(ctx))
      {:ok, again} = Catalogue.trash_item(stool, opts(ctx))

      assert again.status == "deleted"
      # exactly one entry: the first trash's
      assert_activity_logged("item.trashed", resource_uuid: stool.uuid)
    end
  end
end
