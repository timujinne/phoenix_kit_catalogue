defmodule PhoenixKitCatalogue.Schemas.ItemSupplierInfo do
  @moduledoc """
  Schema for per-supplier sourcing info on a catalogue item — SKU, unit
  cost, currency, lead time, and minimum order quantity.

  `item_uuid` is a real FK (`ON DELETE CASCADE` in V144). `supplier_uuid`
  is a **soft ref, no FK** — it resolves to a local `cat_supplier` or a
  federated CRM party via
  `PhoenixKitCatalogue.Catalogue.Suppliers.resolve_supplier/1`.

  At most one row per item may have `is_primary: true`, enforced by a
  partial unique index (`item_uuid` `WHERE is_primary`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_cat_item_supplier_info" do
    belongs_to(:item, PhoenixKitCatalogue.Schemas.Item,
      foreign_key: :item_uuid,
      references: :uuid,
      define_field: false
    )

    field(:item_uuid, UUIDv7)
    field(:supplier_uuid, UUIDv7)
    field(:supplier_sku, :string)
    field(:supplier_name_snapshot, :string)
    field(:unit_cost, :decimal)
    field(:currency, :string)
    field(:lead_time_days, :integer)
    field(:min_order_qty, :decimal)
    field(:is_primary, :boolean, default: false)
    field(:valid_from, :date)
    field(:valid_to, :date)
    field(:position, :integer, default: 0)
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime)
  end

  @required_fields [:item_uuid, :supplier_uuid]
  @optional_fields [
    :supplier_sku,
    :supplier_name_snapshot,
    :unit_cost,
    :currency,
    :lead_time_days,
    :min_order_qty,
    :is_primary,
    :valid_from,
    :valid_to,
    :position
  ]

  @doc """
  Builds a changeset. `metadata` is intentionally excluded from the
  castable field list — it's only ever set programmatically by the
  context, never from raw (e.g. LiveView form) params.
  """
  @spec changeset(t() | Ecto.Changeset.t(t()), map()) :: Ecto.Changeset.t(t())
  def changeset(item_supplier_info, attrs) do
    item_supplier_info
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:supplier_sku, max: 100)
    |> validate_length(:supplier_name_snapshot, max: 255)
    |> validate_length(:currency, is: 3)
    |> validate_number(:unit_cost, greater_than_or_equal_to: 0)
    |> validate_number(:min_order_qty, greater_than_or_equal_to: 0)
    |> validate_number(:lead_time_days, greater_than_or_equal_to: 0)
    |> validate_valid_to()
    |> foreign_key_constraint(:item_uuid)
    |> unique_constraint(:is_primary,
      name: :phoenix_kit_cat_item_supplier_info_primary_uniq,
      message: "only one supplier can be marked primary per item"
    )
  end

  defp validate_valid_to(changeset) do
    valid_from = get_field(changeset, :valid_from)
    valid_to = get_field(changeset, :valid_to)

    if valid_from && valid_to && Date.compare(valid_to, valid_from) == :lt do
      add_error(changeset, :valid_to, "must be on or after valid_from")
    else
      changeset
    end
  end
end
