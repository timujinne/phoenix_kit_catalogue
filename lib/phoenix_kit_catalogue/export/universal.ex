defmodule PhoenixKitCatalogue.Export.Universal do
  @moduledoc """
  Universal export destination.

  Produces a generic, destination-agnostic JSON dump that can be consumed by
  any application. Useful for data exchange, backups, and integrations that
  do not require a proprietary format.
  """

  @behaviour PhoenixKitCatalogue.Export.Destination

  alias PhoenixKitCatalogue.Export.UniversalJson

  @impl true
  def key, do: :universal

  @impl true
  def label, do: "Универсальный (Universal)"

  @impl true
  def formats do
    [{:json, "JSON"}]
  end

  @impl true
  def render(:json, ctx) do
    UniversalJson.render(ctx)
  end
end
