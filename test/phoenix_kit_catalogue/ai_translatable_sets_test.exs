defmodule PhoenixKitCatalogue.AITranslatableSetsTest do
  @moduledoc """
  Unit coverage for the catalogue attribute-SETS `Translatable` adapter —
  the entities-backed `"catalogue_set_label"` (blueprint display name) and
  `"catalogue_set_value"` (value title) resources. Drives the real entities
  API (path dep); skipped when it lacks the Managed contract, same guard as
  `AttributeSetsTest`.
  """

  use PhoenixKitCatalogue.DataCase, async: false

  alias PhoenixKitCatalogue.AITranslatable.Sets
  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitCatalogue.TranslationStatus

  # Ecto's default `telemetry_prefix` for `PhoenixKitCatalogue.Test.Repo`
  # (no override in `test/support/test_repo.ex`): the module split,
  # underscored — `[:phoenix_kit_catalogue, :test, :repo]` — with `:query`
  # appended by `Ecto.Adapters.SQL` for every executed statement.
  @query_event [:phoenix_kit_catalogue, :test, :repo, :query]

  # Attaches a telemetry handler for the duration of `fun.()`, returns
  # every SQL statement text observed. Used to assert `Sets.put_translation/4`
  # issues an actual `FOR UPDATE` lock, not just a plain re-read.
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
    alias PhoenixKitEntities.EntityData

    setup do
      AttributeSets.register_deletion_guard()
      PhoenixKit.Settings.update_setting("entities_enabled", "true")
      on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)
      :ok
    end

    defp create_set!(name \\ "Ikea colors") do
      {:ok, set} = AttributeSets.create_set(%{name: name}, actor_uuid: Ecto.UUID.generate())
      set
    end

    defp create_value!(set, label \\ "Oak") do
      {:ok, value} =
        AttributeSets.create_value(set, %{label: label}, actor_uuid: Ecto.UUID.generate())

      value
    end

    # A generic (unmanaged) blueprint — the negative case for the ownership
    # scoping `fetch/2` must apply. Provisioned directly through entities,
    # bypassing `AttributeSets` (which only ever creates managed ones).
    defp create_unmanaged_entity! do
      {:ok, entity} =
        PhoenixKitEntities.create_entity(%{
          name: "brand_#{Ecto.UUID.generate() |> binary_part(0, 8)}",
          display_name: "Brand",
          display_name_plural: "Brands",
          created_by_uuid: Ecto.UUID.generate()
        })

      entity
    end

    describe "fetch/2" do
      test "loads a managed set (catalogue_set_label) by uuid" do
        set = create_set!()
        assert {:ok, fetched} = Sets.fetch("catalogue_set_label", set.uuid)
        assert fetched.uuid == set.uuid
      end

      test "loads a value (catalogue_set_value) whose entity is a catalogue set" do
        set = create_set!()
        value = create_value!(set)
        assert {:ok, fetched} = Sets.fetch("catalogue_set_value", value.uuid)
        assert fetched.uuid == value.uuid
      end

      test "refuses a blueprint not managed by catalogue" do
        entity = create_unmanaged_entity!()
        assert {:error, :resource_not_found} = Sets.fetch("catalogue_set_label", entity.uuid)
      end

      test "refuses a value whose entity is not a catalogue set" do
        entity = create_unmanaged_entity!()

        {:ok, value} =
          EntityData.create(%{
            entity_uuid: entity.uuid,
            title: "Acme",
            created_by_uuid: Ecto.UUID.generate()
          })

        assert {:error, :resource_not_found} = Sets.fetch("catalogue_set_value", value.uuid)
      end

      test "missing row → :resource_not_found" do
        assert {:error, :resource_not_found} =
                 Sets.fetch("catalogue_set_label", Ecto.UUID.generate())

        assert {:error, :resource_not_found} =
                 Sets.fetch("catalogue_set_value", Ecto.UUID.generate())
      end

      test "unknown resource type → :unknown_resource_type" do
        assert {:error, {:unknown_resource_type, "bogus"}} = Sets.fetch("bogus", "x")
      end
    end

    describe "source_fields/2" do
      test "set label reads the primary display_name" do
        set = create_set!("Ikea colors")
        assert Sets.source_fields(set, "en-US") == %{"label" => "Ikea colors"}
      end

      test "set label prefers an existing translation override" do
        set = create_set!("Ikea colors")

        {:ok, set} =
          PhoenixKitEntities.set_entity_translation(set, "en-US", %{"display_name" => "Colours"})

        assert Sets.source_fields(set, "en-US") == %{"label" => "Colours"}
      end

      test "value title reads the title column" do
        set = create_set!()
        value = create_value!(set, "Oak")
        assert Sets.source_fields(value, "en-US") == %{"title" => "Oak"}
      end

      test "value title prefers data[lang][\"_title\"] over the column" do
        set = create_set!()
        value = create_value!(set, "Oak")
        {:ok, value} = EntityData.set_title_translation(value, "en-US", "Oak (override)")
        assert Sets.source_fields(value, "en-US") == %{"title" => "Oak (override)"}
      end
    end

    describe "put_translation/4 — set label" do
      test ~s(writes settings["translations"][lang]["display_name"]) do
        set = create_set!()
        assert {:ok, _} = Sets.put_translation(set, "fr-FR", %{"label" => "Couleurs"}, [])

        reloaded = PhoenixKitEntities.get_entity(set.uuid)
        assert reloaded.settings["translations"]["fr-FR"]["display_name"] == "Couleurs"
        # unmanaged markers survive the write
        assert reloaded.settings["managed_by"] == "catalogue"
      end

      test "merges — never drops a sibling language, even from a stale caller struct" do
        set = create_set!()

        assert {:ok, _} = Sets.put_translation(set, "de-DE", %{"label" => "Farben"}, [])
        # Second call reuses the ORIGINAL (now-stale) `set` struct, not a
        # reload — proving the write goes through a fresh FOR-UPDATE read
        # rather than the caller's in-memory snapshot.
        assert {:ok, _} = Sets.put_translation(set, "fr-FR", %{"label" => "Couleurs"}, [])

        reloaded = PhoenixKitEntities.get_entity(set.uuid)
        assert reloaded.settings["translations"]["de-DE"]["display_name"] == "Farben"
        assert reloaded.settings["translations"]["fr-FR"]["display_name"] == "Couleurs"
      end

      test "no-ops when fields carries no \"label\" key" do
        set = create_set!()
        assert {:ok, unchanged} = Sets.put_translation(set, "fr-FR", %{}, [])
        assert unchanged.uuid == set.uuid
        refute PhoenixKitEntities.get_entity(set.uuid).settings["translations"]
      end

      test "re-reads the row under an actual FOR UPDATE lock, not a plain SELECT" do
        set = create_set!()

        assert query_texts(fn -> Sets.put_translation(set, "fr-FR", %{"label" => "X"}, []) end)
               |> Enum.any?(&(&1 =~ ~r/FOR UPDATE/i))
      end

      test "strips a leaked AI note from the translated label" do
        set = create_set!()
        noisy = "Couleurs\n\n(Note: the description field was skipped.)"
        assert {:ok, _} = Sets.put_translation(set, "fr-FR", %{"label" => noisy}, [])

        reloaded = PhoenixKitEntities.get_entity(set.uuid)
        assert reloaded.settings["translations"]["fr-FR"]["display_name"] == "Couleurs"
      end
    end

    describe "put_translation/4 — value title" do
      test "writes data[lang][\"_title\"]" do
        set = create_set!()
        value = create_value!(set, "Oak")
        assert {:ok, _} = Sets.put_translation(value, "fr-FR", %{"title" => "Chêne"}, [])

        reloaded = EntityData.get(value.uuid)
        assert reloaded.data["fr-FR"]["_title"] == "Chêne"
        assert EntityData.get_title_translation(reloaded, "fr-FR") == "Chêne"
      end

      test "primary language write also syncs the title column" do
        set = create_set!()
        value = create_value!(set, "Oak")
        assert {:ok, _} = Sets.put_translation(value, "en-US", %{"title" => "Oak (renamed)"}, [])

        reloaded = EntityData.get(value.uuid)
        assert reloaded.title == "Oak (renamed)"
      end

      test "merges — never drops a sibling language, even from a stale caller struct" do
        set = create_set!()
        value = create_value!(set, "Oak")

        assert {:ok, _} = Sets.put_translation(value, "de-DE", %{"title" => "Eiche"}, [])
        # Same stale-struct proof as the set-label test above.
        assert {:ok, _} = Sets.put_translation(value, "fr-FR", %{"title" => "Chêne"}, [])

        reloaded = EntityData.get(value.uuid)
        assert reloaded.data["de-DE"]["_title"] == "Eiche"
        assert reloaded.data["fr-FR"]["_title"] == "Chêne"

        # The storefront's own lookup (data[lang]["_title"] → primary →
        # title column) resolves each language to its own translation.
        assert EntityData.get_title_translation(reloaded, "de-DE") == "Eiche"
        assert EntityData.get_title_translation(reloaded, "fr-FR") == "Chêne"
        assert EntityData.get_title_translation(reloaded, "en-US") == "Oak"
      end

      test "re-reads the row under an actual FOR UPDATE lock, not a plain SELECT" do
        set = create_set!()
        value = create_value!(set, "Oak")

        assert query_texts(fn ->
                 Sets.put_translation(value, "fr-FR", %{"title" => "Chêne"}, [])
               end)
               |> Enum.any?(&(&1 =~ ~r/FOR UPDATE/i))
      end

      test "strips a leaked AI note from the translated title" do
        set = create_set!()
        value = create_value!(set, "Oak")
        noisy = "Chêne\n\n(Note: the description field was skipped.)"
        assert {:ok, _} = Sets.put_translation(value, "fr-FR", %{"title" => noisy}, [])

        reloaded = EntityData.get(value.uuid)
        assert reloaded.data["fr-FR"]["_title"] == "Chêne"
      end

      test "no-ops when fields carries no \"title\" key" do
        set = create_set!()
        value = create_value!(set, "Oak")
        assert {:ok, unchanged} = Sets.put_translation(value, "fr-FR", %{}, [])
        assert unchanged.uuid == value.uuid
        refute EntityData.get(value.uuid).data["fr-FR"]
      end
    end

    describe "put_translation/4 — per-field write narrowing (design source §4.4/§12.2)" do
      test "set label: a fresh translation is left untouched by a re-translate whose source didn't change" do
        set = create_set!()
        {:ok, _} = Sets.put_translation(set, "fr-FR", %{"label" => "Couleurs"}, [])
        translated = PhoenixKitEntities.get_entity(set.uuid)
        assert TranslationStatus.state(translated, "fr-FR") == :fresh

        # Hand-edit the translation directly (not through put_translation/4) —
        # simulates an operator correction. The next AI re-translate (source
        # unchanged) must not clobber it.
        {:ok, hand_edited} =
          PhoenixKitEntities.set_entity_translation(translated, "fr-FR", %{
            "display_name" => "Couleurs (corrigé)"
          })

        assert {:ok, unchanged} =
                 Sets.put_translation(hand_edited, "fr-FR", %{"label" => "Couleurs AI"}, [])

        assert unchanged.uuid == hand_edited.uuid
        reloaded = PhoenixKitEntities.get_entity(set.uuid)
        assert reloaded.settings["translations"]["fr-FR"]["display_name"] == "Couleurs (corrigé)"
      end

      test "set label: a re-translate DOES write when the source changed since the last translation" do
        set = create_set!("Ikea colors")
        {:ok, _} = Sets.put_translation(set, "fr-FR", %{"label" => "Couleurs"}, [])
        translated = PhoenixKitEntities.get_entity(set.uuid)

        {:ok, renamed} = PhoenixKitEntities.update_entity(translated, %{display_name: "Colours"})
        assert TranslationStatus.state(renamed, "fr-FR") == :stale

        assert {:ok, _} = Sets.put_translation(renamed, "fr-FR", %{"label" => "Couleurs 2"}, [])
        reloaded = PhoenixKitEntities.get_entity(set.uuid)
        assert reloaded.settings["translations"]["fr-FR"]["display_name"] == "Couleurs 2"
      end

      test "value title: a fresh translation is left untouched by a re-translate whose source didn't change" do
        set = create_set!()
        value = create_value!(set, "Oak")
        {:ok, _} = Sets.put_translation(value, "fr-FR", %{"title" => "Chêne"}, [])
        translated = EntityData.get(value.uuid)
        assert TranslationStatus.state(translated, "fr-FR") == :fresh

        {:ok, hand_edited} =
          PhoenixKitEntities.EntityData.set_title_translation(translated, "fr-FR", "Chêne (fix)")

        assert {:ok, unchanged} =
                 Sets.put_translation(hand_edited, "fr-FR", %{"title" => "Chêne AI"}, [])

        assert unchanged.uuid == hand_edited.uuid
        reloaded = EntityData.get(value.uuid)
        assert reloaded.data["fr-FR"]["_title"] == "Chêne (fix)"
      end
    end

    describe "put_translation/4 — broadcast (after the FOR UPDATE transaction commits)" do
      test "set label: broadcasts entity_updated exactly once on a successful write" do
        set = create_set!()
        :ok = PhoenixKitEntities.Events.subscribe_to_entities()

        assert {:ok, _} = Sets.put_translation(set, "fr-FR", %{"label" => "Couleurs"}, [])

        assert_receive {:entity_updated, uuid}, 500
        assert uuid == set.uuid
        refute_receive {:entity_updated, _}, 50
      end

      test "set label: no broadcast when the locked transaction rolls back" do
        set = create_set!()
        :ok = PhoenixKitEntities.Events.subscribe_to_entities()
        {:ok, _} = AttributeSets.delete_set(set)

        assert {:error, :resource_not_found} =
                 Sets.put_translation(set, "fr-FR", %{"label" => "Couleurs"}, [])

        refute_receive {:entity_updated, _}, 100
      end

      test "value title: broadcasts data_updated exactly once on a successful write" do
        set = create_set!()
        value = create_value!(set, "Oak")
        :ok = PhoenixKitEntities.Events.subscribe_to_all_data()

        assert {:ok, _} = Sets.put_translation(value, "fr-FR", %{"title" => "Chêne"}, [])

        assert_receive {:data_updated, entity_uuid, data_uuid}, 500
        assert entity_uuid == set.uuid
        assert data_uuid == value.uuid
        refute_receive {:data_updated, _, _}, 50
      end

      test "value title: no broadcast when the locked transaction rolls back" do
        set = create_set!()
        value = create_value!(set, "Oak")
        :ok = PhoenixKitEntities.Events.subscribe_to_all_data()
        {:ok, _} = AttributeSets.delete_value(set, value)

        assert {:error, :resource_not_found} =
                 Sets.put_translation(value, "fr-FR", %{"title" => "Chêne"}, [])

        refute_receive {:data_updated, _, _}, 100
      end
    end
  end

  describe "registration" do
    test "PhoenixKitCatalogue.ai_translatables/0 includes both set resource types" do
      registered = PhoenixKitCatalogue.ai_translatables()

      assert {"catalogue_set_label", Sets} in registered
      assert {"catalogue_set_value", Sets} in registered
    end
  end
end
