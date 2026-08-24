defmodule PhoenixKitCatalogue.ItemSupplierInfosTest do
  @moduledoc """
  Tests for the ItemSupplierInfos context and ItemSupplierInfo schema/changeset.
  Covers CRUD, set_primary uniqueness guarantee, and the Suppliers facade.
  """

  use PhoenixKitCatalogue.DataCase, async: true

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.ItemSupplierInfos
  alias PhoenixKitCatalogue.Catalogue.Suppliers
  alias PhoenixKitCatalogue.Schemas.ItemSupplierInfo

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp create_catalogue do
    {:ok, c} =
      Catalogue.create_catalogue(%{
        name: "Test Cat #{System.unique_integer([:positive])}"
      })

    c
  end

  defp create_item(catalogue) do
    {:ok, item} =
      Catalogue.create_item(%{
        name: "Item #{System.unique_integer([:positive])}",
        catalogue_uuid: catalogue.uuid
      })

    item
  end

  defp create_supplier do
    {:ok, s} =
      Catalogue.create_supplier(%{name: "Supplier #{System.unique_integer([:positive])}"})

    s
  end

  defp create_info(item, supplier, attrs \\ %{}) do
    base = %{
      "item_uuid" => item.uuid,
      "supplier_uuid" => supplier.uuid,
      "supplier_source" => "local",
      "supplier_name_snapshot" => supplier.name
    }

    {:ok, info} = ItemSupplierInfos.create(Map.merge(base, attrs))
    info
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Schema / changeset
  # ═══════════════════════════════════════════════════════════════════════════

  describe "ItemSupplierInfo.changeset/2" do
    test "requires item_uuid, supplier_uuid, supplier_source" do
      cs = ItemSupplierInfo.changeset(%ItemSupplierInfo{}, %{})
      refute cs.valid?
      errors = Ecto.Changeset.traverse_errors(cs, fn {m, _} -> m end)
      assert errors[:item_uuid]
      assert errors[:supplier_uuid]

      # `supplier_source` is in @required_fields but the field declares
      # `default: "local"`, so a fresh struct already satisfies
      # validate_required/2 and an empty-attrs changeset can never produce
      # this error. The requirement only bites when a caller blanks it
      # explicitly, which is what is asserted here instead.
      refute errors[:supplier_source]

      blanked = ItemSupplierInfo.changeset(%ItemSupplierInfo{}, %{supplier_source: nil})
      blanked_errors = Ecto.Changeset.traverse_errors(blanked, fn {m, _} -> m end)
      assert blanked_errors[:supplier_source]
    end

    test "rejects invalid supplier_source" do
      cs =
        ItemSupplierInfo.changeset(%ItemSupplierInfo{}, %{
          item_uuid: UUIDv7.generate(),
          supplier_uuid: UUIDv7.generate(),
          supplier_source: "bogus"
        })

      refute cs.valid?
    end

    test "accepts all valid supplier_sources" do
      for src <- ~w(crm_company crm_contact local) do
        cs =
          ItemSupplierInfo.changeset(%ItemSupplierInfo{}, %{
            item_uuid: UUIDv7.generate(),
            supplier_uuid: UUIDv7.generate(),
            supplier_source: src
          })

        assert cs.valid?, "expected source #{src} to be valid"
      end
    end

    test "rejects negative unit_cost" do
      cs =
        ItemSupplierInfo.changeset(%ItemSupplierInfo{}, %{
          item_uuid: UUIDv7.generate(),
          supplier_uuid: UUIDv7.generate(),
          supplier_source: "local",
          unit_cost: -1
        })

      refute cs.valid?
    end

    test "accepts zero unit_cost" do
      cs =
        ItemSupplierInfo.changeset(%ItemSupplierInfo{}, %{
          item_uuid: UUIDv7.generate(),
          supplier_uuid: UUIDv7.generate(),
          supplier_source: "local",
          unit_cost: 0
        })

      assert cs.valid?
    end

    test "rejects invalid currency (non-3-uppercase)" do
      cs =
        ItemSupplierInfo.changeset(%ItemSupplierInfo{}, %{
          item_uuid: UUIDv7.generate(),
          supplier_uuid: UUIDv7.generate(),
          supplier_source: "local",
          currency: "eu"
        })

      refute cs.valid?
    end

    test "accepts valid 3-uppercase currency" do
      cs =
        ItemSupplierInfo.changeset(%ItemSupplierInfo{}, %{
          item_uuid: UUIDv7.generate(),
          supplier_uuid: UUIDv7.generate(),
          supplier_source: "local",
          currency: "EUR"
        })

      assert cs.valid?
    end

    test "rejects valid_to before valid_from" do
      cs =
        ItemSupplierInfo.changeset(%ItemSupplierInfo{}, %{
          item_uuid: UUIDv7.generate(),
          supplier_uuid: UUIDv7.generate(),
          supplier_source: "local",
          valid_from: ~D[2026-06-01],
          valid_to: ~D[2026-05-01]
        })

      refute cs.valid?
    end

    test "accepts valid_from == valid_to" do
      cs =
        ItemSupplierInfo.changeset(%ItemSupplierInfo{}, %{
          item_uuid: UUIDv7.generate(),
          supplier_uuid: UUIDv7.generate(),
          supplier_source: "local",
          valid_from: ~D[2026-06-01],
          valid_to: ~D[2026-06-01]
        })

      assert cs.valid?
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Context CRUD
  # ═══════════════════════════════════════════════════════════════════════════

  describe "ItemSupplierInfos context" do
    test "create/1 persists a row" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()

      assert {:ok, info} =
               ItemSupplierInfos.create(%{
                 "item_uuid" => item.uuid,
                 "supplier_uuid" => supplier.uuid,
                 "supplier_source" => "local"
               })

      assert info.item_uuid == item.uuid
      assert info.supplier_uuid == supplier.uuid
      # The first linked supplier is auto-promoted to primary.
      assert info.is_primary == true
    end

    test "create/1 does not steal primary from an existing row" do
      cat = create_catalogue()
      item = create_item(cat)
      s1 = create_supplier()
      s2 = create_supplier()

      {:ok, first} =
        ItemSupplierInfos.create(%{
          "item_uuid" => item.uuid,
          "supplier_uuid" => s1.uuid,
          "supplier_source" => "local"
        })

      {:ok, second} =
        ItemSupplierInfos.create(%{
          "item_uuid" => item.uuid,
          "supplier_uuid" => s2.uuid,
          "supplier_source" => "local"
        })

      assert first.is_primary == true
      assert second.is_primary == false
    end

    test "create/1 with is_primary while a primary exists returns a changeset error" do
      cat = create_catalogue()
      item = create_item(cat)
      s1 = create_supplier()
      s2 = create_supplier()

      {:ok, _first} =
        ItemSupplierInfos.create(%{
          "item_uuid" => item.uuid,
          "supplier_uuid" => s1.uuid,
          "supplier_source" => "local"
        })

      assert {:error, %Ecto.Changeset{errors: errors}} =
               ItemSupplierInfos.create(%{
                 "item_uuid" => item.uuid,
                 "supplier_uuid" => s2.uuid,
                 "supplier_source" => "local",
                 "is_primary" => true
               })

      assert Keyword.has_key?(errors, :item_uuid)
    end

    test "list_for_item/1 returns rows ordered by position then inserted_at" do
      cat = create_catalogue()
      item = create_item(cat)
      s1 = create_supplier()
      s2 = create_supplier()

      info1 = create_info(item, s1, %{"position" => 2})
      info2 = create_info(item, s2, %{"position" => 1})

      infos = ItemSupplierInfos.list_for_item(item.uuid)
      assert [^info2, ^info1] = infos
    end

    test "get/1 fetches by uuid" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()
      info = create_info(item, supplier)

      assert %ItemSupplierInfo{} = ItemSupplierInfos.get(info.uuid)
    end

    test "get/1 returns nil for unknown uuid" do
      assert is_nil(ItemSupplierInfos.get(UUIDv7.generate()))
    end

    test "update/2 changes fields" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()
      info = create_info(item, supplier)

      assert {:ok, updated} = ItemSupplierInfos.update(info, %{"supplier_sku" => "NEW-SKU"})
      assert updated.supplier_sku == "NEW-SKU"
    end

    # Removal CLOSES the row (like a price revision closes the one it
    # supersedes) rather than deleting it: the row carries the pair's
    # comment thread, and every "current" reader filters on valid_to.
    test "delete/1 closes the row: gone from the item, kept in the pair's history" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()
      info = create_info(item, supplier)

      assert {:ok, closed} = ItemSupplierInfos.delete(info)
      assert closed.valid_to == Date.utc_today()
      assert ItemSupplierInfos.list_for_item(item.uuid) == []
      assert %ItemSupplierInfo{valid_to: %Date{}} = ItemSupplierInfos.get(info.uuid)

      assert [%ItemSupplierInfo{uuid: uuid}] =
               ItemSupplierInfos.history_for_pair(item.uuid, supplier.uuid)

      assert uuid == info.uuid
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # set_primary
  # ═══════════════════════════════════════════════════════════════════════════

  describe "set_primary/1" do
    test "sets is_primary on the target row" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()
      info = create_info(item, supplier)

      assert {:ok, updated} = ItemSupplierInfos.set_primary(info)
      assert updated.is_primary
    end

    test "clears existing primary before setting new one" do
      cat = create_catalogue()
      item = create_item(cat)
      s1 = create_supplier()
      s2 = create_supplier()

      info1 = create_info(item, s1)
      info2 = create_info(item, s2)

      {:ok, _} = ItemSupplierInfos.set_primary(info1)
      {:ok, _} = ItemSupplierInfos.set_primary(info2)

      # Only info2 should be primary now
      assert ItemSupplierInfos.get(info2.uuid).is_primary
      refute ItemSupplierInfos.get(info1.uuid).is_primary
    end

    test "only one primary per item after multiple set_primary calls" do
      cat = create_catalogue()
      item = create_item(cat)
      s1 = create_supplier()
      s2 = create_supplier()
      s3 = create_supplier()

      info1 = create_info(item, s1)
      info2 = create_info(item, s2)
      info3 = create_info(item, s3)

      {:ok, _} = ItemSupplierInfos.set_primary(info1)
      {:ok, _} = ItemSupplierInfos.set_primary(info2)
      {:ok, _} = ItemSupplierInfos.set_primary(info3)

      primaries =
        ItemSupplierInfos.list_for_item(item.uuid)
        |> Enum.filter(& &1.is_primary)

      assert length(primaries) == 1
      assert hd(primaries).uuid == info3.uuid
    end

    test "primary_for_item/1 returns the primary row" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()
      info = create_info(item, supplier)
      {:ok, _} = ItemSupplierInfos.set_primary(info)

      assert %ItemSupplierInfo{uuid: uuid} = ItemSupplierInfos.primary_for_item(item.uuid)
      assert uuid == info.uuid
    end

    test "primary_for_item/1 returns nil when the primary is demoted" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()
      # First row is auto-promoted; explicitly demote it.
      info = create_info(item, supplier)
      {:ok, _} = ItemSupplierInfos.update(info, %{"is_primary" => false})

      assert is_nil(ItemSupplierInfos.primary_for_item(item.uuid))
    end

    test "returns {:error, :not_current} for a closed revision" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()
      info = create_info(item, supplier)
      {:ok, closed} = ItemSupplierInfos.delete(info)

      assert {:error, :not_current} = ItemSupplierInfos.set_primary(closed)
      assert is_nil(ItemSupplierInfos.primary_for_item(item.uuid))
    end

    test "refuses a stale in-memory current row that has been closed since" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()
      info = create_info(item, supplier)
      assert is_nil(info.valid_to)

      {:ok, _} = ItemSupplierInfos.delete(ItemSupplierInfos.get(info.uuid))

      assert {:error, :not_current} = ItemSupplierInfos.set_primary(info)
      assert is_nil(ItemSupplierInfos.primary_for_item(item.uuid))
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Suppliers facade
  # ═══════════════════════════════════════════════════════════════════════════

  describe "Suppliers.resolve/1 — local path" do
    test "resolves a local supplier" do
      supplier = create_supplier()

      assert {:ok, resolved} = Suppliers.resolve(supplier.uuid)
      assert resolved.uuid == supplier.uuid
      assert resolved.name == supplier.name
      assert resolved.source == :local
      assert is_nil(resolved.email)
    end

    test "returns :error for unknown uuid" do
      assert :error = Suppliers.resolve(UUIDv7.generate())
    end
  end

  describe "Suppliers.resolve/1 — guarded CRM path (CRM absent)" do
    test "falls back to local when the uuid isn't a known CRM party" do
      # test/support/fake_crm_party_roles.ex makes `PhoenixKitCRM.PartyRoles`
      # loaded for the whole suite, so this exercises the guard's "checked
      # CRM, found nothing" branch rather than "module not loaded" — a real
      # host without phoenix_kit_crm installed hits `crm_available?() ==
      # false` instead and short-circuits before ever calling `get_supplier/1`.
      supplier = create_supplier()
      assert {:ok, %{source: :local}} = Suppliers.resolve(supplier.uuid)
    end
  end

  describe "Suppliers.resolve/1 — guarded CRM path (CRM present)" do
    test "resolves a CRM-sourced supplier with the generic :crm tag" do
      # Fixture uuid from FakeCrmPartyRoles.get_supplier/1.
      assert {:ok, resolved} = Suppliers.resolve("11111111-1111-7111-8111-111111111111")
      assert resolved.name == "Acme Supply Co"
      assert resolved.email == "sales@acme.test"
      assert resolved.source == :crm
    end
  end

  describe "Suppliers.list_all/0" do
    test "includes local suppliers" do
      s1 = create_supplier()
      s2 = create_supplier()

      all = Suppliers.list_all()
      uuids = Enum.map(all, & &1.uuid)

      assert s1.uuid in uuids
      assert s2.uuid in uuids
    end

    test "each entry has required keys" do
      _supplier = create_supplier()

      all = Suppliers.list_all()
      assert Enum.all?(all, &Map.has_key?(&1, :uuid))
      assert Enum.all?(all, &Map.has_key?(&1, :name))
      assert Enum.all?(all, &Map.has_key?(&1, :source))
    end

    test "tags CRM companies and contacts distinctly, not lumped as :crm_company" do
      all = Suppliers.list_all()
      by_uuid = Map.new(all, &{&1.uuid, &1})

      assert by_uuid["11111111-1111-7111-8111-111111111111"].source == :crm_company
      assert by_uuid["33333333-3333-7333-8333-333333333333"].source == :crm_contact
    end

    test "falls back to a placeholder name for blank CRM company/contact names" do
      all = Suppliers.list_all()
      by_uuid = Map.new(all, &{&1.uuid, &1})

      assert by_uuid["22222222-2222-7222-8222-222222222222"].name == "Unnamed"
      # Blank-named contact falls back to its email, mirroring
      # `PhoenixKitCRM.Schemas.Contact.display_name/1`.
      assert by_uuid["44444444-4444-7444-8444-444444444444"].name == "anon@example.test"
    end
  end

  describe "Suppliers.primary_for_item/1" do
    test "delegates to ItemSupplierInfos.primary_for_item/1" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()
      info = create_info(item, supplier)
      {:ok, _} = ItemSupplierInfos.set_primary(info)

      result = Suppliers.primary_for_item(item.uuid)
      assert result.uuid == info.uuid
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # revise_unit_cost
  # ═══════════════════════════════════════════════════════════════════════════

  describe "ItemSupplierInfos.revise_unit_cost/3" do
    test "closes the current row and inserts a successor with the new cost" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()
      info = create_info(item, supplier, %{"unit_cost" => "10.00", "currency" => "EUR"})

      new_cost = Decimal.new("12.50")
      assert {:ok, successor} = ItemSupplierInfos.revise_unit_cost(info, new_cost)

      # Successor has the new cost and is current
      assert Decimal.equal?(successor.unit_cost, new_cost)
      assert is_nil(successor.valid_to)
      assert successor.valid_from == Date.utc_today()
      assert successor.currency == "EUR"

      # Original row is now closed
      closed = ItemSupplierInfos.get(info.uuid)
      assert closed.valid_to == Date.utc_today()
      assert closed.is_primary == false
    end

    test "carries over is_primary: true from the closed row to the successor" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()
      info = create_info(item, supplier, %{"unit_cost" => "5.00"})

      # First row is auto-promoted to primary
      info = ItemSupplierInfos.get(info.uuid)
      assert info.is_primary == true

      assert {:ok, successor} = ItemSupplierInfos.revise_unit_cost(info, Decimal.new("6.00"))

      assert successor.is_primary == true
      refute ItemSupplierInfos.get(info.uuid).is_primary
    end

    test "non-primary row: successor is also non-primary" do
      cat = create_catalogue()
      item = create_item(cat)
      s1 = create_supplier()
      s2 = create_supplier()

      _primary = create_info(item, s1)
      secondary = create_info(item, s2)

      assert secondary.is_primary == false
      assert {:ok, successor} = ItemSupplierInfos.revise_unit_cost(secondary, Decimal.new("9.00"))
      assert successor.is_primary == false
    end

    test "returns {:error, :not_current} when valid_to is set" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()
      info = create_info(item, supplier, %{"unit_cost" => "10.00"})

      # Manually close the row
      {:ok, closed} = ItemSupplierInfos.update(info, %{"valid_to" => Date.utc_today()})

      assert {:error, :not_current} =
               ItemSupplierInfos.revise_unit_cost(closed, Decimal.new("15.00"))
    end

    test "returns {:ok, info} unchanged when new_cost equals existing unit_cost (no-op)" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()
      info = create_info(item, supplier, %{"unit_cost" => "10.00"})

      assert {:ok, ^info} = ItemSupplierInfos.revise_unit_cost(info, Decimal.new("10.00"))

      # No new row was created
      assert length(ItemSupplierInfos.history_for_pair(item.uuid, supplier.uuid)) == 1
    end

    test "no-op when unit_cost is nil and new_cost is zero" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()
      info = create_info(item, supplier)

      assert {:ok, ^info} = ItemSupplierInfos.revise_unit_cost(info, Decimal.new(0))
    end

    test "same cost but different currency still creates a revision (not a no-op)" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()
      info = create_info(item, supplier, %{"unit_cost" => "10.00", "currency" => "EUR"})

      assert {:ok, successor} =
               ItemSupplierInfos.revise_unit_cost(info, Decimal.new("10.00"), currency: "USD")

      refute successor.uuid == info.uuid
      assert successor.currency == "USD"
      assert Decimal.equal?(successor.unit_cost, Decimal.new("10.00"))

      closed = ItemSupplierInfos.get(info.uuid)
      assert closed.valid_to == Date.utc_today()

      assert length(ItemSupplierInfos.history_for_pair(item.uuid, supplier.uuid)) == 2
    end

    test "stores new currency when opts[:currency] differs" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()
      info = create_info(item, supplier, %{"unit_cost" => "10.00", "currency" => "EUR"})

      assert {:ok, successor} =
               ItemSupplierInfos.revise_unit_cost(info, Decimal.new("8.00"), currency: "USD")

      assert successor.currency == "USD"
    end

    test "keeps original currency when opts[:currency] is same as existing" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()
      info = create_info(item, supplier, %{"unit_cost" => "10.00", "currency" => "EUR"})

      assert {:ok, successor} =
               ItemSupplierInfos.revise_unit_cost(info, Decimal.new("8.00"), currency: "EUR")

      assert successor.currency == "EUR"
    end

    test "copies item_uuid, supplier_uuid, supplier_source, sku, lead_time_days, min_order_qty, position" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()

      info =
        create_info(item, supplier, %{
          "unit_cost" => "10.00",
          "supplier_sku" => "SKU-1",
          "lead_time_days" => 7,
          "min_order_qty" => "3.0",
          "position" => 2
        })

      assert {:ok, successor} = ItemSupplierInfos.revise_unit_cost(info, Decimal.new("11.00"))

      assert successor.item_uuid == info.item_uuid
      assert successor.supplier_uuid == info.supplier_uuid
      assert successor.supplier_source == info.supplier_source
      assert successor.supplier_sku == info.supplier_sku
      assert successor.lead_time_days == info.lead_time_days
      assert Decimal.equal?(successor.min_order_qty, info.min_order_qty)
      assert successor.position == info.position
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # history_for_pair
  # ═══════════════════════════════════════════════════════════════════════════

  describe "history_for_pair/2" do
    test "returns all rows for a pair ordered newest-first (current then closed)" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()
      info = create_info(item, supplier, %{"unit_cost" => "10.00"})

      {:ok, successor} = ItemSupplierInfos.revise_unit_cost(info, Decimal.new("12.00"))
      {:ok, _successor2} = ItemSupplierInfos.revise_unit_cost(successor, Decimal.new("14.00"))

      rows = ItemSupplierInfos.history_for_pair(item.uuid, supplier.uuid)
      assert length(rows) == 3

      # Most recent (current, valid_to nil) is first
      assert is_nil(hd(rows).valid_to)
      assert Decimal.equal?(hd(rows).unit_cost, Decimal.new("14.00"))
    end

    # The intermittent failure this function had. Every tiebreak column is
    # forced to tie, and the CURRENT row is given the LOWEST uuid — which is
    # what actually happens when two revisions land in the same millisecond,
    # because UUIDv7 is only time-ordered to the millisecond and the tail
    # below that is random. Under the old ordering (`valid_from` leading, and
    # `desc: :uuid` deciding) the current row sorted LAST here.
    test "the current row sorts first even when every tiebreak column ties" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()
      repo = PhoenixKit.RepoHelper.repo()

      stamp = ~U[2026-08-21 12:00:00Z]
      today = Date.utc_today()

      [lowest, middle, highest] =
        Enum.sort([UUIDv7.generate(), UUIDv7.generate(), UUIDv7.generate()])

      # current row gets `lowest`, so uuid ordering argues against it.
      for {uuid, cost, valid_to} <- [
            {lowest, "14.00", nil},
            {middle, "12.00", today},
            {highest, "10.00", today}
          ] do
        {:ok, _row} =
          %ItemSupplierInfo{}
          |> ItemSupplierInfo.changeset(%{
            "item_uuid" => item.uuid,
            "supplier_uuid" => supplier.uuid,
            "supplier_source" => "local",
            "unit_cost" => cost,
            "valid_from" => today,
            "valid_to" => valid_to
          })
          |> Ecto.Changeset.put_change(:uuid, uuid)
          |> Ecto.Changeset.put_change(:inserted_at, stamp)
          |> Ecto.Changeset.put_change(:updated_at, stamp)
          |> repo.insert()
      end

      [first | _] = ItemSupplierInfos.history_for_pair(item.uuid, supplier.uuid)

      assert is_nil(first.valid_to)
      assert Decimal.equal?(first.unit_cost, Decimal.new("14.00"))
    end

    test "does not include rows from a different supplier" do
      cat = create_catalogue()
      item = create_item(cat)
      s1 = create_supplier()
      s2 = create_supplier()

      info1 = create_info(item, s1, %{"unit_cost" => "10.00"})
      _info2 = create_info(item, s2, %{"unit_cost" => "20.00"})

      {:ok, _} = ItemSupplierInfos.revise_unit_cost(info1, Decimal.new("11.00"))

      rows = ItemSupplierInfos.history_for_pair(item.uuid, s1.uuid)
      assert length(rows) == 2
      assert Enum.all?(rows, &(&1.supplier_uuid == s1.uuid))
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # list_for_item current-only
  # ═══════════════════════════════════════════════════════════════════════════

  describe "list_for_item/1 current-only filter" do
    test "excludes closed rows after a cost revision" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()
      info = create_info(item, supplier, %{"unit_cost" => "10.00"})

      {:ok, _successor} = ItemSupplierInfos.revise_unit_cost(info, Decimal.new("12.00"))

      rows = ItemSupplierInfos.list_for_item(item.uuid)
      # Only the current (successor) row should appear
      assert length(rows) == 1
      assert Decimal.equal?(hd(rows).unit_cost, Decimal.new("12.00"))
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # primary_for_item current-only
  # ═══════════════════════════════════════════════════════════════════════════

  describe "primary_for_item/1 current-only filter" do
    test "returns nil when only a closed primary row exists" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()
      info = create_info(item, supplier, %{"unit_cost" => "10.00"})

      # info is auto-primary; now close it manually (simulates partial state)
      {:ok, _} =
        ItemSupplierInfos.update(info, %{"is_primary" => true, "valid_to" => Date.utc_today()})

      assert is_nil(ItemSupplierInfos.primary_for_item(item.uuid))
    end

    test "returns current primary after revision" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()
      info = create_info(item, supplier, %{"unit_cost" => "10.00"})

      assert info.is_primary == true
      {:ok, successor} = ItemSupplierInfos.revise_unit_cost(info, Decimal.new("15.00"))

      primary = ItemSupplierInfos.primary_for_item(item.uuid)
      assert primary.uuid == successor.uuid
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Suppliers facade additions
  # ═══════════════════════════════════════════════════════════════════════════

  describe "Suppliers.active_info_for/2" do
    test "returns the current junction row for a pair" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()
      info = create_info(item, supplier, %{"unit_cost" => "10.00"})

      result = Suppliers.active_info_for(item.uuid, supplier.uuid)
      assert result.uuid == info.uuid
    end

    test "returns nil when the current row has been closed" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()
      info = create_info(item, supplier, %{"unit_cost" => "10.00"})

      {:ok, _} = ItemSupplierInfos.update(info, %{"valid_to" => Date.utc_today()})

      assert is_nil(Suppliers.active_info_for(item.uuid, supplier.uuid))
    end

    test "returns nil when no junction row exists" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()

      assert is_nil(Suppliers.active_info_for(item.uuid, supplier.uuid))
    end

    test "returns successor after revision, not the closed row" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()
      info = create_info(item, supplier, %{"unit_cost" => "10.00"})

      {:ok, successor} = ItemSupplierInfos.revise_unit_cost(info, Decimal.new("12.00"))

      result = Suppliers.active_info_for(item.uuid, supplier.uuid)
      assert result.uuid == successor.uuid
    end
  end

  describe "Suppliers.revise_unit_cost/3" do
    test "delegates to ItemSupplierInfos.revise_unit_cost/3" do
      cat = create_catalogue()
      item = create_item(cat)
      supplier = create_supplier()
      info = create_info(item, supplier, %{"unit_cost" => "5.00"})

      assert {:ok, successor} = Suppliers.revise_unit_cost(info, Decimal.new("7.00"))
      assert Decimal.equal?(successor.unit_cost, Decimal.new("7.00"))
    end
  end

  # A supplier listed twice on one item means two live prices for the same
  # pair and no rule about which anything downstream should believe.
  describe "one current row per item/supplier pair" do
    test "a second link to the same supplier is refused" do
      item = create_catalogue() |> create_item()
      supplier = create_supplier()

      _first = create_info(item, supplier)

      assert {:error, :already_linked} =
               ItemSupplierInfos.create(%{
                 "item_uuid" => item.uuid,
                 "supplier_uuid" => supplier.uuid,
                 "supplier_source" => "local"
               })

      assert length(ItemSupplierInfos.list_for_item(item.uuid)) == 1
    end

    test "a different supplier on the same item is fine" do
      item = create_catalogue() |> create_item()

      create_info(item, create_supplier())
      create_info(item, create_supplier())

      assert length(ItemSupplierInfos.list_for_item(item.uuid)) == 2
    end

    test "the same supplier on a different item is fine" do
      catalogue = create_catalogue()
      supplier = create_supplier()

      create_info(create_item(catalogue), supplier)
      create_info(create_item(catalogue), supplier)
    end

    # Price history is exactly "several rows for one pair", so the guard
    # must not block a revision — only one of them is ever open.
    test "a price revision still appends a successor for the same pair" do
      item = create_catalogue() |> create_item()
      supplier = create_supplier()

      info = create_info(item, supplier, %{"unit_cost" => "10.00"})
      {:ok, _revised} = ItemSupplierInfos.revise_unit_cost(info, Decimal.new("12.50"))

      assert length(ItemSupplierInfos.list_for_item(item.uuid)) == 1
      assert length(ItemSupplierInfos.history_for_pair(item.uuid, supplier.uuid)) == 2
    end

    # Once the earlier row is closed, re-adding the supplier is a new
    # arrangement, not a duplicate.
    test "re-adding is allowed after the previous row is closed" do
      item = create_catalogue() |> create_item()
      supplier = create_supplier()

      info = create_info(item, supplier)

      info
      |> Ecto.Changeset.change(%{valid_to: Date.utc_today()})
      |> PhoenixKit.RepoHelper.repo().update!()

      assert {:ok, _} =
               ItemSupplierInfos.create(%{
                 "item_uuid" => item.uuid,
                 "supplier_uuid" => supplier.uuid,
                 "supplier_source" => "local"
               })
    end
  end
end
