defmodule PhoenixKitCatalogue.Web.TableQuery do
  @moduledoc """
  Pure, in-memory search → filter → sort pipeline over a list of row maps
  (catalogues/suppliers/manufacturers already loaded by the LiveView).
  """
  alias PhoenixKitCatalogue.Web.Helpers
  alias PhoenixKitCatalogue.Web.TableConfig

  # Sentinel filter value for "folder is nil" — distinct from `to_string(nil)`
  # (which is `""`, already reserved by `filter/2` to mean "no filter set").
  @unfiled_folder "__unfiled__"

  @spec unfiled_folder_value() :: String.t()
  def unfiled_folder_value, do: @unfiled_folder

  @spec apply([map()], TableConfig.scope(), map()) :: [map()]
  def apply(rows, scope, opts) do
    rows
    |> search(Map.get(opts, :search, ""))
    |> filter(scope, Map.get(opts, :filters, %{}))
    |> sort(scope, Map.get(opts, :sort_by), Map.get(opts, :sort_dir, :asc))
  end

  @spec search([map()], String.t() | nil, (map() -> String.t() | nil)) :: [map()]
  def search(rows, q, field_fn \\ & &1.name)

  def search(rows, q, field_fn) when is_binary(q) do
    # Trimmed: a trailing space must not turn a match into a miss
    # (Max, 2026-08-28), and an all-space query means "no filter".
    case q |> String.trim() |> String.downcase() do
      "" ->
        rows

      needle ->
        Enum.filter(rows, fn r ->
          String.contains?(String.downcase(field_fn.(r) || ""), needle) or
            translation_matches?(r, needle)
        end)
    end
  end

  def search(rows, _, _), do: rows

  # Rows carry the row's own `:data` JSONB, which is where translations
  # live (`%{"et" => %{"_name" => "Köögisari"}}`). Only the VALUES count:
  # JSON-encoding the map and searching that matched KEY names too, so
  # "Plumbing" came back for the query "a" — its data holds the key
  # `_name` (Max, 2026-08-28). On real data, "a" matched 7 of 26 items
  # that way against 3 by value.
  defp translation_matches?(row, needle) do
    case Map.get(row, :data) do
      data when is_map(data) and map_size(data) > 0 ->
        data |> string_values() |> Enum.any?(&String.contains?(String.downcase(&1), needle))

      _ ->
        false
    end
  end

  # Every string leaf, whatever the shape nests into.
  defp string_values(value) when is_binary(value), do: [value]

  defp string_values(value) when is_map(value),
    do: value |> Map.values() |> Enum.flat_map(&string_values/1)

  defp string_values(value) when is_list(value), do: Enum.flat_map(value, &string_values/1)

  defp string_values(_other), do: []

  @spec filter([map()], TableConfig.scope(), map()) :: [map()]
  def filter(rows, scope, filters) when is_map(filters) do
    Enum.reduce(filters, rows, fn
      {_id, val}, acc when val in [nil, "", "all"] -> acc
      {id, val}, acc -> Enum.filter(acc, &filter_match?(scope, id, &1, val))
    end)
  end

  def filter(rows, _scope, _), do: rows

  defp filter_match?(_scope, "folder", row, @unfiled_folder), do: is_nil(row[:folder_uuid])

  # A set of uuids means "anywhere in this subtree" — the shape the
  # LiveView passes while a search is on, so searching a drilled folder
  # also finds catalogues filed in its subfolders.
  defp filter_match?(_scope, "folder", row, %MapSet{} = uuids),
    do: MapSet.member?(uuids, to_string(row[:folder_uuid]))

  defp filter_match?(_scope, "folder", row, val), do: to_string(row[:folder_uuid]) == val

  defp filter_match?(_scope, id, row, val) do
    to_string(Map.get(row, String.to_existing_atom(id))) == val
  rescue
    # Unknown atom = no column exists for this id; skip the filter rather than crash.
    ArgumentError -> true
  end

  @spec sort([map()], TableConfig.scope(), String.t() | nil, :asc | :desc) :: [map()]
  def sort(rows, scope, sort_by, dir) when is_binary(sort_by) do
    case TableConfig.column_map(scope)[sort_by] do
      %{sort_key: key} when is_function(key, 1) -> Enum.sort_by(rows, key, dir)
      _ -> rows
    end
  end

  def sort(rows, _scope, _sort_by, _dir), do: rows

  # Tuples are `{label, value}` — the order Phoenix's `options_for_select`
  # expects. Status options get the same translated label as the rest of
  # the UI (Helpers.status_label/1) instead of the raw DB value.
  @spec enum_options([map()], TableConfig.scope(), String.t()) :: [{String.t(), String.t()}]
  def enum_options(rows, scope, "status") do
    rows
    |> raw_enum_values(scope, "status")
    |> Enum.map(&{Helpers.status_label(&1), &1})
  end

  def enum_options(rows, scope, id) do
    Enum.map(raw_enum_values(rows, scope, id), &{&1, &1})
  end

  defp raw_enum_values(rows, _scope, id) do
    key = String.to_existing_atom(id)

    rows
    |> Enum.map(&to_string(Map.get(&1, key)))
    |> Enum.reject(&(&1 in ["", "nil"]))
    |> Enum.uniq()
    |> Enum.sort()
  rescue
    ArgumentError -> []
  end
end
