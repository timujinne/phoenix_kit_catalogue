defmodule PhoenixKitCatalogue.Import.Source.Universal do
  @moduledoc "Universal import source: XLSX/CSV (existing parser) + JSON (export round-trip)."
  @behaviour PhoenixKitCatalogue.Import.Source
  alias PhoenixKitCatalogue.Import.Parser

  @impl true
  def key, do: :universal
  @impl true
  def label, do: "Универсальный (Universal)"
  @impl true
  def formats, do: [{:spreadsheet, "XLSX / CSV"}, {:json, "JSON (экспорт)"}]
  @impl true
  def accept, do: ~w(.xlsx .csv .json)
  @impl true
  def flow, do: :mapping

  @doc "Parse an uploaded file into the mapper's parsed_file shape."
  @spec parse(binary(), String.t(), atom()) :: {:ok, map()} | {:error, term()}
  def parse(binary, _filename, :json), do: parse_json(binary)
  def parse(binary, filename, _spreadsheet), do: Parser.parse(binary, filename)

  defp parse_json(binary) do
    case Jason.decode(binary) do
      {:ok, %{"items" => items}} when is_list(items) ->
        headers = ~w(name sku base_price unit item_type catalogue)
        rows = Enum.map(items, fn it -> Enum.map(headers, &to_string(Map.get(it, &1, ""))) end)
        {:ok, %{sheets: [], headers: headers, rows: rows, row_count: length(rows)}}

      {:ok, _} ->
        {:error, :bad_json_shape}

      err ->
        err
    end
  end
end
