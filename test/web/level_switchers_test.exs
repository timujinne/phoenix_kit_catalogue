defmodule PhoenixKitCatalogue.Web.LevelSwitchersTest do
  @moduledoc """
  The header's level switchers (boss, 2026-09-19, "like in GitHub"): a ▾
  beside the catalogue and each category of the trail lists the others on
  that level. Pure — no database.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Schemas.Category
  alias PhoenixKitCatalogue.Web.LevelSwitchers

  @kitchen %{uuid: "cat-kitchen", name: "Kitchen"}
  @bath %{uuid: "cat-bath", name: "Bathroom"}

  defp category(uuid, name, parent \\ nil),
    do: %Category{uuid: uuid, name: name, parent_uuid: parent}

  setup do
    doors = category("doors", "Doors")
    handles = category("handles", "Handles")
    oak = category("oak", "Oak doors", "doors")
    glass = category("glass", "Glass doors", "doors")

    ctx = %{
      catalogues: [@kitchen, @bath],
      siblings: %{nil => [doors, handles], "doors" => [oak, glass]},
      uncategorized?: false
    }

    %{ctx: ctx, doors: doors, oak: oak}
  end

  defp labels(switcher), do: Enum.map(switcher.items, & &1.label)
  defp current(switcher), do: switcher.items |> Enum.filter(& &1.current) |> Enum.map(& &1.label)

  test "at the root the catalogue is the title, and it switches catalogues", %{ctx: ctx} do
    assert LevelSwitchers.crumbs(@kitchen, nil, [], ctx) == []

    title = LevelSwitchers.title(@kitchen, nil, ctx)
    assert labels(title) == ["Kitchen", "Bathroom"]
    assert current(title) == ["Kitchen"]
    # Another catalogue is another LiveView mount: navigate, not patch.
    assert Enum.map(title.items, & &1.navigate) ==
             [Paths.catalogue_detail("cat-kitchen"), Paths.catalogue_detail("cat-bath")]
  end

  test "drilled into a subcategory, every level switches among its own siblings", %{
    ctx: ctx,
    doors: doors,
    oak: oak
  } do
    [catalogue_crumb, doors_crumb] = LevelSwitchers.crumbs(@kitchen, oak, [doors], ctx)

    assert catalogue_crumb.label == "Kitchen"
    assert current(catalogue_crumb.switcher) == ["Kitchen"]

    assert doors_crumb.label == "Doors"
    assert labels(doors_crumb.switcher) == ["Doors", "Handles"]
    assert current(doors_crumb.switcher) == ["Doors"]

    title = LevelSwitchers.title(@kitchen, oak, ctx)
    assert labels(title) == ["Oak doors", "Glass doors"]
    assert current(title) == ["Oak doors"]
    # A category is the same page: patch, keeping the LiveView.
    assert hd(title.items).patch == Paths.category_browse("cat-kitchen", "oak")
    refute Map.has_key?(hd(title.items), :navigate)
  end

  test "a level with nothing else on it gets no ▾", %{ctx: ctx, doors: doors} do
    lonely = %{ctx | catalogues: [@kitchen], siblings: %{nil => [doors]}}

    assert LevelSwitchers.title(@kitchen, nil, lonely) == nil
    assert LevelSwitchers.title(@kitchen, doors, lonely) == nil

    [catalogue_crumb] = LevelSwitchers.crumbs(@kitchen, doors, [], lonely)
    refute Map.has_key?(catalogue_crumb, :switcher)
  end

  test "Uncategorized sits beside the top-level categories when it holds anything", %{
    ctx: ctx,
    doors: doors
  } do
    refute "Uncategorized" in labels(LevelSwitchers.title(@kitchen, doors, ctx))

    with_loose = %{ctx | uncategorized?: true}
    title = LevelSwitchers.title(@kitchen, doors, with_loose)
    assert labels(title) == ["Doors", "Handles", "Uncategorized"]
    assert List.last(title.items).patch == Paths.uncategorized_browse("cat-kitchen")

    # Standing in the bucket, it is the ticked row.
    assert current(LevelSwitchers.title(@kitchen, :uncategorized, ctx)) == ["Uncategorized"]
  end

  test "a subcategory's list never offers Uncategorized", %{ctx: ctx, oak: oak} do
    refute "Uncategorized" in labels(
             LevelSwitchers.title(@kitchen, oak, %{ctx | uncategorized?: true})
           )
  end
end
