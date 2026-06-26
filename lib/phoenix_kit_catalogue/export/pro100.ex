defmodule PhoenixKitCatalogue.Export.Pro100 do
  @moduledoc """
  PRO100 export destination.

  Produces two text formats used by the PRO100 furniture-design application:

  * `:furniture` — "Parts" list, tab-delimited with CRLF line endings.
  * `:materials` — "Materials" list, tab-delimited with CRLF line endings.

  ## Format layout

  Both text formats share common encoding rules (UTF-8, TAB separator, CRLF):

      Furniture:  # Parts\\t<index>\\r\\n
                  \\t\\t<name>\\t<sku>\\t0\\t<price>\\t1.0\\t\\t0.0\\r\\n

      Materials:  # Materials\\t<index>\\r\\n
                  \\t\\t<name>\\t<sku>\\t0\\t<price>\\t1.0\\t<unit>\\r\\n

  `index` is `System.os_time(:second)` at export time (unix timestamp).
  `price` is formatted to 2 decimal places; nil becomes `"0.00"`.
  `unit` is the abbreviated label from `PhoenixKitCatalogue.Schemas.Item.unit_label/1`.
  """

  @behaviour PhoenixKitCatalogue.Export.Destination

  alias PhoenixKitCatalogue.Schemas.Item

  @tab "\t"
  @crlf "\r\n"

  @impl true
  def key, do: :pro100

  @impl true
  def label, do: "PRO100"

  @impl true
  def formats do
    [
      {:furniture, "Фурнитура (Furniture)"},
      {:materials, "Материалы (Materials)"}
    ]
  end

  @impl true
  def render(:furniture, ctx) do
    %{items: items, index: index} = ctx
    header = ["# Parts", @tab, Integer.to_string(index), @crlf]
    rows = Enum.map(items, &furniture_row/1)
    {"Furniture.txt", [header | rows], "text/plain"}
  end

  def render(:materials, ctx) do
    %{items: items, index: index} = ctx
    header = ["# Materials", @tab, Integer.to_string(index), @crlf]
    rows = Enum.map(items, &materials_row/1)
    {"Materials.txt", [header | rows], "text/plain"}
  end

  # ---------------------------------------------------------------------------
  # Row builders
  # ---------------------------------------------------------------------------

  defp furniture_row(item) do
    [
      @tab,
      @tab,
      sanitize(item.name),
      @tab,
      sanitize(item.sku || ""),
      @tab,
      "0",
      @tab,
      format_price(item.base_price),
      @tab,
      "1.0",
      @tab,
      "",
      @tab,
      "0.0",
      @crlf
    ]
  end

  defp materials_row(item) do
    [
      @tab,
      @tab,
      sanitize(item.name),
      @tab,
      sanitize(item.sku || ""),
      @tab,
      "0",
      @tab,
      format_price(item.base_price),
      @tab,
      "1.0",
      @tab,
      sanitize(Item.unit_label(item.unit)),
      @crlf
    ]
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @doc false
  def format_price(nil), do: "0.00"

  def format_price(%Decimal{} = d),
    do: d |> Decimal.round(2) |> Decimal.to_string(:normal)

  # Sanitize a field value: strip TAB, CR, and LF so they never corrupt rows.
  @doc false
  def sanitize(nil), do: ""

  def sanitize(str) when is_binary(str),
    do: String.replace(str, ["\t", "\r", "\n"], "")
end
