defmodule PhoenixKitCatalogue.Catalogue.Suppliers do
  @moduledoc """
  Suppliers — delivery companies linked to manufacturers via the
  many-to-many `phoenix_kit_cat_manufacturer_suppliers` table.

  Same lifecycle as manufacturers: hard-delete only, `"active"` /
  `"inactive"` status.

  Public surface is re-exported from `PhoenixKitCatalogue.Catalogue`.
  """

  import Ecto.Query, warn: false

  alias PhoenixKitCatalogue.Catalogue.{ActivityLog, PubSub}
  alias PhoenixKitCatalogue.Schemas.Supplier

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
        fn -> repo().delete(supplier) end,
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

    with {:ok, deleted} <- result do
      PubSub.broadcast(:supplier, supplier.uuid)
      {:ok, deleted}
    end
  end

  @doc "Returns a changeset for tracking supplier changes."
  @spec change_supplier(Supplier.t(), map()) :: Ecto.Changeset.t(Supplier.t())
  def change_supplier(%Supplier{} = supplier, attrs \\ %{}) do
    Supplier.changeset(supplier, attrs)
  end

  # ── CRM federation (additive) ────────────────────────────────────────
  #
  # `resolve_supplier/1` and `list_federated_suppliers/1` are purely
  # additive: they never change what `list_suppliers/1` or
  # `get_supplier/1` return, so warehouse (and anything else already
  # depending on the plain `%Supplier{}` contract) is unaffected.
  #
  # `phoenix_kit_crm` is an optional dependency — every reference to
  # `PhoenixKitCRM.PartyRoles` is guarded by `Code.ensure_loaded?/1` +
  # `function_exported?/3` and dispatched via `apply/3` so this module
  # compiles cleanly whether or not CRM is installed.

  @typedoc "Supplier normalized across local `cat_supplier`s and CRM-federated parties."
  @type normalized_supplier :: %{
          uuid: Ecto.UUID.t(),
          name: String.t(),
          email: String.t() | nil,
          phone: String.t() | nil,
          website: String.t() | nil,
          source: :crm | :local
        }

  @doc """
  Resolves a supplier UUID to a normalized map, checking CRM first (when
  `phoenix_kit_crm` is installed and the party currently holds an active
  `"supplier"` role) and falling back to a local `cat_supplier`. Returns
  `nil` when the UUID resolves to neither, or isn't a valid UUID at all
  (e.g. a blank picker submission) — callers don't need to pre-validate.
  """
  @spec resolve_supplier(Ecto.UUID.t()) :: normalized_supplier() | nil
  def resolve_supplier(supplier_uuid) do
    case Ecto.UUID.cast(supplier_uuid) do
      {:ok, _} -> resolve_known_supplier(supplier_uuid)
      :error -> nil
    end
  end

  defp resolve_known_supplier(supplier_uuid) do
    case resolve_crm_supplier(supplier_uuid) do
      %{} = crm_supplier -> crm_supplier
      nil -> resolve_local_supplier(supplier_uuid)
    end
  end

  defp resolve_crm_supplier(supplier_uuid) do
    if Code.ensure_loaded?(PhoenixKitCRM.PartyRoles) and
         function_exported?(PhoenixKitCRM.PartyRoles, :get_supplier, 1) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(PhoenixKitCRM.PartyRoles, :get_supplier, [supplier_uuid])
    end
  end

  defp resolve_local_supplier(supplier_uuid) do
    case get_supplier(supplier_uuid) do
      %Supplier{} = supplier -> normalize_local(supplier)
      nil -> nil
    end
  end

  @doc """
  Lists suppliers federated across local `cat_supplier`s and CRM parties
  holding an active `"supplier"` role, normalized to a single shape and
  sorted by name. CRM suppliers are simply omitted when `phoenix_kit_crm`
  isn't installed.

  `opts` are forwarded to `list_suppliers/1` (e.g. `status: "active"`)
  for the local half only — CRM has no equivalent filter here.
  """
  @spec list_federated_suppliers(keyword()) :: [normalized_supplier()]
  def list_federated_suppliers(opts \\ []) do
    local = opts |> list_suppliers() |> Enum.map(&normalize_local/1)

    (local ++ resolve_crm_suppliers())
    |> Enum.sort_by(& &1.name)
  end

  defp resolve_crm_suppliers do
    if Code.ensure_loaded?(PhoenixKitCRM.PartyRoles) and
         function_exported?(PhoenixKitCRM.PartyRoles, :list_companies_with_role, 1) and
         function_exported?(PhoenixKitCRM.PartyRoles, :list_contacts_with_role, 1) do
      companies = crm_companies_with_supplier_role() |> Enum.map(&normalize_crm/1)
      contacts = crm_contacts_with_supplier_role() |> Enum.map(&normalize_crm/1)
      companies ++ contacts
    else
      []
    end
  end

  defp crm_companies_with_supplier_role do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(PhoenixKitCRM.PartyRoles, :list_companies_with_role, ["supplier"])
  end

  defp crm_contacts_with_supplier_role do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(PhoenixKitCRM.PartyRoles, :list_contacts_with_role, ["supplier"])
  end

  # `cat_supplier` only has a free-text `contact_info` field — email and
  # phone have no structured home there, so they're always nil.
  defp normalize_local(%Supplier{} = supplier) do
    %{
      uuid: supplier.uuid,
      name: supplier.name,
      email: nil,
      phone: nil,
      website: supplier.website,
      source: :local
    }
  end

  # `party` is a CRM `Company` or `Contact` struct, deliberately accessed
  # via `Map.get/2` (not a struct pattern-match) since `phoenix_kit_crm`
  # isn't a compile-time dependency here — `Contact` has no `:website`
  # field at all, so a plain `party.website` would raise `KeyError`.
  defp normalize_crm(party) do
    email = Map.get(party, :email)

    %{
      uuid: Map.get(party, :uuid),
      # Mirror the fallback CRM's own get_supplier/1 uses (Company/Contact
      # display_name → email → "Unnamed") so the picker label and the
      # snapshot stored on selection agree for blank-name parties.
      name: Map.get(party, :name) || email || "Unnamed",
      email: email,
      phone: Map.get(party, :phone),
      website: Map.get(party, :website),
      source: :crm
    }
  end
end
