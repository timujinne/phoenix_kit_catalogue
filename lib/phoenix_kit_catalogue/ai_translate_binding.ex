defmodule PhoenixKitCatalogue.AITranslateBinding do
  @moduledoc """
  `PhoenixKitWeb.Components.AITranslate.FormBinding` for catalogue forms —
  the storage-specific half of the shared AI-translate glue.

  Catalogue stores translations in the multilang `data` JSONB via
  `PhoenixKit.Utils.Multilang`, with per-language overrides under
  **underscore-prefixed** keys (`data[lang]["_name"]`). The engine speaks
  plain field names, so `apply_translation/4` re-prefixes before writing and
  force-stores even values equal to the primary (so an untranslatable string
  still fills the field instead of looking like a failed translation).
  """

  @behaviour PhoenixKitWeb.Components.AITranslate.FormBinding

  alias PhoenixKitCatalogue.AITranslatable

  @impl true
  def existing_translation_langs(_resource_type, assigns) do
    data = Ecto.Changeset.get_field(assigns.changeset, :data) || %{}

    data
    |> Map.drop(["_primary_language"])
    |> Enum.filter(fn {k, v} -> is_binary(k) and translated_subtree?(v) end)
    |> Enum.map(fn {k, _v} -> k end)
  end

  # A language counts as translated only when its subtree holds at least one
  # non-empty `_`-prefixed override (the multilang form's key shape).
  defp translated_subtree?(v) when is_map(v) do
    Enum.any?(v, fn {k, val} ->
      is_binary(k) and String.starts_with?(k, "_") and is_binary(val) and String.trim(val) != ""
    end)
  end

  defp translated_subtree?(_), do: false

  @impl true
  def apply_translation(_resource_type, changeset, lang, fields) do
    data = Ecto.Changeset.get_field(changeset, :data) || %{}
    # Re-prefix plain engine names to the multilang `_`-form the form reads.
    lang_fields = Map.new(fields, fn {k, v} -> {"_" <> k, v} end)
    new_data = AITranslatable.force_put_language(data, lang, lang_fields)
    Ecto.Changeset.put_change(changeset, :data, new_data)
  end

  @impl true
  def actor_uuid(socket), do: PhoenixKitCatalogue.Web.Helpers.actor_uuid(socket)
end
