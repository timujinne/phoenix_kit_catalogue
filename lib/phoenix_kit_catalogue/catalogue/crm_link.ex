defmodule PhoenixKitCatalogue.Catalogue.CrmLink do
  @moduledoc """
  Links a catalogue directory row to the CRM party it represents.

  There is no UI for linking any more: suppliers and manufacturers are created
  and managed in CRM, and the item form picks them from there directly. What
  remains is the migration path for rows that predate the move —
  `mix phoenix_kit_crm.import_suppliers_from_catalogue` and anything else that
  needs to attach an existing local row to its party.

  This module also owns the other direction — `resolve_or_create_company/3`,
  which turns a NAME into a party. The importer is its caller: a spreadsheet
  column carries a name, and the catalogue no longer owns supplier or
  manufacturer identity, so that name has to land in CRM. Local directory rows
  are created only when CRM is absent.

  CRM owns party identity: "supplier" and "manufacturer" are *roles* on a CRM
  company or contact. The catalogue's local `phoenix_kit_cat_suppliers` /
  `phoenix_kit_cat_manufacturers` rows are kept — catalogue-standalone installs
  have no CRM, `phoenix_kit_cat_manufacturer_suppliers` carries hard FKs onto
  the manufacturer row, and `logo_url`, notes and catalogue status have no home
  in CRM — but once linked they stop being an identity of their own.

  ## Linking copies nothing

  A link writes exactly one column: `crm_company_uuid`. It does not copy the
  party's name, website or contact details onto the local row, because
  `Suppliers.resolve/1` and `Manufacturers.resolve/1` **resolve through the
  xref**: a stored reference to the local uuid returns the party's CURRENT
  identity. Every existing reference — junction rows, warehouse documents —
  goes live the moment the row is linked, with no data rewritten and nothing
  to keep in sync afterwards.

  That is why there is no "refresh" here. There is nothing to refresh.

  ## Ordering and atomicity

  Granting the role and stamping the xref happen in ONE transaction, and a
  failed grant fails the whole link. Both halves are load-bearing: the
  resolvers key on the ACTIVE ROLE, not on the xref column, so an xref stamped
  against a party that does not carry the role resolves to nothing — and the
  row would then be hidden from the directory as "linked" while resolving to
  nothing, i.e. silently disappear.

  Every CRM call is guarded with `Code.ensure_loaded?` + `function_exported?`
  and cannot raise out of this module: CRM is an optional runtime dependency.
  """

  # CRM is an optional runtime dependency: these calls are guarded by
  # `available?/0` and the module legitimately may not exist at compile time.
  @compile {:no_warn_undefined, [PhoenixKitCRM.Companies, PhoenixKitCRM.PartyRoles]}

  import Ecto.Query, warn: false

  alias PhoenixKitCatalogue.Catalogue.{ActivityLog, PubSub}
  alias PhoenixKitCatalogue.Schemas.{Manufacturer, Supplier}

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc "True when the CRM module is loaded and exposes the party API this bridge needs."
  @spec available?() :: boolean()
  def available? do
    Code.ensure_loaded?(PhoenixKitCRM.Companies) and
      function_exported?(PhoenixKitCRM.Companies, :get_company, 1) and
      Code.ensure_loaded?(PhoenixKitCRM.PartyRoles) and
      function_exported?(PhoenixKitCRM.PartyRoles, :grant_role, 4)
  end

  @doc """
  CRM companies offered as link targets, as `{label, uuid}` pairs.

  Every company is a candidate, not only those already holding the role —
  linking is how a company *acquires* the role. Returns `[]` when CRM is absent.
  """
  @spec list_candidates() :: [{String.t(), Ecto.UUID.t()}]
  def list_candidates do
    if available?() and function_exported?(PhoenixKitCRM.Companies, :company_options, 0) do
      # `apply/3` rather than a direct call: CRM is an optional runtime
      # dependency, so the module does not exist at compile or analysis time.
      # Every other cross-module call in this file is written the same way.
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      options = apply(PhoenixKitCRM.Companies, :company_options, [])
      normalize_candidates(options)
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc """
  True when CRM can additionally PROVISION a company, not just read one —
  a narrower guard than `available?/0`, which only covers linking an
  existing party.
  """
  @spec can_provision?() :: boolean()
  def can_provision? do
    available?() and
      function_exported?(PhoenixKitCRM.Companies, :create_company, 1) and
      function_exported?(PhoenixKitCRM.Companies, :list_companies, 1)
  end

  @doc """
  Resolves a party BY NAME, creating the company when there is no match, and
  grants it `role`. Returns `{:ok, company_uuid}`.

  This is the importer's entry point. An import column carries a name, not a
  uuid, and the catalogue no longer owns supplier or manufacturer identity —
  so a name that CRM already knows must attach to that company rather than
  minting a second record for the same business.

  `:unavailable` when CRM is absent, which is a supported install: the caller
  falls back to a local directory row. `{:error, {:ambiguous_name, uuids}}` when
  two live companies share the name — picking one by list order would attach the
  reference to an arbitrary legal entity while looking like it worked.

  Creating the company and granting the role happen in ONE transaction: the
  resolvers key on the active role, so a company created without one is
  invisible to every picker.

  ## Matching

  Trimmed, case-insensitive, exact. CRM's own search is an ILIKE *contains*
  match, so "Nordic" would otherwise adopt "Nordic Hardware Supply OY" — the
  candidates come from that search but the equality check is done here. Two
  genuinely different companies whose names differ only in case are treated
  as one; that is the deliberate trade, because importing `ACME` beside
  `Acme` as separate suppliers is the worse failure and the harder one to
  notice.
  """
  @spec resolve_or_create_company(String.t(), String.t(), keyword()) ::
          {:ok, Ecto.UUID.t()} | :unavailable | {:error, term()}
  def resolve_or_create_company(name, role, opts \\ []) when is_binary(name) do
    trimmed = String.trim(name)

    cond do
      trimmed == "" -> {:error, :blank_name}
      not can_provision?() -> :unavailable
      true -> do_resolve_or_create(trimmed, role, opts)
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  # Creating the company and granting the role are ONE transaction. The
  # resolvers key on the ACTIVE ROLE, so a company created without one is
  # invisible to every picker — a failed grant must not leave that behind.
  defp do_resolve_or_create(name, role, opts) do
    result =
      repo().transaction(fn ->
        with {:ok, company} <- find_or_create_company(name),
             {:ok, _role} <- grant(company, role, opts) do
          company.uuid
        else
          {:error, reason} -> repo().rollback(reason)
        end
      end)

    case result do
      {:ok, uuid} -> {:ok, uuid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp find_or_create_company(name) do
    case existing_companies(name) do
      [company] ->
        {:ok, company}

      [] ->
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(PhoenixKitCRM.Companies, :create_company, [%{name: name}])

      [_ | _] = several ->
        # Two live companies share this name. Picking one by list order would
        # attach the reference to an arbitrary legal entity and look like it
        # worked — the caller has to decide, so say so.
        {:error, {:ambiguous_name, Enum.map(several, & &1.uuid)}}
    end
  end

  defp existing_companies(name) do
    target = String.downcase(name)

    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    candidates = apply(PhoenixKitCRM.Companies, :list_companies, [[search: name]])

    Enum.filter(candidates, fn company ->
      is_binary(company.name) and String.downcase(String.trim(company.name)) == target
    end)
  end

  defp grant(company, role, opts) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(PhoenixKitCRM.PartyRoles, :grant_role, [company, role, %{}, opts])
  end

  @doc """
  Normalizes whatever CRM's option source returns into `{label, value}` pairs.

  CRM hands back `%{label:, value:}` today; the tuple shape is accepted too and
  anything unrecognized is dropped. Public so it can be tested without CRM
  installed — this is a cross-module shape assumption, and the version that
  assumed tuples rendered a picker with zero options and no error anywhere,
  because a comprehension silently drops elements that don't match its pattern.
  """
  @spec normalize_candidates([term()]) :: [{String.t(), Ecto.UUID.t()}]
  def normalize_candidates(options) when is_list(options),
    do: Enum.flat_map(options, &normalize_candidate/1)

  defp normalize_candidate(%{label: label, value: value})
       when is_binary(label) and is_binary(value),
       do: [{label, value}]

  defp normalize_candidate({label, value}) when is_binary(label) and is_binary(value),
    do: [{label, value}]

  defp normalize_candidate(_other), do: []

  @doc """
  Links a supplier to a CRM company: grants the `supplier` role and stamps the
  cross-reference, in one transaction.

  Errors: `:crm_unavailable` (module absent), `:company_not_found`,
  `:role_grant_failed` (the party could not be given the role — the link is
  abandoned rather than left resolving to nothing), `:stale` (the row was
  linked or relinked by someone else since it was loaded), or a changeset when
  the company already projects a different supplier.
  """
  @spec link_supplier(Supplier.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Supplier.t()} | {:error, link_error()}
  def link_supplier(%Supplier{} = supplier, company_uuid, opts \\ []),
    do: link(supplier, company_uuid, "supplier", opts)

  @doc "Manufacturer counterpart of `link_supplier/3` — grants the `manufacturer` role."
  @spec link_manufacturer(Manufacturer.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Manufacturer.t()} | {:error, link_error()}
  def link_manufacturer(%Manufacturer{} = manufacturer, company_uuid, opts \\ []),
    do: link(manufacturer, company_uuid, "manufacturer", opts)

  @typep link_error ::
           :crm_unavailable
           | :company_not_found
           | :role_grant_failed
           | :stale
           | Ecto.Changeset.t()

  defp link(record, company_uuid, role, opts) do
    with :ok <- ensure_available(),
         {:ok, company} <- fetch_company(company_uuid) do
      record
      |> transaction_link(company, role)
      |> announce("linked", role, opts)
    end
  end

  defp transaction_link(record, company, role) do
    transaction(fn ->
      with {:ok, _role_row} <- grant_role(company, role) do
        stamp_xref(record, company.uuid)
      end
    end)
  end

  @doc """
  Clears a supplier's CRM cross-reference. Its own name and website become the
  identity again — no data moves, because none was copied.

  The party role is deliberately left in place: the role's lifecycle belongs to
  CRM, the company may hold it independently of whether this row projects it,
  and revoking it from here would reach across the boundary this design exists
  to keep. It also means a re-link is a single stamp.
  """
  @spec unlink_supplier(Supplier.t(), keyword()) ::
          {:ok, Supplier.t()} | {:error, :stale | Ecto.Changeset.t()}
  def unlink_supplier(%Supplier{} = supplier, opts \\ []), do: unlink(supplier, "supplier", opts)

  @doc "Manufacturer counterpart of `unlink_supplier/2`."
  @spec unlink_manufacturer(Manufacturer.t(), keyword()) ::
          {:ok, Manufacturer.t()} | {:error, :stale | Ecto.Changeset.t()}
  def unlink_manufacturer(%Manufacturer{} = manufacturer, opts \\ []),
    do: unlink(manufacturer, "manufacturer", opts)

  defp unlink(record, role, opts) do
    record
    |> clear_xref()
    |> announce("unlinked", role, opts)
  end

  # ── Writes, conditioned on the xref we believe we are changing ─────────────
  # `update_all` with the expected value in the WHERE clause: a struct loaded
  # before someone else linked/relinked/unlinked the row would otherwise
  # overwrite their write with data derived from a state that no longer exists.
  # 0 rows updated means our belief was wrong, and the caller must reload.

  defp stamp_xref(record, party_uuid) do
    query =
      record
      |> row_query()
      |> where([r], is_nil(r.crm_company_uuid) or r.crm_company_uuid == ^party_uuid)

    case repo().update_all(query, set: [crm_company_uuid: party_uuid, updated_at: now()]) do
      {1, _} -> {:ok, %{record | crm_company_uuid: party_uuid}}
      {0, _} -> {:error, :stale}
    end
  rescue
    # The partial unique index refuses a second row claiming this party.
    e in Postgrex.Error ->
      if unique_violation?(e),
        do: {:error, already_linked_changeset(record)},
        else: reraise(e, __STACKTRACE__)
  end

  defp clear_xref(%{crm_company_uuid: nil} = record), do: {:ok, record}

  defp clear_xref(record) do
    query =
      record
      |> row_query()
      |> where([r], r.crm_company_uuid == ^record.crm_company_uuid)

    case repo().update_all(query, set: [crm_company_uuid: nil, updated_at: now()]) do
      {1, _} -> {:ok, %{record | crm_company_uuid: nil}}
      {0, _} -> {:error, :stale}
    end
  end

  defp row_query(%Supplier{uuid: uuid}), do: from(s in Supplier, where: s.uuid == ^uuid)
  defp row_query(%Manufacturer{uuid: uuid}), do: from(m in Manufacturer, where: m.uuid == ^uuid)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp unique_violation?(%Postgrex.Error{postgres: %{code: :unique_violation}}), do: true
  defp unique_violation?(_), do: false

  defp already_linked_changeset(record) do
    record
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(
      :crm_company_uuid,
      "is already linked to another #{kind(record)}"
    )
    # Built outside a repo call, so nothing sets `:action`; without it a
    # form renders zero errors for this changeset.
    |> Map.put(:action, :insert)
  end

  defp kind(%Supplier{}), do: "supplier"
  defp kind(%Manufacturer{}), do: "manufacturer"

  # ── CRM access (guarded; never raises out of this module) ──────────────────

  defp ensure_available do
    if available?(), do: :ok, else: {:error, :crm_unavailable}
  end

  defp fetch_company(uuid) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    case apply(PhoenixKitCRM.Companies, :get_company, [uuid]) do
      nil -> {:error, :company_not_found}
      company -> {:ok, company}
    end
  rescue
    _ -> {:error, :company_not_found}
  catch
    :exit, _ -> {:error, :company_not_found}
  end

  # A failed grant FAILS THE LINK. Swallowing it stamps an xref against a party
  # with no active role: the resolvers find nothing, the directory hides the row
  # as linked, and the supplier disappears from every picker with no error
  # anywhere. Reported by three independent reviewers against the version that
  # did `_ = grant_role(...)`.
  defp grant_role(company, role) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    case apply(PhoenixKitCRM.PartyRoles, :grant_role, [company, role, %{}, []]) do
      {:ok, row} -> {:ok, row}
      _other -> {:error, :role_grant_failed}
    end
  rescue
    _ -> {:error, :role_grant_failed}
  catch
    :exit, _ -> {:error, :role_grant_failed}
  end

  # ── Transaction + effects ─────────────────────────────────────────────────

  defp transaction(fun) do
    repo().transaction(fn -> unwrap_or_rollback(fun.()) end)
  end

  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, reason}), do: repo().rollback(reason)

  # Audit + PubSub run AFTER the transaction commits and are best-effort: the
  # write is already durable, so a logging or broadcast failure must not be
  # reported to the caller as a failed link.
  defp announce({:ok, record} = ok, action, role, opts) do
    ActivityLog.log(%{
      action: "#{role}.crm_#{action}",
      mode: "manual",
      actor_uuid: opts[:actor_uuid],
      resource_type: role,
      resource_uuid: record.uuid,
      metadata: %{"name" => record.name, "crm_company_uuid" => record.crm_company_uuid}
    })

    PubSub.broadcast(pubsub_kind(role), record.uuid)
    ok
  rescue
    _ -> ok
  catch
    :exit, _ -> ok
  end

  defp announce(error, _action, _role, _opts), do: error

  defp pubsub_kind("supplier"), do: :supplier
  defp pubsub_kind("manufacturer"), do: :manufacturer
end
