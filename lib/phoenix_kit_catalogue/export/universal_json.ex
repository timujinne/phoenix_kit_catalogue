defmodule PhoenixKitCatalogue.Export.UniversalJson do
  @moduledoc """
  Universal JSON export encoder.

  Produces a generic, destination-agnostic JSON dump of catalogue items
  across one or more catalogues.

  ## Output shape

      {
        "catalogues": [{"uuid": "...", "name": "..."}, ...],
        "exported_at": "2026-06-26T16:00:00Z",
        "index": 1111111111,
        "items": [
          {"name": "...", "sku": "...", "base_price": "2222.00", "unit": "piece", "catalogue": "..."}
        ]
      }

  Filename: when a single catalogue is exported, the file is named after the
  catalogue (e.g. `"My Catalogue.json"`). When multiple catalogues are exported
  the file is named `"Catalogues.json"`.
  """

  alias PhoenixKitCatalogue.Export.Pro100

  @doc """
  Renders the universal JSON export.

  `ctx` must have keys:
  - `:items` — list of items (with `:catalogue` association preloaded)
  - `:index` — unix timestamp integer
  - `:catalogues` — list of catalogue structs

  Returns `{filename, iodata, mime_type}`.
  """
  def render(ctx) do
    %{items: items, index: index, catalogues: catalogues} = ctx

    payload = %{
      "catalogues" => Enum.map(catalogues, &encode_catalogue/1),
      "exported_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "index" => index,
      "items" => Enum.map(items, &encode_item/1)
    }

    filename = build_filename(catalogues)
    json = Jason.encode!(payload, pretty: true)
    {filename, json, "application/json"}
  end

  defp encode_catalogue(catalogue) do
    %{"uuid" => catalogue.uuid, "name" => catalogue.name}
  end

  defp encode_item(item) do
    catalogue_name =
      case item.catalogue do
        %{name: name} -> name
        _ -> nil
      end

    %{
      "name" => item.name,
      "sku" => item.sku,
      "base_price" => Pro100.format_price(item.base_price),
      "unit" => item.unit,
      "catalogue" => catalogue_name
    }
  end

  defp build_filename([catalogue]) do
    "#{sanitize_filename(catalogue.name)}.json"
  end

  defp build_filename(_), do: "Catalogues.json"

  defp sanitize_filename(name) when is_binary(name) do
    name
    |> String.replace(~r/[^\w\s-]/, "")
    |> String.replace(~r/\s+/, "_")
    |> String.trim("_")
  end

  defp sanitize_filename(_), do: "catalogue"
end
