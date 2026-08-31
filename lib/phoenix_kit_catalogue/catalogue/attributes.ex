defmodule PhoenixKitCatalogue.Catalogue.Attributes do
  @moduledoc """
  Attribute groups — reusable, translatable sets of product characteristics.

  A group ("Idea doors") owns attributes ("Color", "Trim"), each attribute
  owns ordered values ("White", "Oak"); an item is linked to one group
  through `phoenix_kit_cat_item_attribute_groups` and inherits everything
  the group defines. This is an evolution of the hand-typed per-item
  metadata (`item.data["meta"]`), which stays untouched and is surfaced
  read/editable by the item form's legacy collapse.

  ## Identity and translations

  `key` slugs (auto-generated from the primary-language name via
  `PhoenixKit.Utils.Slug`, immutable after creation) plus row UUIDs are the
  durable identity — future exclusion rules and parent-app order lines
  reference them, so editing a translation never changes what old data
  means. Display names ride the module's multilang `data` JSONB convention
  (primary language in the `name`/`value` columns, other languages in
  `data`); resolve them with `resolved_group/2`.

  ## Deletion vs archive

  All three definition levels carry `status` (`"active"` / `"archived"`).
  Archive is the path for anything in use: the DB RESTRICTs deleting a
  group any item references, and `delete_attribute_group/2` performs the
  values → attributes → group cascade explicitly in one transaction
  (mirroring `permanently_delete_catalogue/2`'s gate-then-cascade shape)
  rather than trusting a silent DB cascade.

  ## Downstream contract

  Order lines in the parent app that record a chosen value must snapshot
  the resolved labels and keys at order time — the UUID reference alone is
  identity, not history.

  Public surface is re-exported from `PhoenixKitCatalogue.Catalogue` via
  `defdelegate`.
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.Utils.Multilang
  alias PhoenixKit.Utils.Slug
  alias PhoenixKitCatalogue.Catalogue.{ActivityLog, PubSub}
  alias PhoenixKitCatalogue.Schemas.Attribute
  alias PhoenixKitCatalogue.Schemas.AttributeGroup
  alias PhoenixKitCatalogue.Schemas.AttributeValue
  alias PhoenixKitCatalogue.Schemas.Item
  alias PhoenixKitCatalogue.Schemas.ItemAttributeGroup

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ── Groups ─────────────────────────────────────────────────────────

  @doc """
  Lists attribute groups ordered by position, then name.

  ## Options

    * `:status` — filter by status (`"active"` / `"archived"`); nil = all.
  """
  @spec list_attribute_groups(keyword()) :: [AttributeGroup.t()]
  def list_attribute_groups(opts \\ []) do
    query = from(g in AttributeGroup, order_by: [asc: g.position, asc: g.name])

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> where(query, [g], g.status == ^status)
      end

    repo().all(query)
  end

  @doc "Fetches an attribute group by UUID. Returns `nil` if not found."
  @spec get_attribute_group(Ecto.UUID.t()) :: AttributeGroup.t() | nil
  def get_attribute_group(uuid), do: repo().get(AttributeGroup, uuid)

  @doc """
  Fetches a group with ALL its attributes and values preloaded in position
  order, archived rows included — the group editor's working set. Consumer
  paths (item preview, product card) want `resolved_group/2` instead.
  """
  @spec get_attribute_group_full(Ecto.UUID.t()) :: AttributeGroup.t() | nil
  def get_attribute_group_full(uuid) do
    case repo().get(AttributeGroup, uuid) do
      nil -> nil
      group -> repo().preload(group, attributes: :values)
    end
  end

  @doc """
  Per-group attribute counts for the groups list — one grouped query,
  active attributes only. Returns `%{group_uuid => count}`.
  """
  @spec attribute_counts([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => non_neg_integer()}
  def attribute_counts([]), do: %{}

  def attribute_counts(group_uuids) when is_list(group_uuids) do
    from(a in Attribute,
      where: a.group_uuid in ^group_uuids and a.status == "active",
      group_by: a.group_uuid,
      select: {a.group_uuid, count(a.uuid)}
    )
    |> repo().all()
    |> Map.new()
  end

  @doc """
  How many items are assigned to each of the given groups — one grouped
  query. Returns `%{group_uuid => count}`; drives the "in use" gate and
  the list page's usage column.
  """
  @spec assignment_counts([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => non_neg_integer()}
  def assignment_counts([]), do: %{}

  def assignment_counts(group_uuids) when is_list(group_uuids) do
    from(iag in ItemAttributeGroup,
      where: iag.attribute_group_uuid in ^group_uuids,
      group_by: iag.attribute_group_uuid,
      select: {iag.attribute_group_uuid, count(iag.uuid)}
    )
    |> repo().all()
    |> Map.new()
  end

  @doc "Returns a changeset for tracking attribute-group form changes."
  @spec change_attribute_group(AttributeGroup.t(), map()) :: Ecto.Changeset.t()
  def change_attribute_group(%AttributeGroup{} = group, attrs \\ %{}) do
    AttributeGroup.changeset(group, attrs)
  end

  @doc "Creates an attribute group."
  @spec create_attribute_group(map(), keyword()) ::
          {:ok, AttributeGroup.t()} | {:error, Ecto.Changeset.t()}
  def create_attribute_group(attrs, opts \\ []) do
    result =
      ActivityLog.with_log(
        fn -> %AttributeGroup{} |> AttributeGroup.changeset(attrs) |> repo().insert() end,
        fn group ->
          %{
            action: "attribute_group.created",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "attribute_group",
            resource_uuid: group.uuid,
            metadata: %{"name" => group.name}
          }
        end
      )

    with {:ok, group} <- result do
      PubSub.broadcast(:attribute_group, group.uuid)
      {:ok, group}
    end
  end

  @doc "Updates an attribute group (name, translations, status, position)."
  @spec update_attribute_group(AttributeGroup.t(), map(), keyword()) ::
          {:ok, AttributeGroup.t()} | {:error, Ecto.Changeset.t()}
  def update_attribute_group(%AttributeGroup{} = group, attrs, opts \\ []) do
    result =
      ActivityLog.with_log(
        fn -> group |> AttributeGroup.changeset(attrs) |> repo().update() end,
        fn updated ->
          %{
            action: "attribute_group.updated",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "attribute_group",
            resource_uuid: updated.uuid,
            metadata: %{"name" => updated.name}
          }
        end
      )

    with {:ok, updated} <- result do
      PubSub.broadcast(:attribute_group, updated.uuid)
      {:ok, updated}
    end
  end

  @doc """
  Hard-deletes a group with an explicit values → attributes → group
  cascade in one transaction.

  Gated: returns `{:error, :in_use}` when any item is assigned to the
  group (the assignment FK would RESTRICT anyway — the gate turns the
  constraint error into a domain answer). Archive is the path for groups
  in use.
  """
  @spec delete_attribute_group(AttributeGroup.t(), keyword()) ::
          {:ok, AttributeGroup.t()} | {:error, :in_use | Ecto.Changeset.t()}
  def delete_attribute_group(%AttributeGroup{} = group, opts \\ []) do
    result =
      ActivityLog.with_log(
        fn -> delete_group_cascade(group) end,
        fn _ ->
          %{
            action: "attribute_group.deleted",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "attribute_group",
            resource_uuid: group.uuid,
            metadata: %{"name" => group.name}
          }
        end
      )

    with {:ok, deleted} <- result do
      PubSub.broadcast(:attribute_group, group.uuid)
      {:ok, deleted}
    end
  end

  defp delete_group_cascade(group) do
    repo().transaction(fn ->
      in_use =
        repo().exists?(
          from(iag in ItemAttributeGroup, where: iag.attribute_group_uuid == ^group.uuid)
        )

      if in_use do
        repo().rollback(:in_use)
      else
        attr_uuids =
          repo().all(from(a in Attribute, where: a.group_uuid == ^group.uuid, select: a.uuid))

        repo().delete_all(from(v in AttributeValue, where: v.attribute_uuid in ^attr_uuids))
        repo().delete_all(from(a in Attribute, where: a.group_uuid == ^group.uuid))
        repo().delete!(group)
      end
    end)
  rescue
    # TOCTOU: an assignment (or new child) can land between the gate and
    # the delete; the RESTRICT FK then raises. Same domain answer as the
    # gate, not a crash (panel finding).
    _e in [Ecto.ConstraintError, Postgrex.Error] -> {:error, :in_use}
  end

  # ── Attributes ─────────────────────────────────────────────────────

  @doc "Fetches an attribute by UUID (with its group). Returns `nil` if not found."
  @spec get_attribute(Ecto.UUID.t()) :: Attribute.t() | nil
  def get_attribute(uuid) do
    case repo().get(Attribute, uuid) do
      nil -> nil
      attribute -> repo().preload(attribute, :group)
    end
  end

  @doc """
  Adds an attribute to a group. The stable `key` slug is generated from
  the given name (deduped within the group); position appends at the end.
  """
  @spec create_attribute(AttributeGroup.t(), map(), keyword()) ::
          {:ok, Attribute.t()} | {:error, Ecto.Changeset.t()}
  def create_attribute(%AttributeGroup{} = group, attrs, opts \\ []) do
    name = attrs["name"] || attrs[:name]

    taken =
      repo().all(from(a in Attribute, where: a.group_uuid == ^group.uuid, select: a.key))

    # MAX+1, not COUNT: after a mid-list delete, COUNT would hand out a
    # position an existing row still holds (panel finding).
    next_pos =
      repo().one(
        from(a in Attribute,
          where: a.group_uuid == ^group.uuid,
          select: coalesce(max(a.position), -1) + 1
        )
      )

    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("group_uuid", group.uuid)
      |> Map.put("key", generate_key(name, taken, "attr"))
      |> Map.put_new("position", next_pos)

    result =
      ActivityLog.with_log(
        fn -> %Attribute{} |> Attribute.create_changeset(attrs) |> repo().insert() end,
        fn attribute ->
          %{
            action: "attribute_group.attribute_added",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "attribute_group",
            resource_uuid: group.uuid,
            metadata: %{"name" => attribute.name, "key" => attribute.key}
          }
        end
      )

    with {:ok, attribute} <- result do
      PubSub.broadcast(:attribute_group, group.uuid)
      {:ok, attribute}
    end
  end

  @doc "Updates an attribute (name, translations, kind, status, position). `key` is immutable."
  @spec update_attribute(Attribute.t(), map()) ::
          {:ok, Attribute.t()} | {:error, Ecto.Changeset.t()}
  def update_attribute(%Attribute{} = attribute, attrs) do
    with {:ok, updated} <-
           attribute |> Attribute.update_changeset(attrs) |> repo().update() do
      PubSub.broadcast(:attribute_group, attribute.group_uuid)
      {:ok, updated}
    end
  end

  @doc "Deletes an attribute and its values in one transaction."
  @spec delete_attribute(Attribute.t(), keyword()) ::
          {:ok, Attribute.t()} | {:error, term()}
  def delete_attribute(%Attribute{} = attribute, opts \\ []) do
    result =
      ActivityLog.with_log(
        fn ->
          # RESTRICT can still fire if a value lands concurrently between
          # the delete_all and the attribute delete — domain error, not a
          # crash.
          try do
            repo().transaction(fn ->
              repo().delete_all(
                from(v in AttributeValue, where: v.attribute_uuid == ^attribute.uuid)
              )

              repo().delete!(attribute)
            end)
          rescue
            _e in [Ecto.ConstraintError, Postgrex.Error] -> {:error, :in_use}
          end
        end,
        fn _ ->
          %{
            action: "attribute_group.attribute_removed",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "attribute_group",
            resource_uuid: attribute.group_uuid,
            metadata: %{"name" => attribute.name, "key" => attribute.key}
          }
        end
      )

    with {:ok, deleted} <- result do
      PubSub.broadcast(:attribute_group, attribute.group_uuid)
      {:ok, deleted}
    end
  end

  @doc """
  Persists a manual ordering of a group's attributes. UUIDs not in the
  list keep their position; unknown UUIDs are dropped BEFORE any writes —
  the client list is forgeable, so the write count is bounded by the
  group's real row count, never by payload length (panel finding).
  """
  @spec reorder_attributes(AttributeGroup.t(), [Ecto.UUID.t()]) :: :ok | {:error, term()}
  def reorder_attributes(%AttributeGroup{} = group, uuids) when is_list(uuids) do
    known =
      repo().all(from(a in Attribute, where: a.group_uuid == ^group.uuid, select: a.uuid))

    ordered = sanitize_reorder(uuids, known)

    result =
      run_reorder(fn ->
        ordered
        |> Enum.with_index()
        |> Enum.each(fn {uuid, idx} ->
          repo().update_all(
            from(a in Attribute, where: a.uuid == ^uuid),
            set: [position: idx, updated_at: DateTime.utc_now(:second)]
          )
        end)
      end)

    # Broadcast and report success only if the transaction COMMITTED, and
    # make "did not commit" an outcome this function can actually return.
    #
    # The result used to be discarded and `:ok` returned unconditionally. I
    # first changed only this `case`, which was not the fix I described:
    # nothing in the transaction calls `rollback/1`, so a database failure
    # RAISES straight out of `Repo.transaction/1` and an `{:error, _}` clause
    # underneath it is unreachable — the page still crashed, and the spec
    # still advertised an error nothing produced. `run_reorder/1` turns the
    # DB families this can genuinely hit into that error, and leaves
    # programmer errors (KeyError, FunctionClauseError from a future
    # refactor) to crash as they should.
    case result do
      {:ok, _} ->
        PubSub.broadcast(:attribute_group, group.uuid)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Values ─────────────────────────────────────────────────────────

  @doc "Fetches a value by UUID (with its attribute). Returns `nil` if not found."
  @spec get_attribute_value(Ecto.UUID.t()) :: AttributeValue.t() | nil
  def get_attribute_value(uuid) do
    case repo().get(AttributeValue, uuid) do
      nil -> nil
      value -> repo().preload(value, :attribute)
    end
  end

  @doc """
  Adds a value to an attribute. The stable `key` slug is generated from
  the display text (deduped within the attribute); position appends at the
  end; the attribute's first value becomes the default automatically.
  """
  @spec create_attribute_value(Attribute.t(), map()) ::
          {:ok, AttributeValue.t()} | {:error, Ecto.Changeset.t()}
  def create_attribute_value(%Attribute{} = attribute, attrs) do
    text = attrs["value"] || attrs[:value]

    taken =
      repo().all(
        from(v in AttributeValue, where: v.attribute_uuid == ^attribute.uuid, select: v.key)
      )

    next_pos =
      repo().one(
        from(v in AttributeValue,
          where: v.attribute_uuid == ^attribute.uuid,
          select: coalesce(max(v.position), -1) + 1
        )
      )

    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("attribute_uuid", attribute.uuid)
      |> Map.put("key", generate_key(text, taken, "value"))
      |> Map.put_new("position", next_pos)

    # Insert non-default, then atomically promote when the attribute has no
    # default — the read-count-then-flag version let two concurrent "first
    # value" inserts both claim the default and trip the partial unique
    # index (panel finding). `promote_when_none/1` is one guarded UPDATE,
    # so the race resolves inside Postgres instead.
    result =
      repo().transaction(fn ->
        case %AttributeValue{} |> AttributeValue.create_changeset(attrs) |> repo().insert() do
          {:ok, value} ->
            promote_when_none(attribute.uuid)
            repo().get!(AttributeValue, value.uuid)

          {:error, changeset} ->
            repo().rollback(changeset)
        end
      end)

    case result do
      {:ok, value} ->
        PubSub.broadcast(:attribute_group, attribute.group_uuid)
        {:ok, value}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  @doc "Updates a value's display text / translations / status. `key` is immutable."
  @spec update_attribute_value(AttributeValue.t(), map()) ::
          {:ok, AttributeValue.t()} | {:error, Ecto.Changeset.t()}
  def update_attribute_value(%AttributeValue{} = value, attrs) do
    with {:ok, updated} <-
           value |> AttributeValue.update_changeset(attrs) |> repo().update() do
      broadcast_for_attribute(value.attribute_uuid)
      {:ok, updated}
    end
  end

  @doc """
  Deletes a value. If it was the default, the lowest-position remaining
  active value is promoted so a `multi` attribute never silently loses
  its default.
  """
  @spec delete_attribute_value(AttributeValue.t()) ::
          {:ok, AttributeValue.t()} | {:error, term()}
  def delete_attribute_value(%AttributeValue{} = value) do
    result =
      repo().transaction(fn ->
        # delete_all by uuid: a concurrent delete of the same row is a
        # no-op here, not an Ecto.StaleEntryError crash.
        repo().delete_all(from(v in AttributeValue, where: v.uuid == ^value.uuid))
        promote_when_none(value.attribute_uuid)
        value
      end)

    with {:ok, deleted} <- result do
      broadcast_for_attribute(value.attribute_uuid)
      {:ok, deleted}
    end
  rescue
    # A concurrent default flip can still trip the partial unique index at
    # commit; surface a domain error instead of crashing the LiveView.
    _e in [Ecto.ConstraintError, Postgrex.Error] -> {:error, :conflict}
  end

  @doc """
  Makes a value its attribute's default. Unset-then-set inside one
  transaction (the partial unique index allows at most one default);
  fails with `{:error, :not_found}` when the value vanished concurrently
  and `{:error, :conflict}` when two flips race on the index.
  """
  @spec set_default_value(AttributeValue.t()) :: {:ok, AttributeValue.t()} | {:error, term()}
  def set_default_value(%AttributeValue{} = value) do
    result =
      repo().transaction(fn ->
        repo().update_all(
          from(v in AttributeValue,
            where: v.attribute_uuid == ^value.attribute_uuid and v.is_default
          ),
          set: [is_default: false, updated_at: DateTime.utc_now(:second)]
        )

        # Row-count check: a concurrently deleted target must not commit a
        # cleared-defaults state while reporting success (panel finding).
        case repo().update_all(from(v in AttributeValue, where: v.uuid == ^value.uuid),
               set: [is_default: true, updated_at: DateTime.utc_now(:second)]
             ) do
          {1, _} -> %{value | is_default: true}
          _ -> repo().rollback(:not_found)
        end
      end)

    with {:ok, updated} <- result do
      broadcast_for_attribute(value.attribute_uuid)
      {:ok, updated}
    end
  rescue
    _e in [Ecto.ConstraintError, Postgrex.Error] -> {:error, :conflict}
  end

  # One guarded UPDATE: crown the lowest-position active value, but only
  # when the attribute currently has NO default — atomic under the partial
  # unique index, so concurrent callers can't double-promote.
  defp promote_when_none(attribute_uuid) do
    target =
      from(v in AttributeValue,
        where: v.attribute_uuid == ^attribute_uuid and v.status == "active",
        order_by: [asc: v.position, asc: v.uuid],
        limit: 1,
        select: v.uuid
      )

    none_default =
      from(v in AttributeValue,
        where: v.attribute_uuid == ^attribute_uuid and v.is_default
      )

    repo().update_all(
      from(v in AttributeValue,
        where: v.uuid in subquery(target) and not exists(none_default)
      ),
      set: [is_default: true, updated_at: DateTime.utc_now(:second)]
    )
  end

  @doc "Persists a manual ordering of an attribute's values (same contract as `reorder_attributes/2`)."
  @spec reorder_attribute_values(Attribute.t(), [Ecto.UUID.t()]) :: :ok | {:error, term()}
  def reorder_attribute_values(%Attribute{} = attribute, uuids) when is_list(uuids) do
    known =
      repo().all(
        from(v in AttributeValue, where: v.attribute_uuid == ^attribute.uuid, select: v.uuid)
      )

    ordered = sanitize_reorder(uuids, known)

    result =
      run_reorder(fn ->
        ordered
        |> Enum.with_index()
        |> Enum.each(fn {uuid, idx} ->
          repo().update_all(
            from(v in AttributeValue, where: v.uuid == ^uuid),
            set: [position: idx, updated_at: DateTime.utc_now(:second)]
          )
        end)
      end)

    case result do
      {:ok, _} ->
        PubSub.broadcast(:attribute_group, attribute.group_uuid)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `Repo.transaction/1`, with the database failures a reorder can actually
  # hit turned into `{:error, reason}` instead of an exception that unwinds
  # past both the broadcast and the caller.
  #
  # Deliberately narrow. A deadlock, a lost connection or a constraint
  # violation is a runtime condition the caller can report; a KeyError or a
  # FunctionClauseError is a bug, and swallowing those into a flash would
  # hide it. Same reasoning, and the same family list, as the import path's
  # rescue.
  defp run_reorder(fun) do
    repo().transaction(fun)
  rescue
    e in [DBConnection.ConnectionError, Ecto.QueryError, Postgrex.Error] ->
      {:error, e}
  end

  # Dedupe + intersect the forgeable client list with the real child set;
  # only rows the parent actually owns get an index.
  defp sanitize_reorder(uuids, known) do
    known_set = MapSet.new(known)

    uuids
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.filter(&MapSet.member?(known_set, &1))
  end

  defp broadcast_for_attribute(attribute_uuid) do
    group_uuid =
      repo().one(from(a in Attribute, where: a.uuid == ^attribute_uuid, select: a.group_uuid))

    PubSub.broadcast(:attribute_group, group_uuid)
  end

  # ── Item assignment ────────────────────────────────────────────────

  @doc """
  Sets (or clears, with `nil`) the item's attribute group.

  Validates the group exists and is active — except that keeping the
  item's CURRENT group is always allowed even when that group has been
  archived since (the stale-select rule: an archived assignment renders,
  it just can't be newly chosen). Returns `{:error, :invalid_group}` for
  anything else.
  """
  @spec set_item_attribute_group(Item.t(), Ecto.UUID.t() | nil, keyword()) ::
          {:ok, :assigned | :cleared | :unchanged} | {:error, :invalid_group | Ecto.Changeset.t()}
  def set_item_attribute_group(item, group_uuid, opts \\ [])

  def set_item_attribute_group(%Item{} = item, nil, opts) do
    case repo().get_by(ItemAttributeGroup, item_uuid: item.uuid) do
      nil ->
        {:ok, :unchanged}

      assignment ->
        # delete_all by uuid: a concurrent clear (double-click, second tab)
        # is a no-op, not an Ecto.StaleEntryError crash.
        repo().delete_all(from(iag in ItemAttributeGroup, where: iag.uuid == ^assignment.uuid))
        log_assignment(item, nil, opts)
        PubSub.broadcast(:item, item.uuid, item.catalogue_uuid)
        {:ok, :cleared}
    end
  end

  def set_item_attribute_group(%Item{} = item, group_uuid, opts) when is_binary(group_uuid) do
    # Events are client-forgeable: a malformed uuid must be a domain error,
    # not an Ecto.Query.CastError crash further down.
    case Ecto.UUID.cast(group_uuid) do
      {:ok, _} -> do_set_item_attribute_group(item, group_uuid, opts)
      :error -> {:error, :invalid_group}
    end
  end

  defp do_set_item_attribute_group(%Item{} = item, group_uuid, opts) do
    current = repo().get_by(ItemAttributeGroup, item_uuid: item.uuid)

    cond do
      current && current.attribute_group_uuid == group_uuid ->
        {:ok, :unchanged}

      not valid_assignable_group?(group_uuid) ->
        {:error, :invalid_group}

      true ->
        result =
          if current do
            current
            |> ItemAttributeGroup.changeset(%{attribute_group_uuid: group_uuid})
            |> repo().update()
          else
            %ItemAttributeGroup{}
            |> ItemAttributeGroup.changeset(%{
              item_uuid: item.uuid,
              attribute_group_uuid: group_uuid
            })
            |> repo().insert()
          end

        with {:ok, _} <- result do
          log_assignment(item, group_uuid, opts)
          PubSub.broadcast(:item, item.uuid, item.catalogue_uuid)
          {:ok, :assigned}
        end
    end
  end

  defp valid_assignable_group?(group_uuid) do
    repo().exists?(
      from(g in AttributeGroup, where: g.uuid == ^group_uuid and g.status == "active")
    )
  end

  defp log_assignment(item, group_uuid, opts) do
    ActivityLog.log(%{
      action:
        if(group_uuid, do: "item.attribute_group_set", else: "item.attribute_group_cleared"),
      mode: "manual",
      actor_uuid: opts[:actor_uuid],
      resource_type: "item",
      resource_uuid: item.uuid,
      metadata: %{"name" => item.name, "attribute_group_uuid" => group_uuid}
    })
  end

  @doc """
  The item's current assignment (or `nil`) — one indexed lookup.
  """
  @spec get_item_attribute_group_uuid(Ecto.UUID.t()) :: Ecto.UUID.t() | nil
  def get_item_attribute_group_uuid(item_uuid) do
    repo().one(
      from(iag in ItemAttributeGroup,
        where: iag.item_uuid == ^item_uuid,
        select: iag.attribute_group_uuid
      )
    )
  end

  @doc """
  Batch map of `%{item_uuid => attribute_group_uuid}` for the given items —
  one indexed query; drives the list/card indicator chips with no per-row
  lookups.
  """
  @spec item_attribute_group_map([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => Ecto.UUID.t()}
  def item_attribute_group_map([]), do: %{}

  def item_attribute_group_map(item_uuids) when is_list(item_uuids) do
    from(iag in ItemAttributeGroup,
      where: iag.item_uuid in ^item_uuids,
      select: {iag.item_uuid, iag.attribute_group_uuid}
    )
    |> repo().all()
    |> Map.new()
  end

  # ── Resolution (translated read models) ────────────────────────────

  @doc """
  The programmatic read surface: a group resolved for display in `lang` —
  active attributes in position order, each with its active values in
  position order, names/labels translated with primary-language fallback.

  Returns `nil` when the group doesn't exist. Shape:

      %{
        uuid: ..., key-less group: name: "Idea doors",
        attributes: [
          %{uuid: ..., key: "color", name: "Цвет", kind: "multi",
            values: [%{uuid: ..., key: "oak", value: "Дуб", default?: true}, ...]},
          ...
        ]
      }

  This is what the item form preview, the product card, and (later) the
  parent app's order-line picker all consume — module boundaries stay at
  the context, not at raw table access.
  """
  @spec resolved_group(Ecto.UUID.t() | nil, String.t()) :: map() | nil
  def resolved_group(nil, _lang), do: nil

  def resolved_group(group_uuid, lang) when is_binary(group_uuid) do
    group =
      repo().one(
        from(g in AttributeGroup,
          where: g.uuid == ^group_uuid,
          preload: [attributes: ^active_attributes_query()]
        )
      )

    case group do
      nil ->
        nil

      group ->
        %{
          uuid: group.uuid,
          name: translated(group.data, lang, "name", group.name),
          status: group.status,
          attributes:
            Enum.map(group.attributes, fn attribute ->
              %{
                uuid: attribute.uuid,
                key: attribute.key,
                name: translated(attribute.data, lang, "name", attribute.name),
                kind: attribute.kind,
                values:
                  Enum.map(attribute.values, fn value ->
                    %{
                      uuid: value.uuid,
                      key: value.key,
                      value: translated(value.data, lang, "value", value.value),
                      default?: value.is_default
                    }
                  end)
              }
            end)
        }
    end
  end

  defp active_attributes_query do
    from(a in Attribute,
      where: a.status == "active",
      order_by: [asc: a.position, asc: a.uuid],
      preload: [
        values:
          ^from(v in AttributeValue,
            where: v.status == "active",
            order_by: [asc: v.position, asc: v.uuid]
          )
      ]
    )
  end

  # Multilang stores per-language sub-maps with "_"-prefixed field keys
  # ("_name"); primary-language text lives in the schema column. Fall back
  # to the column whenever the requested language has no override.
  # (`get_language_data/2` always returns a map, so no other shape to match.)
  defp translated(data, lang, field, fallback) do
    lang_data = Multilang.get_language_data(data || %{}, lang)

    case lang_data["_" <> field] do
      text when is_binary(text) and text != "" -> text
      _ -> fallback
    end
  end

  # ── Key generation ─────────────────────────────────────────────────

  # Stable slug from the primary-language display text: transliterated,
  # underscored, deduped with -2/-3… within the parent scope. Names that
  # slugify to nothing (emoji, punctuation) fall back to the given base.
  defp generate_key(nil, _taken, base), do: base

  # Forged non-string names (maps, lists) must not reach to_string/1 —
  # fall back to the base; the changeset then rejects the junk name.
  defp generate_key(text, _taken, base) when not is_binary(text), do: base

  defp generate_key(text, taken, base) do
    slug =
      case Slug.slugify(to_string(text)) do
        "" -> base
        s -> String.slice(s, 0, 90)
      end

    if slug in taken, do: dedupe_key(slug, taken), else: slug
  end

  defp dedupe_key(slug, taken) do
    Enum.find_value(2..1000, fn n ->
      candidate = "#{slug}-#{n}"
      if candidate not in taken, do: candidate
    end)
  end
end
