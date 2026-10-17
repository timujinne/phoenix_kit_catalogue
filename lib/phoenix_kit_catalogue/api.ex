defmodule PhoenixKitCatalogue.API do
  @moduledoc """
  The catalogue's part of the shop API.

  This module is the surface the **sibling modules** build on: e-commerce and
  warehouse tools take product references in the same three forms and resolve
  them here.

  ## References

  A reference names one item (or category) and has exactly one of

      %{"id" => uuid} | %{"sku" => text} | %{"external_id" => text}

  (`sku` for items only). `id` is the stable key; a `sku` is not unique, so
  one that matches several live items resolves to `{:ambiguous_ref, uuids}`;
  `external_id` (stored at `data["api"]["external_id"]`) is unique per
  catalogue among live rows (migration V5).

  ## Catalogue scope

  References resolve inside ONE catalogue. `resolve_catalogue/2` picks it from
  the tool's `catalogue_id` input: required when the install has more than one
  active catalogue, optional (the only one) otherwise.
  """

  alias PhoenixKitCatalogue.API.{CatalogueScope, Gate, Refs, Tools}

  @doc """
  The catalogue's admin tools, as `PhoenixKitCatalogue.api_tools/0` hands them
  to core. FAIL CLOSED: a tool declared `danger: :always` (today
  `catalogue.delete_products` and `catalogue.delete_categories`) is withheld unless the
  loaded core can enforce the confirmation gate (`Gate.available?/0`). A core without
  the gate ignores the `danger` field and would trash on the first call; a version number or a
  `mix.exs` floor does not prove the gate exists (the stand and the forks use
  git and path pins), so the check is made on the running code.
  """
  @spec tools(boolean()) :: [PhoenixKit.API.Tool.t()]
  def tools(gate? \\ Gate.available?()) do
    Enum.filter(Tools.all(), fn tool -> gate? or tool.danger != :always end)
  end

  @doc """
  Resolves references (see the moduledoc). Answers one
  `{ref, {:ok, struct} | {:error, reason}}` per input reference, in order, with
  the reference echoed as given. Never raises on input.

  ## Options

    * `:kind` — `:item` (default) or `:category` (no `sku`).
    * `:catalogue_uuid` — resolve inside this catalogue only.
    * `:include_deleted` — also match trashed rows (default `false`).
    * `:preload` — associations to preload (default none).

  `reason` is `:not_found` (including an `id` that is not a UUID and a text
  containing a NUL byte), `:invalid_ref` (zero or several keys, a blank or
  non-string value) or `{:ambiguous_ref, [uuid]}` (candidates, sorted). With
  `include_deleted: true` a trashed row counts as a candidate too, so an
  `external_id` held by a live and a trashed row is ambiguous.
  """
  @spec resolve_refs([term()], keyword()) :: [Refs.resolution()]
  def resolve_refs(refs, opts \\ []), do: Refs.resolve(refs, opts)

  @doc """
  The catalogue a tool works in. `nil` means "not given": the only active
  standard catalogue, or `opts[:default_uuid]` when the caller has a default
  (e-commerce passes the catalogue the shop reads); with several active
  catalogues and no default the answer lists them.

  Answers `{:ok, catalogue}` or a handler error tuple
  (`{:error, :validation_failed | :not_found, message, context}`), so a handler
  can return it as it is. Smart catalogues are refused; an archived catalogue
  can be read but, with `writable: true`, not changed.
  """
  @spec resolve_catalogue(term(), keyword()) ::
          {:ok, PhoenixKitCatalogue.Schemas.Catalogue.t()}
          | {:error, :validation_failed | :not_found, String.t(), map()}
  def resolve_catalogue(catalogue_id, opts \\ []), do: CatalogueScope.resolve(catalogue_id, opts)
end
