defmodule PhoenixKitCatalogue.Web.Routes do
  @moduledoc """
  Route module for PhoenixKit Catalogue admin routes.

  Injects the stateless export-download GET route into the host app's
  router via the `route_module/0` callback on `PhoenixKit.Module`, and the
  GET routes that send the module's old addresses — `/admin/catalogue`,
  anything under it, and `/admin/settings/catalogue` — on to the current
  ones (`Web.LegacyPathController`).
  Called at compile time by `PhoenixKit.Integration.compile_external_admin_routes/1`.
  """

  @doc "Admin routes for localized paths (with /:locale prefix)."
  def admin_locale_routes do
    quote do
      get(
        "/admin/catalogues/export/download",
        PhoenixKitCatalogue.Web.ExportController,
        :download,
        as: :catalogue_export_download_locale
      )

      get("/admin/catalogue", PhoenixKitCatalogue.Web.LegacyPathController, :forward,
        as: :catalogue_legacy_root_locale
      )

      get("/admin/catalogue/*rest", PhoenixKitCatalogue.Web.LegacyPathController, :forward,
        as: :catalogue_legacy_path_locale
      )

      get(
        "/admin/settings/catalogue",
        PhoenixKitCatalogue.Web.LegacyPathController,
        :forward,
        as: :catalogue_legacy_settings_locale
      )
    end
  end

  @doc "Admin routes for non-localized paths."
  def admin_routes do
    quote do
      get(
        "/admin/catalogues/export/download",
        PhoenixKitCatalogue.Web.ExportController,
        :download,
        as: :catalogue_export_download
      )

      get("/admin/catalogue", PhoenixKitCatalogue.Web.LegacyPathController, :forward,
        as: :catalogue_legacy_root
      )

      get("/admin/catalogue/*rest", PhoenixKitCatalogue.Web.LegacyPathController, :forward,
        as: :catalogue_legacy_path
      )

      get(
        "/admin/settings/catalogue",
        PhoenixKitCatalogue.Web.LegacyPathController,
        :forward,
        as: :catalogue_legacy_settings
      )
    end
  end
end
