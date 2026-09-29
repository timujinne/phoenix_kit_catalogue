defmodule PhoenixKitCatalogue.Schemas.Catalogue do
  @moduledoc "Schema for catalogues — top-level groupings (e.g., Kitchen Furniture, Plumbing)."

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @statuses ~w(active archived deleted)
  @kinds ~w(standard smart)
  # Mirrors the V4 CHECK; `Item.allowed_item_types/0` is the same list.
  @item_types ~w(goods service)

  def allowed_kinds, do: @kinds

  schema "phoenix_kit_cat_catalogues" do
    field(:name, :string)
    field(:description, :string)
    field(:kind, :string, default: "standard")
    # The type this catalogue's items take unless they name their own —
    # see `Item.effective_type/2`. Independent of `kind`: smart is how an
    # item is priced, service is what it is.
    field(:item_type, :string, default: "goods")
    field(:markup_percentage, :decimal, default: Decimal.new("0"))
    field(:discount_percentage, :decimal, default: Decimal.new("0"))
    field(:status, :string, default: "active")
    field(:position, :integer, default: 0)
    field(:data, :map, default: %{})

    # Nullable folder home — NULL = unfiled (root). Folders are module-global
    # (see PhoenixKitCatalogue.Schemas.Folder); ON DELETE SET NULL at the DB
    # level so removing a folder unfiles its catalogues rather than deleting.
    belongs_to(:folder, PhoenixKitCatalogue.Schemas.Folder,
      foreign_key: :folder_uuid,
      references: :uuid,
      type: UUIDv7
    )

    has_many(:categories, PhoenixKitCatalogue.Schemas.Category,
      foreign_key: :catalogue_uuid,
      references: :uuid
    )

    timestamps(type: :utc_datetime)
  end

  @required_fields [:name]
  @optional_fields [
    :description,
    :kind,
    :item_type,
    :markup_percentage,
    :discount_percentage,
    :status,
    :position,
    :data,
    :folder_uuid
  ]

  def changeset(catalogue, attrs) do
    catalogue
    |> cast(attrs, @required_fields ++ @optional_fields)
    # The column is NOT NULL; `cast` maps "" to the default, this guards an explicit nil.
    |> validate_required(@required_fields ++ [:item_type])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:item_type, @item_types)
    |> validate_number(:markup_percentage,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 1000
    )
    |> validate_number(:discount_percentage,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 100
    )
    |> foreign_key_constraint(:folder_uuid)
  end
end
