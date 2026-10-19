defmodule PhoenixKitCatalogue.Catalogue.ItemDependenciesTest do
  @moduledoc """
  Item dependencies through the context: the replace-all write that
  writes nothing when nothing changed, its validation, what a soft trash
  and a permanent delete do to the rows, the "who lists this?" lookup,
  the count a permanent-delete confirmation states, and duplication
  (rows copied, targets inside a copied catalogue pointed at the copies).
  """

  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase,
    only: [fixture_catalogue: 1, fixture_category: 2, fixture_item: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Schemas.{Item, ItemDependency}

  @actor "00000000-0000-7000-8000-000000000002"

  setup do
    furniture = fixture_catalogue(%{name: "Furniture"})
    screws = fixture_catalogue(%{name: "Screws"})
    wood_screws = fixture_category(screws, %{name: "Wood screws"})
    susan = fixture_item(%{name: "Lazy susan", catalogue_uuid: furniture.uuid})

    screw =
      fixture_item(%{
        name: "Screw 4x30",
        catalogue_uuid: screws.uuid,
        category_uuid: wood_screws.uuid
      })

    %{furniture: furniture, screws: screws, wood_screws: wood_screws, susan: susan, screw: screw}
  end

  defp put!(item, specs, opts \\ []) do
    {:ok, rows} = Catalogue.put_item_dependencies(item, specs, opts)
    rows
  end

  defp count_logs(item_uuid) do
    Repo.one(
      from(a in "phoenix_kit_activities",
        where:
          a.action == "item.dependencies_synced" and
            a.resource_uuid == type(^item_uuid, :binary_id),
        select: count()
      )
    )
  end

  describe "put_item_dependencies/3" do
    test "writes the rows in order with their targets loaded", ctx do
      rows =
        put!(ctx.susan, [
          %{target: {:catalogue, ctx.screws.uuid}, quantity: "8", note: " pick by wood type "},
          %{target: {:category, ctx.wood_screws.uuid}, quantity: Decimal.new("2.5")},
          %{target: {:item, ctx.screw.uuid}, quantity: 1, note: ""}
        ])

      assert [
               %ItemDependency{
                 position: 0,
                 note: "pick by wood type",
                 target_catalogue: %{name: "Screws"}
               },
               %ItemDependency{position: 1, note: nil, target_category: %{name: "Wood screws"}},
               %ItemDependency{position: 2, target_item: %{name: "Screw 4x30"}}
             ] = rows

      assert Decimal.equal?(Enum.at(rows, 1).quantity, Decimal.new("2.5"))
      assert Catalogue.list_item_dependencies(ctx.susan) |> length() == 3
    end

    test "takes the target as raw target_*_uuid keys too, and trims a blank note to nil", ctx do
      [row] =
        put!(ctx.susan, [
          %{"target_category_uuid" => ctx.wood_screws.uuid, "quantity" => "3", "note" => "   "}
        ])

      assert row.target_category_uuid == ctx.wood_screws.uuid
      assert row.note == nil
    end

    test "the readers answer [] or 0 for an unsaved record or a string that is not a uuid",
         ctx do
      # Rows aimed at a catalogue would match a nil compiled to IS NULL.
      put!(ctx.susan, [%{target: {:catalogue, ctx.screws.uuid}, quantity: 1}])

      assert Catalogue.list_item_dependencies("not-a-uuid") == []
      assert Catalogue.list_item_dependencies(%Item{uuid: nil}) == []
      assert Catalogue.list_item_dependents({:catalogue, "not-a-uuid"}) == []
      assert Catalogue.count_outside_dependents(%Item{uuid: nil}) == 0
      assert Catalogue.count_outside_dependents(%Item{uuid: "nope"}) == 0
      assert Catalogue.count_outside_dependents({:categories, ["nope"]}) == 0
    end

    test "the same target twice is allowed — the note tells them apart", ctx do
      rows =
        put!(ctx.susan, [
          %{target: {:catalogue, ctx.screws.uuid}, quantity: 8, note: "for the base"},
          %{target: {:catalogue, ctx.screws.uuid}, quantity: 4, note: "for the top"}
        ])

      assert length(rows) == 2
    end

    test "an unchanged list writes nothing: no activity row and no broadcast", ctx do
      specs = [%{target: {:item, ctx.screw.uuid}, quantity: "8", note: "x"}]
      [first] = put!(ctx.susan, specs, actor_uuid: @actor)
      assert count_logs(ctx.susan.uuid) == 1

      Catalogue.PubSub.subscribe()

      # "8.0" reads as the same amount; the row is not rewritten.
      [again] =
        put!(ctx.susan, [%{target: {:item, ctx.screw.uuid}, quantity: "8.0", note: "x"}])

      assert again.uuid == first.uuid
      assert count_logs(ctx.susan.uuid) == 1
      refute_receive {:catalogue_data_changed, :item, _, _}, 50
    end

    test "a change rewrites the list, logs once with the counts and broadcasts the item", ctx do
      put!(ctx.susan, [%{target: {:item, ctx.screw.uuid}, quantity: 8}], actor_uuid: @actor)
      Catalogue.PubSub.subscribe()

      put!(ctx.susan, [], actor_uuid: @actor)

      assert Catalogue.list_item_dependencies(ctx.susan) == []

      assert_activity_logged("item.dependencies_synced",
        resource_uuid: ctx.susan.uuid,
        actor_uuid: @actor,
        metadata_has: %{"before" => 1, "total" => 0, "name" => "Lazy susan"}
      )

      susan_uuid = ctx.susan.uuid
      assert_receive {:catalogue_data_changed, :item, ^susan_uuid, _}
    end

    test "expected: refuses to overwrite a list someone else changed since it was read", ctx do
      read = Catalogue.list_item_dependencies(ctx.susan)
      put!(ctx.susan, [%{target: {:item, ctx.screw.uuid}, quantity: 8}])

      assert {:error, :dependencies_changed} =
               Catalogue.put_item_dependencies(
                 ctx.susan,
                 [%{target: {:catalogue, ctx.screws.uuid}, quantity: 1}],
                 expected: read
               )

      # The other save stands.
      assert [%{target_item_uuid: screw}] = Catalogue.list_item_dependencies(ctx.susan)
      assert screw == ctx.screw.uuid

      # Read again, the same write goes through.
      fresh = Catalogue.list_item_dependencies(ctx.susan)

      assert {:ok, [%{target_catalogue_uuid: _}]} =
               Catalogue.put_item_dependencies(
                 ctx.susan,
                 [%{target: {:catalogue, ctx.screws.uuid}, quantity: 1}],
                 expected: fresh
               )
    end

    test "two saves of the same new list from the same read are no conflict", ctx do
      read = Catalogue.list_item_dependencies(ctx.susan)
      specs = [%{target: {:item, ctx.screw.uuid}, quantity: 8}]

      assert {:ok, [_]} = Catalogue.put_item_dependencies(ctx.susan, specs, expected: read)
      assert {:ok, [_]} = Catalogue.put_item_dependencies(ctx.susan, specs, expected: read)
    end

    test "a bad row refuses the whole list and writes nothing", ctx do
      put!(ctx.susan, [%{target: {:item, ctx.screw.uuid}, quantity: 8}])

      for bad <- [
            %{target: {:item, ctx.screw.uuid}, quantity: 0},
            %{target: {:item, ctx.screw.uuid}, quantity: "-1"},
            %{target: {:item, ctx.screw.uuid}, quantity: "1.23456"},
            %{target: {:item, ctx.screw.uuid}, quantity: "100000000"},
            %{target: {:item, ctx.screw.uuid}, quantity: nil},
            %{target: {:item, ctx.screw.uuid}, quantity: 1, note: String.duplicate("n", 501)},
            %{target: {:item, ctx.susan.uuid}, quantity: 1},
            %{quantity: 1},
            %{
              target_item_uuid: ctx.screw.uuid,
              target_catalogue_uuid: ctx.screws.uuid,
              quantity: 1
            }
          ] do
        assert {:error, %Ecto.Changeset{valid?: false}} =
                 Catalogue.put_item_dependencies(ctx.susan, [
                   %{target: {:catalogue, ctx.screws.uuid}, quantity: 1},
                   bad
                 ]),
               inspect(bad)

        assert [%{target_item_uuid: screw_uuid}] = Catalogue.list_item_dependencies(ctx.susan)
        assert screw_uuid == ctx.screw.uuid
      end
    end

    test "a target that no longer exists is a changeset error, not a crash", ctx do
      assert {:error, %Ecto.Changeset{}} =
               Catalogue.put_item_dependencies(ctx.susan, [
                 %{target: {:item, Ecto.UUID.generate()}, quantity: 1}
               ])
    end
  end

  describe "trash and permanent delete" do
    test "a trashed target stays listed, with its status", ctx do
      put!(ctx.susan, [%{target: {:item, ctx.screw.uuid}, quantity: 8}])
      {:ok, _} = Catalogue.trash_item(ctx.screw)

      assert [%{target_item: %Item{status: "deleted"}}] =
               Catalogue.list_item_dependencies(ctx.susan)
    end

    test "a permanent delete of the target takes the row with it", ctx do
      put!(ctx.susan, [%{target: {:item, ctx.screw.uuid}, quantity: 8}])
      {:ok, trashed} = Catalogue.trash_item(ctx.screw)
      {:ok, _} = Catalogue.permanently_delete_item(trashed)

      assert Catalogue.list_item_dependencies(ctx.susan) == []
    end

    test "a permanent delete of the owner takes its rows with it", ctx do
      put!(ctx.susan, [%{target: {:item, ctx.screw.uuid}, quantity: 8}])
      {:ok, trashed} = Catalogue.trash_item(ctx.susan)
      {:ok, _} = Catalogue.permanently_delete_item(trashed)

      assert Repo.aggregate(ItemDependency, :count) == 0
    end

    test "count_outside_dependents counts other items that lose a line", ctx do
      other = fixture_item(%{name: "Corner unit", catalogue_uuid: ctx.furniture.uuid})
      put!(ctx.susan, [%{target: {:item, ctx.screw.uuid}, quantity: 8}])
      put!(other, [%{target: {:category, ctx.wood_screws.uuid}, quantity: 2}])

      # An item inside the screws catalogue depending on its own catalogue
      # goes with the delete — not counted.
      sibling = fixture_item(%{name: "Screw box", catalogue_uuid: ctx.screws.uuid})
      put!(sibling, [%{target: {:catalogue, ctx.screws.uuid}, quantity: 1}])

      assert Catalogue.count_outside_dependents(ctx.screw) == 1
      assert Catalogue.count_outside_dependents(ctx.screws) == 2
      assert Catalogue.count_outside_dependents({:categories, [ctx.wood_screws.uuid]}) == 2
      assert Catalogue.count_outside_dependents(ctx.susan) == 0
    end

    test "permanent_delete_scope reports a category's outside dependents", ctx do
      put!(ctx.susan, [%{target: {:item, ctx.screw.uuid}, quantity: 8}])
      assert %{dependents: 1} = Catalogue.permanent_delete_scope(ctx.wood_screws)
    end
  end

  describe "list_item_dependents/1" do
    test "lists the rows naming the target itself, with their items", ctx do
      put!(ctx.susan, [%{target: {:catalogue, ctx.screws.uuid}, quantity: 8}])

      assert [%{item: %Item{name: "Lazy susan"}}] =
               Catalogue.list_item_dependents({:catalogue, ctx.screws.uuid})

      # Naming the catalogue is not naming its category or its items.
      assert Catalogue.list_item_dependents({:category, ctx.wood_screws.uuid}) == []
      assert Catalogue.list_item_dependents({:item, ctx.screw.uuid}) == []
      assert Catalogue.list_item_dependents({:item, "not-a-uuid"}) == []
    end
  end

  describe "duplication" do
    test "copying an item copies its rows with the same targets", ctx do
      put!(ctx.susan, [%{target: {:item, ctx.screw.uuid}, quantity: 8, note: "n"}])
      {:ok, copy} = Catalogue.duplicate_item(ctx.susan)

      assert [%{target_item_uuid: target, note: "n"}] = Catalogue.list_item_dependencies(copy)
      assert target == ctx.screw.uuid
    end

    test "copying a catalogue points a target inside it at the copy, others at the original",
         ctx do
      knob = fixture_item(%{name: "Knob", catalogue_uuid: ctx.furniture.uuid})
      cabinets = fixture_category(ctx.furniture, %{name: "Cabinets"})

      put!(ctx.susan, [
        %{target: {:item, knob.uuid}, quantity: 2},
        %{target: {:category, cabinets.uuid}, quantity: 1},
        %{target: {:catalogue, ctx.furniture.uuid}, quantity: 1},
        %{target: {:item, ctx.screw.uuid}, quantity: 8}
      ])

      {:ok, %{catalogue: copy}} = Catalogue.duplicate_catalogue(ctx.furniture)

      copied_susan =
        Repo.one!(
          from(i in Item, where: i.catalogue_uuid == ^copy.uuid and i.name == "Lazy susan")
        )

      copied_knob =
        Repo.one!(from(i in Item, where: i.catalogue_uuid == ^copy.uuid and i.name == "Knob"))

      [to_knob, to_cabinets, to_catalogue, to_screw] =
        Catalogue.list_item_dependencies(copied_susan)

      assert to_knob.target_item_uuid == copied_knob.uuid
      assert to_cabinets.target_category.catalogue_uuid == copy.uuid
      assert to_catalogue.target_catalogue_uuid == copy.uuid
      assert to_screw.target_item_uuid == ctx.screw.uuid

      # The original is untouched.
      assert [%{target_item_uuid: knob_uuid} | _] = Catalogue.list_item_dependencies(ctx.susan)
      assert knob_uuid == knob.uuid
    end
  end
end
