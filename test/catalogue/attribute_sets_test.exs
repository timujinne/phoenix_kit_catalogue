defmodule PhoenixKitCatalogue.Catalogue.AttributeSetsTest do
  @moduledoc """
  The attribute-sets rework (2026-08-18 design doc): provisioned
  managed blueprints, the contract, attachments, and the batched v2
  resolve. Drives the REAL entities API (path dep) — these tests are
  skipped when the entities package in use lacks the Managed contract.
  """
  use PhoenixKitCatalogue.DataCase, async: false

  alias PhoenixKitCatalogue.Catalogue

  import PhoenixKitCatalogue.LiveCase, only: [fixture_item: 1]
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitCatalogue.Catalogue.PubSub
  alias PhoenixKitCatalogue.Test.Repo

  if Code.ensure_loaded?(PhoenixKitEntities.Managed) do
    setup do
      # Entities gates on a settings toggle (default false). The delete
      # guard normally registers from the host supervision tree; do it
      # here so the entities-side path is armed too.
      AttributeSets.register_deletion_guard()
      PhoenixKit.Settings.update_setting("entities_enabled", "true")
      on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)
      :ok
    end

    defp create_set!(name, kind \\ "multi") do
      {:ok, set} =
        AttributeSets.create_set(%{name: name, kind: kind}, actor_uuid: Ecto.UUID.generate())

      set
    end

    describe "set provisioning" do
      test "creates a managed blueprint with the locked contract" do
        set = create_set!("Ikea colors")

        assert set.name == "catalogue_set_ikea_colors"
        assert set.display_name == "Ikea colors"
        assert set.settings["managed_by"] == "catalogue"
        assert set.settings["catalogue"]["kind"] == "multi"
        assert {:ok, %{kind: :multi, default: nil}} = AttributeSets.contract(set)

        # Hidden from the generic entities admin listing.
        generic = PhoenixKitEntities.list_entities(include_managed: false)
        refute Enum.any?(generic, &(&1.uuid == set.uuid))

        # Visible through the catalogue's own listing.
        assert Enum.any?(AttributeSets.list_sets(), &(&1.uuid == set.uuid))
      end

      test "update_set changes kind/default through the owner bypass" do
        set = create_set!("Ikea trims", "fixed")

        {:ok, _} =
          AttributeSets.create_value(set, %{label: "Gold"}, actor_uuid: Ecto.UUID.generate())

        {:ok, updated} =
          AttributeSets.update_set(set, %{kind: "multi", default_value_slug: "gold"})

        assert {:ok, %{kind: :multi, default: "gold"}} = AttributeSets.contract(updated)

        # The same change WITHOUT the owner bypass is refused by entities.
        assert {:error, :locked_key} =
                 PhoenixKitEntities.update_entity(updated, %{
                   "settings" => put_in(updated.settings, ["catalogue", "kind"], "fixed")
                 })
      end

      test "update_set refuses a default_value_slug with no matching value — never a guessed default" do
        set = create_set!("Ikea trims", "fixed")

        assert {:error, :contract_broken} =
                 AttributeSets.update_set(set, %{default_value_slug: "no-such-slug"})

        # Unwritten: the set still has no default, not a ghost one.
        assert {:ok, %{default: nil}} = AttributeSets.contract(AttributeSets.get_set(set.uuid))
      end

      test "contract rejects tampered blueprints instead of guessing" do
        set = create_set!("Ikea widths")
        broken = put_in(set.settings, ["catalogue", "kind"], "banana")
        assert {:error, :contract_broken} = AttributeSets.contract(%{set | settings: broken})
        assert {:error, :contract_broken} = AttributeSets.contract(%{settings: %{}, name: "x"})
      end
    end

    describe "values" do
      test "values are records with stable slugs, ordered" do
        set = create_set!("Ikea colors")

        {:ok, oak} =
          AttributeSets.create_value(set, %{label: "Oak"}, actor_uuid: Ecto.UUID.generate())

        {:ok, _} =
          AttributeSets.create_value(set, %{label: "Anthracite Grey"},
            actor_uuid: Ecto.UUID.generate()
          )

        assert oak.slug == "oak"
        assert [%{slug: "oak"}, %{slug: "anthracite-grey"}] = AttributeSets.list_values(set)
      end

      test "extras ride the record data" do
        set = create_set!("Ikea colors")

        {:ok, _} =
          PhoenixKitEntities.update_entity(
            set,
            %{
              "fields_definition" => [
                %{"type" => "number", "key" => "price_per_liter", "label" => "Price per liter"}
              ]
            },
            on_behalf_of: "catalogue"
          )

        set = AttributeSets.get_set(set.uuid)

        {:ok, red} =
          AttributeSets.create_value(
            set,
            %{label: "Red", extras: %{"price_per_liter" => 12}},
            actor_uuid: Ecto.UUID.generate()
          )

        assert red.data["price_per_liter"] == 12
      end

      test "value management: rename keeps the slug, extras, reorder, delete clears default" do
        actor = Ecto.UUID.generate()
        set = create_set!("Ikea colors")

        {:ok, _} =
          AttributeSets.add_extra_field(set, %{label: "Price per liter", type: "number"})

        set = AttributeSets.get_set(set.uuid)
        assert [%{"key" => "price_per_liter", "type" => "number"}] = set.fields_definition

        {:ok, oak} = AttributeSets.create_value(set, %{label: "Oak"}, actor_uuid: actor)
        {:ok, ash} = AttributeSets.create_value(set, %{label: "Ash"}, actor_uuid: actor)
        {:ok, _} = AttributeSets.update_set(set, %{default_value_slug: "oak"})
        set = AttributeSets.get_set(set.uuid)

        # Display text changes; the stable key never does.
        {:ok, renamed} = AttributeSets.update_value(set, oak, %{label: "Golden Oak"})
        assert renamed.slug == "oak"
        assert renamed.title == "Golden Oak"

        {:ok, priced} =
          AttributeSets.update_value(set, renamed, %{extras: %{"price_per_liter" => 12}})

        assert priced.data["price_per_liter"] == 12

        :ok = AttributeSets.reorder_values(set, [ash.uuid, oak.uuid])
        assert [%{slug: "ash"}, %{slug: "oak"}] = AttributeSets.list_values(set)

        # Deleting the default value clears the contract default too.
        {:ok, _} = AttributeSets.delete_value(set, priced)
        set = AttributeSets.get_set(set.uuid)
        assert {:ok, %{default: nil}} = AttributeSets.contract(set)
        assert [%{slug: "ash"}] = AttributeSets.list_values(set)

        # Field-management guards + removal (per-value data is kept).
        assert {:error, :duplicate_key} =
                 AttributeSets.add_extra_field(set, %{label: "Price per liter", type: "text"})

        assert {:error, :invalid_type} =
                 AttributeSets.add_extra_field(set, %{label: "X", type: "rich_text"})

        {:ok, _} = AttributeSets.remove_extra_field(set, "price_per_liter")
        assert AttributeSets.get_set(set.uuid).fields_definition == []
      end

      test "extras cast through the entities pipeline; select/image/video field types" do
        actor = Ecto.UUID.generate()
        set = create_set!("Ikea finishes")

        {:ok, _} = AttributeSets.add_extra_field(set, %{label: "Price", type: "number"})

        assert {:error, :options_required} =
                 AttributeSets.add_extra_field(set, %{label: "Finish", type: "select"})

        {:ok, _} =
          AttributeSets.add_extra_field(set, %{
            label: "Finish",
            type: "select",
            options: ["Matte", " Gloss ", ""]
          })

        {:ok, _} = AttributeSets.add_extra_field(set, %{label: "Swatch", type: "image"})
        set = AttributeSets.get_set(set.uuid)

        assert %{"options" => ["Matte", "Gloss"]} =
                 Enum.find(set.fields_definition, &(&1["key"] == "finish"))

        {:ok, oak} = AttributeSets.create_value(set, %{label: "Oak"}, actor_uuid: actor)

        # Raw form strings coerce; junk is refused before the DB.
        {:ok, v} = AttributeSets.update_value(set, oak, %{extras: %{"price" => "12.5"}})
        assert v.data["price"] == 12.5

        assert {:error, :invalid_value} =
                 AttributeSets.update_value(set, v, %{extras: %{"price" => "12abc"}})

        assert {:error, :invalid_value} =
                 AttributeSets.update_value(set, v, %{extras: %{"finish" => "Satin"}})

        {:ok, v} = AttributeSets.update_value(set, v, %{extras: %{"finish" => "Gloss"}})
        assert v.data["finish"] == "Gloss"

        assert {:error, :unknown_field} =
                 AttributeSets.update_value(set, v, %{extras: %{"nope" => "x"}})

        # Media reference: storage uuid in, junk refused, "" clears.
        file_uuid = Ecto.UUID.generate()
        {:ok, v} = AttributeSets.update_value(set, v, %{extras: %{"swatch" => file_uuid}})
        assert v.data["swatch"] == file_uuid

        assert {:error, :invalid_value} =
                 AttributeSets.update_value(set, v, %{extras: %{"swatch" => "not-a-uuid"}})

        {:ok, v} = AttributeSets.update_value(set, v, %{extras: %{"swatch" => ""}})
        assert v.data["swatch"] == nil
      end

      test "update_extra_field renames labels and edits select options, key immutable" do
        set = create_set!("Ikea papers")

        {:ok, _} =
          AttributeSets.add_extra_field(set, %{
            label: "Finish",
            type: "select",
            options: ["Matte", "Gloss"]
          })

        {:ok, _} =
          AttributeSets.update_extra_field(set, "finish", %{
            label: "Surface finish",
            options: ["Matte", "Gloss", "Satin"]
          })

        set = AttributeSets.get_set(set.uuid)
        [field] = set.fields_definition
        assert field["key"] == "finish"
        assert field["label"] == "Surface finish"
        assert field["options"] == ["Matte", "Gloss", "Satin"]

        assert {:error, :label_required} =
                 AttributeSets.update_extra_field(set, "finish", %{label: "  "})

        assert {:error, :options_required} =
                 AttributeSets.update_extra_field(set, "finish", %{options: ["", " "]})

        assert {:error, :unknown_field} =
                 AttributeSets.update_extra_field(set, "nope", %{label: "X"})
      end
    end

    describe "attachments + resolve" do
      test "multi-set attach, order, resolve, detach — the full v2 loop" do
        colors = create_set!("Ikea colors")
        widths = create_set!("Ikea widths", "fixed")

        {:ok, _} =
          AttributeSets.create_value(colors, %{label: "Oak"}, actor_uuid: Ecto.UUID.generate())

        {:ok, _} =
          AttributeSets.create_value(colors, %{label: "White"}, actor_uuid: Ecto.UUID.generate())

        {:ok, _} =
          AttributeSets.create_value(widths, %{label: "600mm"}, actor_uuid: Ecto.UUID.generate())

        {:ok, _} = AttributeSets.update_set(colors, %{default_value_slug: "oak"})

        item = fixture_item(%{name: "Door"})
        other = fixture_item(%{name: "Panel"})

        {:ok, _} = AttributeSets.attach_set(item.uuid, colors.uuid)
        {:ok, _} = AttributeSets.attach_set(item.uuid, widths.uuid)
        {:ok, _} = AttributeSets.attach_set(other.uuid, colors.uuid)

        # Batched resolve: both items, one shape.
        resolved = AttributeSets.resolve_for_items([item.uuid, other.uuid])

        assert %{schema_version: 2, sets: [c, w]} = resolved[item.uuid]
        assert c.key == "catalogue_set_ikea_colors"
        assert c.kind == :multi
        assert c.default == "oak"
        assert [%{key: "oak", label: "Oak"}, %{key: "white"}] = c.values
        assert w.kind == :fixed

        assert %{sets: [%{key: "catalogue_set_ikea_colors"}]} = resolved[other.uuid]

        # Reorder flips the item's set order.
        :ok = AttributeSets.reorder_attachments(item.uuid, [widths.uuid, colors.uuid])
        assert %{sets: [first, _]} = AttributeSets.resolve_for_item(item.uuid)
        assert first.key == "catalogue_set_ikea_widths"

        # Attached sets refuse deletion (catalogue and entities paths).
        assert {:error, :set_in_use} = AttributeSets.delete_set(colors)

        # Detach frees it.
        :ok = AttributeSets.detach_set(item.uuid, colors.uuid)
        :ok = AttributeSets.detach_set(other.uuid, colors.uuid)
        assert {:ok, _} = AttributeSets.delete_set(colors)
      end

      test "attach is idempotent and validates the set exists" do
        set = create_set!("Ikea trims")
        item = fixture_item(%{name: "Door"})

        {:ok, _} = AttributeSets.attach_set(item.uuid, set.uuid)
        {:ok, _} = AttributeSets.attach_set(item.uuid, set.uuid)
        assert length(AttributeSets.list_attachments(item.uuid)) == 1

        assert {:error, :set_not_found} =
                 AttributeSets.attach_set(item.uuid, Ecto.UUID.generate())
      end

      test "per-attachment selection: count is the mode, junk dropped, resolve carries it" do
        actor = Ecto.UUID.generate()
        set = create_set!("Ikea colors")
        {:ok, red} = AttributeSets.create_value(set, %{label: "Red"}, actor_uuid: actor)
        {:ok, blue} = AttributeSets.create_value(set, %{label: "Blue"}, actor_uuid: actor)
        {:ok, _} = AttributeSets.create_value(set, %{label: "Gold"}, actor_uuid: actor)

        item = fixture_item(%{name: "Door"})

        assert {:error, :not_attached} =
                 AttributeSets.set_attachment_selection(item.uuid, set.uuid, [red.slug])

        {:ok, _} = AttributeSets.attach_set(item.uuid, set.uuid)

        # No selection → no statement, resolve shows the whole set.
        assert %{sets: [%{selected: []}]} = AttributeSets.resolve_for_item(item.uuid)

        # One checked = this exact object.
        :ok = AttributeSets.set_attachment_selection(item.uuid, set.uuid, [red.slug])
        assert %{sets: [%{selected: [sel]}]} = AttributeSets.resolve_for_item(item.uuid)
        assert sel == red.slug

        # Several checked = the options it comes in; unknown slugs and
        # duplicates are dropped.
        :ok =
          AttributeSets.set_attachment_selection(item.uuid, set.uuid, [
            blue.slug,
            red.slug,
            red.slug,
            "not-a-value"
          ])

        assert %{sets: [%{selected: selected}]} = AttributeSets.resolve_for_item(item.uuid)
        assert Enum.sort(selected) == Enum.sort([red.slug, blue.slug])

        # Empty clears the statement.
        :ok = AttributeSets.set_attachment_selection(item.uuid, set.uuid, [])
        assert %{sets: [%{selected: []}]} = AttributeSets.resolve_for_item(item.uuid)
      end

      test "deleting a value sweeps it from selections; reads never echo ghosts" do
        actor = Ecto.UUID.generate()
        set = create_set!("Ikea trims")
        {:ok, red} = AttributeSets.create_value(set, %{label: "Red"}, actor_uuid: actor)
        {:ok, blue} = AttributeSets.create_value(set, %{label: "Blue"}, actor_uuid: actor)

        item = fixture_item(%{name: "Door"})
        {:ok, _} = AttributeSets.attach_set(item.uuid, set.uuid)
        :ok = AttributeSets.set_attachment_selection(item.uuid, set.uuid, [red.slug, blue.slug])

        # Deleting Red sweeps it from the stored selection (not just
        # the read path) — the row itself is rewritten.
        {:ok, _} = AttributeSets.delete_value(set, red)
        [attachment] = AttributeSets.list_attachments(item.uuid)
        assert attachment.data["selected_value_slugs"] == [blue.slug]
        assert %{sets: [%{selected: [b]}]} = AttributeSets.resolve_for_item(item.uuid)
        assert b == blue.slug

        # Belt for out-of-band ghosts (writes that bypassed the sweep):
        # the read path intersects with current values, degrading a
        # fully-ghosted selection to [] — whole set applies, the set
        # never vanishes and the mode never silently flips.
        Repo.update_all(
          from(a in PhoenixKitCatalogue.Schemas.ItemAttributeSet,
            where: a.item_uuid == ^item.uuid
          ),
          set: [data: %{"selected_value_slugs" => ["ghost-slug"]}]
        )

        assert %{sets: [%{selected: []}]} = AttributeSets.resolve_for_item(item.uuid)
      end

      test "attachment_counts and the single-set resolve (UI reads)" do
        set = create_set!("Ikea knobs")
        other = create_set!("Ikea rails")
        item = fixture_item(%{name: "Door"})
        item2 = fixture_item(%{name: "Panel"})

        {:ok, _} = AttributeSets.attach_set(item.uuid, set.uuid)
        {:ok, _} = AttributeSets.attach_set(item2.uuid, set.uuid)

        counts = AttributeSets.attachment_counts([set.uuid, other.uuid])
        assert counts[set.uuid] == 2
        refute Map.has_key?(counts, other.uuid)

        assert %{key: "catalogue_set_ikea_knobs", kind: :multi, values: []} =
                 AttributeSets.resolve_set(set.uuid)

        assert AttributeSets.resolve_set(Ecto.UUID.generate()) == nil
      end

      test "orphan pruning clears attachments to vanished blueprints" do
        set = create_set!("Ikea handles")
        item = fixture_item(%{name: "Door"})
        {:ok, _} = AttributeSets.attach_set(item.uuid, set.uuid)

        # With entities disabled EVERY set reads as missing — pruning
        # then must be a no-op, not a purge (panel finding).
        PhoenixKit.Settings.update_setting("entities_enabled", "false")
        assert AttributeSets.prune_orphan_attachments(set.uuid) == 0
        PhoenixKit.Settings.update_setting("entities_enabled", "true")
        assert length(AttributeSets.list_attachments(item.uuid)) == 1

        # Simulate an out-of-band blueprint delete (repo-level, bypassing
        # the guard) — the PubSub cleanup path prunes the orphan row.
        Repo.delete!(set)
        assert AttributeSets.prune_orphan_attachments(set.uuid) == 1
        assert AttributeSets.list_attachments(item.uuid) == []
      end
    end

    describe "PubSub broadcasts (every mutation must fan out — Catalogue.PubSub doctrine)" do
      setup do
        PubSub.subscribe()
        :ok
      end

      defp drain_events do
        receive do
          {:catalogue_data_changed, _, _, _} -> drain_events()
        after
          0 -> :ok
        end
      end

      test "an orphan prune broadcasts :attribute_set; nothing to prune stays silent" do
        set = create_set!("Ikea hinges")
        item = fixture_item(%{name: "Door"})
        {:ok, _} = AttributeSets.attach_set(item.uuid, set.uuid)
        drain_events()

        # The blueprint still exists — no-op, no event.
        assert AttributeSets.prune_orphan_attachments(set.uuid) == 0
        refute_receive {:catalogue_data_changed, :attribute_set, _, _}

        Repo.delete!(set)
        assert AttributeSets.prune_orphan_attachments(set.uuid) == 1
        assert_receive {:catalogue_data_changed, :attribute_set, uuid, nil}
        assert uuid == set.uuid
      end

      test "set CRUD broadcasts :attribute_set with the blueprint uuid" do
        {:ok, set} =
          AttributeSets.create_set(%{name: "Ikea colors"}, actor_uuid: Ecto.UUID.generate())

        assert_receive {:catalogue_data_changed, :attribute_set, uuid, nil}
        assert uuid == set.uuid

        {:ok, value} =
          AttributeSets.create_value(set, %{label: "Oak"}, actor_uuid: Ecto.UUID.generate())

        assert_receive {:catalogue_data_changed, :attribute_set, uuid, nil}
        assert uuid == set.uuid

        {:ok, _} = AttributeSets.update_set(set, %{default_value_slug: value.slug})
        assert_receive {:catalogue_data_changed, :attribute_set, uuid, nil}
        assert uuid == set.uuid
      end

      test "attach/detach/reorder broadcast :item scoped to the item's catalogue" do
        set = create_set!("Ikea trims")
        item = fixture_item(%{name: "Door"})

        {:ok, _} = AttributeSets.attach_set(item.uuid, set.uuid)
        assert_receive {:catalogue_data_changed, :item, uuid, parent}
        assert uuid == item.uuid
        assert parent == item.catalogue_uuid

        :ok = AttributeSets.detach_set(item.uuid, set.uuid)
        assert_receive {:catalogue_data_changed, :item, uuid, parent}
        assert uuid == item.uuid
        assert parent == item.catalogue_uuid
      end
    end

    describe "migration from groups" do
      test "explodes groups into sets, preserves keys, is idempotent" do
        actor = Ecto.UUID.generate()

        {:ok, group} = Catalogue.create_attribute_group(%{name: "Ikea doors"})
        {:ok, color} = Catalogue.create_attribute(group, %{"name" => "Color", "kind" => "multi"})
        {:ok, oak} = Catalogue.create_attribute_value(color, %{"value" => "Oak"})
        {:ok, _} = Catalogue.create_attribute_value(color, %{"value" => "White"})
        {:ok, _} = Catalogue.set_default_value(oak)
        {:ok, trim} = Catalogue.create_attribute(group, %{"name" => "Trim", "kind" => "fixed"})
        {:ok, _} = Catalogue.create_attribute_value(trim, %{"value" => "Gold"})

        item = fixture_item(%{name: "Door"})
        {:ok, _} = Catalogue.set_item_attribute_group(item, group.uuid)

        assert {:ok, %{sets: 2, values: 3, attachments: 2}} =
                 AttributeSets.migrate_groups_to_sets(actor_uuid: actor)

        # The item now resolves BOTH sets, keys preserved from the old
        # attribute/value keys so order-line picks keep working.
        %{sets: sets} = AttributeSets.resolve_for_item(item.uuid)
        assert length(sets) == 2

        color_set = Enum.find(sets, &(&1.kind == :multi))
        assert color_set.default == oak.key

        assert Enum.map(color_set.values, & &1.key) |> Enum.sort() ==
                 Enum.sort([oak.key | ["white"]])

        # Idempotent: nothing new on a re-run.
        assert {:ok, %{sets: 0, values: 0, attachments: 0}} =
                 AttributeSets.migrate_groups_to_sets(actor_uuid: actor)
      end

      test "colliding and non-sluggable names get distinct sets, defaults are topped up" do
        actor = Ecto.UUID.generate()

        # "A B"/"C" and "A"/"B C" both slugify to a_b_c; "Цвет" strips
        # to "" — three distinct dimensions that must NOT merge.
        {:ok, g1} = Catalogue.create_attribute_group(%{name: "A B"})
        {:ok, a1} = Catalogue.create_attribute(g1, %{"name" => "C", "kind" => "multi"})
        {:ok, v1} = Catalogue.create_attribute_value(a1, %{"value" => "One"})
        {:ok, _} = Catalogue.set_default_value(v1)

        {:ok, g2} = Catalogue.create_attribute_group(%{name: "A"})
        {:ok, _a2} = Catalogue.create_attribute(g2, %{"name" => "B C", "kind" => "multi"})

        {:ok, g3} = Catalogue.create_attribute_group(%{name: "Цвет"})
        {:ok, _a3} = Catalogue.create_attribute(g3, %{"name" => "Размер", "kind" => "fixed"})

        assert {:ok, %{sets: 3}} = AttributeSets.migrate_groups_to_sets(actor_uuid: actor)

        assert {:ok, %{sets: 0, values: 0}} =
                 AttributeSets.migrate_groups_to_sets(actor_uuid: actor)

        slugs = AttributeSets.list_sets() |> Enum.map(& &1.name)
        assert length(Enum.uniq(slugs)) == length(slugs)
        assert length(slugs) == 3

        # Default top-up: clear the migrated default to simulate a crash
        # between set creation and the default write — a re-run heals it.
        # The set is found by provenance (collision handling means its
        # slug depends on group processing order).
        with_default =
          Enum.find(
            AttributeSets.list_sets(),
            &(get_in(&1.settings, ["catalogue", "migrated_from"]) == a1.uuid)
          )

        {:ok, _} = AttributeSets.update_set(with_default, %{default_value_slug: nil})
        assert {:ok, %{sets: 0}} = AttributeSets.migrate_groups_to_sets(actor_uuid: actor)
        healed = AttributeSets.get_set(with_default.uuid)
        assert {:ok, %{default: default}} = AttributeSets.contract(healed)
        assert default == v1.key
      end
    end

    describe "auto migration" do
      test "auto_migrate_legacy migrates silently, no-ops when clean or disabled" do
        # Disabled → no-op, no crash.
        PhoenixKit.Settings.update_setting("entities_enabled", "false")
        assert :ok = AttributeSets.auto_migrate_legacy()
        PhoenixKit.Settings.update_setting("entities_enabled", "true")

        # Nothing legacy → no-op.
        assert :ok = AttributeSets.auto_migrate_legacy()
        assert AttributeSets.list_sets() == []

        # Legacy present → migrated without any manual step. The
        # auto-path carries no actor, so entities attributes creation
        # to the first user — give the sandbox one, as production has
        # (repo-level insert: register_user/1 needs the rate limiter's
        # ETS table, which this suite doesn't boot).
        {:ok, _user} =
          %User{}
          |> User.registration_changeset(%{
            email: "auto-migrate-#{System.unique_integer([:positive])}@example.com",
            password: "ValidPassword123!"
          })
          |> Repo.insert()

        {:ok, group} = Catalogue.create_attribute_group(%{name: "Auto doors"})
        {:ok, color} = Catalogue.create_attribute(group, %{"name" => "Color", "kind" => "multi"})
        {:ok, _} = Catalogue.create_attribute_value(color, %{"value" => "Oak"})
        item = fixture_item(%{name: "Door"})
        {:ok, _} = Catalogue.set_item_attribute_group(item, group.uuid)

        assert :ok = AttributeSets.auto_migrate_legacy()

        assert [%{key: "catalogue_set_auto_doors_color"}] =
                 AttributeSets.resolve_for_item(item.uuid).sets
      end
    end

    describe "quality-sweep pins (2026-08-19)" do
      test "value slugs survive non-Latin labels and duplicate labels" do
        actor = Ecto.UUID.generate()
        set = create_set!("Ikea colors")

        # Non-Latin labels slugify to "" — without the fallback every
        # Cyrillic value shares slug "" and per-value selection
        # collapses to one shared key.
        {:ok, red_ru} = AttributeSets.create_value(set, %{label: "Красный"}, actor_uuid: actor)
        {:ok, blue_ru} = AttributeSets.create_value(set, %{label: "Синий"}, actor_uuid: actor)
        assert red_ru.slug != ""
        assert blue_ru.slug != ""
        assert red_ru.slug != blue_ru.slug

        # Duplicate labels get disambiguated, not collided.
        {:ok, a} = AttributeSets.create_value(set, %{label: "Red"}, actor_uuid: actor)
        {:ok, b} = AttributeSets.create_value(set, %{label: "Red"}, actor_uuid: actor)
        assert a.slug == "red"
        assert b.slug != a.slug
        assert String.starts_with?(b.slug, "red-")
      end

      test "extra fields survive non-Latin labels; create_value casts extras" do
        set = create_set!("Ikea finishes")

        {:ok, set} = AttributeSets.add_extra_field(set, %{label: "Цена", type: "number"})
        [field] = set.fields_definition
        assert field["label"] == "Цена"
        assert String.starts_with?(field["key"], "field_")

        # create_value runs the same extras cast as update_value: junk
        # keys refuse instead of silently landing in record data.
        assert {:error, :unknown_field} =
                 AttributeSets.create_value(set, %{label: "Matte", extras: %{"nope" => 1}})

        {:ok, v} =
          AttributeSets.create_value(
            set,
            %{label: "Matte", extras: %{field["key"] => "12.5"}}
          )

        assert v.data[field["key"]] == 12.5
      end

      test "get_value scopes to the set" do
        set = create_set!("Ikea knobs")
        other = create_set!("Ikea rails")
        {:ok, v} = AttributeSets.create_value(set, %{label: "Brass"})

        assert AttributeSets.get_value(set, v.uuid).uuid == v.uuid
        assert AttributeSets.get_value(other, v.uuid) == nil
        assert AttributeSets.get_value(set, "not-a-uuid") == nil
      end

      test "extra_field_types is the curated entities subset" do
        assert AttributeSets.extra_field_types() ==
                 ~w(text textarea number boolean date select image video)
      end

      test "entities-side delete path consults the registered guard" do
        set = create_set!("Ikea hinges")
        item = fixture_item(%{name: "Door"})
        {:ok, _} = AttributeSets.attach_set(item.uuid, set.uuid)

        # NOT delete_set — the entities write path itself must refuse
        # through the registered deletion_guard/1 while attached.
        assert {:error, :set_in_use} =
                 PhoenixKitEntities.delete_entity(set, on_behalf_of: "catalogue")

        :ok = AttributeSets.detach_set(item.uuid, set.uuid)
        assert {:ok, _} = PhoenixKitEntities.delete_entity(set, on_behalf_of: "catalogue")
      end

      test "re-attach is a silent no-op: persisted row back, no second activity row" do
        set = create_set!("Ikea trims")
        item = fixture_item(%{name: "Door"})

        {:ok, first} = AttributeSets.attach_set(item.uuid, set.uuid, actor_uuid: nil)
        {:ok, again} = AttributeSets.attach_set(item.uuid, set.uuid, actor_uuid: nil)

        # The persisted position, not the attempted one.
        assert again.position == first.position

        assert_activity_logged("attribute_set.attached",
          resource_uuid: set.uuid,
          metadata_has: %{"item_uuid" => item.uuid}
        )
      end

      test "unchanged selection writes are no-ops (no duplicate activity rows)" do
        set = create_set!("Ikea colors")
        {:ok, red} = AttributeSets.create_value(set, %{label: "Red"})
        item = fixture_item(%{name: "Door"})
        {:ok, _} = AttributeSets.attach_set(item.uuid, set.uuid)

        :ok = AttributeSets.set_attachment_selection(item.uuid, set.uuid, [red.slug])
        :ok = AttributeSets.set_attachment_selection(item.uuid, set.uuid, [red.slug])

        # assert_activity_logged flunks on more than one matching row.
        assert_activity_logged("attribute_set.selection_changed", resource_uuid: set.uuid)
      end

      test "reorders and prunes land in the audit trail with resource links" do
        actor = Ecto.UUID.generate()
        set = create_set!("Ikea widths")
        {:ok, _} = AttributeSets.create_value(set, %{label: "40cm"})
        item = fixture_item(%{name: "Door"})
        {:ok, _} = AttributeSets.attach_set(item.uuid, set.uuid)

        assert_activity_logged("attribute_set.created", resource_uuid: set.uuid)
        assert_activity_logged("attribute_set.value_created", resource_uuid: set.uuid)

        # Junk uuids in a reorder are dropped, never a CastError crash.
        :ok = AttributeSets.reorder_values(set, ["junk", "x"], actor_uuid: actor)
        assert_activity_logged("attribute_set.values_reordered", resource_uuid: set.uuid)

        # A genuinely reordered attachment list logs; re-asserting the
        # same order does not add a second row.
        :ok = AttributeSets.reorder_attachments(item.uuid, [set.uuid])
        assert AttributeSets.list_attachments(item.uuid) |> length() == 1

        # Orphan prune: junk uuid degrades to 0, a real orphan logs.
        assert AttributeSets.prune_orphan_attachments("not-a-uuid") == 0
        Repo.delete!(set)
        assert AttributeSets.prune_orphan_attachments(set.uuid) == 1
        assert_activity_logged("attribute_set.orphans_pruned", resource_uuid: set.uuid)
      end

      test "valid_selection/2 is the single ghost rule" do
        resolved = %{values: [%{key: "red"}, %{key: "blue"}]}

        assert AttributeSets.valid_selection(["red", "ghost", "red", nil], resolved) == ["red"]
        assert AttributeSets.valid_selection("junk", resolved) == []
        assert AttributeSets.valid_selection(["red"], nil) == []
      end

      test "stale caller structs cannot clobber settings or fields" do
        stale = create_set!("Ikea panels")

        # Another writer stamps provenance after our struct was loaded.
        {:ok, _} =
          PhoenixKitEntities.update_entity(
            stale,
            %{settings: put_in(stale.settings, ["catalogue", "migrated_from"], "prov-123")},
            on_behalf_of: "catalogue"
          )

        # update_set re-reads: the whole-settings write keeps the key.
        {:ok, _} = AttributeSets.update_set(stale, %{name: "Ikea panels 2"})
        fresh = AttributeSets.get_set(stale.uuid)
        assert get_in(fresh.settings, ["catalogue", "migrated_from"]) == "prov-123"

        # remove_extra_field re-reads: removing B off a stale struct
        # that never saw A must not resurrect the pre-A field list.
        {:ok, with_a} = AttributeSets.add_extra_field(fresh, %{label: "Alpha", type: "text"})
        {:ok, _} = AttributeSets.add_extra_field(with_a, %{label: "Beta", type: "text"})
        {:ok, after_remove} = AttributeSets.remove_extra_field(fresh, "beta")
        assert Enum.map(after_remove.fields_definition, & &1["key"]) == ["alpha"]
      end
    end

    describe "disabled entities" do
      test "every entry point degrades loudly, none crash" do
        PhoenixKit.Settings.update_setting("entities_enabled", "false")

        assert {:error, :entities_disabled} = AttributeSets.create_set(%{name: "X"})
        assert AttributeSets.list_sets() == []
        assert AttributeSets.get_set(Ecto.UUID.generate()) == nil
        assert AttributeSets.resolve_for_items([Ecto.UUID.generate()]) == %{}
        assert Catalogue.resolve_attribute_sets_for_item(Ecto.UUID.generate()).sets == []
      end
    end
  else
    @tag :skip
    test "entities package lacks the Managed contract — suite skipped" do
      assert true
    end
  end
end
