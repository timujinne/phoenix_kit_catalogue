defmodule PhoenixKitCatalogue.AIPromptTest do
  @moduledoc """
  Unit coverage for `PhoenixKitCatalogue.AIPrompt.ensure_prompt/0` — the
  idempotent-by-slug provisioning of the catalogue translation prompt,
  and its `content_sha`-driven rollout when the template changes.
  """

  use PhoenixKitCatalogue.DataCase, async: true

  alias PhoenixKitCatalogue.AIPrompt

  describe "ensure_prompt/0" do
    test "creates the prompt on first call under the expected slug" do
      assert {:ok, uuid} = AIPrompt.ensure_prompt()

      prompt = PhoenixKitAI.get_prompt(uuid)
      assert prompt.slug == AIPrompt.slug()
      assert is_binary(prompt.metadata["content_sha"])
      assert prompt.metadata["managed_by"] == "phoenix_kit_catalogue"
    end

    test "is idempotent by slug — repeated calls return the same uuid" do
      assert {:ok, uuid1} = AIPrompt.ensure_prompt()
      assert {:ok, uuid2} = AIPrompt.ensure_prompt()
      assert uuid1 == uuid2

      # No duplicate row was inserted under the slug.
      assert PhoenixKitAI.get_prompt_by_slug(AIPrompt.slug()).uuid == uuid1
    end

    test "does not rewrite the stored row when content_sha already matches" do
      {:ok, uuid} = AIPrompt.ensure_prompt()
      before = PhoenixKitAI.get_prompt(uuid)

      {:ok, ^uuid} = AIPrompt.ensure_prompt()
      after_second_call = PhoenixKitAI.get_prompt(uuid)

      assert before.updated_at == after_second_call.updated_at
    end

    test "updates the stored prompt in place when the template has evolved" do
      {:ok, uuid} = AIPrompt.ensure_prompt()
      prompt = PhoenixKitAI.get_prompt(uuid)

      # Simulate a shipped rule change that predates this deploy: the
      # stored row still carries an older template and content_sha.
      {:ok, stale} =
        PhoenixKitAI.update_prompt(prompt, %{
          content: "An older, since-replaced catalogue translation prompt.",
          metadata: %{"managed_by" => "phoenix_kit_catalogue", "content_sha" => "deadbeef"}
        })

      refute stale.content == prompt.content

      assert {:ok, ^uuid} = AIPrompt.ensure_prompt()

      updated = PhoenixKitAI.get_prompt(uuid)
      assert updated.content == prompt.content
      assert updated.metadata["content_sha"] == prompt.metadata["content_sha"]
      refute updated.metadata["content_sha"] == "deadbeef"
    end
  end

  describe "ensure_sets_prompt/0" do
    test "creates a prompt distinct from ensure_prompt/0's, with no per-field slots" do
      assert {:ok, sets_uuid} = AIPrompt.ensure_sets_prompt()
      assert {:ok, item_uuid} = AIPrompt.ensure_prompt()

      refute sets_uuid == item_uuid

      sets_prompt = PhoenixKitAI.get_prompt(sets_uuid)
      assert sets_prompt.slug == AIPrompt.sets_slug()
      refute sets_prompt.slug == AIPrompt.slug()
      # The fields arrive through the engine's block; a `{{label}}` slot left
      # unbound by a title-only call is what the model used to comment on.
      assert sets_prompt.content =~ "{{SourceFields}}"
      refute sets_prompt.content =~ "{{label}}"
      refute sets_prompt.content =~ "{{title}}"
      refute sets_prompt.content =~ "seo_title"
    end

    test "is idempotent by slug — repeated calls return the same uuid" do
      assert {:ok, uuid1} = AIPrompt.ensure_sets_prompt()
      assert {:ok, uuid2} = AIPrompt.ensure_sets_prompt()
      assert uuid1 == uuid2

      assert PhoenixKitAI.get_prompt_by_slug(AIPrompt.sets_slug()).uuid == uuid1
    end

    test "updates the stored prompt in place when the template has evolved" do
      {:ok, uuid} = AIPrompt.ensure_sets_prompt()
      prompt = PhoenixKitAI.get_prompt(uuid)

      {:ok, stale} =
        PhoenixKitAI.update_prompt(prompt, %{
          content: "An older, since-replaced set translation prompt.",
          metadata: %{"managed_by" => "phoenix_kit_catalogue", "content_sha" => "deadbeef"}
        })

      refute stale.content == prompt.content

      assert {:ok, ^uuid} = AIPrompt.ensure_sets_prompt()

      updated = PhoenixKitAI.get_prompt(uuid)
      assert updated.content == prompt.content
      assert updated.metadata["content_sha"] == prompt.metadata["content_sha"]
      refute updated.metadata["content_sha"] == "deadbeef"
    end
  end
end
