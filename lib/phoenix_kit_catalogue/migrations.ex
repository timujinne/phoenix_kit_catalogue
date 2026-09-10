defmodule PhoenixKitCatalogue.Migrations do
  @moduledoc """
  Module-owned versioned migrations for `phoenix_kit_catalogue` — the
  decentralized-migrations protocol that core's `mix phoenix_kit.update`
  discovers via `migration_module/0`: `current_version/0` +
  `migrated_version_runtime/1` + idempotent `up/1` + version-aware
  `down/1`. `phoenix_kit_crm` (ten adopted tables) is the closest sibling
  example of this exact situation, scaled up further to eighteen tables.

  ## What V01 is

  V01 is an ADOPTION step for all eighteen `phoenix_kit_cat_*` tables that
  core already creates (V135: catalogues, categories, items,
  manufacturers, manufacturer_suppliers, suppliers, folders,
  item_catalogue_rules, pdfs, pdf_pages, pdf_page_contents,
  pdf_extractions; V149: item_supplier_info; V173: attribute_groups,
  attributes, attribute_values, item_attribute_groups; V177:
  item_attribute_sets).

  Those four versions only CREATE the tables; five more reshape them, and
  the DDL below is the sum of all nine — check every one of them when
  auditing a table's shape, not just its creator:

    * V146 adds `items.primary_supplier_uuid` (+ its partial index and FK);
    * V151 adds `item_supplier_info.supplier_source` / `is_primary`
      (+ the source CHECK and the one-primary-per-item partial unique);
    * V178 adds `manufacturers.crm_company_uuid` (+ the partial unique
      indexes on both directories' `crm_company_uuid`);
    * V179 adds `items.manufacturer_source` /
      `manufacturer_name_snapshot` (+ the source CHECK) and **DROPS**
      `phoenix_kit_cat_items_manufacturer_uuid_fkey`;
    * V180 adds `manufacturer_suppliers.manufacturer_source` /
      `supplier_source` (+ both source CHECKs and the current-pair unique
      on `item_supplier_info`) and **DROPS** both
      `phoenix_kit_cat_manufacturer_suppliers_*_uuid_fkey` constraints.

  The three dropped foreign keys are the reason `foreign_keys/2` does not
  simply mirror V135: core carries them as `:legacy_optional` in
  `ExpectedSchema` — present only on installs that stopped before V179/
  V180 — so re-adding one here would pin an item's manufacturer and both
  sides of the M:N graph back to a local row, undoing the CRM federation.
  `test/phoenix_kit_catalogue/migrations_test.exs` pins that against the
  manifest in both directions.

  So, concretely:

    * on an install already at core's V180+ shape (crm_company_uuid,
      manufacturer_source/supplier_source, the item/manufacturer_suppliers
      FKs V179–V180 drop) every table is already there, the `CREATE TABLE
      IF NOT EXISTS` / guarded `DO $$ ... pg_constraint ... $$` blocks all
      find their targets already in place and are no-ops — the only new
      object is the `pkc_schema:1` marker. From then on this chain owns
      every adopted table's future shape;
    * on a hypothetical fresh install whose core baseline no longer
      creates these tables, the same statements create them —
      shape-identical to core's live V182 schema (authority: a
      `pg_dump --schema-only` of the live database), with core's exact
      table/constraint/index names.

  `CREATE TABLE IF NOT EXISTS` adoption is a presence check only — it
  does not repair a table whose columns have drifted from core's current
  shape on a host stuck below core V180 (the guarded `ADD CONSTRAINT`
  blocks below DO repair a missing constraint on an existing table, but
  they cannot add a missing *column* like `crm_company_uuid` or
  `manufacturer_source`). That risk is contained, not eliminated: core's
  own migration chain always runs ahead of this one (`mix
  phoenix_kit.update` applies core's chain first), so by the time V01
  runs, every adopted table is already at core's current shape on any
  host this chain actually executes against — the `pk_dep(:phoenix_kit,
  "~> 2.13.11")` floor in `mix.exs` exists precisely so a host can always
  reach that shape (see the comment there for why 2.13.4–2.13.10, which
  ship the shape, are excluded: V180 itself crashes on those releases).

  Because V01 changes no shape, core's `ExpectedSchema` manifest (which
  still audits these tables' shapes) stays accurate and no core release
  is required for this version. A version that DOES change shape (V2+)
  must follow the excluded-object protocol described in the Legal
  chain's extraction report before it ships.

  ## What V2 is

  V2 adds shape on top of two core-known tables (`phoenix_kit_cat_items`,
  `phoenix_kit_cat_categories`): a `slug jsonb NOT NULL DEFAULT '{}'`
  column on each. Core's `ExpectedSchema` resolver only ever iterates
  the manifest's *declared* objects — it never enumerates a table's
  actual columns to notice one that isn't manifested, so an extra
  column is not inspected at all (not classified as an `:info`
  finding; simply outside what the resolver looks at) — so this is
  safe without a core release. The rest of V2 (the two
  `phoenix_kit_cat_item_slugs` / `phoenix_kit_cat_category_slugs`
  projection tables, their sync triggers, and the attribute-set GIN
  index) creates objects core's manifest never names at all, which is
  outside the manifest's reach by construction. Contrast the case that
  WOULD require a core release first: altering the shape of a table
  column core's manifest actually declares — see
  `phoenix_kit_legal`'s `dev_docs/reports/2026-08-10-consent-logs-extraction.md`
  for that scenario.

  The two projection tables exist so a slug can be looked up (and its
  per-language uniqueness enforced) without scanning every item/category
  row's `slug` jsonb — the same shape core's own `ShopSlugProjection`
  used before catalogue absorbed the shop tables. A trigger
  (`AFTER INSERT OR UPDATE OF slug`) keeps each projection in sync with
  its owning table; the projection's own `DELETE FROM <projection>` at
  the top of the sync function is the one DELETE this chain is allowed
  to emit (it deletes only projection rows it is about to
  re-insert — never a base table row).

  ## What `down/1` is NOT

  `down/1` unstamps the version marker; it NEVER drops any of the
  eighteen tables — catalogue, category, item, and supplier data is not
  this chain's to destroy, and most of it is core-created. The ownership
  test pins this by asserting no statement this module can emit matches
  `DROP`, `TRUNCATE`, or `DELETE`.

  The migrated version is tracked as a `pkc_schema:<N>` `COMMENT ON
  TABLE` marker on `phoenix_kit_cat_catalogues` (the marker convention
  from the projects/Legal/CRM chains). A marker-less table reads as
  version 0 — the core-baseline shape before this chain existed.
  """

  use Ecto.Migration

  @current_version 2
  @marker_prefix "pkc_schema:"
  @version_table "phoenix_kit_cat_catalogues"

  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc "The table carrying the `pkc_schema:<N>` marker (auditor contract)."
  @spec version_table() :: String.t()
  def version_table, do: @version_table

  @doc "The chain version read from INSIDE a migration (migration repo)."
  def migrated_version(opts \\ []) do
    prefix = validated_prefix(opts)
    %{rows: rows} = repo().query!(marker_query(), [prefix])
    rows |> List.first() |> marker_to_version()
  end

  @doc """
  The chain version currently applied in the database, read OUTSIDE a
  migration (the protocol shape core's update task calls — `opts` with
  `:prefix`): the `pkc_schema:<N>` marker when present; a marker-less or
  foreign-comment table reads as `0` (core-baseline shape — V1 is purely
  adoptive, there is no pre-chain content to defend).
  """
  def migrated_version_runtime(opts \\ []) do
    prefix = validated_prefix(opts)

    case PhoenixKit.RepoHelper.repo().query(marker_query(), [prefix]) do
      {:ok, %{rows: rows}} -> rows |> List.first() |> marker_to_version()
      _ -> 0
    end
  rescue
    # An invalid prefix must surface as the validation error, not be
    # swallowed into 0 ("not installed") — that misleads the operator AND
    # lets the unvalidated string reach interpolated SQL in callers'
    # fallback paths.
    e in ArgumentError -> reraise e, __STACKTRACE__
    _ -> 0
  end

  @doc "Applies every chain version up to `target` (`:version` in `opts`, default `current_version/0`); idempotent."
  def up(opts \\ []) do
    prefix = validated_prefix(opts)

    target =
      if is_list(opts), do: Keyword.get(opts, :version, @current_version), else: @current_version

    prefix
    |> up_statements(target)
    |> Enum.each(&execute/1)
  end

  @doc "Rolls back to `target` (`:version` in `opts`). Never drops a table — see the moduledoc."
  def down(opts \\ []) do
    prefix = validated_prefix(opts)
    target = if is_list(opts), do: Keyword.get(opts, :version, 0), else: 0

    prefix
    |> down_statements(target)
    |> Enum.each(&execute/1)
  end

  @doc """
  The SQL `up/1` executes, as data — the testable single source. Every
  statement is idempotent (`IF NOT EXISTS` / guarded `DO $$` block /
  `CREATE OR REPLACE FUNCTION` / `DROP TRIGGER IF EXISTS` + `CREATE
  TRIGGER` / `COMMENT`) so it is safe to replay on an install where
  core already created some or all of these tables, and on a fresh
  install with none of them. V1 order: every `CREATE TABLE`, then every
  primary-key guard, then every foreign-key guard, then every
  CHECK-constraint guard, then every index (table declaration order
  only matters for self-documentation — FK targets are guarded, not
  required to pre-exist at CREATE TABLE time; the 13 CHECK constraints
  also ride inline inside their `CREATE TABLE IF NOT EXISTS`, harmless
  since Postgres no-ops the whole statement on an existing table — the
  guards are what actually repair a pre-existing table missing one).
  V2 statements follow, then the version marker last.

  `target` selects how much of the chain to emit (default
  `current_version/0`): `1` is the pure V1 adoption step (the owned
  tables/keys/checks/indexes below); `2` additionally adds V2's
  per-language `slug` column, its trigger projections, and the
  attribute-set GIN index. Mirrors `phoenix_kit_billing`'s version-aware
  `up_statements/2` — the wrapper migration core's update task generates
  calls this with an explicit `:version`, and a stale wrapper asking for
  `1` must not receive `2`'s objects.
  """
  @spec up_statements(String.t(), pos_integer()) :: [String.t()]
  def up_statements(prefix \\ "public", target \\ @current_version)

  def up_statements(prefix, target) when is_integer(target) and target >= 1 do
    prefix = validated_prefix(prefix: prefix)
    p = "#{prefix}."
    target = min(target, @current_version)

    v2 = if target >= 2, do: v2_statements(p), else: []

    List.flatten([
      v1_statements(prefix, p),
      v2,
      "COMMENT ON TABLE #{p}#{@version_table} IS '#{@marker_prefix}#{target}'"
    ])
  end

  defp v1_statements(prefix, p) do
    [
      tables(p),
      primary_keys(prefix, p),
      foreign_keys(prefix, p),
      checks(prefix, p),
      indexes(p)
    ]
  end

  # ── V2: per-language slug column + trigger projections + GIN index ──

  defp v2_statements(p) do
    [
      "ALTER TABLE #{p}phoenix_kit_cat_items ADD COLUMN IF NOT EXISTS slug jsonb DEFAULT '{}'::jsonb NOT NULL",
      "ALTER TABLE #{p}phoenix_kit_cat_categories ADD COLUMN IF NOT EXISTS slug jsonb DEFAULT '{}'::jsonb NOT NULL",
      slug_projection_statements(p,
        projection: "phoenix_kit_cat_item_slugs",
        owner: "phoenix_kit_cat_items",
        owner_uuid_column: "item_uuid",
        sync_function: "sync_cat_item_slugs",
        trigger: "trg_cat_item_slugs"
      ),
      slug_projection_statements(p,
        projection: "phoenix_kit_cat_category_slugs",
        owner: "phoenix_kit_cat_categories",
        owner_uuid_column: "category_uuid",
        sync_function: "sync_cat_category_slugs",
        trigger: "trg_cat_category_slugs"
      ),
      "CREATE INDEX IF NOT EXISTS phoenix_kit_cat_item_attribute_sets_selected_values_gin ON #{p}phoenix_kit_cat_item_attribute_sets USING gin ((data -> 'selected_value_slugs'))"
    ]
  end

  # One projection: table + its FK index + sync trigger function +
  # trigger + a one-time backfill INSERT (idempotent via `ON CONFLICT
  # DO NOTHING`) so items/categories that already carry a `slug` before
  # this version runs get projected immediately, not only on their next
  # write.
  defp slug_projection_statements(p, opts) do
    projection = Keyword.fetch!(opts, :projection)
    owner = Keyword.fetch!(opts, :owner)
    owner_uuid_column = Keyword.fetch!(opts, :owner_uuid_column)
    sync_function = Keyword.fetch!(opts, :sync_function)
    trigger = Keyword.fetch!(opts, :trigger)

    [
      """
      CREATE TABLE IF NOT EXISTS #{p}#{projection} (
        lang text NOT NULL,
        value text NOT NULL,
        #{owner_uuid_column} uuid NOT NULL REFERENCES #{p}#{owner}(uuid) ON DELETE CASCADE,
        PRIMARY KEY (lang, value)
      )
      """,
      "CREATE INDEX IF NOT EXISTS #{projection}_#{owner_uuid_column}_idx ON #{p}#{projection} (#{owner_uuid_column})",
      """
      CREATE OR REPLACE FUNCTION #{p}#{sync_function}() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        DELETE FROM #{p}#{projection} WHERE #{owner_uuid_column} = NEW.uuid;
        INSERT INTO #{p}#{projection} (lang, value, #{owner_uuid_column})
        SELECT DISTINCT lower(split_part(e.key, '-', 1)), e.value, NEW.uuid
          FROM jsonb_each_text(COALESCE(NEW.slug, '{}'::jsonb)) e
         WHERE e.value <> '';
        RETURN NEW;
      END $$
      """,
      "DROP TRIGGER IF EXISTS #{trigger} ON #{p}#{owner}",
      """
      CREATE TRIGGER #{trigger}
        AFTER INSERT OR UPDATE OF slug ON #{p}#{owner}
        FOR EACH ROW EXECUTE FUNCTION #{p}#{sync_function}()
      """,
      """
      INSERT INTO #{p}#{projection} (lang, value, #{owner_uuid_column})
      SELECT DISTINCT lower(split_part(e.key, '-', 1)), e.value, t.uuid
        FROM #{p}#{owner} t, jsonb_each_text(COALESCE(t.slug, '{}'::jsonb)) e
       WHERE e.value <> ''
      ON CONFLICT (lang, value) DO NOTHING
      """
    ]
  end

  @doc "The SQL `down/1` executes, as data (marker bookkeeping only)."
  @spec down_statements(String.t(), non_neg_integer()) :: [String.t()]
  def down_statements(prefix \\ "public", target \\ 0)
      when is_integer(target) and target >= 0 do
    prefix = validated_prefix(prefix: prefix)
    p = "#{prefix}."

    if target > 0 do
      ["COMMENT ON TABLE #{p}#{@version_table} IS '#{@marker_prefix}#{target}'"]
    else
      ["COMMENT ON TABLE #{p}#{@version_table} IS NULL"]
    end
  end

  # ── CREATE TABLE (core V135/V146/V149/V151/V173/V177/V178/V179/V180) ─

  defp tables(p) do
    [
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_cat_catalogues (
        uuid uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        name character varying(255) NOT NULL,
        description text,
        status character varying(20) DEFAULT 'active'::character varying,
        data jsonb DEFAULT '{}'::jsonb,
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL,
        markup_percentage numeric(7,2) DEFAULT 0 NOT NULL,
        discount_percentage numeric(7,2) DEFAULT 0 NOT NULL,
        kind character varying(20) DEFAULT 'standard'::character varying NOT NULL,
        "position" integer DEFAULT 0,
        folder_uuid uuid,
        CONSTRAINT phoenix_kit_cat_catalogues_discount_pct_check CHECK (((discount_percentage >= (0)::numeric) AND (discount_percentage <= (100)::numeric))),
        CONSTRAINT phoenix_kit_cat_catalogues_kind_check CHECK (((kind)::text = ANY (ARRAY[('standard'::character varying)::text, ('smart'::character varying)::text])))
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_cat_folders (
        uuid uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        name character varying(255) NOT NULL,
        parent_uuid uuid,
        "position" integer DEFAULT 0 NOT NULL,
        status character varying(255) DEFAULT 'active'::character varying NOT NULL,
        data jsonb DEFAULT '{}'::jsonb NOT NULL,
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_cat_categories (
        uuid uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        name character varying(255) NOT NULL,
        description text,
        "position" integer DEFAULT 0,
        status character varying(20) DEFAULT 'active'::character varying,
        catalogue_uuid uuid NOT NULL,
        data jsonb DEFAULT '{}'::jsonb,
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL,
        parent_uuid uuid
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_cat_manufacturers (
        uuid uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        name character varying(255) NOT NULL,
        description text,
        website character varying(500),
        contact_info character varying(500),
        logo_url character varying(500),
        notes text,
        status character varying(20) DEFAULT 'active'::character varying,
        data jsonb DEFAULT '{}'::jsonb,
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL,
        crm_company_uuid uuid
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_cat_suppliers (
        uuid uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        name character varying(255) NOT NULL,
        description text,
        website character varying(500),
        contact_info character varying(500),
        notes text,
        status character varying(20) DEFAULT 'active'::character varying,
        data jsonb DEFAULT '{}'::jsonb,
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL,
        crm_company_uuid uuid
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_cat_manufacturer_suppliers (
        uuid uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        manufacturer_uuid uuid CONSTRAINT phoenix_kit_cat_manufacturer_supplie_manufacturer_uuid_not_null NOT NULL,
        supplier_uuid uuid NOT NULL,
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL,
        manufacturer_source character varying(20) DEFAULT 'local'::character varying CONSTRAINT phoenix_kit_cat_manufacturer_suppl_manufacturer_source_not_null NOT NULL,
        supplier_source character varying(20) DEFAULT 'local'::character varying NOT NULL,
        CONSTRAINT phoenix_kit_cat_manufacturer_suppliers_mfr_source_check CHECK (((manufacturer_source)::text = ANY ((ARRAY['local'::character varying, 'crm_company'::character varying, 'crm_contact'::character varying])::text[]))),
        CONSTRAINT phoenix_kit_cat_manufacturer_suppliers_sup_source_check CHECK (((supplier_source)::text = ANY ((ARRAY['local'::character varying, 'crm_company'::character varying, 'crm_contact'::character varying])::text[])))
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_cat_items (
        uuid uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        name character varying(255) NOT NULL,
        description text,
        sku character varying(100),
        base_price numeric(12,2),
        unit character varying(20) DEFAULT 'piece'::character varying,
        status character varying(20) DEFAULT 'active'::character varying,
        category_uuid uuid,
        manufacturer_uuid uuid,
        data jsonb DEFAULT '{}'::jsonb,
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL,
        catalogue_uuid uuid,
        markup_percentage numeric(7,2),
        discount_percentage numeric(7,2),
        default_value numeric(12,4),
        default_unit character varying(20),
        "position" integer DEFAULT 0,
        primary_supplier_uuid uuid,
        manufacturer_source character varying(20) DEFAULT 'local'::character varying NOT NULL,
        manufacturer_name_snapshot character varying(255),
        CONSTRAINT phoenix_kit_cat_items_default_value_check CHECK (((default_value IS NULL) OR (default_value >= (0)::numeric))),
        CONSTRAINT phoenix_kit_cat_items_discount_pct_check CHECK (((discount_percentage IS NULL) OR ((discount_percentage >= (0)::numeric) AND (discount_percentage <= (100)::numeric)))),
        CONSTRAINT phoenix_kit_cat_items_manufacturer_source_check CHECK (((manufacturer_source)::text = ANY ((ARRAY['local'::character varying, 'crm_company'::character varying])::text[])))
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_cat_item_catalogue_rules (
        uuid uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        item_uuid uuid NOT NULL,
        referenced_catalogue_uuid uuid CONSTRAINT phoenix_kit_cat_item_catalog_referenced_catalogue_uuid_not_null NOT NULL,
        value numeric(12,4),
        unit character varying(20),
        "position" integer DEFAULT 0 NOT NULL,
        inserted_at timestamp with time zone DEFAULT now() NOT NULL,
        updated_at timestamp with time zone DEFAULT now() NOT NULL,
        CONSTRAINT phoenix_kit_cat_item_catalogue_rules_value_check CHECK (((value IS NULL) OR (value >= (0)::numeric)))
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_cat_item_supplier_info (
        uuid uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        item_uuid uuid NOT NULL,
        supplier_uuid uuid NOT NULL,
        supplier_sku character varying(100),
        supplier_name_snapshot character varying(255),
        unit_cost numeric(14,4),
        currency character varying(3),
        lead_time_days integer,
        min_order_qty numeric(14,4),
        valid_from date,
        valid_to date,
        "position" integer DEFAULT 0 NOT NULL,
        metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
        inserted_at timestamp with time zone DEFAULT now() NOT NULL,
        updated_at timestamp with time zone DEFAULT now() NOT NULL,
        supplier_source character varying(20) DEFAULT 'local'::character varying NOT NULL,
        is_primary boolean DEFAULT false NOT NULL,
        CONSTRAINT phoenix_kit_cat_item_supplier_info_supplier_source_check CHECK (((supplier_source)::text = ANY (ARRAY[('crm_company'::character varying)::text, ('crm_contact'::character varying)::text, ('local'::character varying)::text])))
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_cat_pdf_page_contents (
        content_hash character varying(64) NOT NULL,
        text text NOT NULL,
        inserted_at timestamp(0) without time zone NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_cat_pdfs (
        uuid uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        file_uuid uuid NOT NULL,
        original_filename character varying(500) NOT NULL,
        byte_size bigint,
        status character varying(20) DEFAULT 'active'::character varying NOT NULL,
        trashed_at timestamp(0) without time zone,
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_cat_pdf_pages (
        file_uuid uuid NOT NULL,
        page_number integer NOT NULL,
        content_hash character varying(64) NOT NULL,
        inserted_at timestamp(0) without time zone NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_cat_pdf_extractions (
        file_uuid uuid NOT NULL,
        extraction_status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
        page_count integer,
        extracted_at timestamp(0) without time zone,
        error_message text,
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_cat_attribute_groups (
        uuid uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        name character varying(255) NOT NULL,
        data jsonb DEFAULT '{}'::jsonb NOT NULL,
        status character varying(20) DEFAULT 'active'::character varying NOT NULL,
        "position" integer DEFAULT 0 NOT NULL,
        inserted_at timestamp with time zone DEFAULT now() NOT NULL,
        updated_at timestamp with time zone DEFAULT now() NOT NULL,
        CONSTRAINT phoenix_kit_cat_attribute_groups_status_check CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'archived'::character varying])::text[])))
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_cat_attributes (
        uuid uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        group_uuid uuid NOT NULL,
        key character varying(100) NOT NULL,
        name character varying(255) NOT NULL,
        data jsonb DEFAULT '{}'::jsonb NOT NULL,
        kind character varying(20) DEFAULT 'multi'::character varying NOT NULL,
        status character varying(20) DEFAULT 'active'::character varying NOT NULL,
        "position" integer DEFAULT 0 NOT NULL,
        inserted_at timestamp with time zone DEFAULT now() NOT NULL,
        updated_at timestamp with time zone DEFAULT now() NOT NULL,
        CONSTRAINT phoenix_kit_cat_attributes_kind_check CHECK (((kind)::text = ANY ((ARRAY['fixed'::character varying, 'multi'::character varying])::text[]))),
        CONSTRAINT phoenix_kit_cat_attributes_status_check CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'archived'::character varying])::text[])))
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_cat_attribute_values (
        uuid uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        attribute_uuid uuid NOT NULL,
        key character varying(100) NOT NULL,
        value character varying(255) NOT NULL,
        data jsonb DEFAULT '{}'::jsonb NOT NULL,
        is_default boolean DEFAULT false NOT NULL,
        status character varying(20) DEFAULT 'active'::character varying NOT NULL,
        "position" integer DEFAULT 0 NOT NULL,
        inserted_at timestamp with time zone DEFAULT now() NOT NULL,
        updated_at timestamp with time zone DEFAULT now() NOT NULL,
        CONSTRAINT phoenix_kit_cat_attribute_values_status_check CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'archived'::character varying])::text[])))
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_cat_item_attribute_groups (
        uuid uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        item_uuid uuid NOT NULL,
        attribute_group_uuid uuid CONSTRAINT phoenix_kit_cat_item_attribute_gr_attribute_group_uuid_not_null NOT NULL,
        "position" integer DEFAULT 0 NOT NULL,
        inserted_at timestamp with time zone DEFAULT now() NOT NULL,
        updated_at timestamp with time zone DEFAULT now() NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_cat_item_attribute_sets (
        item_uuid uuid NOT NULL,
        set_uuid uuid NOT NULL,
        "position" integer DEFAULT 0 NOT NULL,
        data jsonb DEFAULT '{}'::jsonb NOT NULL,
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL
      )
      """
    ]
  end

  # ── PRIMARY KEY guards (all 18 tables) ───────────────────────────────

  defp primary_keys(prefix, p) do
    [
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_catalogues",
        "phoenix_kit_cat_catalogues_pkey",
        "ALTER TABLE #{p}phoenix_kit_cat_catalogues ADD CONSTRAINT phoenix_kit_cat_catalogues_pkey PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_folders",
        "phoenix_kit_cat_folders_pkey",
        "ALTER TABLE #{p}phoenix_kit_cat_folders ADD CONSTRAINT phoenix_kit_cat_folders_pkey PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_categories",
        "phoenix_kit_cat_categories_pkey",
        "ALTER TABLE #{p}phoenix_kit_cat_categories ADD CONSTRAINT phoenix_kit_cat_categories_pkey PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_manufacturers",
        "phoenix_kit_cat_manufacturers_pkey",
        "ALTER TABLE #{p}phoenix_kit_cat_manufacturers ADD CONSTRAINT phoenix_kit_cat_manufacturers_pkey PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_suppliers",
        "phoenix_kit_cat_suppliers_pkey",
        "ALTER TABLE #{p}phoenix_kit_cat_suppliers ADD CONSTRAINT phoenix_kit_cat_suppliers_pkey PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_manufacturer_suppliers",
        "phoenix_kit_cat_manufacturer_suppliers_pkey",
        "ALTER TABLE #{p}phoenix_kit_cat_manufacturer_suppliers ADD CONSTRAINT phoenix_kit_cat_manufacturer_suppliers_pkey PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_items",
        "phoenix_kit_cat_items_pkey",
        "ALTER TABLE #{p}phoenix_kit_cat_items ADD CONSTRAINT phoenix_kit_cat_items_pkey PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_item_catalogue_rules",
        "phoenix_kit_cat_item_catalogue_rules_pkey",
        "ALTER TABLE #{p}phoenix_kit_cat_item_catalogue_rules ADD CONSTRAINT phoenix_kit_cat_item_catalogue_rules_pkey PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_item_supplier_info",
        "phoenix_kit_cat_item_supplier_info_pkey",
        "ALTER TABLE #{p}phoenix_kit_cat_item_supplier_info ADD CONSTRAINT phoenix_kit_cat_item_supplier_info_pkey PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_pdf_page_contents",
        "phoenix_kit_cat_pdf_page_contents_pkey",
        "ALTER TABLE #{p}phoenix_kit_cat_pdf_page_contents ADD CONSTRAINT phoenix_kit_cat_pdf_page_contents_pkey PRIMARY KEY (content_hash)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_pdfs",
        "phoenix_kit_cat_pdfs_pkey",
        "ALTER TABLE #{p}phoenix_kit_cat_pdfs ADD CONSTRAINT phoenix_kit_cat_pdfs_pkey PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_pdf_pages",
        "phoenix_kit_cat_pdf_pages_pkey",
        "ALTER TABLE #{p}phoenix_kit_cat_pdf_pages ADD CONSTRAINT phoenix_kit_cat_pdf_pages_pkey PRIMARY KEY (file_uuid, page_number)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_pdf_extractions",
        "phoenix_kit_cat_pdf_extractions_pkey",
        "ALTER TABLE #{p}phoenix_kit_cat_pdf_extractions ADD CONSTRAINT phoenix_kit_cat_pdf_extractions_pkey PRIMARY KEY (file_uuid)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_attribute_groups",
        "phoenix_kit_cat_attribute_groups_pkey",
        "ALTER TABLE #{p}phoenix_kit_cat_attribute_groups ADD CONSTRAINT phoenix_kit_cat_attribute_groups_pkey PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_attributes",
        "phoenix_kit_cat_attributes_pkey",
        "ALTER TABLE #{p}phoenix_kit_cat_attributes ADD CONSTRAINT phoenix_kit_cat_attributes_pkey PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_attribute_values",
        "phoenix_kit_cat_attribute_values_pkey",
        "ALTER TABLE #{p}phoenix_kit_cat_attribute_values ADD CONSTRAINT phoenix_kit_cat_attribute_values_pkey PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_item_attribute_groups",
        "phoenix_kit_cat_item_attribute_groups_pkey",
        "ALTER TABLE #{p}phoenix_kit_cat_item_attribute_groups ADD CONSTRAINT phoenix_kit_cat_item_attribute_groups_pkey PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_item_attribute_sets",
        "phoenix_kit_cat_item_attribute_sets_pkey",
        "ALTER TABLE #{p}phoenix_kit_cat_item_attribute_sets ADD CONSTRAINT phoenix_kit_cat_item_attribute_sets_pkey PRIMARY KEY (item_uuid, set_uuid)"
      )
    ]
  end

  # ── FOREIGN KEY guards (core's exact names; FKs to phoenix_kit_files kept verbatim) ──

  defp foreign_keys(prefix, p) do
    [
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_attribute_values",
        "phoenix_kit_cat_attribute_values_attribute_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_cat_attribute_values ADD CONSTRAINT phoenix_kit_cat_attribute_values_attribute_uuid_fkey FOREIGN KEY (attribute_uuid) REFERENCES #{p}phoenix_kit_cat_attributes(uuid) ON DELETE RESTRICT"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_attributes",
        "phoenix_kit_cat_attributes_group_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_cat_attributes ADD CONSTRAINT phoenix_kit_cat_attributes_group_uuid_fkey FOREIGN KEY (group_uuid) REFERENCES #{p}phoenix_kit_cat_attribute_groups(uuid) ON DELETE RESTRICT"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_catalogues",
        "phoenix_kit_cat_catalogues_folder_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_cat_catalogues ADD CONSTRAINT phoenix_kit_cat_catalogues_folder_uuid_fkey FOREIGN KEY (folder_uuid) REFERENCES #{p}phoenix_kit_cat_folders(uuid) ON DELETE SET NULL"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_categories",
        "phoenix_kit_cat_categories_catalogue_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_cat_categories ADD CONSTRAINT phoenix_kit_cat_categories_catalogue_uuid_fkey FOREIGN KEY (catalogue_uuid) REFERENCES #{p}phoenix_kit_cat_catalogues(uuid) ON DELETE CASCADE"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_categories",
        "phoenix_kit_cat_categories_parent_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_cat_categories ADD CONSTRAINT phoenix_kit_cat_categories_parent_uuid_fkey FOREIGN KEY (parent_uuid) REFERENCES #{p}phoenix_kit_cat_categories(uuid)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_folders",
        "phoenix_kit_cat_folders_parent_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_cat_folders ADD CONSTRAINT phoenix_kit_cat_folders_parent_uuid_fkey FOREIGN KEY (parent_uuid) REFERENCES #{p}phoenix_kit_cat_folders(uuid) ON DELETE SET NULL"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_item_attribute_groups",
        "phoenix_kit_cat_item_attribute_groups_attribute_group_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_cat_item_attribute_groups ADD CONSTRAINT phoenix_kit_cat_item_attribute_groups_attribute_group_uuid_fkey FOREIGN KEY (attribute_group_uuid) REFERENCES #{p}phoenix_kit_cat_attribute_groups(uuid) ON DELETE RESTRICT"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_item_attribute_groups",
        "phoenix_kit_cat_item_attribute_groups_item_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_cat_item_attribute_groups ADD CONSTRAINT phoenix_kit_cat_item_attribute_groups_item_uuid_fkey FOREIGN KEY (item_uuid) REFERENCES #{p}phoenix_kit_cat_items(uuid) ON DELETE CASCADE"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_item_attribute_sets",
        "phoenix_kit_cat_item_attribute_sets_item_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_cat_item_attribute_sets ADD CONSTRAINT phoenix_kit_cat_item_attribute_sets_item_uuid_fkey FOREIGN KEY (item_uuid) REFERENCES #{p}phoenix_kit_cat_items(uuid) ON DELETE CASCADE"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_item_catalogue_rules",
        "phoenix_kit_cat_item_catalogue_r_referenced_catalogue_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_cat_item_catalogue_rules ADD CONSTRAINT phoenix_kit_cat_item_catalogue_r_referenced_catalogue_uuid_fkey FOREIGN KEY (referenced_catalogue_uuid) REFERENCES #{p}phoenix_kit_cat_catalogues(uuid) ON DELETE CASCADE"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_item_catalogue_rules",
        "phoenix_kit_cat_item_catalogue_rules_item_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_cat_item_catalogue_rules ADD CONSTRAINT phoenix_kit_cat_item_catalogue_rules_item_uuid_fkey FOREIGN KEY (item_uuid) REFERENCES #{p}phoenix_kit_cat_items(uuid) ON DELETE CASCADE"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_item_supplier_info",
        "phoenix_kit_cat_item_supplier_info_item_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_cat_item_supplier_info ADD CONSTRAINT phoenix_kit_cat_item_supplier_info_item_uuid_fkey FOREIGN KEY (item_uuid) REFERENCES #{p}phoenix_kit_cat_items(uuid) ON DELETE CASCADE"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_items",
        "phoenix_kit_cat_items_catalogue_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_cat_items ADD CONSTRAINT phoenix_kit_cat_items_catalogue_uuid_fkey FOREIGN KEY (catalogue_uuid) REFERENCES #{p}phoenix_kit_cat_catalogues(uuid) ON DELETE SET NULL"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_items",
        "phoenix_kit_cat_items_category_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_cat_items ADD CONSTRAINT phoenix_kit_cat_items_category_uuid_fkey FOREIGN KEY (category_uuid) REFERENCES #{p}phoenix_kit_cat_categories(uuid) ON DELETE SET NULL"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_items",
        "phoenix_kit_cat_items_primary_supplier_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_cat_items ADD CONSTRAINT phoenix_kit_cat_items_primary_supplier_uuid_fkey FOREIGN KEY (primary_supplier_uuid) REFERENCES #{p}phoenix_kit_cat_suppliers(uuid) ON DELETE SET NULL"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_pdf_extractions",
        "phoenix_kit_cat_pdf_extractions_file_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_cat_pdf_extractions ADD CONSTRAINT phoenix_kit_cat_pdf_extractions_file_uuid_fkey FOREIGN KEY (file_uuid) REFERENCES #{p}phoenix_kit_files(uuid) ON DELETE CASCADE"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_pdf_pages",
        "phoenix_kit_cat_pdf_pages_content_hash_fkey",
        "ALTER TABLE #{p}phoenix_kit_cat_pdf_pages ADD CONSTRAINT phoenix_kit_cat_pdf_pages_content_hash_fkey FOREIGN KEY (content_hash) REFERENCES #{p}phoenix_kit_cat_pdf_page_contents(content_hash) ON DELETE RESTRICT"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_pdf_pages",
        "phoenix_kit_cat_pdf_pages_file_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_cat_pdf_pages ADD CONSTRAINT phoenix_kit_cat_pdf_pages_file_uuid_fkey FOREIGN KEY (file_uuid) REFERENCES #{p}phoenix_kit_files(uuid) ON DELETE CASCADE"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_pdfs",
        "phoenix_kit_cat_pdfs_file_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_cat_pdfs ADD CONSTRAINT phoenix_kit_cat_pdfs_file_uuid_fkey FOREIGN KEY (file_uuid) REFERENCES #{p}phoenix_kit_files(uuid) ON DELETE RESTRICT"
      )
    ]
  end

  # ── CHECK constraint guards (core's exact names/expressions; also ride
  # inline inside CREATE TABLE above — these repair a pre-existing table
  # that's missing one) ────────────────────────────────────────────────

  defp checks(prefix, p) do
    [
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_catalogues",
        "phoenix_kit_cat_catalogues_discount_pct_check",
        "ALTER TABLE #{p}phoenix_kit_cat_catalogues ADD CONSTRAINT phoenix_kit_cat_catalogues_discount_pct_check CHECK (((discount_percentage >= (0)::numeric) AND (discount_percentage <= (100)::numeric)))"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_catalogues",
        "phoenix_kit_cat_catalogues_kind_check",
        "ALTER TABLE #{p}phoenix_kit_cat_catalogues ADD CONSTRAINT phoenix_kit_cat_catalogues_kind_check CHECK (((kind)::text = ANY (ARRAY[('standard'::character varying)::text, ('smart'::character varying)::text])))"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_manufacturer_suppliers",
        "phoenix_kit_cat_manufacturer_suppliers_mfr_source_check",
        "ALTER TABLE #{p}phoenix_kit_cat_manufacturer_suppliers ADD CONSTRAINT phoenix_kit_cat_manufacturer_suppliers_mfr_source_check CHECK (((manufacturer_source)::text = ANY ((ARRAY['local'::character varying, 'crm_company'::character varying, 'crm_contact'::character varying])::text[])))"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_manufacturer_suppliers",
        "phoenix_kit_cat_manufacturer_suppliers_sup_source_check",
        "ALTER TABLE #{p}phoenix_kit_cat_manufacturer_suppliers ADD CONSTRAINT phoenix_kit_cat_manufacturer_suppliers_sup_source_check CHECK (((supplier_source)::text = ANY ((ARRAY['local'::character varying, 'crm_company'::character varying, 'crm_contact'::character varying])::text[])))"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_items",
        "phoenix_kit_cat_items_default_value_check",
        "ALTER TABLE #{p}phoenix_kit_cat_items ADD CONSTRAINT phoenix_kit_cat_items_default_value_check CHECK (((default_value IS NULL) OR (default_value >= (0)::numeric)))"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_items",
        "phoenix_kit_cat_items_discount_pct_check",
        "ALTER TABLE #{p}phoenix_kit_cat_items ADD CONSTRAINT phoenix_kit_cat_items_discount_pct_check CHECK (((discount_percentage IS NULL) OR ((discount_percentage >= (0)::numeric) AND (discount_percentage <= (100)::numeric))))"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_items",
        "phoenix_kit_cat_items_manufacturer_source_check",
        "ALTER TABLE #{p}phoenix_kit_cat_items ADD CONSTRAINT phoenix_kit_cat_items_manufacturer_source_check CHECK (((manufacturer_source)::text = ANY ((ARRAY['local'::character varying, 'crm_company'::character varying])::text[])))"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_item_catalogue_rules",
        "phoenix_kit_cat_item_catalogue_rules_value_check",
        "ALTER TABLE #{p}phoenix_kit_cat_item_catalogue_rules ADD CONSTRAINT phoenix_kit_cat_item_catalogue_rules_value_check CHECK (((value IS NULL) OR (value >= (0)::numeric)))"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_item_supplier_info",
        "phoenix_kit_cat_item_supplier_info_supplier_source_check",
        "ALTER TABLE #{p}phoenix_kit_cat_item_supplier_info ADD CONSTRAINT phoenix_kit_cat_item_supplier_info_supplier_source_check CHECK (((supplier_source)::text = ANY (ARRAY[('crm_company'::character varying)::text, ('crm_contact'::character varying)::text, ('local'::character varying)::text])))"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_attribute_groups",
        "phoenix_kit_cat_attribute_groups_status_check",
        "ALTER TABLE #{p}phoenix_kit_cat_attribute_groups ADD CONSTRAINT phoenix_kit_cat_attribute_groups_status_check CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'archived'::character varying])::text[])))"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_attributes",
        "phoenix_kit_cat_attributes_kind_check",
        "ALTER TABLE #{p}phoenix_kit_cat_attributes ADD CONSTRAINT phoenix_kit_cat_attributes_kind_check CHECK (((kind)::text = ANY ((ARRAY['fixed'::character varying, 'multi'::character varying])::text[])))"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_attributes",
        "phoenix_kit_cat_attributes_status_check",
        "ALTER TABLE #{p}phoenix_kit_cat_attributes ADD CONSTRAINT phoenix_kit_cat_attributes_status_check CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'archived'::character varying])::text[])))"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_cat_attribute_values",
        "phoenix_kit_cat_attribute_values_status_check",
        "ALTER TABLE #{p}phoenix_kit_cat_attribute_values ADD CONSTRAINT phoenix_kit_cat_attribute_values_status_check CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'archived'::character varying])::text[])))"
      )
    ]
  end

  # ── indexes (all natively idempotent via IF NOT EXISTS) ──────────────

  defp indexes(p) do
    [
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_cat_attribute_values_attr_key_index ON #{p}phoenix_kit_cat_attribute_values USING btree (attribute_uuid, key)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_cat_attribute_values_attr_position_index ON #{p}phoenix_kit_cat_attribute_values USING btree (attribute_uuid, \"position\")",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_cat_attribute_values_default_index ON #{p}phoenix_kit_cat_attribute_values USING btree (attribute_uuid) WHERE is_default",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_cat_attributes_group_key_index ON #{p}phoenix_kit_cat_attributes USING btree (group_uuid, key)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_cat_attributes_group_position_index ON #{p}phoenix_kit_cat_attributes USING btree (group_uuid, \"position\")",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_cat_catalogues_folder_uuid_index ON #{p}phoenix_kit_cat_catalogues USING btree (folder_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_cat_catalogues_kind_smart_index ON #{p}phoenix_kit_cat_catalogues USING btree (uuid) WHERE ((kind)::text = 'smart'::text)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_cat_catalogues_status_index ON #{p}phoenix_kit_cat_catalogues USING btree (status)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_cat_categories_catalogue_uuid_index ON #{p}phoenix_kit_cat_categories USING btree (catalogue_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_cat_categories_catalogue_uuid_position_index ON #{p}phoenix_kit_cat_categories USING btree (catalogue_uuid, \"position\")",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_cat_categories_parent_index ON #{p}phoenix_kit_cat_categories USING btree (parent_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_cat_categories_status_index ON #{p}phoenix_kit_cat_categories USING btree (status)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_cat_folders_parent_uuid_position_index ON #{p}phoenix_kit_cat_folders USING btree (parent_uuid, \"position\")",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_cat_folders_status_index ON #{p}phoenix_kit_cat_folders USING btree (status)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_cat_item_attr_groups_group_index ON #{p}phoenix_kit_cat_item_attribute_groups USING btree (attribute_group_uuid)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_cat_item_attr_groups_item_index ON #{p}phoenix_kit_cat_item_attribute_groups USING btree (item_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_cat_item_attribute_sets_set_uuid_index ON #{p}phoenix_kit_cat_item_attribute_sets USING btree (set_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_cat_item_catalogue_rules_item_index ON #{p}phoenix_kit_cat_item_catalogue_rules USING btree (item_uuid)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_cat_item_catalogue_rules_pair_index ON #{p}phoenix_kit_cat_item_catalogue_rules USING btree (item_uuid, referenced_catalogue_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_cat_item_catalogue_rules_referenced_index ON #{p}phoenix_kit_cat_item_catalogue_rules USING btree (referenced_catalogue_uuid)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_cat_item_supplier_info_current_pair_uniq ON #{p}phoenix_kit_cat_item_supplier_info USING btree (item_uuid, supplier_uuid) WHERE (valid_to IS NULL)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_cat_item_supplier_info_item_index ON #{p}phoenix_kit_cat_item_supplier_info USING btree (item_uuid)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_cat_item_supplier_info_primary_uniq ON #{p}phoenix_kit_cat_item_supplier_info USING btree (item_uuid) WHERE is_primary",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_cat_item_supplier_info_supplier_index ON #{p}phoenix_kit_cat_item_supplier_info USING btree (supplier_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_cat_items_catalogue_uuid_index ON #{p}phoenix_kit_cat_items USING btree (catalogue_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_cat_items_catalogue_uuid_status_index ON #{p}phoenix_kit_cat_items USING btree (catalogue_uuid, status)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_cat_items_category_uuid_index ON #{p}phoenix_kit_cat_items USING btree (category_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_cat_items_manufacturer_uuid_index ON #{p}phoenix_kit_cat_items USING btree (manufacturer_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_cat_items_primary_supplier_uuid_index ON #{p}phoenix_kit_cat_items USING btree (primary_supplier_uuid) WHERE (primary_supplier_uuid IS NOT NULL)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_cat_items_status_index ON #{p}phoenix_kit_cat_items USING btree (status)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_cat_manufacturer_suppliers_manufacturer_uuid_suppli ON #{p}phoenix_kit_cat_manufacturer_suppliers USING btree (manufacturer_uuid, supplier_uuid)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_cat_manufacturers_crm_company_uuid_index ON #{p}phoenix_kit_cat_manufacturers USING btree (crm_company_uuid) WHERE (crm_company_uuid IS NOT NULL)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_cat_manufacturers_status_index ON #{p}phoenix_kit_cat_manufacturers USING btree (status)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_cat_pdf_extractions_extraction_status_index ON #{p}phoenix_kit_cat_pdf_extractions USING btree (extraction_status)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_cat_pdf_page_contents_text_trgm_index ON #{p}phoenix_kit_cat_pdf_page_contents USING gin (text public.gin_trgm_ops)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_cat_pdf_pages_content_hash_index ON #{p}phoenix_kit_cat_pdf_pages USING btree (content_hash)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_cat_pdfs_file_uuid_index ON #{p}phoenix_kit_cat_pdfs USING btree (file_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_cat_pdfs_status_index ON #{p}phoenix_kit_cat_pdfs USING btree (status)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_cat_suppliers_crm_company_uuid_index ON #{p}phoenix_kit_cat_suppliers USING btree (crm_company_uuid) WHERE (crm_company_uuid IS NOT NULL)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_cat_suppliers_status_index ON #{p}phoenix_kit_cat_suppliers USING btree (status)"
    ]
  end

  defp guarded_constraint(prefix, table, constraint_name, add_sql) do
    """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE c.conname = '#{constraint_name}'
          AND t.relname = '#{table}'
          AND n.nspname = '#{prefix}'
      ) THEN
        #{add_sql};
      END IF;
    END
    $$
    """
  end

  defp marker_query do
    """
    SELECT d.description
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_description d
      ON d.objoid = c.oid AND d.objsubid = 0 AND d.classoid = 'pg_class'::regclass
    WHERE n.nspname = $1 AND c.relname = '#{@version_table}' AND c.relkind = 'r'
    """
  end

  defp marker_to_version([@marker_prefix <> n]) do
    case Integer.parse(n) do
      {v, ""} when v >= 0 -> v
      _ -> 0
    end
  end

  defp marker_to_version(_), do: 0

  defp validated_prefix(opts) do
    prefix =
      case opts do
        opts when is_list(opts) -> Keyword.get(opts, :prefix) || "public"
        %{prefix: prefix} when is_binary(prefix) -> prefix
        _ -> "public"
      end

    unless prefix =~ ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/ do
      raise ArgumentError, "invalid schema prefix: #{inspect(prefix)}"
    end

    prefix
  end
end
