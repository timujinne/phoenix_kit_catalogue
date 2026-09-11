defmodule PhoenixKitCatalogue.Web.HelpersDataOwnedKeysTest do
  @moduledoc """
  Unit coverage for `PhoenixKitCatalogue.Web.Helpers.data_owned_keys/2` —
  the item/category forms' derivation of `Catalogue.update_item/3` /
  `update_category/3`'s `:data_owned_keys` option. Separate file (not
  `test/web/helpers_test.exs`) because the extension-key cases mutate the
  process-global `PhoenixKit.ModuleRegistry`, so this whole file runs
  `async: false` — see `extensions_test.exs` for the same pattern.
  """

  use ExUnit.Case, async: false

  alias PhoenixKitCatalogue.Test.FakeExtension
  alias PhoenixKitCatalogue.Test.FakeModule
  alias PhoenixKitCatalogue.Web.Helpers

  setup do
    start_supervised!(PhoenixKit.ModuleRegistry)
    :ok
  end

  defp socket(assigns), do: %Phoenix.LiveView.Socket{assigns: assigns}

  describe "multilang enabled" do
    test "includes every language tab's code plus _primary_language" do
      s =
        socket(%{
          multilang_enabled: true,
          language_tabs: [%{code: "en-US"}, %{code: "fr"}, %{code: "es"}]
        })

      keys = Helpers.data_owned_keys(s)

      assert "en-US" in keys
      assert "fr" in keys
      assert "es" in keys
      assert "_primary_language" in keys
      refute "_seo_title" in keys
    end
  end

  describe "multilang disabled" do
    test "includes the flat-data SEO keys instead of any language code" do
      s = socket(%{multilang_enabled: false, language_tabs: []})

      keys = Helpers.data_owned_keys(s)

      assert "_seo_title" in keys
      assert "_seo_description" in keys
      refute "_primary_language" in keys
    end
  end

  describe "extra_keys" do
    test "are folded in alongside the derived keys" do
      s = socket(%{multilang_enabled: false, language_tabs: []})

      keys = Helpers.data_owned_keys(s, ["meta", "featured_image_uuid"])

      assert "meta" in keys
      assert "featured_image_uuid" in keys
      assert "_seo_title" in keys
    end

    test "default to none when omitted" do
      s = socket(%{multilang_enabled: false, language_tabs: []})
      assert Helpers.data_owned_keys(s) == ["_seo_title", "_seo_description"]
    end
  end

  describe "extension keys" do
    test "no registered extension contributes nothing extra" do
      s = socket(%{multilang_enabled: false, language_tabs: []})
      assert Helpers.data_owned_keys(s) == ["_seo_title", "_seo_description"]
    end

    test "an enabled extension's key/0 is included" do
      :ok = PhoenixKit.ModuleRegistry.register(FakeModule)

      on_exit(fn ->
        :persistent_term.put(
          {PhoenixKit, :registered_modules},
          List.delete(PhoenixKit.ModuleRegistry.all_modules(), FakeModule)
        )
      end)

      s = socket(%{multilang_enabled: false, language_tabs: []})
      assert FakeExtension.key() in Helpers.data_owned_keys(s)
    end
  end
end
