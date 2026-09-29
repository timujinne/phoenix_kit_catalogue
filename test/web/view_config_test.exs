defmodule PhoenixKitCatalogue.Web.ViewConfigTest do
  use ExUnit.Case, async: true
  alias PhoenixKitCatalogue.Web.ViewConfig, as: VC

  test "defaults shape" do
    assert %{
             columns: ["folder", "items", "status", "updated"],
             sort_by: "position",
             sort_dir: :asc,
             filters: %{},
             view: "comfy"
           } = VC.defaults(:catalogues)
  end

  test "normalize falls back on empty/invalid, keeps valid" do
    assert VC.normalize(:catalogues, %{}) == VC.defaults(:catalogues)

    got =
      VC.normalize(:catalogues, %{
        "columns" => ["items", "bogus"],
        "sort_dir" => "desc",
        "view" => "card"
      })

    assert got.columns == ["items"]
    assert got.sort_dir == :desc
    assert got.view == "card"
  end

  test "normalize keeps an empty column list — every optional column hidden is a choice" do
    assert VC.normalize(:detail_categories, %{"columns" => []}).columns == []
    assert VC.normalize(:catalogues, %{"columns" => []}).columns == []
  end

  test "normalize falls back to the defaults only when nothing valid was stored" do
    defaults = VC.defaults(:detail_categories).columns

    assert VC.normalize(:detail_categories, %{}).columns == defaults
    assert VC.normalize(:detail_categories, %{"columns" => "items"}).columns == defaults
    # Every stored id went stale (a column since removed from the module).
    assert VC.normalize(:detail_categories, %{"columns" => ["gone"]}).columns == defaults
    # A config saved while "name" still sat in the defaults loads without it.
    stored = %{"columns" => ["name", "items"]}
    assert VC.normalize(:detail_categories, stored).columns == ["items"]
  end

  test "normalize strips filter keys that are not filterable columns for the scope" do
    # "name" is a valid column but not filterable; "ghost_col" never existed.
    # Both stale keys must be dropped to prevent String.to_existing_atom crashes downstream.
    raw = %{
      "filters" => %{
        "status" => "active",
        "name" => "something",
        "ghost_col" => "some_value"
      }
    }

    got = VC.normalize(:catalogues, raw)

    # "status" is filterable for :catalogues — must survive
    assert got.filters == %{"status" => "active"}
  end

  test "normalize preserves a persisted 'position' (manual order) sort_by" do
    # sort_by isn't whitelisted against known columns here (the write-path
    # LV events validate against TableConfig's known_sortable_ids before
    # ever calling `put_cfg`) — normalize just has to not clobber it.
    assert VC.normalize(:catalogues, %{"sort_by" => "position"}).sort_by == "position"
  end
end
