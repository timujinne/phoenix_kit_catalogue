defmodule PhoenixKitCatalogue.Import.DependencyCell do
  @moduledoc """
  Reads an import file's Dependencies cell into dependency references.

  Two shapes are accepted:

    * **The Universal JSON export's own list** — a JSON array of objects
      with `type` (`"item"`, `"category"`, `"catalogue"`), `uuid`, `name`,
      `sku`, `catalogue`, `quantity` and `note`; the JSON import source
      hands the list over as the cell's text.
    * **Text a person types in a spreadsheet** — items by SKU, one per
      entry: `8 × SCREW-4X30; 2,5 × EDGE-22`. Entries are separated by `;`
      or a line break; `×`, `x`, `X` or `*` sits between the quantity and
      the SKU.

  Pure: nothing is looked up here. `Import.Executor` resolves each
  reference after the rows are created, so an item may depend on another
  row of the same file.
  """

  alias PhoenixKit.Utils.Number
  alias PhoenixKitCatalogue.Schemas.ItemDependency

  # A cell is one item's list: these bound what one row can cost — the
  # references are resolved one query each and written in one transaction.
  @max_refs 200
  @max_cell_length 100_000

  @type ref :: %{
          type: String.t(),
          uuid: String.t() | nil,
          sku: String.t() | nil,
          name: String.t() | nil,
          catalogue: String.t() | nil,
          quantity: Decimal.t(),
          note: String.t() | nil
        }

  @types ~w(item category catalogue)

  @doc """
  `{:ok, refs}` (an empty or blank cell is `{:ok, []}`), or
  `{:error, entry}` naming the first entry that cannot be read.
  """
  @spec parse(String.t() | nil) :: {:ok, [ref()]} | {:error, String.t()}
  def parse(nil), do: {:ok, []}

  def parse(cell) when is_binary(cell) and byte_size(cell) > @max_cell_length,
    do: {:error, String.slice(cell, 0, 60)}

  def parse(cell) when is_binary(cell) do
    result =
      case String.trim(cell) do
        "" -> {:ok, []}
        "[" <> _ = json -> parse_json(json)
        text -> parse_text(text)
      end

    case result do
      {:ok, refs} when length(refs) > @max_refs -> {:error, String.slice(cell, 0, 60)}
      other -> other
    end
  end

  defp parse_json(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> collect(list, &json_ref/1)
      _ -> {:error, String.slice(json, 0, 60)}
    end
  end

  defp json_ref(%{"type" => type} = entry) when type in @types do
    with {:ok, quantity} <- quantity(entry["quantity"]),
         true <- note_fits?(entry["note"]) do
      {:ok,
       %{
         type: type,
         uuid: text(entry["uuid"]),
         sku: text(entry["sku"]),
         name: text(entry["name"]),
         catalogue: text(entry["catalogue"]),
         quantity: quantity,
         note: text(entry["note"])
       }}
    end
  end

  defp json_ref(_entry), do: :error

  defp note_fits?(note) when is_binary(note),
    do: String.length(note) <= ItemDependency.max_note_length()

  defp note_fits?(_note), do: true

  defp parse_text(text) do
    text
    |> String.split(~r/[;\n]/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> collect(&text_ref/1)
  end

  # "8 × SKU", "2,5 x SKU", "3*SKU" — the quantity first, the SKU after.
  defp text_ref(entry) do
    with [_, raw_quantity, sku] <-
           Regex.run(~r/^([0-9]+(?:[.,][0-9]+)?)\s*[×xX*]\s*(\S.*)$/u, entry),
         {:ok, quantity} <- quantity(raw_quantity) do
      {:ok,
       %{
         type: "item",
         uuid: nil,
         sku: String.trim(sku),
         name: nil,
         catalogue: nil,
         quantity: quantity,
         note: nil
       }}
    else
      _ -> :error
    end
  end

  defp collect(entries, read) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case read.(entry) do
        {:ok, ref} -> {:cont, {:ok, [ref | acc]}}
        _ -> {:halt, {:error, describe(entry)}}
      end
    end)
    |> case do
      {:ok, refs} -> {:ok, Enum.reverse(refs)}
      error -> error
    end
  end

  defp quantity(value) when is_number(value) or is_binary(value) do
    case Number.parse_decimal(value) do
      # What the column takes — above zero, at most four decimal places —
      # or the row's whole list would fail to save later.
      {:ok, %Decimal{} = decimal} ->
        if ItemDependency.valid_quantity?(decimal), do: {:ok, decimal}, else: :error

      _ ->
        :error
    end
  end

  defp quantity(_value), do: :error

  # JSON can spell a NUL (`\u0000`); the database refuses one in text.
  defp text(value) when is_binary(value) do
    case value |> String.replace(<<0>>, "") |> String.trim() do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(_value), do: nil

  defp describe(entry) when is_binary(entry), do: String.slice(entry, 0, 60)
  defp describe(entry), do: entry |> Jason.encode!() |> String.slice(0, 60)
end
