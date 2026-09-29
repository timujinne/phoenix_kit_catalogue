defmodule PhoenixKitCatalogue.AIPromptGlossaryTest do
  @moduledoc """
  The `{{Glossary}}` slot in both catalogue translation templates, and the
  capability gate that keeps it out of the prompt on an older
  `phoenix_kit_ai` that does not bind the variable.

  Database-free: these read the templates, they do not provision them.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitCatalogue.AIPrompt

  @slot "{{Glossary}}"

  describe "the slot is present exactly once when the engine binds it" do
    test "item/category template" do
      assert length(Regex.scan(~r/\{\{Glossary\}\}/, AIPrompt.content(true))) == 1
    end

    test "attribute-set template" do
      assert length(Regex.scan(~r/\{\{Glossary\}\}/, AIPrompt.sets_content(true))) == 1
    end

    test "the slot sits in the instruction area, before the SOURCE block" do
      # A glossary rendered after the source text reads as part of the
      # content to translate rather than as an instruction about it.
      for template <- [AIPrompt.content(true), AIPrompt.sets_content(true)] do
        [{slot_at, _}] = Regex.run(~r/\{\{Glossary\}\}/, template, return: :index)
        [{source_at, _}] = Regex.run(~r/=== SOURCE ===/, template, return: :index)

        assert slot_at < source_at
      end
    end
  end

  describe "the slot is absent on an engine that does not bind it" do
    # Without the gate the literal text `{{Glossary}}` reaches the model
    # inside a RULES section that tells it to skip anything looking like an
    # unfilled template slot — an instruction about nothing, in a prompt
    # whose whole point is exact rule-following.
    test "item/category template drops it" do
      refute AIPrompt.content(false) =~ @slot
    end

    test "attribute-set template drops it" do
      refute AIPrompt.sets_content(false) =~ @slot
    end

    test "dropping the slot changes NOTHING else in either template" do
      # The gate must remove the slot line and leave every other byte alone:
      # a stray edit here silently rewrites translation rules for every
      # install on an older engine.
      for {with_slot, without} <- [
            {AIPrompt.content(true), AIPrompt.content(false)},
            {AIPrompt.sets_content(true), AIPrompt.sets_content(false)}
          ] do
        assert String.replace(with_slot, "#{@slot}\n\n", "", global: false) == without
      end
    end

    test "the gated and ungated templates are genuinely different" do
      # Guards the test above from passing vacuously if the slot were
      # missing from the template altogether.
      refute AIPrompt.content(true) == AIPrompt.content(false)
      refute AIPrompt.sets_content(true) == AIPrompt.sets_content(false)
    end
  end

  describe "glossary_slot_supported?/0" do
    test "answers the capability question, not a version question" do
      # Feature detection: `build_variables/4` is the arity that takes the
      # glossary. A version constraint would have to name a release that did
      # not exist when this shipped, and would force a merge order between
      # two repositories.
      expected =
        Code.ensure_loaded?(PhoenixKitAI.Translation) and
          function_exported?(PhoenixKitAI.Translation, :build_variables, 4)

      assert AIPrompt.glossary_slot_supported?() == expected
    end

    test "content/0 and sets_content/0 default to the detected capability" do
      supported = AIPrompt.glossary_slot_supported?()

      assert AIPrompt.content() == AIPrompt.content(supported)
      assert AIPrompt.sets_content() == AIPrompt.sets_content(supported)
    end
  end
end
