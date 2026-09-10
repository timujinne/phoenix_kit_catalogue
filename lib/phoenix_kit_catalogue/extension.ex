defmodule PhoenixKitCatalogue.Extension do
  @moduledoc """
  Behaviour for a module that adds a "Shop"-style section to the catalogue
  item and/or category forms and owns a namespace under `data` (spec §2
  principle 8, §4 row C4).

  Catalogue never names an implementer — discovery is duck-typed through
  `PhoenixKit.ModuleRegistry`, the same pattern `PhoenixKitAI.Translatable`
  uses for `ai_translatables/0` (see `PhoenixKitCatalogue.Extensions`).
  A host module (e.g. `phoenix_kit_ecommerce`) contributes an implementer
  via its own `catalogue_extensions/0` callback; it structurally
  implements this behaviour without declaring `@behaviour
  PhoenixKitCatalogue.Extension`, so it isn't forced to depend on
  `phoenix_kit_catalogue` at compile time.

  All callbacks except `key/0` and `enabled?/0` are optional — an
  extension can own a namespace and render on only one of the two forms,
  or hold data without rendering anything at all.
  """

  @doc "Namespace under `data` this extension owns, e.g. `\"ecommerce\"`."
  @callback key() :: String.t()

  @doc "Whether the extension's section should render and its namespace be absorbed."
  @callback enabled?() :: boolean()

  @doc """
  Renders the extension's section inside the catalogue item form.

  `assigns` carries `:form`, `:item`, `:data` (the item's `data` map, so
  `data[key()]` is the extension's own current values) and
  `:current_language`.
  """
  @callback item_section(assigns :: map()) :: Phoenix.LiveView.Rendered.t()

  @doc "Same as `item_section/1`, for the catalogue category form (`:category` instead of `:item`)."
  @callback category_section(assigns :: map()) :: Phoenix.LiveView.Rendered.t()

  @doc """
  Validates and shapes the item form's submap for this extension's
  namespace (`params[key()]`, a plain map) into the value to store under
  `data[key()]`. `current` is the namespace's existing value (`data[key()]`
  before this submission, or `%{}`).
  """
  @callback cast_item(params :: map(), current :: map()) ::
              {:ok, map()} | {:error, [{atom(), String.t()}]}

  @doc "Same as `cast_item/2`, for the catalogue category form."
  @callback cast_category(params :: map(), current :: map()) ::
              {:ok, map()} | {:error, [{atom(), String.t()}]}

  @typedoc """
  One column this extension contributes to the catalogue admin's
  configurable item/category tables (`item_columns/0` /
  `category_columns/0`) — the "Columns" modal on `CatalogueDetailLive`.

    * `:id` — this extension's own identifier, unique among its own
      columns only. `PhoenixKitCatalogue.Extensions.columns/1`
      namespaces it under `key/0` (`"<key>:<id>"`) before it ever
      reaches the catalogue, so it cannot collide with a catalogue
      column or another extension's.
    * `:label` — zero-arity fn returning the display label (a fn so it
      resolves in the request's current locale, matching
      `PhoenixKitCatalogue.Web.TableConfig`'s own columns).
    * `:render` — one-arity fn `(record) -> Phoenix.LiveView.Rendered.t()`;
      `record` is the item or category struct the table is currently
      rendering a row for. Return the cell's inner content only — the
      catalogue supplies the surrounding table cell.

      A raise, throw, exit, or a return value with no `Phoenix.HTML.Safe`
      representation degrades to an empty cell instead of breaking the
      page — see `PhoenixKitCatalogue.Extensions.columns/1`. Never give
      the returned markup an `id` scoped only by `record`: the SAME
      call renders the row's desktop-table cell AND its mobile-card
      fact, both present in the DOM on one page load (CSS/JS, not the
      server, decides which is visible) — an id that repeats across
      them is invalid HTML. Use a `data-*` attribute instead if the
      cell needs to be addressable.
  """
  @type column :: %{
          id: String.t(),
          label: (-> String.t()),
          render: (record :: map() -> Phoenix.LiveView.Rendered.t())
        }

  @doc """
  Extra columns for the catalogue item table's Columns modal
  (`PhoenixKitCatalogue.Web.TableConfig`'s `:detail_items` scope). Off by
  default — an admin opts in exactly like any catalogue column.
  """
  @callback item_columns() :: [column()]

  @doc "Same as `item_columns/0`, for the catalogue category table (`:detail_categories`)."
  @callback category_columns() :: [column()]

  @optional_callbacks item_section: 1,
                      category_section: 1,
                      cast_item: 2,
                      cast_category: 2,
                      item_columns: 0,
                      category_columns: 0
end
