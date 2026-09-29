defmodule PhoenixKitCatalogue.Import.Source do
  @moduledoc "Behaviour for import sources — the inbound mirror of Export.Destination."
  @callback key() :: atom()
  # Labels are display strings, translated at call time (the LiveView
  # calls these while rendering, in the viewer's locale).
  @callback label() :: String.t()
  @callback formats() :: [{atom(), String.t()}]
  @callback accept() :: [String.t()]
  @callback flow() :: :mapping | :sync
end
