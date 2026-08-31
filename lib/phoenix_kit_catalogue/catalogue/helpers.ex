defmodule PhoenixKitCatalogue.Catalogue.Helpers do
  @moduledoc false
  # Cross-section helpers used by multiple Catalogue submodules.
  # Polymorphic atom/string-keyed map accessors plus a shared
  # `item_catalogue_uuid/1` lookup that both `Catalogue` and `Rules`
  # use for PubSub broadcast scoping (avoids the duplicate query
  # PR #13 review #2 flagged).

  import Ecto.Query, warn: false

  alias PhoenixKitCatalogue.Schemas.Item

  @doc "True when `attrs` has the key as either an atom or its string form."
  @spec has_attr?(map(), atom()) :: boolean()
  def has_attr?(attrs, key) when is_map(attrs) and is_atom(key) do
    Map.has_key?(attrs, key) or Map.has_key?(attrs, to_string(key))
  end

  @doc """
  Reads `attrs[key]` falling back to `attrs[to_string(key)]`. Returns `nil`
  when neither is present.
  """
  @spec fetch_attr(map(), atom()) :: term() | nil
  def fetch_attr(attrs, key) when is_map(attrs) and is_atom(key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, to_string(key))
    end
  end

  @doc """
  Writes a value into `attrs` under whichever key form is already present.
  Falls back to matching the rest of the map's key style on a fresh insert
  so that mixed-key maps (which would later trip `Ecto.Changeset.cast/4`)
  don't get introduced here.
  """
  @spec put_attr(map(), atom(), term()) :: map()
  def put_attr(attrs, key, value) when is_map(attrs) and is_atom(key) do
    cond do
      Map.has_key?(attrs, key) ->
        Map.put(attrs, key, value)

      Map.has_key?(attrs, to_string(key)) ->
        Map.put(attrs, to_string(key), value)

      string_keyed?(attrs) ->
        Map.put(attrs, to_string(key), value)

      true ->
        Map.put(attrs, key, value)
    end
  end

  @doc "True when the first key in `attrs` is a binary string."
  @spec string_keyed?(map()) :: boolean()
  def string_keyed?(attrs) when map_size(attrs) == 0, do: false
  def string_keyed?(attrs) when is_map(attrs), do: attrs |> Map.keys() |> hd() |> is_binary()

  @doc """
  Escapes Postgres `LIKE`/`ILIKE` metacharacters so user-supplied search
  text is matched literally. Handles `\\`, `%`, and `_`.
  """
  @spec sanitize_like(String.t()) :: String.t()
  def sanitize_like(query) when is_binary(query) do
    query
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  @doc """
  How to search a JSONB column's translations without matching its
  structure.

  `data::text ILIKE '%a%'` reads the whole encoded document — braces,
  quotes and KEY names included — so a row whose data merely holds the
  key `_name` came back for the query "a" (Max, 2026-08-28: a catalogue
  called "Plumbing" answering a search for "a"). On the box that matched
  7 of 26 items where only 3 genuinely contain an "a".

  Match the string VALUES instead:

      fragment(
        "EXISTS (SELECT 1 FROM jsonb_path_query(?, '$.**') AS v WHERE jsonb_typeof(v) = 'string' AND v #>> '{}' ILIKE ?)",
        x.data,
        ^pattern
      )

  Two details keep that working: the path stays a SQL literal (a bound
  `jsonpath` parameter is a type Postgrex cannot encode) and it is
  `'$.**'` rather than a type-filtered path, because a `?` inside the
  literal would be read as another Ecto placeholder — hence the
  `jsonb_typeof` test in the WHERE instead.
  """
  @spec json_string_values_doc() :: :see_moduledoc
  def json_string_values_doc, do: :see_moduledoc

  @doc """
  Returns the catalogue UUID an item belongs to, or `nil` if the item
  is missing. Single source of truth for the parent-catalogue lookup
  used by PubSub broadcast scoping in `Catalogue.lookup_parent/2` and
  `Rules.put_catalogue_rules/3` (PR #13 #2 dedupe).
  """
  @spec item_catalogue_uuid(Ecto.UUID.t()) :: Ecto.UUID.t() | nil
  def item_catalogue_uuid(item_uuid) when is_binary(item_uuid) do
    PhoenixKit.RepoHelper.repo().one(
      from(i in Item, where: i.uuid == ^item_uuid, select: i.catalogue_uuid)
    )
  end

  @doc """
  Collapses a list of UUIDs so each appears once, keeping the *last*
  occurrence's position. Shared dedupe semantics for every DnD reorder
  payload — a stale DOM that emits the same uuid twice writes the
  intended (latest) position only.
  """
  @spec dedupe_keep_last([term()]) :: [term()]
  def dedupe_keep_last(items) when is_list(items) do
    items |> Enum.reverse() |> Enum.uniq() |> Enum.reverse()
  end

  @doc """
  Concatenates the caller-provided `:preload` opt onto the bulk-fetcher's
  defaults. Ecto handles atom dedup at preload time, so a caller passing
  `[:catalogue]` redundantly is safe. When a default bare atom collides
  with a caller-provided nested spec on the same key (e.g. defaults
  contain `:catalogue` and the caller passes `[catalogue: :categories]`),
  Ecto merges the two: the parent association loads *and* the nested
  child loads. Pinned by the `":preload collision with default atom"`
  test in `catalogue_test.exs`.
  """
  @spec merge_preloads(list(), keyword()) :: list()
  def merge_preloads(defaults, opts) do
    defaults ++ Keyword.get(opts, :preload, [])
  end
end
