defmodule PhoenixKitCatalogue.Web.Components do
  @moduledoc """
  Reusable UI components for the Catalogue module.

  All components are designed to be opt-in — features are off by default and
  enabled via attributes. Import into any LiveView with:

      import PhoenixKitCatalogue.Web.Components

  ## Components

    * `search_input/1` — search bar with debounce and clear button
    * `search_results_summary/1` — "N results for …" / "X of Y" summary line
    * `scope_selector/1` — disclosure with catalogue/category checkbox lists
      for narrowing a search (pairs with `Catalogue.search_items/2` filters)
    * `catalogue_rules_picker/1` — smart-catalogue rule editor (checkbox +
      value + unit per catalogue; pairs with `Catalogue.put_catalogue_rules/3`)
    * `view_mode_toggle/1` — table/card view toggle synced via localStorage
    * `item_table/1` — configurable item table with selectable columns
    * `item_picker/1` — combobox for picking a single item via server-side
      search; backed by `Components.ItemPicker` LiveComponent, fires
      `{:item_picker_select, id, item}` / `{:item_picker_clear, id}` upward
    * `featured_image_card/1` — the shared featured-image card used on
      catalogue / category / item forms (thumbnail or empty state + picker
      buttons). Expects `open_featured_image_picker` / `clear_featured_image`
      events wired up in the owning LV — see `Attachments`.
    * `metadata_editor/1` — the shared metadata tab body for catalogue and
      item forms (opt-in fields from `Metadata.definitions/1`). Expects
      `add_meta_field` and `remove_meta_field` events wired up in the LV;
      text edits are absorbed via the form's `validate`.
    * `empty_state/1` — centered empty state card with message and optional action

  Several of these (`search_input`, `search_results_summary`,
  `view_mode_toggle`, `empty_state`) are deliberately generic — no
  catalogue-specific schema knowledge — and are candidates for
  promotion to `phoenix_kit` core once a coordinated release lands.
  Keeping them here for now avoids coupling catalogue's hex dep to
  unpublished core features.

  ## Examples

      <%!-- Minimal item table: just name and SKU --%>
      <.item_table items={@items} columns={[:name, :sku]} />

      <%!-- Full-featured table with search, pricing, and actions --%>
      <.item_table
        items={@items}
        columns={[:name, :sku, :base_price, :price, :unit, :status, :category, :manufacturer]}
        markup_percentage={@catalogue.markup_percentage}
        edit_path={&Paths.item_edit/1}
        on_delete="delete_item"
      />

      <%!-- Search bar --%>
      <.search_input query={@search_query} placeholder={Gettext.gettext(PhoenixKitWeb.Gettext, "Search items...")} />
  """

  use Phoenix.Component

  require Logger

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Input, only: [input: 1]
  import PhoenixKitWeb.Components.Core.Select, only: [select: 1]
  import PhoenixKitWeb.Components.Core.TableDefault
  import PhoenixKitWeb.Components.Core.TableRowMenu

  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKitCatalogue.Attachments
  alias PhoenixKitCatalogue.Metadata
  alias PhoenixKitCatalogue.Schemas.Item

  # ═══════════════════════════════════════════════════════════════════
  # Featured image card
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Renders the featured-image card used on catalogue, category, and item forms.

  Shown on the form in a self-contained card: a thumbnail + file name + size
  when an image is set, or a dashed empty-state with a primary button when
  not. Owning LV must handle the three events wired up by this component:

    * `open_featured_image_picker` — opens the `MediaSelectorModal`
    * `clear_featured_image` — nulls the pointer
    * (change — same `open_featured_image_picker` event)

  Each of those has a one-liner delegator to `Attachments`; see the
  reference wiring in `catalogue_form_live.ex`, `category_form_live.ex`,
  or `item_form_live.ex`.

  ## Attributes

    * `featured_image_uuid` — uuid string or nil; drives which branch renders
    * `featured_image_file` — the `%Storage.File{}` struct (for name/size) or nil
    * `subtitle` — override the default caption text (optional)
    * `class` — extra classes merged onto the outer card

  ## Examples

      <.featured_image_card
        featured_image_uuid={@featured_image_uuid}
        featured_image_file={@featured_image_file}
      />

      <.featured_image_card
        featured_image_uuid={@featured_image_uuid}
        featured_image_file={@featured_image_file}
        subtitle={gettext("Shown on category landing pages.")}
      />
  """
  attr(:featured_image_uuid, :string, default: nil)
  attr(:featured_image_file, :any, default: nil)
  attr(:subtitle, :string, default: nil)
  attr(:class, :string, default: "")

  def featured_image_card(assigns) do
    assigns =
      assign_new(assigns, :subtitle_text, fn ->
        assigns[:subtitle] ||
          Gettext.gettext(PhoenixKitWeb.Gettext, "Shown on listings and detail views.")
      end)

    ~H"""
    <div class={["card bg-base-100 shadow-lg", @class]}>
      <div class="card-body flex flex-col gap-3">
        <div class="flex items-center justify-between">
          <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
            <.icon name="hero-photo" class="w-4 h-4" />
            {Gettext.gettext(PhoenixKitWeb.Gettext, "Featured Image")}
          </h2>
          <span class="text-xs text-base-content/50">{@subtitle_text}</span>
        </div>

        <%= if @featured_image_file do %>
          <div class="flex items-center gap-4">
            <a
              href={URLSigner.signed_url(@featured_image_uuid, "original")}
              target="_blank"
              rel="noopener"
              class="shrink-0"
              title={Gettext.gettext(PhoenixKitWeb.Gettext, "Open original")}
            >
              <img
                src={URLSigner.signed_url(@featured_image_uuid, "thumbnail")}
                alt={@featured_image_file.original_file_name}
                class="w-24 h-24 rounded-md object-cover bg-base-200 border border-base-300"
              />
            </a>
            <div class="flex-1 min-w-0">
              <p class="text-sm font-medium truncate">
                {@featured_image_file.original_file_name}
              </p>
              <p class="text-xs text-base-content/50">
                {Attachments.format_file_size(@featured_image_file.size)}
              </p>
            </div>
            <div class="flex flex-col gap-2">
              <button
                type="button"
                phx-click="open_featured_image_picker"
                class="btn btn-sm btn-outline"
              >
                {Gettext.gettext(PhoenixKitWeb.Gettext, "Change")}
              </button>
              <button
                type="button"
                phx-click="clear_featured_image"
                phx-disable-with={Gettext.gettext(PhoenixKitWeb.Gettext, "Removing...")}
                class="btn btn-sm btn-ghost"
              >
                {Gettext.gettext(PhoenixKitWeb.Gettext, "Remove")}
              </button>
            </div>
          </div>
        <% else %>
          <div class="flex items-center justify-between py-4 border border-dashed border-base-300 rounded-md px-4">
            <div class="flex items-center gap-3 text-base-content/60">
              <.icon name="hero-photo" class="w-6 h-6" />
              <span class="text-sm">
                {Gettext.gettext(PhoenixKitWeb.Gettext, "No featured image set.")}
              </span>
            </div>
            <button
              type="button"
              phx-click="open_featured_image_picker"
              class="btn btn-sm btn-primary"
            >
              <.icon name="hero-plus" class="w-4 h-4 mr-1" />
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Set featured image")}
            </button>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ═══════════════════════════════════════════════════════════════════
  # Metadata editor
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Renders the metadata editor used inside the Metadata tab on the item
  and catalogue forms — heading + empty-state alert + one text input
  per attached key + add-picker dropdown.

  Owner LV must handle the three events wired up by this component:

    * `add_meta_field` (from the add-picker `<.select>`'s `phx-change`)
    * `remove_meta_field` (per-row × button)
    * (text edits are absorbed by the form's `phx-change="validate"`
      via `Metadata.absorb_params/2`)

  ## Attributes

    * `resource_type` — `:item` or `:catalogue`; drives which
      `Metadata.definitions/1` list is consumed for the add-picker and
      for legacy-key detection
    * `state` — the `%{attached: [key], values: %{key => string}}` map
      produced by `Metadata.build_state/2` and kept on the socket
    * `id_prefix` — DOM-id prefix for inputs and the add-picker (so the
      same Metadata editor can render twice on a page without colliding)
    * `title` — heading text (optional, defaults to "Metadata")
    * `description` — the grey subtitle under the heading (optional)

  ## Examples

      <.metadata_editor
        resource_type={:catalogue}
        state={@meta_state}
        id_prefix="catalogue"
      />
  """
  attr(:resource_type, :atom, required: true)
  attr(:state, :map, required: true)
  attr(:id_prefix, :string, required: true)
  attr(:title, :string, default: nil)
  attr(:description, :string, default: nil)

  def metadata_editor(assigns) do
    assigns =
      assigns
      |> assign_new(:title_text, fn ->
        assigns[:title] || Gettext.gettext(PhoenixKitWeb.Gettext, "Metadata")
      end)
      |> assign_new(:description_text, fn ->
        assigns[:description] ||
          Gettext.gettext(
            PhoenixKitWeb.Gettext,
            "Attach any metadata fields that apply. Blank values are dropped on save."
          )
      end)

    ~H"""
    <div class="card-body flex flex-col gap-5">
      <div>
        <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
          <.icon name="hero-tag" class="w-4 h-4" />
          {@title_text}
        </h2>
        <p class="text-sm text-base-content/60 mt-1">{@description_text}</p>
      </div>

      <div :if={@state.attached == []} class="alert">
        <.icon name="hero-information-circle" class="w-5 h-5 shrink-0" />
        <span class="text-sm">
          {Gettext.gettext(
            PhoenixKitWeb.Gettext,
            "No metadata attached yet. Pick a field below to add one."
          )}
        </span>
      </div>

      <div :if={@state.attached != []} class="flex flex-col gap-3">
        <div :for={key <- @state.attached} class="flex items-end gap-3">
          {render_metadata_row(assigns, key)}
        </div>
      </div>

      <%!-- Add-metadata picker: only surfaces definitions not yet
           attached. ID cycles with the attached-count so morphdom
           replaces the element on each add — this collapses the
           "stuck selection" quirk that otherwise leaves the picker
           showing the just-added label. --%>
      <div class="divider my-0"></div>
      <div class="flex items-end gap-3">
        <div class="flex-1">
          <.select
            id={"#{@id_prefix}-metadata-add-#{length(@state.attached)}"}
            name="key"
            value={nil}
            label={Gettext.gettext(PhoenixKitWeb.Gettext, "Add metadata")}
            prompt={Gettext.gettext(PhoenixKitWeb.Gettext, "— Pick a field —")}
            options={metadata_add_options(@resource_type, @state)}
            class="select-sm transition-colors focus-within:select-primary"
            phx-change="add_meta_field"
          />
        </div>
      </div>
    </div>
    """
  end

  defp metadata_add_options(resource_type, %{attached: attached}) do
    resource_type
    |> Metadata.definitions()
    |> Enum.reject(fn def_ -> def_.key in attached end)
    |> Enum.map(fn def_ -> {def_.label, def_.key} end)
  end

  # Renders one attached-metadata row. All fields are currently text;
  # legacy keys (stored but no longer in code) fall into a separate
  # read-only renderer that surfaces a "Legacy" pill so data isn't lost
  # silently when a definition is dropped.
  defp render_metadata_row(assigns, key) do
    value = Map.get(assigns.state.values, key, "")

    case Metadata.definition(assigns.resource_type, key) do
      nil -> render_legacy_metadata_row(assigns, key, value)
      def_ -> render_text_metadata_row(assigns, def_, value)
    end
  end

  defp render_text_metadata_row(assigns, def_, value) do
    assigns = assign(assigns, def_: def_, value: value)

    ~H"""
    <div class="flex-1">
      <.input
        type="text"
        name={"meta[#{@def_.key}]"}
        id={"#{@id_prefix}-meta-#{@def_.key}"}
        value={@value}
        label={@def_.label}
        class="input-sm transition-colors focus:input-primary"
      />
    </div>
    <button
      type="button"
      phx-click="remove_meta_field"
      phx-value-key={@def_.key}
      phx-disable-with={Gettext.gettext(PhoenixKitWeb.Gettext, "Removing...")}
      class="btn btn-ghost btn-sm btn-square text-error"
      title={Gettext.gettext(PhoenixKitWeb.Gettext, "Remove")}
    >
      <.icon name="hero-x-mark" class="w-4 h-4" />
    </button>
    """
  end

  defp render_legacy_metadata_row(assigns, key, value) do
    assigns = assign(assigns, key: key, value: value)

    ~H"""
    <div class="flex-1">
      <div class="mb-2 flex items-center gap-2 text-sm">
        <span class="font-mono">{@key}</span>
        <span class="badge badge-warning badge-sm">
          {Gettext.gettext(PhoenixKitWeb.Gettext, "Legacy")}
        </span>
      </div>
      <.input
        type="text"
        name={"meta_legacy[#{@key}]"}
        id={"#{@id_prefix}-meta-legacy-#{@key}"}
        value={@value}
        disabled
        class="input-sm"
      />
    </div>
    <button
      type="button"
      phx-click="remove_meta_field"
      phx-value-key={@key}
      phx-disable-with={Gettext.gettext(PhoenixKitWeb.Gettext, "Removing...")}
      class="btn btn-ghost btn-sm btn-square text-error"
      title={Gettext.gettext(PhoenixKitWeb.Gettext, "Remove")}
    >
      <.icon name="hero-x-mark" class="w-4 h-4" />
    </button>
    """
  end

  # ── Local status badge (catalogue statuses don't match upstream badge variants)

  @doc false
  attr(:status, :string, required: true)
  attr(:size, :atom, default: :sm)

  def status_badge(assigns) do
    ~H"""
    <div class={["badge", status_class(@status), size_class(@size)]}>
      {status_label(@status)}
    </div>
    """
  end

  defp status_class("active"), do: "badge-success"
  defp status_class("archived"), do: "badge-ghost"
  defp status_class("deleted"), do: "badge-error"
  defp status_class("inactive"), do: "badge-warning"
  defp status_class(_), do: "badge-neutral"

  # Status labels are translated via gettext so admin UIs render in the
  # active locale instead of the raw English DB value. Unknown statuses
  # render the raw key verbatim — wrapping it in `String.capitalize/1`
  # would pin English casing on a value the gettext extractor can't
  # see, so we leave it raw and rely on a future status enum addition
  # to surface the missing literal here.
  defp status_label("active"), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Active")
  defp status_label("inactive"), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Inactive")
  defp status_label("archived"), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Archived")
  defp status_label("deleted"), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Deleted")
  defp status_label("discontinued"), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Discontinued")
  defp status_label(other) when is_binary(other), do: other
  defp status_label(_), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Unknown")

  defp size_class(:xs), do: "badge-xs"
  defp size_class(:sm), do: "badge-sm"
  defp size_class(:md), do: ""
  defp size_class(:lg), do: "badge-lg"
  defp size_class(_), do: ""

  # ═══════════════════════════════════════════════════════════════════
  # Search input
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Renders a search input with debounce and clear button.

  Emits `search` event with `%{"query" => value}` on change/submit,
  and `clear_search` on clear button click. Override event names via attrs.

  ## Attributes

    * `query` — current search query string (required)
    * `placeholder` — input placeholder text. `nil` (default) resolves
      to a translated `gettext("Search...")` inside the component body.
      Pass an explicit string to override (e.g.
      `gettext("Search items...")`).
    * `on_search` — event name for search (default: "search")
    * `on_clear` — event name for clear (default: "clear_search")
    * `debounce` — debounce ms (default: 300)
    * `class` — additional CSS classes on the wrapper div
  """
  attr(:query, :string, required: true)
  attr(:placeholder, :string, default: nil)
  attr(:on_search, :string, default: "search")
  attr(:on_clear, :string, default: "clear_search")
  attr(:debounce, :integer, default: 300)
  attr(:class, :string, default: "")

  def search_input(assigns) do
    placeholder =
      assigns.placeholder ||
        Gettext.gettext(PhoenixKitWeb.Gettext, "Search...")

    assigns = assign(assigns, :placeholder, placeholder)

    ~H"""
    <div class={["flex gap-2", @class]}>
      <form phx-change={@on_search} phx-submit={@on_search} class="flex-1 relative">
        <input
          type="text"
          name="query"
          value={@query}
          placeholder={@placeholder}
          class="input input-bordered input-sm w-full pr-8"
          phx-debounce={@debounce}
          autocomplete="off"
        />
        <button
          :if={@query != ""}
          type="button"
          phx-click={@on_clear}
          class="absolute right-2 top-1/2 -translate-y-1/2 text-base-content/40 hover:text-base-content cursor-pointer"
        >
          <.icon name="hero-x-mark" class="w-4 h-4" />
        </button>
      </form>
    </div>
    """
  end

  # ═══════════════════════════════════════════════════════════════════
  # Search results summary
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Renders a search results count summary line.

  ## Attributes

    * `count` — total number of matching results (required)
    * `query` — the search query string (required)
    * `loaded` — optional count of results currently rendered. When given
      and less than `count`, the summary shows "X of Y" so users know the
      list is paging. Omit or pass `nil` for a plain "N results" line.
  """
  attr(:count, :integer, required: true)
  attr(:query, :string, required: true)
  attr(:loaded, :integer, default: nil)

  def search_results_summary(assigns) do
    ~H"""
    <span class="text-sm text-base-content/60">
      <%= if is_integer(@loaded) and @loaded < @count do %>
        {Gettext.gettext(
          PhoenixKitWeb.Gettext,
          "Showing %{loaded} of %{count} results for \"%{query}\"",
          loaded: @loaded,
          count: @count,
          query: @query
        )}
      <% else %>
        {Gettext.ngettext(
          PhoenixKitWeb.Gettext,
          "%{count} result for \"%{query}\"",
          "%{count} results for \"%{query}\"",
          @count, count: @count, query: @query)}
      <% end %>
    </span>
    """
  end

  # ═══════════════════════════════════════════════════════════════════
  # Empty state
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Renders an empty state card with a message and optional action slot.

  ## Attributes

    * `message` — the text to display (required)

  ## Slots

    * `inner_block` — optional action content (buttons, links)
  """
  attr(:message, :string, required: true)
  slot(:inner_block)

  def empty_state(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body items-center text-center py-12">
        <p class="text-base-content/60">{@message}</p>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  # ═══════════════════════════════════════════════════════════════════
  # View mode toggle
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Renders a table/card view toggle that syncs all tables sharing the same storage key.

  Place this once at the top of a page, and set `show_toggle={false}` +
  matching `storage_key` on the individual `item_table` components.

  Uses the same localStorage mechanism as `table_default`'s built-in toggle,
  so all tables reading the same key will respect the user's choice.

  ## Attributes

    * `storage_key` — the localStorage key to sync (required, must match the tables)
    * `class` — additional CSS classes

  ## Examples

      <.view_mode_toggle storage_key="catalogue-items" />
      <.item_table cards={true} show_toggle={false} storage_key="catalogue-items" ... />
  """
  attr(:storage_key, :string, required: true)
  attr(:class, :string, default: "")

  def view_mode_toggle(assigns) do
    ~H"""
    <div
      id={"view-toggle-#{@storage_key}"}
      phx-hook="TableCardView"
      data-storage-key={@storage_key}
      class={["hidden md:flex justify-end", @class]}
    >
      <div data-table-view="" class="hidden"></div>
      <div data-card-view="" class="hidden"></div>
      <div class="join">
        <button
          type="button"
          data-view-action="card"
          class="btn btn-sm join-item"
          title={Gettext.gettext(PhoenixKitWeb.Gettext, "Card view")}
        >
          <.icon name="hero-squares-2x2" class="w-4 h-4" />
        </button>
        <button
          type="button"
          data-view-action="table"
          class="btn btn-sm join-item"
          title={Gettext.gettext(PhoenixKitWeb.Gettext, "Table view")}
        >
          <.icon name="hero-bars-3-bottom-left" class="w-4 h-4" />
        </button>
      </div>
    </div>
    """
  end

  # ═══════════════════════════════════════════════════════════════════
  # Scope selector
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Renders a compact scope selector for narrowing a search to a subset of
  catalogues and/or categories.

  Designed to pair with `Catalogue.search_items/2`'s `:catalogue_uuids`
  and `:category_uuids` options. The component is thin — the parent
  LiveView owns the selection state and decides which catalogues and
  categories are pickable. Typical flow:

      # LV loads the pickable set (e.g. via list_catalogues_by_name_prefix/2)
      socket
      |> assign(:scope_catalogues, Catalogue.list_catalogues_by_name_prefix("Kit"))
      |> assign(:scope_categories, [])
      |> assign(:selected_catalogue_uuids, [])
      |> assign(:selected_category_uuids, [])

  Renders as a disclosure with a summary ("2 catalogues · all categories")
  and two checkbox lists inside. Each section is only rendered when its
  list is non-empty, so callers can use it for catalogue-only or
  category-only scoping.

  ## Events

  Emits four events (all names customizable via attrs):

    * `on_toggle_catalogue` — `%{"uuid" => uuid}` when a catalogue is clicked
    * `on_toggle_category` — `%{"uuid" => uuid}` when a category is clicked
    * `on_clear_catalogues` — no params; clear all catalogue selections
    * `on_clear_categories` — no params; clear all category selections

  The LV toggles membership in its own selection lists, then re-runs
  the search with the updated scope.

  ## Attributes

    * `catalogues` — list of `%Catalogue{}` the user can pick from (default `[]`)
    * `categories` — list of `%Category{}` the user can pick from (default `[]`)
    * `selected_catalogue_uuids` — currently selected catalogue UUIDs (default `[]`)
    * `selected_category_uuids` — currently selected category UUIDs (default `[]`)
    * `on_toggle_catalogue` — event name (default `"toggle_catalogue_scope"`)
    * `on_toggle_category` — event name (default `"toggle_category_scope"`)
    * `on_clear_catalogues` — event name (default `"clear_catalogue_scope"`)
    * `on_clear_categories` — event name (default `"clear_category_scope"`)
    * `id` — DOM id (default `"scope-selector"`)
    * `open` — force the disclosure open (default `false` — collapsed until clicked)
    * `class` — extra CSS classes on the wrapper

  ## Example

      <.scope_selector
        catalogues={@scope_catalogues}
        categories={@scope_categories}
        selected_catalogue_uuids={@selected_catalogue_uuids}
        selected_category_uuids={@selected_category_uuids}
      />
  """
  attr(:catalogues, :list, default: [])
  attr(:categories, :list, default: [])
  attr(:selected_catalogue_uuids, :list, default: [])
  attr(:selected_category_uuids, :list, default: [])
  attr(:on_toggle_catalogue, :string, default: "toggle_catalogue_scope")
  attr(:on_toggle_category, :string, default: "toggle_category_scope")
  attr(:on_clear_catalogues, :string, default: "clear_catalogue_scope")
  attr(:on_clear_categories, :string, default: "clear_category_scope")
  attr(:id, :string, default: "scope-selector")
  attr(:open, :boolean, default: false)
  attr(:class, :string, default: "")

  def scope_selector(assigns) do
    assigns =
      assigns
      |> assign(:has_catalogues, assigns.catalogues != [])
      |> assign(:has_categories, assigns.categories != [])
      |> assign(:cat_count, length(assigns.selected_catalogue_uuids))
      |> assign(:cat_categories_count, length(assigns.selected_category_uuids))

    ~H"""
    <details
      :if={@has_catalogues or @has_categories}
      id={@id}
      open={@open}
      class={["collapse collapse-arrow bg-base-200 border border-base-300", @class]}
    >
      <summary class="collapse-title min-h-0 py-3 pr-10 text-sm font-medium cursor-pointer">
        <span class="inline-flex items-center gap-2">
          <.icon name="hero-funnel" class="w-4 h-4" />
          <span>{Gettext.gettext(PhoenixKitWeb.Gettext, "Scope")}</span>
          <span class="text-base-content/60 font-normal">
            {scope_summary_text(@has_catalogues, @has_categories, @cat_count, @cat_categories_count)}
          </span>
        </span>
      </summary>
      <div class="collapse-content">
        <div class="grid gap-4 md:grid-cols-2">
          <section :if={@has_catalogues}>
            <div class="flex items-center justify-between mb-2">
              <span class="label-text font-medium">
                {Gettext.gettext(PhoenixKitWeb.Gettext, "Catalogues")}
              </span>
              <button
                :if={@cat_count > 0}
                type="button"
                phx-click={@on_clear_catalogues}
                class="btn btn-ghost btn-xs"
              >
                {Gettext.gettext(PhoenixKitWeb.Gettext, "Clear")}
              </button>
            </div>
            <ul class="max-h-60 overflow-y-auto pr-1 space-y-1">
              <li :for={cat <- @catalogues}>
                <label class="label cursor-pointer justify-start gap-2 py-1">
                  <input
                    type="checkbox"
                    class="checkbox checkbox-sm"
                    checked={cat.uuid in @selected_catalogue_uuids}
                    phx-click={@on_toggle_catalogue}
                    phx-value-uuid={cat.uuid}
                  />
                  <span class="label-text truncate" title={cat.name}>{cat.name}</span>
                </label>
              </li>
            </ul>
          </section>
          <section :if={@has_categories}>
            <div class="flex items-center justify-between mb-2">
              <span class="label-text font-medium">
                {Gettext.gettext(PhoenixKitWeb.Gettext, "Categories")}
              </span>
              <button
                :if={@cat_categories_count > 0}
                type="button"
                phx-click={@on_clear_categories}
                class="btn btn-ghost btn-xs"
              >
                {Gettext.gettext(PhoenixKitWeb.Gettext, "Clear")}
              </button>
            </div>
            <ul class="max-h-60 overflow-y-auto pr-1 space-y-1">
              <li :for={cat <- @categories}>
                <label class="label cursor-pointer justify-start gap-2 py-1">
                  <input
                    type="checkbox"
                    class="checkbox checkbox-sm"
                    checked={cat.uuid in @selected_category_uuids}
                    phx-click={@on_toggle_category}
                    phx-value-uuid={cat.uuid}
                  />
                  <span class="label-text truncate" title={cat.name}>{cat.name}</span>
                </label>
              </li>
            </ul>
          </section>
        </div>
      </div>
    </details>
    """
  end

  defp scope_summary_text(has_catalogues, has_categories, cat_count, cat_categories_count) do
    parts =
      [
        has_catalogues && catalogue_summary(cat_count),
        has_categories && category_summary(cat_categories_count)
      ]
      |> Enum.filter(& &1)

    case parts do
      [] -> ""
      list -> "· " <> Enum.join(list, " · ")
    end
  end

  defp catalogue_summary(0), do: Gettext.gettext(PhoenixKitWeb.Gettext, "all catalogues")

  defp catalogue_summary(n) do
    Gettext.ngettext(
      PhoenixKitWeb.Gettext,
      "%{count} catalogue",
      "%{count} catalogues",
      n,
      count: n
    )
  end

  defp category_summary(0), do: Gettext.gettext(PhoenixKitWeb.Gettext, "all categories")

  defp category_summary(n) do
    Gettext.ngettext(
      PhoenixKitWeb.Gettext,
      "%{count} category",
      "%{count} categories",
      n,
      count: n
    )
  end

  # ═══════════════════════════════════════════════════════════════════
  # Catalogue rules picker (smart catalogue)
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Renders the smart-catalogue rule editor: one row per candidate
  catalogue with a checkbox, a numeric value input, and a unit dropdown.

  Pairs with `PhoenixKitCatalogue.Catalogue.put_catalogue_rules/3`. The
  component is thin — the caller (usually `ItemFormLive`) owns the
  working-rules state in a map `%{referenced_catalogue_uuid => %{value, unit}}`
  and calls `put_catalogue_rules/3` on save.

  **Event flow:**

    * `on_toggle` — `%{"uuid" => uuid}` when the checkbox is clicked.
      Caller toggles membership in its rules map.
    * `on_set_value` — `%{"uuid" => uuid, "value" => string}` when the
      user edits the amount input.
    * `on_set_unit` — `%{"uuid" => uuid, "unit" => string}` when the
      user picks a different unit.
    * `on_clear` — no params; clear every checked row. Shown only when
      at least one rule is active.

  Rows for an unchecked catalogue render disabled inputs but stay
  visible so the user always sees the full picker. When `value` is blank
  and `item_default_value` is given, the input's placeholder previews
  the inherited default (e.g. `"Inherit: 5"`). The unit dropdown is
  self-contained per row — it does not inherit from any item-level
  default, so changing the item's `default_unit` never flips a rule
  row's visible unit.

  ## Attributes

    * `catalogues` — list of `%Catalogue{}` the user can pick (required).
      Typically `Catalogue.list_catalogues()` filtered to active/archived
      and excluding the parent smart catalogue itself.
    * `rules` — map `%{referenced_catalogue_uuid => %{value, unit}}`
      (or `%CatalogueRule{}` values; only `:value` / `:unit` are read).
      Unchecked catalogues simply don't appear in the map (default `%{}`).
    * `item_default_value` — item's `default_value`, used as the value
      input's placeholder (default `nil`)
    * `units` — list of unit options for the dropdown
      (default `["percent", "flat"]`). The first entry is the fallback
      shown when a rule has no unit set yet.
    * `on_toggle` — event name (default `"toggle_catalogue_rule"`)
    * `on_set_value` — event name (default `"set_catalogue_rule_value"`)
    * `on_set_unit` — event name (default `"set_catalogue_rule_unit"`)
    * `on_clear` — event name (default `"clear_catalogue_rules"`)
    * `id` — DOM id (default `"catalogue-rules-picker"`)
    * `class` — extra wrapper classes

  ## Example

      <.catalogue_rules_picker
        catalogues={@candidate_catalogues}
        rules={@working_rules}
        item_default_value={@item_default_value}
      />
  """
  attr(:catalogues, :list, required: true)
  attr(:rules, :map, default: %{})
  attr(:item_default_value, :any, default: nil)
  attr(:units, :list, default: ["percent", "flat"])
  attr(:on_toggle, :string, default: "toggle_catalogue_rule")
  attr(:on_set_value, :string, default: "set_catalogue_rule_value")
  attr(:on_set_unit, :string, default: "set_catalogue_rule_unit")
  attr(:on_clear, :string, default: "clear_catalogue_rules")
  attr(:on_reorder, :string, default: nil, doc: "When set, rule rows are draggable")
  attr(:id, :string, default: "catalogue-rules-picker")
  attr(:class, :string, default: "")

  def catalogue_rules_picker(assigns) do
    assigns =
      assigns
      |> assign(:active_count, map_size(assigns.rules))
      |> assign(:default_placeholder, default_placeholder(assigns))

    ~H"""
    <div id={@id} class={["space-y-3", @class]}>
      <div :if={@catalogues == []} class="text-sm text-base-content/60 italic">
        {Gettext.gettext(PhoenixKitWeb.Gettext, "No other catalogues available to reference yet.")}
      </div>
      <div :if={@catalogues != []}>
        <div class="flex items-center justify-between mb-2">
          <span class="text-sm text-base-content/70">
            {rules_summary_text(@active_count, length(@catalogues))}
          </span>
          <button
            :if={@active_count > 0}
            type="button"
            phx-click={@on_clear}
            class="btn btn-ghost btn-xs"
          >
            {Gettext.gettext(PhoenixKitWeb.Gettext, "Clear all")}
          </button>
        </div>
        <div
          id={"#{@id}-rows"}
          class="rounded-box border border-base-300 bg-base-100 divide-y divide-base-300"
          data-sortable={if @on_reorder, do: "true"}
          data-sortable-event={@on_reorder}
          data-sortable-items=".sortable-item"
          data-sortable-hide-source="false"
          data-sortable-handle={if @on_reorder, do: ".pk-drag-handle"}
          phx-hook={if @on_reorder, do: "SortableGrid"}
        >
          <.catalogue_rule_row
            :for={cat <- @catalogues}
            catalogue={cat}
            rule={Map.get(@rules, cat.uuid)}
            default_placeholder={@default_placeholder}
            units={@units}
            draggable={not is_nil(@on_reorder)}
            on_toggle={@on_toggle}
            on_set_value={@on_set_value}
            on_set_unit={@on_set_unit}
          />
        </div>
      </div>
    </div>
    """
  end

  attr(:catalogue, :any, required: true)
  attr(:rule, :any, default: nil)
  attr(:default_placeholder, :string, default: "")
  attr(:units, :list, required: true)
  attr(:draggable, :boolean, default: false)
  attr(:on_toggle, :string, required: true)
  attr(:on_set_value, :string, required: true)
  attr(:on_set_unit, :string, required: true)

  defp catalogue_rule_row(assigns) do
    fallback_unit = List.first(assigns.units) || "percent"

    assigns =
      assigns
      |> assign(:checked?, not is_nil(assigns.rule))
      |> assign(:rule_value, rule_value(assigns.rule))
      |> assign(:rule_unit, rule_unit(assigns.rule, fallback_unit))
      |> assign(:kind_label, kind_label(assigns.catalogue))

    ~H"""
    <div
      class={[
        "flex items-center gap-3 px-3 py-2",
        @draggable && "sortable-item"
      ]}
      data-id={@catalogue.uuid}
    >
      <div
        :if={@draggable}
        class="pk-drag-handle cursor-grab active:cursor-grabbing text-base-content/30 hover:text-base-content/70 select-none"
        title={Gettext.gettext(PhoenixKitWeb.Gettext, "Drag to reorder")}
      >
        <.icon name="hero-bars-3" class="w-4 h-4" />
      </div>
      <label class="flex items-center gap-2 flex-1 min-w-0 cursor-pointer">
        <input
          type="checkbox"
          class="checkbox checkbox-sm"
          checked={@checked?}
          phx-click={@on_toggle}
          phx-value-uuid={@catalogue.uuid}
        />
        <span class="truncate" title={@catalogue.name}>{@catalogue.name}</span>
        <span :if={@kind_label} class="badge badge-outline badge-xs">{@kind_label}</span>
      </label>
      <div class="flex items-center gap-2 shrink-0">
        <input
          type="number"
          class="input input-bordered input-sm w-24"
          value={@rule_value}
          step="0.0001"
          min="0"
          disabled={not @checked?}
          placeholder={@default_placeholder}
          phx-blur={@on_set_value}
          phx-value-uuid={@catalogue.uuid}
          name="value"
        />
        <.select
          name="unit"
          id={"rule-unit-#{@catalogue.uuid}"}
          value={@rule_unit}
          options={Enum.map(@units, &{unit_label(&1), &1})}
          class="select-sm w-28"
          disabled={not @checked?}
          phx-change={@on_set_unit}
          phx-value-uuid={@catalogue.uuid}
        />
      </div>
    </div>
    """
  end

  defp rules_summary_text(0, total),
    do:
      Gettext.gettext(
        PhoenixKitWeb.Gettext,
        "%{total} catalogues available — none selected",
        total: total
      )

  defp rules_summary_text(active, total) do
    Gettext.ngettext(
      PhoenixKitWeb.Gettext,
      "%{active} of %{total} catalogue selected",
      "%{active} of %{total} catalogues selected",
      total,
      active: active,
      total: total
    )
  end

  defp default_placeholder(%{item_default_value: nil}), do: ""

  defp default_placeholder(%{item_default_value: value}) do
    Gettext.gettext(PhoenixKitWeb.Gettext, "Inherit: %{value}",
      value: format_decimal_display(value)
    )
  rescue
    _ -> ""
  end

  # Strip insignificant trailing zeros so DB values like `5.0000` render
  # as `5` while `5.1000` still renders as `5.1`. Non-Decimal values
  # (strings mid-edit, numbers) pass through unchanged.
  defp format_decimal_display(%Decimal{} = d),
    do: d |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp format_decimal_display(v) when is_number(v), do: to_string(v)
  defp format_decimal_display(v) when is_binary(v), do: v
  defp format_decimal_display(_), do: ""

  defp rule_value(nil), do: ""
  defp rule_value(%{value: nil}), do: ""
  defp rule_value(%{value: %Decimal{} = d}), do: format_decimal_display(d)
  defp rule_value(%{value: v}) when is_number(v) or is_binary(v), do: v
  defp rule_value(_), do: ""

  # Second arg is the component-level fallback (first entry of `units`,
  # typically `"percent"`) used only when the rule has no unit of its
  # own — it does NOT reach for the item's `default_unit`. A rule's unit
  # is self-contained per row.
  defp rule_unit(nil, fallback), do: fallback
  defp rule_unit(%{unit: nil}, fallback), do: fallback
  defp rule_unit(%{unit: u}, _fallback) when is_binary(u), do: u
  defp rule_unit(_, fallback), do: fallback

  # "%" is a literal symbol — sending it through gettext just creates
  # a no-op translation entry that every locale would translate to "%".
  # "Flat" is a real word and stays translatable.
  defp unit_label("percent"), do: "%"
  defp unit_label("flat"), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Flat")
  defp unit_label(u), do: to_string(u)

  defp kind_label(%{kind: "smart"}), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Smart")
  defp kind_label(_), do: nil

  # ═══════════════════════════════════════════════════════════════════
  # Item table
  # ═══════════════════════════════════════════════════════════════════

  @all_columns ~w(name sku base_price price discount final_price unit status category catalogue manufacturer)a

  @doc """
  Renders a configurable item table with optional card view toggle.

  Columns are opt-in — only the columns you list are shown. Actions (edit, delete,
  restore) are opt-in via their respective attributes.

  ## Attributes

    * `items` — list of items to display (required)
    * `columns` — list of column atoms to show (default: `[:name, :sku, :base_price, :status]`)
      Available: #{inspect(@all_columns)}
    * `cards` — enable card view toggle (default: `false`). When enabled, renders a
      table/card toggle button and shows items as cards on mobile. The card view
      shows the item name as the title, selected columns as key-value fields,
      and action buttons in the card footer.
    * `id` — unique ID for the component (required when `cards` is true, used by
      the JS hook to persist view preference)
    * `markup_percentage` — catalogue markup for `:price` and `:final_price` columns
      (required when either is listed; ignored otherwise)
    * `discount_percentage` — catalogue discount for `:discount` and `:final_price`
      columns (required when either is listed; ignored otherwise). The `:discount`
      column honors per-item overrides via `Item.effective_discount/2`.
    * `edit_path` — 1-arity function `(uuid -> path)` to enable edit links
    * `on_delete` — event name for soft-delete button (e.g. `"delete_item"`)
    * `on_restore` — event name for restore button (e.g. `"restore_item"`)
    * `on_permanent_delete` — event name for permanent delete (e.g. `"show_delete_confirm"`)
    * `permanent_delete_type` — type string passed as `phx-value-type` (e.g. `"item"`)
    * `catalogue_path` — 1-arity function `(uuid -> path)` for catalogue links in `:catalogue` column
    * `variant` — table variant: `"default"` or `"zebra"` (default: `"default"`)
    * `size` — table size: `"xs"`, `"sm"`, `"md"`, `"lg"` (default: `"sm"`)
    * `wrapper_class` — override wrapper CSS class

  ## Examples

      <%!-- Table only --%>
      <.item_table items={@items} columns={[:name, :sku, :base_price]} />

      <%!-- With card view toggle --%>
      <.item_table
        items={@items}
        columns={[:name, :sku, :base_price, :price, :status]}
        cards={true}
        id="catalogue-items"
        markup_percentage={@catalogue.markup_percentage}
        edit_path={&Paths.item_edit/1}
        on_delete="delete_item"
      />
  """
  attr(:items, :list, required: true)
  attr(:columns, :list, default: [:name, :sku, :base_price, :status])
  attr(:cards, :boolean, default: false)
  attr(:show_toggle, :boolean, default: true)
  attr(:id, :string, default: nil)
  attr(:storage_key, :string, default: nil)
  attr(:markup_percentage, :any, default: nil)
  attr(:discount_percentage, :any, default: nil)
  attr(:edit_path, :any, default: nil)
  attr(:on_delete, :string, default: nil)
  attr(:on_restore, :string, default: nil)
  attr(:on_permanent_delete, :string, default: nil)
  attr(:permanent_delete_type, :string, default: "item")
  attr(:catalogue_path, :any, default: nil)
  attr(:variant, :string, default: "default")
  attr(:size, :string, default: "sm")
  attr(:wrapper_class, :string, default: nil)

  attr(:pdf_search_event, :string,
    default: nil,
    doc:
      "When set, action menu gets a 'Search PDFs' entry that pushes this event with phx-value-uuid"
  )

  attr(:on_reorder, :string,
    default: nil,
    doc: "When set, rows become draggable and emit this event"
  )

  attr(:reorder_scope, :map,
    default: %{},
    doc:
      "Map of extra scope values (e.g. %{catalogue_uuid: \"...\", category_uuid: \"...\"}) — exposed to the SortableGrid hook as data-sortable-scope-* attrs"
  )

  attr(:reorder_group, :string,
    default: nil,
    doc:
      "SortableJS group name; tables sharing a group can exchange items via cross-container drag (e.g. items moving between categories)"
  )

  attr(:selectable, :boolean,
    default: false,
    doc:
      "When true, each row gets a checkbox in the leftmost column (combined with the drag handle when reorderable). The drag handle is hidden until the row is hovered."
  )

  attr(:selected_uuids, :any, default: nil, doc: "MapSet of selected item UUIDs")

  attr(:on_toggle_select, :string,
    default: nil,
    doc:
      "Event name fired when the user toggles a row's checkbox. The LV handler receives `phx-value-uuid`."
  )

  def item_table(assigns) do
    assigns =
      assigns
      |> assign(:has_actions, has_actions?(assigns))
      |> assign(:card_columns, Enum.reject(assigns.columns, &(&1 == :name)))
      |> assign(:reorder_scope_attrs, build_reorder_scope_attrs(assigns[:reorder_scope] || %{}))

    ~H"""
    <.table_default
      variant={@variant}
      size={@size}
      toggleable={@cards}
      show_toggle={@show_toggle}
      id={@id}
      storage_key={@storage_key}
      items={@items}
      on_reorder={@on_reorder}
      reorder_scope={@reorder_scope}
      reorder_group={@reorder_group}
      item_id={fn item -> item.uuid end}
      card_fields={
        &card_fields(&1, @card_columns, @markup_percentage, @discount_percentage, @catalogue_path)
      }
    >
      <:card_header :let={item}>
        <%!-- Mobile card view: prepend the checkbox so bulk-select works
             on phone screens too. The desktop table view has its own
             checkbox column; this keeps the card view symmetric. --%>
        <div class="flex items-center gap-2">
          <input
            :if={@selectable and @on_toggle_select}
            type="checkbox"
            class="checkbox checkbox-xs"
            checked={selected?(@selected_uuids, item.uuid)}
            phx-click={@on_toggle_select}
            phx-value-uuid={item.uuid}
          />
          <.link
            :if={@edit_path && item.uuid}
            navigate={safe_call(@edit_path, item.uuid)}
            class="font-medium text-sm link link-hover"
          >
            {item.name || "—"}
          </.link>
          <span :if={!@edit_path || !item.uuid} class="font-medium text-sm">{item.name || "—"}</span>
        </div>
      </:card_header>
      <.table_default_header>
        <.table_default_row>
          <.table_default_header_cell :if={!is_nil(@on_reorder) or @selectable} class="w-10"></.table_default_header_cell>
          <.table_default_header_cell :for={col <- @columns}>
            {column_label(col)}
          </.table_default_header_cell>
          <.table_default_header_cell :if={@has_actions} class="text-right">
            {Gettext.gettext(PhoenixKitWeb.Gettext, "Actions")}
          </.table_default_header_cell>
        </.table_default_row>
      </.table_default_header>
      <tbody
        id={if @on_reorder, do: "#{@id || "items-tbody"}-tbody"}
        data-sortable={if @on_reorder, do: "true"}
        data-sortable-event={@on_reorder}
        data-sortable-items=".sortable-item"
        data-sortable-hide-source="false"
        data-sortable-group={@reorder_group}
        data-sortable-handle={if @on_reorder, do: ".pk-drag-handle"}
        phx-hook={if @on_reorder, do: "SortableGrid"}
        {@reorder_scope_attrs}
      >
        <.table_default_row
          :for={item <- @items}
          class={
            [
              if(@on_reorder, do: "sortable-item"),
              "group",
              # Selected-row tint + left-edge primary accent. 10% bg
              # alone (the media_browser convention) is too subtle on
              # zebra-striped tables; the left border makes selection
              # unambiguous at a glance. `!` overrides daisyUI's table
              # zebra row bg.
              selected?(@selected_uuids, item.uuid) &&
                "!bg-primary/15 border-l-4 border-l-primary"
            ]
            |> Enum.reject(&(&1 in [nil, false]))
            |> Enum.join(" ")
          }
          data-id={item.uuid}
        >
          <%!-- Combined checkbox + drag handle column. Checkbox is
               always visible when selectable; drag handle hover-reveals
               via group-hover so it doesn't compete visually with the
               checkbox or the row content. --%>
          <.table_default_cell :if={!is_nil(@on_reorder) or @selectable} class="w-10">
            <div class="flex items-center gap-1.5">
              <span
                :if={@on_reorder}
                class="pk-drag-handle cursor-grab active:cursor-grabbing text-base-content/40 opacity-0 group-hover:opacity-100 transition-opacity"
                title={Gettext.gettext(PhoenixKitWeb.Gettext, "Drag to reorder")}
              >
                <.icon name="hero-bars-3" class="w-4 h-4" />
              </span>
              <input
                :if={@selectable and @on_toggle_select}
                type="checkbox"
                class="checkbox checkbox-xs"
                checked={selected?(@selected_uuids, item.uuid)}
                phx-click={@on_toggle_select}
                phx-value-uuid={item.uuid}
              />
            </div>
          </.table_default_cell>
          <.item_cell
            :for={col <- @columns}
            column={col}
            item={item}
            markup_percentage={@markup_percentage}
            discount_percentage={@discount_percentage}
            catalogue_path={@catalogue_path}
            edit_path={@edit_path}
          />
          <.item_actions
            :if={@has_actions}
            item={item}
            edit_path={@edit_path}
            on_delete={@on_delete}
            on_restore={@on_restore}
            on_permanent_delete={@on_permanent_delete}
            permanent_delete_type={@permanent_delete_type}
            pdf_search_event={@pdf_search_event}
          />
        </.table_default_row>
      </tbody>
      <:card_actions :let={item} :if={@has_actions}>
        <.card_action_buttons
          item={item}
          edit_path={@edit_path}
          on_delete={@on_delete}
          on_restore={@on_restore}
          on_permanent_delete={@on_permanent_delete}
          permanent_delete_type={@permanent_delete_type}
          pdf_search_event={@pdf_search_event}
        />
      </:card_actions>
    </.table_default>
    """
  end

  # ── Card view helpers ───────────────────────────────────────────

  # Translates a `%{key => value}` map into a list of
  # `{"data-sortable-scope-key" => value}` tuples so the SortableGrid
  # hook can pluck them off the container as extra payload. `nil` /
  # blank values become `""`-valued attrs so the parser side can detect
  # "uncategorized" without ambiguity.
  defp selected?(nil, _uuid), do: false
  defp selected?(%MapSet{} = set, uuid), do: MapSet.member?(set, uuid)
  defp selected?(_, _), do: false

  defp build_reorder_scope_attrs(scope) when is_map(scope) do
    Enum.flat_map(scope, fn {key, value} ->
      attr_name = "data-sortable-scope-" <> dash_case(to_string(key))
      [{attr_name, scope_value_to_string(value)}]
    end)
  end

  defp scope_value_to_string(nil), do: ""
  defp scope_value_to_string(v) when is_binary(v), do: v
  defp scope_value_to_string(v), do: to_string(v)

  defp dash_case(name) do
    name
    |> String.replace("_", "-")
    |> String.downcase()
  end

  defp card_fields(item, columns, markup_percentage, discount_percentage, catalogue_path) do
    Enum.flat_map(columns, fn col ->
      case card_field_value(item, col, markup_percentage, discount_percentage, catalogue_path) do
        nil -> []
        value -> [%{label: column_label(col), value: value}]
      end
    end)
  end

  defp card_field_value(item, :sku, _, _, _), do: item.sku || "—"
  defp card_field_value(item, :base_price, _, _, _), do: format_price(item.base_price)

  defp card_field_value(item, :price, markup, _, _),
    do: format_price(safe_sale_price(item, markup))

  defp card_field_value(item, :discount, _, discount, _),
    do: format_percentage(safe_effective_discount(item, discount))

  defp card_field_value(item, :final_price, markup, discount, _),
    do: format_price(safe_final_price(item, markup, discount))

  defp card_field_value(item, :unit, _, _, _), do: format_unit(item.unit)

  defp card_field_value(item, :status, _, _, _),
    do: status_label(item.status || "unknown")

  defp card_field_value(item, :category, _, _, _), do: safe_assoc_field(item, :category, :name)

  defp card_field_value(item, :catalogue, _, _, _),
    do: safe_assoc_field(item, :catalogue, :name)

  defp card_field_value(item, :manufacturer, _, _, _),
    do: safe_assoc_field(item, :manufacturer, :name)

  defp card_field_value(_, col, _, _, _) do
    Logger.warning("item_table card: unknown column #{inspect(col)}, skipping")
    nil
  end

  attr(:item, :any, required: true)
  attr(:edit_path, :any, default: nil)
  attr(:on_delete, :string, default: nil)
  attr(:on_restore, :string, default: nil)
  attr(:on_permanent_delete, :string, default: nil)
  attr(:permanent_delete_type, :string, default: "item")
  attr(:pdf_search_event, :string, default: nil)

  defp card_action_buttons(assigns) do
    ~H"""
    <%!-- Mobile card view: icon-only buttons (text labels would overflow
         a 390px card row). `title` carries the label as a native browser
         tooltip + accessibility name. The card view is desktop-hidden
         (`md:hidden`) so we don't worry about labelled-button parity. --%>
    <.link
      :if={@edit_path && @item.uuid}
      navigate={safe_call(@edit_path, @item.uuid)}
      class="btn btn-ghost btn-xs btn-square"
      title={Gettext.gettext(PhoenixKitWeb.Gettext, "Edit")}
      aria-label={Gettext.gettext(PhoenixKitWeb.Gettext, "Edit")}
    >
      <.icon name="hero-pencil" class="w-4 h-4" />
    </.link>
    <button
      :if={@pdf_search_event && @item.uuid}
      type="button"
      phx-click={@pdf_search_event}
      phx-value-uuid={@item.uuid}
      class="btn btn-ghost btn-xs btn-square"
      title={Gettext.gettext(PhoenixKitWeb.Gettext, "Search PDFs")}
      aria-label={Gettext.gettext(PhoenixKitWeb.Gettext, "Search PDFs")}
    >
      <.icon name="hero-document-magnifying-glass" class="w-4 h-4" />
    </button>
    <button
      :if={@on_delete}
      phx-click={@on_delete}
      phx-value-uuid={@item.uuid}
      phx-disable-with={Gettext.gettext(PhoenixKitWeb.Gettext, "Deleting...")}
      class="btn btn-ghost btn-xs btn-square text-error"
      title={Gettext.gettext(PhoenixKitWeb.Gettext, "Delete")}
      aria-label={Gettext.gettext(PhoenixKitWeb.Gettext, "Delete")}
    >
      <.icon name="hero-trash" class="w-4 h-4" />
    </button>
    <button
      :if={@on_restore}
      phx-click={@on_restore}
      phx-value-uuid={@item.uuid}
      phx-disable-with={Gettext.gettext(PhoenixKitWeb.Gettext, "Restoring...")}
      class="btn btn-ghost btn-xs btn-square text-success"
      title={Gettext.gettext(PhoenixKitWeb.Gettext, "Restore")}
      aria-label={Gettext.gettext(PhoenixKitWeb.Gettext, "Restore")}
    >
      <.icon name="hero-arrow-path" class="w-4 h-4" />
    </button>
    <button
      :if={@on_permanent_delete}
      phx-click={@on_permanent_delete}
      phx-value-uuid={@item.uuid}
      phx-value-type={@permanent_delete_type}
      phx-disable-with={Gettext.gettext(PhoenixKitWeb.Gettext, "Deleting...")}
      class="btn btn-ghost btn-xs btn-square text-error"
      title={Gettext.gettext(PhoenixKitWeb.Gettext, "Delete Forever")}
      aria-label={Gettext.gettext(PhoenixKitWeb.Gettext, "Delete Forever")}
    >
      <.icon name="hero-trash" class="w-4 h-4" />
    </button>
    """
  end

  # ── Column cells ───────────────────────────────────────────────

  attr(:column, :atom, required: true)
  attr(:item, :any, required: true)
  attr(:markup_percentage, :any, default: nil)
  attr(:discount_percentage, :any, default: nil)
  attr(:catalogue_path, :any, default: nil)
  attr(:edit_path, :any, default: nil)

  defp item_cell(%{column: :name} = assigns) do
    ~H"""
    <.table_default_cell class="font-medium">
      <.link
        :if={@edit_path && @item.uuid}
        navigate={safe_call(@edit_path, @item.uuid)}
        class="link link-hover"
      >
        {@item.name || "—"}
      </.link>
      <span :if={!@edit_path || !@item.uuid}>{@item.name || "—"}</span>
    </.table_default_cell>
    """
  end

  defp item_cell(%{column: :sku} = assigns) do
    ~H"""
    <.table_default_cell class="text-sm font-mono text-base-content/60">
      {@item.sku || "—"}
    </.table_default_cell>
    """
  end

  defp item_cell(%{column: :base_price} = assigns) do
    ~H"""
    <.table_default_cell class="text-sm">{format_price(@item.base_price)}</.table_default_cell>
    """
  end

  defp item_cell(%{column: :price} = assigns) do
    ~H"""
    <.table_default_cell class="text-sm font-semibold">
      {format_price(safe_sale_price(@item, @markup_percentage))}
    </.table_default_cell>
    """
  end

  defp item_cell(%{column: :discount} = assigns) do
    ~H"""
    <.table_default_cell class="text-sm">
      {format_percentage(safe_effective_discount(@item, @discount_percentage))}
    </.table_default_cell>
    """
  end

  defp item_cell(%{column: :final_price} = assigns) do
    ~H"""
    <.table_default_cell class="text-sm font-semibold">
      {format_price(safe_final_price(@item, @markup_percentage, @discount_percentage))}
    </.table_default_cell>
    """
  end

  defp item_cell(%{column: :unit} = assigns) do
    ~H"""
    <.table_default_cell class="text-sm">{format_unit(@item.unit)}</.table_default_cell>
    """
  end

  defp item_cell(%{column: :status} = assigns) do
    ~H"""
    <.table_default_cell>
      <.status_badge status={@item.status || "unknown"} size={:xs} />
    </.table_default_cell>
    """
  end

  defp item_cell(%{column: :category} = assigns) do
    ~H"""
    <.table_default_cell class="text-sm text-base-content/60">
      {safe_assoc_field(@item, :category, :name)}
    </.table_default_cell>
    """
  end

  defp item_cell(%{column: :catalogue} = assigns) do
    assigns =
      assign(
        assigns,
        :catalogue_name,
        safe_assoc_field(assigns.item, :catalogue, :name)
      )

    ~H"""
    <.table_default_cell class="text-sm">
      <.link
        :if={@catalogue_name != "—" && @catalogue_path}
        navigate={safe_call(@catalogue_path, safe_assoc_field(@item, :catalogue, :uuid))}
        class="link link-hover"
      >
        {@catalogue_name}
      </.link>
      <span :if={@catalogue_name == "—" || !@catalogue_path} class="text-base-content/60">—</span>
    </.table_default_cell>
    """
  end

  defp item_cell(%{column: :manufacturer} = assigns) do
    ~H"""
    <.table_default_cell class="text-sm text-base-content/60">
      {safe_assoc_field(@item, :manufacturer, :name)}
    </.table_default_cell>
    """
  end

  # Catch-all for unknown columns — log warning, render empty cell
  defp item_cell(assigns) do
    Logger.warning("item_table: unknown column #{inspect(assigns.column)}, skipping")

    ~H"""
    <.table_default_cell class="text-sm text-base-content/40">—</.table_default_cell>
    """
  end

  # ── Action cell ────────────────────────────────────────────────

  attr(:item, :any, required: true)
  attr(:edit_path, :any, default: nil)
  attr(:on_delete, :string, default: nil)
  attr(:on_restore, :string, default: nil)
  attr(:on_permanent_delete, :string, default: nil)
  attr(:permanent_delete_type, :string, default: "item")
  attr(:pdf_search_event, :string, default: nil)

  defp item_actions(%{item: %{uuid: nil}} = assigns) do
    ~H"""
    <.table_default_cell class="text-right whitespace-nowrap">—</.table_default_cell>
    """
  end

  defp item_actions(assigns) do
    ~H"""
    <.table_default_cell class="text-right whitespace-nowrap">
      <.table_row_menu mode="auto" id={"item-action-#{@item.uuid}"}>
        <.table_row_menu_link
          :if={@edit_path}
          navigate={safe_call(@edit_path, @item.uuid)}
          icon="hero-pencil"
          label={Gettext.gettext(PhoenixKitWeb.Gettext, "Edit")}
        />
        <.table_row_menu_button
          :if={@pdf_search_event}
          phx-click={@pdf_search_event}
          phx-value-uuid={@item.uuid}
          icon="hero-document-magnifying-glass"
          label={Gettext.gettext(PhoenixKitWeb.Gettext, "Search PDFs")}
        />
        <.table_row_menu_divider :if={
          (@edit_path || @pdf_search_event) && (@on_delete || @on_restore)
        } />
        <.table_row_menu_button
          :if={@on_delete}
          phx-click={@on_delete}
          phx-value-uuid={@item.uuid}
          phx-disable-with={Gettext.gettext(PhoenixKitWeb.Gettext, "Deleting...")}
          icon="hero-trash"
          label={Gettext.gettext(PhoenixKitWeb.Gettext, "Delete")}
          variant="error"
        />
        <.table_row_menu_button
          :if={@on_restore}
          phx-click={@on_restore}
          phx-value-uuid={@item.uuid}
          phx-disable-with={Gettext.gettext(PhoenixKitWeb.Gettext, "Restoring...")}
          icon="hero-arrow-path"
          label={Gettext.gettext(PhoenixKitWeb.Gettext, "Restore")}
          variant="success"
        />
        <.table_row_menu_divider :if={@on_restore && @on_permanent_delete} />
        <.table_row_menu_button
          :if={@on_permanent_delete}
          phx-click={@on_permanent_delete}
          phx-value-uuid={@item.uuid}
          phx-value-type={@permanent_delete_type}
          phx-disable-with={Gettext.gettext(PhoenixKitWeb.Gettext, "Deleting...")}
          icon="hero-trash"
          label={Gettext.gettext(PhoenixKitWeb.Gettext, "Delete Forever")}
          variant="error"
        />
      </.table_row_menu>
    </.table_default_cell>
    """
  end

  # ═══════════════════════════════════════════════════════════════════
  # Item Picker
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Combobox for picking a single catalogue item via server-side search.

  Thin wrapper around the `ItemPicker` LiveComponent — it's the
  LiveComponent that owns search state, events, and the colocated JS
  hook. This wrapper exists so consumers have an attr-declared call
  site and don't have to remember `<.live_component module={...}>`.

  The parent LiveView reacts to two messages in its `handle_info/2`:

      {:item_picker_select, id, %Item{}}   # user chose an item
      {:item_picker_clear,  id}            # user cleared the selection

  where `id` is the `:id` you passed in — handy for multiple pickers on
  one page.

  ## Examples

      <.item_picker
        id={"row-\#{@row.id}-picker"}
        category_uuids={[@category_uuid]}
        selected_item={@row.item}
        excluded_uuids={@used_uuids}
        locale="en"
      />

  See `PhoenixKitCatalogue.Web.Components.ItemPicker` for the full attr
  reference and the keyboard / a11y contract.
  """

  attr(:id, :string, required: true)
  attr(:category_uuids, :list, default: nil)
  attr(:catalogue_uuids, :list, default: nil)
  attr(:include_descendants, :boolean, default: true)

  attr(:only, :atom,
    default: nil,
    values: [nil, :uncategorized_only, :categorized_only],
    doc: "Restrict results to uncategorised or categorised items only."
  )

  attr(:selected_item, :any, default: nil)
  attr(:excluded_uuids, :list, default: [])
  attr(:locale, :string, required: true)
  attr(:placeholder, :string, default: nil)
  attr(:empty_query_limit, :integer, default: 10)
  attr(:page_size, :integer, default: 20)
  attr(:disabled, :boolean, default: false)
  attr(:format_price, :any, default: nil)

  def item_picker(assigns) do
    ~H"""
    <.live_component
      module={PhoenixKitCatalogue.Web.Components.ItemPicker}
      id={@id}
      category_uuids={@category_uuids}
      catalogue_uuids={@catalogue_uuids}
      include_descendants={@include_descendants}
      only={@only}
      selected_item={@selected_item}
      excluded_uuids={@excluded_uuids}
      locale={@locale}
      placeholder={@placeholder}
      empty_query_limit={@empty_query_limit}
      page_size={@page_size}
      disabled={@disabled}
      format_price={@format_price}
    />
    """
  end

  # ── Helpers ────────────────────────────────────────────────────

  defp has_actions?(assigns) do
    assigns[:edit_path] != nil or assigns[:on_delete] != nil or
      assigns[:on_restore] != nil or assigns[:on_permanent_delete] != nil or
      assigns[:pdf_search_event] != nil
  end

  defp column_label(:name), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Name")
  defp column_label(:sku), do: Gettext.gettext(PhoenixKitWeb.Gettext, "SKU")
  defp column_label(:base_price), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Base Price")
  defp column_label(:price), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Price")
  defp column_label(:discount), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Discount")
  defp column_label(:final_price), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Final Price")
  defp column_label(:unit), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Unit")
  defp column_label(:status), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Status")
  defp column_label(:category), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Category")
  defp column_label(:catalogue), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Catalogue")
  defp column_label(:manufacturer), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Manufacturer")
  # `column_label` is called with a programmatic atom; falling back to
  # the raw atom name avoids pinning English casing on a value the
  # gettext extractor can't see. Add a literal clause above this one
  # when a new opt-in column is introduced.
  defp column_label(col), do: to_string(col)

  defp format_price(nil), do: "—"

  defp format_price(price) do
    Decimal.to_string(price, :normal)
  rescue
    _ -> "—"
  end

  defp format_unit(nil), do: "—"
  defp format_unit("piece"), do: Gettext.gettext(PhoenixKitWeb.Gettext, "pc")
  defp format_unit("set"), do: Gettext.gettext(PhoenixKitWeb.Gettext, "set")
  defp format_unit("pair"), do: Gettext.gettext(PhoenixKitWeb.Gettext, "pair")
  defp format_unit("sheet"), do: Gettext.gettext(PhoenixKitWeb.Gettext, "sheet")
  defp format_unit("m2"), do: Gettext.gettext(PhoenixKitWeb.Gettext, "m²")
  defp format_unit("running_meter"), do: Gettext.gettext(PhoenixKitWeb.Gettext, "rm")
  defp format_unit(other), do: to_string(other)

  # Sale-price wrapper: coerces non-Decimal markup at the boundary so
  # callers can pass Decimal | number | string | nil without thinking.
  # `Item.sale_price/2` itself is total over `(item, Decimal | nil)`.
  defp safe_sale_price(item, markup) do
    Item.sale_price(item, ensure_decimal(markup))
  end

  defp safe_final_price(item, markup, discount) do
    Item.final_price(item, ensure_decimal(markup), ensure_decimal(discount))
  end

  defp safe_effective_discount(item, discount) do
    Item.effective_discount(item, ensure_decimal(discount))
  end

  defp ensure_decimal(nil), do: nil
  defp ensure_decimal(%Decimal{} = d), do: d
  defp ensure_decimal(n) when is_number(n), do: Decimal.new("#{n}")
  defp ensure_decimal(s) when is_binary(s), do: Decimal.new(s)
  defp ensure_decimal(_), do: nil

  defp format_percentage(nil), do: "—"

  defp format_percentage(%Decimal{} = pct) do
    case Decimal.compare(pct, Decimal.new("0")) do
      :eq -> "—"
      _ -> Decimal.to_string(pct, :normal) <> "%"
    end
  end

  # Returns "—" if the association is nil or not loaded; otherwise the
  # named field. Used at template render time, where a bare `nil` would
  # be ugly. This is presentation, not error handling.
  defp safe_assoc_field(record, assoc, field) do
    case Map.get(record, assoc) do
      %{__struct__: Ecto.Association.NotLoaded} -> "—"
      nil -> "—"
      assoc_record -> Map.get(assoc_record, field) || "—"
    end
  end

  # Calls a caller-supplied path function. Both `nil` paths and `nil`
  # UUIDs collapse to `"#"` so unguarded `navigate={...}` attrs always
  # produce a defined href. Path functions themselves are trusted to
  # be total over a binary UUID.
  defp safe_call(nil, _arg), do: "#"
  defp safe_call(_func, nil), do: "#"
  defp safe_call(func, arg) when is_function(func, 1), do: func.(arg)

  # Safe nested association access — follows a path of keys, returns nil on any miss
end
