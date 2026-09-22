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
  import PhoenixKitWeb.Components.Core.SortSelector, only: [sort_selector: 1]

  alias PhoenixKitCatalogue.Gettext, as: G
  alias PhoenixKitCatalogue.Web.TableConfig

  defp g(s), do: Gettext.gettext(G, s)

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

  attr(:show, :boolean, required: true)

  attr(:sections, :list,
    required: true,
    doc:
      "One block per visible table: %{scope: atom, title: String.t(), selected: [id]}. A drilled category page shows its subcategories and its items at once, so their column editors share one modal (one section each) instead of two side-by-side \"Columns\" buttons."
  )

  # Multi-table variant of the modal above, markup mirroring core's
  # `column_settings_modal/1`. Events carry the section's scope
  # (`phx-value-scope`), and each Shown list pushes its own reorder
  # event (`reorder_columns_<scope>`) because the SortableGrid payload
  # is only `%{ordered_ids}`. Reset resets every section shown.
  def column_sections_modal(assigns) do
    sections =
      for s <- assigns.sections do
        columns = for c <- TableConfig.managed_columns(s.scope), do: %{id: c.id, label: c.label}
        map = Map.new(columns, &{&1.id, &1})

        Map.merge(s, %{
          map: map,
          shown: Enum.filter(s.selected, &Map.has_key?(map, &1)),
          hidden: Enum.reject(columns, &(&1.id in s.selected))
        })
      end

    assigns = assign(assigns, :sections, sections)

    ~H"""
    <.modal :if={@show} id="catalogue-columns-modal" show on_close="hide_column_modal" max_width="lg">
      <:title>{g("Columns")}</:title>
      <div class="space-y-6">
        <section :for={s <- @sections}>
          <h4 :if={length(@sections) > 1} class="text-sm font-semibold mb-2">{s.title}</h4>
          <div class="grid grid-cols-2 gap-4">
            <div>
              <p class="text-xs uppercase text-base-content/50 mb-2">{g("Shown")}</p>
              <ul
                id={"columns-shown-#{s.scope}"}
                phx-hook="SortableGrid"
                data-sortable="true"
                data-sortable-event={"reorder_columns_#{s.scope}"}
                data-sortable-items=".sortable-item"
                data-sortable-handle=".pk-drag-handle"
                class="space-y-1"
              >
                <li
                  :for={id <- s.shown}
                  data-id={id}
                  class="sortable-item flex items-center gap-2 px-2 py-1 rounded bg-base-200"
                >
                  <.icon
                    name="hero-bars-3"
                    class="w-4 h-4 pk-drag-handle cursor-grab text-base-content/40"
                  />
                  <span class="flex-1 text-sm">{s.map[id].label.()}</span>
                  <button
                    type="button"
                    phx-click="remove_column"
                    phx-value-column_id={id}
                    phx-value-scope={s.scope}
                    class="btn btn-ghost btn-xs btn-square text-error cursor-pointer"
                    title={g("Remove")}
                  >
                    <.icon name="hero-x-mark" class="w-4 h-4" />
                  </button>
                </li>
              </ul>
            </div>
            <div>
              <p class="text-xs uppercase text-base-content/50 mb-2">{g("Available")}</p>
              <ul class="space-y-1">
                <li :for={c <- s.hidden}>
                  <button
                    type="button"
                    phx-click="add_column"
                    phx-value-column_id={c.id}
                    phx-value-scope={s.scope}
                    class="flex items-center gap-2 w-full text-left text-sm px-2 py-1 rounded hover:bg-base-200 cursor-pointer transition-colors"
                  >
                    <.icon name="hero-plus" class="w-4 h-4 text-base-content/40" />
                    <span>{c.label.()}</span>
                  </button>
                </li>
              </ul>
            </div>
          </div>
        </section>
      </div>
      <:actions>
        <button type="button" phx-click="reset_columns" class="btn btn-ghost btn-sm">
          {g("Reset")}
        </button>
        <button type="button" phx-click="hide_column_modal" class="btn btn-primary btn-sm">
          {g("Close")}
        </button>
      </:actions>
    </.modal>
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
