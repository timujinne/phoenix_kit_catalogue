defmodule PhoenixKitCatalogue.Catalogue.ItemSupplierInfo do
  @moduledoc """
  Per-supplier sourcing info for a catalogue item — SKU, unit cost,
  currency, lead time, and minimum order quantity. `supplier_uuid` is a
  soft ref (no FK): it resolves to a local `cat_supplier` or a federated
  CRM party via `PhoenixKitCatalogue.Catalogue.Suppliers.resolve_supplier/1`.

  At most one row per item can have `is_primary: true` (enforced by a
  partial unique index); use `set_primary/3` to flip it safely instead
  of setting `is_primary` through `upsert/2` directly.

  Public surface is re-exported from `PhoenixKitCatalogue.Catalogue`.
  """

  import Ecto.Query, warn: false

  alias PhoenixKitCatalogue.Catalogue.{ActivityLog, Helpers, PubSub, Suppliers}
  alias PhoenixKitCatalogue.Schemas.ItemSupplierInfo

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc "Lists an item's supplier-info rows, primary first, then by position."
  @spec list_for_item(Ecto.UUID.t()) :: [ItemSupplierInfo.t()]
  def list_for_item(item_uuid) do
    from(isi in ItemSupplierInfo,
      where: isi.item_uuid == ^item_uuid,
      order_by: [desc: isi.is_primary, asc: isi.position]
    )
    |> repo().all()
  end

  @doc """
  Inserts a new supplier-info row, or updates an existing one when
  `attrs` carries a `:uuid` (or `"uuid"`) matching a persisted row.

  `supplier_name_snapshot` is always overwritten from the resolved
  supplier name (local `cat_supplier` or CRM-federated party) at write
  time — callers don't need to (and shouldn't) set it directly.
  """
  @spec upsert(map(), keyword()) ::
          {:ok, ItemSupplierInfo.t()} | {:error, Ecto.Changeset.t(ItemSupplierInfo.t())}
  def upsert(attrs, opts \\ []) do
    {target, action} = fetch_target(attrs)
    attrs = snapshot_supplier_name(attrs)

    result =
      ActivityLog.with_log(
        fn -> target |> ItemSupplierInfo.changeset(attrs) |> repo().insert_or_update() end,
        fn record ->
          %{
            action: action,
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "item_supplier_info",
            resource_uuid: record.uuid,
            metadata: %{
              "item_uuid" => record.item_uuid,
              "supplier_uuid" => record.supplier_uuid
            }
          }
        end
      )

    with {:ok, record} <- result do
      broadcast(record.uuid, record.item_uuid)
      {:ok, record}
    end
  end

  defp fetch_target(attrs) do
    case Helpers.fetch_attr(attrs, :uuid) do
      nil ->
        {%ItemSupplierInfo{}, "item_supplier_info.created"}

      uuid ->
        case repo().get(ItemSupplierInfo, uuid) do
          nil -> {%ItemSupplierInfo{}, "item_supplier_info.created"}
          existing -> {existing, "item_supplier_info.updated"}
        end
    end
  end

  defp snapshot_supplier_name(attrs) do
    case Helpers.fetch_attr(attrs, :supplier_uuid) do
      nil ->
        attrs

      supplier_uuid ->
        case Suppliers.resolve_supplier(supplier_uuid) do
          %{name: name} -> Helpers.put_attr(attrs, :supplier_name_snapshot, name)
          nil -> attrs
        end
    end
  end

  @doc "Deletes a supplier-info row by UUID. Returns `{:error, :not_found}` if missing."
  @spec delete(Ecto.UUID.t(), keyword()) ::
          {:ok, ItemSupplierInfo.t()}
          | {:error, :not_found | Ecto.Changeset.t(ItemSupplierInfo.t())}
  def delete(uuid, opts \\ []) do
    case repo().get(ItemSupplierInfo, uuid) do
      nil ->
        {:error, :not_found}

      record ->
        result =
          ActivityLog.with_log(
            fn -> repo().delete(record) end,
            fn _ ->
              %{
                action: "item_supplier_info.deleted",
                mode: "manual",
                actor_uuid: opts[:actor_uuid],
                resource_type: "item_supplier_info",
                resource_uuid: record.uuid,
                metadata: %{
                  "item_uuid" => record.item_uuid,
                  "supplier_uuid" => record.supplier_uuid
                }
              }
            end
          )

        with {:ok, deleted} <- result do
          broadcast(record.uuid, record.item_uuid)
          {:ok, deleted}
        end
    end
  end

  @doc """
  Sets `isi_uuid` as the primary supplier-info row for `item_uuid`,
  clearing `is_primary` on any other row for the same item first (inside
  a transaction) so the partial unique index never sees two primaries
  for the same item at once.
  """
  @spec set_primary(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, ItemSupplierInfo.t()}
          | {:error, :not_found | Ecto.Changeset.t(ItemSupplierInfo.t())}
  def set_primary(item_uuid, isi_uuid, opts \\ []) do
    result =
      repo().transaction(fn ->
        clear_other_primaries(item_uuid, isi_uuid)

        case repo().get(ItemSupplierInfo, isi_uuid) do
          %ItemSupplierInfo{item_uuid: ^item_uuid} = record -> flip_to_primary(record)
          _ -> repo().rollback(:not_found)
        end
      end)

    with {:ok, record} <- result do
      ActivityLog.log(%{
        action: "item_supplier_info.primary_set",
        mode: "manual",
        actor_uuid: opts[:actor_uuid],
        resource_type: "item_supplier_info",
        resource_uuid: record.uuid,
        metadata: %{"item_uuid" => item_uuid}
      })

      broadcast(record.uuid, item_uuid)
      {:ok, record}
    end
  end

  defp clear_other_primaries(item_uuid, isi_uuid) do
    from(isi in ItemSupplierInfo,
      where: isi.item_uuid == ^item_uuid and isi.uuid != ^isi_uuid and isi.is_primary == true
    )
    |> repo().update_all(set: [is_primary: false])
  end

  defp flip_to_primary(record) do
    case record |> ItemSupplierInfo.changeset(%{is_primary: true}) |> repo().update() do
      {:ok, updated} -> updated
      {:error, changeset} -> repo().rollback(changeset)
    end
  end

  @doc "Returns a changeset for tracking supplier-info changes."
  @spec change(ItemSupplierInfo.t(), map()) :: Ecto.Changeset.t(ItemSupplierInfo.t())
  def change(%ItemSupplierInfo{} = item_supplier_info, attrs \\ %{}) do
    ItemSupplierInfo.changeset(item_supplier_info, attrs)
  end

  defp broadcast(uuid, item_uuid) do
    PubSub.broadcast(:item_supplier, uuid, Helpers.item_catalogue_uuid(item_uuid))
  end
end
