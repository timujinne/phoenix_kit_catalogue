defmodule PhoenixKitCatalogue.AITranslateBinding do
  @moduledoc """
  `PhoenixKitAI.Components.AITranslate.FormBinding` for catalogue forms —
  the storage-specific half of the shared AI-translate glue.

  Catalogue stores translations in the multilang `data` JSONB via
  `PhoenixKit.Utils.Multilang`, with per-language overrides under
  **underscore-prefixed** keys (`data[lang]["_name"]`). The engine speaks
  plain field names, so `apply_translation/4` re-prefixes before writing and
  force-stores even values equal to the primary (so an untranslatable string
  still fills the field instead of looking like a failed translation).
  """

  @behaviour PhoenixKitAI.Components.AITranslate.FormBinding

  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitCatalogue.AITranslatable
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Web.Helpers

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
  def apply_translation(resource_type, changeset, lang, fields) do
    data = Ecto.Changeset.get_field(changeset, :data) || %{}
    row = persisted_row(resource_type, changeset)

    new_data =
      data
      |> AITranslatable.force_put_language(lang, translated_bucket(row, lang, fields))
      |> put_fresh_fingerprints(row)

    Ecto.Changeset.put_change(changeset, :data, new_data)
  end

  # The worker PERSISTED before it broadcast, and its write is the
  # narrowed, sanitized one (`AITranslatable.put_translation/4`): a field
  # whose translation was hand-corrected and is still `:fresh` was
  # skipped, and a leaked model aside was cut by `strip_ai_note/1`. The
  # payload the form receives is the RAW model output, so until
  # 2026-09-13 an in-form Translate followed by Save wrote the raw
  # value over the hand correction — with the fingerprint still saying
  # fresh, so nothing ever flagged it. Each field is therefore taken
  # from the row the worker just wrote; the (sanitized) payload is only
  # the fallback for a field the row has nothing for — a `:new`
  # resource, a type without the mechanism, a field the worker left
  # untouched. Plain engine names are re-prefixed to the multilang
  # `_`-form the form reads.
  defp translated_bucket(row, lang, fields) do
    stored =
      case row do
        %{data: data} -> Multilang.get_raw_language_data(data || %{}, lang)
        _ -> %{}
      end

    Map.new(fields, fn {k, v} ->
      key = "_" <> k

      case Map.get(stored, key) do
        value when is_binary(value) and value != "" -> {key, value}
        _ -> {key, AITranslatable.strip_ai_note(v)}
      end
    end)
  end

  # `PhoenixKitCatalogue.TranslationStatus` writes
  # `_translation_fingerprints` straight to the DB row (the worker's
  # write path — see `AITranslatable.put_translation/4`), independently
  # of whatever changeset an open form is holding. Left alone, the next
  # save from that open form would overwrite the row with THIS
  # changeset's `data`, which predates the worker's write, silently
  # erasing the fingerprint it just landed (reproduced live 2026-09-10 on
  # a real item: translate, then Save a few seconds later, and the whole
  # `_translation_fingerprints` map was gone). Re-reading the row here
  # keeps the live changeset — and so the eventual save — carrying the
  # freshest fingerprints regardless of what this changeset started
  # from.
  #
  # A no-op for resource types with no fingerprint mechanism at all
  # (`"catalogue"`, attribute groups, …) and for a not-yet-persisted
  # (`:new`) resource, which has no row to re-read.
  defp put_fresh_fingerprints(data, %{data: row_data}) when is_map(row_data) do
    case Map.get(row_data, "_translation_fingerprints") do
      nil -> data
      fingerprints -> Map.put(data, "_translation_fingerprints", fingerprints)
    end
  end

  defp put_fresh_fingerprints(data, _row), do: data

  # The row as the worker left it — one read, shared by the field values
  # and the fingerprints above. `nil` for a `:new` resource and for types
  # this module does not persist translations for.
  defp persisted_row(resource_type, changeset) do
    case Ecto.Changeset.get_field(changeset, :uuid) do
      uuid when is_binary(uuid) -> fetch_row(resource_type, uuid)
      _ -> nil
    end
  end

  defp fetch_row("catalogue_item", uuid), do: Catalogue.get_item(uuid)
  defp fetch_row("catalogue_category", uuid), do: Catalogue.get_category(uuid)
  defp fetch_row(_resource_type, _uuid), do: nil

  @impl true
  def actor_uuid(socket), do: Helpers.actor_uuid(socket)
end
