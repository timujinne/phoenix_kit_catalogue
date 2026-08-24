defmodule PhoenixKitCatalogue.Catalogue.Manufacturers do
  @moduledoc """
  Manufacturers — company directory used as the source of items.

  Hard-deletes only (manufacturers are reference data, not user content).
  Status field is `"active"` / `"inactive"`; inactive manufacturers
  remain in the DB but are filtered from item dropdowns.

  Public surface is re-exported from `PhoenixKitCatalogue.Catalogue` via
  `defdelegate`, so callers can keep using the canonical context module.
  """

  import Ecto.Query, warn: false

  alias PhoenixKitCatalogue.Catalogue.{ActivityLog, Links, PubSub, Suppliers}
  alias PhoenixKitCatalogue.Schemas.{Item, Manufacturer}

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc """
  Lists all manufacturers, ordered by name.

  ## Options

    * `:status` — filter by status (e.g. `"active"`, `"inactive"`).
      When nil (default), returns all manufacturers.
  """
  @spec list_manufacturers(keyword()) :: [Manufacturer.t()]
  def list_manufacturers(opts \\ []) do
    query = from(m in Manufacturer, order_by: [asc: :name])

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> where(query, [m], m.status == ^status)
      end

    repo().all(query)
  end

  @doc "Fetches a manufacturer by UUID. Returns `nil` if not found."
  @spec get_manufacturer(Ecto.UUID.t()) :: Manufacturer.t() | nil
  def get_manufacturer(uuid), do: repo().get(Manufacturer, uuid)

  @doc "Fetches a manufacturer by UUID. Raises `Ecto.NoResultsError` if not found."
  @spec get_manufacturer!(Ecto.UUID.t()) :: Manufacturer.t()
  def get_manufacturer!(uuid), do: repo().get!(Manufacturer, uuid)

  @doc """
  Creates a manufacturer.

  ## Required attributes

    * `:name` — manufacturer name (1-255 chars)

  ## Optional attributes

    * `:description`, `:website`, `:contact_info`, `:logo_url`, `:notes`
    * `:status` — `"active"` (default) or `"inactive"`
    * `:data` — flexible JSON map
  """
  @spec create_manufacturer(map(), keyword()) ::
          {:ok, Manufacturer.t()} | {:error, Ecto.Changeset.t(Manufacturer.t())}
  def create_manufacturer(attrs, opts \\ []) do
    result =
      ActivityLog.with_log(
        fn -> %Manufacturer{} |> Manufacturer.changeset(attrs) |> repo().insert() end,
        fn manufacturer ->
          %{
            action: "manufacturer.created",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "manufacturer",
            resource_uuid: manufacturer.uuid,
            metadata: %{"name" => manufacturer.name}
          }
        end
      )

    with {:ok, manufacturer} <- result do
      PubSub.broadcast(:manufacturer, manufacturer.uuid)
      {:ok, manufacturer}
    end
  end

  @doc "Updates a manufacturer with the given attributes."
  @spec update_manufacturer(Manufacturer.t(), map(), keyword()) ::
          {:ok, Manufacturer.t()} | {:error, Ecto.Changeset.t(Manufacturer.t())}
  def update_manufacturer(%Manufacturer{} = manufacturer, attrs, opts \\ []) do
    result =
      ActivityLog.with_log(
        fn -> manufacturer |> Manufacturer.changeset(attrs) |> repo().update() end,
        fn updated ->
          %{
            action: "manufacturer.updated",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "manufacturer",
            resource_uuid: updated.uuid,
            metadata: %{"name" => updated.name}
          }
        end
      )

    with {:ok, updated} <- result do
      PubSub.broadcast(:manufacturer, updated.uuid)
      {:ok, updated}
    end
  end

  @doc "Hard-deletes a manufacturer from the database."
  @spec delete_manufacturer(Manufacturer.t(), keyword()) ::
          {:ok, Manufacturer.t()} | {:error, Ecto.Changeset.t(Manufacturer.t())}
  def delete_manufacturer(%Manufacturer{} = manufacturer, opts \\ []) do
    result =
      ActivityLog.with_log(
        fn -> delete_with_links(manufacturer) end,
        fn _ ->
          %{
            action: "manufacturer.deleted",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "manufacturer",
            resource_uuid: manufacturer.uuid,
            metadata: %{"name" => manufacturer.name}
          }
        end
      )

    with {:ok, {deleted, links_removed}} <- result do
      PubSub.broadcast(:manufacturer, manufacturer.uuid)
      # The links went in the same transaction (muted); announce them now
      # that it has committed.
      if links_removed > 0, do: PubSub.broadcast(:links, manufacturer.uuid)
      {:ok, deleted}
    end
  end

  # V180 dropped the FKs that carried ON DELETE CASCADE, so the links have to
  # be cleared here or they outlive the row they point at. One transaction:
  # a delete that fails must not leave the graph already pruned.
  defp delete_with_links(record) do
    repo().transaction(fn ->
      {links_removed, _} = Links.delete_links_for(record.uuid, broadcast: false)

      case repo().delete(record) do
        {:ok, deleted} -> {deleted, links_removed}
        {:error, changeset} -> repo().rollback(changeset)
      end
    end)
  end

  @doc "Returns a changeset for tracking manufacturer changes."
  @spec change_manufacturer(Manufacturer.t(), map()) :: Ecto.Changeset.t(Manufacturer.t())
  def change_manufacturer(%Manufacturer{} = manufacturer, attrs \\ %{}) do
    Manufacturer.changeset(manufacturer, attrs)
  end

  # ── Cross-module resolution ────────────────────────────────────────────────
  # Mirrors `PhoenixKitCatalogue.Catalogue.Suppliers`' resolver pair. Since V179
  # an item's manufacturer is a federated `{source, uuid}` reference rather than
  # a foreign key, so these functions are the ONLY way to turn one into a name:
  # `Item` carries no `belongs_to :manufacturer` to preload.

  @doc """
  Resolves a manufacturer UUID to a unified map regardless of source.

  Returns `{:ok, map}` with keys `:uuid`, `:name`, `:email`, `:phone`,
  `:website`, `:source` (`:crm | :local`), or `:error` when the uuid is
  unknown to both sources. CRM is consulted first and only when the CRM
  module is loaded.
  """
  @spec resolve(Ecto.UUID.t()) :: {:ok, map()} | :error
  def resolve(uuid) when is_binary(uuid) do
    with :error <- try_resolve_crm(uuid) do
      case repo().get(Manufacturer, uuid) do
        nil -> :error
        %Manufacturer{} = m -> resolve_local(m)
      end
    end
  end

  # Resolves THROUGH the xref to the party — see the twin in
  # `PhoenixKitCatalogue.Catalogue.Suppliers`. This is what lets an item that
  # still stores the LOCAL manufacturer uuid display the party's current name
  # with no data rewrite, and why linking copies nothing down.
  defp resolve_local(%Manufacturer{crm_company_uuid: party} = m) when is_binary(party) do
    case try_resolve_crm(party) do
      {:ok, resolved} -> {:ok, resolved}
      :error -> {:ok, local_map(m)}
    end
  end

  defp resolve_local(%Manufacturer{} = m), do: {:ok, local_map(m)}

  defp local_map(%Manufacturer{} = m) do
    %{uuid: m.uuid, name: m.name, email: nil, phone: nil, website: m.website, source: :local}
  end

  @doc """
  Batch form of `resolve/1` — see
  `PhoenixKitCatalogue.Catalogue.Suppliers.resolve_many/1`. This is the call
  that hydrates a page of items without one cross-module lookup per row.
  """
  @spec resolve_many([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => map()}
  def resolve_many([]), do: %{}

  def resolve_many(uuids) when is_list(uuids) do
    uuids = uuids |> Enum.reject(&is_nil/1) |> Enum.uniq()
    from_crm = batch_resolve_crm(uuids)

    locals =
      Manufacturer
      |> where([m], m.uuid in ^(uuids -- Map.keys(from_crm)))
      |> repo().all()

    party_uuids = for %Manufacturer{crm_company_uuid: p} <- locals, is_binary(p), do: p
    projected = batch_resolve_crm(party_uuids)

    locals
    |> Map.new(fn m -> {m.uuid, Map.get(projected, m.crm_company_uuid) || local_map(m)} end)
    |> Map.merge(from_crm)
  end

  @doc """
  Every item this CRM party is recorded as the manufacturer of, for the
  catalogue panel on that party's page in CRM.

  Matches the party's own uuid AND any local manufacturer row projecting it,
  so items that still store the pre-move local uuid are included. Deleted
  items excluded.
  """
  @spec items_manufactured_by(Ecto.UUID.t()) :: [Item.t()]
  def items_manufactured_by(party_uuid) when is_binary(party_uuid) do
    uuids = [party_uuid | Suppliers.projection_uuids(Manufacturer, party_uuid)]

    from(i in Item,
      where: i.manufacturer_uuid in ^uuids and i.status != "deleted",
      order_by: [asc: i.name],
      preload: [:catalogue, :category]
    )
    |> repo().all()
    |> hydrate()
  end

  def items_manufactured_by(_), do: []

  @doc """
  Stamps `:manufacturer_name` on each item — the replacement for the
  `preload(:manufacturer)` that V179's federated reference made impossible.

  One call per page, two queries at most, whatever mix of local and CRM
  manufacturers the page contains. Items whose reference resolves to nothing
  fall back to their stored `manufacturer_name_snapshot`, and then to `nil`,
  so a deleted party degrades to the last known name rather than a blank.

  Accepts a single item or a list, and is a no-op for anything without a
  manufacturer.
  """
  @spec hydrate([Item.t()] | Item.t()) :: [Item.t()] | Item.t()
  def hydrate(%Item{} = item), do: item |> List.wrap() |> hydrate() |> List.first()

  def hydrate(items) when is_list(items) do
    resolved =
      items
      |> Enum.map(& &1.manufacturer_uuid)
      |> Enum.reject(&is_nil/1)
      |> resolve_many()

    Enum.map(items, fn item ->
      name =
        case Map.get(resolved, item.manufacturer_uuid) do
          %{name: name} -> name
          nil -> item.manufacturer_name_snapshot
        end

      %{item | manufacturer_name: name}
    end)
  end

  defp batch_resolve_crm([]), do: %{}

  defp batch_resolve_crm(uuids) do
    if crm_available?() and function_exported?(PhoenixKitCRM.PartyRoles, :get_manufacturers, 1) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(PhoenixKitCRM.PartyRoles, :get_manufacturers, [uuids])
    else
      %{}
    end
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  @doc """
  Lists manufacturers from all available sources as normalized maps.

  CRM parties holding an active `manufacturer` role come first, then local
  rows ordered by name. Local rows already linked to a CRM party are omitted:
  the party side of the same company is in the list already, and emitting both
  would show one company twice.
  """
  @spec list_all(keyword()) :: [map()]
  def list_all(opts \\ []) do
    crm = list_crm_manufacturers()
    listed_parties = MapSet.new(crm, & &1.uuid)

    local =
      opts
      |> list_manufacturers()
      # Only hide a linked local when its party is genuinely in the list — see
      # the twin in `Suppliers.list_all/1` for why rejecting on the xref alone
      # silently deletes the row from every picker when CRM is absent.
      |> Enum.reject(
        &(&1.crm_company_uuid && MapSet.member?(listed_parties, &1.crm_company_uuid))
      )
      |> Enum.map(&local_map/1)

    crm ++ local
  end

  defp try_resolve_crm(uuid) do
    if crm_available?() do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      case apply(PhoenixKitCRM.PartyRoles, :get_manufacturer, [uuid]) do
        nil ->
          :error

        party ->
          {:ok,
           %{
             uuid: uuid,
             name: party.name,
             email: Map.get(party, :email),
             phone: Map.get(party, :phone),
             website: Map.get(party, :website),
             source: :crm
           }}
      end
    else
      :error
    end
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  defp list_crm_manufacturers do
    if crm_available?() and
         function_exported?(PhoenixKitCRM.PartyRoles, :list_manufacturers, 1) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(PhoenixKitCRM.PartyRoles, :list_manufacturers, [[]])
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp crm_available? do
    Code.ensure_loaded?(PhoenixKitCRM.PartyRoles) and
      function_exported?(PhoenixKitCRM.PartyRoles, :get_manufacturer, 1)
  end
end
