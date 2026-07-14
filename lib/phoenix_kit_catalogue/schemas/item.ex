defmodule PhoenixKitCatalogue.Schemas.Item do
  @moduledoc """
  Schema for catalogue items — individual products/materials with SKU and pricing.

  V102 added discount + smart-catalogue fields: `discount_percentage` (per-item
  override of the catalogue discount, NULL = inherit), and `default_value` /
  `default_unit` (smart-only fallbacks consumed by `CatalogueRule.effective/2`
  when a rule row leaves either leg NULL). The optional `:catalogue_rules`
  association mirrors the V102 rules table — only populated for items in a
  smart catalogue.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @statuses ~w(active inactive discontinued deleted)
  @units ~w(piece set pair sheet m2 running_meter)
  @default_units ~w(percent flat)

  @spec allowed_units() :: [String.t()]
  def allowed_units, do: @units

  @spec allowed_default_units() :: [String.t()]
  def allowed_default_units, do: @default_units

  @doc """
  Human-facing abbreviation for a measurement unit (`"piece"` → `"pc"`,
  `"m2"` → `"m²"`, `"running_meter"` → `"rm"`, …). Unknown strings pass
  through unchanged; `nil` and non-binaries collapse to `""`.

  Single source of truth for unit labels, shared by the items table and the
  item picker — each caller layers its own empty/placeholder handling on top.
  """
  @spec unit_label(term()) :: String.t()
  def unit_label(nil), do: ""
  def unit_label("piece"), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "pc")
  def unit_label("set"), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "set")
  def unit_label("pair"), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "pair")
  def unit_label("sheet"), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "sheet")
  def unit_label("m2"), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "m²")
  def unit_label("running_meter"), do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "rm")
  def unit_label(other) when is_binary(other), do: other
  def unit_label(_), do: ""

  schema "phoenix_kit_cat_items" do
    field(:name, :string)
    field(:description, :string)
    field(:sku, :string)
    field(:base_price, :decimal)
    # Per-item markup override. `nil` means "inherit from the parent
    # catalogue's markup_percentage" (the pre-V97 default behavior); any
    # Decimal (including 0) overrides the catalogue's value for this item.
    field(:markup_percentage, :decimal)
    # Per-item discount override. Same inherit-or-override semantics as
    # markup_percentage: `nil` = inherit the catalogue's discount, any
    # Decimal (including 0) overrides. Added in V102.
    field(:discount_percentage, :decimal)
    # Smart-catalogue defaults (V102): the fallback value + unit applied
    # when a CatalogueRule row has nil `value`/`unit`. Lets a user set
    # "5% across everything" once and only override specific catalogues.
    # Only meaningful when the parent catalogue is kind: "smart".
    field(:default_value, :decimal)
    field(:default_unit, :string)
    field(:unit, :string, default: "piece")
    field(:status, :string, default: "active")
    field(:position, :integer, default: 0)
    field(:data, :map, default: %{})

    belongs_to(:catalogue, PhoenixKitCatalogue.Schemas.Catalogue,
      foreign_key: :catalogue_uuid,
      references: :uuid,
      type: UUIDv7
    )

    belongs_to(:category, PhoenixKitCatalogue.Schemas.Category,
      foreign_key: :category_uuid,
      references: :uuid,
      type: UUIDv7
    )

    belongs_to(:manufacturer, PhoenixKitCatalogue.Schemas.Manufacturer,
      foreign_key: :manufacturer_uuid,
      references: :uuid,
      type: UUIDv7
    )

    # Default supplier to order this item from, independent of manufacturer —
    # set directly when there's no brand to resolve through (generic materials)
    # or when a manufacturer has several suppliers and one should always win.
    belongs_to(:primary_supplier, PhoenixKitCatalogue.Schemas.Supplier,
      foreign_key: :primary_supplier_uuid,
      references: :uuid,
      type: UUIDv7
    )

    has_many(:catalogue_rules, PhoenixKitCatalogue.Schemas.CatalogueRule,
      foreign_key: :item_uuid,
      references: :uuid
    )

    timestamps(type: :utc_datetime)
  end

  @required_fields [:name, :catalogue_uuid]
  @optional_fields [
    :description,
    :sku,
    :base_price,
    :markup_percentage,
    :discount_percentage,
    :default_value,
    :default_unit,
    :unit,
    :status,
    :position,
    :category_uuid,
    :manufacturer_uuid,
    :primary_supplier_uuid,
    :data
  ]

  @spec changeset(t() | Ecto.Changeset.t(t()), map()) :: Ecto.Changeset.t(t())
  def changeset(item, attrs) do
    item
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:sku, max: 100)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:unit, @units)
    |> validate_number(:base_price, greater_than_or_equal_to: 0)
    |> validate_number(:markup_percentage, greater_than_or_equal_to: 0)
    |> validate_number(:discount_percentage,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 100
    )
    |> validate_number(:default_value, greater_than_or_equal_to: 0)
    |> validate_inclusion(:default_unit, @default_units ++ [nil])
    |> foreign_key_constraint(:catalogue_uuid)
    |> foreign_key_constraint(:category_uuid)
    |> foreign_key_constraint(:primary_supplier_uuid)
  end

  @doc """
  Calculates the sale price for an item.

  `catalogue_markup` is the fallback markup used when the item has no
  override of its own. The item's `markup_percentage` takes precedence
  if set (including an explicit `0`, which means "sell at base price
  even if the catalogue has a markup"). A `nil` catalogue_markup with a
  `nil` item override returns the base price unchanged.

  Returns `nil` if the item has no base price. Both percentage values
  should be `Decimal`s (e.g., `Decimal.new("15.0")` for 15%).

  ## Examples

      # Item has no override — inherits catalogue's 20%
      Item.sale_price(%Item{base_price: Decimal.new("100"), markup_percentage: nil}, Decimal.new("20"))
      #=> Decimal.new("120.00")

      # Item explicitly overrides to 50% — catalogue markup is ignored
      Item.sale_price(%Item{base_price: Decimal.new("100"), markup_percentage: Decimal.new("50")}, Decimal.new("20"))
      #=> Decimal.new("150.00")

      # Item override of 0 means "sell at base price" even if catalogue marks up
      Item.sale_price(%Item{base_price: Decimal.new("100"), markup_percentage: Decimal.new("0")}, Decimal.new("20"))
      #=> Decimal.new("100.00")
  """
  @spec sale_price(t(), Decimal.t() | nil) :: Decimal.t() | nil
  def sale_price(%__MODULE__{base_price: nil}, _catalogue_markup), do: nil

  def sale_price(%__MODULE__{base_price: base_price} = item, catalogue_markup) do
    case effective_markup(item, catalogue_markup) do
      nil ->
        base_price

      markup ->
        multiplier = Decimal.add(Decimal.new("1"), Decimal.div(markup, Decimal.new("100")))
        base_price |> Decimal.mult(multiplier) |> Decimal.round(2)
    end
  end

  @doc """
  Returns the markup percentage that actually applies to an item — the
  item's own `markup_percentage` if set, otherwise `catalogue_markup`.

  `nil` on both sides means "no markup at all" and the item should be
  sold at its base price. Callers that only need to *display* which
  markup is active (without computing a price) can use this directly.
  """
  @spec effective_markup(t(), Decimal.t() | nil) :: Decimal.t() | nil
  def effective_markup(%__MODULE__{markup_percentage: nil}, catalogue_markup),
    do: catalogue_markup

  def effective_markup(%__MODULE__{markup_percentage: override}, _catalogue_markup),
    do: override

  @doc """
  Returns the discount percentage that actually applies to an item — the
  item's own `discount_percentage` if set, otherwise `catalogue_discount`.

  Mirrors `effective_markup/2`: `nil` on the item means "inherit the
  catalogue's discount", any Decimal (including `0`) overrides. `nil` on
  both sides means "no discount at all".

  Use this when you need to display which discount is active without
  computing the final price.
  """
  @spec effective_discount(t(), Decimal.t() | nil) :: Decimal.t() | nil
  def effective_discount(%__MODULE__{discount_percentage: nil}, catalogue_discount),
    do: catalogue_discount

  def effective_discount(%__MODULE__{discount_percentage: override}, _catalogue_discount),
    do: override

  @doc """
  Returns the final price for an item — `base_price` with the effective
  markup applied, then the effective discount subtracted.

  The chain is `base → markup → discount`:

      sale_price  = base_price * (1 + effective_markup   / 100)
      final_price = sale_price  * (1 -  effective_discount / 100)

  `catalogue_markup` and `catalogue_discount` are the fallbacks used when
  the item has no matching override of its own. `nil` on either side
  means "no markup / no discount on that leg"; the other leg still applies.

  Returns `nil` when `base_price` is `nil`. Result is rounded to 2
  decimal places. Percentage values should be `Decimal`s (e.g.
  `Decimal.new("15.0")`).

  ## Examples

      # 100 * 1.20 * 0.90 = 108.00
      Item.final_price(
        %Item{base_price: Decimal.new("100"), markup_percentage: nil, discount_percentage: nil},
        Decimal.new("20"),
        Decimal.new("10")
      )
      #=> Decimal.new("108.00")

      # Per-item discount 0 overrides a catalogue discount of 10 →
      # final equals sale_price
      Item.final_price(
        %Item{base_price: Decimal.new("100"), discount_percentage: Decimal.new("0")},
        Decimal.new("20"),
        Decimal.new("10")
      )
      #=> Decimal.new("120.00")
  """
  @spec final_price(t(), Decimal.t() | nil, Decimal.t() | nil) :: Decimal.t() | nil
  def final_price(%__MODULE__{base_price: nil}, _catalogue_markup, _catalogue_discount), do: nil

  def final_price(%__MODULE__{} = item, catalogue_markup, catalogue_discount) do
    with %Decimal{} = sale <- sale_price(item, catalogue_markup) do
      case effective_discount(item, catalogue_discount) do
        nil -> sale
        discount -> apply_discount(sale, discount)
      end
    end
  end

  @doc """
  Returns the Decimal amount subtracted by the discount for an item —
  i.e. `sale_price - final_price`. Useful for "You save $X" UI.

  Returns `nil` when `base_price` is `nil` or when no discount applies
  (both catalogue and item discount are `nil`).
  """
  @spec discount_amount(t(), Decimal.t() | nil, Decimal.t() | nil) :: Decimal.t() | nil
  def discount_amount(%__MODULE__{base_price: nil}, _catalogue_markup, _catalogue_discount),
    do: nil

  def discount_amount(%__MODULE__{} = item, catalogue_markup, catalogue_discount) do
    case effective_discount(item, catalogue_discount) do
      nil ->
        nil

      _discount ->
        with %Decimal{} = sale <- sale_price(item, catalogue_markup),
             %Decimal{} = final <- final_price(item, catalogue_markup, catalogue_discount) do
          Decimal.sub(sale, final) |> Decimal.round(2)
        end
    end
  end

  defp apply_discount(sale_price, discount) do
    multiplier = Decimal.sub(Decimal.new("1"), Decimal.div(discount, Decimal.new("100")))
    sale_price |> Decimal.mult(multiplier) |> Decimal.round(2)
  end
end
