defmodule PhoenixKitCatalogue.API.CreateProducts do
  @moduledoc false
  # Tool `catalogue.create_products`.

  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKitCatalogue.API
  alias PhoenixKitCatalogue.API.{Attributes, Common}
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.Slugs
  alias PhoenixKitCatalogue.Schemas.Item

  @tool "catalogue.create_products"
  @identifier_hint "give sku, external_id or both, so that a retry cannot create the item twice"

  @spec call(map(), map()) ::
          {:ok, map()} | {:preview, map(), String.t()} | {:error, atom(), String.t(), map()}
  def call(input, ctx) do
    with :ok <- Common.ensure_schema(),
         {:ok, catalogue} <- API.resolve_catalogue(input["catalogue_id"], writable: true) do
      plan = plan(input["items"], catalogue)

      if ctx.dry_run?, do: preview(plan), else: execute(plan, catalogue, ctx)
    end
  end

  # --- planning (reads only) ---------------------------------------------------------

  @doc false
  # One planned row is `{:create, ref, attrs, attributes}`, `{:skip, ref, existing_id, why}`
  # or `{:error, ref, message, context}`. Public only so a test can plan, let a
  # rival write the same id, and execute: the race the unique index closes.
  def plan(rows, catalogue) do
    existing = existing_index(rows, catalogue)

    {planned, _state} =
      Enum.map_reduce(rows, %{seen: MapSet.new(), categories: %{}}, fn row, state ->
        plan_row(row, catalogue, existing, state)
      end)

    planned
  end

  defp ref_of(row), do: Map.take(row, ["external_id", "sku"])

  # Live items of the catalogue that already carry one of the request's ids.
  defp existing_index(rows, catalogue) do
    opts = [kind: :item, catalogue_uuid: catalogue.uuid]

    by_eid =
      rows
      |> values("external_id")
      |> Enum.map(&%{"external_id" => &1})
      |> API.resolve_refs(opts)
      |> Enum.flat_map(fn
        {%{"external_id" => eid}, {:ok, item}} -> [{eid, item.uuid}]
        _other -> []
      end)
      |> Map.new()

    by_sku =
      rows
      |> values("sku")
      |> Enum.map(&%{"sku" => &1})
      |> API.resolve_refs(opts)
      |> Enum.flat_map(fn
        {%{"sku" => sku}, {:ok, item}} -> [{sku, item.uuid}]
        {%{"sku" => sku}, {:error, {:ambiguous_ref, [first | _]}}} -> [{sku, first}]
        _other -> []
      end)
      |> Map.new()

    %{eid: by_eid, sku: by_sku}
  end

  defp values(rows, key), do: rows |> Enum.map(& &1[key]) |> Enum.reject(&is_nil/1) |> Enum.uniq()

  defp plan_row(row, catalogue, existing, state) do
    ref = ref_of(row)
    eid = row["external_id"]
    sku = row["sku"]

    cond do
      problem = row_problem(row, eid, sku) ->
        {path, message} = problem
        {error(ref, path, message), state}

      found_id = existing_id(existing, eid, sku) ->
        {{:skip, ref, found_id, :exists}, state}

      duplicate_in_request?(state.seen, eid, sku) ->
        {{:skip, ref, nil, :duplicate_in_request}, state}

      true ->
        with {:ok, category_uuid, state} <- check_category(row["category_id"], catalogue, state),
             :ok <- check_attributes(row["attributes"] || []) do
          attrs = build_attrs(row, catalogue, category_uuid)
          state = %{state | seen: remember(state.seen, eid, sku)}
          {{:create, ref, attrs, row["attributes"] || []}, state}
        else
          {:error, path, message, context} -> {error(ref, path, message, context), state}
        end
    end
  end

  # The schema has no length floor on row text (see `Schemas`), so a blank
  # name or identifier is this row's error, never a whole-request 422.
  defp row_problem(row, eid, sku) do
    cond do
      Common.blank?(row["name"]) -> {"name", "must not be blank"}
      blank_given?(row, "sku") -> {"sku", "must not be blank"}
      blank_given?(row, "external_id") -> {"external_id", "must not be blank"}
      is_nil(eid) and is_nil(sku) -> {"sku", @identifier_hint}
      true -> nil
    end
  end

  defp blank_given?(row, key), do: Map.has_key?(row, key) and Common.blank?(row[key])

  defp existing_id(existing, eid, sku) do
    (eid && existing.eid[eid]) || (sku && existing.sku[sku]) || nil
  end

  defp duplicate_in_request?(seen, eid, sku),
    do: (eid != nil and {:eid, eid} in seen) or (sku != nil and {:sku, sku} in seen)

  defp remember(seen, eid, sku) do
    seen
    |> then(&if(eid, do: MapSet.put(&1, {:eid, eid}), else: &1))
    |> then(&if(sku, do: MapSet.put(&1, {:sku, sku}), else: &1))
  end

  defp error(ref, path, message, context \\ %{}),
    do:
      {:error, ref, message,
       Map.merge(%{"errors" => [%{"path" => path, "message" => message}]}, context)}

  # The category must exist, be live and belong to this catalogue.
  defp check_category(nil, _catalogue, state), do: {:ok, nil, state}

  defp check_category(id, catalogue, state) do
    {verdict, cache} = Common.category_verdict(id, catalogue, state.categories)
    state = %{state | categories: cache}

    case verdict do
      {:ok, uuid} -> {:ok, uuid, state}
      {:error, message} -> {:error, "category_id", message, %{}}
    end
  end

  defp check_attributes(entries) do
    case Attributes.validate(entries) do
      :ok -> :ok
      {:error, message, context} -> {:error, "attributes", message, context}
    end
  end

  defp build_attrs(row, catalogue, category_uuid) do
    %{
      name: String.trim(row["name"]),
      catalogue_uuid: catalogue.uuid,
      status: row["status"] || "active"
    }
    |> put_unless_nil(:description, row["description"])
    |> put_unless_nil(:sku, row["sku"])
    |> put_unless_nil(:unit, row["unit"])
    |> put_unless_nil(:category_uuid, category_uuid)
    |> Map.put(:data, new_item_data(row["external_id"]))
  end

  # Every created item starts as a shop draft. The shop reads a missing
  # `shop_status` as "active", so omitting the key would publish the item.
  defp new_item_data(nil), do: %{"ecommerce" => %{"shop_status" => "draft"}}

  defp new_item_data(eid),
    do: %{"api" => %{"external_id" => eid}, "ecommerce" => %{"shop_status" => "draft"}}

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  # --- dry run -------------------------------------------------------------------------

  defp preview(plan) do
    plan
    |> Enum.map(fn
      {:create, ref, attrs, _attributes} ->
        Common.row_ok(ref, "created", nil, %{"fields" => stringify(attrs)})

      {:skip, ref, existing_id, why} ->
        skipped(ref, existing_id, why)

      {:error, ref, message, context} ->
        Common.row_error(ref, :validation_failed, message, context)
    end)
    |> Common.preview()
  end

  defp stringify(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

  # --- execution -------------------------------------------------------------------------

  @doc false
  def execute(plan, catalogue, ctx) do
    opts = Common.write_opts(ctx, @tool, broadcast: false)
    claims = :ets.new(:slug_claims, [:set, :private])

    rows =
      try do
        Enum.map(plan, &execute_row(&1, opts, catalogue, claims))
      after
        :ets.delete(claims)
      end

    created = for %{"action" => "created", "id" => id} <- rows, do: id
    Catalogue.broadcast_item_batch_change(catalogue.uuid, :created, created)

    Common.batch_result(rows)
  end

  defp execute_row({:skip, ref, existing_id, why}, _opts, _catalogue, _claims),
    do: skipped(ref, existing_id, why)

  defp execute_row({:error, ref, message, context}, _opts, _catalogue, _claims),
    do: Common.row_error(ref, :validation_failed, message, context)

  defp execute_row({:create, ref, attrs, attributes}, opts, catalogue, claims) do
    case create_with_slug(attrs, opts, claims) do
      {:ok, item} ->
        claim_slugs(claims, item)
        finish(ref, item, attributes, opts)

      {:error, %Ecto.Changeset{} = changeset} ->
        failure(ref, changeset, catalogue)
    end
  end

  # The slug is generated per row, at the moment of creation, so two items of
  # one request with the same name see each other's slug. One retry covers a
  # slug taken by a writer between the probe and the insert.
  defp create_with_slug(attrs, opts, claims, attempts \\ 2) do
    case Catalogue.create_item(with_slug(attrs, claims), opts) do
      {:error, %Ecto.Changeset{} = changeset} = error ->
        if attempts > 1 and Keyword.has_key?(changeset.errors, :slug),
          do: create_with_slug(attrs, opts, claims, attempts - 1),
          else: error

      other ->
        other
    end
  end

  # `Slugs.maybe_generate/3` is not wired into `create_item/2` (it would give a
  # duplicated item the slug of its source), so it is called explicitly on a
  # changeset built with `Catalogue.change_item/2`.
  defp with_slug(attrs, claims) do
    slug =
      %Item{}
      |> Catalogue.change_item(attrs)
      |> Slugs.maybe_generate(:slug,
        from: :name,
        taken?: fn candidate, lang -> slug_taken?(claims, candidate, lang) end
      )
      |> Ecto.Changeset.get_field(:slug)

    Map.put(attrs, :slug, slug || %{})
  end

  # `claims` remembers every slug this request has created or found taken, so a
  # request of N equal names probes the database about once per row instead of
  # walking `base`, `base-2`, ... for every row. It never remembers a free slug.
  defp slug_taken?(claims, candidate, lang) do
    key = claim_key(candidate, lang)

    cond do
      :ets.member(claims, key) ->
        true

      Catalogue.item_slug_taken?(candidate, lang) ->
        :ets.insert(claims, {key})
        true

      true ->
        false
    end
  end

  defp claim_slugs(claims, %{slug: slugs}) when is_map(slugs) do
    for {lang, slug} <- slugs, is_binary(slug), do: :ets.insert(claims, {claim_key(slug, lang)})
    :ok
  end

  defp claim_slugs(_claims, _item), do: :ok

  # The projection is per base language ("de-DE" and "de-AT" both live in "de").
  defp claim_key(slug, lang), do: {DialectMapper.extract_base(lang), slug}

  defp finish(ref, item, [], _opts), do: Common.row_ok(ref, "created", item.uuid)

  defp finish(ref, item, attributes, opts) do
    case Attributes.apply_to_item(
           item.uuid,
           attributes,
           Keyword.take(opts, [:actor_uuid, :mode, :log_metadata, :broadcast])
         ) do
      :ok ->
        Common.row_ok(ref, "created", item.uuid)

      {:error, reason} ->
        ref
        |> Common.row_error(
          :validation_failed,
          "The item was created, but its attributes were not saved: #{Common.attribute_sentence(reason)}.",
          %{"created" => true, "reason" => Common.reason_code(reason)}
        )
        |> Map.put("id", item.uuid)
    end
  end

  defp failure(ref, changeset, catalogue) do
    if Common.external_id_conflict?(changeset) do
      skipped(ref, existing_by_external_id(ref, catalogue), :exists)
    else
      Common.row_error(ref, :validation_failed, "The item is not valid.", %{
        "errors" => Common.changeset_errors(changeset)
      })
    end
  end

  defp existing_by_external_id(%{"external_id" => eid}, catalogue) do
    case API.resolve_refs([%{"external_id" => eid}], kind: :item, catalogue_uuid: catalogue.uuid) do
      [{_ref, {:ok, item}}] -> item.uuid
      _other -> nil
    end
  end

  defp existing_by_external_id(_ref, _catalogue), do: nil

  defp skipped(ref, existing_id, :exists) do
    Common.row_skipped(
      ref,
      :already_exists,
      "An item with this sku or external_id already exists in the catalogue.",
      %{"existing_id" => existing_id}
    )
  end

  defp skipped(ref, existing_id, :duplicate_in_request) do
    Common.row_skipped(
      ref,
      :already_exists,
      "The same sku or external_id appears earlier in this request.",
      %{"existing_id" => existing_id, "duplicate_in_request" => true}
    )
  end
end
