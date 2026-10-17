defmodule PhoenixKitCatalogue.API.CatalogueScopeTest do
  @moduledoc """
  `PhoenixKitCatalogue.API.resolve_catalogue/2`: the tool's
  `catalogue_id` is required when more than one catalogue is active.
  """

  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase, only: [fixture_catalogue: 1]

  alias PhoenixKitCatalogue.API
  alias PhoenixKitCatalogue.Catalogue

  # The scratch database may hold catalogues from earlier runs outside the
  # sandbox; inside this test's transaction they are trashed so the install
  # "has" exactly the catalogues the test creates.
  defp clear_catalogues! do
    for catalogue <- Catalogue.list_catalogues(),
        do: {:ok, _} = Catalogue.trash_catalogue(catalogue)
  end

  setup do
    clear_catalogues!()
    :ok
  end

  test "no id and exactly one active standard catalogue: that one" do
    only = fixture_catalogue(%{name: "Only"})
    {:ok, _} = Catalogue.create_catalogue(%{name: "Smart one", kind: "smart"})
    {:ok, archived} = Catalogue.create_catalogue(%{name: "Archived one"})
    {:ok, _} = Catalogue.update_catalogue(archived, %{status: "archived"})

    assert {:ok, found} = API.resolve_catalogue(nil)
    assert found.uuid == only.uuid
  end

  test "no id and no active catalogue" do
    assert {:error, :validation_failed, message, %{errors: [error]}} = API.resolve_catalogue(nil)
    assert message =~ "There is no active catalogue"
    assert error.path == "catalogue_id"
    assert error.allowed == []
  end

  test "no id and several active catalogues: catalogue_id is required, candidates listed" do
    a = fixture_catalogue(%{name: "A"})
    b = fixture_catalogue(%{name: "B"})

    assert {:error, :validation_failed, message, %{errors: [error]}} = API.resolve_catalogue(nil)
    assert message =~ "catalogue_id is required"
    assert error.path == "catalogue_id"
    assert Enum.sort(error.allowed) == Enum.sort([a.uuid, b.uuid])
  end

  test "an explicit id wins over the count" do
    a = fixture_catalogue(%{name: "A"})
    _b = fixture_catalogue(%{name: "B"})

    assert {:ok, found} = API.resolve_catalogue(a.uuid)
    assert found.uuid == a.uuid
  end

  test "default_uuid stands in for a missing id" do
    _a = fixture_catalogue(%{name: "A"})
    b = fixture_catalogue(%{name: "B"})

    assert {:ok, found} = API.resolve_catalogue(nil, default_uuid: b.uuid)
    assert found.uuid == b.uuid
  end

  test "unknown, malformed and trashed ids are not_found, a non-string is invalid" do
    a = fixture_catalogue(%{name: "A"})
    {:ok, _} = Catalogue.trash_catalogue(a)

    assert {:error, :not_found, _, _} = API.resolve_catalogue(Ecto.UUID.generate())
    assert {:error, :not_found, _, _} = API.resolve_catalogue("nope")
    assert {:error, :not_found, _, _} = API.resolve_catalogue(a.uuid)
    assert {:error, :validation_failed, _, _} = API.resolve_catalogue(12)
  end

  test "smart catalogues are refused" do
    {:ok, smart} = Catalogue.create_catalogue(%{name: "Smart", kind: "smart"})

    assert {:error, :validation_failed, message, _} = API.resolve_catalogue(smart.uuid)
    assert message =~ "Smart catalogues"
  end

  test "an archived catalogue can be read but not written" do
    {:ok, archived} = Catalogue.create_catalogue(%{name: "Archived"})
    {:ok, archived} = Catalogue.update_catalogue(archived, %{status: "archived"})

    assert {:ok, _} = API.resolve_catalogue(archived.uuid)

    assert {:error, :validation_failed, message, _} =
             API.resolve_catalogue(archived.uuid, writable: true)

    assert message =~ "archived"
  end
end
