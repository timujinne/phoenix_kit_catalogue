defmodule PhoenixKitCatalogue.Web.TableConfigExtensionsTest do
  @moduledoc """
  `PhoenixKitCatalogue.Web.TableConfig`'s `:detail_items` /
  `:detail_categories` scopes folding in enabled extensions' contributed
  columns (`PhoenixKitCatalogue.Extensions.columns/1`). Mutates the
  process-global `PhoenixKit.ModuleRegistry`, so `async: false` — same
  pattern as `PhoenixKitCatalogue.ExtensionsTest`.
  """
  use ExUnit.Case, async: false

  alias PhoenixKitCatalogue.Test.FakeModule
  alias PhoenixKitCatalogue.Web.TableConfig, as: TC

  setup do
    start_supervised!(PhoenixKit.ModuleRegistry)
    :ok
  end

  test "with no registered extension, columns/1 is unaffected" do
    refute Enum.any?(TC.columns(:detail_items), &(&1.id == "fake:status"))
    refute Enum.any?(TC.columns(:detail_categories), &(&1.id == "fake:status"))
    assert TC.extension_columns(:detail_items) == %{}
  end

  describe "with FakeExtension registered" do
    setup do
      :ok = PhoenixKit.ModuleRegistry.register(FakeModule)

      on_exit(fn ->
        :persistent_term.put(
          {PhoenixKit, :registered_modules},
          List.delete(PhoenixKit.ModuleRegistry.all_modules(), FakeModule)
        )
      end)

      :ok
    end

    test "its namespaced column appears in columns/1, off by default" do
      for scope <- [:detail_items, :detail_categories] do
        col = TC.column_map(scope)["fake:status"]
        assert col, "expected \"fake:status\" to appear in #{scope}"
        assert col.managed?
        refute col.default?
        refute "fake:status" in TC.default_columns(scope)
        assert is_function(col.render, 1)
      end
    end

    test "it appears among managed_columns/1 — what the Columns modal offers" do
      assert Enum.any?(TC.managed_columns(:detail_items), &(&1.id == "fake:status"))
      assert Enum.any?(TC.managed_columns(:detail_categories), &(&1.id == "fake:status"))
    end

    test "validate_columns/2 accepts the namespaced id once selected" do
      assert TC.validate_columns(:detail_items, ["sku", "fake:status"]) == [
               "sku",
               "fake:status"
             ]
    end

    test "extension_columns/1 exposes it keyed by id, ready for cell dispatch" do
      map = TC.extension_columns(:detail_items)
      assert %{"fake:status" => %{render: render}} = map
      assert is_function(render, 1)
    end

    test "does not leak into unrelated scopes" do
      refute Enum.any?(TC.columns(:catalogues), &(&1.id == "fake:status"))
      refute Enum.any?(TC.columns(:suppliers), &(&1.id == "fake:status"))
    end
  end
end
