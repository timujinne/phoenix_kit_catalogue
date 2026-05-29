defmodule PhoenixKitCatalogue.Test.Router do
  @moduledoc """
  Minimal Router used by the LiveView test suite. Routes match the URLs
  produced by `PhoenixKitCatalogue.Paths` so `live/2` calls in tests
  work with exactly the same URLs the LiveViews push themselves to.

  `PhoenixKit.Utils.Routes.path/1` defaults to no URL prefix when the
  phoenix_kit_settings table is unavailable, so the base is simply
  `/admin/catalogue`.
  """

  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, {PhoenixKitCatalogue.Test.Layouts, :root})
    plug(:protect_from_forgery)
  end

  # `PhoenixKit.Utils.Routes.path/1` prepends the default locale ("en")
  # to every admin path. Our scope must match so `live/2` in tests can
  # use the exact URL the LiveViews navigate to themselves.
  scope "/en/admin/catalogue", PhoenixKitCatalogue.Web do
    pipe_through(:browser)

    live_session :catalogue_test,
      on_mount: {PhoenixKitCatalogue.LiveCase, :assign_test_current_user},
      layout: {PhoenixKitCatalogue.Test.Layouts, :app} do
      # Catalogues / Manufacturers / Suppliers — CataloguesLive owns
      # all three tabs.
      live("/", CataloguesLive, :index)
      live("/manufacturers", CataloguesLive, :manufacturers)
      live("/suppliers", CataloguesLive, :suppliers)

      # Catalogue CRUD
      live("/new", CatalogueFormLive, :new)
      live("/:uuid/edit", CatalogueFormLive, :edit)

      # Category CRUD (scoped to catalogue)
      live("/:catalogue_uuid/categories/new", CategoryFormLive, :new)
      live("/categories/:uuid/edit", CategoryFormLive, :edit)

      # Item CRUD
      live("/:catalogue_uuid/items/new", ItemFormLive, :new)
      live("/items/:uuid/edit", ItemFormLive, :edit)

      # Manufacturer / Supplier CRUD
      live("/manufacturers/new", ManufacturerFormLive, :new)
      live("/manufacturers/:uuid/edit", ManufacturerFormLive, :edit)
      live("/suppliers/new", SupplierFormLive, :new)
      live("/suppliers/:uuid/edit", SupplierFormLive, :edit)

      # Import wizard (scoped to catalogue)
      live("/import", ImportLive, :index)

      # Events / activity feed
      live("/events", EventsLive, :index)

      # PDF library (literal "/pdfs" prefix; declared before the "/:uuid"
      # catch-all so it isn't swallowed by CatalogueDetailLive).
      live("/pdfs", PdfLibraryLive, :index)
      live("/pdfs/:uuid", PdfDetailLive, :show)

      # Catalogue detail (last so it doesn't swallow the static routes above)
      live("/:uuid", CatalogueDetailLive, :show)
    end
  end
end
