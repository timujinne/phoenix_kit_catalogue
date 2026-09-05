defmodule PhoenixKitCatalogue.Web.TableConfig do
  @moduledoc """
  Column metadata for the catalogue admin tables, keyed by scope
  (`:catalogues`, `:suppliers`, `:manufacturers`). Pure data — cell and
  card rendering live in the LiveView. Labels are zero-arity fns so they
  resolve in the request's current locale.
  """
  use Gettext, backend: PhoenixKitCatalogue.Gettext

  alias PhoenixKitCatalogue.Gettext, as: G

  @type scope ::
          :catalogues
          | :suppliers
          | :manufacturers
          | :attribute_groups
          | :detail_items
          | :detail_categories
  @type column :: %{
          id: String.t(),
          label: (-> String.t()),
          default?: boolean(),
          managed?: boolean(),
          sortable?: boolean(),
          sort_key: (map() -> term()) | nil,
          align: :left | :right,
          filterable?: boolean(),
          filter_type: :enum | nil
        }

  defp g(s), do: Gettext.gettext(G, s)

  # Build a column with sensible defaults.
  defp col(id, label_fn, opts) do
    %{
      id: id,
      label: label_fn,
      default?: Keyword.get(opts, :default?, false),
      managed?: Keyword.get(opts, :managed?, true),
      sortable?: Keyword.get(opts, :sortable?, false),
      sort_key: Keyword.get(opts, :sort_key),
      align: Keyword.get(opts, :align, :left),
      filterable?: Keyword.get(opts, :filterable?, false),
      filter_type: Keyword.get(opts, :filter_type)
    }
  end

  @spec columns(scope()) :: [column()]
  def columns(:catalogues) do
    [
      col("name", fn -> g("Name") end,
        default?: true,
        managed?: false,
        sortable?: true,
        sort_key: &down(&1.name)
      ),
      # Sort-only pseudo column — never added to `cfg.columns`, so it
      # never renders as an actual grid column (no "Manual order" cell/
      # header). Selecting it as `sort_by` switches the index into
      # drag-and-drop mode; see `CataloguesLive.manual_order_draggable?/2`.
      # Tie-break on (lowercased) name to mirror `Catalogue.list_catalogues/1`'s
      # `order_by: [asc: :position, asc: :name]` — every legacy catalogue
      # defaults to `position: 0` (only newly-created ones get a real
      # position), so without this the admin list and the printed-document
      # order it's meant to match can disagree on every tied row.
      col("position", fn -> gettext("Manual order") end,
        managed?: false,
        sortable?: true,
        sort_key: &{&1.position, down(&1.name)}
      ),
      # Not filterable: folder scope is the drilled location (?folder=),
      # chosen by navigating, not by a toolbar select (Max, 2026-08-29).
      col("folder", fn -> g("Folder") end,
        default?: true,
        sortable?: true,
        sort_key: &down(&1[:folder_name])
      ),
      # Hidden by default (Max, 2026-08-29): search matches descriptions
      # via the data JSONB, so this is how a "why is Hardware matching
      # 'te'?" result explains itself — reveal it via Columns.
      col("description", fn -> g("Description") end,
        sortable?: true,
        sort_key: &down(&1[:description])
      ),
      col("items", fn -> g("Items") end,
        default?: true,
        sortable?: true,
        align: :right,
        sort_key: &(&1[:item_count] || 0)
      ),
      col("status", fn -> g("Status") end,
        default?: true,
        sortable?: true,
        sort_key: &down(&1.status),
        filterable?: true,
        filter_type: :enum
      ),
      col("kind", fn -> g("Kind") end,
        sortable?: true,
        sort_key: &down(&1.kind),
        filterable?: true,
        filter_type: :enum
      ),
      col("markup", fn -> g("Markup %") end,
        sortable?: true,
        align: :right,
        sort_key: &dec(&1.markup_percentage)
      ),
      col("discount", fn -> g("Discount %") end,
        sortable?: true,
        align: :right,
        sort_key: &dec(&1.discount_percentage)
      ),
      col("updated", fn -> g("Updated") end,
        default?: true,
        sortable?: true,
        sort_key: &epoch(&1.updated_at)
      ),
      col("created", fn -> g("Created") end, sortable?: true, sort_key: &epoch(&1.inserted_at))
    ]
  end

  def columns(scope) when scope in [:suppliers, :manufacturers] do
    [
      col("name", fn -> g("Name") end,
        default?: true,
        managed?: false,
        sortable?: true,
        sort_key: &down(&1.name)
      ),
      col("website", fn -> g("Website") end,
        default?: true,
        sortable?: true,
        sort_key: &down(&1.website)
      ),
      col("status", fn -> g("Status") end,
        default?: true,
        sortable?: true,
        sort_key: &down(&1.status),
        filterable?: true,
        filter_type: :enum
      ),
      col("contact_info", fn -> g("Contact Info") end,
        sortable?: true,
        sort_key: &down(&1.contact_info)
      ),
      col("updated", fn -> g("Updated") end, sortable?: true, sort_key: &epoch(&1.updated_at))
    ]
  end

  # The catalogue detail page's items table. Name is always visible
  # (managed?: false); the rest toggle/reorder via the Columns modal.
  # Header sorting goes through the page's own sort selector /
  # toggle_sort_items — the `sortable?` flags here exist so the GLOBAL
  # sort setting (ViewConfig.load_global_sort) can validate stored ids.
  # "position" and "base_price" are sort-only pseudo ids (managed?:
  # false keeps them out of the Columns modal; "price" is the display
  # column, :base_price the sort field).
  def columns(:detail_items) do
    [
      col("name", fn -> g("Name") end, default?: true, managed?: false, sortable?: true),
      col("position", fn -> gettext("Manual order") end, managed?: false, sortable?: true),
      col("base_price", fn -> g("Price") end, managed?: false, sortable?: true),
      col("sku", fn -> g("SKU") end, default?: true, sortable?: true),
      col("price", fn -> g("Price") end, default?: true),
      col("supplier_price", fn -> g("Supplier price") end, default?: true),
      col("unit", fn -> g("Unit") end, default?: true),
      col("status", fn -> g("Status") end, default?: true, sortable?: true),
      col("attributes", fn -> g("Attributes") end, []),
      col("files", fn -> g("Files") end, []),
      col("description", fn -> g("Description") end, []),
      col("updated", fn -> g("Updated") end, []),
      col("created", fn -> g("Created") end, [])
    ]
  end

  # The detail page's categories table (Name is unmanaged; the rest
  # toggle via the Columns modal; the `sortable?` ids back the global
  # categories sort — the extra display columns are not sort options).
  def columns(:detail_categories) do
    [
      col("name", fn -> g("Name") end, default?: true, managed?: false, sortable?: true),
      col("position", fn -> gettext("Manual order") end, managed?: false, sortable?: true),
      col("items", fn -> g("Items") end, default?: true, sortable?: true),
      col("subcategories", fn -> g("Subcategories") end, default?: true),
      col("description", fn -> g("Description") end, []),
      col("files", fn -> g("Files") end, []),
      col("status", fn -> g("Status") end, []),
      col("updated", fn -> g("Updated") end, sortable?: true),
      col("created", fn -> g("Created") end, [])
    ]
  end

  def columns(:attribute_groups) do
    [
      col("name", fn -> g("Name") end,
        default?: true,
        managed?: false,
        sortable?: true,
        sort_key: &down(&1.name)
      ),
      col("attributes", fn -> g("Attributes") end,
        default?: true,
        sortable?: true,
        align: :right,
        sort_key: &(&1[:attribute_count] || 0)
      ),
      col("items", fn -> g("Items") end,
        default?: true,
        sortable?: true,
        align: :right,
        sort_key: &(&1[:item_count] || 0)
      ),
      col("status", fn -> g("Status") end,
        default?: true,
        sortable?: true,
        sort_key: &down(&1.status),
        filterable?: true,
        filter_type: :enum
      ),
      col("updated", fn -> g("Updated") end,
        default?: true,
        sortable?: true,
        sort_key: &epoch(&1.updated_at)
      )
    ]
  end

  @spec default_columns(scope()) :: [String.t()]
  def default_columns(scope) do
    scope |> columns() |> Enum.filter(& &1.default?) |> Enum.map(& &1.id)
  end

  @spec managed_columns(scope()) :: [column()]
  def managed_columns(scope), do: scope |> columns() |> Enum.filter(& &1.managed?)

  @spec column_map(scope()) :: %{String.t() => column()}
  def column_map(scope), do: scope |> columns() |> Map.new(&{&1.id, &1})

  @spec validate_columns(scope(), [String.t()]) :: [String.t()]
  def validate_columns(scope, ids) when is_list(ids) do
    known = scope |> managed_columns() |> MapSet.new(& &1.id)
    ids |> Enum.filter(&MapSet.member?(known, &1)) |> Enum.uniq()
  end

  def validate_columns(_scope, _), do: []

  @spec sortable_visible(scope(), [String.t()]) :: [column()]
  def sortable_visible(scope, ids) do
    map = column_map(scope)
    ids |> Enum.map(&Map.get(map, &1)) |> Enum.filter(&(&1 && &1.sortable?))
  end

  @spec default_sort(scope()) :: {String.t(), :asc | :desc}
  # Catalogues default to Manual order: that is the tree (file-explorer)
  # view — folders with their catalogues in positional order. Sorting by
  # any column flattens to the sortable table. The detail page's two
  # lists default to Manual too — section order is document order.
  def default_sort(:catalogues), do: {"position", :asc}
  def default_sort(:detail_items), do: {"position", :asc}
  def default_sort(:detail_categories), do: {"position", :asc}
  def default_sort(_), do: {"name", :asc}

  # sort helpers: case-insensitive for strings, Decimal→float, nil-safe.
  defp down(nil), do: ""
  defp down(s) when is_binary(s), do: String.downcase(s)
  defp down(other), do: other

  defp dec(%Decimal{} = d), do: Decimal.to_float(d)
  defp dec(n) when is_number(n), do: n
  defp dec(_), do: 0.0

  # Chronological, not structural: `Enum.sort_by/3`'s default term order
  # compares DateTime structs field-alphabetically (day before month), so
  # a bare `& &1.updated_at` sort key misordered across month boundaries.
  defp epoch(%DateTime{} = dt), do: DateTime.to_unix(dt, :microsecond)

  defp epoch(%NaiveDateTime{} = dt),
    do: NaiveDateTime.diff(dt, ~N[1970-01-01 00:00:00], :microsecond)

  defp epoch(_), do: 0
end
