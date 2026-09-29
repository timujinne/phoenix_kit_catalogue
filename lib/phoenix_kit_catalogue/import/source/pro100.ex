defmodule PhoenixKitCatalogue.Import.Source.Pro100 do
  @moduledoc "PRO100 import source: fixed-layout # Parts / # Materials, update-by-id."
  @behaviour PhoenixKitCatalogue.Import.Source
  alias PhoenixKitCatalogue.Import.{Matcher, Pro100Parser, Pro100Plan}

  @impl true
  def key, do: :pro100
  @impl true
  def label, do: "PRO100"
  @impl true
  def formats do
    [
      {:furniture, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Furniture")},
      {:materials, Gettext.gettext(PhoenixKitCatalogue.Gettext, "Materials")}
    ]
  end

  @impl true
  def accept, do: ~w(.txt)
  @impl true
  def flow, do: :sync

  @doc """
  Parse + match + plan against the selected catalogue's items.

  `catalogue_name` is what rows are checked against for group membership: a
  PRO100 export can span several groups ("Andi Karkass / …", "Andi Töötasapind /
  …") while the sync targets one catalogue, and rows from the other groups must
  not be offered for creation here.

  Note for future sources: `handle_sync_file` dispatches this call on whichever
  module the operator picked, so every `flow() == :sync` source must keep the
  same arity. PRO100 is the only one today.
  """
  @spec analyze(
          binary(),
          :furniture | :materials,
          [PhoenixKitCatalogue.Schemas.Item.t()],
          String.t() | nil
        ) :: {:ok, map()} | {:error, term()}
  def analyze(binary, format, catalogue_items, catalogue_name) do
    with {:ok, rows} <- Pro100Parser.parse(binary, format) do
      index = Matcher.index(catalogue_items)
      {:ok, Pro100Plan.build(rows, index, catalogue_name)}
    end
  end
end
