defmodule PhoenixKitCatalogue.Import.ExecutorTest do
  use PhoenixKitCatalogue.DataCase, async: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Import.Executor

  defp create_catalogue(attrs \\ %{}) do
    {:ok, c} = Catalogue.create_catalogue(Map.merge(%{name: "Test Catalogue"}, attrs))
    c
  end

  describe "execute/4" do
    test "creates items from import plan" do
      cat = create_catalogue()

      plan = %{
        items: [
          %{name: "Oak Panel", sku: "OAK-1", base_price: Decimal.new("4.88")},
          %{name: "Birch Veneer", sku: "BV-1", base_price: Decimal.new("3.50")}
        ],
        categories_to_create: [],
        custom_fields: [],
        errors: [],
        stats: %{total: 2, valid: 2, invalid: 0}
      }

      result = Executor.execute(plan, cat.uuid, self())

      assert result.created == 2
      assert result.errors == []

      # Verify items exist
      items = Catalogue.list_items()
      names = Enum.map(items, & &1.name)
      assert "Oak Panel" in names
      assert "Birch Veneer" in names

      # Verify we received progress messages
      assert_received {:import_progress, 1, 2}
      assert_received {:import_progress, 2, 2}
      assert_received {:import_result, _result}
    end

    test "creates categories from plan" do
      cat = create_catalogue()

      plan = %{
        items: [
          %{name: "Hook A", _category_name: "Hooks"},
          %{name: "Hinge B", _category_name: "Hinges"}
        ],
        categories_to_create: ["Hinges", "Hooks"],
        custom_fields: [],
        errors: [],
        stats: %{total: 2, valid: 2, invalid: 0}
      }

      result = Executor.execute(plan, cat.uuid, self())

      assert result.categories_created == 2
      assert result.created == 2

      # Verify categories exist
      categories = Catalogue.list_categories_for_catalogue(cat.uuid)
      names = Enum.map(categories, & &1.name)
      assert "Hooks" in names
      assert "Hinges" in names

      # Verify items have category_uuid set
      items = Catalogue.list_items()
      assert Enum.all?(items, fn i -> i.category_uuid != nil end)
    end

    test "allows duplicate SKUs" do
      cat = create_catalogue()
      category = create_category(cat)

      {:ok, _} =
        Catalogue.create_item(%{name: "Existing", sku: "DUP-1", category_uuid: category.uuid})

      plan = %{
        items: [
          %{name: "Duplicate", sku: "DUP-1", base_price: Decimal.new("9.99")},
          %{name: "New item", sku: "NEW-1", base_price: Decimal.new("5.00")}
        ],
        categories_to_create: [],
        custom_fields: [],
        errors: [],
        stats: %{total: 2, valid: 2, invalid: 0}
      }

      result = Executor.execute(plan, cat.uuid, self())

      assert result.created == 2
      assert result.errors == []
    end

    test "reimport leaves an already-photographed item's data intact (L026 invariant)" do
      cat = create_catalogue()

      # Simulates: file imported, then operator attached a main image +
      # files folder to the created item.
      {:ok, existing} =
        Catalogue.create_item(%{
          name: "Oak Panel",
          sku: "OAK-1",
          base_price: Decimal.new("4.88"),
          catalogue_uuid: cat.uuid,
          data: %{"featured_image_uuid" => "photo-uuid-1", "files_folder_uuid" => "folder-uuid-1"}
        })

      # Reimport of the same row. The universal executor is insert-only —
      # it never revisits existing rows — so the operator's photo pointers
      # on the original item must be untouched afterwards.
      plan = %{
        items: [%{name: "Oak Panel", sku: "OAK-1", base_price: Decimal.new("4.88")}],
        categories_to_create: [],
        custom_fields: [],
        errors: [],
        stats: %{total: 1, valid: 1, invalid: 0}
      }

      result = Executor.execute(plan, cat.uuid, nil)

      # The executor actually ran (guards against a silent no-op if execute/4
      # ever starts returning early): one row created, none errored, and the
      # SKU now has two rows (the original + the reimported duplicate).
      assert result.created == 1
      assert result.errors == []
      assert Enum.count(Catalogue.list_items(), &(&1.sku == "OAK-1")) == 2

      reloaded = Catalogue.get_item(existing.uuid)
      assert reloaded.data["featured_image_uuid"] == "photo-uuid-1"
      assert reloaded.data["files_folder_uuid"] == "folder-uuid-1"
    end

    test "applies language to imported items" do
      cat = create_catalogue()

      plan = %{
        items: [%{name: "Estonian Item", description: "Kirjeldus"}],
        categories_to_create: [],
        custom_fields: [],
        errors: [],
        stats: %{total: 1, valid: 1, invalid: 0}
      }

      result = Executor.execute(plan, cat.uuid, self(), language: "et")
      assert result.created == 1

      [item] = Catalogue.list_items()
      assert item.data["_primary_language"] == "et"
      assert item.data["et"]["_name"] == "Estonian Item"
    end

    test "applies language to created categories the same way as items" do
      cat = create_catalogue()

      plan = %{
        items: [%{name: "Konks", _category_name: "Konksud"}],
        categories_to_create: ["Konksud"],
        custom_fields: [],
        errors: [],
        stats: %{total: 1, valid: 1, invalid: 0}
      }

      result = Executor.execute(plan, cat.uuid, self(), language: "et")
      assert result.created == 1
      assert result.categories_created == 1

      [category] = Catalogue.list_categories_for_catalogue(cat.uuid)
      # Bare `name` field still holds the imported string for fallback.
      assert category.name == "Konksud"
      # ...AND multilang data is set so the category renders correctly
      # in mixed-language UIs.
      assert category.data["_primary_language"] == "et"
      assert category.data["et"]["_name"] == "Konksud"
    end

    test "matches existing category by translated name when importing in same language" do
      cat = create_catalogue()

      # Pre-existing category with English primary AND an Estonian translation.
      {:ok, _existing} =
        Catalogue.create_category(%{
          name: "Hooks",
          catalogue_uuid: cat.uuid,
          data: %{
            "_primary_language" => "en",
            "en" => %{"_name" => "Hooks"},
            "et" => %{"_name" => "Konksud"}
          }
        })

      plan = %{
        items: [%{name: "Konks", _category_name: "Konksud"}],
        categories_to_create: ["Konksud"],
        custom_fields: [],
        errors: [],
        stats: %{total: 1, valid: 1, invalid: 0}
      }

      result = Executor.execute(plan, cat.uuid, self(), language: "et")

      # Reused the existing category, didn't create a new one.
      assert result.created == 1
      assert result.categories_created == 0

      categories = Catalogue.list_categories_for_catalogue(cat.uuid)
      assert length(categories) == 1
      [category] = categories
      assert category.name == "Hooks"
    end

    test "without :match_categories_across_languages, only the current language is matched" do
      cat = create_catalogue()

      # Category whose ONLY translation is in `de` — bare name is also "Hooks".
      {:ok, _existing} =
        Catalogue.create_category(%{
          name: "Hooks",
          catalogue_uuid: cat.uuid,
          data: %{"_primary_language" => "en", "de" => %{"_name" => "Haken"}}
        })

      plan = %{
        items: [%{name: "Konks", _category_name: "Haken"}],
        categories_to_create: ["Haken"],
        custom_fields: [],
        errors: [],
        stats: %{total: 1, valid: 1, invalid: 0}
      }

      # Importing in et — neither the et translation (none) nor bare name
      # ("Hooks") matches "Haken", and we're not allowed to peek into
      # `de`, so a NEW category gets created.
      result = Executor.execute(plan, cat.uuid, self(), language: "et")

      assert result.categories_created == 1
      assert length(Catalogue.list_categories_for_catalogue(cat.uuid)) == 2
    end

    test "with :match_categories_across_languages, matches against any language's translation" do
      cat = create_catalogue()

      {:ok, _existing} =
        Catalogue.create_category(%{
          name: "Hooks",
          catalogue_uuid: cat.uuid,
          data: %{"_primary_language" => "en", "de" => %{"_name" => "Haken"}}
        })

      plan = %{
        items: [%{name: "Konks", _category_name: "Haken"}],
        categories_to_create: ["Haken"],
        custom_fields: [],
        errors: [],
        stats: %{total: 1, valid: 1, invalid: 0}
      }

      # Same setup as above, but with the cross-language flag on we
      # match the German translation and reuse the existing category.
      result =
        Executor.execute(plan, cat.uuid, self(),
          language: "et",
          match_categories_across_languages: true
        )

      assert result.categories_created == 0
      assert length(Catalogue.list_categories_for_catalogue(cat.uuid)) == 1
    end

    test "matches existing category by bare name as fallback when no translation set" do
      cat = create_catalogue()

      # Pre-existing English-primary category with NO Estonian translation yet.
      {:ok, _existing} =
        Catalogue.create_category(%{
          name: "Hooks",
          catalogue_uuid: cat.uuid,
          data: %{"_primary_language" => "en", "en" => %{"_name" => "Hooks"}}
        })

      plan = %{
        items: [%{name: "Hook A", _category_name: "Hooks"}],
        categories_to_create: ["Hooks"],
        custom_fields: [],
        errors: [],
        stats: %{total: 1, valid: 1, invalid: 0}
      }

      result = Executor.execute(plan, cat.uuid, self(), language: "et")

      # Matched by bare `name` since there's no et translation to match against.
      assert result.created == 1
      assert result.categories_created == 0
      assert length(Catalogue.list_categories_for_catalogue(cat.uuid)) == 1
    end

    test "reuses existing categories instead of creating duplicates" do
      cat = create_catalogue()
      {:ok, _existing_cat} = Catalogue.create_category(%{name: "Hooks", catalogue_uuid: cat.uuid})

      plan = %{
        items: [%{name: "Hook A", _category_name: "Hooks"}],
        categories_to_create: ["Hooks"],
        custom_fields: [],
        errors: [],
        stats: %{total: 1, valid: 1, invalid: 0}
      }

      result = Executor.execute(plan, cat.uuid, self())

      assert result.categories_created == 0
      assert result.created == 1

      # Should still only have 1 category
      categories = Catalogue.list_categories_for_catalogue(cat.uuid)
      assert length(categories) == 1
    end

    test "stores custom data fields" do
      cat = create_catalogue()

      plan = %{
        items: [
          %{name: "Panel", data: %{"color" => "Natural Oak", "original_unit" => "TK"}}
        ],
        categories_to_create: [],
        custom_fields: ["color", "original_unit"],
        errors: [],
        stats: %{total: 1, valid: 1, invalid: 0}
      }

      result = Executor.execute(plan, cat.uuid, self())
      assert result.created == 1

      [item] = Catalogue.list_items()
      assert item.data["color"] == "Natural Oak"
      assert item.data["original_unit"] == "TK"
    end

    # ── Manufacturer / Supplier ─────────────────────────────────

    test "column mode: gets-or-creates manufacturers and assigns per item" do
      cat = create_catalogue()
      {:ok, _existing} = Catalogue.create_manufacturer(%{name: "Blum"})

      plan = %{
        items: [
          %{name: "Hinge", _manufacturer_name: "Blum"},
          %{name: "Drawer Slide", _manufacturer_name: "Hettich"},
          %{name: "Door Handle", _manufacturer_name: "Blum"}
        ],
        categories_to_create: [],
        manufacturers_to_create: ["Blum", "Hettich"],
        suppliers_to_create: [],
        custom_fields: [],
        errors: [],
        stats: %{total: 3, valid: 3, invalid: 0}
      }

      result = Executor.execute(plan, cat.uuid, self())

      # Only Hettich is new — Blum already existed.
      assert result.created == 3
      assert result.manufacturers_created == 1

      items = Catalogue.list_items()
      blum = Enum.find(Catalogue.list_manufacturers(), &(&1.name == "Blum"))
      hettich = Enum.find(Catalogue.list_manufacturers(), &(&1.name == "Hettich"))

      assert Enum.find(items, &(&1.name == "Hinge")).manufacturer_uuid == blum.uuid
      assert Enum.find(items, &(&1.name == "Drawer Slide")).manufacturer_uuid == hettich.uuid
      assert Enum.find(items, &(&1.name == "Door Handle")).manufacturer_uuid == blum.uuid
    end

    test "fixed manufacturer_uuid: pins all items, skips column lookup" do
      cat = create_catalogue()
      {:ok, mfr} = Catalogue.create_manufacturer(%{name: "Pinned"})

      plan = %{
        items: [
          # Even with placeholder set, fixed uuid wins.
          %{name: "A", _manufacturer_name: "ignored"},
          %{name: "B"}
        ],
        categories_to_create: [],
        manufacturers_to_create: [],
        suppliers_to_create: [],
        custom_fields: [],
        errors: [],
        stats: %{total: 2, valid: 2, invalid: 0}
      }

      result = Executor.execute(plan, cat.uuid, self(), manufacturer_uuid: mfr.uuid)

      assert result.created == 2
      assert result.manufacturers_created == 0
      items = Catalogue.list_items()
      assert Enum.all?(items, &(&1.manufacturer_uuid == mfr.uuid))
    end

    test "column mode: per-row supplier links to per-row manufacturer (M:N)" do
      cat = create_catalogue()

      plan = %{
        items: [
          %{name: "A", _manufacturer_name: "Blum", _supplier_name: "Acme"},
          %{name: "B", _manufacturer_name: "Hettich", _supplier_name: "Globex"},
          # Same pair as row 1 → no duplicate link (idempotent).
          %{name: "C", _manufacturer_name: "Blum", _supplier_name: "Acme"}
        ],
        categories_to_create: [],
        manufacturers_to_create: ["Blum", "Hettich"],
        suppliers_to_create: ["Acme", "Globex"],
        custom_fields: [],
        errors: [],
        stats: %{total: 3, valid: 3, invalid: 0}
      }

      result = Executor.execute(plan, cat.uuid, self())

      assert result.created == 3
      assert result.manufacturers_created == 2
      assert result.suppliers_created == 2
      # 2 unique (mfr, sup) pairs.
      assert result.manufacturer_supplier_links_created == 2

      blum = Enum.find(Catalogue.list_manufacturers(), &(&1.name == "Blum"))
      acme = Enum.find(Catalogue.list_suppliers(), &(&1.name == "Acme"))

      assert acme.uuid in (Catalogue.list_suppliers_for_manufacturer(blum.uuid)
                           |> Enum.map(& &1.uuid))
    end

    test "fixed supplier_uuid: links the supplier to every manufacturer the import touched" do
      cat = create_catalogue()
      {:ok, sup} = Catalogue.create_supplier(%{name: "Single Source"})

      plan = %{
        items: [
          %{name: "A", _manufacturer_name: "Blum"},
          %{name: "B", _manufacturer_name: "Hettich"},
          %{name: "C", _manufacturer_name: "Blum"}
        ],
        categories_to_create: [],
        manufacturers_to_create: ["Blum", "Hettich"],
        suppliers_to_create: [],
        custom_fields: [],
        errors: [],
        stats: %{total: 3, valid: 3, invalid: 0}
      }

      result = Executor.execute(plan, cat.uuid, self(), supplier_uuid: sup.uuid)

      # 2 distinct manufacturers touched → 2 links to the fixed supplier.
      assert result.manufacturer_supplier_links_created == 2

      mfrs = Catalogue.list_manufacturers_for_supplier(sup.uuid)
      assert length(mfrs) == 2
    end

    test "rows with no manufacturer don't trigger a M:N link even if supplier is set" do
      cat = create_catalogue()
      {:ok, sup} = Catalogue.create_supplier(%{name: "Single Source"})

      plan = %{
        items: [
          # No manufacturer for this row, but a supplier is named.
          %{name: "Orphan", _supplier_name: "Single Source"}
        ],
        categories_to_create: [],
        manufacturers_to_create: [],
        suppliers_to_create: ["Single Source"],
        custom_fields: [],
        errors: [],
        stats: %{total: 1, valid: 1, invalid: 0}
      }

      result = Executor.execute(plan, cat.uuid, self())

      assert result.created == 1
      # No manufacturer ⇒ no link to make.
      assert result.manufacturer_supplier_links_created == 0
      # ...and the existing supplier was matched by name (not duplicated).
      assert result.suppliers_created == 0
      assert Catalogue.list_manufacturers_for_supplier(sup.uuid) == []
    end
  end

  defp create_category(catalogue, attrs \\ %{}) do
    {:ok, c} =
      Catalogue.create_category(
        Map.merge(%{name: "Test Category", catalogue_uuid: catalogue.uuid}, attrs)
      )

    c
  end

  # CRM is deliberately NOT a dependency of this package, so the suite runs
  # the CRM-ABSENT half — which is the half that must not regress, since a
  # catalogue-standalone install has nowhere else to put a party.
  describe "party sourcing without CRM" do
    test "falls back to local rows and stamps the item manufacturer as local" do
      cat = create_catalogue()

      plan = %{
        categories_to_create: [],
        manufacturers_to_create: ["Local Maker"],
        suppliers_to_create: ["Local Supplier"],
        items: [
          %{name: "Row A", _manufacturer_name: "Local Maker", _supplier_name: "Local Supplier"}
        ]
      }

      result = Executor.execute(plan, cat.uuid, nil)

      assert result.created == 1
      assert result.manufacturers_created == 1
      assert result.suppliers_created == 1

      [item] = Catalogue.list_items_for_catalogue(cat.uuid)
      assert item.manufacturer_source == "local"
      assert is_binary(item.manufacturer_uuid)
    end

    # A supplier column means "this item is supplied by X", so it now
    # produces a junction row rather than only a manufacturer M:N link.
    test "attaches the supplier to the item" do
      cat = create_catalogue()

      plan = %{
        categories_to_create: [],
        suppliers_to_create: ["Local Supplier"],
        items: [%{name: "Row A", _supplier_name: "Local Supplier"}]
      }

      Executor.execute(plan, cat.uuid, nil)

      [item] = Catalogue.list_items_for_catalogue(cat.uuid)
      assert [info] = Catalogue.list_supplier_infos_for_item(item.uuid)
      assert info.supplier_source == "local"
      assert info.supplier_name_snapshot == "Local Supplier"
    end

    # Two rows naming the same supplier for the same item must not create
    # two live prices — create/2 refuses the second.
    test "the same supplier twice on one item yields one junction row" do
      cat = create_catalogue()

      plan = %{
        categories_to_create: [],
        suppliers_to_create: ["Local Supplier"],
        items: [
          %{name: "Row A", sku: "A", _supplier_name: "Local Supplier"},
          %{name: "Row A", sku: "A2", _supplier_name: "Local Supplier"}
        ]
      }

      Executor.execute(plan, cat.uuid, nil)

      for item <- Catalogue.list_items_for_catalogue(cat.uuid) do
        assert length(Catalogue.list_supplier_infos_for_item(item.uuid)) == 1
      end
    end

    test "the manufacturer M:N graph is still built when both sides are local" do
      cat = create_catalogue()

      plan = %{
        categories_to_create: [],
        manufacturers_to_create: ["Local Maker"],
        suppliers_to_create: ["Local Supplier"],
        items: [
          %{name: "Row A", _manufacturer_name: "Local Maker", _supplier_name: "Local Supplier"}
        ]
      }

      result = Executor.execute(plan, cat.uuid, nil)

      assert result.manufacturer_supplier_links_created == 1
    end
  end

  # External review, 2026-08-21: a manufacturer was being resolved through the
  # SUPPLIER resolver. That keys on the supplier role, so a manufacturer-only
  # party resolved to nothing and got stamped "local" — a dangling local uuid
  # in a column whose FK V179 removed.
  describe "a fixed party is resolved for its own role" do
    test "a fixed manufacturer that is a local row is stamped local" do
      cat = create_catalogue()
      {:ok, mfr} = Catalogue.create_manufacturer(%{name: "Local Maker"})

      plan = %{categories_to_create: [], items: [%{name: "Row A"}]}
      Executor.execute(plan, cat.uuid, nil, manufacturer_uuid: mfr.uuid)

      [item] = Catalogue.list_items_for_catalogue(cat.uuid)
      assert item.manufacturer_uuid == mfr.uuid
      assert item.manufacturer_source == "local"
    end

    # A uuid belonging to neither directory must not be silently accepted as a
    # local row; it is stamped local only because there is nothing else it can
    # be, and the audit task is what surfaces it.
    test "an unknown fixed manufacturer still imports the item" do
      cat = create_catalogue()

      plan = %{categories_to_create: [], items: [%{name: "Row A"}]}
      result = Executor.execute(plan, cat.uuid, nil, manufacturer_uuid: Ecto.UUID.generate())

      assert result.created == 1
    end
  end
end
