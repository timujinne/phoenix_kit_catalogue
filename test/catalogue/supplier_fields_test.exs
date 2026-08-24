defmodule PhoenixKitCatalogue.Catalogue.SupplierFieldsTest do
  @moduledoc """
  Admin-defined extra fields on supplier rows: the singleton managed
  blueprint, its field definitions, and the cast/store path onto
  `item_supplier_info.metadata`. Drives the REAL entities API (path
  dep) — skipped when the entities package in use lacks Managed.
  """
  use PhoenixKitCatalogue.DataCase, async: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.{PubSub, SupplierFields}

  if Code.ensure_loaded?(PhoenixKitEntities.Managed) do
    setup do
      SupplierFields.startup()
      PhoenixKit.Settings.update_setting("entities_enabled", "true")
      on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)
      :ok
    end

    defp add!(label, type \\ "text", options \\ []) do
      {:ok, entity} =
        SupplierFields.add_field(%{label: label, type: type, options: options},
          actor_uuid: Ecto.UUID.generate()
        )

      entity
    end

    describe "PubSub (F14 — the per-field columns must refresh when a definition changes)" do
      setup do
        PubSub.subscribe()
        :ok
      end

      test "add / update / remove broadcast :supplier_field with the blueprint uuid" do
        entity = add!("Incoterm")
        assert_receive {:catalogue_data_changed, :supplier_field, uuid, nil}
        assert uuid == entity.uuid

        {:ok, _} = SupplierFields.update_field("incoterm", %{label: "Incoterms"})
        assert_receive {:catalogue_data_changed, :supplier_field, uuid, nil}
        assert uuid == entity.uuid

        {:ok, _} = SupplierFields.remove_field("incoterm")
        assert_receive {:catalogue_data_changed, :supplier_field, uuid, nil}
        assert uuid == entity.uuid
      end

      test "a rejected write stays silent" do
        add!("Incoterm")
        assert_receive {:catalogue_data_changed, :supplier_field, _, nil}

        assert {:error, _} = SupplierFields.add_field(%{label: "Incoterm"})
        refute_receive {:catalogue_data_changed, :supplier_field, _, _}
      end
    end

    describe "blueprint provisioning" do
      test "provisions a managed singleton on first write" do
        assert SupplierFields.blueprint() == nil

        entity = add!("Incoterm")

        assert entity.name == "catalogue_supplier_fields"
        assert entity.settings["managed_by"] == "catalogue_supplier"
        assert entity.settings["catalogue_supplier"]["scope"] == "supplier_info"
      end

      test "is hidden from the generic entities admin" do
        entity = add!("Incoterm")

        generic = PhoenixKitEntities.list_entities(include_managed: false)
        refute Enum.any?(generic, &(&1.uuid == entity.uuid))
      end

      # The reason the owner string is "catalogue_supplier" and not
      # "catalogue": AttributeSets enumerates by owner, so a shared owner
      # would list this blueprint as an attribute set.
      test "does not appear among the attribute sets" do
        entity = add!("Incoterm")

        refute Enum.any?(Catalogue.list_attribute_sets(), &(&1.uuid == entity.uuid))
      end

      test "ensure_blueprint is idempotent" do
        opts = [actor_uuid: Ecto.UUID.generate()]
        {:ok, first} = SupplierFields.ensure_blueprint(opts)
        {:ok, second} = SupplierFields.ensure_blueprint(opts)

        assert first.uuid == second.uuid
      end

      # A rejected request must not leave a provisioned blueprint behind.
      test "an invalid field does not provision the blueprint" do
        assert {:error, :label_required} = SupplierFields.add_field(%{label: "   "})
        assert SupplierFields.blueprint() == nil
      end
    end

    describe "field definitions" do
      test "derives a stable key from the label" do
        add!("Carton quantity")

        assert [%{"key" => "carton_quantity", "label" => "Carton quantity", "type" => "text"}] =
                 SupplierFields.fields()
      end

      test "gives non-Latin labels an opaque key rather than an empty one" do
        add!("Цена")

        [field] = SupplierFields.fields()
        assert field["label"] == "Цена"
        assert String.starts_with?(field["key"], "field_")
      end

      test "rejects a blank label, an unknown type, and a duplicate key" do
        assert {:error, :label_required} = SupplierFields.add_field(%{label: "   "})
        assert {:error, :invalid_type} = SupplierFields.add_field(%{label: "X", type: "relation"})

        add!("Incoterm")
        assert {:error, :duplicate_key} = SupplierFields.add_field(%{label: "Incoterm"})
      end

      test "select requires at least one choice" do
        assert {:error, :options_required} =
                 SupplierFields.add_field(%{label: "Packaging", type: "select"})

        add!("Packaging", "select", ["Box", "Pallet"])
        assert [%{"options" => ["Box", "Pallet"]}] = SupplierFields.fields()
      end

      test "update renames the label but never the key or type" do
        add!("Incoterm")

        {:ok, _} = SupplierFields.update_field("incoterm", %{label: "Delivery terms"})

        assert [%{"key" => "incoterm", "label" => "Delivery terms", "type" => "text"}] =
                 SupplierFields.fields()
      end

      test "update replaces a select's choices" do
        add!("Packaging", "select", ["Box"])

        {:ok, _} = SupplierFields.update_field("packaging", %{options: ["Box", "Crate"]})

        assert [%{"options" => ["Box", "Crate"]}] = SupplierFields.fields()

        assert {:error, :options_required} =
                 SupplierFields.update_field("packaging", %{options: []})
      end

      test "update of an unknown key is refused" do
        add!("Incoterm")
        assert {:error, :unknown_field} = SupplierFields.update_field("nope", %{label: "X"})
      end

      test "remove drops the definition" do
        add!("Incoterm")
        add!("Carton quantity")

        {:ok, _} = SupplierFields.remove_field("incoterm")

        assert ["carton_quantity"] = Enum.map(SupplierFields.fields(), & &1["key"])
      end
    end

    describe "values on a supplier row" do
      test "casts through the entities pipeline" do
        add!("Carton quantity", "number")
        add!("Stocked", "boolean")

        assert {:ok, %{"carton_quantity" => 12.0, "stocked" => true}} =
                 SupplierFields.cast_values(%{"carton_quantity" => "12", "stocked" => "true"})
      end

      test "refuses unknown keys and invalid content" do
        add!("Packaging", "select", ["Box"])

        assert {:error, :unknown_field} = SupplierFields.cast_values(%{"ghost" => "x"})
        assert {:error, :invalid_value} = SupplierFields.cast_values(%{"packaging" => "Barrel"})
      end

      test "nil means not submitted and passes through" do
        assert {:ok, nil} = SupplierFields.cast_values(nil)
      end

      test "put_values namespaces under custom_fields and merges" do
        assert %{"custom_fields" => %{"a" => 1}} = SupplierFields.put_values(%{}, %{"a" => 1})

        merged =
          SupplierFields.put_values(%{"custom_fields" => %{"a" => 1}, "system" => "keep"}, %{
            "b" => 2
          })

        assert merged == %{"custom_fields" => %{"a" => 1, "b" => 2}, "system" => "keep"}
      end

      test "put_values with nil or nothing to merge leaves stored values untouched" do
        metadata = %{"custom_fields" => %{"a" => 1}}
        assert SupplierFields.put_values(metadata, nil) == metadata
        assert SupplierFields.put_values(metadata, %{}) == metadata

        # And must not stamp an empty key onto a row that has none —
        # every supplier written while the UI is hidden takes this path.
        assert SupplierFields.put_values(%{}, %{}) == %{}
      end

      test "values/1 reads the namespaced map and tolerates rows without one" do
        assert SupplierFields.values(%{metadata: %{"custom_fields" => %{"a" => 1}}}) == %{
                 "a" => 1
               }

        assert SupplierFields.values(%{metadata: %{}}) == %{}
        assert SupplierFields.values(%{metadata: nil}) == %{}
        assert SupplierFields.values(nil) == %{}
      end

      # Removing a definition must not destroy data already written under
      # its key — the value comes back if the field is re-added.
      test "removing a field leaves stored values in place" do
        add!("Incoterm")
        {:ok, cast} = SupplierFields.cast_values(%{"incoterm" => "DAP"})
        metadata = SupplierFields.put_values(%{}, cast)

        {:ok, _} = SupplierFields.remove_field("incoterm")

        assert SupplierFields.values(%{metadata: metadata}) == %{"incoterm" => "DAP"}
      end
    end

    describe "deletion guard" do
      test "refuses while fields are defined, allows an empty blueprint" do
        assert {:error, :supplier_fields_defined} =
                 SupplierFields.deletion_guard(%{fields_definition: [%{"key" => "a"}]})

        assert :ok = SupplierFields.deletion_guard(%{fields_definition: []})
      end

      test "generic callers cannot delete the blueprint at all" do
        entity = add!("Incoterm")

        assert {:error, :managed_blueprint} = PhoenixKitEntities.delete_entity(entity)
      end
    end

    describe "entities disabled" do
      setup do
        PhoenixKit.Settings.update_setting("entities_enabled", "false")
        :ok
      end

      test "reads degrade quietly and writes fail loudly" do
        assert SupplierFields.fields() == []
        assert SupplierFields.blueprint() == nil
        assert SupplierFields.field("anything") == nil

        assert {:error, :entities_disabled} = SupplierFields.add_field(%{label: "X"})
        assert {:error, :entities_disabled} = SupplierFields.update_field("x", %{label: "Y"})
        assert {:error, :entities_disabled} = SupplierFields.remove_field("x")
        assert {:error, :entities_disabled} = SupplierFields.ensure_blueprint()
      end

      # Every defined field is unknown when the definitions are
      # unreachable, so a save that carries extras is refused rather
      # than writing them unvalidated.
      test "casting refuses rather than writing unvalidated data" do
        assert {:error, :unknown_field} = SupplierFields.cast_values(%{"anything" => "x"})
        assert {:ok, %{}} = SupplierFields.cast_values(%{})
      end
    end
  end
end
