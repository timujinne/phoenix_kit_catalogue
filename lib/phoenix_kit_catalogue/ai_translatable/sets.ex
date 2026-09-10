defmodule PhoenixKitCatalogue.AITranslatable.Sets do
  @moduledoc """
  `PhoenixKitAI.Translatable` adapter for catalogue attribute SETS — the
  entities-backed blueprint (`"catalogue_set_label"`, the set's own display
  name) and its value records (`"catalogue_set_value"`, each value's title).
  See `PhoenixKitCatalogue.Catalogue.AttributeSets` for what a set is; this
  module only translates it.

  Unlike `PhoenixKitCatalogue.AITranslatable`, both resources here are
  entities schemas (`PhoenixKitEntities` / `PhoenixKitEntities.EntityData`),
  not catalogue's own — and their generic writers (`update_entity/3`,
  `EntityData.update/2`) do not lock the row. Same doctrine as the
  item/category adapter: `put_translation/4` re-reads the row `FOR UPDATE`
  inside its own transaction before merging, so two concurrent per-language
  jobs (de/fr) on the same set or value serialize on the row lock instead of
  each overwriting the other's translation from a stale in-memory struct.

  The merge logic mirrors the entities package's own translation helpers
  (`PhoenixKitEntities.set_entity_translation/3`,
  `PhoenixKitEntities.EntityData.set_title_translation/3` — "never drop
  other languages"), but does NOT call them directly: both route through
  `update_entity/3`/`EntityData.update/2`, which broadcast (PubSub),
  activity-log, and fire an async mirror-export Task right after their own
  `repo().update/1` — INSIDE this adapter's still-open `FOR UPDATE`
  transaction. A subscriber reacting to that broadcast would either block
  on the lock or read pre-commit state, and a later failure in this
  transaction (the fingerprint write, previously a second bare update)
  would roll back a write whose broadcast/log/export already went out.
  So the merge here is a bare `Ecto.Changeset.change/2` + `repo().update/1`
  on the locked row, folding the fingerprint into the SAME write; each
  `put_*` function broadcasts exactly once, after the transaction commits.
  """

  @behaviour PhoenixKitAI.Translatable

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitCatalogue.AITranslatable
  alias PhoenixKitCatalogue.TranslationStatus
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.EntityData
  alias PhoenixKitEntities.Events
  alias PhoenixKitEntities.Managed

  @owner "catalogue"

  defp repo, do: RepoHelper.repo()

  @impl true
  def fetch("catalogue_set_label", uuid) do
    case Entities.get_entity(uuid) do
      %Entities{} = set -> owned_or_not_found(set, set)
      nil -> not_found()
    end
  end

  def fetch("catalogue_set_value", uuid) do
    case EntityData.get(uuid) do
      %EntityData{} = value -> owned_or_not_found(Entities.get_entity(value.entity_uuid), value)
      nil -> not_found()
    end
  end

  def fetch(other, _uuid), do: {:error, {:unknown_resource_type, other}}

  # `set` is the blueprint whose ownership gates access; `resource` is what
  # gets returned on success (the set itself for the label type, the value
  # record for the value type).
  defp owned_or_not_found(%Entities{} = set, resource) do
    if Managed.owner(set) == @owner, do: {:ok, resource}, else: not_found()
  end

  defp owned_or_not_found(_set, _resource), do: not_found()

  defp not_found, do: {:error, :resource_not_found}

  @impl true
  def source_fields(%Entities{} = set, source_lang) do
    fields = source_fields_pure(set, source_lang)
    TranslationStatus.capture_fingerprint("catalogue_set_label", set.uuid, fields)
    fields
  end

  def source_fields(%EntityData{} = value, source_lang) do
    fields = source_fields_pure(value, source_lang)
    TranslationStatus.capture_fingerprint("catalogue_set_value", value.uuid, fields)
    fields
  end

  @doc """
  Same extraction as `source_fields/2`, WITHOUT the process-dictionary
  capture side effect — see `AITranslatable.source_fields_pure/2` for why
  a read-only caller (`TranslationStatus.state/2`/`list/2`, and the
  write-time fingerprint fallback below) must not go through the capturing
  `@impl` callback.
  """
  @spec source_fields_pure(struct(), String.t()) :: map()
  def source_fields_pure(%Entities{} = set, source_lang) do
    label = Entities.get_entity_translation(set, source_lang)["display_name"]
    put_if_present(%{}, "label", label)
  end

  def source_fields_pure(%EntityData{} = value, source_lang) do
    title = EntityData.get_title_translation(value, source_lang)
    put_if_present(%{}, "title", title)
  end

  defp put_if_present(map, key, value) when is_binary(value) do
    if String.trim(value) == "", do: map, else: Map.put(map, key, value)
  end

  defp put_if_present(map, _key, _value), do: map

  @impl true
  def put_translation(%Entities{} = set, target_lang, fields, _opts) do
    case Map.fetch(fields, "label") do
      {:ok, label} -> put_set_label(set, target_lang, AITranslatable.strip_ai_note(label))
      :error -> {:ok, set}
    end
  end

  def put_translation(%EntityData{} = value, target_lang, fields, _opts) do
    case Map.fetch(fields, "title") do
      {:ok, title} -> put_value_title(value, target_lang, AITranslatable.strip_ai_note(title))
      :error -> {:ok, value}
    end
  end

  # Bare-changeset merge (no `Entities.set_entity_translation/3`/
  # `update_entity/3` — see the moduledoc): folds the "never drop other
  # languages" merge AND the fingerprint into the single write the locked
  # transaction makes, then broadcasts once after it commits. Skips the
  # write (and the broadcast) entirely when the field is already `:fresh`
  # — per-field write narrowing, design source §4.4/§12.2, same rule the
  # item/category adapter applies: a hand-edited label/title survives a
  # re-translate whose source didn't actually change.
  defp put_set_label(set, target_lang, label) do
    case locked_update(Entities, set.uuid, &decide_label(&1, target_lang, label)) do
      {:ok, {:written, updated}} ->
        Events.broadcast_entity_updated(updated.uuid)
        {:ok, updated}

      {:ok, {:skipped, fresh}} ->
        {:ok, fresh}

      error ->
        error
    end
  end

  defp put_value_title(value, target_lang, title) do
    case locked_update(EntityData, value.uuid, &decide_title(&1, target_lang, title)) do
      {:ok, {:written, updated}} ->
        Events.broadcast_data_updated(updated.entity_uuid, updated.uuid)
        {:ok, updated}

      {:ok, {:skipped, fresh}} ->
        {:ok, fresh}

      error ->
        error
    end
  end

  # Same eligibility rule as `AITranslatable.writable_fields/3`: write only
  # when the field is `:missing`, `:unknown`, or `:stale`. A `:fresh` field
  # is left untouched (the narrowing this whole block exists for); a `nil`
  # state (no current source right now) is left untouched too, though in
  # practice unreachable here — both `display_name` and `title` are
  # required columns on their respective entities schemas.
  @writable_states [:missing, :unknown, :stale]

  defp decide_label(fresh, target_lang, label) do
    if TranslationStatus.field_state(fresh, target_lang, "label") in @writable_states do
      with {:ok, updated} <- merge_label(fresh, target_lang, label),
           do: {:ok, {:written, updated}}
    else
      {:ok, {:skipped, fresh}}
    end
  end

  defp decide_title(fresh, target_lang, title) do
    if TranslationStatus.field_state(fresh, target_lang, "title") in @writable_states do
      with {:ok, updated} <- merge_title(fresh, target_lang, title),
           do: {:ok, {:written, updated}}
    else
      {:ok, {:skipped, fresh}}
    end
  end

  # Mirrors `PhoenixKitEntities.set_entity_translation/3`'s merge (existing
  # translation for `target_lang`, overlaid with `attrs`, empty values
  # dropped, the whole language entry removed when it goes empty) against
  # the FRESHLY LOCKED row, then folds the fingerprint into the same
  # `settings` write.
  defp merge_label(fresh, target_lang, label) do
    settings = fresh.settings || %{}
    translations = Map.get(settings, "translations", %{})
    existing = Map.get(translations, target_lang, %{})
    merged = Map.merge(existing, %{"display_name" => label})

    cleaned =
      merged |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end) |> Map.new()

    updated_translations =
      if map_size(cleaned) == 0,
        do: Map.delete(translations, target_lang),
        else: Map.put(translations, target_lang, cleaned)

    new_settings =
      if map_size(updated_translations) == 0,
        do: Map.delete(settings, "translations"),
        else: Map.put(settings, "translations", updated_translations)

    fp = fingerprint_for("catalogue_set_label", fresh, "label")
    final_settings = put_field_fingerprint(new_settings, fresh, target_lang, "label", fp)

    fresh |> Ecto.Changeset.change(%{settings: final_settings}) |> repo().update()
  end

  # Mirrors `PhoenixKitEntities.EntityData.set_title_translation/3`
  # (merges `_title` into the existing per-language override, and syncs
  # the `title` column too when `target_lang` is the primary language)
  # against the FRESHLY LOCKED row, then folds the fingerprint into the
  # same `metadata` write.
  defp merge_title(fresh, target_lang, title) do
    existing_lang_data = Multilang.get_raw_language_data(fresh.data, target_lang)
    merged_lang_data = Map.put(existing_lang_data, "_title", title)
    updated_data = Multilang.put_language_data(fresh.data, target_lang, merged_lang_data)

    primary = (fresh.data || %{})["_primary_language"] || Multilang.primary_language()

    fp = fingerprint_for("catalogue_set_value", fresh, "title")
    final_metadata = put_field_fingerprint(fresh.metadata || %{}, fresh, target_lang, "title", fp)

    attrs = %{data: updated_data, metadata: final_metadata}
    attrs = if target_lang == primary, do: Map.put(attrs, :title, title), else: attrs

    fresh |> Ecto.Changeset.change(attrs) |> repo().update()
  end

  # The fingerprint `source_fields/2` captured for THIS job
  # (`TranslationStatus.captured_fingerprint/2`), falling back to hashing
  # `fresh`'s own current source for `field` — via the PURE extraction,
  # never the capturing `source_fields/2` — when nothing was captured (a
  # direct `put_translation/4` call that skipped `source_fields/2`: a
  # test, a CLI write).
  defp fingerprint_for(resource_type, fresh, field) do
    captured = TranslationStatus.captured_fingerprint(resource_type, fresh.uuid) || %{}

    Map.get(captured, field) ||
      fresh
      |> source_fields_pure(Multilang.primary_language())
      |> TranslationStatus.field_fingerprints()
      |> Map.get(field)
  end

  # Folds `field`'s new hash into the WHOLE per-field fingerprint map
  # already stored for `lang` (read from `fresh`, i.e. the row's state
  # BEFORE this write) — a set only ever has the one field ("label" or
  # "title"), but this keeps the storage shape identical to the
  # item/category adapter's multi-field map.
  defp put_field_fingerprint(container, fresh, lang, field, fp) do
    updated = fresh |> TranslationStatus.stored_fingerprint_map(lang) |> Map.put(field, fp)
    fingerprints = container |> Map.get("translation_fingerprints", %{}) |> Map.put(lang, updated)
    Map.put(container, "translation_fingerprints", fingerprints)
  end

  # Re-reads `uuid` FOR UPDATE inside a fresh transaction, then hands the
  # locked row to `update_fn` — the shared shape behind both writes above.
  defp locked_update(queryable, uuid, update_fn) do
    repo().transaction(fn ->
      query = where(queryable, [r], r.uuid == ^uuid) |> lock("FOR UPDATE")

      case repo().one(query) do
        nil -> repo().rollback(:resource_not_found)
        fresh -> apply_locked_update(update_fn, fresh)
      end
    end)
  end

  defp apply_locked_update(update_fn, fresh) do
    case update_fn.(fresh) do
      {:ok, updated} -> updated
      {:error, reason} -> repo().rollback(reason)
    end
  end
end
