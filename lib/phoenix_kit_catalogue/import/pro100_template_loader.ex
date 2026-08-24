defmodule PhoenixKitCatalogue.Import.Pro100TemplateLoader do
  @moduledoc """
  Applies a `Pro100TemplatePlan` to the catalogue.

  Safe to run twice. Identity is resolved at every level, because the one
  question nobody can answer — whether PRO100 regenerates its guids on each
  export — decides whether a second run updates or duplicates:

      folder      by name
      catalogue   by data["pro100"]["template_guid"], else by (folder, name)
      category    by (catalogue, parent, name)
      item        by data["pro100"]["template_guid"], else by (category, name)
                  and only when that item carries no guid of its own

  The last condition is what stops a renamed line from overwriting an unrelated
  item that happens to share its new name: if the candidate already has a guid,
  it belongs to a different line, and the incoming row is reported instead.

  Nothing is ever deleted. Items in a catalogue with no line in the file are
  reported as `:absent`, which is the only signal that a position was dropped
  upstream.

  `dry_run: true` performs every lookup and decision and writes nothing.

  Every write inside the transaction is muted (`broadcast: false`); once it
  has committed the loader emits one `:folder` event if it created the
  folder and one `:catalogue` roll-up per catalogue it touched — the same
  discipline as `Import.Executor`, so open index/detail pages refresh once,
  after the data is really there, instead of on every pre-commit row.
  """

  import Ecto.Query

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.{PubSub, Rules}
  alias PhoenixKitCatalogue.Import.Matcher
  # The context and the schema are both called `Catalogue`; the schema is aliased
  # under a distinct name so it cannot shadow the context's functions.
  alias PhoenixKitCatalogue.Schemas.Catalogue, as: CatalogueSchema
  alias PhoenixKitCatalogue.Schemas.{Category, Folder, Item}

  # Inside the transaction nothing fans out; see `broadcast_touched/1`.
  @muted [broadcast: false]

  @type report :: %{
          folder: :created | :reused,
          catalogues: [map()],
          rules: [map()],
          absent: [map()],
          reported: [map()],
          stats: map()
        }

  @spec apply_plan(map(), keyword()) :: {:ok, report()} | {:error, term()}
  def apply_plan(plan, opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, true)

    cond do
      plan.problems != [] ->
        {:error, {:plan_problems, plan.problems}}

      dry_run? ->
        {report, _touched} = run(plan, true)
        {:ok, report}

      true ->
        run_and_broadcast(plan)
    end
  end

  defp run_and_broadcast(plan) do
    case repo().transaction(fn -> run_or_rollback(plan) end) do
      {:ok, {report, touched}} ->
        broadcast_touched(touched)
        {:ok, report}

      error ->
        error
    end
  end

  defp run_or_rollback(plan) do
    {report, _touched} = result = run(plan, false)
    if report.stats.errors > 0, do: repo().rollback({:errors, report.reported})
    result
  end

  # Post-commit fan-out: the folder only if this run created it, then every
  # catalogue the plan wrote into (created or reused — its categories,
  # items and rules changed either way).
  defp broadcast_touched(%{folder: folder, catalogues: catalogue_uuids}) do
    if folder, do: PubSub.broadcast(:folder, folder)
    Enum.each(catalogue_uuids, &PubSub.broadcast(:catalogue, &1, &1))
    :ok
  end

  # Returns `{report, touched}`; `touched` is what `broadcast_touched/1`
  # announces after the commit.
  defp run(plan, dry?) do
    folder = resolve_folder(plan.folder.name, dry?)

    {catalogue_reports, name_to_uuid} =
      Enum.map_reduce(plan.catalogues, %{}, fn cat, acc ->
        {report, uuid} = apply_catalogue(cat, folder, dry?)
        {report, Map.put(acc, cat.name, uuid)}
      end)

    touched = %{
      folder: if(folder.status == :created, do: folder.uuid),
      catalogues: name_to_uuid |> Map.values() |> Enum.reject(&is_nil/1)
    }

    rule_reports =
      plan.catalogues
      |> Enum.filter(&(&1.rules != []))
      |> Enum.map(&apply_rules(&1, name_to_uuid, dry?))

    absent = Enum.flat_map(catalogue_reports, & &1.absent)
    reported = Enum.flat_map(catalogue_reports, & &1.reported)

    report = %{
      folder: folder.status,
      catalogues: catalogue_reports,
      rules: rule_reports,
      absent: absent,
      reported: reported,
      stats: %{
        catalogues_created: Enum.count(catalogue_reports, &(&1.status == :created)),
        catalogues_reused: Enum.count(catalogue_reports, &(&1.status == :reused)),
        categories_created: catalogue_reports |> Enum.map(& &1.categories_created) |> Enum.sum(),
        items_created: catalogue_reports |> Enum.map(& &1.items_created) |> Enum.sum(),
        items_updated: catalogue_reports |> Enum.map(& &1.items_updated) |> Enum.sum(),
        items_unchanged: catalogue_reports |> Enum.map(& &1.items_unchanged) |> Enum.sum(),
        rules_written: rule_reports |> Enum.map(& &1.count) |> Enum.sum(),
        absent: length(absent),
        errors: length(reported)
      }
    }

    {report, touched}
  end

  # ── Folder ───────────────────────────────────────────────────────

  defp resolve_folder(name, dry?) do
    case repo().one(from(f in Folder, where: f.name == ^name, limit: 1)) do
      %Folder{} = f ->
        %{uuid: f.uuid, status: :reused}

      nil when dry? ->
        %{uuid: nil, status: :created}

      nil ->
        {:ok, f} = Catalogue.create_folder(%{name: name}, @muted)
        %{uuid: f.uuid, status: :created}
    end
  end

  # ── Catalogue ────────────────────────────────────────────────────

  defp apply_catalogue(cat, folder, dry?) do
    existing = find_catalogue(cat, folder)
    {uuid, status} = ensure_catalogue(cat, folder, existing, dry?)

    category_uuids = apply_categories(cat, uuid, dry?)
    {items, absent, reported} = apply_items(cat, uuid, category_uuids, dry?)

    report = %{
      name: cat.name,
      kind: cat.kind,
      status: status,
      categories_created:
        Enum.count(category_uuids, fn {_key, {_uuid, status}} -> status == :created end),
      items_created: Enum.count(items, &(&1 == :created)),
      items_updated: Enum.count(items, &(&1 == :updated)),
      items_unchanged: Enum.count(items, &(&1 == :unchanged)),
      absent: absent,
      reported: reported
    }

    {report, uuid}
  end

  defp find_catalogue(cat, folder) do
    by_guid =
      repo().one(
        from(c in CatalogueSchema,
          where: fragment("?->'pro100'->>'template_guid' = ?", c.data, ^cat.template_guid),
          limit: 1
        )
      )

    by_guid ||
      repo().one(
        from(c in CatalogueSchema,
          where: c.name == ^cat.name and c.status != "deleted",
          where: ^folder_clause(folder.uuid),
          limit: 1
        )
      )
  end

  defp folder_clause(nil), do: dynamic([c], is_nil(c.folder_uuid))
  defp folder_clause(uuid), do: dynamic([c], c.folder_uuid == ^uuid)

  defp ensure_catalogue(_cat, _folder, %CatalogueSchema{} = existing, _dry?),
    do: {existing.uuid, :reused}

  defp ensure_catalogue(_cat, _folder, nil, true), do: {nil, :created}

  defp ensure_catalogue(cat, folder, nil, false) do
    {:ok, created} =
      Catalogue.create_catalogue(
        %{
          name: cat.name,
          kind: cat.kind,
          folder_uuid: folder.uuid,
          position: cat.position,
          data: %{"pro100" => %{"template_guid" => cat.template_guid}}
        },
        @muted
      )

    {created.uuid, :created}
  end

  # ── Categories ───────────────────────────────────────────────────
  # Sections first so a sub-heading can point at its parent's uuid.

  defp apply_categories(cat, catalogue_uuid, dry?) do
    existing =
      if catalogue_uuid,
        do:
          catalogue_uuid
          |> Catalogue.list_categories_for_catalogue()
          |> Map.new(&{{&1.parent_uuid, &1.name}, &1}),
        else: %{}

    {roots, subs} = Enum.split_with(cat.categories, &is_nil(&1.parent))

    root_uuids =
      Enum.reduce(roots, %{}, fn c, acc ->
        Map.put(acc, {nil, c.name}, ensure_category(c, nil, catalogue_uuid, existing, dry?))
      end)

    Enum.reduce(subs, root_uuids, fn c, acc ->
      parent_uuid = acc |> Map.get({nil, c.parent}) |> uuid_of()

      Map.put(
        acc,
        {c.parent, c.name},
        ensure_category(c, parent_uuid, catalogue_uuid, existing, dry?)
      )
    end)
  end

  defp ensure_category(c, parent_uuid, catalogue_uuid, existing, dry?) do
    case Map.get(existing, {parent_uuid, c.name}) do
      %Category{} = found ->
        {found.uuid, :reused}

      nil when dry? ->
        {nil, :created}

      nil ->
        {:ok, created} =
          Catalogue.create_category(
            %{
              name: c.name,
              catalogue_uuid: catalogue_uuid,
              parent_uuid: parent_uuid,
              position: c.position
            },
            @muted
          )

        {created.uuid, :created}
    end
  end

  defp uuid_of({uuid, _status}), do: uuid
  defp uuid_of(_), do: nil

  # ── Items ────────────────────────────────────────────────────────

  defp apply_items(cat, catalogue_uuid, category_uuids, dry?) do
    existing = if catalogue_uuid, do: Catalogue.list_items_for_catalogue(catalogue_uuid), else: []

    by_guid =
      existing
      |> Enum.filter(&guid_of/1)
      |> Map.new(&{guid_of(&1), &1})

    by_name = Enum.group_by(existing, &Matcher.normalize_name(&1.name))

    {results, touched, reported} =
      Enum.reduce(cat.items, {[], MapSet.new(), []}, fn item, {acc, seen, errs} ->
        category_uuid = category_uuids |> Map.get(item.category) |> uuid_of()

        case resolve_item(item, by_guid, by_name) do
          {:update, found} ->
            {[write_update(found, item, category_uuid, dry?) | acc], MapSet.put(seen, found.uuid),
             errs}

          :create ->
            {[write_create(item, catalogue_uuid, category_uuid, dry?) | acc], seen, errs}

          {:report, reason} ->
            {acc, seen, [%{name: item.name, reason: reason} | errs]}
        end
      end)

    absent =
      existing
      |> Enum.reject(&MapSet.member?(touched, &1.uuid))
      |> Enum.map(&%{name: &1.name, sku: &1.sku, uuid: &1.uuid})

    {results, absent, reported}
  end

  defp resolve_item(item, by_guid, by_name) do
    guid = item.data["pro100"]["template_guid"]

    case Map.get(by_guid, guid) do
      %Item{} = found -> {:update, found}
      nil -> resolve_item_by_name(item, by_name)
    end
  end

  defp resolve_item_by_name(item, by_name) do
    case Map.get(by_name, Matcher.normalize_name(item.name), []) do
      [] -> :create
      [one] -> if guid_of(one), do: {:report, :name_taken_by_other_line}, else: {:update, one}
      _many -> {:report, :ambiguous_name}
    end
  end

  defp guid_of(%Item{data: data}) when is_map(data), do: get_in(data, ["pro100", "template_guid"])
  defp guid_of(_), do: nil

  defp write_create(_item, _catalogue_uuid, _category_uuid, true), do: :created

  defp write_create(item, catalogue_uuid, category_uuid, false) do
    {:ok, _} =
      Catalogue.create_item(
        %{
          name: item.name,
          base_price: item.base_price,
          description: item.description,
          position: item.position,
          catalogue_uuid: catalogue_uuid,
          category_uuid: category_uuid,
          data: item.data
        },
        skip_derive: true,
        broadcast: false
      )

    :created
  end

  defp write_update(found, item, category_uuid, dry?) do
    changes = item_changes(found, item, category_uuid)

    cond do
      changes == %{} -> :unchanged
      dry? -> :updated
      true -> apply_update(found, changes)
    end
  end

  defp apply_update(found, changes) do
    {:ok, _} = Catalogue.update_item(found, changes, skip_derive: true, broadcast: false)
    :updated
  end

  # The file is the reference, so a changed name follows the file. `data` is
  # deep-merged under "pro100" rather than replaced: the price-list sync keeps
  # its own service columns under the same key on other items, and a blanket
  # overwrite here would set the precedent that clobbers them.
  defp item_changes(found, item, category_uuid) do
    %{}
    |> put_if_changed(:name, found.name, item.name)
    |> put_if_changed(:base_price, found.base_price, item.base_price, &decimal_equal?/2)
    |> put_if_changed(:description, found.description, item.description)
    |> put_if_changed(:position, found.position, item.position)
    |> put_if_changed(:category_uuid, found.category_uuid, category_uuid)
    |> merge_data(found, item)
  end

  defp put_if_changed(acc, key, old, new, eq \\ &==/2) do
    if eq.(old, new), do: acc, else: Map.put(acc, key, new)
  end

  defp decimal_equal?(nil, nil), do: true
  defp decimal_equal?(nil, _), do: false
  defp decimal_equal?(_, nil), do: false
  defp decimal_equal?(a, b), do: Decimal.equal?(a, b)

  defp merge_data(acc, found, item) do
    old = (found.data || %{})["pro100"] || %{}
    new = Map.merge(old, item.data["pro100"])

    if new == old,
      do: acc,
      else: Map.put(acc, :data, Map.put(found.data || %{}, "pro100", new))
  end

  # ── Rules ────────────────────────────────────────────────────────

  defp apply_rules(cat, name_to_uuid, dry?) do
    catalogue_uuid = Map.get(name_to_uuid, cat.name)

    items =
      if catalogue_uuid,
        do: catalogue_uuid |> Catalogue.list_items_for_catalogue() |> Map.new(&{&1.name, &1}),
        else: %{}

    written =
      cat.rules
      |> Enum.group_by(& &1.item_name)
      |> Enum.map(fn {item_name, rules} ->
        payload =
          Enum.map(rules, fn r ->
            %{
              referenced_catalogue_uuid: Map.get(name_to_uuid, r.referenced_catalogue),
              value: r.value,
              unit: r.unit
            }
          end)

        case Map.get(items, item_name) do
          %Item{} = item when not dry? ->
            {:ok, _} = Rules.put_catalogue_rules(item, payload, @muted)
            length(payload)

          _ ->
            length(payload)
        end
      end)
      |> Enum.sum()

    %{catalogue: cat.name, count: written}
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
