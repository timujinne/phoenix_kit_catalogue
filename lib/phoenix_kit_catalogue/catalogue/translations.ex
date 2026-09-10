defmodule PhoenixKitCatalogue.Catalogue.Translations do
  @moduledoc """
  Multilang `data` JSONB helpers — read merged language data from a
  record and write language-specific overrides through the entity's own
  update function.

  Public surface is re-exported from `PhoenixKitCatalogue.Catalogue`.

  ## Dialect matching in `translated_name/2` / `translated_description/2`

  Deciding whether a requested locale IS the record's own primary
  language (see `primary_locale?/2`) mirrors, base code for base code,
  the SAME lookup `Multilang.get_language_data/2` already does when
  reading the bucket (its private `language_entry/3`) — deliberately,
  not by accident: the two must never drift apart, or a dialect-loose
  caller (a bare base code from a downgraded Gettext locale, e.g.) would
  read the bucket while an exact caller reads the column, splitting one
  record's displayed name across two disagreeing code paths.

  That mirrored lookup carries one asymmetry inherited as-is from
  `language_entry/3`, not designed by this module: among every bucket
  sharing a requested base code, the PRIMARY bucket always wins the
  fallback, even when a distinct, more specific sibling of that same
  base also exists and the primary is no better a match than that
  sibling. E.g. primary `"en-US"`, siblings `"en-US"` and `"en-GB"` both
  present, requesting an unrelated third dialect `"en-CA"` (no bucket of
  its own) resolves to `"en-US"`, not `"en-GB"`. This is left as-is
  because mirroring the layer below — including its warts — is the
  entire point; inventing a "better" tiebreak here would just be a
  second, competing source of truth for what a locale resolves to.
  """

  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Utils.Multilang

  @doc """
  Gets translated field data for a record in a specific language.
  Returns merged data (primary language as base + overrides for the
  requested language).
  """
  @spec get_translation(map(), String.t()) :: map()
  def get_translation(record, lang_code) do
    Multilang.get_language_data(record.data || %{}, lang_code)
  end

  @doc """
  Updates the multilang `data` field for a record with language-specific
  field data. For primary language: stores ALL fields. For secondary
  languages: stores only overrides (differences from primary).

  `update_fn` is the entity's update function. It receives `(record, attrs)`
  for 2-arity or `(record, attrs, opts)` for 3-arity when activity-logging
  opts are provided.
  """
  @spec set_translation(map(), String.t(), map(), function(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def set_translation(record, lang_code, field_data, update_fn, opts \\ []) do
    new_data = Multilang.put_language_data(record.data || %{}, lang_code, field_data)

    if opts == [] do
      update_fn.(record, %{data: new_data})
    else
      update_fn.(record, %{data: new_data}, opts)
    end
  end

  @doc """
  The display name for `locale`: the locale's translation override
  (either the `"_name"` shape the shared multilang helper writes or the
  legacy bare `"name"`), falling back to the primary-language column.
  Safe on records without translations and on plain maps.

  When `locale` IS the record's own primary language, the column is
  read FIRST and the bucket is only a fallback for a blank column — a
  writer that legitimately updates only the column (e.g. the Shopify
  sync) must not be shadowed forever by a stale primary-language bucket
  entry. Every other locale is unchanged: bucket override first, then
  the column.
  """
  @spec translated_name(map() | nil, String.t() | nil) :: String.t() | nil
  def translated_name(nil, _locale), do: nil
  def translated_name(record, nil), do: Map.get(record, :name)

  def translated_name(record, locale) do
    translation = safe_translation(record, locale)

    if primary_locale?(record, locale) do
      presence(Map.get(record, :name)) ||
        presence(Map.get(translation, "_name")) ||
        presence(Map.get(translation, "name"))
    else
      presence(Map.get(translation, "_name")) ||
        presence(Map.get(translation, "name")) ||
        Map.get(record, :name)
    end
  end

  @doc "Same contract as `translated_name/2`, for `:description`."
  @spec translated_description(map() | nil, String.t() | nil) :: String.t() | nil
  def translated_description(nil, _locale), do: nil
  def translated_description(record, nil), do: Map.get(record, :description)

  def translated_description(record, locale) do
    translation = safe_translation(record, locale)

    if primary_locale?(record, locale) do
      presence(Map.get(record, :description)) ||
        presence(Map.get(translation, "_description")) ||
        presence(Map.get(translation, "description"))
    else
      presence(Map.get(translation, "_description")) ||
        presence(Map.get(translation, "description")) ||
        Map.get(record, :description)
    end
  end

  @doc """
  The SEO title override for `locale`, or `nil` when unset.

  Unlike `translated_name/2`, there is no DB-column fallback — `seo_title`
  only ever lives under the multilang `data` override (`"_seo_title"`),
  same storage shape as `_name`/`_description` but with no primary-column
  counterpart.
  """
  @spec translated_seo_title(map() | nil, String.t() | nil) :: String.t() | nil
  def translated_seo_title(nil, _locale), do: nil
  def translated_seo_title(_record, nil), do: nil

  def translated_seo_title(record, locale) do
    record |> safe_translation(locale) |> Map.get("_seo_title") |> presence()
  end

  @doc "Same contract as `translated_seo_title/2`, for `_seo_description`."
  @spec translated_seo_description(map() | nil, String.t() | nil) :: String.t() | nil
  def translated_seo_description(nil, _locale), do: nil
  def translated_seo_description(_record, nil), do: nil

  def translated_seo_description(record, locale) do
    record |> safe_translation(locale) |> Map.get("_seo_description") |> presence()
  end

  @doc """
  Replaces `:name` (and `:description` where present) on each record
  with the `locale`-resolved display text, so list/detail surfaces can
  render `record.name` untouched and still honor the viewer's locale.

  Resolve-early by design (the same shape as `resolved_group/2`): the
  alternative — threading a `locale` attr through every table/tile/cell
  component — spreads the concern across dozens of render sites.
  Records without a `:data` map (folders) pass through unchanged, as
  does everything when `locale` is nil. Struct identity is preserved
  (`%{record | ...}`), and mutations are unaffected: status/move/
  reorder writes never take `:name` from these list structs.
  """
  @spec localize(list(), String.t() | nil) :: list()
  def localize(records, locale) when is_list(records) do
    Enum.map(records, &localize_one(&1, locale))
  end

  @doc "Single-record `localize/2`."
  @spec localize_one(map() | nil, String.t() | nil) :: map() | nil
  def localize_one(nil, _locale), do: nil
  def localize_one(record, nil), do: record

  def localize_one(record, locale) do
    if is_map(record) and is_map(Map.get(record, :data)) do
      record
      |> maybe_put_localized(:name, translated_name(record, locale))
      |> maybe_put_localized(:description, translated_description(record, locale))
    else
      record
    end
  end

  defp maybe_put_localized(record, key, value) do
    if Map.has_key?(record, key) and is_binary(value) and value != "" do
      Map.put(record, key, value)
    else
      record
    end
  end

  defp safe_translation(record, locale) do
    get_translation(record, locale)
  rescue
    _ -> %{}
  end

  # `locale` resolves, through the SAME bucket lookup `get_translation/2`
  # would do, to the record's own primary-language bucket — not merely
  # "locale is the exact primary string". A caller can reach the primary
  # bucket via a bare base code ("en" when primary is "en-US") or via a
  # sibling dialect with no own entry, exactly as
  # `Multilang.get_language_data/2` does internally
  # (`deps/phoenix_kit/lib/phoenix_kit/utils/multilang.ex`, private
  # `language_entry/3`) — comparing `locale == primary` alone missed
  # those and let a stale bucket shadow a fresh column again for any
  # dialect-imprecise caller (e.g. a locale downgraded to a base code by
  # `PhoenixKitWeb.Users.Auth.put_gettext_locale/1`). `resolved_bucket_key/3`
  # below mirrors `language_entry/3` step for step, via the same
  # `DialectMapper.extract_base/1` it uses, so the two layers cannot
  # drift apart; a `nil` resolution (no entry anywhere for `locale`'s
  # language) is deliberately NOT treated as primary — that is the
  # "secondary locale, no override, falls back to the primary bucket"
  # case, which must keep reading the bucket first, unchanged from
  # before this module existed.
  defp primary_locale?(record, locale) when is_binary(locale) do
    primary = record_primary_language(record)
    data = record_data(record)

    if Multilang.multilang_data?(data) do
      resolved_bucket_key(data, locale, primary) == primary
    else
      # Flat, pre-multilang `data` (a legacy bare `"name"`/`"description"`
      # key, no override yet, or no `:data` at all) has no per-locale
      # buckets to resolve — `Multilang.get_language_data/2` itself
      # gates on the SAME `multilang_data?/1` check
      # (`deps/phoenix_kit/lib/phoenix_kit/utils/multilang.ex:81`) and
      # returns a flat map UNCHANGED for every locale, so
      # `resolved_bucket_key/3` would always land on `nil` here — never
      # `primary` — and this record would NEVER get the column-first
      # treatment, even when `locale` IS genuinely the primary language,
      # letting a stale flat `"name"` shadow a fresh column exactly like
      # before this module's fix existed. `multilang_data?/1` is already
      # safe on `nil` and non-map `data`, so no separate case is needed.
      locale == primary
    end
  end

  defp primary_locale?(_record, _locale), do: false

  # `data["_primary_language"]`, falling back to the system default when
  # the key is absent (same idiom as `AiTranslatable.Sets.merge_title/3`).
  # Never raises: `record_data/1` only reads `:data` off a map, and
  # `primary_from_data/1` only reads a string key off a map. A
  # non-`nil`, non-binary `_primary_language` (corrupt data) is NOT
  # normalized here — it is returned as-is, so `||` does not kick in and
  # every downstream `== primary` comparison simply never matches,
  # which quietly falls back to the pre-fix (bucket-first) branch rather
  # than raising.
  defp record_primary_language(record) do
    record |> record_data() |> primary_from_data() || Multilang.primary_language()
  end

  defp record_data(record) when is_map(record), do: Map.get(record, :data)
  defp record_data(_record), do: nil

  defp primary_from_data(data) when is_map(data), do: Map.get(data, "_primary_language")
  defp primary_from_data(_data), do: nil

  # Mirrors `PhoenixKit.Utils.Multilang`'s private `language_entry/3`
  # exactly: `locale`'s own literal bucket entry wins first, then its
  # base code's own literal entry, then — among every bucket sharing
  # that base — the PRIMARY entry if it shares the base (regardless of
  # whether OTHER siblings of that base also exist), else the
  # lexicographically first sibling. Returns the resolved key, or `nil`
  # when nothing matches at all.
  defp resolved_bucket_key(data, locale, primary) do
    if has_bucket?(data, locale) do
      locale
    else
      base_resolved_key(data, DialectMapper.extract_base(locale), primary)
    end
  end

  defp base_resolved_key(data, base, primary) do
    if has_bucket?(data, base) do
      base
    else
      same_base_key(data, base, primary)
    end
  end

  defp has_bucket?(data, key), do: match?(%{}, Map.get(data, key))

  defp same_base_key(data, base, primary) do
    same_base_keys =
      data
      |> Enum.filter(fn
        {key, %{}} when is_binary(key) and key != "_primary_language" ->
          DialectMapper.extract_base(key) == base

        _ ->
          false
      end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    cond do
      same_base_keys == [] -> nil
      is_binary(primary) and primary in same_base_keys -> primary
      true -> hd(same_base_keys)
    end
  end

  defp presence(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp presence(_), do: nil
end
