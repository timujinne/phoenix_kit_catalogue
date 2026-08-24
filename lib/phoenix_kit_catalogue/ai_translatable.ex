defmodule PhoenixKitCatalogue.AITranslatable do
  @moduledoc """
  `PhoenixKitAI.Translatable` adapter for catalogue resources —
  the small per-module hook into PhoenixKitAI's generic AI-translation pipeline.

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
  alias PhoenixKitCatalogue.Schemas.{Attribute, AttributeGroup, AttributeValue, Category, Item}
  alias PhoenixKitCatalogue.Schemas.Catalogue, as: CatalogueSchema

  # Engine-facing field names (plain strings) ↔ their schema columns, per
  # resource shape. The AI engine speaks the string keys; `column_value/2`
  # maps back to the atom column. Attribute values translate their `value`
  # display text; groups and attributes only a `name`. (The attribute rows
  # have no in-form AI button yet — registration serves the programmatic /
  # bulk enqueue paths.)
  defp field_columns(%AttributeValue{}), do: %{"value" => :value}
  defp field_columns(%Attribute{}), do: %{"name" => :name}
  defp field_columns(%AttributeGroup{}), do: %{"name" => :name}
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
    lang_data = Multilang.get_language_data(resource.data || %{}, source_lang)

    for field <- Map.keys(field_columns(resource)),
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
    Map.get(resource, Map.fetch!(field_columns(resource), field))
  end

  @impl true
  def put_translation(resource, target_lang, fields, opts) do
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
    |> tap_broadcast()
  end

  defp tap_broadcast({:ok, updated} = ok) do
    broadcast_translated(updated)
    ok
  end

  defp tap_broadcast(other), do: other

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

  # Merge `fields` into the freshly-locked row's `data` and persist, rolling
  # the surrounding transaction back on a changeset error.
  defp merge_translation!(repo, fresh, target_lang, fields, update_fn, opts) do
    # Re-prefix plain engine field names to the multilang `_`-form the form
    # reads (`_name`/`_description`), so the translation shows.
    lang_fields = Map.new(fields, fn {k, v} -> {"_" <> k, v} end)
    new_data = force_put_language(fresh.data || %{}, target_lang, lang_fields)

    case update_fn.(fresh, %{data: new_data}, opts) do
      {:ok, updated} -> updated
      {:error, reason} -> repo.rollback(reason)
    end
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
