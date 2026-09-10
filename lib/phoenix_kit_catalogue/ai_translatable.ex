defmodule PhoenixKitCatalogue.AITranslatable do
  @moduledoc """
  `PhoenixKitAI.Translatable` adapter for catalogue resources —
  the small per-module hook into PhoenixKitAI's generic AI-translation pipeline.

  Serves three resource types (`"catalogue"`, `"catalogue_category"`,
  `"catalogue_item"`). The catalogue translates `name` + `description`;
  items and categories additionally carry `summary`, `seo_title`, and
  `seo_description` — multilang-only fields with no schema column. Source
  text and translations live in the shared `data` JSONB via
  `PhoenixKit.Utils.Multilang` (primary value as base, per-language
  overrides), so AI-filled languages round-trip through the multilang form
  unchanged.

  ## Field-key convention

  The multilang form stores each per-language override under an
  **underscore-prefixed** key (`data[lang]["_name"]`, `data[lang]["_description"]`
  — see `PhoenixKitWeb.Components.MultilangForm`). The AI engine, however,
  speaks plain field names (`"name"` / `"description"`) for prompt
  variables + `---MARKER---` parsing. So `source_fields/2` returns plain
  keys (engine contract) and `put_translation/4` re-prefixes them to the
  `_`-form before writing, so the secondary-language inputs actually render
  the result.

  Registered via the host module's `ai_translatables` callback (see
  `PhoenixKitCatalogue`). The enqueue, the AI call, the translation-status
  broadcasts, retry policy, and the audit log all live in core.

  ## Catalogue fan-out

  A finished translation changes what the catalogue's own list/detail
  pages render (localized names, attribute labels), so `put_translation/4`
  emits the matching `Catalogue.PubSub` event — `:catalogue` / `:category`
  / `:item` for the three resources, `:attribute_group` (the owning group)
  for group / attribute / value rows — once its `FOR UPDATE` transaction
  has committed. Core's `:ai_translation` status events only reach the
  form that asked; this is what keeps every other open tab current.
  """

  @behaviour PhoenixKitAI.Translatable

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.PubSub
  alias PhoenixKitCatalogue.Catalogue.Slugs
  alias PhoenixKitCatalogue.Schemas.{Attribute, AttributeGroup, AttributeValue, Category, Item}
  alias PhoenixKitCatalogue.Schemas.Catalogue, as: CatalogueSchema
  alias PhoenixKitCatalogue.TranslationStatus

  # Engine-facing field names (plain strings) ↔ their schema columns, per
  # resource shape. The AI engine speaks the string keys; `column_value/2`
  # maps back to the atom column. Attribute values translate their `value`
  # display text; groups and attributes only a `name`. (The attribute rows
  # have no in-form AI button yet — registration serves the programmatic /
  # bulk enqueue paths.)
  #
  # Items and categories additionally carry `summary`/`seo_title`/
  # `seo_description` — multilang-only fields with no schema column (hence
  # the `_`-prefixed atom placeholders below, never resolved by
  # `Map.get/2` since no struct has such a field). `field_value/3` only
  # falls through to `column_value/2` for them when the primary-language
  # `data` subtree has no override either, in which case there genuinely
  # is no source text and `column_value/2` must say so via `nil`.
  @item_and_category_fields %{
    "name" => :name,
    "description" => :description,
    "summary" => :_summary,
    "seo_title" => :_seo_title,
    "seo_description" => :_seo_description
  }

  # Every plain field key this adapter round-trips through `data` (the
  # union of all `field_columns/1` shapes above) plus its multilang
  # `_`-prefixed override form — the only keys legacy flat `data` could
  # legitimately hold as field content. Used by `force_put_language/3` to
  # tell field content apart from unrelated top-level namespaces (an
  # ecommerce sync's `data["ecommerce"]`, extension metadata, …) sharing
  # the same JSONB column.
  @legacy_field_names ~w(name description summary seo_title seo_description value)
  @legacy_field_keys @legacy_field_names ++ Enum.map(@legacy_field_names, &("_" <> &1))

  defp field_columns(%AttributeValue{}), do: %{"value" => :value}
  defp field_columns(%Attribute{}), do: %{"name" => :name}
  defp field_columns(%AttributeGroup{}), do: %{"name" => :name}
  defp field_columns(%Item{}), do: @item_and_category_fields
  defp field_columns(%Category{}), do: @item_and_category_fields
  defp field_columns(_resource), do: %{"name" => :name, "description" => :description}

  @impl true
  def fetch("catalogue", uuid), do: wrap(Catalogue.get_catalogue(uuid))
  def fetch("catalogue_category", uuid), do: wrap(Catalogue.get_category(uuid))
  def fetch("catalogue_item", uuid), do: wrap(Catalogue.get_item(uuid))
  def fetch("catalogue_attribute_group", uuid), do: wrap(Catalogue.get_attribute_group(uuid))
  def fetch("catalogue_attribute", uuid), do: wrap(Catalogue.get_attribute(uuid))
  def fetch("catalogue_attribute_value", uuid), do: wrap(Catalogue.get_attribute_value(uuid))
  def fetch(other, _uuid), do: {:error, {:unknown_resource_type, other}}

  defp wrap(nil), do: {:error, :resource_not_found}
  defp wrap(%_{} = resource), do: {:ok, resource}

  @impl true
  def source_fields(resource, source_lang) do
    fields = source_fields_pure(resource, source_lang)
    maybe_capture_fingerprint(resource, fields)
    fields
  end

  @doc """
  Same extraction as `source_fields/2`, WITHOUT the process-dictionary
  capture side effect — for callers that read the source without being
  the read step of an actual translation job (`TranslationStatus.state/2`/
  `list/2`, and the write-time fingerprint fallback below). Calling
  `source_fields/2` from either would stash a fingerprint keyed by
  `resource_type`/`uuid` in the CALLING process, clobbering (or being
  clobbered by) whatever `put_translation/4` later reads back via
  `TranslationStatus.captured_fingerprint/2` for an unrelated job running
  in the same process — see `TranslationStatus`'s moduledoc.
  """
  @spec source_fields_pure(struct(), String.t()) :: map()
  def source_fields_pure(resource, source_lang) do
    lang_data = Multilang.get_language_data(resource.data || %{}, source_lang)

    for field <- Map.keys(field_columns(resource)),
        value = field_value(resource, field, lang_data),
        is_binary(value) and String.trim(value) != "",
        into: %{},
        do: {field, value}
  end

  # Only item/category carry a freshness model (`TranslationStatus`) — the
  # catalogue and attribute resources have no fingerprint storage key.
  defp maybe_capture_fingerprint(%Item{uuid: uuid}, fields),
    do: TranslationStatus.capture_fingerprint("catalogue_item", uuid, fields)

  defp maybe_capture_fingerprint(%Category{uuid: uuid}, fields),
    do: TranslationStatus.capture_fingerprint("catalogue_category", uuid, fields)

  defp maybe_capture_fingerprint(_resource, _fields), do: :ok

  # Prefer the multilang `_`-prefixed override, then a legacy plain key,
  # then the resource's primary column (rows created without multilang data
  # only have columns).
  defp field_value(resource, field, lang_data) do
    cond do
      nonempty(Map.get(lang_data, "_" <> field)) -> Map.get(lang_data, "_" <> field)
      nonempty(Map.get(lang_data, field)) -> Map.get(lang_data, field)
      true -> column_value(resource, field)
    end
  end

  defp nonempty(v) when is_binary(v), do: String.trim(v) != ""
  defp nonempty(_), do: false

  # The multilang-only fields have no schema column to fall back to — an
  # absent override means there is no source text for them at all.
  defp column_value(_resource, field)
       when field in ["summary", "seo_title", "seo_description"],
       do: nil

  defp column_value(resource, field) do
    Map.get(resource, Map.fetch!(field_columns(resource), field))
  end

  @impl true
  def put_translation(resource, target_lang, fields, opts) do
    fields = sanitize_fields(fields)
    repo = RepoHelper.repo()
    {schema, update_fn} = persist_target(resource)
    uuid = resource.uuid
    # `broadcast: false` — the write happens inside this FOR UPDATE
    # transaction, so suppress the updater's own resource broadcast (it would
    # fire pre-commit). The catalogue event goes out below, after commit.
    opts = Keyword.put(opts, :broadcast, false)

    # Re-read the row FOR UPDATE inside the transaction so concurrent
    # per-language jobs (enqueue_all_missing) serialize on the row lock and
    # each merges against the latest committed `data` — otherwise a job
    # merging into its stale pre-AI snapshot would drop sibling languages.
    repo.transaction(fn ->
      query = schema |> where([r], r.uuid == ^uuid) |> lock("FOR UPDATE")

      case repo.one(query) do
        nil -> repo.rollback(:resource_not_found)
        fresh -> merge_translation!(repo, fresh, target_lang, fields, update_fn, opts)
      end
    end)
    |> finish_write()
  end

  # `merge_translation!/6` reports which of the two things happened inside
  # the transaction: `{:written, updated}` when at least one field was
  # actually persisted (broadcast fires, matching the pre-narrowing
  # behaviour), or `{:skipped, fresh}` when EVERY field was left alone by
  # the per-field write-narrowing below — a "success without a write"
  # (design source §4.4): no DB write happened, so no catalogue broadcast
  # either.
  defp finish_write({:ok, {:written, updated}}) do
    broadcast_translated(updated)
    {:ok, updated}
  end

  defp finish_write({:ok, {:skipped, fresh}}), do: {:ok, fresh}
  defp finish_write({:error, _reason} = error), do: error

  @doc """
  Strips a model's leaked "note" aside from a translated field value.

  Despite the prompt's explicit "output only the markers, no commentary"
  rule (`PhoenixKitCatalogue.AIPrompt`), a model asked to translate a
  resource that only has a `name` (no description/summary/SEO) has been
  observed to append an aside straight onto the translated marker's value
  — as its own paragraph (`"\\n\\n(Note: I've omitted the fields with
  placeholder values ... as per the rules...)"`, `"\\n\\nNotes:\\n1. The
  \`Label\` field ..."`, `"\\n\\nNote that the \\"Label\\" field ..."`) or as
  a bare parenthetical tacked onto the same line (`"Cartes (Note: skipped
  description as instructed)"`) — which then feeds the slug rule
  (`generate_slug/5`) and produces a slug with a trailing "-note-i-ve-
  omitted" segment. This is a defensive backstop for when the prompt
  alone isn't obeyed: cuts everything from the start of the first such
  aside onward and trims the result.

  Narrow by construction, though not airtight: two of its own trigger
  words ("field", "placeholder") can appear in an ordinary product aside
  that happens to open with "Note:" (a sizing disclaimer mentioning a
  "placeholder" dimension, a personalization note about a "name field") —
  a residual false-positive this design accepts because those two bare
  words are also how three of the real leaked notes below are caught, and
  tightening them further (e.g. requiring nearby punctuation) loses that
  detection. Locating the
  candidate aside is only half the check: it must start its own line
  (optionally wrapped in a leading paren) or open a bare `(Note:` anywhere
  on the line — never "note" appearing mid-sentence (`"Please note: sizes
  vary"`, `"Veuillez noter : ..."`). But an anchor alone isn't enough — a
  genuine product aside can start the exact same way (`"Note: hand wash
  only."`, `"(Note: 100% merino wool)."`, `"Note: use \`cast iron\` pan for
  best results."`, `"Note: fits sizes {{S,M,L}} as shown."`, `"Note:
  available in \"Blue\" and \"Red\" glazes."`), and ordinary product copy
  can contain backticks, `{{...}}`, or a quoted capitalized word for its
  own reasons — none of those are reliable evidence of a leaked note by
  themselves. So the candidate is only cut when its text names the
  translation machinery in plain words — a `"field"`, a `"placeholder"`,
  a `"template slot"` — or uses one of the model's stock phrases for
  skipping one (`"was skipped"`, `"no actual value"`, `"as per the
  rules"`, `"as instructed"`, …). Lacking any of those, the value is left
  untouched. That content check only inspects the anchored aside's own
  paragraph (up to the next blank line or the end of the value) — a
  trigger word in some later, unrelated paragraph never reaches back to
  implicate an earlier, legitimate "Note:" aside.
  """
  # Anchors the start of a candidate leaked aside, the same way as before:
  #   1. a "Note"/"Notes" paragraph starting its own line, optionally
  #      wrapped in a leading "(" — `\n\n(Note: ...)`, `\n\nNotes:\n1. ...`,
  #      `\nNote that the ... field ...`;
  #   2. a bare `(Note:` opened anywhere on the same line — `Cartes
  #      (Note: skipped description as instructed)`.
  # Requiring the paragraph break (or the literal `(Note:` open-paren) as
  # the anchor is what keeps this from firing on "Please note: ..."
  # running text or an unrelated parenthetical/enumerated paragraph.
  @note_anchor_regex ~r/\n\s*\(?\s*Notes?\b[:\-–]?\s|\(Note:/i

  # Whether the candidate aside actually talks about the translation
  # process — the tell that separates a leaked model note from legitimate
  # product copy that merely happens to start with "Note:". Deliberately
  # does NOT trigger on backticks, quoted capitalized words, or `{{...}}`
  # alone — ordinary product copy uses all three (a quoted color name, a
  # backtick-quoted material, a `{{...}}` size chart) with no relation to
  # the translation pipeline. Instead requires plain-word evidence: a
  # named "field"/"placeholder"/"template slot", or one of the model's
  # stock phrases for explaining why it skipped one. "is translated" /
  # "not translated" alone are deliberately excluded — they read just as
  # naturally as marketing copy about the listing itself.
  @note_content_regex ~r/\b(?:field|placeholder|template\s+slot|was\s+skipped|
    is\s+skipped|no\s+actual\s+value|not\s+a\s+real\s+value|as\s+per\s+the\s+rules|
    as\s+instructed)\b/xi

  @spec strip_ai_note(String.t()) :: String.t()
  def strip_ai_note(value) when is_binary(value) do
    case Regex.run(@note_anchor_regex, value, return: :index) do
      [{start, len} | _] ->
        after_anchor = start + len
        search_from = binary_part(value, after_anchor, byte_size(value) - after_anchor)

        # Only the anchored aside's own paragraph is evidence — a trigger
        # word in a later, unrelated paragraph must not retroactively
        # implicate an earlier legitimate "Note:" aside and cut everything
        # (including that later paragraph) off the end of the value.
        aside_end =
          case :binary.match(search_from, "\n\n") do
            {idx, _len} -> after_anchor + idx
            :nomatch -> byte_size(value)
          end

        aside = binary_part(value, start, aside_end - start)

        if Regex.match?(@note_content_regex, aside) do
          binary_part(value, 0, start)
        else
          value
        end

      nil ->
        value
    end
    |> String.trim()
  end

  def strip_ai_note(value), do: value

  defp sanitize_fields(fields) when is_map(fields) do
    Map.new(fields, fn {k, v} -> {k, strip_ai_note(v)} end)
  end

  defp broadcast_translated(%CatalogueSchema{uuid: uuid}),
    do: PubSub.broadcast(:catalogue, uuid, uuid)

  defp broadcast_translated(%Category{uuid: uuid, catalogue_uuid: parent}),
    do: PubSub.broadcast(:category, uuid, parent)

  defp broadcast_translated(%Item{uuid: uuid, catalogue_uuid: parent}),
    do: PubSub.broadcast(:item, uuid, parent)

  defp broadcast_translated(%AttributeGroup{uuid: uuid}),
    do: PubSub.broadcast(:attribute_group, uuid)

  defp broadcast_translated(%Attribute{group_uuid: group_uuid}),
    do: PubSub.broadcast(:attribute_group, group_uuid)

  # A value knows only its attribute; the group is one indexed read away.
  defp broadcast_translated(%AttributeValue{attribute_uuid: attribute_uuid}) do
    case Catalogue.get_attribute(attribute_uuid) do
      %Attribute{group_uuid: group_uuid} -> PubSub.broadcast(:attribute_group, group_uuid)
      _ -> :ok
    end
  end

  # Item/category carry a `TranslationStatus` freshness model — merge
  # through the per-field write-narrowing path. Every other resource type
  # this adapter serves (the catalogue root, attribute group/attribute/
  # value) has no fingerprint storage key (`TranslationStatus.
  # fingerprint_location/1` has no clause for them) and no freshness
  # tracking at all, so they keep the unconditional full-field write this
  # adapter has always done for them.
  defp merge_translation!(repo, %Item{} = fresh, target_lang, fields, update_fn, opts),
    do: merge_tracked_translation!(repo, fresh, target_lang, fields, update_fn, opts)

  defp merge_translation!(repo, %Category{} = fresh, target_lang, fields, update_fn, opts),
    do: merge_tracked_translation!(repo, fresh, target_lang, fields, update_fn, opts)

  defp merge_translation!(repo, fresh, target_lang, fields, update_fn, opts) do
    lang_fields = Map.new(fields, fn {k, v} -> {"_" <> k, v} end)
    new_data = fresh.data |> Kernel.||(%{}) |> force_put_language(target_lang, lang_fields)

    case update_fn.(fresh, %{data: new_data}, opts) do
      {:ok, updated} -> {:written, updated}
      {:error, reason} -> repo.rollback(reason)
    end
  end

  # Per-field write narrowing (design source §4.4, §12.2): decide, field by
  # field, whether the AI's answer actually needs to land. Only fields
  # whose `TranslationStatus.field_state/3` — computed against THIS
  # freshly-locked row — is `:missing`, `:unknown`, or `:stale` get
  # written; a `:fresh` field (translation already matches the current
  # source) is left untouched, so a hand-corrected translation survives a
  # re-translate that only changed a sibling field. A field with no
  # current source (`field_state/3` returns `nil`) is excluded the same
  # way. When every field is left alone, this is a "success without a
  # write" (no DB write, no broadcast — see `finish_write/1`).
  defp merge_tracked_translation!(repo, fresh, target_lang, fields, update_fn, opts) do
    written = writable_fields(fresh, target_lang, fields)

    if map_size(written) == 0 do
      {:skipped, fresh}
    else
      lang_fields = Map.new(written, fn {k, v} -> {"_" <> k, v} end)

      new_data =
        fresh.data
        |> Kernel.||(%{})
        |> force_put_language(target_lang, lang_fields)
        |> put_field_fingerprints(fresh, target_lang, written)

      attrs = maybe_generate_slug(%{data: new_data}, fresh, new_data, target_lang)

      case update_fn.(fresh, attrs, opts) do
        {:ok, updated} -> {:written, updated}
        {:error, reason} -> repo.rollback(reason)
      end
    end
  end

  defp writable_fields(fresh, target_lang, fields) do
    Map.filter(fields, fn {field, _value} ->
      TranslationStatus.field_state(fresh, target_lang, field) in [:missing, :unknown, :stale]
    end)
  end

  # Slugs are write-once (see `Slugs`'s moduledoc): a translation job
  # fills in a still-blank slug for its target language from the
  # translated name, but never touches a language that already has one —
  # a retranslation must not move a URL that may already be published or
  # bookmarked. The name comes from the POST-MERGE `new_data`, not the raw
  # AI response — when `name` itself was narrowed away (skipped as
  # already-fresh), the slug step still has the already-stored translated
  # title to work from (design source §4.4).
  defp maybe_generate_slug(attrs, %Item{} = fresh, new_data, target_lang),
    do: generate_slug(attrs, fresh, new_data, target_lang, &Catalogue.get_item_by_slug/2)

  defp maybe_generate_slug(attrs, %Category{} = fresh, new_data, target_lang),
    do: generate_slug(attrs, fresh, new_data, target_lang, &Catalogue.get_category_by_slug/2)

  defp generate_slug(attrs, fresh, new_data, target_lang, lookup_fun) do
    slug_map = fresh.slug || %{}
    name = new_data |> Multilang.get_raw_language_data(target_lang) |> Map.get("_name")

    if nonempty(name) and not nonempty(Map.get(slug_map, target_lang)) do
      default_slug = Slugs.default_lang_slug(fresh.data || %{}, slug_map)
      base = Slugs.from_title(name, target_lang, default_slug: default_slug)
      slug = unique_slug(base, target_lang, lookup_fun)
      Map.put(attrs, :slug, Map.put(slug_map, target_lang, slug))
    else
      attrs
    end
  end

  # Probes the global slug projection (`get_item_by_slug/2` /
  # `get_category_by_slug/2`) for `base` in `target_lang`, retrying with a
  # `-2`, `-3`, … suffix on a collision with another resource's slug. A
  # genuine race (two jobs landing on the same free slug at once) still
  # surfaces as the DB's own `unique_constraint` changeset error on save —
  # this is a proactive check, not a lock.
  defp unique_slug(base, target_lang, lookup_fun) do
    Stream.iterate(1, &(&1 + 1))
    |> Enum.reduce_while(nil, fn n, _acc ->
      candidate = if n == 1, do: base, else: "#{base}-#{n}"

      case lookup_fun.(candidate, target_lang) do
        {:error, :not_found} -> {:halt, candidate}
        _found -> {:cont, candidate}
      end
    end)
  end

  # Records the per-field freshness fingerprints alongside the
  # translation, in the SAME write: for each WRITTEN field, the fingerprint
  # `source_fields/2` captured for THIS job (`TranslationStatus.
  # captured_fingerprint/2`), falling back to hashing `fresh`'s own current
  # source for that field when nothing was captured — a direct
  # `put_translation/4` call that skipped `source_fields/2` (a test, a CLI
  # write). Fields NOT in `written_fields` (narrowed away as already-fresh)
  # keep whatever fingerprint was already stored for them — this merge
  # never drops a sibling field's fingerprint. See `TranslationStatus` for
  # the storage-key convention and the legacy single-hash format it also
  # has to tolerate on read.
  defp put_field_fingerprints(new_data, fresh, target_lang, written_fields) do
    resource_type = resource_type_for(fresh)
    captured = TranslationStatus.captured_fingerprint(resource_type, fresh.uuid) || %{}

    current_hashes =
      fresh
      |> source_fields_pure(Multilang.primary_language())
      |> TranslationStatus.field_fingerprints()

    new_entries =
      for {field, _v} <- written_fields, into: %{} do
        {field, Map.get(captured, field) || Map.fetch!(current_hashes, field)}
      end

    merged = Map.merge(TranslationStatus.stored_fingerprint_map(fresh, target_lang), new_entries)

    Map.update(
      new_data,
      "_translation_fingerprints",
      %{target_lang => merged},
      &Map.put(&1, target_lang, merged)
    )
  end

  defp resource_type_for(%Item{}), do: "catalogue_item"
  defp resource_type_for(%Category{}), do: "catalogue_category"

  @doc """
  Store a secondary language's values **verbatim**, like
  `PhoenixKit.Utils.Multilang.put_language_data/3` but WITHOUT dropping
  fields that happen to equal the primary.

  The multilang form normally keeps only the diff-from-primary as an
  override. For AI translation that's wrong: a result that comes back
  identical to the source (a product code, text already in the target
  language) would store nothing, leaving the field blank — the user reads
  that as "translation failed", and the language keeps showing as missing.
  Force-storing populates the field and keeps the missing-count honest.

  `full_field_data` is the already-`_`-prefixed map for `lang`.

  When `existing_data` is still flat (pre-multilang, no `_primary_language`
  marker), only the KNOWN translatable field keys (`@legacy_field_keys`,
  plain or `_`-prefixed — the legacy shape `field_value/3` already reads
  as a fallback) are nested under the primary-language subtree. Any other
  top-level key is left untouched at the top level. `data` on a
  category/item is shared with unrelated namespaces (an ecommerce sync's
  `data["ecommerce"]`, extension metadata, …); wholesale-nesting the
  entire map on the first-ever translation would silently move those
  foreign keys out from under the top-level readers that expect them
  there.
  """
  @spec force_put_language(map(), String.t(), map()) :: map()
  def force_put_language(existing_data, lang, full_field_data) do
    existing_data = existing_data || %{}
    multilang? = Multilang.multilang_data?(existing_data)

    primary =
      if multilang?,
        do: Map.get(existing_data, "_primary_language"),
        else: Multilang.primary_language()

    base =
      if multilang? do
        existing_data
      else
        {legacy_fields, foreign} = Map.split(existing_data, @legacy_field_keys)
        Map.merge(foreign, %{"_primary_language" => primary, primary => legacy_fields})
      end

    # Always MERGE into the lang subtree (never wholesale-replace) so other
    # keys in that language are preserved — important if `lang` ever resolves
    # to the primary subtree (e.g. an item whose embedded primary differs
    # from the global one).
    Map.put(base, lang, Map.merge(Map.get(base, lang, %{}), full_field_data))
  end

  defp persist_target(%CatalogueSchema{}), do: {CatalogueSchema, &Catalogue.update_catalogue/3}
  defp persist_target(%Category{}), do: {Category, &Catalogue.update_category/3}
  defp persist_target(%Item{}), do: {Item, &Catalogue.update_item/3}

  # Attribute resources persist through a bare changeset update — no
  # activity-log entry (core logs `ai.translation_added` for every
  # translation) and no PubSub from inside the FOR UPDATE transaction;
  # `tap_broadcast/1` announces the owning group after commit.
  defp persist_target(%AttributeGroup{}) do
    {AttributeGroup,
     fn fresh, attrs, _opts ->
       fresh |> AttributeGroup.changeset(attrs) |> RepoHelper.repo().update()
     end}
  end

  defp persist_target(%Attribute{}) do
    {Attribute,
     fn fresh, attrs, _opts ->
       fresh |> Attribute.update_changeset(attrs) |> RepoHelper.repo().update()
     end}
  end

  defp persist_target(%AttributeValue{}) do
    {AttributeValue,
     fn fresh, attrs, _opts ->
       fresh |> AttributeValue.update_changeset(attrs) |> RepoHelper.repo().update()
     end}
  end
end
