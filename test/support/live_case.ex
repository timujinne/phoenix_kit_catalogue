defmodule PhoenixKitCatalogue.LiveCase do
  @moduledoc """
  Test case for LiveView tests. Wires up the test Endpoint, imports
  `Phoenix.LiveViewTest` helpers, and sets up an Ecto SQL sandbox
  connection.

  Tests using this case are tagged `:integration` automatically and
  get excluded when the test DB isn't available, matching the rest of
  the suite.

  ## Example

      defmodule PhoenixKitCatalogue.Web.CatalogueFormLiveTest do
        use PhoenixKitCatalogue.LiveCase

        test "renders", %{conn: conn} do
          {:ok, view, html} = live(conn, ~p"/admin/catalogue/new")
          assert html =~ "New Catalogue"
        end
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration
      @endpoint PhoenixKitCatalogue.Test.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import PhoenixKitCatalogue.LiveCase
      import PhoenixKitCatalogue.ActivityLogAssertions
    end
  end

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitCatalogue.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})

    {:ok, conn: conn, scope: build_admin_scope()}
  end

  @doc """
  Builds a minimal authenticated admin scope for tests that assert on the
  *actor* of an activity-log entry. Inserts a real `phoenix_kit_users` row
  (cheap — a pre-computed dummy hash, no bcrypt) so the activity log's
  `actor_uuid` resolves, and wraps it in the `%{user: %{uuid: ...}}` shape
  `PhoenixKitCatalogue.Web.Helpers.actor_uuid/1` reads. Pipe it onto the
  conn with `with_scope/2` before `live/2`.
  """
  def build_admin_scope do
    uuid = UUIDv7.generate()
    email = "lv-test-#{System.unique_integer([:positive])}@example.com"

    SQL.query!(
      TestRepo,
      """
      INSERT INTO phoenix_kit_users
        (uuid, email, hashed_password, account_type, is_active, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'person', true, NOW(), NOW())
      """,
      [
        Ecto.UUID.dump!(uuid),
        email,
        "$2b$12$0000000000000000000000000000000000000000000000000000."
      ]
    )

    %{user: %{uuid: uuid}}
  end

  @doc """
  Stashes a scope's user UUID into the conn session so the test
  live_session's `:assign_test_current_user` on_mount assigns
  `phoenix_kit_current_user` — letting the LV resolve a non-nil
  `actor_uuid` for activity logging. Use as `conn |> with_scope(scope) |>
  live(path)`.
  """
  def with_scope(conn, %{user: %{uuid: uuid}}) do
    Plug.Conn.put_session(conn, "pk_current_user_uuid", uuid)
  end

  @doc """
  on_mount callback wired into the test live_session. Assigns
  `phoenix_kit_current_user` from the session when `with_scope/2` set it;
  otherwise leaves assigns untouched so tests that don't opt in behave
  exactly as before (anonymous actor).
  """
  def on_mount(:assign_test_current_user, _params, session, socket) do
    case session do
      %{"pk_current_user_uuid" => uuid} when is_binary(uuid) ->
        {:cont, Phoenix.Component.assign(socket, :phoenix_kit_current_user, %{uuid: uuid})}

      _ ->
        {:cont, socket}
    end
  end

  @doc """
  Shortcut: insert a minimal catalogue for tests that just need a
  container and don't care about the exact markup percentage.
  """
  def fixture_catalogue(attrs \\ %{}) do
    {:ok, catalogue} =
      PhoenixKitCatalogue.Catalogue.create_catalogue(
        Map.merge(%{name: "Test Catalogue #{System.unique_integer([:positive])}"}, attrs)
      )

    catalogue
  end

  def fixture_category(catalogue, attrs \\ %{}) do
    {:ok, category} =
      PhoenixKitCatalogue.Catalogue.create_category(
        Map.merge(
          %{
            name: "Test Category #{System.unique_integer([:positive])}",
            catalogue_uuid: catalogue.uuid
          },
          attrs
        )
      )

    category
  end

  def fixture_item(attrs \\ %{}) do
    attrs = ensure_item_catalogue(attrs)

    {:ok, item} =
      PhoenixKitCatalogue.Catalogue.create_item(
        Map.merge(%{name: "Test Item #{System.unique_integer([:positive])}"}, attrs)
      )

    item
  end

  def fixture_manufacturer(attrs \\ %{}) do
    {:ok, manufacturer} =
      PhoenixKitCatalogue.Catalogue.create_manufacturer(
        Map.merge(%{name: "Test Manufacturer #{System.unique_integer([:positive])}"}, attrs)
      )

    manufacturer
  end

  def fixture_supplier(attrs \\ %{}) do
    {:ok, supplier} =
      PhoenixKitCatalogue.Catalogue.create_supplier(
        Map.merge(%{name: "Test Supplier #{System.unique_integer([:positive])}"}, attrs)
      )

    supplier
  end

  defp ensure_item_catalogue(attrs) do
    cond do
      Map.has_key?(attrs, :catalogue_uuid) -> attrs
      Map.has_key?(attrs, :category_uuid) -> attrs
      true -> Map.put(attrs, :catalogue_uuid, fixture_catalogue().uuid)
    end
  end
end
