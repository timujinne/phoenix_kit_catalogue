defmodule PhoenixKitCatalogue.Catalogue.SurfaceBroadcastsTest do
  @moduledoc """
  Pins the `{:catalogue_data_changed, kind, uuid, parent}` fan-out of the
  writes that used to leave a surface stale until reload (2026-08 "as live
  as we can" batch). Every write that changes something a list/detail page
  shows must broadcast — after its transaction commits, never inside it.
  """

  use PhoenixKitCatalogue.DataCase, async: false

  alias PhoenixKitCatalogue.AITranslatable
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.PubSub
  alias PhoenixKitCatalogue.Import.Pro100TemplateLoader
  alias PhoenixKitCatalogue.Import.Pro100TemplateParser
  alias PhoenixKitCatalogue.Import.Pro100TemplatePlan

  setup do
    PubSub.subscribe()
    :ok
  end

  defp catalogue!(name \\ "Cat") do
    {:ok, cat} = Catalogue.create_catalogue(%{name: name})
    cat
  end

  defp category!(cat, name \\ "Sec") do
    {:ok, c} = Catalogue.create_category(%{name: name, catalogue_uuid: cat.uuid})
    c
  end

  defp item!(cat, attrs \\ %{}) do
    {:ok, item} =
      Catalogue.create_item(Map.merge(%{name: "Item", catalogue_uuid: cat.uuid}, attrs))

    item
  end

  # Drop the events the fixtures themselves emitted so the assertions
  # below only see the write under test.
  defp flush do
    receive do
      {:catalogue_data_changed, _, _, _} -> flush()
    after
      0 -> :ok
    end
  end

  describe "F1 — bulk item ops emit one batch :item event per touched catalogue" do
    test "bulk_trash_items" do
      cat = catalogue!()
      other = catalogue!("Other")
      a = item!(cat)
      b = item!(other)
      flush()

      assert {2, nil} = Catalogue.bulk_trash_items([a.uuid, b.uuid], [])

      assert_receive {:catalogue_data_changed, :item, nil, parent1}
      assert_receive {:catalogue_data_changed, :item, nil, parent2}
      assert Enum.sort([parent1, parent2]) == Enum.sort([cat.uuid, other.uuid])
      refute_receive {:catalogue_data_changed, :item, _, _}
    end

    test "bulk_trash_items is silent when nothing changed or when muted" do
      cat = catalogue!()
      a = item!(cat)
      flush()

      assert {0, nil} = Catalogue.bulk_trash_items([Ecto.UUID.generate()], [])
      refute_receive {:catalogue_data_changed, :item, _, _}

      assert {1, nil} = Catalogue.bulk_trash_items([a.uuid], broadcast: false)
      refute_receive {:catalogue_data_changed, :item, _, _}
    end

    test "bulk_restore_items" do
      cat = catalogue!()
      a = item!(cat)
      {1, nil} = Catalogue.bulk_trash_items([a.uuid], broadcast: false)
      flush()

      assert {1, nil} = Catalogue.bulk_restore_items([a.uuid], [])
      assert_receive {:catalogue_data_changed, :item, nil, parent}
      assert parent == cat.uuid
    end

    test "bulk_permanently_delete_items resolves the catalogue before the rows are gone" do
      cat = catalogue!()
      a = item!(cat)
      flush()

      assert {1, nil} = Catalogue.bulk_permanently_delete_items([a.uuid], [])
      assert_receive {:catalogue_data_changed, :item, nil, parent}
      assert parent == cat.uuid
    end

    test "bulk_move_items_to_category — into a category and to uncategorized" do
      cat = catalogue!()
      sec = category!(cat)
      a = item!(cat)
      flush()

      assert {:ok, 1} =
               Catalogue.bulk_move_items_to_category([a.uuid], sec.uuid, catalogue_uuid: cat.uuid)

      assert_receive {:catalogue_data_changed, :item, nil, parent}
      assert parent == cat.uuid

      assert {:ok, 1} =
               Catalogue.bulk_move_items_to_category([a.uuid], nil, catalogue_uuid: cat.uuid)

      assert_receive {:catalogue_data_changed, :item, nil, parent}
      assert parent == cat.uuid

      assert {:ok, 1} =
               Catalogue.bulk_move_items_to_category([a.uuid], sec.uuid,
                 catalogue_uuid: cat.uuid,
                 broadcast: false
               )

      refute_receive {:catalogue_data_changed, :item, _, _}
    end

    test "trash_items_in_category carries the category's catalogue as parent" do
      cat = catalogue!()
      sec = category!(cat)
      _a = item!(cat, %{category_uuid: sec.uuid})
      flush()

      assert {1, nil} = Catalogue.trash_items_in_category(sec.uuid)
      assert_receive {:catalogue_data_changed, :item, nil, parent}
      assert parent == cat.uuid
    end

    test "reorder_categories_groups emits a batch :category event" do
      cat = catalogue!()
      a = category!(cat, "A")
      b = category!(cat, "B")
      flush()

      assert :ok = Catalogue.reorder_categories_groups(cat.uuid, [{nil, [b.uuid, a.uuid]}])
      assert_receive {:catalogue_data_changed, :category, nil, parent}
      assert parent == cat.uuid
    end
  end

  describe "F11 — single manufacturer↔supplier link writes broadcast :links like the syncs" do
    setup do
      {:ok, m} = Catalogue.create_manufacturer(%{name: "Mfr"})
      {:ok, s} = Catalogue.create_supplier(%{name: "Sup"})
      flush()
      %{m: m, s: s}
    end

    test "link / unlink", %{m: m, s: s} do
      assert {:ok, _} = Catalogue.link_manufacturer_supplier(m.uuid, s.uuid)
      assert_receive {:catalogue_data_changed, :links, uuid, nil}
      assert uuid == m.uuid

      assert {:ok, _} = Catalogue.unlink_manufacturer_supplier(m.uuid, s.uuid)
      assert_receive {:catalogue_data_changed, :links, uuid, nil}
      assert uuid == m.uuid

      # A miss writes nothing and says nothing.
      assert {:error, :not_found} = Catalogue.unlink_manufacturer_supplier(m.uuid, s.uuid)
      refute_receive {:catalogue_data_changed, :links, _, _}
    end

    test "broadcast: false mutes a single link", %{m: m, s: s} do
      assert {:ok, _} = Catalogue.link_manufacturer_supplier(m.uuid, s.uuid, broadcast: false)
      refute_receive {:catalogue_data_changed, :links, _, _}
    end

    test "delete_links_for broadcasts only when a link was actually removed", %{m: m, s: s} do
      assert {0, nil} = Catalogue.delete_manufacturer_supplier_links_for(s.uuid)
      refute_receive {:catalogue_data_changed, :links, _, _}

      {:ok, _} = Catalogue.link_manufacturer_supplier(m.uuid, s.uuid, broadcast: false)
      assert {1, nil} = Catalogue.delete_manufacturer_supplier_links_for(s.uuid)
      assert_receive {:catalogue_data_changed, :links, uuid, nil}
      assert uuid == s.uuid
    end

    test "a sync still emits exactly one :links event (per-link writes stay muted)",
         %{m: m, s: s} do
      assert {:ok, :synced} = Catalogue.sync_manufacturer_suppliers(m.uuid, [s.uuid])
      assert_receive {:catalogue_data_changed, :links, uuid, nil}
      assert uuid == m.uuid
      refute_receive {:catalogue_data_changed, :links, _, _}
    end

    test "deleting a party announces its removed links after the commit", %{m: m, s: s} do
      {:ok, _} = Catalogue.link_manufacturer_supplier(m.uuid, s.uuid, broadcast: false)

      assert {:ok, _} = Catalogue.delete_supplier(s)
      assert_receive {:catalogue_data_changed, :supplier, _, nil}
      assert_receive {:catalogue_data_changed, :links, uuid, nil}
      assert uuid == s.uuid

      # No links left on the manufacturer — its delete says nothing about links.
      assert {:ok, _} = Catalogue.delete_manufacturer(m)
      assert_receive {:catalogue_data_changed, :manufacturer, _, nil}
      refute_receive {:catalogue_data_changed, :links, _, _}
    end
  end

  describe "F5 — an AI translation write announces the resource it localized" do
    test "catalogue / category / item" do
      cat = catalogue!()
      sec = category!(cat)
      item = item!(cat)
      flush()

      assert {:ok, _} = AITranslatable.put_translation(cat, "et", %{"name" => "Kass"}, [])
      assert_receive {:catalogue_data_changed, :catalogue, uuid, parent}
      assert {uuid, parent} == {cat.uuid, cat.uuid}

      assert {:ok, _} = AITranslatable.put_translation(sec, "et", %{"name" => "Jagu"}, [])
      assert_receive {:catalogue_data_changed, :category, uuid, parent}
      assert {uuid, parent} == {sec.uuid, cat.uuid}

      assert {:ok, _} = AITranslatable.put_translation(item, "et", %{"name" => "Asi"}, [])
      assert_receive {:catalogue_data_changed, :item, uuid, parent}
      assert {uuid, parent} == {item.uuid, cat.uuid}
    end

    test "group / attribute / value all announce the owning group" do
      {:ok, group} = Catalogue.create_attribute_group(%{name: "Doors"})
      {:ok, attribute} = Catalogue.create_attribute(group, %{"name" => "Color"})
      {:ok, value} = Catalogue.create_attribute_value(attribute, %{"value" => "Oak"})
      flush()

      for {resource, fields} <- [
            {group, %{"name" => "Uksed"}},
            {attribute, %{"name" => "Värv"}},
            {value, %{"value" => "Tamm"}}
          ] do
        assert {:ok, _} = AITranslatable.put_translation(resource, "et", fields, [])
        assert_receive {:catalogue_data_changed, :attribute_group, uuid, nil}
        assert uuid == group.uuid
      end
    end

    test "a vanished row rolls back and stays silent" do
      cat = catalogue!()
      item = item!(cat)
      {1, nil} = Catalogue.bulk_permanently_delete_items([item.uuid], broadcast: false)
      flush()

      assert {:error, :resource_not_found} =
               AITranslatable.put_translation(item, "et", %{"name" => "Asi"}, [])

      refute_receive {:catalogue_data_changed, _, _, _}
    end
  end

  describe "F12 — the PRO100 template loader rolls its fan-out up after commit" do
    @pro100_xml """
    <?xml version="1.0"?>
    <ArrayOfTable>
      <Table>
        <Name>Roll-up Table</Name>
        <TemplateGuid>tbl-rollup</TemplateGuid>
        <Id>1</Id>
        <SortOrder>0</SortOrder>
        <Items>
          <TableItem>
            <Name>Sektsioon:</Name>
            <Price>0.00</Price>
            <TemplateGuid>g-sec</TemplateGuid>
            <SortOrder>1</SortOrder>
          </TableItem>
          <TableItem>
            <Name>-CARGO</Name>
            <Price>24.80</Price>
            <TemplateGuid>g-cargo</TemplateGuid>
            <SortOrder>2</SortOrder>
          </TableItem>
        </Items>
      </Table>
    </ArrayOfTable>
    """

    defp pro100_plan do
      {:ok, tables} = Pro100TemplateParser.parse(@pro100_xml)

      Pro100TemplatePlan.build(tables,
        folder_name: "PRO100 rollup #{System.unique_integer([:positive])}"
      )
    end

    test "a dry run says nothing" do
      assert {:ok, _report} = Pro100TemplateLoader.apply_plan(pro100_plan(), dry_run: true)
      refute_receive {:catalogue_data_changed, _, _, _}
    end

    test "a real run emits :folder (created) + one :catalogue roll-up, never the row events" do
      plan = pro100_plan()

      assert {:ok, %{stats: %{catalogues_created: 1, categories_created: 1, items_created: 1}}} =
               Pro100TemplateLoader.apply_plan(plan, dry_run: false)

      assert_receive {:catalogue_data_changed, :folder, folder_uuid, nil}
      assert %{name: _} = Catalogue.get_folder(folder_uuid)
      assert_receive {:catalogue_data_changed, :catalogue, cat_uuid, parent}
      assert parent == cat_uuid
      assert [%{name: "-CARGO"}] = Catalogue.list_items_for_catalogue(cat_uuid)

      refute_receive {:catalogue_data_changed, :category, _, _}
      refute_receive {:catalogue_data_changed, :item, _, _}
      refute_receive {:catalogue_data_changed, _, _, _}

      # Second run: folder + catalogue reused — the catalogue still rolls
      # up (its rows were re-checked), the folder was not created again.
      assert {:ok, %{stats: %{catalogues_reused: 1}}} =
               Pro100TemplateLoader.apply_plan(plan, dry_run: false)

      assert_receive {:catalogue_data_changed, :catalogue, ^cat_uuid, ^cat_uuid}
      refute_receive {:catalogue_data_changed, :folder, _, _}
    end
  end

  describe "F13 — bulk_trash_categories broadcasts after the outer transaction commits" do
    test "one :category batch event per touched catalogue, after commit" do
      cat = catalogue!()
      a = category!(cat, "A")
      b = category!(cat, "B")
      flush()

      assert {:ok, %{categories: 2}} =
               Catalogue.bulk_trash_categories([a.uuid, b.uuid], :cascade, [])

      # Like the other bulk ops: one nil-uuid batch per catalogue, not one
      # event per category (N events = N reloads on every open page).
      cat_uuid = cat.uuid
      assert_receive {:catalogue_data_changed, :category, nil, ^cat_uuid}
      refute_receive {:catalogue_data_changed, :category, _, _}, 100
    end

    test "a rolled-back batch emits nothing for the steps that had succeeded" do
      cat = catalogue!()
      other = catalogue!("Other")
      a = category!(cat, "A")
      target = category!(cat, "Target")
      foreign = category!(other, "Foreign")
      flush()

      # Step 1 (a → move into target) succeeds; step 2 (foreign → target
      # lives in another catalogue) fails and rolls the whole batch back.
      assert {:error, :cross_catalogue_move} =
               Catalogue.bulk_trash_categories(
                 [a.uuid, foreign.uuid],
                 {:move_to, target.uuid},
                 []
               )

      assert Catalogue.get_category(a.uuid).status == "active"
      refute_receive {:catalogue_data_changed, :category, _, _}
    end

    test "broadcast: false mutes the batch" do
      cat = catalogue!()
      a = category!(cat, "A")
      flush()

      assert {:ok, %{categories: 1}} =
               Catalogue.bulk_trash_categories([a.uuid], :cascade, broadcast: false)

      refute_receive {:catalogue_data_changed, :category, _, _}
    end
  end
end
