NimbleCSV.define(PhoenixKitCatalogue.Import.CommaParser, separator: ",", escape: "\"")
NimbleCSV.define(PhoenixKitCatalogue.Import.SemicolonParser, separator: ";", escape: "\"")
NimbleCSV.define(PhoenixKitCatalogue.Import.TabParser, separator: "\t", escape: "\"")

defmodule PhoenixKitCatalogue.Import.Parser do
  @moduledoc """
  Parses XLSX and CSV files into structured row data.

  Returns a map with headers, rows, sheet names, and row count.
  Uses no external dependencies beyond what phoenix_kit already provides:
  - NimbleCSV for CSV (auto-detects separator)
  - XlsxReader for XLSX
  """

  alias PhoenixKitCatalogue.Import.{CommaParser, Encoding, SemicolonParser, TabParser}

  # Upload guards. The import path materializes the whole sheet in memory
  # (NimbleCSV / XlsxReader both return all rows), so cap the raw byte
  # size before parsing and the row count after, surfacing a clean error
  # rather than letting a pathological upload spike memory.
  @max_byte_size 25 * 1024 * 1024
  @max_rows 50_000

  # Candidate CSV parsers, tried in preference order on ties.
  @candidate_parsers [CommaParser, SemicolonParser, TabParser]

  @type parsed_file :: %{
          sheets: [String.t()],
          headers: [String.t()],
          rows: [[String.t()]],
          row_count: non_neg_integer()
        }

  @doc """
  Detects file format from the filename extension.
  """
  @spec detect_format(String.t()) :: :xlsx | :csv | {:error, :unsupported}
  def detect_format(filename) do
    case filename |> String.downcase() |> Path.extname() do
      ".xlsx" -> :xlsx
      ".csv" -> :csv
      ".tsv" -> :csv
      _ -> {:error, :unsupported}
    end
  end

  @doc """
  Parses a file binary into structured data.

  ## Options

    * `:sheet` — sheet name to parse (XLSX only, defaults to first sheet)
  """
  @spec parse(binary(), String.t(), keyword()) :: {:ok, parsed_file()} | {:error, term()}
  def parse(binary, filename, opts \\ []) do
    if byte_size(binary) > @max_byte_size do
      {:error, :file_too_large}
    else
      case detect_format(filename) do
        :xlsx -> binary |> parse_xlsx(opts) |> enforce_row_cap()
        :csv -> binary |> parse_csv() |> enforce_row_cap()
        {:error, :unsupported} -> {:error, :unsupported_file_format}
      end
    end
  end

  defp enforce_row_cap({:ok, %{row_count: row_count}}) when row_count > @max_rows,
    do: {:error, :too_many_rows}

  defp enforce_row_cap(result), do: result

  @doc """
  Lists sheet names from an XLSX file.
  """
  @spec list_sheets(binary()) :: {:ok, [String.t()]} | {:error, term()}
  def list_sheets(binary) when byte_size(binary) > @max_byte_size, do: {:error, :file_too_large}

  def list_sheets(binary) do
    with_xlsx_file(binary, fn path ->
      case XlsxReader.open(path) do
        {:ok, package} ->
          {:ok, XlsxReader.sheet_names(package)}

        {:error, reason} ->
          {:error, {:xlsx_read_failed, reason}}
      end
    end)
  end

  # ── XLSX Parsing ──────────────────────────────────────────────

  defp parse_xlsx(binary, opts) do
    sheet_name = Keyword.get(opts, :sheet)

    with_xlsx_file(binary, fn path ->
      case XlsxReader.open(path) do
        {:ok, package} ->
          sheets = XlsxReader.sheet_names(package)
          target_sheet = sheet_name || List.first(sheets)
          read_xlsx_sheet(package, target_sheet, sheets)

        {:error, reason} ->
          {:error, {:xlsx_open_failed, reason}}
      end
    end)
  end

  # XlsxReader answers `{:error, _}` for an archive it cannot open and for
  # XML that is not well formed, but raises on well-formed XML holding a
  # value it does not expect (a row number that is not a number, say). The
  # bytes are an upload, so every call into it runs here, where a raise, an
  # exit or a throw becomes the same error tuple.
  defp with_xlsx_file(binary, fun) do
    with_temp_file(binary, ".xlsx", fun)
  rescue
    e -> {:error, {:xlsx_read_failed, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:xlsx_read_failed, {kind, reason}}}
  end

  defp read_xlsx_sheet(package, target_sheet, sheets) do
    case XlsxReader.sheet(package, target_sheet, empty_rows: false) do
      {:ok, []} ->
        {:error, {:sheet_empty, target_sheet}}

      {:ok, [header_row | data_rows]} ->
        headers = Enum.map(header_row, &to_string/1)

        rows =
          data_rows
          |> Enum.map(fn row -> Enum.map(row, &to_string/1) end)
          |> reject_empty_rows()

        {headers, rows} = reject_empty_columns(headers, rows)

        {:ok, %{sheets: sheets, headers: headers, rows: rows, row_count: length(rows)}}

      {:error, reason} ->
        {:error, {:sheet_read_failed, target_sheet, reason}}
    end
  end

  defp with_temp_file(binary, ext, fun) do
    tmp_path = Path.join(System.tmp_dir!(), "import_#{:erlang.unique_integer([:positive])}#{ext}")

    try do
      File.write!(tmp_path, binary)
      fun.(tmp_path)
    after
      File.rm(tmp_path)
    end
  end

  # ── CSV Parsing ───────────────────────────────────────────────

  # Cells reach header matching, the JSON-serialised preview and the
  # database, all of which need valid UTF-8 — a file in another encoding
  # is refused here with a message rather than failing further on.
  defp parse_csv(binary) do
    case Encoding.to_utf8(binary) do
      {:ok, text} -> parse_csv_text(text)
      {:error, :not_utf8} -> {:error, :csv_not_utf8}
    end
  end

  defp parse_csv_text(binary) do
    parser = detect_csv_separator(binary)

    try do
      all_rows = parser.parse_string(binary, skip_headers: false)

      case all_rows do
        [] ->
          {:error, :csv_empty}

        [header_row | data_rows] ->
          headers = Enum.map(header_row, &String.trim/1)
          rows = Enum.map(data_rows, fn row -> Enum.map(row, &String.trim/1) end)
          rows = reject_empty_rows(rows)
          {headers, rows} = reject_empty_columns(headers, rows)

          {:ok,
           %{
             sheets: ["Sheet1"],
             headers: headers,
             rows: rows,
             row_count: length(rows)
           }}
      end
    rescue
      e ->
        {:error, {:csv_parse_failed, Exception.message(e)}}
    end
  end

  # Pick the delimiter by actually parsing a sample of the file with each
  # candidate parser and scoring the result, rather than counting raw
  # delimiter characters on the first line. Character counting is fooled
  # by delimiters inside quoted fields (e.g. a single quoted header cell
  # `"Name, with comma"` would pick the comma parser and collapse every
  # row to one column). Parsing a multi-line sample and preferring the
  # parser that yields the most columns with a consistent count across
  # rows is robust to that.
  defp detect_csv_separator(binary) do
    sample =
      binary
      |> String.split(~r/\r?\n/, parts: 11)
      |> Enum.take(10)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    @candidate_parsers
    |> Enum.map(fn parser -> {parser, sample_score(parser, sample)} end)
    |> Enum.max_by(fn {_parser, score} -> score end, fn -> {CommaParser, 0} end)
    |> elem(0)
  end

  # Score a candidate parser on the sample: header column count dominates
  # (a wrong delimiter yields 1 column), with consistency across the
  # sampled rows as a tiebreaker. Returns 0 if the parser raises.
  defp sample_score(parser, sample) do
    case parser.parse_string(sample, skip_headers: false) do
      [header | _] = rows ->
        header_cols = length(header)
        consistent = Enum.count(rows, fn row -> length(row) == header_cols end)
        header_cols * 100 + consistent

      _ ->
        0
    end
  rescue
    _ -> 0
  end

  # ── Helpers ───────────────────────────────────────────────────

  defp reject_empty_rows(rows) do
    Enum.reject(rows, fn row ->
      Enum.all?(row, fn cell -> cell == "" or is_nil(cell) end)
    end)
  end

  # Strips columns that are completely empty — header is blank AND every
  # data cell at that column index is blank. Spreadsheet exports often
  # include leading or trailing empty columns that survive XLSX parsing
  # as `""` cells; without removing them we'd render a column of
  # truncated empty `<td>`s in the preview, generate a phantom mapping
  # card with an empty header, and let the user "skip" a non-column.
  #
  # Columns with a real header but all-blank data are kept — that's a
  # valid (if optional) column that may carry no data in this file.
  defp reject_empty_columns(headers, rows) do
    total_cols = max(length(headers), max_row_length(rows))

    if total_cols == 0 do
      {headers, rows}
    else
      kept =
        for idx <- 0..(total_cols - 1),
            not (blank_cell?(Enum.at(headers, idx)) and column_blank?(rows, idx)),
            do: idx

      new_headers = Enum.map(kept, fn idx -> Enum.at(headers, idx, "") end)
      new_rows = Enum.map(rows, &project_columns(&1, kept))

      {new_headers, new_rows}
    end
  end

  defp project_columns(row, kept_indices) do
    Enum.map(kept_indices, fn idx -> Enum.at(row, idx, "") end)
  end

  defp blank_cell?(nil), do: true
  defp blank_cell?(""), do: true
  defp blank_cell?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank_cell?(_), do: false

  defp column_blank?(rows, idx) do
    Enum.all?(rows, fn row -> blank_cell?(Enum.at(row, idx)) end)
  end

  defp max_row_length([]), do: 0
  defp max_row_length(rows), do: rows |> Enum.map(&length/1) |> Enum.max()
end
