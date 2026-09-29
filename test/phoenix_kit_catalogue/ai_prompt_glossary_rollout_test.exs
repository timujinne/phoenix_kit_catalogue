defmodule PhoenixKitCatalogue.AIPromptGlossaryRolloutTest do
  @moduledoc """
  The rollout this feature promises, exercised against a real database
  rather than inferred from reading `maybe_update/2`: a prompt stored by an
  install whose `phoenix_kit_ai` does not bind `{{Glossary}}` is rewritten
  IN PLACE, under the same uuid, once that install upgrades — and back again
  on a downgrade.

  Both directions matter. The uuid has to survive because callers hold a
  `prompt_uuid`; the `content_sha` has to follow the new content or the next
  call would rewrite the row again on every single request.
  """

  use PhoenixKitCatalogue.DataCase, async: true

  alias PhoenixKit.RepoHelper
  alias PhoenixKitCatalogue.AIPrompt

  @slot "{{Glossary}}"

  defp sha(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  describe "upgrading phoenix_kit_ai adds the slot in place" do
    test "item/category prompt keeps its uuid and re-stamps content_sha" do
      assert {:ok, uuid} = AIPrompt.ensure_prompt(false)
      before = PhoenixKitAI.get_prompt(uuid)
      refute before.content =~ @slot
      assert before.metadata["content_sha"] == sha(before.content)

      assert {:ok, ^uuid} = AIPrompt.ensure_prompt(true)
      upgraded = PhoenixKitAI.get_prompt(uuid)

      assert upgraded.content =~ @slot
      assert upgraded.metadata["content_sha"] == sha(upgraded.content)
      refute upgraded.metadata["content_sha"] == before.metadata["content_sha"]
    end

    test "attribute-set prompt behaves the same" do
      assert {:ok, uuid} = AIPrompt.ensure_sets_prompt(false)
      refute PhoenixKitAI.get_prompt(uuid).content =~ @slot

      assert {:ok, ^uuid} = AIPrompt.ensure_sets_prompt(true)
      upgraded = PhoenixKitAI.get_prompt(uuid)

      assert upgraded.content =~ @slot
      assert upgraded.metadata["content_sha"] == sha(upgraded.content)
    end

    test "a second call at the same capability rewrites nothing" do
      # Otherwise every `ensure_prompt/0` — and these run from a LiveView
      # mount — would write to the database on each connect.
      #
      # Comparing `updated_at` across two back-to-back calls does NOT show
      # this. `PhoenixKitAI.Prompt` uses `timestamps(type: :utc_datetime)`,
      # i.e. second precision, so two calls milliseconds apart land in the
      # same wall-clock second and the field compares equal whether or not a
      # write happened — the assertion passes vacuously. (The same shape
      # exists elsewhere in this repo's prompt tests; it proves nothing
      # there either.)
      #
      # So back-date the row by a margin far larger than the clock's
      # resolution first. A no-op leaves the stale timestamp untouched; any
      # real UPDATE moves it to now, which is unmistakable.
      assert {:ok, uuid} = AIPrompt.ensure_prompt(true)

      backdated = ~U[2020-01-01 00:00:00Z]

      {:ok, _} =
        RepoHelper.repo().query(
          "UPDATE phoenix_kit_ai_prompts SET updated_at = $1 WHERE uuid = $2",
          [backdated, Ecto.UUID.dump!(uuid)]
        )

      assert PhoenixKitAI.get_prompt(uuid).updated_at == backdated

      assert {:ok, ^uuid} = AIPrompt.ensure_prompt(true)

      assert PhoenixKitAI.get_prompt(uuid).updated_at == backdated,
             "ensure_prompt/1 wrote to the database when the content had not changed"
    end
  end

  describe "downgrading removes the slot the same way" do
    test "item/category prompt loses the slot, keeps its uuid" do
      assert {:ok, uuid} = AIPrompt.ensure_prompt(true)
      assert PhoenixKitAI.get_prompt(uuid).content =~ @slot

      assert {:ok, ^uuid} = AIPrompt.ensure_prompt(false)
      downgraded = PhoenixKitAI.get_prompt(uuid)

      refute downgraded.content =~ @slot
      assert downgraded.metadata["content_sha"] == sha(downgraded.content)
    end
  end
end
