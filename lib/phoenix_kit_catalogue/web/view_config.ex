defmodule PhoenixKitCatalogue.Web.ViewConfig do
  @moduledoc """
  Per-user table view config (columns / sort / filters / view mode) for the
  catalogue admin tables. Stored in `phoenix_kit_users.custom_fields` under
  the `"catalogue_view_configs"` key — no dedicated table. Precedent:
  `PhoenixKit.Notifications.Prefs`.

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
  one choice for the whole module, stored under `@view_key`. Picking cards
  on the catalogues index and then opening a catalogue used to land on
  whatever that page happened to remember — every surface kept its own
  preference, and two of them (the detail page, the attributes tab) kept
  theirs in the browser's localStorage instead, so the two halves could not
  agree even in principle (boss's ask via Max, 2026-08-28: the view should
  stay when you switch pages). `load/2` overlays it exactly like the sort,
  so every `cfg.view` in the module returns the same answer.
  """
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKitCatalogue.Web.TableConfig

  @root "catalogue_view_configs"

  # Not a scope name: the module-wide view lives beside the per-scope maps.
  @view_key "__view__"

  # The item-selector popup's per-user choices (2026-08-31, boss: "save
  # settings after a user changes them"): starting view + hidden columns,
  # one set per user for every selector embed, same philosophy as the
  # module-wide view above. Values are stored raw and validated by the
  # consumer against its granted columns.
  @selector_key "__selector__"

  # Shared sort for every admin: the catalogues index plus the detail
  # page's items/categories tables. Manufacturers/suppliers stay per-user.
  @global_sort_scopes [:catalogues, :detail_items, :detail_categories]

  @spec scope_key(TableConfig.scope()) :: String.t()
  def scope_key(scope), do: to_string(scope)

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
    raw =
      case user do
        %{custom_fields: cf} when is_map(cf) -> get_in(cf, [@root, scope_key(scope)]) || %{}
        _ -> %{}
      end

    cfg = normalize(scope, raw)
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
    stored =
      case user do
        %{custom_fields: cf} when is_map(cf) -> get_in(cf, [@root, @view_key])
        _ -> nil
      end

    if stored in ["card", "comfy", "table"], do: stored, else: "comfy"
  end

  @doc """
  Stores the module-wide view mode. Best-effort like `save/3`: a test
  harness user (or none) keeps the choice in memory for the session
  rather than crashing the LiveView on a toggle click.
  """
  @spec save_view(map() | nil, String.t()) :: {:ok, map()} | {:error, term()}
  def save_view(%Auth.User{} = user, view) when view in ["card", "comfy", "table"] do
    current = user.custom_fields || %{}
    merged = Map.put(current, @root, Map.put(Map.get(current, @root, %{}), @view_key, view))

    Auth.update_user_custom_fields(user, merged, ensure_definitions: false, broadcast: false)
  end

  def save_view(_user, _view), do: {:error, :no_user}

  @doc """
  The user's saved item-selector choices: `%{view: "table" | "card" |
  nil, hidden: [String.t()] | nil}`. `nil` halves mean "never chosen" —
  the selector then uses its host attrs/defaults. Hidden entries come
  back as the raw stored strings; the selector validates them against
  its granted columns (a stale column name is simply ignored).
  """
  @spec load_selector(map() | nil) :: %{view: String.t() | nil, hidden: [String.t()] | nil}
  def load_selector(user) do
    stored =
      case user do
        %{custom_fields: cf} when is_map(cf) -> get_in(cf, [@root, @selector_key]) || %{}
        _ -> %{}
      end

    view = stored["view"]
    hidden = stored["hidden"]

    %{
      view: if(view in ["table", "card"], do: view),
      hidden: if(is_list(hidden) and Enum.all?(hidden, &is_binary/1), do: hidden)
    }
  end

  @doc """
  Stores the selector choices (merge — a `nil` half keeps what is
  saved). Best-effort like `save_view/2`: no user, no crash, the choice
  just lives for the session.
  """
  @spec save_selector(map() | nil, %{
          optional(:view) => String.t(),
          optional(:hidden) => [String.t()]
        }) ::
          {:ok, map()} | {:error, term()}
  def save_selector(%Auth.User{} = user, choices) do
    current = user.custom_fields || %{}
    root = Map.get(current, @root, %{})
    stored = Map.get(root, @selector_key, %{})

    stored =
      stored
      |> then(fn s -> if v = choices[:view], do: Map.put(s, "view", v), else: s end)
      |> then(fn s -> if h = choices[:hidden], do: Map.put(s, "hidden", h), else: s end)

    merged = Map.put(current, @root, Map.put(root, @selector_key, stored))
    Auth.update_user_custom_fields(user, merged, ensure_definitions: false, broadcast: false)
  end

  def save_selector(_user, _choices), do: {:error, :no_user}

  @doc """
  `save_view/2` for a LiveView: stores the choice and puts the REFRESHED
  user back on the socket.

  Keeping the refreshed user is the whole point. Every write here merges
  one subtree into the user's entire `custom_fields` map and saves the
  result, so a socket still holding the pre-save user carries a snapshot
  that predates the view. The next column or filter save then merges
  into that snapshot and writes it back — deleting the view the user
  just chose, without an error anywhere. It surfaces one page later, as
  "my view didn't stick", which is the thing this feature exists to fix.
  """
  @spec save_view_on(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def save_view_on(socket, view) do
    case save_view(socket.assigns[:phoenix_kit_current_user], view) do
      {:ok, updated_user} ->
        Phoenix.Component.assign(socket, :phoenix_kit_current_user, updated_user)

      _ ->
        socket
    end
  end

  @spec normalize(TableConfig.scope(), map()) :: map()
  def normalize(scope, raw) when is_map(raw) do
    d = defaults(scope)

    cols =
      case TableConfig.validate_columns(scope, List.wrap(raw["columns"])) do
        [] -> d.columns
        list -> list
      end

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

  @spec save(map() | nil, TableConfig.scope(), map()) :: {:ok, map()} | {:error, term()}
  def save(%Auth.User{} = user, scope, cfg) do
    serialized = %{
      "columns" => cfg.columns,
      "sort_by" => cfg.sort_by,
      "sort_dir" => to_string(cfg.sort_dir),
      # The current folder is LOCATION, not a preference: it lives in
      # the URL (?folder=) like the detail page's ?category=, so it is
      # never persisted — a stored value made the index "remember" a
      # drill across sessions and devices with no link to share.
      # The view is module-wide (see the moduledoc) — `save_view/2` owns
      # it. Writing it per scope here is what let the surfaces drift.
      "filters" => Map.delete(cfg.filters, "folder")
    }

    current = user.custom_fields || %{}
    scoped = Map.put(Map.get(current, @root, %{}), scope_key(scope), serialized)
    merged = Map.put(current, @root, scoped)

    Auth.update_user_custom_fields(user, merged, ensure_definitions: false, broadcast: false)
  end

  # `update_user_custom_fields/3` matches a real `%Auth.User{}`; anything else
  # (nil, or the bare `%{uuid: uuid}` the LV test harness mounts with) used to
  # raise out of `put_cfg` and crash the LiveView on the first sort click.
  # Per-user persistence is best-effort — skip it rather than crash; callers
  # already treat any non-{:ok, user} as "keep the in-memory cfg only".
  def save(_user, _scope, _cfg), do: {:error, :no_user}
end
