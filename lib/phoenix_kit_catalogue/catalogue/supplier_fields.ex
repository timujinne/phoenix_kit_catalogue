defmodule PhoenixKitCatalogue.Catalogue.SupplierFields do
  @moduledoc """
  Admin-defined EXTRA fields on a supplier row — "incoterm", "carton
  quantity", "certification expiry" — added without a migration.

  Same doctrine as attribute-set extras
  (`PhoenixKitCatalogue.Catalogue.AttributeSets`), one blueprint
  narrower: entities owns the **field definitions**, the catalogue owns
  the **values**.

  ## The blueprint contract

      name:      "catalogue_supplier_fields"   (immutable, singleton)
      settings:  "managed_by"  => "catalogue_supplier"
                 "locked_keys" => ["scope"]
                 "catalogue_supplier" => %{"scope" => "supplier_info"}
      records:   NONE — this blueprint is a field-definition carrier
                 only. Values live on the supplier rows themselves.

  A singleton: every `phoenix_kit_cat_item_supplier_info` row in the
  install shares one field set, so a field added while editing one item
  appears on every item's suppliers.

  ## Why the values are NOT entity data records

  Supplier rows are per-item, high-count and relational, and they carry
  money. `phoenix_kit_cat_item_supplier_info` keeps its typed columns —
  `unit_cost NUMERIC(14,4)`, the `is_primary` partial unique index, real
  `date` validity columns, the `{supplier_uuid, supplier_source}`
  federated reference of ADR-0001. Entities casts numbers through
  `Float.parse/1` and enforces nothing at the database level, so moving
  those would trade exact money for JSON floats and silently drop
  "one primary supplier per item".

  The extras ride `metadata["custom_fields"]` instead — namespaced so an
  admin-invented key can never collide with a future system key on the
  same JSONB column. This is the fallback the attribute-sets design doc
  named explicitly: *"keep catalogue tables with a JSONB extras column."*

  ## Owner string

  `"catalogue_supplier"`, deliberately NOT `"catalogue"`. `AttributeSets`
  enumerates its sets with `Managed.owner(&1) == "catalogue"`; sharing the
  owner would make this blueprint show up as an attribute set and put it
  under the set deletion guard. A distinct owner keeps both registries
  clean and gives this blueprint its own guard.

  ## Enablement

  Requires the entities module. Writes return `{:error, :entities_disabled}`
  when it is off; reads degrade quietly (`[]`, `%{}`, `nil`) so the
  supplier UI renders without extras rather than crashing mid-toggle.
  """

  require Logger

  alias PhoenixKitCatalogue.Catalogue.{ActivityLog, PubSub}

  @owner "catalogue_supplier"
  @blueprint_name "catalogue_supplier_fields"
  @locked_keys ["scope"]
  @scope "supplier_info"

  # Where the values live on `item_supplier_info.metadata`.
  @data_key "custom_fields"

  # A curated entities subset. `image`/`video` are deliberately absent:
  # they are not form inputs but picker + uuid references needing a
  # page-level MediaSelectorModal, which the supplier modal has no room
  # for. Add them here when a picker is wired, not before — an
  # unrenderable type would store a uuid nothing can choose.
  @field_types ~w(text textarea number boolean date select)

  # ── Built-in fields ────────────────────────────────────────────────
  #
  # Fields the catalogue itself declares, in the entities field-definition
  # format, so they render and cast through exactly the same machinery as
  # admin-added ones (`FieldInput` + `FormBuilder.cast_field/2`). This is
  # the first step of the owner's "everything in entities" direction:
  # entities owns the SHAPE of a supplier field, including the built-in
  # ones.
  #
  # They deliberately live in code rather than in the blueprint:
  #
  #   * the hidden field manager cannot delete or retype them;
  #   * they keep working when the entities MODULE is toggled off —
  #     `cast_field/2` is a pure function, so only the admin-defined
  #     extras depend on the blueprint being reachable. Money must not
  #     become uneditable because someone flipped a module switch.
  #
  # A built-in key names a real COLUMN on
  # `phoenix_kit_cat_item_supplier_info`; its value is written there, not
  # into `metadata`. `unit_cost` is `NUMERIC(14,4)` and warehouse reads it
  # directly (`cost_proposals.ex` compares a goods-receipt value against
  # it as Decimals), so it cannot move into JSONB — hence `decimal`,
  # added to entities for exactly this.
  @builtin_fields [
    %{
      "type" => "decimal",
      "key" => "unit_cost",
      "label" => "Unit cost",
      "scale" => 4,
      # "any": no stepping, so the arrows walk by 1 instead of crawling
      # 0.0001 at a time, and every 4-place typed value stays SAVEABLE.
      # The original "0.01" was wrong twice over (2026-08-31, entities
      # 0.4.9 review): `step` is a validation constraint the browser
      # enforces before a submit event ever fires, so a cent step made
      # 12.3456 unsaveable — and entities now rejects any override that
      # doesn't admit every value the scale allows, so "0.01" would just
      # fall back to the crawling 0.0001 anyway.
      "step" => "any",
      "min" => 0
    }
  ]

  @doc """
  The catalogue's own supplier field definitions, in entities format.
  Always available — these do not depend on the entities module being
  enabled, only on its field machinery being compiled in.

  Labels are translated at CALL time (2026-08-31 sweep): the compile-time
  map can only hold the msgid, and rendering it raw showed an English
  "Unit cost" to et/ru admins. The runtime `Gettext.gettext/2` call form
  is this repo's convention — the msgid is hand-maintained in the
  catalogues, per AGENTS.md.
  """
  @spec builtin_fields() :: [map()]
  def builtin_fields, do: Enum.map(@builtin_fields, &translate_builtin/1)

  @doc "One built-in field definition by key, or `nil`."
  @spec builtin_field(String.t()) :: map() | nil
  def builtin_field(key) when is_binary(key) do
    case Enum.find(@builtin_fields, &(&1["key"] == key)) do
      nil -> nil
      field -> translate_builtin(field)
    end
  end

  # The label helper stays literal-per-key so the mapping is auditable
  # against the hand-maintained catalogues (the extractor can't see any
  # of this either way — hand-added msgids are the contract here).
  defp translate_builtin(%{"key" => "unit_cost"} = field),
    do: %{field | "label" => Gettext.gettext(PhoenixKitCatalogue.Gettext, "Unit cost")}

  defp translate_builtin(field), do: field

  @doc """
  Casts a built-in field's raw form input through the entities pipeline.
  Returns `{:ok, term}` — a `%Decimal{}` for `unit_cost`, or `nil` when
  cleared — or `{:error, :invalid_value}`.

  Unlike the admin-defined extras, the result is destined for a typed
  COLUMN, so the caller hands it straight to the changeset.
  """
  @spec cast_builtin(String.t(), term()) :: {:ok, term()} | {:error, term()}
  def cast_builtin(key, raw) when is_binary(key) do
    case builtin_field(key) do
      nil ->
        {:error, :unknown_field}

      field ->
        case PhoenixKitEntities.FormBuilder.cast_field(field, raw) do
          {:ok, cast} -> {:ok, cast}
          {:error, _messages} -> {:error, :invalid_value}
        end
    end
  end

  @doc """
  True when the feature is live: the entities module is enabled AND its
  package carries the Managed API. Mirrors
  `AttributeSets.enabled?/0` — UI branches on this to decide whether to
  render the extras at all.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Code.ensure_loaded?(PhoenixKitEntities) and
      Code.ensure_loaded?(PhoenixKitEntities.Managed) and
      PhoenixKitEntities.enabled?()
  end

  @doc "Extra-field types the supplier field editor offers."
  @spec field_types() :: [String.t()]
  def field_types, do: @field_types

  @doc "The blueprint's owner key, as stored in `settings[\"managed_by\"]`."
  @spec owner() :: String.t()
  def owner, do: @owner

  # ── Startup registration ───────────────────────────────────────────

  @doc """
  Registers the supplier-fields deletion guard with entities. Ships as a
  supervision child via `PhoenixKitCatalogue.children/0`.
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
    if enabled?() do
      # External capture, never a local closure — a local fun goes stale
      # on code purge and `:persistent_term` would hold a dead ref
      # (entities' Managed moduledoc).
      PhoenixKitEntities.Managed.register_delete_guard(@owner, &__MODULE__.deletion_guard/1)
    end

    :ok
  rescue
    error ->
      Logger.warning("SupplierFields guard registration failed: #{inspect(error)}")
      :ok
  end

  @doc """
  Refuses deletion of the blueprint while it still defines fields —
  supplier rows store values keyed by those definitions, and dropping
  the blueprint would strand every one of them unreadable. An empty
  blueprint is disposable; the module re-provisions it on next use.
  """
  @spec deletion_guard(struct()) :: :ok | {:error, :supplier_fields_defined}
  def deletion_guard(%{fields_definition: fields}) when is_list(fields) and fields != [],
    do: {:error, :supplier_fields_defined}

  def deletion_guard(_entity), do: :ok

  # ── Blueprint ──────────────────────────────────────────────────────

  @doc """
  The supplier-fields blueprint, or `nil` when entities is off or it has
  never been provisioned. A read — never creates.
  """
  @spec blueprint(keyword()) :: struct() | nil
  def blueprint(opts \\ []) do
    with true <- enabled?(),
         %{} = entity <-
           PhoenixKitEntities.get_entity_by_name(@blueprint_name, lang: opts[:lang]),
         @owner <- PhoenixKitEntities.Managed.owner(entity) do
      entity
    else
      _ -> nil
    end
  end

  @doc """
  The blueprint, provisioning it on first use. Idempotent: a concurrent
  create loses the unique-name race and is re-read rather than reported
  as an error.
  """
  @spec ensure_blueprint(keyword()) :: {:ok, struct()} | {:error, term()}
  def ensure_blueprint(opts \\ []) do
    with :ok <- ensure_enabled() do
      case blueprint(opts) do
        %{} = entity -> {:ok, entity}
        nil -> provision(opts)
      end
    end
  end

  defp provision(opts) do
    %{
      name: @blueprint_name,
      display_name: "Supplier fields",
      display_name_plural: "Supplier fields",
      description: "Extra fields carried by every item-supplier row.",
      status: "published",
      fields_definition: [],
      settings: %{
        "managed_by" => @owner,
        "locked_keys" => @locked_keys,
        @owner => %{"scope" => @scope}
      }
    }
    |> maybe_put_creator(opts)
    |> PhoenixKitEntities.create_entity(on_behalf_of: @owner)
    |> case do
      {:ok, entity} ->
        log("supplier_field.blueprint_created", opts, entity.uuid, %{})
        {:ok, entity}

      # Lost the unique-name race against a concurrent provision (two
      # admins opening the editor at once). The winner's row is the
      # answer — re-read rather than surfacing a constraint error.
      {:error, %Ecto.Changeset{}} = error ->
        case blueprint(opts) do
          %{} = entity -> {:ok, entity}
          nil -> error
        end

      other ->
        other
    end
  end

  @doc """
  The defined field definitions (entities `fields_definition` entries,
  string keys). `[]` when entities is off or nothing is defined — so
  every render site can iterate unconditionally.
  """
  @spec fields(keyword()) :: [map()]
  def fields(opts \\ []) do
    case blueprint(opts) do
      %{fields_definition: fields} when is_list(fields) -> fields
      _ -> []
    end
  end

  @doc "One field definition by key, or `nil`."
  @spec field(String.t(), keyword()) :: map() | nil
  def field(key, opts \\ []) when is_binary(key) do
    Enum.find(fields(opts), &(&1["key"] == key))
  end

  # ── Field definitions ──────────────────────────────────────────────

  @doc """
  Adds a field: `:label` required, `:type` one of `field_types/0`,
  `select` additionally needs a non-empty `:options`. The key is derived
  from the label and is stable — stored values reference it, so it never
  changes afterwards.
  """
  @spec add_field(map(), keyword()) :: {:ok, struct()} | {:error, term()}
  def add_field(attrs, opts \\ []) do
    label = attrs |> Map.get(:label, "") |> String.trim()
    type = Map.get(attrs, :type, "text")

    options =
      attrs |> Map.get(:options, []) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    key = derive_key(label)

    # Shape is validated BEFORE the blueprint is touched: provisioning is
    # a write, and a rejected request must not leave one behind as a side
    # effect. Only the duplicate-key check needs the existing fields.
    with :ok <- ensure_enabled(),
         :ok <- validate_shape(label, type, options),
         {:ok, entity} <- ensure_blueprint(opts),
         # Re-read is implicit: ensure_blueprint/1 always fetches fresh,
         # so a field another session added meanwhile is in `existing`.
         existing = entity.fields_definition || [],
         :ok <- validate_unique_key(key, existing) do
      definition = build_definition(type, key, label, options)

      entity
      |> PhoenixKitEntities.update_entity(
        %{fields_definition: existing ++ [definition]},
        on_behalf_of: @owner
      )
      |> tap_log("supplier_field.added", opts, %{"field" => key, "type" => type})
    end
  end

  @doc """
  Updates a field: `:label` renames the display text, `:options`
  replaces a select's choices. The KEY and the TYPE are immutable —
  stored values were cast for that type and are addressed by that key.
  """
  @spec update_field(String.t(), map(), keyword()) :: {:ok, struct()} | {:error, term()}
  def update_field(key, attrs, opts \\ []) when is_binary(key) do
    with :ok <- ensure_enabled(),
         {:ok, entity} <- ensure_blueprint(opts),
         existing = entity.fields_definition || [],
         %{} = current <- Enum.find(existing, &(&1["key"] == key)) || {:error, :unknown_field},
         {:ok, updated} <- apply_update(current, attrs) do
      entity
      |> PhoenixKitEntities.update_entity(
        %{fields_definition: replace_field(existing, key, updated)},
        on_behalf_of: @owner
      )
      |> tap_log("supplier_field.updated", opts, %{"field" => key})
    end
  end

  defp replace_field(fields, key, updated),
    do: Enum.map(fields, &if(&1["key"] == key, do: updated, else: &1))

  @doc """
  Removes a field definition. Values already stored under its key are
  left in place — harmless and invisible, and they come back if a field
  with the same key is re-added. Same doctrine as entities' own field
  removal and attribute-set extras.
  """
  @spec remove_field(String.t(), keyword()) :: {:ok, struct()} | {:error, term()}
  def remove_field(key, opts \\ []) when is_binary(key) do
    with :ok <- ensure_enabled(),
         {:ok, entity} <- ensure_blueprint(opts) do
      fields = Enum.reject(entity.fields_definition || [], &(&1["key"] == key))

      entity
      |> PhoenixKitEntities.update_entity(
        %{fields_definition: fields},
        on_behalf_of: @owner
      )
      |> tap_log("supplier_field.removed", opts, %{"field" => key})
    end
  end

  # ── Values on a supplier row ───────────────────────────────────────

  @doc """
  The custom-field values carried by one supplier-info row, as a
  `%{key => value}` map. Always a map — a row written before any field
  existed reads as `%{}`.
  """
  @spec values(struct() | nil) :: map()
  def values(%{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, @data_key) do
      values when is_map(values) -> values
      _ -> %{}
    end
  end

  def values(_info), do: %{}

  @doc "One stored value by field key, or `nil`."
  @spec value(struct() | nil, String.t()) :: term()
  def value(info, key) when is_binary(key), do: Map.get(values(info), key)

  @doc """
  Casts raw form input against the defined fields, through the same
  entities pipeline the full form uses (`FormBuilder.cast_field/2`):
  `"12.5"` coerces to `12.5`, `""` clears, a select value outside its
  options is refused.

  Unknown keys return `{:error, :unknown_field}` and invalid content
  `{:error, :invalid_value}` — never a silent junk write. `nil` in
  means "not submitted", and passes through untouched.
  """
  @spec cast_values(map() | nil, keyword()) :: {:ok, map() | nil} | {:error, term()}
  def cast_values(raw, opts \\ [])

  def cast_values(nil, _opts), do: {:ok, nil}

  def cast_values(raw, opts) when is_map(raw) do
    defined = Map.new(fields(opts), &{&1["key"], &1})

    Enum.reduce_while(raw, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case cast_one(defined[key], value) do
        {:ok, cast} -> {:cont, {:ok, Map.put(acc, key, cast)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp cast_one(nil, _value), do: {:error, :unknown_field}

  defp cast_one(field, value) do
    case PhoenixKitEntities.FormBuilder.cast_field(field, value) do
      {:ok, cast} -> {:ok, cast}
      {:error, _messages} -> {:error, :invalid_value}
    end
  end

  @doc """
  Merges cast values into a row's `metadata`, under the namespaced key.
  Returns the metadata map to hand to the changeset. A `nil` `values`
  leaves metadata untouched, so a caller that didn't collect extras
  cannot blank the ones already stored.
  """
  @spec put_values(map() | nil, map() | nil) :: map()
  def put_values(metadata, nil), do: metadata || %{}

  # Merging nothing changes nothing — and must not stamp an empty
  # `custom_fields` key onto every row written while the UI is hidden.
  def put_values(metadata, values) when values == %{}, do: metadata || %{}

  def put_values(metadata, values) when is_map(values) do
    metadata = metadata || %{}
    merged = Map.merge(Map.get(metadata, @data_key) || %{}, values)
    Map.put(metadata, @data_key, merged)
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp ensure_enabled do
    if enabled?(), do: :ok, else: {:error, :entities_disabled}
  end

  # Entities blueprint field keys allow [a-z0-9_]. A non-Latin label
  # ("Цена") collapses to "" — an empty key breaks the form name
  # (`custom_fields[]` parses as a LIST, so the payload never routes)
  # and the field would silently never persist. Opaque fallback key;
  # the label carries the display. Same fix as attribute-set extras.
  defp derive_key(label) do
    case slugify(label) do
      "" when label != "" -> "field_" <> random_uid()
      slug -> slug
    end
  end

  defp slugify(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
  end

  defp random_uid do
    Ecto.UUID.generate() |> String.replace("-", "") |> binary_part(0, 8)
  end

  defp validate_shape(label, type, options) do
    cond do
      label == "" -> {:error, :label_required}
      type not in @field_types -> {:error, :invalid_type}
      type == "select" and options == [] -> {:error, :options_required}
      true -> :ok
    end
  end

  defp validate_unique_key(key, existing) do
    if Enum.any?(existing, &(&1["key"] == key)), do: {:error, :duplicate_key}, else: :ok
  end

  defp build_definition("select", key, label, options),
    do: %{"type" => "select", "key" => key, "label" => label, "options" => options}

  defp build_definition(type, key, label, _options),
    do: %{"type" => type, "key" => key, "label" => label}

  defp apply_update(field, attrs) do
    label = attrs |> Map.get(:label, field["label"]) |> String.trim()

    options =
      case Map.get(attrs, :options) do
        nil -> field["options"]
        list -> list |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
      end

    cond do
      label == "" ->
        {:error, :label_required}

      field["type"] == "select" and options == [] ->
        {:error, :options_required}

      true ->
        {:ok, field |> Map.put("label", label) |> maybe_put_options(options)}
    end
  end

  defp maybe_put_options(field, nil), do: field

  defp maybe_put_options(%{"type" => "select"} = field, options),
    do: Map.put(field, "options", options)

  defp maybe_put_options(field, _options), do: field

  defp maybe_put_creator(attrs, opts) do
    case opts[:actor_uuid] do
      uuid when is_binary(uuid) -> Map.put(attrs, :created_by_uuid, uuid)
      _ -> attrs
    end
  end

  # Field definitions are a singleton shared by every supplier row in the
  # install, so a change fans out as its own kind (`:supplier_field`, the
  # blueprint uuid, no catalogue parent) rather than as an
  # `:item_supplier_info` event for every row — consumers that render the
  # per-field columns reload the definitions on it.
  defp tap_log({:ok, entity} = result, action, opts, metadata) do
    log(action, opts, entity.uuid, metadata)
    PubSub.broadcast(:supplier_field, entity.uuid)
    result
  end

  defp tap_log(other, _action, _opts, _metadata), do: other

  defp log(action, opts, resource_uuid, metadata) do
    ActivityLog.log(%{
      action: action,
      mode: opts[:mode] || "manual",
      actor_uuid: opts[:actor_uuid],
      resource_type: "supplier_field",
      resource_uuid: resource_uuid,
      metadata: metadata
    })
  end
end
