defmodule PhoenixKitCatalogue.API.ExecutorTest do
  @moduledoc """
  Catalogue tools driven through core's real `PhoenixKit.API.Executor` with a
  real key: the scope check, the confirmation round trip of `delete_products`
  (which makes core run the handler twice and compare fingerprints), the batch
  confirmation above the threshold, and an idempotency replay. Everything else
  is tested at the handler (`ApiCase`).
  """

  use PhoenixKitCatalogue.DataCase, async: false

  # Runs only against a core that has the API (see test_helper.exs).
  @moduletag :core_api

  import PhoenixKitCatalogue.LiveCase,
    only: [fixture_catalogue: 1, fixture_category: 2, fixture_item: 1]

  import Plug.Conn

  alias PhoenixKit.API.Auth
  alias PhoenixKit.API.Executor
  alias PhoenixKit.API.Keys
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKitCatalogue.Catalogue

  # Core's API is optional for this package: reached by name only.
  @compile {:no_warn_undefined,
            [
              PhoenixKit.API.Auth,
              PhoenixKit.API.Executor,
              PhoenixKit.API.Keys,
              PhoenixKit.API.Keys.Cache,
              PhoenixKit.Cache,
              PhoenixKit.Cache.Registry,
              PhoenixKit.Users.Auth.Scope,
              PhoenixKit.Users.Permissions,
              PhoenixKit.Users.Roles
            ]}

  @registry_key {PhoenixKit, :registered_modules}
  @scopes [
    "catalogue.products:read",
    "catalogue.products:write",
    "catalogue.products:delete",
    "catalogue.categories:delete"
  ]

  setup do
    start_supervised!({PhoenixKit.Cache.Registry, []})
    start_supervised!({PhoenixKit.Cache, name: :api_keys, ttl: :timer.seconds(60)})
    start_supervised!(PhoenixKit.API.Keys.Cache)

    # Core signs confirmation codes with the application's secret; this package
    # has no endpoint of its own to take one from.
    secret = Application.get_env(:phoenix_kit, :secret_key_base)
    Application.put_env(:phoenix_kit, :secret_key_base, String.duplicate("c", 64))

    previous = :persistent_term.get(@registry_key, :unset)
    :persistent_term.put(@registry_key, [PhoenixKitCatalogue])
    admin_enabled = Settings.get_boolean_setting("api_admin_enabled", false)
    catalogue_enabled = Settings.get_boolean_setting("catalogue_enabled", false)
    batch_over = Settings.get_setting("api_confirm_batch_over")

    on_exit(fn ->
      case previous do
        :unset -> :persistent_term.erase(@registry_key)
        modules -> :persistent_term.put(@registry_key, modules)
      end

      if secret,
        do: Application.put_env(:phoenix_kit, :secret_key_base, secret),
        else: Application.delete_env(:phoenix_kit, :secret_key_base)

      Settings.update_boolean_setting("api_admin_enabled", admin_enabled)
      Settings.update_boolean_setting("catalogue_enabled", catalogue_enabled)
      Settings.update_setting("api_confirm_batch_over", batch_over || "50")
    end)

    # The module is enabled and registered BEFORE the key is created: core only
    # offers scopes that an enabled module's tool declares.
    {:ok, _} = Settings.update_boolean_setting("api_admin_enabled", true)
    {:ok, _} = PhoenixKitCatalogue.enable_system()

    %{catalogue: fixture_catalogue(%{name: "Executor Cat"}), user: owner_with(["catalogue"])}
  end

  defp user! do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "api-cat-#{System.unique_integer([:positive])}@example.com",
        "password" => "password123456789",
        "first_name" => "Api",
        "last_name" => "Test"
      })

    user
  end

  # A real user whose role holds the `api` permission and `permissions`.
  defp owner_with(permissions) do
    {:ok, role} = Roles.create_role(%{name: "CatApi#{System.unique_integer([:positive])}"})
    for key <- ["api" | permissions], do: {:ok, _} = Permissions.grant_permission(role.uuid, key)
    user = user!()
    {:ok, _} = Roles.assign_role(user, role.name)
    user
  end

  # A key created by its owner with the owner's own scope, as the settings page does.
  defp issue_token(owner, scopes) do
    scope = Scope.for_user(owner, narrow: false)
    {:ok, _key, token} = Keys.create_key(owner, scope, %{name: "cat api", scopes: scopes})
    token
  end

  # A request from an address no other test uses (the rate-limit counters are shared).
  defp authed(token) do
    n = System.unique_integer([:positive])
    peer = {10, rem(n, 250) + 1, rem(div(n, 250), 250) + 1, rem(div(n, 62_500), 250) + 1}

    :post
    |> Plug.Test.conn("/")
    |> Map.put(:remote_ip, peer)
    |> put_req_header("authorization", "Bearer " <> token)
    |> Auth.call(Auth.init(audience: :admin))
  end

  # Runs a tool through core's real `Executor.call/4`. Answers `{status, decoded_body, conn}`.
  defp call_with(token, name, input) do
    conn = Executor.call(authed(token), :admin, name, input)
    {conn.status, Jason.decode!(conn.resp_body), conn}
  end

  defp item(catalogue, name, extra \\ %{}),
    do: fixture_item(Map.merge(%{name: name, catalogue_uuid: catalogue.uuid}, extra))

  test "a key without the delete scope is refused with 403 and nothing is trashed", %{
    catalogue: catalogue,
    user: user
  } do
    a = item(catalogue, "Alpha")
    token = issue_token(user, ["catalogue.products:read", "catalogue.products:write"])

    assert {403, %{"code" => "forbidden", "context" => %{"required_scope" => required}}, _} =
             call_with(token, "catalogue.delete_products", %{
               "catalogue_id" => catalogue.uuid,
               "refs" => [%{"id" => a.uuid}]
             })

    assert required == "catalogue.products:delete"
    assert Catalogue.get_item!(a.uuid).status == "active"
  end

  describe "delete_products always needs a confirmation code" do
    test "the first call previews and trashes nothing; the code trashes once", %{
      catalogue: catalogue,
      user: user
    } do
      a = item(catalogue, "Alpha")
      b = item(catalogue, "Beta", %{sku: "SKU-B"})
      token = issue_token(user, @scopes)

      input = %{
        "catalogue_id" => catalogue.uuid,
        "refs" => [%{"id" => a.uuid}, %{"sku" => "SKU-B"}]
      }

      assert {200,
              %{
                "executed" => false,
                "status" => "confirmation_required",
                "confirm_token" => code,
                "preview" => %{"summary" => %{"removed" => 2}}
              }, _} = call_with(token, "catalogue.delete_products", input)

      assert Catalogue.get_item!(a.uuid).status == "active"
      assert Catalogue.get_item!(b.uuid).status == "active"

      assert {200, %{"summary" => %{"removed" => 2}}, _} =
               call_with(
                 token,
                 "catalogue.delete_products",
                 Map.put(input, "confirm_token", code)
               )

      assert Catalogue.get_item!(a.uuid).status == "deleted"
      assert Catalogue.get_item!(b.uuid).status == "deleted"

      # A spent code is refused.
      assert {409, %{"context" => %{"reason" => "used"}}, _} =
               call_with(
                 token,
                 "catalogue.delete_products",
                 Map.put(input, "confirm_token", code)
               )
    end

    test "a code is refused when the rows changed since it was issued", %{
      catalogue: catalogue,
      user: user
    } do
      a = item(catalogue, "Alpha")
      token = issue_token(user, @scopes)
      input = %{"catalogue_id" => catalogue.uuid, "refs" => [%{"id" => a.uuid}]}

      assert {200, %{"confirm_token" => code}, _} =
               call_with(token, "catalogue.delete_products", input)

      {:ok, _} = Catalogue.update_item(Catalogue.get_item!(a.uuid), %{status: "inactive"})

      assert {409, %{"context" => %{"reason" => "changed"}}, _} =
               call_with(
                 token,
                 "catalogue.delete_products",
                 Map.put(input, "confirm_token", code)
               )

      assert Catalogue.get_item!(a.uuid).status == "inactive"
    end
  end

  describe "delete_categories" do
    test "a key with the products delete scope only is refused with 403 and nothing is trashed",
         %{catalogue: catalogue, user: user} do
      a = fixture_category(catalogue, %{name: "Alpha"})
      token = issue_token(user, ["catalogue.products:delete", "catalogue.categories:write"])

      assert {403, %{"code" => "forbidden", "context" => %{"required_scope" => required}}, _} =
               call_with(token, "catalogue.delete_categories", %{
                 "catalogue_id" => catalogue.uuid,
                 "refs" => [%{"id" => a.uuid}]
               })

      assert required == "catalogue.categories:delete"
      assert Catalogue.get_category!(a.uuid).status == "active"
    end

    test "the first call previews and trashes nothing; the code trashes once", %{
      catalogue: catalogue,
      user: user
    } do
      a = fixture_category(catalogue, %{name: "Alpha"})
      item(catalogue, "Inside", %{category_uuid: a.uuid})
      token = issue_token(user, @scopes)
      input = %{"catalogue_id" => catalogue.uuid, "refs" => [%{"id" => a.uuid}]}

      assert {200,
              %{
                "executed" => false,
                "status" => "confirmation_required",
                "confirm_token" => code,
                "preview" => %{
                  "requires_confirmation" => true,
                  "summary" => %{"removed" => 1},
                  "rows" => [%{"items" => 1}]
                }
              }, _} = call_with(token, "catalogue.delete_categories", input)

      assert Catalogue.get_category!(a.uuid).status == "active"

      assert {200, %{"summary" => %{"removed" => 1}}, _} =
               call_with(
                 token,
                 "catalogue.delete_categories",
                 Map.put(input, "confirm_token", code)
               )

      assert Catalogue.get_category!(a.uuid).status == "deleted"

      assert {409, %{"context" => %{"reason" => "used"}}, _} =
               call_with(
                 token,
                 "catalogue.delete_categories",
                 Map.put(input, "confirm_token", code)
               )
    end

    test "a code is refused when something was put into the category since it was issued", %{
      catalogue: catalogue,
      user: user
    } do
      a = fixture_category(catalogue, %{name: "Alpha"})
      token = issue_token(user, @scopes)
      input = %{"catalogue_id" => catalogue.uuid, "refs" => [%{"id" => a.uuid}]}

      assert {200, %{"confirm_token" => code}, _} =
               call_with(token, "catalogue.delete_categories", input)

      item(catalogue, "Late", %{category_uuid: a.uuid})

      assert {409, %{"context" => %{"reason" => "changed"}}, _} =
               call_with(
                 token,
                 "catalogue.delete_categories",
                 Map.put(input, "confirm_token", code)
               )

      assert Catalogue.get_category!(a.uuid).status == "active"
    end

    test "dry_run previews, flags the confirmation and creates no code", %{
      catalogue: catalogue,
      user: user
    } do
      a = fixture_category(catalogue, %{name: "Alpha"})
      token = issue_token(user, @scopes)

      assert {200,
              %{
                "executed" => false,
                "dry_run" => true,
                "preview" => %{"requires_confirmation" => true}
              } = body, _} =
               call_with(token, "catalogue.delete_categories", %{
                 "catalogue_id" => catalogue.uuid,
                 "refs" => [%{"id" => a.uuid}],
                 "dry_run" => true
               })

      refute Map.has_key?(body, "confirm_token")
      assert Catalogue.get_category!(a.uuid).status == "active"
    end
  end

  test "a write above core's row threshold is held for confirmation; the code writes it", %{
    catalogue: catalogue,
    user: user
  } do
    {:ok, _} = Settings.update_setting("api_confirm_batch_over", "2")

    items = for n <- 1..3, do: item(catalogue, "Item #{n}", %{sku: "S-#{n}"})

    input = %{
      "catalogue_id" => catalogue.uuid,
      "items" =>
        for(
          i <- items,
          do: %{"ref" => %{"id" => i.uuid}, "changes" => %{"name" => i.name <> "!"}}
        )
    }

    token = issue_token(user, @scopes)

    assert {200,
            %{"executed" => false, "status" => "confirmation_required", "confirm_token" => code},
            _} = call_with(token, "catalogue.update_products", input)

    for i <- items, do: assert(Catalogue.get_item!(i.uuid).name == i.name)

    assert {200, %{"summary" => %{"updated" => 3}}, _} =
             call_with(token, "catalogue.update_products", Map.put(input, "confirm_token", code))

    for i <- items, do: assert(Catalogue.get_item!(i.uuid).name == i.name <> "!")
  end

  test "a batch within the threshold runs at once", %{catalogue: catalogue, user: user} do
    a = item(catalogue, "Alpha")
    token = issue_token(user, @scopes)

    assert {200, %{"summary" => %{"updated" => 1}}, _} =
             call_with(token, "catalogue.update_products", %{
               "catalogue_id" => catalogue.uuid,
               "items" => [%{"ref" => %{"id" => a.uuid}, "changes" => %{"name" => "Alpha 2"}}]
             })

    assert Catalogue.get_item!(a.uuid).name == "Alpha 2"
  end

  test "a repeated idempotency key replays the first answer and writes nothing again", %{
    catalogue: catalogue,
    user: user
  } do
    token = issue_token(user, @scopes)

    input = %{
      "catalogue_id" => catalogue.uuid,
      "idempotency_key" => "idem-cat-key-0001",
      "items" => [%{"sku" => "IDEM-1", "name" => "Once"}]
    }

    assert {200, %{"summary" => %{"created" => 1}} = first, conn} =
             call_with(token, "catalogue.create_products", input)

    refute get_resp_header(conn, "idempotent-replayed") == ["true"]

    assert {200, ^first, replay} = call_with(token, "catalogue.create_products", input)
    assert get_resp_header(replay, "idempotent-replayed") == ["true"]
    assert length(Catalogue.list_items_for_catalogue(catalogue.uuid)) == 1
  end
end
