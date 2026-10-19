defmodule PhoenixKitCatalogue.Web.DependencyDraft do
  @moduledoc """
  The item form's Dependencies tab, staged: the rows the admin is editing,
  written only when the item is saved (`Catalogue.put_item_dependencies/3`),
  like the supplier rows (`Web.SupplierDraft`).

  Pure — no queries. Each row carries what the tab shows (the target's
  kind, name, place and whether it is trashed or internal) and what the
  admin typed, as typed (`quantity` stays the string until `validate/1`
  reads it, so "2,5" or a half-typed "1." is never rewritten under the
  cursor). Rows are keyed by a draft-local `key`, never by the target: the
  form offers a target once, but a list saved before that rule (or written
  by an import) may still hold one twice.
  """

  alias PhoenixKit.Utils.Number
  alias PhoenixKitCatalogue.Schemas.{Catalogue, Category, Item, ItemDependency}

  # `dirty` — the admin changed something since the list was loaded; a
  # clean draft may be replaced by a fresher read without losing anything.
  # `hidden` — the internal categories and everything under them
  # (`Catalogue.internal_category_uuids/0`, read by the caller): a row
  # whose target is one, or is filed in one, is marked internal.
  defstruct rows: [], next_key: 1, dirty: false, hidden: %{}

  @type kind :: ItemDependency.kind()

  @type row :: %{
          key: String.t(),
          kind: kind(),
          uuid: String.t(),
          catalogue_uuid: String.t() | nil,
          name: String.t() | nil,
          place: String.t() | nil,
          trashed?: boolean(),
          internal?: boolean(),
          quantity: String.t(),
          note: String.t(),
          error: String.t() | nil
        }

  @type t :: %__MODULE__{
          rows: [row()],
          next_key: pos_integer(),
          dirty: boolean(),
          hidden: %{optional(String.t()) => true}
        }

  @doc """
  A draft holding the item's saved dependencies (`list_item_dependencies/1`
  rows, targets preloaded). `name_of` turns a record into the name the page
  shows (the form's locale).
  """
  @spec new([ItemDependency.t()], (struct() -> String.t() | nil), %{optional(String.t()) => true}) ::
          t()
  def new(dependencies \\ [], name_of \\ &default_name/1, hidden \\ %{}) do
    Enum.reduce(dependencies, %__MODULE__{hidden: hidden}, fn dependency, draft ->
      case saved_target(dependency) do
        nil ->
          draft

        {kind, record} ->
          put_row(draft, kind, record, name_of,
            quantity: format_quantity(dependency.quantity),
            note: dependency.note || ""
          )
      end
    end)
  end

  @doc """
  Adds a row for `record` (a catalogue, a category with its `:catalogue`
  loaded, or an item with its `:catalogue` and `:category` loaded).
  `opts` takes the typed `:quantity` (default `"1"`) and `:note` (default
  `""`), kept as typed like the rows' own fields.
  """
  @spec add(t(), kind(), struct(), (struct() -> String.t() | nil), keyword()) :: t()
  def add(%__MODULE__{} = draft, kind, record, name_of \\ &default_name/1, opts \\ [])
      when kind in [:catalogue, :category, :item] do
    draft
    |> put_row(kind, record, name_of,
      quantity: Keyword.get(opts, :quantity, "1"),
      note: Keyword.get(opts, :note, "")
    )
    |> Map.put(:dirty, true)
  end

  @doc """
  What is wrong with a typed quantity and note, by the rows' own rules:
  `nil` when both would save, else `"quantity"` or `"note"`.
  """
  @spec values_error(String.t() | nil, String.t() | nil) :: String.t() | nil
  def values_error(quantity, note), do: row_error(%{quantity: quantity, note: note || ""})

  @doc "Drops the row with `key`."
  @spec remove(t(), String.t()) :: t()
  def remove(%__MODULE__{} = draft, key) do
    case Enum.reject(draft.rows, &(&1.key == key)) do
      same when length(same) == length(draft.rows) -> draft
      rows -> %{draft | rows: rows, dirty: true}
    end
  end

  @doc """
  Puts the rows in the order of `keys` (what a drag-and-drop list reports).
  Keys it does not hold are ignored, and rows `keys` leaves out keep their
  order after the named ones, so a stale or partial list loses nothing.
  """
  @spec reorder(t(), [String.t()]) :: t()
  def reorder(%__MODULE__{rows: rows} = draft, keys) when is_list(keys) do
    by_key = Map.new(rows, &{&1.key, &1})
    named = keys |> Enum.uniq() |> Enum.flat_map(&List.wrap(by_key[&1]))
    reordered = named ++ (rows -- named)

    if reordered == rows, do: draft, else: %{draft | rows: reordered, dirty: true}
  end

  @doc """
  Takes what the admin typed — `%{key => %{"quantity" => …, "note" => …}}`
  as the tab's form posts it. Unknown keys are ignored; a row's error is
  cleared once its values change, and comes back on the next `validate/1`.
  """
  @spec put_values(t(), map()) :: t()
  def put_values(%__MODULE__{} = draft, values) when is_map(values) do
    rows = Enum.map(draft.rows, &put_typed(&1, Map.get(values, &1.key)))
    %{draft | rows: rows, dirty: draft.dirty or rows != draft.rows}
  end

  defp put_typed(row, %{} = typed) do
    quantity = typed_text(typed, "quantity", row.quantity)
    note = typed_text(typed, "note", row.note)

    if quantity == row.quantity and note == row.note,
      do: row,
      else: %{row | quantity: quantity, note: note, error: nil}
  end

  defp put_typed(row, _typed), do: row

  # Only text is typed text: a crafted map or list keeps what was there.
  defp typed_text(typed, key, current) do
    case Map.get(typed, key) do
      value when is_binary(value) -> value
      _ -> current
    end
  end

  @doc """
  Checks every row before anything is written. `{:ok, draft}` when all
  quantities read as numbers above zero and notes fit; `{:error, draft}`
  with each bad row's `error` set otherwise — the item form then blocks
  the whole save, as it does for a bad supplier value.
  """
  @spec validate(t()) :: {:ok, t()} | {:error, t()}
  def validate(%__MODULE__{} = draft) do
    rows = Enum.map(draft.rows, &%{&1 | error: row_error(&1)})
    draft = %{draft | rows: rows}

    if Enum.any?(rows, & &1.error), do: {:error, draft}, else: {:ok, draft}
  end

  @doc """
  Marks every row whose target no longer exists — `exists?.(kind, uuid)`
  answers false — with the `"gone"` error. `{:ok, draft}` when all are
  there, `{:error, draft}` otherwise.
  """
  @spec mark_gone(t(), (kind(), String.t() -> boolean())) :: {:ok, t()} | {:error, t()}
  def mark_gone(%__MODULE__{} = draft, exists?) when is_function(exists?, 2) do
    rows = Enum.map(draft.rows, &mark_row_gone(&1, exists?))
    draft = %{draft | rows: rows}
    if Enum.any?(rows, &(&1.error == "gone")), do: {:error, draft}, else: {:ok, draft}
  end

  defp mark_row_gone(row, exists?) do
    if exists?.(row.kind, row.uuid), do: row, else: %{row | error: "gone"}
  end

  @doc "The rows as `Catalogue.put_item_dependencies/3` specs, in order."
  @spec to_specs(t()) :: [map()]
  def to_specs(%__MODULE__{rows: rows}) do
    Enum.map(rows, fn row ->
      %{target: {row.kind, row.uuid}, quantity: parse_quantity(row.quantity), note: row.note}
    end)
  end

  @doc "How many rows the draft holds — the tab's count badge."
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{rows: rows}), do: length(rows)

  # ── internals ─────────────────────────────────────────────────────

  defp put_row(draft, kind, record, name_of, values) do
    row = %{
      key: Integer.to_string(draft.next_key),
      kind: kind,
      uuid: to_string(record.uuid),
      catalogue_uuid: catalogue_uuid(kind, record),
      name: name_of.(record),
      place: place(kind, record, name_of),
      trashed?: trashed?(kind, record),
      internal?: internal?(kind, record, draft.hidden),
      quantity: Keyword.fetch!(values, :quantity),
      note: Keyword.fetch!(values, :note),
      error: nil
    }

    %{draft | rows: draft.rows ++ [row], next_key: draft.next_key + 1}
  end

  defp catalogue_uuid(:catalogue, record), do: to_string(record.uuid)

  defp catalogue_uuid(_kind, record) do
    case Map.get(record, :catalogue_uuid) do
      nil -> nil
      uuid -> to_string(uuid)
    end
  end

  # The schema structs, not `%{}`: an association left unloaded is a
  # struct too, and would read as a target.
  defp saved_target(%ItemDependency{target_catalogue: %Catalogue{} = record}),
    do: {:catalogue, record}

  defp saved_target(%ItemDependency{target_category: %Category{} = record}),
    do: {:category, record}

  defp saved_target(%ItemDependency{target_item: %Item{} = record}), do: {:item, record}
  defp saved_target(_), do: nil

  # Where the target sits, for a reader who has only its name: a
  # category's catalogue, an item's catalogue and category.
  defp place(:catalogue, _record, _name_of), do: nil

  defp place(:category, record, name_of), do: loaded_name(Map.get(record, :catalogue), name_of)

  defp place(:item, record, name_of) do
    [Map.get(record, :catalogue), Map.get(record, :category)]
    |> Enum.map(&loaded_name(&1, name_of))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " › ")
    end
  end

  defp loaded_name(%{__struct__: _} = record, name_of) do
    if Ecto.assoc_loaded?(record), do: name_of.(record)
  end

  defp loaded_name(_, _name_of), do: nil

  # A row whose target is trashed — or sits in a trashed catalogue —
  # stays listed and says so.
  defp trashed?(kind, record) do
    record.status == "deleted" or
      (kind != :catalogue and match?(%{status: "deleted"}, Map.get(record, :catalogue)))
  end

  defp internal?(:category, record, hidden), do: Map.has_key?(hidden, to_string(record.uuid))

  defp internal?(:item, record, hidden) do
    case Map.get(record, :category_uuid) do
      uuid when is_binary(uuid) -> Map.has_key?(hidden, uuid)
      _ -> false
    end
  end

  defp internal?(:catalogue, _record, _hidden), do: false

  defp row_error(row) do
    case parse_quantity(row.quantity) do
      nil ->
        "quantity"

      quantity ->
        cond do
          not ItemDependency.valid_quantity?(quantity) -> "quantity"
          String.length(row.note) > ItemDependency.max_note_length() -> "note"
          true -> nil
        end
    end
  end

  defp parse_quantity(text) do
    case Number.parse_decimal(String.trim(text || "")) do
      {:ok, %Decimal{} = decimal} -> decimal
      _ -> nil
    end
  end

  defp format_quantity(nil), do: ""

  defp format_quantity(%Decimal{} = quantity),
    do: quantity |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp default_name(%{name: name}), do: name
  defp default_name(_), do: nil
end
