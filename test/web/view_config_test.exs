defmodule PhoenixKitCatalogue.Web.ViewConfigTest do
  use ExUnit.Case, async: true
  alias PhoenixKitCatalogue.Web.ViewConfig, as: VC

  test "defaults shape" do
    assert %{
             columns: ["name", "folder", "items", "status", "updated"],
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

  test "load reads from a user struct's custom_fields" do
    user = %{
      custom_fields: %{
        "catalogue_view_configs" => %{"suppliers" => %{"columns" => ["status"]}}
      }
    }

    # "name" is implicit and never stored, so it is not echoed back here.
    assert VC.load(user, :suppliers).columns == ["status"]
    assert VC.load(%{custom_fields: nil}, :suppliers) == VC.defaults(:suppliers)
  end

  test "the view is module-wide, not per scope (2026-08-28)" do
    # Every surface used to keep its own view, so a choice made on the
    # catalogues index never reached the page you opened next. It now
    # lives beside the per-scope maps and overlays all of them.
    user = %{custom_fields: %{"catalogue_view_configs" => %{"__view__" => "card"}}}

    assert VC.load_view(user) == "card"
    assert VC.load(user, :suppliers).view == "card"
    assert VC.load(user, :catalogues).view == "card"

    # A stale per-scope value from before the change is ignored, and an
    # unknown mode falls back rather than rendering nothing.
    stale = %{
      custom_fields: %{
        "catalogue_view_configs" => %{"suppliers" => %{"view" => "table"}, "__view__" => "bogus"}
      }
    }

    assert VC.load(stale, :suppliers).view == "comfy"
    assert VC.load_view(%{custom_fields: nil}) == "comfy"
    assert VC.load_view(nil) == "comfy"
  end
end
