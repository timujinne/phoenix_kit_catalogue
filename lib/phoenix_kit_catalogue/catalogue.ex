defmodule PhoenixKitCatalogue.Catalogue do
  @moduledoc """
  Context module for managing catalogues, manufacturers, suppliers, categories, and items.

  ## Soft-Delete System

  Catalogues, categories, and items support soft-delete via a `status` field set to `"deleted"`.
  Manufacturers and suppliers use hard-delete only (they are reference data).

  ### Cascade behaviour

  **Downward cascade on trash/permanently_delete:**
  - Trashing a catalogue → trashes all its categories and their items
  - Trashing a category → trashes all its items
  - Permanently deleting follows the same cascade but removes from DB

  **Upward cascade on restore:**
  - Restoring an item → restores its parent category if deleted
  - Restoring a category → restores its parent catalogue if deleted, plus all items

  All cascading operations are wrapped in database transactions.

  ## Usage from IEx

      alias PhoenixKitCatalogue.Catalogue

      # Create a full hierarchy
      {:ok, cat} = Catalogue.create_catalogue(%{name: "Kitchen"})
      {:ok, category} = Catalogue.create_category(%{name: "Frames", catalogue_uuid: cat.uuid})
      {:ok, item} = Catalogue.create_item(%{name: "Oak Panel", category_uuid: category.uuid, base_price: 25.50})

      # Soft-delete and restore
      {:ok, _} = Catalogue.trash_catalogue(cat)   # cascades to category + item
      {:ok, _} = Catalogue.restore_catalogue(cat)  # cascades back

      # Move operations
      {:ok, _} = Catalogue.move_category_to_catalogue(category, other_catalogue_uuid)
      {:ok, _} = Catalogue.move_item_to_category(item, other_category_uuid)

  ## Smart catalogues

  For an end-to-end walkthrough of integrating smart catalogues
  (`kind: "smart"` items priced as functions of other catalogues), see
  the [Smart Catalogues guide](smart_catalogues.md).
  """

  alias PhoenixKitCatalogue.Catalogue.{
    AiNotes,
    Attributes,
    AttributeSets,
    Catalogues,
    Categories,
    Counts,
    CrmLink,
    Dependencies,
    Duplication,
    Folders,
    ItemPaging,
    Items,
    ItemSupplierInfos,
    Links,
    Manufacturers,
    PdfLibrary,
    RefLookup,
    Rules,
    Search,
    SmartPricing,
    SupplierComments,
    SupplierFields,
    Suppliers,
    Translations,
    Trash,
    Tree
  }

  alias PhoenixKitCatalogue.Schemas.Category

  # ═══════════════════════════════════════════════════════════════════
  # Manufacturers — see PhoenixKitCatalogue.Catalogue.Manufacturers
  # ═══════════════════════════════════════════════════════════════════

  defdelegate list_manufacturers(opts \\ []), to: Manufacturers

  defdelegate get_manufacturer(uuid), to: Manufacturers

  defdelegate get_manufacturer!(uuid), to: Manufacturers

  defdelegate create_manufacturer(attrs, opts \\ []), to: Manufacturers

  defdelegate update_manufacturer(manufacturer, attrs, opts \\ []), to: Manufacturers

  defdelegate delete_manufacturer(manufacturer, opts \\ []), to: Manufacturers

  defdelegate change_manufacturer(manufacturer, attrs \\ %{}), to: Manufacturers

  @doc """
  Resolves a manufacturer UUID to a unified map regardless of source
  (local or CRM). Note items still reference the LOCAL row by hard FK.
  """
  defdelegate resolve_manufacturer(uuid), to: Manufacturers, as: :resolve

  @doc "Lists manufacturers from all available sources (local + CRM) as normalized maps."
  defdelegate list_all_manufacturers(opts \\ []), to: Manufacturers, as: :list_all

  # ═══════════════════════════════════════════════════════════════════
  # Suppliers — see PhoenixKitCatalogue.Catalogue.Suppliers
  # ═══════════════════════════════════════════════════════════════════

  defdelegate list_suppliers(opts \\ []), to: Suppliers

  defdelegate get_supplier(uuid), to: Suppliers

  defdelegate get_supplier!(uuid), to: Suppliers

  defdelegate create_supplier(attrs, opts \\ []), to: Suppliers

  defdelegate update_supplier(supplier, attrs, opts \\ []), to: Suppliers

  defdelegate delete_supplier(supplier, opts \\ []), to: Suppliers

  defdelegate change_supplier(supplier, attrs \\ %{}), to: Suppliers

  @doc "Resolves a supplier UUID to a unified map regardless of source (local or CRM)."
  defdelegate resolve_supplier(uuid), to: Suppliers, as: :resolve

  @doc "Lists all suppliers from all available sources (local + CRM) as normalized maps."
  defdelegate list_all_suppliers(opts \\ []), to: Suppliers, as: :list_all

  # ═══════════════════════════════════════════════════════════════════
  # CRM links — see PhoenixKitCatalogue.Catalogue.CrmLink
  # ═══════════════════════════════════════════════════════════════════

  defdelegate crm_link_available?(), to: CrmLink, as: :available?

  defdelegate crm_link_candidates(), to: CrmLink, as: :list_candidates

  defdelegate link_supplier_to_crm(supplier, company_uuid, opts \\ []),
    to: CrmLink,
    as: :link_supplier

  defdelegate unlink_supplier_from_crm(supplier, opts \\ []), to: CrmLink, as: :unlink_supplier

  defdelegate link_manufacturer_to_crm(manufacturer, company_uuid, opts \\ []),
    to: CrmLink,
    as: :link_manufacturer

  defdelegate unlink_manufacturer_from_crm(manufacturer, opts \\ []),
    to: CrmLink,
    as: :unlink_manufacturer

  @doc """
  What a CRM party supplies / manufactures — the read model behind the
  catalogue panel on a company's CRM page. Both accept a party uuid and match
  local projections of it too.
  """
  defdelegate items_supplied_by(party_uuid), to: Suppliers

  defdelegate items_manufactured_by(party_uuid), to: Manufacturers

  @doc "Batch supplier resolution for a page of rows — see `Suppliers.resolve_many/1`."
  defdelegate resolve_suppliers(uuids), to: Suppliers, as: :resolve_many

  @doc "Batch manufacturer resolution for a page of items — see `Manufacturers.resolve_many/1`."
  defdelegate resolve_manufacturers(uuids), to: Manufacturers, as: :resolve_many

  # ═══════════════════════════════════════════════════════════════════
  # Item ↔ Supplier info — see PhoenixKitCatalogue.Catalogue.ItemSupplierInfos
  # ═══════════════════════════════════════════════════════════════════

  # ── Duplication (see `Catalogue.Duplication`) ────────────────────
  defdelegate duplicate_item(item, opts \\ []), to: Duplication

  defdelegate duplicate_category(category, opts \\ []), to: Duplication

  defdelegate duplicate_catalogue(catalogue, opts \\ []), to: Duplication

  defdelegate catalogue_copy_counts(catalogue_uuid), to: Duplication

  defdelegate bulk_duplicate_items(uuids, opts \\ []), to: Duplication

  defdelegate bulk_duplicate_categories(uuids, opts \\ []), to: Duplication

  defdelegate list_supplier_infos_for_item(item_uuid), to: ItemSupplierInfos, as: :list_for_item

  defdelegate supplier_cost_ranges(item_uuids), to: ItemSupplierInfos, as: :cost_ranges

  defdelegate get_supplier_info(uuid), to: ItemSupplierInfos, as: :get

  defdelegate create_supplier_info(attrs, opts \\ []), to: ItemSupplierInfos, as: :create

  defdelegate update_supplier_info(info, attrs, opts \\ []), to: ItemSupplierInfos, as: :update

  defdelegate delete_supplier_info(info, opts \\ []), to: ItemSupplierInfos, as: :delete

  defdelegate set_primary_supplier_info(info, opts \\ []),
    to: ItemSupplierInfos,
    as: :set_primary

  @doc "Returns the primary supplier-info row for an item, or `nil` if none is marked primary."
  defdelegate primary_supplier_info_for_item(item_uuid),
    to: ItemSupplierInfos,
    as: :primary_for_item

  @doc "Returns all rows for an item/supplier pair ordered newest-first (current + closed)."
  defdelegate supplier_info_history_for_pair(item_uuid, supplier_uuid),
    to: ItemSupplierInfos,
    as: :history_for_pair

  @doc "Returns the current junction row for an item/supplier pair or nil."
  defdelegate active_supplier_info_for(item_uuid, supplier_uuid),
    to: Suppliers,
    as: :active_info_for

  @doc "Closes the current junction row and inserts a successor with the new unit cost."
  defdelegate revise_supplier_info_cost(info, new_cost, opts \\ []),
    to: ItemSupplierInfos,
    as: :revise_unit_cost

  # ═══════════════════════════════════════════════════════════════════
  # Manufacturer ↔ Supplier links — see PhoenixKitCatalogue.Catalogue.Links
  # ═══════════════════════════════════════════════════════════════════

  defdelegate link_manufacturer_supplier(manufacturer_uuid, supplier_uuid, opts \\ []),
    to: Links

  defdelegate delete_manufacturer_supplier_links_for(uuid, opts \\ []),
    to: Links,
    as: :delete_links_for

  defdelegate unlink_manufacturer_supplier(manufacturer_uuid, supplier_uuid, opts \\ []),
    to: Links

  defdelegate list_suppliers_for_manufacturer(manufacturer_uuid), to: Links

  defdelegate list_manufacturers_for_supplier(supplier_uuid), to: Links

  defdelegate linked_supplier_uuids(manufacturer_uuid), to: Links

  defdelegate linked_manufacturer_uuids(supplier_uuid), to: Links

  defdelegate sync_manufacturer_suppliers(manufacturer_uuid, supplier_uuids, opts \\ []),
    to: Links

  defdelegate sync_supplier_manufacturers(supplier_uuid, manufacturer_uuids, opts \\ []),
    to: Links

  # ═══════════════════════════════════════════════════════════════════
  # Catalogues — see PhoenixKitCatalogue.Catalogue.Catalogues
  # ═══════════════════════════════════════════════════════════════════

  defdelegate list_catalogues(opts \\ []), to: Catalogues
  defdelegate list_catalogues_by_name_prefix(prefix, opts \\ []), to: Catalogues
  defdelegate deleted_catalogue_count(), to: Catalogues
  defdelegate get_catalogue(uuid), to: Catalogues
  defdelegate fetch_catalogue!(uuid), to: Catalogues
  defdelegate get_catalogue!(uuid, opts \\ []), to: Catalogues
  defdelegate create_catalogue(attrs, opts \\ []), to: Catalogues
  defdelegate update_catalogue(catalogue, attrs, opts \\ []), to: Catalogues
  defdelegate delete_catalogue(catalogue, opts \\ []), to: Catalogues
  defdelegate trash_catalogue(catalogue, opts \\ []), to: Catalogues
  defdelegate restore_catalogue(catalogue, opts \\ []), to: Catalogues
  defdelegate permanently_delete_catalogue(catalogue, opts \\ []), to: Catalogues
  defdelegate change_catalogue(catalogue, attrs \\ %{}), to: Catalogues
  defdelegate next_catalogue_position(), to: Catalogues
  defdelegate reorder_catalogues(ordered_uuids, opts \\ []), to: Catalogues

  # ═══════════════════════════════════════════════════════════════════
  # Categories — see PhoenixKitCatalogue.Catalogue.Categories
  # ═══════════════════════════════════════════════════════════════════

  defdelegate list_categories_for_catalogue(catalogue_uuid), to: Categories
  defdelegate list_categories_metadata_for_catalogue(catalogue_uuid, opts \\ []), to: Categories
  defdelegate category_summary_for_catalogue(catalogue_uuid, opts \\ []), to: Categories
  defdelegate list_all_categories(), to: Categories
  defdelegate get_category(uuid), to: Categories
  defdelegate get_category!(uuid), to: Categories
  defdelegate get_category_by_slug(slug, lang, opts \\ []), to: Categories
  defdelegate create_category(attrs, opts \\ []), to: Categories
  defdelegate update_category(category, attrs, opts \\ []), to: Categories
  defdelegate delete_category(category, opts \\ []), to: Categories
  defdelegate trash_category(category, opts \\ []), to: Categories
  defdelegate trash_category_outcome(category, opts \\ []), to: Categories
  defdelegate broadcast_categories_trashed(catalogue_uuid), to: Categories
  defdelegate restore_category(category, opts \\ []), to: Categories
  defdelegate permanently_delete_category(category, opts \\ []), to: Categories
  defdelegate permanent_delete_scope(category), to: Categories

  defdelegate move_category_to_catalogue(category, target_catalogue_uuid, opts \\ []),
    to: Categories

  defdelegate move_category_under(category, new_parent_uuid, opts \\ []), to: Categories
  defdelegate bulk_move_categories_under(uuids, new_parent_uuid, opts \\ []), to: Categories
  defdelegate swap_category_positions(cat_a, cat_b, opts \\ []), to: Categories
  defdelegate change_category(category, attrs \\ %{}), to: Categories
  defdelegate category_subtree_uuids(category_uuids), to: Categories

  defdelegate internal_category_uuids(), to: Categories
  defdelegate list_move_target_categories(category), to: Categories
  defdelegate list_category_tree(catalogue_uuid, opts \\ []), to: Categories
  defdelegate list_live_categories(catalogue_uuids), to: Categories
  defdelegate list_child_categories(catalogue_uuid, parent_uuid, opts \\ []), to: Categories
  defdelegate category_children_counts(catalogue_uuid, opts \\ []), to: Categories
  defdelegate category_uuids_with_children(catalogue_uuid, opts \\ []), to: Categories
  defdelegate next_category_position(catalogue_uuid, parent_uuid \\ nil), to: Categories
  defdelegate max_category_position(), to: Categories

  defdelegate reorder_categories(catalogue_uuid, parent_uuid, ordered_uuids, opts \\ []),
    to: Categories

  defdelegate reorder_categories_groups(catalogue_uuid, groups, opts \\ []), to: Categories
  defdelegate category_slug_taken?(slug, lang, opts \\ []), to: Categories

  defdelegate bulk_move_categories_to_catalogue(
                uuids,
                target_catalogue_uuid,
                parent_uuid,
                opts \\ []
              ),
              to: Categories

  defdelegate bulk_trash_categories(uuids, disposition, opts), to: Categories

  @doc """
  Returns the list of ancestor categories from root down to (but not
  including) `category_uuid`. Empty when the category is a root.
  Useful for breadcrumbs.
  """
  @spec list_category_ancestors(Ecto.UUID.t()) :: [Category.t()]
  defdelegate list_category_ancestors(category_uuid), to: Tree, as: :ancestors_in_order

  # ═══════════════════════════════════════════════════════════════════
  # Catalogue folders — see PhoenixKitCatalogue.Catalogue.Folders
  # ═══════════════════════════════════════════════════════════════════

  defdelegate list_folder_tree(opts \\ []), to: Folders
  defdelegate folder_uuids_with_children(opts \\ []), to: Folders
  defdelegate catalogues_by_folder(opts \\ []), to: Folders
  defdelegate get_folder(uuid), to: Folders
  defdelegate create_folder(attrs, opts \\ []), to: Folders
  defdelegate update_folder(folder, attrs, opts \\ []), to: Folders
  defdelegate move_folder(folder, new_parent_uuid, opts \\ []), to: Folders
  defdelegate trash_folder(folder, opts \\ []), to: Folders
  defdelegate restore_folder(folder, opts \\ []), to: Folders
  defdelegate delete_empty_folder(folder, opts \\ []), to: Folders
  defdelegate permanently_delete_folder(folder, opts \\ []), to: Folders
  defdelegate reorder_folders(ordered_uuids, opts \\ []), to: Folders
  defdelegate place_level_rows(entries, opts \\ []), to: Folders
  defdelegate move_catalogue_to_folder(catalogue, folder_uuid, opts \\ []), to: Folders

  # ═══════════════════════════════════════════════════════════════════
  # Trash provenance and the per-catalogue lock — see PhoenixKitCatalogue.Catalogue.Trash
  # ═══════════════════════════════════════════════════════════════════

  @doc false
  defdelegate lock_catalogue!(catalogue_uuid), to: Trash

  # ═══════════════════════════════════════════════════════════════════
  # Items — see PhoenixKitCatalogue.Catalogue.Items
  # ═══════════════════════════════════════════════════════════════════

  defdelegate list_items_for_category_paged(category_uuid, opts \\ []), to: Items
  defdelegate list_catalogue_items_paged(catalogue_uuid, opts \\ []), to: Items
  defdelegate count_items_for_catalogue(catalogue_uuid, opts \\ []), to: Items
  defdelegate item_status_counts_for_catalogue(catalogue_uuid), to: Items
  defdelegate list_uncategorized_items_paged(catalogue_uuid, opts \\ []), to: Items
  defdelegate uncategorized_count_for_catalogue(catalogue_uuid, opts \\ []), to: Items
  defdelegate filter_by_attribute_values(query, opts), to: Items
  defdelegate filter_by_item_types(query, opts), to: Items
  defdelegate item_count_for_category(category_uuid, opts \\ []), to: Items
  defdelegate item_status_counts_for_category(category_uuid), to: Items
  defdelegate item_status_counts_for_uncategorized(catalogue_uuid), to: Items
  defdelegate item_counts_by_category_for_catalogue(catalogue_uuid, opts \\ []), to: Items
  defdelegate live_item_uuids_by_category(category_uuids), to: Items
  defdelegate next_item_position(catalogue_uuid, category_uuid), to: Items
  defdelegate reorder_items(catalogue_uuid, category_uuid, ordered_uuids, opts \\ []), to: Items

  defdelegate reorder_items_by(catalogue_uuid, category_uuid, strategy, scope, opts \\ []),
    to: Items

  defdelegate normalize_category_uuid(uuid), to: Items
  defdelegate list_items(opts \\ []), to: Items
  defdelegate list_items_for_category(category_uuid, opts \\ []), to: Items
  defdelegate list_items_for_catalogue(catalogue_uuid, opts \\ []), to: Items
  defdelegate list_live_items(catalogue_uuids), to: Items
  defdelegate list_deleted_items_for_catalogue(catalogue_uuid, opts \\ []), to: Items
  defdelegate list_uncategorized_items(catalogue_uuid, opts \\ []), to: Items
  defdelegate get_item(uuid, opts \\ []), to: Items
  defdelegate get_item!(uuid, opts \\ []), to: Items
  defdelegate get_item_by_slug(slug, lang, opts \\ []), to: Items
  defdelegate item_slug_taken?(slug, lang, opts \\ []), to: Items
  defdelegate list_items_by_uuids(uuids, opts \\ []), to: Items
  defdelegate create_item(attrs, opts \\ []), to: Items
  defdelegate update_item(item, attrs, opts \\ []), to: Items
  defdelegate preview_item_update(item, attrs, opts \\ []), to: Items
  defdelegate update_items(rows, opts \\ []), to: Items
  defdelegate broadcast_item_batch_change(catalogue_uuid, kind, uuids), to: Items
  defdelegate delete_item(item, opts \\ []), to: Items
  defdelegate trash_item(item, opts \\ []), to: Items
  defdelegate trash_item_outcome(item, opts \\ []), to: Items
  defdelegate restore_item(item, opts \\ []), to: Items
  defdelegate permanently_delete_item(item, opts \\ []), to: Items
  defdelegate trash_items_in_category(category_uuid, opts \\ []), to: Items
  defdelegate bulk_trash_items(uuids, opts), to: Items
  defdelegate bulk_restore_items(uuids, opts), to: Items
  defdelegate bulk_permanently_delete_items(uuids, opts), to: Items
  defdelegate bulk_move_items_to_category(uuids, target, opts), to: Items
  defdelegate bulk_move_items(uuids, destination, opts), to: Items
  defdelegate move_item_to_category(item, category_uuid, opts \\ []), to: Items
  defdelegate move_item_to_category_deferred(item, category_uuid, opts \\ []), to: Items
  defdelegate follow_moved_items(pairs, actor_uuid), to: Items
  defdelegate move_item_to_catalogue(item, catalogue_uuid, opts \\ []), to: Items
  defdelegate change_item(item, attrs \\ %{}), to: Items
  defdelegate item_pricing(item), to: Items
  defdelegate effective_item_type(item), to: Items

  # ── Keyset paging for the shop API's incremental export ──────────
  defdelegate list_items_keyset(opts), to: ItemPaging, as: :page
  defdelegate count_items_matching(opts), to: ItemPaging, as: :count
  defdelegate decode_items_cursor(cursor), to: ItemPaging, as: :decode_cursor

  # ── Batched reference lookups for the shop API ───────────────────
  defdelegate lookup_by_ids(kind, ids, opts \\ []), to: RefLookup, as: :by_ids
  defdelegate lookup_by_skus(kind, skus, opts \\ []), to: RefLookup, as: :by_skus
  defdelegate lookup_by_external_ids(kind, eids, opts \\ []), to: RefLookup, as: :by_external_ids
  defdelegate external_id_conflict?(changeset), to: Trash

  # ═══════════════════════════════════════════════════════════════════
  # Smart-catalogue rules — see PhoenixKitCatalogue.Catalogue.Rules
  # ═══════════════════════════════════════════════════════════════════

  defdelegate list_catalogue_rules(item_or_uuid), to: Rules

  defdelegate catalogue_rule_map(item_or_uuid), to: Rules

  defdelegate get_catalogue_rule(item_uuid, referenced_catalogue_uuid), to: Rules

  defdelegate put_catalogue_rules(item, rules, opts \\ []), to: Rules

  defdelegate reorder_catalogue_rules(item_uuid, ordered_referenced_uuids, opts \\ []), to: Rules

  defdelegate list_items_referencing_catalogue(catalogue_uuid), to: Rules

  defdelegate catalogue_reference_count(catalogue_uuid), to: Rules

  defdelegate change_catalogue_rule(rule, attrs \\ %{}), to: Rules

  defdelegate create_catalogue_rule(attrs, opts \\ []), to: Rules

  defdelegate update_catalogue_rule(rule, attrs, opts \\ []), to: Rules

  defdelegate delete_catalogue_rule(rule, opts \\ []), to: Rules

  # ═══════════════════════════════════════════════════════════════════
  # Item dependencies — see PhoenixKitCatalogue.Catalogue.Dependencies
  # ═══════════════════════════════════════════════════════════════════

  defdelegate list_item_dependencies(item_or_uuid), to: Dependencies

  defdelegate dependencies_by_item(item_uuids), to: Dependencies

  defdelegate resolve_import_ref(ref, opts \\ []), to: Dependencies

  defdelegate put_item_dependencies(item, specs, opts \\ []), to: Dependencies
  defdelegate dependencies_conflict?(item, specs, expected), to: Dependencies

  defdelegate list_item_dependents(target), to: Dependencies

  defdelegate count_outside_dependents(record), to: Dependencies

  # ═══════════════════════════════════════════════════════════════════
  # Notes for AI — see PhoenixKitCatalogue.Catalogue.AiNotes
  # ═══════════════════════════════════════════════════════════════════

  defdelegate ai_notes_for_item(item), to: AiNotes

  # ═══════════════════════════════════════════════════════════════════
  # Smart-catalogue pricing — see PhoenixKitCatalogue.Catalogue.SmartPricing
  # ═══════════════════════════════════════════════════════════════════

  defdelegate evaluate_smart_rules(entries, opts \\ []), to: SmartPricing

  # ═══════════════════════════════════════════════════════════════════
  # Search — see PhoenixKitCatalogue.Catalogue.Search
  # ═══════════════════════════════════════════════════════════════════

  defdelegate search_items(query, opts \\ []), to: Search

  defdelegate count_search_items(query, opts \\ []), to: Search

  defdelegate search_items_in_catalogue(catalogue_uuid, query, opts \\ []), to: Search

  defdelegate search_categories(catalogue_uuid, query, opts \\ []), to: Search

  defdelegate match_search_text(query, term), to: Search, as: :match_text

  defdelegate count_search_items_in_catalogue(catalogue_uuid, query), to: Search

  defdelegate search_items_in_category(category_uuid, query, opts \\ []), to: Search

  defdelegate count_search_items_in_category(category_uuid, query), to: Search

  # ═══════════════════════════════════════════════════════════════════
  # Counts — see PhoenixKitCatalogue.Catalogue.Counts
  # ═══════════════════════════════════════════════════════════════════

  defdelegate item_count_for_catalogue(catalogue_uuid), to: Counts

  defdelegate item_counts_by_catalogue(opts \\ []), to: Counts

  defdelegate trashed_item_counts_by_root(catalogue_uuid), to: Counts

  defdelegate attached_file_counts(resources), to: Counts

  defdelegate active_item_count_in_subtree(category_uuid), to: Counts

  defdelegate category_count_for_catalogue(catalogue_uuid), to: Counts

  defdelegate category_counts_by_catalogue(), to: Counts

  defdelegate deleted_item_count_for_catalogue(catalogue_uuid), to: Counts

  defdelegate deleted_category_count_for_catalogue(catalogue_uuid), to: Counts

  defdelegate deleted_count_for_catalogue(catalogue_uuid), to: Counts

  # ═══════════════════════════════════════════════════════════════════
  # Multilang helpers — see PhoenixKitCatalogue.Catalogue.Translations
  # ═══════════════════════════════════════════════════════════════════

  defdelegate get_translation(record, lang_code), to: Translations

  defdelegate translated_name(record, locale), to: Translations

  defdelegate translated_description(record, locale), to: Translations

  defdelegate translated_seo_title(record, locale), to: Translations

  defdelegate translated_seo_description(record, locale), to: Translations

  defdelegate localize(records, locale), to: Translations

  defdelegate localize_one(record, locale), to: Translations

  defdelegate set_translation(record, lang_code, field_data, update_fn, opts \\ []),
    to: Translations

  # ═══════════════════════════════════════════════════════════════════
  # PDF library — see PhoenixKitCatalogue.Catalogue.PdfLibrary
  # ═══════════════════════════════════════════════════════════════════

  defdelegate list_pdfs(opts \\ []), to: PdfLibrary

  defdelegate count_pdfs(opts \\ []), to: PdfLibrary

  defdelegate get_pdf(uuid), to: PdfLibrary

  defdelegate get_pdf!(uuid), to: PdfLibrary

  defdelegate get_pdf_extraction(pdf), to: PdfLibrary, as: :get_extraction

  defdelegate create_pdf_from_upload(tmp_path, original_filename, opts \\ []),
    to: PdfLibrary

  defdelegate trash_pdf(pdf, opts \\ []), to: PdfLibrary

  defdelegate restore_pdf(pdf, opts \\ []), to: PdfLibrary

  defdelegate permanently_delete_pdf(pdf, opts \\ []), to: PdfLibrary

  defdelegate search_pdfs_for_item(item, opts \\ []), to: PdfLibrary

  defdelegate search_pdf_contents(query, opts \\ []), to: PdfLibrary

  defdelegate more_pdf_content_matches(query, pdf_uuid, opts \\ []), to: PdfLibrary

  defdelegate more_pdf_matches_for_item(item, pdf_uuid, opts \\ []), to: PdfLibrary

  defdelegate prune_orphan_pdf_page_contents(), to: PdfLibrary, as: :prune_orphan_page_contents

  defdelegate retry_extraction(pdf, opts \\ []), to: PdfLibrary

  defdelegate requeue_stuck_extractions(opts \\ []), to: PdfLibrary

  # ═══════════════════════════════════════════════════════════════════
  # Attribute groups — see PhoenixKitCatalogue.Catalogue.Attributes
  # ═══════════════════════════════════════════════════════════════════

  defdelegate list_attribute_groups(opts \\ []), to: Attributes

  defdelegate change_attribute_group(group, attrs \\ %{}), to: Attributes

  defdelegate get_attribute_group(uuid), to: Attributes

  defdelegate get_attribute_group_full(uuid), to: Attributes

  defdelegate attribute_counts(group_uuids), to: Attributes

  defdelegate assignment_counts(group_uuids), to: Attributes

  defdelegate create_attribute_group(attrs, opts \\ []), to: Attributes

  defdelegate update_attribute_group(group, attrs, opts \\ []), to: Attributes

  defdelegate delete_attribute_group(group, opts \\ []), to: Attributes

  defdelegate get_attribute(uuid), to: Attributes

  defdelegate create_attribute(group, attrs, opts \\ []), to: Attributes

  defdelegate update_attribute(attribute, attrs, opts \\ []), to: Attributes

  defdelegate delete_attribute(attribute, opts \\ []), to: Attributes

  defdelegate reorder_attributes(group, uuids, opts \\ []), to: Attributes

  defdelegate get_attribute_value(uuid), to: Attributes

  defdelegate create_attribute_value(attribute, attrs, opts \\ []), to: Attributes

  defdelegate update_attribute_value(value, attrs, opts \\ []), to: Attributes

  defdelegate delete_attribute_value(value, opts \\ []), to: Attributes

  defdelegate set_default_value(value, opts \\ []), to: Attributes

  defdelegate reorder_attribute_values(attribute, uuids, opts \\ []), to: Attributes

  # ── Attribute SETS (2026-08-18 rework; see AttributeSets moduledoc) ─
  defdelegate create_attribute_set(attrs, opts \\ []), to: AttributeSets, as: :create_set

  defdelegate list_attribute_sets(opts \\ []), to: AttributeSets, as: :list_sets

  defdelegate get_attribute_set(uuid, opts \\ []), to: AttributeSets, as: :get_set

  defdelegate update_attribute_set(set, attrs, opts \\ []), to: AttributeSets, as: :update_set

  defdelegate delete_attribute_set(set, opts \\ []), to: AttributeSets, as: :delete_set

  defdelegate archive_attribute_set(set, opts \\ []), to: AttributeSets, as: :archive_set

  defdelegate restore_attribute_set(set, opts \\ []), to: AttributeSets, as: :restore_set

  defdelegate attribute_value_match_counts(opts \\ []),
    to: AttributeSets,
    as: :value_match_counts

  defdelegate attribute_filter_options(catalogue_uuid, opts \\ []),
    to: AttributeSets,
    as: :filter_options

  defdelegate attribute_set_uuids_matching_value(set_uuids, term),
    to: AttributeSets,
    as: :set_uuids_matching_value

  defdelegate list_attribute_set_attached_items(set_uuid, opts \\ []),
    to: AttributeSets,
    as: :list_attached_items

  defdelegate count_attribute_set_attached_items(set_uuid, opts \\ []),
    to: AttributeSets,
    as: :count_attached_items

  defdelegate create_attribute_set_value(set, attrs, opts \\ []),
    to: AttributeSets,
    as: :create_value

  defdelegate list_attribute_set_values(set, opts \\ []), to: AttributeSets, as: :list_values

  defdelegate list_attribute_set_values_for(set_uuids, opts \\ []),
    to: AttributeSets,
    as: :list_values_for

  defdelegate list_attribute_set_hidden_values_for(set_uuids, opts \\ []),
    to: AttributeSets,
    as: :list_hidden_values_for

  defdelegate drop_hidden_attribute_set_value_duplicates(hidden_values, values),
    to: AttributeSets,
    as: :drop_hidden_duplicates

  defdelegate get_attribute_set_value(set, value_uuid), to: AttributeSets, as: :get_value

  defdelegate update_attribute_set_value(set, value, attrs, opts \\ []),
    to: AttributeSets,
    as: :update_value

  defdelegate delete_attribute_set_value(set, value, opts \\ []),
    to: AttributeSets,
    as: :delete_value

  defdelegate reorder_attribute_set_values(set, ordered_uuids, opts \\ []),
    to: AttributeSets,
    as: :reorder_values

  defdelegate add_attribute_set_field(set, attrs, opts \\ []),
    to: AttributeSets,
    as: :add_extra_field

  defdelegate remove_attribute_set_field(set, key, opts \\ []),
    to: AttributeSets,
    as: :remove_extra_field

  defdelegate update_attribute_set_field(set, key, attrs, opts \\ []),
    to: AttributeSets,
    as: :update_extra_field

  defdelegate attribute_set_field_types(), to: AttributeSets, as: :extra_field_types

  # ── Supplier custom fields (entities-defined, values on the row) ────

  defdelegate supplier_crm_company_uuid(reference), to: Suppliers, as: :crm_company_uuid

  # ── Supplier comments (one thread per item × supplier) ──────────────
  # See PhoenixKitCatalogue.Catalogue.SupplierComments.
  defdelegate supplier_comment_resource_type(), to: SupplierComments, as: :resource_type

  defdelegate supplier_comment_thread_uuid(info), to: SupplierComments, as: :thread_uuid

  defdelegate supplier_comment_thread_for_pair(item_uuid, supplier_uuid),
    to: SupplierComments,
    as: :thread_for_pair

  defdelegate resolve_supplier_comment_resources(uuids),
    to: SupplierComments,
    as: :resolve_resources

  defdelegate supplier_builtin_fields(), to: SupplierFields, as: :builtin_fields

  defdelegate supplier_builtin_field(key), to: SupplierFields, as: :builtin_field

  defdelegate cast_supplier_builtin(key, raw), to: SupplierFields, as: :cast_builtin

  defdelegate supplier_fields(opts \\ []), to: SupplierFields, as: :fields

  defdelegate supplier_field(key, opts \\ []), to: SupplierFields, as: :field

  defdelegate supplier_field_types(), to: SupplierFields, as: :field_types

  defdelegate supplier_fields_enabled?(), to: SupplierFields, as: :enabled?

  defdelegate add_supplier_field(attrs, opts \\ []), to: SupplierFields, as: :add_field

  defdelegate update_supplier_field(key, attrs, opts \\ []), to: SupplierFields, as: :update_field

  defdelegate remove_supplier_field(key, opts \\ []), to: SupplierFields, as: :remove_field

  defdelegate supplier_field_values(info), to: SupplierFields, as: :values

  defdelegate cast_supplier_field_values(raw, opts \\ []), to: SupplierFields, as: :cast_values

  defdelegate put_supplier_field_values(metadata, values), to: SupplierFields, as: :put_values

  defdelegate attach_attribute_set(item_uuid, set_uuid, opts \\ []),
    to: AttributeSets,
    as: :attach_set

  defdelegate detach_attribute_set(item_uuid, set_uuid, opts \\ []),
    to: AttributeSets,
    as: :detach_set

  defdelegate reorder_attribute_sets(item_uuid, set_uuids, opts \\ []),
    to: AttributeSets,
    as: :reorder_attachments

  defdelegate list_attribute_set_attachments(item_uuid), to: AttributeSets, as: :list_attachments

  defdelegate set_attribute_set_selection(item_uuid, set_uuid, slugs, opts \\ []),
    to: AttributeSets,
    as: :set_attachment_selection

  defdelegate resolve_attribute_sets(item_uuids, opts \\ []),
    to: AttributeSets,
    as: :resolve_for_items

  defdelegate attribute_set_presence(item_uuids), to: AttributeSets, as: :attached_item_uuids

  defdelegate resolve_attribute_sets_for_item(item_uuid, opts \\ []),
    to: AttributeSets,
    as: :resolve_for_item

  defdelegate resolve_attribute_set(set_uuid, opts \\ []), to: AttributeSets, as: :resolve_set

  defdelegate attribute_sets_enabled?(), to: AttributeSets, as: :enabled?

  defdelegate attribute_set_contract(set), to: AttributeSets, as: :contract

  defdelegate attribute_set_kind(set), to: AttributeSets, as: :kind

  defdelegate attribute_set_default_value_slug(set), to: AttributeSets, as: :default_value_slug

  defdelegate attribute_set_attached?(set_uuid), to: AttributeSets, as: :set_attached?

  defdelegate valid_attribute_set_selection(slugs, resolved_set),
    to: AttributeSets,
    as: :valid_selection

  defdelegate prune_orphan_attribute_set_attachments(set_uuid),
    to: AttributeSets,
    as: :prune_orphan_attachments

  defdelegate prune_orphan_attribute_set_value_slugs(set_uuid),
    to: AttributeSets,
    as: :prune_orphan_value_slugs

  defdelegate attribute_set_value_counts(set_uuids), to: AttributeSets, as: :value_counts

  defdelegate attribute_set_attachment_counts(set_uuids),
    to: AttributeSets,
    as: :attachment_counts

  defdelegate migrate_attribute_groups_to_sets(opts \\ []),
    to: AttributeSets,
    as: :migrate_groups_to_sets

  defdelegate auto_migrate_attribute_groups(), to: AttributeSets, as: :auto_migrate_legacy

  defdelegate set_item_attribute_group(item, group_uuid, opts \\ []), to: Attributes

  defdelegate get_item_attribute_group_uuid(item_uuid), to: Attributes

  defdelegate item_attribute_group_map(item_uuids), to: Attributes

  defdelegate attribute_group_names(group_uuids), to: Attributes

  defdelegate resolved_group(group_uuid, lang), to: Attributes
end
