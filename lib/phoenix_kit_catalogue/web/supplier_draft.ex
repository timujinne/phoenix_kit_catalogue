defmodule PhoenixKitCatalogue.Web.SupplierDraft do
  @moduledoc """
  The item form's supplier changes, held until the item is saved (Max,
  2026-09-19: picking a supplier is enough to add it, the cost is edited
  straight in the list, and the item's Save is what locks it all in).

  Picking a supplier stages a row; its cost and currency are edited in the
  table; Remove, Make primary and the row dialog's extra values are staged
  too. `apply/5` writes everything through `ItemSupplierInfos` once the
  item itself has saved, in an order that keeps the context's own rules
  meaningful: removals first (so a removed primary frees the flag), then
  edits, then new rows (the first row added to an item without a primary
  is promoted by the context), then an explicitly chosen primary.

  Rows are keyed by **supplier**: an item has at most one current row per
  supplier, and that key survives the price revision a cost change makes —
  a revision replaces the row's uuid.

  Staged values are the strings the admin typed; `validate/2` checks them
  without writing, so a bad price blocks the whole save the way an invalid
  item field does.
  """

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.ItemSupplierInfos
  alias PhoenixKitCatalogue.Schemas.ItemSupplierInfo

  defstruct adds: [], values: %{}, custom: %{}, removed: [], primary: nil, errors: %{}

  @type supplier_uuid :: String.t()

  @type t :: %__MODULE__{
          adds: [supplier_uuid()],
          values: %{supplier_uuid() => %{String.t() => String.t() | nil}},
          custom: %{supplier_uuid() => map()},
          removed: [supplier_uuid()],
          primary: supplier_uuid() | nil,
          errors: %{supplier_uuid() => atom()}
        }

  @value_keys ~w(unit_cost currency supplier_sku lead_time_days min_order_qty)
  @term_keys ~w(supplier_sku lead_time_days min_order_qty)

  @spec new() :: t()
  def new, do: %__MODULE__{}

  # ── Staging ──────────────────────────────────────────────────────────

  @doc "Stages `supplier_uuid` as a new row, when it is one of `addable`."
  @spec add(t(), term(), [supplier_uuid()]) :: t()
  def add(%__MODULE__{} = draft, supplier_uuid, addable) when is_binary(supplier_uuid) do
    if supplier_uuid in addable and supplier_uuid not in draft.adds,
      do: %{draft | adds: draft.adds ++ [supplier_uuid]},
      else: draft
  end

  def add(draft, _supplier_uuid, _addable), do: draft

  @doc """
  Stages a remove. A staged new row is simply dropped; a saved row is
  marked and closed on save (`restore/2` takes the mark back).
  """
  @spec remove(t(), term(), [ItemSupplierInfo.t()]) :: t()
  def remove(%__MODULE__{} = draft, supplier_uuid, infos) do
    cond do
      supplier_uuid in draft.adds ->
        draft
        |> drop_add(supplier_uuid)
        |> forget(supplier_uuid)
        |> drop_primary(supplier_uuid)

      # Its typed values go with it: Undo brings back the saved row.
      saved?(infos, supplier_uuid) ->
        draft
        |> forget(supplier_uuid)
        |> Map.update!(:removed, &[supplier_uuid | &1])
        |> drop_primary(supplier_uuid)

      true ->
        draft
    end
  end

  @spec restore(t(), term()) :: t()
  def restore(%__MODULE__{} = draft, supplier_uuid),
    do: %{draft | removed: List.delete(draft.removed, supplier_uuid)}

  @doc "Stages `supplier_uuid` as the primary — a row on the item or a staged one."
  @spec make_primary(t(), term(), [ItemSupplierInfo.t()]) :: t()
  def make_primary(%__MODULE__{} = draft, supplier_uuid, infos) do
    if supplier_uuid in draft.adds or
         (saved?(infos, supplier_uuid) and supplier_uuid not in draft.removed),
       do: %{draft | primary: supplier_uuid},
       else: draft
  end

  @doc """
  Takes the table's typed values — `%{supplier_uuid => %{"unit_cost" =>
  …, "currency" => …}}` from the item form — for the rows it has, and
  re-checks those rows so a bad price shows at once. Anything else in the
  payload (a row it does not hold, a removed row, a non-string value) is
  ignored.
  """
  @spec put_values(t(), term(), [ItemSupplierInfo.t()]) :: t()
  def put_values(%__MODULE__{} = draft, rows, infos) when is_map(rows) do
    Enum.reduce(rows, draft, fn
      {supplier_uuid, row}, draft when is_binary(supplier_uuid) and is_map(row) ->
        put_row_values(draft, supplier_uuid, row, infos)

      _other, draft ->
        draft
    end)
  end

  def put_values(draft, _rows, _infos), do: draft

  defp put_row_values(draft, supplier_uuid, row, infos) do
    if editable?(draft, supplier_uuid, infos) do
      typed = for {k, v} <- row, k in @value_keys, is_binary(v), into: %{}, do: {k, v}
      values = Map.merge(Map.get(draft.values, supplier_uuid, %{}), typed)

      draft
      |> put_in([Access.key(:values), supplier_uuid], values)
      |> check_row(supplier_uuid, infos)
    else
      draft
    end
  end

  @doc "Stages the row dialog's values and extra-field values for one row."
  @spec put_details(t(), supplier_uuid(), map(), map(), [ItemSupplierInfo.t()]) :: t()
  def put_details(%__MODULE__{} = draft, supplier_uuid, values, custom, infos) do
    if editable?(draft, supplier_uuid, infos) do
      typed = for {k, v} <- values, k in @value_keys, into: %{}, do: {k, v}

      draft
      |> put_in([Access.key(:values), supplier_uuid], typed)
      |> put_in([Access.key(:custom), supplier_uuid], custom)
      |> check_row(supplier_uuid, infos)
    else
      draft
    end
  end

  @doc """
  Brings the draft in line with the item's rows after they changed
  elsewhere: marks and edits for rows that are gone are dropped, and a
  staged add whose supplier is now on the item is dropped too — the row
  that appeared is the one to edit.
  """
  @spec reconcile(t(), [ItemSupplierInfo.t()]) :: t()
  def reconcile(%__MODULE__{} = draft, infos) do
    saved = MapSet.new(infos, & &1.supplier_uuid)
    adds = Enum.reject(draft.adds, &MapSet.member?(saved, &1))
    keep? = &(MapSet.member?(saved, &1) or &1 in adds)

    %{
      draft
      | adds: adds,
        values: Map.filter(draft.values, fn {s, _} -> keep?.(s) end),
        custom: Map.filter(draft.custom, fn {s, _} -> keep?.(s) end),
        removed: Enum.filter(draft.removed, &MapSet.member?(saved, &1)),
        primary: if(draft.primary && keep?.(draft.primary), do: draft.primary),
        errors: Map.filter(draft.errors, fn {s, _} -> keep?.(s) end)
    }
  end

  # ── Reading ──────────────────────────────────────────────────────────

  @doc """
  The table's rows: the item's saved rows, then the staged ones in the
  order they were picked. Each says what it will be after a save.
  """
  @spec rows(t(), [ItemSupplierInfo.t()], [map()]) :: [map()]
  def rows(%__MODULE__{} = draft, infos, all_suppliers) do
    primary = primary(draft, infos)

    saved =
      for info <- infos do
        supplier_uuid = info.supplier_uuid
        values = Map.get(draft.values, supplier_uuid, %{})

        %{
          key: supplier_uuid,
          info: info,
          name: name(supplier_uuid, info, all_suppliers),
          new?: false,
          removed?: supplier_uuid in draft.removed,
          primary?: primary == supplier_uuid,
          unit_cost: Map.get(values, "unit_cost", decimal_text(info.unit_cost)),
          currency: Map.get(values, "currency", info.currency || ""),
          custom: Map.get(draft.custom, supplier_uuid, Catalogue.supplier_field_values(info)),
          error: Map.get(draft.errors, supplier_uuid)
        }
      end

    added =
      for supplier_uuid <- draft.adds do
        values = Map.get(draft.values, supplier_uuid, %{})

        %{
          key: supplier_uuid,
          info: nil,
          name: name(supplier_uuid, nil, all_suppliers),
          new?: true,
          removed?: false,
          primary?: primary == supplier_uuid,
          unit_cost: Map.get(values, "unit_cost", ""),
          currency: Map.get(values, "currency", ""),
          custom: Map.get(draft.custom, supplier_uuid, %{}),
          error: Map.get(draft.errors, supplier_uuid)
        }
      end

    saved ++ added
  end

  @doc """
  The supplier that will be primary after a save: the one chosen, else
  the current primary unless it is being removed, else — when no primary
  remains — the first staged row, which the context promotes on create.
  """
  @spec primary(t(), [ItemSupplierInfo.t()]) :: supplier_uuid() | nil
  def primary(%__MODULE__{} = draft, infos) do
    kept = Enum.reject(infos, &(&1.supplier_uuid in draft.removed))

    cond do
      draft.primary -> draft.primary
      current = Enum.find(kept, & &1.is_primary) -> current.supplier_uuid
      draft.adds != [] and not Enum.any?(kept, & &1.is_primary) -> hd(draft.adds)
      true -> nil
    end
  end

  @doc "Whether saving would change anything."
  @spec dirty?(t(), [ItemSupplierInfo.t()]) :: boolean()
  def dirty?(%__MODULE__{} = draft, infos) do
    current_primary = Enum.find_value(infos, &(&1.is_primary && &1.supplier_uuid))

    draft.adds != [] or draft.removed != [] or
      (draft.primary != nil and draft.primary != current_primary) or
      Enum.any?(infos, &changed?(draft, &1))
  end

  @doc """
  Checks every staged row without writing. `{:ok, draft}` when all are
  valid, `{:error, draft}` with `errors` filled otherwise.
  """
  @spec validate(t(), [ItemSupplierInfo.t()]) :: {:ok, t()} | {:error, t()}
  def validate(%__MODULE__{} = draft, infos) do
    touched = Enum.uniq(draft.adds ++ Map.keys(draft.values) ++ Map.keys(draft.custom))
    draft = Enum.reduce(touched, %{draft | errors: %{}}, &check_row(&2, &1, infos))
    if draft.errors == %{}, do: {:ok, draft}, else: {:error, draft}
  end

  # ── Applying ─────────────────────────────────────────────────────────

  @doc """
  Writes the draft for the item `item_uuid`, whose rows were `infos` when
  the draft was built. Returns the draft left over — empty when everything
  applied — and the failures as `{supplier_uuid, reason}`. A step that
  fails keeps its staged change, so a form that stays can show it and save
  again without repeating the steps that succeeded; a save that leaves the
  form (a new item, a move to another catalogue) can only report it.

  The primary the table showed (`primary/2`) is set explicitly at the end,
  not left to the context's promote-on-create: when an earlier step fails —
  a primary whose removal did not go through, so no new row was promoted —
  the item still ends with the primary the admin saw.
  """
  @spec apply(t(), String.t(), [ItemSupplierInfo.t()], [map()], keyword()) ::
          {t(), [{supplier_uuid(), atom()}]}
  def apply(%__MODULE__{} = draft, item_uuid, infos, all_suppliers, opts) do
    current = Map.new(infos, &{&1.supplier_uuid, &1})
    intended = primary(draft, infos)

    {draft, failures} =
      {%{draft | errors: %{}}, []}
      |> apply_removals(current, opts)
      |> apply_edits(current, opts)
      |> apply_adds(item_uuid, all_suppliers, opts)
      |> apply_primary(item_uuid, intended, opts)

    failures = Enum.reverse(failures)
    errors = Map.new(failures, fn {s, reason} -> {s, reason} end)

    {%{draft | errors: Map.filter(errors, fn {s, _} -> s in draft.adds or saved?(infos, s) end)},
     failures}
  end

  defp apply_removals({draft, failures}, current, opts) do
    Enum.reduce(draft.removed, {draft, failures}, fn supplier_uuid, {draft, failures} ->
      with %ItemSupplierInfo{} = info <- Map.get(current, supplier_uuid),
           {:error, reason} when reason != :not_current <- ItemSupplierInfos.delete(info, opts) do
        {draft, [{supplier_uuid, :save_failed} | failures]}
      else
        # Removed, or already gone — either way nothing is left to do.
        _ -> {forget(draft, supplier_uuid), failures}
      end
    end)
  end

  defp apply_edits({draft, failures}, current, opts) do
    touched =
      (Map.keys(draft.values) ++ Map.keys(draft.custom))
      |> Enum.uniq()
      |> Enum.reject(&(&1 in draft.adds or &1 in draft.removed))

    Enum.reduce(touched, {draft, failures}, &edit_step(&1, &2, current, opts))
  end

  defp edit_step(supplier_uuid, {draft, failures}, current, opts) do
    case Map.get(current, supplier_uuid) do
      # The row is gone — removed elsewhere since the form loaded.
      nil ->
        {forget(draft, supplier_uuid), failures}

      info ->
        values = Map.get(draft.values, supplier_uuid, %{})
        custom = Map.get(draft.custom, supplier_uuid)

        case edit_row(info, values, custom, opts) do
          :ok -> {forget(draft, supplier_uuid), failures}
          {:error, reason} -> {draft, [{supplier_uuid, reason} | failures]}
        end
    end
  end

  defp apply_adds({draft, failures}, item_uuid, all_suppliers, opts) do
    Enum.reduce(draft.adds, {draft, failures}, fn supplier_uuid, {draft, failures} ->
      values = Map.get(draft.values, supplier_uuid, %{})
      custom = Map.get(draft.custom, supplier_uuid, %{})

      case add_row(item_uuid, supplier_uuid, values, custom, all_suppliers, opts) do
        :ok ->
          {drop_add(draft, supplier_uuid), failures}

        # Someone else linked it meanwhile: the row is on the item now, so
        # the staged one goes — the reload shows the real one.
        {:error, :already_linked} ->
          {drop_add(draft, supplier_uuid), [{supplier_uuid, :already_linked} | failures]}

        {:error, reason} ->
          {draft, [{supplier_uuid, reason} | failures]}
      end
    end)
  end

  defp apply_primary({draft, failures}, _item_uuid, nil, _opts), do: {draft, failures}

  defp apply_primary({draft, failures}, item_uuid, supplier_uuid, opts) do
    rows = ItemSupplierInfos.list_for_item(item_uuid)

    case Enum.find(rows, &(&1.supplier_uuid == supplier_uuid)) do
      nil ->
        {%{draft | primary: nil}, failures}

      %{is_primary: true} ->
        {%{draft | primary: nil}, failures}

      info ->
        case ItemSupplierInfos.set_primary(info, opts) do
          {:ok, _} ->
            {%{draft | primary: nil}, failures}

          {:error, _} ->
            {%{draft | primary: supplier_uuid}, [{supplier_uuid, :primary_failed} | failures]}
        end
    end
  end

  # The terms and extra values go through a plain update — only when they
  # actually differ, since every update is an activity entry — and then
  # the price, which on a row that already had one is a revision (closes
  # the row, opens a successor), never an overwrite: that is what feeds
  # the Price History dialog.
  defp edit_row(info, values, custom, opts) do
    with {:ok, info} <- update_terms(info, values, custom, opts) do
      update_cost(info, values, opts)
    end
  end

  defp update_terms(info, values, custom, opts) do
    with {:ok, attrs} <- terms_attrs(info, values, custom) do
      if ItemSupplierInfo.changeset(info, attrs).changes == %{},
        do: {:ok, info},
        else: info |> ItemSupplierInfos.update(attrs, opts) |> as_result()
    end
  end

  defp terms_attrs(info, values, custom) do
    attrs = values |> Map.take(@term_keys) |> normalize_terms()

    case custom && Catalogue.cast_supplier_field_values(custom) do
      nil ->
        {:ok, attrs}

      {:ok, cast} ->
        {:ok,
         Map.put(attrs, "metadata", Catalogue.put_supplier_field_values(info.metadata, cast))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_cost(info, values, opts) do
    if Map.has_key?(values, "unit_cost") or Map.has_key?(values, "currency") do
      with {:ok, cost} <- cast_cost(Map.get(values, "unit_cost", decimal_text(info.unit_cost))),
           currency = values |> Map.get("currency", info.currency) |> normalize_currency(),
           {:ok, _row} <- info |> write_cost(cost, currency, opts) |> as_result() do
        :ok
      end
    else
      :ok
    end
  end

  defp write_cost(info, cost, currency, opts) do
    cond do
      same_cost?(cost, info.unit_cost) and currency == normalize_currency(info.currency) ->
        {:ok, info}

      is_nil(cost) or is_nil(info.unit_cost) ->
        ItemSupplierInfos.update(info, %{"unit_cost" => cost, "currency" => currency}, opts)

      true ->
        ItemSupplierInfos.revise_unit_cost(info, cost, Keyword.put(opts, :currency, currency))
    end
  end

  # A named refusal keeps its name; a changeset is a shape failure and
  # stays generic.
  defp as_result({:ok, row}), do: {:ok, row}
  defp as_result({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp as_result({:error, _changeset}), do: {:error, :save_failed}

  defp add_row(item_uuid, supplier_uuid, values, custom, all_suppliers, opts) do
    with {:ok, cost} <- cast_cost(Map.get(values, "unit_cost")),
         {:ok, custom} <- cast_custom(custom) do
      selected = Enum.find(all_suppliers, &(&1.uuid == supplier_uuid))

      attrs =
        values
        |> Map.take(@term_keys)
        |> normalize_terms()
        |> Map.merge(%{
          "unit_cost" => cost,
          "currency" => normalize_currency(Map.get(values, "currency")),
          "item_uuid" => item_uuid,
          "supplier_uuid" => supplier_uuid,
          # The picker mixes local and CRM suppliers; persist the source
          # of the chosen entry — a CRM party stored as "local" would
          # misroute the resolver and the audit task.
          "supplier_source" => if(selected, do: Atom.to_string(selected.source), else: "local"),
          "supplier_name_snapshot" => selected && selected.name,
          "metadata" => Catalogue.put_supplier_field_values(%{}, custom)
        })

      with {:ok, _info} <- attrs |> ItemSupplierInfos.create(opts) |> as_result(), do: :ok
    end
  end

  # ── Checks ───────────────────────────────────────────────────────────

  defp check_row(draft, supplier_uuid, infos) do
    info = Enum.find(infos, &(&1.supplier_uuid == supplier_uuid))
    values = Map.get(draft.values, supplier_uuid, %{})
    custom = Map.get(draft.custom, supplier_uuid)

    case row_error(values, custom, info) do
      nil -> %{draft | errors: Map.delete(draft.errors, supplier_uuid)}
      reason -> %{draft | errors: Map.put(draft.errors, supplier_uuid, reason)}
    end
  end

  defp row_error(values, custom, info) do
    base = info || %ItemSupplierInfo{}

    with {:ok, cost} <- cast_cost(Map.get(values, "unit_cost")),
         attrs =
           values
           |> Map.take(@term_keys)
           |> normalize_terms()
           |> Map.put("currency", normalize_currency(Map.get(values, "currency", base.currency)))
           |> put_cost(values, cost),
         :ok <- value_errors(ItemSupplierInfo.changeset(base, attrs)),
         {:ok, _} <- cast_custom(custom) do
      nil
    else
      {:error, reason} -> reason
    end
  end

  # A row whose price was not touched keeps its own.
  defp put_cost(attrs, values, cost) do
    if Map.has_key?(values, "unit_cost"), do: Map.put(attrs, "unit_cost", cost), else: attrs
  end

  # Only the fields the admin types; the changeset's other rules (the
  # item and supplier being set) are the context's business at save.
  defp value_errors(changeset) do
    case Keyword.take(changeset.errors, [
           :currency,
           :unit_cost,
           :supplier_sku,
           :lead_time_days,
           :min_order_qty
         ]) do
      [] -> :ok
      [{:currency, _} | _] -> {:error, :invalid_currency}
      [{:unit_cost, _} | _] -> {:error, :invalid_cost}
      _ -> {:error, :invalid_terms}
    end
  end

  defp cast_custom(nil), do: {:ok, %{}}
  defp cast_custom(custom) when custom == %{}, do: {:ok, %{}}
  defp cast_custom(custom), do: Catalogue.cast_supplier_field_values(custom)

  # `unit_cost` is a BUILT-IN entities field: cast through the same
  # pipeline an admin-defined field uses, so the value reaching the
  # NUMERIC(14,4) column is an exact Decimal. nil when blank.
  defp cast_cost(value) do
    case Catalogue.cast_supplier_builtin("unit_cost", value) do
      {:ok, cost} -> {:ok, cost}
      {:error, _reason} -> {:error, :invalid_cost}
    end
  end

  # `min_order_qty` is a free-decimal input: a typed "2,5" is "2.5".
  defp normalize_terms(attrs) do
    Map.new(attrs, fn
      {"min_order_qty", value} when is_binary(value) ->
        {"min_order_qty", String.replace(value, ",", ".")}

      pair ->
        pair
    end)
  end

  # The input is uppercase by CSS only — the submitted value keeps whatever
  # case was typed, and the schema's ^[A-Z]{3}$ would reject it.
  defp normalize_currency(value) when is_binary(value) do
    case value |> String.trim() |> String.upcase() do
      "" -> nil
      currency -> currency
    end
  end

  defp normalize_currency(_value), do: nil

  # ── Helpers ──────────────────────────────────────────────────────────

  defp changed?(draft, info) do
    supplier_uuid = info.supplier_uuid
    values = Map.get(draft.values, supplier_uuid, %{})

    cost_changed? =
      case cast_cost(Map.get(values, "unit_cost", decimal_text(info.unit_cost))) do
        {:ok, cost} -> not same_cost?(cost, info.unit_cost)
        {:error, _} -> true
      end

    # Both sides normalized: a stored "" and a blank input are the same.
    currency_changed? =
      normalize_currency(Map.get(values, "currency", info.currency)) !=
        normalize_currency(info.currency)

    cost_changed? or currency_changed? or terms_changed?(info, values) or
      custom_changed?(draft, info)
  end

  # Staged, not merely present: the row dialog seeds itself from the row
  # and Done sends that seed straight back, so a row reopened and closed
  # without an edit stages every term it holds. The same changeset
  # `update_terms/4` writes through decides here, so the badge means
  # exactly what a save would write.
  defp terms_changed?(info, values) do
    attrs = values |> Map.take(@term_keys) |> normalize_terms()
    ItemSupplierInfo.changeset(info, attrs).changes != %{}
  end

  # Nothing staged, or the same extra values the row already holds. A
  # typed value arrives as the string the input carried, so a field whose
  # stored value is not a string (a number, a date) still reads as
  # changed — conservative, and `update_terms/4` writes nothing either way.
  defp custom_changed?(draft, info) do
    case Map.fetch(draft.custom, info.supplier_uuid) do
      {:ok, custom} -> custom != Catalogue.supplier_field_values(info)
      :error -> false
    end
  end

  defp same_cost?(nil, nil), do: true
  defp same_cost?(%Decimal{} = a, %Decimal{} = b), do: Decimal.equal?(a, b)
  defp same_cost?(_a, _b), do: false

  defp editable?(draft, supplier_uuid, infos) do
    supplier_uuid in draft.adds or
      (saved?(infos, supplier_uuid) and supplier_uuid not in draft.removed)
  end

  defp saved?(infos, supplier_uuid), do: Enum.any?(infos, &(&1.supplier_uuid == supplier_uuid))

  # Clears a row's staged values and marks — not a staged primary, which
  # outlives an applied edit of the same row.
  defp forget(draft, supplier_uuid) do
    %{
      draft
      | values: Map.delete(draft.values, supplier_uuid),
        custom: Map.delete(draft.custom, supplier_uuid),
        removed: List.delete(draft.removed, supplier_uuid),
        errors: Map.delete(draft.errors, supplier_uuid)
    }
  end

  defp drop_add(draft, supplier_uuid) do
    draft
    |> Map.update!(:adds, &List.delete(&1, supplier_uuid))
    |> Map.update!(:values, &Map.delete(&1, supplier_uuid))
    |> Map.update!(:custom, &Map.delete(&1, supplier_uuid))
  end

  defp drop_primary(%{primary: supplier_uuid} = draft, supplier_uuid), do: %{draft | primary: nil}
  defp drop_primary(draft, _supplier_uuid), do: draft

  defp name(supplier_uuid, info, all_suppliers) do
    case Enum.find(all_suppliers, &(&1.uuid == supplier_uuid)) do
      nil -> (info && info.supplier_name_snapshot) || supplier_uuid
      supplier -> supplier.name
    end
  end

  # How a stored price shows in its input: no trailing zeros from the
  # column's scale (12.5000 is "12.5").
  defp decimal_text(nil), do: ""

  defp decimal_text(%Decimal{} = value),
    do: value |> Decimal.normalize() |> Decimal.to_string(:normal)
end
