defmodule PhoenixKitCatalogue.Import.Pro100ApplyOwnedKeysTest do
  @moduledoc """
  The Pro100 Apply writes only the keys the plan changed, as owned keys —
  the same call the import wizard makes — so a photo pointer or order
  written between Apply's read and its write survives (review sweep,
  2026-09-12; before this Apply merged by hand outside the row lock and
  wrote the whole map).
  """
  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.ActivityLogAssertions, only: [list_activities: 0]
  import PhoenixKitCatalogue.LiveCase, only: [fixture_catalogue: 1, fixture_item: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Import.Pro100Plan

  test "a photo order written between Apply's read and its write survives" do
    catalogue = fixture_catalogue(%{name: "Pro100 Cat"})
    item = fixture_item(%{name: "Board", catalogue_uuid: catalogue.uuid})

    {:ok, item} =
      Catalogue.update_item(item, %{data: %{"media_order" => ["a", "b"], "pro100" => %{"v" => 1}}})

    change = %{item: item, data: Map.put(item.data, "pro100", %{"v" => 2}), changes: %{}}

    # Apply reads the item...
    target = Catalogue.get_item(item.uuid)
    owned = Pro100Plan.data_owned_keys(change)
    assert owned == ["pro100"]

    # ...an editor reorders the photos meanwhile (owned-key write)...
    {:ok, _} =
      Catalogue.update_item(target, %{data: %{"media_order" => ["b", "a"]}},
        data_owned_keys: ["media_order"]
      )

    # ...and Apply writes, the way the wizard does.
    {:ok, updated} =
      Catalogue.update_item(target, %{data: Map.take(change.data, owned)},
        data_owned_keys: owned,
        mode: "auto"
      )

    assert updated.data["pro100"] == %{"v" => 2}
    assert updated.data["media_order"] == ["b", "a"]
    assert Catalogue.get_item!(item.uuid).data["media_order"] == ["b", "a"]

    assert Enum.any?(
             list_activities(),
             &(&1.action == "item.updated" and &1.mode == "auto" and
                 &1.metadata["name"] == "Board")
           )
  end
end
