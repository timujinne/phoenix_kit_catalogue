defmodule PhoenixKitCatalogue.Catalogue do
  @moduledoc """
  Context module for managing catalogues, manufacturers, suppliers, categories, and items.

  ## Soft-Delete System

  Catalogues, categories, and items support soft-delete via a `status` field set to `"deleted"`.
  Manufacturers and suppliers use hard-delete only (they are reference data).

  ### Cascade behaviour

  **Downward cascade on trash/permanently_delete:**
  - Trashing a catalogue → trashes all its categories and their items
  - Trashing a category → trashes all its items
  - Permanently deleting follows the same cascade but removes from DB

  **Upward cascade on restore:**
  - Restoring an item → restores its parent category if deleted
  - Restoring a category → restores its parent catalogue if deleted, plus all items

  All cascading operations are wrapped in database transactions.

  ## Usage from IEx

      alias PhoenixKitCatalogue.Catalogue

      # Create a full hierarchy
      {:ok, cat} = Catalogue.create_catalogue(%{name: "Kitchen"})
      {:ok, category} = Catalogue.create_category(%{name: "Frames", catalogue_uuid: cat.uuid})
      {:ok, item} = Catalogue.create_item(%{name: "Oak Panel", category_uuid: category.uuid, base_price: 25.50})

      # Soft-delete and restore
      {:ok, _} = Catalogue.trash_catalogue(cat)   # cascades to category + item
      {:ok, _} = Catalogue.restore_catalogue(cat)  # cascades back

      # Move operations
      {:ok, _} = Catalogue.move_category_to_catalogue(category, other_catalogue_uuid)
      {:ok, _} = Catalogue.move_item_to_category(item, other_category_uuid)

  ## Smart catalogues

  For an end-to-end walkthrough of integrating smart catalogues
  (`kind: "smart"` items priced as functions of other catalogues), see
  the [Smart Catalogues guide](smart_catalogues.md).
  """

  import Ecto.Query, warn: false

  alias PhoenixKitCatalogue.Catalogue.{
    ActivityLog,
    Counts,
    Helpers,
    Links,
    Manufacturers,
    PdfLibrary,
    PubSub,
    Rules,
    Search,
    SmartPricing,
    Suppliers,
    Translations,
    Tree
  }

  alias PhoenixKitCatalogue.Schemas.{Catalogue, Category, Item}

  require Logger

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # `log_activity/1` was extracted to `PhoenixKitCatalogue.Catalogue.ActivityLog`
  # so the per-section submodules can share it without circular imports.
  # Internal callers in the remaining sections still use this thin
  # alias for diff churn minimization.
  # `log_activity/1` writes an audit-log entry **and** fans out a
  # `{:catalogue_data_changed, kind, uuid, parent_catalogue_uuid}` event
  # so list LVs subscribed via `PubSub.subscribe/0` re-fetch. The two are
  # coupled here because every write in this module that's worth auditing
  # is also worth signalling — keeping them paired prevents accidental
  # "I logged but forgot to broadcast" drift. Submodules under
  # `PhoenixKitCatalogue.Catalogue.*` call `ActivityLog.log/1` and
  # `PubSub.broadcast/3` directly to keep their dependencies explicit.
  #
  # The optional `parent_catalogue_uuid` field on `attrs` is used purely
  # for PubSub routing (it's stripped before the activity entry is
  # persisted). Bulk callers can pass `broadcast: false` in the second
  # argument to suppress the per-row fan-out and emit a single roll-up
  # broadcast at the end of the batch.
  defp log_activity(attrs, opts \\ []) do
    {parent_catalogue_uuid, attrs} = Map.pop(attrs, :parent_catalogue_uuid)

    ActivityLog.log(attrs)

    if Keyword.get(opts, :broadcast, true) do
      broadcast_for(attrs, parent_catalogue_uuid)
    end

    :ok
  end

  defp broadcast_for(%{resource_type: "catalogue", resource_uuid: uuid}, _parent),
    do: PubSub.broadcast(:catalogue, uuid, uuid)

  defp broadcast_for(%{resource_type: "category", resource_uuid: uuid}, parent),
    do: PubSub.broadcast(:category, uuid, parent || lookup_parent(:category, uuid))

  defp broadcast_for(%{resource_type: "item", resource_uuid: uuid}, parent),
    do: PubSub.broadcast(:item, uuid, parent || lookup_parent(:item, uuid))

  # Manufacturer/supplier/smart_rule activity rows never reach this
  # helper today — `Manufacturers`, `Suppliers`, and `Rules` call
  # `PubSub.broadcast/3` directly and bypass `log_activity`. Anything
  # else falls through to `:ok` so adding a new resource type doesn't
  # crash the audit-log path before its broadcast clause is wired up.
  defp broadcast_for(_attrs, _parent), do: :ok

  # Fallback: when a caller doesn't thread `parent_catalogue_uuid:` into
  # the activity-log attrs, look it up here so detail LVs can still
  # filter cross-catalogue noise. One indexed pkey lookup per broadcast
  # — adds ~ms to mutations on the rare path where the parent isn't
  # already in scope. High-frequency callers (smart-rules sync, item
  # CRUD) should thread it explicitly to avoid the lookup.
  defp lookup_parent(:category, uuid) when is_binary(uuid) do
    case repo().one(from(c in Category, where: c.uuid == ^uuid, select: c.catalogue_uuid)) do
      nil -> nil
      parent_uuid -> parent_uuid
    end
  end

  defp lookup_parent(:item, uuid) when is_binary(uuid) do
    Helpers.item_catalogue_uuid(uuid)
  end

  defp lookup_parent(_kind, _uuid), do: nil

  # Same cap reasoning as entities — even a workspace with hundreds of
  # catalogues, categories, or items per group never paints a thousand
  # at once. Beyond this we'd want an explicit batched API rather than
  # an unbounded transaction. Resolved at compile time so the literal
  # is available inside `when length(x) > @reorder_max_uuids` guards.
  # Single source of truth shared with `Catalogue.Rules` via
  # `config :phoenix_kit_catalogue, :reorder_max_uuids, N`.
  @reorder_max_uuids Application.compile_env(
                       :phoenix_kit_catalogue,
                       :reorder_max_uuids,
                       1000
                     )

  # Reorder logging helpers shared by `reorder_catalogues/2`,
  # `reorder_categories/4`, and `reorder_items/4`.
  # `log_reorder_rejected/5` and `log_reorder_db_error/5` cover the
  # audit-trail gap on early rejection (`:too_many_uuids`,
  # `:not_siblings`, `:wrong_scope`) and post-transaction failure.
  # `db_pending: true` lets audit consumers tell rejected/failed rows
  # apart from successful ones.
  #
  # All logging helpers run **outside** the database transaction, so
  # callers that wrap a reorder in an outer transaction (e.g.
  # `move_item_and_reorder_destination/4`) can rely on the rejection
  # row landing even when the outer rolls back.

  defp log_reorder_rejected(kind, reason, count, parent_catalogue_uuid, opts) do
    ActivityLog.log(
      Map.merge(
        %{
          action: reorder_action_for(kind),
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: to_string(kind),
          metadata: %{
            "count" => count,
            "db_pending" => true,
            "rejected" => to_string(reason)
          }
        },
        if(parent_catalogue_uuid,
          do: %{parent_catalogue_uuid: parent_catalogue_uuid},
          else: %{}
        )
      )
    )
  end

  defp log_reorder_db_error(kind, ordered_uuids, parent_catalogue_uuid, opts, extras \\ []) do
    metadata =
      %{
        "count" => length(ordered_uuids),
        "db_pending" => true
      }
      |> maybe_put_metadata("category_uuid", Keyword.get(extras, :category_uuid))

    ActivityLog.log(
      Map.merge(
        %{
          action: reorder_action_for(kind),
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: to_string(kind),
          resource_uuid: List.first(ordered_uuids),
          metadata: metadata
        },
        if(parent_catalogue_uuid,
          do: %{parent_catalogue_uuid: parent_catalogue_uuid},
          else: %{}
        )
      )
    )
  end

  defp reorder_action_for(:catalogue), do: "catalogue.reordered"
  defp reorder_action_for(:category), do: "category.reordered"
  defp reorder_action_for(:item), do: "item.reordered"

  defp maybe_put_metadata(map, _key, nil), do: map
  defp maybe_put_metadata(map, key, value), do: Map.put(map, key, value)

  # Auto-assigns a position to a new catalogue when the caller hasn't
  # supplied one — places the new row at the end of the manual-order
  # list. Existing tests / callers that pass `:position` keep control.
  defp maybe_put_catalogue_position(attrs) when is_map(attrs) do
    if Helpers.has_attr?(attrs, :position) do
      attrs
    else
      Helpers.put_attr(attrs, :position, next_catalogue_position())
    end
  end

  # Same idea for items, scoped by `(catalogue_uuid, category_uuid)`.
  # Only fires when both scope fields are already in attrs — otherwise
  # we don't have enough information to compute the next position, so
  # we leave it at the schema default (0).
  defp maybe_put_item_position(attrs) when is_map(attrs) do
    cond do
      Helpers.has_attr?(attrs, :position) ->
        attrs

      Helpers.has_attr?(attrs, :catalogue_uuid) ->
        catalogue_uuid = Helpers.fetch_attr(attrs, :catalogue_uuid)

        category_uuid =
          if Helpers.has_attr?(attrs, :category_uuid),
            do: attrs |> Helpers.fetch_attr(:category_uuid) |> blank_to_nil(),
            else: nil

        if is_binary(catalogue_uuid) do
          Helpers.put_attr(attrs, :position, next_item_position(catalogue_uuid, category_uuid))
        else
          attrs
        end

      true ->
        attrs
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Manufacturers — see PhoenixKitCatalogue.Catalogue.Manufacturers
  # ═══════════════════════════════════════════════════════════════════

  defdelegate list_manufacturers(opts \\ []), to: Manufacturers
  defdelegate get_manufacturer(uuid), to: Manufacturers
  defdelegate get_manufacturer!(uuid), to: Manufacturers
  defdelegate create_manufacturer(attrs, opts \\ []), to: Manufacturers
  defdelegate update_manufacturer(manufacturer, attrs, opts \\ []), to: Manufacturers
  defdelegate delete_manufacturer(manufacturer, opts \\ []), to: Manufacturers
  defdelegate change_manufacturer(manufacturer, attrs \\ %{}), to: Manufacturers

  # ═══════════════════════════════════════════════════════════════════
  # Suppliers — see PhoenixKitCatalogue.Catalogue.Suppliers
  # ═══════════════════════════════════════════════════════════════════

  defdelegate list_suppliers(opts \\ []), to: Suppliers
  defdelegate get_supplier(uuid), to: Suppliers
  defdelegate get_supplier!(uuid), to: Suppliers
  defdelegate create_supplier(attrs, opts \\ []), to: Suppliers
  defdelegate update_supplier(supplier, attrs, opts \\ []), to: Suppliers
  defdelegate delete_supplier(supplier, opts \\ []), to: Suppliers
  defdelegate change_supplier(supplier, attrs \\ %{}), to: Suppliers

  # ═══════════════════════════════════════════════════════════════════
  # Manufacturer ↔ Supplier links — see PhoenixKitCatalogue.Catalogue.Links
  # ═══════════════════════════════════════════════════════════════════

  defdelegate link_manufacturer_supplier(manufacturer_uuid, supplier_uuid), to: Links
  defdelegate unlink_manufacturer_supplier(manufacturer_uuid, supplier_uuid), to: Links
  defdelegate list_suppliers_for_manufacturer(manufacturer_uuid), to: Links
  defdelegate list_manufacturers_for_supplier(supplier_uuid), to: Links
  defdelegate linked_supplier_uuids(manufacturer_uuid), to: Links
  defdelegate linked_manufacturer_uuids(supplier_uuid), to: Links

  defdelegate sync_manufacturer_suppliers(manufacturer_uuid, supplier_uuids, opts \\ []),
    to: Links

  defdelegate sync_supplier_manufacturers(supplier_uuid, manufacturer_uuids, opts \\ []),
    to: Links

  # ═══════════════════════════════════════════════════════════════════
  # Catalogues
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Lists catalogues, ordered by name. Excludes deleted by default.

  ## Options

    * `:status` — when provided, returns only catalogues with this exact status
      (e.g. `"active"`, `"archived"`, `"deleted"`).
      When nil (default), returns all non-deleted catalogues.
    * `:kind` — when provided, filters to a specific kind (`:standard`, `:smart`,
      or their string equivalents). When nil (default), returns all kinds.

  ## Examples

      Catalogue.list_catalogues()                     # active + archived
      Catalogue.list_catalogues(status: "deleted")    # only deleted
      Catalogue.list_catalogues(status: "active")     # only active
      Catalogue.list_catalogues(kind: :smart)         # only smart catalogues
      Catalogue.list_catalogues(kind: :standard)      # only standard catalogues
  """
  @spec list_catalogues(keyword()) :: [Catalogue.t()]
  def list_catalogues(opts \\ []) do
    query = from(c in Catalogue, order_by: [asc: c.position, asc: c.name])

    query =
      case Keyword.get(opts, :status) do
        nil -> where(query, [c], c.status != "deleted")
        status -> where(query, [c], c.status == ^status)
      end

    query =
      case Keyword.get(opts, :kind) do
        nil -> query
        kind -> where(query, [c], c.kind == ^to_string(kind))
      end

    repo().all(query)
  end

  @doc """
  Lists catalogues whose name starts with `prefix`, case-insensitive.

  Anchored at the start of the name — this is a *prefix* match
  (`name ILIKE 'prefix%'`), not a contains match. LIKE metacharacters
  (`%`, `_`) in the prefix are escaped.

  Excludes deleted catalogues by default. Useful for narrowing a search
  scope: pair with `search_items/2`'s `:catalogue_uuids` to search only
  the matched catalogues.

  ## Options

    * `:status` — when provided, returns only catalogues with this exact status.
      Defaults to non-deleted (active + archived).
    * `:limit` — max results (no limit by default).

  ## Examples

      Catalogue.list_catalogues_by_name_prefix("Kit")
      #=> [%Catalogue{name: "Kitchen Furniture"}, %Catalogue{name: "Kits"}]

      Catalogue.list_catalogues_by_name_prefix("Kit", limit: 5)
      Catalogue.list_catalogues_by_name_prefix("", limit: 10)  # returns first 10

      # Compose with search
      uuids =
        "Kit"
        |> Catalogue.list_catalogues_by_name_prefix()
        |> Enum.map(& &1.uuid)

      Catalogue.search_items("oak", catalogue_uuids: uuids)
  """
  @spec list_catalogues_by_name_prefix(String.t(), keyword()) :: [Catalogue.t()]
  def list_catalogues_by_name_prefix(prefix, opts \\ []) when is_binary(prefix) do
    pattern = "#{Helpers.sanitize_like(prefix)}%"

    query =
      from(c in Catalogue,
        where: ilike(c.name, ^pattern),
        order_by: [asc: :name]
      )

    query =
      case Keyword.get(opts, :status) do
        nil -> where(query, [c], c.status != "deleted")
        status -> where(query, [c], c.status == ^status)
      end

    query =
      case Keyword.get(opts, :limit) do
        nil -> query
        lim -> limit(query, ^lim)
      end

    repo().all(query)
  end

  @doc "Returns the count of soft-deleted catalogues."
  @spec deleted_catalogue_count() :: non_neg_integer()
  def deleted_catalogue_count do
    from(c in Catalogue, where: c.status == "deleted")
    |> repo().aggregate(:count)
  end

  @doc "Fetches a catalogue by UUID without preloads. Returns `nil` if not found."
  @spec get_catalogue(Ecto.UUID.t()) :: Catalogue.t() | nil
  def get_catalogue(uuid), do: repo().get(Catalogue, uuid)

  @doc """
  Fetches a catalogue by UUID without preloading categories or items.
  Raises `Ecto.NoResultsError` if not found. Prefer this over
  `get_catalogue!/2` in read paths that don't need the nested preloads
  (e.g. the infinite-scroll detail view, which pages categories and
  items separately).
  """
  @spec fetch_catalogue!(Ecto.UUID.t()) :: Catalogue.t()
  def fetch_catalogue!(uuid), do: repo().get!(Catalogue, uuid)

  @doc """
  Fetches a catalogue by UUID with preloaded categories and items.
  Raises `Ecto.NoResultsError` if not found.

  ## Options

    * `:mode` — `:active` (default) or `:deleted`
      - `:active` — preloads non-deleted categories with non-deleted items
      - `:deleted` — preloads all categories with only deleted items
        (so you can see which categories contain trashed items)

  ## Examples

      Catalogue.get_catalogue!(uuid)                  # active view
      Catalogue.get_catalogue!(uuid, mode: :deleted)  # deleted view
  """
  @spec get_catalogue!(Ecto.UUID.t(), keyword()) :: Catalogue.t()
  def get_catalogue!(uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)

    {category_query, item_query} =
      case mode do
        :active ->
          {from(c in Category, where: c.status != "deleted", order_by: [asc: :position]),
           from(i in Item, where: i.status != "deleted", order_by: [asc: :position, asc: :name])}

        :deleted ->
          {from(c in Category, order_by: [asc: :position]),
           from(i in Item,
             where: i.status == "deleted",
             order_by: [asc: :position, asc: :name]
           )}
      end

    Catalogue
    |> repo().get!(uuid)
    |> repo().preload(categories: {category_query, [items: item_query]})
  end

  @doc """
  Creates a catalogue.

  ## Required attributes

    * `:name` — catalogue name (1-255 chars)

  ## Optional attributes

    * `:description` — text description
    * `:status` — `"active"` (default), `"archived"`, or `"deleted"`
    * `:data` — flexible JSON map

  ## Examples

      Catalogue.create_catalogue(%{name: "Kitchen Furniture"})
  """
  @spec create_catalogue(map(), keyword()) ::
          {:ok, Catalogue.t()} | {:error, Ecto.Changeset.t(Catalogue.t())}
  def create_catalogue(attrs, opts \\ []) do
    attrs = maybe_put_catalogue_position(attrs)

    case %Catalogue{} |> Catalogue.changeset(attrs) |> repo().insert() do
      {:ok, catalogue} = ok ->
        log_activity(%{
          action: "catalogue.created",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "catalogue",
          resource_uuid: catalogue.uuid,
          metadata: %{"name" => catalogue.name}
        })

        ok

      error ->
        error
    end
  end

  @doc "Updates a catalogue with the given attributes."
  @spec update_catalogue(Catalogue.t(), map(), keyword()) ::
          {:ok, Catalogue.t()} | {:error, Ecto.Changeset.t(Catalogue.t())}
  def update_catalogue(%Catalogue{} = catalogue, attrs, opts \\ []) do
    case catalogue |> Catalogue.changeset(attrs) |> repo().update() do
      {:ok, updated} = ok ->
        log_activity(%{
          action: "catalogue.updated",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "catalogue",
          resource_uuid: updated.uuid,
          metadata: %{"name" => updated.name}
        })

        ok

      error ->
        error
    end
  end

  @doc "Hard-deletes a catalogue. Prefer `trash_catalogue/1` for soft-delete."
  @spec delete_catalogue(Catalogue.t(), keyword()) ::
          {:ok, Catalogue.t()} | {:error, Ecto.Changeset.t(Catalogue.t())}
  def delete_catalogue(%Catalogue{} = catalogue, opts \\ []) do
    case repo().delete(catalogue) do
      {:ok, _} = ok ->
        log_activity(%{
          action: "catalogue.deleted",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "catalogue",
          resource_uuid: catalogue.uuid,
          metadata: %{"name" => catalogue.name}
        })

        ok

      error ->
        error
    end
  end

  @doc """
  Soft-deletes a catalogue by setting its status to `"deleted"`.

  **Cascades downward** in a transaction:
  1. All non-deleted items in the catalogue's categories → status `"deleted"`
  2. All non-deleted categories → status `"deleted"`
  3. The catalogue itself → status `"deleted"`

  ## Examples

      {:ok, catalogue} = Catalogue.trash_catalogue(catalogue)
  """
  @spec trash_catalogue(Catalogue.t(), keyword()) :: {:ok, Catalogue.t()} | {:error, term()}
  def trash_catalogue(%Catalogue{} = catalogue, opts \\ []) do
    result =
      repo().transaction(fn ->
        now = DateTime.utc_now()

        from(i in Item,
          where: i.catalogue_uuid == ^catalogue.uuid and i.status != "deleted"
        )
        |> repo().update_all(set: [status: "deleted", updated_at: now])

        from(c in Category, where: c.catalogue_uuid == ^catalogue.uuid and c.status != "deleted")
        |> repo().update_all(set: [status: "deleted", updated_at: now])

        catalogue
        |> Catalogue.changeset(%{status: "deleted"})
        |> repo().update!()
      end)

    with {:ok, updated} <- result do
      log_activity(%{
        action: "catalogue.trashed",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "catalogue",
        resource_uuid: catalogue.uuid,
        metadata: %{"name" => catalogue.name}
      })

      {:ok, updated}
    end
  end

  @doc """
  Restores a soft-deleted catalogue by setting its status to `"active"`.

  **Cascades downward** in a transaction:
  1. All deleted categories → status `"active"`
  2. All deleted items in those categories → status `"active"`
  3. The catalogue itself → status `"active"`

  ## Examples

      {:ok, catalogue} = Catalogue.restore_catalogue(catalogue)
  """
  @spec restore_catalogue(Catalogue.t(), keyword()) ::
          {:ok, Catalogue.t()} | {:error, term()}
  def restore_catalogue(%Catalogue{} = catalogue, opts \\ []) do
    result =
      repo().transaction(fn ->
        now = DateTime.utc_now()

        from(c in Category, where: c.catalogue_uuid == ^catalogue.uuid and c.status == "deleted")
        |> repo().update_all(set: [status: "active", updated_at: now])

        from(i in Item,
          where: i.catalogue_uuid == ^catalogue.uuid and i.status == "deleted"
        )
        |> repo().update_all(set: [status: "active", updated_at: now])

        catalogue
        |> Catalogue.changeset(%{status: "active"})
        |> repo().update!()
      end)

    with {:ok, updated} <- result do
      log_activity(%{
        action: "catalogue.restored",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "catalogue",
        resource_uuid: catalogue.uuid,
        metadata: %{"name" => catalogue.name}
      })

      {:ok, updated}
    end
  end

  @doc """
  Permanently deletes a catalogue and all its contents from the database.

  **Cascades downward** in a transaction:
  1. Hard-deletes all items in the catalogue's categories
  2. Hard-deletes all categories
  3. Hard-deletes the catalogue

  Refuses with `{:error, {:referenced_by_smart_items, count}}` when one or
  more smart-catalogue items still have rules pointing at this catalogue.
  V102's `ON DELETE CASCADE` would silently wipe those rule rows;
  callers should resolve the references explicitly (or remove the rules)
  before retrying. Use `:force` to bypass this guard at your own risk.

  This cannot be undone.

  ## Options

    * `:actor_uuid` — UUID to attribute on the activity log
    * `:force` — when `true`, deletes even if smart-rule references exist

  ## Examples

      {:ok, _} = Catalogue.permanently_delete_catalogue(catalogue)
      {:error, {:referenced_by_smart_items, 3}} =
        Catalogue.permanently_delete_catalogue(catalogue_with_refs)
  """
  @spec permanently_delete_catalogue(Catalogue.t(), keyword()) ::
          {:ok, Catalogue.t()}
          | {:error, {:referenced_by_smart_items, non_neg_integer()}}
          | {:error, term()}
  def permanently_delete_catalogue(%Catalogue{} = catalogue, opts \\ []) do
    force? = Keyword.get(opts, :force, false)
    ref_count = catalogue_reference_count(catalogue.uuid)

    if ref_count > 0 and not force? do
      {:error, {:referenced_by_smart_items, ref_count}}
    else
      do_permanently_delete_catalogue(catalogue, ref_count, opts)
    end
  end

  defp do_permanently_delete_catalogue(catalogue, ref_count, opts) do
    result =
      repo().transaction(fn ->
        from(i in Item, where: i.catalogue_uuid == ^catalogue.uuid)
        |> repo().delete_all()

        # Break V103 self-FKs inside the catalogue before deleting —
        # every category in the catalogue is being removed anyway, so
        # NULLing parent_uuid first is the simplest way to avoid a
        # leaf-first traversal.
        from(c in Category, where: c.catalogue_uuid == ^catalogue.uuid)
        |> repo().update_all(set: [parent_uuid: nil])

        from(c in Category, where: c.catalogue_uuid == ^catalogue.uuid)
        |> repo().delete_all()

        repo().delete!(catalogue)
      end)

    with {:ok, _} <- result do
      log_activity(%{
        action: "catalogue.permanently_deleted",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "catalogue",
        resource_uuid: catalogue.uuid,
        metadata: %{
          "name" => catalogue.name,
          "smart_rules_cascaded" => ref_count
        }
      })

      result
    end
  end

  @doc "Returns a changeset for tracking catalogue changes."
  @spec change_catalogue(Catalogue.t(), map()) :: Ecto.Changeset.t(Catalogue.t())
  def change_catalogue(%Catalogue{} = catalogue, attrs \\ %{}) do
    Catalogue.changeset(catalogue, attrs)
  end

  # ═══════════════════════════════════════════════════════════════════
  # Categories
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Lists non-deleted categories for a catalogue, ordered by position then name.

  Preloads items (non-deleted only).
  """
  @spec list_categories_for_catalogue(Ecto.UUID.t()) :: [Category.t()]
  def list_categories_for_catalogue(catalogue_uuid) do
    from(c in Category,
      where: c.catalogue_uuid == ^catalogue_uuid and c.status != "deleted",
      order_by: [asc: :position, asc: :name],
      preload: [:items]
    )
    |> repo().all()
  end

  @doc """
  Lists categories for a catalogue **without** preloading items, ordered by
  position then name. Used by the infinite-scroll detail view to walk
  categories in display order without fetching potentially thousands of
  items up front.

  ## Options

    * `:mode` — `:active` (default, excludes deleted categories) or
      `:deleted` (all categories — deleted categories can still contain
      trashed items we want to show).
  """
  @spec list_categories_metadata_for_catalogue(Ecto.UUID.t(), keyword()) :: [Category.t()]
  def list_categories_metadata_for_catalogue(catalogue_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)

    query =
      from(c in Category,
        where: c.catalogue_uuid == ^catalogue_uuid,
        order_by: [asc: :position, asc: :name]
      )

    query =
      case mode do
        :active -> where(query, [c], c.status != "deleted")
        :deleted -> query
      end

    repo().all(query)
  end

  @doc """
  Lists a page of items for a single category, ordered by name.

  Used by the infinite-scroll detail view; returns at most `:limit`
  items starting at `:offset`. Preloads `:catalogue` and `:manufacturer`
  so the table cell renderers can access them without extra queries.

  ## Options

    * `:mode` — `:active` (default, excludes deleted items) or `:deleted`
      (only deleted items)
    * `:offset` — default `0`
    * `:limit` — default `50`
    * `:preload` — extra associations appended to the default
      `[:catalogue, :manufacturer]`.
  """
  @spec list_items_for_category_paged(Ecto.UUID.t(), keyword()) :: [Item.t()]
  def list_items_for_category_paged(category_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)
    offset = Keyword.get(opts, :offset, 0)
    limit = Keyword.get(opts, :limit, 50)
    preloads = Helpers.merge_preloads([:catalogue, :manufacturer], opts)

    query =
      from(i in Item,
        where: i.category_uuid == ^category_uuid,
        order_by: [asc: i.position, asc: i.name],
        offset: ^offset,
        limit: ^limit,
        preload: ^preloads
      )

    query =
      case mode do
        :active -> where(query, [i], i.status != "deleted")
        :deleted -> where(query, [i], i.status == "deleted")
      end

    repo().all(query)
  end

  @doc """
  Lists a page of uncategorized items for a catalogue, ordered by name.

  Same shape as `list_items_for_category_paged/2`, but for items where
  `category_uuid IS NULL AND catalogue_uuid = ?`. Used as the final
  section of the infinite-scroll detail view.

  ## Options

    * `:mode` — `:active` (default) or `:deleted`
    * `:offset` — default `0`
    * `:limit` — default `50`
    * `:preload` — extra associations appended to the default
      `[:catalogue, :manufacturer]`.
  """
  @spec list_uncategorized_items_paged(Ecto.UUID.t(), keyword()) :: [Item.t()]
  def list_uncategorized_items_paged(catalogue_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)
    offset = Keyword.get(opts, :offset, 0)
    limit = Keyword.get(opts, :limit, 50)
    preloads = Helpers.merge_preloads([:catalogue, :manufacturer], opts)

    query =
      from(i in Item,
        where: i.catalogue_uuid == ^catalogue_uuid and is_nil(i.category_uuid),
        order_by: [asc: i.position, asc: i.name],
        offset: ^offset,
        limit: ^limit,
        preload: ^preloads
      )

    query =
      case mode do
        :active -> where(query, [i], i.status != "deleted")
        :deleted -> where(query, [i], i.status == "deleted")
      end

    repo().all(query)
  end

  @doc """
  Counts non-deleted uncategorized items for a catalogue (items with
  `category_uuid IS NULL`). Used to decide whether the infinite-scroll
  detail view needs to show an "Uncategorized" card at all.
  """
  @spec uncategorized_count_for_catalogue(Ecto.UUID.t(), keyword()) :: non_neg_integer()
  def uncategorized_count_for_catalogue(catalogue_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)

    query =
      from(i in Item,
        where: i.catalogue_uuid == ^catalogue_uuid and is_nil(i.category_uuid)
      )

    query =
      case mode do
        :active -> where(query, [i], i.status != "deleted")
        :deleted -> where(query, [i], i.status == "deleted")
      end

    repo().aggregate(query, :count)
  end

  @doc """
  Counts items in a single category (ignoring its catalogue scope).

  Used by the infinite-scroll detail view to show the total under each
  category header (the number in `"Category Name (N items)"`) without
  loading the items themselves.

  ## Options

    * `:mode` — `:active` (default) or `:deleted`
  """
  @spec item_count_for_category(Ecto.UUID.t(), keyword()) :: non_neg_integer()
  def item_count_for_category(category_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)

    query = from(i in Item, where: i.category_uuid == ^category_uuid)

    query =
      case mode do
        :active -> where(query, [i], i.status != "deleted")
        :deleted -> where(query, [i], i.status == "deleted")
      end

    repo().aggregate(query, :count)
  end

  @doc """
  Returns a map of `%{category_uuid => item_count}` for every category
  in a catalogue in a single grouped query. Used by the infinite-scroll
  detail view so each category card can show its total count without a
  separate per-card round trip.

  Items without a category (uncategorized) are excluded here — use
  `uncategorized_count_for_catalogue/2` for those.

  ## Options

    * `:mode` — `:active` (default) or `:deleted`
  """
  @spec item_counts_by_category_for_catalogue(Ecto.UUID.t(), keyword()) :: %{
          Ecto.UUID.t() => non_neg_integer()
        }
  def item_counts_by_category_for_catalogue(catalogue_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)

    query =
      from(i in Item,
        where: i.catalogue_uuid == ^catalogue_uuid and not is_nil(i.category_uuid),
        group_by: i.category_uuid,
        select: {i.category_uuid, count(i.uuid)}
      )

    query =
      case mode do
        :active -> where(query, [i], i.status != "deleted")
        :deleted -> where(query, [i], i.status == "deleted")
      end

    query
    |> repo().all()
    |> Map.new()
  end

  @doc """
  One-shot helper for lazy-loading a catalogue's category tree. Returns
  category metadata plus per-category and uncategorized item counts in
  two queries instead of three.

  Combines the work of:

    * `list_categories_metadata_for_catalogue/2`
    * `item_counts_by_category_for_catalogue/2`
    * `uncategorized_count_for_catalogue/2`

  Categories are ordered the same way `list_categories_metadata_for_catalogue/2`
  orders them. Empty categories don't appear in `:item_counts` (treat
  missing keys as `0`).

  ## Options

    * `:mode` — `:active` (default, excludes deleted) or `:deleted`.
      Mode is applied uniformly to both the categories query and the
      item-count query.
  """
  @spec category_summary_for_catalogue(Ecto.UUID.t(), keyword()) :: %{
          categories: [Category.t()],
          item_counts: %{Ecto.UUID.t() => non_neg_integer()},
          uncategorized_count: non_neg_integer()
        }
  def category_summary_for_catalogue(catalogue_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)

    categories = list_categories_metadata_for_catalogue(catalogue_uuid, mode: mode)

    rows =
      from(i in Item,
        where: i.catalogue_uuid == ^catalogue_uuid,
        group_by: i.category_uuid,
        select: {i.category_uuid, count(i.uuid)}
      )
      |> apply_summary_mode(mode)
      |> repo().all()

    {item_counts, uncategorized_count} =
      Enum.reduce(rows, {%{}, 0}, fn
        {nil, count}, {map, _} -> {map, count}
        {uuid, count}, {map, uncat} -> {Map.put(map, uuid, count), uncat}
      end)

    %{
      categories: categories,
      item_counts: item_counts,
      uncategorized_count: uncategorized_count
    }
  end

  defp apply_summary_mode(query, :active),
    do: where(query, [i], i.status != "deleted")

  defp apply_summary_mode(query, :deleted),
    do: where(query, [i], i.status == "deleted")

  @doc """
  Lists all non-deleted categories across all non-deleted catalogues,
  with breadcrumb-style names prefixed by their catalogue and every
  ancestor category (e.g. `"Kitchen / Cabinets / Frames"`). Useful for
  item move dropdowns where the user needs to distinguish
  same-named leaves under different parents.

  Entries are grouped by catalogue (catalogues ordered by name) and
  within each catalogue returned in depth-first display order.

  One query for catalogues + one query for all their categories — the
  tree walk and breadcrumb rewrite happen in memory. Safe to call on
  demand from move-dropdowns.
  """
  @spec list_all_categories() :: [Category.t()]
  def list_all_categories do
    catalogues =
      from(cat in Catalogue,
        where: cat.status != "deleted",
        order_by: [asc: cat.position, asc: cat.name]
      )
      |> repo().all()

    case catalogues do
      [] ->
        []

      catalogues ->
        catalogue_uuids = Enum.map(catalogues, & &1.uuid)

        categories_by_catalogue =
          from(c in Category,
            where: c.catalogue_uuid in ^catalogue_uuids and c.status != "deleted",
            order_by: [asc: :position, asc: :name]
          )
          |> repo().all()
          |> Enum.group_by(& &1.catalogue_uuid)

        Enum.flat_map(catalogues, fn %Catalogue{uuid: uuid, name: cat_name} ->
          categories = Map.get(categories_by_catalogue, uuid, [])
          breadcrumb_categories_for_catalogue(cat_name, categories)
        end)
    end
  end

  # Builds the depth-first list of `%Category{name: "A / B / C"}` for
  # one catalogue from a flat, pre-sorted list of its categories.
  defp breadcrumb_categories_for_catalogue(cat_name, categories) when is_list(categories) do
    uuid_set = MapSet.new(categories, & &1.uuid)

    # Promote orphans (children whose parent isn't in this list because
    # it's been deleted or excluded) to roots so they still appear.
    normalized =
      Enum.map(categories, fn c ->
        if c.parent_uuid == nil or MapSet.member?(uuid_set, c.parent_uuid) do
          c
        else
          %{c | parent_uuid: nil}
        end
      end)

    index = Tree.build_children_index(normalized)

    {reversed, _} =
      normalized
      |> Enum.filter(&is_nil(&1.parent_uuid))
      |> Enum.reduce({[], %{}}, fn root, {acc, path_by_uuid} ->
        collect_breadcrumb(root, index, cat_name, path_by_uuid, acc)
      end)

    Enum.reverse(reversed)
  end

  defp collect_breadcrumb(%Category{} = cat, index, catalogue_name, path_by_uuid, acc) do
    parent_label =
      case cat.parent_uuid do
        nil -> catalogue_name
        parent_uuid -> Map.get(path_by_uuid, parent_uuid, catalogue_name)
      end

    full_label = "#{parent_label} / #{cat.name}"
    labeled = %{cat | name: full_label}
    path_by_uuid = Map.put(path_by_uuid, cat.uuid, full_label)
    acc = [labeled | acc]

    index
    |> Map.get(cat.uuid, [])
    |> Enum.reduce({acc, path_by_uuid}, fn child, {acc, path_by_uuid} ->
      collect_breadcrumb(child, index, catalogue_name, path_by_uuid, acc)
    end)
  end

  @doc "Fetches a category by UUID. Returns `nil` if not found."
  @spec get_category(Ecto.UUID.t()) :: Category.t() | nil
  def get_category(uuid), do: repo().get(Category, uuid)

  @doc "Fetches a category by UUID. Raises `Ecto.NoResultsError` if not found."
  @spec get_category!(Ecto.UUID.t()) :: Category.t()
  def get_category!(uuid), do: repo().get!(Category, uuid)

  @doc """
  Creates a category within a catalogue.

  ## Required attributes

    * `:name` — category name (1-255 chars)
    * `:catalogue_uuid` — the parent catalogue

  ## Optional attributes

    * `:description`, `:position` (default 0), `:status` (`"active"` or `"deleted"`)
    * `:data` — flexible JSON map

  ## Examples

      Catalogue.create_category(%{name: "Frames", catalogue_uuid: catalogue.uuid})
  """
  @spec create_category(map(), keyword()) ::
          {:ok, Category.t()} | {:error, Ecto.Changeset.t(Category.t())}
  def create_category(attrs, opts \\ []) do
    changeset =
      %Category{}
      |> Category.changeset(attrs)
      |> validate_parent_in_same_catalogue()

    case repo().insert(changeset) do
      {:ok, category} = ok ->
        log_activity(%{
          action: "category.created",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "category",
          resource_uuid: category.uuid,
          parent_catalogue_uuid: category.catalogue_uuid,
          metadata: %{"name" => category.name, "catalogue_uuid" => category.catalogue_uuid}
        })

        ok

      error ->
        error
    end
  end

  @doc "Updates a category with the given attributes."
  @spec update_category(Category.t(), map(), keyword()) ::
          {:ok, Category.t()} | {:error, Ecto.Changeset.t(Category.t())}
  def update_category(%Category{} = category, attrs, opts \\ []) do
    changeset =
      category
      |> Category.changeset(attrs)
      |> validate_parent_in_same_catalogue()

    case repo().update(changeset) do
      {:ok, updated} = ok ->
        log_activity(%{
          action: "category.updated",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "category",
          resource_uuid: updated.uuid,
          parent_catalogue_uuid: updated.catalogue_uuid,
          metadata: %{"name" => updated.name}
        })

        ok

      error ->
        error
    end
  end

  # Guards both create_category/2 and update_category/3 against a
  # `parent_uuid` that names a category in a different catalogue, AND
  # against cycles on update (a raw
  # `update_category(cat, %{parent_uuid: descendant.uuid})` would
  # otherwise sail past the `move_category_under/3` checks). The
  # self-parent rejection lives on `Category.changeset`; the
  # cross-catalogue and full-subtree cycle checks need DB lookups, so
  # they live here.
  defp validate_parent_in_same_catalogue(%Ecto.Changeset{} = changeset) do
    catalogue_uuid = Ecto.Changeset.get_field(changeset, :catalogue_uuid)
    parent_uuid = Ecto.Changeset.get_field(changeset, :parent_uuid)
    own_uuid = Ecto.Changeset.get_field(changeset, :uuid)

    cond do
      parent_uuid in [nil, ""] ->
        changeset

      is_nil(catalogue_uuid) ->
        Ecto.Changeset.add_error(
          changeset,
          :parent_uuid,
          "cannot be set without a catalogue"
        )

      own_uuid && cycle?(parent_uuid, own_uuid) ->
        Ecto.Changeset.add_error(
          changeset,
          :parent_uuid,
          "would create a cycle"
        )

      true ->
        check_parent_catalogue(changeset, parent_uuid, catalogue_uuid)
    end
  end

  # `Tree.subtree_uuids/1` returns raw 16-byte binaries (the schema-less
  # outer CTE select strips Ecto's type info). The textual `parent_uuid`
  # we got from the changeset doesn't match those, so dump it to the
  # raw binary form before the membership test. Without this, a real
  # cycle is silently accepted — the test
  # `update_category/3 rejects a parent that is a descendant (cycle)`
  # pins the regression.
  defp cycle?(parent_uuid, own_uuid) do
    case Ecto.UUID.dump(parent_uuid) do
      {:ok, raw} -> raw in Tree.subtree_uuids(own_uuid)
      :error -> false
    end
  end

  defp check_parent_catalogue(changeset, parent_uuid, catalogue_uuid) do
    case repo().get(Category, parent_uuid) do
      nil ->
        Ecto.Changeset.add_error(changeset, :parent_uuid, "does not exist")

      %Category{catalogue_uuid: ^catalogue_uuid} ->
        changeset

      %Category{} ->
        Ecto.Changeset.add_error(
          changeset,
          :parent_uuid,
          "must belong to the same catalogue"
        )
    end
  end

  @doc "Hard-deletes a category. Prefer `trash_category/1` for soft-delete."
  @spec delete_category(Category.t(), keyword()) :: {:ok, Category.t()} | {:error, term()}
  def delete_category(%Category{} = category, opts \\ []) do
    case repo().delete(category) do
      {:ok, _} = ok ->
        log_activity(%{
          action: "category.deleted",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "category",
          resource_uuid: category.uuid,
          parent_catalogue_uuid: category.catalogue_uuid,
          metadata: %{"name" => category.name}
        })

        ok

      error ->
        error
    end
  end

  @doc """
  Soft-deletes a category and its entire subtree by setting their
  status to `"deleted"`.

  **Cascades the categories downward** in a transaction (the category
  itself and every descendant flip to `"deleted"`), following the V103
  nested-category tree.

  **Items in the subtree** are handled per the `:items` opt:

    * `:cascade` (default) — items in the subtree flip to `"deleted"`
      alongside the categories. Original behavior, kept for programmatic
      callers + admin "delete and trash everything" intent.
    * `:uncategorize` — items in the subtree keep their `catalogue_uuid`
      but get `category_uuid: nil`, surviving the category trash. Used
      by the admin modal when the operator wants the category gone but
      the items kept in the same catalogue.
    * `{:move_to, target_uuid}` — items move to the target category
      (which must live in the same catalogue) before the category is
      trashed. Cross-catalogue moves aren't supported here; the LV
      restricts the dropdown to same-catalogue targets.

  Logs a single `category.trashed` activity on the root with
  `subtree_size`, `items_handled`, and `items_disposition` in metadata.

  ## Examples

      {:ok, _} = Catalogue.trash_category(category)
      {:ok, _} = Catalogue.trash_category(category, items: :uncategorize)
      {:ok, _} = Catalogue.trash_category(category, items: {:move_to, target_uuid})
  """
  @spec trash_category(Category.t(), keyword()) ::
          {:ok, Category.t()}
          | {:error, :move_target_not_found | :cross_catalogue_move | term()}
  def trash_category(%Category{} = category, opts \\ []) do
    disposition = Keyword.get(opts, :items, :cascade)

    result =
      repo().transaction(fn ->
        now = DateTime.utc_now()
        subtree = Tree.subtree_uuids(category.uuid)

        case apply_item_disposition(disposition, subtree, category, now) do
          {:ok, items_handled} ->
            from(c in Category,
              where: c.uuid in ^subtree and c.status != "deleted"
            )
            |> repo().update_all(set: [status: "deleted", updated_at: now])

            updated = repo().get!(Category, category.uuid)
            {updated, length(subtree), items_handled}

          {:error, reason} ->
            repo().rollback(reason)
        end
      end)

    case result do
      {:ok, {updated, subtree_size, items_handled}} ->
        log_activity(%{
          action: "category.trashed",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "category",
          resource_uuid: category.uuid,
          parent_catalogue_uuid: category.catalogue_uuid,
          metadata: %{
            "name" => category.name,
            "catalogue_uuid" => category.catalogue_uuid,
            "subtree_size" => subtree_size,
            "items_handled" => items_handled,
            "items_disposition" => disposition_to_metadata(disposition)
          }
        })

        {:ok, updated}

      error ->
        error
    end
  end

  defp apply_item_disposition(:cascade, subtree, _category, now) do
    {count, _} =
      from(i in Item,
        where: i.category_uuid in ^subtree and i.status != "deleted"
      )
      |> repo().update_all(set: [status: "deleted", updated_at: now])

    {:ok, count}
  end

  defp apply_item_disposition(:uncategorize, subtree, category, now) do
    {count, _} =
      from(i in Item,
        where: i.category_uuid in ^subtree and i.status != "deleted"
      )
      |> repo().update_all(
        set: [category_uuid: nil, catalogue_uuid: category.catalogue_uuid, updated_at: now]
      )

    {:ok, count}
  end

  defp apply_item_disposition({:move_to, target_uuid}, subtree, category, now) do
    case repo().get(Category, target_uuid) do
      nil ->
        {:error, :move_target_not_found}

      %Category{catalogue_uuid: target_cat_uuid}
      when target_cat_uuid != category.catalogue_uuid ->
        {:error, :cross_catalogue_move}

      %Category{uuid: ^target_uuid} = target ->
        {count, _} =
          from(i in Item,
            where: i.category_uuid in ^subtree and i.status != "deleted"
          )
          |> repo().update_all(
            set: [
              category_uuid: target.uuid,
              catalogue_uuid: target.catalogue_uuid,
              updated_at: now
            ]
          )

        {:ok, count}
    end
  end

  defp disposition_to_metadata(:cascade), do: "cascade"
  defp disposition_to_metadata(:uncategorize), do: "uncategorize"
  defp disposition_to_metadata({:move_to, uuid}), do: "move_to:#{uuid}"

  @doc """
  Restores a soft-deleted category (and its deleted subtree) by
  setting status back to `"active"`.

  **Cascades both directions** in a transaction:
  - **Upward**: restores every deleted ancestor category so the restored
    node is reachable in the active tree, then the parent catalogue if
    it's deleted too.
  - **Downward**: restores all deleted categories in this subtree and
    all deleted items inside them. Restoring a node after a prior
    trash cascade brings the whole sub-branch back as one action.

  ## Examples

      {:ok, _} = Catalogue.restore_category(category)
  """
  @spec restore_category(Category.t(), keyword()) ::
          {:ok, Category.t()}
          | {:error, :parent_catalogue_deleted | term()}
  def restore_category(%Category{} = category, opts \\ []) do
    result =
      repo().transaction(fn ->
        # Refuse if the parent catalogue is itself deleted. The operator
        # must restore the catalogue explicitly first.
        case repo().get(Catalogue, category.catalogue_uuid) do
          %Catalogue{status: "deleted"} ->
            repo().rollback(:parent_catalogue_deleted)

          _ ->
            :ok
        end

        # Only flip the target category's status — no cascades. Items,
        # descendant categories, and ancestor categories all keep their
        # current statuses. The boss's principle: each entity's status
        # is its own; restore-as-undo doesn't ripple sideways. Items
        # that were cascade-trashed alongside this category stay
        # deleted; the operator restores them separately (where
        # `restore_item/2` will route them through the same parent the
        # restored category sits in if it's now active).
        category
        |> Category.changeset(%{status: "active"})
        |> repo().update!()
      end)

    case result do
      {:ok, updated} ->
        log_activity(%{
          action: "category.restored",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "category",
          resource_uuid: category.uuid,
          parent_catalogue_uuid: category.catalogue_uuid,
          metadata: %{
            "name" => category.name,
            "catalogue_uuid" => category.catalogue_uuid
          }
        })

        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Permanently deletes a category and its entire subtree (all descendant
  categories + every item in any of them) from the database.

  **Cascades downward** in a transaction, following the nested-category
  tree introduced in V103. Items are hard-deleted first, then the
  subtree categories from leaves up (ordered so child FKs resolve
  before their parent is removed). This cannot be undone.
  """
  @spec permanently_delete_category(Category.t(), keyword()) ::
          {:ok, Category.t()} | {:error, term()}
  def permanently_delete_category(%Category{} = category, opts \\ []) do
    result =
      repo().transaction(fn ->
        subtree = Tree.subtree_uuids(category.uuid)

        {items_cascaded, _} =
          from(i in Item, where: i.category_uuid in ^subtree)
          |> repo().delete_all()

        # V103's self-FK on parent_uuid has no ON DELETE CASCADE — a
        # straight `delete_all` on the subtree would reject any parent
        # row while its children still reference it. Since every row in
        # the subtree is being deleted anyway, NULL out parent_uuid
        # first to break the intra-subtree FKs, then delete in one shot.
        from(c in Category, where: c.uuid in ^subtree)
        |> repo().update_all(set: [parent_uuid: nil])

        from(c in Category, where: c.uuid in ^subtree)
        |> repo().delete_all()

        {length(subtree), items_cascaded}
      end)

    case result do
      {:ok, {subtree_size, items_cascaded}} ->
        log_activity(%{
          action: "category.permanently_deleted",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "category",
          resource_uuid: category.uuid,
          parent_catalogue_uuid: category.catalogue_uuid,
          metadata: %{
            "name" => category.name,
            "catalogue_uuid" => category.catalogue_uuid,
            "subtree_size" => subtree_size,
            "items_cascaded" => items_cascaded
          }
        })

        {:ok, category}

      error ->
        error
    end
  end

  @doc """
  Moves a category — along with its entire subtree and every item
  inside — to a different catalogue.

  The moved category's `parent_uuid` is cleared (it detaches from its
  former parent, which stays in the source catalogue) and it takes the
  next available root-level position in the target. Internal parent
  links inside the moved subtree are preserved.

  Automatically assigns the next available root position in the target
  catalogue.

  ## Examples

      {:ok, moved} = Catalogue.move_category_to_catalogue(category, target_catalogue_uuid)
  """
  @spec move_category_to_catalogue(Category.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Category.t()} | {:error, term()}
  def move_category_to_catalogue(%Category{} = category, target_catalogue_uuid, opts \\ []) do
    source_catalogue_uuid = category.catalogue_uuid

    result =
      repo().transaction(fn ->
        # Take an exclusive row lock on the category being moved. This
        # serializes concurrent `create_item`/`update_item` calls that
        # read the same category via `FOR SHARE` in
        # `put_catalogue_from_effective_category/2`: while we hold the
        # lock they block, and once we commit they read the new
        # `catalogue_uuid`. No item can slip in with a stale
        # `catalogue_uuid` between our items-update and our commit.
        repo().one!(from(c in Category, where: c.uuid == ^category.uuid, lock: "FOR UPDATE"))

        subtree = Tree.subtree_uuids(category.uuid)
        now = DateTime.utc_now()

        {items_updated, _} =
          from(i in Item, where: i.category_uuid in ^subtree)
          |> repo().update_all(set: [catalogue_uuid: target_catalogue_uuid, updated_at: now])

        # Reparent the whole subtree to the target catalogue in a
        # single query — internal parent_uuids stay intact because
        # they still reference rows in the subtree.
        {categories_updated, _} =
          from(c in Category, where: c.uuid in ^subtree)
          |> repo().update_all(set: [catalogue_uuid: target_catalogue_uuid, updated_at: now])

        # Position is computed inside the transaction (after the
        # subtree has moved) to avoid the same-`max_position` race
        # called out in prior PR reviews.
        next_pos = next_category_position(target_catalogue_uuid, nil)

        moved =
          category
          |> Category.changeset(%{
            catalogue_uuid: target_catalogue_uuid,
            parent_uuid: nil,
            position: next_pos
          })
          |> repo().update!()

        {moved, categories_updated, items_updated}
      end)

    case result do
      {:ok, {moved, categories_updated, items_updated}} ->
        log_activity(%{
          action: "category.moved",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "category",
          resource_uuid: moved.uuid,
          parent_catalogue_uuid: target_catalogue_uuid,
          metadata: %{
            "name" => moved.name,
            "from_catalogue_uuid" => source_catalogue_uuid,
            "to_catalogue_uuid" => target_catalogue_uuid,
            "subtree_size" => categories_updated,
            "items_cascaded" => items_updated
          }
        })

        {:ok, moved}

      error ->
        error
    end
  end

  @doc """
  Reparents a category within the same catalogue, placing it under
  `new_parent_uuid` (or promoting it to a root with `nil`).

  Rejects moves that would:
    * produce a cycle (`new_parent_uuid` is the category itself or one
      of its descendants) — returns `{:error, :would_create_cycle}`
    * cross a catalogue boundary — returns `{:error, :cross_catalogue}`.
      Callers who want that should run `move_category_to_catalogue/3`
      first, then reparent.
    * target a missing parent — returns `{:error, :parent_not_found}`

  The moved category takes the next-available position among its new
  siblings. Its subtree comes along untouched (parent links inside the
  subtree stay valid).

  Passing `new_parent_uuid = nil` promotes the category to a root within
  its current catalogue.

  ## Examples

      {:ok, moved} = Catalogue.move_category_under(child, parent.uuid)
      {:ok, moved} = Catalogue.move_category_under(child, nil)  # promote to root
  """
  @spec move_category_under(Category.t(), Ecto.UUID.t() | nil, keyword()) ::
          {:ok, Category.t()}
          | {:error,
             :would_create_cycle
             | :cross_catalogue
             | :parent_not_found
             | Ecto.Changeset.t(Category.t())}
  def move_category_under(category, new_parent_uuid, opts \\ [])

  def move_category_under(%Category{parent_uuid: same} = category, same, _opts)
      when is_binary(same) or is_nil(same),
      do: {:ok, category}

  def move_category_under(%Category{} = category, nil, opts) do
    from_parent_uuid = category.parent_uuid
    next_pos = next_category_position(category.catalogue_uuid, nil)

    with {:ok, moved} <-
           category
           |> Category.changeset(%{parent_uuid: nil, position: next_pos})
           |> repo().update() do
      log_activity(%{
        action: "category.moved",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "category",
        resource_uuid: moved.uuid,
        parent_catalogue_uuid: moved.catalogue_uuid,
        metadata: %{
          "name" => moved.name,
          "from_parent_uuid" => from_parent_uuid,
          "to_parent_uuid" => nil,
          "catalogue_uuid" => moved.catalogue_uuid
        }
      })

      {:ok, moved}
    end
  end

  def move_category_under(%Category{} = category, new_parent_uuid, opts)
      when is_binary(new_parent_uuid) do
    if new_parent_uuid == category.uuid do
      {:error, :would_create_cycle}
    else
      do_move_category_under(category, new_parent_uuid, opts)
    end
  end

  # Runs the cycle check + parent validation + position calc + update
  # inside a single transaction with `FOR UPDATE` on the moved row.
  # Two concurrent reparents on different nodes that would jointly
  # create a cycle now serialise: the second one re-runs `Tree.subtree_uuids/1`
  # against the post-commit tree and gets `:would_create_cycle` instead
  # of silently shipping a corrupting structure.
  defp do_move_category_under(category, new_parent_uuid, opts) do
    result =
      repo().transaction(fn ->
        repo().one!(from(c in Category, where: c.uuid == ^category.uuid, lock: "FOR UPDATE"))

        if cycle?(new_parent_uuid, category.uuid) do
          repo().rollback(:would_create_cycle)
        else
          run_locked_reparent(category, new_parent_uuid)
        end
      end)

    with {:ok, {moved, from_parent_uuid}} <- result do
      log_activity(%{
        action: "category.moved",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "category",
        resource_uuid: moved.uuid,
        parent_catalogue_uuid: moved.catalogue_uuid,
        metadata: %{
          "name" => moved.name,
          "from_parent_uuid" => from_parent_uuid,
          "to_parent_uuid" => new_parent_uuid,
          "catalogue_uuid" => moved.catalogue_uuid
        }
      })

      {:ok, moved}
    end
  end

  # Loads a raw 16-byte binary UUID from a Tree CTE result back into the
  # textual `xxxxxxxx-xxxx-...` form, falling back to the raw input if
  # it isn't a valid UUID. Used by `list_category_tree/2`'s
  # `:exclude_subtree_of` membership test (loaded `Category` rows carry
  # textual UUIDs).
  defp load_uuid(raw) do
    case Ecto.UUID.load(raw) do
      {:ok, str} -> str
      :error -> raw
    end
  end

  defp run_locked_reparent(category, new_parent_uuid) do
    case repo().get(Category, new_parent_uuid) do
      nil ->
        repo().rollback(:parent_not_found)

      %Category{catalogue_uuid: other} when other != category.catalogue_uuid ->
        repo().rollback(:cross_catalogue)

      %Category{} ->
        from_parent_uuid = category.parent_uuid
        next_pos = next_category_position(category.catalogue_uuid, new_parent_uuid)

        case category
             |> Category.changeset(%{parent_uuid: new_parent_uuid, position: next_pos})
             |> repo().update() do
          {:ok, moved} -> {moved, from_parent_uuid}
          {:error, changeset} -> repo().rollback(changeset)
        end
    end
  end

  @doc """
  Atomically swaps the positions of two categories within a transaction.

  Positions are scoped to `(catalogue_uuid, parent_uuid)` sibling
  groups (V103). Swapping positions of categories that are not
  siblings would mix two independent ordering axes, so this function
  refuses with `{:error, :not_siblings}` when the categories live
  under different parents or in different catalogues. The detail-view
  reorder buttons enforce the same constraint at the LV level; this
  is the context-level guard for any programmatic caller.

  ## Examples

      {:ok, _} = Catalogue.swap_category_positions(cat_a, cat_b)
      {:error, :not_siblings} = Catalogue.swap_category_positions(root, child)
  """
  @spec swap_category_positions(Category.t(), Category.t(), keyword()) ::
          {:ok, term()} | {:error, :not_siblings | term()}
  def swap_category_positions(%Category{} = cat_a, %Category{} = cat_b, opts \\ []) do
    if cat_a.catalogue_uuid != cat_b.catalogue_uuid or
         cat_a.parent_uuid != cat_b.parent_uuid do
      {:error, :not_siblings}
    else
      do_swap_category_positions(cat_a, cat_b, opts)
    end
  end

  defp do_swap_category_positions(cat_a, cat_b, opts) do
    result =
      repo().transaction(fn ->
        # Take FOR UPDATE on both rows before reading their positions so
        # two concurrent swaps with overlapping siblings serialise. The
        # first transaction commits its swap; the second re-reads the
        # post-commit positions and writes the correct values, instead
        # of computing both positions off pre-commit reads and producing
        # duplicates.
        a =
          repo().one!(from(c in Category, where: c.uuid == ^cat_a.uuid, lock: "FOR UPDATE"))

        b =
          repo().one!(from(c in Category, where: c.uuid == ^cat_b.uuid, lock: "FOR UPDATE"))

        a |> Category.changeset(%{position: b.position}) |> repo().update!()
        b |> Category.changeset(%{position: a.position}) |> repo().update!()
      end)

    with {:ok, _} <- result do
      log_activity(%{
        action: "category.positions_swapped",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "category",
        resource_uuid: cat_a.uuid,
        parent_catalogue_uuid: cat_a.catalogue_uuid,
        metadata: %{
          "category_a_uuid" => cat_a.uuid,
          "category_a_name" => cat_a.name,
          "category_b_uuid" => cat_b.uuid,
          "category_b_name" => cat_b.name
        }
      })

      result
    end
  end

  @doc "Returns a changeset for tracking category changes."
  @spec change_category(Category.t(), map()) :: Ecto.Changeset.t(Category.t())
  def change_category(%Category{} = category, attrs \\ %{}) do
    Category.changeset(category, attrs)
  end

  @doc """
  Returns the list of ancestor categories from root down to (but not
  including) `category_uuid`. Empty when the category is a root.
  Useful for breadcrumbs.
  """
  @spec list_category_ancestors(Ecto.UUID.t()) :: [Category.t()]
  defdelegate list_category_ancestors(category_uuid), to: Tree, as: :ancestors_in_order

  @doc """
  Returns same-catalogue active categories that can receive items from
  a category about to be deleted (the category itself and its V103
  descendants are excluded). Used by the admin "delete category" modal
  to populate the move-target dropdown.

  Each entry is `{category, depth}`, depth-first order — the same shape
  `list_category_tree/2` returns so callers can render the same indent
  rules.
  """
  @spec list_move_target_categories(Category.t()) :: [{Category.t(), non_neg_integer()}]
  def list_move_target_categories(%Category{} = category) do
    # `Tree.subtree_uuids/1` returns raw 16-byte binaries; `list_category_tree/2`
    # returns Ecto-loaded categories whose `:uuid` is the textual form.
    # Normalise both to text via `load_uuid/1` so the membership check fires.
    subtree =
      category.uuid
      |> Tree.subtree_uuids()
      |> Enum.map(&load_uuid/1)
      |> MapSet.new()

    category.catalogue_uuid
    |> list_category_tree(mode: :active)
    |> Enum.reject(fn {cat, _depth} -> MapSet.member?(subtree, cat.uuid) end)
  end

  @doc """
  Returns the categories in a catalogue paired with their tree depth,
  in depth-first display order (position, then name, recursing into
  children). Each entry is `{category, depth}` where depth `0` means a
  root. Used to render flat parent-pickers and indented listings.

  ## Options

    * `:mode` — `:active` (default, excludes deleted categories) or
      `:deleted` (all statuses — the detail view in deleted mode still
      wants deleted categories that contain trashed items).
    * `:exclude_subtree_of` — skip a category and all its descendants
      (e.g. the category being edited — you can't parent it under
      itself or its descendants).
  """
  @spec list_category_tree(Ecto.UUID.t(), keyword()) :: [{Category.t(), non_neg_integer()}]
  def list_category_tree(catalogue_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)

    # Plain list (not MapSet) because the exclude subtree is typically
    # a single branch (order of 1–20 uuids) and keeping a list here
    # lets dialyzer type-check the `in` check without tripping on
    # MapSet's opaque struct.
    # `Tree.subtree_uuids/1` returns raw 16-byte binaries; loaded
    # `Category` rows carry textual UUIDs. Normalise both sides via
    # `Ecto.UUID.load/1` so the membership test actually fires.
    exclude_uuids =
      case Keyword.get(opts, :exclude_subtree_of) do
        nil -> []
        uuid -> uuid |> Tree.subtree_uuids() |> Enum.map(&load_uuid/1)
      end

    query =
      from(c in Category,
        where: c.catalogue_uuid == ^catalogue_uuid,
        order_by: [asc: :position, asc: :name]
      )

    query =
      case mode do
        :active -> where(query, [c], c.status != "deleted")
        :deleted -> query
      end

    categories =
      query
      |> repo().all()
      |> Enum.reject(&(&1.uuid in exclude_uuids))

    # Some parents may be missing from the filtered list (deleted
    # ancestors in :active mode, or excluded subtree). Orphans — rows
    # whose `parent_uuid` no longer has a matching row in this set —
    # get surfaced as roots so they don't vanish from the UI.
    uuid_set = MapSet.new(categories, & &1.uuid)

    normalized =
      Enum.map(categories, fn c ->
        if c.parent_uuid == nil or MapSet.member?(uuid_set, c.parent_uuid) do
          c
        else
          %{c | parent_uuid: nil}
        end
      end)

    index = Tree.build_children_index(normalized)

    {acc, _} =
      Enum.reduce(Map.get(index, nil, []), {[], index}, fn root, {acc, idx} ->
        {collect_tree(root, idx, 0, acc), idx}
      end)

    Enum.reverse(acc)
  end

  defp collect_tree(%Category{} = cat, index, depth, acc) do
    acc = [{cat, depth} | acc]

    index
    |> Map.get(cat.uuid, [])
    |> Enum.reduce(acc, fn child, acc -> collect_tree(child, index, depth + 1, acc) end)
  end

  @doc """
  Returns the next available position for a new category among its
  siblings. Position is scoped to `(catalogue_uuid, parent_uuid)` — the
  set of categories sharing the same parent within a catalogue — since
  V103's nested-category tree makes a single catalogue-wide ordering
  ambiguous.

  `parent_uuid` defaults to `nil`, i.e. root-level siblings. Returns 0
  if no siblings exist at that level, otherwise `max_position + 1`.
  """
  @spec next_category_position(Ecto.UUID.t(), Ecto.UUID.t() | nil) :: non_neg_integer()
  def next_category_position(catalogue_uuid, parent_uuid \\ nil) do
    query =
      from(c in Category,
        where: c.catalogue_uuid == ^catalogue_uuid,
        select: max(c.position)
      )

    query =
      case parent_uuid do
        nil -> where(query, [c], is_nil(c.parent_uuid))
        uuid -> where(query, [c], c.parent_uuid == ^uuid)
      end

    case repo().one(query) do
      nil -> 0
      max_pos -> max_pos + 1
    end
  end

  @doc """
  Re-indexes a sibling group of categories from a list of UUIDs.

  Sibling scope is `(catalogue_uuid, parent_uuid)` — the same scope used
  by `swap_category_positions/2` and `next_category_position/2`. The
  function loads the supplied categories, verifies they all share that
  scope, and writes positions `1..N` in the order given. UUIDs not found
  in the table are ignored; UUIDs that don't share the scope abort the
  whole batch with `{:error, :not_siblings}`.

  Two-pass updates inside a single transaction — the first pass writes
  negative positions to dodge any future unique index on
  `(catalogue_uuid, parent_uuid, position)`; the second pass writes the
  final positive values. If no such index exists today, the cost is one
  extra `UPDATE` per row, which is cheap relative to the LV round-trip
  that triggers the call.
  """
  @spec reorder_categories(Ecto.UUID.t(), Ecto.UUID.t() | nil, [Ecto.UUID.t()], keyword()) ::
          :ok | {:error, :not_siblings | :too_many_uuids | term()}
  def reorder_categories(catalogue_uuid, parent_uuid, ordered_uuids, opts \\ [])
      when is_binary(catalogue_uuid) and is_list(ordered_uuids) do
    case validate_and_apply_category_reorder(catalogue_uuid, parent_uuid, ordered_uuids) do
      {:ok, 0} ->
        # No matching rows after dedupe — silent no-op, no audit row.
        :ok

      {:ok, count} ->
        log_activity(%{
          action: "category.reordered",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "category",
          resource_uuid: List.first(Helpers.dedupe_keep_last(ordered_uuids)),
          parent_catalogue_uuid: catalogue_uuid,
          metadata: %{
            "parent_uuid" => parent_uuid,
            "count" => count
          }
        })

        :ok

      {:error, reason} when reason in [:too_many_uuids, :not_siblings] ->
        log_reorder_rejected(
          :category,
          reason,
          length(ordered_uuids),
          catalogue_uuid,
          opts
        )

        {:error, reason}

      {:error, reason} ->
        log_reorder_db_error(
          :category,
          Helpers.dedupe_keep_last(ordered_uuids),
          catalogue_uuid,
          opts
        )

        {:error, reason}
    end
  end

  @doc """
  Re-indexes multiple sibling groups of categories in **one outer
  transaction** — the LV layer hits this when a single drop touches
  more than one parent group.

  Each group is `{parent_uuid_or_nil, [uuid]}`. All groups are
  validated up front (cap + sibling scope) before any writes; if any
  group fails validation, the whole batch returns the error and no
  writes happen.

  Atomicity: a DB-level failure in any group rolls back every group.
  Beats the previous LV-side `Enum.reduce` over per-group calls,
  which committed groups one at a time and could leave partial state.
  """
  @spec reorder_categories_groups(
          Ecto.UUID.t(),
          [{Ecto.UUID.t() | nil, [Ecto.UUID.t()]}],
          keyword()
        ) :: :ok | {:error, :too_many_uuids | :not_siblings | term()}
  def reorder_categories_groups(catalogue_uuid, groups, opts \\ [])
      when is_binary(catalogue_uuid) and is_list(groups) do
    deduped_groups =
      Enum.map(groups, fn {parent_uuid, uuids} ->
        {parent_uuid, Helpers.dedupe_keep_last(uuids)}
      end)

    total_count = deduped_groups |> Enum.flat_map(fn {_p, u} -> u end) |> length()

    if total_count > @reorder_max_uuids do
      log_reorder_rejected(:category, :too_many_uuids, total_count, catalogue_uuid, opts)
      {:error, :too_many_uuids}
    else
      run_categories_groups_transaction(catalogue_uuid, deduped_groups, total_count, opts)
    end
  end

  defp run_categories_groups_transaction(catalogue_uuid, deduped_groups, total_count, opts) do
    txn_result =
      repo().transaction(fn ->
        Enum.reduce_while(deduped_groups, :ok, fn group, _acc ->
          apply_category_group_step(catalogue_uuid, group)
        end)
      end)

    case txn_result do
      {:ok, :ok} ->
        log_activity(%{
          action: "category.reordered",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "category",
          parent_catalogue_uuid: catalogue_uuid,
          metadata: %{
            "groups" => length(deduped_groups),
            "count" => total_count
          }
        })

        :ok

      {:error, reason} when reason in [:too_many_uuids, :not_siblings] ->
        log_reorder_rejected(:category, reason, total_count, catalogue_uuid, opts)
        {:error, reason}

      {:error, reason} ->
        log_reorder_db_error(
          :category,
          Enum.flat_map(deduped_groups, fn {_p, u} -> u end),
          catalogue_uuid,
          opts
        )

        {:error, reason}
    end
  end

  # Step inside `Enum.reduce_while` over groups. Returns the
  # `:cont` / `:halt` tuple the caller's reduce expects, and on error
  # rolls back the outer transaction so partial commits aren't
  # possible.
  defp apply_category_group_step(catalogue_uuid, {parent_uuid, uuids}) do
    case validate_and_apply_category_reorder_in_txn(catalogue_uuid, parent_uuid, uuids) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, repo().rollback(reason)}
    end
  end

  # Validates scope + applies the two-pass write inside its own
  # transaction. Returns `{:ok, count}` on success or `{:error, reason}`
  # without any logging — callers handle logging outside the
  # transaction so audit rows survive a rollback.
  defp validate_and_apply_category_reorder(catalogue_uuid, _parent_uuid, ordered_uuids)
       when is_binary(catalogue_uuid) and is_list(ordered_uuids) and
              length(ordered_uuids) > @reorder_max_uuids,
       do: {:error, :too_many_uuids}

  defp validate_and_apply_category_reorder(catalogue_uuid, parent_uuid, ordered_uuids)
       when is_binary(catalogue_uuid) and is_list(ordered_uuids) do
    unique_uuids = Helpers.dedupe_keep_last(ordered_uuids)

    case category_scope_check(catalogue_uuid, parent_uuid, unique_uuids) do
      :empty -> {:ok, 0}
      :ok -> commit_category_positions(unique_uuids)
      {:error, _} = err -> err
    end
  end

  defp commit_category_positions(unique_uuids) do
    case repo().transaction(fn -> write_category_positions(unique_uuids) end) do
      {:ok, _} -> {:ok, length(unique_uuids)}
      {:error, reason} -> {:error, reason}
    end
  end

  # In-transaction variant for `reorder_categories_groups/3` —
  # validates + writes without opening its own savepoint. Returns
  # `:ok` on empty/success, `{:error, reason}` otherwise.
  defp validate_and_apply_category_reorder_in_txn(catalogue_uuid, parent_uuid, unique_uuids)
       when is_binary(catalogue_uuid) and is_list(unique_uuids) do
    case category_scope_check(catalogue_uuid, parent_uuid, unique_uuids) do
      :empty -> :ok
      :ok -> write_category_positions(unique_uuids)
      {:error, _} = err -> err
    end
  end

  defp category_scope_check(catalogue_uuid, parent_uuid, unique_uuids) do
    rows =
      from(c in Category, where: c.uuid in ^unique_uuids)
      |> repo().all()

    cond do
      rows == [] ->
        :empty

      not Enum.all?(rows, fn c ->
        c.catalogue_uuid == catalogue_uuid and c.parent_uuid == parent_uuid
      end) ->
        {:error, :not_siblings}

      true ->
        :ok
    end
  end

  # Future (perf): collapse the two-pass loop below to a single
  # `UPDATE phoenix_kit_cat_categories SET position = v.pos
  #   FROM (VALUES (uuid, pos), …) AS v(uuid, pos)
  #   WHERE phoenix_kit_cat_categories.uuid = v.uuid`
  # round-trip per scope. PG checks unique constraints at statement
  # end, so a CASE-based or VALUES-join UPDATE works even with a
  # future unique index on `(catalogue_uuid, parent_uuid, position)`.
  # Trigger to revisit: `:reorder_max_uuids` config bumped past 1000,
  # or a unique index is added.
  defp write_category_positions(unique_uuids) do
    pairs = Enum.with_index(unique_uuids, 1)

    Enum.each(pairs, fn {uuid, idx} ->
      from(c in Category, where: c.uuid == ^uuid)
      |> repo().update_all(set: [position: -idx])
    end)

    Enum.each(pairs, fn {uuid, idx} ->
      from(c in Category, where: c.uuid == ^uuid)
      |> repo().update_all(set: [position: idx])
    end)

    :ok
  end

  @doc """
  Returns the next available `position` for a new catalogue — one past
  the current max, falling back to `1` on an empty table.
  """
  @spec next_catalogue_position() :: integer()
  def next_catalogue_position do
    case repo().one(from(c in Catalogue, select: max(c.position))) do
      nil -> 1
      n -> n + 1
    end
  end

  @doc """
  Re-indexes the supplied list of catalogue UUIDs into positions
  `1..N`. Used by the catalogues index DnD handler.

  UUIDs missing from the table are skipped. The whole pass runs in one
  transaction. Returns `:ok` on success or `{:error, reason}` on
  transaction failure.
  """
  @spec reorder_catalogues([Ecto.UUID.t()], keyword()) ::
          :ok | {:error, :too_many_uuids | term()}
  def reorder_catalogues(ordered_uuids, opts \\ [])

  def reorder_catalogues(ordered_uuids, opts)
      when is_list(ordered_uuids) and length(ordered_uuids) > @reorder_max_uuids do
    log_reorder_rejected(:catalogue, :too_many_uuids, length(ordered_uuids), nil, opts)
    {:error, :too_many_uuids}
  end

  def reorder_catalogues(ordered_uuids, opts) when is_list(ordered_uuids) do
    unique_uuids = Helpers.dedupe_keep_last(ordered_uuids)

    case write_catalogue_positions(unique_uuids) do
      {:ok, _} ->
        log_activity(%{
          action: "catalogue.reordered",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "catalogue",
          resource_uuid: List.first(unique_uuids),
          metadata: %{"count" => length(unique_uuids)}
        })

        :ok

      {:error, reason} ->
        log_reorder_db_error(:catalogue, unique_uuids, nil, opts)
        {:error, reason}
    end
  end

  # Future (perf): single-pass and single-statement variant once payload
  # sizes warrant it (see categories/items helpers above for the same
  # cross-reference). Catalogues currently have no unique index on
  # `position`, so the negative-pass dance isn't even strictly
  # required — kept here for parity with the other reorder paths.
  defp write_catalogue_positions(unique_uuids) do
    pairs = Enum.with_index(unique_uuids, 1)

    repo().transaction(fn ->
      Enum.each(pairs, fn {uuid, idx} ->
        from(c in Catalogue, where: c.uuid == ^uuid)
        |> repo().update_all(set: [position: idx])
      end)
    end)
  end

  @doc """
  Returns the next available `position` for a new item within a scope.

  Items are scoped to `(catalogue_uuid, category_uuid)`. Pass
  `category_uuid: nil` for the uncategorized bucket of a catalogue.
  """
  @spec next_item_position(Ecto.UUID.t(), Ecto.UUID.t() | nil) :: integer()
  def next_item_position(catalogue_uuid, category_uuid)
      when is_binary(catalogue_uuid) do
    query =
      from(i in Item,
        where: i.catalogue_uuid == ^catalogue_uuid,
        select: max(i.position)
      )

    query =
      case category_uuid do
        nil -> where(query, [i], is_nil(i.category_uuid))
        uuid -> where(query, [i], i.category_uuid == ^uuid)
      end

    case repo().one(query) do
      nil -> 1
      n -> n + 1
    end
  end

  @doc """
  Re-indexes the items inside a `(catalogue_uuid, category_uuid)`
  bucket. Pass `category_uuid: nil` to reorder the uncategorized
  bucket. Behaves like `reorder_categories/4`: validates scope, runs
  two passes inside a transaction, logs an activity row.

  UUIDs that don't belong to the scope abort with
  `{:error, :wrong_scope}` so a stale DOM can't bleed reorder writes
  across catalogues.
  """
  @spec reorder_items(Ecto.UUID.t(), Ecto.UUID.t() | nil, [Ecto.UUID.t()], keyword()) ::
          :ok | {:error, :wrong_scope | :too_many_uuids | term()}
  def reorder_items(catalogue_uuid, category_uuid, ordered_uuids, opts \\ [])
      when is_binary(catalogue_uuid) and is_list(ordered_uuids) do
    case validate_and_apply_item_reorder(catalogue_uuid, category_uuid, ordered_uuids) do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        unique_uuids = Helpers.dedupe_keep_last(ordered_uuids)

        log_activity(%{
          action: "item.reordered",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "item",
          resource_uuid: List.first(unique_uuids),
          parent_catalogue_uuid: catalogue_uuid,
          metadata: %{
            "category_uuid" => category_uuid,
            "count" => count
          }
        })

        :ok

      {:error, reason} when reason in [:too_many_uuids, :wrong_scope] ->
        log_reorder_rejected(
          :item,
          reason,
          length(ordered_uuids),
          catalogue_uuid,
          opts
        )

        {:error, reason}

      {:error, reason} ->
        log_reorder_db_error(
          :item,
          Helpers.dedupe_keep_last(ordered_uuids),
          catalogue_uuid,
          opts,
          category_uuid: category_uuid
        )

        {:error, reason}
    end
  end

  # Validates scope + applies the two-pass write inside its own
  # transaction. Returns `{:ok, count}` on success or `{:error, reason}`
  # without any logging — callers (incl. `move_item_and_reorder_destination/4`)
  # handle logging outside the transaction so audit rows survive a
  # rollback.
  defp validate_and_apply_item_reorder(catalogue_uuid, _category_uuid, ordered_uuids)
       when is_binary(catalogue_uuid) and is_list(ordered_uuids) and
              length(ordered_uuids) > @reorder_max_uuids,
       do: {:error, :too_many_uuids}

  defp validate_and_apply_item_reorder(catalogue_uuid, category_uuid, ordered_uuids)
       when is_binary(catalogue_uuid) and is_list(ordered_uuids) do
    unique_uuids = Helpers.dedupe_keep_last(ordered_uuids)

    case item_scope_check(catalogue_uuid, category_uuid, unique_uuids) do
      :empty -> {:ok, 0}
      :ok -> commit_item_positions(unique_uuids)
      {:error, _} = err -> err
    end
  end

  defp commit_item_positions(unique_uuids) do
    case repo().transaction(fn -> write_item_positions(unique_uuids) end) do
      {:ok, _} -> {:ok, length(unique_uuids)}
      {:error, reason} -> {:error, reason}
    end
  end

  # In-transaction variant — used by `move_item_and_reorder_destination/4`
  # so the move + reorder live inside one outer transaction without a
  # nested savepoint.
  defp validate_and_apply_item_reorder_in_txn(catalogue_uuid, category_uuid, ordered_uuids)
       when is_binary(catalogue_uuid) and is_list(ordered_uuids) do
    if length(ordered_uuids) > @reorder_max_uuids do
      {:error, :too_many_uuids}
    else
      unique_uuids = Helpers.dedupe_keep_last(ordered_uuids)

      case item_scope_check(catalogue_uuid, category_uuid, unique_uuids) do
        :empty -> {:ok, 0}
        :ok -> {:ok, write_item_positions_count(unique_uuids)}
        {:error, _} = err -> err
      end
    end
  end

  defp item_scope_check(catalogue_uuid, category_uuid, unique_uuids) do
    rows =
      from(i in Item, where: i.uuid in ^unique_uuids)
      |> repo().all()

    cond do
      rows == [] ->
        :empty

      not Enum.all?(rows, fn i ->
        i.catalogue_uuid == catalogue_uuid and i.category_uuid == category_uuid
      end) ->
        {:error, :wrong_scope}

      true ->
        :ok
    end
  end

  # Future (perf): collapse the two-pass loop below to a single
  # `UPDATE phoenix_kit_cat_items SET position = v.pos
  #   FROM (VALUES (uuid, pos), …) AS v(uuid, pos)
  #   WHERE phoenix_kit_cat_items.uuid = v.uuid`
  # round-trip per scope. Trigger to revisit: `:reorder_max_uuids`
  # config bumped past 1000, or a unique index on
  # `(catalogue_uuid, category_uuid, position)` is added.
  defp write_item_positions(unique_uuids) do
    pairs = Enum.with_index(unique_uuids, 1)

    Enum.each(pairs, fn {uuid, idx} ->
      from(i in Item, where: i.uuid == ^uuid)
      |> repo().update_all(set: [position: -idx])
    end)

    Enum.each(pairs, fn {uuid, idx} ->
      from(i in Item, where: i.uuid == ^uuid)
      |> repo().update_all(set: [position: idx])
    end)

    :ok
  end

  defp write_item_positions_count(unique_uuids) do
    write_item_positions(unique_uuids)
    length(unique_uuids)
  end

  # ═══════════════════════════════════════════════════════════════════
  # Items
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Lists all non-deleted items across all catalogues, ordered by name.

  Preloads category (with catalogue) and manufacturer.

  ## Options

    * `:status` — filter by status (e.g. `"active"`, `"inactive"`).
      When nil (default), returns all non-deleted items.
    * `:limit` — max results to return (default: no limit)

  ## Examples

      Catalogue.list_items()                          # all non-deleted
      Catalogue.list_items(status: "active")          # only active
      Catalogue.list_items(limit: 100)                # first 100
  """
  @spec list_items(keyword()) :: [Item.t()]
  def list_items(opts \\ []) do
    query =
      from(i in Item,
        order_by: [asc: i.position, asc: i.name],
        preload: [:catalogue, category: :catalogue, manufacturer: []]
      )

    query =
      case Keyword.get(opts, :status) do
        nil -> where(query, [i], i.status != "deleted")
        status -> where(query, [i], i.status == ^status)
      end

    query =
      case Keyword.get(opts, :limit) do
        nil -> query
        limit -> limit(query, ^limit)
      end

    repo().all(query)
  end

  @doc """
  Lists non-deleted items for a category, ordered by position then name.

  Default preloads `[:catalogue, category: :catalogue, manufacturer: []]`.
  Pass `:preload` in `opts` to add more (e.g.
  `preload: [catalogue_rules: :referenced_catalogue]` for smart-pricing
  consumers); the lists are concatenated, not replaced.
  """
  @spec list_items_for_category(Ecto.UUID.t(), keyword()) :: [Item.t()]
  def list_items_for_category(category_uuid, opts \\ []) do
    from(i in Item,
      where: i.category_uuid == ^category_uuid and i.status != "deleted",
      order_by: [asc: i.position, asc: i.name],
      preload: ^Helpers.merge_preloads([:catalogue, category: :catalogue, manufacturer: []], opts)
    )
    |> repo().all()
  end

  @doc """
  Lists non-deleted items for a catalogue, ordered by category position then
  item name. Includes uncategorized items (those with no category) at the end.

  Default preloads `[:catalogue, category: :catalogue, manufacturer: []]`.
  Pass `:preload` in `opts` to add more — see `list_items_for_category/2`.
  """
  @spec list_items_for_catalogue(Ecto.UUID.t(), keyword()) :: [Item.t()]
  def list_items_for_catalogue(catalogue_uuid, opts \\ []) do
    from(i in Item,
      left_join: c in Category,
      on: i.category_uuid == c.uuid,
      where: i.catalogue_uuid == ^catalogue_uuid and i.status != "deleted",
      order_by: [asc_nulls_last: c.position, asc: i.position, asc: i.name],
      preload: ^Helpers.merge_preloads([:catalogue, category: :catalogue, manufacturer: []], opts)
    )
    |> repo().all()
  end

  @doc """
  Lists soft-deleted items in a catalogue as a flat list, ordered by
  deletion date (most-recently-deleted first). `updated_at` is the
  deletion-time proxy — flipping `status` to `"deleted"` always bumps
  it. Used by the Items tab Deleted view, which surfaces a recency-
  ordered audit list rather than category-grouped cards.

  ## Options

    * `:limit` — caps the list (default 500). Pagination isn't wired
      yet; if a catalogue routinely exceeds the limit, layer a cursor
      on top of this query.
    * `:preload` — extra associations on top of the default
      `[:catalogue, category: :catalogue, manufacturer: []]`.

  ## Examples

      Catalogue.list_deleted_items_for_catalogue(catalogue_uuid)
  """
  @spec list_deleted_items_for_catalogue(Ecto.UUID.t(), keyword()) :: [Item.t()]
  def list_deleted_items_for_catalogue(catalogue_uuid, opts \\ []) do
    limit = Keyword.get(opts, :limit, 500)

    from(i in Item,
      where: i.catalogue_uuid == ^catalogue_uuid and i.status == "deleted",
      order_by: [desc: i.updated_at, asc: i.uuid],
      limit: ^limit,
      preload: ^Helpers.merge_preloads([:catalogue, category: :catalogue, manufacturer: []], opts)
    )
    |> repo().all()
  end

  @doc """
  Lists uncategorized items (no category assigned) for a specific catalogue.

  ## Options

    * `:mode` — `:active` (default) excludes deleted items;
      `:deleted` returns only deleted items.
    * `:preload` — extra associations appended to the default
      `[:catalogue, :manufacturer]` preloads. Pass
      `[catalogue_rules: :referenced_catalogue]` for smart-pricing.

  ## Examples

      Catalogue.list_uncategorized_items(catalogue_uuid)
      Catalogue.list_uncategorized_items(catalogue_uuid, mode: :deleted)
  """
  @spec list_uncategorized_items(Ecto.UUID.t(), keyword()) :: [Item.t()]
  def list_uncategorized_items(catalogue_uuid, opts \\ []) do
    mode = Keyword.get(opts, :mode, :active)
    preloads = Helpers.merge_preloads([:catalogue, :manufacturer], opts)

    query =
      from(i in Item,
        where: i.catalogue_uuid == ^catalogue_uuid and is_nil(i.category_uuid),
        order_by: [asc: i.position, asc: i.name],
        preload: ^preloads
      )

    query =
      case mode do
        :active -> where(query, [i], i.status != "deleted")
        :deleted -> where(query, [i], i.status == "deleted")
      end

    repo().all(query)
  end

  @doc """
  Fetches an item by UUID. Returns `nil` if not found.

  ## Options

    * `:preload` — list of associations to preload. Default `[]`.
      Common smart-pricing preload: `[catalogue_rules: :referenced_catalogue]`.

  ## Examples

      Catalogue.get_item(uuid)
      Catalogue.get_item(uuid, preload: [:catalogue, catalogue_rules: :referenced_catalogue])
  """
  @spec get_item(Ecto.UUID.t(), keyword()) :: Item.t() | nil
  def get_item(uuid, opts \\ []) do
    case repo().get(Item, uuid) do
      nil -> nil
      item -> repo().preload(item, Keyword.get(opts, :preload, []))
    end
  end

  @doc """
  Fetches an item by UUID with preloaded `:catalogue`, `:category`, and
  `:manufacturer`. Raises `Ecto.NoResultsError` if not found.

  Pass `:preload` to add more associations (concatenated with the
  defaults).
  """
  @spec get_item!(Ecto.UUID.t(), keyword()) :: Item.t()
  def get_item!(uuid, opts \\ []) do
    Item
    |> repo().get!(uuid)
    |> repo().preload(Helpers.merge_preloads([:catalogue, :category, :manufacturer], opts))
  end

  @doc """
  Bulk-fetches items by a list of UUIDs. Excludes soft-deleted items.
  Result order matches the input UUID order; missing UUIDs are dropped
  (no `nil` placeholders, no error). Duplicate input UUIDs collapse to
  a single result.

  Designed for snapshot rehydration — e.g. an order stored as a list of
  item UUIDs that needs full item data on reload. Avoids the N+1 trap
  of looping `get_item/1` per UUID.

  ## Options

    * `:preload` — extra associations appended to the default
      `[:catalogue, :category, :manufacturer]`. Pass
      `[catalogue_rules: :referenced_catalogue]` for smart-pricing.

  ## Examples

      Catalogue.list_items_by_uuids([uuid1, uuid2, uuid3])
      Catalogue.list_items_by_uuids(uuids, preload: [catalogue_rules: :referenced_catalogue])
  """
  @spec list_items_by_uuids([Ecto.UUID.t()], keyword()) :: [Item.t()]
  def list_items_by_uuids(uuids, opts \\ [])

  def list_items_by_uuids([], _opts), do: []

  def list_items_by_uuids(uuids, opts) when is_list(uuids) do
    preloads = Helpers.merge_preloads([:catalogue, :category, :manufacturer], opts)

    items_by_uuid =
      from(i in Item,
        where: i.uuid in ^uuids and i.status != "deleted",
        preload: ^preloads
      )
      |> repo().all()
      |> Map.new(&{&1.uuid, &1})

    uuids
    |> Enum.uniq()
    |> Enum.flat_map(fn uuid ->
      case Map.get(items_by_uuid, uuid) do
        nil -> []
        item -> [item]
      end
    end)
  end

  @doc """
  Creates an item.

  ## Required attributes

    * `:name` — item name (1-255 chars)
    * `:catalogue_uuid` — the parent catalogue (required). Auto-derived from
      `:category_uuid` when omitted and a category is provided.

  ## Optional attributes

    * `:description` — text description
    * `:sku` — stock keeping unit (unique, max 100 chars)
    * `:base_price` — decimal, must be >= 0 (cost/purchase price before markup)
    * `:unit` — `"piece"` (default), `"m2"`, or `"running_meter"`
    * `:status` — `"active"` (default), `"inactive"`, `"discontinued"`, or `"deleted"`
    * `:category_uuid` — the parent category (optional — leave nil for uncategorized items)
    * `:manufacturer_uuid` — the manufacturer (optional)
    * `:data` — flexible JSON map

  ## Examples

      Catalogue.create_item(%{name: "Oak Panel 18mm", catalogue_uuid: cat.uuid, base_price: 25.50})
      Catalogue.create_item(%{name: "Hinge", category_uuid: category.uuid, manufacturer_uuid: m.uuid})
  """
  @spec create_item(map(), keyword()) ::
          {:ok, Item.t()} | {:error, Ecto.Changeset.t(Item.t())}
  def create_item(attrs, opts \\ []) do
    skip_derive? = Keyword.get(opts, :skip_derive, false)
    attrs = maybe_put_item_position(attrs)

    # We run derivation + insert in the same transaction so that the
    # `FOR SHARE` row lock inside `put_catalogue_from_effective_category`
    # is held until the INSERT commits. That closes the race with a
    # concurrent `move_category_to_catalogue/3` (which takes `FOR UPDATE`
    # on the same row): while the move holds the exclusive lock, our
    # derive waits; once we hold the shared lock, the move waits — so an
    # item can never be inserted with a stale `catalogue_uuid` mid-move.
    result =
      repo().transaction(fn ->
        attrs = if skip_derive?, do: attrs, else: derive_catalogue_uuid(nil, attrs)

        case %Item{} |> Item.changeset(attrs) |> repo().insert() do
          {:ok, item} -> item
          {:error, changeset} -> repo().rollback(changeset)
        end
      end)

    case result do
      {:ok, item} ->
        log_activity(
          %{
            action: "item.created",
            mode: opts[:mode] || "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "item",
            resource_uuid: item.uuid,
            parent_catalogue_uuid: item.catalogue_uuid,
            metadata: %{"name" => item.name, "sku" => item.sku || ""}
          },
          opts
        )

        {:ok, item}

      {:error, _changeset} = error ->
        error
    end
  end

  # Keeps `catalogue_uuid` in lockstep with `category_uuid`. The
  # category is the single source of truth: an item in a category must
  # live in that category's catalogue. We compute the *effective*
  # resulting `category_uuid` (new value if attrs mentions it, otherwise
  # the item's current value) and, whenever that yields a category, we
  # set `catalogue_uuid` to that category's `catalogue_uuid` — overriding
  # any stale value the caller might have passed. This prevents silent
  # inconsistencies where an item ends up with a category in catalogue A
  # but `catalogue_uuid` pointing at catalogue B.
  #
  # Also normalizes an empty-string `category_uuid` from form params
  # into `nil` so the changeset treats it as "clear category" rather
  # than attempting a malformed DB lookup.
  #
  # Accepts both atom- and string-keyed maps, and a `nil` item for the
  # create path.
  defp derive_catalogue_uuid(item, attrs) when is_map(attrs) do
    attrs
    |> normalize_blank_category()
    |> put_catalogue_from_effective_category(effective_category_uuid(item, attrs))
  end

  # Returns the category_uuid the item will have *after* this
  # create/update: the incoming one from attrs if provided (nil if it's
  # an empty string), otherwise the item's current value (nil on create).
  defp effective_category_uuid(item, attrs) do
    if Helpers.has_attr?(attrs, :category_uuid) do
      attrs |> Helpers.fetch_attr(:category_uuid) |> blank_to_nil()
    else
      item && Map.get(item, :category_uuid)
    end
  end

  # An empty-string `category_uuid` arrives from form params; normalize it
  # to `nil` so the changeset treats it as "clear category" instead of
  # tripping a malformed FK lookup.
  defp normalize_blank_category(attrs) do
    if Helpers.has_attr?(attrs, :category_uuid) and
         Helpers.fetch_attr(attrs, :category_uuid) == "" do
      Helpers.put_attr(attrs, :category_uuid, nil)
    else
      attrs
    end
  end

  # If the effective category exists, pin `catalogue_uuid` to that
  # category's catalogue — this is the single source of truth and
  # overrides any stale value the caller might have passed. If no
  # category exists in the resulting state, leave `catalogue_uuid`
  # alone; `validate_required` enforces it ends up set.
  #
  # The `FOR SHARE` row lock closes the move_category race: see the
  # comment in `create_item/2`. Must be invoked inside a transaction
  # for the lock to persist until the insert/update commits.
  defp put_catalogue_from_effective_category(attrs, nil), do: attrs

  defp put_catalogue_from_effective_category(attrs, category_uuid)
       when is_binary(category_uuid) do
    query = from(c in Category, where: c.uuid == ^category_uuid, lock: "FOR SHARE")

    case repo().one(query) do
      %Category{catalogue_uuid: cat_uuid} ->
        Helpers.put_attr(attrs, :catalogue_uuid, cat_uuid)

      nil ->
        # Target category doesn't exist — leave attrs as-is so the
        # changeset's FK constraint surfaces a clear error.
        attrs
    end
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  @doc "Updates an item with the given attributes."
  @spec update_item(Item.t(), map(), keyword()) ::
          {:ok, Item.t()} | {:error, Ecto.Changeset.t(Item.t())}
  def update_item(%Item{} = item, attrs, opts \\ []) do
    skip_derive? = Keyword.get(opts, :skip_derive, false)

    result =
      repo().transaction(fn ->
        attrs = if skip_derive?, do: attrs, else: derive_catalogue_uuid(item, attrs)

        case item |> Item.changeset(attrs) |> repo().update() do
          {:ok, updated} -> updated
          {:error, changeset} -> repo().rollback(changeset)
        end
      end)

    case result do
      {:ok, updated} ->
        log_activity(%{
          action: "item.updated",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "item",
          resource_uuid: updated.uuid,
          parent_catalogue_uuid: updated.catalogue_uuid,
          metadata: %{"name" => updated.name, "sku" => updated.sku || ""}
        })

        {:ok, updated}

      {:error, _changeset} = error ->
        error
    end
  end

  @doc "Hard-deletes an item. Prefer `trash_item/1` for soft-delete."
  @spec delete_item(Item.t(), keyword()) :: {:ok, Item.t()} | {:error, term()}
  def delete_item(%Item{} = item, opts \\ []) do
    case repo().delete(item) do
      {:ok, _} = ok ->
        log_activity(%{
          action: "item.deleted",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "item",
          resource_uuid: item.uuid,
          parent_catalogue_uuid: item.catalogue_uuid,
          metadata: %{"name" => item.name}
        })

        ok

      error ->
        error
    end
  end

  @doc """
  Soft-deletes an item by setting its status to `"deleted"`.

  ## Examples

      {:ok, item} = Catalogue.trash_item(item)
  """
  @spec trash_item(Item.t(), keyword()) ::
          {:ok, Item.t()} | {:error, Ecto.Changeset.t(Item.t())}
  def trash_item(%Item{} = item, opts \\ []) do
    case item |> Item.changeset(%{status: "deleted"}) |> repo().update() do
      {:ok, trashed} = ok ->
        log_activity(%{
          action: "item.trashed",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "item",
          resource_uuid: trashed.uuid,
          parent_catalogue_uuid: trashed.catalogue_uuid,
          metadata: %{"name" => trashed.name}
        })

        ok

      error ->
        error
    end
  end

  @doc """
  Restores a soft-deleted item by setting its status to `"active"`.

  Refuses with `{:error, :parent_catalogue_deleted}` when the item's
  parent catalogue is itself deleted — the operator must restore the
  catalogue first. (An item cannot exist outside a catalogue.)

  When the parent catalogue is active but the item's category is
  deleted, the item is **uncategorized on restore**: `category_uuid` is
  set to `nil` so the item resurfaces in the catalogue's Uncategorized
  bucket. This avoids the surprising side-effect of auto-reviving the
  whole category structure. If the user wants the category back, they
  restore the category explicitly (which cascades downward and brings
  the item with it via `category_uuid` matching).

  ## Examples

      {:ok, item} = Catalogue.restore_item(item)
      {:error, :parent_catalogue_deleted} =
        Catalogue.restore_item(item_under_deleted_catalogue)
  """
  @spec restore_item(Item.t(), keyword()) ::
          {:ok, Item.t()} | {:error, :parent_catalogue_deleted | term()}
  def restore_item(%Item{} = item, opts \\ []) do
    result =
      repo().transaction(fn ->
        case repo().get(Catalogue, item.catalogue_uuid) do
          %Catalogue{status: "deleted"} ->
            repo().rollback(:parent_catalogue_deleted)

          _ ->
            :ok
        end

        detached? = category_deleted?(item.category_uuid)

        attrs =
          if detached?,
            do: %{status: "active", category_uuid: nil},
            else: %{status: "active"}

        restored =
          item
          |> Item.changeset(attrs)
          |> repo().update!()

        {restored, detached?}
      end)

    with {:ok, {restored, detached?}} <- result do
      log_activity(%{
        action: "item.restored",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "item",
        resource_uuid: restored.uuid,
        parent_catalogue_uuid: restored.catalogue_uuid,
        metadata:
          %{"name" => restored.name}
          |> Map.merge(if detached?, do: %{"detached_from_category" => true}, else: %{})
      })

      {:ok, restored}
    end
  end

  defp category_deleted?(nil), do: false

  defp category_deleted?(category_uuid) do
    case repo().get(Category, category_uuid) do
      %Category{status: "deleted"} -> true
      _ -> false
    end
  end

  @doc """
  Permanently deletes an item from the database. This cannot be undone.

  ## Examples

      {:ok, _} = Catalogue.permanently_delete_item(item)
  """
  @spec permanently_delete_item(Item.t(), keyword()) :: {:ok, Item.t()} | {:error, term()}
  def permanently_delete_item(%Item{} = item, opts \\ []) do
    case repo().delete(item) do
      {:ok, _} = ok ->
        log_activity(%{
          action: "item.permanently_deleted",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "item",
          resource_uuid: item.uuid,
          parent_catalogue_uuid: item.catalogue_uuid,
          metadata: %{"name" => item.name}
        })

        ok

      error ->
        error
    end
  end

  @doc """
  Bulk soft-deletes all non-deleted items in a category.

  Returns `{count, nil}` where count is the number of items affected.

  ## Examples

      {3, nil} = Catalogue.trash_items_in_category(category_uuid)
  """
  @spec trash_items_in_category(Ecto.UUID.t(), keyword()) :: {non_neg_integer(), nil}
  def trash_items_in_category(category_uuid, opts \\ []) do
    {count, _} =
      from(i in Item,
        where: i.category_uuid == ^category_uuid and i.status != "deleted"
      )
      |> repo().update_all(set: [status: "deleted", updated_at: DateTime.utc_now()])

    if count > 0 do
      log_activity(%{
        action: "item.bulk_trashed",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "item",
        metadata: %{"category_uuid" => category_uuid, "count" => count}
      })
    end

    {count, nil}
  end

  # ── Bulk actions on UUID lists (admin selection toolbar) ──────

  @doc """
  Bulk soft-deletes items by UUID. Empty list is a no-op. Logs a single
  `item.bulk_trashed` activity row when count > 0.
  """
  @spec bulk_trash_items([Ecto.UUID.t()], keyword()) :: {non_neg_integer(), nil}
  def bulk_trash_items([], _opts), do: {0, nil}

  def bulk_trash_items(uuids, opts) when is_list(uuids) do
    {count, _} =
      from(i in Item, where: i.uuid in ^uuids and i.status != "deleted")
      |> repo().update_all(set: [status: "deleted", updated_at: DateTime.utc_now()])

    if count > 0 do
      log_activity(%{
        action: "item.bulk_trashed",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "item",
        metadata: %{"count" => count, "uuids" => uuids}
      })
    end

    {count, nil}
  end

  @doc """
  Bulk restores items by UUID. Refuses any item whose parent catalogue
  is deleted (returns the count of *attempted* successes; skipped ones
  are excluded). Items with deleted parent categories are uncategorized
  on restore — same rule as `restore_item/2`.
  """
  @spec bulk_restore_items([Ecto.UUID.t()], keyword()) :: {non_neg_integer(), nil}
  def bulk_restore_items([], _opts), do: {0, nil}

  def bulk_restore_items(uuids, opts) when is_list(uuids) do
    now = DateTime.utc_now()

    items =
      from(i in Item,
        where: i.uuid in ^uuids and i.status == "deleted",
        preload: [:catalogue, :category]
      )
      |> repo().all()
      |> Enum.reject(fn i -> i.catalogue && i.catalogue.status == "deleted" end)

    {ok_uuids, detached_uuids} =
      Enum.reduce(items, {[], []}, fn item, {ok_acc, det_acc} ->
        if item.category && item.category.status == "deleted" do
          {[item.uuid | ok_acc], [item.uuid | det_acc]}
        else
          {[item.uuid | ok_acc], det_acc}
        end
      end)

    {count_attached, _} =
      from(i in Item,
        where: i.uuid in ^(ok_uuids -- detached_uuids) and i.status == "deleted"
      )
      |> repo().update_all(set: [status: "active", updated_at: now])

    {count_detached, _} =
      from(i in Item, where: i.uuid in ^detached_uuids and i.status == "deleted")
      |> repo().update_all(set: [status: "active", category_uuid: nil, updated_at: now])

    count = count_attached + count_detached

    if count > 0 do
      log_activity(%{
        action: "item.bulk_restored",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "item",
        metadata: %{
          "count" => count,
          "detached_count" => count_detached,
          "uuids" => ok_uuids
        }
      })
    end

    {count, nil}
  end

  @doc """
  Bulk hard-deletes items by UUID. Use with care — no soft-delete cycle.
  Logs a single `item.bulk_permanently_deleted` activity row when
  count > 0.
  """
  @spec bulk_permanently_delete_items([Ecto.UUID.t()], keyword()) ::
          {non_neg_integer(), nil}
  def bulk_permanently_delete_items([], _opts), do: {0, nil}

  def bulk_permanently_delete_items(uuids, opts) when is_list(uuids) do
    {count, _} = from(i in Item, where: i.uuid in ^uuids) |> repo().delete_all()

    if count > 0 do
      log_activity(%{
        action: "item.bulk_permanently_deleted",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "item",
        metadata: %{"count" => count, "uuids" => uuids}
      })
    end

    {count, nil}
  end

  @doc """
  Bulk-moves items to a target category within a single catalogue.

  ## Required opts

    * `:catalogue_uuid` — the calling LV's catalogue scope. Every item
      in `uuids` MUST already belong to this catalogue, and `target_uuid`
      (when not `nil`) must live in this catalogue. The single-item DnD
      handler enforces the same scope; this guard makes the bulk path
      symmetric so a crafted client request can't silently flip an
      item's `catalogue_uuid` cross-catalogue.

  Pass `target_uuid: nil` to uncategorize all items within their
  catalogue.

  Returns `{:ok, count}`, `{:error, :category_not_found}` (target),
  `{:error, :wrong_catalogue_scope}` (target lives elsewhere or one or
  more items don't belong to `:catalogue_uuid`), or
  `{:error, :missing_catalogue_scope}` (caller forgot the required opt).
  """
  @spec bulk_move_items_to_category([Ecto.UUID.t()], Ecto.UUID.t() | nil, keyword()) ::
          {:ok, non_neg_integer()}
          | {:error, :category_not_found}
          | {:error, :wrong_catalogue_scope}
          | {:error, :missing_catalogue_scope}
  def bulk_move_items_to_category([], _target, _opts), do: {:ok, 0}

  def bulk_move_items_to_category(uuids, target_uuid, opts) when is_list(uuids) do
    case Keyword.fetch(opts, :catalogue_uuid) do
      :error ->
        {:error, :missing_catalogue_scope}

      {:ok, catalogue_uuid} when is_binary(catalogue_uuid) ->
        with :ok <- ensure_items_in_catalogue(uuids, catalogue_uuid),
             {:ok, target} <- resolve_move_target(target_uuid, catalogue_uuid) do
          do_bulk_move(uuids, target, catalogue_uuid, opts)
        end
    end
  end

  defp ensure_items_in_catalogue(uuids, catalogue_uuid) do
    foreign? =
      from(i in Item,
        where: i.uuid in ^uuids and i.catalogue_uuid != ^catalogue_uuid,
        limit: 1,
        select: i.uuid
      )
      |> repo().exists?()

    if foreign?, do: {:error, :wrong_catalogue_scope}, else: :ok
  end

  defp resolve_move_target(nil, _catalogue_uuid), do: {:ok, nil}

  defp resolve_move_target(target_uuid, catalogue_uuid) do
    case repo().get(Category, target_uuid) do
      nil ->
        {:error, :category_not_found}

      %Category{catalogue_uuid: ^catalogue_uuid} = cat ->
        {:ok, cat}

      %Category{} ->
        {:error, :wrong_catalogue_scope}
    end
  end

  defp do_bulk_move(uuids, nil, catalogue_uuid, opts) do
    {count, _} =
      from(i in Item, where: i.uuid in ^uuids)
      |> repo().update_all(set: [category_uuid: nil, updated_at: DateTime.utc_now()])

    if count > 0 do
      log_activity(%{
        action: "item.bulk_moved",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "item",
        parent_catalogue_uuid: catalogue_uuid,
        metadata: %{"count" => count, "to_category_uuid" => nil}
      })
    end

    {:ok, count}
  end

  defp do_bulk_move(uuids, %Category{} = target, _catalogue_uuid, opts) do
    {count, _} =
      from(i in Item, where: i.uuid in ^uuids)
      |> repo().update_all(set: [category_uuid: target.uuid, updated_at: DateTime.utc_now()])

    if count > 0 do
      log_activity(%{
        action: "item.bulk_moved",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "item",
        parent_catalogue_uuid: target.catalogue_uuid,
        metadata: %{
          "count" => count,
          "to_category_uuid" => target.uuid,
          "to_catalogue_uuid" => target.catalogue_uuid
        }
      })
    end

    {:ok, count}
  end

  @doc """
  Bulk soft-deletes categories by UUID with a uniform item disposition
  (cascade / uncategorize / move_to). Each category goes through the
  same logic as `trash_category/2`. Returns `{:ok, %{categories:
  count, items_handled: count}}` or surfaces the first error.
  """
  @spec bulk_trash_categories(
          [Ecto.UUID.t()],
          :cascade | :uncategorize | {:move_to, Ecto.UUID.t()},
          keyword()
        ) ::
          {:ok, %{categories: non_neg_integer(), items_handled: non_neg_integer()}}
          | {:error, term()}
  def bulk_trash_categories([], _disposition, _opts),
    do: {:ok, %{categories: 0, items_handled: 0}}

  def bulk_trash_categories(uuids, disposition, opts) when is_list(uuids) do
    repo().transaction(fn ->
      Enum.reduce_while(uuids, %{categories: 0, items_handled: 0}, fn uuid, acc ->
        bulk_trash_category_step(uuid, disposition, opts, acc)
      end)
    end)
    |> case do
      {:ok, summary} -> {:ok, summary}
      error -> error
    end
  end

  defp bulk_trash_category_step(uuid, disposition, opts, acc) do
    case repo().get(Category, uuid) do
      nil -> {:cont, acc}
      %Category{status: "deleted"} -> {:cont, acc}
      %Category{} = category -> trash_one_in_bulk(category, disposition, opts, acc)
    end
  end

  defp trash_one_in_bulk(category, disposition, opts, acc) do
    case trash_category(category, Keyword.put(opts, :items, disposition)) do
      {:ok, _} -> {:cont, %{acc | categories: acc.categories + 1}}
      {:error, reason} -> {:halt, repo().rollback(reason)}
    end
  end

  @doc """
  Moves an item to a different category.

  If the target category lives in a different catalogue, the item's
  `catalogue_uuid` is updated to match. Passing `nil` for `category_uuid`
  detaches the item from any category while keeping it in its current
  catalogue.

  ## Examples

      {:ok, item} = Catalogue.move_item_to_category(item, new_category_uuid)
      {:ok, item} = Catalogue.move_item_to_category(item, nil)  # make uncategorized
  """
  @spec move_item_to_category(Item.t(), Ecto.UUID.t() | nil, keyword()) ::
          {:ok, Item.t()} | {:error, :category_not_found | Ecto.Changeset.t(Item.t())}
  def move_item_to_category(%Item{} = item, category_uuid, opts \\ []) do
    from_category_uuid = item.category_uuid

    with {:ok, attrs} <- resolve_move_attrs(category_uuid),
         {:ok, moved} <- item |> Item.changeset(attrs) |> repo().update() do
      log_activity(%{
        action: "item.moved",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "item",
        resource_uuid: moved.uuid,
        parent_catalogue_uuid: moved.catalogue_uuid,
        metadata: %{
          "name" => moved.name,
          "from_category_uuid" => from_category_uuid,
          "to_category_uuid" => category_uuid
        }
      })

      {:ok, moved}
    end
  end

  @doc """
  Atomic combine of `move_item_to_category/3` and `reorder_items/4` for
  the cross-category drag-and-drop case.

  The DnD path triggers two writes on a single drop: the moved item's
  `category_uuid` flips, and the destination category's `position`
  values get re-indexed to match the visual order. Calling the two
  context fns separately leaves a window where the move commits but
  the reorder rolls back, leaving the item in the new category with
  a stale position. Wrapping both in a single `repo().transaction/1`
  closes that window — either both land or both roll back.

  Calls the unlogged `validate_and_apply_item_reorder_in_txn/3` so
  rejection / db-error audit rows are written **outside** the outer
  transaction. Otherwise a rejection inside the inner reorder would
  log a row that the outer rollback then discards, reopening the
  audit-trail gap.

  Activity-log fan-out: `item.moved` lands inside the inner
  `move_item_to_category/3` (rolled back if the reorder fails, which
  is correct — the move didn't actually happen). `item.reordered`
  lands here, after the outer transaction commits.
  """
  @spec move_item_and_reorder_destination(
          Item.t(),
          Ecto.UUID.t() | nil,
          [Ecto.UUID.t()],
          keyword()
        ) ::
          {:ok, Item.t()}
          | {:error, :category_not_found | :wrong_scope | :too_many_uuids | term()}
  def move_item_and_reorder_destination(
        %Item{} = item,
        to_category_uuid,
        ordered_uuids,
        opts \\ []
      ) do
    txn_result =
      repo().transaction(fn ->
        with {:ok, moved} <- move_item_to_category(item, to_category_uuid, opts),
             {:ok, count} <-
               validate_and_apply_item_reorder_in_txn(
                 moved.catalogue_uuid,
                 to_category_uuid,
                 ordered_uuids
               ) do
          {moved, count}
        else
          {:error, reason} -> repo().rollback(reason)
        end
      end)

    case txn_result do
      {:ok, {moved, 0}} ->
        {:ok, moved}

      {:ok, {moved, count}} ->
        log_activity(%{
          action: "item.reordered",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "item",
          resource_uuid: List.first(Helpers.dedupe_keep_last(ordered_uuids)),
          parent_catalogue_uuid: moved.catalogue_uuid,
          metadata: %{
            "category_uuid" => to_category_uuid,
            "count" => count
          }
        })

        {:ok, moved}

      {:error, reason} when reason in [:too_many_uuids, :wrong_scope] ->
        log_reorder_rejected(
          :item,
          reason,
          length(ordered_uuids),
          item.catalogue_uuid,
          opts
        )

        {:error, reason}

      {:error, :category_not_found} = err ->
        # `move_item_to_category/3` already logged nothing (validation
        # failed before its own audit). Surface as-is — caller flashes.
        err

      {:error, reason} ->
        log_reorder_db_error(
          :item,
          Helpers.dedupe_keep_last(ordered_uuids),
          item.catalogue_uuid,
          opts,
          category_uuid: to_category_uuid
        )

        {:error, reason}
    end
  end

  defp resolve_move_attrs(nil), do: {:ok, %{category_uuid: nil}}

  defp resolve_move_attrs(category_uuid) when is_binary(category_uuid) do
    case repo().get(Category, category_uuid) do
      %Category{catalogue_uuid: cat_uuid} ->
        {:ok, %{category_uuid: category_uuid, catalogue_uuid: cat_uuid}}

      nil ->
        {:error, :category_not_found}
    end
  end

  @doc """
  Moves an item to a different catalogue, clearing its category.

  Primarily used for **smart** items, where categories don't apply —
  the "where does this item live?" question reduces to "which catalogue?".
  Sets both `catalogue_uuid` and `category_uuid` in one update so the
  item becomes uncategorized within its new catalogue.

  Returns `{:error, :catalogue_not_found}` if the target catalogue UUID
  doesn't resolve, `{:error, :same_catalogue}` if it's already there, or
  `{:error, changeset}` on validation failure. Logs an `item.moved`
  activity with from/to catalogue metadata.

  ## Examples

      {:ok, item} = Catalogue.move_item_to_catalogue(item, other_smart.uuid)
  """
  @spec move_item_to_catalogue(Item.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Item.t()}
          | {:error, :catalogue_not_found | :same_catalogue | Ecto.Changeset.t(Item.t())}
  def move_item_to_catalogue(%Item{} = item, catalogue_uuid, opts \\ [])
      when is_binary(catalogue_uuid) do
    from_catalogue_uuid = item.catalogue_uuid

    cond do
      catalogue_uuid == from_catalogue_uuid ->
        {:error, :same_catalogue}

      is_nil(repo().get(Catalogue, catalogue_uuid)) ->
        {:error, :catalogue_not_found}

      true ->
        attrs = %{catalogue_uuid: catalogue_uuid, category_uuid: nil}

        with {:ok, moved} <- item |> Item.changeset(attrs) |> repo().update() do
          log_activity(%{
            action: "item.moved",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "item",
            resource_uuid: moved.uuid,
            parent_catalogue_uuid: catalogue_uuid,
            metadata: %{
              "name" => moved.name,
              "from_catalogue_uuid" => from_catalogue_uuid,
              "to_catalogue_uuid" => catalogue_uuid,
              "from_category_uuid" => item.category_uuid,
              "to_category_uuid" => nil
            }
          })

          {:ok, moved}
        end
    end
  end

  @doc "Returns a changeset for tracking item changes."
  @spec change_item(Item.t(), map()) :: Ecto.Changeset.t(Item.t())
  def change_item(%Item{} = item, attrs \\ %{}) do
    Item.changeset(item, attrs)
  end

  @doc """
  Returns the full pricing breakdown for an item within its catalogue.

  Resolves both the catalogue's markup and discount (loading the
  catalogue association once if needed), then computes the sale price
  (after markup) and final price (after discount). The chain is
  `base → markup → discount`:

      sale_price  = base_price * (1 + effective_markup   / 100)
      final_price = sale_price  * (1 -  effective_discount / 100)

  Never raises — if the catalogue can't be loaded (e.g. DB hiccup), falls
  back to 0% markup and 0% discount and logs a warning so the caller
  still gets a renderable result instead of crashing a template.

  Returns a map with every field a pricing UI needs in one hop:

    * `:base_price` — the item's stored base price (or `nil` if unset)
    * `:catalogue_markup` — the catalogue's `markup_percentage` (the
      inherited default when the item has no override)
    * `:item_markup` — the item's markup override, or `nil` when
      inheriting from the catalogue
    * `:markup_percentage` — the markup actually applied (item override
      if set, otherwise catalogue's)
    * `:sale_price` — the price after markup, before any discount
      (or `nil` if no base price)
    * `:catalogue_discount` — the catalogue's `discount_percentage`
    * `:item_discount` — the item's discount override, or `nil` when
      inheriting from the catalogue
    * `:discount_percentage` — the discount actually applied (item
      override if set, otherwise catalogue's)
    * `:discount_amount` — the Decimal amount subtracted by the discount
      (`sale_price - final_price`), or `nil` if no discount applies or
      no base price
    * `:final_price` — the price after both markup and discount (or
      `nil` if no base price)

  ## Examples

      # Item inherits both markup (15%) and discount (10%)
      Catalogue.item_pricing(item)
      #=> %{
      #=>   base_price: Decimal.new("100.00"),
      #=>   catalogue_markup: Decimal.new("15.0"),
      #=>   item_markup: nil,
      #=>   markup_percentage: Decimal.new("15.0"),
      #=>   sale_price: Decimal.new("115.00"),
      #=>   catalogue_discount: Decimal.new("10.0"),
      #=>   item_discount: nil,
      #=>   discount_percentage: Decimal.new("10.0"),
      #=>   discount_amount: Decimal.new("11.50"),
      #=>   final_price: Decimal.new("103.50")
      #=> }

      # Item overrides discount to 0 — sale price is charged at full
      Catalogue.item_pricing(item_with_zero_discount)
      #=> %{..., final_price: Decimal.new("115.00"), discount_amount: Decimal.new("0.00"), ...}
  """
  @spec item_pricing(Item.t()) :: %{
          base_price: Decimal.t() | nil,
          catalogue_markup: Decimal.t() | nil,
          item_markup: Decimal.t() | nil,
          markup_percentage: Decimal.t() | nil,
          sale_price: Decimal.t() | nil,
          catalogue_discount: Decimal.t() | nil,
          item_discount: Decimal.t() | nil,
          discount_percentage: Decimal.t() | nil,
          discount_amount: Decimal.t() | nil,
          final_price: Decimal.t() | nil
        }
  def item_pricing(%Item{} = item) do
    {catalogue_markup, catalogue_discount} = safe_pricing_for_item(item)
    effective_markup = Item.effective_markup(item, catalogue_markup)
    effective_discount = Item.effective_discount(item, catalogue_discount)

    %{
      base_price: item.base_price,
      catalogue_markup: catalogue_markup,
      item_markup: item.markup_percentage,
      markup_percentage: effective_markup,
      sale_price: Item.sale_price(item, catalogue_markup),
      catalogue_discount: catalogue_discount,
      item_discount: item.discount_percentage,
      discount_percentage: effective_discount,
      discount_amount: Item.discount_amount(item, catalogue_markup, catalogue_discount),
      final_price: Item.final_price(item, catalogue_markup, catalogue_discount)
    }
  end

  # Returns {markup, discount} from the item's catalogue. Preloads
  # the catalogue association if needed; falls back to {0, 0} on any
  # failure so pricing rendering never crashes a template. One preload
  # handles both values.
  defp safe_pricing_for_item(item) do
    case item.catalogue do
      %Catalogue{} = catalogue ->
        {markup_from(catalogue), discount_from(catalogue)}

      %Ecto.Association.NotLoaded{} ->
        load_pricing(item)

      _ ->
        {Decimal.new("0"), Decimal.new("0")}
    end
  end

  defp load_pricing(item) do
    case repo().preload(item, [:catalogue]) do
      %Item{catalogue: %Catalogue{} = catalogue} ->
        {markup_from(catalogue), discount_from(catalogue)}

      _ ->
        {Decimal.new("0"), Decimal.new("0")}
    end
  rescue
    e ->
      Logger.warning(
        "[Catalogue] Failed to load catalogue for item_pricing/1 (item #{item.uuid}): " <>
          Exception.message(e)
      )

      {Decimal.new("0"), Decimal.new("0")}
  end

  defp markup_from(%Catalogue{markup_percentage: nil}), do: Decimal.new("0")
  defp markup_from(%Catalogue{markup_percentage: mp}), do: mp

  defp discount_from(%Catalogue{discount_percentage: nil}), do: Decimal.new("0")
  defp discount_from(%Catalogue{discount_percentage: d}), do: d

  # ═══════════════════════════════════════════════════════════════════
  # Smart-catalogue rules — see PhoenixKitCatalogue.Catalogue.Rules
  # ═══════════════════════════════════════════════════════════════════

  defdelegate list_catalogue_rules(item_or_uuid), to: Rules
  defdelegate catalogue_rule_map(item_or_uuid), to: Rules
  defdelegate get_catalogue_rule(item_uuid, referenced_catalogue_uuid), to: Rules
  defdelegate put_catalogue_rules(item, rules, opts \\ []), to: Rules
  defdelegate reorder_catalogue_rules(item_uuid, ordered_referenced_uuids, opts \\ []), to: Rules
  defdelegate list_items_referencing_catalogue(catalogue_uuid), to: Rules
  defdelegate catalogue_reference_count(catalogue_uuid), to: Rules
  defdelegate change_catalogue_rule(rule, attrs \\ %{}), to: Rules
  defdelegate create_catalogue_rule(attrs, opts \\ []), to: Rules
  defdelegate update_catalogue_rule(rule, attrs, opts \\ []), to: Rules
  defdelegate delete_catalogue_rule(rule, opts \\ []), to: Rules

  # ═══════════════════════════════════════════════════════════════════
  # Smart-catalogue pricing — see PhoenixKitCatalogue.Catalogue.SmartPricing
  # ═══════════════════════════════════════════════════════════════════

  defdelegate evaluate_smart_rules(entries, opts \\ []), to: SmartPricing

  # ═══════════════════════════════════════════════════════════════════
  # Search — see PhoenixKitCatalogue.Catalogue.Search
  # ═══════════════════════════════════════════════════════════════════

  defdelegate search_items(query, opts \\ []), to: Search
  defdelegate count_search_items(query, opts \\ []), to: Search
  defdelegate search_items_in_catalogue(catalogue_uuid, query, opts \\ []), to: Search
  defdelegate count_search_items_in_catalogue(catalogue_uuid, query), to: Search
  defdelegate search_items_in_category(category_uuid, query, opts \\ []), to: Search
  defdelegate count_search_items_in_category(category_uuid, query), to: Search

  # ═══════════════════════════════════════════════════════════════════
  # Counts — see PhoenixKitCatalogue.Catalogue.Counts
  # ═══════════════════════════════════════════════════════════════════

  defdelegate item_count_for_catalogue(catalogue_uuid), to: Counts
  defdelegate item_counts_by_catalogue(), to: Counts
  defdelegate active_item_count_in_subtree(category_uuid), to: Counts
  defdelegate category_count_for_catalogue(catalogue_uuid), to: Counts
  defdelegate category_counts_by_catalogue(), to: Counts
  defdelegate deleted_item_count_for_catalogue(catalogue_uuid), to: Counts
  defdelegate deleted_category_count_for_catalogue(catalogue_uuid), to: Counts
  defdelegate deleted_count_for_catalogue(catalogue_uuid), to: Counts

  # ═══════════════════════════════════════════════════════════════════
  # Multilang helpers — see PhoenixKitCatalogue.Catalogue.Translations
  # ═══════════════════════════════════════════════════════════════════

  defdelegate get_translation(record, lang_code), to: Translations

  defdelegate set_translation(record, lang_code, field_data, update_fn, opts \\ []),
    to: Translations

  # ═══════════════════════════════════════════════════════════════════
  # PDF library — see PhoenixKitCatalogue.Catalogue.PdfLibrary
  # ═══════════════════════════════════════════════════════════════════

  defdelegate list_pdfs(opts \\ []), to: PdfLibrary
  defdelegate count_pdfs(opts \\ []), to: PdfLibrary
  defdelegate get_pdf(uuid), to: PdfLibrary
  defdelegate get_pdf!(uuid), to: PdfLibrary
  defdelegate get_pdf_extraction(pdf), to: PdfLibrary, as: :get_extraction

  defdelegate create_pdf_from_upload(tmp_path, original_filename, opts \\ []),
    to: PdfLibrary

  defdelegate trash_pdf(pdf, opts \\ []), to: PdfLibrary
  defdelegate restore_pdf(pdf, opts \\ []), to: PdfLibrary
  defdelegate permanently_delete_pdf(pdf, opts \\ []), to: PdfLibrary
  defdelegate search_pdfs_for_item(item, opts \\ []), to: PdfLibrary
  defdelegate more_pdf_matches_for_item(item, pdf_uuid, opts \\ []), to: PdfLibrary
  defdelegate prune_orphan_pdf_page_contents(), to: PdfLibrary, as: :prune_orphan_page_contents
end
