defmodule PhoenixKitCatalogue.JsSourcesTest do
  @moduledoc """
  The hooks the admin templates name must exist in the file `js_sources/0`
  ships — rename either half and the browser logs `unknown hook found`
  while every other gate stays green (quality sweep, 2026-09-13).
  """
  use ExUnit.Case, async: true

  test "js_sources/0 names an existing file that registers every hook the templates use" do
    sources = PhoenixKitCatalogue.js_sources()
    assert sources != []

    js =
      sources
      |> Enum.map(fn %{app: app, file: rel} -> app |> :code.priv_dir() |> Path.join(rel) end)
      |> Enum.map_join("\n", fn path ->
        assert File.exists?(path), "js_sources/0 names a missing file: #{path}"
        File.read!(path)
      end)

    lib_hooks =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.flat_map(&Regex.scan(~r/phx-hook=(?:"|\{")([A-Z][A-Za-z]+)"/, File.read!(&1)))
      |> Enum.map(fn [_, name] -> name end)
      |> Enum.uniq()
      |> Enum.sort()

    ours = Enum.filter(lib_hooks, &(&1 in ["CatalogueTreeDnD", "ViewPref"]))
    assert ours == ["CatalogueTreeDnD", "ViewPref"]

    for name <- ours do
      assert js =~ "PhoenixKitCatalogueHooks.#{name} = ",
             "#{name} is not registered in js_sources"
    end
  end
end
