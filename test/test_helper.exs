# Elixir 1.19's `mix test` no longer auto-loads modules from the
# `:elixirc_paths` test directories at test-helper time — only files
# matching `:test_load_filters` get loaded by the test runner. Our
# support modules (`PhoenixKitCatalogue.Test.Repo`, `Test.Endpoint`,
# etc.) are compiled but not loaded, so explicit `Code.require_file/2`
# calls are needed before `test_helper.exs` references them.
support_dir = Path.expand("support", __DIR__)

[
  "test_repo.ex",
  "test_layouts.ex",
  "test_router.ex",
  "test_endpoint.ex",
  "activity_log_assertions.ex",
  "data_case.ex",
  "live_case.ex",
  "live_database_guard.ex"
]
|> Enum.each(&Code.require_file(&1, support_dir))

# Check if the test database exists
db_name =
  Application.get_env(:phoenix_kit_catalogue, PhoenixKitCatalogue.Test.Repo)[:database] ||
    "phoenix_kit_catalogue_test"

# S014: refuse before anything else touches the database — see
# PhoenixKitCatalogue.Test.LiveDatabaseGuard's moduledoc for why this
# exists alongside (not instead of) the external `pk-test` wrapper.
PhoenixKitCatalogue.Test.LiveDatabaseGuard.check!(db_name)

# `System.cmd/3` raises `:enoent` when the binary isn't on PATH, so probe for
# the client first — a machine without libpq installed must fall through to
# `:try_connect` (and from there to the exclusion notice below), not abort the
# whole run before a single test loads.
psql_listing =
  if System.find_executable("psql"),
    do: System.cmd("psql", ["-lqt"], stderr_to_stdout: true),
    else: {"", 1}

db_check =
  case psql_listing do
    {output, 0} ->
      exists =
        output
        |> String.split("\n")
        |> Enum.any?(fn line ->
          line |> String.split("|") |> List.first("") |> String.trim() == db_name
        end)

      if exists, do: :exists, else: :not_found

    _ ->
      :try_connect
  end

repo_available =
  if db_check == :not_found do
    IO.puts("""
    \n⚠  Test database "#{db_name}" not found — integration tests will be excluded.
       Run `mix test.setup` to create the test database.
    """)

    false
  else
    try do
      {:ok, _} = PhoenixKitCatalogue.Test.Repo.start_link()

      # Build the schema directly from core's versioned migrations.
      # `ensure_current/2` re-applies any newly-shipped Vxxx migrations
      # on every boot — the older
      # `Ecto.Migrator.run([{0, PhoenixKit.Migration}])` pattern was
      # idempotent at the outer Ecto.Migrator layer (version `0`
      # cached in `schema_migrations`), so newly-shipped Vxxx versions
      # silently never applied. The catalogue tables come from core
      # (V87 creates them; V89 / V96 / V97 / V102 / V103 / V108 evolve
      # them; V111 adds the PDF library tables) along with
      # phoenix_kit_settings (V03), the storage family (V20+), and the
      # `uuid-ossp` / `pgcrypto` / `pg_trgm` extensions +
      # `uuid_generate_v7()` function (V40 / V111). No module-owned DDL
      # anywhere.
      PhoenixKit.Migration.ensure_current(PhoenixKitCatalogue.Test.Repo, log: false)

      Ecto.Adapters.SQL.Sandbox.mode(PhoenixKitCatalogue.Test.Repo, :manual)
      true
    rescue
      # Catch only DB-connectivity failure modes — anything else (in
      # particular `UndefinedFunctionError`, which surfaces when the
      # pinned `phoenix_kit` is older than the migration helper this
      # file calls) propagates so version mismatches and code bugs
      # don't masquerade as "DB unavailable" with the full
      # `:integration` suite silently excluded.
      e in [DBConnection.ConnectionError, Postgrex.Error] ->
        IO.puts("""
        \n⚠  Could not connect to test database — integration tests will be excluded.
           Run `mix test.setup` to create the test database.
           Error: #{Exception.message(e)}
        """)

        false
    catch
      :exit, reason ->
        IO.puts("""
        \n⚠  Could not connect to test database — integration tests will be excluded.
           Run `mix test.setup` to create the test database.
           Error: #{inspect(reason)}
        """)

        false
    end
  end

Application.put_env(:phoenix_kit_catalogue, :test_repo_available, repo_available)

# Exclude integration tests when DB is not available
exclude = if repo_available, do: [], else: [:integration]

# Force PhoenixKit's URL prefix cache to an empty string for tests so
# `Paths.index()` etc. produce paths the test router can match. Admin
# paths always get the default locale ("en") prefix, so our router
# scope is `/en/admin/catalogue`.
:persistent_term.put({PhoenixKit.Config, :url_prefix}, "/")

# Start the test Endpoint so Phoenix.LiveViewTest can drive our
# LiveViews via `live/2` with real URLs. Runs with `server: false`, so
# no port is opened.
{:ok, _} = PhoenixKitCatalogue.Test.Endpoint.start_link()

# Start a Phoenix.PubSub registered as `PhoenixKit.PubSub` so the
# catalogue's `Catalogue.PubSub.broadcast/3` calls (fired on every
# mutation) don't crash with "unknown registry". The host app provides
# this in production.
# The entities module's write path broadcasts through
# PhoenixKit.PubSub.Manager (:phoenix_kit_internal_pubsub) — the
# attribute-sets tests drive that path, so start it like entities'
# own suite does.
case PhoenixKit.PubSub.Manager.start_link([]) do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

case Phoenix.PubSub.Supervisor.start_link(name: PhoenixKit.PubSub) do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

# Start a Task.Supervisor registered as `PhoenixKit.TaskSupervisor` so
# ImportLive's supervised import task can start in tests. The host app
# provides this in production.
case Task.Supervisor.start_link(name: PhoenixKit.TaskSupervisor) do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

ExUnit.start(exclude: exclude)
