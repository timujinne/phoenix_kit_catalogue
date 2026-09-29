defmodule PhoenixKitCatalogue.Web.ViewConfig do
  @moduledoc """
  Per-user table view config (columns / sort / filters / view mode) for the
  catalogue admin tables, kept in core's per-user view preferences
  (`PhoenixKit.Users.ViewPrefs`): one row per scope under
  `"catalogue.<scope>"` (`columns`, `sort_by`, `sort_dir`, `filters`) and
  one module-wide row under `"catalogue"` (`view`, `selector`). A save
  writes only the fields it changed, patched in the database, so two tabs
  changing different things both keep theirs. Columns follow core's rules
  (`PhoenixKitWeb.TableColumns`): an empty list is a choice, ids no longer
  offered are skipped, and resetting takes the choice back out.

  V3 of this module's migration chain copied what earlier versions kept in
  `phoenix_kit_users.custom_fields["catalogue_view_configs"]`.

  ## Global sort

  For scopes in `@global_sort_scopes` the SORT half of the config is not
  per-user: it lives in a module setting (`catalogue_sort_<scope>`), so every
  admin sees the same ordering — when one of them switches the catalogues
  index to "Manual order" and drags rows, everyone else is looking at that
  same order (the live half rides `Catalogue.PubSub`; see
  `broadcast_view_sort_changed/4` and `CataloguesLive.put_cfg/3`).
  `load/2` overlays the global value over whatever the user row stored, so
  the per-user copy is inert for these scopes. Columns and filters stay
  per-user, per-scope.

  ## Shared view mode

  The VIEW (card / comfy / table) is per-user but **not** per-scope: it is
  one choice for the whole module, stored in the `"catalogue"` row. Picking cards
  on the catalogues index and then opening a catalogue used to land on
  whatever that page happened to remember — every surface kept its own
  preference, and two of them (the detail page, the attributes tab) kept
  theirs in the browser's localStorage instead, so the two halves could not
  agree even in principle (boss's ask via Max, 2026-08-28: the view should
  stay when you switch pages). `load/2` overlays it exactly like the sort,
  so every `cfg.view` in the module returns the same answer.
  """
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.ViewPrefs
  alias PhoenixKitCatalogue.Web.TableConfig
  alias PhoenixKitWeb.TableColumns

  # The module-wide row: the view (card / comfy / table) and the item
  # selector's two choices (`selector_view`, `selector_hidden`) (2026-08-31, boss: "save settings after a user
  # changes them") — starting view + hidden columns, one set per user for
  # every selector embed. Selector values are stored raw and validated by
  # the consumer against its granted columns.
  @module_key "catalogue"

  # Shared sort for every admin: the catalogues index plus the detail
  # page's items/categories tables. Manufacturers/suppliers stay per-user.
  @global_sort_scopes [:catalogues, :detail_items, :detail_categories]

  @spec scope_key(TableConfig.scope()) :: String.t()
  def scope_key(scope), do: to_string(scope)

  @doc "The view-preferences key a scope's choices are kept under."
  @spec view_key(TableConfig.scope()) :: String.t()
  def view_key(scope), do: @module_key <> "." <> scope_key(scope)

  @doc """
  The `PhoenixKitWeb.TableColumns` spec for a scope: its managed columns
  (Name and the sort-only ids are drawn by the table, not picked) and
  their defaults.
  """
  @spec column_spec(TableConfig.scope()) :: map()
  def column_spec(scope) do
    %{
      key: view_key(scope),
      columns: for(c <- TableConfig.managed_columns(scope), do: %{id: c.id, label: c.label}),
      defaults: TableConfig.default_columns(scope)
    }
  end

  @spec defaults(TableConfig.scope()) :: map()
  def defaults(scope) do
    {sort_by, sort_dir} = TableConfig.default_sort(scope)

    %{
      columns: TableConfig.default_columns(scope),
      sort_by: sort_by,
      sort_dir: sort_dir,
      filters: %{},
      view: "comfy"
    }
  end

  @spec global_sort?(TableConfig.scope()) :: boolean()
  def global_sort?(scope), do: scope in @global_sort_scopes

  defp global_sort_setting_key(scope), do: "catalogue_sort_" <> scope_key(scope)

  @doc """
  The shared sort for a global-sort scope: the `catalogue_sort_<scope>`
  setting (`"<column>:<asc|desc>"`), falling back to the scope's default
  when unset or when it names a column that is no longer sortable.
  """
  @spec load_global_sort(TableConfig.scope()) :: {String.t(), :asc | :desc}
  def load_global_sort(scope) do
    fallback = TableConfig.default_sort(scope)

    case Settings.get_setting(global_sort_setting_key(scope), nil) do
      value when is_binary(value) -> parse_global_sort(scope, value, fallback)
      _ -> fallback
    end
  end

  defp parse_global_sort(scope, value, fallback) do
    with [by, dir_s] <- String.split(value, ":", parts: 2),
         true <- sortable_id?(scope, by),
         dir when dir in [:asc, :desc] <- (dir_s == "asc" && :asc) || (dir_s == "desc" && :desc) do
      {by, dir}
    else
      _ -> fallback
    end
  end

  defp sortable_id?(scope, id) do
    scope |> TableConfig.columns() |> Enum.any?(&(&1.id == id and &1.sortable?))
  end

  @spec save_global_sort(TableConfig.scope(), String.t(), :asc | :desc) ::
          {:ok, term()} | {:error, term()}
  def save_global_sort(scope, sort_by, sort_dir) do
    Settings.update_setting_with_module(
      global_sort_setting_key(scope),
      "#{sort_by}:#{sort_dir}",
      PhoenixKitCatalogue.module_key()
    )
  end

  @spec load(map() | nil, TableConfig.scope()) :: map()
  def load(user, scope) do
    cfg = normalize(scope, ViewPrefs.get(user, view_key(scope)))
    # Legacy cleanup: configs saved before ?folder= became URL state may
    # still carry the folder filter — ignore it so nobody stays stuck.
    cfg = %{cfg | filters: Map.delete(cfg.filters, "folder")}

    cfg = %{cfg | view: load_view(user)}

    if global_sort?(scope) do
      {sort_by, sort_dir} = load_global_sort(scope)
      %{cfg | sort_by: sort_by, sort_dir: sort_dir}
    else
      cfg
    end
  end

  @doc """
  The user's module-wide view mode: `"card"`, `"comfy"` or `"table"`.
  Defaults to `"comfy"` for anyone who has never chosen.
  """
  @spec load_view(map() | nil) :: String.t()
  def load_view(user) do
    stored = user |> ViewPrefs.get(@module_key) |> Map.get("view")
    if stored in ["card", "comfy", "table"], do: stored, else: "comfy"
  end

  @doc """
  Stores the module-wide view mode. Best-effort: with no user (or a user
  row that is gone) the choice lives in the page for the session rather
  than crashing the LiveView on a toggle click.
  """
  @spec save_view(map() | nil, String.t()) :: {:ok, map()} | {:error, term()}
  def save_view(user, view) when view in ["card", "comfy", "table"],
    do: ViewPrefs.put(user, @module_key, %{"view" => view})

  def save_view(_user, _view), do: {:error, :invalid_view}

  @doc """
  The user's saved item-selector choices: `%{view: "table" | "comfy" |
  "card" | nil, hidden: [String.t()] | nil}`. `nil` halves mean "never
  chosen" — the selector then uses its host attrs/defaults. Hidden entries
  come back as the raw stored strings; the selector validates them against
  its granted columns (a stale column name is simply ignored).
  """
  @spec load_selector(map() | nil) :: %{view: String.t() | nil, hidden: [String.t()] | nil}
  def load_selector(user) do
    stored = ViewPrefs.get(user, @module_key)
    view = stored["selector_view"]
    hidden = stored["selector_hidden"]

    %{
      view: if(view in ["table", "comfy", "card"], do: view),
      hidden: if(is_list(hidden) and Enum.all?(hidden, &is_binary/1), do: hidden)
    }
  end

  @doc """
  Stores the selector choices — each half its own field, so a `nil` half
  keeps what is saved and two tabs changing different halves both keep
  theirs. Best-effort like `save_view/2`.
  """
  @spec save_selector(map() | nil, %{
          optional(:view) => String.t(),
          optional(:hidden) => [String.t()]
        }) ::
          {:ok, map()} | {:error, term()}
  def save_selector(user, choices) do
    fields =
      %{"selector_view" => choices[:view], "selector_hidden" => choices[:hidden]}
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    if fields == %{},
      do: {:ok, ViewPrefs.get(user, @module_key)},
      else: ViewPrefs.put(user, @module_key, fields)
  end

  @doc "`save_view/2` for a LiveView: stores the signed-in user's choice."
  @spec save_view_on(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def save_view_on(socket, view) do
    _ = save_view(socket.assigns[:phoenix_kit_current_user], view)
    socket
  end

  @spec normalize(TableConfig.scope(), map()) :: map()
  def normalize(scope, raw) when is_map(raw) do
    d = defaults(scope)

    cols = TableColumns.resolve(raw["columns"], column_spec(scope))

    filters =
      if is_map(raw["filters"]) do
        valid_filter_ids =
          scope
          |> TableConfig.columns()
          |> Enum.filter(& &1.filterable?)
          |> MapSet.new(& &1.id)

        Map.filter(raw["filters"], fn {k, _v} -> MapSet.member?(valid_filter_ids, k) end)
      else
        %{}
      end

    %{
      columns: cols,
      sort_by: raw["sort_by"] || d.sort_by,
      sort_dir: dir(raw["sort_dir"], d.sort_dir),
      filters: filters,
      view: (raw["view"] in ["table", "card", "comfy"] && raw["view"]) || "comfy"
    }
  end

  def normalize(scope, _), do: defaults(scope)

  defp dir("desc", _), do: :desc
  defp dir("asc", _), do: :asc
  defp dir(_, fallback), do: fallback

  @doc """
  Stores a scope's config for `user`. With `prev` (the config the page held
  before the change), only the fields that differ are written — the rest
  stay as stored, so a sort change in one tab cannot put back the columns
  another tab just changed.
  """
  @spec save(map() | nil, TableConfig.scope(), map(), map() | nil) ::
          {:ok, map()} | {:error, term()}
  def save(user, scope, cfg, prev \\ nil) do
    # A global-sort scope's ordering is the module setting's; a per-user
    # copy would be inert.
    fields =
      if global_sort?(scope),
        do: Map.drop(serialize(cfg), ["sort_by", "sort_dir"]),
        else: serialize(cfg)

    changed =
      case prev do
        %{} -> Map.reject(fields, fn {k, v} -> serialize(prev)[k] == v end)
        _ -> fields
      end

    if changed == %{},
      do: {:ok, ViewPrefs.get(user, view_key(scope))},
      else: ViewPrefs.put(user, view_key(scope), changed)
  end

  @doc "Stores just a scope's column choice for `user`."
  @spec save_columns(map() | nil, TableConfig.scope(), [String.t()]) ::
          {:ok, map()} | {:error, term()}
  def save_columns(user, scope, columns),
    do: ViewPrefs.put(user, view_key(scope), %{"columns" => columns})

  @doc """
  Takes the scope's column choice back out, so `user` sees the defaults
  and follows them if they change — rather than a saved copy of them.
  """
  @spec reset_columns(map() | nil, TableConfig.scope()) :: {:ok, map()} | {:error, term()}
  def reset_columns(user, scope), do: ViewPrefs.delete_fields(user, view_key(scope), ["columns"])

  # The current folder is LOCATION, not a preference: it lives in the URL
  # (?folder=) like the detail page's ?category=, so it is never persisted —
  # a stored value made the index "remember" a drill across sessions and
  # devices with no link to share. The view is module-wide (see the
  # moduledoc) — `save_view/2` owns it; writing it per scope is what let
  # the surfaces drift.
  defp serialize(cfg) do
    %{
      "columns" => cfg.columns,
      "sort_by" => cfg.sort_by,
      "sort_dir" => to_string(cfg.sort_dir),
      "filters" => Map.delete(cfg.filters, "folder")
    }
  end
end
