defmodule PhoenixKitCatalogue.Web.TableToolbar do
  @moduledoc """
  Toolbar pieces for the catalogue admin tables: the column-settings modal,
  the sort select+direction control, and an enum filter select. All emit
  plain events handled by `CataloguesLive` against the active scope.
  """
  use Phoenix.Component

  import PhoenixKitWeb.Components.Core.Select, only: [select: 1]
  import PhoenixKitWeb.Components.Core.SortSelector, only: [sort_selector: 1]

  alias PhoenixKitCatalogue.Web.TableConfig

  attr(:show, :boolean, required: true)
  attr(:scope, :atom, required: true)
  attr(:selected, :list, required: true)

  # Thin adapter over the core live editor: maps this module's
  # TableConfig catalog into the generic column shape. Event contract
  # (add/remove/reorder/reset/hide) is implemented by the consuming LV.
  def column_settings_modal(assigns) do
    assigns =
      assign(
        assigns,
        :columns,
        for(c <- TableConfig.managed_columns(assigns.scope), do: %{id: c.id, label: c.label})
      )

    ~H"""
    <PhoenixKitWeb.Components.Core.ColumnSettings.column_settings_modal
      id="catalogue-columns-modal"
      show={@show}
      columns={@columns}
      selected={@selected}
    />
    """
  end

  attr(:scope, :atom, required: true)
  attr(:selected, :list, required: true)
  attr(:sort_by, :string, required: true)
  attr(:sort_dir, :atom, required: true)

  attr(:manual_value, :string,
    default: nil,
    doc:
      "sort_by value that means \"manual/drag order\" (e.g. \"position\"). When active, the direction toggle is hidden — direction has no meaning for a user-dragged order."
  )

  @doc """
  The index's sort control — core's `sort_selector`, not a second
  implementation of it.

  This used to be a hand-rolled `join` with its own `<select>` and its own
  `flip_sort_dir` event, so the index's sort widget looked and behaved
  unlike the one every catalogue page shows (a ghost chevron vs a square
  button, `hero-chevron-*` vs `hero-bars-arrow-*`). The owner saw the two
  side by side (boss via Max, 2026-09-21). Both directions now ride the
  one `set_sort` event: the select sends `sort_by`, the arrow sends
  `sort_dir`.
  """
  def sort_controls(assigns) do
    assigns =
      assign(
        assigns,
        :options,
        for(
          c <- TableConfig.sortable_visible(assigns.scope, assigns.selected),
          do: {c.id, c.label.()}
        )
      )

    ~H"""
    <.sort_selector
      id={"#{@scope}-sort-controls"}
      sort_by={@sort_by}
      sort_dir={@sort_dir}
      options={@options}
      manual_field={@manual_value}
      event="set_sort"
      label
    />
    """
  end

  attr(:id, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :string, default: nil)
  attr(:options, :list, required: true)
  attr(:prompt, :string, required: true)

  def enum_filter(assigns) do
    ~H"""
    <form id={"filter-form-#{@id}"} phx-change="set_filter" class="contents">
      <input type="hidden" name="column_id" value={@id} />
      <.select
        name="value"
        id={"filter-#{@id}"}
        value={@value}
        prompt={@prompt}
        options={@options}
        class="select-sm"
        aria-label={@label}
      />
    </form>
    """
  end
end
