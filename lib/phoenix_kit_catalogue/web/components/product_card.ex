defmodule PhoenixKitCatalogue.Web.Components.ProductCard do
  @moduledoc """
  A read-only card for a catalogue row — opened from the `ItemPicker`
  thumbnail, a list's featured-image thumb, or the View action in any row
  menu. The item form is the one potentially shown to a CLIENT rather than
  an admin, so the card has to stand on its own.

  Three kinds of row have one (an `%Item{}`, a `%Catalogue{}` and a
  `%Category{}`), and they differ only in their FIELDS — the media half is
  identical, because `Attachments` gives all three the same featured
  image / files folder shape. Hence one render and three builders:
  `build_fields/3`, `build_catalogue_fields/3` and
  `build_category_fields/3`. Each takes `:admin` (default `false`), which
  is what adds the operator rows — status, place, counts, sourcing and
  pricing internals. Leave it off for anything a client can reach.

  The render itself (`product_card/1`, `product_card_body/1`) delegates to
  core's `PhoenixKitWeb.Components.Core.PreviewCard` — the same carousel +
  fields shell generalised for any resource with photos/files. This module
  keeps its own name/attrs for compatibility and stays the catalogue's
  entry point.

  Image/file resolution and field extraction (the DB-backed work) live in
  the public helpers `resolve_images/1`, `resolve_files/1`, `resolve_name/2`,
  and the three field builders, so the delegation stays render-only and
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

  alias PhoenixKitCatalogue.Web.Components.Browse
  alias PhoenixKitCatalogue.Web.Helpers
  alias PhoenixKitWeb.Components.Core.PreviewCard

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitCatalogue.{Attachments, Catalogue, Metadata}
  alias PhoenixKitCatalogue.Schemas.{Category, Item}
  # `Catalogue` above is the context; the schema of the same name needs its own.
  alias PhoenixKitCatalogue.Schemas.Catalogue, as: CatalogueSchema

  # The three rows a person can open a View card on. They share the whole
  # media half (`Attachments` gives items and catalogues a featured image
  # plus a files folder, categories a featured image), so only the field
  # list differs — one builder each, below.
  @carded [Item, CatalogueSchema, Category]

  # ── Render ───────────────────────────────────────────────────────

  @doc """
  Renders the product card modal. Pure: every DB-backed value
  (`images`, `fields`, `item_name`) is resolved by the caller and passed
  in. Delegates to `PhoenixKitWeb.Components.Core.PreviewCard.preview_card/1`.

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
    <PreviewCard.preview_card
      id={@id}
      show={@show}
      target={@target}
      title={card_title(@item_name)}
      images={@images}
      fields={@fields}
      files={@files}
      on_close={@on_close}
    >
      <:extra_actions>{render_slot(@extra_actions)}</:extra_actions>
    </PreviewCard.preview_card>
    """
  end

  @doc """
  The card's content without the modal shell — the "notpopup" form, for
  embedding the same product view inline (a detail pane, a future product
  page). Same attrs as `product_card/1` minus the modal ones. Delegates to
  `PhoenixKitWeb.Components.Core.PreviewCard.preview_card_body/1`.
  """
  attr(:target, :any,
    default: nil,
    doc:
      "Accepted for API compatibility; the body renders no event of its own " <>
        "(slides switch client-side, Close lives in the modal's action row), " <>
        "so core's `preview_card_body/1` does not take a target and this is " <>
        "not forwarded."
  )

  attr(:item_name, :string, default: nil)
  attr(:images, :list, default: [])
  attr(:current_image, :string, default: nil, doc: "accepted for API compatibility; unused")
  attr(:fields, :list, default: [])
  attr(:files, :list, default: [])

  def product_card_body(assigns) do
    ~H"""
    <PreviewCard.preview_card_body
      title={card_title(@item_name)}
      images={@images}
      fields={@fields}
      files={@files}
    />
    """
  end

  # The card's title/aria fallback. Core's own fallback is the generic
  # "Preview"; the catalogue keeps saying "Item", from its OWN backend, so
  # the string stays translated by this module's et/ru catalogues.
  defp card_title(nil), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Item")
  defp card_title(""), do: card_title(nil)
  defp card_title(name), do: name

  # ── Resolution helpers (DB-backed; called by the picker on click) ─

  @doc """
  Resolves the ordered gallery images for an item: the main
  (`featured_image_uuid`) first, then the remaining image files in the
  item's `files_folder_uuid`, de-duplicated. Returns `%{uuid, name}`
  maps. Nil/blank-safe and rescued — a missing folder or a Storage
  hiccup degrades to just the main image (or `[]` if there is none).
  """
  @spec resolve_images(Item.t() | CatalogueSchema.t() | Category.t() | term()) :: [
          %{uuid: String.t(), name: String.t() | nil}
        ]
  def resolve_images(%{__struct__: struct, data: data}) when struct in @carded and is_map(data) do
    folder_images =
      data
      |> read_uuid("files_folder_uuid")
      |> list_folder_images()
      # The editor's saved drag order (data["media_order"]) drives the
      # carousel too — the client reordered these on purpose (boss,
      # 2026-08-31). Unknown files keep their inserted_at tail order.
      |> Attachments.apply_media_order(Map.get(data, "media_order") || [])

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
  @spec resolve_files(Item.t() | CatalogueSchema.t() | Category.t() | term()) ::
          [%{uuid: String.t(), name: String.t() | nil, size: integer() | nil, pdf?: boolean()}]
  def resolve_files(%{__struct__: struct, data: data}) when struct in @carded and is_map(data) do
    case read_uuid(data, "files_folder_uuid") do
      nil ->
        []

      folder_uuid ->
        folder_uuid
        |> list_folder_files()
        |> Attachments.apply_media_order(Map.get(data, "media_order") || [])
    end
  end

  def resolve_files(_), do: []

  @doc "Resolves the row's display name for the given locale (translation, then bare name)."
  @spec resolve_name(Item.t() | CatalogueSchema.t() | Category.t() | term(), String.t()) ::
          String.t() | nil
  def resolve_name(%{__struct__: struct} = record, locale) when struct in @carded,
    do: Catalogue.translated_name(record, locale)

  def resolve_name(_, _), do: nil

  @doc """
  Builds the ordered `{label, value}` list of the item's filled,
  user-facing scalar fields — SKU, price, unit, description, then
  metadata. Empty values are dropped, so the card only shows what is set.

  `opts` (2026-08-30, for embeddings under a display contract — the item
  selector's detail page honours its `show_prices`/`show_sku` grants):

    * `:include_price` — default `true`; `false` drops the price row.
    * `:include_sku` — default `true`; `false` drops the SKU row.
    * `:admin` — default `false`; `true` adds the rows only an operator may
      see (status, location, manufacturer, main supplier). Every
      client-facing embed leaves it off, which is why it is opt-in.
  """
  @spec build_fields(Item.t() | term(), String.t(), keyword()) :: [{String.t(), String.t()}]
  def build_fields(item, locale, opts \\ [])

  def build_fields(%Item{} = item, locale, opts) do
    item
    |> scalar_fields(opts)
    |> Enum.concat(admin_fields(item, locale, opts))
    |> Enum.concat([{gettext("Description"), resolve_description(item, locale)}])
    |> Enum.concat(metadata_fields(:item, item))
    |> Enum.concat(attribute_fields(item, locale))
    |> finish_fields()
  end

  def build_fields(_, _, _), do: []

  defp scalar_fields(%Item{} = item, opts) do
    [
      {Keyword.get(opts, :include_sku, true), {gettext("SKU"), item.sku}},
      {Keyword.get(opts, :include_price, true),
       {gettext("Price"), format_price(item) || fee_value(item)}},
      {true, {gettext("Unit"), unit_value(item)}}
    ]
    |> Enum.filter(fn {include, _field} -> include end)
    |> Enum.map(fn {_include, field} -> field end)
  end

  # The operator-only rows, asked for by the catalogue page's View popup
  # (boss, 2026-09-19: "they're either editing or nothing at all"). They sit
  # between the scalars and the description so the short rows stay together
  # in the two-column grid. Each resolver is rescued on its own: a dangling
  # manufacturer must not cost the card its status row.
  defp admin_fields(%Item{} = item, locale, opts) do
    if Keyword.get(opts, :admin, false) do
      [
        {gettext("Status"), Helpers.status_label(item.status)},
        {gettext("Location"), location_value(item, locale)},
        {gettext("Manufacturer"), manufacturer_value(item)},
        {gettext("Primary supplier"), supplier_value(item)}
      ]
    else
      []
    end
  end

  @doc """
  Builds the `{label, value}` list for a CATALOGUE's View card — the same
  read-only look the items have, for the row above them.

  `opts` mirrors `build_fields/3`: `:admin` (default `false`) adds the rows
  only an operator may see — status, where it is filed, what it holds, and
  its markup/discount. Everything outside that gate is what a catalogue
  would show a client, so a future client-facing embed stays safe by
  default.
  """
  @spec build_catalogue_fields(CatalogueSchema.t() | term(), String.t(), keyword()) ::
          [{String.t(), String.t()}]
  def build_catalogue_fields(catalogue, locale, opts \\ [])

  def build_catalogue_fields(%CatalogueSchema{} = catalogue, locale, opts) do
    [{gettext("Kind"), kind_value(catalogue)}]
    |> Enum.concat(catalogue_admin_fields(catalogue, locale, opts))
    |> Enum.concat([{gettext("Description"), resolve_description(catalogue, locale)}])
    |> Enum.concat(metadata_fields(:catalogue, catalogue))
    |> finish_fields()
  end

  def build_catalogue_fields(_, _, _), do: []

  # Counts are one GROUP BY each, like the item card's location path — paid
  # per click on View, never per row.
  defp catalogue_admin_fields(%CatalogueSchema{} = catalogue, locale, opts) do
    if Keyword.get(opts, :admin, false) do
      [
        {gettext("Status"), Helpers.status_label(catalogue.status)},
        {gettext("Folder"), folder_value(catalogue, locale)},
        {gettext("Categories"),
         count_value(&Catalogue.category_count_for_catalogue/1, catalogue)},
        {gettext("Items"), count_value(&Catalogue.item_count_for_catalogue/1, catalogue)},
        {gettext("Markup"), percentage_value(catalogue.markup_percentage)},
        {gettext("Discount"), percentage_value(catalogue.discount_percentage)}
      ]
    else
      []
    end
  end

  @doc """
  Builds the `{label, value}` list for a CATEGORY's View card.

  Same `:admin` contract as `build_catalogue_fields/3`: status, the path it
  sits on and what it holds are operator rows; the description is not.
  """
  @spec build_category_fields(Category.t() | term(), String.t(), keyword()) ::
          [{String.t(), String.t()}]
  def build_category_fields(category, locale, opts \\ [])

  def build_category_fields(%Category{} = category, locale, opts) do
    category
    |> category_admin_fields(locale, opts)
    |> Enum.concat([{gettext("Description"), resolve_description(category, locale)}])
    |> finish_fields()
  end

  def build_category_fields(_, _, _), do: []

  defp category_admin_fields(%Category{} = category, locale, opts) do
    if Keyword.get(opts, :admin, false) do
      [
        {gettext("Status"), Helpers.status_label(category.status)},
        # The path ABOVE this category — its own name is already the card's
        # title, so repeating it in the location would read as a loop.
        {gettext("Location"), category_parent_path(category, locale)},
        {gettext("Subcategories"), subcategory_count(category)},
        {gettext("Items"), category_item_count(category)}
      ]
    else
      []
    end
  end

  # The shared tail of every builder: stringify, then drop what is not set,
  # so a card only ever shows filled rows.
  defp finish_fields(fields) do
    fields
    |> Enum.map(fn {label, value} -> {label, to_display(value)} end)
    |> Enum.reject(fn {_label, value} -> blank?(value) end)
  end

  defp kind_value(%CatalogueSchema{kind: "smart"}),
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Smart")

  defp kind_value(_), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Standard")

  # Nothing filed at the root, rather than a made-up "Root" row.
  defp folder_value(%CatalogueSchema{folder_uuid: uuid}, locale) when is_binary(uuid) do
    case Catalogue.get_folder(uuid) do
      %{} = folder -> Catalogue.translated_name(folder, locale)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp folder_value(_catalogue, _locale), do: nil

  defp category_parent_path(%Category{} = category, locale) do
    catalogue =
      case category.catalogue_uuid && Catalogue.get_catalogue(category.catalogue_uuid) do
        %{} = found -> [Catalogue.translated_name(found, locale)]
        _ -> []
      end

    ancestors =
      category.uuid
      |> Catalogue.list_category_ancestors()
      |> Enum.map(&Catalogue.translated_name(&1, locale))

    (catalogue ++ ancestors)
    |> Enum.reject(&blank?/1)
    |> Enum.join(" › ")
  rescue
    _ -> nil
  end

  # A count of 0 is a fact worth showing ("this holds nothing"), so these
  # return a string rather than dropping out through `blank?/1`.
  defp count_value(fun, %CatalogueSchema{uuid: uuid}) when is_binary(uuid) do
    to_string(fun.(uuid))
  rescue
    _ -> nil
  end

  defp count_value(_fun, _catalogue), do: nil

  defp subcategory_count(%Category{catalogue_uuid: cat_uuid, uuid: uuid})
       when is_binary(cat_uuid) and is_binary(uuid) do
    cat_uuid
    |> Catalogue.category_children_counts(mode: :active)
    |> Map.get(uuid, 0)
    |> to_string()
  rescue
    _ -> nil
  end

  defp subcategory_count(_category), do: nil

  defp category_item_count(%Category{catalogue_uuid: cat_uuid, uuid: uuid})
       when is_binary(cat_uuid) and is_binary(uuid) do
    cat_uuid
    |> Catalogue.item_counts_by_category_for_catalogue(mode: :active)
    |> Map.get(uuid, 0)
    |> to_string()
  rescue
    _ -> nil
  end

  defp category_item_count(_category), do: nil

  defp percentage_value(%Decimal{} = value) do
    if Decimal.equal?(value, 0), do: nil, else: Decimal.to_string(value, :normal) <> "%"
  end

  defp percentage_value(_value), do: nil

  # "Kitchens › Hardware › Hinges" — the same place the item form's Location
  # section names, read straight from the row rather than from that tree
  # (the card opens over a list, and the tree is a whole-module read).
  defp location_value(%Item{} = item, locale) do
    catalogue =
      case item.catalogue_uuid && Catalogue.get_catalogue(item.catalogue_uuid) do
        %{} = catalogue -> [Catalogue.translated_name(catalogue, locale)]
        _ -> []
      end

    (catalogue ++ category_names(item.category_uuid, locale))
    |> Enum.reject(&blank?/1)
    |> Enum.join(" › ")
  rescue
    _ -> nil
  end

  defp category_names(uuid, locale) when is_binary(uuid) do
    case Catalogue.get_category(uuid) do
      %{} = category ->
        uuid
        |> Catalogue.list_category_ancestors()
        |> Enum.concat([category])
        |> Enum.map(&Catalogue.translated_name(&1, locale))

      _ ->
        []
    end
  end

  defp category_names(_uuid, _locale), do: []

  # The manufacturer resolves through CRM, so the name shown is the party's
  # current one; the snapshot on the item is the fallback for a party that
  # no longer resolves.
  defp manufacturer_value(%Item{manufacturer_uuid: uuid} = item) when is_binary(uuid) do
    case Catalogue.resolve_manufacturer(uuid) do
      {:ok, %{name: name}} -> name
      _ -> item.manufacturer_name_snapshot
    end
  rescue
    _ -> item.manufacturer_name_snapshot
  end

  defp manufacturer_value(%Item{} = item), do: item.manufacturer_name_snapshot

  # The primary supplier row, named and priced: "Acme Ltd · 12.50 EUR".
  defp supplier_value(%Item{uuid: uuid}) when is_binary(uuid) do
    case Catalogue.primary_supplier_info_for_item(uuid) do
      %{} = info -> [supplier_name(info), supplier_cost(info)] |> compact_join(" · ")
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp supplier_value(_item), do: nil

  # Rescued on its own, not with the row read: a supplier whose identity no
  # longer resolves must still leave the cost the row does know (panel
  # review, 2026-09-20). Suppliers are hard-delete only, so for a deleted
  # one the row's own snapshot is the last name there is — the item form
  # falls back to it too.
  defp supplier_name(%{supplier_uuid: uuid} = info) when is_binary(uuid) do
    case Catalogue.resolve_supplier(uuid) do
      {:ok, %{name: name}} -> name
      _ -> snapshot_name(info)
    end
  rescue
    _ -> snapshot_name(info)
  end

  defp supplier_name(info), do: snapshot_name(info)

  defp snapshot_name(info), do: Map.get(info, :supplier_name_snapshot)

  defp supplier_cost(%{unit_cost: %Decimal{} = cost} = info),
    do: compact_join([Browse.format_price(cost), info.currency], " ")

  defp supplier_cost(_info), do: nil

  defp compact_join(parts, separator) do
    case Enum.reject(parts, &blank?/1) do
      [] -> nil
      kept -> Enum.join(kept, separator)
    end
  end

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

  # A selected value archived/trashed after being picked stays in
  # `:selected` (§3c, 2026-09-11 direction) but drops out of `:values` —
  # look it up in `:hidden_values` too, or its chip silently disappears
  # from the card exactly like the bug this exists to fix.
  defp selected_values(%{selected: [_ | _] = selected} = resolved) do
    hidden = resolved |> Map.get(:hidden_values, []) |> Enum.map(&mark_hidden/1)

    Enum.filter(resolved.values ++ hidden, &(&1.key in selected))
  end

  defp selected_values(%{values: values}), do: values

  # A value archived or trashed after being picked still describes the item,
  # and the card says it is archived, as the item form and the Items popup do.
  # Marked as a hidden value, not by key: a legacy set can hold a live and a
  # hidden value under the same key, and only the hidden one is archived.
  defp mark_hidden(value) do
    %{
      value
      | label:
          Gettext.gettext(PhoenixKitCatalogue.Gettext, "%{value} (archived)", value: value.label)
    }
  end

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

  # Both read the SAME set the item form lists —
  # `Attachments.list_folder_files/2`: home files plus folder-linked
  # ones. Reading the home folder alone (`Storage.list_files_in_scope/2`)
  # dropped every linked file, which is what a content-duplicate upload
  # becomes, so a file the editor showed was missing from the card
  # (client, 2026-09-12).
  defp list_folder_images(folder_uuid) when is_binary(folder_uuid) do
    folder_uuid
    |> Attachments.list_folder_files(file_type: "image", exclude_system_managed: true)
    |> Enum.map(&%{uuid: &1.uuid, name: &1.original_file_name})
  rescue
    _ -> []
  end

  defp list_folder_files(folder_uuid) when is_binary(folder_uuid) do
    # Same set as Counts.attached_file_counts/1 — its docstring promises
    # the paperclip count and this list agree, so system-managed files
    # are excluded here too.
    folder_uuid
    |> Attachments.list_folder_files(exclude_file_type: "image", exclude_system_managed: true)
    |> Enum.map(
      &%{uuid: &1.uuid, name: &1.original_file_name, size: &1.size, pdf?: pdf_file?(&1)}
    )
  rescue
    _ -> []
  end

  defp pdf_file?(file) do
    file.mime_type == "application/pdf" or file.ext in ["pdf", ".pdf"]
  end

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

  # Smart-fee fallback for the Price row: "49.00" (flat), "12%", or a
  # localized Computed — the same resolution the listing shows
  # (Browse.smart_fee/1), so the card never disagrees with the row the
  # click came from.
  defp fee_value(item) do
    case Browse.smart_fee(item) do
      # Browse.format_price/1, not raw to_string — a DB numeric arrives
      # as 49.0000 and the card must not disagree with the listing's
      # "49.00" (external review, 2026-08-31).
      {:price, fee} -> Browse.format_price(fee)
      {:note, note} -> note
      nil -> nil
    end
  end

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

  defp resolve_description(%{__struct__: struct} = record, locale) when struct in @carded,
    do: Catalogue.translated_description(record, locale)

  defp metadata_fields(kind, record) do
    state = Metadata.build_state(kind, record)

    Enum.map(state.attached, fn key ->
      label =
        case Metadata.definition(kind, key) do
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
