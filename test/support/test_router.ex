defmodule PhoenixKitCatalogue.Test.Router do
  @moduledoc """
  Minimal Router used by the LiveView test suite. Routes match the URLs
  produced by `PhoenixKitCatalogue.Paths` so `live/2` calls in tests
  work with exactly the same URLs the LiveViews push themselves to.

  `PhoenixKit.Utils.Routes.path/1` defaults to no URL prefix when the
  phoenix_kit_settings table is unavailable, so the base is simply
  `/admin/catalogues`.
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

  # Core's `Routes.path/1` leaves the locale segment out of an admin path
  # on a single-language site (`/admin/catalogues`) and adds it on a
  # multilingual one (`/en/admin/catalogues`). A LiveView navigates to
  # whichever it produces and a test may use either, so both prefixes sit
  # in ONE live session — a patch between them stays on the same view.
  live_session :catalogue_test,
    on_mount: {PhoenixKitCatalogue.LiveCase, :assign_test_current_user},
    layout: {PhoenixKitCatalogue.Test.Layouts, :app} do
    for prefix <- ["/en/admin/catalogues", "/admin/catalogues"] do
      scope prefix, PhoenixKitCatalogue.Web do
        pipe_through(:browser)

        live("/", CataloguesLive, :index)
        live("/attributes", CataloguesLive, :attribute_groups)

        # Attribute group CRUD (literal "/attributes" prefix; declared before
        # the "/:uuid" catch-all)
        live("/attributes/new", AttributeGroupFormLive, :new)
        live("/attributes/:uuid/edit", AttributeGroupFormLive, :edit)

        # Catalogue CRUD
        live("/new", CatalogueFormLive, :new)
        live("/:uuid/edit", CatalogueFormLive, :edit)

        # Category CRUD (scoped to catalogue)
        live("/:catalogue_uuid/categories/new", CategoryFormLive, :new)
        live("/categories/:uuid/edit", CategoryFormLive, :edit)

        # Item CRUD
        live("/:catalogue_uuid/items/new", ItemFormLive, :new)
        live("/items/:uuid/edit", ItemFormLive, :edit)

        # Import wizard (scoped to catalogue)
        live("/import", ImportLive, :index)
        live("/export", ExportLive, :index)

        # Events / activity feed
        live("/events", EventsLive, :index)

        # PDF library (literal "/pdfs" prefix; declared before the "/:uuid"
        # catch-all so it isn't swallowed by CatalogueDetailLive).
        live("/pdfs", PdfLibraryLive, :index)
        live("/pdfs/:uuid", PdfDetailLive, :show)

        # Translation freshness admin page (literal "/translations" prefix;
        # declared before the "/:uuid" catch-all for the same reason as PDFs).
        live("/translations", TranslationsLive, :index)

        # Catalogue detail (last so it doesn't swallow the static routes above)
        live("/:uuid", CatalogueDetailLive, :show)
      end
    end
  end

  # Settings → Catalogue. A separate scope because the page lives under
  # /admin/settings, not /admin/catalogues — the real route comes from the
  # module's `settings_tabs/0`, which resolves a bare "catalogues" path
  # against the settings prefix.
  live_session :catalogue_settings_test,
    on_mount: {PhoenixKitCatalogue.LiveCase, :assign_test_current_user},
    layout: {PhoenixKitCatalogue.Test.Layouts, :app} do
    for prefix <- ["/en/admin/settings", "/admin/settings"] do
      scope prefix, PhoenixKitCatalogue.Web do
        pipe_through(:browser)

        live("/catalogues", SettingsLive, :settings)
      end
    end
  end

  # Unaliased scope: the block above prefixes every module with
  # PhoenixKitCatalogue.Web, and the selector host lives under Test.
  scope "/test" do
    pipe_through(:browser)

    live_session :selector_test,
      on_mount: {PhoenixKitCatalogue.LiveCase, :assign_test_current_user},
      layout: {PhoenixKitCatalogue.Test.Layouts, :app} do
      # Test-only host for the ItemSelectorModal LiveComponent — asserts
      # the process-message contract a real host would consume.
      live("/selector-host", PhoenixKitCatalogue.Test.SelectorHostLive)
    end
  end
end
