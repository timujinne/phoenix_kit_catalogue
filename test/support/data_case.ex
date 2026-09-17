defmodule PhoenixKitCatalogue.DataCase do
  @moduledoc """
  Test case for tests requiring database access.
  Uses SQL Sandbox for test isolation.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration

      alias PhoenixKitCatalogue.Test.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import PhoenixKitCatalogue.DataCase
      import PhoenixKitCatalogue.ActivityLogAssertions
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitCatalogue.Test.Repo, as: TestRepo

  # A test tagged with a longer timeout keeps its connection that long
  # too; the sandbox's own limit is two minutes.
  setup tags do
    ownership = if is_integer(tags[:timeout]), do: [ownership_timeout: tags[:timeout]], else: []
    pid = Sandbox.start_owner!(TestRepo, [shared: not tags[:async]] ++ ownership)
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
