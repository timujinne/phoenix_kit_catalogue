defmodule PhoenixKitCatalogue.API.MediaFoldersTest do
  @moduledoc """
  The shop API's write tools keep the media-folder layout the way the admin's
  single-record saves do: a renamed or moved product or category takes its
  folder along, a request's failed row leaves its folder where it is, a trash
  leaves the folder with the item, and creating a record makes no folder (it
  gets one when its first file arrives).
  """

  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase,
    only: [fixture_catalogue: 1, fixture_category: 2, fixture_item: 1]

  import PhoenixKitCatalogue.Test.MediaFixtures

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Folder
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Test.{ApiCase, MediaHooks, QueryHook, Repo}

  setup do
    MediaHooks.restore_on_exit()
    user_uuid = insert_user!(ApiCase.user_uuid())

    catalogue = fixture_catalogue(%{name: "Shop"})
    chairs = fixture_category(catalogue, %{name: "Chairs"})
    tables = fixture_category(catalogue, %{name: "Tables"})

    stool = item(catalogue, chairs, "Stool", user_uuid)
    bench = item(catalogue, chairs, "Bench", user_uuid)
    desk = item(catalogue, tables, "Desk", user_uuid)

    %{
      user_uuid: user_uuid,
      catalogue: catalogue,
      chairs: chairs,
      tables: tables,
      stool: stool,
      bench: bench,
      desk: desk
    }
  end

  defp item(catalogue, category, name, user_uuid, extra \\ %{}) do
    %{catalogue_uuid: catalogue.uuid, category_uuid: category && category.uuid, name: name}
    |> Map.merge(extra)
    |> fixture_item()
    |> with_folder!(user_uuid)
  end

  defp where_is(%{uuid: uuid}), do: uuid |> Catalogue.get_item!() |> pointer() |> path()

  defp where_is_category(%{uuid: uuid}),
    do: uuid |> Catalogue.get_category() |> pointer() |> path()

  defp rows({:ok, %{"results" => rows}}), do: rows

  defp folder_count, do: Repo.aggregate(Folder, :count)

  describe "catalogue.update_products" do
    @tool "catalogue.update_products"

    defp run_update(catalogue, entries),
      do: ApiCase.call(@tool, %{"catalogue_id" => catalogue.uuid, "items" => entries}, %{})

    defp entry(item, changes), do: %{"ref" => %{"id" => item.uuid}, "changes" => changes}

    test "renamed products take their folders along", ctx do
      assert {:ok, %{"summary" => %{"updated" => 2}}} =
               run_update(ctx.catalogue, [
                 entry(ctx.stool, %{"name" => "Bar stool"}),
                 entry(ctx.bench, %{"name" => "Long bench"})
               ])

      assert where_is(ctx.stool) == ["Catalogues", "Shop", "Chairs", "Bar stool"]
      assert where_is(ctx.bench) == ["Catalogues", "Shop", "Chairs", "Long bench"]
    end

    test "products moved to another category take their folders along", ctx do
      assert {:ok, %{"summary" => %{"updated" => 2}}} =
               run_update(ctx.catalogue, [
                 entry(ctx.stool, %{"category_id" => ctx.tables.uuid}),
                 entry(ctx.bench, %{"category_id" => nil})
               ])

      assert where_is(ctx.stool) == ["Catalogues", "Shop", "Tables", "Stool"]
      assert where_is(ctx.bench) == ["Catalogues", "Shop", "Bench"]
    end

    test "products moved together move their folders in one pass", ctx do
      moving =
        for n <- 1..20 do
          item(ctx.catalogue, ctx.chairs, "Chair #{n}", ctx.user_uuid)
        end

      entries = Enum.map(moving, &entry(&1, %{"category_id" => ctx.tables.uuid}))
      {result, queries} = QueryHook.queries(fn -> run_update(ctx.catalogue, entries) end)

      assert {:ok, %{"summary" => %{"updated" => 20}}} = result

      folder_updates =
        Enum.count(queries, fn query ->
          String.starts_with?(query, "UPDATE ") and
            String.contains?(query, "phoenix_kit_media_folders")
        end)

      # One UPDATE for the twenty folders; one by one it would be twenty.
      assert folder_updates == 1

      assert Enum.all?(moving, &(Enum.take(where_is(&1), 3) == ["Catalogues", "Shop", "Tables"]))
    end

    test "a product renamed by someone else before its move still has its folder follow", ctx do
      # The other writer renames the stool after the batch write and before the
      # stool's own move: the move works on the row it locked, not on the copy
      # the request planned with, so the folder (renamed along by that save) is
      # still recognised as the item's and goes along into the new category.
      result =
        QueryHook.after_query(
          ~r/INSERT INTO "phoenix_kit_activities"/,
          fn ->
            {:ok, _} =
              Catalogue.update_item(Catalogue.get_item!(ctx.stool.uuid), %{name: "Stool v2"})
          end,
          fn ->
            run_update(ctx.catalogue, [
              entry(ctx.bench, %{"name" => "Long bench"}),
              entry(ctx.stool, %{"category_id" => ctx.tables.uuid})
            ])
          end
        )

      assert {:ok, %{"summary" => %{"updated" => 2}}} = result
      assert Catalogue.get_item!(ctx.stool.uuid).category_uuid == ctx.tables.uuid
      assert where_is(ctx.stool) == ["Catalogues", "Shop", "Tables", "Stool v2"]
    end

    test "a product renamed between its move and the folder pass gets its new name", ctx do
      # The rename lands after the move committed and before the one folder pass:
      # the admin's own save finds the folder not yet in the new category and
      # leaves it, so the pass has to take the item as it is by then.
      result =
        QueryHook.after_query(
          ~r/INSERT INTO "phoenix_kit_activities"/,
          fn ->
            {:ok, _} =
              Catalogue.update_item(Catalogue.get_item!(ctx.stool.uuid), %{name: "Stool v2"})
          end,
          fn ->
            run_update(ctx.catalogue, [entry(ctx.stool, %{"category_id" => ctx.tables.uuid})])
          end
        )

      assert {:ok, %{"summary" => %{"updated" => 1}}} = result
      assert where_is(ctx.stool) == ["Catalogues", "Shop", "Tables", "Stool v2"]

      # and a later rename still finds the folder
      {:ok, _} = Catalogue.update_item(Catalogue.get_item!(ctx.stool.uuid), %{name: "Stool v3"})
      assert where_is(ctx.stool) == ["Catalogues", "Shop", "Tables", "Stool v3"]
    end

    test "a row that raises leaves the folders of the moves already made following", ctx do
      # The second move raises (a check constraint a hook adds after the first
      # move's log entry), after the first one committed.
      outcome =
        try do
          QueryHook.after_query(
            ~r/INSERT INTO "phoenix_kit_activities"/,
            fn ->
              Repo.query!(
                "ALTER TABLE phoenix_kit_cat_items ADD CONSTRAINT api_test_ck " <>
                  "CHECK (name <> 'Bench') NOT VALID"
              )
            end,
            fn ->
              run_update(ctx.catalogue, [
                entry(ctx.stool, %{"category_id" => ctx.tables.uuid}),
                entry(ctx.bench, %{"category_id" => ctx.tables.uuid})
              ])
            end
          )
        rescue
          exception -> {:raised, exception}
        end

      assert {:raised, _exception} = outcome
      assert Catalogue.get_item!(ctx.stool.uuid).category_uuid == ctx.tables.uuid
      assert where_is(ctx.stool) == ["Catalogues", "Shop", "Tables", "Stool"]
    end

    test "a rename together with a move leaves one folder, named and placed anew", ctx do
      before = folder_count()

      assert {:ok, %{"summary" => %{"updated" => 1}}} =
               run_update(ctx.catalogue, [
                 entry(ctx.stool, %{"name" => "Bar stool", "category_id" => ctx.tables.uuid})
               ])

      assert where_is(ctx.stool) == ["Catalogues", "Shop", "Tables", "Bar stool"]
      assert folder_count() == before
    end

    test "a product the request rejects keeps its folder; the others follow", ctx do
      other = fixture_catalogue(%{name: "Other"})
      foreign = fixture_category(other, %{name: "Foreign"})

      result =
        run_update(ctx.catalogue, [
          entry(ctx.stool, %{"name" => "Bar stool"}),
          entry(ctx.bench, %{"name" => "Long bench", "category_id" => foreign.uuid})
        ])

      assert {:ok, %{"summary" => %{"updated" => 1, "error" => 1}}} = result
      assert where_is(ctx.stool) == ["Catalogues", "Shop", "Chairs", "Bar stool"]
      assert where_is(ctx.bench) == ["Catalogues", "Shop", "Chairs", "Bench"]
    end

    test "a product whose write fails keeps its folder; the others follow", ctx do
      # The holder takes the external_id after the request was planned.
      result =
        QueryHook.after_query(
          ~s(SELECT p0."category_uuid" FROM "phoenix_kit_cat_items"),
          fn ->
            {:ok, _} =
              Catalogue.create_item(%{
                name: "Holder",
                catalogue_uuid: ctx.catalogue.uuid,
                data: %{"api" => %{"external_id" => "TAKEN"}}
              })
          end,
          fn ->
            run_update(ctx.catalogue, [
              entry(ctx.stool, %{"name" => "Bar stool"}),
              entry(ctx.bench, %{"name" => "Long bench", "external_id" => "TAKEN"})
            ])
          end
        )

      assert {:ok, %{"summary" => %{"updated" => 1, "error" => 1}}} = result
      assert where_is(ctx.stool) == ["Catalogues", "Shop", "Chairs", "Bar stool"]
      assert where_is(ctx.bench) == ["Catalogues", "Shop", "Chairs", "Bench"]
      assert Catalogue.get_item!(ctx.bench.uuid).name == "Bench"
    end

    test "a rename stays with its folder when the move that came with it is refused", ctx do
      # The new category is trashed between planning and the move: the rename
      # is stored (the row says `saved`), the item stays where it was.
      result =
        QueryHook.after_query(
          ~s(UPDATE "phoenix_kit_cat_items"),
          fn -> {:ok, _} = Catalogue.trash_category(Catalogue.get_category(ctx.tables.uuid)) end,
          fn ->
            run_update(ctx.catalogue, [
              entry(ctx.stool, %{"name" => "Bar stool", "category_id" => ctx.tables.uuid})
            ])
          end
        )

      assert [%{"action" => "error", "error" => %{"context" => %{"saved" => true}}}] =
               rows(result)

      reread = Catalogue.get_item!(ctx.stool.uuid)
      assert {reread.name, reread.category_uuid} == {"Bar stool", ctx.chairs.uuid}
      assert where_is(ctx.stool) == ["Catalogues", "Shop", "Chairs", "Bar stool"]
    end

    test "a dry run moves nothing", ctx do
      assert {:preview, _preview, _fingerprint} =
               ApiCase.call(
                 @tool,
                 %{
                   "catalogue_id" => ctx.catalogue.uuid,
                   "items" => [entry(ctx.stool, %{"name" => "Bar stool"})]
                 },
                 %{dry_run?: true}
               )

      assert where_is(ctx.stool) == ["Catalogues", "Shop", "Chairs", "Stool"]
    end

    test "a folder a person renamed stays put", ctx do
      {:ok, _} =
        ctx.stool
        |> pointer()
        |> Storage.get_folder()
        |> Storage.update_folder(%{name: "Photos"})

      assert {:ok, %{"summary" => %{"updated" => 1}}} =
               run_update(ctx.catalogue, [entry(ctx.stool, %{"name" => "Bar stool"})])

      assert where_is(ctx.stool) == ["Catalogues", "Shop", "Chairs", "Photos"]
    end

    test "with the layout switched off nothing follows", ctx do
      MediaHooks.without_hooks()

      assert {:ok, %{"summary" => %{"updated" => 1}}} =
               run_update(ctx.catalogue, [entry(ctx.stool, %{"name" => "Bar stool"})])

      assert where_is(ctx.stool) == ["Catalogues", "Shop", "Chairs", "Stool"]
    end
  end

  describe "catalogue.set_translations" do
    @translate "catalogue.set_translations"

    setup ctx do
      {:ok, _} = Languages.enable_system()
      {:ok, _} = Languages.add_language("de-DE")
      {:ok, _} = Languages.add_language("fr-FR")
      on_exit(fn -> Languages.disable_system() end)

      # The folder is named in the site's language, which is not the item's
      # own primary language here, so a translation can rename it.
      {:ok, _} =
        Catalogue.update_item(Catalogue.get_item!(ctx.stool.uuid), %{
          data: Map.put(Catalogue.get_item!(ctx.stool.uuid).data, "_primary_language", "en-US")
        })

      {:ok, _} = Languages.set_default_language("de-DE")
      on_exit(fn -> Languages.set_default_language("en-US") end)
      :ok
    end

    defp translate(catalogue, item, translations) do
      ApiCase.call(
        @translate,
        %{
          "catalogue_id" => catalogue.uuid,
          "items" => [%{"ref" => %{"id" => item.uuid}, "translations" => translations}]
        },
        %{}
      )
    end

    test "the translation in the site's language renames the folder", ctx do
      assert {:ok, %{"summary" => %{"updated" => 1}}} =
               translate(ctx.catalogue, ctx.stool, %{"de-DE" => %{"name" => "Hocker"}})

      assert where_is(ctx.stool) == ["Catalogues", "Shop", "Chairs", "Hocker"]
    end

    test "a translation in another language leaves the folder alone", ctx do
      assert {:ok, %{"summary" => %{"updated" => 1}}} =
               translate(ctx.catalogue, ctx.stool, %{"fr-FR" => %{"name" => "Tabouret"}})

      assert where_is(ctx.stool) == ["Catalogues", "Shop", "Chairs", "Stool"]
    end
  end

  describe "catalogue.upsert_categories" do
    @upsert "catalogue.upsert_categories"

    defp upsert(catalogue, rows),
      do: ApiCase.call(@upsert, %{"catalogue_id" => catalogue.uuid, "items" => rows}, %{})

    test "a renamed category's folder is renamed, with everything in it", ctx do
      assert {:ok, %{"summary" => %{"updated" => 1}}} =
               upsert(ctx.catalogue, [%{"id" => ctx.chairs.uuid, "name" => "Seating"}])

      assert where_is_category(ctx.chairs) == ["Catalogues", "Shop", "Seating"]
      assert where_is(ctx.stool) == ["Catalogues", "Shop", "Seating", "Stool"]
      assert where_is(ctx.bench) == ["Catalogues", "Shop", "Seating", "Bench"]
    end

    test "a category moved under another takes its folder and its subtree along", ctx do
      assert {:ok, %{"summary" => %{"updated" => 1}}} =
               upsert(ctx.catalogue, [
                 %{"id" => ctx.chairs.uuid, "parent" => %{"id" => ctx.tables.uuid}}
               ])

      assert where_is_category(ctx.chairs) == ["Catalogues", "Shop", "Tables", "Chairs"]
      assert where_is(ctx.stool) == ["Catalogues", "Shop", "Tables", "Chairs", "Stool"]
    end

    test "a category moved to the top level goes back under the catalogue's folder", ctx do
      {:ok, _} =
        upsert(ctx.catalogue, [
          %{"id" => ctx.chairs.uuid, "parent" => %{"id" => ctx.tables.uuid}}
        ])

      assert {:ok, %{"summary" => %{"updated" => 1}}} =
               upsert(ctx.catalogue, [%{"id" => ctx.chairs.uuid, "parent" => nil}])

      assert where_is(ctx.stool) == ["Catalogues", "Shop", "Chairs", "Stool"]
    end

    test "a row the request refuses leaves its folder; the others follow", ctx do
      result =
        upsert(ctx.catalogue, [
          %{"id" => ctx.chairs.uuid, "parent" => %{"id" => ctx.tables.uuid}},
          # now a cycle: Tables under its own descendant
          %{"id" => ctx.tables.uuid, "parent" => %{"id" => ctx.chairs.uuid}}
        ])

      assert {:ok, %{"summary" => %{"updated" => 1, "error" => 1}}} = result
      assert where_is(ctx.stool) == ["Catalogues", "Shop", "Tables", "Chairs", "Stool"]
      assert where_is(ctx.desk) == ["Catalogues", "Shop", "Tables", "Desk"]
    end

    test "a category with a new name and a new parent is renamed and moved once", ctx do
      assert {:ok, %{"summary" => %{"updated" => 1}}} =
               upsert(ctx.catalogue, [
                 %{
                   "id" => ctx.chairs.uuid,
                   "name" => "Seating",
                   "parent" => %{"id" => ctx.tables.uuid}
                 }
               ])

      assert where_is(ctx.stool) == ["Catalogues", "Shop", "Tables", "Seating", "Stool"]
    end

    test "creating a category makes no folder", ctx do
      before = folder_count()

      assert {:ok, %{"summary" => %{"created" => 1}}} =
               upsert(ctx.catalogue, [%{"external_id" => "C-NEW", "name" => "Lamps"}])

      assert folder_count() == before
    end
  end

  describe "catalogue.delete_products" do
    @delete "catalogue.delete_products"

    test "a trashed product keeps its folder, and gets it back on restore", ctx do
      folder = pointer(ctx.stool)

      assert {:ok, %{"summary" => %{"removed" => 1}}} =
               ApiCase.call(
                 @delete,
                 %{"catalogue_id" => ctx.catalogue.uuid, "refs" => [%{"id" => ctx.stool.uuid}]},
                 %{}
               )

      trashed = Catalogue.get_item!(ctx.stool.uuid)
      assert trashed.status == "deleted"
      assert pointer(trashed) == folder
      assert where_is(ctx.stool) == ["Catalogues", "Shop", "Chairs", "Stool"]

      {:ok, restored} = Catalogue.restore_item(trashed)
      assert pointer(restored) == folder
      assert where_is(ctx.stool) == ["Catalogues", "Shop", "Chairs", "Stool"]
    end
  end

  describe "catalogue.create_products" do
    @create "catalogue.create_products"

    test "creating a product makes no folder; its first file makes one in the layout", ctx do
      before = folder_count()

      assert {:ok, %{"summary" => %{"created" => 1}, "results" => [%{"id" => id}]}} =
               ApiCase.call(
                 @create,
                 %{
                   "catalogue_id" => ctx.catalogue.uuid,
                   "items" => [
                     %{
                       "external_id" => "E-NEW",
                       "sku" => "NEW-1",
                       "name" => "Footstool",
                       "category_id" => ctx.chairs.uuid
                     }
                   ]
                 },
                 %{}
               )

      created = Catalogue.get_item!(id)
      assert pointer(created) == nil
      assert folder_count() == before

      attached = with_folder!(created, ctx.user_uuid)
      assert path(pointer(attached)) == ["Catalogues", "Shop", "Chairs", "Footstool"]
    end
  end
end
