defmodule PhoenixKitCatalogue.Extensions do
  @moduledoc """
  Discovery and absorption for `PhoenixKitCatalogue.Extension` implementers
  — the item/category form "extension slot" (spec §2 principle 8, §4 row
  C4).

  Discovery is duck-typed, mirroring `PhoenixKitAI.Translatables`'
  `ai_translatables/0` pattern: any module registered with
  `PhoenixKit.ModuleRegistry` that exports `catalogue_extensions/0` gets
  its returned modules folded in, filtered to those reporting
  `enabled?/0`. Catalogue never references an implementer by name — an
  unregistered or disabled host changes nothing (spec §4 row C4's
  regression rule: forms without a registered extension render exactly as
  before).
  """

  require Logger

  alias Phoenix.HTML.Safe, as: HtmlSafe
  alias PhoenixKit.ModuleRegistry

  # The delimiter between an extension's `key/0` and a column's `id` in
  # the namespaced id `columns/1` returns. Neither half may contain it
  # (see `valid_column?/1` and `extension_columns/2`'s guard) —
  # otherwise two different (key, id) pairs could produce the same
  # namespaced string, defeating the whole point of namespacing.
  @namespace_delimiter ":"

  # Process-dictionary key for `log_render_error_once/4`'s per-(column,
  # render pass) latch — see that function's doc.
  @render_error_latch {__MODULE__, :extension_render_error_logged?}

  @doc """
  All enabled extension modules contributed by registered `PhoenixKit`
  modules, in registration order, deduplicated.
  """
  @spec all() :: [module()]
  def all do
    ModuleRegistry.all_modules()
    |> Enum.flat_map(&contributed_by/1)
    |> Enum.uniq()
    |> Enum.filter(&enabled?/1)
  end

  defp contributed_by(mod) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :catalogue_extensions, 0) do
      case mod.catalogue_extensions() do
        list when is_list(list) -> list
        _ -> []
      end
    else
      []
    end
  rescue
    _ -> []
  end

  defp enabled?(ext) do
    Code.ensure_loaded?(ext) and function_exported?(ext, :enabled?, 0) and ext.enabled?()
  rescue
    _ -> false
  end

  @doc """
  Enabled extension modules that render a section for `kind` (`:item` or
  `:category`) — i.e. export `item_section/1` (or `category_section/1`).
  """
  @spec sections(:item | :category) :: [module()]
  def sections(kind) do
    callback = section_callback(kind)
    Enum.filter(all(), &function_exported?(&1, callback, 1))
  end

  defp section_callback(:item), do: :item_section
  defp section_callback(:category), do: :category_section
  defp cast_callback(:item), do: :cast_item
  defp cast_callback(:category), do: :cast_category

  @doc """
  Folds every enabled extension's submitted namespace into `data`.

  For each enabled extension `E` exporting the `kind`-appropriate cast
  callback: takes `params[E.key()]` (a map, or `%{}` when absent/nil),
  calls `E.cast_item/2` (or `cast_category/2`) with the extension's
  current value `data[E.key()] || %{}`, and merges the result under
  `data[E.key()]`. Stops at the first extension that returns an error.
  """
  @spec absorb(:item | :category, map(), map()) ::
          {:ok, map()} | {:error, {module(), [{atom(), String.t()}]}}
  def absorb(kind, params, data)
      when kind in [:item, :category] and is_map(params) and is_map(data) do
    cast_fun = cast_callback(kind)

    Enum.reduce_while(all(), {:ok, data}, fn ext, {:ok, acc} ->
      if function_exported?(ext, cast_fun, 2) do
        absorb_one(ext, cast_fun, params, acc)
      else
        {:cont, {:ok, acc}}
      end
    end)
  end

  defp absorb_one(ext, cast_fun, params, acc) do
    ext_params = as_map(Map.get(params, ext.key()))
    current = as_map(Map.get(acc, ext.key()))

    case apply(ext, cast_fun, [ext_params, current]) do
      {:ok, casted} -> {:cont, {:ok, Map.put(acc, ext.key(), casted)}}
      {:error, errors} -> {:halt, {:error, {ext, errors}}}
    end
  end

  defp as_map(map) when is_map(map), do: map
  defp as_map(_), do: %{}

  @doc """
  Enabled extensions' contributed columns for the catalogue admin's
  configurable `:detail_items` / `:detail_categories` tables (spec §2
  principle 8, §4 row C4's column follow-up — the "Columns" modal on
  `CatalogueDetailLive`).

  Each contributed id is namespaced under its extension's `key/0`
  (`"<key>:<id>"`) so it can never collide with
  `PhoenixKitCatalogue.Web.TableConfig`'s own ids or another
  extension's — enforced by rejecting a `key/0` or column `id` that
  itself carries the `#{inspect(@namespace_delimiter)}` delimiter (see
  `valid_column?/1`), so `key <> #{inspect(@namespace_delimiter)} <>
  id` can never mean two different things.

  Same resilience contract as `sections/1` and `absorb/3`: a missing,
  disabled, or raising extension — or one whose
  `item_columns/0`/`category_columns/0` returns a malformed entry —
  contributes nothing rather than breaking the page. That contract also
  covers what happens once a column is actually IN USE: a `label` or
  `render` that raises, throws, exits, or returns a value
  `Phoenix.HTML.Safe` can't turn into HTML degrades to a blank
  label/empty cell for that one column instead of taking down the whole
  page — see `guarded_label/3` and `guarded_render/3`.
  """
  @spec columns(:detail_items | :detail_categories) :: [PhoenixKitCatalogue.Extension.column()]
  def columns(kind) when kind in [:detail_items, :detail_categories] do
    callback = columns_callback(kind)

    all()
    |> Enum.filter(&function_exported?(&1, callback, 0))
    |> Enum.flat_map(&extension_columns(&1, callback))
  end

  defp columns_callback(:detail_items), do: :item_columns
  defp columns_callback(:detail_categories), do: :category_columns

  defp extension_columns(ext, callback) do
    key = ext.key()

    if is_binary(key) and not String.contains?(key, @namespace_delimiter) do
      case apply(ext, callback, []) do
        list when is_list(list) ->
          list
          |> Enum.filter(&valid_column?/1)
          |> Enum.map(&namespace_column(ext, &1))

        _ ->
          []
      end
    else
      []
    end
  rescue
    _ -> []
  end

  defp valid_column?(%{id: id, label: label, render: render})
       when is_binary(id) and is_function(label, 0) and is_function(render, 1) do
    not String.contains?(id, @namespace_delimiter)
  end

  defp valid_column?(_), do: false

  defp namespace_column(ext, col) do
    namespaced_id = ext.key() <> @namespace_delimiter <> col.id
    # A fresh id here means a fresh render pass is picking these
    # columns up (`TableConfig.extension_columns/1`'s "fetch ONCE per
    # page render" contract), so this is also the right moment to clear
    # any earlier latch — a column that's STILL broken logs again this
    # render instead of going silent forever after its first failure.
    clear_render_error_latch(namespaced_id)

    %{
      col
      | id: namespaced_id,
        label: guarded_label(ext, namespaced_id, col.label),
        render: guarded_render(ext, namespaced_id, col.render)
    }
  end

  # Wraps a column's `label`/`render` so a raise, throw, exit, or a
  # return value with no `Phoenix.HTML.Safe` implementation degrades to
  # `fallback` for that one label/cell instead of crashing the
  # LiveView. `valid_column?/1` only checks the *shape* of these
  # functions at discovery time (are they 0-/1-arity); it cannot see
  # what happens when one is actually CALLED against a real row — this
  # is the guard for that.
  defp guarded_label(ext, namespaced_id, label_fn) do
    fn -> run_guarded(ext, namespaced_id, :label, fn -> label_fn.() end, "") end
  end

  defp guarded_render(ext, namespaced_id, render_fn) do
    fn record -> run_guarded(ext, namespaced_id, :render, fn -> render_fn.(record) end, nil) end
  end

  defp run_guarded(ext, namespaced_id, kind, thunk, fallback) do
    result = thunk.()
    # Forces the value's dynamic parts to actually be evaluated (a
    # `%Phoenix.LiveView.Rendered{}`'s included), the same conversion
    # the real template does when it embeds `{ext.render.(record)}` —
    # so a raise buried in the extension's own nested HEEx, or a bare
    # value with no safe-HTML representation, is caught right here too,
    # not just a raise from `render_fn`/`label_fn` itself.
    _ = HtmlSafe.to_iodata(result)
    result
  rescue
    error ->
      log_render_error_once(
        ext,
        namespaced_id,
        kind,
        Exception.format(:error, error, __STACKTRACE__)
      )

      fallback
  catch
    caught_kind, reason ->
      log_render_error_once(
        ext,
        namespaced_id,
        kind,
        Exception.format(caught_kind, reason, __STACKTRACE__)
      )

      fallback
  end

  defp clear_render_error_latch(namespaced_id) do
    Process.delete({@render_error_latch, namespaced_id, :label})
    Process.delete({@render_error_latch, namespaced_id, :render})
  end

  # Logs at most once per (column, render pass) — bounded via a
  # process-dictionary latch reset in `namespace_column/2` each time a
  # fresh columns list is built (which, per
  # `TableConfig.extension_columns/1`'s contract, happens once per page
  # render of a table) — so a column that's broken for every row of a
  # 200-row table produces ONE log line for that render, not two
  # hundred, while a page that re-renders later logs again if the
  # column is still broken.
  defp log_render_error_once(ext, namespaced_id, kind, formatted) do
    latch_key = {@render_error_latch, namespaced_id, kind}

    unless Process.get(latch_key) do
      Process.put(latch_key, true)

      Logger.error(
        "PhoenixKitCatalogue.Extensions: #{inspect(ext)}'s #{kind} for column " <>
          "#{inspect(namespaced_id)} failed; showing an empty cell for the rest " <>
          "of this render.\n#{formatted}"
      )
    end
  end
end
