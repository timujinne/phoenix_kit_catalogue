defmodule PhoenixKitCatalogue.Schemas.Category do
  @moduledoc "Schema for categories within a catalogue."

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  alias PhoenixKitCatalogue.Schemas.Catalogue, as: CatalogueSchema

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @statuses ~w(active deleted)

  schema "phoenix_kit_cat_categories" do
    field(:name, :string)
    field(:description, :string)
    field(:position, :integer, default: 0)
    field(:status, :string, default: "active")
    field(:data, :map, default: %{})
    # Kept out of the embeddable pop-ups (`ItemPicker`, `ItemSelectorModal`,
    # `CatalogueBrowse`) with everything under it — subcategories and their
    # items — unless the host passes `include_internal`; the admin pages
    # show it like any other category. See `Catalogue.internal_category_uuids/0`.
    field(:internal, :boolean, default: false)
    # Free text for an AI that reads the catalogue (V5) — see
    # `PhoenixKitCatalogue.Schemas.Catalogue`'s field of the same name.
    field(:ai_notes, :string)
    # Per-language public URL slug (lang -> value), projected for
    # uniqueness by the `trg_cat_category_slugs` trigger into
    # `phoenix_kit_cat_category_slugs`. See `PhoenixKitCatalogue.Catalogue.Slugs`.
    field(:slug, :map, default: %{})

    belongs_to(:catalogue, PhoenixKitCatalogue.Schemas.Catalogue,
      foreign_key: :catalogue_uuid,
      references: :uuid,
      type: UUIDv7
    )

    # Nullable self-FK — NULL = root category. Cycle detection and
    # same-catalogue enforcement happen in the Catalogue context because
    # they require DB lookups; the changeset only catches self-parent.
    belongs_to(:parent, __MODULE__,
      foreign_key: :parent_uuid,
      references: :uuid,
      type: UUIDv7
    )

    has_many(:children, __MODULE__,
      foreign_key: :parent_uuid,
      references: :uuid
    )

    has_many(:items, PhoenixKitCatalogue.Schemas.Item,
      foreign_key: :category_uuid,
      references: :uuid
    )

    timestamps(type: :utc_datetime)
  end

  @required_fields [:name, :catalogue_uuid]
  @optional_fields [
    :description,
    :ai_notes,
    :internal,
    :position,
    :status,
    :data,
    :parent_uuid,
    :slug
  ]

  def changeset(category, attrs) do
    category
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> update_change(:data, &drop_nil_data_values/1)
    |> validate_required(@required_fields ++ [:internal])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:ai_notes,
      max: CatalogueSchema.ai_notes_max_length()
    )
    |> validate_inclusion(:status, @statuses)
    |> validate_not_self_parent()
    |> foreign_key_constraint(:parent_uuid)
    |> unique_constraint(:slug,
      name: "phoenix_kit_cat_category_slugs_pkey",
      message: "is already taken in this language"
    )
    |> unique_constraint(:data,
      name: "phoenix_kit_cat_categories_external_id_uniq",
      message: "external_id is already taken in this catalogue"
    )
  end

  # See the identical helper (and its full rationale) in
  # `PhoenixKitCatalogue.Schemas.Item.changeset/2` — `nil` is never a
  # legitimate stored value for a top-level `data` key; a caller that
  # wants one gone (see `Attachments.inject_attachment_data/2`) means
  # "this key doesn't exist", not "JSON null".
  defp drop_nil_data_values(data) when is_map(data),
    do: Map.reject(data, fn {_k, v} -> is_nil(v) end)

  defp drop_nil_data_values(other), do: other

  defp validate_not_self_parent(changeset) do
    uuid = get_field(changeset, :uuid)
    parent = get_field(changeset, :parent_uuid)

    if uuid != nil and parent != nil and uuid == parent do
      add_error(changeset, :parent_uuid, "category cannot be its own parent")
    else
      changeset
    end
  end
end
