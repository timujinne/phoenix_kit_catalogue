defmodule PhoenixKitCatalogue.Web.ViewConfigPrefsTest do
  @moduledoc """
  A user's catalogue table choices live in core's per-user view
  preferences: one row per scope and one module-wide row, a save writing
  only what changed, and V3 of this module's chain bringing the choices
  kept in `custom_fields` across once.
  """
  use PhoenixKitCatalogue.DataCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.{ViewPref, ViewPrefs}
  alias PhoenixKitCatalogue.Migrations
  alias PhoenixKitCatalogue.Web.ViewConfig, as: VC

  defp user! do
    uuid = UUIDv7.generate()

    Repo.query!(
      """
      INSERT INTO phoenix_kit_users
        (uuid, email, hashed_password, account_type, is_active, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'person', true, NOW(), NOW())
      """,
      [
        Ecto.UUID.dump!(uuid),
        "view-config-#{System.unique_integer([:positive])}@example.com",
        "$2b$12$0000000000000000000000000000000000000000000000000000."
      ]
    )

    Auth.get_user!(uuid)
  end

  test "a scope's choices round-trip, and a save writes only what changed" do
    user = user!()
    cfg = VC.load(user, :suppliers)
    assert cfg == VC.defaults(:suppliers)

    {:ok, _} = VC.save(user, :suppliers, %{cfg | columns: ["status"]}, cfg)
    assert ViewPrefs.get(user, "catalogue.suppliers") == %{"columns" => ["status"]}

    # Another tab changes the sort; this tab's stale cfg changes only a filter.
    {:ok, _} = ViewPrefs.put(user, "catalogue.suppliers", %{"sort_by" => "website"})
    {:ok, _} = VC.save(user, :suppliers, %{cfg | filters: %{"status" => "active"}}, cfg)

    loaded = VC.load(user, :suppliers)
    assert loaded.columns == ["status"]
    assert loaded.sort_by == "website"
    assert loaded.filters == %{"status" => "active"}
  end

  test "a global-sort scope keeps no per-user sort, and reset follows the defaults" do
    user = user!()
    cfg = VC.load(user, :catalogues)
    {:ok, _} = VC.save(user, :catalogues, %{cfg | sort_by: "name", columns: []}, cfg)

    assert ViewPrefs.get(user, "catalogue.catalogues") == %{"columns" => []}
    assert VC.load(user, :catalogues).columns == []

    {:ok, _} = VC.reset_columns(user, :catalogues)
    assert VC.load(user, :catalogues).columns == VC.defaults(:catalogues).columns
  end

  test "the view and the selector are module-wide" do
    user = user!()
    {:ok, _} = VC.save_view(user, "card")
    {:ok, _} = VC.save_selector(user, %{hidden: ["sku"]})
    {:ok, _} = VC.save_selector(user, %{view: "table"})

    assert VC.load_view(user) == "card"
    assert VC.load(user, :suppliers).view == "card"
    assert VC.load_selector(user) == %{view: "table", hidden: ["sku"]}
    assert VC.load_view(nil) == "comfy"
    assert VC.save_view(user, "bogus") == {:error, :invalid_view}
  end

  describe "V3" do
    defp v3_statement do
      Enum.find(Migrations.up_statements("public"), &(&1 =~ "phoenix_kit_user_view_prefs"))
    end

    defp copied?(done?) do
      Repo.query!("DELETE FROM phoenix_kit_settings WHERE key = 'catalogue_view_prefs_copied_at'")

      if done?,
        do:
          Repo.query!(
            "INSERT INTO phoenix_kit_settings (key, value, module) VALUES ('catalogue_view_prefs_copied_at', 'x', 'catalogue')"
          )
    end

    defp legacy!(user, configs) do
      {:ok, user} =
        Auth.update_user_custom_fields(
          user,
          Map.put(user.custom_fields || %{}, "catalogue_view_configs", configs),
          ensure_definitions: false,
          broadcast: false
        )

      user
    end

    test "copies each scope and the module-wide choices once; a row already in core wins" do
      a =
        legacy!(user!(), %{
          "suppliers" => %{"columns" => ["status"], "sort_by" => "name", "sort_dir" => "desc"},
          "catalogues" => %{"columns" => [], "filters" => %{"status" => "active"}},
          "__view__" => "table",
          "__selector__" => %{"hidden" => ["sku"], "view" => "card"},
          # Not a scope of this module.
          "typo" => %{"columns" => ["status"]}
        })

      b = legacy!(user!(), %{"suppliers" => %{"columns" => ["website"]}})
      # A malformed store is skipped, not an error that aborts the migration.
      odd = legacy!(user!(), "not a map")
      # A key too long for a view key is skipped rather than aborting the copy.
      long = legacy!(user!(), %{String.duplicate("a", 300) => %{"columns" => ["x"]}})
      {:ok, _} = ViewPrefs.put(b, "catalogue.suppliers", %{"columns" => ["status"]})

      copied?(false)
      Repo.query!(v3_statement())

      assert ViewPrefs.get(a, "catalogue.suppliers") ==
               %{"columns" => ["status"], "sort_by" => "name", "sort_dir" => "desc"}

      assert ViewPrefs.get(a, "catalogue.catalogues") ==
               %{"columns" => [], "filters" => %{"status" => "active"}}

      assert ViewPrefs.get(a, "catalogue") ==
               %{"view" => "table", "selector_view" => "card", "selector_hidden" => ["sku"]}

      assert VC.load_selector(a) == %{view: "card", hidden: ["sku"]}
      assert ViewPrefs.get(a, "catalogue.typo") == %{}

      assert ViewPrefs.get(a, "catalogue.__selector__") == %{}
      assert ViewPrefs.get(b, "catalogue.suppliers") == %{"columns" => ["status"]}
      assert ViewPrefs.get(odd, "catalogue") == %{}

      assert Repo.aggregate(
               from(p in ViewPref, where: p.user_uuid == ^long.uuid),
               :count
             ) == 0
    end

    test "a field chosen in core before the copy wins; the legacy fields it lacks are added" do
      user =
        legacy!(user!(), %{
          "suppliers" => %{"columns" => ["website"], "sort_by" => "name"},
          "__view__" => "table",
          "__selector__" => %{"hidden" => ["sku"]}
        })

      # Between the deploy and the migration, the user changed the view and
      # a table's columns in core.
      {:ok, _} = VC.save_view(user, "card")
      {:ok, _} = ViewPrefs.put(user, "catalogue.suppliers", %{"columns" => ["status"]})

      copied?(false)
      Repo.query!(v3_statement())

      assert ViewPrefs.get(user, "catalogue") == %{"view" => "card", "selector_hidden" => ["sku"]}

      assert ViewPrefs.get(user, "catalogue.suppliers") ==
               %{"columns" => ["status"], "sort_by" => "name"}
    end

    test "runs once: after the copy, a replay changes nothing" do
      user = legacy!(user!(), %{"suppliers" => %{"columns" => ["status"]}})
      copied?(false)
      Repo.query!(v3_statement())
      {:ok, _} = VC.reset_columns(user, :suppliers)

      Repo.query!(v3_statement())
      assert ViewPrefs.get(user, "catalogue.suppliers") == %{}
    end

    test "a copy the chain skipped is made by a later replay of the chain" do
      # The chain's version marker says V3, but no copy ever ran (core's
      # table was not there yet when it did).
      user = legacy!(user!(), %{"suppliers" => %{"columns" => ["status"]}})
      Repo.query!("COMMENT ON TABLE public.phoenix_kit_cat_catalogues IS 'pkc_schema:3'")
      copied?(false)

      Repo.query!(v3_statement())
      assert ViewPrefs.get(user, "catalogue.suppliers") == %{"columns" => ["status"]}
    end
  end
end
