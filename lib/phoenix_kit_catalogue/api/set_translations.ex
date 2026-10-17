defmodule PhoenixKitCatalogue.API.SetTranslations do
  @moduledoc false
  # Tool `catalogue.set_translations`.
  #
  # Language buckets are top-level keys of `data` (`data["de-DE"]["_name"]`,
  # with `data["_primary_language"]`). Everything is written as leaf paths under
  # the row lock, never by wrapping the item's whole flat `data` under the
  # primary key, which is what `Multilang.put_language_data/3` does on a flat
  # item and would move `data["ecommerce"]` out from under the shop.

  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitCatalogue.API
  alias PhoenixKitCatalogue.API.Common
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.Slugs

  require Logger

  @tool "catalogue.set_translations"
  @max_languages 20
  # Fields whose text must not be blank: clearing is `null`.
  @text_fields ~w(name description seo_title seo_description slug)
  @bare_code ~r/\A[A-Za-z]{2,3}\z/
  @bucket_keys %{
    "name" => "_name",
    "description" => "_description",
    "seo_title" => "_seo_title",
    "seo_description" => "_seo_description"
  }
  # A flat `data` that still carries any of these is the legacy shape.
  @legacy_keys ~w(name description seo_title seo_description _name _description _seo_title _seo_description)

  @spec call(map(), map()) ::
          {:ok, map()} | {:preview, map(), String.t()} | {:error, atom(), String.t(), map()}
  def call(input, ctx) do
    with {:ok, catalogue} <- API.resolve_catalogue(input["catalogue_id"], writable: true) do
      entries = input["items"]

      resolutions =
        API.resolve_refs(Enum.map(entries, & &1["ref"]),
          kind: :item,
          catalogue_uuid: catalogue.uuid
        )

      plan = plan(Enum.zip(entries, resolutions))

      if ctx.dry_run?, do: preview(plan), else: execute(plan, ctx)
    end
  end

  # --- planning (reads only) ---------------------------------------------------------

  # `{:update, ref, item, update}`, `{:rejected, ref, message, context}` or
  # `{:resolution_error, ref, reason}`.
  defp plan(pairs) do
    enabled = Multilang.enabled_languages()

    {planned, _state} =
      Enum.map_reduce(pairs, %{seen: MapSet.new(), claimed: %{}}, fn {entry, {ref, resolution}},
                                                                     state ->
        plan_one(entry["translations"], ref, resolution, enabled, state)
      end)

    planned
  end

  defp plan_one(_translations, ref, {:error, reason}, _enabled, state),
    do: {{:resolution_error, ref, reason}, state}

  defp plan_one(translations, ref, {:ok, item}, enabled, state) do
    cond do
      MapSet.member?(state.seen, item.uuid) ->
        {rejected(ref, "ref", "The same item appears twice in this request."), state}

      map_size(translations) == 0 ->
        {rejected(ref, "translations", "must name at least one language"), state}

      map_size(translations) > @max_languages ->
        {rejected(ref, "translations", "may name at most #{@max_languages} languages"), state}

      true ->
        case build(item, translations, enabled, state.claimed) do
          {:ok, update, claimed} ->
            {{:update, ref, item, update},
             %{state | seen: MapSet.put(state.seen, item.uuid), claimed: claimed}}

          {:error, path, message, context} ->
            {rejected(ref, path, message, context), state}
        end
    end
  end

  defp rejected(ref, path, message, context \\ %{}) do
    {:rejected, ref, message,
     Map.merge(%{"errors" => [%{"path" => path, "message" => message}]}, context)}
  end

  defp build(item, translations, enabled, claimed) do
    data = item.data || %{}
    multilang? = Multilang.multilang_data?(data)
    primary = Map.get(data, "_primary_language") || Multilang.primary_language()

    with :ok <- check_shape(data, multilang?),
         {:ok, languages} <- resolve_languages(translations, enabled, primary) do
      assemble(item, languages, multilang?, primary, claimed)
    end
  end

  # Flat data with bare translatable keys is the legacy shape; this tool does
  # not reinterpret it (nesting it would move keys other writers read).
  defp check_shape(_data, true), do: :ok

  defp check_shape(data, false) do
    if Enum.any?(@legacy_keys, &Map.has_key?(data, &1)) do
      {:error, "translations",
       "The item's data still uses the legacy flat translation keys: open and save it once in the admin, then retry.",
       %{}}
    else
      :ok
    end
  end

  # -> {:ok, [{language, fields}]} (sorted by language) | {:error, path, message, context}
  defp resolve_languages(translations, enabled, primary) do
    translations
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn {given, fields}, {:ok, acc} ->
      path = "translations." <> given

      with {:ok, lang} <- resolve_language(given, enabled, path),
           :ok <- check_not_primary(lang, primary, path),
           :ok <- check_distinct(lang, acc, path),
           :ok <- check_fields(fields, path) do
        {:cont, {:ok, [{lang, trim_name(fields)} | acc]}}
      else
        {:error, _path, _message, _context} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  # A full code must be an enabled language as written; only a bare code ("de")
  # may stand for the one enabled language of that base ("de-DE").
  defp resolve_language(given, enabled, path) do
    cond do
      given in enabled ->
        {:ok, given}

      Regex.match?(@bare_code, given) ->
        resolve_bare_language(given, enabled, path)

      true ->
        {:error, path, "is not an enabled language", %{"allowed" => enabled}}
    end
  end

  defp resolve_bare_language(given, enabled, path) do
    base = DialectMapper.extract_base(given)

    case Enum.filter(enabled, &(DialectMapper.extract_base(&1) == base)) do
      [one] ->
        {:ok, one}

      [] ->
        {:error, path, "is not an enabled language", %{"allowed" => enabled}}

      several ->
        {:error, path, "matches several enabled languages; use the full code",
         %{"allowed" => several}}
    end
  end

  defp trim_name(%{"name" => name} = fields) when is_binary(name),
    do: %{fields | "name" => String.trim(name)}

  defp trim_name(fields), do: fields

  # Same conceptual language under a different precision ("en" / "en-US"). The
  # last test covers a stored primary language with a region next to a bare
  # enabled code; core does not enable bare codes today.
  defp check_not_primary(lang, primary, path) do
    if lang == primary or DialectMapper.extract_base(lang) == primary or
         lang == DialectMapper.extract_base(primary) do
      {:error, path, "is the item's primary language: change it with catalogue.update_products",
       %{}}
    else
      :ok
    end
  end

  defp check_distinct(lang, acc, path) do
    if List.keymember?(acc, lang, 0),
      do:
        {:error, path, "names a language that another key of this item already names (#{lang})",
         %{}},
      else: :ok
  end

  defp check_fields(fields, path) when map_size(fields) == 0,
    do: {:error, path, "must name at least one field", %{}}

  # A blank text would be stored as a value nothing treats as absent: clearing is `null`.
  defp check_fields(fields, path) do
    Enum.find_value(@text_fields, :ok, fn key ->
      with %{^key => text} when is_binary(text) <- fields,
           true <- Common.blank?(text) do
        {:error, path <> "." <> key, blank_message(key), %{}}
      else
        _fine -> nil
      end
    end)
  end

  defp blank_message("slug"), do: "must not be blank; send null to remove it"
  defp blank_message(_key), do: "must not be blank; send null to clear it"

  defp assemble(item, languages, multilang?, primary, claimed) do
    slugs = item.slug || %{}
    initial = %{data: %{}, paths: [], slugs: slugs, claimed: claimed}

    languages
    |> Enum.reduce_while({:ok, initial}, fn {lang, fields}, {:ok, acc} ->
      case translate(item, lang, fields, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _path, _message, _context} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, update_for(acc, slugs, multilang?, primary), acc.claimed}
      error -> error
    end
  end

  defp update_for(acc, slugs, multilang?, primary) do
    # Flat data becomes multilang only when a value is actually written: a clear
    # that finds nothing to clear leaves the item alone.
    {data, paths} =
      if multilang? or not writes_value?(acc.data),
        do: {acc.data, acc.paths},
        else:
          {Map.put(acc.data, "_primary_language", primary), [["_primary_language"] | acc.paths]}

    # The slug column is one map for all languages. Send only the languages this call
    # changed (added, changed or removed) as per-language deltas; `update_item/3` merges
    # them into the LOCKED row, so a slug another writer stored for a different language
    # since we read the item is not overwritten.
    slug_langs =
      for lang <- Enum.uniq(Map.keys(slugs) ++ Map.keys(acc.slugs)),
          Map.get(slugs, lang) != Map.get(acc.slugs, lang),
          do: lang

    attrs = if slug_langs == [], do: %{data: data}, else: %{data: data, slug: acc.slugs}

    %{
      attrs: attrs,
      row_opts: [
        skip_derive: true,
        data_owned_paths: paths,
        logged_data_paths: paths,
        slug_owned_langs: slug_langs
      ]
    }
  end

  defp writes_value?(data) do
    Enum.any?(data, fn {_lang, bucket} ->
      Enum.any?(bucket, fn {_key, value} -> value != nil end)
    end)
  end

  defp translate(item, lang, fields, acc) do
    values =
      for {key, stored} <- @bucket_keys, Map.has_key?(fields, key), do: {stored, fields[key]}

    paths = for {stored, _value} <- values, do: [lang, stored]
    data = if values == [], do: acc.data, else: Map.put(acc.data, lang, Map.new(values))

    with {:ok, slugs, claimed} <- slug_for(item, lang, fields, acc) do
      {:ok, %{acc | data: data, paths: acc.paths ++ paths, slugs: slugs, claimed: claimed}}
    end
  end

  # Explicit slug: normalised, must be free. No slug but a name and no slug yet:
  # generated, made unique. Otherwise untouched (write-once).
  defp slug_for(item, lang, fields, acc) do
    current = Map.get(acc.slugs, lang)
    path = "translations." <> lang <> ".slug"

    cond do
      Map.has_key?(fields, "slug") and is_nil(fields["slug"]) ->
        {:ok, Map.delete(acc.slugs, lang), acc.claimed}

      Map.has_key?(fields, "slug") ->
        explicit_slug(item, lang, fields["slug"], current, acc, path)

      Common.blank?(current) and is_binary(fields["name"]) ->
        generated_slug(item, lang, fields["name"], acc)

      true ->
        {:ok, acc.slugs, acc.claimed}
    end
  end

  defp explicit_slug(item, lang, text, current, acc, path) do
    slug = Slugs.from_title(text, lang)

    cond do
      Slugs.hash_fallback?(slug, text) ->
        {:error, path, "has no characters a URL can carry; send letters or digits", %{}}

      slug == current ->
        {:ok, acc.slugs, acc.claimed}

      taken?(item, acc.claimed).(slug, lang) ->
        {:error, path, "is already taken in this language", %{"slug" => slug}}

      true ->
        {:ok, Map.put(acc.slugs, lang, slug), claim(acc.claimed, item, slug, lang)}
    end
  end

  defp generated_slug(item, lang, name, acc) do
    base =
      Slugs.from_title(name, lang,
        default_slug: Slugs.default_lang_slug(item.data || %{}, acc.slugs)
      )

    slug = Slugs.unique(base, lang, taken?(item, acc.claimed))
    {:ok, Map.put(acc.slugs, lang, slug), claim(acc.claimed, item, slug, lang)}
  end

  # Taken in the database by another item, or claimed earlier in this request by
  # another item (the same item may use one slug in two dialects of a language).
  defp taken?(item, claimed) do
    fn candidate, lang ->
      case Map.fetch(claimed, claim_key(candidate, lang)) do
        {:ok, owner} -> owner != item.uuid
        :error -> Catalogue.item_slug_taken?(candidate, lang, exclude_uuid: item.uuid)
      end
    end
  end

  defp claim(claimed, item, slug, lang), do: Map.put(claimed, claim_key(slug, lang), item.uuid)

  # The projection is per base language ("de-DE" and "de-AT" both live in "de").
  defp claim_key(slug, lang), do: {DialectMapper.extract_base(lang), slug}

  # --- dry run -------------------------------------------------------------------------

  defp preview(plan) do
    plan
    |> Enum.map(fn
      {:update, ref, item, update} ->
        preview_row(ref, item, update)

      {:rejected, ref, message, context} ->
        Common.row_error(ref, :validation_failed, message, context)

      {:resolution_error, ref, reason} ->
        Common.resolution_error(ref, reason)
    end)
    |> Common.preview()
  end

  defp preview_row(ref, item, update) do
    case Catalogue.preview_item_update(item, update.attrs, update.row_opts) do
      {:ok, changes} ->
        action = if changes == %{}, do: "unchanged", else: "updated"
        Common.row_ok(ref, action, item.uuid, %{"changes" => changes})

      {:error, changeset} ->
        Common.row_error(ref, :validation_failed, "The change is not valid.", %{
          "errors" => Common.changeset_errors(changeset)
        })
    end
  end

  # --- execution -------------------------------------------------------------------------

  defp execute(plan, ctx) do
    opts = Common.write_opts(ctx, @tool)

    rows =
      for {:update, _ref, item, update} <- plan, do: {item.uuid, update.attrs, update.row_opts}

    case write(rows, opts) do
      {:ok, outcomes} ->
        by_uuid = Map.new(outcomes)
        plan |> Enum.map(&finish(&1, by_uuid)) |> Common.batch_result()

      {:error, reason} ->
        Logger.warning("#{@tool} batch could not be written: #{Common.reason_code(reason)}")
        {:error, :internal_error, "The batch could not be written.", %{}}
    end
  end

  # A request whose rows were all rejected opens no transaction.
  defp write([], _opts), do: {:ok, []}
  defp write(rows, opts), do: Catalogue.update_items(rows, opts)

  defp finish({:rejected, ref, message, context}, _outcomes),
    do: Common.row_error(ref, :validation_failed, message, context)

  defp finish({:resolution_error, ref, reason}, _outcomes),
    do: Common.resolution_error(ref, reason)

  defp finish({:update, ref, item, _update}, outcomes) do
    case Map.get(outcomes, item.uuid) do
      {kind, %{status: "deleted"} = trashed} -> trashed_row(ref, trashed, kind == :updated)
      {:updated, _updated} -> Common.row_ok(ref, "updated", item.uuid)
      {:unchanged, _updated} -> Common.row_ok(ref, "unchanged", item.uuid)
      {:error, %Ecto.Changeset{} = changeset} -> changeset_failure(ref, changeset)
      {:error, :not_found} -> Common.row_error(ref, :not_found, "The item no longer exists.")
      _other -> Common.row_error(ref, :internal_error, "The item could not be written.")
    end
  end

  # The item was trashed between planning and writing. The write is the one
  # `Catalogue.update_item/3` makes on a trashed row (its status stays `deleted`),
  # so the translations may have been stored: the row says so.
  defp trashed_row(ref, item, saved?) do
    ref
    |> Common.row_error(:not_found, "The item was trashed before the change was applied.", %{
      "saved" => saved?
    })
    |> Map.put("id", item.uuid)
  end

  # A slug taken by a writer between planning and writing surfaces here.
  defp changeset_failure(ref, changeset) do
    Common.row_error(ref, :validation_failed, "The translation is not valid.", %{
      "errors" => Common.changeset_errors(changeset)
    })
  end
end
