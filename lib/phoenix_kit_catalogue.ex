defmodule PhoenixKitCatalogue do
  @moduledoc """
  Catalogue module for PhoenixKit.

  Manages product catalogues with manufacturers, suppliers, categories, and items.
  Designed for manufacturing companies (e.g., kitchen/furniture producers) that need
  to organize materials and components from multiple manufacturers and suppliers.

  ## Installation

  Add to your parent app's `mix.exs`:

      {:phoenix_kit_catalogue, path: "../phoenix_kit_catalogue"}

  Then `mix deps.get`. The module auto-discovers via beam scanning.
  Enable it in Admin > Modules.

  ## Structure

  - **Manufacturers** — companies that produce materials/components
  - **Suppliers** — companies that deliver materials (many-to-many with manufacturers)
  - **Catalogues** — top-level groupings (e.g., "Kitchen Furniture", "Plumbing")
  - **Categories** — subdivisions within a catalogue (e.g., "Cabinet Frames", "Doors")
  - **Items** — individual products with SKU, price, unit of measure
  """

  use PhoenixKit.Module

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Settings
  alias PhoenixKitCatalogue.Catalogue.ActivityLog

  # ===========================================================================
  # Required callbacks
  # ===========================================================================

  @impl PhoenixKit.Module
  def module_key, do: "catalogue"

  @impl PhoenixKit.Module
  def module_name, do: "Catalogue"

  @impl PhoenixKit.Module
  def enabled? do
    Settings.get_boolean_setting("catalogue_enabled", false)
  rescue
    _ -> false
  catch
    # Sandbox-owner-exited race: a non-DataCase test calls `enabled?/0`
    # right as a sibling test's owner pid has stopped. The pool checkout
    # exits before we even reach the `rescue` clause, so we have to
    # `catch :exit` separately. Returning `false` is correct — if we
    # can't read the setting, the module is effectively disabled.
    :exit, _ -> false
  end

  @impl PhoenixKit.Module
  def enable_system do
    result =
      Settings.update_boolean_setting_with_module("catalogue_enabled", true, module_key())

    ActivityLog.log(%{
      action: "catalogue_module.enabled",
      mode: "manual",
      resource_type: "module",
      metadata: %{"module_key" => module_key()}
    })

    result
  end

  @impl PhoenixKit.Module
  def disable_system do
    result =
      Settings.update_boolean_setting_with_module("catalogue_enabled", false, module_key())

    ActivityLog.log(%{
      action: "catalogue_module.disabled",
      mode: "manual",
      resource_type: "module",
      metadata: %{"module_key" => module_key()}
    })

    result
  end

  # ===========================================================================
  # Optional callbacks
  # ===========================================================================

  @impl PhoenixKit.Module
  def version, do: "0.2.0"

  @impl PhoenixKit.Module
  def css_sources, do: [:phoenix_kit_catalogue]

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: module_key(),
      label: "Catalogue",
      icon: "hero-rectangle-stack",
      description: "Product catalogue management for manufacturers and suppliers"
    }
  end

  @impl PhoenixKit.Module
  def admin_tabs do
    [
      # Main tab — parent container, redirects to first subtab.
      # match: :prefix keeps subtabs open on any /catalogue/* subpage;
      # highlight_with_subtabs: false suppresses parent highlight when a subtab is active.
      # Note: parent highlights on hidden subpages (e.g. /catalogue/new) — acceptable tradeoff.
      %Tab{
        id: :admin_catalogue,
        label: "Catalogue",
        gettext_backend: PhoenixKitCatalogue.Gettext,
        gettext_domain: "default",
        icon: "hero-rectangle-stack",
        path: "catalogue",
        priority: 660,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false,
        redirect_to_first_subtab: true,
        live_view: {PhoenixKitCatalogue.Web.CataloguesLive, :index}
      },
      # Subtabs — Catalogues, Manufacturers, Suppliers
      %Tab{
        id: :admin_catalogue_list,
        label: "Catalogues",
        gettext_backend: PhoenixKitCatalogue.Gettext,
        gettext_domain: "default",
        icon: "hero-rectangle-stack",
        path: "catalogue",
        priority: 661,
        level: :admin,
        permission: module_key(),
        # Regex match so this subtab stays highlighted on every page
        # that conceptually belongs to it — the catalogues list, the
        # catalogue detail/new/edit pages, the nested item/category
        # new/edit pages — while explicitly excluding the sibling
        # subtab paths (manufacturers, suppliers, import, events).
        #
        # Without this, hidden subtabs with literal `:uuid` segments
        # (e.g. "catalogue/:uuid/edit") never match a real URL, so the
        # parent "Catalogue" tab is the only thing that lights up on
        # detail/form pages — which looks wrong in the sidebar.
        match:
          {:regex, ~r"^/admin/catalogue(/(?!manufacturers|suppliers|import|events|pdfs).*)?$"},
        parent: :admin_catalogue,
        live_view: {PhoenixKitCatalogue.Web.CataloguesLive, :index}
      },
      %Tab{
        id: :admin_catalogue_manufacturers,
        label: "Manufacturers",
        gettext_backend: PhoenixKitCatalogue.Gettext,
        gettext_domain: "default",
        icon: "hero-building-office",
        path: "catalogue/manufacturers",
        priority: 662,
        level: :admin,
        permission: module_key(),
        parent: :admin_catalogue,
        live_view: {PhoenixKitCatalogue.Web.CataloguesLive, :manufacturers}
      },
      %Tab{
        id: :admin_catalogue_suppliers,
        label: "Suppliers",
        gettext_backend: PhoenixKitCatalogue.Gettext,
        gettext_domain: "default",
        icon: "hero-cube",
        path: "catalogue/suppliers",
        priority: 663,
        level: :admin,
        permission: module_key(),
        parent: :admin_catalogue,
        live_view: {PhoenixKitCatalogue.Web.CataloguesLive, :suppliers}
      },
      # Import tab
      %Tab{
        id: :admin_catalogue_import,
        label: "Import",
        gettext_backend: PhoenixKitCatalogue.Gettext,
        gettext_domain: "default",
        icon: "hero-arrow-up-tray",
        path: "catalogue/import",
        priority: 664,
        level: :admin,
        permission: module_key(),
        parent: :admin_catalogue,
        live_view: {PhoenixKitCatalogue.Web.ImportLive, :index}
      },
      # Events tab
      %Tab{
        id: :admin_catalogue_events,
        label: "Events",
        gettext_backend: PhoenixKitCatalogue.Gettext,
        gettext_domain: "default",
        icon: "hero-clock",
        path: "catalogue/events",
        priority: 665,
        level: :admin,
        permission: module_key(),
        parent: :admin_catalogue,
        live_view: {PhoenixKitCatalogue.Web.EventsLive, :index}
      },
      # PDF library — visible subtab. Sits last among the visible
      # subtabs (after Events, priority 665).
      %Tab{
        id: :admin_catalogue_pdfs,
        label: "PDFs",
        gettext_backend: PhoenixKitCatalogue.Gettext,
        gettext_domain: "default",
        icon: "hero-document-text",
        path: "catalogue/pdfs",
        priority: 690,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        parent: :admin_catalogue,
        live_view: {PhoenixKitCatalogue.Web.PdfLibraryLive, :index}
      },
      # PDF detail — hidden subtab; must be declared BEFORE
      # `catalogue/:uuid` so Phoenix matches the literal "pdfs" segment
      # first instead of treating it as a UUID.
      %Tab{
        id: :admin_catalogue_pdf_detail,
        label: "PDF",
        gettext_backend: PhoenixKitCatalogue.Gettext,
        gettext_domain: "default",
        icon: "hero-document-text",
        path: "catalogue/pdfs/:uuid",
        priority: 691,
        level: :admin,
        permission: module_key(),
        parent: :admin_catalogue,
        visible: false,
        live_view: {PhoenixKitCatalogue.Web.PdfDetailLive, :show}
      },
      # Static paths MUST come before wildcard :uuid paths
      # so Phoenix router matches them first.

      # Catalogue — static paths
      %Tab{
        id: :admin_catalogue_new,
        label: "New Catalogue",
        gettext_backend: PhoenixKitCatalogue.Gettext,
        gettext_domain: "default",
        icon: "hero-plus",
        path: "catalogue/new",
        priority: 666,
        level: :admin,
        permission: module_key(),
        parent: :admin_catalogue,
        visible: false,
        live_view: {PhoenixKitCatalogue.Web.CatalogueFormLive, :new}
      },
      %Tab{
        id: :admin_catalogue_manufacturer_new,
        label: "New Manufacturer",
        gettext_backend: PhoenixKitCatalogue.Gettext,
        gettext_domain: "default",
        icon: "hero-plus",
        path: "catalogue/manufacturers/new",
        priority: 667,
        level: :admin,
        permission: module_key(),
        parent: :admin_catalogue,
        visible: false,
        live_view: {PhoenixKitCatalogue.Web.ManufacturerFormLive, :new}
      },
      %Tab{
        id: :admin_catalogue_manufacturer_edit,
        label: "Edit Manufacturer",
        gettext_backend: PhoenixKitCatalogue.Gettext,
        gettext_domain: "default",
        icon: "hero-pencil-square",
        path: "catalogue/manufacturers/:uuid/edit",
        priority: 668,
        level: :admin,
        permission: module_key(),
        parent: :admin_catalogue,
        visible: false,
        live_view: {PhoenixKitCatalogue.Web.ManufacturerFormLive, :edit}
      },
      %Tab{
        id: :admin_catalogue_supplier_new,
        label: "New Supplier",
        gettext_backend: PhoenixKitCatalogue.Gettext,
        gettext_domain: "default",
        icon: "hero-plus",
        path: "catalogue/suppliers/new",
        priority: 669,
        level: :admin,
        permission: module_key(),
        parent: :admin_catalogue,
        visible: false,
        live_view: {PhoenixKitCatalogue.Web.SupplierFormLive, :new}
      },
      %Tab{
        id: :admin_catalogue_supplier_edit,
        label: "Edit Supplier",
        gettext_backend: PhoenixKitCatalogue.Gettext,
        gettext_domain: "default",
        icon: "hero-pencil-square",
        path: "catalogue/suppliers/:uuid/edit",
        priority: 670,
        level: :admin,
        permission: module_key(),
        parent: :admin_catalogue,
        visible: false,
        live_view: {PhoenixKitCatalogue.Web.SupplierFormLive, :edit}
      },
      # Categories — static edit path before catalogue :uuid wildcard
      %Tab{
        id: :admin_catalogue_category_edit,
        label: "Edit Category",
        gettext_backend: PhoenixKitCatalogue.Gettext,
        gettext_domain: "default",
        icon: "hero-pencil-square",
        path: "catalogue/categories/:uuid/edit",
        priority: 671,
        level: :admin,
        permission: module_key(),
        parent: :admin_catalogue,
        visible: false,
        live_view: {PhoenixKitCatalogue.Web.CategoryFormLive, :edit}
      },
      # Items — static edit path before catalogue :uuid wildcard
      %Tab{
        id: :admin_catalogue_item_edit,
        label: "Edit Item",
        gettext_backend: PhoenixKitCatalogue.Gettext,
        gettext_domain: "default",
        icon: "hero-pencil-square",
        path: "catalogue/items/:uuid/edit",
        priority: 672,
        level: :admin,
        permission: module_key(),
        parent: :admin_catalogue,
        visible: false,
        live_view: {PhoenixKitCatalogue.Web.ItemFormLive, :edit}
      },
      # Wildcard :uuid routes LAST — these catch anything not matched above
      %Tab{
        id: :admin_catalogue_detail,
        label: "Catalogue",
        gettext_backend: PhoenixKitCatalogue.Gettext,
        gettext_domain: "default",
        icon: "hero-rectangle-stack",
        path: "catalogue/:uuid",
        priority: 673,
        level: :admin,
        permission: module_key(),
        parent: :admin_catalogue,
        visible: false,
        live_view: {PhoenixKitCatalogue.Web.CatalogueDetailLive, :show}
      },
      %Tab{
        id: :admin_catalogue_edit,
        label: "Edit Catalogue",
        gettext_backend: PhoenixKitCatalogue.Gettext,
        gettext_domain: "default",
        icon: "hero-pencil-square",
        path: "catalogue/:uuid/edit",
        priority: 674,
        level: :admin,
        permission: module_key(),
        parent: :admin_catalogue,
        visible: false,
        live_view: {PhoenixKitCatalogue.Web.CatalogueFormLive, :edit}
      },
      %Tab{
        id: :admin_catalogue_category_new,
        label: "New Category",
        gettext_backend: PhoenixKitCatalogue.Gettext,
        gettext_domain: "default",
        icon: "hero-plus",
        path: "catalogue/:catalogue_uuid/categories/new",
        priority: 675,
        level: :admin,
        permission: module_key(),
        parent: :admin_catalogue,
        visible: false,
        live_view: {PhoenixKitCatalogue.Web.CategoryFormLive, :new}
      },
      %Tab{
        id: :admin_catalogue_item_new,
        label: "New Item",
        gettext_backend: PhoenixKitCatalogue.Gettext,
        gettext_domain: "default",
        icon: "hero-plus",
        path: "catalogue/:catalogue_uuid/items/new",
        priority: 676,
        level: :admin,
        permission: module_key(),
        parent: :admin_catalogue,
        visible: false,
        live_view: {PhoenixKitCatalogue.Web.ItemFormLive, :new}
      }
    ]
  end
end
