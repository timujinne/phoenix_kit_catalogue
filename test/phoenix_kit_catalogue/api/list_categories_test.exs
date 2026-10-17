defmodule PhoenixKitCatalogue.API.ListCategoriesTest do
  @moduledoc "`catalogue.list_categories`: the category tree with ids, names per language and positions."

  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase, only: [fixture_catalogue: 1, fixture_category: 2]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Test.ApiCase

  @tool "catalogue.list_categories"

  setup do
    %{catalogue: fixture_catalogue(%{name: "Categories Cat"})}
  end

  test "returns the tree ordered by position then name", %{catalogue: catalogue} do
    shelves = fixture_category(catalogue, %{name: "Shelves", position: 1})
    _doors = fixture_category(catalogue, %{name: "Doors", position: 0})
    _glass = fixture_category(catalogue, %{name: "Glass shelves", parent_uuid: shelves.uuid})

    _wood =
      fixture_category(catalogue, %{name: "Wood shelves", parent_uuid: shelves.uuid, position: 5})

    assert {:ok, body} = ApiCase.call(@tool, %{"catalogue_id" => catalogue.uuid})

    assert body["catalogue_id"] == catalogue.uuid
    assert body["count"] == 4

    assert [
             %{"name" => "Doors", "position" => 0, "children" => []},
             %{
               "name" => "Shelves",
               "id" => shelves_id,
               "children" => [
                 %{"name" => "Glass shelves", "parent_id" => parent_id, "children" => []},
                 %{"name" => "Wood shelves", "position" => 5}
               ]
             }
           ] = body["categories"]

    assert shelves_id == shelves.uuid
    assert parent_id == shelves.uuid
  end

  test "carries the external id and the names per language", %{catalogue: catalogue} do
    {:ok, category} =
      Catalogue.create_category(%{
        name: "Shelves",
        catalogue_uuid: catalogue.uuid,
        data: %{
          "_primary_language" => "en-US",
          "en-US" => %{"_name" => "Shelves"},
          "de-DE" => %{"_name" => "Regale"},
          "api" => %{"external_id" => "C-7"}
        }
      })

    assert {:ok, %{"categories" => [node]}} =
             ApiCase.call(@tool, %{"catalogue_id" => catalogue.uuid})

    assert node["id"] == category.uuid
    assert node["external_id"] == "C-7"
    assert node["names"] == %{"en-US" => "Shelves", "de-DE" => "Regale"}
    assert node["status"] == "active"
  end

  test "trashed categories and other catalogues' categories are not listed", %{
    catalogue: catalogue
  } do
    other = fixture_catalogue(%{name: "Another"})
    fixture_category(other, %{name: "Foreign"})
    gone = fixture_category(catalogue, %{name: "Gone"})
    fixture_category(catalogue, %{name: "Kept"})
    {:ok, _} = Catalogue.trash_category(gone)

    assert {:ok, body} = ApiCase.call(@tool, %{"catalogue_id" => catalogue.uuid})
    assert Enum.map(body["categories"], & &1["name"]) == ["Kept"]
    assert body["count"] == 1
  end

  test "a category whose parent is not live is promoted to a root", %{catalogue: catalogue} do
    parent = fixture_category(catalogue, %{name: "Parent"})
    fixture_category(catalogue, %{name: "Child", parent_uuid: parent.uuid})

    # A trash cascades to the subtree, so build the state a half-restored or
    # hand-edited tree can be in: the parent deleted, the child live.
    {1, _} =
      Repo.update_all(
        from(c in PhoenixKitCatalogue.Schemas.Category, where: c.uuid == ^parent.uuid),
        set: [status: "deleted"]
      )

    assert {:ok, body} = ApiCase.call(@tool, %{"catalogue_id" => catalogue.uuid})

    assert [%{"name" => "Child", "parent_id" => parent_id, "children" => []}] = body["categories"]
    assert parent_id == parent.uuid
  end

  test "an empty catalogue answers an empty tree", %{catalogue: catalogue} do
    assert {:ok, %{"categories" => [], "count" => 0}} =
             ApiCase.call(@tool, %{"catalogue_id" => catalogue.uuid})
  end

  test "catalogue errors come through", %{catalogue: _catalogue} do
    assert {:error, :not_found, _, _} =
             ApiCase.call(@tool, %{"catalogue_id" => Ecto.UUID.generate()})

    _second = fixture_catalogue(%{name: "Second"})

    assert {:error, :validation_failed, _, %{errors: [%{path: "catalogue_id"}]}} =
             ApiCase.call(@tool, %{})
  end

  test "unknown fields are refused", %{catalogue: catalogue} do
    assert {:error, :validation_failed, _, %{errors: errors}} =
             ApiCase.call(@tool, %{"catalogue_id" => catalogue.uuid, "data" => %{}})

    assert Enum.any?(errors, &(&1.path == "data"))
  end
end
