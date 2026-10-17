defmodule PhoenixKitCatalogue.API.UpsertCategories do
  @moduledoc false
  # Tool `catalogue.upsert_categories`. Rows are processed in
  # order, in both modes: what an earlier row did is visible to the later ones
  # (in the database when executing; when previewing, in the walk state:
  # `sim` holds the values the earlier rows would have written, keyed by the
  # category's uuid or `{:planned, external_id}` for one the request would
  # create, and `eids` says who would hold each external_id they touched).
  # A preview also models the two ways an update fails at write time (an
  # external_id another category holds, a parent that would make a cycle) so
  # that it does not promise a row that will fail.

  alias PhoenixKitCatalogue.API
  alias PhoenixKitCatalogue.API.{Common, Refs}
  alias PhoenixKitCatalogue.Catalogue

  @tool "catalogue.upsert_categories"
  @external_id_path ["api", "external_id"]
  @planned_text "(a category created earlier in this request)"

  @spec call(map(), map()) ::
          {:ok, map()} | {:preview, map(), String.t()} | {:error, atom(), String.t(), map()}
  def call(input, ctx) do
    with :ok <- Common.ensure_schema(),
         {:ok, catalogue} <- API.resolve_catalogue(input["catalogue_id"], writable: true) do
      mode = if ctx.dry_run?, do: :preview, else: :execute
      opts = Common.write_opts(ctx, @tool)

      {rows, _state} =
        Enum.map_reduce(input["items"], %{sim: %{}, eids: %{}, parents: nil}, fn row, state ->
          process(row, state, catalogue, mode, opts)
        end)

      if mode == :preview, do: Common.preview(rows), else: Common.batch_result(rows)
    end
  end

  defp process(row, state, catalogue, mode, opts) do
    ref = Map.take(row, ["id", "external_id"])

    with :ok <- check_reference(row),
         :ok <- check_name(row),
         :ok <- check_position(row),
         {:ok, existing} <- find_existing(row, catalogue, state),
         {:ok, parent} <- find_parent(row, catalogue, state) do
      case existing do
        {:category, category} -> update(ref, row, category, parent, catalogue, state, mode, opts)
        :none -> create(ref, row, parent, catalogue, state, mode, opts)
      end
    else
      {:error, code, message, context} -> {Common.row_error(ref, code, message, context), state}
    end
  end

  # Row-level strings have no length floor in the schema (see `Schemas`): a
  # blank external_id is this row's error. A malformed `id` falls through to
  # `find_existing/3`, where `Refs` answers `not_found`. `external_id: null`
  # next to an `id` clears the link; alone it names no category.
  defp check_reference(%{"id" => _, "external_id" => nil}), do: :ok

  defp check_reference(%{"id" => _, "external_id" => eid}) do
    if Common.blank?(eid), do: invalid("external_id", "must not be blank"), else: :ok
  end

  defp check_reference(%{"id" => _}), do: :ok

  defp check_reference(%{"external_id" => nil}),
    do: invalid("id", "give the id of the category whose external_id to clear")

  defp check_reference(%{"external_id" => eid}) do
    if Common.blank?(eid), do: invalid("external_id", "must not be blank"), else: :ok
  end

  defp check_reference(_row),
    do: invalid("id", "give the category's id or its external_id")

  defp check_name(%{"name" => name}) do
    if Common.blank?(name), do: invalid("name", "must not be blank"), else: :ok
  end

  defp check_name(_row), do: :ok

  # A position far below the 32-bit column limit: a value at the limit would make
  # the next automatic position overflow the column. Too large is this row's
  # error, not a crash that would leave the rest of the batch unprocessed.
  defp check_position(%{"position" => position}) when is_integer(position) do
    max = Catalogue.max_category_position()
    if position > max, do: invalid("position", "must be at most #{max}"), else: :ok
  end

  defp check_position(_row), do: :ok

  defp invalid(path, message),
    do:
      {:error, :validation_failed, message,
       %{"errors" => [%{"path" => path, "message" => message}]}}

  # --- finding things -------------------------------------------------------------------

  defp find_existing(%{"id" => id}, catalogue, state) do
    case lookup(%{"id" => id}, catalogue) do
      {:ok, category} ->
        {:ok, {:category, overlay(category, state)}}

      {:error, :not_found} ->
        {:error, :not_found,
         "No category has this id; to create one, give an external_id and no id.", %{}}

      {:error, other} ->
        lookup_error(other, "id")
    end
  end

  defp find_existing(%{"external_id" => eid}, catalogue, state) do
    case find_by_external_id(eid, catalogue, state) do
      {:ok, category} -> {:ok, {:category, category}}
      {:error, :not_found} -> {:ok, :none}
      {:error, other} -> lookup_error(other, "external_id")
    end
  end

  # An external_id as the rows before this one leave it: freed, held by a
  # category the request would create, held by one it re-pointed, or (when
  # no earlier row touched it) as the database has it. When executing,
  # `eids` is always empty and this is the database lookup.
  defp find_by_external_id(eid, catalogue, state) do
    case Map.fetch(state.eids, eid) do
      {:ok, nil} ->
        {:error, :not_found}

      {:ok, {:planned, _eid} = key} ->
        {:ok, planned_category(key, Map.fetch!(state.sim, key))}

      {:ok, uuid} ->
        with {:ok, category} <- lookup(%{"id" => uuid}, catalogue),
             do: {:ok, overlay(category, state)}

      :error ->
        with {:ok, category} <- lookup(%{"external_id" => eid}, catalogue),
             do: {:ok, overlay(category, state)}
    end
  end

  # The category as the earlier rows of a preview would have left it.
  defp overlay(category, state) do
    case Map.fetch(state.sim, category.uuid) do
      {:ok, sim} ->
        %{
          category
          | name: sim.name,
            position: sim.position,
            parent_uuid: sim.parent,
            data: put_external_id(category.data, sim.eid)
        }

      :error ->
        category
    end
  end

  defp planned_category(key, sim) do
    %{
      uuid: key,
      name: sim.name,
      position: sim.position,
      parent_uuid: sim.parent,
      data: put_external_id(%{}, sim.eid)
    }
  end

  defp put_external_id(data, eid) do
    data = data || %{}
    Map.put(data, "api", Map.put(Map.get(data, "api") || %{}, "external_id", eid))
  end

  # `parent`: absent keeps it (`:keep`), `nil` is the top level, a reference is
  # resolved among this catalogue's categories (or the request's own, in a preview).
  defp find_parent(row, catalogue, state) do
    case Map.fetch(row, "parent") do
      :error -> {:ok, :keep}
      {:ok, nil} -> {:ok, nil}
      {:ok, ref} -> resolve_parent(ref, catalogue, state)
    end
  end

  defp resolve_parent(ref, catalogue, state) do
    result =
      case ref do
        %{"external_id" => eid} when map_size(ref) == 1 ->
          find_by_external_id(eid, catalogue, state)

        _other ->
          lookup(ref, catalogue)
      end

    case result do
      {:ok, parent} ->
        {:ok, parent.uuid}

      {:error, :not_found} ->
        {:error, :not_found, "The parent category was not found in this catalogue.",
         %{"errors" => [%{"path" => "parent", "message" => "not found"}]}}

      {:error, other} ->
        lookup_error(other, "parent")
    end
  end

  defp lookup(ref, catalogue) do
    case API.resolve_refs([ref], kind: :category, catalogue_uuid: catalogue.uuid) do
      [{_ref, {:ok, category}}] -> {:ok, category}
      [{_ref, {:error, reason}}] -> {:error, reason}
    end
  end

  defp lookup_error(:invalid_ref, "parent"),
    do: invalid("parent", "give exactly one of id or external_id")

  defp lookup_error(:invalid_ref, path), do: invalid(path, "must not be blank")

  defp lookup_error({:ambiguous_ref, ids}, _path),
    do:
      {:error, :ambiguous_ref, "The reference matches several categories.",
       %{"candidates" => ids}}

  # --- update -----------------------------------------------------------------------------

  defp update(ref, row, category, parent, catalogue, state, mode, opts) do
    {attrs, changes} = diff(row, category, parent)
    {attrs, changes, eid_change?} = with_external_id(attrs, changes, row, category)

    cond do
      changes == %{} ->
        {Common.row_ok(ref, "unchanged", row_id(category)), state}

      mode == :preview ->
        preview_update(ref, row, category, attrs, changes, eid_change?, catalogue, state)

      true ->
        write_opts =
          if eid_change?,
            do:
              opts ++
                [data_owned_paths: [@external_id_path], logged_data_paths: [@external_id_path]],
            else: opts

        case Catalogue.update_category(category, attrs, write_opts) do
          {:ok, _updated} ->
            {Common.row_ok(ref, "updated", category.uuid), state}

          {:error, %Ecto.Changeset{} = changeset} ->
            {failure(ref, changeset, row, catalogue, state), state}

          {:error, :not_found} ->
            {Common.row_error(ref, :not_found, "The category no longer exists."), state}

          {:error, _reason} ->
            {Common.row_error(ref, :internal_error, "The category could not be written."), state}
        end
    end
  end

  defp preview_update(ref, row, category, attrs, changes, eid_change?, catalogue, state) do
    state = load_parents(state, catalogue)

    case preview_problem(row, category, attrs, eid_change?, catalogue, state) do
      {:external_id_taken, holder} ->
        {external_id_taken(ref, holder_id(holder)), state}

      {:parent, message} ->
        {Common.row_error(ref, :validation_failed, "The category is not valid.", %{
           "errors" => [%{"path" => "parent_uuid", "message" => message}]
         }), state}

      nil ->
        {Common.row_ok(ref, "updated", row_id(category), %{"changes" => changes}),
         simulate(state, category, attrs, row, eid_change?)}
    end
  end

  defp preview_problem(row, category, attrs, eid_change?, catalogue, state) do
    holder = if eid_change?, do: holder_key(row["external_id"], catalogue, state)

    cond do
      holder not in [nil, category.uuid] ->
        {:external_id_taken, holder}

      message = parent_problem(state, category.uuid, Map.get(attrs, :parent_uuid, :keep)) ->
        {:parent, message}

      true ->
        nil
    end
  end

  # What the update row leaves behind for the rows after it.
  defp simulate(state, category, attrs, row, eid_change?) do
    sim = %{
      name: Map.get(attrs, :name, category.name),
      position: Map.get(attrs, :position, category.position),
      parent: Map.get(attrs, :parent_uuid, category.parent_uuid),
      eid: if(eid_change?, do: row["external_id"], else: Refs.external_id(category))
    }

    eids =
      if eid_change? do
        state.eids
        |> release_external_id(Refs.external_id(category))
        |> claim_external_id(row["external_id"], category.uuid)
      else
        state.eids
      end

    %{state | sim: Map.put(state.sim, category.uuid, sim), eids: eids}
  end

  defp release_external_id(eids, nil), do: eids
  defp release_external_id(eids, eid), do: Map.put(eids, eid, nil)

  defp claim_external_id(eids, nil, _uuid), do: eids
  defp claim_external_id(eids, eid, uuid), do: Map.put(eids, eid, uuid)

  # The parent of every live category, read once per preview. Parents the
  # earlier rows of the request would change are in `state.sim`, which
  # `parent_of/2` consults first, so that a cycle made by two rows of the same
  # request is seen like the sequential writes would see it.
  defp load_parents(%{parents: nil} = state, catalogue) do
    parents =
      catalogue.uuid
      |> Catalogue.list_categories_metadata_for_catalogue()
      |> Map.new(&{&1.uuid, &1.parent_uuid})

    %{state | parents: parents}
  end

  defp load_parents(state, _catalogue), do: state

  defp parent_of(state, key) do
    case Map.fetch(state.sim, key) do
      {:ok, %{parent: parent}} -> parent
      :error -> Map.get(state.parents, key)
    end
  end

  defp parent_problem(_state, _own, :keep), do: nil
  defp parent_problem(_state, _own, nil), do: nil
  defp parent_problem(_state, own, own), do: "category cannot be its own parent"

  defp parent_problem(state, own, candidate) do
    if descends_from?(state, candidate, own, %{}), do: "would create a cycle"
  end

  # Whether walking up from `current` reaches `own`.
  defp descends_from?(_state, nil, _own, _seen), do: false
  defp descends_from?(_state, own, own, _seen), do: true

  defp descends_from?(state, current, own, seen) do
    if Map.has_key?(seen, current),
      do: false,
      else: descends_from?(state, parent_of(state, current), own, Map.put(seen, current, true))
  end

  # The fields that differ, as column attrs and as a from/to map for the log and the preview.
  # A name is stored trimmed (as `create` stores it), so a retry compares equal.
  defp diff(row, category, parent) do
    [
      {"name", :name, category.name, trimmed(row["name"]), Map.has_key?(row, "name")},
      {"position", :position, category.position, row["position"], Map.has_key?(row, "position")},
      {"parent_id", :parent_uuid, category.parent_uuid, parent, parent != :keep}
    ]
    |> Enum.reduce({%{}, %{}}, fn {key, field, old, new, given?}, {attrs, changes} ->
      if not given? or new == old do
        {attrs, changes}
      else
        {Map.put(attrs, field, new),
         Map.put(changes, key, %{"from" => show(old), "to" => show(new)})}
      end
    end)
  end

  defp trimmed(name) when is_binary(name), do: String.trim(name)
  defp trimmed(other), do: other

  defp show(nil), do: ""
  defp show({:planned, _eid}), do: @planned_text
  defp show(value) when is_binary(value), do: value
  defp show(value), do: to_string(value)

  # id AND external_id given, and the stored external id differs: set it, or
  # clear it when the given one is null (a nil in `data_owned_paths` deletes the key).
  defp with_external_id(attrs, changes, %{"id" => _, "external_id" => eid}, category) do
    if Refs.external_id(category) == eid do
      {attrs, changes, false}
    else
      {Map.put(attrs, :data, %{"api" => %{"external_id" => eid}}),
       Map.put(changes, "data.api.external_id", %{
         "from" => show(Refs.external_id(category)),
         "to" => show(eid)
       }), true}
    end
  end

  defp with_external_id(attrs, changes, _row, _category), do: {attrs, changes, false}

  # A category the request would create has no id yet.
  defp row_id(%{uuid: uuid}) when is_binary(uuid), do: uuid
  defp row_id(_category), do: nil

  # --- create -----------------------------------------------------------------------------

  defp create(ref, row, parent, catalogue, state, mode, opts) do
    cond do
      Common.blank?(row["name"]) ->
        {Common.row_error(ref, :validation_failed, "A name is required to create a category.", %{
           "errors" => [%{"path" => "name", "message" => "is required to create a category"}]
         }), state}

      mode == :preview ->
        preview_create(ref, row, parent, state)

      true ->
        case Catalogue.create_category(create_attrs(row, parent, catalogue), opts) do
          {:ok, category} ->
            {Common.row_ok(ref, "created", category.uuid), state}

          {:error, %Ecto.Changeset{} = changeset} ->
            {failure(ref, changeset, row, catalogue, state), state}
        end
    end
  end

  defp preview_create(ref, row, parent, state) do
    eid = row["external_id"]
    name = String.trim(row["name"])
    fields = %{"name" => name, "external_id" => eid}

    fields =
      if parent in [:keep, nil], do: fields, else: Map.put(fields, "parent", show(parent))

    fields = if row["position"], do: Map.put(fields, "position", row["position"]), else: fields

    key = {:planned, eid}

    sim = %{
      name: name,
      position: row["position"] || 0,
      parent: if(parent == :keep, do: nil, else: parent),
      eid: eid
    }

    {Common.row_ok(ref, "created", nil, %{"fields" => fields}),
     %{state | sim: Map.put(state.sim, key, sim), eids: Map.put(state.eids, eid, key)}}
  end

  defp create_attrs(row, parent, catalogue) do
    %{
      name: String.trim(row["name"]),
      catalogue_uuid: catalogue.uuid,
      data: %{"api" => %{"external_id" => row["external_id"]}}
    }
    |> then(&if(is_binary(parent), do: Map.put(&1, :parent_uuid, parent), else: &1))
    |> then(&if(row["position"], do: Map.put(&1, :position, row["position"]), else: &1))
  end

  # --- failures -----------------------------------------------------------------------------

  defp failure(ref, changeset, row, catalogue, state) do
    if Common.external_id_conflict?(changeset) do
      external_id_taken(ref, holder_id(holder_key(row["external_id"], catalogue, state)))
    else
      Common.row_error(ref, :validation_failed, "The category is not valid.", %{
        "errors" => Common.changeset_errors(changeset)
      })
    end
  end

  defp external_id_taken(ref, holder_uuid) do
    Common.row_error(
      ref,
      :already_exists,
      "Another category of the catalogue already has this external_id.",
      %{
        "existing_id" => holder_uuid
      }
    )
  end

  # Who holds the external_id: a category uuid, `{:planned, eid}` for one the
  # request would create, or nil.
  defp holder_key(nil, _catalogue, _state), do: nil

  defp holder_key(eid, catalogue, state) do
    case find_by_external_id(eid, catalogue, state) do
      {:ok, category} -> category.uuid
      {:error, _reason} -> nil
    end
  end

  defp holder_id(key) when is_binary(key), do: key
  defp holder_id(_key), do: nil
end
