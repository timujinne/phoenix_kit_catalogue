defmodule PhoenixKitCatalogue.AITranslatableTest do
  @moduledoc """
  Unit coverage for the catalogue `Translatable` adapter — the storage half
  of the AI-translation pipeline. No live `PhoenixKitAI` needed; these test
  fetch / source-field extraction / persist directly against the DB.
  """

  use PhoenixKitCatalogue.DataCase, async: true

  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitCatalogue.AITranslatable
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.PubSub
  alias PhoenixKitCatalogue.Schemas.Item
  alias PhoenixKitCatalogue.TranslationStatus

  defp primary, do: Multilang.primary_language()

  defp create_item(attrs \\ %{}) do
    {:ok, cat} = Catalogue.create_catalogue(%{name: "Cat"})

    {:ok, item} =
      Catalogue.create_item(Map.merge(%{name: "Widget", catalogue_uuid: cat.uuid}, attrs))

    item
  end

  defp create_category(attrs \\ %{}) do
    {:ok, cat} = Catalogue.create_catalogue(%{name: "Cat"})

    {:ok, category} =
      Catalogue.create_category(Map.merge(%{name: "Cards", catalogue_uuid: cat.uuid}, attrs))

    category
  end

  describe "fetch/2" do
    test "loads a known item by type + uuid" do
      item = create_item()
      assert {:ok, fetched} = AITranslatable.fetch("catalogue_item", item.uuid)
      assert fetched.uuid == item.uuid
    end

    test "loads a known catalogue by type + uuid" do
      {:ok, cat} = Catalogue.create_catalogue(%{name: "Cat"})
      assert {:ok, fetched} = AITranslatable.fetch("catalogue", cat.uuid)
      assert fetched.uuid == cat.uuid
    end

    test "loads a known category by type + uuid" do
      category = create_category()
      assert {:ok, fetched} = AITranslatable.fetch("catalogue_category", category.uuid)
      assert fetched.uuid == category.uuid
    end

    test "missing row → :resource_not_found" do
      assert {:error, :resource_not_found} =
               AITranslatable.fetch("catalogue_item", "00000000-0000-0000-0000-000000000000")
    end

    test "unknown resource type → :unknown_resource_type" do
      assert {:error, {:unknown_resource_type, "bogus"}} = AITranslatable.fetch("bogus", "x")
    end
  end

  describe "source_fields/2" do
    test "falls back to the column when the lang subtree has no override" do
      item = create_item(%{name: "Widget"})
      fields = AITranslatable.source_fields(item, primary())
      assert fields["name"] == "Widget"
    end

    test "blank source fields are omitted" do
      item = create_item(%{name: "Widget"})
      # description not set → not in the source map
      refute Map.has_key?(AITranslatable.source_fields(item, primary()), "description")
    end

    test "prefers the multilang `_`-prefixed override over the column" do
      item = %Item{
        name: "Column",
        data: %{"_primary_language" => primary(), "fr" => %{"_name" => "Renard"}}
      }

      assert AITranslatable.source_fields(item, "fr")["name"] == "Renard"
    end

    test "falls back to a legacy plain key when there's no `_`-prefixed override" do
      item = %Item{
        name: "Column",
        data: %{"_primary_language" => primary(), "fr" => %{"name" => "Plain"}}
      }

      assert AITranslatable.source_fields(item, "fr")["name"] == "Plain"
    end

    test "includes seo_title when set in the primary language" do
      item = %Item{
        name: "Column",
        data: %{
          "_primary_language" => primary(),
          primary() => %{"_seo_title" => "Buy Vase", "_seo_description" => "A nice vase"}
        }
      }

      fields = AITranslatable.source_fields(item, primary())
      assert fields["seo_title"] == "Buy Vase"
      assert fields["seo_description"] == "A nice vase"
    end

    test "omits summary when it is blank" do
      item = %Item{
        name: "Column",
        data: %{"_primary_language" => primary(), primary() => %{"_summary" => ""}}
      }

      refute Map.has_key?(AITranslatable.source_fields(item, primary()), "summary")
    end

    test "includes summary when set" do
      item = %Item{
        name: "Column",
        data: %{"_primary_language" => primary(), primary() => %{"_summary" => "Short blurb"}}
      }

      assert AITranslatable.source_fields(item, primary())["summary"] == "Short blurb"
    end

    test "category also exposes summary/seo_title/seo_description" do
      category = %PhoenixKitCatalogue.Schemas.Category{
        name: "Cards",
        data: %{"_primary_language" => primary(), primary() => %{"_seo_title" => "Shop cards"}}
      }

      assert AITranslatable.source_fields(category, primary())["seo_title"] == "Shop cards"
    end
  end

  describe "put_translation/4" do
    test "writes the translation under the multilang `_`-prefixed key" do
      item = create_item()
      assert {:ok, _} = AITranslatable.put_translation(item, "es", %{"name" => "Artilugio"}, [])

      reloaded = Catalogue.get_item(item.uuid)
      assert reloaded.data["es"]["_name"] == "Artilugio"
    end

    test "merges into an existing lang subtree (keeps sibling fields)" do
      # `description` needs actual source text — a field with no current
      # source is excluded from the per-field write narrowing (design
      # source §4.1) and its translation, if any, is left untouched.
      item = create_item(%{description: "A thing"})
      {:ok, _} = AITranslatable.put_translation(item, "es", %{"name" => "Artilugio"}, [])
      item2 = Catalogue.get_item(item.uuid)
      {:ok, _} = AITranslatable.put_translation(item2, "es", %{"description" => "Una cosa"}, [])

      reloaded = Catalogue.get_item(item.uuid)
      assert reloaded.data["es"]["_name"] == "Artilugio"
      assert reloaded.data["es"]["_description"] == "Una cosa"
    end

    test "stores seo_title alongside name under the multilang `_`-prefixed keys" do
      # seo_title has no schema column — it only has current source when
      # the primary language's override is set, same as `describe
      # "source_fields/2"`'s "includes seo_title when set" case above.
      item =
        create_item(%{
          data: %{"_primary_language" => primary(), primary() => %{"_seo_title" => "Buy Vase"}}
        })

      assert {:ok, _} =
               AITranslatable.put_translation(
                 item,
                 "fr-FR",
                 %{"name" => "Vase", "seo_title" => "Acheter"},
                 []
               )

      reloaded = Catalogue.get_item(item.uuid)
      assert reloaded.data["fr-FR"]["_name"] == "Vase"
      assert reloaded.data["fr-FR"]["_seo_title"] == "Acheter"
    end

    test "force-stores a value even when it equals the source (no blank-drop)" do
      item = create_item(%{name: "ABC123"})
      {:ok, _} = AITranslatable.put_translation(item, "es", %{"name" => "ABC123"}, [])

      reloaded = Catalogue.get_item(item.uuid)
      assert reloaded.data["es"]["_name"] == "ABC123"
    end

    test "round-trips a catalogue (fetch → translate → reload)" do
      {:ok, cat} = Catalogue.create_catalogue(%{name: "Cat"})
      {:ok, fetched} = AITranslatable.fetch("catalogue", cat.uuid)
      assert {:ok, _} = AITranslatable.put_translation(fetched, "es", %{"name" => "Gato"}, [])

      reloaded = Catalogue.get_catalogue(cat.uuid)
      assert reloaded.data["es"]["_name"] == "Gato"
    end

    test "round-trips a category (fetch → translate → reload)" do
      category = create_category()
      {:ok, fetched} = AITranslatable.fetch("catalogue_category", category.uuid)
      assert {:ok, _} = AITranslatable.put_translation(fetched, "es", %{"name" => "Tarjetas"}, [])

      reloaded = Catalogue.get_category(category.uuid)
      assert reloaded.data["es"]["_name"] == "Tarjetas"
    end

    test "preserves foreign top-level `data` keys on a category's first translation" do
      foreign_data = %{
        "_primary_language" => "en-US",
        "ecommerce" => %{"shopify" => %{"collection_id" => "gid://1"}},
        "meta" => %{"k" => "v"}
      }

      category = create_category(%{data: foreign_data})

      assert {:ok, updated} =
               AITranslatable.put_translation(category, "fr-FR", %{"name" => "Cartes"}, [])

      assert updated.data["ecommerce"] == foreign_data["ecommerce"]
      assert updated.data["meta"] == foreign_data["meta"]
      assert updated.data["fr-FR"]["_name"] == "Cartes"

      assert updated.data["_translation_fingerprints"]["fr-FR"] == %{
               "name" => TranslationStatus.field_fingerprint("Cards")
             }

      reloaded = Catalogue.get_category(category.uuid)
      assert reloaded.data["ecommerce"] == foreign_data["ecommerce"]
      assert reloaded.data["meta"] == foreign_data["meta"]
    end

    test "preserves foreign top-level `data` keys on an item's first translation" do
      foreign_data = %{
        "_primary_language" => "en-US",
        "ecommerce" => %{"shopify" => %{"collection_id" => "gid://1"}},
        "meta" => %{"k" => "v"}
      }

      item = create_item(%{data: foreign_data})

      assert {:ok, updated} =
               AITranslatable.put_translation(item, "fr-FR", %{"name" => "Objet"}, [])

      assert updated.data["ecommerce"] == foreign_data["ecommerce"]
      assert updated.data["meta"] == foreign_data["meta"]
      assert updated.data["fr-FR"]["_name"] == "Objet"

      reloaded = Catalogue.get_item(item.uuid)
      assert reloaded.data["ecommerce"] == foreign_data["ecommerce"]
      assert reloaded.data["meta"] == foreign_data["meta"]
    end

    test "preserves foreign top-level `data` keys even without a pre-existing `_primary_language` marker" do
      foreign_data = %{"ecommerce" => %{"x" => 1}, "meta" => %{"k" => "v"}}
      category = create_category(%{data: foreign_data})

      assert {:ok, updated} =
               AITranslatable.put_translation(category, "fr-FR", %{"name" => "Cartes"}, [])

      assert updated.data["ecommerce"] == %{"x" => 1}
      assert updated.data["meta"] == %{"k" => "v"}
      assert updated.data["fr-FR"]["_name"] == "Cartes"
    end

    test "strips a leaked AI note from a translated name so it never reaches the field or the slug" do
      item = create_item(%{name: "Widget"})

      noisy_name =
        "Vase en Bois\n\n(Note: I've omitted the fields with placeholder values " <>
          "({{description}}, {{summary}}) as per the rules.)"

      assert {:ok, updated} =
               AITranslatable.put_translation(item, "fr-FR", %{"name" => noisy_name}, [])

      assert updated.data["fr-FR"]["_name"] == "Vase en Bois"
      refute updated.data["fr-FR"]["_name"] =~ "Note"
      assert updated.slug["fr-FR"] == "vase-en-bois"
      refute updated.slug["fr-FR"] =~ "note"
    end
  end

  describe "put_translation/4 write-once slugs" do
    test "generates a slug for the target language from the translated name when it has none" do
      item = create_item(%{name: "Widget"})

      assert {:ok, _} =
               AITranslatable.put_translation(item, "fr-FR", %{"name" => "Vase en Bois"}, [])

      reloaded = Catalogue.get_item(item.uuid)
      assert reloaded.slug["fr-FR"] == "vase-en-bois"
    end

    test "leaves an existing slug for the target language untouched" do
      item = create_item(%{name: "Widget", slug: %{"fr-FR" => "custom-slug"}})

      assert {:ok, _} =
               AITranslatable.put_translation(item, "fr-FR", %{"name" => "Vase en Bois"}, [])

      reloaded = Catalogue.get_item(item.uuid)
      assert reloaded.slug["fr-FR"] == "custom-slug"
    end

    test "does not generate a slug when the translation carries no name" do
      item = create_item(%{name: "Widget"})

      assert {:ok, _} =
               AITranslatable.put_translation(item, "fr-FR", %{"seo_title" => "Acheter"}, [])

      reloaded = Catalogue.get_item(item.uuid)
      refute Map.has_key?(reloaded.slug, "fr-FR")
    end

    test "retries with a numeric suffix on a collision with another item's slug" do
      _taken = create_item(%{name: "Taken", slug: %{"fr-FR" => "vase"}})
      item = create_item(%{name: "Widget"})

      assert {:ok, _} = AITranslatable.put_translation(item, "fr-FR", %{"name" => "Vase"}, [])

      reloaded = Catalogue.get_item(item.uuid)
      assert reloaded.slug["fr-FR"] == "vase-2"
    end

    test "generates a slug for a category the same way" do
      category = create_category(%{name: "Cards"})

      assert {:ok, _} =
               AITranslatable.put_translation(category, "fr-FR", %{"name" => "Cartes"}, [])

      reloaded = Catalogue.get_category(category.uuid)
      assert reloaded.slug["fr-FR"] == "cartes"
    end
  end

  describe "put_translation/4 — per-field write narrowing (design source §4.4/§12.2)" do
    test "a changed field is rewritten while an untouched sibling's hand-edit survives, in the SAME run" do
      item = create_item(%{name: "Widget", description: "A thing"})

      {:ok, _} =
        AITranslatable.put_translation(
          item,
          "fr-FR",
          %{"name" => "Widget FR", "description" => "Une chose"},
          []
        )

      translated = Catalogue.get_item(item.uuid)

      # Operator hand-corrects the description translation directly (not
      # through put_translation/4) — no fingerprint stamp accompanies it,
      # same as a save from the multilang form.
      hand_edited_data =
        AITranslatable.force_put_language(translated.data, "fr-FR", %{
          "_description" => "Correction manuelle"
        })

      {:ok, hand_edited} = Catalogue.update_item(translated, %{data: hand_edited_data})

      # The ENGLISH name changes — description's source does not.
      {:ok, changed} = Catalogue.update_item(hand_edited, %{name: "Widget Mk2"})

      assert {:ok, updated} =
               AITranslatable.put_translation(
                 changed,
                 "fr-FR",
                 %{"name" => "Widget Mk2 FR", "description" => "AI would overwrite this"},
                 []
               )

      # name: source changed -> rewritten.
      assert updated.data["fr-FR"]["_name"] == "Widget Mk2 FR"
      # description: source unchanged since the last translation -> the
      # hand edit is untouched, even though this SAME call also carried a
      # (different) AI answer for it.
      assert updated.data["fr-FR"]["_description"] == "Correction manuelle"
    end

    test "when every field is narrowed away, this is a success without a write: no broadcast, no version bump" do
      item = create_item(%{name: "Widget"})
      {:ok, _} = AITranslatable.put_translation(item, "fr-FR", %{"name" => "Widget FR"}, [])
      translated = Catalogue.get_item(item.uuid)

      :ok = PubSub.subscribe()

      assert {:ok, unchanged} =
               AITranslatable.put_translation(
                 translated,
                 "fr-FR",
                 %{"name" => "Widget FR bis"},
                 []
               )

      # Original (untouched) translation text, not the new AI answer.
      assert unchanged.data["fr-FR"]["_name"] == "Widget FR"
      assert unchanged.updated_at == translated.updated_at
      refute_receive {:catalogue_data_changed, :item, _uuid, _parent}, 100
    end

    test "category: the same per-field narrowing rule applies" do
      category = create_category(%{name: "Cards", description: "Playing cards"})

      {:ok, _} =
        AITranslatable.put_translation(
          category,
          "fr-FR",
          %{"name" => "Cartes", "description" => "Cartes a jouer"},
          []
        )

      translated = Catalogue.get_category(category.uuid)
      {:ok, changed} = Catalogue.update_category(translated, %{name: "Cards Mk2"})

      assert {:ok, updated} =
               AITranslatable.put_translation(
                 changed,
                 "fr-FR",
                 %{"name" => "Cartes 2", "description" => "AI would overwrite this"},
                 []
               )

      assert updated.data["fr-FR"]["_name"] == "Cartes 2"
      assert updated.data["fr-FR"]["_description"] == "Cartes a jouer"
    end

    test "a field the AI response doesn't mention is never a candidate, written or skipped" do
      item = create_item(%{name: "Widget", description: "A thing"})

      assert {:ok, updated} =
               AITranslatable.put_translation(item, "fr-FR", %{"name" => "Widget FR"}, [])

      refute Map.has_key?(updated.data["fr-FR"], "_description")
      assert TranslationStatus.field_state(updated, "fr-FR", "description") == :missing
    end
  end

  describe "force_put_language/3" do
    test "merges rather than wholesale-replacing the lang subtree" do
      data = %{"_primary_language" => "en", "es" => %{"_name" => "Hola", "_keep" => "x"}}
      merged = AITranslatable.force_put_language(data, "es", %{"_description" => "Mundo"})
      assert merged["es"]["_name"] == "Hola"
      assert merged["es"]["_keep"] == "x"
      assert merged["es"]["_description"] == "Mundo"
    end

    test "seeds the multilang marker for a column-only (non-multilang) map" do
      merged = AITranslatable.force_put_language(%{}, "es", %{"_name" => "Hola"})
      assert merged["es"]["_name"] == "Hola"
      assert Map.has_key?(merged, "_primary_language")
    end
  end

  describe "strip_ai_note/1" do
    test "keeps legitimate parenthetical and enumerated copy intact" do
      text =
        "Care instructions.\n\n(1) Keep away from heat.\n\n(see the FAQ) Note: hand wash only"

      assert AITranslatable.strip_ai_note(text) == text
    end

    test "cuts a trailing note preceded by a blank line" do
      value = "Vase en Bois\n\n(Note: I've omitted the fields with placeholder values.)"
      assert AITranslatable.strip_ai_note(value) == "Vase en Bois"
    end

    test "cuts from a bare (Note marker with no preceding blank line" do
      value = "Cartes (Note: skipped description as instructed)"
      assert AITranslatable.strip_ai_note(value) == "Cartes"
    end

    test "cuts from a bare Note: marker" do
      value = "Objet\nNote: the description field was skipped."
      assert AITranslatable.strip_ai_note(value) == "Objet"
    end

    test "cuts a trailing note paragraph from a multi-paragraph description" do
      value =
        "Ce produit est magnifique.\n\nIl est fait de bois.\n\n(Note: the SEO field was skipped.)"

      assert AITranslatable.strip_ai_note(value) ==
               "Ce produit est magnifique.\n\nIl est fait de bois."
    end

    test "leaves clean text untouched" do
      assert AITranslatable.strip_ai_note("Vase en Bois") == "Vase en Bois"
    end

    test "passes through non-binary values unchanged" do
      assert AITranslatable.strip_ai_note(nil) == nil
    end

    test "cuts a trailing enumerated 'Notes:' paragraph" do
      value = "Objet decoratif\n\nNotes:\n1. The `Label` field was left as-is."
      assert AITranslatable.strip_ai_note(value) == "Objet decoratif"
    end

    test "cuts a trailing 'Note that ...' paragraph with no colon" do
      value = "Objet decoratif\n\nNote that the \"Label\" field was not translated."
      assert AITranslatable.strip_ai_note(value) == "Objet decoratif"
    end

    test "does not cut 'Please note:' appearing mid-sentence" do
      value = "Please note: sizes vary slightly by batch."
      assert AITranslatable.strip_ai_note(value) == value
    end

    test "does not cut the French 'Veuillez noter' aside" do
      value = "Fait main. Veuillez noter : les couleurs peuvent varier."
      assert AITranslatable.strip_ai_note(value) == value
    end

    test "does not cut a legitimate German 'Hinweis:' paragraph" do
      value = "Handgefertigt.\n\nHinweis: Farben können variieren."
      assert AITranslatable.strip_ai_note(value) == value
    end

    test "does not cut a legitimate care-instructions 'Note:' paragraph" do
      value = "Handmade wooden vase.\n\nNote: hand wash only."
      assert AITranslatable.strip_ai_note(value) == value
    end

    test "does not cut a legitimate bare (Note: parenthetical" do
      value = "Cozy wool scarf (Note: 100% merino wool)."
      assert AITranslatable.strip_ai_note(value) == value
    end

    test "cuts a parenthetical note naming a skipped quoted field with a placeholder" do
      value =
        "Vase\n\n(Note: The \"Title\" field was skipped as it contained only a placeholder " <>
          "{{title}} with no actual value bound to it.)"

      assert AITranslatable.strip_ai_note(value) == "Vase"
    end

    test "cuts a note describing a template-slot field in backticks" do
      value =
        "Vase\n\nNote: Since `Title: {{title}}` is a template slot (indicated by the double " <>
          "curly braces) and not a real value, it is skipped silently as per the rules. Only " <>
          "the `Label` field with an actual value is translated."

      assert AITranslatable.strip_ai_note(value) == "Vase"
    end

    test "cuts an enumerated Notes: list naming a skipped placeholder field in backticks" do
      value =
        "Objet decoratif\n\nNotes:\n1. The `Label` field was skipped because it contains a " <>
          "placeholder."

      assert AITranslatable.strip_ai_note(value) == "Objet decoratif"
    end

    test "does not cut a legitimate 'Note:' paragraph that quotes color names" do
      value = "Ceramic mug.\n\nNote: available in \"Blue\" and \"Red\" glazes."
      assert AITranslatable.strip_ai_note(value) == value
    end

    test "does not cut a legitimate 'Note:' paragraph that backtick-quotes a material" do
      value = "Cast iron skillet.\n\nNote: use `cast iron` pan for best results."
      assert AITranslatable.strip_ai_note(value) == value
    end

    test "does not cut a legitimate 'Note:' paragraph using {{...}} for a size chart" do
      value = "Merino wool scarf.\n\nNote: fits sizes {{S,M,L}} as shown."
      assert AITranslatable.strip_ai_note(value) == value
    end

    test "does not cut marketing copy about the listing itself using 'is/not translated'" do
      value =
        "Elegant scarf.\n\nNote: every listing in our shop is translated by hand and not " <>
          "translated by any automatic tool, to keep the wording natural."

      assert AITranslatable.strip_ai_note(value) == value
    end

    test "does not let a trigger word in a later unrelated paragraph cut a legitimate Note: aside" do
      value =
        "Nice scarf.\n\nNote: hand wash only.\n\nComes with a reusable gift box; the box's " <>
          "engraving field allows personalization."

      assert AITranslatable.strip_ai_note(value) == value
    end
  end

  describe "attribute resources" do
    setup do
      {:ok, group} = Catalogue.create_attribute_group(%{name: "Idea doors"})
      {:ok, attribute} = Catalogue.create_attribute(group, %{"name" => "Color"})
      {:ok, value} = Catalogue.create_attribute_value(attribute, %{"value" => "Oak"})
      %{group: group, attribute: attribute, value: value}
    end

    test "fetch resolves all three types", ctx do
      assert {:ok, %{uuid: g}} = AITranslatable.fetch("catalogue_attribute_group", ctx.group.uuid)
      assert g == ctx.group.uuid
      assert {:ok, _} = AITranslatable.fetch("catalogue_attribute", ctx.attribute.uuid)
      assert {:ok, _} = AITranslatable.fetch("catalogue_attribute_value", ctx.value.uuid)
    end

    test "source_fields speak name for group/attribute and value for values", ctx do
      assert AITranslatable.source_fields(ctx.group, primary()) == %{"name" => "Idea doors"}
      assert AITranslatable.source_fields(ctx.attribute, primary()) == %{"name" => "Color"}
      assert AITranslatable.source_fields(ctx.value, primary()) == %{"value" => "Oak"}
    end

    test "put_translation persists per-language overrides for a value", ctx do
      assert {:ok, _} =
               AITranslatable.put_translation(ctx.value, "ru", %{"value" => "Дуб"}, [])

      reloaded = Catalogue.get_attribute_value(ctx.value.uuid)
      assert reloaded.data["ru"]["_value"] == "Дуб"
      # key untouched — identity survives translation
      assert reloaded.key == ctx.value.key

      resolved = Catalogue.resolved_group(ctx.group.uuid, "ru")
      assert [%{values: [%{value: "Дуб"}]}] = resolved.attributes
    end

    test "put_translation persists a group name override", ctx do
      assert {:ok, _} =
               AITranslatable.put_translation(ctx.group, "et", %{"name" => "Idea uksed"}, [])

      assert Catalogue.get_attribute_group(ctx.group.uuid).data["et"]["_name"] == "Idea uksed"
    end
  end
end
