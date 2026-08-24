defmodule PhoenixKitCatalogue do
  @moduledoc """
  Catalogue module for PhoenixKit.

  Manages product catalogues with categories and items.
  Designed for manufacturing companies (e.g., kitchen/furniture producers) that need
  to organize materials and components.

  Suppliers and manufacturers are NOT managed here: both are companies in the
  CRM module, holding the `supplier` / `manufacturer` role. This module
  keeps only the per-item sourcing facts (cost, SKU, lead time) and resolves the
  supplier's identity through `PhoenixKitCatalogue.Catalogue.Suppliers`.

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
  def version, do: "0.19.0"

  @impl PhoenixKit.Module
  def route_module, do: PhoenixKitCatalogue.Web.Routes

  @impl PhoenixKit.Module
  # Makes supplier comment threads deep-linkable from the Comments admin and
  # the Activity feed with NO host configuration: core discovers this
  # callback on every loaded module and registers the resolver itself. A
  # host's `config :phoenix_kit, :comment_resource_handlers` entry for the
  # same type is an override, not a requirement.
  def resource_links,
    do: %{PhoenixKitCatalogue.Catalogue.supplier_comment_resource_type() => __MODULE__}

  @doc """
  Resolver for supplier comment threads (`"catalogue_item_supplier"`): turns
  thread uuids into `%{uuid => %{title, path}}` chips, so a "he promised a
  discount" note links back to the item's Suppliers tab from the central
  Comments admin and the Activity feed.

  Registered automatically through `resource_links/0`. Paths are RAW (no URL
  prefix) — core applies the prefix/locale once at render.

  See `PhoenixKitCatalogue.Catalogue.SupplierComments` for the thread model.
  """
  @spec resolve_comment_resources([binary()]) :: %{binary() => map()}
  def resolve_comment_resources(uuids) when is_list(uuids),
    do: PhoenixKitCatalogue.Catalogue.resolve_supplier_comment_resources(uuids)

  @impl PhoenixKit.Module
  def css_sources, do: [:phoenix_kit_catalogue]

  @impl PhoenixKit.Module
  def children do
    # Registers the attribute-set deletion guard with entities at boot
    # (a set with item attachments cannot be deleted; temporary task —
    # runs once, exits), plus the PubSub subscriber that prunes item
    # attachments when a set blueprint is deleted out-of-band.
    #
    # SupplierFields registers its own guard under its own owner key —
    # its blueprint is NOT an attribute set and must not land in either
    # of the set registries above.
    [
      PhoenixKitCatalogue.Catalogue.AttributeSets,
      PhoenixKitCatalogue.Catalogue.AttributeSets.OrphanPruner,
      PhoenixKitCatalogue.Catalogue.SupplierFields
    ]
  end

  @impl PhoenixKit.Module
  def js_sources do
    [
      %{
        app: :phoenix_kit_catalogue,
        file: "static/assets/phoenix_kit_catalogue.js",
        global: "PhoenixKitCatalogueHooks"
      }
    ]
  end

  def ai_translatables do
    [
      {"catalogue", PhoenixKitCatalogue.AITranslatable},
      {"catalogue_category", PhoenixKitCatalogue.AITranslatable},
      {"catalogue_item", PhoenixKitCatalogue.AITranslatable},
      {"catalogue_attribute_group", PhoenixKitCatalogue.AITranslatable},
      {"catalogue_attribute", PhoenixKitCatalogue.AITranslatable},
      {"catalogue_attribute_value", PhoenixKitCatalogue.AITranslatable}
    ]
  end

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: module_key(),
      label: "Catalogue",
      icon: "hero-rectangle-stack",
      description: "Product catalogue management for items and categories"
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
        # subtab paths (attributes, import, events).
        #
        # Without this, hidden subtabs with literal `:uuid` segments
        # (e.g. "catalogue/:uuid/edit") never match a real URL, so the
        # parent "Catalogue" tab is the only thing that lights up on
        # detail/form pages — which looks wrong in the sidebar.
        match: {:regex, ~r"^/admin/catalogue(/(?!attributes|import|export|events|pdfs).*)?$"},
        parent: :admin_catalogue,
        live_view: {PhoenixKitCatalogue.Web.CataloguesLive, :index}
      },
      # Attributes tab — reusable attribute groups. `match: :prefix` keeps
      # it lit on the hidden new/edit subpages below.
      %Tab{
        id: :admin_catalogue_attributes,
        label: "Attributes",
        gettext_backend: PhoenixKitCatalogue.Gettext,
        gettext_domain: "default",
        icon: "hero-swatch",
        path: "catalogue/attributes",
        priority: 664,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        parent: :admin_catalogue,
        live_view: {PhoenixKitCatalogue.Web.CataloguesLive, :attribute_groups}
      },
      # Attribute group forms — hidden; declared here (long before the
      # `catalogue/:uuid` wildcard) so the literal "attributes" segment
      # wins the route match.
      %Tab{
        id: :admin_catalogue_attribute_group_new,
        label: "New Attribute Group",
        gettext_backend: PhoenixKitCatalogue.Gettext,
        gettext_domain: "default",
        icon: "hero-plus",
        path: "catalogue/attributes/new",
        priority: 668,
        level: :admin,
        permission: module_key(),
        parent: :admin_catalogue,
        visible: false,
        live_view: {PhoenixKitCatalogue.Web.AttributeGroupFormLive, :new}
      },
      %Tab{
        id: :admin_catalogue_attribute_group_edit,
        label: "Edit Attribute Group",
        gettext_backend: PhoenixKitCatalogue.Gettext,
        gettext_domain: "default",
        icon: "hero-pencil-square",
        path: "catalogue/attributes/:uuid/edit",
        priority: 669,
        level: :admin,
        permission: module_key(),
        parent: :admin_catalogue,
        visible: false,
        live_view: {PhoenixKitCatalogue.Web.AttributeGroupFormLive, :edit}
      },
      # Attribute SETS (2026-08-18 rework) — the "sets" literal segment
      # cannot collide with the group routes above: new/edit differ in
      # their tail segment and the set-edit path is one segment longer.
      %Tab{
        id: :admin_catalogue_attribute_set_new,
        label: "New Attribute Set",
        gettext_backend: PhoenixKitCatalogue.Gettext,
        gettext_domain: "default",
        icon: "hero-plus",
        path: "catalogue/attributes/sets/new",
        priority: 670,
        level: :admin,
        permission: module_key(),
        parent: :admin_catalogue,
        visible: false,
        live_view: {PhoenixKitCatalogue.Web.AttributeSetFormLive, :new}
      },
      %Tab{
        id: :admin_catalogue_attribute_set_edit,
        label: "Edit Attribute Set",
        gettext_backend: PhoenixKitCatalogue.Gettext,
        gettext_domain: "default",
        icon: "hero-pencil-square",
        path: "catalogue/attributes/sets/:uuid/edit",
        priority: 671,
        level: :admin,
        permission: module_key(),
        parent: :admin_catalogue,
        visible: false,
        live_view: {PhoenixKitCatalogue.Web.AttributeSetFormLive, :edit}
      },
      # Import tab
      %Tab{
        id: :admin_catalogue_import,
        label: "Import",
        gettext_backend: PhoenixKitCatalogue.Gettext,
        gettext_domain: "default",
        icon: "hero-arrow-down-tray",
        path: "catalogue/import",
        priority: 665,
        level: :admin,
        permission: module_key(),
        parent: :admin_catalogue,
        live_view: {PhoenixKitCatalogue.Web.ImportLive, :index}
      },
      # Export tab
      %Tab{
        id: :admin_catalogue_export,
        label: "Export",
        gettext_backend: PhoenixKitCatalogue.Gettext,
        gettext_domain: "default",
        icon: "hero-arrow-up-tray",
        path: "catalogue/export",
        priority: 666,
        level: :admin,
        permission: module_key(),
        parent: :admin_catalogue,
        live_view: {PhoenixKitCatalogue.Web.ExportLive, :index}
      },
      # Events tab
      %Tab{
        id: :admin_catalogue_events,
        label: "Events",
        gettext_backend: PhoenixKitCatalogue.Gettext,
        gettext_domain: "default",
        icon: "hero-clock",
        path: "catalogue/events",
        priority: 667,
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
