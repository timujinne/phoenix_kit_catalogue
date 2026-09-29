defmodule PhoenixKitCatalogue.AIPromptSourceFieldsRolloutTest do
  @moduledoc """
  A prompt stored by an install whose `phoenix_kit_ai` does not bind
  `{{SourceFields}}` (per-field slots) is rewritten IN PLACE, under the same
  uuid, once the engine binds it — the same content-addressed rollout the
  glossary slot uses, driven here by the second capability.
  """

  use PhoenixKitCatalogue.DataCase, async: true

  alias PhoenixKitCatalogue.AIPrompt

  defp sha(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  test "item/category prompt switches to the SourceFields block, same uuid" do
    assert {:ok, uuid} = AIPrompt.ensure_prompt(true, false)
    before = PhoenixKitAI.get_prompt(uuid)
    assert before.content =~ "{{summary}}"

    assert {:ok, ^uuid} = AIPrompt.ensure_prompt(true, true)
    upgraded = PhoenixKitAI.get_prompt(uuid)

    assert upgraded.content =~ "{{SourceFields}}"
    refute upgraded.content =~ "{{summary}}"
    assert upgraded.metadata["content_sha"] == sha(upgraded.content)
  end

  test "attribute-set prompt switches the same way" do
    assert {:ok, uuid} = AIPrompt.ensure_sets_prompt(true, false)
    assert PhoenixKitAI.get_prompt(uuid).content =~ "{{label}}"

    assert {:ok, ^uuid} = AIPrompt.ensure_sets_prompt(true, true)
    upgraded = PhoenixKitAI.get_prompt(uuid)

    assert upgraded.content =~ "{{SourceFields}}"
    refute upgraded.content =~ "{{label}}"
    assert upgraded.metadata["content_sha"] == sha(upgraded.content)
  end
end
