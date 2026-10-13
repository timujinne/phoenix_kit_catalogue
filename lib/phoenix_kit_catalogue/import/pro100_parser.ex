defmodule PhoenixKitCatalogue.Import.Pro100Parser do
  @moduledoc """
  Parses the PRO100 fixed-layout text formats (`# Parts` / `# Materials`).

  UTF-8 with an optional leading BOM (or UTF-16 with one), TAB-separated,
  CRLF (or LF) lines. Each data row begins with two empty fields (the leading `\\t\\t`); after dropping
  them the positional columns are:

      Furniture: name  id  c3  price  c5  c6  c7
      Materials: name  id  c3  price  c5  unit
  """
  alias PhoenixKitCatalogue.Import.{Encoding, Mapper}
  alias PhoenixKitCatalogue.Pro100.Id

  @type row :: %{
          line_no: pos_integer(),
          raw_line: String.t(),
          id: String.t(),
          name: String.t(),
          base_price: Decimal.t() | nil,
          unit: String.t() | nil,
          service: %{String.t() => String.t()},
          format: :furniture | :materials
        }

  @spec parse(binary(), :furniture | :materials) :: {:ok, [row()]} | {:error, term()}
  def parse(binary, format) when is_binary(binary) and format in [:furniture, :materials] do
    case Encoding.to_utf8(binary) do
      {:ok, ""} -> {:error, :empty}
      {:ok, text} -> parse_text(text, format)
      {:error, :not_utf8} -> {:error, :not_utf8}
    end
  end

  defp parse_text(binary, format) do
    lines =
      binary
      |> String.split(["\r\n", "\n"])
      |> Enum.reject(&(&1 == ""))

    case lines do
      [header | data] ->
        if valid_header?(header, format) do
          rows = data |> Enum.with_index(2) |> Enum.map(&row(&1, format))
          {:ok, rows}
        else
          {:error, :bad_header}
        end

      [] ->
        {:error, :empty}
    end
  end

  defp valid_header?(header, :furniture), do: String.starts_with?(header, "# Parts\t")
  defp valid_header?(header, :materials), do: String.starts_with?(header, "# Materials\t")

  # Drop the two leading empty fields produced by the row's "\t\t" prefix.
  defp row({raw_line, line_no}, format) do
    cols =
      case String.split(raw_line, "\t") do
        ["", "" | rest] -> rest
        other -> other
      end

    base = %{
      line_no: line_no,
      raw_line: raw_line,
      name: Enum.at(cols, 0, ""),
      id: Id.digits_only(Enum.at(cols, 1)),
      base_price: price(Enum.at(cols, 3)),
      format: format
    }

    columns(base, cols, format)
  end

  defp columns(base, cols, :furniture) do
    base
    |> Map.put(:unit, nil)
    |> Map.put(:service, %{
      "c3" => Enum.at(cols, 2, ""),
      "c5" => Enum.at(cols, 4, ""),
      "c6" => Enum.at(cols, 5, ""),
      "c7" => Enum.at(cols, 6, "")
    })
  end

  defp columns(base, cols, :materials) do
    base
    |> Map.put(:unit, Enum.at(cols, 5))
    |> Map.put(:service, %{"c3" => Enum.at(cols, 2, ""), "c5" => Enum.at(cols, 4, "")})
  end

  defp price(nil), do: nil

  defp price(str) do
    case Mapper.normalize_price(str) do
      {:ok, dec} -> dec
      :error -> nil
    end
  end
end
