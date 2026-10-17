defmodule PhoenixKitCatalogue.ExternalIdIndexTest do
  @moduledoc """
  `data["api"]["external_id"]` is unique per catalogue among live rows.
  Written through the context, the index violation must come
  back as a changeset error, not an `Ecto.ConstraintError`.
  """

  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase, only: [fixture_catalogue: 1]

  alias PhoenixKitCatalogue.Catalogue

  defp item_attrs(catalogue, external_id, name \\ "Item") do
    %{
      name: name,
      catalogue_uuid: catalogue.uuid,
      data: %{"api" => %{"external_id" => external_id}}
    }
  end

  defp category_attrs(catalogue, external_id, name \\ "Category") do
    %{
      name: name,
      catalogue_uuid: catalogue.uuid,
      data: %{"api" => %{"external_id" => external_id}}
    }
  end

  setup do
    %{catalogue: fixture_catalogue(%{name: "Ext Id Catalogue"})}
  end

  test "two live items of one catalogue cannot share an external_id", %{catalogue: catalogue} do
    assert {:ok, _} = Catalogue.create_item(item_attrs(catalogue, "A-1"))

    assert {:error, changeset} = Catalogue.create_item(item_attrs(catalogue, "A-1", "Other"))
    assert %{data: [message]} = errors_on(changeset)
    assert message == "external_id is already taken in this catalogue"
  end

  test "the same external_id is fine in another catalogue", %{catalogue: catalogue} do
    other = fixture_catalogue(%{name: "Other Catalogue"})

    assert {:ok, _} = Catalogue.create_item(item_attrs(catalogue, "A-1"))
    assert {:ok, _} = Catalogue.create_item(item_attrs(other, "A-1"))
  end

  test "a trashed item frees its external_id", %{catalogue: catalogue} do
    {:ok, old} = Catalogue.create_item(item_attrs(catalogue, "A-1"))
    {:ok, _} = Catalogue.trash_item(old)

    assert {:ok, new} = Catalogue.create_item(item_attrs(catalogue, "A-1", "Replacement"))
    assert new.uuid != old.uuid
  end

  test "items without an external_id never collide", %{catalogue: catalogue} do
    assert {:ok, _} = Catalogue.create_item(%{name: "Plain 1", catalogue_uuid: catalogue.uuid})
    assert {:ok, _} = Catalogue.create_item(%{name: "Plain 2", catalogue_uuid: catalogue.uuid})

    assert {:ok, _} =
             Catalogue.create_item(%{
               name: "With other api data 1",
               catalogue_uuid: catalogue.uuid,
               data: %{"api" => %{"note" => "x"}}
             })

    assert {:ok, _} =
             Catalogue.create_item(%{
               name: "With other api data 2",
               catalogue_uuid: catalogue.uuid,
               data: %{"api" => %{"note" => "x"}}
             })
  end

  test "changing an item's external_id to a taken one is a changeset error", %{
    catalogue: catalogue
  } do
    {:ok, _first} = Catalogue.create_item(item_attrs(catalogue, "A-1"))
    {:ok, second} = Catalogue.create_item(item_attrs(catalogue, "A-2", "Second"))

    assert {:error, changeset} =
             Catalogue.update_item(second, %{data: %{"api" => %{"external_id" => "A-1"}}})

    assert %{data: ["external_id is already taken in this catalogue"]} = errors_on(changeset)
  end

  test "categories follow the same rule", %{catalogue: catalogue} do
    assert {:ok, _} = Catalogue.create_category(category_attrs(catalogue, "C-1"))

    assert {:error, changeset} =
             Catalogue.create_category(category_attrs(catalogue, "C-1", "Other"))

    assert %{data: ["external_id is already taken in this catalogue"]} = errors_on(changeset)
  end

  test "a trashed category frees its external_id", %{catalogue: catalogue} do
    {:ok, old} = Catalogue.create_category(category_attrs(catalogue, "C-1"))
    {:ok, _} = Catalogue.trash_category(old)

    assert {:ok, _} = Catalogue.create_category(category_attrs(catalogue, "C-1", "Again"))
  end
end
