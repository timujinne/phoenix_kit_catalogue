defmodule PhoenixKitCatalogue.Catalogue.Suppliers do
  @moduledoc """
  Suppliers — delivery companies linked to manufacturers via the
  many-to-many `phoenix_kit_cat_manufacturer_suppliers` table.

  Same lifecycle as manufacturers: hard-delete only, `"active"` /
  `"inactive"` status.

  ### Cross-module supplier resolution

  `resolve/1` and `list_all/1` provide a unified view of suppliers across
  sources (local `cat_suppliers` + CRM when available). CRM access is
  guarded via `Code.ensure_loaded?` / `function_exported?` — the CRM module
  is an optional runtime dependency and may not be present.

  Public surface is re-exported from `PhoenixKitCatalogue.Catalogue`.
  """

  import Ecto.Query, warn: false

  alias PhoenixKitCatalogue.Catalogue.{
    ActivityLog,
    ItemSupplierInfos,
    Links,
    Manufacturers,
    PubSub
  }

  alias PhoenixKitCatalogue.Schemas.{Item, ItemSupplierInfo, Supplier}

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc """
  Lists all suppliers, ordered by name.

  ## Options

    * `:status` — filter by status (e.g. `"active"`, `"inactive"`).
  """
  @spec list_suppliers(keyword()) :: [Supplier.t()]
  def list_suppliers(opts \\ []) do
    query = from(s in Supplier, order_by: [asc: :name])

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> where(query, [s], s.status == ^status)
      end

    repo().all(query)
  end

  @doc "Fetches a supplier by UUID. Returns `nil` if not found."
  @spec get_supplier(Ecto.UUID.t()) :: Supplier.t() | nil
  def get_supplier(uuid), do: repo().get(Supplier, uuid)

  @doc "Fetches a supplier by UUID. Raises `Ecto.NoResultsError` if not found."
  @spec get_supplier!(Ecto.UUID.t()) :: Supplier.t()
  def get_supplier!(uuid), do: repo().get!(Supplier, uuid)

  @doc """
  Creates a supplier.

  ## Required attributes

    * `:name` — supplier name (1-255 chars)

  ## Optional attributes

    * `:description`, `:website`, `:contact_info`, `:notes`
    * `:status` — `"active"` (default) or `"inactive"`
    * `:data` — flexible JSON map
  """
  @spec create_supplier(map(), keyword()) ::
          {:ok, Supplier.t()} | {:error, Ecto.Changeset.t(Supplier.t())}
  def create_supplier(attrs, opts \\ []) do
    result =
      ActivityLog.with_log(
        fn -> %Supplier{} |> Supplier.changeset(attrs) |> repo().insert() end,
        fn supplier ->
          %{
            action: "supplier.created",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "supplier",
            resource_uuid: supplier.uuid,
            metadata: %{"name" => supplier.name}
          }
        end
      )

    with {:ok, supplier} <- result do
      PubSub.broadcast(:supplier, supplier.uuid)
      {:ok, supplier}
    end
  end

  @doc "Updates a supplier with the given attributes."
  @spec update_supplier(Supplier.t(), map(), keyword()) ::
          {:ok, Supplier.t()} | {:error, Ecto.Changeset.t(Supplier.t())}
  def update_supplier(%Supplier{} = supplier, attrs, opts \\ []) do
    result =
      ActivityLog.with_log(
        fn -> supplier |> Supplier.changeset(attrs) |> repo().update() end,
        fn updated ->
          %{
            action: "supplier.updated",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "supplier",
            resource_uuid: updated.uuid,
            metadata: %{"name" => updated.name}
          }
        end
      )

    with {:ok, updated} <- result do
      PubSub.broadcast(:supplier, updated.uuid)
      {:ok, updated}
    end
  end

  @doc "Hard-deletes a supplier from the database."
  @spec delete_supplier(Supplier.t(), keyword()) ::
          {:ok, Supplier.t()} | {:error, Ecto.Changeset.t(Supplier.t())}
  def delete_supplier(%Supplier{} = supplier, opts \\ []) do
    result =
      ActivityLog.with_log(
        fn -> delete_with_links(supplier) end,
        fn _ ->
          %{
            action: "supplier.deleted",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "supplier",
            resource_uuid: supplier.uuid,
            metadata: %{"name" => supplier.name}
          }
        end
      )

    with {:ok, {deleted, links_removed}} <- result do
      PubSub.broadcast(:supplier, supplier.uuid)
      # The links went in the same transaction (muted); announce them now
      # that it has committed.
      if links_removed > 0, do: PubSub.broadcast(:links, supplier.uuid)
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

  @doc "Returns a changeset for tracking supplier changes."
  @spec change_supplier(Supplier.t(), map()) :: Ecto.Changeset.t(Supplier.t())
  def change_supplier(%Supplier{} = supplier, attrs \\ %{}) do
    Supplier.changeset(supplier, attrs)
  end

  @doc """
  Resolves a supplier UUID to a unified map regardless of source.

  Returns `{:ok, map}` with keys `:uuid`, `:name`, `:email`, `:phone`,
  `:website`, `:source` (`:crm | :local`), or `:error` when the supplier
  cannot be found in any source.

  The CRM branch reports the generic `:crm` tag rather than
  `:crm_company` / `:crm_contact` — `PhoenixKitCRM.PartyRoles.get_supplier/1`
  resolves either roleable type in one call but its return shape doesn't
  say which; `list_all/1` (backed by per-type role listings) is the
  source for the more specific tags used elsewhere in this module.

  CRM lookup is guarded — when `PhoenixKitCRM.PartyRoles` is not loaded
  (the CRM module is an optional runtime dependency), the CRM path is
  skipped and only local suppliers are checked.
  """
  @spec resolve(Ecto.UUID.t()) :: {:ok, map()} | :error
  def resolve(uuid) when is_binary(uuid) do
    with :error <- try_resolve_crm(uuid) do
      case repo().get(Supplier, uuid) do
        nil -> :error
        %Supplier{} = s -> resolve_local(s)
      end
    end
  end

  # A local row that projects a CRM party resolves THROUGH to the party.
  #
  # This is what makes existing references live without rewriting a single
  # stored uuid: junction rows and warehouse documents that already hold the
  # local uuid keep working, and they show the party's current name rather than
  # whatever the local row was called when it was linked. It is also why
  # linking does not copy identity down — there is nothing to keep in sync.
  #
  # A party that has since been deleted (or a CRM that is not installed) falls
  # back to the local row, which is the last thing anyone knew about it.
  defp resolve_local(%Supplier{crm_company_uuid: party_uuid} = s) when is_binary(party_uuid) do
    case try_resolve_crm(party_uuid) do
      {:ok, party} -> {:ok, party}
      :error -> {:ok, local_map(s)}
    end
  end

  defp resolve_local(%Supplier{} = s), do: {:ok, local_map(s)}

  defp local_map(%Supplier{} = s) do
    %{uuid: s.uuid, name: s.name, email: nil, phone: nil, website: s.website, source: :local}
  end

  @doc """
  The CRM **company** uuid a supplier reference points at — directly when
  the reference is already a party, or through the xref when it is a local
  row linked to one. `nil` when there is no company behind it.

  This is the join anyone needs to address a supplier as a CRM company:
  comments, activity, anything CRM stores per company. Contacts return
  `nil` deliberately — a contact is not a company, and pointing
  company-scoped records at one would file them against the wrong party.
  """
  @spec crm_company_uuid(map()) :: Ecto.UUID.t() | nil
  def crm_company_uuid(%{supplier_source: "crm_company", supplier_uuid: uuid})
      when is_binary(uuid),
      do: uuid

  def crm_company_uuid(%{supplier_source: "local", supplier_uuid: uuid}) when is_binary(uuid) do
    case repo().get(Supplier, uuid) do
      %Supplier{crm_company_uuid: company_uuid} when is_binary(company_uuid) -> company_uuid
      _ -> nil
    end
  end

  def crm_company_uuid(_reference), do: nil

  @doc """
  Lists all suppliers from all available sources as normalized maps.

  Each entry has keys `:uuid`, `:name`, `:email`, `:phone`, `:website`,
  `:source` (`:crm_company | :crm_contact | :local`). CRM companies then
  CRM contacts are listed first (when available), then local suppliers
  ordered by name.

  CRM access is guarded — when `PhoenixKitCRM.PartyRoles` is not loaded,
  only local suppliers are returned.
  """
  @spec list_all(keyword()) :: [map()]
  def list_all(opts \\ []) do
    crm_suppliers = list_crm_suppliers()
    listed_parties = MapSet.new(crm_suppliers, & &1.uuid)

    local_suppliers =
      opts
      |> list_suppliers()
      # Hide a linked local row ONLY when the party it projects is actually in
      # the list above. Rejecting on `crm_company_uuid` alone made the supplier
      # vanish entirely whenever the party did not come back — CRM uninstalled
      # or unavailable, the role revoked, the company trashed or deleted, or a
      # role grant that failed. That broke the standalone install outright, and
      # it is silent: no error, the row simply stops existing.
      |> Enum.reject(
        &(&1.crm_company_uuid && MapSet.member?(listed_parties, &1.crm_company_uuid))
      )
      |> Enum.map(&local_map/1)

    crm_suppliers ++ local_suppliers
  end

  @doc """
  Batch form of `resolve/1`: `%{uuid => resolved_map}` for many supplier uuids
  in a bounded number of queries, whatever mix of local and CRM they are.

  Unresolvable uuids are simply absent — callers render their stored name
  snapshot, or a placeholder.
  """
  @spec resolve_many([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => map()}
  def resolve_many([]), do: %{}

  def resolve_many(uuids) when is_list(uuids) do
    uuids = uuids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    # 1. Whichever uuids are parties in their own right.
    from_crm = batch_resolve_crm(uuids)

    # 2. The rest may be local rows — and a local row that projects a party
    #    resolves THROUGH to it (see `resolve_local/1`), which needs a second
    #    CRM round trip for the parties those rows point at. Two batches total,
    #    not one per row.
    locals =
      Supplier
      |> where([s], s.uuid in ^(uuids -- Map.keys(from_crm)))
      |> repo().all()

    party_uuids = for %Supplier{crm_company_uuid: p} <- locals, is_binary(p), do: p
    projected = batch_resolve_crm(party_uuids)

    local_resolved =
      Map.new(locals, fn s ->
        {s.uuid, Map.get(projected, s.crm_company_uuid) || local_map(s)}
      end)

    Map.merge(local_resolved, from_crm)
  end

  defp batch_resolve_crm([]), do: %{}

  defp batch_resolve_crm(uuids) do
    if crm_available?() and function_exported?(PhoenixKitCRM.PartyRoles, :get_suppliers, 1) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(PhoenixKitCRM.PartyRoles, :get_suppliers, [uuids])
    else
      %{}
    end
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  @doc """
  Everything a CRM party currently supplies, for the catalogue panel on that
  party's page in CRM.

  Matches the party's own uuid AND the uuid of any local supplier row that
  projects it — the same resolve-through rule `resolve/1` uses, so sourcing
  recorded against the old local row before the party existed still shows up.
  Current rows only (`valid_to` is null), deleted items excluded.

  Returns plain maps, not schemas: the caller is another module rendering a
  read-only list, and handing it structs would invite it to write them back.
  """
  @spec items_supplied_by(Ecto.UUID.t()) :: [Item.t()]
  def items_supplied_by(party_uuid) when is_binary(party_uuid) do
    uuids = [party_uuid | projection_uuids(Supplier, party_uuid)]

    from(i in Item,
      join: info in ItemSupplierInfo,
      on: info.item_uuid == i.uuid,
      where: info.supplier_uuid in ^uuids and is_nil(info.valid_to) and i.status != "deleted",
      order_by: [desc: info.is_primary, asc: i.name],
      distinct: i.uuid,
      preload: [:catalogue, :category]
    )
    |> repo().all()
    |> Manufacturers.hydrate()
  end

  def items_supplied_by(_), do: []

  # Local directory rows that project this party. Callers prepend the party's
  # own uuid: a reference may name either side, and both mean the same company.
  @doc false
  def projection_uuids(schema, party_uuid) do
    from(r in schema, where: r.crm_company_uuid == ^party_uuid, select: r.uuid)
    |> repo().all()
  end

  @doc "Returns the primary supplier-info row for an item, or `nil` if none is marked primary."
  @spec primary_for_item(Ecto.UUID.t()) :: PhoenixKitCatalogue.Schemas.ItemSupplierInfo.t() | nil
  def primary_for_item(item_uuid), do: ItemSupplierInfos.primary_for_item(item_uuid)

  @doc """
  Returns the *current* junction row for an item/supplier pair, or `nil`.

  "Current" means `valid_to` is `nil`. This is the function warehouse calls
  to check whether a receipt line's unit price diverges from the catalogued
  cost for the same supplier.
  """
  @spec active_info_for(Ecto.UUID.t(), Ecto.UUID.t()) ::
          PhoenixKitCatalogue.Schemas.ItemSupplierInfo.t() | nil
  def active_info_for(item_uuid, supplier_uuid) do
    import Ecto.Query, warn: false

    from(i in PhoenixKitCatalogue.Schemas.ItemSupplierInfo,
      where:
        i.item_uuid == ^item_uuid and i.supplier_uuid == ^supplier_uuid and is_nil(i.valid_to),
      limit: 1
    )
    |> repo().one()
  end

  @doc """
  Delegates to `ItemSupplierInfos.revise_unit_cost/3`.

  This is the stable public surface that warehouse and other consumers should
  call. See `ItemSupplierInfos.revise_unit_cost/3` for full documentation.
  """
  @spec revise_unit_cost(
          PhoenixKitCatalogue.Schemas.ItemSupplierInfo.t(),
          Decimal.t(),
          keyword()
        ) ::
          {:ok, PhoenixKitCatalogue.Schemas.ItemSupplierInfo.t()}
          | {:error, :not_current | Ecto.Changeset.t()}
  def revise_unit_cost(info, new_cost, opts \\ []),
    do: ItemSupplierInfos.revise_unit_cost(info, new_cost, opts)

  # ── CRM helpers ────────────────────────────────────────────────────────────
  # All CRM calls are guarded behind function_exported? so the catalogue
  # module compiles and runs without the CRM module present. CRM is an
  # optional soft dependency — its absence is not an error.

  defp try_resolve_crm(uuid) do
    if crm_available?() do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      case apply(PhoenixKitCRM.PartyRoles, :get_supplier, [uuid]) do
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

  # `PartyRoles.get_supplier/1` federates both roleable types behind one
  # call but doesn't say which it hydrated (see `resolve/1` doc), so
  # listing goes through the per-type role queries instead — that's also
  # what lets each entry carry the specific `:crm_company` / `:crm_contact`
  # tag that `ItemFormLive` persists onto `item_supplier_info.supplier_source`.
  defp list_crm_suppliers do
    if crm_available?() do
      list_crm_companies() ++ list_crm_contacts()
    else
      []
    end
  end

  defp list_crm_companies do
    if function_exported?(PhoenixKitCRM.PartyRoles, :list_companies_with_role, 2) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(PhoenixKitCRM.PartyRoles, :list_companies_with_role, ["supplier", []])
      |> Enum.map(fn c ->
        %{
          uuid: c.uuid,
          name: blank_to_unnamed(c.name),
          email: c.email,
          phone: c.phone,
          website: c.website,
          source: :crm_company
        }
      end)
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp list_crm_contacts do
    if function_exported?(PhoenixKitCRM.PartyRoles, :list_contacts_with_role, 2) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(PhoenixKitCRM.PartyRoles, :list_contacts_with_role, ["supplier", []])
      |> Enum.map(fn c ->
        %{
          uuid: c.uuid,
          name: if(c.name in [nil, ""], do: blank_to_unnamed(c.email), else: c.name),
          email: c.email,
          phone: c.phone,
          # Contacts have no website field on the CRM side (mirrors
          # `PartyRoles`' own hydration for contacts).
          website: nil,
          source: :crm_contact
        }
      end)
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp blank_to_unnamed(nil), do: "Unnamed"
  defp blank_to_unnamed(""), do: "Unnamed"
  defp blank_to_unnamed(value), do: value

  defp crm_available? do
    Code.ensure_loaded?(PhoenixKitCRM.PartyRoles) and
      function_exported?(PhoenixKitCRM.PartyRoles, :get_supplier, 1)
  end
end
