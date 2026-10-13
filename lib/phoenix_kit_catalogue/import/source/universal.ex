defmodule PhoenixKitCatalogue.Import.Source.Universal do
  @moduledoc "Universal import source: XLSX/CSV (existing parser) + JSON (export round-trip)."
  @behaviour PhoenixKitCatalogue.Import.Source
  alias PhoenixKitCatalogue.Import.Parser

  @impl true
  def key, do: :universal
  @impl true
  def label, do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Universal")
  @impl true
  def formats,
    do: [
      {:spreadsheet, "XLSX / CSV"},
      {:json, Gettext.gettext(PhoenixKitCatalogue.Gettext, "JSON (export)")}
    ]

  @impl true
  def accept, do: ~w(.xlsx .csv .json)
  @impl true
  def flow, do: :mapping

  @doc "Parse an uploaded file into the mapper's parsed_file shape."
  @spec parse(binary(), String.t(), atom()) :: {:ok, map()} | {:error, term()}
  def parse(binary, _filename, :json), do: parse_json(binary)
  def parse(binary, filename, _spreadsheet), do: Parser.parse(binary, filename)

  @json_headers ~w(name sku base_price unit item_type catalogue)

  defp parse_json(binary) do
    case Jason.decode(binary) do
      {:ok, %{"items" => items}} when is_list(items) -> rows_from_items(items)
      {:ok, _} -> {:error, :bad_json_shape}
      err -> err
    end
  end

  defp rows_from_items(items) do
    if Enum.all?(items, &flat_item?/1) do
      rows = Enum.map(items, fn it -> Enum.map(@json_headers, &to_string(it[&1])) end)
      {:ok, %{sheets: [], headers: @json_headers, rows: rows, row_count: length(rows)}}
    else
      {:error, :bad_json_shape}
    end
  end

  # The export writes each item as an object of plain values, and every
  # cell is rendered with `to_string/1` — which raises on a nested object
  # and on some lists. Anything else is not this format.
  defp flat_item?(item) when is_map(item) do
    Enum.all?(@json_headers, &plain_value?(item[&1]))
  end

  defp flat_item?(_item), do: false

  # JSON can spell a NUL (`\u0000`) inside a string; the database refuses
  # one in a text value.
  defp plain_value?(value) when is_binary(value), do: not String.contains?(value, <<0>>)
  defp plain_value?(value), do: is_nil(value) or is_number(value) or is_boolean(value)
end
