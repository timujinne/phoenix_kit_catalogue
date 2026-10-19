defmodule PhoenixKitCatalogue.Import.DependencyImportTest do
  @moduledoc """
  The new fields through export and import: the Dependencies cell parser,
  the reference resolver, the Universal JSON export carrying the
  notes for AI and the dependencies, and a full round trip —
  export, parse, map, execute — into another catalogue, where targets are
  found by SKU or name and a missing one is reported, not fatal.
  """

  use PhoenixKitCatalogue.DataCase, async: false

  import PhoenixKitCatalogue.LiveCase,
    only: [fixture_catalogue: 1, fixture_category: 2, fixture_item: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Export
  alias PhoenixKitCatalogue.Import.{DependencyCell, Executor, Mapper}
  alias PhoenixKitCatalogue.Import.Source.Universal

  describe "DependencyCell.parse/1" do
    test "reads typed text: quantity, a times sign, a SKU; ; or a line break between" do
      assert {:ok, [a, b, c]} = DependencyCell.parse("8 × SCREW-4X30; 2,5 x EDGE 22\n3*KNOB")

      assert %{type: "item", sku: "SCREW-4X30"} = a
      assert Decimal.equal?(a.quantity, 8)
      assert %{sku: "EDGE 22"} = b
      assert Decimal.equal?(b.quantity, Decimal.new("2.5"))
      assert %{sku: "KNOB"} = c
    end

    test "reads the export's own JSON list" do
      json =
        Jason.encode!([
          %{
            "type" => "catalogue",
            "uuid" => "u",
            "name" => "Screws",
            "quantity" => "8",
            "note" => "by wood"
          },
          %{"type" => "category", "name" => "Wood", "catalogue" => "Screws", "quantity" => 1}
        ])

      assert {:ok,
              [
                %{type: "catalogue", name: "Screws", note: "by wood"},
                %{type: "category", catalogue: "Screws"}
              ]} =
               DependencyCell.parse(json)
    end

    test "a blank cell is no dependencies; an unreadable entry is named" do
      assert DependencyCell.parse("") == {:ok, []}
      assert DependencyCell.parse("   ") == {:ok, []}
      assert {:error, "eight screws"} = DependencyCell.parse("8 × A; eight screws")
      assert {:error, _} = DependencyCell.parse("0 × A")
      assert {:error, _} = DependencyCell.parse(~s([{"type":"shelf","quantity":1}]))
      assert {:error, _} = DependencyCell.parse("[not json")
    end

    test "what the column would refuse is refused here, so a row never loses its list later" do
      assert {:error, _} = DependencyCell.parse("0.00001 × A")
      assert {:error, _} = DependencyCell.parse("100000000 × A")

      long_note = String.duplicate("n", 501)

      assert {:error, _} =
               DependencyCell.parse(
                 Jason.encode!([
                   %{"type" => "item", "sku" => "A", "quantity" => 1, "note" => long_note}
                 ])
               )

      assert {:ok, [_]} = DependencyCell.parse("0.0001 × A")
    end

    test "a cell is capped at 200 references and 100 000 characters" do
      assert {:ok, refs} = DependencyCell.parse(Enum.map_join(1..200, "; ", &"1 × S#{&1}"))
      assert length(refs) == 200
      assert {:error, _} = DependencyCell.parse(Enum.map_join(1..201, "; ", &"1 × S#{&1}"))
      assert {:error, _} = DependencyCell.parse("1 × " <> String.duplicate("A", 100_001))
    end

    test "a NUL in a JSON note is dropped, not sent to the database" do
      assert {:ok, [%{note: "ab"}]} =
               DependencyCell.parse(
                 ~s([{"type":"item","sku":"A","quantity":1,"note":"a\\u0000b"}])
               )
    end
  end

  describe "Catalogue.resolve_import_ref/2" do
    setup do
      screws = fixture_catalogue(%{name: "Screws"})
      wood = fixture_category(screws, %{name: "Wood"})
      screw = fixture_item(%{name: "Screw", sku: "S-1", catalogue_uuid: screws.uuid})
      %{screws: screws, wood: wood, screw: screw}
    end

    test "the uuid wins; then SKU, catalogue name, category name in its catalogue", ctx do
      assert {:ok, {:item, uuid}} =
               Catalogue.resolve_import_ref(%{type: "item", uuid: ctx.screw.uuid})

      assert uuid == ctx.screw.uuid

      assert {:ok, {:item, uuid}} =
               Catalogue.resolve_import_ref(%{
                 type: "item",
                 uuid: Ecto.UUID.generate(),
                 sku: "S-1"
               })

      assert uuid == ctx.screw.uuid

      assert {:ok, {:catalogue, uuid}} =
               Catalogue.resolve_import_ref(%{type: "catalogue", name: "Screws"})

      assert uuid == ctx.screws.uuid

      assert {:ok, {:category, uuid}} =
               Catalogue.resolve_import_ref(%{
                 type: "category",
                 name: "Wood",
                 catalogue: "Screws"
               })

      assert uuid == ctx.wood.uuid
    end

    test "an ambiguous SKU resolves only to the importing catalogue's one", ctx do
      other = fixture_catalogue(%{name: "Other"})
      twin = fixture_item(%{name: "Twin", sku: "S-1", catalogue_uuid: other.uuid})

      assert {:error, :ambiguous} = Catalogue.resolve_import_ref(%{type: "item", sku: "S-1"})

      assert {:ok, {:item, uuid}} =
               Catalogue.resolve_import_ref(%{type: "item", sku: "S-1"},
                 catalogue_uuid: other.uuid
               )

      assert uuid == twin.uuid
      assert ctx.screw.uuid != twin.uuid
    end

    test "trashed rows and nonsense are never matched", ctx do
      {:ok, _} = Catalogue.trash_item(ctx.screw)

      assert {:error, :not_found} =
               Catalogue.resolve_import_ref(%{type: "item", uuid: ctx.screw.uuid, sku: "S-1"})

      assert {:error, :not_found} = Catalogue.resolve_import_ref(%{type: "item", sku: "NOPE"})
      assert {:error, :not_found} = Catalogue.resolve_import_ref(%{type: "item"})
      assert {:error, :not_found} = Catalogue.resolve_import_ref(%{type: "nonsense", name: "x"})
    end
  end

  describe "export, then import into another catalogue" do
    setup do
      screws = fixture_catalogue(%{name: "Screws", ai_notes: "Back office"})
      screw = fixture_item(%{name: "Screw 4x30", sku: "S-430", catalogue_uuid: screws.uuid})

      furniture = fixture_catalogue(%{name: "Furniture"})

      susan =
        fixture_item(%{
          name: "Lazy susan",
          sku: "LS-1",
          catalogue_uuid: furniture.uuid,
          ai_notes: "Turns 360°"
        })

      knob = fixture_item(%{name: "Knob", sku: "KN-1", catalogue_uuid: furniture.uuid})

      {:ok, _} =
        Catalogue.put_item_dependencies(susan, [
          %{target: {:item, screw.uuid}, quantity: 8, note: "by wood type"},
          %{target: {:item, knob.uuid}, quantity: 2},
          %{target: {:catalogue, screws.uuid}, quantity: "1.5"}
        ])

      {_filename, json, _mime} =
        Export.build(%{
          destination: :universal,
          format: :json,
          catalogue_uuids: [furniture.uuid, screws.uuid]
        })

      %{json: json, screws: screws, screw: screw, susan: susan}
    end

    test "the JSON carries the notes and the dependencies", %{json: json} do
      payload = Jason.decode!(json)

      assert %{"ai_notes" => "Back office"} =
               Enum.find(payload["catalogues"], &(&1["name"] == "Screws"))

      susan = Enum.find(payload["items"], &(&1["name"] == "Lazy susan"))
      assert susan["ai_notes"] == "Turns 360°"

      assert [
               %{
                 "type" => "item",
                 "sku" => "S-430",
                 "quantity" => "8",
                 "note" => "by wood type",
                 "catalogue" => "Screws"
               },
               %{"type" => "item", "sku" => "KN-1"},
               %{"type" => "catalogue", "name" => "Screws", "quantity" => "1.5"}
             ] = susan["dependencies"]
    end

    test "importing the file links the dependencies again, by uuid while the targets exist",
         %{json: json} = ctx do
      target = fixture_catalogue(%{name: "Imported"})
      {:ok, parsed} = Universal.parse(json, "export.json", :json)
      mappings = Mapper.auto_detect_mappings(parsed.headers)

      assert Enum.any?(mappings, &(&1.target == :ai_notes))
      assert Enum.any?(mappings, &(&1.target == :dependencies))

      plan = Mapper.build_import_plan(mappings, parsed.rows)
      assert plan.errors == []

      result = Executor.execute(plan, target.uuid, nil)
      assert result.dependencies_unresolved == []
      assert result.dependencies_linked > 0

      [copy] =
        Catalogue.search_items("Lazy susan", catalogue_uuids: [target.uuid])

      assert copy.ai_notes == "Turns 360°"

      assert [to_screw, to_knob, to_catalogue] = Catalogue.list_item_dependencies(copy)
      # Same database: every exported uuid still names a live row, so each
      # line points at exactly the target it had — not at the imported copy.
      assert to_screw.target_item_uuid == ctx.screw.uuid
      assert to_screw.note == "by wood type"
      assert to_knob.target_item_uuid != nil
      assert Catalogue.get_item(to_knob.target_item_uuid).catalogue_uuid != target.uuid
      assert to_catalogue.target_catalogue_uuid == ctx.screws.uuid
      assert Decimal.equal?(to_catalogue.quantity, Decimal.new("1.5"))
    end

    test "a target that cannot be found is reported by row; the item still imports", ctx do
      target = fixture_catalogue(%{name: "Elsewhere"})
      {:ok, _} = Catalogue.trash_item(ctx.screw)

      payload = Jason.decode!(ctx.json)
      items = Enum.filter(payload["items"], &(&1["name"] == "Lazy susan"))
      # Strip the uuid so only the SKU, now trashed, can find it.
      [susan] =
        Enum.map(items, fn item ->
          update_in(item["dependencies"], fn deps -> Enum.map(deps, &Map.delete(&1, "uuid")) end)
        end)

      {:ok, parsed} =
        Universal.parse(Jason.encode!(%{"items" => [susan]}), "x.json", :json)

      plan = Mapper.build_import_plan(Mapper.auto_detect_mappings(parsed.headers), parsed.rows)
      result = Executor.execute(plan, target.uuid, nil)

      assert result.created == 1
      assert {1, "S-430", :not_found} in result.dependencies_unresolved
    end

    test "an ambiguous SKU is reported as ambiguous, not as missing", ctx do
      other = fixture_catalogue(%{name: "Other"})
      fixture_item(%{name: "Twin screw", sku: "S-430", catalogue_uuid: other.uuid})
      target = fixture_catalogue(%{name: "Third"})

      {:ok, parsed} =
        Universal.parse(
          Jason.encode!(%{
            "items" => [
              %{
                "name" => "Shelf",
                "base_price" => "10.00",
                "dependencies" => [%{"type" => "item", "sku" => "S-430", "quantity" => 1}]
              }
            ]
          }),
          "x.json",
          :json
        )

      plan = Mapper.build_import_plan(Mapper.auto_detect_mappings(parsed.headers), parsed.rows)
      result = Executor.execute(plan, target.uuid, nil)

      assert result.dependencies_unresolved == [{1, "S-430", :ambiguous}]
      _ = ctx
    end
  end

  describe "the report names the file's row" do
    test "a rejected row before it does not shift the row number" do
      catalogue = fixture_catalogue(%{name: "Rows"})
      mappings = Mapper.auto_detect_mappings(["Name", "Price", "Dependencies"])

      rows = [
        ["Bad price", "abc", ""],
        ["Good", "1.00", "1 × MISSING"]
      ]

      plan = Mapper.build_import_plan(mappings, rows)
      result = Executor.execute(plan, catalogue.uuid, nil)

      assert result.dependencies_unresolved == [{2, "MISSING", :not_found}]
    end
  end

  describe "a spreadsheet's Dependencies column" do
    test "auto-detects, reads 8 × SKU and rejects an unreadable cell as a row error" do
      catalogue = fixture_catalogue(%{name: "Sheet"})
      fixture_item(%{name: "Hinge", sku: "H-1", catalogue_uuid: catalogue.uuid})

      headers = ["Name", "SKU", "Notes for AI", "Dependencies"]
      mappings = Mapper.auto_detect_mappings(headers)

      assert Enum.map(mappings, & &1.target) == [:name, :sku, :ai_notes, :dependencies]

      rows = [
        ["Door", "D-1", "Soft close", "2 × H-1"],
        ["Broken", "B-1", "", "two hinges"]
      ]

      plan = Mapper.build_import_plan(mappings, rows)
      assert [{2, {:invalid_dependencies, "two hinges"}}] = plan.errors

      result = Executor.execute(plan, catalogue.uuid, nil)
      assert result.dependencies_linked == 1

      [door] = Catalogue.search_items("Door", catalogue_uuids: [catalogue.uuid])
      assert door.ai_notes == "Soft close"
      assert [%{target_item: %{sku: "H-1"}}] = Catalogue.list_item_dependencies(door)
    end
  end
end
