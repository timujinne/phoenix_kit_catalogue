# Catalogue Admin Table Stack — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `/admin/catalogue`, `/admin/catalogue/suppliers`, and `/admin/catalogue/manufacturers` a control toolbar (search + filters + sort + view-toggle + column management + relocated action buttons), a table↔card view, and per-user-persisted column/sort/filter/view state — with the catalogues index flattened (folder filter + "Folders" modal instead of the inline tree).

**Architecture:** A self-contained mini-toolkit inside `phoenix_kit_catalogue` (no host-app deps): `TableConfig` (column metadata per scope), `TableQuery` (in-memory search/filter/sort), `ViewConfig` (per-user persistence in `users.custom_fields`), and a `column_settings_modal` component — all wired into the single `CataloguesLive` LiveView, rendering through phoenix_kit core's `<.table_default toggleable>`.

**Tech Stack:** Elixir/Phoenix LiveView, phoenix_kit core components (`table_default`, `modal`, `icon`, `SortableGrid` JS hook), Gettext (`PhoenixKitCatalogue.Gettext`), daisyUI 5.

## Global Constraints

- **No host-app dependencies** — `phoenix_kit_catalogue` is a standalone library. Use phoenix_kit **core** components only.
- **No new DB table / migration.** Per-user state lives in `phoenix_kit_users.custom_fields["catalogue_view_configs"]`.
- **Persist writes** use `PhoenixKit.Users.Auth.update_user_custom_fields(user, merged, ensure_definitions: false, broadcast: false)` — the `ensure_definitions: false` opt is mandatory.
- **Compile only via** `cd <host-app> && mix compile` (catalogue can't compile standalone — stale deps). Must be clean: no new warnings/errors.
- **Runtime verify:** `sudo /usr/bin/supervisorctl restart elixir` (path-dep, no hot reload), then HTTP 200 + Tidewave `project_eval` for logic + headless browser for UI.
- **Gettext:** add strings manually to `priv/gettext/default.pot` + `en`/`ru`/`et` `.po`. **Never** run `mix gettext.merge` (fuzzy pollution). Labels are lazy `fn -> Gettext.gettext(PhoenixKitCatalogue.Gettext, "...") end`.
- **daisyUI 5:** conditional classes via list syntax `class={["base", @flag && "x"]}`; flex/grid children that can overflow need `min-w-0`; never eyeball mobile — measure with a headless browser.
- **Commits:** work on `main`, one commit per task, message starts with a verb. **No** CHANGELOG.md / `@version` edits. **No** AI attribution.
- **Current user:** `socket.assigns.phoenix_kit_current_user` (full `%User{}` with `custom_fields` already loaded). `actor_uuid/1` in `Web.Helpers`.
- All edits are in `/www/phoenix_kit_catalogue/`.

---

## File Structure

**Create:**
- `lib/phoenix_kit_catalogue/web/table_config.ex` — `PhoenixKitCatalogue.Web.TableConfig`: column metadata per scope (`:catalogues | :suppliers | :manufacturers`).
- `lib/phoenix_kit_catalogue/web/table_query.ex` — `PhoenixKitCatalogue.Web.TableQuery`: pure search/filter/sort over a row list using TableConfig metadata.
- `lib/phoenix_kit_catalogue/web/view_config.ex` — `PhoenixKitCatalogue.Web.ViewConfig`: get/put per-user config in `custom_fields`.
- `lib/phoenix_kit_catalogue/web/table_toolbar.ex` — `PhoenixKitCatalogue.Web.TableToolbar`: the `column_settings_modal/1` component + small toolbar sub-components (sort select, filter selects). (Keeps `catalogues_live.ex` from ballooning.)
- `test/web/table_config_test.exs`, `test/web/table_query_test.exs`, `test/web/view_config_test.exs` — pure unit tests (runnable once the catalogue test env is set up; mirrored by Tidewave evals in-session).

**Modify:**
- `lib/phoenix_kit_catalogue/web/catalogues_live.ex` — mount loads `@view_configs`; new event handlers; three table renders rewired; folders modal; remove tree + global item search.
- `priv/gettext/default.pot` + `priv/gettext/{en,ru,et}/LC_MESSAGES/default.po` — new strings.

---

## Task 1: `TableConfig` — column metadata per scope

**Files:**
- Create: `lib/phoenix_kit_catalogue/web/table_config.ex`
- Test: `test/web/table_config_test.exs`

**Interfaces:**
- Produces:
  - `TableConfig.columns(scope) :: [col]` where `scope in [:catalogues, :suppliers, :manufacturers]`
  - `TableConfig.default_columns(scope) :: [String.t()]` (managed defaults, in order)
  - `TableConfig.column_map(scope) :: %{String.t() => col}`
  - `TableConfig.managed_columns(scope) :: [col]` (those with `managed?: true`)
  - `TableConfig.validate_columns(scope, [id]) :: [id]` (known managed ids, dedup, order preserved)
  - `TableConfig.sortable_visible(scope, [id]) :: [col]` (sortable cols among the given ids)
  - `TableConfig.default_sort(scope) :: {id, :asc | :desc}`
  - `col` map keys: `:id` (String), `:label` (0-arity fn), `:default?` (bool), `:managed?` (bool), `:sortable?` (bool), `:sort_key` (1-arity fn | nil), `:align` (`:left|:right`), `:filterable?` (bool), `:filter_type` (`:enum | nil`).

- [ ] **Step 1: Write the module.**

```elixir
defmodule PhoenixKitCatalogue.Web.TableConfig do
  @moduledoc """
  Column metadata for the catalogue admin tables, keyed by scope
  (`:catalogues`, `:suppliers`, `:manufacturers`). Pure data — cell and
  card rendering live in the LiveView. Labels are zero-arity fns so they
  resolve in the request's current locale.
  """
  alias PhoenixKitCatalogue.Gettext, as: G

  @type scope :: :catalogues | :suppliers | :manufacturers
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
      col("name", fn -> g("Name") end, default?: true, managed?: false, sortable?: true,
        sort_key: &down(&1.name)),
      col("folder", fn -> g("Folder") end, default?: true, sortable?: true,
        sort_key: &down(&1[:folder_name]), filterable?: true, filter_type: :enum),
      col("items", fn -> g("Items") end, default?: true, sortable?: true,
        align: :right, sort_key: &(&1[:item_count] || 0)),
      col("status", fn -> g("Status") end, default?: true, sortable?: true,
        sort_key: &down(&1.status), filterable?: true, filter_type: :enum),
      col("kind", fn -> g("Kind") end, sortable?: true, sort_key: &down(&1.kind),
        filterable?: true, filter_type: :enum),
      col("markup", fn -> g("Markup %") end, sortable?: true, align: :right,
        sort_key: &dec(&1.markup_percentage)),
      col("discount", fn -> g("Discount %") end, sortable?: true, align: :right,
        sort_key: &dec(&1.discount_percentage)),
      col("updated", fn -> g("Updated") end, default?: true, sortable?: true,
        sort_key: & &1.updated_at),
      col("created", fn -> g("Created") end, sortable?: true, sort_key: & &1.inserted_at)
    ]
  end

  def columns(scope) when scope in [:suppliers, :manufacturers] do
    [
      col("name", fn -> g("Name") end, default?: true, managed?: false, sortable?: true,
        sort_key: &down(&1.name)),
      col("website", fn -> g("Website") end, default?: true, sortable?: true,
        sort_key: &down(&1.website)),
      col("status", fn -> g("Status") end, default?: true, sortable?: true,
        sort_key: &down(&1.status), filterable?: true, filter_type: :enum),
      col("contact_info", fn -> g("Contact Info") end, sortable?: true,
        sort_key: &down(&1.contact_info)),
      col("updated", fn -> g("Updated") end, sortable?: true, sort_key: & &1.updated_at)
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
  def default_sort(:catalogues), do: {"name", :asc}
  def default_sort(_), do: {"name", :asc}

  # sort helpers: case-insensitive for strings, Decimal→float, nil-safe.
  defp down(nil), do: ""
  defp down(s) when is_binary(s), do: String.downcase(s)
  defp down(other), do: other

  defp dec(%Decimal{} = d), do: Decimal.to_float(d)
  defp dec(n) when is_number(n), do: n
  defp dec(_), do: 0.0
end
```

- [ ] **Step 2: Write the unit test.**

```elixir
defmodule PhoenixKitCatalogue.Web.TableConfigTest do
  use ExUnit.Case, async: true
  alias PhoenixKitCatalogue.Web.TableConfig, as: TC

  test "catalogues defaults are the visible managed+name set, in order" do
    assert TC.default_columns(:catalogues) == ["name", "folder", "items", "status", "updated"]
  end

  test "name is always present but not managed (never hidden via modal)" do
    refute Enum.any?(TC.managed_columns(:catalogues), &(&1.id == "name"))
    assert TC.column_map(:catalogues)["name"].managed? == false
  end

  test "validate_columns drops unknown + non-managed ids and dedups" do
    assert TC.validate_columns(:catalogues, ["items", "items", "bogus", "name"]) == ["items"]
  end

  test "sortable_visible keeps only sortable, in given order" do
    ids = ["status", "name", "markup"]
    assert Enum.map(TC.sortable_visible(:catalogues, ids), & &1.id) == ids
  end

  test "suppliers/manufacturers share the column shape" do
    assert TC.default_columns(:suppliers) == ["name", "website", "status"]
    assert TC.default_columns(:manufacturers) == ["name", "website", "status"]
  end
end
```

- [ ] **Step 3: Compile via the app.**

Run: `cd <host-app> && mix compile 2>&1 | grep -iE "table_config|error|warning: " | head`
Expected: no errors/warnings referencing `table_config.ex`.

- [ ] **Step 4: Verify behavior on the live node.**

After `sudo /usr/bin/supervisorctl restart elixir` (wait for HTTP 200), Tidewave `project_eval`:
```elixir
{PhoenixKitCatalogue.Web.TableConfig.default_columns(:catalogues),
 PhoenixKitCatalogue.Web.TableConfig.validate_columns(:catalogues, ["items","bogus","name"]),
 Enum.map(PhoenixKitCatalogue.Web.TableConfig.sortable_visible(:catalogues, ["status","name"]), & &1.id)}
```
Expected: `{["name","folder","items","status","updated"], ["items"], ["status","name"]}`

- [ ] **Step 5: Commit.**

```bash
cd /www/phoenix_kit_catalogue
git add lib/phoenix_kit_catalogue/web/table_config.ex test/web/table_config_test.exs
git commit -m "Add TableConfig column metadata for catalogue admin tables"
```

---

## Task 2: `TableQuery` — in-memory search/filter/sort

**Files:**
- Create: `lib/phoenix_kit_catalogue/web/table_query.ex`
- Test: `test/web/table_query_test.exs`

**Interfaces:**
- Consumes: `TableConfig.column_map/1`, `TableConfig.columns/1`.
- Produces:
  - `TableQuery.apply(rows, scope, %{search: str, filters: %{id=>val}, sort_by: id, sort_dir: :asc|:desc}) :: [row]`
  - `TableQuery.search(rows, str) :: [row]` (case-insensitive substring on `row.name`)
  - `TableQuery.filter(rows, scope, filters) :: [row]`
  - `TableQuery.sort(rows, scope, sort_by, dir) :: [row]`
  - `TableQuery.enum_options(rows, scope, col_id) :: [{value, label}]` (distinct present values for an enum filter column; `folder` uses `row[:folder_name]`, others use the field named by `col_id`)

- [ ] **Step 1: Write the module.**

```elixir
defmodule PhoenixKitCatalogue.Web.TableQuery do
  @moduledoc """
  Pure, in-memory search → filter → sort pipeline over a list of row maps
  (catalogues/suppliers/manufacturers already loaded by the LiveView).
  """
  alias PhoenixKitCatalogue.Web.TableConfig

  @spec apply([map()], TableConfig.scope(), map()) :: [map()]
  def apply(rows, scope, opts) do
    rows
    |> search(Map.get(opts, :search, ""))
    |> filter(scope, Map.get(opts, :filters, %{}))
    |> sort(scope, Map.get(opts, :sort_by), Map.get(opts, :sort_dir, :asc))
  end

  @spec search([map()], String.t() | nil) :: [map()]
  def search(rows, q) when is_binary(q) and q != "" do
    needle = String.downcase(q)
    Enum.filter(rows, fn r -> String.contains?(String.downcase(r.name || ""), needle) end)
  end

  def search(rows, _), do: rows

  @spec filter([map()], TableConfig.scope(), map()) :: [map()]
  def filter(rows, scope, filters) when is_map(filters) do
    Enum.reduce(filters, rows, fn
      {_id, val}, acc when val in [nil, "", "all"] -> acc
      {id, val}, acc -> Enum.filter(acc, &filter_match?(scope, id, &1, val))
    end)
  end

  def filter(rows, _scope, _), do: rows

  defp filter_match?(_scope, "folder", row, val), do: to_string(row[:folder_uuid]) == val
  defp filter_match?(_scope, id, row, val), do: to_string(Map.get(row, String.to_existing_atom(id))) == val

  @spec sort([map()], TableConfig.scope(), String.t() | nil, :asc | :desc) :: [map()]
  def sort(rows, scope, sort_by, dir) when is_binary(sort_by) do
    case TableConfig.column_map(scope)[sort_by] do
      %{sort_key: key} when is_function(key, 1) -> Enum.sort_by(rows, key, dir)
      _ -> rows
    end
  end

  def sort(rows, _scope, _sort_by, _dir), do: rows

  @spec enum_options([map()], TableConfig.scope(), String.t()) :: [{String.t(), String.t()}]
  def enum_options(rows, _scope, "folder") do
    rows
    |> Enum.map(&{to_string(&1[:folder_uuid]), &1[:folder_name]})
    |> Enum.reject(fn {uuid, _} -> uuid in ["", "nil"] end)
    |> Enum.uniq()
    |> Enum.sort_by(fn {_u, name} -> String.downcase(name || "") end)
  end

  def enum_options(rows, _scope, id) do
    key = String.to_existing_atom(id)

    rows
    |> Enum.map(&to_string(Map.get(&1, key)))
    |> Enum.reject(&(&1 in ["", "nil"]))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&{&1, &1})
  end
end
```

- [ ] **Step 2: Write the unit test.** (Uses plain maps mirroring the row shape the LiveView builds.)

```elixir
defmodule PhoenixKitCatalogue.Web.TableQueryTest do
  use ExUnit.Case, async: true
  alias PhoenixKitCatalogue.Web.TableQuery, as: Q

  defp rows do
    [
      %{name: "Beta", status: "active", item_count: 3, folder_uuid: "f1", folder_name: "Kitchen", updated_at: ~U[2026-01-02 00:00:00Z]},
      %{name: "alpha", status: "archived", item_count: 9, folder_uuid: nil, folder_name: nil, updated_at: ~U[2026-01-01 00:00:00Z]}
    ]
  end

  test "search is case-insensitive substring on name" do
    assert Enum.map(Q.search(rows(), "al"), & &1.name) == ["alpha"]
    assert Q.search(rows(), "") == rows()
  end

  test "filter by status; 'all'/nil are no-ops" do
    assert Enum.map(Q.filter(rows(), :catalogues, %{"status" => "active"}), & &1.name) == ["Beta"]
    assert Q.filter(rows(), :catalogues, %{"status" => "all"}) == rows()
  end

  test "filter by folder uuid" do
    assert Enum.map(Q.filter(rows(), :catalogues, %{"folder" => "f1"}), & &1.name) == ["Beta"]
  end

  test "sort by name is case-insensitive; dir respected" do
    assert Enum.map(Q.sort(rows(), :catalogues, "name", :asc), & &1.name) == ["alpha", "Beta"]
    assert Enum.map(Q.sort(rows(), :catalogues, "name", :desc), & &1.name) == ["Beta", "alpha"]
  end

  test "enum_options for folder skips unfiled and dedups" do
    assert Q.enum_options(rows(), :catalogues, "folder") == [{"f1", "Kitchen"}]
  end
end
```

- [ ] **Step 3: Compile via the app.** Run `cd <host-app> && mix compile` — clean re: `table_query.ex`.

- [ ] **Step 4: Verify on live node** (after restart) via Tidewave `project_eval`:
```elixir
rows = [%{name: "Beta", status: "active", folder_uuid: "f1", folder_name: "Kitchen"},
        %{name: "alpha", status: "archived", folder_uuid: nil, folder_name: nil}]
{Enum.map(PhoenixKitCatalogue.Web.TableQuery.apply(rows, :catalogues,
   %{search: "a", filters: %{"status" => "all"}, sort_by: "name", sort_dir: :asc}), & &1.name),
 PhoenixKitCatalogue.Web.TableQuery.enum_options(rows, :catalogues, "folder")}
```
Expected: `{["alpha", "Beta"], [{"f1", "Kitchen"}]}`

- [ ] **Step 5: Commit.**
```bash
git add lib/phoenix_kit_catalogue/web/table_query.ex test/web/table_query_test.exs
git commit -m "Add TableQuery in-memory search/filter/sort pipeline"
```

---

## Task 3: `ViewConfig` — per-user persistence in custom_fields

**Files:**
- Create: `lib/phoenix_kit_catalogue/web/view_config.ex`
- Test: `test/web/view_config_test.exs` (pure merge logic only; the DB write is verified at runtime)

**Interfaces:**
- Consumes: `TableConfig.default_columns/1`, `TableConfig.validate_columns/2`, `TableConfig.default_sort/1`; `PhoenixKit.Users.Auth.update_user_custom_fields/3`.
- Produces:
  - `ViewConfig.scope_key(scope) :: String.t()` (`"catalogues"|"suppliers"|"manufacturers"`)
  - `ViewConfig.defaults(scope) :: cfg` where `cfg = %{columns: [id], sort_by: id, sort_dir: :asc|:desc, filters: %{}, view: "table"}` (atom keys, in-memory shape)
  - `ViewConfig.load(user, scope) :: cfg` — reads `custom_fields`, normalizes over defaults
  - `ViewConfig.save(user, scope, cfg) :: {:ok, %User{}} | {:error, term}`
  - `ViewConfig.normalize(scope, raw_map) :: cfg` (string-keyed raw → atom-keyed cfg, validated)

- [ ] **Step 1: Write the module.**

```elixir
defmodule PhoenixKitCatalogue.Web.ViewConfig do
  @moduledoc """
  Per-user table view config (columns / sort / filters / view mode) for the
  catalogue admin tables. Stored in `phoenix_kit_users.custom_fields` under
  the `"catalogue_view_configs"` key — no dedicated table. Precedent:
  `PhoenixKit.Notifications.Prefs`.
  """
  alias PhoenixKit.Users.Auth
  alias PhoenixKitCatalogue.Web.TableConfig

  @root "catalogue_view_configs"

  @spec scope_key(TableConfig.scope()) :: String.t()
  def scope_key(scope), do: to_string(scope)

  @spec defaults(TableConfig.scope()) :: map()
  def defaults(scope) do
    {sort_by, sort_dir} = TableConfig.default_sort(scope)
    %{columns: TableConfig.default_columns(scope), sort_by: sort_by, sort_dir: sort_dir,
      filters: %{}, view: "table"}
  end

  @spec load(map() | nil, TableConfig.scope()) :: map()
  def load(user, scope) do
    raw =
      case user do
        %{custom_fields: cf} when is_map(cf) -> get_in(cf, [@root, scope_key(scope)]) || %{}
        _ -> %{}
      end

    normalize(scope, raw)
  end

  @spec normalize(TableConfig.scope(), map()) :: map()
  def normalize(scope, raw) when is_map(raw) do
    d = defaults(scope)

    cols =
      case TableConfig.validate_columns(scope, List.wrap(raw["columns"])) do
        [] -> d.columns
        list -> list
      end

    %{
      columns: cols,
      sort_by: raw["sort_by"] || d.sort_by,
      sort_dir: dir(raw["sort_dir"], d.sort_dir),
      filters: (is_map(raw["filters"]) && raw["filters"]) || %{},
      view: (raw["view"] in ["table", "card"] && raw["view"]) || "table"
    }
  end

  def normalize(scope, _), do: defaults(scope)

  defp dir("desc", _), do: :desc
  defp dir("asc", _), do: :asc
  defp dir(_, fallback), do: fallback

  @spec save(map(), TableConfig.scope(), map()) :: {:ok, map()} | {:error, term()}
  def save(user, scope, cfg) do
    serialized = %{
      "columns" => cfg.columns,
      "sort_by" => cfg.sort_by,
      "sort_dir" => to_string(cfg.sort_dir),
      "filters" => cfg.filters,
      "view" => cfg.view
    }

    current = user.custom_fields || %{}
    scoped = Map.put(Map.get(current, @root, %{}), scope_key(scope), serialized)
    merged = Map.put(current, @root, scoped)

    Auth.update_user_custom_fields(user, merged, ensure_definitions: false, broadcast: false)
  end
end
```

- [ ] **Step 2: Write the unit test** (normalize only — no DB):

```elixir
defmodule PhoenixKitCatalogue.Web.ViewConfigTest do
  use ExUnit.Case, async: true
  alias PhoenixKitCatalogue.Web.ViewConfig, as: VC

  test "defaults shape" do
    assert %{columns: ["name", "folder", "items", "status", "updated"], sort_by: "name",
             sort_dir: :asc, filters: %{}, view: "table"} = VC.defaults(:catalogues)
  end

  test "normalize falls back on empty/invalid, keeps valid" do
    assert VC.normalize(:catalogues, %{}) == VC.defaults(:catalogues)
    got = VC.normalize(:catalogues, %{"columns" => ["items", "bogus"], "sort_dir" => "desc", "view" => "card"})
    assert got.columns == ["items"]
    assert got.sort_dir == :desc
    assert got.view == "card"
  end

  test "load reads from a user struct's custom_fields" do
    user = %{custom_fields: %{"catalogue_view_configs" => %{"suppliers" => %{"view" => "card"}}}}
    assert VC.load(user, :suppliers).view == "card"
    assert VC.load(%{custom_fields: nil}, :suppliers) == VC.defaults(:suppliers)
  end
end
```

- [ ] **Step 3: Compile via the app** — clean re: `view_config.ex`. Confirm `PhoenixKit.Users.Auth.update_user_custom_fields/3` arity exists:
  `cd <host-app> && mix compile` then Tidewave `project_eval`: `function_exported?(PhoenixKit.Users.Auth, :update_user_custom_fields, 3)` → `true`.

- [ ] **Step 4: Verify normalize on live node** via `project_eval`:
```elixir
PhoenixKitCatalogue.Web.ViewConfig.normalize(:catalogues,
  %{"columns" => ["items","bogus"], "sort_dir" => "desc", "view" => "card"})
```
Expected: `%{columns: ["items"], sort_by: "name", sort_dir: :desc, filters: %{}, view: "card"}`

- [ ] **Step 5: Commit.**
```bash
git add lib/phoenix_kit_catalogue/web/view_config.ex test/web/view_config_test.exs
git commit -m "Add ViewConfig per-user table state persistence"
```

---

## Task 4: `TableToolbar` — column-settings modal + toolbar sub-components

**Files:**
- Create: `lib/phoenix_kit_catalogue/web/table_toolbar.ex`

**Interfaces:**
- Consumes: `TableConfig`, core `<.modal>`/`<.icon>`, the `SortableGrid` JS hook (already in the module's JS).
- Produces (function components, `use Phoenix.Component`):
  - `column_settings_modal(assigns)` — attrs: `show` (bool), `scope` (atom), `selected` ([id], ordered), `temp_selected` ([id]|nil). Emits events: `add_column` (`column_id`), `remove_column` (`column_id`), `reorder_columns` (`ordered_ids` CSV via SortableGrid), `reset_columns`, `apply_columns` (form submit, hidden `column_order` CSV), `hide_column_modal`.
  - `sort_controls(assigns)` — attrs: `scope`, `selected` ([id]), `sort_by`, `sort_dir`. Emits `set_sort` (select), `flip_sort_dir` (button).
  - `enum_filter(assigns)` — attrs: `id`, `label`, `value`, `options` ([{val,label}]), `prompt`. Emits `set_filter` (`column_id`, `value`) / `clear_filter`.

- [ ] **Step 1: Write the component module.** Full code:

```elixir
defmodule PhoenixKitCatalogue.Web.TableToolbar do
  @moduledoc """
  Toolbar pieces for the catalogue admin tables: the column-settings modal,
  the sort select+direction control, and an enum filter select. All emit
  plain events handled by `CataloguesLive` against the active scope.
  """
  use Phoenix.Component

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Modal, only: [modal: 1]
  import PhoenixKitWeb.Components.Core.Select, only: [select: 1]

  alias PhoenixKitCatalogue.Gettext, as: G
  alias PhoenixKitCatalogue.Web.TableConfig

  defp g(s), do: Gettext.gettext(G, s)

  attr :show, :boolean, required: true
  attr :scope, :atom, required: true
  attr :selected, :list, required: true
  attr :temp_selected, :list, default: nil

  def column_settings_modal(assigns) do
    assigns =
      assigns
      |> assign(:current, assigns.temp_selected || assigns.selected)
      |> assign(:map, TableConfig.column_map(assigns.scope))
      |> assign(:available, TableConfig.managed_columns(assigns.scope))

    assigns =
      assign(assigns, :hidden, Enum.reject(assigns.available, &(&1.id in assigns.current)))

    ~H"""
    <.modal :if={@show} id="catalogue-columns-modal" show on_cancel={JS_hide()}>
      <form phx-submit="apply_columns">
        <input type="hidden" name="column_order" value={Enum.join(@current, ",")} id="catalogue-columns-order" />
        <h3 class="text-lg font-semibold mb-3">{g("Columns")}</h3>
        <div class="grid grid-cols-2 gap-4">
          <div>
            <p class="text-xs uppercase text-base-content/50 mb-2">{g("Shown")}</p>
            <ul
              id="catalogue-columns-selected"
              phx-hook="SortableGrid"
              data-sortable="true"
              data-sortable-event="reorder_columns"
              data-sortable-items=".col-item"
              class="space-y-1"
            >
              <li :for={id <- @current} :if={@map[id] && @map[id].managed?} data-id={id}
                  class="col-item flex items-center gap-2 px-2 py-1 rounded bg-base-200">
                <.icon name="hero-bars-3" class="w-4 h-4 pk-drag-handle cursor-grab text-base-content/40" />
                <span class="flex-1 text-sm">{@map[id].label.()}</span>
                <button type="button" phx-click="remove_column" phx-value-column_id={id}
                        class="btn btn-ghost btn-xs btn-square text-error">
                  <.icon name="hero-x-mark" class="w-4 h-4" />
                </button>
              </li>
            </ul>
          </div>
          <div>
            <p class="text-xs uppercase text-base-content/50 mb-2">{g("Available")}</p>
            <ul class="space-y-1">
              <li :for={c <- @hidden} class="flex items-center gap-2 px-2 py-1 rounded hover:bg-base-200">
                <button type="button" phx-click="add_column" phx-value-column_id={c.id}
                        class="flex items-center gap-2 w-full text-left text-sm">
                  <.icon name="hero-plus" class="w-4 h-4 text-base-content/40" />
                  <span>{c.label.()}</span>
                </button>
              </li>
            </ul>
          </div>
        </div>
        <div class="flex justify-between mt-4">
          <button type="button" phx-click="reset_columns" class="btn btn-ghost btn-sm">{g("Reset")}</button>
          <div class="flex gap-2">
            <button type="button" phx-click="hide_column_modal" class="btn btn-ghost btn-sm">{g("Cancel")}</button>
            <button type="submit" class="btn btn-primary btn-sm">{g("Apply")}</button>
          </div>
        </div>
      </form>
    </.modal>
    """
  end

  # Closing the modal via the X / backdrop just pushes the same cancel event.
  defp JS_hide, do: Phoenix.LiveView.JS.push("hide_column_modal")

  attr :scope, :atom, required: true
  attr :selected, :list, required: true
  attr :sort_by, :string, required: true
  attr :sort_dir, :atom, required: true

  def sort_controls(assigns) do
    assigns = assign(assigns, :options, TableConfig.sortable_visible(assigns.scope, assigns.selected))

    ~H"""
    <form phx-change="set_sort" class="join">
      <select name="sort_by" class="select select-sm join-item">
        <option :for={c <- @options} value={c.id} selected={@sort_by == c.id}>{c.label.()}</option>
      </select>
      <button type="button" phx-click="flip_sort_dir" class="btn btn-sm btn-ghost join-item"
              title={g("Toggle sort direction")}>
        <.icon name={if @sort_dir == :asc, do: "hero-chevron-up", else: "hero-chevron-down"} class="w-4 h-4" />
      </button>
    </form>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, default: nil
  attr :options, :list, required: true
  attr :prompt, :string, required: true

  def enum_filter(assigns) do
    ~H"""
    <form phx-change="set_filter" class="contents">
      <input type="hidden" name="column_id" value={@id} />
      <.select name="value" id={"filter-#{@id}"} value={@value} prompt={@prompt}
               options={@options} class="select-sm" aria-label={@label} />
    </form>
    """
  end
end
```

- [ ] **Step 2: Compile via the app.** Run `cd <host-app> && mix compile` — clean re: `table_toolbar.ex`. (Confirm core modules `...Core.Modal`, `...Core.Select`, `...Core.Icon` export `modal/1`, `select/1`, `icon/1` — they're used elsewhere in this module already.)

- [ ] **Step 3: Commit.**
```bash
git add lib/phoenix_kit_catalogue/web/table_toolbar.ex
git commit -m "Add TableToolbar column-settings modal and toolbar controls"
```

> No runtime UI test here — the components render only once wired into `CataloguesLive` (Task 6+). Compilation + attr validation is the gate.

---

## Task 5: `CataloguesLive` — view-config state + shared event handlers

This task adds the state plumbing and event handlers WITHOUT yet changing the table renders. After it, the LV holds per-scope config and reacts to toolbar events; the tables still render as before (next tasks switch them over).

**Files:**
- Modify: `lib/phoenix_kit_catalogue/web/catalogues_live.ex` (mount, new handlers, helpers)

**Interfaces:**
- Consumes: `ViewConfig.load/2`, `ViewConfig.save/3`, `TableConfig`, `TableQuery`.
- Produces (assigns other tasks rely on):
  - `@view_configs :: %{catalogues: cfg, suppliers: cfg, manufacturers: cfg}` (cfg = atom-keyed map from ViewConfig)
  - `@show_column_modal :: boolean`, `@temp_columns :: [id] | nil`
  - helpers: `active_scope(assigns) :: atom`, `current_cfg(assigns) :: cfg`, `put_cfg(socket, scope, cfg) :: socket` (assigns + persists)

- [ ] **Step 1: Add scope mapping + mount load.** In `mount/3`, after existing assigns, add:

```elixir
|> assign(:view_configs, load_view_configs(socket))
|> assign(:show_column_modal, false)
|> assign(:temp_columns, nil)
```

And helpers (place near `tab_title/1`):

```elixir
# Maps the active UI tab to a TableConfig/ViewConfig scope.
defp active_scope(%{assigns: a}), do: active_scope(a)
defp active_scope(%{active_tab: :index}), do: :catalogues
defp active_scope(%{active_tab: :manufacturers}), do: :manufacturers
defp active_scope(%{active_tab: :suppliers}), do: :suppliers

defp load_view_configs(socket) do
  user = socket.assigns[:phoenix_kit_current_user]
  Map.new([:catalogues, :suppliers, :manufacturers], fn scope ->
    {scope, PhoenixKitCatalogue.Web.ViewConfig.load(user, scope)}
  end)
end

defp current_cfg(assigns), do: Map.fetch!(assigns.view_configs, active_scope(assigns))

# Update one scope's cfg in assigns AND persist to the user row.
defp put_cfg(socket, scope, cfg) do
  user = socket.assigns[:phoenix_kit_current_user]
  _ = PhoenixKitCatalogue.Web.ViewConfig.save(user, scope, cfg)
  assign(socket, :view_configs, Map.put(socket.assigns.view_configs, scope, cfg))
end
```

- [ ] **Step 2: Add the toolbar/column event handlers.** Place with the other `handle_event/3` clauses:

```elixir
@impl true
def handle_event("show_column_modal", _p, socket) do
  {:noreply, assign(socket, show_column_modal: true, temp_columns: current_cfg(socket.assigns).columns)}
end

def handle_event("hide_column_modal", _p, socket),
  do: {:noreply, assign(socket, show_column_modal: false, temp_columns: nil)}

def handle_event("add_column", %{"column_id" => id}, socket) do
  {:noreply, update(socket, :temp_columns, &((&1 || []) ++ [id]))}
end

def handle_event("remove_column", %{"column_id" => id}, socket) do
  {:noreply, update(socket, :temp_columns, &Enum.reject(&1 || [], fn c -> c == id end))}
end

def handle_event("reorder_columns", params, socket) do
  ids = parse_order(params)
  {:noreply, assign(socket, :temp_columns, ids)}
end

def handle_event("reset_columns", _p, socket) do
  {:noreply, assign(socket, :temp_columns, PhoenixKitCatalogue.Web.TableConfig.default_columns(active_scope(socket.assigns)))}
end

def handle_event("apply_columns", params, socket) do
  scope = active_scope(socket.assigns)
  ids = PhoenixKitCatalogue.Web.TableConfig.validate_columns(scope, parse_order(params) || socket.assigns.temp_columns || [])
  ids = if ids == [], do: PhoenixKitCatalogue.Web.TableConfig.default_columns(scope), else: ids
  cfg = %{current_cfg(socket.assigns) | columns: ids}
  cfg = if cfg.sort_by in ids, do: cfg, else: %{cfg | sort_by: List.first(ids)}
  {:noreply, socket |> put_cfg(scope, cfg) |> assign(show_column_modal: false, temp_columns: nil)}
end

def handle_event("set_sort", %{"sort_by" => by}, socket) do
  scope = active_scope(socket.assigns)
  {:noreply, put_cfg(socket, scope, %{current_cfg(socket.assigns) | sort_by: by})}
end

def handle_event("flip_sort_dir", _p, socket) do
  scope = active_scope(socket.assigns)
  cfg = current_cfg(socket.assigns)
  {:noreply, put_cfg(socket, scope, %{cfg | sort_dir: flip(cfg.sort_dir)})}
end

def handle_event("toggle_sort", %{"by" => by}, socket) do
  scope = active_scope(socket.assigns)
  cfg = current_cfg(socket.assigns)
  dir = if cfg.sort_by == by, do: flip(cfg.sort_dir), else: :asc
  {:noreply, put_cfg(socket, scope, %{cfg | sort_by: by, sort_dir: dir})}
end

def handle_event("set_filter", %{"column_id" => id, "value" => val}, socket) do
  scope = active_scope(socket.assigns)
  cfg = current_cfg(socket.assigns)
  filters = if val in [nil, "", "all"], do: Map.delete(cfg.filters, id), else: Map.put(cfg.filters, id, val)
  {:noreply, put_cfg(socket, scope, %{cfg | filters: filters})}
end

def handle_event("clear_filter", %{"column_id" => id}, socket) do
  scope = active_scope(socket.assigns)
  cfg = current_cfg(socket.assigns)
  {:noreply, put_cfg(socket, scope, %{cfg | filters: Map.delete(cfg.filters, id)})}
end

def handle_event("set_view", %{"view" => v}, socket) when v in ["table", "card"] do
  scope = active_scope(socket.assigns)
  {:noreply, put_cfg(socket, scope, %{current_cfg(socket.assigns) | view: v})}
end
```

Helpers:
```elixir
defp flip(:asc), do: :desc
defp flip(_), do: :asc

# SortableGrid sends "ordered_ids"/"order" (list) or "column_order" (csv).
defp parse_order(%{"ordered_ids" => ids}) when is_list(ids), do: ids
defp parse_order(%{"order" => ids}) when is_list(ids), do: ids
defp parse_order(%{"column_order" => csv}) when is_binary(csv), do: String.split(csv, ",", trim: true)
defp parse_order(_), do: nil
```

> NOTE: the existing `"search"` handler currently drives the GLOBAL ITEM search. It is repurposed in Task 7 (catalogues). For suppliers/manufacturers (Task 6) the search filters the table. To avoid a clash, Task 6/7 introduce a single `"table_search"` event for the toolbar search and remove the old global-search `"search"` handler in Task 7.

- [ ] **Step 3: Compile via the app.** `cd <host-app> && mix compile` — clean. (Handlers are unused until renders call them — that's fine; Elixir won't warn on handle_event clauses.)

- [ ] **Step 4: Commit.**
```bash
git add lib/phoenix_kit_catalogue/web/catalogues_live.ex
git commit -m "Wire per-scope view-config state and toolbar event handlers in CataloguesLive"
```

---

## Task 6: Suppliers + Manufacturers — dynamic columns, toolbar, card view

Suppliers and manufacturers are structurally identical; build ONE shared render helper `simple_table/1` (private to `catalogues_live.ex`) driven by scope + the visible columns, and a shared toolbar. Replace `manufacturers_table/1` and `suppliers_table/1`.

**Files:**
- Modify: `lib/phoenix_kit_catalogue/web/catalogues_live.ex`

**Interfaces:**
- Consumes: Task 5 assigns/handlers; `TableConfig`, `TableQuery`, `TableToolbar`; core `<.table_default>`.
- Produces: `simple_table/1` + `table_toolbar/1` private components reused by Task 7.

- [ ] **Step 1: Import the toolbar + add the derived-rows helper.** Add to imports:
```elixir
import PhoenixKitCatalogue.Web.TableToolbar
```
Add helper:
```elixir
# Visible columns (col maps) for a scope per the user's cfg, in order.
defp visible_columns(scope, cfg) do
  map = PhoenixKitCatalogue.Web.TableConfig.column_map(scope)
  (["name"] ++ cfg.columns) |> Enum.uniq() |> Enum.map(&map[&1]) |> Enum.reject(&is_nil/1)
end

# Apply search/filter/sort to a raw list for the active scope.
defp derive_rows(rows, scope, cfg) do
  PhoenixKitCatalogue.Web.TableQuery.apply(rows, scope,
    %{search: cfg[:search] || "", filters: cfg.filters, sort_by: cfg.sort_by, sort_dir: cfg.sort_dir})
end
```
(Add a transient `:search` key into cfg in assigns — it is NOT persisted; keep it only in the in-memory cfg. Adjust `ViewConfig.save` already ignores unknown keys since it serializes explicit keys; confirm `:search` is never written. It isn't — `save/3` only writes columns/sort/filters/view.)

Add the `"table_search"` handler (used by the toolbar search for all scopes):
```elixir
def handle_event("table_search", %{"query" => q}, socket) do
  scope = active_scope(socket.assigns)
  cfg = Map.put(current_cfg(socket.assigns), :search, q)
  {:noreply, assign(socket, :view_configs, Map.put(socket.assigns.view_configs, scope, cfg))}
end
```
(Search is not persisted, so update assigns directly — do not call `put_cfg`.)

- [ ] **Step 2: Add the shared toolbar component** (private function component in the LV):
```elixir
attr :scope, :atom, required: true
attr :cfg, :map, required: true
attr :rows, :list, required: true
slot :filters
slot :actions

defp table_toolbar(assigns) do
  ~H"""
  <div class="flex flex-wrap items-center gap-2 mb-3">
    <form phx-change="table_search" class="contents">
      <label class="input input-sm w-full sm:w-64">
        <.icon name="hero-magnifying-glass" class="h-4 w-4 opacity-50" />
        <input type="search" name="query" value={@cfg[:search] || ""} phx-debounce="300"
               placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search...")} class="grow" />
      </label>
    </form>
    {render_slot(@filters)}
    <div class="flex-1"></div>
    <.sort_controls scope={@scope} selected={@cfg.columns} sort_by={@cfg.sort_by} sort_dir={@cfg.sort_dir} />
    <button type="button" phx-click="show_column_modal" class="btn btn-outline btn-sm">
      <.icon name="hero-adjustments-horizontal" class="w-4 h-4" />
      <span class="hidden sm:inline">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Columns")}</span>
    </button>
    {render_slot(@actions)}
  </div>
  """
end
```

- [ ] **Step 3: Add the generic `simple_table/1`** (table+card, dynamic columns). It renders `name` as a link via a passed `edit_path` fn, other cells via `render_cell/3`, and actions via a slot.
```elixir
attr :scope, :atom, required: true
attr :cfg, :map, required: true
attr :rows, :list, required: true
attr :empty, :string, required: true
slot :row_actions, required: true   # :let={row}
slot :card_actions, required: true  # :let={row}

defp simple_table(assigns) do
  assigns = assign(assigns, :cols, visible_columns(assigns.scope, assigns.cfg))

  ~H"""
  <div :if={@rows == []} class="card bg-base-100 shadow">
    <div class="card-body items-center text-center py-12">
      <p class="text-base-content/60">{@empty}</p>
    </div>
  </div>

  <.table_default :if={@rows != []}
    id={"#{@scope}-table"} variant="zebra" size="sm" toggleable view_mode={@cfg.view}
    view_event="set_view" items={@rows}
    card_fields={fn row -> for c <- @cols, c.id != "name", do:
      %{label: c.label.(), value: render_card_value(@scope, c.id, row)} end}>
    <.table_default_header>
      <.table_default_row>
        <.table_default_header_cell :for={c <- @cols} class={c.align == :right && "text-right"}>
          <.sort_header :if={c.sortable?} by={c.id} label={c.label.()} sort_by={@cfg.sort_by} sort_dir={@cfg.sort_dir} align={c.align} />
          <span :if={!c.sortable?}>{c.label.()}</span>
        </.table_default_header_cell>
        <.table_default_header_cell class="text-right">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Actions")}</.table_default_header_cell>
      </.table_default_row>
    </.table_default_header>
    <.table_default_body>
      <.table_default_row :for={row <- @rows}>
        <.table_default_cell :for={c <- @cols} class={c.align == :right && "text-right"}>
          {render_cell(@scope, c.id, row)}
        </.table_default_cell>
        <.table_default_cell class="text-right whitespace-nowrap">{render_slot(@row_actions, row)}</.table_default_cell>
      </.table_default_row>
    </.table_default_body>
    <:card_header :let={row}>{render_cell(@scope, "name", row)}</:card_header>
    <:card_actions :let={row}>{render_slot(@card_actions, row)}</:card_actions>
  </.table_default>
  """
end
```

- [ ] **Step 4: Add `sort_header/1`, `render_cell/3`, `render_card_value/3`** for suppliers/manufacturers columns:
```elixir
attr :by, :string, required: true
attr :label, :string, required: true
attr :sort_by, :string, required: true
attr :sort_dir, :atom, required: true
attr :align, :atom, default: :left

defp sort_header(assigns) do
  assigns = assign(assigns, :active?, assigns.sort_by == assigns.by)
  ~H"""
  <button type="button" phx-click="toggle_sort" phx-value-by={@by}
    class={["inline-flex items-center gap-1 cursor-pointer select-none", @align == :right && "justify-end w-full"]}>
    <span>{@label}</span>
    <.icon :if={@active?} name={if @sort_dir == :asc, do: "hero-chevron-up-mini", else: "hero-chevron-down-mini"} class="w-3.5 h-3.5" />
  </button>
  """
end

# Table cells (may contain links). Suppliers/manufacturers:
defp render_cell(scope, "name", row) when scope in [:suppliers, :manufacturers] do
  path = if scope == :suppliers, do: Paths.supplier_edit(row.uuid), else: Paths.manufacturer_edit(row.uuid)
  assigns = %{path: path, name: row.name}
  ~H"""<.link navigate={@path} class="link link-hover font-medium">{@name}</.link>"""
end

defp render_cell(_scope, "website", row), do: website_cell(row.website)
defp render_cell(_scope, "contact_info", row), do: text_or_dash(row.contact_info)
defp render_cell(_scope, "status", row), do: status_badge_cell(row.status)
defp render_cell(_scope, "updated", row), do: ts(row.updated_at)

defp render_card_value(_scope, "website", row), do: row.website || "—"
defp render_card_value(_scope, "status", row), do: status_label(row.status)
defp render_card_value(_scope, "contact_info", row), do: row.contact_info || "—"
defp render_card_value(_scope, "updated", row), do: ts_str(row.updated_at)
defp render_card_value(_scope, _id, _row), do: "—"
```
Small render helpers:
```elixir
defp website_cell(nil), do: ~H""
defp website_cell(url) do
  assigns = %{url: url}
  ~H"""<span class="text-sm text-base-content/60">{@url}</span>"""
end
defp text_or_dash(nil), do: ~H"""<span class="text-base-content/40">—</span>"""
defp text_or_dash(v), do: (assigns = %{v: v}; ~H"""<span class="text-sm">{@v}</span>""")
defp status_badge_cell(status), do: (assigns = %{status: status}; ~H"""<.status_badge status={@status} size={:sm} />""")
defp ts(nil), do: ~H"""<span class="text-base-content/40">—</span>"""
defp ts(dt), do: (assigns = %{dt: dt}; ~H"""<span class="text-sm text-base-content/60">{Calendar.strftime(@dt, "%Y-%m-%d %H:%M")}</span>""")
defp ts_str(nil), do: "—"
defp ts_str(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
```

- [ ] **Step 5: Replace the manufacturers/suppliers tab render** in `render/1`. For each, derive rows + render toolbar + simple_table + the column modal. Manufacturers example (suppliers identical with `:suppliers`, `@suppliers`, supplier paths/labels):
```heex
<div :if={@active_tab == :manufacturers and is_nil(@search_results)} class="flex flex-col gap-4">
  <% cfg = @view_configs.manufacturers %>
  <.table_toolbar scope={:manufacturers} cfg={cfg} rows={@manufacturers}>
    <:filters>
      <.enum_filter id="status" label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Status")}
        value={cfg.filters["status"]} prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "All statuses")}
        options={PhoenixKitCatalogue.Web.TableQuery.enum_options(@manufacturers, :manufacturers, "status")} />
    </:filters>
    <:actions>
      <.link navigate={Paths.manufacturer_new()} class="btn btn-primary btn-sm">
        <.icon name="hero-plus" class="w-4 h-4" /> {Gettext.gettext(PhoenixKitCatalogue.Gettext, "New Manufacturer")}
      </.link>
    </:actions>
  </.table_toolbar>
  <.simple_table scope={:manufacturers} cfg={cfg} rows={derive_rows(@manufacturers, :manufacturers, cfg)}
    empty={Gettext.gettext(PhoenixKitCatalogue.Gettext, "No manufacturers yet.")}>
    <:row_actions :let={m}>
      <.table_row_menu mode="auto" id={"mfg-menu-#{m.uuid}"}>
        <.table_row_menu_link navigate={Paths.manufacturer_edit(m.uuid)} icon="hero-pencil" label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit")} />
        <.table_row_menu_divider />
        <.table_row_menu_button phx-click="show_delete_confirm" phx-value-uuid={m.uuid} phx-value-type="manufacturer" icon="hero-trash" label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")} variant="error" />
      </.table_row_menu>
    </:row_actions>
    <:card_actions :let={m}>
      <.link navigate={Paths.manufacturer_edit(m.uuid)} class="btn btn-ghost btn-xs">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit")}</.link>
      <button phx-click="show_delete_confirm" phx-value-uuid={m.uuid} phx-value-type="manufacturer" class="btn btn-ghost btn-xs text-error">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")}</button>
    </:card_actions>
  </.simple_table>
</div>
```
Then add the column modal once near the end of `render/1` (shared across tabs):
```heex
<.column_settings_modal show={@show_column_modal} scope={active_scope(assigns)}
  selected={current_cfg(assigns).columns} temp_selected={@temp_columns} />
```
Delete the old `manufacturers_table/1` and `suppliers_table/1` defs.

- [ ] **Step 6: Compile via the app + restart + runtime verify.**
  - `cd <host-app> && mix compile` clean.
  - Restart elixir; HTTP 200.
  - Headless browser (logged-in admin) on `/admin/catalogue/manufacturers` and `/suppliers`: toolbar shows search/status-filter/sort/Columns/view-toggle/New button; toggling a column in the modal hides/shows it and persists across reload; sort + filter + search work in table and card view.

- [ ] **Step 7: Commit.**
```bash
git add lib/phoenix_kit_catalogue/web/catalogues_live.ex
git commit -m "Apply table toolbar + dynamic columns + card view to suppliers and manufacturers"
```

---

## Task 7: Catalogues index — flat table, folder filter/column, remove tree + global search

**Files:**
- Modify: `lib/phoenix_kit_catalogue/web/catalogues_live.ex`

**Interfaces:**
- Consumes: Task 5/6 helpers; folder context (`list_folder_tree/1`, `catalogues_by_folder/1`, `item_counts_by_catalogue/0`).
- Produces: flat `@catalogue_rows` (enriched maps with `:folder_uuid`, `:folder_name`, `:item_count`).

- [ ] **Step 1: Build enriched flat catalogue rows in `load_data(:index)`** (replace tree building). Each row = the `%Catalogue{}` enriched into a map the table/cells use. Add helper:
```elixir
defp build_catalogue_rows(catalogues, folder_lookup, item_counts) do
  Enum.map(catalogues, fn c ->
    c
    |> Map.from_struct()
    |> Map.put(:folder_uuid, c.folder_uuid)
    |> Map.put(:folder_name, c.folder_uuid && folder_lookup[c.folder_uuid] && folder_lookup[c.folder_uuid].name)
    |> Map.put(:item_count, Map.get(item_counts, c.uuid, 0))
  end)
end
```
Build `folder_lookup = Map.new(list_folder_tree(), fn {f, _depth} -> {f.uuid, f} end)` and a flat catalogue list (active vs deleted per `@catalogue_view_mode`) from `catalogues_by_folder/1` values, assign `:catalogue_rows`.

- [ ] **Step 2: Add catalogue-specific `render_cell/3` + `render_card_value/3` clauses** (name link, folder, items, status, kind, markup, discount, updated, created). E.g.:
```elixir
defp render_cell(:catalogues, "name", row) do
  assigns = %{row: row}
  ~H"""
  <.link :if={@row.status != "deleted"} navigate={Paths.catalogue_detail(@row.uuid)} class="link link-hover font-medium">{@row.name}</.link>
  <span :if={@row.status == "deleted"} class="font-medium text-base-content/50">{@row.name}</span>
  """
end
defp render_cell(:catalogues, "folder", row), do: text_or_dash(row[:folder_name])
defp render_cell(:catalogues, "items", row), do: (assigns = %{n: row[:item_count] || 0}; ~H"""<span class="tabular-nums">{@n}</span>""")
defp render_cell(:catalogues, "kind", row), do: text_or_dash(row.kind)
defp render_cell(:catalogues, "markup", row), do: pct(row.markup_percentage)
defp render_cell(:catalogues, "discount", row), do: pct(row.discount_percentage)
defp render_cell(:catalogues, "created", row), do: ts(row.inserted_at)
# status/updated reuse the generic clauses from Task 6.
defp render_card_value(:catalogues, "folder", row), do: row[:folder_name] || "—"
defp render_card_value(:catalogues, "items", row), do: to_string(row[:item_count] || 0)
defp render_card_value(:catalogues, "kind", row), do: row.kind || "—"
defp render_card_value(:catalogues, "markup", row), do: pct_str(row.markup_percentage)
defp render_card_value(:catalogues, "discount", row), do: pct_str(row.discount_percentage)
defp render_card_value(:catalogues, "created", row), do: ts_str(row.inserted_at)
```
With `pct/1`/`pct_str/1` formatting Decimals (reuse `format_decimal_display` if available, else `Decimal.to_string`).

- [ ] **Step 3: Replace the index tab render.** Keep the Active/Deleted sub-tabs block as-is. Below it, render the toolbar (with Folder + Status filters and the catalogue action buttons + a "Folders" button) and `simple_table` with the catalogue row actions. Catalogue row_actions/card_actions reuse the existing menu items (View/Edit/Move to folder/Delete; or Restore/Delete-forever in deleted mode). Folder filter:
```heex
<.enum_filter id="folder" label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Folder")}
  value={cfg.filters["folder"]} prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "All folders")}
  options={PhoenixKitCatalogue.Web.TableQuery.enum_options(@catalogue_rows, :catalogues, "folder")} />
```
Toolbar actions: `New Folder` (existing `new_folder`), `New Catalogue` (`Paths.catalogue_new()`), and a `Folders…` button (`phx-click="show_folders_modal"`).

- [ ] **Step 4: Remove the dead code.** Delete `folder_tree_table/1`; delete the global item-search block in the index render (the search input + `@search_results`/`@search_loading`/infinite-scroll-for-search markup); remove the old `"search"`, search-pagination, and `CatalogueTreeDnD`-related handlers/assigns that are now unused. Grep to confirm no remaining references: `grep -n "search_results\|folder_tree_table\|CatalogueTreeDnD\|search_has_more" lib/phoenix_kit_catalogue/web/catalogues_live.ex` → only intentional ones (none).

- [ ] **Step 5: Compile + restart + runtime verify.**
  - `cd <host-app> && mix compile` clean (watch for "unused" warnings from removed handlers — remove their helpers too).
  - Restart; HTTP 200.
  - Browser `/admin/catalogue`: flat table; Active/Deleted toggle works; Folder filter narrows; Folder/Items/Status/Updated columns; column modal persists; sort works; card view shows folder/items/status; "Move to folder" still in row menu; no global item-search box; no JS console errors from the removed DnD hook.

- [ ] **Step 6: Commit.**
```bash
git add lib/phoenix_kit_catalogue/web/catalogues_live.ex
git commit -m "Flatten catalogues index to a sortable table with folder filter; remove tree and global item search"
```

---

## Task 8: Folders management modal

**Files:**
- Modify: `lib/phoenix_kit_catalogue/web/catalogues_live.ex`

**Interfaces:**
- Consumes: existing folder context functions (`create_folder/2`, `update_folder/3`, `move_folder/3`, `trash_folder/2`, `restore_folder/2`, `permanently_delete_folder/2`, `list_folder_tree/1`) and existing folder event handlers where present.

- [ ] **Step 1: Add modal state + open/close handlers.**
```elixir
# in mount: |> assign(:show_folders_modal, false)
def handle_event("show_folders_modal", _p, socket), do: {:noreply, assign(socket, :show_folders_modal, true)}
def handle_event("hide_folders_modal", _p, socket), do: {:noreply, assign(socket, :show_folders_modal, false)}
```

- [ ] **Step 2: Add the modal render** (folder tree list with per-row actions). Reuse the existing folder event names (`new_folder`, `new_subfolder`, `start_rename_folder`/`rename_folder`, `open_move`, `trash_folder`, `restore_folder`, `show_delete_confirm`) so their handlers are unchanged. A compact indented list built from `@active_tree`/`list_folder_tree/1`, each row: name (rename inline), New subfolder, Move, Trash/Restore, Delete-forever — mirroring the row menus the tree had. Place inside `render/1` near the column modal:
```heex
<.modal :if={@show_folders_modal} id="catalogue-folders-modal" show on_cancel={JS.push("hide_folders_modal")}>
  <h3 class="text-lg font-semibold mb-3">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Folders")}</h3>
  <!-- indented folder list with the action buttons listed above -->
</.modal>
```

- [ ] **Step 3: Compile + restart + runtime verify.** Folder create/rename/subfolder/move/trash/restore/delete all work from the modal; the catalogue table's Folder filter/column reflect changes after the action (PubSub reload already wired).

- [ ] **Step 4: Commit.**
```bash
git add lib/phoenix_kit_catalogue/web/catalogues_live.ex
git commit -m "Add Folders management modal to catalogues index"
```

---

## Task 9: Gettext strings

**Files:**
- Modify: `priv/gettext/default.pot`, `priv/gettext/{en,ru,et}/LC_MESSAGES/default.po`

- [ ] **Step 1: Add new msgids** (single form each), manually, mirroring an existing entry's block format. Strings to add (en = msgid; ru/et translations):

| msgid | ru | et |
|-------|----|----|
| `Columns` | Колонки | Veerud |
| `Shown` | Показаны | Näidatud |
| `Available` | Доступные | Saadaval |
| `Reset` | Сбросить | Lähtesta |
| `Apply` | Применить | Rakenda |
| `Toggle sort direction` | Сменить направление сортировки | Muuda sortimissuunda |
| `Folder` | Папка | Kaust |
| `Folders` | Папки | Kaustad |
| `All folders` | Все папки | Kõik kaustad |
| `All statuses` | Все статусы | Kõik staatused |
| `Kind` | Вид | Tüüp |
| `Markup %` | Наценка % | Juurdehindlus % |
| `Discount %` | Скидка % | Allahindlus % |
| `Created` | Создан | Loodud |
| `Contact Info` | Контакты | Kontaktandmed |
| `New Manufacturer` | (existing — verify) | |
| `New Supplier` | (existing — verify) | |

(Verify which already exist with `grep -n '^msgid "X"' priv/gettext/ru/LC_MESSAGES/default.po` before adding — do not duplicate.)

- [ ] **Step 2: Verify renders on live node** (after restart) via Tidewave:
```elixir
Gettext.put_locale(PhoenixKitCatalogue.Gettext, "ru")
Enum.map(["Columns","Folder","Kind","Markup %","All folders"], &Gettext.gettext(PhoenixKitCatalogue.Gettext, &1))
```
Expected: `["Колонки","Папка","Вид","Наценка %","Все папки"]`

- [ ] **Step 3: Commit.**
```bash
git add priv/gettext
git commit -m "Add gettext strings for catalogue table toolbar and columns"
```

---

## Task 10: Final integration verification

- [ ] **Step 1: Full clean compile.** `cd <host-app> && mix compile` — zero new warnings attributable to catalogue files.
- [ ] **Step 2: Restart + boot check.** `sudo /usr/bin/supervisorctl restart elixir`; wait for "Running <HostWeb>.Endpoint"; HTTP 200 on `/`.
- [ ] **Step 3: Cross-table runtime sweep (headless browser, logged-in admin):**
  - `/admin/catalogue`: flat table, Active/Deleted, folder filter+column, column modal persists across reload, sort (header + select), card view, Folders modal CRUD, Move-to-folder, no global item search, no JS errors.
  - `/admin/catalogue/suppliers` & `/manufacturers`: toolbar, status filter, sort, search, column modal persists, card view, New button.
  - Persistence cross-session: change columns, reconnect (reload) — choice retained; verify via a second admin user that defaults differ per user.
- [ ] **Step 4: Mobile check (headless, narrow viewport):** no horizontal overflow on all three pages (per daisyUI 5 memory — `min-w-0` on flex children if needed).
- [ ] **Step 5: Self-review against the spec** (`dev_docs/2026-06-27-catalogue-table-stack-design.md`): every decision covered; no regressions in folder management vs the old tree.
- [ ] **Step 6:** No final commit needed if Tasks 1-9 each committed; otherwise commit any verification fixes.

---

## Self-Review (plan vs spec)

- **Spec coverage:** toolbar (T6/T7), card view (T6/T7), column management (T1/T4/T5), sorting (T1/T5/T6), filtering (T2/T6/T7), per-user persistence (T3/T5), flat catalogues + folder filter/column (T7), Folders modal full CRUD (T8), remove tree+DnD+global search (T7), Active/Deleted retained (T7), suppliers/manufacturers (T6), i18n (T9), verification incl. mobile (T10). All covered.
- **Placeholders:** none — pure modules have full code; HEEx renders give exact component calls and representative cells (the repetitive cells follow the shown `render_cell/3` pattern).
- **Type consistency:** cfg is atom-keyed in-memory (`%{columns, sort_by, sort_dir, filters, view}`) everywhere; `:search` is a transient cfg key never persisted; `scope` atoms `:catalogues/:suppliers/:manufacturers`; event names consistent (`set_view`/`view_event="set_view"`, `table_search`, `toggle_sort`/`set_sort`/`flip_sort_dir`, `*_column(s)`).
- **Watch-item:** confirm core `<.table_default>` supports `view_mode` + `view_event` controlled mode (researcher confirmed). If an older core build lacks it, fall back to default JS-hook toggle and persist view via a `set_view` button instead — verify in T6 Step 6.
