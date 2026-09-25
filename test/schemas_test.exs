defmodule PhoenixKitCatalogue.SchemasTest do
  @moduledoc """
  Unit tests for all catalogue schema changesets. These are pure
  changeset validations — no DB round trip — so they run fast and
  cover every field-level constraint (required, length, inclusion,
  number range, etc.).
  """
  use ExUnit.Case, async: true

  alias PhoenixKitCatalogue.Schemas.{
    Catalogue,
    CatalogueRule,
    Category,
    Item,
    Manufacturer,
    Supplier
  }

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # ═══════════════════════════════════════════════════════════════════
  # Catalogue
  # ═══════════════════════════════════════════════════════════════════

  describe "Catalogue.changeset/2" do
    test "accepts minimal valid attrs" do
      cs = Catalogue.changeset(%Catalogue{}, %{name: "Kitchen"})
      assert cs.valid?
    end

    test "requires name" do
      cs = Catalogue.changeset(%Catalogue{}, %{})
      refute cs.valid?
      assert %{name: ["can't be blank"]} = errors_on(cs)
    end

    test "rejects blank name" do
      cs = Catalogue.changeset(%Catalogue{}, %{name: ""})
      refute cs.valid?
    end

    test "rejects name over 255 chars" do
      cs = Catalogue.changeset(%Catalogue{}, %{name: String.duplicate("a", 256)})
      refute cs.valid?
      assert errors_on(cs)[:name]
    end

    test "accepts name exactly 255 chars" do
      cs = Catalogue.changeset(%Catalogue{}, %{name: String.duplicate("a", 255)})
      assert cs.valid?
    end

    test "rejects bogus status" do
      cs = Catalogue.changeset(%Catalogue{}, %{name: "x", status: "bogus"})
      refute cs.valid?
      assert errors_on(cs)[:status]
    end

    test "accepts all valid statuses" do
      for status <- ~w(active archived deleted) do
        cs = Catalogue.changeset(%Catalogue{}, %{name: "x", status: status})
        assert cs.valid?, "expected status #{status} to be valid"
      end
    end

    test "rejects negative markup_percentage" do
      cs = Catalogue.changeset(%Catalogue{}, %{name: "x", markup_percentage: -1})
      refute cs.valid?
      assert errors_on(cs)[:markup_percentage]
    end

    test "rejects markup_percentage over 1000" do
      cs = Catalogue.changeset(%Catalogue{}, %{name: "x", markup_percentage: 1001})
      refute cs.valid?
      assert errors_on(cs)[:markup_percentage]
    end

    test "accepts markup_percentage = 0 and = 1000" do
      for mp <- [0, 1000] do
        cs = Catalogue.changeset(%Catalogue{}, %{name: "x", markup_percentage: mp})
        assert cs.valid?, "expected markup_percentage=#{mp} to be valid"
      end
    end

    test "accepts decimal markup_percentage as string" do
      cs = Catalogue.changeset(%Catalogue{}, %{name: "x", markup_percentage: "15.50"})
      assert cs.valid?

      assert Decimal.equal?(
               Ecto.Changeset.get_field(cs, :markup_percentage),
               Decimal.new("15.50")
             )
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Category
  # ═══════════════════════════════════════════════════════════════════

  describe "Category.changeset/2" do
    @valid_catalogue_uuid "019d1330-c5e0-7caf-b84b-91a4418f67f2"

    test "accepts valid attrs" do
      cs =
        Category.changeset(%Category{}, %{
          name: "Frames",
          catalogue_uuid: @valid_catalogue_uuid
        })

      assert cs.valid?
    end

    test "requires name and catalogue_uuid" do
      cs = Category.changeset(%Category{}, %{})
      refute cs.valid?
      errors = errors_on(cs)
      assert errors[:name]
      assert errors[:catalogue_uuid]
    end

    test "rejects name over 255 chars" do
      cs =
        Category.changeset(%Category{}, %{
          name: String.duplicate("a", 256),
          catalogue_uuid: @valid_catalogue_uuid
        })

      refute cs.valid?
      assert errors_on(cs)[:name]
    end

    test "rejects bogus status" do
      cs =
        Category.changeset(%Category{}, %{
          name: "x",
          catalogue_uuid: @valid_catalogue_uuid,
          status: "bogus"
        })

      refute cs.valid?
      assert errors_on(cs)[:status]
    end

    test "accepts negative position (int field, no constraint)" do
      # Position is just an integer — the context controls ordering.
      cs =
        Category.changeset(%Category{}, %{
          name: "x",
          catalogue_uuid: @valid_catalogue_uuid,
          position: -1
        })

      assert cs.valid?
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Item
  # ═══════════════════════════════════════════════════════════════════

  describe "Item.changeset/2" do
    @valid_catalogue_uuid "019d1330-c5e0-7caf-b84b-91a4418f67f2"

    test "accepts minimal valid attrs" do
      cs = Item.changeset(%Item{}, %{name: "Panel", catalogue_uuid: @valid_catalogue_uuid})
      assert cs.valid?
    end

    test "requires name and catalogue_uuid" do
      cs = Item.changeset(%Item{}, %{})
      refute cs.valid?
      errors = errors_on(cs)
      assert errors[:name]
      assert errors[:catalogue_uuid]
    end

    test "rejects name over 255 chars" do
      cs =
        Item.changeset(%Item{}, %{
          name: String.duplicate("a", 256),
          catalogue_uuid: @valid_catalogue_uuid
        })

      refute cs.valid?
      assert errors_on(cs)[:name]
    end

    test "rejects sku over 100 chars" do
      cs =
        Item.changeset(%Item{}, %{
          name: "x",
          catalogue_uuid: @valid_catalogue_uuid,
          sku: String.duplicate("a", 101)
        })

      refute cs.valid?
      assert errors_on(cs)[:sku]
    end

    test "accepts sku exactly 100 chars" do
      cs =
        Item.changeset(%Item{}, %{
          name: "x",
          catalogue_uuid: @valid_catalogue_uuid,
          sku: String.duplicate("a", 100)
        })

      assert cs.valid?
    end

    test "rejects bogus status" do
      cs =
        Item.changeset(%Item{}, %{
          name: "x",
          catalogue_uuid: @valid_catalogue_uuid,
          status: "bogus"
        })

      refute cs.valid?
      assert errors_on(cs)[:status]
    end

    test "accepts every allowed status" do
      for status <- ~w(active inactive discontinued deleted) do
        cs =
          Item.changeset(%Item{}, %{
            name: "x",
            catalogue_uuid: @valid_catalogue_uuid,
            status: status
          })

        assert cs.valid?, "status #{status} should be valid"
      end
    end

    test "rejects bogus unit" do
      cs =
        Item.changeset(%Item{}, %{
          name: "x",
          catalogue_uuid: @valid_catalogue_uuid,
          unit: "bogus"
        })

      refute cs.valid?
      assert errors_on(cs)[:unit]
    end

    test "accepts every allowed unit" do
      for unit <- Item.allowed_units() do
        cs =
          Item.changeset(%Item{}, %{
            name: "x",
            catalogue_uuid: @valid_catalogue_uuid,
            unit: unit
          })

        assert cs.valid?, "unit #{unit} should be valid"
      end
    end

    test "allowed_units/0 has exactly the 15 goods+services codes" do
      assert Enum.sort(Item.allowed_units()) ==
               Enum.sort(
                 ~w(piece set pair sheet m2 running_meter pack roll kg litre m3 hour service visit km)
               )
    end
  end

  describe "Item.unit_groups/0" do
    test "covers every allowed unit exactly once, split into goods and services" do
      groups = Item.unit_groups()
      assert Enum.map(groups, &elem(&1, 0)) == ["goods", "services"]

      all_grouped = groups |> Enum.flat_map(&elem(&1, 1))
      assert Enum.sort(all_grouped) == Enum.sort(Item.allowed_units())
      assert length(all_grouped) == length(Enum.uniq(all_grouped))
    end

    test "goods group holds the non-service units, services group holds the rest" do
      groups = Item.unit_groups()
      assert {"goods", goods} = List.keyfind(groups, "goods", 0)
      assert {"services", services} = List.keyfind(groups, "services", 0)

      assert Enum.sort(goods) ==
               Enum.sort(~w(piece set pair sheet m2 running_meter pack roll kg litre m3))

      assert Enum.sort(services) == Enum.sort(~w(hour service visit km))
    end

    test "rejects negative base_price" do
      cs =
        Item.changeset(%Item{}, %{
          name: "x",
          catalogue_uuid: @valid_catalogue_uuid,
          base_price: -1
        })

      refute cs.valid?
      assert errors_on(cs)[:base_price]
    end

    test "accepts zero base_price" do
      cs =
        Item.changeset(%Item{}, %{
          name: "x",
          catalogue_uuid: @valid_catalogue_uuid,
          base_price: 0
        })

      assert cs.valid?
    end

    test "accepts decimal base_price as string" do
      cs =
        Item.changeset(%Item{}, %{
          name: "x",
          catalogue_uuid: @valid_catalogue_uuid,
          base_price: "25.50"
        })

      assert cs.valid?
    end

    test "accepts nil markup_percentage (means inherit from catalogue)" do
      cs =
        Item.changeset(%Item{}, %{
          name: "x",
          catalogue_uuid: @valid_catalogue_uuid,
          markup_percentage: nil
        })

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :markup_percentage) == nil
    end

    test "accepts empty-string markup_percentage from form params (normalized to nil)" do
      cs =
        Item.changeset(%Item{}, %{
          "name" => "x",
          "catalogue_uuid" => @valid_catalogue_uuid,
          "markup_percentage" => ""
        })

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :markup_percentage) == nil
    end

    test "accepts zero markup_percentage (explicit override to sell at base)" do
      cs =
        Item.changeset(%Item{}, %{
          name: "x",
          catalogue_uuid: @valid_catalogue_uuid,
          markup_percentage: 0
        })

      assert cs.valid?
    end

    test "rejects negative markup_percentage" do
      cs =
        Item.changeset(%Item{}, %{
          name: "x",
          catalogue_uuid: @valid_catalogue_uuid,
          markup_percentage: -5
        })

      refute cs.valid?
      assert errors_on(cs)[:markup_percentage]
    end
  end

  describe "Item.sale_price/2" do
    test "returns nil when base_price is nil" do
      item = %Item{base_price: nil}
      assert Item.sale_price(item, Decimal.new("20")) == nil
    end

    test "returns base_price when markup is nil" do
      item = %Item{base_price: Decimal.new("100")}
      assert Decimal.equal?(Item.sale_price(item, nil), Decimal.new("100"))
    end

    test "computes markup correctly" do
      item = %Item{base_price: Decimal.new("100")}
      assert Decimal.equal?(Item.sale_price(item, Decimal.new("15")), Decimal.new("115.00"))
    end

    test "rounds to 2 decimal places" do
      item = %Item{base_price: Decimal.new("33.33")}
      result = Item.sale_price(item, Decimal.new("15"))
      # 33.33 * 1.15 = 38.3295 → rounds to 38.33
      assert Decimal.equal?(result, Decimal.new("38.33"))
    end

    test "handles zero catalogue markup" do
      item = %Item{base_price: Decimal.new("50")}
      assert Decimal.equal?(Item.sale_price(item, Decimal.new("0")), Decimal.new("50"))
    end

    test "item markup_percentage overrides catalogue markup" do
      item = %Item{base_price: Decimal.new("100"), markup_percentage: Decimal.new("50")}
      # Catalogue says 20, but item overrides to 50 → 100 * 1.50
      assert Decimal.equal?(Item.sale_price(item, Decimal.new("20")), Decimal.new("150.00"))
    end

    test "item markup of 0 overrides a non-zero catalogue markup" do
      # "0 means sell at base price, even if the catalogue has a markup"
      item = %Item{base_price: Decimal.new("100"), markup_percentage: Decimal.new("0")}
      assert Decimal.equal?(Item.sale_price(item, Decimal.new("20")), Decimal.new("100"))
    end

    test "item falls back to catalogue markup when override is nil" do
      item = %Item{base_price: Decimal.new("100"), markup_percentage: nil}
      assert Decimal.equal?(Item.sale_price(item, Decimal.new("25")), Decimal.new("125.00"))
    end

    test "both nil → base price unchanged" do
      item = %Item{base_price: Decimal.new("77"), markup_percentage: nil}
      assert Decimal.equal?(Item.sale_price(item, nil), Decimal.new("77"))
    end
  end

  describe "Item.effective_markup/2" do
    test "returns the item's override when set" do
      item = %Item{markup_percentage: Decimal.new("50")}
      assert Decimal.equal?(Item.effective_markup(item, Decimal.new("20")), Decimal.new("50"))
    end

    test "returns the item's override even when it's zero" do
      item = %Item{markup_percentage: Decimal.new("0")}
      assert Decimal.equal?(Item.effective_markup(item, Decimal.new("20")), Decimal.new("0"))
    end

    test "falls back to catalogue when item override is nil" do
      item = %Item{markup_percentage: nil}
      assert Decimal.equal?(Item.effective_markup(item, Decimal.new("20")), Decimal.new("20"))
    end

    test "returns nil when both are nil" do
      item = %Item{markup_percentage: nil}
      assert Item.effective_markup(item, nil) == nil
    end
  end

  describe "Item.effective_discount/2" do
    test "returns the item's override when set" do
      item = %Item{discount_percentage: Decimal.new("25")}
      assert Decimal.equal?(Item.effective_discount(item, Decimal.new("10")), Decimal.new("25"))
    end

    test "returns the item's override even when it's zero" do
      item = %Item{discount_percentage: Decimal.new("0")}
      assert Decimal.equal?(Item.effective_discount(item, Decimal.new("10")), Decimal.new("0"))
    end

    test "falls back to catalogue when item override is nil" do
      item = %Item{discount_percentage: nil}
      assert Decimal.equal?(Item.effective_discount(item, Decimal.new("15")), Decimal.new("15"))
    end

    test "returns nil when both are nil" do
      item = %Item{discount_percentage: nil}
      assert Item.effective_discount(item, nil) == nil
    end
  end

  describe "Item.final_price/3" do
    test "returns nil when base_price is nil" do
      item = %Item{base_price: nil}
      assert Item.final_price(item, Decimal.new("20"), Decimal.new("10")) == nil
    end

    test "applies markup then discount in that order" do
      item = %Item{base_price: Decimal.new("100")}
      # 100 * 1.20 * 0.90 = 108.00
      result = Item.final_price(item, Decimal.new("20"), Decimal.new("10"))
      assert Decimal.equal?(result, Decimal.new("108.00"))
    end

    test "rounds to 2 decimal places" do
      item = %Item{base_price: Decimal.new("33.33")}
      # 33.33 * 1.15 * 0.95 = 36.41... → rounds
      result = Item.final_price(item, Decimal.new("15"), Decimal.new("5"))
      assert Decimal.equal?(result, Decimal.new("36.41"))
    end

    test "nil discount leaves sale_price unchanged (no discount leg)" do
      item = %Item{base_price: Decimal.new("100")}
      result = Item.final_price(item, Decimal.new("20"), nil)
      assert Decimal.equal?(result, Decimal.new("120.00"))
    end

    test "nil markup leaves base untouched by markup (discount still applies)" do
      item = %Item{base_price: Decimal.new("100")}
      result = Item.final_price(item, nil, Decimal.new("10"))
      assert Decimal.equal?(result, Decimal.new("90.00"))
    end

    test "item discount 0 overrides a non-zero catalogue discount" do
      item = %Item{base_price: Decimal.new("100"), discount_percentage: Decimal.new("0")}
      # Catalogue says 25% discount, but item overrides to 0 → no discount
      result = Item.final_price(item, Decimal.new("20"), Decimal.new("25"))
      assert Decimal.equal?(result, Decimal.new("120.00"))
    end

    test "item discount overrides catalogue discount" do
      item = %Item{base_price: Decimal.new("100"), discount_percentage: Decimal.new("50")}
      # Catalogue says 10%, item says 50% → 50% applies
      result = Item.final_price(item, Decimal.new("0"), Decimal.new("10"))
      assert Decimal.equal?(result, Decimal.new("50.00"))
    end

    test "100% discount yields 0" do
      item = %Item{base_price: Decimal.new("100")}
      result = Item.final_price(item, Decimal.new("0"), Decimal.new("100"))
      assert Decimal.equal?(result, Decimal.new("0.00"))
    end
  end

  describe "Item.discount_amount/3" do
    test "returns nil when base_price is nil" do
      item = %Item{base_price: nil}
      assert Item.discount_amount(item, Decimal.new("20"), Decimal.new("10")) == nil
    end

    test "returns nil when both discount sources are nil" do
      item = %Item{base_price: Decimal.new("100"), discount_percentage: nil}
      assert Item.discount_amount(item, Decimal.new("20"), nil) == nil
    end

    test "returns the difference between sale_price and final_price" do
      item = %Item{base_price: Decimal.new("100")}
      # sale = 100 * 1.20 = 120; final = 120 * 0.90 = 108; amount = 12
      result = Item.discount_amount(item, Decimal.new("20"), Decimal.new("10"))
      assert Decimal.equal?(result, Decimal.new("12.00"))
    end

    test "zero when effective discount is 0 (not nil)" do
      item = %Item{base_price: Decimal.new("100"), discount_percentage: Decimal.new("0")}
      result = Item.discount_amount(item, Decimal.new("20"), Decimal.new("25"))
      # item override of 0 means no discount → amount is 0, not nil
      assert Decimal.equal?(result, Decimal.new("0.00"))
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Manufacturer
  # ═══════════════════════════════════════════════════════════════════

  describe "Manufacturer.changeset/2" do
    test "accepts minimal valid attrs" do
      cs = Manufacturer.changeset(%Manufacturer{}, %{name: "Blum"})
      assert cs.valid?
    end

    test "requires name" do
      cs = Manufacturer.changeset(%Manufacturer{}, %{})
      refute cs.valid?
      assert errors_on(cs)[:name]
    end

    test "rejects long name/website/contact_info/logo_url" do
      too_long_name = String.duplicate("a", 256)
      too_long_500 = String.duplicate("b", 501)

      assert errors_on(Manufacturer.changeset(%Manufacturer{}, %{name: too_long_name}))[:name]

      cs =
        Manufacturer.changeset(%Manufacturer{}, %{
          name: "ok",
          website: too_long_500,
          contact_info: too_long_500,
          logo_url: too_long_500
        })

      refute cs.valid?
      errors = errors_on(cs)
      assert errors[:website]
      assert errors[:contact_info]
      assert errors[:logo_url]
    end

    test "only 'active' and 'inactive' statuses are allowed (no 'deleted')" do
      for status <- ~w(active inactive) do
        cs = Manufacturer.changeset(%Manufacturer{}, %{name: "x", status: status})
        assert cs.valid?
      end

      refute Manufacturer.changeset(%Manufacturer{}, %{name: "x", status: "deleted"}).valid?
      refute Manufacturer.changeset(%Manufacturer{}, %{name: "x", status: "bogus"}).valid?
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Supplier
  # ═══════════════════════════════════════════════════════════════════

  describe "Supplier.changeset/2" do
    test "accepts minimal valid attrs" do
      cs = Supplier.changeset(%Supplier{}, %{name: "DelCo"})
      assert cs.valid?
    end

    test "requires name" do
      cs = Supplier.changeset(%Supplier{}, %{})
      refute cs.valid?
      assert errors_on(cs)[:name]
    end

    test "rejects bogus status" do
      cs = Supplier.changeset(%Supplier{}, %{name: "x", status: "bogus"})
      refute cs.valid?
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Smart catalogues (0.1.12)
  # ═══════════════════════════════════════════════════════════════════

  describe "Catalogue.changeset/2 — kind" do
    test "defaults to 'standard' when omitted" do
      cs = Catalogue.changeset(%Catalogue{}, %{name: "X"})
      assert cs.valid?
      # The default lives on the struct's `:kind` field, not in the
      # changeset changes — so get_field reads the default.
      assert Ecto.Changeset.get_field(cs, :kind) == "standard"
    end

    test "accepts 'smart'" do
      cs = Catalogue.changeset(%Catalogue{}, %{name: "Services", kind: "smart"})
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :kind) == "smart"
    end

    test "rejects unknown kind" do
      cs = Catalogue.changeset(%Catalogue{}, %{name: "X", kind: "weird"})
      refute cs.valid?
      assert errors_on(cs)[:kind]
    end
  end

  describe "Item.changeset/2 — default_value / default_unit" do
    test "defaults to nil/nil" do
      cs = Item.changeset(%Item{}, %{name: "Delivery", catalogue_uuid: UUIDv7.generate()})
      assert cs.valid?
      assert is_nil(Ecto.Changeset.get_field(cs, :default_value))
      assert is_nil(Ecto.Changeset.get_field(cs, :default_unit))
    end

    test "accepts valid default_value + default_unit" do
      cs =
        Item.changeset(%Item{}, %{
          name: "Delivery",
          catalogue_uuid: UUIDv7.generate(),
          default_value: "5",
          default_unit: "percent"
        })

      assert cs.valid?
      assert Decimal.equal?(Ecto.Changeset.get_field(cs, :default_value), Decimal.new("5"))
    end

    test "rejects negative default_value" do
      cs =
        Item.changeset(%Item{}, %{
          name: "Delivery",
          catalogue_uuid: UUIDv7.generate(),
          default_value: "-1"
        })

      refute cs.valid?
      assert errors_on(cs)[:default_value]
    end

    test "rejects unknown default_unit" do
      cs =
        Item.changeset(%Item{}, %{
          name: "Delivery",
          catalogue_uuid: UUIDv7.generate(),
          default_unit: "banana"
        })

      refute cs.valid?
      assert errors_on(cs)[:default_unit]
    end

    test "accepts flat default_unit" do
      cs =
        Item.changeset(%Item{}, %{
          name: "Delivery",
          catalogue_uuid: UUIDv7.generate(),
          default_unit: "flat"
        })

      assert cs.valid?
    end

    test "allowed_default_units/0 exposes the accepted values" do
      assert Item.allowed_default_units() == ~w(percent flat)
    end
  end

  describe "CatalogueRule.changeset/2" do
    test "accepts minimal valid attrs (all-nil value/unit)" do
      cs =
        CatalogueRule.changeset(%CatalogueRule{}, %{
          item_uuid: UUIDv7.generate(),
          referenced_catalogue_uuid: UUIDv7.generate()
        })

      assert cs.valid?
    end

    test "accepts value + unit" do
      cs =
        CatalogueRule.changeset(%CatalogueRule{}, %{
          item_uuid: UUIDv7.generate(),
          referenced_catalogue_uuid: UUIDv7.generate(),
          value: "5",
          unit: "percent"
        })

      assert cs.valid?
    end

    test "requires item_uuid and referenced_catalogue_uuid" do
      cs = CatalogueRule.changeset(%CatalogueRule{}, %{})
      refute cs.valid?
      assert errors_on(cs)[:item_uuid]
      assert errors_on(cs)[:referenced_catalogue_uuid]
    end

    test "rejects negative value" do
      cs =
        CatalogueRule.changeset(%CatalogueRule{}, %{
          item_uuid: UUIDv7.generate(),
          referenced_catalogue_uuid: UUIDv7.generate(),
          value: "-5"
        })

      refute cs.valid?
      assert errors_on(cs)[:value]
    end

    test "rejects unknown unit" do
      cs =
        CatalogueRule.changeset(%CatalogueRule{}, %{
          item_uuid: UUIDv7.generate(),
          referenced_catalogue_uuid: UUIDv7.generate(),
          unit: "bogus"
        })

      refute cs.valid?
      assert errors_on(cs)[:unit]
    end
  end

  describe "CatalogueRule.effective/2" do
    test "rule value/unit take precedence over item defaults" do
      rule = %CatalogueRule{value: Decimal.new("10"), unit: "flat"}
      item = %Item{default_value: Decimal.new("5"), default_unit: "percent"}
      assert CatalogueRule.effective(rule, item) == {Decimal.new("10"), "flat"}
    end

    test "each leg inherits independently" do
      # Rule has value, no unit → inherits unit only
      rule = %CatalogueRule{value: Decimal.new("10"), unit: nil}
      item = %Item{default_value: Decimal.new("5"), default_unit: "percent"}
      assert CatalogueRule.effective(rule, item) == {Decimal.new("10"), "percent"}

      # Rule has unit, no value → inherits value only
      rule = %CatalogueRule{value: nil, unit: "flat"}
      assert CatalogueRule.effective(rule, item) == {Decimal.new("5"), "flat"}
    end

    test "both nil on rule → inherits both from item" do
      rule = %CatalogueRule{value: nil, unit: nil}
      item = %Item{default_value: Decimal.new("5"), default_unit: "percent"}
      assert CatalogueRule.effective(rule, item) == {Decimal.new("5"), "percent"}
    end

    test "both nil everywhere → {nil, nil}" do
      rule = %CatalogueRule{value: nil, unit: nil}
      item = %Item{default_value: nil, default_unit: nil}
      assert CatalogueRule.effective(rule, item) == {nil, nil}
    end

    test "tolerates nil item (handy for detached rules)" do
      rule = %CatalogueRule{value: Decimal.new("5"), unit: "percent"}
      assert CatalogueRule.effective(rule, nil) == {Decimal.new("5"), "percent"}
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # PDF library schemas (added by 2026-05-06 Phase 2 sweep)
  # ═══════════════════════════════════════════════════════════════════

  alias PhoenixKitCatalogue.Schemas.{Pdf, PdfExtraction, PdfPage, PdfPageContent}

  describe "Pdf.changeset/2" do
    test "accepts minimal valid attrs" do
      cs = Pdf.changeset(%Pdf{}, %{file_uuid: UUIDv7.generate(), original_filename: "x.pdf"})
      assert cs.valid?
    end

    test "requires file_uuid" do
      cs = Pdf.changeset(%Pdf{}, %{original_filename: "x.pdf"})
      refute cs.valid?
      assert %{file_uuid: ["can't be blank"]} = errors_on(cs)
    end

    test "requires original_filename" do
      cs = Pdf.changeset(%Pdf{}, %{file_uuid: UUIDv7.generate()})
      refute cs.valid?
      assert %{original_filename: ["can't be blank"]} = errors_on(cs)
    end

    test "rejects original_filename longer than 500 chars" do
      cs =
        Pdf.changeset(%Pdf{}, %{
          file_uuid: UUIDv7.generate(),
          original_filename: String.duplicate("a", 501)
        })

      refute cs.valid?
      assert %{original_filename: [_]} = errors_on(cs)
    end

    test "accepts both active and trashed status" do
      base = %{file_uuid: UUIDv7.generate(), original_filename: "x.pdf"}
      assert Pdf.changeset(%Pdf{}, Map.put(base, :status, "active")).valid?
      assert Pdf.changeset(%Pdf{}, Map.put(base, :status, "trashed")).valid?
    end

    test "rejects unknown status" do
      cs =
        Pdf.changeset(%Pdf{}, %{
          file_uuid: UUIDv7.generate(),
          original_filename: "x.pdf",
          status: "purgatory"
        })

      refute cs.valid?
      assert %{status: ["is invalid"]} = errors_on(cs)
    end
  end

  describe "Pdf.trash_changeset/1" do
    test "flips status to trashed and stamps trashed_at" do
      cs = Pdf.trash_changeset(%Pdf{status: "active"})
      assert cs.changes.status == "trashed"
      assert %DateTime{} = cs.changes.trashed_at
    end

    test "trashed_at is current-second precision" do
      cs = Pdf.trash_changeset(%Pdf{status: "active"})
      assert cs.changes.trashed_at == DateTime.truncate(cs.changes.trashed_at, :second)
    end
  end

  describe "Pdf.restore_changeset/1" do
    test "flips status to active and clears trashed_at" do
      pdf = %Pdf{status: "trashed", trashed_at: DateTime.utc_now() |> DateTime.truncate(:second)}
      cs = Pdf.restore_changeset(pdf)
      assert cs.changes.status == "active"
      assert cs.changes.trashed_at == nil
    end
  end

  describe "Pdf.statuses/0" do
    test "lists exactly the two valid statuses" do
      assert Pdf.statuses() == ~w(active trashed)
    end
  end

  describe "PdfExtraction.changeset/2" do
    test "accepts minimal valid attrs" do
      cs = PdfExtraction.changeset(%PdfExtraction{}, %{file_uuid: UUIDv7.generate()})
      assert cs.valid?
    end

    test "requires file_uuid" do
      cs = PdfExtraction.changeset(%PdfExtraction{}, %{})
      refute cs.valid?
      assert %{file_uuid: ["can't be blank"]} = errors_on(cs)
    end

    test "rejects unknown extraction_status" do
      cs =
        PdfExtraction.changeset(%PdfExtraction{}, %{
          file_uuid: UUIDv7.generate(),
          extraction_status: "haunted"
        })

      refute cs.valid?
      assert %{extraction_status: ["is invalid"]} = errors_on(cs)
    end

    test "rejects negative page_count" do
      cs =
        PdfExtraction.changeset(%PdfExtraction{}, %{
          file_uuid: UUIDv7.generate(),
          page_count: -1
        })

      refute cs.valid?
      assert %{page_count: [_]} = errors_on(cs)
    end

    test "accepts page_count of 0 (empty PDF edge case)" do
      cs =
        PdfExtraction.changeset(%PdfExtraction{}, %{
          file_uuid: UUIDv7.generate(),
          page_count: 0
        })

      assert cs.valid?
    end
  end

  describe "PdfExtraction.status_changeset/2" do
    test "flips extraction_status from pending to extracting" do
      cs =
        PdfExtraction.status_changeset(
          %PdfExtraction{extraction_status: "pending"},
          %{extraction_status: "extracting"}
        )

      assert cs.changes.extraction_status == "extracting"
    end

    test "rejects unknown status transition" do
      cs = PdfExtraction.status_changeset(%PdfExtraction{}, %{extraction_status: "vanished"})
      refute cs.valid?
    end

    test "accepts page_count + extracted_at + error_message together" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      cs =
        PdfExtraction.status_changeset(%PdfExtraction{}, %{
          extraction_status: "extracted",
          page_count: 42,
          extracted_at: now,
          error_message: nil
        })

      assert cs.valid?
      assert cs.changes.page_count == 42
      assert cs.changes.extracted_at == now
    end
  end

  describe "PdfExtraction.statuses/0" do
    test "lists the five worker states" do
      assert PdfExtraction.statuses() == ~w(pending extracting extracted scanned_no_text failed)
    end
  end

  describe "PdfPage.changeset/2" do
    test "accepts minimal valid attrs" do
      cs =
        PdfPage.changeset(%PdfPage{}, %{
          file_uuid: UUIDv7.generate(),
          page_number: 1,
          content_hash: String.duplicate("a", 64),
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      assert cs.valid?
    end

    test "requires file_uuid + page_number + content_hash + inserted_at" do
      cs = PdfPage.changeset(%PdfPage{}, %{})
      refute cs.valid?

      keys = errors_on(cs) |> Map.keys()

      for required <- [:file_uuid, :page_number, :content_hash, :inserted_at] do
        assert required in keys, "expected `#{required}` in errors, got #{inspect(keys)}"
      end
    end

    test "rejects page_number below 1" do
      cs =
        PdfPage.changeset(%PdfPage{}, %{
          file_uuid: UUIDv7.generate(),
          page_number: 0,
          content_hash: String.duplicate("a", 64),
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      refute cs.valid?
      assert %{page_number: [_]} = errors_on(cs)
    end
  end

  describe "PdfPageContent.changeset/2" do
    test "accepts a 64-char hex content_hash" do
      cs =
        PdfPageContent.changeset(%PdfPageContent{}, %{
          content_hash: String.duplicate("0", 64),
          text: "hello",
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      assert cs.valid?
    end

    test "rejects content_hash with the wrong length" do
      cs =
        PdfPageContent.changeset(%PdfPageContent{}, %{
          content_hash: "short",
          text: "hello",
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      refute cs.valid?
      assert %{content_hash: [_]} = errors_on(cs)
    end

    test "requires content_hash + text + inserted_at" do
      cs = PdfPageContent.changeset(%PdfPageContent{}, %{})
      refute cs.valid?

      keys = errors_on(cs) |> Map.keys()

      for required <- [:content_hash, :text, :inserted_at] do
        assert required in keys, "expected `#{required}` in errors, got #{inspect(keys)}"
      end
    end

    test "rejects empty-string text via validate_required" do
      # Pinned for documentation: the changeset rejects `""` because
      # `validate_required` treats empty strings as blank. Production
      # ingestion bypasses the changeset — the worker uses
      # `repo().insert_all/3` with raw maps so genuinely-empty pages
      # (image-only PDFs) get stored. If a future caller routes
      # PdfPageContent inserts through the changeset, this test will
      # fail and the caller can either: (a) skip empty-text rows, or
      # (b) drop `:text` from `@required_fields`.
      cs =
        PdfPageContent.changeset(%PdfPageContent{}, %{
          content_hash: String.duplicate("e", 64),
          text: "",
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      refute cs.valid?
      assert %{text: [_]} = errors_on(cs)
    end
  end
end
