defmodule PhoenixKitCatalogue.ActivityModeTest do
  @moduledoc """
  The importer passes `mode: "auto"`; until 2026-09-12 every context
  logger but `create_item/2` hardcoded "manual", so the activity log
  could not tell an import from a hand edit.
  """
  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.ActivityLogAssertions, only: [list_activities: 0]
  import PhoenixKitCatalogue.LiveCase, only: [fixture_catalogue: 1]

  alias PhoenixKitCatalogue.Catalogue

  defp mode_of(action, name) do
    list_activities()
    |> Enum.find(&(&1.action == action and &1.metadata["name"] == name))
    |> Map.fetch!(:mode)
  end

  test "a caller's mode reaches the log; the default stays manual" do
    catalogue = fixture_catalogue(%{name: "Mode Cat"})

    {:ok, auto} =
      Catalogue.create_category(%{name: "From import", catalogue_uuid: catalogue.uuid},
        mode: "auto"
      )

    {:ok, manual} = Catalogue.create_category(%{name: "By hand", catalogue_uuid: catalogue.uuid})

    assert mode_of("category.created", "From import") == "auto"
    assert mode_of("category.created", "By hand") == "manual"

    # A site that narrows its opts (Keyword.take) still forwards the mode.
    {:ok, _} = Catalogue.move_category_under(auto, manual.uuid, mode: "auto")
    assert mode_of("category.moved", "From import") == "auto"
  end
end
