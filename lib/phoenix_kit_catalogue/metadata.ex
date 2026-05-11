defmodule PhoenixKitCatalogue.Metadata do
  @moduledoc """
  Global, code-defined list of metadata fields that catalogue resources
  (items and catalogues) can opt into.

  Resources store chosen values in `resource.data["meta"]` as a flat map
  keyed by the definition's `:key` — e.g. `%{"color" => "red"}`. Only
  fields the user has explicitly added appear in that map.

  The multilang layer owns the top-level `data` map (keys like `_name`,
  `_primary_language`, per-language entries) — metadata lives strictly
  under the `"meta"` sub-key so the two don't collide.

  All fields are text inputs for now — typed inputs (decimal / enum /
  etc.) can be reintroduced later by adding a `:type` field to the
  definition shape and dispatching at render + cast time.

  Edit `definitions/1` to add/remove fields. Removing a field from the
  list does **not** wipe stored values — resources that already hold a
  value for the removed key will surface it as "Legacy" in the form so
  the data isn't lost; the user can clear it manually.

  ## Form helpers

  Callers (LiveViews) drive the three-phase metadata flow through this
  module's pure helpers:

  - `build_state/2` turns a `resource.data` blob into `%{attached, values}`
    on mount (known keys first in definition order, legacy keys sorted).
  - `absorb_params/2` folds the user's latest inputs from the form's
    `"meta"` submap into `state.values` on validate/save.
  - `inject_into_data/3` casts values to storage shape and wedges them
    into `params["data"]["meta"]` right before hitting the context.

  See `PhoenixKitCatalogue.Web.ItemFormLive` / `CatalogueFormLive` for
  the reference wiring — one `meta_state` assign and three calls.
  """

  @type resource_type :: :item | :catalogue
  @type definition :: %{
          required(:key) => String.t(),
          required(:label) => String.t()
        }
  @type state :: %{attached: [String.t()], values: %{String.t() => String.t()}}

  @doc """
  The global list of metadata definitions for a given resource type.
  Order here is the order used for the "Add metadata" dropdown.

  The `:label` values are translated at call time via
  `PhoenixKitCatalogue.Gettext` — do not cache the result across locale
  changes. The `:key` is stable (it's the JSONB key) and never
  translated.
  """
  @spec definitions(resource_type()) :: [definition()]
  def definitions(:item) do
    [
      %{key: "color", label: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Color")},
      %{key: "weight", label: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Weight")},
      %{key: "width", label: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Width")},
      %{key: "height", label: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Height")},
      %{key: "depth", label: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Depth")},
      %{key: "material", label: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Material")},
      %{key: "finish", label: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Finish")}
    ]
  end

  def definitions(:catalogue) do
    [
      %{key: "brand", label: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Brand")},
      %{key: "collection", label: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Collection")},
      %{key: "season", label: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Season")},
      %{key: "region", label: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Region")},
      %{
        key: "vendor_ref",
        label: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Vendor Reference")
      }
    ]
  end

  @doc "Fetches a single definition by key. Returns `nil` if the key isn't in `definitions/1`."
  @spec definition(resource_type(), String.t()) :: definition() | nil
  def definition(resource_type, key) when is_binary(key) do
    Enum.find(definitions(resource_type), &(&1.key == key))
  end

  @doc """
  Normalizes a raw form value for storage: trims whitespace, collapses
  blanks to `nil` so callers can drop empty entries from the JSONB map.
  """
  @spec cast_value(definition(), term()) :: String.t() | nil
  def cast_value(_def, value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def cast_value(_def, _value), do: nil

  @doc """
  Builds the initial meta state from a resource's `data` map.

  Accepts either the raw `resource.data` (a map or `nil`) or a struct
  with a `:data` field — both shapes surface in practice because new
  structs default to `%{}` but a caller may pass `nil` if the field is
  unset. Known keys (those in `definitions(resource_type)`) land first
  in their declared order; legacy keys (stored but no longer defined)
  come after, alphabetized, so the UI can flag them and offer a
  remove-only action without dropping stored data.

  Returns `%{attached: [key], values: %{key => stringified_value}}`.

  ## Examples

      iex> Metadata.build_state(:catalogue, %{"meta" => %{"brand" => "Acme"}})
      %{attached: ["brand"], values: %{"brand" => "Acme"}}

      iex> Metadata.build_state(:item, nil)
      %{attached: [], values: %{}}
  """
  @spec build_state(resource_type(), map() | struct() | nil) :: state()
  def build_state(resource_type, %{data: data}),
    do: build_state(resource_type, data)

  def build_state(resource_type, data) when is_map(data) do
    raw =
      case data do
        %{"meta" => %{} = m} -> m
        _ -> %{}
      end

    defined_keys = Enum.map(definitions(resource_type), & &1.key)
    present_defined = Enum.filter(defined_keys, &Map.has_key?(raw, &1))
    legacy = raw |> Map.keys() |> Enum.reject(&(&1 in defined_keys)) |> Enum.sort()

    %{attached: present_defined ++ legacy, values: stringify_values(raw)}
  end

  def build_state(_resource_type, _), do: %{attached: [], values: %{}}

  @doc """
  Merges whatever the user currently has typed into the metadata inputs
  (delivered as `params["meta"]`) into the state's `:values`. Unattached
  keys are ignored so the render doesn't resurrect a row the user just
  removed.

  Returns the updated state; leaves the state untouched when the params
  don't contain a `"meta"` submap.
  """
  @spec absorb_params(state(), map()) :: state()
  def absorb_params(%{attached: attached, values: values} = state, params) do
    meta_params = Map.get(params, "meta", %{})

    if is_map(meta_params) and meta_params != %{} do
      new_values = Enum.reduce(attached, values, &absorb_one(meta_params, &1, &2))
      %{state | values: new_values}
    else
      state
    end
  end

  @doc """
  Casts the state into its storage shape and wedges it into
  `params["data"]["meta"]`. Known-key values go through `cast_value/2`
  (blanks become `nil` → the key drops). Legacy keys (no current
  definition) pass through untouched so their data isn't silently
  nuked by a save — the user clears them explicitly via the × button.
  """
  @spec inject_into_data(map(), state(), resource_type()) :: map()
  def inject_into_data(params, %{attached: attached, values: values}, resource_type) do
    meta =
      Enum.reduce(attached, %{}, &cast_meta_entry(&1, values, resource_type, &2))

    data =
      case Map.get(params, "data") do
        %{} = d -> d
        _ -> %{}
      end

    Map.put(params, "data", Map.put(data, "meta", meta))
  end

  defp stringify_values(values) when is_map(values) do
    Map.new(values, fn
      {k, nil} -> {k, ""}
      {k, v} when is_binary(v) -> {k, v}
      {k, v} -> {k, to_string(v)}
    end)
  end

  defp absorb_one(meta_params, key, acc) do
    case Map.get(meta_params, key) do
      nil -> acc
      value -> Map.put(acc, key, value)
    end
  end

  defp cast_meta_entry(key, values, resource_type, acc) do
    raw = Map.get(values, key, "")

    case definition(resource_type, key) do
      nil -> put_legacy_meta(acc, key, raw)
      def_ -> put_defined_meta(acc, key, def_, raw)
    end
  end

  defp put_legacy_meta(acc, _key, raw) when raw in [nil, ""], do: acc
  defp put_legacy_meta(acc, key, raw), do: Map.put(acc, key, raw)

  defp put_defined_meta(acc, key, def_, raw) do
    case cast_value(def_, raw) do
      nil -> acc
      cast -> Map.put(acc, key, cast)
    end
  end
end
