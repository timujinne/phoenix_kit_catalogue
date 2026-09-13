defmodule PhoenixKitCatalogue.Import.Pro100Plan do
  @moduledoc """
  Builds the PRO100 sync diff/report. Rows fall into three buckets:

    * `:updates` — matched rows become per-field change sets (`base_price`,
      materials `unit`) plus a `data["pro100"]` round-trip blob
    * `:creates` — rows with no catalogue match but enough data to become a
      new item; applied only when the operator opts in on the preview screen
    * `:skipped` — ambiguous matches, rows belonging to another group, and
      unmatched rows that cannot be created (no id, no name)

  Pure — no DB. All three buckets are computed unconditionally so the preview
  can show counts before the operator decides what to apply.
  """
  alias PhoenixKitCatalogue.Import.{Mapper, Matcher}

  # PRO100 prefixes the item name with its group: "Andi Karkass / MP U741 …".
  # The separator must be whitespace-padded: article codes contain bare
  # slashes ("MP U767 PM/ST9 18mm") that must NOT be treated as a group split.
  @group_separator ~r/\s+\/\s+/

  @spec build([map()], Matcher.t(), String.t() | nil) :: %{
          updates: [map()],
          creates: [map()],
          skipped: [map()],
          stats: map()
        }
  def build(rows, index, catalogue_name) do
    classified = Enum.map(rows, &classify(index, &1, catalogue_name))

    updates = build_updates(classified)
    creates = build_creates(classified)
    skipped = for {:skip, entry} <- classified, do: entry

    %{
      updates: updates,
      creates: creates,
      skipped: skipped,
      stats: %{
        update: Enum.count(updates, &(&1.status == :update)),
        nochange: Enum.count(updates, &(&1.status == :nochange)),
        create: length(creates),
        ambiguous: Enum.count(skipped, &(&1.reason == :ambiguous)),
        no_id: Enum.count(skipped, &(&1.reason == :no_id)),
        no_name: Enum.count(skipped, &(&1.reason == :no_name)),
        foreign_group: Enum.count(skipped, &(&1.reason == :foreign_group))
      }
    }
  end

  # ── Classification ───────────────────────────────────────────────

  # `split_name/1` runs once per row, at the top: the group half feeds the
  # foreign check, the name half feeds the match key, and the create path reuses
  # both. Splitting again downstream would be three regex passes and an
  # opportunity for the two halves to disagree.
  #
  # The foreign check runs BEFORE Matcher.resolve, deliberately. A row from
  # another group must never be matched at all: nothing rules out its code and
  # name also existing in the target catalogue, and resolving first would let it
  # quietly update an item in the wrong catalogue — the exact failure this guard
  # exists to prevent.
  defp classify(index, row, catalogue_name) do
    {group, name} = split_name(row.name)

    if foreign_group?(group, catalogue_name) do
      {:skip, %{row: row, reason: :foreign_group, group: group}}
    else
      case Matcher.resolve(index, row.id, name) do
        {:matched, item} -> {:match, item, row}
        {:ambiguous, items} -> {:skip, %{row: row, reason: :ambiguous, items: items}}
        :unmatched -> classify_unmatched(row, category_from_group(group, catalogue_name), name)
      end
    end
  end

  # A group that survived `foreign_group?/2` against a real catalogue name IS
  # that catalogue name — nothing else gets past the guard. Turning it into a
  # category would file every created row under a category duplicating the
  # catalogue, while the unprefixed rows of the same export land at the
  # catalogue root: two placements for one file. So a checked group carries no
  # grouping information and yields no category.
  #
  # It still does when there was no catalogue name to check against — the
  # `analyze/4` contract lets a caller opt out of the group guard, and for that
  # caller the prefix is the only structure the file has.
  defp category_from_group(nil, _catalogue_name), do: nil
  defp category_from_group(_group, catalogue_name) when is_binary(catalogue_name), do: nil
  defp category_from_group(group, nil), do: group

  # A row with no group prefix belongs to whatever catalogue was selected: the
  # per-catalogue PRO100 exports carry no prefix at all, and the `# Materials`
  # layout has no group column. With no catalogue name to compare against
  # (callers that do not care about grouping), the check is off.
  defp foreign_group?(nil, _catalogue_name), do: false
  defp foreign_group?(_group, nil), do: false

  defp foreign_group?(group, catalogue_name),
    do: String.trim(group) != String.trim(catalogue_name)

  # An id-less row is creatable on paper, but it would get `sku: nil`, never
  # match on the next sync, and duplicate itself on every subsequent import —
  # silent multiplication is worse than an explicit skip. A nameless row would
  # fail the item changeset deep inside the executor; catching it here turns an
  # opaque per-row error into a clear plan-time reason.
  defp classify_unmatched(row, category, name) do
    cond do
      row.id in [nil, ""] -> {:skip, %{row: row, reason: :no_id}}
      name == "" -> {:skip, %{row: row, reason: :no_name}}
      true -> {:create, row, category, name}
    end
  end

  @doc """
  Splits a PRO100 row name into `{category_name_or_nil, item_name}`.

  Both parts are trimmed. When there is no whitespace-padded separator — or
  when either side of it is blank ("/ Foo", "Group /") — the whole trimmed
  string becomes the item name and there is no category. A blank category name
  would fail `create_category`'s changeset, which the executor swallows
  silently, leaving items uncategorized with no diagnostic.
  """
  @spec split_name(String.t() | nil) :: {String.t() | nil, String.t()}
  def split_name(nil), do: {nil, ""}

  def split_name(name) when is_binary(name) do
    case Regex.split(@group_separator, name, parts: 2) do
      [group, rest] ->
        group = String.trim(group)
        rest = String.trim(rest)
        if group == "" or rest == "", do: {nil, String.trim(name)}, else: {group, rest}

      _ ->
        {nil, String.trim(name)}
    end
  end

  # ── Updates ──────────────────────────────────────────────────────

  # Group rows by matched item UUID (newest-first) so that when multiple
  # PRO100 rows resolve to the same catalogue item, we compute exactly ONE
  # change entry per item rather than emitting independent writes that
  # would silently overwrite each other on apply. Policy: last-row-wins —
  # see change/3 below for why the diff is computed against the LAST row
  # only, not folded field-by-field across rows.
  defp build_updates(classified) do
    {by_uuid, order} =
      Enum.reduce(classified, {%{}, []}, fn
        {:match, item, row}, {by_uuid, order} ->
          case Map.get(by_uuid, item.uuid) do
            nil -> {Map.put(by_uuid, item.uuid, %{item: item, rows: [row]}), [item.uuid | order]}
            entry -> {Map.put(by_uuid, item.uuid, %{entry | rows: [row | entry.rows]}), order}
          end

        _other, acc ->
          acc
      end)

    # Restore input order (first occurrence of each item).
    order
    |> Enum.reverse()
    |> Enum.map(fn uuid ->
      %{item: item, rows: rows_for_item} = by_uuid[uuid]
      # `rows_for_item` accumulated newest-first; the head is the last row
      # in file order for this item, and the sole source of truth for the
      # applied change (see change/3).
      [last_row | earlier_rows] = rows_for_item
      change(item, last_row, earlier_rows)
    end)
  end

  # ── Creates ──────────────────────────────────────────────────────

  # Same last-row-wins policy as updates, but keyed on the row id: creates have
  # no item uuid to group by, and two file rows carrying the same id must yield
  # one new item, not two colliding ones.
  defp build_creates(classified) do
    {by_id, order} =
      Enum.reduce(classified, {%{}, []}, fn
        {:create, row, category, name}, {by_id, order} ->
          payload = {row, category, name}

          if Map.has_key?(by_id, row.id),
            do: {Map.put(by_id, row.id, payload), order},
            else: {Map.put(by_id, row.id, payload), [row.id | order]}

        _other, acc ->
          acc
      end)

    order
    |> Enum.reverse()
    |> Enum.map(fn id -> create_entry(by_id[id]) end)
  end

  defp create_entry({row, category, name}) do
    {unit_attrs, flags, extra_data} = create_unit(row)

    price_flags = if is_nil(row.base_price), do: [:price_unparseable], else: []

    attrs =
      %{name: name, sku: row.id, data: create_data(row, extra_data)}
      |> maybe_put(:base_price, row.base_price)
      |> maybe_put(:_category_name, category)
      |> Map.merge(unit_attrs)

    %{
      row: row,
      name: name,
      category: category,
      attrs: attrs,
      flags: flags ++ price_flags
    }
  end

  # The `:unit` key is OMITTED rather than set to nil when there is nothing to
  # say: the schema's "piece" default only applies to absent keys, so an
  # explicit nil (which is what the parser hands us for furniture rows) would
  # write NULL and produce unitless items.
  defp create_unit(%{format: :materials, unit: label}) when is_binary(label) and label != "" do
    case Mapper.resolve_pro100_unit(label) do
      {:ok, unit} -> {%{unit: unit}, [], %{}}
      :unknown -> {%{}, [:unit_unrecognized], %{"original_unit" => label}}
    end
  end

  defp create_unit(_row), do: {%{}, [], %{}}

  defp create_data(row, extra) do
    pro100 = Map.put(row.service, "format", Atom.to_string(row.format))
    Map.merge(%{"pro100" => pro100}, extra)
  end

  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, key, value), do: Map.put(attrs, key, value)

  @doc """
  The `data` keys an update change actually writes — those whose value
  differs from the item snapshot the plan diffed against (`"pro100"`, and
  `"original_unit"` for an unrecognised material unit). Apply writes ONLY
  these, as owned keys, so a photo attached or reordered between the
  preview and Apply — or between Apply's read and its write — survives.
  """
  @spec data_owned_keys(map()) :: [String.t()]
  def data_owned_keys(%{item: item, data: data}) when is_map(data) do
    snapshot = (item && item.data) || %{}

    data
    |> Enum.reject(fn {key, value} -> Map.get(snapshot, key) == value end)
    |> Enum.map(&elem(&1, 0))
  end

  @doc """
  Converts the `:creates` bucket into the plan shape `Executor.execute/4` wants.

  Category linkage runs through the `:_category_name` placeholder resolved
  against the phase-1 lookup, which is built from `categories_to_create` — a
  name present on an item but missing from that list is dropped silently, so
  the two must be derived together.
  """
  @spec to_executor_plan([map()]) :: %{items: [map()], categories_to_create: [String.t()]}
  def to_executor_plan(creates) do
    %{
      items: Enum.map(creates, & &1.attrs),
      categories_to_create:
        creates
        |> Enum.map(& &1.category)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
    }
  end

  # Diffs against the TRUE pre-import `item`, using only the last row for
  # this item's own field values/data. Diffing each collided row independently
  # and then folding the resulting *changes* maps (the previous approach) is
  # unsound: a row whose raw value happens to equal `item`'s pristine value
  # produces an empty diff and so can never "win" a Map.merge, even when it's
  # the last row and should be authoritative — e.g. item.base_price = 80,
  # row1 says 100 (diff recorded), row2 (later, same item) says 80 (looks
  # like "no change" against the pristine item, contributes no key) — the
  # fold would keep row1's 80->100 even though the last row says 80. Diffing
  # the last row directly against `item` sidesteps that: the correct final
  # value for a repeatedly-asserted field is always the last row's value,
  # and comparing straight to `item` gets the diff (or lack thereof) right
  # regardless of what intermediate rows said. Earlier rows' diagnostic
  # flags (e.g. `:unit_unrecognized`) are still surfaced since they're
  # informational and non-exclusive, not per-item state.
  defp change(item, row, earlier_rows) do
    {price_changes, _} = price_change(item, row)
    {unit_changes, flags, extra_data} = unit_change(item, row)
    earlier_flags = Enum.flat_map(earlier_rows, fn r -> elem(unit_change(item, r), 1) end)

    changes = Map.merge(price_changes, unit_changes)
    data = build_data(item, row, extra_data)

    %{
      item: item,
      row: row,
      changes: changes,
      data: data,
      flags: Enum.uniq(flags ++ earlier_flags),
      status: if(map_size(changes) > 0, do: :update, else: :nochange)
    }
  end

  defp price_change(item, %{base_price: new}) when not is_nil(new) do
    cond do
      is_nil(item.base_price) -> {%{base_price: {nil, new}}, :changed}
      Decimal.equal?(item.base_price, new) -> {%{}, :same}
      true -> {%{base_price: {item.base_price, new}}, :changed}
    end
  end

  defp price_change(_item, _row), do: {%{}, :same}

  # materials: resolve unit; unknown -> keep current unit, flag + stash raw.
  # furniture (unit: nil) and blank labels fall through to the catch-all.
  defp unit_change(item, %{format: :materials, unit: label})
       when is_binary(label) and label != "" do
    case Mapper.resolve_pro100_unit(label) do
      {:ok, unit} ->
        if unit == item.unit,
          do: {%{}, [], %{}},
          else: {%{unit: {item.unit, unit}}, [], %{}}

      :unknown ->
        {%{}, [:unit_unrecognized], %{"original_unit" => label}}
    end
  end

  defp unit_change(_item, _row), do: {%{}, [], %{}}

  defp build_data(item, row, extra) do
    pro100 = Map.put(row.service, "format", Atom.to_string(row.format))
    base = item.data || %{}

    base
    |> Map.put("pro100", pro100)
    |> Map.merge(extra)
  end
end
