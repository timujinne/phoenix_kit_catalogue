defmodule PhoenixKitCatalogue.MigrationsV5DBTest do
  @moduledoc """
  V5 (external_id uniqueness) against the real database: the chain
  replays as a no-op on an install already at V5, and both indexes land
  unique, partial and per catalogue.
  """

  # async: false — the replay takes table locks on the catalogue tables for
  # the whole sandboxed transaction.
  use PhoenixKitCatalogue.DataCase, async: false

  alias PhoenixKitCatalogue.Migrations

  defp replay_chain! do
    for stmt <- Migrations.up_statements("public"), do: Repo.query!(stmt)
  end

  defp index_definition(name) do
    case Repo.query!(
           "SELECT indexdef FROM pg_indexes WHERE schemaname = 'public' AND indexname = $1",
           [name]
         ) do
      %{rows: [[definition]]} -> definition
      %{rows: []} -> nil
    end
  end

  test "replaying the chain twice is idempotent and stamps the current marker" do
    replay_chain!()
    replay_chain!()

    assert Migrations.migrated_version_runtime(prefix: "public") == Migrations.current_version()
  end

  test "both indexes are unique, partial and keyed on the catalogue" do
    replay_chain!()

    for table <- ~w(items categories) do
      definition = index_definition("phoenix_kit_cat_#{table}_external_id_uniq")

      assert definition, "index for #{table} is missing"
      assert definition =~ "CREATE UNIQUE INDEX"
      assert definition =~ "(catalogue_uuid, "
      assert definition =~ "external_id"
      assert definition =~ "WHERE"
      assert definition =~ "'deleted'"
    end
  end
end
