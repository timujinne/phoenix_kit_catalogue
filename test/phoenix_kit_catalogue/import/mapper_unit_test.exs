defmodule PhoenixKitCatalogue.Import.MapperUnitTest do
  use ExUnit.Case, async: true
  alias PhoenixKitCatalogue.Import.Mapper

  test "maps known PRO100 unit labels to canonical units" do
    assert Mapper.resolve_pro100_unit("pc") == {:ok, "piece"}
    assert Mapper.resolve_pro100_unit("m²") == {:ok, "m2"}
    assert Mapper.resolve_pro100_unit("m") == {:ok, "running_meter"}
    # m³ gained an alias with the service-unit set (§4.4) — it is no longer
    # the "no equivalent" example.
    assert Mapper.resolve_pro100_unit("m³") == {:ok, "m3"}
  end

  test "returns :unknown for unmappable units instead of defaulting to piece" do
    assert Mapper.resolve_pro100_unit("gross") == :unknown
    assert Mapper.resolve_pro100_unit(nil) == :unknown
    assert Mapper.resolve_pro100_unit("") == :unknown
  end
end
