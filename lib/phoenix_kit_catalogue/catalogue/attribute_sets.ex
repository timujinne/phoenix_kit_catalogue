defmodule PhoenixKitCatalogue.Catalogue.AttributeSets do
  @moduledoc """
  Attribute SETS — the 2026-08-18 rework of the group/attribute system.

  A set is one dimension from one vendor ("Ikea colors"), stored as a
  MANAGED entities blueprint (created only through this module, hidden
  from the generic entities admin); its data records are the values.
  Items attach any number of sets through the catalogue-owned
  `phoenix_kit_cat_item_attribute_sets` join (V177).

  ## The blueprint contract

      name:      "catalogue_set_<slug>"          (immutable identity)
      settings:  "managed_by"  => "catalogue"
                 "locked_keys" => ["kind", "default_value_slug"]
                 "catalogue"   => %{"kind" => "fixed" | "multi",
                                    "default_value_slug" => slug | nil}
      records:   slug = the value's stable key, title = display text,
                 position = order, data = extras (per-set fields)

  Everything else on the blueprint (display name, translations,
  `fields_definition` extras like "price per liter") is freely editable.
  `contract/1` validates the shape on every resolve; a broken contract
  is surfaced (`{:error, :contract_broken}`), never guessed around.

  ## Enablement

  Requires the entities module (`PhoenixKitEntities.enabled?/0`). Every
  WRITE returns `{:error, :entities_disabled}` when it is off — same
  loud-failure doctrine as the `:catalogue_pdf` queue guard. Reads
  degrade quietly instead (`[]`, `nil`, `%{}`, `0`): UI callers render
  empty rather than crash during a feature toggle.

  Public surface re-exported from `PhoenixKitCatalogue.Catalogue`.
  """

  import Ecto.Query
  require Logger

  alias PhoenixKitCatalogue.Catalogue.ActivityLog
  alias PhoenixKitCatalogue.Catalogue.Helpers
  alias PhoenixKitCatalogue.Catalogue.PubSub
  alias PhoenixKitCatalogue.Schemas.Item
  alias PhoenixKitCatalogue.Schemas.ItemAttributeSet

  @owner "catalogue"
  @slug_prefix "catalogue_set_"
  @locked_keys ["kind", "default_value_slug"]
  @kinds ~w(fixed multi)

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc """
  True when the sets feature is live: the entities module is enabled
  AND its package carries the Managed API (entities > 0.4.0) — on an
  older package the whole feature degrades to `:entities_disabled`
  rather than crashing on missing functions. UI surfaces branch on
  this to decide sets-vs-legacy rendering.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Code.ensure_loaded?(PhoenixKitEntities) and
      Code.ensure_loaded?(PhoenixKitEntities.Managed) and
      PhoenixKitEntities.enabled?()
  end

  defp entities_enabled?, do: enabled?()

  # ── Startup registration ───────────────────────────────────────────

  @doc """
  Registers the catalogue's blueprint delete guard with entities.
  Ships as a supervision child via `PhoenixKitCatalogue.children/0`, so
  it runs once per boot; deleting a set with item attachments is
  refused at the entities write path.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    %{
      id: __MODULE__.GuardRegistration,
      start: {Task, :start_link, [&__MODULE__.startup/0]},
      restart: :temporary
    }
  end

  @doc false
  @spec startup() :: :ok
  def startup do
    register_deletion_guard()
    auto_migrate_legacy()
  end

  @doc """
  Migrates any remaining legacy groups into sets, silently and safely —
  there is no legacy UI once sets are live ("it should just migrate",
  boss direction 2026-08-18), so this runs from the supervision-tree
  startup task and again from the attributes page as a backstop (boot
  can race the repo/settings, and entities can be enabled at runtime).

  Never raises: any failure is logged and swallowed — a broken
  migration must not take down boot or an admin page. Idempotent by
  way of `migrate_groups_to_sets/1`.
  """
  @spec auto_migrate_legacy() :: :ok
  def auto_migrate_legacy do
    if enabled?() and PhoenixKitCatalogue.Catalogue.list_attribute_groups() != [] do
      case migrate_groups_to_sets() do
        {:ok, %{sets: 0, values: 0, attachments: 0}} ->
          :ok

        {:ok, counts} ->
          Logger.info("AttributeSets: auto-migrated legacy groups — #{inspect(counts)}")

        {:error, reason} ->
          Logger.warning("AttributeSets: legacy auto-migration failed: #{inspect(reason)}")
      end
    end

    :ok
  rescue
    # Bounded inspect: a failed value write raises with the whole
    # changeset (record titles + extras) in the term — log a truncated
    # form, not an unbounded blob of business content.
    error ->
      Logger.warning(
        "AttributeSets: legacy auto-migration crashed: " <>
          inspect(error, limit: 10, printable_limit: 500)
      )

      :ok
  catch
    :exit, reason ->
      Logger.warning(
        "AttributeSets: legacy auto-migration exited: " <>
          inspect(reason, limit: 10, printable_limit: 500)
      )

      :ok
  end

  @doc false
  @spec register_deletion_guard() :: :ok
  def register_deletion_guard do
    if Code.ensure_loaded?(PhoenixKitEntities.Managed) do
      # EXTERNAL capture, never `&deletion_guard/1`: a local fun pins the
      # module version that registered it, and after a second code purge
      # (dev reloads, hot upgrades) calling it from :persistent_term is a
      # badfun crash. The external capture dispatches to the current
      # module version at call time (panel finding, 2026-08-18 review).
      PhoenixKitEntities.Managed.register_delete_guard(@owner, &__MODULE__.deletion_guard/1)
    end

    :ok
  end

  # The cross-module contract entities' Managed.run_delete_guard/2
  # pattern-matches on — must stay public (invoked via :persistent_term).
  @doc false
  @spec deletion_guard(struct()) :: :ok | {:error, :set_in_use}
  def deletion_guard(entity) do
    if set_attached?(entity.uuid), do: {:error, :set_in_use}, else: :ok
  end

  # ── Set CRUD (provisioned blueprints) ──────────────────────────────

  @doc """
  Provisions a new set: a managed blueprint from the locked template.

  `attrs`: `:name` (display, required), `:slug` (optional — derived
  from the name when absent), `:kind` (`"fixed"`/`"multi"`, default
  `"multi"`), `:description`.
  """
  @spec create_set(map(), keyword()) :: {:ok, struct()} | {:error, term()}
  def create_set(attrs, opts \\ []) do
    with :ok <- ensure_enabled(),
         {:ok, kind} <- validate_kind(Map.get(attrs, :kind, "multi")) do
      display = String.trim(Map.get(attrs, :name, ""))
      slug = @slug_prefix <> (Map.get(attrs, :slug) || slugify_name(display))

      %{
        name: slug,
        display_name: display,
        display_name_plural: display,
        description: Map.get(attrs, :description),
        status: "published",
        fields_definition: [],
        settings: %{
          "managed_by" => @owner,
          "locked_keys" => @locked_keys,
          "sort_mode" => "manual",
          "catalogue" => %{"kind" => kind, "default_value_slug" => nil}
        }
      }
      |> maybe_put_creator(opts)
      |> PhoenixKitEntities.create_entity(on_behalf_of: @owner)
      |> tap_log("attribute_set.created", opts, & &1.uuid, fn set ->
        %{"name" => set.display_name, "slug" => set.name, "kind" => kind}
      end)
    end
  end

  @doc "Lists the catalogue's sets (managed blueprints), locale-resolved."
  @spec list_sets(keyword()) :: [struct()]
  def list_sets(opts \\ []) do
    if entities_enabled?() do
      PhoenixKitEntities.list_entities(lang: opts[:lang])
      |> Enum.filter(&(PhoenixKitEntities.Managed.owner(&1) == @owner))
    else
      []
    end
  end

  @doc "Fetches one set by blueprint uuid (nil when missing/not a set)."
  @spec get_set(Ecto.UUID.t(), keyword()) :: struct() | nil
  def get_set(uuid, opts \\ []) do
    with true <- entities_enabled?(),
         %{} = entity <- PhoenixKitEntities.get_entity(uuid, lang: opts[:lang]),
         @owner <- PhoenixKitEntities.Managed.owner(entity) do
      entity
    else
      _ -> nil
    end
  end

  @doc """
  Updates a set's unlocked surface: `:name` (display), `:description`,
  `:kind`, `:default_value_slug`. Kind/default ride the owner bypass —
  they are locked against GENERIC writes, not against this module.
  """
  @spec update_set(struct(), map(), keyword()) :: {:ok, struct()} | {:error, term()}
  def update_set(set, attrs, opts \\ []) do
    # Re-read before the settings read-modify-write: the WHOLE settings
    # map is written back below, so a stale caller struct would clobber
    # keys another writer changed meanwhile (managed markers, migration
    # provenance) — same doctrine as the extra-field functions.
    set = get_set(set.uuid) || set
    default_slug = Map.get(attrs, :default_value_slug, current_default(set))

    with :ok <- ensure_enabled(),
         {:ok, kind} <- validate_kind(Map.get(attrs, :kind, current_kind(set))),
         :ok <- validate_default_slug(set, default_slug) do
      catalogue_settings =
        (set.settings["catalogue"] || %{})
        |> Map.put("kind", kind)
        |> Map.put("default_value_slug", default_slug)

      entity_attrs =
        %{settings: Map.put(set.settings, "catalogue", catalogue_settings)}
        |> maybe_put(:display_name, Map.get(attrs, :name))
        |> maybe_put(:display_name_plural, Map.get(attrs, :name))
        |> maybe_put(:description, Map.get(attrs, :description))

      set
      |> PhoenixKitEntities.update_entity(entity_attrs, on_behalf_of: @owner)
      |> tap_log("attribute_set.updated", opts, & &1.uuid, fn s ->
        %{"name" => s.display_name}
      end)
    end
  end

  @doc """
  Deletes a set. Refused (`{:error, :set_in_use}`) while any item
  attaches it — the same guard entities consults on its own delete path.
  """
  @spec delete_set(struct(), keyword()) :: {:ok, struct()} | {:error, term()}
  def delete_set(set, opts \\ []) do
    with :ok <- ensure_enabled() do
      # The attachment check runs here AND via the registered
      # entities-side guard (belt and suspenders), both under the same
      # per-set advisory lock `attach_set/3` takes — closing the
      # check-then-delete window a concurrent attach could slip through.
      repo().transaction(fn -> locked_delete(set) end)
      |> tap_log("attribute_set.deleted", opts, & &1.uuid, fn s ->
        %{"name" => s.display_name, "slug" => s.name}
      end)
    end
  end

  defp locked_delete(set) do
    lock_set(set.uuid)

    with :ok <- ensure_not_attached(set.uuid),
         {:ok, deleted} <- PhoenixKitEntities.delete_entity(set, on_behalf_of: @owner) do
      deleted
    else
      {:error, reason} -> repo().rollback(reason)
    end
  end

  defp ensure_not_attached(set_uuid) do
    if set_attached?(set_uuid), do: {:error, :set_in_use}, else: :ok
  end

  # ── Values (entity data records) ───────────────────────────────────

  @doc """
  Adds a value to a set. `attrs`: `:label` (required), `:slug`
  (derived from label when absent), `:extras` (map merged into the
  record's data — cast against the blueprint's fields the same way
  `update_value/4` casts them).
  """
  @spec create_value(struct(), map(), keyword()) :: {:ok, struct()} | {:error, term()}
  def create_value(set, attrs, opts \\ []) do
    with :ok <- ensure_enabled(),
         {:ok, extras} <- cast_extras(set, Map.get(attrs, :extras)) do
      label = String.trim(Map.get(attrs, :label, ""))

      %{
        entity_uuid: set.uuid,
        title: label,
        slug: value_slug(set, Map.get(attrs, :slug), label),
        status: "published",
        data: extras || %{}
      }
      |> maybe_put_creator(opts)
      # activity_log: false — this module writes its own richer
      # attribute_set.value_created row below; without the flag every
      # add double-logs (entities' entity_data.created + ours).
      |> PhoenixKitEntities.EntityData.create(activity_log: false)
      |> tap_log("attribute_set.value_created", opts, & &1.entity_uuid, fn v ->
        %{"set" => set.name, "value" => v.slug}
      end)
    end
  end

  # Value slugs are the stable per-value selection keys, so they must be
  # non-empty and unique within the set. Both invariants break in the
  # wild (panel finding, 2026-08-19 review): a non-Latin label
  # ("Красный") slugifies to "", and a repeated label collides — either
  # way every affected chip shares one key and ticks/unticks together.
  # Mirror the migration's fallback: short random uid.
  defp value_slug(set, explicit_slug, label) do
    base =
      case explicit_slug || slugify_value(label) do
        "" -> "value-" <> random_uid()
        slug -> slug
      end

    taken = set |> list_values() |> MapSet.new(& &1.slug)
    if MapSet.member?(taken, base), do: base <> "-" <> random_uid(), else: base
  end

  defp random_uid do
    Ecto.UUID.generate() |> String.replace("-", "") |> binary_part(0, 8)
  end

  @doc "Lists a set's values in display order, locale-resolved."
  @spec list_values(struct() | Ecto.UUID.t(), keyword()) :: [struct()]
  def list_values(set_or_uuid, opts \\ [])
  def list_values(%{uuid: uuid}, opts), do: list_values(uuid, opts)

  def list_values(set_uuid, opts) when is_binary(set_uuid) do
    if entities_enabled?() do
      [set_uuid] |> list_values_for(opts) |> Map.get(set_uuid, [])
    else
      []
    end
  end

  @doc """
  Values for MANY sets at once: `%{set_uuid => [value]}`, archived excluded.

  The batched twin of `list_values/2`. A listing that shows a preview of each
  set's values must not call the singular form per row — the sets listing did,
  and paged 25 at a time, so opening the Attributes tab cost 25 queries and
  repeated them on every attribute or item broadcast.

  `:limit` is PER SET. The batched entities API filters status in SQL, which is
  what makes that limit mean what it says; the fallback for an older entities
  pin cannot, so it over-fetches and trims — asking for 5 and getting 3 reads
  as "there are only 3".
  """
  @spec list_values_for([Ecto.UUID.t()], keyword()) :: %{optional(Ecto.UUID.t()) => [struct()]}
  def list_values_for(set_uuids, opts \\ [])
  def list_values_for([], _opts), do: %{}

  def list_values_for(set_uuids, opts) when is_list(set_uuids) do
    # Gated like its singular twin. This was private when it had one caller
    # that had already asked; making it public — and delegating to it from
    # `Catalogue.list_attribute_set_values_for/2` — put a read on the public
    # surface that answers with live data while every sibling read degrades
    # to empty with the feature off. The module's contract (see the moduledoc)
    # is that reads degrade quietly: `[]`, `nil`, `%{}`, `0`.
    #
    # It also guards the fallback below: without entities loaded at all,
    # `batch.list_by_entity/2` is a call into a module that is not there.
    if entities_enabled?() do
      do_list_values_for(set_uuids, opts)
    else
      %{}
    end
  end

  defp do_list_values_for(set_uuids, opts) do
    batch = PhoenixKitEntities.EntityData
    limit = opts[:limit]

    if Code.ensure_loaded?(batch) and function_exported?(batch, :list_by_entities, 2) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(batch, :list_by_entities, [
        set_uuids,
        [
          lang: opts[:lang],
          limit: limit,
          exclude_statuses: ["archived"],
          preload: []
        ]
      ])
    else
      fetch = if limit, do: [lang: opts[:lang], limit: limit + 5], else: [lang: opts[:lang]]

      Map.new(set_uuids, fn uuid ->
        values =
          uuid
          |> batch.list_by_entity(fetch)
          |> Enum.reject(&(&1.status == "archived"))

        {uuid, if(limit, do: Enum.take(values, limit), else: values)}
      end)
    end
  end

  @doc """
  Of the given sets, which have at least one VALUE whose label matches
  `term`? Returns a list of set uuids — the listing search uses it
  to find a set by what is IN it ("oak" finds the color set), not only
  by its own name.

  One batched query where the entities pin carries the API; the
  fallback is the older global title search, intersected here. Archived
  values are excluded, matching `list_values/2`.
  """
  @spec set_uuids_matching_value([Ecto.UUID.t()], String.t()) :: [Ecto.UUID.t()]
  def set_uuids_matching_value([], _term), do: []

  def set_uuids_matching_value(set_uuids, term) when is_list(set_uuids) and is_binary(term) do
    batch = PhoenixKitEntities.EntityData

    cond do
      not entities_enabled?() or String.trim(term) == "" ->
        []

      Code.ensure_loaded?(batch) and function_exported?(batch, :entity_uuids_matching_title, 3) ->
        # apply/3 on purpose: a direct call compiles as an undefined-
        # function warning against the released entities pin, which
        # doesn't carry the batch matcher yet.
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(batch, :entity_uuids_matching_title, [
          set_uuids,
          term,
          [exclude_statuses: ["archived"]]
        ])

      true ->
        # Released entities without the batch matcher: the global title
        # search, narrowed here. Heavier (it loads matching rows across
        # every entity, preloads and all) but it still finds the set —
        # degrading to name-only search would be a silent wrong answer.
        wanted = MapSet.new(set_uuids)

        term
        |> String.trim()
        |> batch.search_by_title()
        |> Enum.reject(&(&1.status == "archived"))
        |> Enum.map(& &1.entity_uuid)
        |> Enum.filter(&MapSet.member?(wanted, &1))
        |> Enum.uniq()
    end
  end

  @doc """
  Value counts for many sets at once: `%{set_uuid => count}`, matching
  `list_values/2`'s semantics (archived and trashed excluded). One
  grouped query — the viewer must not COUNT per row.
  """
  @spec value_counts([Ecto.UUID.t()]) :: %{optional(Ecto.UUID.t()) => non_neg_integer()}
  def value_counts([]), do: %{}

  def value_counts(set_uuids) when is_list(set_uuids) do
    batch = PhoenixKitEntities.EntityData

    cond do
      not entities_enabled?() ->
        %{}

      Code.ensure_loaded?(batch) and function_exported?(batch, :counts_by_entities, 2) ->
        # apply/3 on purpose: a direct call compiles as an undefined-
        # function warning against the released entities pin, which
        # doesn't carry the batch API yet.
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(batch, :counts_by_entities, [set_uuids, [exclude_statuses: ["archived"]]])

      true ->
        # Released entities without the batch API yet: one COUNT per set —
        # still counts, just not batched, and it tallies archived values
        # the batch would exclude (a small drift the pin release closes).
        Map.new(set_uuids, &{&1, PhoenixKitEntities.EntityData.count_by_entity(&1)})
    end
  end

  @doc "Fetches one value record, scoped to the set (nil when foreign/missing)."
  @spec get_value(struct(), Ecto.UUID.t()) :: struct() | nil
  def get_value(set, value_uuid) when is_binary(value_uuid) do
    with true <- entities_enabled?(),
         %{entity_uuid: entity_uuid} = record <- PhoenixKitEntities.EntityData.get(value_uuid),
         true <- entity_uuid == set.uuid do
      record
    else
      _ -> nil
    end
  end

  def get_value(_set, _), do: nil

  @doc """
  Updates a value: `:label` rewrites the display text (the slug — the
  stable key — never changes), `:extras` merges into the record data.

  Extras are cast per field type through the entities pipeline
  (`FormBuilder.cast_field/2`): raw form strings coerce ("12.5" →
  12.5, "" clears), invalid content returns `{:error, :invalid_value}`
  and unknown keys `{:error, :unknown_field}` — never a silent junk
  write.
  """
  @spec update_value(struct(), struct(), map(), keyword()) :: {:ok, struct()} | {:error, term()}
  def update_value(set, value, attrs, opts \\ []) do
    with :ok <- ensure_enabled(),
         {:ok, extras} <- cast_extras(set, Map.get(attrs, :extras)) do
      entity_attrs =
        %{}
        |> maybe_put(:title, Map.get(attrs, :label))
        |> maybe_put_extras(value, extras)

      value
      |> PhoenixKitEntities.EntityData.update(entity_attrs, activity_log: false)
      |> tap_log("attribute_set.value_updated", opts, & &1.entity_uuid, fn v ->
        %{"set" => set.name, "value" => v.slug}
      end)
    end
  end

  defp cast_extras(_set, nil), do: {:ok, nil}

  defp cast_extras(set, extras) when is_map(extras) do
    fields = Map.new(set.fields_definition || [], &{&1["key"], &1})

    Enum.reduce_while(extras, {:ok, %{}}, fn {key, raw}, {:ok, acc} ->
      case cast_one_extra(fields[key], raw) do
        {:ok, cast} -> {:cont, {:ok, Map.put(acc, key, cast)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp cast_one_extra(nil, _raw), do: {:error, :unknown_field}

  defp cast_one_extra(field, raw) do
    case PhoenixKitEntities.FormBuilder.cast_field(field, raw) do
      {:ok, cast} -> {:ok, cast}
      {:error, _msgs} -> {:error, :invalid_value}
    end
  end

  @doc """
  Deletes a value record. When the value is the set's default, the
  default is cleared first so the contract never points at a ghost.
  """
  @spec delete_value(struct(), struct(), keyword()) :: {:ok, struct()} | {:error, term()}
  def delete_value(set, value, opts \\ []) do
    with :ok <- ensure_enabled(),
         :ok <- maybe_clear_default(set, value, opts) do
      result =
        value
        |> PhoenixKitEntities.EntityData.delete(activity_log: false)
        |> tap_log("attribute_set.value_deleted", opts, & &1.entity_uuid, fn v ->
          %{"set" => set.name, "value" => v.slug}
        end)

      # Sweep the slug out of every attachment's stored selection —
      # same doctrine as clearing a ghost default above (panel
      # finding: readers intersect defensively, but stored ghosts
      # must not wait for the next incidental item save as GC).
      with {:ok, _} <- result, do: prune_selection_slug(set.uuid, value.slug)

      result
    end
  end

  # One atomic UPDATE, not fetch-and-loop: jsonb's `- text` operator
  # removes the string from the stored array in place, the WHERE `?`
  # (exists) operator touches only rows that actually carry the slug,
  # and there is no per-row changeset to raise StaleEntryError when an
  # attachment is detached mid-sweep (panel finding, 2026-08-19 review).
  defp prune_selection_slug(set_uuid, slug) do
    from(a in ItemAttributeSet,
      where: a.set_uuid == ^set_uuid,
      where: fragment("jsonb_typeof(? -> 'selected_value_slugs') = 'array'", a.data),
      where: fragment("? -> 'selected_value_slugs' \\? ?", a.data, ^slug),
      update: [
        set: [
          data:
            fragment(
              "jsonb_set(?, '{selected_value_slugs}', (? -> 'selected_value_slugs') - ?)",
              a.data,
              a.data,
              ^slug
            ),
          updated_at: ^now_utc()
        ]
      ]
    )
    |> repo().update_all([])

    :ok
  end

  defp now_utc, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp maybe_clear_default(set, value, opts) do
    if current_default(set) == value.slug do
      case update_set(set, %{default_value_slug: nil}, opts) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  @doc "Reorders a set's values to the given record-uuid order."
  @spec reorder_values(struct(), [Ecto.UUID.t()], keyword()) :: :ok | {:error, term()}
  def reorder_values(set, ordered_uuids, opts \\ []) when is_list(ordered_uuids) do
    with :ok <- ensure_enabled() do
      # Malformed uuids raise Ecto.Query.CastError out of the bulk
      # position update — drop them so a buggy client payload can't
      # crash the caller (foreign uuids already no-op: the update is
      # scoped to this set's records).
      ordered = Enum.filter(ordered_uuids, &match?({:ok, _}, Ecto.UUID.cast(&1)))
      PhoenixKitEntities.EntityData.reorder(set.uuid, ordered, activity_log: false)
      log_activity("attribute_set.values_reordered", opts, set.uuid, %{"set" => set.name})
      PubSub.broadcast(:attribute_set, set.uuid)
      :ok
    end
  end

  # ── Extras (blueprint fields — "price per liter" etc.) ─────────────

  @extra_field_types ~w(text textarea number boolean date select image video)

  @doc "Extra-field types the set editor offers (a curated entities subset)."
  @spec extra_field_types() :: [String.t()]
  def extra_field_types, do: @extra_field_types

  @doc """
  Adds an extra field to the set's blueprint (`:label` required,
  `:type` one of `extra_field_types/0`; `select` additionally needs
  `:options`, a non-empty list). Every value can then carry data for
  it. The key is derived from the label and is stable.
  """
  @spec add_extra_field(struct(), map(), keyword()) :: {:ok, struct()} | {:error, term()}
  def add_extra_field(set, attrs, opts \\ []) do
    label = String.trim(Map.get(attrs, :label, ""))
    type = Map.get(attrs, :type, "text")

    options =
      attrs |> Map.get(:options, []) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    key =
      case slugify_name(label) do
        # Non-Latin labels ("Цена") slugify to "" — an empty key breaks
        # the extras form name (`extras[]` parses as a LIST, so the
        # change payload never routes) and the field silently never
        # persists (panel finding, 2026-08-19 review). Opaque fallback
        # key; the label carries the display.
        "" when label != "" -> "field_" <> random_uid()
        slugified -> slugified
      end

    # Re-read before append: the caller's struct may be stale, and a
    # read-modify-write off it would silently drop a field another
    # session added meanwhile.
    set = get_set(set.uuid) || set
    fields = set.fields_definition || []

    with :ok <- ensure_enabled(),
         :ok <- validate_extra_field(label, type, key, options, fields) do
      definition = build_field_definition(type, key, label, options)

      set
      |> PhoenixKitEntities.update_entity(
        %{fields_definition: fields ++ [definition]},
        on_behalf_of: @owner
      )
      |> tap_log("attribute_set.field_added", opts, & &1.uuid, fn s ->
        %{"set" => s.name, "field" => key, "type" => type}
      end)
    end
  end

  defp build_field_definition("select", key, label, options),
    do: %{"type" => "select", "key" => key, "label" => label, "options" => options}

  defp build_field_definition(type, key, label, _options),
    do: %{"type" => type, "key" => key, "label" => label}

  defp validate_extra_field(label, type, key, options, fields) do
    cond do
      label == "" -> {:error, :label_required}
      type not in @extra_field_types -> {:error, :invalid_type}
      type == "select" and options == [] -> {:error, :options_required}
      Enum.any?(fields, &(&1["key"] == key)) -> {:error, :duplicate_key}
      true -> :ok
    end
  end

  @doc """
  Updates an existing extra field: `:label` renames the display text
  (the key — referenced by stored per-value data — never changes),
  `:options` replaces a select field's option list (non-empty
  required). The type is immutable after creation: stored values were
  cast for it.
  """
  @spec update_extra_field(struct(), String.t(), map(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def update_extra_field(set, key, attrs, opts \\ []) when is_binary(key) do
    set = get_set(set.uuid) || set
    fields = set.fields_definition || []

    with :ok <- ensure_enabled(),
         %{} = field <- Enum.find(fields, &(&1["key"] == key)) || {:error, :unknown_field},
         {:ok, updated_field} <- apply_field_update(field, attrs) do
      updated = Enum.map(fields, &if(&1["key"] == key, do: updated_field, else: &1))

      set
      |> PhoenixKitEntities.update_entity(%{fields_definition: updated}, on_behalf_of: @owner)
      |> tap_log("attribute_set.field_updated", opts, & &1.uuid, fn s ->
        %{"set" => s.name, "field" => key}
      end)
    end
  end

  defp apply_field_update(field, attrs) do
    label = attrs |> Map.get(:label, field["label"]) |> String.trim()

    options =
      case Map.get(attrs, :options) do
        nil -> field["options"]
        list -> list |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
      end

    cond do
      label == "" -> {:error, :label_required}
      field["type"] == "select" and options == [] -> {:error, :options_required}
      true -> {:ok, field |> Map.put("label", label) |> maybe_put_options(options)}
    end
  end

  defp maybe_put_options(field, nil), do: field

  defp maybe_put_options(%{"type" => "select"} = field, options),
    do: Map.put(field, "options", options)

  defp maybe_put_options(field, _options), do: field

  @doc """
  Removes an extra field from the blueprint. Existing per-value data
  for the key is left in place (harmless, invisible) — same doctrine
  as entities' own field removal.
  """
  @spec remove_extra_field(struct(), String.t(), keyword()) :: {:ok, struct()} | {:error, term()}
  def remove_extra_field(set, key, opts \\ []) when is_binary(key) do
    with :ok <- ensure_enabled() do
      # Re-read before reject — same stale-struct doctrine as
      # add_extra_field/update_extra_field: rejecting from the caller's
      # struct would resurrect fields another session deleted and drop
      # ones it added.
      set = get_set(set.uuid) || set
      fields = Enum.reject(set.fields_definition || [], &(&1["key"] == key))

      set
      |> PhoenixKitEntities.update_entity(%{fields_definition: fields}, on_behalf_of: @owner)
      |> tap_log("attribute_set.field_removed", opts, & &1.uuid, fn s ->
        %{"set" => s.name, "field" => key}
      end)
    end
  end

  # ── Contract ───────────────────────────────────────────────────────

  @doc """
  Validates a set blueprint's catalogue contract. Returns
  `{:ok, %{kind: atom, default: slug | nil}}` or
  `{:error, :contract_broken}` — never a guessed fallback.
  """
  @spec contract(struct()) :: {:ok, map()} | {:error, :contract_broken}
  def contract(%{settings: settings, name: @slug_prefix <> _} = _set) when is_map(settings) do
    catalogue = settings["catalogue"]

    case catalogue do
      %{"kind" => kind} when kind in @kinds ->
        {:ok, %{kind: String.to_existing_atom(kind), default: catalogue["default_value_slug"]}}

      _ ->
        {:error, :contract_broken}
    end
  end

  def contract(_), do: {:error, :contract_broken}

  # ── Attachments ────────────────────────────────────────────────────

  @doc """
  Attaches a set to an item (appends; no-op when already attached).

  Runs under the per-set advisory lock shared with `delete_set/2` —
  without it, an attach racing a delete could commit after the guard's
  `set_attached?` check read false, leaving an instant orphan row
  (panel finding, 2026-08-18 review).
  """
  @spec attach_set(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, ItemAttributeSet.t()} | {:error, term()}
  def attach_set(item_uuid, set_uuid, opts \\ []) do
    with :ok <- ensure_enabled() do
      repo().transaction(fn -> locked_attach(item_uuid, set_uuid) end)
      |> handle_attach_result(item_uuid, set_uuid, opts)
    end
  end

  # Already attached: return the PERSISTED row (an on_conflict insert
  # would hand back the attempted, unstored position) and write no
  # activity row for the no-op (panel finding, 2026-08-19 review).
  defp handle_attach_result({:ok, {:existing, row}}, _item_uuid, _set_uuid, _opts), do: {:ok, row}

  defp handle_attach_result({:ok, row}, item_uuid, set_uuid, opts) do
    log_activity("attribute_set.attached", opts, set_uuid, %{
      "item_uuid" => item_uuid,
      "set_uuid" => set_uuid
    })

    maybe_broadcast_item(item_uuid, opts)
    {:ok, row}
  end

  defp handle_attach_result({:error, reason}, _item_uuid, _set_uuid, _opts), do: {:error, reason}

  defp locked_attach(item_uuid, set_uuid) do
    lock_set(set_uuid)

    existing =
      repo().one(
        from(a in ItemAttributeSet,
          where: a.item_uuid == ^item_uuid and a.set_uuid == ^set_uuid
        )
      )

    cond do
      # Safe check-then-act: the advisory lock serializes every
      # attach/delete for this set.
      match?(%ItemAttributeSet{}, existing) ->
        {:existing, existing}

      is_nil(get_set(set_uuid)) ->
        repo().rollback(:set_not_found)

      true ->
        case insert_attachment(item_uuid, set_uuid) do
          {:ok, row} -> row
          {:error, reason} -> repo().rollback(reason)
        end
    end
  end

  defp insert_attachment(item_uuid, set_uuid) do
    position =
      repo().one(
        from(a in ItemAttributeSet,
          where: a.item_uuid == ^item_uuid,
          select: coalesce(max(a.position), 0)
        )
      ) + 1

    %ItemAttributeSet{}
    |> ItemAttributeSet.changeset(%{
      item_uuid: item_uuid,
      set_uuid: set_uuid,
      position: position
    })
    |> repo().insert(
      on_conflict: :nothing,
      conflict_target: [:item_uuid, :set_uuid]
    )
  end

  # Per-set advisory transaction lock serializing attach vs delete.
  # hashtextextended folds the uuid to a bigint; xact locks release on
  # commit/rollback, so there is nothing to clean up.
  defp lock_set(set_uuid) do
    repo().query!("SELECT pg_advisory_xact_lock(hashtextextended($1::text, 42))", [set_uuid])
  end

  @doc "Detaches a set from an item (no-op when not attached)."
  @spec detach_set(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) :: :ok
  def detach_set(item_uuid, set_uuid, opts \\ []) do
    {count, _} =
      repo().delete_all(
        from(a in ItemAttributeSet,
          where: a.item_uuid == ^item_uuid and a.set_uuid == ^set_uuid
        )
      )

    if count > 0 do
      log_activity("attribute_set.detached", opts, set_uuid, %{
        "item_uuid" => item_uuid,
        "set_uuid" => set_uuid
      })

      maybe_broadcast_item(item_uuid, opts)
    end

    :ok
  end

  @doc """
  Reorders an item's attachments to the given set_uuid order. No-op
  (no writes, no activity row) when the order already matches — this
  runs on every item save.
  """
  @spec reorder_attachments(Ecto.UUID.t(), [Ecto.UUID.t()], keyword()) :: :ok | {:error, term()}
  def reorder_attachments(item_uuid, set_uuids, opts \\ []) when is_list(set_uuids) do
    ordered = Enum.uniq(set_uuids)

    # Read, compare and write inside ONE transaction, under a per-item
    # advisory lock. This was a check-then-act on a non-primary-key column
    # with neither: two saves of the same item interleaved their per-row
    # `update_all`s into a mixed order, and a mid-loop failure left half the
    # attachments renumbered with no rollback. Every sibling reorder in this
    # codebase wraps the loop; `lock_set/1` above is the same mechanism,
    # keyed by set rather than by item.
    result =
      repo().transaction(fn ->
        lock_item_attachments(item_uuid)
        current = item_uuid |> list_attachments() |> Enum.map(& &1.set_uuid)

        if ordered == current do
          :unchanged
        else
          write_attachment_positions(item_uuid, ordered)
          :reordered
        end
      end)

    case result do
      {:ok, :unchanged} ->
        :ok

      {:ok, :reordered} ->
        # No single set is "the" resource for a whole-item reorder — the
        # row links through metadata.item_uuid instead.
        log_activity("attribute_set.attachments_reordered", opts, nil, %{
          "item_uuid" => item_uuid,
          "order" => ordered
        })

        maybe_broadcast_item(item_uuid, opts)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `broadcast: false` for callers that make several of these changes in a
  # row — an item save can attach, detach, reorder and set selections in one
  # pass, and each of those broadcast separately AND ran its own
  # `item_catalogue_uuid/1` SELECT to do it. Every open detail LiveView then
  # re-ran `refresh_in_place/1` once per change. The importer already uses
  # this convention (`import/executor.ex`), with one roll-up event at the end.
  defp maybe_broadcast_item(item_uuid, opts) do
    if Keyword.get(opts, :broadcast, true) do
      PubSub.broadcast(:item, item_uuid, Helpers.item_catalogue_uuid(item_uuid))
    end

    :ok
  end

  defp write_attachment_positions(item_uuid, ordered) do
    ordered
    |> Enum.with_index(1)
    |> Enum.each(fn {set_uuid, idx} ->
      from(a in ItemAttributeSet,
        where: a.item_uuid == ^item_uuid and a.set_uuid == ^set_uuid
      )
      |> repo().update_all(set: [position: idx])
    end)
  end

  defp lock_item_attachments(item_uuid) do
    repo().query!("SELECT pg_advisory_xact_lock(hashtextextended($1::text, 43))", [item_uuid])
  end

  @doc "The item's attachments in order."
  @spec list_attachments(Ecto.UUID.t()) :: [ItemAttributeSet.t()]
  def list_attachments(item_uuid) do
    repo().all(
      from(a in ItemAttributeSet,
        where: a.item_uuid == ^item_uuid,
        order_by: [asc: a.position, asc: a.set_uuid]
      )
    )
  end

  @doc "True when any item attaches the set (drives the delete guard)."
  @spec set_attached?(Ecto.UUID.t()) :: boolean()
  def set_attached?(set_uuid) do
    repo().exists?(from(a in ItemAttributeSet, where: a.set_uuid == ^set_uuid))
  end

  @doc "How many items attach each of the given sets: %{set_uuid => count}."
  @spec attachment_counts([Ecto.UUID.t()]) :: %{optional(Ecto.UUID.t()) => non_neg_integer()}
  def attachment_counts([]), do: %{}

  def attachment_counts(set_uuids) when is_list(set_uuids) do
    repo().all(
      from(a in ItemAttributeSet,
        where: a.set_uuid in ^set_uuids,
        group_by: a.set_uuid,
        select: {a.set_uuid, count(a.item_uuid)}
      )
    )
    |> Map.new()
  end

  @doc """
  How many rows each attribute VALUE would still match, given the filter
  already applied — the numbers beside the filter's checkboxes, and what
  lets a value that leads nowhere be disabled instead of offered (Max,
  2026-08-28).

  Conditioned on the CURRENT selection, so once Blue is on, Oak shows how
  many blue oak items there are. A dead combination is therefore visible
  as a 0 before it is picked, rather than as an empty list afterwards.

  Options: `:catalogue_uuid`, `:catalogue_uuids`, `:category_uuids`,
  `:statuses`, `:search`, `:value_slugs` (the selection to condition on)
  and `:count` — `:items` (default) or `:catalogues`, which counts
  distinct catalogues for the index's version of the filter.

  Every scope the LISTING is under has to be passed, or the promise
  breaks the other way: a value offered as live because something
  matches it SOMEWHERE, while the page the user is on has none of it,
  is exactly the empty list this exists to prevent. `:search` narrows by
  the same text predicate the item search uses.

  One grouped query: the selection slugs are unnested from the
  attachment's JSONB, so a page with fifteen values still asks once.
  """
  @spec value_match_counts(keyword()) :: %{optional(String.t()) => non_neg_integer()}
  def value_match_counts(opts \\ []) do
    if entities_enabled?() do
      base =
        from(a in ItemAttributeSet,
          join: i in Item,
          as: :item,
          on: i.uuid == a.item_uuid,
          inner_lateral_join:
            slug in fragment(
              "jsonb_array_elements_text(CASE WHEN jsonb_typeof(? -> 'selected_value_slugs') = 'array' THEN ? -> 'selected_value_slugs' ELSE '[]'::jsonb END)",
              a.data,
              a.data
            ),
          on: true,
          group_by: fragment("?", slug)
        )
        |> exclude_deleted_unless_asked(opts)
        |> PhoenixKitCatalogue.Catalogue.match_search_text(opts[:search])
        |> scope_counts(opts)
        |> PhoenixKitCatalogue.Catalogue.filter_by_attribute_values(opts)

      # Two selects rather than a dynamic: a dynamic cannot be spliced
      # into a select tuple.
      case Keyword.get(opts, :count, :items) do
        :catalogues ->
          select(base, [_a, i, slug], {fragment("?", slug), count(i.catalogue_uuid, :distinct)})

        _ ->
          select(base, [_a, i, slug], {fragment("?", slug), count(i.uuid, :distinct)})
      end
      |> repo().all()
      |> Map.new()
    else
      %{}
    end
  end

  # Deleted items are out unless the caller asked for a status set that
  # names them — otherwise the Deleted tab's own counts contradict
  # themselves (`status in ["deleted"]` AND `status != "deleted"`) and
  # every value reads 0.
  defp exclude_deleted_unless_asked(query, opts) do
    if "deleted" in List.wrap(opts[:statuses]) do
      query
    else
      where(query, [_a, i], i.status != "deleted")
    end
  end

  defp scope_counts(query, opts) do
    query
    |> scope_one_catalogue(opts[:catalogue_uuid])
    |> scope_many_catalogues(opts[:catalogue_uuids])
    |> scope_categories(opts[:category_uuids])
    |> scope_statuses(opts[:statuses])
    |> scope_uncategorized(opts[:only])
  end

  defp scope_one_catalogue(query, uuid) when is_binary(uuid),
    do: where(query, [_a, i], i.catalogue_uuid == ^uuid)

  defp scope_one_catalogue(query, _), do: query

  # The INDEX's version: count only within the catalogues the list is
  # currently showing, so a value cannot look available because of a
  # catalogue hidden by the folder, search or status the user is in. An
  # EMPTY list is a real answer — "the list is showing nothing, so nothing
  # matches" — and must not read as "no constraint".
  defp scope_many_catalogues(query, uuids) when is_list(uuids),
    do: where(query, [_a, i], i.catalogue_uuid in ^uuids)

  defp scope_many_catalogues(query, _), do: query

  defp scope_categories(query, [_ | _] = uuids),
    do: where(query, [_a, i], i.category_uuid in ^uuids)

  defp scope_categories(query, _), do: query

  defp scope_statuses(query, [_ | _] = statuses),
    do: where(query, [_a, i], i.status in ^statuses)

  defp scope_statuses(query, _), do: query

  # The uncategorized bucket is a scope like any other level.
  defp scope_uncategorized(query, :uncategorized_only),
    do: where(query, [_a, i], is_nil(i.category_uuid))

  defp scope_uncategorized(query, _), do: query

  @doc """
  The attribute filter's options for one catalogue: every set attached to
  an item in it, with that set's values.

  Only sets actually in use appear — a filter offering "Colour" for a
  catalogue of screws is noise. Values come from the set itself rather
  than from what is currently selected, so picking one that matches
  nothing yet returns an honest empty list instead of hiding the option.

  Shape: `[%{uuid:, name:, values: [%{slug:, title:}]}]`, named for what
  the UI renders.
  """
  @spec filter_options(Ecto.UUID.t() | :all, keyword()) :: [map()]
  def filter_options(catalogue_uuid, opts \\ []) do
    if entities_enabled?() do
      base =
        from(a in ItemAttributeSet,
          join: i in Item,
          on: i.uuid == a.item_uuid,
          where: i.status != "deleted",
          distinct: true,
          select: a.set_uuid
        )

      # `:all` is the catalogues INDEX, which filters catalogues by what
      # their items carry, so its options come from every catalogue.
      set_uuids =
        case catalogue_uuid do
          :all -> base
          uuid -> where(base, [_a, i], i.catalogue_uuid == ^uuid)
        end
        |> repo().all()

      # Values for every set in ONE query. Per-set loading here is two
      # queries each and this runs on every URL change — on the index,
      # where `:all` gathers the sets used anywhere, that is the whole
      # roster loaded a row at a time.
      values_by_set = list_values_for(set_uuids, lang: opts[:lang])

      set_uuids
      |> Enum.map(&get_set(&1, lang: opts[:lang]))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn set ->
        %{
          uuid: set.uuid,
          name: set.display_name || set.name,
          values:
            values_by_set
            |> Map.get(set.uuid, [])
            |> Enum.map(&%{slug: &1.slug, title: &1.title})
        }
      end)
      |> Enum.reject(&(&1.values == []))
      |> Enum.sort_by(& &1.name)
    else
      []
    end
  end

  @doc """
  One page of the items attached to a set, name-ordered — the set
  detail page's listing. Each row is `%{item: %Item{}, selected_slugs:
  [...]}`; the slugs are the RAW attachment selection — callers
  ghost-filter them against the set's current values with
  `valid_selection/2`. Deleted items are excluded.

  Options: `:search` (trimmed, matched on item name), `:limit`
  (default 25), `:offset` (default 0).
  """
  @spec list_attached_items(Ecto.UUID.t(), keyword()) :: [map()]
  def list_attached_items(set_uuid, opts \\ []) when is_binary(set_uuid) do
    limit = Keyword.get(opts, :limit, 25)
    offset = Keyword.get(opts, :offset, 0)

    rows =
      set_uuid
      |> attached_items_base(opts)
      |> order_by([a, i], asc: i.name)
      |> limit(^limit)
      |> offset(^offset)
      |> select([a, i], %{item: i, data: a.data})
      |> repo().all()

    items =
      rows
      |> Enum.map(& &1.item)
      |> repo().preload([:catalogue, category: []])

    Enum.zip_with(items, rows, fn item, row ->
      %{item: item, selected_slugs: List.wrap(row.data["selected_value_slugs"])}
    end)
  end

  @doc "Total match count for `list_attached_items/2` (same filters)."
  @spec count_attached_items(Ecto.UUID.t(), keyword()) :: non_neg_integer()
  def count_attached_items(set_uuid, opts \\ []) when is_binary(set_uuid) do
    set_uuid
    |> attached_items_base(opts)
    |> select([a, i], count(i.uuid))
    |> repo().one()
  end

  defp attached_items_base(set_uuid, opts) do
    query =
      from(a in ItemAttributeSet,
        join: i in Item,
        on: i.uuid == a.item_uuid,
        where: a.set_uuid == ^set_uuid and i.status != "deleted"
      )

    case opts |> Keyword.get(:search, "") |> to_string() |> String.trim() do
      "" ->
        query

      term ->
        pattern = "%#{Helpers.sanitize_like(term)}%"
        where(query, [a, i], ilike(i.name, ^pattern))
    end
  end

  @doc """
  Removes attachments whose set blueprint no longer exists (called by
  `AttributeSets.OrphanPruner` off entities PubSub delete events).

  Guarded on enablement: with entities disabled, `get_set/1` returns
  nil for EVERY uuid — without the guard a stray call during a feature
  toggle would read that as "blueprint deleted" and destroy valid
  attachments (panel finding, 2026-08-18 review).
  """
  @spec prune_orphan_attachments(Ecto.UUID.t()) :: non_neg_integer()
  def prune_orphan_attachments(set_uuid) do
    cond do
      not entities_enabled?() ->
        0

      # PubSub payloads are external input to this process — a
      # malformed uuid must degrade, not raise out of the pruner.
      not match?({:ok, _}, Ecto.UUID.cast(set_uuid)) ->
        0

      get_set(set_uuid) ->
        0

      true ->
        {count, _} =
          repo().delete_all(from(a in ItemAttributeSet, where: a.set_uuid == ^set_uuid))

        if count > 0 do
          # Destructive machine-originated sweep — audit it like every
          # other mutation in this module (no actor: PubSub-driven), and
          # fan it out like one: the Attributes tab's per-set item counts
          # and any open item form's staged sets just changed.
          log_activity("attribute_set.orphans_pruned", [mode: "auto"], set_uuid, %{
            "set_uuid" => set_uuid,
            "count" => count
          })

          PubSub.broadcast(:attribute_set, set_uuid)
        end

        count
    end
  end

  # ── Resolution (the v2 consumer read) ──────────────────────────────

  @doc """
  Resolves the attached sets for many items in one batched pass:
  one attachment query + one value listing per DISTINCT set (values are
  shared across items, so a 50-item page with 6 sets is 7 queries).

  Returns `%{item_uuid => resolved}` where resolved is the v2 shape:

      %{schema_version: 2,
        sets: [%{uuid, key, name, kind, default,
                 values:   [%{key, label, extras}],
                 fields:   [%{key, label, type}],
                 selected: [slug]}]}

  `:fields` mirrors the blueprint's extra-field definitions (what each
  value's `extras` keys mean); `:selected` is the per-ATTACHMENT value
  selection, already intersected against current values (ghost slugs
  degrade out). `:selected` exists ONLY on this batched read —
  `resolve_set/2` resolves a bare set with no attachment context and
  carries no `:selected` key.

  Sets with a broken contract are skipped with a warning — a tampered
  blueprint must not take item pages down, but it must not render
  guessed data either.
  """
  @spec resolve_for_items([Ecto.UUID.t()], keyword()) :: %{optional(Ecto.UUID.t()) => map()}
  def resolve_for_items(item_uuids, opts \\ [])
  def resolve_for_items([], _opts), do: %{}

  def resolve_for_items(item_uuids, opts) when is_list(item_uuids) do
    if entities_enabled?() do
      attachments =
        repo().all(
          from(a in ItemAttributeSet,
            where: a.item_uuid in ^item_uuids,
            order_by: [asc: a.position, asc: a.set_uuid]
          )
        )

      resolved_sets =
        attachments
        |> Enum.map(& &1.set_uuid)
        |> Enum.uniq()
        |> Map.new(fn set_uuid -> {set_uuid, resolve_set(set_uuid, opts)} end)

      attachments
      |> Enum.group_by(& &1.item_uuid)
      |> Map.new(fn {item_uuid, rows} ->
        sets =
          rows
          |> Enum.map(&attach_selection(resolved_sets[&1.set_uuid], &1))
          |> Enum.reject(&is_nil/1)

        {item_uuid, %{schema_version: 2, sets: sets}}
      end)
    else
      %{}
    end
  end

  defp attach_selection(nil, _row), do: nil

  defp attach_selection(set, %ItemAttributeSet{data: data}),
    do: Map.put(set, :selected, valid_selection(data["selected_value_slugs"], set))

  @doc """
  Filters stored selection slugs against a resolved set's CURRENT
  values — THE single implementation of the ghost rule, shared with
  every hydration path (the item form stages selections off raw
  attachment rows).

  The per-attachment selection is the boss's two modes (2026-08-19):
  one slug = "this exact object is Red", several = "this object comes
  in Red/Blue/Yellow", empty = no statement, the whole set applies.
  The count IS the mode — nothing else is tracked. A value deleted
  after being ticked must not ghost through reads: unknown slugs drop
  out, and a fully-ghosted selection degrades to `[]` ("whole set
  applies"), never to a vanished or mode-flipped set.
  """
  @spec valid_selection(term(), map() | nil) :: [String.t()]
  def valid_selection(slugs, %{values: values}) when is_list(slugs) do
    valid = MapSet.new(values, & &1.key)
    slugs |> Enum.filter(&(is_binary(&1) and &1 in valid)) |> Enum.uniq()
  end

  def valid_selection(_slugs, _resolved_set), do: []

  @doc "Single-item convenience over `resolve_for_items/2`."
  @spec resolve_for_item(Ecto.UUID.t(), keyword()) :: map()
  def resolve_for_item(item_uuid, opts \\ []) do
    resolve_for_items([item_uuid], opts)
    |> Map.get(item_uuid, %{schema_version: 2, sets: []})
  end

  @doc """
  Resolves ONE set to the v2 per-set shape
  (`%{uuid, key, name, kind, default, values, fields}`), or `nil` when
  the set is missing or its contract is broken. No attachment context,
  so no `:selected` key — that exists only on `resolve_for_items/2`'s
  per-item sets. Powers the item form's attach-preview; the batched
  item reads go through `resolve_for_items/2`.
  """
  @spec resolve_set(Ecto.UUID.t(), keyword()) :: map() | nil
  def resolve_set(set_uuid, opts \\ []) do
    with %{} = set <- get_set(set_uuid, opts),
         {:ok, %{kind: kind, default: default}} <- contract(set) do
      values =
        set_uuid
        |> list_values(opts)
        |> Enum.map(fn record ->
          %{key: record.slug, label: record.title, extras: record.data || %{}}
        end)

      fields =
        Enum.map(set.fields_definition || [], fn f ->
          %{key: f["key"], label: f["label"], type: f["type"]}
        end)

      %{
        uuid: set_uuid,
        key: set.name,
        name: set.display_name,
        kind: kind,
        default: default,
        values: values,
        fields: fields
      }
    else
      nil ->
        nil

      {:error, :contract_broken} ->
        Logger.warning("AttributeSets: contract broken for set #{inspect(set_uuid)} — skipped")
        nil
    end
  end

  @doc """
  Stores the per-attachment value selection (`selected_value_slugs` in
  the join row's reserved `data`) — the boss's two modes: ONE slug says
  "this exact object is Red", several say "this object comes in these
  options", empty clears the statement. Unknown slugs are dropped
  against the set's current values; `{:error, :not_attached}` when the
  item doesn't attach the set.
  """
  @spec set_attachment_selection(Ecto.UUID.t(), Ecto.UUID.t(), [String.t()], keyword()) ::
          :ok | {:error, term()}
  def set_attachment_selection(item_uuid, set_uuid, slugs, opts \\ []) when is_list(slugs) do
    with :ok <- ensure_enabled(),
         %ItemAttributeSet{} = row <-
           repo().one(
             from(a in ItemAttributeSet,
               where: a.item_uuid == ^item_uuid and a.set_uuid == ^set_uuid
             )
           ) || {:error, :not_attached} do
      selection = valid_selection(slugs, resolve_set(set_uuid))

      if selection == List.wrap(row.data["selected_value_slugs"]) do
        # Unchanged — no write, no activity row. This runs for every
        # attached set on every item save (panel finding, 2026-08-19).
        :ok
      else
        write_attachment_selection(item_uuid, set_uuid, selection, opts)
      end
    end
  end

  # Atomic jsonb_set on ONLY this key: a read-modify-write of the whole
  # data map off the fetched row would clobber concurrent writes to
  # other reserved keys, and a per-row changeset update raises
  # Ecto.StaleEntryError when the attachment is detached in the window —
  # update_all instead reports {0, _}, which maps to :not_attached
  # (panel finding, 2026-08-19 review).
  defp write_attachment_selection(item_uuid, set_uuid, selection, opts) do
    {count, _} =
      from(a in ItemAttributeSet,
        where: a.item_uuid == ^item_uuid and a.set_uuid == ^set_uuid,
        update: [
          set: [
            data:
              fragment(
                # to_jsonb over a text[] param — NOT a JSON-encoded
                # string param, which Ecto types as a jsonb STRING and
                # stores the selection as one quoted blob.
                "jsonb_set(coalesce(?, '{}'::jsonb), '{selected_value_slugs}', to_jsonb(?::text[]))",
                a.data,
                ^selection
              ),
            updated_at: ^now_utc()
          ]
        ]
      )
      |> repo().update_all([])

    if count > 0 do
      log_activity("attribute_set.selection_changed", opts, set_uuid, %{
        "item_uuid" => item_uuid,
        "set_uuid" => set_uuid,
        "selected" => selection
      })

      maybe_broadcast_item(item_uuid, opts)
      :ok
    else
      {:error, :not_attached}
    end
  end

  # ── Migration from the group system (dual-run; design doc §Migration) ─

  @doc """
  Migrates the legacy group→attribute→value data into sets:

    * each `(group, attribute)` pair → one set blueprint, slug
      `catalogue_set_<group>_<attr-key>` (display "<Group> — <Attr>");
    * attribute values → records, slug = the old value key (stable, so
      existing order-line picks keep resolving), old `is_default` → the
      set's `default_value_slug`;
    * every item's single group assignment explodes into one attachment
      per attribute of that group, in attribute order.

  Idempotent: an existing blueprint with the target slug is reused (its
  values/attachments are topped up, never duplicated), so re-running
  after a partial failure is safe. Old tables are left untouched
  (read-only by convention; dropped by a later core migration after
  cutover). Returns `{:ok, %{sets: n, values: n, attachments: n}}`.
  """
  @spec migrate_groups_to_sets(keyword()) :: {:ok, map()} | {:error, term()}
  def migrate_groups_to_sets(opts \\ []) do
    with :ok <- ensure_enabled() do
      groups = PhoenixKitCatalogue.Catalogue.list_attribute_groups()

      {set_map, counts} =
        Enum.reduce(groups, {%{}, %{sets: 0, values: 0}}, fn group, acc ->
          migrate_group(group, opts, acc)
        end)

      attachment_count = migrate_assignments(set_map, opts)

      {:ok, %{sets: counts.sets, values: counts.values, attachments: attachment_count}}
    end
  end

  defp migrate_group(group, opts, acc) do
    full = PhoenixKitCatalogue.Catalogue.get_attribute_group_full(group.uuid)

    Enum.reduce(full.attributes, acc, fn attribute, {set_map, counts} ->
      {set, created?} = find_or_create_migrated_set(group, attribute, opts)

      value_count =
        Enum.count(attribute.values, fn value ->
          ensure_migrated_value(set, value, opts)
        end)

      default = Enum.find(attribute.values, & &1.is_default)

      # Top-up, not created-only: a crash between creating the set and
      # writing its default must not lose the default forever — on
      # re-run the set exists (created? false) but its default is still
      # nil, so apply it then too (panel finding, 2026-08-18 review).
      if default && is_nil(current_default(set)) do
        {:ok, _} = update_set(set, %{default_value_slug: default.key}, opts)
      end

      {
        Map.put(set_map, {group.uuid, attribute.uuid}, set.uuid),
        %{
          counts
          | sets: counts.sets + if(created?, do: 1, else: 0),
            values: counts.values + value_count
        }
      }
    end)
  end

  # Two distinct (group, attribute) pairs can slugify to the same text —
  # "A B"/"C" vs "A"/"B C", or non-Latin names that strip to "" — and a
  # blind slug reuse would silently merge unrelated dimensions (panel
  # finding, 2026-08-18 review). Each migrated set records which legacy
  # attribute it came from (settings.catalogue.migrated_from); on a slug
  # hit for a DIFFERENT attribute the slug is disambiguated with the
  # attribute's stable short uuid, which also keeps re-runs idempotent.
  # A hit without provenance is grandfathered as a match (sets migrated
  # before provenance existed).
  defp find_or_create_migrated_set(group, attribute, opts) do
    base =
      case slugify_name("#{group.name} #{attribute.key}") do
        "" -> "attr_" <> short_uid(attribute)
        slug -> slug
      end

    find_or_create_with_slug(base, group, attribute, opts)
  end

  defp find_or_create_with_slug(slug, group, attribute, opts) do
    full_slug = @slug_prefix <> slug

    case Enum.find(list_sets(), &(&1.name == full_slug)) do
      nil ->
        {create_migrated_set(slug, group, attribute, opts), true}

      %{} = existing ->
        provenance = get_in(existing.settings, ["catalogue", "migrated_from"])

        if provenance in [nil, attribute.uuid] do
          {existing, false}
        else
          find_or_create_with_slug(slug <> "_" <> short_uid(attribute), group, attribute, opts)
        end
    end
  end

  defp create_migrated_set(slug, group, attribute, opts) do
    {:ok, set} =
      create_set(
        %{
          name: "#{group.name} — #{attribute.name}",
          slug: slug,
          kind: attribute.kind
        },
        opts
      )

    {:ok, set} =
      PhoenixKitEntities.update_entity(
        set,
        %{settings: put_in(set.settings, ["catalogue", "migrated_from"], attribute.uuid)},
        on_behalf_of: @owner
      )

    set
  end

  defp short_uid(%{uuid: uuid}) do
    uuid |> String.replace("-", "") |> binary_part(0, 8)
  end

  defp ensure_migrated_value(set, value, opts) do
    existing = list_values(set) |> Enum.any?(&(&1.slug == value.key))

    if existing do
      false
    else
      {:ok, _} = create_value(set, %{label: value.value, slug: value.key}, opts)
      true
    end
  end

  defp migrate_assignments(set_map, opts) do
    assignments =
      repo().all(from(a in PhoenixKitCatalogue.Schemas.ItemAttributeGroup, select: a))

    Enum.reduce(assignments, 0, fn assignment, count ->
      set_uuids =
        set_map
        |> Enum.filter(fn {{group_uuid, _attr}, _set} ->
          group_uuid == assignment.attribute_group_uuid
        end)
        |> Enum.map(fn {_key, set_uuid} -> set_uuid end)

      count + attach_missing(assignment.item_uuid, set_uuids, opts)
    end)
  end

  # attach_set reports {:ok, existing_row} for an already-attached pair
  # too — count only genuinely new rows so the idempotency contract
  # ({:ok, all-zeros} on re-run) holds. opts threads the migration
  # actor into each attachment's activity row.
  defp attach_missing(item_uuid, set_uuids, opts) do
    existing =
      item_uuid
      |> list_attachments()
      |> MapSet.new(& &1.set_uuid)

    Enum.reduce(set_uuids, 0, fn set_uuid, acc ->
      with false <- MapSet.member?(existing, set_uuid),
           {:ok, _} <- attach_set(item_uuid, set_uuid, opts) do
        acc + 1
      else
        _ -> acc
      end
    end)
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp ensure_enabled do
    if entities_enabled?() do
      :ok
    else
      {:error, :entities_disabled}
    end
  end

  defp validate_kind(kind) when kind in @kinds, do: {:ok, kind}
  defp validate_kind(kind) when kind in [:fixed, :multi], do: {:ok, Atom.to_string(kind)}
  defp validate_kind(_), do: {:error, :invalid_kind}

  # The default slot is a structural "at most one default" pointer
  # (design doc §Chosen architecture) — a write that points it at a
  # slug with no matching value record would let `resolve_set/2` hand
  # every consumer a ghost default, exactly the guessed fallback the
  # contract doctrine forbids. nil (no default) is always valid.
  defp validate_default_slug(_set, nil), do: :ok

  defp validate_default_slug(set, slug) do
    if slug in Enum.map(list_values(set), & &1.slug) do
      :ok
    else
      {:error, :contract_broken}
    end
  end

  @doc """
  The set's kind string (`"fixed"`/`"multi"`, tolerant default
  `"multi"`). Public so UI layers read the contract through one
  accessor instead of destructuring `settings["catalogue"]` — the
  strict validating read stays `contract/1`.
  """
  @spec kind(struct()) :: String.t()
  def kind(set), do: current_kind(set)

  @doc "The set's default value slug, or nil. See `kind/1`."
  @spec default_value_slug(struct()) :: String.t() | nil
  def default_value_slug(set), do: current_default(set)

  defp current_kind(set), do: get_in(set.settings, ["catalogue", "kind"]) || "multi"
  defp current_default(set), do: get_in(set.settings, ["catalogue", "default_value_slug"])

  # Entities enforces two slug dialects: blueprint names allow
  # [a-z0-9_], data-record slugs allow hyphenated [a-z0-9-]. Mirror
  # both — these become the immutable set/value keys.
  defp slugify_name(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
  end

  defp slugify_value(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_extras(attrs, value, extras) when is_map(extras),
    do: Map.put(attrs, :data, Map.merge(value.data || %{}, extras))

  defp maybe_put_extras(attrs, _value, _extras), do: attrs

  defp maybe_put_creator(attrs, opts) do
    case opts[:actor_uuid] do
      uuid when is_binary(uuid) -> Map.put(attrs, :created_by_uuid, uuid)
      _ -> attrs
    end
  end

  defp tap_log({:ok, resource} = result, action, opts, uuid_fn, metadata_fn) do
    set_uuid = uuid_fn.(resource)
    log_activity(action, opts, set_uuid, metadata_fn.(resource))
    PubSub.broadcast(:attribute_set, set_uuid)
    result
  end

  defp tap_log(other, _action, _opts, _uuid_fn, _metadata_fn), do: other

  # resource_uuid is the SET's blueprint uuid (repo convention: every
  # activity row links back to its resource); item-scoped context rides
  # in metadata. mode defaults to "manual" — machine-originated sweeps
  # (orphan pruning) pass mode: "auto" in opts.
  defp log_activity(action, opts, resource_uuid, metadata) do
    ActivityLog.log(%{
      action: action,
      mode: opts[:mode] || "manual",
      actor_uuid: opts[:actor_uuid],
      resource_type: "attribute_set",
      resource_uuid: resource_uuid,
      metadata: metadata
    })
  end
end
