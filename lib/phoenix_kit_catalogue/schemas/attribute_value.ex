defmodule PhoenixKitCatalogue.Schemas.AttributeValue do
  @moduledoc """
  Schema for values within an attribute ("White", "Oak", "Anthracite").

  `key` is a stable slug unique within its attribute — generated once by
  the context, never cast on update. `value` holds the primary-language
  display text; other languages live in `data`.

  `is_default` is explicit — display order and commercial default are
  independent (values may sort alphabetically while Oak is the standard).
  A partial unique index allows at most one default per attribute; the
  context flips defaults inside a transaction (unset-then-set).
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @statuses ~w(active archived)

  schema "phoenix_kit_cat_attribute_values" do
    field(:key, :string)
    field(:value, :string)
    field(:data, :map, default: %{})
    field(:is_default, :boolean, default: false)
    field(:status, :string, default: "active")
    field(:position, :integer, default: 0)

    belongs_to(:attribute, PhoenixKitCatalogue.Schemas.Attribute,
      foreign_key: :attribute_uuid,
      references: :uuid,
      type: UUIDv7
    )

    timestamps(type: :utc_datetime)
  end

  # `is_default` is deliberately NOT castable in either changeset: a forged
  # payload could otherwise bypass the unset-then-set transaction in
  # `Attributes.set_default_value/1` and trip the partial unique index.
  # Default flips go through that context function only.
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t(t())
  def create_changeset(value, attrs) do
    value
    |> cast(attrs, [:attribute_uuid, :key, :value, :data, :status, :position])
    |> validate_required([:attribute_uuid, :key, :value])
    |> shared_validations()
    |> validate_format(:key, ~r/^[a-z0-9][a-z0-9_-]*$/)
    |> validate_length(:key, max: 100)
    |> unique_constraint(:key, name: :phoenix_kit_cat_attribute_values_attr_key_index)
    |> foreign_key_constraint(:attribute_uuid)
  end

  # `key` is deliberately not castable after creation.
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t(t())
  def update_changeset(value, attrs) do
    value
    |> cast(attrs, [:value, :data, :status, :position])
    |> validate_required([:value])
    |> shared_validations()
  end

  defp shared_validations(changeset) do
    changeset
    |> validate_length(:value, min: 1, max: 255)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:is_default, name: :phoenix_kit_cat_attribute_values_default_index)
  end
end
