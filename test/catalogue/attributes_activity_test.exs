defmodule PhoenixKitCatalogue.Catalogue.AttributesActivityTest do
  @moduledoc """
  One pin per audit action on the attribute / value surface — until the
  2026-09-13 sweep only `create_attribute/3` and `delete_attribute/2`
  wrote a row; the other seven mutations were silent.
  """
  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.ActivityLogAssertions

  alias PhoenixKitCatalogue.Catalogue

  @actor Ecto.UUID.generate()
  @opts [actor_uuid: @actor]

  setup do
    {:ok, group} = Catalogue.create_attribute_group(%{name: "Doors"})
    {:ok, attribute} = Catalogue.create_attribute(group, %{"name" => "Color"})
    {:ok, white} = Catalogue.create_attribute_value(attribute, %{"value" => "White"}, @opts)
    {:ok, black} = Catalogue.create_attribute_value(attribute, %{"value" => "Black"}, @opts)
    %{group: group, attribute: attribute, white: white, black: black}
  end

  test "attribute_group.attribute_updated", %{group: group, attribute: attribute} do
    {:ok, _} = Catalogue.update_attribute(attribute, %{"name" => "Colour"}, @opts)

    assert_activity_logged("attribute_group.attribute_updated",
      resource_uuid: group.uuid,
      actor_uuid: @actor,
      metadata_has: %{"key" => attribute.key}
    )
  end

  test "attribute_group.attributes_reordered", %{group: group, attribute: attribute} do
    {:ok, trim} = Catalogue.create_attribute(group, %{"name" => "Trim"})
    :ok = Catalogue.reorder_attributes(group, [trim.uuid, attribute.uuid], @opts)

    assert_activity_logged("attribute_group.attributes_reordered",
      resource_uuid: group.uuid,
      actor_uuid: @actor,
      metadata_has: %{"count" => 2}
    )
  end

  test "attribute.value_added", %{attribute: attribute, white: white} do
    assert_activity_logged("attribute.value_added",
      resource_uuid: attribute.uuid,
      actor_uuid: @actor,
      metadata_has: %{"key" => white.key}
    )
  end

  test "attribute.value_updated", %{attribute: attribute, white: white} do
    {:ok, _} = Catalogue.update_attribute_value(white, %{"value" => "Off white"}, @opts)

    assert_activity_logged("attribute.value_updated",
      resource_uuid: attribute.uuid,
      actor_uuid: @actor,
      metadata_has: %{"key" => white.key}
    )
  end

  test "attribute.value_removed", %{attribute: attribute, black: black} do
    {:ok, _} = Catalogue.delete_attribute_value(black, @opts)

    assert_activity_logged("attribute.value_removed",
      resource_uuid: attribute.uuid,
      actor_uuid: @actor,
      metadata_has: %{"key" => black.key}
    )
  end

  test "attribute.default_set", %{attribute: attribute, black: black} do
    {:ok, _} = Catalogue.set_default_value(black, @opts)

    assert_activity_logged("attribute.default_set",
      resource_uuid: attribute.uuid,
      actor_uuid: @actor,
      metadata_has: %{"key" => black.key}
    )
  end

  test "attribute.values_reordered", %{attribute: attribute, white: white, black: black} do
    :ok = Catalogue.reorder_attribute_values(attribute, [black.uuid, white.uuid], @opts)

    assert_activity_logged("attribute.values_reordered",
      resource_uuid: attribute.uuid,
      actor_uuid: @actor,
      metadata_has: %{"count" => 2}
    )
  end

  test "the default stays manual and the importer's mode wins", %{attribute: attribute} do
    {:ok, _} = Catalogue.update_attribute(attribute, %{"name" => "A"})
    {:ok, _} = Catalogue.update_attribute(attribute, %{"name" => "B"}, mode: "auto")

    modes =
      list_activities()
      |> Enum.filter(&(&1.action == "attribute_group.attribute_updated"))
      |> Enum.map(& &1.mode)
      |> Enum.sort()

    assert modes == ["auto", "manual"]
  end
end
