defmodule PhoenixKitCatalogue.Test.MediaHooks do
  @moduledoc """
  The attachment hook keys around a test. `mix.exs` installs the
  `PhoenixKitCatalogue.MediaFolders` defaults, so a test that sets or
  clears a key must put back what was there — `Application.delete_env/2`
  would leave every later test without the defaults.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @app :phoenix_kit_catalogue
  @keys [:attachments_parent_folder, :attachments_folder_name]

  @doc "Restores both hook keys, as they are now, when the test exits."
  def restore_on_exit do
    saved = Enum.map(@keys, &{&1, Application.fetch_env(@app, &1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {key, {:ok, value}} -> Application.put_env(@app, key, value)
        {key, :error} -> Application.delete_env(@app, key)
      end)
    end)
  end

  @doc """
  No hooks at all for this test — the host that opted out with both keys
  set to `nil`: folders at the media root under their deterministic names.
  """
  def without_hooks do
    restore_on_exit()
    Enum.each(@keys, &Application.put_env(@app, &1, nil))
  end
end
