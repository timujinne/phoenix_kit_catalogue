defmodule PhoenixKitCatalogue.Web.Settings do
  @moduledoc """
  Read/write helpers for the catalogue's operational settings — the
  AI-translation sweep the `PhoenixKitCatalogue.Workers.TranslationSweepWorker`
  reads on every tick, and the admin-list preferences the web layer reads at
  render time.

  `PhoenixKitCatalogue.Web.SettingsLive` (Settings → Catalogue) is the page
  that writes them. It arrived late: the sweep keys shipped with no UI at all,
  so turning the sweep on was an operator call into `update_*` and nobody
  could see it was off (boss via Max, 2026-09-21).

  Kept as a thin module rather than folding the keys into
  `PhoenixKitCatalogue` itself: the worker and the templates only ever read,
  the settings page only ever writes, and neither needs the other's concerns.

  | key                                            | type | default        |
  |-------------------------------------------------|------|----------------|
  | `catalogue_row_context_menu_enabled`             | bool | `true`         |
  | `catalogue_item_seo_fields_visible`              | bool | `false`        |
  | `catalogue_translation_sweep_enabled`            | bool | `false`        |
  | `catalogue_translation_sweep_interval_minutes`   | int  | `60`           |
  | `catalogue_translation_sweep_langs`              | json | see below      |
  | `catalogue_translation_sweep_max_per_run`        | int  | `200`          |

  `catalogue_translation_sweep_langs` defaults to every enabled language
  except the primary one — computed at read time (not stored) so a language
  toggled on/off in the languages module is picked up without a settings
  write. Stored as `%{"codes" => [...]}` rather than a bare JSON array:
  `PhoenixKit.Settings`'s `value_json` column is an Ecto `:map`, which
  rejects a top-level list.
  """

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitCatalogue.Workers.TranslationSweepWorker

  @module_key "catalogue"

  @context_menu_key "catalogue_row_context_menu_enabled"
  @seo_fields_key "catalogue_item_seo_fields_visible"

  @enabled_key "catalogue_translation_sweep_enabled"
  @interval_key "catalogue_translation_sweep_interval_minutes"
  @langs_key "catalogue_translation_sweep_langs"
  @max_per_run_key "catalogue_translation_sweep_max_per_run"

  @default_interval_minutes 60
  @default_max_per_run 200

  @doc """
  Does a right-click on an admin list row open that row's menu at the pointer?

  Default `true` — the gesture is what a desktop user expects of a list, and
  a row that offers nothing on right-click reads as unfinished. Off leaves
  the browser's own menu in place everywhere (Copy, Inspect, Open in new
  tab), which is the reason to want it off.

  Read at render time by the row components, which simply omit the
  `data-row-menu-context` attribute when it is false — so turning it off
  removes the wiring rather than disabling it in the browser.
  """
  @spec context_menu_enabled?() :: boolean()
  def context_menu_enabled?, do: Settings.get_boolean_setting(@context_menu_key, true)

  @doc """
  Does the item form show its URL slug, SEO title and SEO description?

  Default `false`: the current client has no use for them and they crowd
  the form (boss via Max, 2026-09-21: "hidden for now"). Hidden is not
  gone — the form still carries their stored values, so a save keeps them,
  and turning this on brings the fields back with their contents.
  """
  @spec seo_fields_visible?() :: boolean()
  def seo_fields_visible?, do: Settings.get_boolean_setting(@seo_fields_key, false)

  @doc "Shows or hides the item form's slug and SEO fields."
  @spec update_seo_fields_visible(boolean()) :: {:ok, struct()} | {:error, term()}
  def update_seo_fields_visible(visible?) when is_boolean(visible?) do
    Settings.update_boolean_setting_with_module(@seo_fields_key, visible?, @module_key)
  end

  @doc "Turns the right-click row menu on or off."
  @spec update_context_menu_enabled(boolean()) :: {:ok, struct()} | {:error, term()}
  def update_context_menu_enabled(enabled?) when is_boolean(enabled?) do
    Settings.update_boolean_setting_with_module(@context_menu_key, enabled?, @module_key)
  end

  @doc "Is the automatic sweep enabled?"
  @spec sweep_enabled?() :: boolean()
  def sweep_enabled?, do: Settings.get_boolean_setting(@enabled_key, false)

  @doc """
  Toggles the automatic sweep. Flipping it ON seeds the sweep's
  self-rescheduling chain (`TranslationSweepWorker.ensure_scheduled/0`) —
  the boot-time bootstrap only seeds it when already enabled (additive
  for hosts that never opt in), so this write is what starts the chain
  the first time an operator turns the sweep on.
  """
  @spec update_sweep_enabled(boolean()) :: {:ok, struct()} | {:error, term()}
  def update_sweep_enabled(enabled?) when is_boolean(enabled?) do
    with {:ok, setting} <-
           Settings.update_boolean_setting_with_module(@enabled_key, enabled?, @module_key) do
      if enabled?, do: TranslationSweepWorker.ensure_scheduled()
      {:ok, setting}
    end
  end

  @doc "Minutes between sweep ticks."
  @spec sweep_interval_minutes() :: pos_integer()
  def sweep_interval_minutes do
    Settings.get_integer_setting(@interval_key, @default_interval_minutes)
  end

  @doc "Sets the sweep interval, in minutes."
  @spec update_sweep_interval_minutes(pos_integer()) :: {:ok, struct()} | {:error, term()}
  def update_sweep_interval_minutes(minutes) when is_integer(minutes) and minutes > 0 do
    Settings.update_setting_with_module(@interval_key, Integer.to_string(minutes), @module_key)
  end

  @doc """
  Target languages the sweep considers. Defaults to every enabled language
  except the primary one when nothing is stored; a stored list is
  intersected with the enabled languages, so a language disabled after
  the setting was written stops receiving sweep jobs — the same check the
  Translations page applies to a manual Translate.
  """
  @spec sweep_langs() :: [String.t()]
  def sweep_langs do
    case Settings.get_json_setting(@langs_key) do
      %{"codes" => codes} when is_list(codes) ->
        enabled = Multilang.enabled_languages()
        Enum.filter(codes, &(is_binary(&1) and &1 in enabled))

      _ ->
        default_sweep_langs()
    end
  end

  @doc "Sets the sweep's target languages."
  @spec update_sweep_langs([String.t()]) :: {:ok, struct()} | {:error, term()}
  def update_sweep_langs(langs) when is_list(langs) do
    Settings.update_json_setting_with_module(@langs_key, %{"codes" => langs}, @module_key)
  end

  @doc "Maximum number of translation jobs one sweep tick enqueues."
  @spec sweep_max_per_run() :: pos_integer()
  def sweep_max_per_run do
    Settings.get_integer_setting(@max_per_run_key, @default_max_per_run)
  end

  @doc "Sets the per-tick enqueue cap."
  @spec update_sweep_max_per_run(pos_integer()) :: {:ok, struct()} | {:error, term()}
  def update_sweep_max_per_run(n) when is_integer(n) and n > 0 do
    Settings.update_setting_with_module(@max_per_run_key, Integer.to_string(n), @module_key)
  end

  defp default_sweep_langs do
    Multilang.enabled_languages() -- [Multilang.primary_language()]
  end
end
