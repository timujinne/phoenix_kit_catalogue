defmodule PhoenixKitCatalogue.Web.Components.DependenciesPanel do
  @moduledoc """
  The item form's Dependencies tab: the staged rows of a
  `PhoenixKitCatalogue.Web.DependencyDraft` and its Add button, which opens
  a pop-up like the Location chooser's — one tree of folders › catalogues ›
  categories › items (`PlaceTree.places/2` with `items: true`). Picking a
  row only selects it: the pop-up shows the selection the way the list
  will read it, takes its quantity and note, and adds the row on Add,
  which closes it. Rows reorder by dragging (core's `draggable_list`).

  Rendered OUTSIDE the item form: the rows are a small form of their own
  (`dependency_change`), and the picker brings its own search box. Nothing
  here writes — the item's Save does (`ItemFormLive`). The host
  LiveView handles `dependency_open_picker`, `dependency_close_picker`,
  `dependency_picker_change`, `dependency_picker_confirm`,
  `dependency_change`, `dependency_remove` and `dependency_reorder`, plus
  the tree's `{TreePicker, "dependency-place-picker", id}`.

  Internal categories are offered here like any other: this is an admin
  page, and back-office stock is exactly what a dependency points at.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS

  import PhoenixKitWeb.Components.Core.DecimalInput, only: [decimal_input: 1]
  import PhoenixKitWeb.Components.Core.DraggableList, only: [draggable_list: 1]
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Input, only: [input: 1]
  import PhoenixKitWeb.Components.Core.Modal, only: [modal: 1]
  import PhoenixKitCatalogue.Web.Components, only: [internal_badge: 1]

  alias PhoenixKitCatalogue.Paths
  alias PhoenixKitCatalogue.Schemas.ItemDependency
  alias PhoenixKitCatalogue.Web.DependencyDraft
  alias PhoenixKitWeb.Components.TreePicker

  attr(:draft, DependencyDraft, required: true)

  attr(:picker, :map,
    default: nil,
    doc: """
    The open pop-up — `%{tree, value, kind, path, quantity, note, error}`,
    where `value` is the selected row's id (`nil` before one is picked) and
    `error` names what stops Add — or nil while closed.
    """
  )

  attr(:class, :any, default: nil)

  def dependencies_panel(assigns) do
    ~H"""
    <div id="item-dependencies" class={["card bg-base-100 shadow-lg", @class]}>
      <div class="card-body flex flex-col gap-4">
        <p class="text-sm text-base-content/60">
          {Gettext.gettext(
            PhoenixKitCatalogue.Gettext,
            "What this item needs from other catalogues, categories or items, and how many. It is for the people using the catalogue: nothing is calculated from it."
          )}
        </p>

        <p :if={@draft.rows == []} id="dependencies-empty" class="text-sm text-base-content/50">
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No dependencies yet.")}
        </p>

        <form
          :if={@draft.rows != []}
          id="dependency-rows-form"
          phx-change="dependency_change"
          phx-submit="dependency_change"
          class="flex flex-col divide-y divide-base-200"
        >
          <%!-- The column names once, above the rows, so each row's name
               lines up with its own fields. Hidden where the row wraps. --%>
          <div
            aria-hidden="true"
            class="hidden md:flex items-center gap-3 pb-1 text-sm font-medium text-base-content/70"
          >
            <span class="w-4 shrink-0"></span>
            <span class="w-5 shrink-0"></span>
            <span class="flex-1 min-w-48"></span>
            <span class="w-32">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Quantity")}</span>
            <span class="flex-1 min-w-48">{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Note")}</span>
            <span class="w-6 shrink-0"></span>
          </div>

          <.draggable_list
            id="dependency-rows"
            items={@draft.rows}
            item_id={& &1.key}
            on_reorder="dependency_reorder"
            layout={:list}
            gap="gap-0"
            class="divide-y divide-base-200"
            draggable={length(@draft.rows) > 1}
            sortable_handle=".pk-drag-handle"
          >
            <:item :let={row}>
              <div
                id={"dependency-row-#{row.key}"}
                data-dependency-kind={row.kind}
                class="flex flex-wrap items-center gap-3 py-3 bg-base-100"
              >
                <span
                  class={[
                    "w-4 shrink-0",
                    length(@draft.rows) > 1 &&
                      "pk-drag-handle cursor-grab text-base-content/30 hover:text-base-content/60"
                  ]}
                  title={
                    length(@draft.rows) > 1 &&
                      Gettext.gettext(PhoenixKitCatalogue.Gettext, "Drag to reorder")
                  }
                >
                  <.icon :if={length(@draft.rows) > 1} name="hero-bars-3" class="w-4 h-4" />
                </span>

                <.icon name={kind_icon(row.kind)} class="w-5 h-5 shrink-0 text-base-content/60" />

                <div class="flex-1 min-w-48 flex flex-col gap-0.5">
                  <div class="flex items-center gap-2 min-w-0">
                    <.link navigate={target_path(row)} class="link link-hover font-medium truncate">
                      {row.name || "—"}
                    </.link>
                    <span class="badge badge-ghost badge-xs shrink-0">{kind_label(row.kind)}</span>
                    <.internal_badge record={%{internal: row.internal?, uuid: row.uuid}} />
                    <span :if={row.trashed?} class="badge badge-warning badge-xs shrink-0">
                      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "In trash")}
                    </span>
                  </div>
                  <span :if={row.place} class="text-xs text-base-content/50 truncate">
                    {row.place}
                  </span>
                </div>

                <.decimal_input
                  id={"dependency-#{row.key}-quantity"}
                  name={"dependencies[#{row.key}][quantity]"}
                  value={row.quantity}
                  aria-label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Quantity")}
                  placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Quantity")}
                  errors={field_errors(row, "quantity")}
                  wrapper_class="w-32"
                  class="input-sm"
                  phx-debounce="300"
                />

                <.input
                  type="text"
                  id={"dependency-#{row.key}-note"}
                  name={"dependencies[#{row.key}][note]"}
                  value={row.note}
                  aria-label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Note")}
                  errors={field_errors(row, "note")}
                  wrapper_class="flex-1 min-w-48"
                  class="input-sm"
                  maxlength={ItemDependency.max_note_length()}
                  placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "e.g., pick by wood type")}
                  phx-debounce="300"
                />

                <button
                  type="button"
                  phx-click="dependency_remove"
                  phx-value-key={row.key}
                  class="btn btn-ghost btn-xs btn-square text-error w-6 shrink-0"
                  title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Remove")}
                >
                  <.icon name="hero-x-mark" class="w-4 h-4" />
                </button>

                <p :if={row.error == "gone"} class="basis-full text-xs text-error pl-16">
                  {row_error_message(row.error)}
                </p>
              </div>
            </:item>
          </.draggable_list>
        </form>

        <div class="divider my-0"></div>

        <div>
          <button
            type="button"
            id="dependency-add"
            phx-click="dependency_open_picker"
            class="btn btn-sm btn-outline"
          >
            <.icon name="hero-plus" class="w-4 h-4" />
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Add")}
          </button>
        </div>

        <%!-- Like the Location chooser: one tree, folders › catalogues ›
             categories › items. Picking a row selects it; below, the
             selection reads as its line will, with its quantity and note;
             Add stages the row and closes. --%>
        <.modal
          :if={@picker}
          id="dependency-picker"
          show
          on_close="dependency_close_picker"
          max_width="lg"
        >
          <:title>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Add a dependency")}</:title>

          <div
            class="flex flex-col gap-4"
            phx-mounted={JS.focus(to: "#dependency-place-picker-search")}
          >
            <p class="text-sm text-base-content/60">
              {Gettext.gettext(
                PhoenixKitCatalogue.Gettext,
                "Pick a catalogue, a category or an item, then say how many."
              )}
              {Gettext.gettext(
                PhoenixKitCatalogue.Gettext,
                "What is already on the list, and anything inside it, is not offered."
              )}
            </p>

            <.live_component
              module={TreePicker}
              id="dependency-place-picker"
              tree={@picker.tree}
              value={@picker.value}
              pickable={[:catalogue, :category, :item]}
              path_skip={[:folder]}
              search_placeholder={
                Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search catalogues, categories and items…")
              }
            />

            <form
              id="dependency-picker-form"
              phx-change="dependency_picker_change"
              phx-submit="dependency_picker_confirm"
              class="flex flex-col gap-3 border-t border-base-300 pt-4"
            >
              <div id="dependency-picker-selection" class="flex flex-col gap-1 min-w-0">
                <span class="text-xs font-medium text-base-content/60">
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Selected")}
                </span>
                <p :if={is_nil(@picker.value)} class="text-sm text-base-content/50">
                  {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Nothing selected yet.")}
                </p>
                <div :if={@picker.value} class="flex items-start gap-2 min-w-0">
                  <.icon name={kind_icon(@picker.kind)} class="w-5 h-5 shrink-0 text-base-content/60" />
                  <span class="font-medium min-w-0 break-words">
                    {selection_text(@picker.kind, @picker.path)}
                  </span>
                  <span class="badge badge-ghost badge-xs shrink-0 mt-1">{kind_label(@picker.kind)}</span>
                </div>
              </div>

              <div class="flex flex-wrap items-start gap-3">
                <.decimal_input
                  id="dependency-picker-quantity"
                  name="picker[quantity]"
                  value={@picker.quantity}
                  label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Quantity")}
                  errors={if @picker.error == "quantity", do: [row_error_message("quantity")], else: []}
                  wrapper_class="w-32"
                  class="input-sm"
                  phx-debounce="300"
                />
                <.input
                  type="text"
                  id="dependency-picker-note"
                  name="picker[note]"
                  value={@picker.note}
                  label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Note")}
                  errors={if @picker.error == "note", do: [row_error_message("note")], else: []}
                  wrapper_class="flex-1 min-w-48"
                  class="input-sm"
                  maxlength={ItemDependency.max_note_length()}
                  placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "e.g., pick by wood type")}
                  phx-debounce="300"
                />
              </div>

              <p :if={@picker.error == "gone"} id="dependency-picker-error" class="text-sm text-error">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "That no longer exists. Choose another.")}
              </p>
              <p :if={@picker.error == "self"} id="dependency-picker-error" class="text-sm text-error">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "An item cannot depend on itself.")}
              </p>
            </form>
          </div>

          <:actions>
            <button
              type="button"
              id="dependency-picker-cancel"
              phx-click="dependency_close_picker"
              class="btn btn-ghost btn-sm"
            >
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Cancel")}
            </button>
            <button
              type="submit"
              form="dependency-picker-form"
              id="dependency-picker-confirm"
              disabled={is_nil(@picker.value)}
              class="btn btn-primary btn-sm"
            >
              <.icon name="hero-plus" class="w-4 h-4" />
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Add")}
            </button>
          </:actions>
        </.modal>
      </div>
    </div>
    """
  end

  # The selection as its line will read: an item by its path; a category
  # or catalogue as "any item in" it, which is what such a line means.
  defp selection_text(:item, path), do: Enum.join(path, " › ")

  defp selection_text(:category, path),
    do:
      Gettext.gettext(PhoenixKitCatalogue.Gettext, "Any item in %{place}",
        place: Enum.join(path, " › ")
      )

  defp selection_text(_catalogue, path),
    do:
      Gettext.gettext(PhoenixKitCatalogue.Gettext, "Anything in %{place}",
        place: Enum.join(path, " › ")
      )

  defp kind_icon(:catalogue), do: "hero-rectangle-stack"
  defp kind_icon(:category), do: "hero-folder"
  defp kind_icon(:item), do: "hero-cube"

  defp kind_label(:catalogue), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue")
  defp kind_label(:category), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category")
  defp kind_label(:item), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Item")

  defp target_path(%{kind: :catalogue, uuid: uuid}), do: Paths.catalogue_detail(uuid)

  defp target_path(%{kind: :category, uuid: uuid, catalogue_uuid: catalogue_uuid})
       when is_binary(catalogue_uuid),
       do: Paths.category_browse(catalogue_uuid, uuid)

  defp target_path(%{kind: :item, uuid: uuid}), do: Paths.item_edit(uuid)
  defp target_path(_row), do: nil

  # A field's own error shows under the field; "gone" is the row's.
  defp field_errors(%{error: field} = row, field), do: [row_error_message(row.error)]
  defp field_errors(_row, _field), do: []

  defp row_error_message("gone"),
    do:
      Gettext.gettext(
        PhoenixKitCatalogue.Gettext,
        "This no longer exists. Remove the line to save."
      )

  defp row_error_message("note"),
    do:
      Gettext.gettext(
        PhoenixKitCatalogue.Gettext,
        "The note is too long (%{max} characters at most).",
        max: ItemDependency.max_note_length()
      )

  defp row_error_message(_quantity),
    do:
      Gettext.gettext(
        PhoenixKitCatalogue.Gettext,
        "Enter a quantity above zero, with at most four decimal places."
      )
end
