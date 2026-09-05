defmodule PhoenixKitCatalogue.Web.TableQueryTest do
  use ExUnit.Case, async: true
  alias PhoenixKitCatalogue.Web.TableQuery, as: Q

  defp rows do
    [
      %{
        name: "Beta",
        status: "active",
        item_count: 3,
        folder_uuid: "f1",
        folder_name: "Kitchen",
        updated_at: ~U[2026-01-02 00:00:00Z],
        position: 1
      },
      %{
        name: "alpha",
        status: "archived",
        item_count: 9,
        folder_uuid: nil,
        folder_name: nil,
        updated_at: ~U[2026-01-01 00:00:00Z],
        position: 0
      }
    ]
  end

  test "search is case-insensitive substring on name" do
    assert Enum.map(Q.search(rows(), "al"), & &1.name) == ["alpha"]
    assert Q.search(rows(), "") == rows()
    # Trimmed: a trailing space is not part of the needle, and an
    # all-space query means "no filter" (Max, 2026-08-28).
    assert Enum.map(Q.search(rows(), "alpha "), & &1.name) == ["alpha"]
    assert Q.search(rows(), "   ") == rows()
  end

  test "filter by status; 'all'/nil are no-ops" do
    assert Enum.map(Q.filter(rows(), :catalogues, %{"status" => "active"}), & &1.name) == ["Beta"]
    assert Q.filter(rows(), :catalogues, %{"status" => "all"}) == rows()
  end

  test "filter by folder uuid" do
    assert Enum.map(Q.filter(rows(), :catalogues, %{"folder" => "f1"}), & &1.name) == ["Beta"]
  end

  test "sort by name is case-insensitive; dir respected" do
    assert Enum.map(Q.sort(rows(), :catalogues, "name", :asc), & &1.name) == ["alpha", "Beta"]
    assert Enum.map(Q.sort(rows(), :catalogues, "name", :desc), & &1.name) == ["Beta", "alpha"]
  end

  test "sort by position (manual order)" do
    assert Enum.map(Q.sort(rows(), :catalogues, "position", :asc), & &1.name) == [
             "alpha",
             "Beta"
           ]
  end

  test "sort by position ties break on name (mirrors Catalogue.list_catalogues/1's [asc: :position, asc: :name])" do
    tied = [
      %{name: "Zeta", position: 0},
      %{name: "Alpha", position: 0},
      %{name: "Mid", position: 0}
    ]

    assert Enum.map(Q.sort(tied, :catalogues, "position", :asc), & &1.name) == [
             "Alpha",
             "Mid",
             "Zeta"
           ]
  end

  # The shape CataloguesLive passes while a search is on: the drilled
  # folder expanded to its subtree, so subfolder contents match too.
  test "a MapSet folder value matches any folder in the set, never unfiled" do
    assert Enum.map(
             Q.filter(rows(), :catalogues, %{"folder" => MapSet.new(["f1", "f2"])}),
             & &1.name
           ) == ["Beta"]

    # An unfiled row (nil folder_uuid) is in nobody's subtree.
    assert Q.filter(rows(), :catalogues, %{"folder" => MapSet.new(["f9"])}) == []
  end

  # Regression: `to_string(nil) == ""`, which `filter/2` already reserves to
  # mean "no filter set" — so the unfiled sentinel must be a distinct value,
  # not the row's stringified nil folder_uuid.
  test "filter by the unfiled sentinel matches only rows with a nil folder_uuid" do
    assert Enum.map(
             Q.filter(rows(), :catalogues, %{"folder" => Q.unfiled_folder_value()}),
             & &1.name
           ) ==
             ["alpha"]
  end

  test "date sorts are chronological, not structural" do
    # `Enum.sort_by/3`'s default term order compares DateTime structs
    # field-alphabetically — day before month — so a bare `& &1.updated_at`
    # sort key put Jan 2nd AFTER Feb 1st. The distinguishing shape is two
    # dates straddling a month boundary with inverted days.
    rows = [
      %{
        name: "Newer",
        updated_at: ~U[2026-02-01 00:00:00Z],
        inserted_at: ~U[2026-02-01 00:00:00Z]
      },
      %{
        name: "Older",
        updated_at: ~U[2026-01-02 00:00:00Z],
        inserted_at: ~U[2026-01-02 00:00:00Z]
      }
    ]

    assert Enum.map(Q.sort(rows, :catalogues, "updated", :asc), & &1.name) == ["Older", "Newer"]
    assert Enum.map(Q.sort(rows, :catalogues, "updated", :desc), & &1.name) == ["Newer", "Older"]
    assert Enum.map(Q.sort(rows, :catalogues, "created", :asc), & &1.name) == ["Older", "Newer"]
    assert Enum.map(Q.sort(rows, :suppliers, "updated", :asc), & &1.name) == ["Older", "Newer"]
  end
end
