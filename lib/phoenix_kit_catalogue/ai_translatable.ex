defmodule PhoenixKitCatalogue.AITranslatable do
  @moduledoc """
  `PhoenixKit.Modules.AI.Translatable` adapter for catalogue resources —
  the small per-module hook into core's generic AI-translation pipeline.

  Serves three resource types (`"catalogue"`, `"catalogue_category"`,
  `"catalogue_item"`), each translating `name` + `description`. Source text
  and translations live in the shared `data` JSONB via
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

  Registered from `PhoenixKitCatalogue.ai_translatables/0`. The enqueue,
  the AI call, broadcasts, retry policy, and the audit log all live in core.
  """

  @behaviour PhoenixKit.Modules.AI.Translatable

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Schemas.Catalogue, as: CatalogueSchema
  alias PhoenixKitCatalogue.Schemas.{Category, Item}

  @translatable_fields ["name", "description"]

  @impl true
  def fetch("catalogue", uuid), do: wrap(Catalogue.get_catalogue(uuid))
  def fetch("catalogue_category", uuid), do: wrap(Catalogue.get_category(uuid))
  def fetch("catalogue_item", uuid), do: wrap(Catalogue.get_item(uuid))
  def fetch(other, _uuid), do: {:error, {:unknown_resource_type, other}}

  defp wrap(nil), do: {:error, :resource_not_found}
  defp wrap(%_{} = resource), do: {:ok, resource}

  @impl true
  def source_fields(resource, source_lang) do
    lang_data = Multilang.get_language_data(resource.data || %{}, source_lang)

    for field <- @translatable_fields,
        value = field_value(resource, field, lang_data),
        is_binary(value) and String.trim(value) != "",
        into: %{},
        do: {field, value}
  end

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

  defp column_value(resource, field) do
    Map.get(resource, String.to_existing_atom(field))
  rescue
    ArgumentError -> nil
  end

  @impl true
  def put_translation(resource, target_lang, fields, opts) do
    repo = RepoHelper.repo()
    {schema, update_fn} = persist_target(resource)
    uuid = resource.uuid
    # `broadcast: false` — the write happens inside this FOR UPDATE
    # transaction, so suppress the updater's own resource broadcast (it would
    # fire pre-commit / look like a user edit). Translation completion is
    # signalled by core's `:translation_completed` after this returns.
    opts = Keyword.put(opts, :broadcast, false)

    # Re-read the row FOR UPDATE inside the transaction so concurrent
    # per-language jobs (enqueue_all_missing) serialize on the row lock and
    # each merges against the latest committed `data` — otherwise a job
    # merging into its stale pre-AI snapshot would drop sibling languages.
    repo.transaction(fn ->
      query = schema |> where([r], r.uuid == ^uuid) |> lock("FOR UPDATE")

      case repo.one(query) do
        nil ->
          repo.rollback(:resource_not_found)

        fresh ->
          # Re-prefix plain engine field names to the multilang `_`-form the
          # form reads (`_name`/`_description`), so the translation shows.
          lang_fields = Map.new(fields, fn {k, v} -> {"_" <> k, v} end)
          new_data = force_put_language(fresh.data || %{}, target_lang, lang_fields)

          case update_fn.(fresh, %{data: new_data}, opts) do
            {:ok, updated} -> updated
            {:error, reason} -> repo.rollback(reason)
          end
      end
    end)
  end

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
      if multilang?,
        do: existing_data,
        else: %{"_primary_language" => primary, primary => existing_data}

    # Always MERGE into the lang subtree (never wholesale-replace) so other
    # keys in that language are preserved — important if `lang` ever resolves
    # to the primary subtree (e.g. an item whose embedded primary differs
    # from the global one). `primary` is bound only to seed the marker above.
    _ = primary
    Map.put(base, lang, Map.merge(Map.get(base, lang, %{}), full_field_data))
  end

  defp persist_target(%CatalogueSchema{}), do: {CatalogueSchema, &Catalogue.update_catalogue/3}
  defp persist_target(%Category{}), do: {Category, &Catalogue.update_category/3}
  defp persist_target(%Item{}), do: {Item, &Catalogue.update_item/3}
end
