defmodule PhoenixKitCatalogue.Catalogue.ItemSupplierInfos do
  @moduledoc """
  Context for managing the `phoenix_kit_cat_item_supplier_info` junction table.

  Each row links a catalogue item to a supplier (local or CRM-sourced) and
  carries a snapshot of the supplier's name at write time so the record stays
  readable even after renaming or deletion.

  At most one row per item may have `is_primary: true` — enforced by a partial
  unique index and by `set_primary/1`, which uses a transaction to clear any
  existing primary before promoting the target row.

  ## Price history via validity windows

  The schema carries `valid_from`/`valid_to` date fields. A row is considered
  *current* when `valid_to` is `nil`. `revise_unit_cost/3` implements a
  non-destructive price revision: the current row is closed (`valid_to: today`,
  `is_primary: false`) and a successor row is inserted with the new cost,
  `valid_from: today`, and `valid_to: nil`. This produces an append-only price
  history. The canonical "current" predicate is `is_nil(valid_to)`, and that is
  also what `history_for_pair/2` orders on first — see the note there.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias PhoenixKitCatalogue.Catalogue.{ActivityLog, PubSub, SupplierComments}
  alias PhoenixKitCatalogue.Schemas.ItemSupplierInfo

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @pair_constraint "phoenix_kit_cat_item_supplier_info_current_pair_uniq"

  @doc """
  Supplier cost ranges for a batch of items, from their CURRENT rows
  (`valid_to` nil) that carry a unit cost: `%{item_uuid => [range]}` with
  one range per currency — `%{currency: "EUR" | nil, min: Decimal,
  max: Decimal, count: n}`, cheapest currency group first. Items without
  a priced supplier are absent. One query however many items.
  """
  @spec cost_ranges([Ecto.UUID.t()]) :: %{
          Ecto.UUID.t() => [
            %{
              currency: String.t() | nil,
              min: Decimal.t(),
              max: Decimal.t(),
              count: pos_integer()
            }
          ]
        }
  def cost_ranges([]), do: %{}

  def cost_ranges(item_uuids) when is_list(item_uuids) do
    from(i in ItemSupplierInfo,
      where: i.item_uuid in ^item_uuids and is_nil(i.valid_to) and not is_nil(i.unit_cost),
      group_by: [i.item_uuid, i.currency],
      select: {i.item_uuid, i.currency, min(i.unit_cost), max(i.unit_cost), count(i.uuid)}
    )
    |> repo().all()
    |> Enum.group_by(&elem(&1, 0), fn {_, currency, min, max, count} ->
      %{currency: blank_to_nil(currency), min: min, max: max, count: count}
    end)
    |> Map.new(fn {uuid, ranges} -> {uuid, Enum.sort_by(ranges, & &1.min, Decimal)} end)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  @doc """
  Lists *current* supplier-info rows for an item, ordered by position then
  inserted_at.

  A row is current when `valid_to` is `nil`. Closed rows (produced by
  `revise_unit_cost/3`) are excluded; use `history_for_pair/2` to retrieve the
  full history for a specific item/supplier pair.
  """
  @spec list_for_item(Ecto.UUID.t()) :: [ItemSupplierInfo.t()]
  def list_for_item(item_uuid) do
    from(i in ItemSupplierInfo,
      where: i.item_uuid == ^item_uuid and is_nil(i.valid_to),
      order_by: [asc: :position, asc: :inserted_at]
    )
    |> repo().all()
  end

  @doc """
  Returns all rows for an item/supplier pair ordered newest-first.

  Includes both current (`valid_to: nil`) and closed rows so callers can
  display a full price revision history. The current row is always first;
  closed rows follow, most recently closed first.
  """
  @spec history_for_pair(Ecto.UUID.t(), Ecto.UUID.t()) :: [ItemSupplierInfo.t()]
  def history_for_pair(item_uuid, supplier_uuid) do
    from(i in ItemSupplierInfo,
      where: i.item_uuid == ^item_uuid and i.supplier_uuid == ^supplier_uuid,
      # `valid_to` leads, nulls first: the CURRENT row is the one with no end
      # date, and that is the only column that says so. Everything below it is
      # a tiebreak between closed rows.
      #
      # It used to lead with `valid_from`, leaving "current first" to fall
      # through to `desc: :uuid`. That reads as safe because UUIDv7 is
      # time-ordered — but only to the MILLISECOND; inside one millisecond the
      # tail is random, so two revisions made in the same millisecond sorted
      # arbitrarily and the current row was not reliably first. That is the
      # intermittent failure in this function's test.
      order_by: [
        desc_nulls_first: :valid_to,
        desc_nulls_last: :valid_from,
        desc: :inserted_at,
        desc: :uuid
      ]
    )
    |> repo().all()
  end

  @doc "Fetches a supplier-info row by UUID. Returns `nil` if not found."
  @spec get(Ecto.UUID.t()) :: ItemSupplierInfo.t() | nil
  def get(uuid), do: repo().get(ItemSupplierInfo, uuid)

  @doc """
  Creates a supplier-info row.

  When the item has no primary supplier yet, the newly linked row is
  auto-promoted to primary (an item with suppliers but no primary is a
  valid state only when the user explicitly demotes it).
  """
  @spec create(map(), keyword()) ::
          {:ok, ItemSupplierInfo.t()}
          | {:error, :already_linked | Ecto.Changeset.t(ItemSupplierInfo.t())}
  def create(attrs, opts \\ []) do
    with :ok <- ensure_not_already_linked(attrs) do
      do_create(attrs, opts)
    end
  end

  # At most ONE CURRENT row per item/supplier pair. Several rows per pair
  # are legitimate — that is exactly what `revise_unit_cost/3` produces —
  # but only one of them may be open (`valid_to` nil). Two open rows mean
  # the same supplier listed twice on the item, with two live prices and
  # no rule about which one anything downstream should believe.
  #
  # Enforced here rather than only in the form so imports and any future
  # caller inherit it. `revise_unit_cost/3` inserts its successor through
  # its own Multi, not through this function, so revisions are unaffected.
  defp ensure_not_already_linked(attrs) do
    item_uuid = attrs["item_uuid"] || attrs[:item_uuid]
    supplier_uuid = attrs["supplier_uuid"] || attrs[:supplier_uuid]

    cond do
      is_nil(item_uuid) or is_nil(supplier_uuid) -> :ok
      current_for_pair(item_uuid, supplier_uuid) -> {:error, :already_linked}
      true -> :ok
    end
  end

  defp current_for_pair(item_uuid, supplier_uuid) do
    from(i in ItemSupplierInfo,
      where:
        i.item_uuid == ^item_uuid and i.supplier_uuid == ^supplier_uuid and is_nil(i.valid_to),
      limit: 1
    )
    |> repo().exists?()
  end

  # The pre-check above is not a guarantee — two callers can both see no row.
  # Core V180's partial unique index is what actually holds the line, so its
  # violation is translated back into the same reason the pre-check returns.
  defp already_linked_violation?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:supplier_uuid, {_msg, opts}} -> opts[:constraint_name] == @pair_constraint
      _ -> false
    end)
  end

  defp already_linked_violation?(_other), do: false

  # The comment thread is stamped here, never taken from attrs: a pair that
  # was attached before resumes its thread (see SupplierComments), a new
  # pair gets a fresh one, and neither an import nor a form can point the
  # row at somebody else's.
  defp do_create(attrs, opts) do
    changeset = ItemSupplierInfo.changeset(%ItemSupplierInfo{}, attrs)

    thread =
      SupplierComments.inherited_thread(
        Ecto.Changeset.get_field(changeset, :item_uuid),
        Ecto.Changeset.get_field(changeset, :supplier_uuid)
      ) || UUIDv7.generate()

    result =
      ActivityLog.with_log(
        fn -> changeset |> SupplierComments.stamp_changeset(thread) |> repo().insert() end,
        fn info ->
          %{
            action: "item_supplier_info.created",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "item_supplier_info",
            resource_uuid: info.uuid,
            metadata: %{
              "item_uuid" => info.item_uuid,
              "supplier_uuid" => info.supplier_uuid,
              "supplier_source" => info.supplier_source
            }
          }
        end
      )

    case result do
      {:ok, info} ->
        PubSub.broadcast(:item_supplier_info, info.uuid)

        if info.is_primary == false and primary_for_item(info.item_uuid) == nil do
          set_primary(info, opts)
        else
          {:ok, info}
        end

      {:error, changeset} ->
        if already_linked_violation?(changeset),
          do: {:error, :already_linked},
          else: {:error, changeset}
    end
  end

  @doc """
  Updates a supplier-info row.

  The row's comment thread is re-stamped from the row itself on every
  update, so a caller replacing `metadata` wholesale (the custom-field save
  does) cannot drop it, and attrs cannot change it.
  """
  @spec update(ItemSupplierInfo.t(), map(), keyword()) ::
          {:ok, ItemSupplierInfo.t()} | {:error, Ecto.Changeset.t(ItemSupplierInfo.t())}
  def update(%ItemSupplierInfo{} = info, attrs, opts \\ []) do
    thread = SupplierComments.thread_uuid(info)
    # The pair is the row's identity and carries its comment thread: an
    # update never re-points a row at another item or supplier (that would
    # move the thread with it). Detach and attach instead.
    attrs = Map.drop(attrs, [:item_uuid, :supplier_uuid, "item_uuid", "supplier_uuid"])

    result =
      ActivityLog.with_log(
        fn ->
          info
          |> ItemSupplierInfo.changeset(attrs)
          |> SupplierComments.stamp_changeset(thread)
          |> repo().update()
        end,
        fn updated ->
          %{
            action: "item_supplier_info.updated",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "item_supplier_info",
            resource_uuid: updated.uuid,
            metadata: %{"item_uuid" => updated.item_uuid}
          }
        end
      )

    with {:ok, updated} <- result do
      PubSub.broadcast(:item_supplier_info, updated.uuid)
      {:ok, updated}
    end
  end

  @doc """
  Removes a supplier from its item.

  The current row is CLOSED (`valid_to` today, primary flag dropped), not
  deleted — exactly what a price revision does to the row it supersedes.
  Every "current" reader filters on `valid_to`, so the supplier disappears
  from the item everywhere; `history_for_pair/2` keeps the row, which is
  what carries the pair's comment thread so re-attaching the supplier
  resumes it. Only the current row can be removed: `{:error, :not_current}`
  for one already closed.
  """
  @spec delete(ItemSupplierInfo.t(), keyword()) ::
          {:ok, ItemSupplierInfo.t()}
          | {:error, :not_current | Ecto.Changeset.t(ItemSupplierInfo.t())}
  def delete(info, opts \\ [])

  def delete(%ItemSupplierInfo{valid_to: valid_to}, _opts) when not is_nil(valid_to),
    do: {:error, :not_current}

  def delete(%ItemSupplierInfo{} = info, opts) do
    result =
      ActivityLog.with_log(
        fn -> close_current(info) end,
        fn closed ->
          %{
            action: "item_supplier_info.deleted",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "item_supplier_info",
            resource_uuid: closed.uuid,
            metadata: %{
              "item_uuid" => closed.item_uuid,
              "supplier_uuid" => closed.supplier_uuid,
              "closed" => true,
              "valid_to" => Date.to_iso8601(closed.valid_to)
            }
          }
        end
      )

    with {:ok, closed} <- result do
      PubSub.broadcast(:item_supplier_info, closed.uuid)
      {:ok, closed}
    end
  end

  # Re-read the row under lock so a revision or a second remove that
  # committed after the caller's struct was loaded cannot resurrect a
  # supplier or close a row twice; `:not_current` when it is no longer open.
  # A row dated to start in the future closes on its own start date, so
  # the window is never inverted (force_change bypasses the changeset's
  # valid_to >= valid_from rule).
  defp close_current(%ItemSupplierInfo{uuid: uuid}) do
    repo().transaction(fn ->
      case repo().one(from(i in ItemSupplierInfo, where: i.uuid == ^uuid, lock: "FOR UPDATE")) do
        %ItemSupplierInfo{valid_to: nil} = current -> close_row!(current)
        _ -> repo().rollback(:not_current)
      end
    end)
  end

  defp close_row!(current) do
    close_on = Enum.max([Date.utc_today(), current.valid_from || Date.utc_today()], Date)

    current
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.force_change(:valid_to, close_on)
    |> Ecto.Changeset.force_change(:is_primary, false)
    |> SupplierComments.stamp_changeset(SupplierComments.thread_uuid(current))
    |> repo().update()
    |> case do
      {:ok, closed} -> closed
      {:error, changeset} -> repo().rollback(changeset)
    end
  end

  @doc """
  Promotes a supplier-info row to primary for its item.

  Runs in a transaction: clears `is_primary` on all sibling rows first,
  then sets `is_primary: true` on the target. Respects the partial unique
  index — concurrent callers produce a constraint violation rather than
  double-marking.
  """
  @spec set_primary(ItemSupplierInfo.t(), keyword()) ::
          {:ok, ItemSupplierInfo.t()} | {:error, any()}
  def set_primary(info, opts \\ [])

  # Only a current row can be the primary; promoting a closed revision
  # would demote the live one and leave the item without a primary.
  def set_primary(%ItemSupplierInfo{valid_to: valid_to}, _opts) when not is_nil(valid_to),
    do: {:error, :not_current}

  def set_primary(%ItemSupplierInfo{} = info, opts) do
    # Re-read under lock: a concurrent close/revise can land between the
    # caller's struct and this write, and promoting that closed row would
    # demote the live primary (primary_for_item/1 then returns nil).
    result =
      repo().transaction(fn ->
        case repo().one(
               from(i in ItemSupplierInfo, where: i.uuid == ^info.uuid, lock: "FOR UPDATE")
             ) do
          %ItemSupplierInfo{valid_to: nil} = current -> promote_locked!(current)
          _ -> repo().rollback(:not_current)
        end
      end)

    case result do
      {:ok, updated} ->
        ActivityLog.log(%{
          action: "item_supplier_info.primary_set",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "item_supplier_info",
          resource_uuid: updated.uuid,
          metadata: %{"item_uuid" => updated.item_uuid}
        })

        PubSub.broadcast(:item_supplier_info, updated.uuid)
        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp promote_locked!(current) do
    from(i in ItemSupplierInfo,
      where: i.item_uuid == ^current.item_uuid and i.is_primary == true
    )
    |> repo().update_all(set: [is_primary: false])

    # force_change: when `current` is already the in-memory primary (e.g. the
    # auto-promoted first row), a plain changeset diffs to empty and the
    # UPDATE is skipped — while the clear above has just demoted the DB
    # row, silently leaving the item with no primary at all.
    current
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.force_change(:is_primary, true)
    |> Ecto.Changeset.unique_constraint(:item_uuid,
      name: :phoenix_kit_cat_item_supplier_info_primary_uniq,
      message: "another supplier is already marked primary for this item"
    )
    |> repo().update()
    |> case do
      {:ok, updated} -> updated
      {:error, changeset} -> repo().rollback(changeset)
    end
  end

  @doc """
  Returns the *current* primary supplier-info row for an item, or `nil` if
  none is marked primary.

  Only current rows (`valid_to: nil`) are considered — closed revision rows
  carry `is_primary: false` by construction and are excluded.
  """
  @spec primary_for_item(Ecto.UUID.t()) :: ItemSupplierInfo.t() | nil
  def primary_for_item(item_uuid) do
    from(i in ItemSupplierInfo,
      where: i.item_uuid == ^item_uuid and i.is_primary == true and is_nil(i.valid_to),
      limit: 1
    )
    |> repo().one()
  end

  @doc """
  Closes the current junction row and inserts a successor with the new unit
  cost, creating an append-only price revision history.

  ## Guards

    * `{:error, :not_current}` — `info.valid_to` is not `nil`; only the current
      row can be revised.
    * `{:ok, info}` (no-op) — `new_cost` equals `info.unit_cost` (or both
      effectively zero when `unit_cost` is `nil`), *and* `opts[:currency]` is
      either absent or matches the row's current currency. A currency-only
      change (same cost, different `:currency`) still creates a revision.

  ## Transaction

  Within a single Ecto.Multi transaction:

  1. The current row is closed: `valid_to` is set to today and `is_primary` is
     forced to `false` via `force_change/3`, freeing the partial-unique index
     inside the tx so the successor can inherit the primary flag.
  2. A successor row is inserted copying `item_uuid`, `supplier_uuid`,
     `supplier_source`, `supplier_name_snapshot`, `supplier_sku`, `currency`,
     `lead_time_days`, `min_order_qty`, `position`, and `metadata` from the
     closed row. `unit_cost` is set to `new_cost`; `valid_from` is today;
     `valid_to` is `nil`; `is_primary` inherits the original row's value.

  ## Options

    * `:actor_uuid` — UUID of the user performing the revision (persisted in the
      activity log).
    * `:source` — free-form source label (e.g. `"goods_receipt"`).
    * `:source_uuid` — UUID of the originating resource (e.g. receipt UUID).
    * `:currency` — when provided and different from the row's currency, the
      successor stores the new currency; both old and new currencies are
      recorded in the activity metadata.

  ## Currency awareness

  The successor always keeps the row's own currency unless `opts[:currency]` is
  given and differs, in which case the new currency is stored and the activity
  log captures both.
  """
  @spec revise_unit_cost(ItemSupplierInfo.t(), Decimal.t(), keyword()) ::
          {:ok, ItemSupplierInfo.t()} | {:error, :not_current | Ecto.Changeset.t()}
  def revise_unit_cost(%ItemSupplierInfo{} = info, new_cost, opts \\ []) do
    caller_currency = opts[:currency]
    currency_unchanged = is_nil(caller_currency) or caller_currency == info.currency

    cond do
      not is_nil(info.valid_to) ->
        {:error, :not_current}

      Decimal.compare(new_cost, info.unit_cost || Decimal.new(0)) == :eq and
          currency_unchanged ->
        {:ok, info}

      true ->
        do_revise_unit_cost(info, new_cost, opts)
    end
  end

  defp do_revise_unit_cost(%ItemSupplierInfo{} = info, new_cost, opts) do
    today = Date.utc_today()

    result =
      Multi.new()
      # Same class as close_current/1: a concurrent revise or remove can
      # close this row after the caller loaded it. Lock, re-check, then
      # close *that* row so we never insert a second current pair.
      |> Multi.run(:current, fn repo, _ -> lock_current_row(repo, info.uuid) end)
      |> Multi.update(:close, &close_for_revision(&1.current, today))
      |> Multi.insert(
        :successor,
        &successor_changeset(&1.current, new_cost, today, opts[:currency])
      )
      |> repo().transaction()

    case result do
      {:ok, %{current: current, successor: successor}} ->
        log_revision(current, successor, new_cost, opts)
        PubSub.broadcast(:item_supplier_info, successor.uuid)
        {:ok, successor}

      {:error, _op, reason, _changes} ->
        {:error, reason}
    end
  end

  defp lock_current_row(repo, uuid) do
    case repo.one(from(i in ItemSupplierInfo, where: i.uuid == ^uuid, lock: "FOR UPDATE")) do
      %ItemSupplierInfo{valid_to: nil} = current -> {:ok, current}
      _ -> {:error, :not_current}
    end
  end

  defp close_for_revision(current, today) do
    current
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.force_change(:valid_to, today)
    |> Ecto.Changeset.force_change(:is_primary, false)
  end

  defp successor_changeset(current, new_cost, today, caller_currency) do
    new_currency =
      if caller_currency && caller_currency != current.currency,
        do: caller_currency,
        else: current.currency

    attrs = %{
      item_uuid: current.item_uuid,
      supplier_uuid: current.supplier_uuid,
      supplier_source: current.supplier_source,
      supplier_name_snapshot: current.supplier_name_snapshot,
      supplier_sku: current.supplier_sku,
      unit_cost: new_cost,
      currency: new_currency,
      lead_time_days: current.lead_time_days,
      min_order_qty: current.min_order_qty,
      is_primary: current.is_primary,
      valid_from: today,
      valid_to: nil,
      position: current.position,
      metadata: SupplierComments.stamp(current.metadata, SupplierComments.thread_uuid(current))
    }

    ItemSupplierInfo.changeset(%ItemSupplierInfo{}, attrs)
    |> Ecto.Changeset.unique_constraint(:item_uuid,
      name: :phoenix_kit_cat_item_supplier_info_primary_uniq,
      message: "another supplier is already marked primary for this item"
    )
  end

  defp log_revision(current, successor, new_cost, opts) do
    old_cost_str =
      if current.unit_cost, do: Decimal.to_string(current.unit_cost, :normal), else: nil

    caller_currency = opts[:currency]

    currency_meta =
      if caller_currency && caller_currency != current.currency,
        do: %{"old_currency" => current.currency, "new_currency" => successor.currency},
        else: %{}

    ActivityLog.log(%{
      action: "item_supplier_info.cost_revised",
      mode: "manual",
      actor_uuid: opts[:actor_uuid],
      resource_type: "item_supplier_info",
      resource_uuid: successor.uuid,
      metadata:
        Map.merge(
          %{
            "item_uuid" => current.item_uuid,
            "supplier_uuid" => current.supplier_uuid,
            "old_cost" => old_cost_str,
            "new_cost" => Decimal.to_string(new_cost, :normal),
            "source" => opts[:source],
            "source_uuid" => opts[:source_uuid]
          },
          currency_meta
        )
    })
  end
end
