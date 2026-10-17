defmodule PhoenixKitCatalogue.Catalogue.Shared do
  @moduledoc false
  # Private helpers of the catalogue context that more than one section
  # (`Catalogues`, `Categories`, `Folders`, `Items`) calls: the activity-log
  # and PubSub fan-out, the reorder audit rows, the interleaved
  # folder/catalogue level positions and their advisory lock, the slug
  # projection lookups, and the trash-status and data-ownership guards of
  # the create/update paths. Internal; reached only from `Catalogue.*`.

  import Ecto.Query, warn: false

  alias PhoenixKitCatalogue.Catalogue.{ActivityLog, Helpers, PubSub}
  alias PhoenixKitCatalogue.Schemas.{Catalogue, Category, Folder}

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # A move's two ends, snapshotted with the names they had at the time. The
  # log used to carry `from_category_uuid`/`to_category_uuid` and friends —
  # true, and unreadable: the owner saw walls of uuids and could not tell
  # where a thing had gone (boss via Max, 2026-09-20).
  #
  # Resolved on the WRITE, deliberately: a name looked up on read changes
  # under the reader and vanishes entirely once the category is deleted,
  # which is the moment the log is the only record of where something was.
  @doc false
  def category_ref(nil), do: ActivityLog.ref(nil, nil, uncategorized_label())

  def category_ref(uuid) do
    ActivityLog.ref(
      uuid,
      name_of(&PhoenixKitCatalogue.Catalogue.get_category/1, uuid),
      uncategorized_label()
    )
  end

  @doc false
  def catalogue_ref(uuid),
    do: ActivityLog.ref(uuid, name_of(&PhoenixKitCatalogue.Catalogue.get_catalogue/1, uuid))

  @doc false
  def name_of(getter, uuid) when is_binary(uuid) do
    case getter.(uuid) do
      %{name: name} -> name
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def name_of(_getter, _uuid), do: nil

  @doc false
  def uncategorized_label,
    do: Gettext.gettext(PhoenixKitCatalogue.Gettext, "Uncategorized")

  # Same source of truth as `PhoenixKit.SchemaPrefix` (`config :phoenix_kit,
  # prefix: ...`), for the one place in this module that reaches the slug
  # projection tables with raw SQL instead of a schema-backed Ecto query —
  # a named-schema install must not silently query `public`.
  @doc false
  def qualified(table) do
    case Application.get_env(:phoenix_kit, :prefix) do
      prefix when is_binary(prefix) and prefix not in ["", "public"] -> "#{prefix}.#{table}"
      _ -> table
    end
  end

  # `log_activity/1` was extracted to `PhoenixKitCatalogue.Catalogue.ActivityLog`
  # so the per-section submodules can share it without circular imports.
  # Internal callers in the remaining sections still use this thin
  # alias for diff churn minimization.
  # `log_activity/1` writes an audit-log entry **and** fans out a
  # `{:catalogue_data_changed, kind, uuid, parent_catalogue_uuid}` event
  # so list LVs subscribed via `PubSub.subscribe/0` re-fetch. The two are
  # coupled here because every write in this module that's worth auditing
  # is also worth signalling — keeping them paired prevents accidental
  # "I logged but forgot to broadcast" drift. Submodules under
  # `PhoenixKitCatalogue.Catalogue.*` call `ActivityLog.log/1` and
  # `PubSub.broadcast/3` directly to keep their dependencies explicit.
  #
  # The optional `parent_catalogue_uuid` field on `attrs` is used purely
  # for PubSub routing (it's stripped before the activity entry is
  # persisted). Bulk callers can pass `broadcast: false` in the second
  # argument to suppress the per-row fan-out and emit a single roll-up
  # broadcast at the end of the batch.
  @doc false
  def log_activity(attrs, opts \\ []) do
    {parent_catalogue_uuid, attrs} = Map.pop(attrs, :parent_catalogue_uuid)

    # The shop API's `via` / `key_prefix` / `request_id` / `tool` ride in
    # `opts[:log_metadata]`; the entry's own metadata wins on a clash.
    attrs =
      case Keyword.get(opts, :log_metadata) do
        extra when is_map(extra) and map_size(extra) > 0 ->
          Map.update(
            attrs,
            :metadata,
            ActivityLog.with_extra(%{}, extra),
            &ActivityLog.with_extra(&1, extra)
          )

        _none ->
          attrs
      end

    # The caller's `mode` wins over the site's default ("manual"): the
    # importer passes `mode: "auto"`, and until 2026-09-12 every site but
    # `create_item/2` dropped it, so the log could not tell an import
    # from a hand edit.
    attrs =
      case Keyword.get(opts, :mode) do
        mode when is_binary(mode) -> Map.put(attrs, :mode, mode)
        _ -> attrs
      end

    ActivityLog.log(attrs)

    if Keyword.get(opts, :broadcast, true) do
      broadcast_for(attrs, parent_catalogue_uuid)
    end

    :ok
  end

  @doc false
  def broadcast_for(%{resource_type: "catalogue", resource_uuid: uuid}, _parent),
    do: PubSub.broadcast(:catalogue, uuid, uuid)

  def broadcast_for(%{resource_type: "category", resource_uuid: uuid}, parent),
    do: PubSub.broadcast(:category, uuid, parent || lookup_parent(:category, uuid))

  def broadcast_for(%{resource_type: "item", resource_uuid: uuid}, parent),
    do: PubSub.broadcast(:item, uuid, parent || lookup_parent(:item, uuid))

  # Folders are module-global, not scoped to a single catalogue, so there's
  # no parent_catalogue_uuid to thread — the index LV reloads its whole tree
  # on any :folder event regardless of the parent slot.
  def broadcast_for(%{resource_type: "folder", resource_uuid: uuid}, _parent),
    do: PubSub.broadcast(:folder, uuid)

  # Batch writes (bulk trash / restore / move, category reorder) log ONE
  # activity row for the whole batch and carry no single `resource_uuid`.
  # They still have to fan out — the index "Items" column and every open
  # detail page count them — so the batch rides the same kind with a
  # `nil` uuid and the catalogue as parent. Consumers already treat the
  # uuid as informational and refresh the whole slice.
  def broadcast_for(%{resource_type: "item"}, parent) when is_binary(parent),
    do: PubSub.broadcast(:item, nil, parent)

  def broadcast_for(%{resource_type: "category"}, parent) when is_binary(parent),
    do: PubSub.broadcast(:category, nil, parent)

  # Manufacturer/supplier/smart_rule activity rows never reach this
  # helper today — `Manufacturers`, `Suppliers`, and `Rules` call
  # `PubSub.broadcast/3` directly and bypass `log_activity`. Anything
  # else falls through to `:ok` so adding a new resource type doesn't
  # crash the audit-log path before its broadcast clause is wired up.
  def broadcast_for(_attrs, _parent), do: :ok

  # Fallback: when a caller doesn't thread `parent_catalogue_uuid:` into
  # the activity-log attrs, look it up here so detail LVs can still
  # filter cross-catalogue noise. One indexed pkey lookup per broadcast
  # — adds ~ms to mutations on the rare path where the parent isn't
  # already in scope. High-frequency callers (smart-rules sync, item
  # CRUD) should thread it explicitly to avoid the lookup.
  @doc false
  def lookup_parent(:category, uuid) when is_binary(uuid) do
    case repo().one(from(c in Category, where: c.uuid == ^uuid, select: c.catalogue_uuid)) do
      nil -> nil
      parent_uuid -> parent_uuid
    end
  end

  def lookup_parent(:item, uuid) when is_binary(uuid) do
    Helpers.item_catalogue_uuid(uuid)
  end

  def lookup_parent(_kind, _uuid), do: nil

  # Same cap reasoning as entities — even a workspace with hundreds of
  # catalogues, categories, or items per group never paints a thousand
  # at once. Beyond this we'd want an explicit batched API rather than
  # an unbounded transaction. Resolved at compile time so the literal
  # is available inside `when length(x) > @reorder_max_uuids` guards.
  # Single source of truth shared with `Catalogue.Rules` via
  # `config :phoenix_kit_catalogue, :reorder_max_uuids, N`.
  @reorder_max_uuids Application.compile_env(
                       :phoenix_kit_catalogue,
                       :reorder_max_uuids,
                       1000
                     )

  # Reorder logging helpers shared by `reorder_catalogues/2`,
  # `reorder_categories/4`, and `reorder_items/4`.
  # `log_reorder_rejected/5` and `log_reorder_db_error/5` cover the
  # audit-trail gap on early rejection (`:too_many_uuids`,
  # `:not_siblings`, `:wrong_scope`) and post-transaction failure.
  # `db_pending: true` lets audit consumers tell rejected/failed rows
  # apart from successful ones.
  #
  # All logging helpers run **outside** the database transaction, so
  # callers that wrap a reorder in an outer transaction (e.g.
  # a future in-transaction caller) can rely on the rejection
  # row landing even when the outer rolls back.

  @doc false
  def log_reorder_rejected(kind, reason, count, parent_catalogue_uuid, opts) do
    ActivityLog.log(
      Map.merge(
        %{
          action: reorder_action_for(kind),
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: to_string(kind),
          metadata: %{
            "count" => count,
            "db_pending" => true,
            "rejected" => to_string(reason)
          }
        },
        if(parent_catalogue_uuid,
          do: %{parent_catalogue_uuid: parent_catalogue_uuid},
          else: %{}
        )
      )
    )
  end

  @doc false
  def log_reorder_db_error(kind, ordered_uuids, parent_catalogue_uuid, opts, extras \\ []) do
    metadata =
      %{
        "count" => length(ordered_uuids),
        "db_pending" => true
      }
      |> maybe_put_metadata("category_uuid", Keyword.get(extras, :category_uuid))

    ActivityLog.log(
      Map.merge(
        %{
          action: reorder_action_for(kind),
          mode: "manual",
          actor_uuid: opts[:actor_uuid],
          resource_type: to_string(kind),
          resource_uuid: List.first(ordered_uuids),
          metadata: metadata
        },
        if(parent_catalogue_uuid,
          do: %{parent_catalogue_uuid: parent_catalogue_uuid},
          else: %{}
        )
      )
    )
  end

  @doc false
  def reorder_action_for(:catalogue), do: "catalogue.reordered"
  def reorder_action_for(:category), do: "category.reordered"
  def reorder_action_for(:item), do: "item.reordered"
  def reorder_action_for(:folder), do: "folder.reordered"
  def reorder_action_for(:level), do: "catalogue.level_reordered"

  @doc false
  def maybe_put_metadata(map, _key, nil), do: map
  def maybe_put_metadata(map, key, value), do: Map.put(map, key, value)

  # Shared by `update_item/3` and `update_category/3`'s `:data_owned_keys`
  # option — see `update_item/3`'s doc for the full rationale. `nil` (no
  # option passed) is a no-op so every existing caller keeps the plain
  # full-replace behavior.
  #
  # Must run INSIDE the caller's transaction: the `FOR UPDATE` lock this
  # takes only protects against a concurrent writer landing between our
  # read and the eventual `repo().update()` if both happen on the same
  # connection/transaction.
  @doc false
  def narrow_data_ownership(schema, uuid, attrs, opts) when is_map(attrs) do
    case Keyword.get(opts, :data_owned_keys) do
      nil -> attrs
      owned_keys -> splice_owned_data(schema, uuid, attrs, owned_keys)
    end
  end

  @doc false
  def splice_owned_data(schema, uuid, attrs, owned_keys) do
    case lock_fresh(schema, uuid) do
      nil ->
        attrs

      %{data: fresh_data} ->
        incoming_data = Helpers.fetch_attr(attrs, :data) || %{}
        owned = Map.take(incoming_data, owned_keys)
        merged = apply_owned_data(fresh_data || %{}, owned)
        Helpers.put_attr(attrs, :data, merged)
    end
  end

  # An owned key present in `owned` with a non-`nil` value overwrites the
  # fresh row's value for that key — the caller's normal write. An owned
  # key present with an EXPLICIT `nil` is a "clear this" marker (see
  # `PhoenixKitCatalogue.Attachments.inject_attachment_data/2` /
  # `inject_media_order/2`, which write `nil` rather than simply omitting
  # the key) and comes out of the result entirely — the record must end
  # up looking exactly like one that never had the key, not one holding
  # a JSON `null` (`Schemas.Item`/`Schemas.Category`'s changeset enforces
  # the same thing at cast time; doing it here too keeps this function's
  # own contract self-evident). A key `owned` doesn't mention at all —
  # because the caller's `attrs["data"]` never mentioned it — is left
  # untouched, distinct from an explicit `nil`: that's the whole point of
  # `:data_owned_keys` (see `update_item/3`'s doc).
  @doc false
  def apply_owned_data(fresh_data, owned) do
    Enum.reduce(owned, fresh_data, fn
      {key, nil}, acc -> Map.delete(acc, key)
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  # `:data_owned_paths`: `nil` when the option is absent, the validated list
  # otherwise. A malformed value is the caller's bug and raises.
  @doc false
  def owned_paths!(opts) do
    case Keyword.get(opts, :data_owned_paths) do
      nil ->
        nil

      paths ->
        if Keyword.get(opts, :data_owned_keys) != nil do
          raise ArgumentError, ":data_owned_paths and :data_owned_keys are mutually exclusive"
        end

        if valid_paths?(paths) do
          paths
        else
          raise ArgumentError,
                ":data_owned_paths must be a list of non-empty lists of non-empty strings " <>
                  "(the first segment may not be \"_trash\")"
        end
    end
  end

  defp valid_paths?(paths) when is_list(paths) do
    Enum.all?(paths, fn
      [first | _] = path ->
        first != "_trash" and Enum.all?(path, &(is_binary(&1) and &1 != ""))

      _other ->
        false
    end)
  end

  defp valid_paths?(_other), do: false

  # `:slug_owned_langs`: `nil` when the option is absent, the validated list
  # otherwise. The messages carry no values: an ArgumentError message may end
  # up in a log.
  @doc false
  def slug_langs!(opts) do
    case Keyword.get(opts, :slug_owned_langs) do
      nil ->
        nil

      langs when is_list(langs) ->
        if Enum.all?(langs, &(is_binary(&1) and &1 != "")),
          do: langs,
          else: raise(ArgumentError, ":slug_owned_langs must be a list of non-empty strings")

      _other ->
        raise ArgumentError, ":slug_owned_langs must be a list of non-empty strings"
    end
  end

  # Both options of the row-locked update, validated together: `{paths, langs}`,
  # each `nil` when its option is absent.
  @doc false
  def owned_options!(opts) do
    paths = owned_paths!(opts)
    langs = slug_langs!(opts)

    if langs != nil and paths == nil,
      do: raise(ArgumentError, ":slug_owned_langs needs :data_owned_paths (the row lock)")

    {paths, langs}
  end

  # Merges the owned languages of `attrs[:slug]` into the fresh row's slug map.
  # `nil` langs (option absent): `attrs[:slug]` is cast whole like any column.
  # With the option, and nothing to merge (`[]`, no `:slug` sent, or a `:slug`
  # that is not a map), `:slug` is taken out of `attrs` so the fresh row's slug
  # map stays exactly as it is.
  @doc false
  def splice_owned_slugs(_fresh, attrs, nil), do: attrs

  def splice_owned_slugs(%{slug: fresh_slug}, attrs, langs) do
    case Helpers.fetch_attr(attrs, :slug) do
      %{} = incoming when langs != [] ->
        Helpers.put_attr(attrs, :slug, merge_slug_langs(fresh_slug || %{}, incoming, langs))

      _nothing_to_merge ->
        attrs |> Map.delete(:slug) |> Map.delete("slug")
    end
  end

  defp merge_slug_langs(fresh_slug, incoming, langs) do
    Enum.reduce(langs, fresh_slug, fn lang, acc ->
      case Map.get(incoming, lang) do
        slug when is_binary(slug) and slug != "" -> Map.put(acc, lang, slug)
        _blank -> Map.delete(acc, lang)
      end
    end)
  end

  @doc false
  def lock_fresh(schema, uuid),
    do: repo().one(from(r in schema, where: r.uuid == ^uuid, lock: "FOR UPDATE"))

  # Copies the owned paths from `attrs["data"]` onto the fresh row's `data`;
  # everything else in the result is the fresh row's. A path absent from the
  # incoming data is left alone, an explicit `nil` deletes it.
  @doc false
  def splice_owned_paths(%{data: fresh_data}, attrs, paths) do
    incoming = Helpers.fetch_attr(attrs, :data) || %{}

    merged =
      Enum.reduce(paths, fresh_data || %{}, fn path, acc ->
        case fetch_path(incoming, path) do
          {:ok, nil} -> delete_path(acc, path)
          {:ok, value} -> put_path(acc, path, value)
          :error -> acc
        end
      end)

    Helpers.put_attr(attrs, :data, merged)
  end

  defp fetch_path(%{} = map, [key]), do: Map.fetch(map, key)

  defp fetch_path(%{} = map, [key | rest]) do
    case Map.get(map, key) do
      %{} = child -> fetch_path(child, rest)
      _other -> :error
    end
  end

  defp fetch_path(_other, _path), do: :error

  defp put_path(map, [key], value), do: Map.put(map, key, value)

  defp put_path(map, [key | rest], value) do
    child =
      case Map.get(map, key) do
        %{} = existing -> existing
        _other -> %{}
      end

    Map.put(map, key, put_path(child, rest, value))
  end

  # Deletes the leaf and prunes the maps it leaves empty, so a record ends up
  # looking like one that never had the key.
  defp delete_path(map, [key]), do: Map.delete(map, key)

  defp delete_path(map, [key | rest]) do
    case Map.get(map, key) do
      %{} = child ->
        case delete_path(child, rest) do
          empty when map_size(empty) == 0 -> Map.delete(map, key)
          pruned -> Map.put(map, key, pruned)
        end

      _other ->
        map
    end
  end

  # The canonical string form only: `Ecto.UUID.cast/1` also accepts any
  # 16-byte binary, which later dumps and lock keys would mishandle.
  @doc false
  def valid_uuid?(value), do: is_binary(value) and Ecto.UUID.cast(value) == {:ok, value}

  # A move destination must be a live catalogue of the source's kind:
  # standard items price from base price + markup, smart items from
  # their rules, so a row carried across kinds would lose its meaning.
  # Runs under the destination's catalogue lock (the callers take it).
  @doc false
  def check_move_destination!(source_catalogue_uuid, target_catalogue_uuid) do
    kinds =
      from(c in Catalogue,
        where: c.uuid in ^Enum.uniq([source_catalogue_uuid, target_catalogue_uuid]),
        where: c.status != "deleted" or c.uuid == ^source_catalogue_uuid,
        select: {c.uuid, c.kind}
      )
      |> repo().all()
      |> Map.new()

    case {Map.get(kinds, source_catalogue_uuid), Map.get(kinds, target_catalogue_uuid)} do
      {_, nil} -> repo().rollback(:catalogue_not_found)
      {kind, kind} -> :ok
      _ -> repo().rollback(:kind_mismatch)
    end
  end

  # Next free slot in the interleaved folder+catalogue sequence at this
  # level (`nil` = root). Folders and catalogues share one `position`
  # number line; a type-specific max would land a new row on top of the
  # other type.
  @doc false
  def next_level_position(level_uuid) do
    case level_position_bound(:max, level_uuid) do
      nil -> 1
      n -> n + 1
    end
  end

  @doc false
  def level_position_bound(agg, level_uuid) do
    combine_bound(
      agg,
      folder_position_bound(agg, level_uuid),
      catalogue_position_bound(agg, level_uuid)
    )
  end

  @doc false
  def combine_bound(_agg, nil, nil), do: nil
  def combine_bound(_agg, a, nil), do: a
  def combine_bound(_agg, nil, b), do: b
  def combine_bound(:max, a, b), do: max(a, b)
  def combine_bound(:min, a, b), do: min(a, b)

  @doc false
  def folder_position_bound(agg, level_uuid) do
    scoped =
      case level_uuid do
        nil -> from(f in Folder, where: f.status != "deleted" and is_nil(f.parent_uuid))
        uuid -> from(f in Folder, where: f.status != "deleted" and f.parent_uuid == ^uuid)
      end

    query =
      case agg do
        :max -> from(f in scoped, select: max(f.position))
        :min -> from(f in scoped, select: min(f.position))
      end

    repo().one(query)
  end

  @doc false
  def catalogue_position_bound(agg, level_uuid) do
    scoped =
      case level_uuid do
        nil -> from(c in Catalogue, where: c.status != "deleted" and is_nil(c.folder_uuid))
        uuid -> from(c in Catalogue, where: c.status != "deleted" and c.folder_uuid == ^uuid)
      end

    query =
      case agg do
        :max -> from(c in scoped, select: max(c.position))
        :min -> from(c in scoped, select: min(c.position))
      end

    repo().one(query)
  end

  # Folder uuid normalization: "", "unfiled", :unfiled, nil all mean root.
  @doc false
  def normalize_folder_uuid(nil), do: nil
  def normalize_folder_uuid(""), do: nil
  def normalize_folder_uuid(:unfiled), do: nil
  def normalize_folder_uuid("unfiled"), do: nil
  def normalize_folder_uuid(uuid) when is_binary(uuid), do: uuid

  # Shared advisory-lock key for the catalogues/folders position domain
  # (issue #56): every writer of that order — flat catalogue reorder,
  # folder reorder, and the interleaved level placement — takes the same
  # transaction-scoped lock, so two simultaneous drags serialise instead
  # of interleaving their per-row updates into a mixed order with
  # duplicate positions. Released automatically at transaction end.
  @catalogues_order_lock_key 727_401_119

  @doc false
  def lock_catalogues_order! do
    repo().query!("SELECT pg_advisory_xact_lock($1)", [@catalogues_order_lock_key])
  end

  # Shared by `get_item_by_slug/3` and `get_category_by_slug/3`. Looks up
  # the projected uuid for `slug` in `lang`'s base language, optionally
  # falling back to any language (`opts[:any_lang]`), then resolves it
  # through `get_fun` (which also receives every other option, e.g.
  # `:preload`). A resolved uuid whose row has since disappeared (a
  # deleted item/category racing the projection's `ON DELETE CASCADE`)
  # is treated the same as a lookup miss.
  @doc false
  def find_by_slug(table, uuid_column, slug, lang, opts, get_fun) do
    any_lang? = Keyword.get(opts, :any_lang, false)
    fetch_opts = Keyword.drop(opts, [:any_lang])
    base = base_lang(lang)

    found =
      case query_slug(table, uuid_column, base, slug) do
        nil when any_lang? -> query_slug(table, uuid_column, nil, slug)
        result -> result
      end

    case found do
      nil ->
        {:error, :not_found}

      {uuid, matched_lang} ->
        case get_fun.(uuid, fetch_opts) do
          nil -> {:error, :not_found}
          struct when any_lang? -> {:ok, struct, matched_lang}
          struct -> {:ok, struct}
        end
    end
  end

  @doc false
  def slug_taken?(table, uuid_column, slug, lang, exclude_uuid)
      when is_binary(slug) and is_binary(lang) do
    case query_slug(table, uuid_column, base_lang(lang), slug) do
      nil -> false
      {uuid, _lang} -> uuid != exclude_uuid
    end
  end

  @doc false
  def base_lang(lang), do: lang |> String.split("-") |> List.first() |> String.downcase()

  @doc false
  def query_slug(table, uuid_column, nil, slug) do
    %{rows: rows} =
      repo().query!(
        "SELECT #{uuid_column}::text, lang FROM #{qualified(table)} WHERE value = $1 ORDER BY lang LIMIT 1",
        [slug]
      )

    one_row(rows)
  end

  def query_slug(table, uuid_column, lang, slug) do
    %{rows: rows} =
      repo().query!(
        "SELECT #{uuid_column}::text, lang FROM #{qualified(table)} WHERE lang = $1 AND value = $2 LIMIT 1",
        [lang, slug]
      )

    one_row(rows)
  end

  @doc false
  def one_row([[uuid, lang]]), do: {uuid, lang}
  def one_row(_), do: nil

  # A row created already "deleted" (an import, an API caller) is in the
  # trash on its own: stamped as such, a catalogue restore does not take it
  # for a row trashed before provenance and revive it.
  @doc false
  def stamp_created_deleted(%Ecto.Changeset{} = changeset) do
    if Ecto.Changeset.get_field(changeset, :status) == "deleted" do
      data = Ecto.Changeset.get_field(changeset, :data) || %{}
      stamp = %{"via" => "self", "from_status" => "active"}
      Ecto.Changeset.put_change(changeset, :data, Map.put(data, "_trash", stamp))
    else
      changeset
    end
  end

  # Moves into or out of "deleted" belong to the trash and restore paths,
  # which stamp, cascade and lock. A plain update never makes one: a form
  # saving a trashed row cannot show "deleted" in its status select, so it
  # posts the first option; and a form opened before a trash would revive
  # the row on save, with none of the restore rules. Decided from the row
  # as it is now, not from the caller's snapshot.
  @doc false
  def keep_trash_status(%Ecto.Changeset{} = changeset, schema, uuid) do
    case Ecto.Changeset.get_change(changeset, :status) do
      nil ->
        changeset

      "deleted" ->
        Ecto.Changeset.delete_change(changeset, :status)

      _live ->
        if current_status(schema, uuid) == "deleted",
          do: Ecto.Changeset.delete_change(changeset, :status),
          else: changeset
    end
  end

  @doc false
  def current_status(schema, uuid) do
    repo().one(from(r in schema, where: r.uuid == ^uuid, lock: "FOR UPDATE", select: r.status))
  end

  @doc false
  def catalogue_deleted?(nil), do: false

  def catalogue_deleted?(catalogue_uuid) do
    repo().one(from(c in Catalogue, where: c.uuid == ^catalogue_uuid, select: c.status)) ==
      "deleted"
  end

  @doc false
  def reorder_max_uuids, do: @reorder_max_uuids
end
