defmodule PhoenixKitCatalogue.Web.Routes do
  @moduledoc """
  Route module for PhoenixKit Catalogue admin routes.

  Injects the stateless export-download GET route into the host app's
  router via the `route_module/0` callback on `PhoenixKit.Module`.
  Called at compile time by `PhoenixKit.Integration.compile_external_admin_routes/1`.
  """

  @doc "Admin routes for localized paths (with /:locale prefix)."
  def admin_locale_routes do
    quote do
      get(
        "/admin/catalogue/export/download",
        PhoenixKitCatalogue.Web.ExportController,
        :download,
        as: :catalogue_export_download_locale
      )
    end
  end

  @doc "Admin routes for non-localized paths."
  def admin_routes do
    quote do
      get(
        "/admin/catalogue/export/download",
        PhoenixKitCatalogue.Web.ExportController,
        :download,
        as: :catalogue_export_download
      )
    end
  end
end
