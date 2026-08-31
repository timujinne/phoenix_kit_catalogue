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

  ## Embeddable browse surfaces (separate modules)

    * `Components.ItemSelectorModal` — LiveComponent: the client-facing
      "pick items + quantities from the catalogue" modal. Scoped via
      `search_items/2` opts, reports `{:items_selected, %{picks: …}}` /
      `{:item_selector_closed, _}` to the host LV.
    * `Components.CatalogueBrowse` — LiveComponent: the same browse
      surface (search + category chips + card grid or admin-look table,
      toggleable since 2026-08-30) without selection chrome, for
      embedding a catalogue view on any logged-in page.
      Reports `{:catalogue_browse, %{event: :item_clicked, …}}`.
    * `Components.Browse` — the pure function components both are built
      from (`item_card/1`, `item_grid/1`, `item_table/1`, `item_row/1`,
      `category_chips/1`, `qty_stepper/1`, `view_toggle/1`,
      `column_toggle/1`, `grid_skeleton/1`, `present_items/2`, plus the
      shared scope/column resolvers) for hosts that want to compose
      their own surface with `Catalogue.BrowseState`. ⚠️ `Browse` has
      its own `item_table/1` and `view_toggle/1`, colliding with THIS
      module's same-named admin components — don't import both wholesale;
      import Browse with `only:`/`except:` or call it qualified.

  Several of these (`search_input`, `search_results_summary`,
  `view_mode_toggle`) are deliberately generic — no
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
      <.search_input query={@search_query} placeholder={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search items...")} />
  """

  use Phoenix.Component

  # Macro form, so `mix gettext.extract` can see these. The runtime form
  # `Gettext.gettext(Backend, "…")` extracts fine in ordinary code, but NOT
  # inside a HEEx attribute interpolation — which is how "Comfortable view"
  # and "Compact view" came to be in the catalogues but absent from a
  # regenerated .pot.
  use Gettext, backend: PhoenixKitCatalogue.Gettext

  require Logger

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Input, only: [input: 1]
  import PhoenixKitWeb.Components.Core.Select, only: [select: 1]
  import PhoenixKitWeb.Components.Core.TableDefault
  import PhoenixKitWeb.Components.Core.TableRowMenu

  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKitCatalogue.Attachments
  alias PhoenixKitCatalogue.Catalogue
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
          Gettext.gettext(PhoenixKitCatalogue.Gettext, "Shown on listings and detail views.")
      end)

    ~H"""
    <div class={["card bg-base-100 shadow-lg", @class]}>
      <div class="card-body flex flex-col gap-3">
        <div class="flex items-center justify-between">
          <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
            <.icon name="hero-photo" class="w-4 h-4" />
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Featured Image")}
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
              title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Open original")}
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
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Change")}
              </button>
              <button
                type="button"
                phx-click="clear_featured_image"
                phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Removing...")}
                class="btn btn-sm btn-ghost"
              >
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Remove")}
              </button>
            </div>
          </div>
        <% else %>
          <div class="flex items-center justify-between py-4 border border-dashed border-base-300 rounded-md px-4">
            <div class="flex items-center gap-3 text-base-content/60">
              <.icon name="hero-photo" class="w-6 h-6" />
              <span class="text-sm">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No featured image set.")}
              </span>
            </div>
            <button
              type="button"
              phx-click="open_featured_image_picker"
              class="btn btn-sm btn-primary"
            >
              <.icon name="hero-plus" class="w-4 h-4 mr-1" />
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Set featured image")}
            </button>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  The shared "Photos and Files" tab panel: featured-image card plus the
  attached-files manager (dropzone, in-flight uploads, file grid with
  signed links and a confirm-guarded remove). One implementation for
  the catalogue / category / item forms so the three tabs cannot drift.

  Consumer contract: the LiveView uses `PhoenixKitCatalogue.Attachments`
  (mount_attachments + allow_attachment_upload) and delegates the
  `cancel_upload` and `remove_file` events; this component only renders.
  """
  attr(:uploads, :any, required: true)
  attr(:files_state, :map, required: true)
  attr(:featured_image_uuid, :any, default: nil)
  attr(:featured_image_file, :any, default: nil)
  attr(:featured_subtitle, :string, required: true)
  attr(:files_hint, :string, required: true)
  attr(:remove_confirm, :string, required: true)
  attr(:remove_title, :string, required: true)

  def attachments_files_panel(assigns) do
    ~H"""
    <.featured_image_card
      featured_image_uuid={@featured_image_uuid}
      featured_image_file={@featured_image_file}
      subtitle={@featured_subtitle}
    />

    <div class="card bg-base-100 shadow-lg">
      <div class="card-body flex flex-col gap-4">
        <div class="flex flex-col gap-0.5">
          <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
            <.icon name="hero-paper-clip" class="w-4 h-4" />
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Attached Files")}
            <span :if={@files_state.files != []} class="badge badge-sm badge-ghost ml-1">
              {length(@files_state.files)}
            </span>
          </h2>
          <p class="text-xs text-base-content/50">{@files_hint}</p>
        </div>

        <label
          for={@uploads.attachment_files.ref}
          class="flex flex-col items-center justify-center gap-2 py-6 border-2 border-dashed border-base-300 rounded-md bg-base-200/20 hover:bg-base-200/40 transition-colors cursor-pointer"
          phx-drop-target={@uploads.attachment_files.ref}
        >
          <.icon name="hero-cloud-arrow-up" class="w-8 h-8 text-base-content/40" />
          <div class="text-sm text-base-content/60">
            <span class="font-medium text-primary">
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Click to upload")}
            </span>
            <span>{Gettext.gettext(PhoenixKitCatalogue.Gettext, " or drag & drop")}</span>
          </div>
          <.live_file_input upload={@uploads.attachment_files} class="hidden" />
        </label>

        <div :if={@uploads.attachment_files.entries != []} class="flex flex-col gap-2">
          <div
            :for={entry <- @uploads.attachment_files.entries}
            class="flex items-center gap-3 rounded-md border border-base-300 bg-base-100 p-2"
          >
            <.icon name="hero-cloud-arrow-up" class="w-4 h-4 text-base-content/60 shrink-0" />
            <div class="flex-1 min-w-0">
              <p class="text-sm truncate">{entry.client_name}</p>
              <progress
                class="progress progress-primary w-full h-1 mt-1"
                value={entry.progress}
                max="100"
              >
              </progress>
            </div>
            <span class="text-xs text-base-content/50 tabular-nums">{entry.progress}%</span>
            <button
              type="button"
              phx-click="cancel_upload"
              phx-value-ref={entry.ref}
              class="btn btn-ghost btn-xs btn-square"
              title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Cancel")}
            >
              <.icon name="hero-x-mark" class="w-4 h-4" />
            </button>
          </div>
        </div>

        <p :for={err <- upload_errors(@uploads.attachment_files)} class="text-xs text-error">
          {Attachments.upload_error_message(err)}
        </p>

        <%= if @files_state.files == [] do %>
          <div class="flex flex-col items-center gap-2 py-10 text-center border border-dashed border-base-300 rounded-md">
            <.icon name="hero-paper-clip" class="w-8 h-8 text-base-content/30" />
            <p class="text-sm text-base-content/50">
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No files attached yet.")}
            </p>
          </div>
        <% else %>
          <ul class="grid grid-cols-1 md:grid-cols-2 gap-3">
            <li
              :for={file <- @files_state.files}
              class="flex items-center gap-3 rounded-md border border-base-300 bg-base-200/30 p-3"
            >
              <%= if file.file_type == "image" do %>
                <a
                  href={URLSigner.signed_url(file.uuid, "original")}
                  target="_blank"
                  rel="noopener"
                  class="shrink-0"
                >
                  <img
                    src={URLSigner.signed_url(file.uuid, "thumbnail")}
                    alt={file.original_file_name}
                    class="w-14 h-14 rounded object-cover bg-base-200 border border-base-300"
                  />
                </a>
              <% else %>
                <a
                  href={URLSigner.signed_url(file.uuid, "original")}
                  target="_blank"
                  rel="noopener"
                  class="shrink-0 flex items-center justify-center w-14 h-14 rounded bg-base-200 border border-base-300 text-base-content/60"
                  title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Download")}
                >
                  <.icon name={Attachments.file_icon(file)} class="w-6 h-6" />
                </a>
              <% end %>
              <div class="flex-1 min-w-0">
                <p class="text-sm font-medium truncate" title={file.original_file_name}>
                  {file.original_file_name}
                </p>
                <p class="text-xs text-base-content/50">
                  {Attachments.format_file_size(file.size)} · {file.file_type}
                </p>
              </div>
              <button
                type="button"
                phx-click="remove_file"
                phx-value-uuid={file.uuid}
                phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Removing...")}
                data-confirm={@remove_confirm}
                class="btn btn-ghost btn-xs btn-square"
                title={@remove_title}
              >
                <.icon name="hero-x-mark" class="w-4 h-4" />
              </button>
            </li>
          </ul>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  Featured-image thumbnail for list rows, rendered to the left of the name.
  Renders nothing when the resource carries no attached image. Works on
  anything with a `data` map holding `"featured_image_uuid"` — catalogue /
  category / item structs and the index's `Map.from_struct/1` row maps alike.

  The URL is signed straight off the stored uuid (no per-row file lookup, so
  lists stay query-free); a dangling pointer — the file was deleted after
  being attached — 404s and removes itself via `onerror` instead of showing
  the browser's broken-image glyph.
  """
  attr(:resource, :any, required: true)
  attr(:class, :any, default: "w-10 h-10")

  attr(:variant, :string,
    default: "thumbnail",
    doc:
      "Storage variant to load. \"thumbnail\" (150px) fits the 40px list " <>
        "cells this was built for; pass \"medium\" (800px) for card-width " <>
        "slots — a 150px asset stretched across a card is the blur the boss " <>
        "reported (2026-08-29). Never \"original\" in lists."
  )

  attr(:comfy_scale, :boolean,
    default: true,
    doc:
      "Whether the comfy-density row override ([.pk-comfy_&]:w-18) applies. " <>
        "True for table cells; FALSE for fill slots — inside a comfy card " <>
        "the override beat w-full and shrank the band image to a 72px " <>
        "square (the not-full-width report, 2026-08-29)."
  )

  attr(:has_files, :boolean,
    default: false,
    doc:
      "The file-attached indicator: with an image, a small paperclip emblem in " <>
        "the thumb's top-right corner; with no image, a muted paperclip tile in " <>
        "the same slot. Feed it from `Catalogue.attached_file_counts/1` — it " <>
        "means \"has attached documents\" (the non-image files the product " <>
        "card's Files section lists)."
  )

  attr(:on_click, :string,
    default: nil,
    doc:
      "When set, the thumb becomes a button pushing this event with the resource's " <>
        "uuid — the product-view hook (\"pressing on the featured image\"). nil keeps " <>
        "the thumb inert."
  )

  def featured_thumb(assigns) do
    assigns = assign(assigns, :uuid, featured_image_uuid(assigns.resource))

    ~H"""
    <button
      :if={(@uuid || @has_files) && @on_click}
      type="button"
      phx-click={@on_click}
      phx-value-uuid={@resource.uuid}
      class={["shrink-0 cursor-pointer", !@comfy_scale && "block w-full h-full"]}
      title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "View item details")}
    >
      <.thumb_visual
        uuid={@uuid}
        has_files={@has_files}
        class={@class}
        variant={@variant}
        comfy_scale={@comfy_scale}
      />
    </button>
    <.thumb_visual
      :if={(@uuid || @has_files) && !@on_click}
      uuid={@uuid}
      has_files={@has_files}
      class={@class}
      variant={@variant}
      comfy_scale={@comfy_scale}
    />
    """
  end

  attr(:options, :list, required: true)
  attr(:selected, :list, required: true)
  attr(:class, :string, default: nil)
  attr(:id, :string, default: "attribute-filter")

  attr(:always_visible, :boolean,
    default: false,
    doc:
      "Skip the every-value-is-dead hiding. In items mode the filter is a " <>
        "primary control (Max, 2026-08-29): a search that currently kills " <>
        "every value should show them greyed out, not vanish the button."
  )

  attr(:counts, :map,
    default: %{},
    doc:
      "`%{slug => count}` of what each value would still match given the current " <>
        "selection (`Catalogue.attribute_value_match_counts/1`). A value missing " <>
        "from the map matches nothing and is offered disabled."
  )

  @doc """
  The attribute filter: ONE button opening every set and its values.

  A set per button put six dropdowns in the catalogues index toolbar and
  wrapped it onto a second row; one button keeps the toolbar the shape it
  was whatever a catalogue's attributes grow into (Max, 2026-08-28).

  Values are toggles, and picking Blue and Oak narrows to the items
  carrying BOTH — which is what "blue oak doors" means. Shared by the
  detail page and the index's items search mode, both narrowing items
  directly, so it means the same thing wherever it appears (the index's
  old "catalogues CONTAINING such items" reading left with the folder-
  level filter, 2026-08-29).

  Each value carries what it would still match and is DISABLED at zero,
  so the filter cannot be walked into an empty list (Max, 2026-08-28).
  Because the counts are conditioned on the current selection, a dead
  combination greys out the moment its first half is picked.
  """
  def attribute_filter(assigns) do
    assigns =
      assigns
      |> assign(:active_count, length(assigns.selected))
      # A filter whose every value is dead is not a filter — it is a
      # button that can only disappoint. It comes back the moment
      # something here carries a value.
      |> assign(:usable?, usable_filter?(assigns))

    ~H"""
    <div :if={@usable?} id={@id} class={["dropdown", @class]}>
      <%!-- `role="button"`, not a bare label: without it a screen reader
           reads the trigger as plain text and Enter does nothing — the
           dropdown only opened because Tab-focus happens to trip
           daisyUI's :focus-within. --%>
      <label
        tabindex="0"
        role="button"
        aria-haspopup="true"
        class={["btn btn-sm gap-1", if(@active_count > 0, do: "btn-primary", else: "btn-outline")]}
      >
        <.icon name="hero-swatch" class="w-4 h-4" />
        {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Attributes")}
        <span :if={@active_count > 0} class="badge badge-xs">{@active_count}</span>
        <.icon name="hero-chevron-down" class="w-3 h-3" />
      </label>
      <div
        tabindex="0"
        class="dropdown-content z-[1] p-2 shadow-lg bg-base-100 rounded-box w-64 mt-1 max-h-96 overflow-y-auto"
      >
        <div :for={set <- @options} class="mb-1 last:mb-0">
          <div class="px-2 py-1 text-xs font-semibold uppercase tracking-wide text-base-content/50">
            {set.name}
            <span :if={selected_count(set, @selected) > 0} class="badge badge-xs badge-primary ml-1">
              {selected_count(set, @selected)}
            </span>
          </div>
          <ul class="menu menu-sm p-0">
            <li :for={value <- set.values} class={value_dead?(value, @counts, @selected) && "disabled"}>
              <button
                type="button"
                phx-click={!value_dead?(value, @counts, @selected) && "toggle_attribute_filter"}
                phx-value-slug={value.slug}
                disabled={value_dead?(value, @counts, @selected)}
                aria-pressed={to_string(value.slug in @selected)}
                title={
                  value_dead?(value, @counts, @selected) &&
                    Gettext.gettext(
                      PhoenixKitCatalogue.Gettext,
                      "Nothing matches this together with the filters already on"
                    )
                }
              >
                <%!-- A tick that LOOKS like a checkbox rather than one.
                     A real <input> inside a <button> is invalid HTML: it
                     may take focus of its own, and there it has no name
                     to announce — the row's name belongs to the button.
                     The button carries the state as aria-pressed. --%>
                <span
                  aria-hidden="true"
                  class={[
                    "w-4 h-4 shrink-0 rounded border flex items-center justify-center",
                    if(value.slug in @selected,
                      do: "bg-primary border-primary text-primary-content",
                      else: "border-base-content/30"
                    )
                  ]}
                >
                  <.icon :if={value.slug in @selected} name="hero-check" class="w-3 h-3" />
                </span>
                <span class="truncate">{value.title}</span>
                <span class="ml-auto text-xs opacity-50">{Map.get(@counts, value.slug, 0)}</span>
              </button>
            </li>
          </ul>
        </div>

        <button
          :if={@selected != []}
          type="button"
          phx-click="clear_attribute_filter"
          class="btn btn-ghost btn-xs w-full mt-2"
        >
          <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Clear filters")}
        </button>
      </div>
    </div>
    """
  end

  defp selected_count(set, selected), do: Enum.count(set.values, &(&1.slug in selected))

  defp usable_filter?(%{always_visible: true}), do: true
  defp usable_filter?(%{selected: selected}) when selected != [], do: true

  defp usable_filter?(%{options: options, counts: counts, selected: selected}) do
    Enum.any?(options, fn set ->
      Enum.any?(set.values, &(not value_dead?(&1, counts, selected)))
    end)
  end

  # A value leads nowhere when nothing matches it alongside the filters
  # already on. An ACTIVE value is never dead — it has to stay clickable
  # to be switched back off.
  defp value_dead?(value, counts, selected),
    do: value.slug not in selected and Map.get(counts, value.slug, 0) == 0

  @doc """
  The attribute filter as a slug list.

  Stored in the URL as one comma-joined string, so a filtered view is a
  link you can send someone.
  """
  # The attribute filter as a slug list. Stored in the URL as one
  # comma-joined string so a filtered view is a shareable link.
  def attribute_filter_slugs(%{assigns: assigns}), do: attribute_filter_slugs(assigns)

  def attribute_filter_slugs(assigns) when is_map(assigns) do
    assigns
    |> Map.get(:attribute_filter, "")
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    # `?attr=oak,oak` would otherwise take two clicks to switch off:
    # toggling removes one copy and the box stays checked, which reads
    # as a dead control.
    |> Enum.uniq()
  end

  @doc """
  The module's card media band: the picture a card leads with.

  One definition for every card in the module. The categories grid had a
  band like this from the start and the boss likes it (via Max,
  2026-08-28) — item and catalogue cards showed a small inline thumbnail
  beside the title instead, or nothing at all, so the same data looked
  like two different products depending on the page.

  Pass it to `table_default`'s `:card_media` slot together with
  `card_media_class={card_media_band()}`. Renders the resource's featured
  photo, or a muted icon when there is none, so a card without a picture
  is the same shape as one with.
  """
  attr(:resource, :map, required: true)
  attr(:has_files, :boolean, default: false)
  attr(:on_click, :string, default: nil)

  attr(:variant, :string,
    default: "medium",
    doc:
      "Storage variant — cards are card-width, so the 800px \"medium\" by " <>
        "default (the 150px thumbnail stretched here was the blur the boss " <>
        "reported, 2026-08-29)."
  )

  attr(:navigate, :any,
    default: nil,
    doc: "When set, the picture links here — the same place the card's title goes."
  )

  attr(:patch, :any, default: nil, doc: "patch variant of `navigate`.")

  attr(:placeholder_icon, :string,
    default: "hero-photo",
    doc: ~s(Shown when the resource has no picture — "hero-folder" for containers.)
  )

  slot(:overlay, doc: "Corner controls (a checkbox, a drag handle) — absolutely positioned.")

  def card_media(assigns) do
    ~H"""
    <%!-- The picture is clickable like the title (boss, 2026-08-29):
         a navigate/patch wraps the visual in the same link the name
         carries. Overlay controls render after it, so they stay on top
         and keep their own clicks. --%>
    <.link
      :if={@navigate || @patch}
      navigate={@navigate}
      patch={@patch}
      class="block w-full h-full"
    >
      <.card_media_visual
        resource={@resource}
        has_files={@has_files}
        variant={@variant}
        placeholder_icon={@placeholder_icon}
      />
    </.link>
    <.card_media_visual
      :if={!(@navigate || @patch)}
      resource={@resource}
      has_files={@has_files}
      on_click={@on_click}
      variant={@variant}
      placeholder_icon={@placeholder_icon}
    />
    {render_slot(@overlay)}
    """
  end

  attr(:resource, :map, required: true)
  attr(:has_files, :boolean, required: true)
  attr(:on_click, :string, default: nil)
  attr(:variant, :string, required: true)
  attr(:placeholder_icon, :string, required: true)

  defp card_media_visual(assigns) do
    ~H"""
    <.featured_thumb
      resource={@resource}
      has_files={@has_files}
      on_click={@on_click}
      variant={@variant}
      comfy_scale={false}
      class="w-full h-full"
    />
    <%!-- Centred by its OWN full-size flex box, not by absolute
         positioning against the frame: the frame's `relative` reaches it
         through `card_media_class`, which a core older than this module's
         pin ignores. Anchored to the card instead, the icon floated over
         the title. --%>
    <div
      :if={!featured_image_uuid(@resource) && !@has_files}
      class="w-full h-full flex items-center justify-center"
    >
      <.icon name={@placeholder_icon} class="w-10 h-10 text-base-content/20" />
    </div>
    """
  end

  @doc """
  Classes for the `:card_media` frame every catalogue card uses. Kept in
  one place so the bands cannot drift apart page by page.
  """
  def card_media_band, do: "relative h-40 bg-base-200 overflow-hidden"

  @doc """
  The band as a DYNAMIC attribute for `table_default`.

  `card_media_class` only exists in core after this module's released pin,
  and a literal attribute would fail the compile gate until that lands. An
  older core ignores the extra assign and renders the media unframed —
  the picture is still there, it just isn't held to a fixed height yet.
  """
  def card_media_frame, do: %{card_media_class: card_media_band()}

  @doc """
  One category as the admin-look tile: the shared media band (featured
  image or folder glyph), the linked name, a columns-driven facts grid
  and the badge row — extracted from the catalogue detail page
  (2026-08-31) so the item-selector popup presents subcategories exactly
  the way the admin pages do, from ONE definition.

  The tile is presentation only. Navigation comes in from the caller:
  `patch` (the admin pages) or `phx_click`/`phx_target` (the popup's
  drill event — the trigger then carries `phx-value-uuid`). Admin-only
  chrome stays with the admin: the bulk checkbox and drag handle render
  through the `:overlay` slot (inside the figure), the row menu through
  `:menu` (end of the badge row), and the tree-DnD data attributes ride
  `:rest` on the root.
  """
  attr(:category, :map, required: true)

  attr(:name, :string,
    default: nil,
    doc: "Display name override (viewer-locale translation); falls back to category.name."
  )

  attr(:columns, :list,
    default: ["items"],
    doc: "Which facts the grid shows, in order — the admin Columns modal's vocabulary."
  )

  attr(:count, :integer, default: 0)
  attr(:subcat_count, :integer, default: 0)
  attr(:file_count, :integer, default: 0)
  attr(:has_subs, :boolean, default: false)
  attr(:has_files, :boolean, default: false)
  attr(:patch, :string, default: nil)
  attr(:phx_click, :string, default: nil)
  attr(:phx_target, :any, default: nil)
  attr(:rest, :global)
  slot(:overlay)
  slot(:menu)

  def category_card(assigns) do
    ~H"""
    <div
      class="group card card-sm bg-base-100 shadow hover:shadow-md transition-shadow overflow-hidden"
      {@rest}
    >
      <%!-- The shared band (taller since 2026-08-29 — the h-24 sliver
           cropped hard) with the card-grade variant: the tile was
           stretching the 150px list thumbnail across the full card,
           which is the blur the boss reported. The picture triggers
           where the title does. --%>
      <figure class={card_media_band()}>
        <.category_card_trigger
          patch={@patch}
          phx_click={@phx_click}
          phx_target={@phx_target}
          uuid={@category.uuid}
          class="block w-full h-full"
        >
          <.featured_thumb resource={@category} class="w-full h-full" variant="medium" comfy_scale={false} />
          <.icon
            :if={!featured_image_uuid(@category)}
            name="hero-folder"
            class="w-10 h-10 text-base-content/20 absolute inset-0 m-auto"
          />
        </.category_card_trigger>
        {render_slot(@overlay)}
      </figure>
      <div class="card-body p-3 gap-1.5">
        <.category_card_trigger
          patch={@patch}
          phx_click={@phx_click}
          phx_target={@phx_target}
          uuid={@category.uuid}
          class="font-medium truncate text-left hover:text-primary"
        >
          {@name || @category.name}
        </.category_card_trigger>
        <%!-- Configured columns add their data to the card, mirroring the
             table (the admin Columns modal drives both). --%>
        <div :if={@columns != []} class="grid grid-cols-2 gap-x-3 gap-y-0.5 text-xs mt-1">
          <%= for col <- @columns do %>
            <%= case col do %>
              <% "items" -> %>
                <div class="text-base-content/50">{gettext("Items")}</div>
                <div class="tabular-nums">{@count}</div>
              <% "subcategories" -> %>
                <div class="text-base-content/50">{gettext("Subcategories")}</div>
                <div class="tabular-nums">{@subcat_count}</div>
              <% "description" -> %>
                <div class="text-base-content/50">{gettext("Description")}</div>
                <div class="line-clamp-2">{@category.description || "—"}</div>
              <% "files" -> %>
                <div class="text-base-content/50">{gettext("Files")}</div>
                <div class="tabular-nums">{@file_count}</div>
              <% "status" -> %>
                <div class="text-base-content/50">{gettext("Status")}</div>
                <div><.status_badge status={@category.status} size={:xs} /></div>
              <% "updated" -> %>
                <div class="text-base-content/50">{gettext("Updated")}</div>
                <div>{Calendar.strftime(@category.updated_at, "%Y-%m-%d %H:%M")}</div>
              <% "created" -> %>
                <div class="text-base-content/50">{gettext("Created")}</div>
                <div>{Calendar.strftime(@category.inserted_at, "%Y-%m-%d %H:%M")}</div>
              <% _ -> %>
            <% end %>
          <% end %>
        </div>
        <div class="flex items-center gap-1.5">
          <span :if={@has_subs} class="badge badge-ghost badge-xs" title={gettext("Has subcategories")}>
            <.icon name="hero-rectangle-stack" class="w-3 h-3" />
          </span>
          <span :if={@has_files} class="badge badge-ghost badge-xs" title={gettext("Files")}>
            <.icon name="hero-paper-clip" class="w-3 h-3 rotate-45" />
          </span>
          <div class="flex-1"></div>
          {render_slot(@menu)}
        </div>
      </div>
    </div>
    """
  end

  # The tile's navigation surface: a patch link for the admin pages, a
  # phx-click button for the popup (LiveComponent target + the uuid the
  # drill event reads). Neither given renders inert text — a tile is
  # never the only way to a category, so a caller without navigation
  # still gets the full look.
  attr(:patch, :string, default: nil)
  attr(:phx_click, :string, default: nil)
  attr(:phx_target, :any, default: nil)
  attr(:uuid, :any, default: nil)
  attr(:class, :string, default: nil)
  slot(:inner_block, required: true)

  defp category_card_trigger(%{patch: patch} = assigns) when is_binary(patch) do
    ~H"""
    <.link patch={@patch} class={@class}>{render_slot(@inner_block)}</.link>
    """
  end

  defp category_card_trigger(%{phx_click: click} = assigns) when is_binary(click) do
    ~H"""
    <button
      type="button"
      phx-click={@phx_click}
      phx-value-uuid={@uuid}
      phx-target={@phx_target}
      class={@class}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp category_card_trigger(assigns) do
    ~H"""
    <span class={@class}>{render_slot(@inner_block)}</span>
    """
  end

  @doc """
  The Uncategorized bucket in the shared category card's clothes — the
  catalogue's loose items presented like any subcategory (Max,
  2026-08-31: "show them, just like if we were inside a category and
  there were sub categories"). No Category record backs it, so it takes
  the items count directly; navigation comes in like `category_card/1`'s
  (`patch` for the admin pages, `phx_click`/`phx_target` for the popup —
  the trigger then carries `phx-value-uuid="__uncategorized__"`).
  """
  attr(:count, :integer, default: nil, doc: "Items count; nil hides the facts grid.")
  attr(:patch, :string, default: nil)
  attr(:phx_click, :string, default: nil)
  attr(:phx_target, :any, default: nil)

  def uncategorized_card(assigns) do
    ~H"""
    <div class="group card card-sm bg-base-100 shadow hover:shadow-md transition-shadow overflow-hidden">
      <figure class={card_media_band()}>
        <.category_card_trigger
          patch={@patch}
          phx_click={@phx_click}
          phx_target={@phx_target}
          uuid="__uncategorized__"
          class="block w-full h-full"
        >
          <.icon
            name="hero-folder-open"
            class="w-10 h-10 text-base-content/20 absolute inset-0 m-auto"
          />
        </.category_card_trigger>
      </figure>
      <div class="card-body p-3 gap-1.5">
        <.category_card_trigger
          patch={@patch}
          phx_click={@phx_click}
          phx_target={@phx_target}
          uuid="__uncategorized__"
          class="font-medium truncate text-left hover:text-primary"
        >
          {gettext("Uncategorized")}
        </.category_card_trigger>
        <div :if={@count} class="grid grid-cols-2 gap-x-3 gap-y-0.5 text-xs mt-1">
          <div class="text-base-content/50">{gettext("Items")}</div>
          <div class="tabular-nums">{@count}</div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  The category tables' configurable header cells — one per entry of the
  admin Columns modal's vocabulary, same order. Extracted with
  `category_body_cells/1` from the catalogue detail page (2026-08-31) so
  its flat table, its tree table and the item-selector popup's level
  table all draw the same columns from one definition.
  """
  attr(:columns, :list, required: true)

  def category_header_cells(assigns) do
    ~H"""
    <%= for col <- @columns do %>
      <%= case col do %>
        <% "items" -> %>
          <.table_default_header_cell class="text-right">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Items")}
          </.table_default_header_cell>
        <% "updated" -> %>
          <.table_default_header_cell>
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Updated")}
          </.table_default_header_cell>
        <% "subcategories" -> %>
          <.table_default_header_cell class="text-right">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Subcategories")}
          </.table_default_header_cell>
        <% "description" -> %>
          <.table_default_header_cell>
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Description")}
          </.table_default_header_cell>
        <% "files" -> %>
          <.table_default_header_cell>
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Files")}
          </.table_default_header_cell>
        <% "status" -> %>
          <.table_default_header_cell>
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Status")}
          </.table_default_header_cell>
        <% "created" -> %>
          <.table_default_header_cell>
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Created")}
          </.table_default_header_cell>
        <% _ -> %>
      <% end %>
    <% end %>
    """
  end

  @doc """
  One category row's configurable data cells — the body twin of
  `category_header_cells/1`, keyed off the same columns list.
  """
  attr(:columns, :list, required: true)
  attr(:cat, :map, required: true)
  attr(:child_counts, :map, required: true)
  attr(:child_subcat_counts, :map, default: %{})
  attr(:file_counts, :map, default: %{})

  def category_body_cells(assigns) do
    ~H"""
    <%= for col <- @columns do %>
      <%= case col do %>
        <% "items" -> %>
          <.table_default_cell class="text-right tabular-nums">
            {Map.get(@child_counts, @cat.uuid, 0)}
          </.table_default_cell>
        <% "updated" -> %>
          <.table_default_cell class="text-sm text-base-content/60">
            {Calendar.strftime(@cat.updated_at, "%Y-%m-%d %H:%M")}
          </.table_default_cell>
        <% "subcategories" -> %>
          <.table_default_cell class="text-right tabular-nums text-base-content/60">
            {Map.get(@child_subcat_counts, @cat.uuid, 0)}
          </.table_default_cell>
        <% "description" -> %>
          <.table_default_cell class="text-sm text-base-content/60 max-w-64">
            <span class="line-clamp-2">{@cat.description || "—"}</span>
          </.table_default_cell>
        <% "files" -> %>
          <.table_default_cell class="text-sm tabular-nums text-base-content/60">
            {Map.get(@file_counts, @cat.uuid, 0)}
          </.table_default_cell>
        <% "status" -> %>
          <.table_default_cell>
            <.status_badge status={@cat.status} size={:xs} />
          </.table_default_cell>
        <% "created" -> %>
          <.table_default_cell class="text-sm text-base-content/60">
            {Calendar.strftime(@cat.inserted_at, "%Y-%m-%d %H:%M")}
          </.table_default_cell>
        <% _ -> %>
      <% end %>
    <% end %>
    """
  end

  # The thumb slot's visual: image (with an optional corner paperclip emblem)
  # or, with no image, the paperclip tile filling the same footprint so names
  # stay aligned across rows either way.
  attr(:uuid, :string, default: nil)
  attr(:has_files, :boolean, required: true)
  attr(:class, :any, required: true)
  attr(:variant, :string, default: "thumbnail")
  attr(:comfy_scale, :boolean, default: true)

  defp thumb_visual(assigns) do
    ~H"""
    <span class={[
      "relative block shrink-0",
      @comfy_scale && "[.pk-comfy_&]:w-18 [.pk-comfy_&]:h-18",
      @class
    ]}>
      <img
        :if={@uuid}
        src={URLSigner.signed_url(@uuid, @variant)}
        alt=""
        loading="lazy"
        onerror="this.style.display='none'"
        class="w-full h-full rounded object-cover bg-base-200"
      />
      <span
        :if={!@uuid}
        class="w-full h-full rounded bg-base-200 flex items-center justify-center"
        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Files")}
      >
        <.icon name="hero-paper-clip" class="w-4 h-4 rotate-45 text-base-content/50" />
      </span>
      <span
        :if={@uuid && @has_files}
        class="absolute -top-1 -right-1 w-4 h-4 rounded-full bg-base-100 border border-base-300 shadow-sm flex items-center justify-center"
        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Files")}
      >
        <.icon name="hero-paper-clip" class="w-2.5 h-2.5 rotate-45 text-base-content/70" />
      </span>
    </span>
    """
  end

  @doc false
  def featured_image_uuid(%{data: %{"featured_image_uuid" => uuid}})
      when is_binary(uuid) and uuid != "",
      do: uuid

  def featured_image_uuid(_), do: nil

  @doc """
  Whether any row in a list carries a featured image — gates the photo
  column in table views, so a table with no images at all doesn't spend a
  permanently empty column on them.
  """
  def any_featured_thumb?(rows), do: Enum.any?(rows, &(featured_image_uuid(&1) != nil))

  @doc """
  Like `any_featured_thumb?/1`, but also counts the paperclip indicator:
  the media column earns its place when some row has an image OR attached
  documents (per the `counts` map from `Catalogue.attached_file_counts/1`).
  """
  def any_media_thumb?(rows, counts) do
    Enum.any?(rows, fn row ->
      featured_image_uuid(row) != nil or Map.get(counts, row.uuid, 0) > 0
    end)
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
        assigns[:title] || Gettext.gettext(PhoenixKitCatalogue.Gettext, "Metadata")
      end)
      |> assign_new(:description_text, fn ->
        assigns[:description] ||
          Gettext.gettext(
            PhoenixKitCatalogue.Gettext,
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
            PhoenixKitCatalogue.Gettext,
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
            label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Add metadata")}
            prompt={Gettext.gettext(PhoenixKitCatalogue.Gettext, "— Pick a field —")}
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
      phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Removing...")}
      class="btn btn-ghost btn-sm btn-square text-error"
      title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Remove")}
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
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Legacy")}
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
      phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Removing...")}
      class="btn btn-ghost btn-sm btn-square text-error"
      title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Remove")}
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
  defp status_label("active"), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Active")
  defp status_label("inactive"), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Inactive")
  defp status_label("archived"), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Archived")
  defp status_label("deleted"), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Deleted")

  defp status_label("discontinued"),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Discontinued")

  defp status_label(other) when is_binary(other), do: other
  defp status_label(_), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Unknown")

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

  attr(:id, :string,
    default: "catalogue-search-input",
    doc: "Form id — LiveView warns without one and cannot recover the form after a disconnect."
  )

  def search_input(assigns) do
    placeholder =
      assigns.placeholder ||
        Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search...")

    assigns = assign(assigns, :placeholder, placeholder)

    ~H"""
    <div class={["flex gap-2", @class]}>
      <form id={@id} phx-change={@on_search} phx-submit={@on_search} class="flex-1 relative">
        <input
          type="text"
          name="query"
          value={@query}
          placeholder={@placeholder}
          class="input input-sm w-full pr-8"
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
          PhoenixKitCatalogue.Gettext,
          "Showing %{loaded} of %{count} results for \"%{query}\"",
          loaded: @loaded,
          count: @count,
          query: @query
        )}
      <% else %>
        {Gettext.ngettext(
          PhoenixKitCatalogue.Gettext,
          "%{count} result for \"%{query}\"",
          "%{count} results for \"%{query}\"",
          @count, count: @count, query: @query)}
      <% end %>
    </span>
    """
  end

  # ═══════════════════════════════════════════════════════════════════
  # View mode toggle
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  The INSTANT view switcher, for surfaces that render both faces and let
  CSS choose between them.

  Core's `view_mode_toggle/1` does the switching (no server involved, so
  it is immediate) and this adds the remembering: the page's stored
  choice seeds the browser on mount, and a change is pushed to
  `set_view` afterwards, once the view has already moved.

  Use `view_toggle/1` instead where the server picks the layout — the
  catalogues index renders a folder tree or a card grid, which is not
  something CSS can swap.
  """
  attr(:view, :string, required: true)
  attr(:id, :string, default: "catalogue-view-pref")
  attr(:class, :any, default: nil)

  def view_toggle_instant(assigns) do
    ~H"""
    <div class={["flex items-center", @class]}>
      <div
        id={@id}
        phx-hook="ViewPref"
        data-storage-key={view_storage_key()}
        data-server-view={@view}
        class="hidden"
      >
      </div>
      <.view_mode_toggle storage_key={view_storage_key()} />
    </div>
    """
  end

  @doc """
  The one localStorage key every catalogue surface shares, so a view
  chosen on one page is the view the next page opens with.
  """
  def view_storage_key, do: "catalogue-view"

  @doc """
  The module's view switcher: card / comfortable / compact.

  Server-driven on purpose. The localStorage-backed `view_mode_toggle/1`
  remembers a mode per surface and per browser, which is why a choice made
  on one page never reached the next one; this posts `set_view` and the
  answer is stored per USER, module-wide (`ViewConfig.load_view/1`), so
  every catalogue page opens the way you left the last one.
  """
  attr(:view, :string, required: true)
  attr(:class, :any, default: nil)

  def view_toggle(assigns) do
    ~H"""
    <div class={["join inline-flex", @class]}>
      <button
        type="button"
        phx-click="set_view"
        phx-value-mode="card"
        class={["btn btn-sm join-item", @view == "card" && "btn-active"]}
        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Card view")}
      >
        <.icon name="hero-squares-2x2" class="w-4 h-4" />
      </button>
      <button
        type="button"
        phx-click="set_view"
        phx-value-mode="comfy"
        class={["btn btn-sm join-item", @view == "comfy" && "btn-active"]}
        title={gettext("Comfortable view")}
      >
        <.icon name="hero-bars-3" class="w-4 h-4" />
      </button>
      <button
        type="button"
        phx-click="set_view"
        phx-value-mode="table"
        class={["btn btn-sm join-item", @view == "table" && "btn-active"]}
        title={gettext("Compact view")}
      >
        <.icon name="hero-bars-4" class="w-4 h-4" />
      </button>
    </div>
    """
  end

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
          title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Card view")}
        >
          <.icon name="hero-squares-2x2" class="w-4 h-4" />
        </button>
        <button
          type="button"
          data-view-action="comfy"
          class="btn btn-sm join-item"
          title={gettext("Comfortable view")}
        >
          <.icon name="hero-bars-3" class="w-4 h-4" />
        </button>
        <button
          type="button"
          data-view-action="table"
          class="btn btn-sm join-item"
          title={gettext("Compact view")}
        >
          <.icon name="hero-bars-4" class="w-4 h-4" />
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
          <span>{Gettext.gettext(PhoenixKitCatalogue.Gettext, "Scope")}</span>
          <span class="text-base-content/60 font-normal">
            {scope_summary_text(@has_catalogues, @has_categories, @cat_count, @cat_categories_count)}
          </span>
        </span>
      </summary>
      <div class="collapse-content">
        <div class="grid gap-4 md:grid-cols-2">
          <section :if={@has_catalogues}>
            <div class="flex items-center justify-between mb-2">
              <span class="fieldset-legend font-medium">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogues")}
              </span>
              <button
                :if={@cat_count > 0}
                type="button"
                phx-click={@on_clear_catalogues}
                class="btn btn-ghost btn-xs"
              >
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Clear")}
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
                  <span class="fieldset-legend truncate" title={cat.name}>{cat.name}</span>
                </label>
              </li>
            </ul>
          </section>
          <section :if={@has_categories}>
            <div class="flex items-center justify-between mb-2">
              <span class="fieldset-legend font-medium">
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Categories")}
              </span>
              <button
                :if={@cat_categories_count > 0}
                type="button"
                phx-click={@on_clear_categories}
                class="btn btn-ghost btn-xs"
              >
                {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Clear")}
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
                  <span class="fieldset-legend truncate" title={cat.name}>{cat.name}</span>
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

  defp catalogue_summary(0), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "all catalogues")

  defp catalogue_summary(n) do
    Gettext.ngettext(
      PhoenixKitCatalogue.Gettext,
      "%{count} catalogue",
      "%{count} catalogues",
      n,
      count: n
    )
  end

  defp category_summary(0), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "all categories")

  defp category_summary(n) do
    Gettext.ngettext(
      PhoenixKitCatalogue.Gettext,
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
        {Gettext.gettext(PhoenixKitCatalogue.Gettext, "No other catalogues available to reference yet.")}
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
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Clear all")}
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
        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Drag to reorder")}
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
          class="input input-sm w-24"
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
        PhoenixKitCatalogue.Gettext,
        "%{total} catalogues available — none selected",
        total: total
      )

  defp rules_summary_text(active, total) do
    Gettext.ngettext(
      PhoenixKitCatalogue.Gettext,
      "%{active} of %{total} catalogue selected",
      "%{active} of %{total} catalogues selected",
      total,
      active: active,
      total: total
    )
  end

  defp default_placeholder(%{item_default_value: nil}), do: ""

  defp default_placeholder(%{item_default_value: value}) do
    Gettext.gettext(PhoenixKitCatalogue.Gettext, "Inherit: %{value}",
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
  defp unit_label("flat"), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Flat")
  defp unit_label(u), do: to_string(u)

  defp kind_label(%{kind: "smart"}), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Smart")
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
  # Card view on by default (deliberate product call, 2026-08-14) — a new
  # item table gets the card/table toggle without having to ask for it.
  attr(:cards, :boolean, default: true)

  attr(:photo_click, :string,
    default: nil,
    doc:
      "Event pushed (with the item's uuid) when a featured-image thumb is " <>
        "clicked — the host renders the ProductCard modal and handles its " <>
        "events. nil keeps thumbs inert."
  )

  attr(:file_counts, :map,
    default: %{},
    doc:
      "%{item_uuid => attached-document count} from " <>
        "Catalogue.attached_file_counts/1 — drives the paperclip indicator " <>
        "in the photo column. Computed by the caller (function components " <>
        "must not query)."
  )

  attr(:attribute_map, :map,
    default: %{},
    doc:
      "%{item_uuid => attribute_group_uuid} from " <>
        "Catalogue.item_attribute_group_map/1 — drives the swatch indicator " <>
        "beside the name. Computed by the caller."
  )

  attr(:show_toggle, :boolean, default: true)
  attr(:id, :string, default: nil)
  attr(:storage_key, :string, default: nil)

  attr(:view_mode, :string,
    default: nil,
    doc:
      "Controlled view (`card` / `comfy` / `table`). Set it to follow the user's " <>
        "module-wide preference (`ViewConfig.load_view/1`) instead of the " <>
        "per-browser localStorage key — see `view_toggle/1`. Setting it also " <>
        "hides the table's built-in toggle: in controlled mode that toggle posts " <>
        "to the server, and the module answers on `set_view` (see `view_event`)."
  )

  attr(:view_event, :string,
    default: "set_view",
    doc:
      "Event the CONTROLLED toggle posts. Core's default is `switch_view`, which " <>
        "no catalogue LiveView answers — and an unhandled event crashes the view."
  )

  attr(:markup_percentage, :any, default: nil)
  attr(:discount_percentage, :any, default: nil)
  attr(:edit_path, :any, default: nil)

  attr(:name_path, :any,
    default: nil,
    doc: """
    Where an item's NAME links, as a 1-arity function of the item. Defaults to
    `edit_path` (the catalogue's own convention). An embedded, read-only list
    can point it somewhere else — landing on an edit form from a list you are
    only reading is a surprise.
    """
  )

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
      # Featured images / file indicators get their own slim column
      # (inline-left of the name made rows jagged); it only exists when at
      # least one row would render a thumb or a paperclip.
      |> then(
        &assign(&1, :photo_col?, any_featured_thumb?(&1.items) or map_size(&1.file_counts) > 0)
      )

    ~H"""
    <.table_default
      variant={@variant}
      size={@size}
      toggleable={@cards}
      show_toggle={is_nil(@view_mode) and @show_toggle}
      id={@id}
      storage_key={@storage_key}
      view_mode={@view_mode}
      view_event={@view_event}
      {card_media_frame()}
      items={@items}
      on_reorder={@on_reorder}
      reorder_scope={@reorder_scope}
      reorder_group={@reorder_group}
      item_id={fn item -> item.uuid end}
      card_fields={
        &card_fields(&1, @card_columns, @markup_percentage, @discount_percentage, @catalogue_path)
      }
    >
      <%!-- The picture leads the card, the way the categories grid has
            always done it (boss via Max, 2026-08-28) — this used to be a
            48px thumb wedged beside the title, so the same product looked
            like a different kind of thing depending on which page you
            were on. --%>
      <:card_media :let={item}>
        <%!-- The band lives INSIDE the slot: the pinned core ignores
             card_media_class, so an outer frame never applied and the
             150px thumb stretched unbounded — half of the blur the boss
             reported (2026-08-29). --%>
        <figure class={card_media_band()}>
          <.card_media
            resource={item}
            has_files={Map.get(@file_counts, item.uuid, 0) > 0}
            on_click={@photo_click}
          />
        </figure>
      </:card_media>
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
            :if={item_name_link(assigns, item)}
            navigate={item_name_link(assigns, item)}
            class="font-medium text-sm link link-hover"
          >
            {item.name || "—"}
          </.link>
          <span :if={is_nil(item_name_link(assigns, item))} class="font-medium text-sm">
            {item.name || "—"}
          </span>
          <span
            :if={Map.has_key?(@attribute_map, item.uuid)}
            class="shrink-0"
            title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Has attribute group")}
          >
            <.icon name="hero-swatch" class="w-3.5 h-3.5 text-primary/60" />
          </span>
        </div>
      </:card_header>
      <.table_default_header>
        <.table_default_row>
          <.table_default_header_cell :if={!is_nil(@on_reorder) or @selectable} class="w-10"></.table_default_header_cell>
          <.table_default_header_cell :if={@photo_col?} class="w-12 !pr-0 !py-1 [.pk-comfy_&]:w-22 [.pk-comfy_&]:!py-1.5"></.table_default_header_cell>
          <.table_default_header_cell :for={col <- @columns}>
            {column_label(col)}
          </.table_default_header_cell>
          <.table_default_header_cell :if={@has_actions} class="text-right">
            {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Actions")}
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
          <%!-- Combined checkbox + drag handle column. Both always
               visible — the handle used to hover-reveal, but an
               affordance you cannot see is one nobody discovers
               (deliberate product call, 2026-08-14). --%>
          <.table_default_cell :if={!is_nil(@on_reorder) or @selectable} class="w-10">
            <div class="flex items-center gap-1.5">
              <span
                :if={@on_reorder}
                class="pk-drag-handle cursor-grab active:cursor-grabbing text-base-content/40 hover:text-base-content/70 transition-colors"
                title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Drag to reorder")}
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
          <.table_default_cell :if={@photo_col?} class="w-12 !pr-0 !py-1 [.pk-comfy_&]:w-22 [.pk-comfy_&]:!py-1.5">
            <.featured_thumb
              resource={item}
              on_click={@photo_click}
              has_files={Map.get(@file_counts, item.uuid, 0) > 0}
            />
          </.table_default_cell>
          <.item_cell
            :for={col <- @columns}
            column={col}
            item={item}
            markup_percentage={@markup_percentage}
            discount_percentage={@discount_percentage}
            catalogue_path={@catalogue_path}
            edit_path={@edit_path}
            name_path={@name_path}
            has_attributes={Map.has_key?(@attribute_map, item.uuid)}
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

  @doc """
  The "Supplier price" cell text for one item's cost ranges (see
  `Catalogue.supplier_cost_ranges/1`): one supplier → `5.69`, several →
  `5.69–9.99` (min–max of the current rows). Rows priced in different
  currencies are shown as separate ranges with their code — `5.69–9.99
  EUR, 4.00 USD` — so two currencies are never collapsed into one span.
  Nothing priced → `—`.
  """
  @spec format_supplier_costs(list() | nil) :: String.t()
  def format_supplier_costs(nil), do: "—"
  def format_supplier_costs([]), do: "—"

  def format_supplier_costs(ranges) when is_list(ranges) do
    show_currency? = length(ranges) > 1

    # `unit_cost` is stored at scale 4; the column shows money, 2 places.
    money = &Decimal.to_string(Decimal.round(&1, 2), :normal)

    Enum.map_join(ranges, ", ", fn %{min: min, max: max} = range ->
      span =
        if Decimal.equal?(min, max),
          do: money.(min),
          else: money.(min) <> "–" <> money.(max)

      case range[:currency] do
        code when show_currency? and is_binary(code) -> span <> " " <> code
        _ -> span
      end
    end)
  end

  # ── Shared item cells (reused by item_table AND the core-toolkit
  #    table in CatalogueDetailLive's active list, so the two surfaces
  #    don't drift on pricing / action markup) ───────────────────────

  @doc """
  The name + SKU + sale-price cells for an item, rendered as standalone
  `<td>`s for a core-toolkit `<.table_default>` row. Pricing uses
  `Catalogue.item_pricing/1` so the figures match the rest of the
  module. Pass `edit_path` (a 1-arity `uuid -> path` fn) to make the
  name a link.

  Renders the name cell (link), then one cell per entry in `columns` —
  `"sku"` / `"price"` / `"unit"` / `"status"` — in the given order, so
  a Columns configuration controls both visibility and sequence.
  """
  attr(:item, :any, required: true)
  attr(:edit_path, :any, default: nil)

  attr(:has_attributes, :boolean, default: false)
  attr(:file_count, :integer, default: 0)
  attr(:columns, :list, default: ["sku", "price", "unit", "status"])

  attr(:supplier_costs, :list,
    default: [],
    doc:
      "This item's entry from `Catalogue.supplier_cost_ranges/1` (drives `\"supplier_price\"`)."
  )

  def item_pricing_cell(assigns) do
    pricing = Catalogue.item_pricing(assigns.item)
    assigns = assign(assigns, :sale_price, pricing.sale_price)

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
      <span
        :if={assigns[:has_attributes]}
        class="inline-block ml-1.5 align-[-2px]"
        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Has attribute group")}
      >
        <.icon name="hero-swatch" class="w-3.5 h-3.5 text-primary/60" />
      </span>
    </.table_default_cell>
    <%= for col <- @columns do %>
      <%= case col do %>
        <% "sku" -> %>
          <.table_default_cell class="text-sm font-mono text-base-content/60">
            {@item.sku || "—"}
          </.table_default_cell>
        <% "price" -> %>
          <.table_default_cell class="text-sm font-semibold">
            {format_price(@sale_price)}
          </.table_default_cell>
        <% "supplier_price" -> %>
          <.table_default_cell class="text-sm text-base-content/80">
            {format_supplier_costs(@supplier_costs)}
          </.table_default_cell>
        <% "unit" -> %>
          <.table_default_cell class="text-sm">{format_unit(@item.unit)}</.table_default_cell>
        <% "status" -> %>
          <.table_default_cell>
            <.status_badge status={@item.status || "unknown"} size={:xs} />
          </.table_default_cell>
        <% "attributes" -> %>
          <.table_default_cell>
            <span
              :if={@has_attributes}
              title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Has attribute group")}
            >
              <.icon name="hero-swatch" class="w-4 h-4 text-primary/60" />
            </span>
            <span :if={!@has_attributes} class="text-base-content/30">—</span>
          </.table_default_cell>
        <% "files" -> %>
          <.table_default_cell class="text-sm tabular-nums text-base-content/60">
            <span :if={@file_count > 0} class="inline-flex items-center gap-1">
              <.icon name="hero-paper-clip" class="w-3.5 h-3.5 rotate-45 opacity-60" />
              {@file_count}
            </span>
            <span :if={@file_count == 0} class="text-base-content/30">—</span>
          </.table_default_cell>
        <% "description" -> %>
          <.table_default_cell class="text-sm text-base-content/60 max-w-64">
            <span class="line-clamp-2">{@item.description || "—"}</span>
          </.table_default_cell>
        <% "updated" -> %>
          <.table_default_cell class="text-sm text-base-content/60 whitespace-nowrap">
            {Calendar.strftime(@item.updated_at, "%Y-%m-%d %H:%M")}
          </.table_default_cell>
        <% "created" -> %>
          <.table_default_cell class="text-sm text-base-content/60 whitespace-nowrap">
            {Calendar.strftime(@item.inserted_at, "%Y-%m-%d %H:%M")}
          </.table_default_cell>
        <% _ -> %>
      <% end %>
    <% end %>
    """
  end

  @doc """
  The per-row action menu for an active item (Edit / Search PDFs /
  Delete), rendered as a standalone `<td>` for a core-toolkit row.
  Mirrors `item_table`'s `item_actions` action set for the active list.
  """
  attr(:item, :any, required: true)
  attr(:edit_path, :any, default: nil)

  attr(:on_delete, :string, default: nil)
  attr(:pdf_search_event, :string, default: nil)

  def item_row_menu(assigns) do
    ~H"""
    <.table_default_cell class="text-right whitespace-nowrap">
      <.item_card_menu
        item={@item}
        id_prefix="item-row-menu"
        edit_path={@edit_path}
        on_delete={@on_delete}
        pdf_search_event={@pdf_search_event}
      />
    </.table_default_cell>
    """
  end

  @doc """
  The same Edit / Search PDFs / Delete menu WITHOUT the table cell —
  for card footers, where the boss standard is the ⋮ menu, not a row of
  icon buttons.
  """
  attr(:item, :any, required: true)
  attr(:id_prefix, :string, default: "item-card-menu")
  attr(:edit_path, :any, default: nil)

  attr(:on_delete, :string, default: nil)
  attr(:pdf_search_event, :string, default: nil)

  def item_card_menu(assigns) do
    ~H"""
    <.table_row_menu mode="auto" id={"#{@id_prefix}-#{@item.uuid}"}>
      <.table_row_menu_link
        :if={@edit_path}
        navigate={safe_call(@edit_path, @item.uuid)}
        icon="hero-pencil"
        label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit")}
      />
      <.table_row_menu_button
        :if={@pdf_search_event}
        phx-click={@pdf_search_event}
        phx-value-uuid={@item.uuid}
        icon="hero-document-magnifying-glass"
        label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search PDFs")}
      />
      <.table_row_menu_divider :if={
        (@edit_path || @pdf_search_event) && @on_delete
      } />
      <.table_row_menu_button
        :if={@on_delete}
        phx-click={@on_delete}
        phx-value-uuid={@item.uuid}
        phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Deleting...")}
        icon="hero-trash"
        label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")}
        variant="error"
      />
    </.table_row_menu>
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
    do: manufacturer_display(item)

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
    <%!-- Card footers use the same ⋮ menu as table rows (boss standard) —
         one compact trigger instead of a row of icon buttons. --%>
    <.table_row_menu mode="auto" id={"item-table-card-menu-#{@item.uuid}"}>
      <.table_row_menu_link
        :if={@edit_path && @item.uuid}
        navigate={safe_call(@edit_path, @item.uuid)}
        icon="hero-pencil"
        label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit")}
      />
      <.table_row_menu_button
        :if={@pdf_search_event && @item.uuid}
        phx-click={@pdf_search_event}
        phx-value-uuid={@item.uuid}
        icon="hero-document-magnifying-glass"
        label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search PDFs")}
      />
      <.table_row_menu_button
        :if={@on_restore}
        phx-click={@on_restore}
        phx-value-uuid={@item.uuid}
        phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restoring...")}
        icon="hero-arrow-path"
        label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restore")}
        variant="success"
      />
      <.table_row_menu_divider :if={@on_delete || @on_permanent_delete} />
      <.table_row_menu_button
        :if={@on_delete}
        phx-click={@on_delete}
        phx-value-uuid={@item.uuid}
        phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Deleting...")}
        icon="hero-trash"
        label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")}
        variant="error"
      />
      <.table_row_menu_button
        :if={@on_permanent_delete}
        phx-click={@on_permanent_delete}
        phx-value-uuid={@item.uuid}
        phx-value-type={@permanent_delete_type}
        phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Deleting...")}
        icon="hero-trash"
        label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete Forever")}
        variant="error"
      />
    </.table_row_menu>
    """
  end

  # ── Column cells ───────────────────────────────────────────────

  attr(:column, :atom, required: true)
  attr(:item, :any, required: true)
  attr(:markup_percentage, :any, default: nil)
  attr(:discount_percentage, :any, default: nil)
  attr(:catalogue_path, :any, default: nil)
  attr(:edit_path, :any, default: nil)

  attr(:name_path, :any,
    default: nil,
    doc: """
    Where an item's NAME links, as a 1-arity function of the item. Defaults to
    `edit_path` (the catalogue's own convention). An embedded, read-only list
    can point it somewhere else — landing on an edit form from a list you are
    only reading is a surprise.
    """
  )

  attr(:has_attributes, :boolean, default: false)

  defp item_cell(%{column: :name} = assigns) do
    assigns = assign(assigns, :name_link, item_name_link(assigns, assigns.item))

    ~H"""
    <.table_default_cell class="font-medium">
      <.link :if={@name_link} navigate={@name_link} class="link link-hover">
        {@item.name || "—"}
      </.link>
      <span :if={is_nil(@name_link)}>{@item.name || "—"}</span>
      <span
        :if={assigns[:has_attributes]}
        class="inline-block ml-1.5 align-[-2px]"
        title={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Has attribute group")}
      >
        <.icon name="hero-swatch" class="w-3.5 h-3.5 text-primary/60" />
      </span>
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
      {manufacturer_display(@item)}
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
          label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Edit")}
        />
        <.table_row_menu_button
          :if={@pdf_search_event}
          phx-click={@pdf_search_event}
          phx-value-uuid={@item.uuid}
          icon="hero-document-magnifying-glass"
          label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Search PDFs")}
        />
        <.table_row_menu_divider :if={
          (@edit_path || @pdf_search_event) && (@on_delete || @on_restore)
        } />
        <.table_row_menu_button
          :if={@on_delete}
          phx-click={@on_delete}
          phx-value-uuid={@item.uuid}
          phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Deleting...")}
          icon="hero-trash"
          label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete")}
          variant="error"
        />
        <.table_row_menu_button
          :if={@on_restore}
          phx-click={@on_restore}
          phx-value-uuid={@item.uuid}
          phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restoring...")}
          icon="hero-arrow-path"
          label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Restore")}
          variant="success"
        />
        <.table_row_menu_divider :if={@on_restore && @on_permanent_delete} />
        <.table_row_menu_button
          :if={@on_permanent_delete}
          phx-click={@on_permanent_delete}
          phx-value-uuid={@item.uuid}
          phx-value-type={@permanent_delete_type}
          phx-disable-with={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Deleting...")}
          icon="hero-trash"
          label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Delete Forever")}
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
  # `:any` (not `:list`) so callers can pass an explicit `nil` for the
  # documented "all categories + uncategorized" scope without tripping
  # Phoenix's attr type check — `default: nil` only covers omission, not
  # an explicit `nil`. The LiveComponent + `search_items/2` both treat
  # `nil`/`[]` identically.
  attr(:category_uuids, :any, default: nil)
  attr(:catalogue_uuids, :any, default: nil)
  attr(:include_descendants, :boolean, default: true)

  attr(:only, :atom,
    default: nil,
    values: [nil, :uncategorized_only, :categorized_only],
    doc: "Restrict results to uncategorised or categorised items only."
  )

  # `:any` for the same explicit-nil reason as the uuid scopes above.
  attr(:statuses, :any,
    default: nil,
    doc: "Item statuses to include (`nil`/`[]` = all non-deleted) — search_items/2's :statuses."
  )

  attr(:selected_item, :any, default: nil)
  attr(:excluded_uuids, :list, default: [])
  attr(:locale, :string, required: true)
  attr(:placeholder, :string, default: nil)
  attr(:empty_query_limit, :integer, default: 10)
  attr(:page_size, :integer, default: 20)
  attr(:disabled, :boolean, default: false)
  attr(:format_price, :any, default: nil)
  attr(:format_unit, :any, default: nil)
  attr(:show_unit, :boolean, default: false)
  attr(:show_sku, :boolean, default: false)
  attr(:highlight_selected, :boolean, default: true)
  attr(:initial_query, :string, default: nil)
  attr(:photo_clickable, :boolean, default: false)
  attr(:photo_placeholder, :boolean, default: false)
  attr(:photo_size, :string, default: "w-8 h-8")
  attr(:photo_asset_type, :string, default: "thumbnail")
  attr(:show_photo, :boolean, default: true)

  def item_picker(assigns) do
    ~H"""
    <.live_component
      module={PhoenixKitCatalogue.Web.Components.ItemPicker}
      id={@id}
      category_uuids={@category_uuids}
      catalogue_uuids={@catalogue_uuids}
      include_descendants={@include_descendants}
      only={@only}
      statuses={@statuses}
      selected_item={@selected_item}
      excluded_uuids={@excluded_uuids}
      locale={@locale}
      placeholder={@placeholder}
      empty_query_limit={@empty_query_limit}
      page_size={@page_size}
      disabled={@disabled}
      format_price={@format_price}
      format_unit={@format_unit}
      show_unit={@show_unit}
      show_sku={@show_sku}
      highlight_selected={@highlight_selected}
      initial_query={@initial_query}
      photo_clickable={@photo_clickable}
      photo_placeholder={@photo_placeholder}
      photo_size={@photo_size}
      photo_asset_type={@photo_asset_type}
      show_photo={@show_photo}
    />
    """
  end

  # ── Helpers ────────────────────────────────────────────────────

  defp has_actions?(assigns) do
    assigns[:edit_path] != nil or assigns[:on_delete] != nil or
      assigns[:on_restore] != nil or assigns[:on_permanent_delete] != nil or
      assigns[:pdf_search_event] != nil
  end

  defp column_label(:name), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Name")
  defp column_label(:sku), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "SKU")
  defp column_label(:base_price), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Base Price")
  defp column_label(:price), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Price")
  defp column_label(:discount), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Discount")
  defp column_label(:final_price), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Final Price")
  defp column_label(:unit), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Unit")
  defp column_label(:status), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Status")
  defp column_label(:category), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category")
  defp column_label(:catalogue), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue")

  defp column_label(:manufacturer),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Manufacturer")

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

  # Table cells show an em-dash for a missing unit; the abbreviation table
  # itself lives in `Item.unit_label/1` (shared with the item picker).
  defp format_unit(nil), do: "—"
  defp format_unit(unit), do: Item.unit_label(unit)

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
  # The manufacturer is a federated {source, uuid} reference (V179), not an
  # association, so there is nothing to preload and nothing to `safe_assoc_field`.
  # `Manufacturers.hydrate/1` stamps `:manufacturer_name` at the query boundary;
  # a nil here means the page forgot to hydrate, which shows as the same "—" an
  # item with no manufacturer gets rather than crashing the render.
  defp manufacturer_display(%{manufacturer_name: name}) when is_binary(name) and name != "",
    do: name

  defp manufacturer_display(_item), do: "—"

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

  @doc """
  An item list for another module to embed — the CRM company page's
  Catalogue tab today.

  This is a deliberately narrow wrapper around `item_table/1` rather than a
  second table. A caller outside this package cannot invoke `item_table/1`
  itself: HEEx injects `attr` defaults at the CALL SITE, so reaching it
  through `apply/3` would mean the caller supplying every attribute by hand
  and re-supplying each new one we add. Here the defaults are applied inside
  the catalogue, and the contract with the caller is two keys.

  Takes a plain map (no attr defaults are available through `apply/3`):

    * `:items` — `%Item{}` structs, ideally hydrated by
      `Manufacturers.hydrate/1` so the manufacturer column has a name
    * `:id` — unique DOM id for the table
    * `:columns` — optional; which columns to show, in order. Defaults to a
      sensible set. Pair it with core's `column_settings_modal/1` and
      `managed_columns/0` below to give the embed a working column picker.

  Presentation — the image column, the card/table toggle, price and status
  formatting — stays owned by the catalogue, so an embedded list keeps
  matching the catalogue's own. That includes the convention that an item's
  name opens its edit form; the `catalogue` column is the way back to where
  the item lives.
  """
  def party_items_table(assigns) do
    assigns =
      assigns
      |> Map.put_new(
        :columns,
        party_items_default_columns() |> Enum.map(&String.to_existing_atom/1)
      )
      |> Map.put_new(:id, "party-items")
      # `:name` is always shown and is not the picker's to remove, but
      # `item_table/1` still needs it in `columns` to render the Name COLUMN —
      # the card view draws the name from its header instead, which is why a
      # missing `:name` looks fine in cards and blank in the table.
      |> Map.update!(:columns, fn cols -> [:name | List.delete(cols, :name)] end)

    ~H"""
    <.item_table
      id={@id}
      items={@items}
      columns={@columns}
      edit_path={&PhoenixKitCatalogue.Paths.item_edit/1}
      name_path={&item_in_catalogue_path/1}
      catalogue_path={&PhoenixKitCatalogue.Paths.catalogue_detail/1}
      size="sm"
    />
    """
  end

  @doc """
  The configurable columns of `party_items_table/1`, in the shape core's
  `column_settings_modal/1` expects. `name` is deliberately absent: it is
  always shown, so it is not the picker's to remove.
  """
  def party_items_columns do
    [
      %{id: "sku", label: fn -> Gettext.gettext(PhoenixKitCatalogue.Gettext, "SKU") end},
      %{
        id: "base_price",
        label: fn -> Gettext.gettext(PhoenixKitCatalogue.Gettext, "Base Price") end
      },
      %{id: "unit", label: fn -> Gettext.gettext(PhoenixKitCatalogue.Gettext, "Unit") end},
      %{id: "status", label: fn -> Gettext.gettext(PhoenixKitCatalogue.Gettext, "Status") end},
      %{
        id: "catalogue",
        label: fn -> Gettext.gettext(PhoenixKitCatalogue.Gettext, "Catalogue") end
      },
      %{
        id: "category",
        label: fn -> Gettext.gettext(PhoenixKitCatalogue.Gettext, "Category") end
      },
      %{
        id: "manufacturer",
        label: fn -> Gettext.gettext(PhoenixKitCatalogue.Gettext, "Manufacturer") end
      }
    ]
  end

  @doc "Default shown columns for `party_items_table/1`."
  def party_items_default_columns, do: ~w(sku base_price unit status catalogue category)

  # An item is viewed inside its catalogue, filtered to its category — there
  # is no standalone item page to link to.
  defp item_in_catalogue_path(%{catalogue_uuid: nil}), do: nil

  defp item_in_catalogue_path(%{catalogue_uuid: cat, category_uuid: nil}),
    do: PhoenixKitCatalogue.Paths.uncategorized_browse(cat)

  defp item_in_catalogue_path(%{catalogue_uuid: cat, category_uuid: category}),
    do: PhoenixKitCatalogue.Paths.category_browse(cat, category)

  # Where an item's name links: `name_path` when a caller overrides it,
  # otherwise the catalogue's own convention of opening the edit form.
  defp item_name_link(_assigns, %{uuid: nil}), do: nil

  defp item_name_link(%{name_path: fun}, item) when is_function(fun, 1), do: fun.(item)

  defp item_name_link(%{edit_path: edit_path}, item) when not is_nil(edit_path),
    do: safe_call(edit_path, item.uuid)

  defp item_name_link(_assigns, _item), do: nil
end
