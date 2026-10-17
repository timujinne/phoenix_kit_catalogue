defmodule PhoenixKitCatalogue.API.RefsTest do
  @moduledoc """
  `PhoenixKitCatalogue.API.resolve_refs/2`: `{id}`, `{sku}` or
  `{external_id}`, resolved inside one catalogue, never raising on input.
  """

  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase,
    only: [fixture_catalogue: 1, fixture_category: 2, fixture_item: 1]

  alias PhoenixKitCatalogue.API
  alias PhoenixKitCatalogue.API.Refs
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Schemas.Item
  alias PhoenixKitCatalogue.Test.Repo

  defp item(catalogue, name, extra \\ %{}),
    do: fixture_item(Map.merge(%{name: name, catalogue_uuid: catalogue.uuid}, extra))

  defp with_eid(eid), do: %{data: %{"api" => %{"external_id" => eid}}}

  setup do
    %{catalogue: fixture_catalogue(%{name: "Refs Cat"})}
  end

  test "resolves id, sku and external_id in one call, in input order", %{catalogue: catalogue} do
    a = item(catalogue, "A", %{sku: "SKU-A"})
    b = item(catalogue, "B", with_eid("EXT-B"))
    c = item(catalogue, "C")

    refs = [%{"external_id" => "EXT-B"}, %{"id" => c.uuid}, %{"sku" => "SKU-A"}]

    assert [
             {%{"external_id" => "EXT-B"}, {:ok, found_b}},
             {%{"id" => _}, {:ok, found_c}},
             {%{"sku" => "SKU-A"}, {:ok, found_a}}
           ] = API.resolve_refs(refs, catalogue_uuid: catalogue.uuid)

    assert {found_a.uuid, found_b.uuid, found_c.uuid} == {a.uuid, b.uuid, c.uuid}
  end

  test "an upper-case UUID resolves; atom-keyed refs are accepted", %{catalogue: catalogue} do
    a = item(catalogue, "A")

    assert [{_, {:ok, found}}] = API.resolve_refs([%{"id" => String.upcase(a.uuid)}])
    assert found.uuid == a.uuid

    assert [{%{id: _}, {:ok, found}}] = API.resolve_refs([%{id: a.uuid}])
    assert found.uuid == a.uuid
  end

  test "input that names no row never raises", %{catalogue: catalogue} do
    assert [
             {_, {:error, :not_found}},
             {_, {:error, :not_found}},
             {_, {:error, :not_found}},
             {_, {:error, :not_found}}
           ] =
             API.resolve_refs(
               [
                 %{"id" => "not-a-uuid"},
                 %{"id" => Ecto.UUID.generate()},
                 %{"sku" => "NOPE"},
                 %{"external_id" => "NOPE"}
               ],
               catalogue_uuid: catalogue.uuid
             )
  end

  test "malformed refs are :invalid_ref", %{catalogue: catalogue} do
    bad = [
      %{},
      %{"id" => Ecto.UUID.generate(), "sku" => "X"},
      %{"sku" => ""},
      %{"sku" => "   "},
      %{"id" => ""},
      %{"id" => "   "},
      %{"external_id" => nil},
      %{"id" => 12},
      %{"sku" => 12},
      "just a string",
      nil
    ]

    results = API.resolve_refs(bad, catalogue_uuid: catalogue.uuid)

    assert length(results) == length(bad)
    assert Enum.all?(results, &match?({_, {:error, :invalid_ref}}, &1))
  end

  test "texts with a NUL byte name no row and do not fail their neighbours", %{
    catalogue: catalogue
  } do
    a = item(catalogue, "A", Map.merge(%{sku: "SKU-OK"}, with_eid("EXT-OK")))

    refs = [
      %{"sku" => "a\u0000b"},
      %{"sku" => "SKU-OK"},
      %{"external_id" => "a\u0000b"},
      %{"external_id" => "EXT-OK"},
      %{"id" => "a\u0000b"}
    ]

    assert [
             {_, {:error, :not_found}},
             {_, {:ok, by_sku}},
             {_, {:error, :not_found}},
             {_, {:ok, by_eid}},
             {_, {:error, :not_found}}
           ] = API.resolve_refs(refs, catalogue_uuid: catalogue.uuid)

    assert by_sku.uuid == a.uuid and by_eid.uuid == a.uuid
  end

  test "a NUL byte in a category external_id names no row", %{catalogue: catalogue} do
    category =
      fixture_category(catalogue, %{name: "Shelf", data: %{"api" => %{"external_id" => "C-OK"}}})

    assert [{_, {:error, :not_found}}, {_, {:ok, found}}] =
             API.resolve_refs(
               [%{"external_id" => "a\u0000b"}, %{"external_id" => "C-OK"}],
               kind: :category,
               catalogue_uuid: catalogue.uuid
             )

    assert found.uuid == category.uuid
  end

  test "an id that is 16 characters of text is not read as raw UUID bytes", %{
    catalogue: catalogue
  } do
    # Ecto.UUID.cast/1 turns the 16 bytes "abcdefghijklmnop" into this uuid
    raw = "61626364-6566-6768-696a-6b6c6d6e6f70"
    Repo.insert!(%Item{uuid: raw, name: "Raw", catalogue_uuid: catalogue.uuid})

    assert [{_, {:error, :not_found}}, {_, {:ok, found}}] =
             API.resolve_refs([%{"id" => "abcdefghijklmnop"}, %{"id" => raw}],
               catalogue_uuid: catalogue.uuid
             )

    assert found.uuid == raw
  end

  test "a sku matching two live items is ambiguous, with sorted candidates", %{
    catalogue: catalogue
  } do
    a = item(catalogue, "A1", %{sku: "DUP"})
    b = item(catalogue, "A2", %{sku: "DUP"})

    # Rewriting the first row moves it to the end of the heap, so the order
    # the database returns differs from the uuid order the answer must have.
    {:ok, _} = Catalogue.update_item(a, %{name: "A1 renamed"})

    assert [{_, {:error, {:ambiguous_ref, candidates}}}] =
             API.resolve_refs([%{"sku" => "DUP"}], catalogue_uuid: catalogue.uuid)

    assert candidates == Enum.sort([a.uuid, b.uuid])
  end

  test "a trashed duplicate is not a candidate", %{catalogue: catalogue} do
    a = item(catalogue, "A1", %{sku: "DUP"})
    b = item(catalogue, "A2", %{sku: "DUP"})
    {:ok, _} = Catalogue.trash_item(b)

    assert [{_, {:ok, found}}] =
             API.resolve_refs([%{"sku" => "DUP"}], catalogue_uuid: catalogue.uuid)

    assert found.uuid == a.uuid
  end

  test "lookups are scoped to the catalogue", %{catalogue: catalogue} do
    other = fixture_catalogue(%{name: "Refs Other"})
    foreign = item(other, "Foreign", Map.merge(%{sku: "S-1"}, with_eid("E-1")))

    refs = [%{"id" => foreign.uuid}, %{"sku" => "S-1"}, %{"external_id" => "E-1"}]

    assert Enum.all?(
             API.resolve_refs(refs, catalogue_uuid: catalogue.uuid),
             &match?({_, {:error, :not_found}}, &1)
           )

    assert Enum.all?(
             API.resolve_refs(refs, catalogue_uuid: other.uuid),
             &match?({_, {:ok, _}}, &1)
           )
  end

  test "an external_id shared by a trashed and a live item resolves to the live one", %{
    catalogue: catalogue
  } do
    old = item(catalogue, "Old", with_eid("E-9"))
    {:ok, _} = Catalogue.trash_item(old)
    live = item(catalogue, "Live", with_eid("E-9"))

    assert [{_, {:ok, found}}] =
             API.resolve_refs([%{"external_id" => "E-9"}], catalogue_uuid: catalogue.uuid)

    assert found.uuid == live.uuid
  end

  test "trashed rows are found by id only with include_deleted", %{catalogue: catalogue} do
    a = item(catalogue, "A")
    {:ok, _} = Catalogue.trash_item(a)

    assert [{_, {:error, :not_found}}] = API.resolve_refs([%{"id" => a.uuid}])
    assert [{_, {:ok, found}}] = API.resolve_refs([%{"id" => a.uuid}], include_deleted: true)
    assert found.status == "deleted"
  end

  test "the same ref twice is resolved twice", %{catalogue: catalogue} do
    a = item(catalogue, "A", %{sku: "TWICE"})
    ref = %{"sku" => "TWICE"}

    assert [{^ref, {:ok, one}}, {^ref, {:ok, two}}] =
             API.resolve_refs([ref, ref], catalogue_uuid: catalogue.uuid)

    assert one.uuid == a.uuid and two.uuid == a.uuid
  end

  test "preload is passed through", %{catalogue: catalogue} do
    category = fixture_category(catalogue, %{name: "Shelf"})
    a = item(catalogue, "A", %{category_uuid: category.uuid})

    assert [{_, {:ok, found}}] =
             API.resolve_refs([%{"id" => a.uuid}], preload: [:category])

    assert found.category.name == "Shelf"
  end

  describe "categories" do
    test "resolve by id and external_id; sku is not a category reference", %{catalogue: catalogue} do
      {:ok, category} =
        Catalogue.create_category(%{
          name: "Shelf",
          catalogue_uuid: catalogue.uuid,
          data: %{"api" => %{"external_id" => "C-1"}}
        })

      results =
        API.resolve_refs(
          [%{"id" => category.uuid}, %{"external_id" => "C-1"}, %{"sku" => "X"}],
          kind: :category,
          catalogue_uuid: catalogue.uuid
        )

      assert [{_, {:ok, one}}, {_, {:ok, two}}, {_, {:error, :invalid_ref}}] = results
      assert one.uuid == category.uuid and two.uuid == category.uuid
    end
  end

  test "Refs.external_id/1 reads the api namespace and nothing else", %{catalogue: catalogue} do
    assert Refs.external_id(item(catalogue, "A", with_eid("E-1"))) ==
             "E-1"

    assert Refs.external_id(item(catalogue, "B")) == nil
    assert Refs.external_id(%{data: %{"api" => "oops"}}) == nil
    assert Refs.external_id(%{data: nil}) == nil
  end
end
