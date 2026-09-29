defmodule PhoenixKitCatalogue.MigrationsV4DBTest do
  @moduledoc """
  V4 (item type) against the real database: replaying the whole chain on an
  install already at V4 is a no-op, the columns land with the declared
  shape, and the CHECKs hold.
  """

  # async: false — the replay takes table locks on the catalogue tables
  # for the whole sandboxed transaction, and the last test aborts its
  # transaction on purpose.
  use PhoenixKitCatalogue.DataCase, async: false

  alias PhoenixKitCatalogue.Migrations

  defp replay_chain! do
    for stmt <- Migrations.up_statements("public"), do: Repo.query!(stmt)
  end

  defp column(table, name) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT data_type, character_maximum_length, is_nullable, column_default
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2
        """,
        [table, name]
      )

    rows
  end

  defp constraint_count(name) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM pg_constraint WHERE conname = $1", [name])

    count
  end

  test "replaying the chain twice is idempotent and stamps pkc_schema:4" do
    replay_chain!()
    replay_chain!()

    assert constraint_count("phoenix_kit_cat_catalogues_item_type_check") == 1
    assert constraint_count("phoenix_kit_cat_items_item_type_check") == 1
    assert Migrations.migrated_version_runtime(prefix: "public") == 4
  end

  test "the columns have the declared shape" do
    replay_chain!()

    assert [["character varying", 20, "NO", default]] =
             column("phoenix_kit_cat_catalogues", "item_type")

    assert default =~ "'goods'"

    assert [["character varying", 20, "YES", nil]] = column("phoenix_kit_cat_items", "item_type")
  end

  test "existing rows read as goods catalogues and inheriting items" do
    {:ok, catalogue} = PhoenixKitCatalogue.Catalogue.create_catalogue(%{name: "V4 rows"})

    {:ok, item} =
      PhoenixKitCatalogue.Catalogue.create_item(%{
        name: "V4 item",
        catalogue_uuid: catalogue.uuid
      })

    %{rows: [[catalogue_type]]} =
      Repo.query!("SELECT item_type FROM phoenix_kit_cat_catalogues WHERE uuid::text = $1", [
        catalogue.uuid
      ])

    %{rows: [[item_type]]} =
      Repo.query!("SELECT item_type FROM phoenix_kit_cat_items WHERE uuid::text = $1", [item.uuid])

    assert catalogue_type == "goods"
    assert is_nil(item_type)
  end

  test "the item CHECK refuses a type outside goods/service" do
    {:ok, catalogue} = PhoenixKitCatalogue.Catalogue.create_catalogue(%{name: "V4 check"})

    assert_raise Postgrex.Error, ~r/phoenix_kit_cat_items_item_type_check/, fn ->
      Repo.query!(
        """
        INSERT INTO phoenix_kit_cat_items (name, catalogue_uuid, item_type, inserted_at, updated_at)
        VALUES ('bad', $1::text::uuid, 'widget', now(), now())
        """,
        [catalogue.uuid]
      )
    end
  end

  test "the catalogue CHECK refuses a type outside goods/service" do
    {:ok, catalogue} = PhoenixKitCatalogue.Catalogue.create_catalogue(%{name: "V4 check cat"})

    assert_raise Postgrex.Error, ~r/phoenix_kit_cat_catalogues_item_type_check/, fn ->
      Repo.query!(
        "UPDATE phoenix_kit_cat_catalogues SET item_type = 'widget' WHERE uuid::text = $1",
        [catalogue.uuid]
      )
    end
  end
end
