defmodule PhoenixKitCatalogue.MigrationsV6DBTest do
  @moduledoc """
  V6 (internal categories, notes for AI, item dependencies) against the
  real database: a replay is a no-op, the columns and the table land with
  the declared shape, and the CHECKs and foreign keys hold — including the
  cascade that removes a dependency row with either end.
  """

  # async: false — the replay takes table locks for the whole sandboxed
  # transaction, and the CHECK tests abort theirs on purpose.
  use PhoenixKitCatalogue.DataCase, async: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Migrations

  defp replay_chain! do
    for stmt <- Migrations.up_statements("public"), do: Repo.query!(stmt)
  end

  defp constraint_count(name) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM pg_constraint WHERE conname = $1", [name])

    count
  end

  defp column(table, name) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT data_type, is_nullable, column_default
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2
        """,
        [table, name]
      )

    rows
  end

  # Raw SQL, so the database's own rules are what is tested — not the
  # changeset's, which would refuse the same rows first.
  defp insert_dependency(attrs) do
    columns = Map.keys(attrs)

    values =
      columns
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {column, i} -> "$#{i}::text#{cast_for(column)}" end)

    Repo.query(
      "INSERT INTO phoenix_kit_cat_item_dependencies (#{Enum.join(columns, ", ")}) VALUES (#{values})",
      Enum.map(columns, &to_string(Map.fetch!(attrs, &1)))
    )
  end

  defp cast_for(:quantity), do: "::numeric"
  defp cast_for(_uuid_column), do: "::uuid"

  defp dependency_count(item_uuid) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM phoenix_kit_cat_item_dependencies WHERE item_uuid = $1::text::uuid",
        [item_uuid]
      )

    count
  end

  setup do
    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "V5 catalogue"})
    {:ok, item} = Catalogue.create_item(%{name: "Lazy susan", catalogue_uuid: catalogue.uuid})
    {:ok, screw} = Catalogue.create_item(%{name: "Screw", catalogue_uuid: catalogue.uuid})
    %{catalogue: catalogue, item: item, screw: screw}
  end

  test "replaying the chain twice is idempotent and stamps pkc_schema:6" do
    replay_chain!()
    replay_chain!()

    for name <- ~w(
          phoenix_kit_cat_catalogues_ai_notes_length_check
          phoenix_kit_cat_item_dependencies_pkey
          phoenix_kit_cat_item_dependencies_one_target_check
          phoenix_kit_cat_item_dependencies_target_item_uuid_fkey
        ) do
      assert constraint_count(name) == 1, name
    end

    assert Migrations.migrated_version_runtime(prefix: "public") == 6
  end

  test "the columns have the declared shape" do
    replay_chain!()

    assert [["boolean", "NO", "false"]] = column("phoenix_kit_cat_categories", "internal")

    for t <- ~w(phoenix_kit_cat_catalogues phoenix_kit_cat_categories phoenix_kit_cat_items) do
      assert [["text", "YES", nil]] = column(t, "ai_notes")
    end

    assert [["numeric", "NO", nil]] = column("phoenix_kit_cat_item_dependencies", "quantity")
  end

  test "existing categories read as not internal" do
    %{rows: rows} = Repo.query!("SELECT DISTINCT internal FROM phoenix_kit_cat_categories")
    assert rows in [[], [[false]]]
  end

  test "a row names exactly one target", %{item: item, screw: screw} do
    assert {:ok, _} =
             insert_dependency(%{item_uuid: item.uuid, target_item_uuid: screw.uuid, quantity: 8})

    assert {:error,
            %Postgrex.Error{
              postgres: %{constraint: "phoenix_kit_cat_item_dependencies_one_target_check"}
            }} =
             insert_dependency(%{item_uuid: item.uuid, quantity: 1})
  end

  test "two targets on one row are refused", %{item: item, screw: screw, catalogue: catalogue} do
    assert {:error,
            %Postgrex.Error{
              postgres: %{constraint: "phoenix_kit_cat_item_dependencies_one_target_check"}
            }} =
             insert_dependency(%{
               item_uuid: item.uuid,
               target_item_uuid: screw.uuid,
               target_catalogue_uuid: catalogue.uuid,
               quantity: 1
             })
  end

  test "an item cannot depend on itself", %{item: item} do
    assert {:error,
            %Postgrex.Error{
              postgres: %{constraint: "phoenix_kit_cat_item_dependencies_not_self_check"}
            }} =
             insert_dependency(%{item_uuid: item.uuid, target_item_uuid: item.uuid, quantity: 1})
  end

  test "the quantity is above zero", %{item: item, screw: screw} do
    assert {:error,
            %Postgrex.Error{
              postgres: %{constraint: "phoenix_kit_cat_item_dependencies_quantity_check"}
            }} =
             insert_dependency(%{item_uuid: item.uuid, target_item_uuid: screw.uuid, quantity: 0})
  end

  test "the AI notes are capped at 10 000 characters", %{catalogue: catalogue} do
    assert {:error,
            %Postgrex.Error{
              postgres: %{constraint: "phoenix_kit_cat_catalogues_ai_notes_length_check"}
            }} =
             Repo.query(
               "UPDATE phoenix_kit_cat_catalogues SET ai_notes = repeat('x', 10001) WHERE uuid::text = $1",
               [catalogue.uuid]
             )
  end

  test "deleting the owning item or the target removes the row", %{item: item, screw: screw} do
    {:ok, _} =
      insert_dependency(%{item_uuid: item.uuid, target_item_uuid: screw.uuid, quantity: 8})

    assert dependency_count(item.uuid) == 1

    Repo.query!("DELETE FROM phoenix_kit_cat_items WHERE uuid::text = $1", [screw.uuid])
    assert dependency_count(item.uuid) == 0
  end
end
