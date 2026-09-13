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

  # Ecto's default `telemetry_prefix` for `PhoenixKitCatalogue.Test.Repo`
  # (no override in `test/support/test_repo.ex`): the module split,
  # underscored — `[:phoenix_kit_catalogue, :test, :repo]` — with `:query`
  # appended by `Ecto.Adapters.SQL` for every executed statement.
  @query_event [:phoenix_kit_catalogue, :test, :repo, :query]

  # Attaches a telemetry handler for the duration of `fun.()`, returns
  # every SQL statement text observed — used to assert a batched read
  # issues a fixed number of queries regardless of how many distinct
  # sets are in play (the N+1 this module has already had to fix once).
  defp query_texts(fun) do
    handler_id = {:query_texts, self(), System.unique_integer()}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      @query_event,
      fn _event, _measurements, %{query: query}, _config -> send(test_pid, {:query, query}) end,
      nil
    )

    try do
      fun.()
      collect_query_texts([])
    after
      :telemetry.detach(handler_id)
    end
  end

  defp collect_query_texts(acc) do
    receive do
      {:query, query} -> collect_query_texts([query | acc])
    after
      0 -> acc
    end
  end

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

    # Legacy assignment timestamps are second-precision; pin one clearly
    # before or after a migration run instead of racing the clock.
    defp shift_assignment_updated_at(item_uuid, seconds) do
      import Ecto.Query, only: [from: 2]

      at = DateTime.utc_now() |> DateTime.add(seconds) |> DateTime.truncate(:second)

      {1, _} =
        Repo.update_all(
          from(a in PhoenixKitCatalogue.Schemas.ItemAttributeGroup,
            where: a.item_uuid == ^item_uuid
          ),
          set: [updated_at: at]
        )

      :ok
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

      test "update_set still accepts an ARCHIVED default — a hidden value is still real (§3c)" do
        set = create_set!("Ikea trims archived default", "fixed")

        {:ok, gold} =
          AttributeSets.create_value(set, %{label: "Gold"}, actor_uuid: Ecto.UUID.generate())

        {:ok, set} = AttributeSets.update_set(set, %{default_value_slug: gold.slug})

        {:ok, _} =
          PhoenixKitEntities.EntityData.update(gold, %{status: "archived"}, activity_log: false)

        # An unrelated rename must not start failing just because the
        # set's default happens to point at an archived (still real,
        # still resolvable via `hidden_values`) value.
        assert {:ok, renamed} = AttributeSets.update_set(set, %{name: "Ikea trims v2"})
        assert {:ok, %{default: slug}} = AttributeSets.contract(renamed)
        assert slug == gold.slug
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

      test "resolve_set of a missing uuid skips the values/hidden-values reads" do
        # Existence is checked BEFORE paying for the values/hidden-values
        # listing reads — a random uuid must cost zero `entity_data`
        # queries, not the two full listing reads `get_set/2` would have
        # made pointless anyway.
        entity_data_queries =
          query_texts(fn -> AttributeSets.resolve_set(Ecto.UUID.generate()) end)
          |> Enum.count(&(&1 =~ "phoenix_kit_entity_data"))

        assert entity_data_queries == 0
      end

      test "resolve_set of an existing set stays within its stated statement budget" do
        # Pins the query-count claim from the PR description (also
        # confirmed by review): 9 statements total, 2 of them against
        # `phoenix_kit_entity_data` (one values fetch, one hidden-values
        # fetch — both batched, `resolve_set/2` passes a single-element
        # uuid list through the same batched calls `resolve_for_items/2`
        # uses). A regression that reintroduces a per-value or
        # per-field query would move this number; if a deliberate
        # change moves it, update both this assertion and the
        # description together.
        set = create_set!("Ikea statement budget")
        {:ok, _} = AttributeSets.create_value(set, %{label: "Oak"})

        queries = query_texts(fn -> AttributeSets.resolve_set(set.uuid) end)

        assert length(queries) == 9
        assert Enum.count(queries, &(&1 =~ "phoenix_kit_entity_data")) == 2
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

    describe "soft lifecycle: archive/restore a set (2026-09-11 direction)" do
      test "archive_set flips status through the owner bypass; generic writes still refuse it" do
        set = create_set!("Ikea colors")

        # The bug this replaces: a generic status write on a managed
        # blueprint is refused (identity-rename guard) — proves the
        # bypass in archive_set/2 is doing real work, not a no-op.
        assert {:error, :managed_blueprint} =
                 PhoenixKitEntities.update_entity(set, %{status: "archived"})

        assert {:ok, archived} = AttributeSets.archive_set(set)
        assert archived.status == "archived"

        assert {:ok, restored} = AttributeSets.restore_set(archived)
        assert restored.status == "published"
      end

      test "archiving is allowed even while the set is attached to items" do
        set = create_set!("Ikea trims")
        item = fixture_item(%{name: "Door"})
        {:ok, _} = AttributeSets.attach_set(item.uuid, set.uuid)

        assert {:ok, archived} = AttributeSets.archive_set(set)
        assert archived.status == "archived"
        # The attachment itself is untouched — soft-delete keeps ties intact.
        assert length(AttributeSets.list_attachments(item.uuid)) == 1
      end

      test "archive/restore log activity and broadcast" do
        set = create_set!("Ikea hinges")
        actor = Ecto.UUID.generate()

        {:ok, _} = AttributeSets.archive_set(set, actor_uuid: actor)
        assert_activity_logged("attribute_set.archived", resource_uuid: set.uuid)

        set = AttributeSets.get_set(set.uuid)
        {:ok, _} = AttributeSets.restore_set(set, actor_uuid: actor)
        assert_activity_logged("attribute_set.restored", resource_uuid: set.uuid)
      end

      test "archive/restore are idempotent — a repeat call writes no duplicate row" do
        set = create_set!("Ikea idempotent hinges")
        actor = Ecto.UUID.generate()

        {:ok, archived} = AttributeSets.archive_set(set, actor_uuid: actor)
        assert {:ok, ^archived} = AttributeSets.archive_set(archived, actor_uuid: actor)
        # Would flunk on a duplicate row (assert_activity_logged expects
        # exactly one match).
        assert_activity_logged("attribute_set.archived", resource_uuid: set.uuid)

        {:ok, restored} = AttributeSets.restore_set(archived, actor_uuid: actor)
        assert {:ok, ^restored} = AttributeSets.restore_set(restored, actor_uuid: actor)
        assert_activity_logged("attribute_set.restored", resource_uuid: set.uuid)
      end

      test "restore_set re-reads before deciding idempotency, not the caller's stale struct" do
        set = create_set!("Ikea stale restore")
        # `stale` still claims status "published" after this point.
        stale = set

        {:ok, _} = AttributeSets.archive_set(set)

        # The bug this replaces: the old idempotency clause pattern-matched
        # on `stale.status` itself ("published" != "archived"), so it
        # returned {:ok, stale} as a silent no-op — reporting "published"
        # while the DB stayed "archived". Re-reading before deciding must
        # see the real "archived" row and perform the write for real.
        assert {:ok, restored} = AttributeSets.restore_set(stale)
        assert restored.status == "published"
        assert AttributeSets.get_set(set.uuid).status == "published"
        assert_activity_logged("attribute_set.restored", resource_uuid: set.uuid)
      end

      test "archive_set re-reads before deciding idempotency, not the caller's stale struct" do
        set = create_set!("Ikea stale archive")

        {:ok, archived_stale} = AttributeSets.archive_set(set)
        {:ok, _} = AttributeSets.restore_set(archived_stale)
        # `archived_stale` still claims status "archived", though the set
        # is "published" again in the DB.

        assert {:ok, re_archived} = AttributeSets.archive_set(archived_stale)
        assert re_archived.status == "archived"
        assert AttributeSets.get_set(set.uuid).status == "archived"
      end

      test "archive_set/restore_set refuse :entities_disabled even on the idempotent path" do
        set = create_set!("Ikea disabled idempotent")
        {:ok, archived} = AttributeSets.archive_set(set)

        PhoenixKit.Settings.update_setting("entities_enabled", "false")

        # The bug this replaces: the idempotency clause matched BEFORE
        # `ensure_enabled/0` ran, so an already-archived/restored set kept
        # reporting success while the feature itself was off.
        assert {:error, :entities_disabled} = AttributeSets.archive_set(archived)
        assert {:error, :entities_disabled} = AttributeSets.restore_set(archived)
      end

      test "list_sets/1 defaults to non-archived, :archived and :all opt in" do
        active = create_set!("Active set")
        archived = create_set!("Archived set")
        {:ok, _} = AttributeSets.archive_set(archived)

        default_uuids = AttributeSets.list_sets() |> Enum.map(& &1.uuid)
        assert active.uuid in default_uuids
        refute archived.uuid in default_uuids

        archived_uuids = AttributeSets.list_sets(status: :archived) |> Enum.map(& &1.uuid)
        assert archived_uuids == [archived.uuid]

        all_uuids = AttributeSets.list_sets(status: :all) |> Enum.map(& &1.uuid)
        assert active.uuid in all_uuids
        assert archived.uuid in all_uuids
      end

      test "list_sets/1 raises on an unrecognized :status instead of reading as non-archived" do
        assert_raise ArgumentError, ~r/:status/, fn ->
          AttributeSets.list_sets(status: :published)
        end

        assert_raise ArgumentError, ~r/:status/, fn ->
          AttributeSets.list_sets(status: "archived")
        end
      end

      test "Catalogue delegates archive_attribute_set/2 and restore_attribute_set/2" do
        set = create_set!("Delegate set")

        assert {:ok, archived} = Catalogue.archive_attribute_set(set)
        assert archived.status == "archived"
        assert {:ok, restored} = Catalogue.restore_attribute_set(archived)
        assert restored.status == "published"
      end

      test "archive_set refuses a uuid that isn't a catalogue set — never falls back to the caller's struct" do
        # The bug this replaces: `get_set(set.uuid) || set` fell back to
        # the caller's own struct whenever the uuid didn't resolve to a
        # catalogue-owned set, and `do_archive_set/2` then flipped ITS
        # status through the owner bypass regardless — a public API meant
        # to touch only attribute sets could flip the status of ANY
        # entity handed to it, managed by catalogue or not.
        {:ok, foreign} =
          PhoenixKitEntities.create_entity(%{
            name: "some_unrelated_entity",
            display_name: "Unrelated",
            display_name_plural: "Unrelated",
            created_by_uuid: Ecto.UUID.generate()
          })

        assert {:error, :not_found} = AttributeSets.archive_set(foreign)
        assert PhoenixKitEntities.get_entity(foreign.uuid).status == "published"
      end

      test "restore_set refuses a uuid that isn't a catalogue set — never falls back to the caller's struct" do
        {:ok, foreign} =
          PhoenixKitEntities.create_entity(%{
            name: "some_other_unrelated_entity",
            display_name: "Unrelated",
            display_name_plural: "Unrelated",
            status: "archived",
            created_by_uuid: Ecto.UUID.generate()
          })

        assert {:error, :not_found} = AttributeSets.restore_set(foreign)
        assert PhoenixKitEntities.get_entity(foreign.uuid).status == "archived"
      end
    end

    describe "managed_path (2026-09-11 direction, step 2)" do
      test "create_set stamps a top-level managed_path settings key" do
        set = create_set!("Path set")
        assert set.settings["managed_path"] == "/admin/catalogue/attributes"
      end

      test "the managed_path key does not trip tampers_with_markers?/2" do
        set = create_set!("Path guard set")

        # managed_path is a top-level settings key, a sibling of
        # managed_by/locked_keys — NOT one of them. A generic (non-owner)
        # caller changing ONLY managed_path must pass: it touches neither
        # `tampers_with_markers?/2` (managed_by/locked_keys unchanged) nor
        # `touches_locked_keys?/2` (settings["catalogue"] unchanged).
        assert {:ok, _} =
                 PhoenixKitEntities.update_entity(set, %{
                   settings: Map.put(set.settings, "managed_path", "/x")
                 })
      end

      test "a locked key touched alongside managed_path is still rejected" do
        set = create_set!("Path guard set, locked key")

        # The positive test above only proves a BRAND NEW top-level key
        # passes — `touches_locked_keys?/2` allows any new key
        # unconditionally, so that alone wouldn't tell placement apart
        # from the key simply not being "kind"/"default_value_slug".
        # This is the other half: a generic (non-owner) caller that
        # rides the SAME settings write to also touch a real locked key
        # (`settings["catalogue"]["kind"]`) must still be refused.
        tampered_catalogue = Map.put(set.settings["catalogue"], "kind", "fixed")

        new_settings =
          set.settings
          |> Map.put("managed_path", "/x")
          |> Map.put("catalogue", tampered_catalogue)

        assert {:error, :locked_key} =
                 PhoenixKitEntities.update_entity(set, %{settings: new_settings})
      end

      test "backfill_managed_path stamps existing sets idempotently" do
        set = create_set!("Legacy path set")

        # Simulate a pre-existing set provisioned before managed_path
        # existed: strip it out via a direct owner-bypass write.
        {:ok, stripped} =
          PhoenixKitEntities.update_entity(
            set,
            %{settings: Map.delete(set.settings, "managed_path")},
            on_behalf_of: "catalogue"
          )

        refute Map.has_key?(stripped.settings, "managed_path")

        assert :ok = AttributeSets.backfill_managed_path()
        backfilled = AttributeSets.get_set(set.uuid)
        assert backfilled.settings["managed_path"] == "/admin/catalogue/attributes"

        # Idempotent: a set that already carries it is left alone (no
        # crash, no duplicate write) on a second run.
        assert :ok = AttributeSets.backfill_managed_path()

        assert AttributeSets.get_set(set.uuid).settings["managed_path"] ==
                 "/admin/catalogue/attributes"
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

      test "trashed or archived migrated values are not resurrected on re-run" do
        actor = Ecto.UUID.generate()

        {:ok, group} = Catalogue.create_attribute_group(%{name: "Hermes doors"})

        {:ok, color} =
          Catalogue.create_attribute(group, %{"name" => "Color", "kind" => "multi"})

        {:ok, _} = Catalogue.create_attribute_value(color, %{"value" => "Punane"})
        {:ok, _} = Catalogue.create_attribute_value(color, %{"value" => "Sinine"})

        assert {:ok, %{sets: 1, values: 2}} =
                 AttributeSets.migrate_groups_to_sets(actor_uuid: actor)

        [set] = AttributeSets.list_sets()
        [punane, sinine] = AttributeSets.list_values(set) |> Enum.sort_by(& &1.slug)

        {:ok, _} = PhoenixKitEntities.EntityData.trash(punane)

        {:ok, _} =
          PhoenixKitEntities.EntityData.update(sinine, %{status: "archived"}, activity_log: false)

        # Legacy group still exists in the DB (adoption never deletes it),
        # so a repeat run (as `auto_migrate_legacy/0` fires on every
        # Attributes-tab visit) must not top up either value back to
        # "published" — the trashed/archived row already carries the slug.
        assert {:ok, %{sets: 0, values: 0}} =
                 AttributeSets.migrate_groups_to_sets(actor_uuid: actor)

        all_rows =
          PhoenixKitEntities.EntityData.list_by_entity(set.uuid, include_trashed: true)

        by_slug = Enum.group_by(all_rows, & &1.slug)
        assert Map.keys(by_slug) |> Enum.sort() == Enum.sort([punane.slug, sinine.slug])
        assert length(by_slug[punane.slug]) == 1
        assert length(by_slug[sinine.slug]) == 1

        assert hd(by_slug[punane.slug]).status == "trashed"
        assert hd(by_slug[sinine.slug]).status == "archived"
      end

      test "a migrated set detached from an item is not re-attached on re-run" do
        actor = Ecto.UUID.generate()

        {:ok, group} = Catalogue.create_attribute_group(%{name: "Hermes handles"})

        {:ok, finish} =
          Catalogue.create_attribute(group, %{"name" => "Finish", "kind" => "multi"})

        {:ok, _} = Catalogue.create_attribute_value(finish, %{"value" => "Brass"})

        item = fixture_item(%{name: "Handle"})
        {:ok, _} = Catalogue.set_item_attribute_group(item, group.uuid)
        :ok = shift_assignment_updated_at(item.uuid, -60)

        assert {:ok, %{sets: 1, attachments: 1}} =
                 AttributeSets.migrate_groups_to_sets(actor_uuid: actor)

        [set] = AttributeSets.list_sets()

        assert is_binary(
                 get_in(AttributeSets.get_set(set.uuid).settings, [
                   "catalogue",
                   "assignments_migrated_at"
                 ])
               )

        # The legacy assignment row stays forever and the migration re-runs
        # on every Attributes-tab visit — the detach must stick.
        :ok = AttributeSets.detach_set(item.uuid, set.uuid)

        assert {:ok, %{attachments: 0}} = AttributeSets.migrate_groups_to_sets(actor_uuid: actor)
        assert AttributeSets.list_attachments(item.uuid) == []

        # A legacy assignment written after the set was migrated is a new
        # statement and still migrates, without undoing the detach above.
        later = fixture_item(%{name: "Handle later"})
        {:ok, _} = Catalogue.set_item_attribute_group(later, group.uuid)
        :ok = shift_assignment_updated_at(later.uuid, 60)

        assert {:ok, %{attachments: 1}} = AttributeSets.migrate_groups_to_sets(actor_uuid: actor)
        set_uuid = set.uuid
        assert [%{set_uuid: ^set_uuid}] = AttributeSets.list_attachments(later.uuid)
        assert AttributeSets.list_attachments(item.uuid) == []
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

    describe "prune_orphan_value_slugs/1 (3b, 2026-09-11 direction)" do
      test "sweeps slugs of HARD-deleted values, leaves archived/trashed ones alone" do
        actor = Ecto.UUID.generate()
        set = create_set!("Ikea veneers")
        {:ok, red} = AttributeSets.create_value(set, %{label: "Red"}, actor_uuid: actor)
        {:ok, blue} = AttributeSets.create_value(set, %{label: "Blue"}, actor_uuid: actor)
        {:ok, green} = AttributeSets.create_value(set, %{label: "Green"}, actor_uuid: actor)

        item = fixture_item(%{name: "Door"})
        {:ok, _} = AttributeSets.attach_set(item.uuid, set.uuid)

        :ok =
          AttributeSets.set_attachment_selection(item.uuid, set.uuid, [
            red.slug,
            blue.slug,
            green.slug
          ])

        # Archive Blue (soft) and hard-delete Green out of band — bypassing
        # AttributeSets.delete_value/3's own sweep, simulating exactly the
        # scenario the subscriber backstops (a delete that skipped it).
        {:ok, _} =
          PhoenixKitEntities.EntityData.update(blue, %{status: "archived"}, activity_log: false)

        {:ok, _} = PhoenixKitEntities.EntityData.delete(green, activity_log: false)

        assert AttributeSets.prune_orphan_value_slugs(set.uuid) == 1

        [attachment] = AttributeSets.list_attachments(item.uuid)
        selected = attachment.data["selected_value_slugs"]
        # Red (live) and Blue (archived, still a real row) survive; Green
        # (hard-deleted, no row anywhere) is gone.
        assert Enum.sort(selected) == Enum.sort([red.slug, blue.slug])

        # A clean set no-ops.
        assert AttributeSets.prune_orphan_value_slugs(set.uuid) == 0

        assert_activity_logged("attribute_set.orphans_pruned",
          resource_uuid: set.uuid,
          metadata_has: %{"count" => 1}
        )
      end

      test "a TRASHED value's slug is also not an orphan — the other half of archived-or-trashed" do
        # The test above only exercises the archived half of "leaves
        # archived/trashed ones alone" — `EntityData.list_by_entity/2`
        # doesn't exclude archived by default anyway, so that half would
        # pass even if `sweep_orphan_value_slugs/1` dropped
        # `include_trashed: true` entirely. Trash Blue here instead, the
        # one status that flag actually gates.
        actor = Ecto.UUID.generate()
        set = create_set!("Ikea veneers trashed")
        {:ok, red} = AttributeSets.create_value(set, %{label: "Red"}, actor_uuid: actor)
        {:ok, blue} = AttributeSets.create_value(set, %{label: "Blue"}, actor_uuid: actor)

        item = fixture_item(%{name: "Door"})
        {:ok, _} = AttributeSets.attach_set(item.uuid, set.uuid)

        :ok =
          AttributeSets.set_attachment_selection(item.uuid, set.uuid, [red.slug, blue.slug])

        {:ok, _} = PhoenixKitEntities.EntityData.trash(blue)

        assert AttributeSets.prune_orphan_value_slugs(set.uuid) == 0

        [attachment] = AttributeSets.list_attachments(item.uuid)
        selected = attachment.data["selected_value_slugs"]
        assert Enum.sort(selected) == Enum.sort([red.slug, blue.slug])
      end

      test "prunes each orphan slug via an atomic per-slug UPDATE, not a snapshot overwrite" do
        # Review finding: the old version read every attachment's full
        # selection into `kept`, then overwrote the WHOLE array with it —
        # a selection saved between that read and the write would be
        # lost. The fix removes each orphan slug with the same atomic
        # jsonb `-` UPDATE `delete_value/3` already uses (WHERE the row
        # actually carries the slug), so a concurrent write to any OTHER
        # slug on the same row can never be clobbered. This pins that
        # atomicity at the SQL level: one UPDATE per orphan slug, using
        # the `-` remove-key operator, never a whole-array
        # `to_jsonb(?::text[])` replace.
        actor = Ecto.UUID.generate()
        set = create_set!("Ikea veneers atomic")
        {:ok, red} = AttributeSets.create_value(set, %{label: "Red"}, actor_uuid: actor)
        {:ok, green} = AttributeSets.create_value(set, %{label: "Green"}, actor_uuid: actor)

        item_a = fixture_item(%{name: "Door A"})
        item_b = fixture_item(%{name: "Door B"})
        {:ok, _} = AttributeSets.attach_set(item_a.uuid, set.uuid)
        {:ok, _} = AttributeSets.attach_set(item_b.uuid, set.uuid)

        :ok =
          AttributeSets.set_attachment_selection(item_a.uuid, set.uuid, [red.slug, green.slug])

        :ok = AttributeSets.set_attachment_selection(item_b.uuid, set.uuid, [green.slug])

        {:ok, _} = PhoenixKitEntities.EntityData.delete(green, activity_log: false)

        queries = query_texts(fn -> AttributeSets.prune_orphan_value_slugs(set.uuid) end)

        update_queries =
          Enum.filter(queries, &(String.contains?(&1, "UPDATE") and &1 =~ "item_attribute_sets"))

        # One orphan slug ⇒ one UPDATE, even though it touches two rows —
        # the whole point of a set-based atomic UPDATE over a per-row loop.
        assert length(update_queries) == 1
        assert Enum.all?(update_queries, &String.contains?(&1, "jsonb_set"))
        refute Enum.any?(update_queries, &String.contains?(&1, "to_jsonb"))

        [att_a] = AttributeSets.list_attachments(item_a.uuid)
        [att_b] = AttributeSets.list_attachments(item_b.uuid)
        assert att_a.data["selected_value_slugs"] == [red.slug]
        assert att_b.data["selected_value_slugs"] == []
      end

      test "no-op for a uuid that isn't a catalogue set" do
        assert AttributeSets.prune_orphan_value_slugs(Ecto.UUID.generate()) == 0
        assert AttributeSets.prune_orphan_value_slugs("not-a-uuid") == 0
      end
    end

    describe "OrphanPruner subscribes to data-deletion events too (3b)" do
      test "prunes value slugs on {:data_deleted, set_uuid, value_uuid}" do
        set = create_set!("Ikea rails")
        {:ok, red} = AttributeSets.create_value(set, %{label: "Red"})
        item = fixture_item(%{name: "Door"})
        {:ok, _} = AttributeSets.attach_set(item.uuid, set.uuid)
        :ok = AttributeSets.set_attachment_selection(item.uuid, set.uuid, [red.slug])

        {:ok, _} = PhoenixKitEntities.EntityData.delete(red, activity_log: false)

        assert {:noreply, %{}} =
                 AttributeSets.OrphanPruner.handle_info(
                   {:data_deleted, set.uuid, red.uuid},
                   %{}
                 )

        [attachment] = AttributeSets.list_attachments(item.uuid)
        assert attachment.data["selected_value_slugs"] == []

        # A data_deleted for something that isn't a set, and shared-topic
        # noise, are absorbed rather than crashing the subscriber.
        assert {:noreply, %{}} =
                 AttributeSets.OrphanPruner.handle_info(
                   {:data_deleted, Ecto.UUID.generate(), Ecto.UUID.generate()},
                   %{}
                 )

        assert {:noreply, %{}} =
                 AttributeSets.OrphanPruner.handle_info({:data_created, "x", "y"}, %{})
      end

      test "init/1 really subscribes — a broadcast event reaches a started process" do
        # Every other test in this describe block drives
        # `handle_info/2` directly, which would stay green even if
        # `init/1` stopped calling `subscribe_to_all_data/0` (review
        # finding). Start the GenServer for real and fire the event
        # through entities' own PubSub broadcast instead, so the
        # subscription itself is what's under test.
        set = create_set!("Ikea rails subscribed")
        {:ok, red} = AttributeSets.create_value(set, %{label: "Red"})
        item = fixture_item(%{name: "Door"})
        {:ok, _} = AttributeSets.attach_set(item.uuid, set.uuid)
        :ok = AttributeSets.set_attachment_selection(item.uuid, set.uuid, [red.slug])

        {:ok, _} = PhoenixKitEntities.EntityData.delete(red, activity_log: false)

        pid = start_supervised!(AttributeSets.OrphanPruner)

        PhoenixKitEntities.Events.broadcast_data_deleted(set.uuid, red.uuid)

        # Synchronize on the GenServer's mailbox instead of sleeping —
        # once it replies here, the broadcast above has been handled.
        _ = :sys.get_state(pid)

        [attachment] = AttributeSets.list_attachments(item.uuid)
        assert attachment.data["selected_value_slugs"] == []
      end
    end

    describe "hidden values: archived/trashed selections survive resolve (3c)" do
      test "resolve_set carries hidden_values; values stays active-only" do
        set = create_set!("Ikea finishes")
        {:ok, oak} = AttributeSets.create_value(set, %{label: "Oak"})
        {:ok, ash} = AttributeSets.create_value(set, %{label: "Ash"})

        {:ok, _} =
          PhoenixKitEntities.EntityData.update(ash, %{status: "archived"}, activity_log: false)

        resolved = AttributeSets.resolve_set(set.uuid)

        assert Enum.map(resolved.values, & &1.key) == [oak.slug]
        assert Enum.map(resolved.hidden_values, & &1.key) == [ash.slug]
      end

      test "resolve_set carries a TRASHED value in hidden_values too, not just archived" do
        set = create_set!("Ikea finishes trashed")
        {:ok, oak} = AttributeSets.create_value(set, %{label: "Oak"})
        {:ok, ash} = AttributeSets.create_value(set, %{label: "Ash"})

        {:ok, _} = PhoenixKitEntities.EntityData.trash(ash)

        resolved = AttributeSets.resolve_set(set.uuid)

        assert Enum.map(resolved.values, & &1.key) == [oak.slug]
        assert Enum.map(resolved.hidden_values, & &1.key) == [ash.slug]
      end

      test "list_hidden_values_for/2 filters by status in SQL, not by re-fetching active rows" do
        # Review finding: the hidden-values batch used to load every row
        # of the set — active included — then filter by status in
        # Elixir, re-reading the same active values `list_values_for/2`
        # already fetches separately. Filtering server-side means the
        # query text itself excludes the non-hidden statuses.
        set = create_set!("Ikea finishes sql-filtered")
        {:ok, oak} = AttributeSets.create_value(set, %{label: "Oak"})
        {:ok, ash} = AttributeSets.create_value(set, %{label: "Ash"})

        {:ok, _} =
          PhoenixKitEntities.EntityData.update(ash, %{status: "archived"}, activity_log: false)

        queries =
          query_texts(fn -> AttributeSets.list_hidden_values_for([set.uuid]) end)

        entity_data_query =
          Enum.find(queries, &(&1 =~ "phoenix_kit_entity_data"))

        refute is_nil(entity_data_query)
        assert entity_data_query =~ "status"

        # Behaviour is unchanged: only the archived value comes back.
        hidden = AttributeSets.list_hidden_values_for([set.uuid]) |> Map.get(set.uuid, [])
        assert Enum.map(hidden, & &1.uuid) == [ash.uuid]
        refute Enum.any?(hidden, &(&1.uuid == oak.uuid))
      end

      test "a live value's slug wins over a trashed duplicate sharing the same key" do
        # A trashed value's slug isn't checked for uniqueness against new
        # values (`value_slug/3` only compares against active ones), so
        # the same slug can end up on more than one row: a live value
        # plus one or more stale trashed copies underneath it. Every
        # consumer builds its lookup pool as `values ++ hidden_values`
        # (product card, attribute-set items modal, item form) — a
        # duplicate key there means "last wins", and the stale trashed
        # row's label would silently shadow the live one's.
        set = create_set!("Ikea slug collision")

        {:ok, old} =
          AttributeSets.create_value(set, %{label: "Old Red", slug: "punane"})

        {:ok, _} = PhoenixKitEntities.EntityData.trash(old)

        {:ok, live} =
          AttributeSets.create_value(set, %{label: "New Red", slug: "punane"})

        assert old.slug == live.slug

        resolved = AttributeSets.resolve_set(set.uuid)

        assert Enum.map(resolved.values, & &1.key) == ["punane"]
        assert Enum.map(resolved.values, & &1.label) == ["New Red"]
        # The trashed duplicate is dropped entirely, not just shadowed —
        # the live row already carries the key, so it stays the ONLY
        # source of that key in the resolved pool.
        assert resolved.hidden_values == []
      end

      test "two HIDDEN rows sharing a slug (no live row) still collapse to one" do
        # Same slug-uniqueness gap as above, but with no live value at
        # all this time: a trashed row and an archived row sharing a
        # slug. Without collapsing hidden-vs-hidden duplicates too, both
        # would survive into `hidden_values`, and the item form would
        # render the selection's chip twice for what is really one slug.
        set = create_set!("Ikea slug collision hidden-hidden")

        {:ok, old} =
          AttributeSets.create_value(set, %{label: "Old Teal", slug: "roheline"})

        {:ok, _} = PhoenixKitEntities.EntityData.trash(old)

        {:ok, newer} =
          AttributeSets.create_value(set, %{label: "Newer Teal", slug: "roheline"})

        {:ok, _} =
          PhoenixKitEntities.EntityData.update(newer, %{status: "archived"}, activity_log: false)

        resolved = AttributeSets.resolve_set(set.uuid)

        assert resolved.values == []
        assert Enum.map(resolved.hidden_values, & &1.key) == ["roheline"]
      end

      test "a selected value that gets archived is not silently dropped from resolve" do
        actor = Ecto.UUID.generate()
        set = create_set!("Ikea worktops")
        {:ok, oak} = AttributeSets.create_value(set, %{label: "Oak"}, actor_uuid: actor)
        {:ok, ash} = AttributeSets.create_value(set, %{label: "Ash"}, actor_uuid: actor)

        item = fixture_item(%{name: "Worktop"})
        {:ok, _} = AttributeSets.attach_set(item.uuid, set.uuid)
        :ok = AttributeSets.set_attachment_selection(item.uuid, set.uuid, [oak.slug, ash.slug])

        {:ok, _} =
          PhoenixKitEntities.EntityData.update(ash, %{status: "archived"}, activity_log: false)

        assert %{sets: [resolved]} = AttributeSets.resolve_for_item(item.uuid)
        # Invariant: the selection keeps BOTH — archiving a value must not
        # silently drop it from what the item is resolved to have picked.
        assert Enum.sort(resolved.selected) == Enum.sort([oak.slug, ash.slug])
        # Invariant: `values` (what a picker OFFERS) stays active-only.
        assert Enum.map(resolved.values, & &1.key) == [oak.slug]
        assert Enum.map(resolved.hidden_values, & &1.key) == [ash.slug]
      end

      test "resolve_for_items batches hidden-value loading across sets (no N+1)" do
        sets =
          for n <- 1..4 do
            set = create_set!("Ikea hidden batch #{n}")
            {:ok, kept} = AttributeSets.create_value(set, %{label: "Kept"})

            {:ok, gone} =
              AttributeSets.create_value(set, %{label: "Gone"})

            {:ok, _} =
              PhoenixKitEntities.EntityData.update(gone, %{status: "archived"},
                activity_log: false
              )

            {set, kept}
          end

        item = fixture_item(%{name: "Combo"})

        for {set, _kept} <- sets do
          {:ok, _} = AttributeSets.attach_set(item.uuid, set.uuid)
        end

        entity_data_queries =
          query_texts(fn -> AttributeSets.resolve_for_items([item.uuid]) end)
          |> Enum.count(&(&1 =~ "phoenix_kit_entity_data"))

        # Values and hidden values are each fetched in ONE batched query
        # across every distinct set in play, not once per set — 4 distinct
        # sets must cost the SAME entity_data-table query count as 1 would
        # (2: one values fetch, one hidden-values fetch). Before the fix,
        # `list_hidden_values/2` looped `EntityData.list_by_entity/2` per
        # set, so this scaled with the number of sets instead.
        assert entity_data_queries == 2
      end

      test "a HARD-deleted value's slug is still dropped — the ghost rule survives" do
        actor = Ecto.UUID.generate()
        set = create_set!("Ikea legs")
        {:ok, oak} = AttributeSets.create_value(set, %{label: "Oak"}, actor_uuid: actor)
        {:ok, steel} = AttributeSets.create_value(set, %{label: "Steel"}, actor_uuid: actor)

        item = fixture_item(%{name: "Legs"})
        {:ok, _} = AttributeSets.attach_set(item.uuid, set.uuid)
        :ok = AttributeSets.set_attachment_selection(item.uuid, set.uuid, [oak.slug, steel.slug])

        {:ok, _} = AttributeSets.delete_value(set, steel)

        assert %{sets: [resolved]} = AttributeSets.resolve_for_item(item.uuid)
        assert resolved.selected == [oak.slug]
      end

      test "set_attachment_selection keeps a stored hidden slug but refuses to ADD one" do
        set = create_set!("Ikea handles")
        {:ok, oak} = AttributeSets.create_value(set, %{label: "Oak"})
        {:ok, ash} = AttributeSets.create_value(set, %{label: "Ash"})
        {:ok, elm} = AttributeSets.create_value(set, %{label: "Elm"})

        kept = fixture_item(%{name: "Handle kept"})
        {:ok, _} = AttributeSets.attach_set(kept.uuid, set.uuid)
        :ok = AttributeSets.set_attachment_selection(kept.uuid, set.uuid, [oak.slug, ash.slug])

        added = fixture_item(%{name: "Handle added"})
        {:ok, _} = AttributeSets.attach_set(added.uuid, set.uuid)
        :ok = AttributeSets.set_attachment_selection(added.uuid, set.uuid, [oak.slug])

        for value <- [ash, elm] do
          {:ok, _} =
            PhoenixKitEntities.EntityData.update(value, %{status: "archived"},
              activity_log: false
            )
        end

        # Re-saving a selection that already holds the hidden value keeps it.
        :ok = AttributeSets.set_attachment_selection(kept.uuid, set.uuid, [oak.slug, ash.slug])
        assert %{sets: [resolved]} = AttributeSets.resolve_for_item(kept.uuid)
        assert Enum.sort(resolved.selected) == Enum.sort([oak.slug, ash.slug])

        # A hidden value the row never held is dropped — not offered, not addable.
        :ok = AttributeSets.set_attachment_selection(added.uuid, set.uuid, [oak.slug, elm.slug])
        assert %{sets: [resolved]} = AttributeSets.resolve_for_item(added.uuid)
        assert resolved.selected == [oak.slug]
      end

      test "valid_selection/2 accepts hidden_values slugs, still drops true ghosts" do
        resolved = %{
          values: [%{key: "red"}],
          hidden_values: [%{key: "blue"}]
        }

        assert AttributeSets.valid_selection(["red", "blue", "ghost"], resolved) ==
                 ["red", "blue"]

        # Backward compatible: a map with no :hidden_values key still works.
        assert AttributeSets.valid_selection(["red"], %{values: [%{key: "red"}]}) == ["red"]
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
