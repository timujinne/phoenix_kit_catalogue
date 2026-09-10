defmodule PhoenixKitCatalogue.TranslationStatus do
  @moduledoc """
  Freshness of catalogue AI translations: a per-(resource, language, FIELD)
  fingerprint of the source text, and the state it implies.

  ## Fingerprints

  `field_fingerprint/1` sha256-hexes a single trimmed source value.
  `field_fingerprints/1` applies it to every entry of a `source_fields/2`-
  shaped map, producing one hash per field. This is the per-field
  narrowing decision from the design source (§4.4, §12.2): staleness, and
  the write path's decision to touch a field at all, are computed FIELD BY
  FIELD, not over the whole resource collapsed into one hash — so a hand-
  corrected translation of one field survives a re-translate that only
  changed a sibling field.

  (`fingerprint/1` remains: a single order-independent hash over an entire
  `source_fields/2` map. It predates the per-field model and is kept for
  callers that still want a whole-resource digest — nothing in this module
  writes it to storage any more.)

  The fingerprint must reflect the source text **as read at translation
  time**, not whatever it looks like when the translation is written back —
  a sync can land on the row in between (design source doc §4.1). So
  `capture_fingerprint/3` stashes the PER-FIELD hashes in the calling
  process's dictionary when `source_fields/2` runs, keyed by
  `{resource_type, uuid}`; `put_translation/4` in each adapter reads them
  back via `captured_fingerprint/2` and writes the touched ones under the
  target language's key — falling back to hashing the freshly-locked row's
  OWN current source only when nothing was captured (a direct call
  bypassing `source_fields/2`).

  Storage (catalogue-owned keys, additive JSONB — see the block-6 plan's
  amendment vs the original design source), now a MAP of field name to
  hash per language rather than a single hash:

    * `%Item{}` / `%Category{}` →
      `data["_translation_fingerprints"][lang][field]`
    * `%PhoenixKitEntities{}` (a catalogue set's blueprint) →
      `settings["translation_fingerprints"][lang][field]` (single field,
      `"label"`)
    * `%PhoenixKitEntities.EntityData{}` (a set's value) →
      `metadata["translation_fingerprints"][lang][field]` (single field,
      `"title"`)

  ### Legacy rows (pre-per-field rollout)

  Resources translated before this model shipped store a single hex
  string at `[...]["_translation_fingerprints"][lang]` instead of a map
  (the whole-resource `fingerprint/1` digest from the original rollout).
  Every reader here (`stored_fingerprint_map/2`, `field_state/3`, …)
  treats a non-map value at that key as **absent** — the field falls back
  to `:unknown` (given an existing translation) rather than `:stale`.

  This is a deliberate choice over the alternative (comparing the legacy
  whole-resource hash against each field's fresh hash, which would
  virtually never match since the two hash different inputs, and so would
  report `:stale` for nearly every field). `:stale` feeds the sweep
  worker's automatic candidate list — turning every legacy row `:stale` on
  deploy would silently enqueue a re-translation storm across every
  legacy resource the moment this ships, spending AI tokens nobody
  authorized (design source §13: "a mass run happens only by separate
  owner decision"). `:unknown` is the model's existing "we don't know,
  ask a human" bucket, is never auto-swept, and matches what the write
  path already does for these rows regardless of which interpretation
  `state/2` reports: since neither interpretation ever finds a matching
  per-field hash for a legacy row, the write-narrowing table's "no stored
  fingerprint" and "hash mismatch" branches agree — both write + stamp.
  So `:unknown` costs nothing at write time and avoids an unauthorized
  automatic AI bill at read time.

  ## States

  `state/2` folds a (resource, language) pair into one of four states —
  the WORST across every field that currently has non-empty source text
  (a field whose source is empty right now is excluded from the fold
  entirely, per design source §4.1; its translation, if any, is left
  alone). `field_state/3` answers the same question for one field alone
  (or `nil` when that field currently has no source).

    * `:missing` — the source is non-empty but there is no translation
    * `:unknown` — a translation exists but has no recorded fingerprint
      (pre-existing translations from before this model shipped, one
      written outside `put_translation/4`, or a legacy whole-resource
      fingerprint — see above)
    * `:stale`   — the translation's fingerprint no longer matches the
      current source
    * `:fresh`   — the translation's fingerprint matches the current source

  Fold order (worst wins): `missing` > `stale` > `unknown` > `fresh`.

  `unknown` is deliberately never auto-swept (see the sweep worker,
  Task 4) — an operator decides its fate via `stamp_fresh/2`/`3` ("the
  current source is the reference") or an explicit retranslate.
  """

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitCatalogue.AITranslatable
  alias PhoenixKitCatalogue.AITranslatable.Sets
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitCatalogue.Schemas.Category
  alias PhoenixKitCatalogue.Schemas.Item
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.EntityData

  @type state :: :missing | :stale | :unknown | :fresh

  # The multilang-override field keys the item/category adapter exposes
  # (`PhoenixKitCatalogue.AITranslatable`'s engine-facing names) — a
  # resource counts as "translated" for a language when at least one of
  # these has a non-blank override.
  @override_fields ~w(name description summary seo_title seo_description)

  # Worst-wins fold order for `state/2`: lower rank = worse.
  @state_rank %{missing: 0, stale: 1, unknown: 2, fresh: 3}

  defp repo, do: RepoHelper.repo()
  defp source_lang, do: Multilang.primary_language()

  # ── Fingerprinting ────────────────────────────────────────────────

  @doc """
  sha256 hex digest of `source_fields`, order-independent: fields are
  sorted by key, each rendered as `"field=trimmed value"`, joined by `"\\n"`.

  Kept for callers that want a single whole-resource digest (and for the
  legacy-format discussion in the moduledoc); the per-field model below
  (`field_fingerprint/1` / `field_fingerprints/1`) is what gets written to
  storage now.
  """
  @spec fingerprint(map()) :: String.t()
  def fingerprint(source_fields) when is_map(source_fields) do
    source_fields
    |> Enum.sort_by(fn {field, _value} -> field end)
    |> Enum.map_join("\n", fn {field, value} -> "#{field}=#{String.trim(to_string(value))}" end)
    |> sha256_hex()
  end

  @doc "sha256 hex digest of a single trimmed field value."
  @spec field_fingerprint(String.t()) :: String.t()
  def field_fingerprint(value) when is_binary(value) do
    value |> String.trim() |> sha256_hex()
  end

  @doc "Applies `field_fingerprint/1` to every entry of a `source_fields/2`-shaped map."
  @spec field_fingerprints(map()) :: %{String.t() => String.t()}
  def field_fingerprints(source_fields) when is_map(source_fields) do
    Map.new(source_fields, fn {field, value} -> {field, field_fingerprint(to_string(value))} end)
  end

  defp sha256_hex(binary) do
    binary |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end

  @doc """
  Records the PER-FIELD fingerprints of `source_fields` for
  `{resource_type, uuid}` in the CALLING PROCESS's dictionary. Meant to be
  called from inside a `source_fields/2` implementation, right before the
  value is handed to the AI engine — see the moduledoc.
  """
  @spec capture_fingerprint(String.t(), Ecto.UUID.t(), map()) :: :ok
  def capture_fingerprint(resource_type, uuid, source_fields) do
    Process.put({:pk_catalogue_fp, resource_type, uuid}, field_fingerprints(source_fields))
    :ok
  end

  @doc "Reads back the per-field fingerprints captured earlier in THIS process, or `nil`."
  @spec captured_fingerprint(String.t(), Ecto.UUID.t()) :: %{String.t() => String.t()} | nil
  def captured_fingerprint(resource_type, uuid) do
    Process.get({:pk_catalogue_fp, resource_type, uuid})
  end

  # ── States ────────────────────────────────────────────────────────

  @doc """
  The freshness state of `resource`'s translation into `lang`, folded
  (worst wins) across every field that currently has non-empty source
  text. `:missing` when no field currently has source text at all but
  something is translated for `lang` would be surprising — that resource
  simply reports `:missing` (nothing eligible to translate) unless it is
  itself translated, in which case `:unknown` (see moduledoc).
  """
  @spec state(struct(), String.t()) :: state()
  def state(resource, lang) do
    fields = resource |> current_source_fields() |> Map.keys()

    case fields do
      [] ->
        if translated?(resource, lang), do: :unknown, else: :missing

      _ ->
        fields |> Enum.map(&field_state(resource, lang, &1)) |> Enum.reject(&is_nil/1) |> worst()
    end
  end

  defp worst([]), do: :missing
  defp worst(states), do: Enum.min_by(states, &Map.fetch!(@state_rank, &1))

  @doc """
  The freshness state of a single FIELD of `resource`'s translation into
  `lang`. `nil` when `field` currently has no non-empty source text — such
  a field is excluded from `state/2`'s fold and its translation, if any,
  is left untouched by the write path.
  """
  @spec field_state(struct(), String.t(), String.t()) :: state() | nil
  def field_state(resource, lang, field) do
    case Map.get(current_source_fields(resource), field) do
      nil ->
        nil

      value ->
        cond do
          is_nil(field_translated_value(resource, lang, field)) -> :missing
          is_nil(stored_field_fingerprint(resource, lang, field)) -> :unknown
          stored_field_fingerprint(resource, lang, field) == field_fingerprint(value) -> :fresh
          true -> :stale
        end
    end
  end

  @doc """
  Operator action: "the current source is canonical" — writes the CURRENT
  source's fingerprint under `lang` for every field that is both currently
  sourced and translated, without calling the AI. Flips the resource to
  `:fresh` for `lang` (or leaves it alone — see the guard below: a
  resource with no translation for `lang` has nothing to stamp).
  """
  @spec stamp_fresh(struct(), String.t()) :: {:ok, struct()} | {:error, term()}
  def stamp_fresh(resource, lang) do
    if translated?(resource, lang) do
      locked_stamp(resource, lang, :all)
    else
      {:error, :no_translation}
    end
  end

  @doc """
  Field-narrowed `stamp_fresh/2`: stamps only `fields` (a field name or a
  list of them), leaving every other field's stored fingerprint as-is. A
  field is skipped (no-op) unless it is both currently sourced AND
  translated; the call as a whole fails with `{:error, :no_translation}`
  only when NONE of the requested fields qualify.
  """
  @spec stamp_fresh(struct(), String.t(), String.t() | [String.t()]) ::
          {:ok, struct()} | {:error, term()}
  def stamp_fresh(resource, lang, fields) do
    fields = List.wrap(fields)

    if Enum.any?(fields, &field_translated?(resource, lang, &1)) do
      locked_stamp(resource, lang, fields)
    else
      {:error, :no_translation}
    end
  end

  @doc """
  "Reset baseline" (design source §4.4): deletes the stored fingerprints
  of `fields` (a field name or a list of them) for `lang`, WITHOUT
  touching the translation itself or calling the AI. A field with no
  stored fingerprint is left alone (no-op for that field). The pair drops
  to `:unknown` for each reset field until the next successful write —
  the sweep never auto-picks up `:unknown`, so a forced re-translate stays
  a deliberate, visible operator action rather than a sweep-driven loop.
  """
  @spec reset_baseline(struct(), String.t(), String.t() | [String.t()]) ::
          {:ok, struct()} | {:error, term()}
  def reset_baseline(resource, lang, fields) do
    locked_reset(resource, lang, List.wrap(fields))
  end

  defp locked_stamp(%schema{uuid: uuid}, lang, fields) do
    repo().transaction(fn ->
      query = where(schema, [r], r.uuid == ^uuid) |> lock("FOR UPDATE")

      case repo().one(query) do
        nil -> repo().rollback(:resource_not_found)
        fresh -> apply_stamp(fresh, lang, resolve_stamp_fields(fresh, lang, fields))
      end
    end)
  end

  defp resolve_stamp_fields(fresh, lang, :all) do
    fresh
    |> current_source_fields()
    |> Map.keys()
    |> Enum.filter(&field_translated?(fresh, lang, &1))
  end

  defp resolve_stamp_fields(_fresh, _lang, fields), do: fields

  defp apply_stamp(fresh, lang, fields) do
    current = current_source_fields(fresh)
    hashes = field_fingerprints(current)

    new_entries =
      for f <- fields, Map.has_key?(current, f), into: %{}, do: {f, Map.fetch!(hashes, f)}

    write_fingerprint_map(
      fresh,
      lang,
      Map.merge(stored_fingerprint_map(fresh, lang), new_entries)
    )
  end

  defp locked_reset(%schema{uuid: uuid}, lang, fields) do
    repo().transaction(fn ->
      query = where(schema, [r], r.uuid == ^uuid) |> lock("FOR UPDATE")

      case repo().one(query) do
        nil -> repo().rollback(:resource_not_found)
        fresh -> apply_reset(fresh, lang, fields)
      end
    end)
  end

  defp apply_reset(fresh, lang, fields) do
    write_fingerprint_map(fresh, lang, Map.drop(stored_fingerprint_map(fresh, lang), fields))
  end

  # Persists `field_map` (the WHOLE per-field fingerprint map for `lang`,
  # already merged/dropped by the caller) back onto `fresh`, dropping
  # empty containers so a fully-reset resource doesn't accumulate `%{}`
  # litter under `_translation_fingerprints`.
  defp write_fingerprint_map(fresh, lang, field_map) do
    {holder, fp_key} = fingerprint_location(fresh)
    container = Map.get(fresh, holder) || %{}
    by_lang = Map.get(container, fp_key, %{})

    by_lang =
      if map_size(field_map) == 0,
        do: Map.delete(by_lang, lang),
        else: Map.put(by_lang, lang, field_map)

    new_container =
      if map_size(by_lang) == 0,
        do: Map.delete(container, fp_key),
        else: Map.put(container, fp_key, by_lang)

    case fresh |> Ecto.Changeset.change(%{holder => new_container}) |> repo().update() do
      {:ok, updated} -> updated
      {:error, reason} -> repo().rollback(reason)
    end
  end

  defp fingerprint_location(%Item{}), do: {:data, "_translation_fingerprints"}
  defp fingerprint_location(%Category{}), do: {:data, "_translation_fingerprints"}
  defp fingerprint_location(%Entities{}), do: {:settings, "translation_fingerprints"}
  defp fingerprint_location(%EntityData{}), do: {:metadata, "translation_fingerprints"}

  defp translated?(%Item{data: data}, lang), do: any_override_present?(data, lang)
  defp translated?(%Category{data: data}, lang), do: any_override_present?(data, lang)

  defp translated?(%Entities{} = set, lang) do
    set |> Entities.get_entity_translations() |> Map.get(lang) |> is_map()
  end

  defp translated?(%EntityData{} = value, lang) do
    case Multilang.get_raw_language_data(value.data, lang) do
      %{"_title" => title} when is_binary(title) -> String.trim(title) != ""
      _ -> false
    end
  end

  defp any_override_present?(data, lang) do
    raw = Multilang.get_raw_language_data(data, lang)

    Enum.any?(@override_fields, fn field ->
      case Map.get(raw, "_" <> field) do
        value when is_binary(value) -> String.trim(value) != ""
        _ -> false
      end
    end)
  end

  @spec field_translated?(struct(), String.t(), String.t()) :: boolean()
  defp field_translated?(resource, lang, field),
    do: not is_nil(field_translated_value(resource, lang, field))

  # The resource's CURRENT translated value for one engine field name, or
  # `nil` when there is none. Mirrors `translated?/2`'s per-type storage
  # knowledge, but for one field instead of "any of them".
  defp field_translated_value(%Item{data: data}, lang, field),
    do: override_value(data, lang, field)

  defp field_translated_value(%Category{data: data}, lang, field),
    do: override_value(data, lang, field)

  defp field_translated_value(%Entities{} = set, lang, "label") do
    case set |> Entities.get_entity_translations() |> Map.get(lang) do
      %{"display_name" => v} when is_binary(v) -> nonblank(v)
      _ -> nil
    end
  end

  defp field_translated_value(%Entities{}, _lang, _field), do: nil

  defp field_translated_value(%EntityData{} = value, lang, "title") do
    case Multilang.get_raw_language_data(value.data, lang) do
      %{"_title" => v} when is_binary(v) -> nonblank(v)
      _ -> nil
    end
  end

  defp field_translated_value(%EntityData{}, _lang, _field), do: nil

  defp override_value(data, lang, field) do
    data |> Multilang.get_raw_language_data(lang) |> Map.get("_" <> field) |> nonblank_binary()
  end

  defp nonblank_binary(v) when is_binary(v), do: nonblank(v)
  defp nonblank_binary(_v), do: nil

  defp nonblank(v), do: if(String.trim(v) == "", do: nil, else: v)

  # ── Fingerprint storage reads ─────────────────────────────────────

  @doc """
  The WHOLE per-field fingerprint map stored for `resource`/`lang`
  (`%{field => hash}`), or `%{}` if there is none. A legacy single-hash
  string at that key (see moduledoc) is treated as `%{}` — absent, not a
  match for any field.
  """
  @spec stored_fingerprint_map(struct(), String.t()) :: %{String.t() => String.t()}
  def stored_fingerprint_map(resource, lang) do
    {holder, fp_key} = fingerprint_location(resource)

    case get_in(Map.get(resource, holder) || %{}, [fp_key, lang]) do
      m when is_map(m) -> m
      _ -> %{}
    end
  end

  defp stored_field_fingerprint(resource, lang, field) do
    resource |> stored_fingerprint_map(lang) |> Map.get(field)
  end

  # PURE variants only — this is a read-only path (`state/2`/`list/2`), not
  # the read step of a translation job. `AITranslatable.source_fields/2` /
  # `Sets.source_fields/2` (the `@impl` callbacks the AI engine calls) also
  # stash the fingerprint in the CALLING process's dictionary; going
  # through them here would silently corrupt whatever `put_translation/4`
  # later reads back for an actual job sharing this process (e.g. a
  # LiveView computing a row's state, then dispatching a translation).
  defp current_source_fields(%Item{} = r),
    do: AITranslatable.source_fields_pure(r, source_lang())

  defp current_source_fields(%Category{} = r),
    do: AITranslatable.source_fields_pure(r, source_lang())

  defp current_source_fields(%Entities{} = r), do: Sets.source_fields_pure(r, source_lang())
  defp current_source_fields(%EntityData{} = r), do: Sets.source_fields_pure(r, source_lang())

  # ── Listing ───────────────────────────────────────────────────────

  @doc """
  Lists (resource, language) rows for `type`, one per language in
  `opts[:langs]`.

  ## Options

    * `:langs` — target languages to report on (default `[]` — an empty
      list yields no rows; callers pick the languages that matter to them,
      e.g. the enabled non-default set or a single language filter)
    * `:state` — one state atom or a list of them; unfiltered when absent
    * `:catalogue_uuid` — scope `:item`/`:category` rows to one catalogue
      (ignored for `:set_label`/`:set_value`, which are catalogue-wide)
    * `:page` / `:per_page` — 1-indexed pagination (defaults `1` / `50`)
  """
  @spec list(:item | :category | :set_label | :set_value, keyword()) :: [map()]
  def list(type, opts \\ []) do
    langs = Keyword.get(opts, :langs, [])
    states = opts |> Keyword.get(:state) |> List.wrap()
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 50)

    type
    |> resources_for(Keyword.get(opts, :catalogue_uuid))
    |> Enum.flat_map(&rows_for(type, &1, langs))
    |> Enum.sort_by(&{&1.name, &1.lang})
    |> filter_states(states)
    |> Enum.drop((page - 1) * per_page)
    |> Enum.take(per_page)
  end

  defp resources_for(:item, nil), do: Catalogue.list_items()

  defp resources_for(:item, catalogue_uuid),
    do: Catalogue.list_items_for_catalogue(catalogue_uuid)

  defp resources_for(:category, nil),
    do: repo().all(from(c in Category, where: c.status != "deleted"))

  defp resources_for(:category, catalogue_uuid),
    do: Catalogue.list_categories_for_catalogue(catalogue_uuid)

  defp resources_for(:set_label, _catalogue_uuid), do: AttributeSets.list_sets()

  # One batched query for every set's values (`list_values_for/2`, the
  # same call the Attributes tab's preview already uses to avoid N+1),
  # not `list_values/1` per set — this runs on every page render, every
  # translation-completed broadcast, and every sweep tick.
  defp resources_for(:set_value, _catalogue_uuid) do
    sets = AttributeSets.list_sets()
    values_by_set = sets |> Enum.map(& &1.uuid) |> AttributeSets.list_values_for()
    sets |> Enum.flat_map(&Map.get(values_by_set, &1.uuid, []))
  end

  defp rows_for(type, resource, langs) do
    Enum.map(langs, fn lang ->
      %{
        type: type,
        uuid: resource.uuid,
        name: resource_name(resource),
        lang: lang,
        state: state(resource, lang),
        updated_at: resource_updated_at(resource)
      }
    end)
  end

  defp resource_name(%Item{name: name}), do: name
  defp resource_name(%Category{name: name}), do: name
  defp resource_name(%Entities{display_name: name}), do: name
  defp resource_name(%EntityData{title: title}), do: title

  defp resource_updated_at(%Item{updated_at: t}), do: t
  defp resource_updated_at(%Category{updated_at: t}), do: t
  defp resource_updated_at(%Entities{date_updated: t}), do: t
  defp resource_updated_at(%EntityData{date_updated: t}), do: t

  defp filter_states(rows, []), do: rows
  defp filter_states(rows, states), do: Enum.filter(rows, &(&1.state in states))
end
