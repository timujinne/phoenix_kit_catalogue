defmodule PhoenixKitCatalogue.AIPromptSourceFieldsTest do
  @moduledoc """
  The SOURCE block of both catalogue translation templates, built from the
  engine's `{{SourceFields}}` block instead of one slot per possible field,
  and the Markdown rule that keeps a description's headings inside it.

  Two defects observed on deepseek/deepseek-chat drive this:

    * a call binding only some fields left the other slots as literal
      `{{summary}}`/`{{label}}` text; the model skipped them as told and
      then wrote notes about skipping them, which ended up in the stored
      translation;
    * a description's `## Section` headings came back as extra
      `---SECTION---` marker lines, which cut the description short.

  Database-free: these read and render the templates, they do not
  provision them.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitAI.Prompt
  alias PhoenixKitAI.Translation
  alias PhoenixKitCatalogue.AIPrompt

  @engine_slots ["{{SourceLanguage}}", "{{TargetLanguage}}", "{{SourceFields}}", "{{Glossary}}"]

  defp render(template, fields) do
    variables = Translation.build_variables(fields, "en-US", "de-DE", nil)
    {:ok, rendered} = Prompt.render_content(template, variables)
    rendered
  end

  describe "a call that binds only some fields" do
    test "renders no unbound placeholder in the set prompt (a value title alone)" do
      rendered = render(AIPrompt.sets_content(), %{"title" => "Yellow"})

      assert Prompt.unbound_placeholders(rendered) == []
      assert rendered =~ "---TITLE---\nYellow"
    end

    test "renders no unbound placeholder in the item prompt (name and description alone)" do
      rendered =
        render(AIPrompt.content(), %{
          "name" => "Vase",
          "description" => "A vase.\n\n## Size\n\n12 inches."
        })

      assert Prompt.unbound_placeholders(rendered) == []
      assert rendered =~ "---DESCRIPTION---\nA vase.\n\n## Size\n\n12 inches."
    end
  end

  describe "templates built on {{SourceFields}}" do
    test "carry no slot but the engine's own" do
      for template <- [AIPrompt.content(true, true), AIPrompt.sets_content(true, true)] do
        assert Prompt.unbound_placeholders(template) -- @engine_slots == []
        assert template =~ "{{SourceFields}}"
      end
    end

    test "carry no rule about unfilled template slots — there are none to skip" do
      for template <- [AIPrompt.content(true, true), AIPrompt.sets_content(true, true)] do
        refute template =~ "unfilled template slot"
      end
    end
  end

  describe "templates for an engine without {{SourceFields}}" do
    # `phoenix_kit_ai` before 0.23.0 does not bind the block, so the slot
    # would reach the model as literal text. These keep the per-field slots
    # and the rule telling the model to skip the unbound ones.
    test "keep the per-field slots and the skip rule" do
      item = AIPrompt.content(true, false)
      sets = AIPrompt.sets_content(true, false)

      for slot <- ~w({{name}} {{description}} {{summary}} {{seo_title}} {{seo_description}}),
          do: assert(item =~ slot)

      assert sets =~ "{{label}}"
      assert sets =~ "{{title}}"

      for template <- [item, sets] do
        refute template =~ "{{SourceFields}}"
        assert template =~ "unfilled template slot"
      end
    end
  end

  describe "the Markdown rule" do
    test "is in the shipped templates" do
      for template <- [AIPrompt.content(), AIPrompt.sets_content()] do
        assert template =~ "headings (`##`, `###`)"
        assert template =~ "Never turn a heading"
      end
    end

    test "is in every capability combination" do
      for glossary? <- [true, false], source_fields? <- [true, false] do
        assert AIPrompt.content(glossary?, source_fields?) =~ "headings (`##`, `###`)"
        assert AIPrompt.sets_content(glossary?, source_fields?) =~ "headings (`##`, `###`)"
      end
    end

    test "sits in the instruction area, before the SOURCE block" do
      for template <- [AIPrompt.content(), AIPrompt.sets_content()] do
        [{rule_at, _}] = Regex.run(~r/headings \(`##`, `###`\)/, template, return: :index)
        [{source_at, _}] = Regex.run(~r/=== SOURCE ===/, template, return: :index)

        assert rule_at < source_at
      end
    end
  end

  describe "the no-extension rule" do
    # A shop's `summary` is the description's first ~500 characters, cut
    # mid-sentence. The model continued one such summary past the cut: a
    # 500-character source came back as 1976 (de-DE) and 2126 (fr-FR).
    test "is in every capability combination of both templates" do
      for glossary? <- [true, false], source_fields? <- [true, false] do
        for template <- [
              AIPrompt.content(glossary?, source_fields?),
              AIPrompt.sets_content(glossary?, source_fields?)
            ] do
          assert template =~ ~r/do not complete, extend\s+or summarise it/
          assert template =~ ~r/ends mid-sentence, end\s+the translation/
        end
      end
    end

    test "is in the shipped templates" do
      for template <- [AIPrompt.content(), AIPrompt.sets_content()] do
        assert template =~ ~r/do not complete, extend\s+or summarise it/
      end
    end
  end

  describe "source_fields_supported?/0" do
    test "answers the capability question, not a version question" do
      # `build_variables/3` arrived in the same release that started binding
      # `{{SourceFields}}`; an engine without it binds neither.
      expected =
        Code.ensure_loaded?(PhoenixKitAI.Translation) and
          function_exported?(PhoenixKitAI.Translation, :build_variables, 3)

      assert AIPrompt.source_fields_supported?() == expected
    end

    test "content/0 and sets_content/0 default to both detected capabilities" do
      glossary? = AIPrompt.glossary_slot_supported?()
      source_fields? = AIPrompt.source_fields_supported?()

      assert AIPrompt.content() == AIPrompt.content(glossary?, source_fields?)
      assert AIPrompt.sets_content() == AIPrompt.sets_content(glossary?, source_fields?)
    end
  end
end
