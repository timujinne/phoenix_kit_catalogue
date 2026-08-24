defmodule PhoenixKitCatalogue.Catalogue.Rules do
  @moduledoc """
  Smart-catalogue rules — one row per `(item, referenced_catalogue)` pair.

  Items in a smart catalogue (`kind: "smart"`) reference other catalogues
  with a value + unit. The rule row stores the user's intent; consumers
  evaluate the math, and `CatalogueRule.effective/2` resolves null
  `value` / `unit` to the parent item's `default_value` / `default_unit`.

  Provides both the bulk replace-all flow (`put_catalogue_rules/3`,
  preferred when editing the full set in a form) and surgical single-rule
  CRUD (`create_*` / `update_*` / `delete_*`) for CLI / external use.

  Public surface is re-exported from `PhoenixKitCatalogue.Catalogue`.
  """

  import Ecto.Query, warn: false

  alias PhoenixKitCatalogue.Catalogue.{ActivityLog, Helpers, PubSub}
  alias PhoenixKitCatalogue.Schemas.{Catalogue, CatalogueRule, Item}

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc """
  Lists the rules attached to an item, ordered by `position` then by the
  referenced catalogue's name. The `:referenced_catalogue` association
  is preloaded so UIs can render the catalogue name + status without a
  second query.

  Smart items are the only ones that should have rules; a standard item
  simply returns `[]` unless someone put rules on it manually.
  """
  @spec list_catalogue_rules(Item.t() | Ecto.UUID.t()) :: [CatalogueRule.t()]
  def list_catalogue_rules(%Item{uuid: uuid}), do: list_catalogue_rules(uuid)

  def list_catalogue_rules(item_uuid) when is_binary(item_uuid) do
    from(r in CatalogueRule,
      join: c in Catalogue,
      on: r.referenced_catalogue_uuid == c.uuid,
      where: r.item_uuid == ^item_uuid,
      order_by: [asc: r.position, asc: c.name],
      preload: [referenced_catalogue: c]
    )
    |> repo().all()
  end

  @doc """
  Returns the rules for an item as `%{referenced_catalogue_uuid => rule}`.

  Convenient for picker UIs that render every available catalogue row
  and need O(1) lookup for "is this one checked?". Preloads the
  referenced catalogue on each rule.
  """
  @spec catalogue_rule_map(Item.t() | Ecto.UUID.t()) :: %{Ecto.UUID.t() => CatalogueRule.t()}
  def catalogue_rule_map(item_or_uuid) do
    item_or_uuid
    |> list_catalogue_rules()
    |> Map.new(fn %CatalogueRule{referenced_catalogue_uuid: uuid} = rule -> {uuid, rule} end)
  end

  @doc """
  Fetches a single rule by `{item_uuid, referenced_catalogue_uuid}`.
  Returns `nil` if not found. Does not preload the referenced catalogue.
  """
  @spec get_catalogue_rule(Ecto.UUID.t(), Ecto.UUID.t()) :: CatalogueRule.t() | nil
  def get_catalogue_rule(item_uuid, referenced_catalogue_uuid) do
    repo().get_by(CatalogueRule,
      item_uuid: item_uuid,
      referenced_catalogue_uuid: referenced_catalogue_uuid
    )
  end

  @doc """
  Atomic replace-all for an item's rules. See moduledoc for context.
  """
  @spec put_catalogue_rules(Item.t(), [map()], keyword()) ::
          {:ok, [CatalogueRule.t()]}
          | {:error, {:duplicate_referenced_catalogue, Ecto.UUID.t() | nil}}
          | {:error, Ecto.Changeset.t(CatalogueRule.t())}
  def put_catalogue_rules(%Item{} = item, rules, opts \\ []) when is_list(rules) do
    case detect_duplicate_references(rules) do
      {:duplicate, uuid} ->
        {:error, {:duplicate_referenced_catalogue, uuid}}

      :ok ->
        do_put_catalogue_rules(item, rules, opts)
    end
  end

  defp do_put_catalogue_rules(item, rules, opts) do
    existing = list_catalogue_rules(item) |> Map.new(&{&1.referenced_catalogue_uuid, &1})

    incoming_by_uuid =
      Map.new(rules, &{Helpers.fetch_attr(&1, :referenced_catalogue_uuid), &1})

    {to_delete, to_keep} =
      Map.split(existing, Map.keys(existing) -- Map.keys(incoming_by_uuid))

    Ecto.Multi.new()
    |> delete_removed_rules(to_delete)
    |> upsert_rules(item, rules, to_keep)
    |> repo().transaction()
    |> case do
      {:ok, results} ->
        {added, updated} = count_rule_ops(results)
        removed = map_size(to_delete)

        ActivityLog.log(%{
          action: "smart_rules.synced",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "item",
          resource_uuid: item.uuid,
          metadata: %{
            "added" => added,
            "updated" => updated,
            "removed" => removed,
            "total" => length(rules)
          }
        })

        # Batch callers (the PRO100 template loader) write inside their own
        # transaction and roll the fan-out up after commit.
        if Keyword.get(opts, :broadcast, true),
          do: PubSub.broadcast(:smart_rule, item.uuid, item.catalogue_uuid)

        {:ok, list_catalogue_rules(item)}

      {:error, _step, changeset, _changes} ->
        {:error, changeset}
    end
  end

  defp detect_duplicate_references(rules) do
    rules
    |> Enum.map(&Helpers.fetch_attr(&1, :referenced_catalogue_uuid))
    |> Enum.reduce_while(MapSet.new(), fn uuid, seen ->
      cond do
        is_nil(uuid) -> {:halt, {:duplicate, nil}}
        MapSet.member?(seen, uuid) -> {:halt, {:duplicate, uuid}}
        true -> {:cont, MapSet.put(seen, uuid)}
      end
    end)
    |> case do
      {:duplicate, _} = err -> err
      _ -> :ok
    end
  end

  defp delete_removed_rules(multi, to_delete) do
    Enum.reduce(to_delete, multi, fn {uuid, rule}, multi ->
      Ecto.Multi.delete(multi, {:delete, uuid}, rule)
    end)
  end

  defp upsert_rules(multi, item, rules, to_keep) do
    rules
    |> Enum.with_index()
    |> Enum.reduce(multi, fn {rule_attrs, idx}, multi ->
      referenced_uuid = Helpers.fetch_attr(rule_attrs, :referenced_catalogue_uuid)
      attrs = rule_attrs_with_item_and_position(rule_attrs, item, idx)

      case Map.get(to_keep, referenced_uuid) do
        nil ->
          changeset = build_rule_changeset(%CatalogueRule{}, attrs)
          Ecto.Multi.insert(multi, {:insert, referenced_uuid}, changeset)

        %CatalogueRule{} = existing ->
          changeset = build_rule_changeset(existing, attrs)
          Ecto.Multi.update(multi, {:update, referenced_uuid}, changeset)
      end
    end)
  end

  # Merges :item_uuid (from the item) and defaults a missing :position
  # to the rule's index in the incoming list.
  defp rule_attrs_with_item_and_position(rule_attrs, item, idx) do
    rule_attrs
    |> normalize_rule_attrs()
    |> Map.put(:item_uuid, item.uuid)
    |> Map.put_new(:position, idx)
  end

  # Closed-set string-key normalizer. Unknown string keys are dropped
  # (rather than raising via `String.to_existing_atom/1`) so a future
  # caller that adds an unrecognized field gets a clean changeset
  # validation error instead of a confusing ArgumentError.
  @rule_known_keys ~w(item_uuid referenced_catalogue_uuid value unit position)
  defp normalize_rule_attrs(attrs) when is_map(attrs) do
    Enum.reduce(attrs, %{}, fn
      {k, v}, acc when is_atom(k) ->
        Map.put(acc, k, v)

      {k, v}, acc when is_binary(k) and k in @rule_known_keys ->
        Map.put(acc, String.to_atom(k), v)

      {_k, _v}, acc ->
        acc
    end)
  end

  defp count_rule_ops(results) when is_map(results) do
    Enum.reduce(results, {0, 0}, fn
      {{:insert, _}, _}, {ins, upd} -> {ins + 1, upd}
      {{:update, _}, _}, {ins, upd} -> {ins, upd + 1}
      _, acc -> acc
    end)
  end

  @doc """
  Re-indexes the rule rows attached to an item from a list of
  referenced-catalogue UUIDs.

  This is the lighter-weight sibling of `put_catalogue_rules/3` for the
  DnD case — leaves `value` / `unit` untouched, only writes new
  `position` values `1..N`. UUIDs that don't match an existing rule on
  the item are silently skipped (a stale-DOM artifact, not worth
  blowing up over). Wraps both passes in a single transaction.
  """
  # Same cap reasoning as the catalogues / categories / items reorder
  # paths in `Catalogue` — single source of truth via
  # `config :phoenix_kit_catalogue, :reorder_max_uuids, N`. Resolved at
  # compile time so it's available in the `when length(x) > @…` guard.
  @reorder_max_uuids Application.compile_env(
                       :phoenix_kit_catalogue,
                       :reorder_max_uuids,
                       1000
                     )

  @spec reorder_catalogue_rules(Ecto.UUID.t(), [Ecto.UUID.t()], keyword()) ::
          :ok | {:error, :too_many_uuids | term()}
  def reorder_catalogue_rules(item_uuid, ordered_referenced_uuids, opts \\ [])

  def reorder_catalogue_rules(item_uuid, ordered_referenced_uuids, opts)
      when is_binary(item_uuid) and is_list(ordered_referenced_uuids) and
             length(ordered_referenced_uuids) > @reorder_max_uuids do
    log_smart_rules_reorder_rejected(
      :too_many_uuids,
      length(ordered_referenced_uuids),
      item_uuid,
      opts
    )

    {:error, :too_many_uuids}
  end

  def reorder_catalogue_rules(item_uuid, ordered_referenced_uuids, opts)
      when is_binary(item_uuid) and is_list(ordered_referenced_uuids) do
    unique = Helpers.dedupe_keep_last(ordered_referenced_uuids)
    pairs = Enum.with_index(unique, 1)

    # Future (perf): collapse the two-pass loop below to a single
    # `UPDATE phoenix_kit_cat_item_catalogue_rules SET position = v.pos
    #   FROM (VALUES (item_uuid, ref_uuid, pos), …) AS v(...)
    #   WHERE …` round-trip per item. Trigger to revisit:
    # `:reorder_max_uuids` config bumped past 1000, or a unique index
    # on `(item_uuid, position)` is added.
    result =
      repo().transaction(fn ->
        Enum.each(pairs, fn {ref_uuid, idx} ->
          from(r in CatalogueRule,
            where: r.item_uuid == ^item_uuid and r.referenced_catalogue_uuid == ^ref_uuid
          )
          |> repo().update_all(set: [position: -idx])
        end)

        Enum.each(pairs, fn {ref_uuid, idx} ->
          from(r in CatalogueRule,
            where: r.item_uuid == ^item_uuid and r.referenced_catalogue_uuid == ^ref_uuid
          )
          |> repo().update_all(set: [position: idx])
        end)
      end)

    case result do
      {:ok, _} ->
        ActivityLog.log(%{
          action: "smart_rules.reordered",
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: "item",
          resource_uuid: item_uuid,
          metadata: %{"count" => length(unique)}
        })

        PubSub.broadcast(:smart_rule, item_uuid, item_parent_catalogue_uuid(item_uuid))
        :ok

      {:error, reason} ->
        log_smart_rules_reorder_db_error(item_uuid, length(unique), opts)
        {:error, reason}
    end
  end

  defp log_smart_rules_reorder_rejected(reason, count, item_uuid, opts) do
    ActivityLog.log(%{
      action: "smart_rules.reordered",
      mode: "manual",
      actor_uuid: opts[:actor_uuid],
      resource_type: "item",
      resource_uuid: item_uuid,
      metadata: %{
        "count" => count,
        "db_pending" => true,
        "rejected" => to_string(reason)
      }
    })
  end

  defp log_smart_rules_reorder_db_error(item_uuid, count, opts) do
    ActivityLog.log(%{
      action: "smart_rules.reordered",
      mode: "manual",
      actor_uuid: opts[:actor_uuid],
      resource_type: "item",
      resource_uuid: item_uuid,
      metadata: %{
        "count" => count,
        "db_pending" => true
      }
    })
  end

  @doc """
  Lists non-deleted smart items that reference a given catalogue.

  Useful for warning-before-delete flows: "This catalogue is referenced
  by 3 smart items — deleting it cascades to those rules."

  Preloads the parent catalogue so the UI can render "Services / Delivery".
  """
  @spec list_items_referencing_catalogue(Ecto.UUID.t()) :: [Item.t()]
  def list_items_referencing_catalogue(catalogue_uuid) do
    # Newer Ecto requires the preload binding to be present in `select`.
    # Pull `i` (the items) directly via the rules' has-many → switch to
    # `Item`-rooted query joining through rules, and preload off it.
    from(i in Item,
      join: r in CatalogueRule,
      on: r.item_uuid == i.uuid,
      where: r.referenced_catalogue_uuid == ^catalogue_uuid,
      where: i.status != "deleted",
      order_by: [asc: i.name, asc: i.uuid],
      distinct: true,
      preload: [:catalogue]
    )
    |> repo().all()
  end

  @doc """
  Returns the count of rules referencing a given catalogue (non-deleted
  items only). Cheaper than `list_items_referencing_catalogue/1` when
  you just need a badge number.
  """
  @spec catalogue_reference_count(Ecto.UUID.t()) :: non_neg_integer()
  def catalogue_reference_count(catalogue_uuid) do
    from(r in CatalogueRule,
      join: i in Item,
      on: r.item_uuid == i.uuid,
      where: r.referenced_catalogue_uuid == ^catalogue_uuid,
      where: i.status != "deleted"
    )
    |> repo().aggregate(:count)
  end

  @doc "Returns a changeset for tracking a single rule's changes."
  @spec change_catalogue_rule(CatalogueRule.t(), map()) :: Ecto.Changeset.t(CatalogueRule.t())
  def change_catalogue_rule(%CatalogueRule{} = rule, attrs \\ %{}) do
    build_rule_changeset(rule, attrs)
  end

  # Builds the canonical write-side changeset: schema validation plus the
  # context-level smart-chain guard (a smart catalogue may not be the
  # `referenced_catalogue` of a rule — see issue #16). Self-references
  # are rejected as a side effect of the same guard: the only way to
  # self-reference is for the rule's referenced catalogue to be the
  # item's own catalogue, which (since rules only exist on smart items)
  # is smart by definition and therefore caught here.
  defp build_rule_changeset(rule, attrs) do
    rule
    |> CatalogueRule.changeset(attrs)
    |> validate_referenced_catalogue_kind()
  end

  # Rejects rules whose referenced catalogue is itself smart. Without
  # this guard, downstream consumers — which sum standard items only —
  # silently treat the rule's contribution as 0 with no UI signal.
  #
  # Only runs when `:referenced_catalogue_uuid` is in `changes` (i.e. a
  # new rule, or an existing rule whose ref the user just changed). On
  # the form-validate path that means: one DB lookup when the picker
  # selection changes, zero on every other keystroke. The catalogue's
  # `kind` was already validated when the original ref was written, so
  # re-checking unchanged values would only surface drift from a
  # standard→smart kind flip — out of scope for a per-keystroke guard.
  defp validate_referenced_catalogue_kind(%Ecto.Changeset{} = changeset) do
    case Ecto.Changeset.get_change(changeset, :referenced_catalogue_uuid) do
      nil ->
        changeset

      uuid ->
        case repo().get(Catalogue, uuid) do
          %Catalogue{kind: "smart"} ->
            Ecto.Changeset.add_error(
              changeset,
              :referenced_catalogue_uuid,
              "must reference a standard catalogue, not a smart catalogue",
              validation: :smart_chain
            )

          _ ->
            changeset
        end
    end
  end

  @doc """
  Inserts a single rule. Prefer `put_catalogue_rules/3` for managing an
  item's full set of rules; this function exists for surgical edits.
  """
  @spec create_catalogue_rule(map(), keyword()) ::
          {:ok, CatalogueRule.t()} | {:error, Ecto.Changeset.t(CatalogueRule.t())}
  def create_catalogue_rule(attrs, opts \\ []) do
    result =
      ActivityLog.with_log(
        fn ->
          %CatalogueRule{}
          |> build_rule_changeset(normalize_rule_attrs(attrs))
          |> repo().insert()
        end,
        fn rule ->
          %{
            action: "smart_rule.created",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "smart_rule",
            resource_uuid: rule.uuid,
            metadata: %{
              "item_uuid" => rule.item_uuid,
              "referenced_catalogue_uuid" => rule.referenced_catalogue_uuid
            }
          }
        end
      )

    with {:ok, rule} <- result do
      PubSub.broadcast(:smart_rule, rule.item_uuid, item_parent_catalogue_uuid(rule.item_uuid))
      {:ok, rule}
    end
  end

  @doc "Updates a single rule's `value`/`unit`/`position`."
  @spec update_catalogue_rule(CatalogueRule.t(), map(), keyword()) ::
          {:ok, CatalogueRule.t()} | {:error, Ecto.Changeset.t(CatalogueRule.t())}
  def update_catalogue_rule(%CatalogueRule{} = rule, attrs, opts \\ []) do
    result =
      ActivityLog.with_log(
        fn -> rule |> build_rule_changeset(normalize_rule_attrs(attrs)) |> repo().update() end,
        fn updated ->
          %{
            action: "smart_rule.updated",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "smart_rule",
            resource_uuid: updated.uuid,
            metadata: %{
              "item_uuid" => updated.item_uuid,
              "referenced_catalogue_uuid" => updated.referenced_catalogue_uuid
            }
          }
        end
      )

    with {:ok, updated} <- result do
      PubSub.broadcast(
        :smart_rule,
        updated.item_uuid,
        item_parent_catalogue_uuid(updated.item_uuid)
      )

      {:ok, updated}
    end
  end

  @doc "Deletes a single rule."
  @spec delete_catalogue_rule(CatalogueRule.t(), keyword()) ::
          {:ok, CatalogueRule.t()} | {:error, Ecto.Changeset.t(CatalogueRule.t())}
  def delete_catalogue_rule(%CatalogueRule{} = rule, opts \\ []) do
    result =
      ActivityLog.with_log(
        fn -> repo().delete(rule) end,
        fn deleted ->
          %{
            action: "smart_rule.deleted",
            mode: "manual",
            actor_uuid: opts[:actor_uuid],
            resource_type: "smart_rule",
            resource_uuid: deleted.uuid,
            metadata: %{
              "item_uuid" => deleted.item_uuid,
              "referenced_catalogue_uuid" => deleted.referenced_catalogue_uuid
            }
          }
        end
      )

    with {:ok, deleted} <- result do
      PubSub.broadcast(
        :smart_rule,
        deleted.item_uuid,
        item_parent_catalogue_uuid(deleted.item_uuid)
      )

      {:ok, deleted}
    end
  end

  # Lookup the parent catalogue for a smart-rule broadcast. The rule
  # itself only knows its item_uuid; the detail LV needs the catalogue
  # UUID to filter cross-catalogue noise. Delegates to the shared
  # `Helpers.item_catalogue_uuid/1` so this and `Catalogue.lookup_parent(:item, _)`
  # don't duplicate the same query (PR #13 review #2 dedupe).
  defp item_parent_catalogue_uuid(item_uuid) when is_binary(item_uuid),
    do: Helpers.item_catalogue_uuid(item_uuid)

  defp item_parent_catalogue_uuid(_), do: nil
end
