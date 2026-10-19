defmodule PhoenixKitCatalogue.Web.DependencyDraftTest do
  @moduledoc """
  `DependencyDraft` with no database: rows as the Dependencies tab stages
  them, what typing keeps verbatim, what `validate/1` refuses, and the
  specs it hands `put_item_dependencies/3`.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitCatalogue.Schemas.{Catalogue, Category, Item, ItemDependency}
  alias PhoenixKitCatalogue.Web.DependencyDraft

  @screws %Catalogue{uuid: "c1", name: "Screws", status: "active"}
  @wood %Category{
    uuid: "k1",
    name: "Wood",
    status: "active",
    catalogue_uuid: "c1",
    catalogue: @screws
  }
  @screw %Item{
    uuid: "i1",
    name: "Screw",
    status: "deleted",
    catalogue_uuid: "c1",
    category_uuid: "k1",
    catalogue: @screws,
    category: @wood
  }

  # "k1" is internal (or under an internal category): the hidden set the
  # item form reads from `Catalogue.internal_category_uuids/0`.
  defp draft do
    DependencyDraft.new([], &Map.get(&1, :name), %{"k1" => true})
    |> DependencyDraft.add(:catalogue, @screws)
    |> DependencyDraft.add(:category, @wood)
    |> DependencyDraft.add(:item, @screw)
  end

  test "a row says what it is, where it sits and whether it is trashed or internal" do
    assert [
             %{kind: :catalogue, name: "Screws", place: nil, internal?: false, quantity: "1"},
             %{
               kind: :category,
               name: "Wood",
               place: "Screws",
               catalogue_uuid: "c1",
               internal?: true
             },
             %{kind: :item, place: "Screws › Wood", trashed?: true, internal?: true}
           ] = draft().rows
  end

  test "without a hidden set nothing is marked internal" do
    rows =
      DependencyDraft.new()
      |> DependencyDraft.add(:category, @wood)
      |> DependencyDraft.add(:item, @screw)
      |> Map.fetch!(:rows)

    assert Enum.all?(rows, &(&1.internal? == false))
  end

  test "a saved list round-trips through new/2 with its quantities and notes" do
    saved = [
      %ItemDependency{target_item: @screw, quantity: Decimal.new("8.0000"), note: "by wood"},
      %ItemDependency{target_catalogue: @screws, quantity: Decimal.new("2.5000"), note: nil}
    ]

    assert [
             %{kind: :item, quantity: "8", note: "by wood"},
             %{kind: :catalogue, quantity: "2.5", note: ""}
           ] = DependencyDraft.new(saved).rows
  end

  test "typed values are kept as typed and clear the row's error" do
    {:error, bad} =
      draft()
      |> DependencyDraft.put_values(%{"1" => %{"quantity" => "0"}})
      |> DependencyDraft.validate()

    assert %{error: "quantity"} = hd(bad.rows)

    typed = DependencyDraft.put_values(bad, %{"1" => %{"quantity" => "2,5", "note" => "x"}})
    assert %{quantity: "2,5", note: "x", error: nil} = hd(typed.rows)
  end

  test "validate refuses what the column would refuse or round" do
    for {quantity, ok?} <- [
          {"1", true},
          {"2,5", true},
          {"0.0001", true},
          {"99999999.9999", true},
          {"0", false},
          {"-1", false},
          {"", false},
          {"abc", false},
          {"1.23456", false},
          {"100000000", false}
        ] do
      result =
        draft()
        |> DependencyDraft.put_values(%{"1" => %{"quantity" => quantity}})
        |> DependencyDraft.validate()

      assert match?({:ok, _}, result) == ok?, quantity
    end

    long_note = String.duplicate("n", ItemDependency.max_note_length() + 1)

    assert {:error, %{rows: [%{error: "note"} | _]}} =
             draft()
             |> DependencyDraft.put_values(%{"1" => %{"note" => long_note}})
             |> DependencyDraft.validate()
  end

  test "reorder follows the dragged order and loses nothing; remove drops one row" do
    draft = draft()
    keys = Enum.map(draft.rows, & &1.key)

    reordered = DependencyDraft.reorder(draft, ["3", "1", "2"])
    assert Enum.map(reordered.rows, & &1.key) == ["3", "1", "2"]
    assert reordered.dirty

    # Unknown and repeated keys are ignored; rows left out keep their place after.
    assert Enum.map(DependencyDraft.reorder(draft, ["2", "x", "2"]).rows, & &1.key) ==
             ["2", "1", "3"]

    # The same order changes nothing, not even the dirty flag.
    assert DependencyDraft.reorder(draft, keys) == draft
    assert Enum.map(DependencyDraft.remove(draft, "2").rows, & &1.key) == ["1", "3"]
    assert DependencyDraft.count(DependencyDraft.remove(draft, "2")) == 2
  end

  test "to_specs hands the context targets and parsed quantities in order" do
    specs =
      draft()
      |> DependencyDraft.put_values(%{"2" => %{"quantity" => "2,5", "note" => "n"}})
      |> DependencyDraft.to_specs()

    assert [
             %{target: {:catalogue, "c1"}},
             %{target: {:category, "k1"}, note: "n", quantity: quantity},
             %{target: {:item, "i1"}}
           ] = specs

    assert Decimal.equal?(quantity, Decimal.new("2.5"))
  end
end
