defmodule PhoenixKitCatalogue.Catalogue.Links do
  @moduledoc """
  Manufacturer ↔ Supplier many-to-many links.

  Add and remove individual links via `link_*`/`unlink_*`; sync the
  full set for one side via `sync_*`. Bulk syncs run inside a single
  transaction and emit one summary activity entry (added + removed
  counts).

  Every write broadcasts `:links` (uuid of the party whose link set
  changed, no catalogue parent). The single-link functions accept
  `broadcast: false` so the syncs — and the party deletes in
  `Manufacturers` / `Suppliers` — can run them inside a transaction and
  fan out once after the commit.

  Public surface is re-exported from `PhoenixKitCatalogue.Catalogue`.
  """

  import Ecto.Query, warn: false

  alias PhoenixKitCatalogue.Catalogue.{ActivityLog, PubSub}
  alias PhoenixKitCatalogue.Schemas.{Manufacturer, ManufacturerSupplier, Supplier}

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # Inside the sync transactions the per-link writes stay quiet; the
  # sync emits the one post-commit `:links` event itself.
  @muted [broadcast: false]

  @doc """
  Creates a many-to-many link between a manufacturer and a supplier.

  Returns `{:error, changeset}` if the link already exists (unique constraint).
  """
  @spec link_manufacturer_supplier(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, ManufacturerSupplier.t()}
          | {:error, Ecto.Changeset.t(ManufacturerSupplier.t())}
  def link_manufacturer_supplier(manufacturer_uuid, supplier_uuid, opts \\ []) do
    %ManufacturerSupplier{}
    |> ManufacturerSupplier.changeset(%{
      manufacturer_uuid: manufacturer_uuid,
      supplier_uuid: supplier_uuid,
      # Default "local" keeps every existing caller working unchanged; core
      # V180 federated both sides, so a CRM party is now storable here.
      manufacturer_source: Keyword.get(opts, :manufacturer_source, "local"),
      supplier_source: Keyword.get(opts, :supplier_source, "local")
    })
    |> repo().insert()
    |> tap_broadcast(manufacturer_uuid, opts)
  end

  @doc """
  Deletes every link touching a party, whichever side it sits on.

  Replaces the `ON DELETE CASCADE` that core V180 dropped along with the two
  foreign keys: without this, deleting a local supplier or manufacturer leaves
  its links behind pointing at nothing.
  """
  @spec delete_links_for(Ecto.UUID.t(), keyword()) :: {integer(), nil}
  def delete_links_for(uuid, opts \\ []) when is_binary(uuid) do
    {count, _} =
      result =
      from(ms in ManufacturerSupplier,
        where: ms.manufacturer_uuid == ^uuid or ms.supplier_uuid == ^uuid
      )
      |> repo().delete_all()

    if count > 0, do: maybe_broadcast(uuid, opts)

    result
  end

  @doc """
  Removes the link between a manufacturer and a supplier.

  Returns `{:error, :not_found}` if the link doesn't exist.
  """
  @spec unlink_manufacturer_supplier(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, ManufacturerSupplier.t()}
          | {:error, :not_found | Ecto.Changeset.t(ManufacturerSupplier.t())}
  def unlink_manufacturer_supplier(manufacturer_uuid, supplier_uuid, opts \\ []) do
    query =
      from(ms in ManufacturerSupplier,
        where: ms.manufacturer_uuid == ^manufacturer_uuid and ms.supplier_uuid == ^supplier_uuid
      )

    case repo().one(query) do
      nil -> {:error, :not_found}
      record -> record |> repo().delete() |> tap_broadcast(manufacturer_uuid, opts)
    end
  end

  @doc "Lists all suppliers linked to a manufacturer, ordered by name."
  @spec list_suppliers_for_manufacturer(Ecto.UUID.t()) :: [Supplier.t()]
  def list_suppliers_for_manufacturer(manufacturer_uuid) do
    from(s in Supplier,
      join: ms in ManufacturerSupplier,
      on: ms.supplier_uuid == s.uuid,
      where: ms.manufacturer_uuid == ^manufacturer_uuid,
      order_by: [asc: s.name]
    )
    |> repo().all()
  end

  @doc "Lists all manufacturers linked to a supplier, ordered by name."
  @spec list_manufacturers_for_supplier(Ecto.UUID.t()) :: [Manufacturer.t()]
  def list_manufacturers_for_supplier(supplier_uuid) do
    from(m in Manufacturer,
      join: ms in ManufacturerSupplier,
      on: ms.manufacturer_uuid == m.uuid,
      where: ms.supplier_uuid == ^supplier_uuid,
      order_by: [asc: m.name]
    )
    |> repo().all()
  end

  @doc "Returns a list of supplier UUIDs linked to a manufacturer."
  @spec linked_supplier_uuids(Ecto.UUID.t()) :: [Ecto.UUID.t()]
  def linked_supplier_uuids(manufacturer_uuid) do
    from(ms in ManufacturerSupplier,
      where: ms.manufacturer_uuid == ^manufacturer_uuid,
      select: ms.supplier_uuid
    )
    |> repo().all()
  end

  @doc "Returns a list of manufacturer UUIDs linked to a supplier."
  @spec linked_manufacturer_uuids(Ecto.UUID.t()) :: [Ecto.UUID.t()]
  def linked_manufacturer_uuids(supplier_uuid) do
    from(ms in ManufacturerSupplier,
      where: ms.supplier_uuid == ^supplier_uuid,
      select: ms.manufacturer_uuid
    )
    |> repo().all()
  end

  @doc """
  Syncs the supplier links for a manufacturer to match the given list of supplier UUIDs.

  Adds missing links and removes extra ones via set difference.
  Returns `{:ok, :synced}` on success or `{:error, reason}` on the first failure.
  """
  @spec sync_manufacturer_suppliers(Ecto.UUID.t(), [Ecto.UUID.t()], keyword()) ::
          {:ok, :synced} | {:error, term()}
  def sync_manufacturer_suppliers(manufacturer_uuid, supplier_uuids, opts \\ [])
      when is_list(supplier_uuids) do
    current = linked_supplier_uuids(manufacturer_uuid) |> MapSet.new()
    desired = MapSet.new(supplier_uuids)
    added = MapSet.difference(desired, current)
    removed = MapSet.difference(current, desired)

    result =
      repo().transaction(fn ->
        Enum.each(
          added,
          &ok_or_rollback(link_manufacturer_supplier(manufacturer_uuid, &1, @muted))
        )

        Enum.each(
          removed,
          &ok_or_rollback(unlink_manufacturer_supplier(manufacturer_uuid, &1, @muted))
        )

        :synced
      end)

    with {:ok, :synced} <- result do
      if MapSet.size(added) > 0 or MapSet.size(removed) > 0 do
        ActivityLog.log(%{
          action: "manufacturer.suppliers_synced",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "manufacturer",
          resource_uuid: manufacturer_uuid,
          metadata: %{
            "added_count" => MapSet.size(added),
            "removed_count" => MapSet.size(removed)
          }
        })

        PubSub.broadcast(:links, manufacturer_uuid)
      end

      result
    end
  end

  @doc """
  Syncs the manufacturer links for a supplier to match the given list of manufacturer UUIDs.

  Adds missing links and removes extra ones via set difference.
  Returns `{:ok, :synced}` on success or `{:error, reason}` on the first failure.
  """
  @spec sync_supplier_manufacturers(Ecto.UUID.t(), [Ecto.UUID.t()], keyword()) ::
          {:ok, :synced} | {:error, term()}
  def sync_supplier_manufacturers(supplier_uuid, manufacturer_uuids, opts \\ [])
      when is_list(manufacturer_uuids) do
    current = linked_manufacturer_uuids(supplier_uuid) |> MapSet.new()
    desired = MapSet.new(manufacturer_uuids)
    added = MapSet.difference(desired, current)
    removed = MapSet.difference(current, desired)

    result =
      repo().transaction(fn ->
        Enum.each(added, &ok_or_rollback(link_manufacturer_supplier(&1, supplier_uuid, @muted)))

        Enum.each(
          removed,
          &ok_or_rollback(unlink_manufacturer_supplier(&1, supplier_uuid, @muted))
        )

        :synced
      end)

    with {:ok, :synced} <- result do
      if MapSet.size(added) > 0 or MapSet.size(removed) > 0 do
        ActivityLog.log(%{
          action: "supplier.manufacturers_synced",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "supplier",
          resource_uuid: supplier_uuid,
          metadata: %{
            "added_count" => MapSet.size(added),
            "removed_count" => MapSet.size(removed)
          }
        })

        PubSub.broadcast(:links, supplier_uuid)
      end

      result
    end
  end

  defp ok_or_rollback({:ok, _}), do: :ok
  defp ok_or_rollback({:error, reason}), do: repo().rollback(reason)

  defp tap_broadcast({:ok, _} = ok, uuid, opts) do
    maybe_broadcast(uuid, opts)
    ok
  end

  defp tap_broadcast(other, _uuid, _opts), do: other

  defp maybe_broadcast(uuid, opts) do
    if Keyword.get(opts, :broadcast, true), do: PubSub.broadcast(:links, uuid)
    :ok
  end
end
