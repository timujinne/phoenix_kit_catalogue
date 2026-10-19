defmodule PhoenixKitCatalogue.Schemas.ItemDependency do
  @moduledoc """
  One line of an item's dependencies: what the item needs, and how much.

  A row names exactly ONE target — a catalogue ("8 screws, any from this
  catalogue"), a category (the same, narrowed) or an item (that exact
  one) — with a positive `quantity` and an optional `note` ("pick by wood
  type"). The database holds the "exactly one" rule as a CHECK and every
  target as a real foreign key, so a permanent delete of the item or of a
  target removes the row; a soft trash leaves it in place.

  Purely informational: nothing in the module prices, counts or expands
  dependencies. Read and write them through
  `PhoenixKitCatalogue.Catalogue.list_item_dependencies/1` and
  `put_item_dependencies/3`.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  alias PhoenixKitCatalogue.Schemas.{Catalogue, Category, Item}

  @type kind :: :catalogue | :category | :item

  @type t :: %__MODULE__{
          uuid: Ecto.UUID.t() | nil,
          item_uuid: Ecto.UUID.t() | nil,
          target_catalogue_uuid: Ecto.UUID.t() | nil,
          target_category_uuid: Ecto.UUID.t() | nil,
          target_item_uuid: Ecto.UUID.t() | nil,
          quantity: Decimal.t() | nil,
          note: String.t() | nil,
          position: integer(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  # numeric(12,4): the column's own ceiling.
  @max_quantity Decimal.new("99999999.9999")
  @max_note_length 500

  @target_fields [:target_catalogue_uuid, :target_category_uuid, :target_item_uuid]

  schema "phoenix_kit_cat_item_dependencies" do
    field(:quantity, :decimal)
    field(:note, :string)
    field(:position, :integer, default: 0)

    belongs_to(:item, Item, foreign_key: :item_uuid, references: :uuid, type: UUIDv7)

    belongs_to(:target_catalogue, Catalogue,
      foreign_key: :target_catalogue_uuid,
      references: :uuid,
      type: UUIDv7
    )

    belongs_to(:target_category, Category,
      foreign_key: :target_category_uuid,
      references: :uuid,
      type: UUIDv7
    )

    belongs_to(:target_item, Item,
      foreign_key: :target_item_uuid,
      references: :uuid,
      type: UUIDv7
    )

    timestamps(type: :utc_datetime)
  end

  @doc """
  Whether a quantity fits the column: above zero, at most
  99 999 999.9999 and at most four decimal places (Postgres would round a
  fifth away silently).
  """
  @spec valid_quantity?(Decimal.t()) :: boolean()
  def valid_quantity?(%Decimal{} = quantity) do
    Decimal.compare(quantity, 0) == :gt and
      Decimal.compare(quantity, @max_quantity) != :gt and
      decimal_places(quantity) <= 4
  end

  defp validate_scale(:quantity, %Decimal{} = quantity) do
    if decimal_places(quantity) <= 4,
      do: [],
      else: [quantity: "has more than four decimal places"]
  end

  defp decimal_places(%Decimal{} = quantity) do
    case Decimal.normalize(quantity) do
      %Decimal{exp: exp} when exp < 0 -> -exp
      _ -> 0
    end
  end

  @doc "The longest note a dependency takes."
  @spec max_note_length() :: pos_integer()
  def max_note_length, do: @max_note_length

  @doc """
  Casts and checks one row: exactly one target, not the item itself, a
  quantity above zero with at most four decimal places, a note within
  `max_note_length/0`. The foreign keys and CHECKs map back to errors.
  """
  @spec changeset(t() | Ecto.Changeset.t(t()), map()) :: Ecto.Changeset.t(t())
  def changeset(dependency, attrs) do
    dependency
    |> cast(attrs, [:item_uuid, :quantity, :note, :position | @target_fields])
    |> validate_required([:item_uuid, :quantity])
    |> validate_number(:quantity, greater_than: 0, less_than_or_equal_to: @max_quantity)
    |> validate_change(:quantity, &validate_scale/2)
    |> validate_length(:note, max: @max_note_length)
    |> validate_one_target()
    |> validate_not_self()
    |> foreign_key_constraint(:item_uuid)
    |> foreign_key_constraint(:target_catalogue_uuid)
    |> foreign_key_constraint(:target_category_uuid)
    |> foreign_key_constraint(:target_item_uuid)
    |> check_constraint(:target_item_uuid,
      name: :phoenix_kit_cat_item_dependencies_not_self_check,
      message: "an item cannot depend on itself"
    )
  end

  @doc """
  Which kind of target a row names, and its uuid — `{:catalogue, uuid}`,
  `{:category, uuid}` or `{:item, uuid}`. `nil` for a row that names none
  (only an unsaved, invalid one can).
  """
  @spec target(t() | map()) :: {kind(), Ecto.UUID.t()} | nil
  def target(%{target_catalogue_uuid: uuid}) when not is_nil(uuid), do: {:catalogue, uuid}
  def target(%{target_category_uuid: uuid}) when not is_nil(uuid), do: {:category, uuid}
  def target(%{target_item_uuid: uuid}) when not is_nil(uuid), do: {:item, uuid}
  def target(_), do: nil

  @doc "The column a target kind is stored in."
  @spec target_field(kind()) :: atom()
  def target_field(:catalogue), do: :target_catalogue_uuid
  def target_field(:category), do: :target_category_uuid
  def target_field(:item), do: :target_item_uuid

  defp validate_one_target(changeset) do
    case Enum.count(@target_fields, &(get_field(changeset, &1) != nil)) do
      1 -> changeset
      0 -> add_error(changeset, :target_item_uuid, "choose what this depends on")
      _ -> add_error(changeset, :target_item_uuid, "a dependency names exactly one target")
    end
  end

  defp validate_not_self(changeset) do
    target = get_field(changeset, :target_item_uuid)

    if target != nil and target == get_field(changeset, :item_uuid) do
      add_error(changeset, :target_item_uuid, "an item cannot depend on itself")
    else
      changeset
    end
  end
end
