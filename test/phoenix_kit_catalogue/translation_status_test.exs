defmodule PhoenixKitCatalogue.TranslationStatusTest do
  @moduledoc """
  Unit coverage for the catalogue translation-freshness model: fingerprint
  hashing, process-dictionary capture at read time, state transitions, and
  `list/2` filtering/pagination. Item/category cases need no live
  `PhoenixKitAI`; the sets cases (entities-backed) are skipped when the
  entities package lacks the Managed contract, same guard as
  `AITranslatableSetsTest`.
  """

  use PhoenixKitCatalogue.DataCase, async: false

  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitCatalogue.AITranslatable
  alias PhoenixKitCatalogue.AITranslatable.Sets
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitCatalogue.TranslationStatus

  defp primary, do: Multilang.primary_language()

  defp create_catalogue_with_item(attrs) do
    {:ok, cat} = Catalogue.create_catalogue(%{name: "Cat"})

    {:ok, item} =
      Catalogue.create_item(Map.merge(%{name: "Widget", catalogue_uuid: cat.uuid}, attrs))

    {cat, item}
  end

  defp create_item(attrs \\ %{}) do
    {_cat, item} = create_catalogue_with_item(attrs)
    item
  end

  defp create_category(attrs \\ %{}) do
    {:ok, cat} = Catalogue.create_catalogue(%{name: "Cat"})

    {:ok, category} =
      Catalogue.create_category(Map.merge(%{name: "Cards", catalogue_uuid: cat.uuid}, attrs))

    category
  end

  describe "fingerprint/1" do
    test "is independent of field order" do
      a = TranslationStatus.fingerprint(%{"name" => "Widget", "description" => "A thing"})
      b = TranslationStatus.fingerprint(%{"description" => "A thing", "name" => "Widget"})
      assert a == b
    end

    test "trims surrounding whitespace" do
      a = TranslationStatus.fingerprint(%{"name" => "Widget"})
      b = TranslationStatus.fingerprint(%{"name" => "  Widget  "})
      assert a == b
    end

    test "differs when a value differs" do
      a = TranslationStatus.fingerprint(%{"name" => "Widget"})
      b = TranslationStatus.fingerprint(%{"name" => "Gadget"})
      refute a == b
    end
  end

  describe "capture_fingerprint/3 + captured_fingerprint/2" do
    test "round-trips within the same process" do
      uuid = Ecto.UUID.generate()
      :ok = TranslationStatus.capture_fingerprint("catalogue_item", uuid, %{"name" => "Widget"})

      assert TranslationStatus.captured_fingerprint("catalogue_item", uuid) ==
               TranslationStatus.field_fingerprints(%{"name" => "Widget"})
    end

    test "nothing captured → nil" do
      assert TranslationStatus.captured_fingerprint("catalogue_item", Ecto.UUID.generate()) == nil
    end
  end

  describe "state/2 — item" do
    test "no translation → :missing" do
      item = create_item()
      assert TranslationStatus.state(item, "fr") == :missing
    end

    test "translation written outside put_translation/4 → :unknown" do
      item = create_item()

      new_data = AITranslatable.force_put_language(item.data, "fr", %{"_name" => "Widget FR"})
      {:ok, item} = Catalogue.update_item(item, %{data: new_data})

      assert TranslationStatus.state(item, "fr") == :unknown
    end

    test "after put_translation/4 → :fresh" do
      item = create_item()
      {:ok, _} = AITranslatable.put_translation(item, "fr", %{"name" => "Widget FR"}, [])

      reloaded = Catalogue.get_item(item.uuid)
      assert TranslationStatus.state(reloaded, "fr") == :fresh
    end

    test "source changes after a fresh translation → :stale" do
      item = create_item()
      {:ok, _} = AITranslatable.put_translation(item, "fr", %{"name" => "Widget FR"}, [])
      translated = Catalogue.get_item(item.uuid)

      {:ok, _} = Catalogue.update_item(translated, %{name: "Widget Mk2"})
      reloaded = Catalogue.get_item(item.uuid)

      assert TranslationStatus.state(reloaded, "fr") == :stale
    end

    test "stamp_fresh/2 flips :stale (or :unknown) back to :fresh" do
      item = create_item()

      new_data = AITranslatable.force_put_language(item.data, "fr", %{"_name" => "Widget FR"})
      {:ok, item} = Catalogue.update_item(item, %{data: new_data})
      assert TranslationStatus.state(item, "fr") == :unknown

      assert {:ok, _} = TranslationStatus.stamp_fresh(item, "fr")
      reloaded = Catalogue.get_item(item.uuid)
      assert TranslationStatus.state(reloaded, "fr") == :fresh
    end

    test "stamp_fresh/2 refuses when there is nothing translated" do
      item = create_item()
      assert {:error, :no_translation} = TranslationStatus.stamp_fresh(item, "fr")
    end
  end

  describe "field_state/3" do
    test "folds independently per field — one field fresh, its sourced sibling still missing" do
      item = create_item(%{description: "A thing"})
      {:ok, _} = AITranslatable.put_translation(item, "fr", %{"name" => "Widget FR"}, [])
      reloaded = Catalogue.get_item(item.uuid)

      assert TranslationStatus.field_state(reloaded, "fr", "name") == :fresh
      assert TranslationStatus.field_state(reloaded, "fr", "description") == :missing
      # state/2 folds worst-wins across fields: missing beats fresh.
      assert TranslationStatus.state(reloaded, "fr") == :missing
    end

    test "a field with no current source is excluded — nil, not :missing" do
      item = create_item()
      assert TranslationStatus.field_state(item, "fr", "description") == nil
    end

    test "a changed field is :stale while an untouched sibling field stays :fresh" do
      item = create_item(%{description: "A thing"})
      {:ok, _} = AITranslatable.put_translation(item, "fr", %{"name" => "Widget FR"}, [])
      translated = Catalogue.get_item(item.uuid)

      {:ok, _} =
        AITranslatable.put_translation(translated, "fr", %{"description" => "Une chose"}, [])

      with_both = Catalogue.get_item(item.uuid)
      {:ok, _} = Catalogue.update_item(with_both, %{name: "Widget Mk2"})
      reloaded = Catalogue.get_item(item.uuid)

      assert TranslationStatus.field_state(reloaded, "fr", "name") == :stale
      assert TranslationStatus.field_state(reloaded, "fr", "description") == :fresh
    end
  end

  describe "stamp_fresh/3 (field-narrowed)" do
    test "stamps only the requested field, leaving an untranslated sibling alone" do
      item = create_item(%{description: "A thing"})

      new_data =
        AITranslatable.force_put_language(item.data, "fr", %{
          "_name" => "Widget FR",
          "_description" => "Une chose"
        })

      {:ok, item} = Catalogue.update_item(item, %{data: new_data})
      assert TranslationStatus.field_state(item, "fr", "name") == :unknown
      assert TranslationStatus.field_state(item, "fr", "description") == :unknown

      assert {:ok, _} = TranslationStatus.stamp_fresh(item, "fr", "name")
      reloaded = Catalogue.get_item(item.uuid)

      assert TranslationStatus.field_state(reloaded, "fr", "name") == :fresh
      assert TranslationStatus.field_state(reloaded, "fr", "description") == :unknown
    end

    test "accepts a list of fields" do
      item = create_item(%{description: "A thing"})

      new_data =
        AITranslatable.force_put_language(item.data, "fr", %{
          "_name" => "Widget FR",
          "_description" => "Une chose"
        })

      {:ok, item} = Catalogue.update_item(item, %{data: new_data})

      assert {:ok, _} = TranslationStatus.stamp_fresh(item, "fr", ["name", "description"])
      reloaded = Catalogue.get_item(item.uuid)

      assert TranslationStatus.field_state(reloaded, "fr", "name") == :fresh
      assert TranslationStatus.field_state(reloaded, "fr", "description") == :fresh
    end

    test "refuses only when NONE of the requested fields are translated" do
      item = create_item(%{description: "A thing"})
      assert {:error, :no_translation} = TranslationStatus.stamp_fresh(item, "fr", "description")
    end

    test "one qualifying field among several requested is enough to proceed" do
      item = create_item(%{description: "A thing"})
      new_data = AITranslatable.force_put_language(item.data, "fr", %{"_name" => "Widget FR"})
      {:ok, item} = Catalogue.update_item(item, %{data: new_data})

      assert {:ok, _} = TranslationStatus.stamp_fresh(item, "fr", ["name", "description"])
      reloaded = Catalogue.get_item(item.uuid)
      assert TranslationStatus.field_state(reloaded, "fr", "name") == :fresh
      # description was never translated — nothing to stamp for it, no crash.
      assert TranslationStatus.field_state(reloaded, "fr", "description") == :missing
    end
  end

  describe "reset_baseline/3" do
    test "deletes the stored fingerprint for the chosen field, dropping it to :unknown, without touching the translation" do
      item = create_item()
      {:ok, _} = AITranslatable.put_translation(item, "fr", %{"name" => "Widget FR"}, [])
      translated = Catalogue.get_item(item.uuid)
      assert TranslationStatus.field_state(translated, "fr", "name") == :fresh

      assert {:ok, _} = TranslationStatus.reset_baseline(translated, "fr", "name")
      reloaded = Catalogue.get_item(item.uuid)

      assert TranslationStatus.field_state(reloaded, "fr", "name") == :unknown
      assert reloaded.data["fr"]["_name"] == "Widget FR"
    end

    test "leaves fingerprints of OTHER fields intact" do
      item = create_item(%{description: "A thing"})
      {:ok, _} = AITranslatable.put_translation(item, "fr", %{"name" => "Widget FR"}, [])
      t1 = Catalogue.get_item(item.uuid)
      {:ok, _} = AITranslatable.put_translation(t1, "fr", %{"description" => "Une chose"}, [])
      t2 = Catalogue.get_item(item.uuid)

      assert {:ok, _} = TranslationStatus.reset_baseline(t2, "fr", "name")
      reloaded = Catalogue.get_item(item.uuid)

      assert TranslationStatus.field_state(reloaded, "fr", "name") == :unknown
      assert TranslationStatus.field_state(reloaded, "fr", "description") == :fresh
    end

    test "forces the next translate to rewrite that field (the whole point of a reset baseline)" do
      item = create_item()
      {:ok, _} = AITranslatable.put_translation(item, "fr", %{"name" => "Widget FR"}, [])
      translated = Catalogue.get_item(item.uuid)

      # A plain re-translate with an UNCHANGED source would normally be
      # narrowed away (skip — see the write-narrowing tests). Reset first.
      {:ok, reset} = TranslationStatus.reset_baseline(translated, "fr", "name")

      assert {:ok, updated} =
               AITranslatable.put_translation(reset, "fr", %{"name" => "Widget FR bis"}, [])

      assert updated.data["fr"]["_name"] == "Widget FR bis"
      assert TranslationStatus.field_state(updated, "fr", "name") == :fresh
    end

    test "a no-op on a field with nothing stored" do
      item = create_item()
      assert {:ok, unchanged} = TranslationStatus.reset_baseline(item, "fr", "name")
      assert unchanged.uuid == item.uuid
    end
  end

  describe "stamp_preimage/3" do
    test "stamps a fingerprint computed from the GIVEN value, not the current source" do
      item = create_item()
      {:ok, _} = AITranslatable.put_translation(item, "fr", %{"name" => "Widget FR"}, [])
      translated = Catalogue.get_item(item.uuid)

      # Current source is still "Widget" (unchanged) — a fingerprint
      # computed from the current source would read :fresh here. Since
      # stamp_preimage/3 hashes the value it's TOLD instead, it reads
      # :stale.
      assert {:ok, _} = TranslationStatus.stamp_preimage(translated, "fr", %{"name" => "Old"})
      reloaded = Catalogue.get_item(item.uuid)

      assert TranslationStatus.field_state(reloaded, "fr", "name") == :stale
    end

    test "touches only the listed fields, leaving other fields' fingerprints untouched" do
      item = create_item(%{description: "A thing"})

      {:ok, _} =
        AITranslatable.put_translation(
          item,
          "fr",
          %{"name" => "Widget FR", "description" => "Une chose"},
          []
        )

      translated = Catalogue.get_item(item.uuid)
      assert TranslationStatus.field_state(translated, "fr", "description") == :fresh

      assert {:ok, _} = TranslationStatus.stamp_preimage(translated, "fr", %{"name" => "Old"})
      reloaded = Catalogue.get_item(item.uuid)

      assert TranslationStatus.field_state(reloaded, "fr", "name") == :stale
      assert TranslationStatus.field_state(reloaded, "fr", "description") == :fresh
    end

    test "the pair reads :stale (not :unknown) once the sync's own write lands — the whole point" do
      item = create_item()
      {:ok, _} = AITranslatable.put_translation(item, "fr", %{"name" => "Widget FR"}, [])
      translated = Catalogue.get_item(item.uuid)

      # A sync about to overwrite the English name knows the value it's
      # replacing — stamp it as the reference BEFORE the write lands.
      assert {:ok, _} = TranslationStatus.stamp_preimage(translated, "fr", %{"name" => "Widget"})
      {:ok, _} = Catalogue.update_item(translated, %{name: "Widget Mk2"})
      reloaded = Catalogue.get_item(item.uuid)

      assert TranslationStatus.field_state(reloaded, "fr", "name") == :stale
    end

    test "refuses when the language has no translation at all, like stamp_fresh/2" do
      item = create_item()

      assert {:error, :no_translation} =
               TranslationStatus.stamp_preimage(item, "fr", %{"name" => "Old"})
    end

    test "works for categories too" do
      category = create_category()
      {:ok, _} = AITranslatable.put_translation(category, "fr", %{"name" => "Cartes FR"}, [])
      translated = Catalogue.get_category(category.uuid)

      assert {:ok, _} =
               TranslationStatus.stamp_preimage(translated, "fr", %{"name" => "Old Cards"})

      reloaded = Catalogue.get_category(category.uuid)
      assert TranslationStatus.field_state(reloaded, "fr", "name") == :stale
    end
  end

  describe "legacy single-hash fingerprint format (pre-per-field rollout)" do
    # Resources translated before this model shipped store a single hex
    # STRING at `data["_translation_fingerprints"][lang]` (the old
    # `fingerprint/1` whole-resource digest) instead of a per-field map.
    # Decision (see the module's moduledoc): treat it as ABSENT for every
    # field — :unknown, not :stale, and never a match. Rationale: reading
    # it as "every field hashed to this value" would make virtually every
    # field :stale (a combined multi-field hash never equals a lone
    # field's hash), and :stale feeds the sweep worker's automatic
    # candidate list — turning 38 live items + 13 live categories `:stale`
    # the moment this ships would silently enqueue an unauthorized
    # AI-translation storm on deploy (design source §13: a mass run only
    # happens by separate owner decision). :unknown is never auto-swept
    # and matches what the write path does for these rows regardless.
    test "a legacy row reads as :unknown per field, not :stale, even though the source hasn't changed" do
      item = create_item(%{name: "Widget"})

      legacy_data =
        item.data
        |> Kernel.||(%{})
        |> AITranslatable.force_put_language("fr", %{"_name" => "Widget FR"})
        |> Map.put("_translation_fingerprints", %{
          "fr" => TranslationStatus.fingerprint(%{"name" => "Widget"})
        })

      {:ok, legacy} = Catalogue.update_item(item, %{data: legacy_data})

      # Sanity: the legacy value really is what the OLD whole-resource
      # digest would have stored for this exact source.
      assert is_binary(legacy.data["_translation_fingerprints"]["fr"])

      assert TranslationStatus.field_state(legacy, "fr", "name") == :unknown
      assert TranslationStatus.state(legacy, "fr") == :unknown
    end

    test "a write over a legacy row replaces the string with a clean per-field map, stamping only the written field" do
      item = create_item(%{name: "Widget", description: "A thing"})

      legacy_data =
        item.data
        |> Kernel.||(%{})
        |> AITranslatable.force_put_language("fr", %{
          "_name" => "Widget FR",
          "_description" => "Une chose"
        })
        |> Map.put("_translation_fingerprints", %{"fr" => "deadbeef"})

      {:ok, legacy} = Catalogue.update_item(item, %{data: legacy_data})

      # Re-translating "name" only touches "name": the legacy string is
      # gone, replaced by a map holding just the field that was actually
      # written this round — "description"'s (nonexistent) legacy entry
      # doesn't reappear, and its state stays :unknown either way.
      assert {:ok, updated} =
               AITranslatable.put_translation(legacy, "fr", %{"name" => "Widget FR2"}, [])

      assert updated.data["_translation_fingerprints"]["fr"] == %{
               "name" => TranslationStatus.field_fingerprint("Widget")
             }

      assert TranslationStatus.field_state(updated, "fr", "name") == :fresh
      assert TranslationStatus.field_state(updated, "fr", "description") == :unknown
    end

    test "stamp_fresh/2 on a legacy row upgrades storage to a per-field map" do
      item = create_item(%{name: "Widget"})

      legacy_data =
        item.data
        |> Kernel.||(%{})
        |> AITranslatable.force_put_language("fr", %{"_name" => "Widget FR"})
        |> Map.put("_translation_fingerprints", %{"fr" => "deadbeef"})

      {:ok, legacy} = Catalogue.update_item(item, %{data: legacy_data})

      assert {:ok, updated} = TranslationStatus.stamp_fresh(legacy, "fr")

      assert updated.data["_translation_fingerprints"]["fr"] == %{
               "name" => TranslationStatus.field_fingerprint("Widget")
             }
    end
  end

  describe "degenerate cases — no AI module involvement, nothing translated at all" do
    # `TranslationStatus` never references `PhoenixKitAI` (grep the
    # module — only the doc text does) and computes everything from plain
    # Ecto structs + `PhoenixKit.Utils.Multilang`, so a resource with zero
    # translations behaves the same whether or not an AI provider is
    # configured, or even installed. These exercises don't touch
    # `PhoenixKitAI.Translations` (endpoint/prompt config) at all.
    test "a brand-new item with only a name: state/2, field_state/3, and list/2 all behave, no crash" do
      {cat, item} = create_catalogue_with_item(%{})

      assert TranslationStatus.state(item, "de-DE") == :missing
      assert TranslationStatus.field_state(item, "de-DE", "name") == :missing
      assert TranslationStatus.field_state(item, "de-DE", "description") == nil

      rows = TranslationStatus.list(:item, catalogue_uuid: cat.uuid, langs: ["de-DE"])
      assert Enum.find(rows, &(&1.uuid == item.uuid)).state == :missing
    end
  end

  describe "state/2 — category" do
    test "round-trips missing → fresh → stale" do
      category = create_category()
      assert TranslationStatus.state(category, "fr") == :missing

      {:ok, _} = AITranslatable.put_translation(category, "fr", %{"name" => "Cartes"}, [])
      translated = Catalogue.get_category(category.uuid)
      assert TranslationStatus.state(translated, "fr") == :fresh

      {:ok, _} = Catalogue.update_category(translated, %{name: "Cards Mk2"})
      reloaded = Catalogue.get_category(category.uuid)
      assert TranslationStatus.state(reloaded, "fr") == :stale
    end
  end

  describe "process-dictionary capture (write reflects the READ-time source)" do
    test "a source mutation between source_fields/2 and put_translation/4 doesn't affect the write" do
      item = create_item(%{name: "Widget"})

      # Simulate the TranslateWorker's read step.
      _ = AITranslatable.source_fields(item, primary())

      # A sync lands on the row while the (multi-second) AI call is
      # in flight — same race the design source describes (§4.1).
      {:ok, mutated} = Catalogue.update_item(item, %{name: "Mutated"})

      {:ok, _} = AITranslatable.put_translation(mutated, "fr", %{"name" => "Traduit"}, [])

      reloaded = Catalogue.get_item(item.uuid)
      stored_fp = reloaded.data["_translation_fingerprints"]["fr"]["name"]
      assert stored_fp == TranslationStatus.field_fingerprint("Widget")
      refute stored_fp == TranslationStatus.field_fingerprint("Mutated")
    end

    test "state/2, a read-only check, does not clobber a fingerprint an in-flight RETRANSLATION job already captured" do
      # `state/2` only reaches the fingerprint-computing branch once a
      # translation already exists for the pair (the :missing branch
      # short-circuits first) — so this reproduces the retranslate case:
      # a resource already translated once, whose source changes again.
      item = create_item(%{name: "Widget"})
      {:ok, _} = AITranslatable.put_translation(item, "fr", %{"name" => "Widget FR"}, [])

      {:ok, v2} = item.uuid |> Catalogue.get_item() |> Catalogue.update_item(%{name: "Widget V2"})

      # Job B's actual read step for the retranslation.
      _ = AITranslatable.source_fields(v2, primary())

      {:ok, v3} = Catalogue.update_item(v2, %{name: "Widget V3"})

      # Something else in the SAME process — e.g. the admin translations
      # page re-checking freshness against the now-latest source — calls
      # the read-only `state/2` in between. It must not go through the
      # capturing `source_fields/2` internally and overwrite what job B
      # already stashed for this uuid.
      assert TranslationStatus.state(v3, "fr") == :stale

      {:ok, _} = AITranslatable.put_translation(v3, "fr", %{"name" => "Widget V2 FR"}, [])

      reloaded = Catalogue.get_item(item.uuid)
      stored_fp = reloaded.data["_translation_fingerprints"]["fr"]["name"]
      assert stored_fp == TranslationStatus.field_fingerprint("Widget V2")
      refute stored_fp == TranslationStatus.field_fingerprint("Widget V3")
    end
  end

  if Code.ensure_loaded?(PhoenixKitEntities.Managed) do
    describe "state/2 — sets" do
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

      defp create_value!(set, label) do
        {:ok, value} =
          AttributeSets.create_value(set, %{label: label}, actor_uuid: Ecto.UUID.generate())

        value
      end

      test "set label: missing → fresh → stale" do
        set = create_set!("Ikea colors")
        assert TranslationStatus.state(set, "fr-FR") == :missing

        {:ok, _} = Sets.put_translation(set, "fr-FR", %{"label" => "Couleurs"}, [])
        translated = PhoenixKitEntities.get_entity(set.uuid)
        assert TranslationStatus.state(translated, "fr-FR") == :fresh

        {:ok, renamed} = PhoenixKitEntities.update_entity(translated, %{display_name: "Colours"})
        assert TranslationStatus.state(renamed, "fr-FR") == :stale
      end

      test "set label: stamp_fresh flips an unknown pair to fresh" do
        set = create_set!("Ikea colors")

        # Translated outside `put_translation/4` — no fingerprint
        # recorded, so the pair is `:unknown`, not `:missing`/`:stale`.
        {:ok, translated} =
          PhoenixKitEntities.set_entity_translation(set, "fr-FR", %{"display_name" => "Couleurs"})

        assert TranslationStatus.state(translated, "fr-FR") == :unknown

        assert {:ok, _} = TranslationStatus.stamp_fresh(translated, "fr-FR")
        reloaded = PhoenixKitEntities.get_entity(set.uuid)
        assert TranslationStatus.state(reloaded, "fr-FR") == :fresh
      end

      test "value title: missing → fresh → stale, and stamp_fresh flips it back" do
        set = create_set!()
        value = create_value!(set, "Oak")
        assert TranslationStatus.state(value, "fr-FR") == :missing

        {:ok, _} = Sets.put_translation(value, "fr-FR", %{"title" => "Chêne"}, [])
        translated = PhoenixKitEntities.EntityData.get(value.uuid)
        assert TranslationStatus.state(translated, "fr-FR") == :fresh

        {:ok, renamed} = PhoenixKitEntities.EntityData.update(translated, %{title: "Oak Mk2"})
        assert TranslationStatus.state(renamed, "fr-FR") == :stale

        assert {:ok, _} = TranslationStatus.stamp_fresh(renamed, "fr-FR")
        reloaded = PhoenixKitEntities.EntityData.get(value.uuid)
        assert TranslationStatus.state(reloaded, "fr-FR") == :fresh
      end
    end

    describe "list/2 — sets" do
      setup do
        AttributeSets.register_deletion_guard()
        PhoenixKit.Settings.update_setting("entities_enabled", "true")
        on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)
        :ok
      end

      test "lists set-label rows across every set" do
        set_a = create_set!("Ikea colors")
        set_b = create_set!("Ikea sizes")

        rows = TranslationStatus.list(:set_label, langs: ["fr-FR"])
        uuids = Enum.map(rows, & &1.uuid)

        assert set_a.uuid in uuids
        assert set_b.uuid in uuids
      end

      test "lists set-value rows for every set's values, not just the first (batched query)" do
        set_a = create_set!("Ikea colors")
        set_b = create_set!("Ikea sizes")
        value_a = create_value!(set_a, "Oak")
        value_b = create_value!(set_b, "Large")

        rows = TranslationStatus.list(:set_value, langs: ["fr-FR"])
        uuids = Enum.map(rows, & &1.uuid)

        assert value_a.uuid in uuids
        assert value_b.uuid in uuids
      end
    end
  end

  describe "list/2 — item" do
    test "filters by state and paginates" do
      {cat, translated} = create_catalogue_with_item(%{name: "Alpha"})
      {:ok, missing} = Catalogue.create_item(%{name: "Beta", catalogue_uuid: cat.uuid})
      {:ok, _other_missing} = Catalogue.create_item(%{name: "Gamma", catalogue_uuid: cat.uuid})

      {:ok, _} = AITranslatable.put_translation(translated, "fr", %{"name" => "Alpha FR"}, [])

      all =
        TranslationStatus.list(:item, catalogue_uuid: cat.uuid, langs: ["fr"], per_page: 50)

      assert length(all) == 3
      assert Enum.find(all, &(&1.uuid == translated.uuid)).state == :fresh
      assert Enum.find(all, &(&1.uuid == missing.uuid)).state == :missing

      missing_only =
        TranslationStatus.list(:item,
          catalogue_uuid: cat.uuid,
          langs: ["fr"],
          state: :missing,
          per_page: 50
        )

      assert length(missing_only) == 2
      assert Enum.all?(missing_only, &(&1.state == :missing))

      page1 =
        TranslationStatus.list(:item,
          catalogue_uuid: cat.uuid,
          langs: ["fr"],
          per_page: 1,
          page: 1
        )

      page2 =
        TranslationStatus.list(:item,
          catalogue_uuid: cat.uuid,
          langs: ["fr"],
          per_page: 1,
          page: 2
        )

      assert length(page1) == 1
      assert length(page2) == 1
      refute hd(page1).uuid == hd(page2).uuid
    end
  end
end
