defmodule PhoenixKitCatalogue.API.UpdateProducts do
  @moduledoc false
  # Tool `catalogue.update_products`.

  alias PhoenixKit.Modules.Storage.ResourceFolders
  alias PhoenixKitCatalogue.API
  alias PhoenixKitCatalogue.API.{Attributes, Common}
  alias PhoenixKitCatalogue.Catalogue

  require Logger

  @tool "catalogue.update_products"
  @columns %{
    "name" => :name,
    "description" => :description,
    "sku" => :sku,
    "status" => :status,
    "unit" => :unit
  }
  @external_id_path ["api", "external_id"]
  # Where the category moves that went through are collected, for the media folders to
  # follow them even when a later row raises.
  @moves_key {__MODULE__, :moves}

  @spec call(map(), map()) ::
          {:ok, map()} | {:preview, map(), String.t()} | {:error, atom(), String.t(), map()}
  def call(input, ctx) do
    with :ok <- Common.ensure_schema(),
         {:ok, catalogue} <- API.resolve_catalogue(input["catalogue_id"], writable: true) do
      entries = input["items"]

      resolutions =
        API.resolve_refs(Enum.map(entries, & &1["ref"]),
          kind: :item,
          catalogue_uuid: catalogue.uuid
        )

      plan = Enum.zip(entries, resolutions) |> plan(catalogue) |> mark_sku_conflicts(catalogue)

      if ctx.dry_run?, do: preview(plan, catalogue), else: execute(plan, catalogue, ctx)
    end
  end

  # --- planning (reads only) ---------------------------------------------------------

  # A planned row is `{:update, ref, item, update}`, `{:rejected, ref, message, context}`,
  # `{:resolution_error, ref, reason}` or, after `mark_sku_conflicts/2`,
  # `{:sku_taken, ref, holder_uuid}`.
  defp plan(pairs, catalogue) do
    {planned, _state} =
      Enum.map_reduce(pairs, %{seen: MapSet.new(), categories: %{}, sets: %{}}, fn {entry,
                                                                                    {ref,
                                                                                     resolution}},
                                                                                   state ->
        plan_one(entry["changes"], ref, resolution, catalogue, state)
      end)

    planned
  end

  defp plan_one(_changes, ref, {:error, reason}, _catalogue, state),
    do: {{:resolution_error, ref, reason}, state}

  defp plan_one(changes, ref, {:ok, item}, catalogue, state) do
    cond do
      MapSet.member?(state.seen, item.uuid) ->
        {rejected(ref, "ref", "The same item appears twice in this request."), state}

      map_size(changes) == 0 ->
        {rejected(ref, "changes", "must name at least one field to change"), state}

      true ->
        case build(changes, catalogue, state) do
          {:ok, update, state} ->
            {{:update, ref, item, update}, %{state | seen: MapSet.put(state.seen, item.uuid)}}

          {:error, path, message, context} ->
            {rejected(ref, path, message, context), state}
        end
    end
  end

  # A sku is not unique in the database, so nothing else stops a change that gives an item the
  # sku another live item of the catalogue holds (a later lookup by that sku would then answer
  # `ambiguous_ref`). `create_products` refuses such a row; so does this. The rows are walked in
  # input order, like the write: a row that changes or clears a sku releases it for the rows after
  # it, and a row that sets one takes it. An item that keeps its own sku is no conflict.
  defp mark_sku_conflicts(plan, catalogue) do
    {marked, _holders} = Enum.map_reduce(plan, sku_holders(plan, catalogue), &claim_sku/2)
    marked
  end

  # `%{sku => [uuid]}` for the skus the plan wants to set.
  defp sku_holders(plan, catalogue) do
    refs =
      for {:update, _ref, item, %{attrs: %{sku: sku}}} <- plan,
          is_binary(sku),
          sku != item.sku,
          uniq: true,
          do: %{"sku" => sku}

    for {%{"sku" => sku}, resolution} <-
          API.resolve_refs(refs, kind: :item, catalogue_uuid: catalogue.uuid),
        into: %{},
        do: {sku, holder_uuids(resolution)}
  end

  defp holder_uuids({:ok, item}), do: [item.uuid]
  defp holder_uuids({:error, {:ambiguous_ref, uuids}}), do: uuids
  defp holder_uuids({:error, _reason}), do: []

  defp claim_sku({:update, ref, item, %{attrs: %{sku: wanted}}} = row, holders) do
    if wanted == item.sku do
      {row, holders}
    else
      case holders |> Map.get(wanted, []) |> List.delete(item.uuid) do
        [holder | _others] when is_binary(wanted) ->
          {{:sku_taken, ref, holder}, holders}

        _free ->
          {row, holders |> release_sku(item) |> hold_sku(wanted, item.uuid)}
      end
    end
  end

  defp claim_sku(row, holders), do: {row, holders}

  defp release_sku(holders, %{sku: sku, uuid: uuid}) when is_binary(sku),
    do: Map.update(holders, sku, [], &List.delete(&1, uuid))

  defp release_sku(holders, _item), do: holders

  defp hold_sku(holders, sku, uuid) when is_binary(sku),
    do: Map.update(holders, sku, [uuid], &Enum.sort([uuid | &1]))

  defp hold_sku(holders, _sku, _uuid), do: holders

  defp rejected(ref, path, message, context \\ %{}) do
    {:rejected, ref, message,
     Map.merge(%{"errors" => [%{"path" => path, "message" => message}]}, context)}
  end

  defp build(changes, catalogue, state) do
    with :ok <- check_name(changes),
         :ok <- check_clearable_text(changes, "sku"),
         :ok <- check_clearable_text(changes, "external_id"),
         {:ok, category, state} <- check_category(changes, catalogue, state),
         {:ok, state} <- check_attributes(changes, state) do
      {attrs, row_opts} = column_attrs(changes)

      update = %{
        attrs: attrs,
        # Defensive: the attrs never carry a category (it is moved separately, so
        # that the context logs its own readable `item.moved` entry), so there is
        # nothing for the update to derive a catalogue from.
        row_opts: [skip_derive: true] ++ row_opts,
        category: category,
        attributes: changes["attributes"] || [],
        external_id: changes["external_id"]
      }

      {:ok, update, state}
    end
  end

  defp check_name(%{"name" => name}) do
    if Common.blank?(name),
      do: {:error, "changes.name", "must not be blank", %{}},
      else: :ok
  end

  defp check_name(_changes), do: :ok

  # A blank text would store an empty value that nothing can look up again:
  # clearing is `null`.
  defp check_clearable_text(changes, key) do
    case changes do
      %{^key => text} when is_binary(text) ->
        if Common.blank?(text),
          do: {:error, "changes." <> key, "must not be blank; send null to clear it", %{}},
          else: :ok

      _other ->
        :ok
    end
  end

  # `:keep` = not mentioned, `nil` = uncategorize, a uuid = move there.
  defp check_category(changes, catalogue, state) do
    case Map.fetch(changes, "category_id") do
      :error ->
        {:ok, :keep, state}

      {:ok, nil} ->
        {:ok, nil, state}

      {:ok, id} ->
        {verdict, cache} = Common.category_verdict(id, catalogue, state.categories)
        state = %{state | categories: cache}

        case verdict do
          {:ok, uuid} -> {:ok, uuid, state}
          {:error, message} -> {:error, "changes.category_id", message, %{}}
        end
    end
  end

  defp check_attributes(changes, state) do
    case Attributes.validate(changes["attributes"] || [], state.sets) do
      {:ok, sets} -> {:ok, %{state | sets: sets}}
      {{:error, message, context}, _sets} -> {:error, "changes.attributes", message, context}
    end
  end

  defp column_attrs(changes) do
    attrs =
      for {key, field} <- @columns,
          Map.has_key?(changes, key),
          into: %{},
          do: {field, column_value(field, changes[key])}

    if Map.has_key?(changes, "external_id") do
      attrs = Map.put(attrs, :data, %{"api" => %{"external_id" => changes["external_id"]}})
      {attrs, [data_owned_paths: [@external_id_path], logged_data_paths: [@external_id_path]]}
    else
      {attrs, []}
    end
  end

  # A blank name is refused at plan time, so the trim never empties it.
  defp column_value(:name, name), do: String.trim(name)
  defp column_value(_field, value), do: value

  # --- dry run -------------------------------------------------------------------------

  defp preview(plan, catalogue) do
    plan
    |> mark_external_id_conflicts(catalogue)
    |> Enum.map(fn
      {:update, ref, item, update} ->
        preview_row(ref, item, update)

      {:rejected, ref, message, context} ->
        Common.row_error(ref, :validation_failed, message, context)

      {:resolution_error, ref, reason} ->
        Common.resolution_error(ref, reason)

      {:external_id_taken, ref, holder_uuid} ->
        external_id_taken(ref, holder_uuid)

      {:sku_taken, ref, holder_uuid} ->
        sku_taken(ref, holder_uuid)
    end)
    |> Common.preview()
  end

  # The unique index on `external_id` decides at write time; the preview models it
  # so that it does not promise a row that will fail. The rows are walked in input
  # order, like the write: a row that changes or clears an external id releases it
  # for the rows after it, and a row that sets one takes it.
  defp mark_external_id_conflicts(plan, catalogue) do
    {marked, _owners} = Enum.map_reduce(plan, external_id_holders(plan, catalogue), &claim/2)
    marked
  end

  defp external_id_holders(plan, catalogue) do
    refs =
      for {:update, _ref, _item, %{external_id: eid}} <- plan,
          is_binary(eid),
          uniq: true,
          do: %{"external_id" => eid}

    for {%{"external_id" => eid}, {:ok, holder}} <-
          API.resolve_refs(refs, kind: :item, catalogue_uuid: catalogue.uuid),
        into: %{},
        do: {eid, holder.uuid}
  end

  defp claim({:update, ref, item, %{attrs: %{data: _}} = update} = row, owners) do
    wanted = update.external_id

    case Map.get(owners, wanted) do
      holder when is_binary(wanted) and is_binary(holder) and holder != item.uuid ->
        {{:external_id_taken, ref, holder}, owners}

      _free ->
        owners = release(owners, item)
        {row, if(is_binary(wanted), do: Map.put(owners, wanted, item.uuid), else: owners)}
    end
  end

  defp claim(row, owners), do: {row, owners}

  defp release(owners, %{data: %{"api" => %{"external_id" => eid}}, uuid: uuid})
       when is_binary(eid) do
    case owners do
      %{^eid => ^uuid} -> Map.delete(owners, eid)
      _other -> owners
    end
  end

  defp release(owners, _item), do: owners

  defp preview_row(ref, item, update) do
    case Catalogue.preview_item_update(item, update.attrs, update.row_opts) do
      {:ok, changes} ->
        changes =
          changes
          |> with_category_change(item, update.category)
          |> with_attribute_changes(item, update.attributes)

        action = if changes == %{}, do: "unchanged", else: "updated"
        Common.row_ok(ref, action, item.uuid, %{"changes" => changes})

      {:error, changeset} ->
        Common.row_error(ref, :validation_failed, "The change is not valid.", %{
          "errors" => Common.changeset_errors(changeset)
        })
    end
  end

  defp with_category_change(changes, _item, :keep), do: changes
  defp with_category_change(changes, %{category_uuid: same}, same), do: changes

  defp with_category_change(changes, item, category) do
    Map.put(changes, "category_id", %{"from" => item.category_uuid || "", "to" => category || ""})
  end

  defp with_attribute_changes(changes, _item, []), do: changes

  defp with_attribute_changes(changes, item, entries) do
    # one read of the item's attachments for all its entries
    selections = Attributes.selections(item.uuid)

    Enum.reduce(entries, changes, fn %{"set_id" => set_id, "values" => values}, acc ->
      set_uuid = canonical_id(set_id)
      current = Map.get(selections, set_uuid, [])

      if Enum.sort(current) == Enum.sort(values),
        do: acc,
        else:
          Map.put(acc, "attributes." <> set_uuid, %{
            "from" => Enum.join(current, ","),
            "to" => Enum.join(values, ",")
          })
    end)
  end

  defp canonical_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> id
    end
  end

  # --- execution -------------------------------------------------------------------------

  defp execute(plan, catalogue, ctx) do
    opts = Common.write_opts(ctx, @tool)

    rows =
      for {:update, _ref, item, update} <- plan, do: {item.uuid, update.attrs, update.row_opts}

    # The column write, the category moves and the attribute writes all run with
    # `broadcast: false`; the handler announces ONCE, below, every item that was
    # written to in any way.
    case write_columns(rows, opts) do
      {:ok, outcomes} ->
        by_uuid = Map.new(outcomes)
        discard_moves()

        # The moves' media folders follow their items in one pass, now that every
        # row has been written. The `after` runs the pass for the moves that were
        # committed even when a row raises: the exception goes on, and the folders
        # of the moves already made are not left behind.
        try do
          finished = Enum.map(plan, &finish(&1, by_uuid, opts, catalogue))
          follow_moves(opts[:actor_uuid])

          saved = for {%{"id" => id}, true} <- finished, do: id
          Catalogue.broadcast_item_batch_change(catalogue.uuid, :updated, saved)
          finished |> Enum.map(&elem(&1, 0)) |> Common.batch_result()
        after
          follow_moves(opts[:actor_uuid])
        end

      {:error, reason} ->
        Logger.warning("#{@tool} batch could not be written: #{Common.reason_code(reason)}")
        {:error, :internal_error, "The batch could not be written.", %{}}
    end
  end

  defp collect_move(pair), do: Process.put(@moves_key, [pair | Process.get(@moves_key, [])])
  defp discard_moves, do: Process.delete(@moves_key)

  # Follows the collected moves once and forgets them, so that a second call finds
  # nothing. It never raises: in the `after` of an exception it must not replace it.
  defp follow_moves(actor_uuid) do
    case Process.delete(@moves_key) do
      nil -> :ok
      moves -> moves |> Enum.reverse() |> Catalogue.follow_moved_items(actor_uuid)
    end
  rescue
    exception -> log_follow_failure(ResourceFolders.describe_failure(exception))
  catch
    kind, reason -> log_follow_failure(ResourceFolders.describe_failure({kind, reason}))
  end

  defp log_follow_failure(reason),
    do: Logger.warning("[Catalogue] media folders did not follow the moved items: " <> reason)

  defp write_columns([], _opts), do: {:ok, []}

  defp write_columns(rows, opts),
    do: Catalogue.update_items(rows, Keyword.put(opts, :broadcast, false))

  # `{row, saved?}`: `saved?` tells whether the item was written to, so that it is
  # announced even when a later step of its row failed.
  defp finish({:rejected, ref, message, context}, _outcomes, _opts, _catalogue),
    do: {Common.row_error(ref, :validation_failed, message, context), false}

  defp finish({:resolution_error, ref, reason}, _outcomes, _opts, _catalogue),
    do: {Common.resolution_error(ref, reason), false}

  defp finish({:sku_taken, ref, holder_uuid}, _outcomes, _opts, _catalogue),
    do: {sku_taken(ref, holder_uuid), false}

  defp finish({:update, ref, item, update}, outcomes, opts, catalogue) do
    case Map.get(outcomes, item.uuid) do
      {kind, %{status: "deleted"} = trashed} ->
        {trashed_row(ref, trashed, kind == :updated), kind == :updated}

      {kind, updated} when kind in [:updated, :unchanged] ->
        follow_up(ref, kind, updated, update, opts, catalogue)

      {:error, reason} ->
        {failure(ref, reason, update, catalogue), false}

      nil ->
        {Common.row_error(ref, :internal_error, "The item was not part of the write."), false}
    end
  end

  # The item was trashed between planning and writing. The column write is the
  # same one `Catalogue.update_item/3` makes on a trashed row (its status stays
  # `deleted`), so it may have been stored; nothing else is done to a trashed item.
  defp trashed_row(ref, item, saved?) do
    ref
    |> Common.row_error(:not_found, "The item was trashed before the change was applied.", %{
      "saved" => saved?
    })
    |> Map.put("id", item.uuid)
  end

  # After the columns: the category move, then the attribute selections.
  defp follow_up(ref, kind, updated, update, opts, catalogue) do
    # Asked BEFORE the write: afterwards the selection always equals the request.
    attributes_changed? = Attributes.changed?(updated.uuid, update.attributes)

    case move_category(updated, update.category, opts, catalogue) do
      {:ok, moved?} ->
        saved? = kind == :updated or moved?
        apply_attributes_step(ref, updated, update, opts, saved?, attributes_changed?)

      {:error, reason, moved?} ->
        saved? = kind == :updated or moved?

        {step_failure(
           ref,
           updated,
           "The category was not changed",
           move_sentence(reason),
           reason,
           saved?
         ), saved?}
    end
  end

  defp apply_attributes_step(ref, updated, update, opts, saved?, attributes_changed?) do
    case apply_attributes(updated, update.attributes, opts) do
      :ok ->
        changed? = saved? or attributes_changed?

        {Common.row_ok(ref, if(changed?, do: "updated", else: "unchanged"), updated.uuid),
         changed?}

      {:error, reason} ->
        # Attribute sets are written one by one, so some may be stored: announce the item.
        {step_failure(
           ref,
           updated,
           "The attributes were not saved",
           Common.attribute_sentence(reason),
           reason,
           saved?
         ), true}
    end
  end

  defp step_failure(ref, updated, lead, sentence, reason, saved?) do
    ref
    |> Common.row_error(:validation_failed, "#{lead}: #{sentence}.", %{
      "saved" => saved?,
      "reason" => Common.reason_code(reason)
    })
    |> Map.put("id", updated.uuid)
  end

  defp move_sentence(:category_not_found), do: "the category no longer exists or is in the trash"
  defp move_sentence(:not_found), do: "the item no longer exists or is in the trash"
  defp move_sentence(:kind_mismatch), do: "the category belongs to a catalogue of another kind"

  defp move_sentence(:catalogue_changed),
    do: "the category was moved to another catalogue meanwhile and the item went with it"

  defp move_sentence(_other), do: "the move was refused"

  # `{:ok, moved?}` or `{:error, reason, moved?}`; `moved?` is true when the item did
  # change category although the row failed (the category was re-homed meanwhile).
  # A move that went through is collected for the media folders to follow.
  defp move_category(_item, :keep, _opts, _catalogue), do: {:ok, false}
  defp move_category(%{category_uuid: same}, same, _opts, _catalogue), do: {:ok, false}

  defp move_category(item, category, opts, catalogue) do
    # A move logs one `item.moved` entry per item, the context's own action with
    # readable from/to references, so N moves are N log inserts; the batch is
    # announced once by `execute/3` (`broadcast: false`), and the folders follow
    # the moved items once there too (the deferred move).
    move_opts = Keyword.take(opts, [:actor_uuid, :mode, :log_metadata]) ++ [broadcast: false]

    case Catalogue.move_item_to_category_deferred(item, category, move_opts) do
      {:ok, {_locked_before, %{catalogue_uuid: catalogue_uuid}} = pair}
      when catalogue_uuid == catalogue.uuid ->
        collect_move(pair)
        {:ok, true}

      {:ok, {_locked_before, moved} = pair} ->
        # The category was re-homed after planning; the move follows the category.
        collect_move(pair)
        Catalogue.broadcast_item_batch_change(moved.catalogue_uuid, :updated, [moved.uuid])
        {:error, :catalogue_changed, true}

      {:error, reason} ->
        {:error, reason, false}
    end
  end

  defp apply_attributes(_item, [], _opts), do: :ok

  defp apply_attributes(item, entries, opts) do
    attribute_opts = Keyword.take(opts, [:actor_uuid, :mode, :log_metadata]) ++ [broadcast: false]
    Attributes.apply_to_item(item.uuid, entries, attribute_opts)
  end

  defp failure(ref, %Ecto.Changeset{} = changeset, update, catalogue) do
    if Common.external_id_conflict?(changeset) do
      external_id_taken(ref, holder_of(update.external_id, catalogue))
    else
      Common.row_error(ref, :validation_failed, "The change is not valid.", %{
        "errors" => Common.changeset_errors(changeset)
      })
    end
  end

  defp failure(ref, :not_found, _update, _catalogue),
    do: Common.row_error(ref, :not_found, "The item no longer exists.")

  defp failure(ref, _reason, _update, _catalogue),
    do: Common.row_error(ref, :internal_error, "The item could not be written.")

  defp external_id_taken(ref, existing_id) do
    Common.row_error(
      ref,
      :already_exists,
      "Another item of the catalogue already has this external_id.",
      %{"existing_id" => existing_id}
    )
  end

  defp sku_taken(ref, existing_id) do
    Common.row_error(
      ref,
      :sku_taken,
      "Another live item of the catalogue already has this sku.",
      %{"existing_id" => existing_id}
    )
  end

  defp holder_of(nil, _catalogue), do: nil

  defp holder_of(external_id, catalogue) do
    case API.resolve_refs([%{"external_id" => external_id}],
           kind: :item,
           catalogue_uuid: catalogue.uuid
         ) do
      [{_ref, {:ok, item}}] -> item.uuid
      _other -> nil
    end
  end
end
