defmodule PhoenixKitCatalogue.Export.Destination do
  @moduledoc """
  Behaviour for export destinations (e.g. PRO100, Universal).

  Each destination module defines a key, a human-readable label, the list of
  format options it supports, and a `render/2` function that produces the
  file content for a given format key and export context.

  ## Adding a new destination

  1. Create a module that `@behaviour PhoenixKitCatalogue.Export.Destination`.
  2. Implement all four callbacks.
  3. Register it in `PhoenixKitCatalogue.Export.destinations/0`.
  """

  @doc "Machine key for the destination (e.g. `:pro100`)."
  @callback key() :: atom()

  @doc "Human-readable label shown in the UI select."
  @callback label() :: String.t()

  @doc """
  Supported formats as `[{key, label}]` pairs.
  `key` is an atom used when calling `render/2`; `label` is the display string.
  """
  @callback formats() :: [{atom(), String.t()}]

  @doc """
  Renders the export content.

  `format_key` must be one of the atoms from `formats/0`.
  `ctx` is a map with keys: `:items`, `:index`, `:catalogues`.

  Returns `{filename, iodata, mime_type}`.
  """
  @callback render(format_key :: atom(), ctx :: map()) ::
              {filename :: String.t(), iodata :: iodata(), mime :: String.t()}
end
