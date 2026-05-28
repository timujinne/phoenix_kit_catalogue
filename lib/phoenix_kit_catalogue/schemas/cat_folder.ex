defmodule PhoenixKitCatalogue.Schemas.Folder do
  @moduledoc """
  Schema for catalogue folders — a nesting layer for organizing catalogues
  on the admin index. Folders are module-global (not scoped to a catalogue)
  and are unrelated to the media-folder system.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @statuses ~w(active deleted)

  schema "phoenix_kit_cat_folders" do
    field(:name, :string)
    field(:position, :integer, default: 0)
    field(:status, :string, default: "active")
    field(:data, :map, default: %{})

    # Nullable self-FK — NULL = root folder. Cycle detection happens in the
    # Catalogue context (needs DB lookups); the changeset only catches the
    # direct self-parent case.
    belongs_to(:parent, __MODULE__,
      foreign_key: :parent_uuid,
      references: :uuid,
      type: UUIDv7
    )

    has_many(:children, __MODULE__,
      foreign_key: :parent_uuid,
      references: :uuid
    )

    has_many(:catalogues, PhoenixKitCatalogue.Schemas.Catalogue,
      foreign_key: :folder_uuid,
      references: :uuid
    )

    timestamps(type: :utc_datetime)
  end

  @required_fields [:name]
  @optional_fields [:position, :status, :data, :parent_uuid]

  def changeset(folder, attrs) do
    folder
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_inclusion(:status, @statuses)
    |> validate_not_self_parent()
    |> foreign_key_constraint(:parent_uuid)
  end

  defp validate_not_self_parent(changeset) do
    uuid = get_field(changeset, :uuid)
    parent = get_field(changeset, :parent_uuid)

    if uuid != nil and parent != nil and uuid == parent do
      add_error(changeset, :parent_uuid, "folder cannot be its own parent")
    else
      changeset
    end
  end
end
