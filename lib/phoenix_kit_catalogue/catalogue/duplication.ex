defmodule PhoenixKitCatalogue.Catalogue.Duplication do
  @moduledoc """
  Copies of items and categories — the "Duplicate" bulk action.

  An item copy is the row plus everything the item form edits alongside
  it: multilang `data` (translations, custom fields, featured-image
  pointer), attribute-set attachments, the attribute-group assignment,
  the CURRENT supplier rows, catalogue rules, and its files folder. Files
  are not re-uploaded: the copy gets its own Storage folder with a
  `FolderLink` to each of the source's files, so removing one from the
  copy never touches the original. Supplier rows get a FRESH comment
  thread — a discount promised on the original stays on the original.
  Comments and activity history are not copied.

  A category copy is the category row (same treatment) plus its whole
  subtree: every active child category and every non-trashed item, each
  keeping its own name and position. Only the top-level copy is renamed
  ("Alpha (copy)") and slotted right after its source.

  A catalogue copy is the catalogue row (renamed "Alpha (copy)", then
  "Alpha (copy 2)" while that name is taken, same status, same folder)
  plus every live category and item in it, names and positions kept. A
  live category whose parent is in the trash becomes a top-level
  category of the copy, and a live item whose category is not copied
  becomes uncategorized — the copy never inherits a hole. References
  inside the copied rows' `data` that name another copied row (an
  extension's featured item, say) are pointed at the copy — any string
  equal to such a uuid, so a field meant to keep naming the original
  would be re-pointed too. A category copy does the same within its
  subtree.

  Every item and category copy (a catalogue row carries no extension
  data) hands each extension's namespace in `data` to that extension's
  optional `duplicate_data/2` (see
  `PhoenixKitCatalogue.Extension`), so an id that must stay unique to
  the original — a shop's external product id — is dropped by the
  module that knows what it means.

  Everything for one copy runs in one transaction; the bulk functions
  run one transaction per source so a refused row does not undo the
  others, and emit ONE batch event per touched catalogue afterwards.

  Public surface is re-exported from `PhoenixKitCatalogue.Catalogue`.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Ecto.Adapters.SQL
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.FolderLink
  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitCatalogue.Catalogue.{ActivityLog, PubSub, SupplierComments}
  alias PhoenixKitCatalogue.Extensions
  alias PhoenixKitCatalogue.Schemas.Catalogue, as: CatalogueSchema

  alias PhoenixKitCatalogue.Schemas.{
    CatalogueRule,
    Category,
    Item,
    ItemAttributeGroup,
    ItemAttributeSet,
    ItemSupplierInfo
  }

  @item_fields [
    :description,
    :sku,
    :base_price,
    :markup_percentage,
    :discount_percentage,
    :default_value,
    :default_unit,
    :unit,
    :status,
    :manufacturer_uuid,
    :manufacturer_source,
    :manufacturer_name_snapshot
  ]

  @supplier_fields [
    :supplier_uuid,
    :supplier_source,
    :supplier_name_snapshot,
    :supplier_sku,
    :unit_cost,
    :currency,
    :lead_time_days,
    :min_order_qty,
    :is_primary,
    :valid_from,
    :position
  ]

  # The folder pointer belongs to exactly one resource; the copy gets its
  # own folder (see `copy_files_folder/3`) or none.
  # `_trash` is trash provenance — a copy is a new row nothing trashed.
  @data_keys_not_copied ["files_folder_uuid", "_trash"]
  # What `files: false` leaves out besides the folder: the image pointers.
  @image_keys ["featured_image_uuid", "media_order"]

  # The choices a copy's nested rows inherit (see `duplicate_catalogue/2`).
  @copy_choices [:skus, :files, :suppliers]

  # Advisory lock names (single-key `hashtext` form) and the name search's
  # upper bound.
  @copy_claim_prefix "catalogue:duplicate:"
  @copy_names_lock "catalogue:copy-names"
  @max_copy_number 10_000

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @type bulk_result :: {:ok, %{created: non_neg_integer(), errors: [{Ecto.UUID.t(), term()}]}}

  @doc """
  Copies one item. Options:

    * `:category_uuid` — put the copy in this category (`nil` = uncategorized)
      instead of the source's; the catalogue follows the category.
    * `:suffix` — append " (copy)" to the name (default `true`).
    * `:keep_position` — keep the source's position number verbatim instead of
      slotting the copy right after the source (default `false`; used for
      subtree copies where the whole sibling set moves together).
    * `:actor_uuid`, `:mode`, `:broadcast` — as elsewhere in the context.
  """
  @spec duplicate_item(Item.t(), keyword()) :: {:ok, Item.t()} | {:error, term()}
  def duplicate_item(%Item{} = source, opts \\ []) do
    case repo().transaction(fn -> copy_item(source, opts) end) do
      {:ok, {item, logs}} ->
        flush_logs(logs)

        if Keyword.get(opts, :broadcast, true),
          do: PubSub.broadcast(:item, item.uuid, item.catalogue_uuid)

        {:ok, item}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Copies one category with its subtree. Options as `duplicate_item/2`
  (`:parent_uuid` instead of `:category_uuid`). Returns the new category and
  how many descendant categories and items came along.
  """
  @spec duplicate_category(Category.t(), keyword()) ::
          {:ok,
           %{category: Category.t(), categories: non_neg_integer(), items: non_neg_integer()}}
          | {:error, term()}
  def duplicate_category(%Category{} = source, opts \\ []) do
    copy = fn ->
      {result, logs} = copy_category(source, opts)
      remap_copies!(copy_mapping([], logs))
      # Re-read: the remap may have rewritten the copy's own data.
      {%{result | category: repo().get!(Category, result.category.uuid)}, logs}
    end

    case repo().transaction(copy) do
      {:ok, {%{category: category} = result, logs}} ->
        flush_logs(logs)

        if Keyword.get(opts, :broadcast, true) do
          PubSub.broadcast(:category, nil, category.catalogue_uuid)
          PubSub.broadcast(:item, nil, category.catalogue_uuid)
        end

        {:ok, result}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Copies a whole catalogue: the catalogue row plus every live category and
  item in it (see the moduledoc). The copy keeps the source's status and
  folder and is named "Name (copy)" — "Name (copy 2)" and so on while a
  live catalogue already has that name, since the shop finds its
  catalogue by name.

  One transaction, all or nothing, holding the source's trash/restore/move
  lock (about a second for a few thousand items): editors keep editing
  while it runs, and the copy is the source as it was when the copy read
  it — the items, then the tree, one read each, so nothing is copied
  twice or lands outside its category. An edit made after that read is
  simply not in the copy.
  Two copies of the same source at once are refused
  (`:already_duplicating`); a trashed or missing source is `:not_found`.

  Per-row activity is not written — one `catalogue.duplicated` row carries
  the counts. Options:

    * `:skus` — keep the items' SKUs (default `true`; `false` leaves them blank)
    * `:files` — link the images and files (default `true`; `false` gives
      the copies no files and no featured image)
    * `:suppliers` — copy the current supplier rows and purchase prices
      (default `true`)
    * `:archived` — start the copy archived instead of with the source's
      status (default `false`)
    * `:actor_uuid`, `:mode`, `:broadcast` — as elsewhere in the context
  """
  @spec duplicate_catalogue(CatalogueSchema.t(), keyword()) ::
          {:ok,
           %{
             catalogue: CatalogueSchema.t(),
             categories: non_neg_integer(),
             items: non_neg_integer()
           }}
          | {:error, term()}
  def duplicate_catalogue(%CatalogueSchema{} = source, opts \\ []) do
    case repo().transaction(fn -> copy_catalogue(source, opts) end, timeout: :infinity) do
      {:ok, %{catalogue: copy} = result} ->
        ActivityLog.log(%{
          action: "catalogue.duplicated",
          mode: opts[:mode] || "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "catalogue",
          resource_uuid: copy.uuid,
          metadata: %{
            "name" => copy.name,
            "source_uuid" => source.uuid,
            "categories" => result.categories,
            "items" => result.items,
            "without" =>
              for({key, false} <- Keyword.take(opts, @copy_choices), do: to_string(key)),
            "archived" => Keyword.get(opts, :archived, false)
          }
        })

        if Keyword.get(opts, :broadcast, true),
          do: PubSub.broadcast(:catalogue, copy.uuid, copy.uuid)

        {:ok, result}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  What `duplicate_catalogue/2` would copy right now: live categories and
  live items, for the confirmation.
  """
  @spec catalogue_copy_counts(Ecto.UUID.t()) :: %{
          categories: non_neg_integer(),
          items: non_neg_integer()
        }
  def catalogue_copy_counts(catalogue_uuid) do
    count = fn schema ->
      from(r in schema, where: r.catalogue_uuid == ^catalogue_uuid and r.status != "deleted")
      |> repo().aggregate(:count)
    end

    %{categories: count.(Category), items: count.(Item)}
  end

  defp copy_catalogue(source, opts) do
    claim_copy_of!(source.uuid)
    # Copies take the name lock before their source's lock, so a copy
    # queued behind another does not hold its own catalogue meanwhile.
    lock_copy_names!()
    # The source's trash/restore/move lock, to commit: none of those can
    # change what the copy reads while it runs (about a second). Plain
    # edits and creates do not take it and carry on.
    PhoenixKitCatalogue.Catalogue.lock_catalogue!(source.uuid)

    fresh =
      case repo().get(CatalogueSchema, source.uuid) do
        %CatalogueSchema{status: status} = fresh when status != "deleted" -> fresh
        _ -> repo().rollback(:not_found)
      end

    number = free_copy_number(fresh)

    # Row copies below write no activity of their own; their would-be log
    # entries still name each source and its copy, which the remap needs.
    nested =
      [
        suffix: false,
        keep_position: true,
        actor_uuid: opts[:actor_uuid],
        mode: opts[:mode] || "manual"
      ] ++ Keyword.take(opts, @copy_choices)

    copy = insert_catalogue_copy(fresh, Keyword.put(opts, :copy_number, number))
    nested = Keyword.put(nested, :catalogue_uuid, copy.uuid)

    # Items first, then the tree, one read each: every item read belongs
    # to a category that already existed, so the tree read after it holds
    # that category (the lock keeps trash and moves out of the gap). Each
    # item is copied once, under that category — or uncategorized when
    # its category is not a live one.
    live_items =
      from(i in Item,
        where: i.catalogue_uuid == ^fresh.uuid and i.status != "deleted",
        order_by: [asc: i.position, asc: i.name, asc: i.uuid]
      )
      |> repo().all()

    live_categories =
      from(c in Category,
        where: c.catalogue_uuid == ^fresh.uuid and c.status != "deleted",
        order_by: [asc: c.position, asc: c.name, asc: c.uuid]
      )
      |> repo().all()

    live_uuids = MapSet.new(live_categories, & &1.uuid)

    {filed, loose_items} =
      Enum.split_with(
        live_items,
        &(&1.category_uuid && MapSet.member?(live_uuids, &1.category_uuid))
      )

    snapshot = %{
      items: Enum.group_by(filed, & &1.category_uuid),
      children:
        live_categories
        |> Enum.filter(&(&1.parent_uuid && MapSet.member?(live_uuids, &1.parent_uuid)))
        |> Enum.group_by(& &1.parent_uuid)
    }

    nested = Keyword.put(nested, :snapshot, snapshot)

    # A live category under a trashed (or vanished) parent is a root here,
    # as the source's Active tab shows it at the top level.
    {categories, items, logs} =
      live_categories
      |> Enum.filter(&(is_nil(&1.parent_uuid) or not MapSet.member?(live_uuids, &1.parent_uuid)))
      |> Enum.reduce({0, 0, []}, fn root, {cats, its, logs} ->
        {%{categories: c, items: i}, root_logs} =
          copy_category(root, Keyword.put(nested, :parent_uuid, nil))

        {cats + 1 + c, its + i, root_logs ++ logs}
      end)

    {loose, loose_logs} = copy_loose_items(loose_items, nested)
    remap_copies!(copy_mapping([{fresh.uuid, copy.uuid}], loose_logs ++ logs))

    %{
      catalogue: repo().get!(CatalogueSchema, copy.uuid),
      categories: categories,
      items: items + loose
    }
  end

  # Transaction-scoped: released at commit or rollback. A second request
  # for the same source (a double click, a second tab) is refused instead
  # of producing a second full copy.
  defp claim_copy_of!(source_uuid) do
    %{rows: [[claimed?]]} =
      SQL.query!(repo(), "SELECT pg_try_advisory_xact_lock(hashtext($1))", [
        @copy_claim_prefix <> to_string(source_uuid)
      ])

    unless claimed?, do: repo().rollback(:already_duplicating)
    :ok
  end

  # Copies serialise on their own lock (held to commit), so two copies of
  # two same-named sources cannot both pick one name — without holding up
  # reorders or edits, which never take it.
  defp lock_copy_names! do
    SQL.query!(repo(), "SELECT pg_advisory_xact_lock(hashtext($1))", [@copy_names_lock])
    :ok
  end

  # The first free "(copy N)" among live catalogues, compared the way the
  # copy's name column will be written.
  defp free_copy_number(source) do
    taken =
      from(c in CatalogueSchema, where: c.status != "deleted", select: c.name)
      |> repo().all()
      |> MapSet.new()

    Enum.find(1..@max_copy_number, fn number ->
      not MapSet.member?(taken, column_copy_name(source, copy_number: number))
    end)
  end

  defp insert_catalogue_copy(source, opts) do
    attrs = %{
      name: column_copy_name(source, opts),
      description: source.description,
      kind: source.kind,
      markup_percentage: source.markup_percentage,
      discount_percentage: source.discount_percentage,
      status: if(Keyword.get(opts, :archived, false), do: "archived", else: source.status),
      position: source.position,
      folder_uuid: source.folder_uuid,
      data: copy_data(source.data, :catalogue, opts)
    }

    %CatalogueSchema{}
    |> CatalogueSchema.changeset(attrs)
    |> insert!()
    |> then(&copy_files_folder(source, &1, opts))
  end

  # Live items no copied category holds: uncategorized ones, and any whose
  # category is trashed or gone (they become uncategorized in the copy).
  defp copy_loose_items(items, nested) do
    Enum.reduce(items, {0, []}, fn item, {n, logs} ->
      {_copy, item_logs} = copy_item(item, Keyword.put(nested, :category_uuid, nil))
      {n + 1, item_logs ++ logs}
    end)
  end

  defp copy_mapping(pairs, logs) do
    Enum.reduce(logs, Map.new(pairs), fn
      %{resource_uuid: copy, metadata: %{"source_uuid" => source}}, acc ->
        Map.put(acc, source, copy)

      _, acc ->
        acc
    end)
  end

  # A string anywhere in a copied row's `data` that is the uuid of another
  # copied row names that row, so it is pointed at the copy — without
  # knowing whose namespace holds it. File uuids and anything outside the
  # copy are not in the map and stay as they are.
  defp remap_copies!(mapping) do
    copies = Map.values(mapping)

    for schema <- [CatalogueSchema, Category, Item] do
      remap_rows!(schema, from(r in schema, where: r.uuid in ^copies), mapping)
    end

    :ok
  end

  defp remap_rows!(schema, query, mapping) do
    query
    |> select([r], {r.uuid, r.data})
    |> repo().all()
    |> Enum.each(fn {uuid, data} ->
      remapped = remap_value(data, mapping)

      if remapped != data,
        do: repo().update_all(from(r in schema, where: r.uuid == ^uuid), set: [data: remapped])
    end)
  end

  defp remap_value(value, mapping) when is_binary(value), do: Map.get(mapping, value, value)

  defp remap_value(value, mapping) when is_list(value),
    do: Enum.map(value, &remap_value(&1, mapping))

  defp remap_value(value, mapping) when is_map(value),
    do: Map.new(value, fn {k, v} -> {k, remap_value(v, mapping)} end)

  defp remap_value(value, _mapping), do: value

  @doc """
  Copies several items; one transaction each, one `:item` batch event per
  catalogue. Pass `catalogue_uuid:` to refuse items outside that catalogue
  (`:wrong_catalogue_scope`) — the uuids are client-captured.
  """
  @spec bulk_duplicate_items([Ecto.UUID.t()], keyword()) :: bulk_result()
  def bulk_duplicate_items(uuids, opts \\ []) when is_list(uuids) do
    muted = Keyword.put(opts, :broadcast, false)

    {created, errors, catalogues} =
      uuids
      |> load_in_position_order(Item, opts)
      |> Enum.reduce({0, [], MapSet.new()}, fn
        {uuid, reason}, {n, errors, cats}
        when reason in [:invalid_uuid, :wrong_catalogue_scope] ->
          {n, [{uuid, reason} | errors], cats}

        {uuid, nil}, {n, errors, cats} ->
          {n, [{uuid, :not_found} | errors], cats}

        {uuid, item}, {n, errors, cats} ->
          case duplicate_item(item, muted) do
            {:ok, copy} -> {n + 1, errors, MapSet.put(cats, copy.catalogue_uuid)}
            {:error, reason} -> {n, [{uuid, normalize_error(reason)} | errors], cats}
          end
      end)

    log_bulk("item", created, catalogues, opts)

    if created > 0 and Keyword.get(opts, :broadcast, true),
      do: Enum.each(catalogues, &PubSub.broadcast(:item, nil, &1))

    {:ok, %{created: created, errors: Enum.reverse(errors)}}
  end

  @doc "Copies several categories (each with its subtree); one batch event per catalogue."
  @spec bulk_duplicate_categories([Ecto.UUID.t()], keyword()) :: bulk_result()
  def bulk_duplicate_categories(uuids, opts \\ []) when is_list(uuids) do
    muted = Keyword.put(opts, :broadcast, false)

    {created, errors, catalogues} =
      uuids
      |> load_in_position_order(Category, opts)
      |> Enum.reduce({0, [], MapSet.new()}, fn
        {uuid, reason}, {n, errors, cats}
        when reason in [:invalid_uuid, :wrong_catalogue_scope] ->
          {n, [{uuid, reason} | errors], cats}

        {uuid, nil}, {n, errors, cats} ->
          {n, [{uuid, :not_found} | errors], cats}

        {uuid, category}, {n, errors, cats} ->
          case duplicate_category(category, muted) do
            {:ok, %{category: copy}} -> {n + 1, errors, MapSet.put(cats, copy.catalogue_uuid)}
            {:error, reason} -> {n, [{uuid, normalize_error(reason)} | errors], cats}
          end
      end)

    log_bulk("category", created, catalogues, opts)

    if created > 0 and Keyword.get(opts, :broadcast, true) do
      Enum.each(catalogues, fn cat ->
        PubSub.broadcast(:category, nil, cat)
        PubSub.broadcast(:item, nil, cat)
      end)
    end

    {:ok, %{created: created, errors: Enum.reverse(errors)}}
  end

  # Activity rows are written AFTER the copy's transaction commits: core's
  # `Activity.log/1` inserts and broadcasts at once, so logging inside the
  # transaction would announce rows that may still roll back (and a failed
  # activity insert would abort the copy itself).
  defp flush_logs(logs), do: Enum.each(logs, &ActivityLog.log/1)

  # One summary row per bulk run, like `item.bulk_trashed`.
  defp log_bulk(_type, 0, _catalogues, _opts), do: :ok

  defp log_bulk(type, created, catalogues, opts) do
    ActivityLog.log(%{
      action: "#{type}.bulk_duplicated",
      mode: opts[:mode] || "manual",
      actor_uuid: opts[:actor_uuid],
      resource_type: type,
      metadata: %{"count" => created, "catalogue_uuids" => MapSet.to_list(catalogues)}
    })
  end

  # Bulk callers count and log errors; a changeset or a tagged tuple is
  # collapsed to one atom so the error list has one shape.
  defp normalize_error(%Ecto.Changeset{}), do: :invalid
  defp normalize_error({:files_folder, _}), do: :files_folder
  defp normalize_error(reason) when is_atom(reason), do: reason
  defp normalize_error(_), do: :failed

  # Sources are copied lowest position first so several copies inside
  # one sibling list land in the same order as their originals. The
  # uuids are client-captured: a malformed one must surface as an error
  # for that entry, not as a query cast crash for the whole batch.
  # `opts[:catalogue_uuid]` scopes the batch: a row from another
  # catalogue is reported as `:wrong_catalogue_scope`, never copied.
  defp load_in_position_order(uuids, schema, opts) do
    uuids = Enum.uniq(uuids)
    scope = opts[:catalogue_uuid]
    {valid, invalid} = Enum.split_with(uuids, &match?({:ok, _}, Ecto.UUID.cast(&1)))
    rows = repo().all(from(r in schema, where: r.uuid in ^valid)) |> Map.new(&{&1.uuid, &1})

    sorted =
      valid
      |> Enum.map(fn uuid ->
        case Map.get(rows, uuid) do
          %{catalogue_uuid: c} when is_binary(scope) and c != scope ->
            {uuid, :wrong_catalogue_scope}

          row ->
            {uuid, row}
        end
      end)
      |> Enum.sort_by(fn
        {_, %{position: position, name: name}} -> {0, position, name}
        _ -> {1, 0, ""}
      end)

    sorted ++ Enum.map(invalid, &{&1, :invalid_uuid})
  end

  # ── Item ──────────────────────────────────────────────────────────

  # Runs inside the caller's transaction; any failure rolls it back.
  defp copy_item(%Item{} = source, opts) do
    category_uuid = Keyword.get(opts, :category_uuid, source.category_uuid)

    catalogue_uuid =
      catalogue_for(category_uuid, Keyword.get(opts, :catalogue_uuid, source.catalogue_uuid))

    keep_position? = Keyword.get(opts, :keep_position, false)

    attrs =
      source
      |> Map.take(@item_fields)
      |> Map.merge(%{
        name: column_copy_name(source, opts),
        sku: if(Keyword.get(opts, :skus, true), do: source.sku),
        catalogue_uuid: catalogue_uuid,
        category_uuid: category_uuid,
        position: source.position,
        data: copy_data(source.data, :item, opts)
      })

    item = insert!(%Item{} |> Item.changeset(attrs))

    copy_attribute_sets(source, item)
    copy_attribute_group(source, item)
    if Keyword.get(opts, :suppliers, true), do: copy_supplier_rows(source, item)
    copy_rules(source, item)
    item = copy_files_folder(source, item, opts)

    unless keep_position?, do: place_item_after(source, item)

    log = %{
      action: "item.duplicated",
      mode: opts[:mode] || "manual",
      actor_uuid: opts[:actor_uuid],
      resource_type: "item",
      resource_uuid: item.uuid,
      metadata: %{
        "name" => item.name,
        "sku" => item.sku || "",
        "source_uuid" => source.uuid,
        "catalogue_uuid" => item.catalogue_uuid
      }
    }

    {repo().get!(Item, item.uuid), [log]}
  end

  defp catalogue_for(nil, fallback), do: fallback

  # `FOR SHARE` until commit, as `create_item/2` does: a concurrent
  # `move_category_to_catalogue/3` takes `FOR UPDATE` on this row, so
  # the copy can never land with a stale `catalogue_uuid`.
  defp catalogue_for(category_uuid, fallback) do
    from(c in Category, where: c.uuid == ^category_uuid, lock: "FOR SHARE")
    |> repo().one()
    |> case do
      nil -> repo().rollback(:category_not_found)
      # A live copy in a trashed category would be hidden from the tree.
      %Category{status: "deleted"} -> repo().rollback(:category_not_found)
      %Category{catalogue_uuid: uuid} -> uuid || fallback
    end
  end

  @name_max 255

  defp copy_name(nil, _opts), do: nil

  # Names are capped at 255 by the schemas; a long original is trimmed
  # so the suffix still fits rather than failing validation.
  defp copy_name(name, opts) do
    if Keyword.get(opts, :suffix, true) do
      number = Keyword.get(opts, :copy_number, 1)
      suffixed = suffixed_name(name, number)
      overflow = String.length(suffixed) - @name_max

      if overflow > 0,
        do: suffixed_name(String.slice(name, 0, String.length(name) - overflow), number),
        else: suffixed
    else
      name
    end
  end

  # "Alpha (copy)" for the first copy, "Alpha (copy 2)" once that is taken.
  defp suffixed_name(name, number) when number in [nil, 1],
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "%{name} (copy)", name: name)

  defp suffixed_name(name, number),
    do:
      Gettext.gettext(PhoenixKitCatalogue.Gettext, "%{name} (copy %{number})",
        name: name,
        number: number
      )

  # Lists show the translated name out of the multilang `data`, not the
  # column, so the suffix has to reach every language entry too — the
  # primary language stores all fields under `"name"`, overrides store
  # `"_name"`. Other top-level keys (custom fields, pointers) are copied
  # untouched, apart from the folder pointer.
  @language_key ~r/^[a-z]{2,3}(-[A-Za-z]{2,4})?$/

  defp copy_data(data, kind, opts) do
    owned = Extensions.owned_keys()

    data =
      (data || %{})
      |> Map.drop(@data_keys_not_copied)
      |> then(&if(Keyword.get(opts, :files, true), do: &1, else: Map.drop(&1, @image_keys)))
      |> then(&if(kind == :catalogue, do: &1, else: Extensions.duplicate_data(kind, &1)))

    if Keyword.get(opts, :suffix, true),
      do: Map.new(data, &suffix_language_entry(&1, owned, opts)),
      else: data
  end

  # The name column holds the content in its primary language, so the
  # suffix is in that language — not the admin's, and not the default a
  # background task would fall back to (review finding).
  defp column_copy_name(source, opts) do
    locale = gettext_locale(primary_language(source.data))

    Gettext.with_locale(PhoenixKitCatalogue.Gettext, locale, fn ->
      copy_name(source.name, opts)
    end)
  end

  defp primary_language(data) do
    case data do
      %{"_primary_language" => lang} when is_binary(lang) and lang != "" -> lang
      _ -> Multilang.primary_language()
    end
  end

  # Each language entry gets the suffix in ITS language ("(koopia)" for
  # et, "(копия)" for ru), not the acting admin's (review finding).
  # An extension's namespace can look like a language code ("crm"); it is
  # never one.
  defp suffix_language_entry({lang, %{} = entry}, owned, opts) do
    if Regex.match?(@language_key, lang) and lang not in owned do
      {lang,
       Gettext.with_locale(PhoenixKitCatalogue.Gettext, gettext_locale(lang), fn ->
         suffix_names(entry, opts)
       end)}
    else
      {lang, entry}
    end
  end

  defp suffix_language_entry(pair, _owned, _opts), do: pair

  # "et", "en-US" → the base language when the backend knows it, else the
  # msgid (English) fallback.
  defp gettext_locale(lang) do
    base = lang |> String.split("-") |> hd()
    if base in Gettext.known_locales(PhoenixKitCatalogue.Gettext), do: base, else: "en"
  end

  defp suffix_names(entry, opts) do
    Enum.reduce(["name", "_name"], entry, fn key, acc ->
      case Map.get(acc, key) do
        name when is_binary(name) and name != "" -> Map.put(acc, key, copy_name(name, opts))
        _ -> acc
      end
    end)
  end

  defp copy_attribute_sets(source, item) do
    from(a in ItemAttributeSet, where: a.item_uuid == ^source.uuid)
    |> repo().all()
    |> Enum.each(fn a ->
      insert!(
        ItemAttributeSet.changeset(%ItemAttributeSet{}, %{
          item_uuid: item.uuid,
          set_uuid: a.set_uuid,
          position: a.position,
          data: a.data
        })
      )
    end)
  end

  defp copy_attribute_group(source, item) do
    case repo().get_by(ItemAttributeGroup, item_uuid: source.uuid) do
      nil ->
        :ok

      g ->
        insert!(
          ItemAttributeGroup.changeset(%ItemAttributeGroup{}, %{
            item_uuid: item.uuid,
            attribute_group_uuid: g.attribute_group_uuid,
            position: g.position
          })
        )
    end
  end

  # Only the CURRENT row per supplier (closed revisions are the source's
  # price history, not the copy's). The stored thread key is dropped and
  # the copy's own pair thread stamped (`thread_for_pair/2` — the copy is a
  # new item, so it is a new thread), so the two items never share
  # supplier comments.
  defp copy_supplier_rows(source, item) do
    from(i in ItemSupplierInfo, where: i.item_uuid == ^source.uuid and is_nil(i.valid_to))
    |> repo().all()
    |> Enum.each(fn row ->
      attrs =
        row
        |> Map.take(@supplier_fields)
        |> Map.merge(%{
          item_uuid: item.uuid,
          metadata: Map.delete(row.metadata || %{}, SupplierComments.thread_key())
        })

      %ItemSupplierInfo{}
      |> ItemSupplierInfo.changeset(attrs)
      |> SupplierComments.stamp_changeset(
        SupplierComments.thread_for_pair(item.uuid, row.supplier_uuid) || UUIDv7.generate()
      )
      |> insert!()
    end)
  end

  defp copy_rules(source, item) do
    from(r in CatalogueRule, where: r.item_uuid == ^source.uuid)
    |> repo().all()
    |> Enum.each(fn r ->
      insert!(
        CatalogueRule.changeset(%CatalogueRule{}, %{
          item_uuid: item.uuid,
          referenced_catalogue_uuid: r.referenced_catalogue_uuid,
          value: r.value,
          unit: r.unit,
          position: r.position
        })
      )
    end)
  end

  # ── Files ─────────────────────────────────────────────────────────

  # The source's folder is the stored pointer or, for resources saved
  # before the pointer existed, the deterministic folder name the form
  # uses. No folder or no files → the copy gets none (the form creates
  # one lazily on first upload). With files → a new folder holding a
  # FolderLink to each, so the copy shows the same files without owning
  # them.
  defp copy_files_folder(source, record, opts) do
    if Keyword.get(opts, :files, true),
      do: link_files_folder(source, record, opts),
      else: record
  end

  defp link_files_folder(source, record, opts) do
    files =
      case source_folder_uuid(source, opts) do
        nil -> []
        folder_uuid -> list_files(folder_uuid)
      end

    if files == [] do
      record
    else
      folder = create_folder!(record, opts)
      Enum.each(files, &link_file!(folder, &1))
      put_folder_pointer!(record, folder)
    end
  end

  defp link_file!(folder, file) do
    %FolderLink{}
    |> FolderLink.changeset(%{folder_uuid: folder.uuid, file_uuid: file.uuid})
    |> repo().insert(on_conflict: :nothing)
    |> case do
      {:ok, _} -> :ok
      {:error, changeset} -> repo().rollback({:files_folder, changeset})
    end
  end

  defp put_folder_pointer!(record, folder) do
    data = Map.put(record.data || %{}, "files_folder_uuid", folder.uuid)

    record
    |> Ecto.Changeset.change(data: data)
    |> repo().update()
    |> case do
      {:ok, updated} -> updated
      {:error, changeset} -> repo().rollback(changeset)
    end
  end

  # Pointer FIRST (the host may have renamed the folder, so a name-only lookup would miss it),
  # then the module's name-based resolution.
  defp source_folder_uuid(%{data: data} = source, opts) do
    case data && data["files_folder_uuid"] do
      uuid when is_binary(uuid) ->
        uuid

      _ ->
        case PhoenixKitCatalogue.Attachments.find_resource_folder(source, opts[:actor_uuid]) do
          %{uuid: uuid} -> uuid
          nil -> nil
        end
    end
  end

  # The same set every other reader shows — home files plus linked ones
  # — but UNCAPPED: a copy must carry every file, not the grid's page.
  defp list_files(folder_uuid) do
    folder_uuid
    |> PhoenixKitCatalogue.Attachments.folder_files_query()
    |> order_by([f], asc: f.inserted_at, asc: f.uuid)
    |> repo().all()
  end

  defp create_folder!(record, opts) do
    attrs = %{
      name: PhoenixKitCatalogue.Attachments.folder_name(record, opts[:actor_uuid]),
      parent_uuid: PhoenixKitCatalogue.Attachments.parent_folder_uuid(record, opts[:actor_uuid])
    }

    attrs = if opts[:actor_uuid], do: Map.put(attrs, :user_uuid, opts[:actor_uuid]), else: attrs

    case Storage.create_folder(attrs) do
      {:ok, folder} -> folder
      {:error, reason} -> repo().rollback({:files_folder, reason})
    end
  end

  # ── Category ──────────────────────────────────────────────────────

  defp copy_category(%Category{} = source, opts) do
    parent_uuid = Keyword.get(opts, :parent_uuid, source.parent_uuid)
    catalogue_uuid = Keyword.get(opts, :catalogue_uuid, source.catalogue_uuid)
    ensure_same_catalogue!(parent_uuid, catalogue_uuid)
    keep_position? = Keyword.get(opts, :keep_position, false)

    attrs = %{
      name: column_copy_name(source, opts),
      description: source.description,
      status: source.status,
      position: source.position,
      catalogue_uuid: catalogue_uuid,
      parent_uuid: parent_uuid,
      data: copy_data(source.data, :category, opts)
    }

    category = insert!(%Category{} |> Category.changeset(attrs))
    category = copy_files_folder(source, category, opts)

    nested =
      [
        suffix: false,
        keep_position: true,
        catalogue_uuid: catalogue_uuid,
        snapshot: opts[:snapshot],
        actor_uuid: opts[:actor_uuid],
        mode: opts[:mode] || "manual"
      ] ++ Keyword.take(opts, @copy_choices)

    {items, item_logs} =
      source
      |> live_items_of(opts[:snapshot])
      |> Enum.reduce({0, []}, fn item, {n, logs} ->
        {_copy, item_logs} = copy_item(item, Keyword.put(nested, :category_uuid, category.uuid))
        {n + 1, [item_logs | logs]}
      end)

    {sub_categories, sub_items, child_logs} =
      source
      |> live_children_of(opts[:snapshot])
      |> Enum.reduce({0, 0, []}, fn child, {cats, its, logs} ->
        {%{categories: c, items: i}, child_logs} =
          copy_category(child, Keyword.put(nested, :parent_uuid, category.uuid))

        {cats + 1 + c, its + i, [child_logs | logs]}
      end)

    unless keep_position?, do: place_category_after(source, category)

    log = %{
      action: "category.duplicated",
      mode: opts[:mode] || "manual",
      actor_uuid: opts[:actor_uuid],
      resource_type: "category",
      resource_uuid: category.uuid,
      metadata: %{
        "name" => category.name,
        "source_uuid" => source.uuid,
        "catalogue_uuid" => category.catalogue_uuid,
        "categories" => sub_categories,
        "items" => items + sub_items
      }
    }

    {%{
       category: repo().get!(Category, category.uuid),
       categories: sub_categories,
       items: items + sub_items
     }, [log | in_order(item_logs) ++ in_order(child_logs)]}
  end

  # Log lists are gathered newest-first (appending each one copied the
  # whole list so far, quadratic on a large category).
  defp in_order(nested_logs), do: nested_logs |> Enum.reverse() |> List.flatten()

  # A whole-catalogue copy reads the tree and the items once, up front
  # (`:snapshot`), so an item moved between two categories while the copy
  # runs is copied once, not twice (review finding); a single category
  # copy reads them as it walks.
  defp live_items_of(source, %{items: by_category}), do: Map.get(by_category, source.uuid, [])

  defp live_items_of(source, nil) do
    from(i in Item,
      where: i.category_uuid == ^source.uuid and i.status != "deleted",
      order_by: [asc: i.position, asc: i.name]
    )
    |> repo().all()
  end

  defp live_children_of(source, %{children: by_parent}), do: Map.get(by_parent, source.uuid, [])

  defp live_children_of(source, nil) do
    from(c in Category,
      where: c.parent_uuid == ^source.uuid and c.status != "deleted",
      order_by: [asc: c.position, asc: c.name]
    )
    |> repo().all()
  end

  # A copy always stays in its source's catalogue; a parent from another
  # catalogue would leave the subtree unreachable through the tree.
  # `FOR SHARE` until commit, as `catalogue_for/2` does: a concurrent
  # `move_category_to_catalogue/3` takes `FOR UPDATE` on this row, so the
  # copy cannot land under a parent that just changed catalogues.
  defp ensure_same_catalogue!(nil, _catalogue_uuid), do: :ok

  defp ensure_same_catalogue!(parent_uuid, catalogue_uuid) do
    from(c in Category, where: c.uuid == ^parent_uuid, lock: "FOR SHARE")
    |> repo().one()
    |> case do
      %Category{catalogue_uuid: ^catalogue_uuid} -> :ok
      nil -> repo().rollback(:parent_not_found)
      _ -> repo().rollback(:cross_catalogue)
    end
  end

  # ── Placement ─────────────────────────────────────────────────────

  # Renumber the copy's sibling list with the copy right after its
  # source (appended when the source is not a sibling — a copy sent to
  # another category). Positions are written 0..n like the reorder path.
  defp place_item_after(source, item) do
    lock_sibling_scope("items", item.catalogue_uuid, item.category_uuid)

    siblings =
      from(i in Item,
        where:
          i.catalogue_uuid == ^item.catalogue_uuid and i.status != "deleted" and
            i.uuid != ^item.uuid,
        order_by: [asc: i.position, asc: i.name],
        select: i.uuid
      )
      |> scope_category(item.category_uuid)
      |> repo().all()

    renumber(Item, insert_after(siblings, source.uuid, item.uuid))
  end

  defp place_category_after(source, category) do
    lock_sibling_scope("categories", category.catalogue_uuid, category.parent_uuid)

    siblings =
      from(c in Category,
        where:
          c.catalogue_uuid == ^category.catalogue_uuid and c.status != "deleted" and
            c.uuid != ^category.uuid,
        order_by: [asc: c.position, asc: c.name],
        select: c.uuid
      )
      |> scope_parent(category.parent_uuid)
      |> repo().all()

    renumber(Category, insert_after(siblings, source.uuid, category.uuid))
  end

  # Two copies into the same sibling list at once would both read the
  # same order and renumber over each other; a transaction-scoped
  # advisory lock on the scope serialises them (released at commit).
  defp lock_sibling_scope(kind, catalogue_uuid, parent_uuid) do
    key = "catalogue:#{kind}:#{catalogue_uuid}:#{parent_uuid || "root"}"
    SQL.query!(repo(), "SELECT pg_advisory_xact_lock(hashtext($1))", [key])
    :ok
  end

  defp scope_category(query, nil), do: where(query, [i], is_nil(i.category_uuid))
  defp scope_category(query, uuid), do: where(query, [i], i.category_uuid == ^uuid)
  defp scope_parent(query, nil), do: where(query, [c], is_nil(c.parent_uuid))
  defp scope_parent(query, uuid), do: where(query, [c], c.parent_uuid == ^uuid)

  defp insert_after(list, anchor, new) do
    case Enum.find_index(list, &(&1 == anchor)) do
      nil -> list ++ [new]
      idx -> List.insert_at(list, idx + 1, new)
    end
  end

  # 1-based, the convention the reorder path writes.
  defp renumber(schema, ordered_uuids) do
    ordered_uuids
    |> Enum.with_index(1)
    |> Enum.each(fn {uuid, idx} ->
      repo().update_all(from(r in schema, where: r.uuid == ^uuid), set: [position: idx])
    end)
  end

  defp insert!(changeset) do
    case repo().insert(changeset) do
      {:ok, record} -> record
      {:error, changeset} -> repo().rollback(changeset)
    end
  end
end
