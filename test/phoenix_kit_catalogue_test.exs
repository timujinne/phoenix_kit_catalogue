defmodule PhoenixKitCatalogueTest do
  use ExUnit.Case

  # Ensure the module is loaded before `function_exported?/3` checks
  # below — test file order when running the full suite isn't stable,
  # and `function_exported?/3` returns `false` for unloaded modules.
  setup_all do
    Code.ensure_loaded(PhoenixKitCatalogue)
    :ok
  end

  describe "behaviour implementation" do
    test "implements PhoenixKit.Module" do
      behaviours =
        PhoenixKitCatalogue.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert PhoenixKit.Module in behaviours
    end

    test "has @phoenix_kit_module attribute for auto-discovery" do
      attrs = PhoenixKitCatalogue.__info__(:attributes)
      assert Keyword.get(attrs, :phoenix_kit_module) == [true]
    end
  end

  describe "required callbacks" do
    test "module_key/0 returns catalogue" do
      assert PhoenixKitCatalogue.module_key() == "catalogue"
    end

    test "module_name/0 returns Catalogue" do
      assert PhoenixKitCatalogue.module_name() == "Catalogue"
    end

    test "enabled?/0 returns a boolean" do
      assert is_boolean(PhoenixKitCatalogue.enabled?())
    end

    test "enable_system/0 is exported" do
      assert function_exported?(PhoenixKitCatalogue, :enable_system, 0)
    end

    test "disable_system/0 is exported" do
      assert function_exported?(PhoenixKitCatalogue, :disable_system, 0)
    end
  end

  describe "permission_metadata/0" do
    test "returns a map with required fields" do
      meta = PhoenixKitCatalogue.permission_metadata()
      assert %{key: key, label: label, icon: icon, description: desc} = meta
      assert is_binary(key)
      assert is_binary(label)
      assert is_binary(icon)
      assert is_binary(desc)
    end

    test "key matches module_key" do
      meta = PhoenixKitCatalogue.permission_metadata()
      assert meta.key == PhoenixKitCatalogue.module_key()
    end

    test "icon uses hero- prefix" do
      meta = PhoenixKitCatalogue.permission_metadata()
      assert String.starts_with?(meta.icon, "hero-")
    end
  end

  describe "admin_tabs/0" do
    test "returns a list of Tab structs" do
      tabs = PhoenixKitCatalogue.admin_tabs()
      assert is_list(tabs)
      assert tabs != []
    end

    test "main tab has required fields" do
      [tab | _] = PhoenixKitCatalogue.admin_tabs()
      assert tab.id == :admin_catalogue
      assert tab.label == "Catalogue"
      assert is_binary(tab.path)
      assert tab.level == :admin
      assert tab.permission == PhoenixKitCatalogue.module_key()
      assert tab.group == :admin_modules
    end

    test "main tab has live_view for route generation" do
      [tab | _] = PhoenixKitCatalogue.admin_tabs()
      assert {PhoenixKitCatalogue.Web.CataloguesLive, :index} = tab.live_view
    end

    test "all tabs have permission matching module_key" do
      for tab <- PhoenixKitCatalogue.admin_tabs() do
        assert tab.permission == PhoenixKitCatalogue.module_key()
      end
    end

    test "all subtabs reference parent" do
      [main | subtabs] = PhoenixKitCatalogue.admin_tabs()

      for tab <- subtabs do
        assert tab.parent == main.id
      end
    end

    test "includes events tab with correct properties" do
      tabs = PhoenixKitCatalogue.admin_tabs()
      events_tab = Enum.find(tabs, &(&1.id == :admin_catalogue_events))

      assert events_tab != nil
      assert events_tab.label == "Events"
      assert events_tab.path == "catalogue/events"
      assert events_tab.icon == "hero-clock"
      assert events_tab.parent == :admin_catalogue
      assert events_tab.live_view == {PhoenixKitCatalogue.Web.EventsLive, :index}
    end
  end

  # Regression: parent "Catalogue" used to be the only tab that
  # highlighted on catalogue detail/new/edit pages because the hidden
  # subtabs with literal `:uuid` segments never matched real URLs and
  # the visible "Catalogues" subtab was `match: :exact`. The visible
  # subtab now uses a regex that matches every catalogue-owned URL
  # except the sibling subtab paths.
  describe "Catalogues subtab path matching" do
    alias PhoenixKit.Dashboard.Tab

    setup do
      tabs = PhoenixKitCatalogue.admin_tabs()
      list_tab = Enum.find(tabs, &(&1.id == :admin_catalogue_list))

      # The registry calls `Tab.resolve_path/2` before storing tabs.
      # Tests must do the same so `matches_path?/2` sees the
      # `/admin/...` prefix production uses.
      {:ok, tab: Tab.resolve_path(list_tab, :admin)}
    end

    test "matches the bare catalogues index", %{tab: tab} do
      assert Tab.matches_path?(tab, "/admin/catalogue")
    end

    test "matches the new-catalogue form", %{tab: tab} do
      assert Tab.matches_path?(tab, "/admin/catalogue/new")
    end

    test "matches a catalogue detail page with an actual UUID", %{tab: tab} do
      assert Tab.matches_path?(
               tab,
               "/admin/catalogue/019d1330-c5e0-7caf-b84b-91a4418f67f2"
             )
    end

    test "matches a catalogue edit page with an actual UUID", %{tab: tab} do
      assert Tab.matches_path?(
               tab,
               "/admin/catalogue/019d1330-c5e0-7caf-b84b-91a4418f67f2/edit"
             )
    end

    test "matches nested item-new and category-new pages", %{tab: tab} do
      assert Tab.matches_path?(
               tab,
               "/admin/catalogue/019d1330-c5e0-7caf-b84b-91a4418f67f2/items/new"
             )

      assert Tab.matches_path?(
               tab,
               "/admin/catalogue/019d1330-c5e0-7caf-b84b-91a4418f67f2/categories/new"
             )
    end

    test "matches item-edit and category-edit pages", %{tab: tab} do
      assert Tab.matches_path?(
               tab,
               "/admin/catalogue/items/019d1330-c5e0-7caf-b84b-91a4418f67f2/edit"
             )

      assert Tab.matches_path?(
               tab,
               "/admin/catalogue/categories/019d1330-c5e0-7caf-b84b-91a4418f67f2/edit"
             )
    end

    test "does NOT match manufacturer paths (belongs to Manufacturers subtab)", %{tab: tab} do
      refute Tab.matches_path?(tab, "/admin/catalogue/manufacturers")
      refute Tab.matches_path?(tab, "/admin/catalogue/manufacturers/new")

      refute Tab.matches_path?(
               tab,
               "/admin/catalogue/manufacturers/019d1330-c5e0-7caf-b84b-91a4418f67f2/edit"
             )
    end

    test "does NOT match supplier paths (belongs to Suppliers subtab)", %{tab: tab} do
      refute Tab.matches_path?(tab, "/admin/catalogue/suppliers")
      refute Tab.matches_path?(tab, "/admin/catalogue/suppliers/new")

      refute Tab.matches_path?(
               tab,
               "/admin/catalogue/suppliers/019d1330-c5e0-7caf-b84b-91a4418f67f2/edit"
             )
    end

    test "does NOT match import or events paths (belong to their own subtabs)", %{tab: tab} do
      refute Tab.matches_path?(tab, "/admin/catalogue/import")
      refute Tab.matches_path?(tab, "/admin/catalogue/events")
    end

    test "does NOT match completely unrelated paths", %{tab: tab} do
      refute Tab.matches_path?(tab, "/admin/users")
      refute Tab.matches_path?(tab, "/admin")
      refute Tab.matches_path?(tab, "/some-other-route")
    end
  end

  describe "version/0" do
    test "returns version string" do
      # Assert the shape, not a pinned literal — the version is bumped on
      # every release and a hardcoded value goes stale immediately.
      assert PhoenixKitCatalogue.version() =~ ~r/^\d+\.\d+\.\d+/
    end
  end

  describe "optional callbacks" do
    test "get_config/0 returns a map" do
      config = PhoenixKitCatalogue.get_config()
      assert is_map(config)
      assert Map.has_key?(config, :enabled)
    end

    test "settings_tabs/0 returns empty list" do
      assert PhoenixKitCatalogue.settings_tabs() == []
    end

    test "user_dashboard_tabs/0 returns empty list" do
      assert PhoenixKitCatalogue.user_dashboard_tabs() == []
    end

    test "children/0 returns empty list" do
      assert PhoenixKitCatalogue.children() == []
    end

    test "route_module/0 returns nil" do
      assert PhoenixKitCatalogue.route_module() == nil
    end
  end
end
