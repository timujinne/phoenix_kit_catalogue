defmodule PhoenixKitCatalogue.Catalogue.DeleteGuardsTest do
  @moduledoc """
  One boot task registers both of the catalogue's entities delete guards. On
  tim-dev and max-dev the two used to register from separate tasks, raced,
  and the attribute-set guard went missing, so every set delete failed closed
  with `:no_delete_guard`.
  """
  use PhoenixKitCatalogue.DataCase, async: false

  alias PhoenixKitCatalogue.Catalogue.DeleteGuards

  @owners ["catalogue", "catalogue_supplier"]

  setup do
    PhoenixKit.Settings.update_setting("entities_enabled", "true")
    on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)
    :ok
  end

  test "register/0 leaves both owners with a delete guard" do
    assert DeleteGuards.register() == :ok

    for owner <- ["catalogue", "catalogue_supplier"] do
      blueprint = %{
        uuid: Ecto.UUID.generate(),
        name: "guard-check",
        status: "published",
        settings: %{"managed_by" => owner}
      }

      refute PhoenixKitEntities.Managed.validate_delete(blueprint, on_behalf_of: owner) ==
               {:error, :no_delete_guard},
             "no delete guard registered for #{owner}"
    end
  end

  # PR #120 release review: the supplier-fields guard registered only while
  # entities was enabled, so a host that turned entities on after boot could
  # not delete that blueprint until a restart.
  test "register/0 registers both guards while entities is disabled" do
    # Entities keeps guards in :persistent_term: one shared map up to 0.4.14,
    # one key per owner since 0.4.15. Clear either form, then check through
    # the public `validate_delete/2` so the test doesn't pin the storage.
    saved = Enum.filter(:persistent_term.get(), fn {key, _} -> guard_term?(key) end)
    on_exit(fn -> Enum.each(saved, fn {key, value} -> :persistent_term.put(key, value) end) end)
    Enum.each(saved, fn {key, _} -> :persistent_term.erase(key) end)

    for owner <- @owners, do: assert(validate_delete(owner) == {:error, :no_delete_guard})

    PhoenixKit.Settings.update_setting("entities_enabled", "false")
    assert DeleteGuards.register() == :ok

    for owner <- @owners do
      refute validate_delete(owner) == {:error, :no_delete_guard},
             "no delete guard registered for #{owner}"
    end
  end

  test "the boot task is a one-shot child" do
    assert %{restart: :temporary, start: {Task, :start_link, [_fun]}} =
             DeleteGuards.child_spec([])
  end

  defp guard_term?({PhoenixKitEntities.Managed, :delete_guards}), do: true
  defp guard_term?({PhoenixKitEntities.Managed, :delete_guard, _owner}), do: true
  defp guard_term?(_key), do: false

  defp validate_delete(owner) do
    PhoenixKitEntities.Managed.validate_delete(
      %{
        uuid: Ecto.UUID.generate(),
        name: "guard-check",
        status: "published",
        settings: %{"managed_by" => owner}
      },
      on_behalf_of: owner
    )
  end
end
