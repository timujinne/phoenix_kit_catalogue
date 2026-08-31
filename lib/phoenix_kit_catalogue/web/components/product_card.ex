defmodule PhoenixKitCatalogue.Web.Components.ProductCard do
  @moduledoc """
  A read-only product card for a catalogue `%Item{}` — opened from the
  `ItemPicker` thumbnail or a list's featured-image thumb, and potentially
  shown to a CLIENT, not just admins, so it has to stand on its own.

  `product_card/1` renders a `<.modal>` whose media area is ONE continuous
  swipeable carousel: the item's photos first, then its attached files (a
  PDF renders inline, any other file as a tile with an Open action) — swipe
  through the photos and just keep going into the files. Below it: the
  item's filled scalar fields (SKU, price, unit, description, metadata) and
  a compact file list for saving. Slide switching is entirely client-side
  (scroll-snap); the only server event left is the close.

  Image/file resolution and field extraction (the DB-backed work) live in
  the public helpers `resolve_images/1`, `resolve_files/1`, `resolve_name/2`,
  and `build_fields/2` so the component itself stays render-only and
  testable without a database. `product_card_body/1` is the same content
  without the modal shell (the "notpopup" form).

  ## Usage (from a LiveComponent or LiveView that owns the state)

      <ProductCard.product_card
        id={@id}
        show={@card_open}
        item_name={@card_name}
        images={@card_images}
        fields={@card_fields}
        files={@card_files}
        target={@myself}
        on_close="card_close"
      />
  """

  use Phoenix.Component

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Modal, only: [modal: 1]

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Utils.Format
  alias PhoenixKitCatalogue.{Catalogue, Metadata}
  alias PhoenixKitCatalogue.Schemas.Item

  # ── Render ───────────────────────────────────────────────────────

  @doc """
  Renders the product card modal. Pure: every DB-backed value
  (`images`, `fields`, `item_name`) is resolved by the caller and passed
  in.

  Attrs:

    * `:id` (required) — used to derive the modal's DOM id.
    * `:show` (required) — whether the modal is open.
    * `:target` (required) — the `@myself` of the LiveComponent that
      handles `card_select_image` / the close event (the `ItemPicker`).
    * `:item_name` — card title.
    * `:images` — ordered list of `%{uuid, name}` (main image first).
    * `:current_image` — UUID of the image shown large.
    * `:fields` — list of `{label, value}` for the already-filtered,
      non-empty fields.
    * `:on_close` — event pushed to `@target` on close (default
      `"card_close"`).
  """
  attr(:id, :string, required: true)
  attr(:show, :boolean, required: true)
  attr(:target, :any, required: true)
  attr(:item_name, :string, default: nil)
  attr(:images, :list, default: [])

  attr(:current_image, :string,
    default: nil,
    doc:
      "Accepted for API compatibility; the carousel starts at the first slide " <>
        "(the featured image is already first) and slides are switched " <>
        "client-side, so this no longer drives the render."
  )

  attr(:fields, :list, default: [])
  attr(:files, :list, default: [])
  attr(:on_close, :string, default: "card_close")

  slot(:extra_actions,
    doc:
      "rendered in the modal's action row before Close — the item " <>
        "selector puts its mode-aware Add/quantity control here " <>
        "(2026-08-31, details as their own popup)."
  )

  def product_card(assigns) do
    ~H"""
    <.modal show={@show} id={"#{@id}-card"} on_close={@on_close} max_width="3xl">
      <:title>{@item_name || Gettext.gettext(PhoenixKitCatalogue.Gettext, "Item")}</:title>

      <.product_card_body
        target={@target}
        item_name={@item_name}
        images={@images}
        fields={@fields}
        files={@files}
      />

      <:actions>
        {render_slot(@extra_actions)}
        <button type="button" class="btn btn-ghost" phx-click={@on_close} phx-target={@target}>
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Close")}
        </button>
      </:actions>
    </.modal>
    """
  end

  @doc """
  The card's content without the modal shell — the "notpopup" form, for
  embedding the same product view inline (a detail pane, a future product
  page). Same attrs as `product_card/1` minus the modal ones.

  The media area is ONE continuous swipeable carousel: photos first, then
  the attached files (a PDF renders inline, any other file as a tile) — the
  client swipes through the photos and just keeps going into the files.
  Scroll-snap (daisyUI `carousel`) drives it entirely client-side: native
  swipe on touch, arrow buttons on desktop, no server round-trip per slide.
  """
  attr(:target, :any, required: true)
  attr(:item_name, :string, default: nil)
  attr(:images, :list, default: [])
  attr(:current_image, :string, default: nil, doc: "accepted for API compatibility; unused")
  attr(:fields, :list, default: [])
  attr(:files, :list, default: [])

  def product_card_body(assigns) do
    assigns = assign(assigns, :slide_count, length(assigns.images) + length(assigns.files))

    ~H"""
    <div class="flex flex-col gap-4" data-pc-root>
      <%!-- Unified media carousel — photos, then files, one swipe track.
           All client-side. The track's onscroll keeps the jump strip's
           active tile in sync (debounced; inline JS like the arrows, so the
           card stays dependency-free wherever it is embedded). --%>
      <div :if={@slide_count > 0} class="relative">
        <div
          class="carousel w-full rounded-lg bg-base-200"
          data-pc-track
          role="region"
          aria-label={@item_name || Gettext.gettext(PhoenixKitCatalogue.Gettext, "Item")}
          onscroll="clearTimeout(this._pc);this._pc=setTimeout(()=>{const i=Math.round(this.scrollLeft/this.clientWidth);const s=this.closest('[data-pc-root]').querySelector('[data-pc-strip]');if(s)Array.from(s.children).forEach((el,j)=>{el.classList.toggle('border-primary',j===i);el.classList.toggle('border-base-300',j!==i);if(j===i){el.setAttribute('aria-current','true')}else{el.removeAttribute('aria-current')}})},80)"
        >
          <div
            :for={{img, idx} <- Enum.with_index(@images)}
            class="carousel-item w-full justify-center items-center"
          >
            <img
              src={URLSigner.signed_url(img.uuid, "medium")}
              alt={img.name || @item_name || ""}
              loading={(idx == 0 && "eager") || "lazy"}
              class="w-full h-[50vh] object-contain"
            />
          </div>
          <div :for={file <- @files} class="carousel-item w-full justify-center items-center">
            <%!-- Inline PDF only from `sm` up: iOS Safari renders iframe
                 PDFs as a broken single page AND the iframe swallows the
                 swipe gesture, stranding the carousel. Small screens get
                 the file tile; the strip and Open still work. --%>
            <iframe
              :if={file.pdf?}
              src={URLSigner.signed_url(file.uuid, "original")}
              loading="lazy"
              title={file.name}
              class="w-full h-[50vh] hidden sm:block"
            >
            </iframe>
            <div
              :if={!file.pdf?}
              class="w-full h-[50vh] flex flex-col items-center justify-center gap-3"
            >
              <.file_slide_tile file={file} />
            </div>
            <div
              :if={file.pdf?}
              class="w-full h-[50vh] flex flex-col items-center justify-center gap-3 sm:hidden"
            >
              <.file_slide_tile file={file} />
            </div>
          </div>
        </div>
        <%!-- Arrows: desktop/pointer only — on touch the swipe IS the
             navigation and the buttons just crowd the photo edge. --%>
        <button
          :if={@slide_count > 1}
          type="button"
          aria-label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Previous")}
          class="btn btn-circle btn-sm bg-base-100/80 border-0 shadow absolute left-2 top-1/2 -translate-y-1/2 hidden sm:inline-flex"
          onclick="const t=this.closest('[data-pc-root]').querySelector('[data-pc-track]');t.scrollBy({left:-t.clientWidth,behavior:'smooth'})"
        >
          <.icon name="hero-chevron-left" class="w-4 h-4" />
        </button>
        <button
          :if={@slide_count > 1}
          type="button"
          aria-label={Gettext.gettext(PhoenixKitCatalogue.Gettext, "Next")}
          class="btn btn-circle btn-sm bg-base-100/80 border-0 shadow absolute right-2 top-1/2 -translate-y-1/2 hidden sm:inline-flex"
          onclick="const t=this.closest('[data-pc-root]').querySelector('[data-pc-track]');t.scrollBy({left:t.clientWidth,behavior:'smooth'})"
        >
          <.icon name="hero-chevron-right" class="w-4 h-4" />
        </button>
      </div>

      <%!-- Jump strip: a tile per slide (image thumbs, then file tiles).
           The border marks the current slide; the track's onscroll moves
           it as the user swipes. Tile 0 starts active server-side. --%>
      <div :if={@slide_count > 1} class="flex gap-2 overflow-x-auto pb-1" data-pc-strip>
        <button
          :for={{img, idx} <- Enum.with_index(@images)}
          type="button"
          class={[
            "shrink-0 rounded border-2 overflow-hidden transition-colors hover:border-primary",
            (idx == 0 && "border-primary") || "border-base-300"
          ]}
          aria-label={
            Gettext.gettext(PhoenixKitCatalogue.Gettext, "Show image %{number}",
              number: idx + 1
            )
          }
          aria-current={idx == 0 && "true"}
          onclick={jump_js(idx)}
        >
          <img
            src={URLSigner.signed_url(img.uuid, "thumbnail")}
            alt=""
            loading="lazy"
            class="w-16 h-16 object-cover"
          />
        </button>
        <button
          :for={{file, idx} <- Enum.with_index(@files, length(@images))}
          type="button"
          class="shrink-0 w-[68px] h-[68px] rounded border-2 border-base-300 hover:border-primary transition-colors flex flex-col items-center justify-center gap-0.5 bg-base-200"
          aria-label={file.name}
          title={file.name}
          onclick={jump_js(idx)}
        >
          <.icon
            name={(file.pdf? && "hero-document-text") || "hero-document"}
            class="w-5 h-5 text-base-content/50"
          />
          <span class="text-[9px] leading-tight text-base-content/50 uppercase">
            {(file.pdf? && "pdf") || file_ext(file.name)}
          </span>
        </button>
      </div>

      <%!-- Filled fields (empty ones already dropped by build_fields/2) --%>
      <dl
        :if={@fields != []}
        class="grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-3 border-t border-base-200 pt-4"
      >
        <div :for={{label, value} <- @fields} class="min-w-0">
          <dt class="text-xs font-medium text-base-content/50">{label}</dt>
          <dd class="text-sm text-base-content break-words whitespace-pre-line">{value}</dd>
        </div>
      </dl>

      <%!-- Compact file list — names, sizes, and a direct Open for saving;
           the slides above are the viewing surface. --%>
      <div :if={@files != []} class="border-t border-base-200 pt-4">
        <h4 class="text-xs font-medium text-base-content/50 mb-2">
          {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Files")}
        </h4>
        <ul class="flex flex-col gap-1.5">
          <li
            :for={file <- @files}
            class="flex items-center gap-3 px-3 py-2 rounded-lg border border-base-200"
          >
            <.icon
              name={(file.pdf? && "hero-document-text") || "hero-document"}
              class="w-4 h-4 shrink-0 text-base-content/40"
            />
            <span class="text-sm truncate flex-1 min-w-0">{file.name}</span>
            <span class="text-xs text-base-content/50 tabular-nums shrink-0">
              {format_size(file.size)}
            </span>
            <a
              href={URLSigner.signed_url(file.uuid, "original")}
              target="_blank"
              rel="noopener"
              class="btn btn-ghost btn-xs"
            >
              {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Open")}
            </a>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  # A non-viewable file as a slide: icon, name, size, and an Open action.
  attr(:file, :map, required: true)

  defp file_slide_tile(assigns) do
    ~H"""
    <.icon name="hero-document" class="w-16 h-16 text-base-content/30" />
    <p class="text-sm font-medium text-center px-6 break-words max-w-full">{@file.name}</p>
    <p class="text-xs text-base-content/50 tabular-nums">{format_size(@file.size)}</p>
    <a
      href={URLSigner.signed_url(@file.uuid, "original")}
      target="_blank"
      rel="noopener"
      class="btn btn-sm btn-outline"
    >
      {Gettext.gettext(PhoenixKitCatalogue.Gettext, "Open")}
    </a>
    """
  end

  # Scrolls the slide at `idx` into view inside this card's own snap track.
  # `block: "nearest"` keeps the vertical position of the modal untouched.
  defp jump_js(idx) do
    "const t=this.closest('[data-pc-root]').querySelector('[data-pc-track]');" <>
      "t.children[#{idx}].scrollIntoView({behavior:'smooth',block:'nearest',inline:'start'})"
  end

  defp file_ext(name) when is_binary(name) do
    case Path.extname(name) do
      "." <> ext when byte_size(ext) in 1..4 -> ext
      _ -> "file"
    end
  end

  defp file_ext(_), do: "file"

  # ── Resolution helpers (DB-backed; called by the picker on click) ─

  @doc """
  Resolves the ordered gallery images for an item: the main
  (`featured_image_uuid`) first, then the remaining image files in the
  item's `files_folder_uuid`, de-duplicated. Returns `%{uuid, name}`
  maps. Nil/blank-safe and rescued — a missing folder or a Storage
  hiccup degrades to just the main image (or `[]` if there is none).
  """
  @spec resolve_images(Item.t() | term()) :: [%{uuid: String.t(), name: String.t() | nil}]
  def resolve_images(%Item{data: data}) when is_map(data) do
    folder_images = list_folder_images(read_uuid(data, "files_folder_uuid"))

    # The featured pointer can dangle (file trashed/deleted after it was set),
    # which would render a broken <img>. Only keep it when it still resolves to
    # a live image — the same bar the folder listing already applies.
    case valid_featured(read_uuid(data, "featured_image_uuid")) do
      nil -> folder_images
      uuid -> [%{uuid: uuid, name: nil} | Enum.reject(folder_images, &(&1.uuid == uuid))]
    end
  end

  def resolve_images(_), do: []

  @doc """
  Resolves the item's attached NON-image files (documents, PDFs, …) from
  its `files_folder_uuid`, as `%{uuid, name, size, pdf?}` maps. PDFs are
  flagged so the card can offer the inline viewer. Nil/blank-safe and
  rescued the same way `resolve_images/1` is.
  """
  @spec resolve_files(Item.t() | term()) ::
          [%{uuid: String.t(), name: String.t() | nil, size: integer() | nil, pdf?: boolean()}]
  def resolve_files(%Item{data: data}) when is_map(data) do
    case read_uuid(data, "files_folder_uuid") do
      nil -> []
      folder_uuid -> list_folder_files(folder_uuid)
    end
  end

  def resolve_files(_), do: []

  @doc "Resolves the item's display name for the given locale (translation, then bare name)."
  @spec resolve_name(Item.t() | term(), String.t()) :: String.t() | nil
  def resolve_name(%Item{} = item, locale) do
    translation = safe_translation(item, locale)

    Map.get(translation, "_name") ||
      Map.get(translation, "name") ||
      item.name
  end

  def resolve_name(_, _), do: nil

  @doc """
  Builds the ordered `{label, value}` list of the item's filled,
  user-facing scalar fields — SKU, price, unit, description, then
  metadata. Empty values are dropped, so the card only shows what is set.

  `opts` (2026-08-30, for embeddings under a display contract — the item
  selector's detail page honours its `show_prices`/`show_sku` grants):

    * `:include_price` — default `true`; `false` drops the price row.
    * `:include_sku` — default `true`; `false` drops the SKU row.
  """
  @spec build_fields(Item.t() | term(), String.t(), keyword()) :: [{String.t(), String.t()}]
  def build_fields(item, locale, opts \\ [])

  def build_fields(%Item{} = item, locale, opts) do
    [
      {Keyword.get(opts, :include_sku, true), {gettext("SKU"), item.sku}},
      {Keyword.get(opts, :include_price, true), {gettext("Price"), format_price(item)}},
      {true, {gettext("Unit"), unit_value(item)}},
      {true, {gettext("Description"), resolve_description(item, locale)}}
    ]
    |> Enum.filter(fn {include, _field} -> include end)
    |> Enum.map(fn {_include, field} -> field end)
    |> Enum.concat(metadata_fields(item))
    |> Enum.concat(attribute_fields(item, locale))
    |> Enum.map(fn {label, value} -> {label, to_display(value)} end)
    |> Enum.reject(fn {_label, value} -> blank?(value) end)
  end

  def build_fields(_, _, _), do: []

  # The item's attributes resolved for the card's locale — one row per
  # set/attribute, values comma-joined in display order. Runs on card
  # open only (this function is caller-side), so no per-row list cost.
  # SETS (the 2026-08-18 rework) render first when the item has any;
  # otherwise the legacy group resolve still carries dual-run items.
  defp attribute_fields(%Item{uuid: uuid}, locale) when is_binary(uuid) do
    case Catalogue.resolve_attribute_sets_for_item(uuid, lang: locale) do
      %{sets: [_ | _] = sets} ->
        # A per-item selection narrows the set (boss's two modes): one
        # checked value = this exact configuration, several = the
        # options this item comes in, none = the whole set.
        for s <- sets do
          {s.name, Enum.map_join(selected_values(s), ", ", & &1.label)}
        end

      _ ->
        legacy_attribute_fields(uuid, locale)
    end
  end

  defp attribute_fields(_, _), do: []

  defp selected_values(%{selected: [_ | _] = selected, values: values}),
    do: Enum.filter(values, &(&1.key in selected))

  defp selected_values(%{values: values}), do: values

  defp legacy_attribute_fields(uuid, locale) do
    with group_uuid when is_binary(group_uuid) <-
           Catalogue.get_item_attribute_group_uuid(uuid),
         %{attributes: attributes} <- Catalogue.resolved_group(group_uuid, locale) do
      for a <- attributes do
        {a.name, Enum.map_join(a.values, ", ", & &1.value)}
      end
    else
      _ -> []
    end
  end

  # ── Internals ─────────────────────────────────────────────────────

  defp list_folder_images(nil), do: []

  defp list_folder_images(folder_uuid) when is_binary(folder_uuid) do
    {files, _total} =
      Storage.list_files_in_scope(nil, folder_uuid: folder_uuid, file_type: "image", per_page: 50)

    files
    |> Enum.reject(&(&1.status == "trashed"))
    |> Enum.map(&%{uuid: &1.uuid, name: &1.original_file_name})
  rescue
    _ -> []
  end

  defp list_folder_files(folder_uuid) when is_binary(folder_uuid) do
    {files, _total} = Storage.list_files_in_scope(nil, folder_uuid: folder_uuid, per_page: 50)

    # Same set as Counts.attached_file_counts/1 — its docstring promises
    # the paperclip count and this list agree, so system-managed files
    # are excluded here too.
    files
    |> Enum.reject(&(&1.status == "trashed" or &1.file_type == "image" or &1.system_managed))
    |> Enum.map(
      &%{uuid: &1.uuid, name: &1.original_file_name, size: &1.size, pdf?: pdf_file?(&1)}
    )
  rescue
    _ -> []
  end

  defp pdf_file?(file) do
    file.mime_type == "application/pdf" or file.ext in ["pdf", ".pdf"]
  end

  defp format_size(size) when is_integer(size) and size > 0,
    do: Format.bytes(size, base: 1000, decimals: 2)

  defp format_size(_), do: ""

  # Keeps the featured pointer only when it still resolves to a live image —
  # a trashed or deleted file would otherwise render a broken thumbnail.
  defp valid_featured(nil), do: nil

  defp valid_featured(uuid) do
    case Storage.get_file(uuid) do
      %{file_type: "image", status: status} when status != "trashed" -> uuid
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Field values reach the template via `{value}`, which calls `to_string/1`.
  # Metadata values come from a free-form JSONB map and could be a nested
  # map/list (malformed or legacy data) that has no String.Chars — coerce
  # non-scalars with `inspect/1` so a stray value can never crash the card.
  defp to_display(nil), do: nil
  defp to_display(value) when is_binary(value), do: value
  defp to_display(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp to_display(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp to_display(value), do: inspect(value)

  defp format_price(%Item{} = item) do
    case Catalogue.item_pricing(item).final_price do
      %Decimal{} = price -> Decimal.to_string(price, :normal)
      _ -> nil
    end
  rescue
    # Chrome-not-data degradation, same doctrine as the other rescues in
    # this file: a broken markup/discount rule must not crash the
    # client-facing card — the price row is simply omitted. The listing
    # behind the card prices items on an unrescued path, so the two
    # surfaces disagreeing IS the visible symptom pointing at the rule.
    _ -> nil
  end

  defp unit_value(%Item{unit: unit}) do
    case Item.unit_label(unit) do
      "" -> nil
      label -> label
    end
  end

  defp resolve_description(%Item{} = item, locale) do
    translation = safe_translation(item, locale)

    Map.get(translation, "_description") ||
      Map.get(translation, "description") ||
      item.description
  end

  defp metadata_fields(%Item{} = item) do
    state = Metadata.build_state(:item, item)

    Enum.map(state.attached, fn key ->
      label =
        case Metadata.definition(:item, key) do
          %{label: label} -> label
          _ -> key
        end

      {label, Map.get(state.values, key)}
    end)
  rescue
    # `Metadata.build_state/2` stringifies each meta value with `to_string/1`,
    # which raises on a non-scalar (a map/list left by malformed or legacy
    # data). Dropping the metadata block is far better than crashing the card;
    # the scalar fields still render.
    _ -> []
  end

  defp safe_translation(record, locale) do
    Catalogue.get_translation(record, locale)
  rescue
    _ -> %{}
  end

  # Both call sites sit inside `resolve_images(%Item{data: data}) when
  # is_map(data)`, so the non-map fallback this used to carry was unreachable —
  # dialyzer reports it as a clause that can never match. The guard stays as
  # documentation of what the function expects.
  defp read_uuid(data, key) when is_map(data) do
    case Map.get(data, key) do
      uuid when is_binary(uuid) and uuid != "" -> uuid
      _ -> nil
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  defp gettext(msgid), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, msgid)
end
