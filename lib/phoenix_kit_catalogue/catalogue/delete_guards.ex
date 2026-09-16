defmodule PhoenixKitCatalogue.Catalogue.DeleteGuards do
  @moduledoc """
  Registers the catalogue's entities delete guards at boot, one after the
  other, from a single task.

  The attribute sets (owner `"catalogue"`) and the supplier fields (owner
  `"catalogue_supplier"`) each own a managed entities blueprint, and entities
  refuses to delete a managed blueprint whose owner has no registered guard.
  Registered from two separate boot tasks, the two registrations raced on
  entities releases that keep every guard in one shared map: the later write
  dropped the other owner's guard, and every delete of that owner's
  blueprints then failed closed with `:no_delete_guard`. One task registering
  both in turn keeps them apart on any entities version.
  """

  alias PhoenixKitCatalogue.Catalogue.{AttributeSets, SupplierFields}

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {Task, :start_link, [&__MODULE__.register/0]},
      restart: :temporary
    }
  end

  @doc "Registers the attribute-set guard, then the supplier-fields guard."
  @spec register() :: :ok
  def register do
    :ok = AttributeSets.register_deletion_guard()
    :ok = SupplierFields.startup()
  end
end
