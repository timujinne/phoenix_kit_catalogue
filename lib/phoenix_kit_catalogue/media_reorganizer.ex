defmodule PhoenixKitCatalogue.MediaReorganizer do
  @moduledoc """
  Catalogue's media-reorganizer plan source.

  Implements core's `PhoenixKit.Modules.Storage.Reorganizer.Source` contract
  (`plan(actor_uuid, opts) :: [map()]`, first shipped in phoenix_kit 2.24.0)
  without declaring `@behaviour`: the `phoenix_kit` pin floor predates that
  release, and on an older core the attribute would only warn about an
  undefined behaviour. Plain maps keep the module compiling either way; see
  `PhoenixKitCatalogue.media_reorganizer/0` for the registration comment.

  Contract (the authoritative list is core's `Reorganizer.Source` moduledoc):

    * **No configured `:attachments_parent_folder` hook → `:report`-only.**
      Orphan and pending-folder reports are still produced (informational,
      no writes); no `:move`, no `:trash`, no pointer back-fill happen.
    * **Claims are hook-independent.** Every live record's valid, live
      pointer folder is "claimed" regardless of whether a hook is
      configured — a pending folder any live record points at is never
      trashed, hook or no hook.
    * **A hook that raises, exits, or returns anything but `{:ok, uuid}`,
      `{:ok, nil}`, or a bare `nil`** is a hook FAILURE: the record is
      skipped (no move planned for it) and counted into one
      `kind: :hook_error` report for the whole plan. Only an explicit
      `nil`/`{:ok, nil}` means "root". A configured `attachments_parent_folder`
      / `attachments_folder_name` whose `{mod, fun}` is not actually
      callable (a typo, a removed function) is the same failure, reported
      the same way — never silently treated as "no hook configured".
    * **An explicit "root" answer never pulls a folder out from under a
      real parent.** For a candidate whose current folder already lives
      under a parent, a `nil`/`{:ok, nil}` parent-hook answer plans only
      the pointer back-fill (if any) — never a `:move` to root — plus one
      `kind: :hook_nil` report for the whole plan.
    * **Current-folder lookup mirrors `Attachments.find_resource_folder/2`:**
      host-named folder under the resolved parent, then the legacy
      deterministic name under the resolved parent, then the legacy name
      at root. A host-named folder found live IS the current folder
      (already-correct case — the plan then only needs a pointer
      back-fill). Host-named and legacy-named both live at once, two
      legacy matches (parent + root), or two records both actually
      resolving to the very same live folder are all unresolvable — each
      is a `kind: :duplicate` report, never a `:move`.
    * **A folder found through a record's live pointer keeps its own name**
      (never renamed) unless that name is still the legacy deterministic
      one — a record whose pointer folder still literally reads
      `catalogue-item-<uuid>` etc. gets the host name like any other
      candidate.
    * **Every live legacy-named copy other than a record's adopted current
      folder** gets its own `kind: :relocated` report (all of them, not
      only the first) — never adopted or moved, and never reported twice
      if the copy is itself another record's claimed current folder.
    * **Two records whose resolved *targets* would coincide** (same
      `{parent, desired name}`) are reported `kind: :duplicate` instead of
      both being planned as moves (the second would collide at apply
      time).
    * Only records that already have SOME live folder (a live pointer, or
      a folder anywhere matching the legacy name) are *candidates* — a
      record with neither never triggers a (possibly writing) host hook.

  Also covers stale `catalogue-attachment-pending-*` upload folders,
  orphaned legacy folders whose record is gone or deleted, and the shared
  PDF library folder — see the section comments below.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.Modules.Storage.{Folder, FolderLink}
  alias PhoenixKitCatalogue.Attachments
  alias PhoenixKitCatalogue.Schemas.{Catalogue, Category, Item, Pdf}

  @pending_prefix "catalogue-attachment-pending-"
  @default_pending_days 7
  @legacy_prefix "catalogue-"

  @legacy_kinds [
    {"catalogue-item-", :item},
    {"catalogue-category-", :category},
    {"catalogue-", :catalogue}
  ]

  @uuid_regex ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  @doc """
  Builds the catalogue's reorganizer plan. See the moduledoc for the full
  contract.

  `opts[:pending_days]` (default #{@default_pending_days}) — how old an
  empty pending folder must be before it is planned as `:trash` (or,
  without a configured hook, merely reported) instead of left alone.
  """
  @spec plan(String.t() | nil, keyword()) :: [map()]
  def plan(actor_uuid, opts \\ []) do
    pending_days = Keyword.get(opts, :pending_days, @default_pending_days)

    tagged_records =
      tag(light_catalogues(), :catalogue) ++
        tag(light_categories(), :category) ++
        tag(light_items(), :item)

    # R1: independent of whether a hook is configured — a folder any live
    # record's pointer names is never a pending-trash/orphan candidate.
    pointer_claims = live_pointer_claims(tagged_records)

    {resource_actions, resolved_claims, resolved_parents, hook_on?} =
      case hook_status() do
        :ok ->
          {actions, claims, parents} =
            build_resource_plan(tagged_records, actor_uuid, pointer_claims)

          {actions, claims, parents, true}

        {:invalid, reason} ->
          {[invalid_hook_action(reason)], claimed_folder_uuids([], [], [], []), [], false}

        :none ->
          {[], claimed_folder_uuids([], [], [], []), [], false}
      end

    claimed_uuids = MapSet.union(pointer_claims, resolved_claims)

    resource_actions ++
      orphan_actions(resolved_parents, claimed_uuids) ++
      pending_folder_actions(pending_days, claimed_uuids, hook_on?) ++
      pdf_report_actions(actor_uuid)
  end

  # ── Catalogues / categories / items ─────────────────────────────

  # T3: a configured `{mod, fun}` that is not actually callable (a typo,
  # a removed function) is a distinct failure from "no hook configured at
  # all" — it must not silently degrade to report-only (E1) without
  # telling the owner why nothing moved. U7/V3: anything configured that
  # is not even a `{mod, fun}` shape (garbage config) is the SAME
  # failure — never silently treated as "no hook configured" either.
  defp hook_status do
    case Application.get_env(:phoenix_kit_catalogue, :attachments_parent_folder) do
      nil ->
        :none

      {mod, fun} when is_atom(mod) and is_atom(fun) ->
        if callable?(mod, fun), do: :ok, else: {:invalid, {:not_callable, mod, fun}}

      other ->
        {:invalid, {:bad_config, other}}
    end
  end

  defp callable?(mod, fun) do
    Code.ensure_loaded?(mod) and
      (function_exported?(mod, fun, 3) or function_exported?(mod, fun, 2))
  end

  defp invalid_hook_action(reason) do
    %{
      source: "catalogue",
      kind: :hook_error,
      op: :report,
      label: "attachments parent hook",
      counts: nil,
      reason: invalid_hook_reason(reason)
    }
  end

  defp invalid_hook_reason({:not_callable, mod, fun}),
    do: "configured parent hook {#{inspect(mod)}, #{inspect(fun)}} is not callable"

  defp invalid_hook_reason({:bad_config, other}),
    do:
      "configured parent hook #{inspect(other)} is not a {module, function} tuple — " <>
        "invalid config, not callable"

  defp tag(records, kind),
    do: Enum.map(records, fn {record, pointer} -> {record, pointer, kind} end)

  # E1/D1: candidate detection needs no hook call, so build_resource_plan
  # is only reached at all when a parent hook is configured (see plan/2).
  # Even then, a record with no existing live folder (pointer or legacy
  # name) never triggers the host's (possibly writing) hooks.
  defp build_resource_plan(tagged_records, actor_uuid, pointer_claims) do
    {mod, fun} = Application.get_env(:phoenix_kit_catalogue, :attachments_parent_folder)

    prelim =
      Enum.map(tagged_records, fn {record, pointer, kind} ->
        %{
          record: record,
          kind: kind,
          pointer: valid_uuid(pointer),
          legacy_name: Attachments.legacy_folder_name(record)
        }
      end)

    by_pointer = preload_by_uuid(Enum.map(prelim, & &1.pointer))
    by_name = preload_by_name_anywhere(Enum.map(prelim, & &1.legacy_name))

    # R10/T6: candidates keep the light query's deterministic order
    # (catalogue → category → item, each by inserted_at/uuid) via
    # `order_index` — splitting into pointer/name tracks below and
    # re-merging them must not scramble it.
    candidates =
      prelim
      |> Enum.filter(fn p ->
        (p.pointer && Map.has_key?(by_pointer, p.pointer)) ||
          Map.has_key?(by_name, p.legacy_name)
      end)
      |> load_full_candidate_records()
      |> Enum.with_index()
      |> Enum.map(fn {c, idx} -> Map.put(c, :order_index, idx) end)

    {resolved_all, hook_error_labels} =
      resolve_candidates(candidates, by_pointer, by_name, mod, fun, actor_uuid)

    resolved_all = Enum.sort_by(resolved_all, & &1.order_index)

    # U4/V2: orphan scope is every parent a SUCCESSFUL hook call returned
    # for ANY candidate, regardless of that candidate's outcome (adopted,
    # ambiguous, hook_nil, stray, converging, shared) — never a parent
    # inferred from where a folder happens to already sit. Must be taken
    # from the RAW hook answer, before `apply_nil_root_guard/1` below
    # overwrites `parent_uuid` for the `:hook_nil` cases.
    resolved_parents =
      resolved_all |> Enum.map(& &1.parent_uuid) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    resolved_all = Enum.map(resolved_all, &apply_nil_root_guard/1)

    hook_nil_entries = Enum.filter(resolved_all, & &1.hook_nil)
    hook_nil_labels = Enum.map(hook_nil_entries, & &1.record.name)

    {ambiguous, normal} = Enum.split_with(resolved_all, & &1.ambiguous)
    {with_folder, without_folder} = Enum.split_with(normal, & &1.folder)

    {shared, unique} = split_shared(with_folder)

    # U2/F6: convergence is only ever computed among entries that would
    # ACTUALLY move — an entry already sitting at its target (a no-op) can
    # never collide with a real mover, so it must never drag that mover
    # into a `:duplicate` report and block the move.
    movers = Enum.filter(unique, &mover?/1)
    {converging, _solo_movers} = split_converging(movers)

    converging_indexes =
      converging |> List.flatten() |> Enum.map(& &1.order_index) |> MapSet.new()

    move_pool = Enum.reject(unique, &MapSet.member?(converging_indexes, &1.order_index))

    move_actions = move_pool |> Enum.map(&build_move_action/1) |> Enum.reject(&is_nil/1)
    dup_actions = Enum.map(ambiguous, &build_ambiguous_duplicate_action(&1, pointer_claims))
    shared_actions = Enum.map(shared, &build_shared_duplicate_action/1)
    converging_actions = Enum.map(converging, &build_converging_duplicate_action/1)
    hook_error_actions = hook_error_action(hook_error_labels)
    hook_nil_actions = hook_nil_action(hook_nil_labels)

    claimed = claimed_folder_uuids(unique, ambiguous, shared, converging)
    all_claimed = MapSet.union(claimed, pointer_claims)

    # F5/T5: every live legacy-named copy other than the record's adopted
    # current folder (if any) gets its own `:relocated` report — except a
    # copy that is itself another record's claimed (adopted) folder, which
    # is never also reported as relocated. U9: includes `ambiguous` too —
    # a THIRD live copy beyond the two the duplicate report already names
    # must still surface here, not be dropped.
    stray_actions =
      stray_relocated_actions(with_folder ++ without_folder ++ ambiguous, all_claimed)

    all_actions =
      move_actions ++
        dup_actions ++
        shared_actions ++
        converging_actions ++ stray_actions ++ hook_error_actions ++ hook_nil_actions

    {finalize_counts(all_actions), claimed, resolved_parents}
  end

  # F1: an explicit `nil`/`{:ok, nil}` answer from the parent hook never
  # pulls a folder that currently lives under a real parent out to root —
  # only a pointer back-fill (if any) is kept; the parent and name stay
  # exactly as they are (no rename either). Named/pointer resolution above
  # already guarantees `entry.folder` is the record's actual current
  # folder when set, so this is safe regardless of resolution route.
  defp apply_nil_root_guard(%{folder: %Folder{parent_uuid: parent_uuid}} = entry)
       when not is_nil(parent_uuid) and is_nil(entry.parent_uuid) do
    entry
    |> Map.put(:parent_uuid, parent_uuid)
    |> Map.put(:name, nil)
    |> Map.put(:hook_nil, true)
  end

  defp apply_nil_root_guard(entry), do: Map.put(entry, :hook_nil, false)

  # F5/T5: a live legacy-named copy of a record other than its adopted
  # current folder — one `:relocated` report per copy, all of them, never
  # just the first. A copy that is itself claimed by another record
  # (its own resolved current folder) is excluded — a claimed folder is
  # never also reported `:relocated`.
  # F5/T5 + R3-4: batched over the whole plan so naming a stray copy's
  # actual (third-party) parent for the report never costs a query per
  # copy.
  defp stray_relocated_actions(entries, claimed) do
    pairs =
      Enum.flat_map(entries, fn entry ->
        entry.stray_legacy
        |> Enum.reject(&MapSet.member?(claimed, &1.uuid))
        |> Enum.map(&{entry, &1})
      end)

    parent_names = load_stray_parent_names(pairs)

    Enum.map(pairs, fn {entry, folder} ->
      build_relocated_action(%{
        record: entry.record,
        kind: entry.kind,
        relocated: folder,
        target_parent_uuid: entry.parent_uuid,
        parent_names: parent_names
      })
    end)
  end

  # Only parents that are neither root nor the record's own target need a
  # name — those two cases already have their own wording.
  defp load_stray_parent_names(pairs) do
    uuids =
      pairs
      |> Enum.map(fn {entry, folder} -> other_parent_uuid(folder, entry.parent_uuid) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case uuids do
      [] ->
        %{}

      uuids ->
        Folder
        |> where([f], f.uuid in ^uuids)
        |> select([f], {f.uuid, f.name})
        |> repo().all()
        |> Map.new()
    end
  end

  defp other_parent_uuid(%Folder{parent_uuid: nil}, _target_parent_uuid), do: nil
  defp other_parent_uuid(%Folder{parent_uuid: parent_uuid}, parent_uuid), do: nil
  defp other_parent_uuid(%Folder{parent_uuid: parent_uuid}, _target_parent_uuid), do: parent_uuid

  # R2: resolves the desired parent for every candidate via the host's
  # exact hook, distinguishing an explicit `nil` (root) from a hook that
  # raised/exited/returned anything else (failure — the record is
  # skipped, never treated as "root"). Only candidates with a live
  # pointer folder are separated from the rest (`pointer_track`) — those
  # never need the batched host-name-under-parent lookup (R3/R8) that the
  # remaining candidates (`name_track`) do.
  defp resolve_candidates(candidates, by_pointer, by_name, mod, fun, actor_uuid) do
    {pointer_track, name_track, hook_error_labels} =
      Enum.reduce(candidates, {[], [], []}, fn p, acc ->
        sort_candidate(p, by_pointer, mod, fun, actor_uuid, acc)
      end)

    pointer_results =
      pointer_track |> Enum.reverse() |> Enum.map(&resolve_pointer_entry(&1, by_name, actor_uuid))

    {pointer_entries, pointer_error_labels} = split_hook_errors(pointer_results)

    {name_entries, name_error_labels} =
      resolve_name_entries(Enum.reverse(name_track), by_name, actor_uuid)

    all_labels = Enum.reverse(hook_error_labels) ++ pointer_error_labels ++ name_error_labels
    {pointer_entries ++ name_entries, all_labels}
  end

  # U8: keeps the label of every failed record (not just a count) so the
  # `:hook_error` report can list them.
  defp split_hook_errors(results) do
    Enum.reduce(results, {[], []}, fn
      {:ok, entry}, {oks, errs} -> {[entry | oks], errs}
      {:error, label}, {oks, errs} -> {oks, [label | errs]}
    end)
    |> then(fn {oks, errs} -> {Enum.reverse(oks), Enum.reverse(errs)} end)
  end

  defp sort_candidate(p, by_pointer, mod, fun, actor_uuid, {ptrs, names, errs}) do
    case resolve_parent(mod, fun, p.kind, actor_uuid, p.record) do
      {:ok, parent_uuid} ->
        base = Map.put(p, :parent_uuid, parent_uuid)
        pointer_folder = p.pointer && Map.get(by_pointer, p.pointer)
        push_candidate(base, pointer_folder, ptrs, names, errs)

      :error ->
        {ptrs, names, [{p.record.name, :parent} | errs]}
    end
  end

  defp push_candidate(base, nil, ptrs, names, errs), do: {ptrs, [base | names], errs}

  defp push_candidate(base, pointer_folder, ptrs, names, errs),
    do: {[Map.put(base, :pointer_folder, pointer_folder) | ptrs], names, errs}

  defp resolve_parent(mod, fun, kind, actor_uuid, resource) do
    cond do
      Code.ensure_loaded?(mod) and function_exported?(mod, fun, 3) ->
        guarded_hook_call(mod, fun, kind, fn -> apply(mod, fun, [kind, actor_uuid, resource]) end)

      Code.ensure_loaded?(mod) and function_exported?(mod, fun, 2) ->
        guarded_hook_call(mod, fun, kind, fn -> apply(mod, fun, [kind, actor_uuid]) end)

      true ->
        :error
    end
  end

  # T1: every answer is cast through `Ecto.UUID.cast/1` and downcased —
  # `{:ok, ""}` / `{:ok, "not-a-uuid"}` are hook FAILURES (`:error`), never
  # sent into a later `in ^uuids` query (which would raise a CastError and
  # take down the whole plan). F2: an explicit `{:ok, nil}` or bare `nil`
  # means root. U6: every log line names the hook as `{mod, fun}` AND the
  # resource `kind`, and a bad (non-exception) return value is logged too,
  # not only a raise/exit.
  defp guarded_hook_call(mod, fun_name, kind, fun, hook_type \\ :parent) do
    case fun.() do
      {:ok, uuid} when is_binary(uuid) ->
        case valid_uuid(uuid) do
          nil ->
            log_and_error(
              hook_type,
              mod,
              fun_name,
              kind,
              "returned {:ok, #{inspect(uuid)}} (not a uuid)"
            )

          cast ->
            {:ok, cast}
        end

      {:ok, nil} ->
        {:ok, nil}

      nil ->
        {:ok, nil}

      other ->
        log_and_error(hook_type, mod, fun_name, kind, "returned #{inspect(other)}")
    end
  rescue
    error ->
      log_and_error(
        hook_type,
        mod,
        fun_name,
        kind,
        "raised: " <> Exception.format(:error, error, __STACKTRACE__)
      )
  catch
    exit_kind, reason ->
      log_and_error(hook_type, mod, fun_name, kind, "#{exit_kind}: #{inspect(reason)}")
  end

  # U6: one log format shared by every hook (parent/name/pdf) — always
  # `{mod, fun}` (not just `mod.fun`) plus the resource `kind` it was
  # called for.
  defp log_hook_event(level, hook_type, mod, fun, kind, message) do
    Logger.log(
      level,
      "Attachments #{hook_type} hook {#{inspect(mod)}, #{inspect(fun)}} (kind: #{inspect(kind)}) #{message}"
    )
  end

  defp log_and_error(hook_type, mod, fun, kind, message) do
    log_hook_event(:warning, hook_type, mod, fun, kind, message)
    :error
  end

  # D6/E2: a folder found through the record's live pointer keeps its own
  # name — UNLESS that name is still the legacy deterministic one, in
  # which case it gets the host name like any other candidate (R8: the
  # name hook is skipped entirely otherwise). F3: a name hook that raises
  # or returns garbage is a hook FAILURE for this record too.
  defp resolve_pointer_entry(%{pointer_folder: folder} = d, by_name, actor_uuid) do
    name_result =
      if folder.name == d.legacy_name do
        resolve_folder_name(d.record, d.kind, actor_uuid)
      else
        {:ok, nil}
      end

    case name_result do
      :error ->
        {:error, {d.record.name, :name}}

      {:ok, name} ->
        {:ok,
         %{
           record: d.record,
           kind: d.kind,
           pointer: d.pointer,
           legacy_name: d.legacy_name,
           parent_uuid: d.parent_uuid,
           order_index: d.order_index,
           name: name,
           folder: folder,
           via: :pointer,
           ambiguous: nil,
           stray_legacy: stray_legacy_matches(d.legacy_name, by_name, folder.uuid)
         }}
    end
  end

  # F5: every live match for the legacy name other than the record's own
  # current folder — a list, not just the first one.
  defp stray_legacy_matches(legacy_name, by_name, current_folder_uuid) do
    by_name
    |> Map.get(legacy_name, [])
    |> Enum.reject(&(&1.uuid == current_folder_uuid))
  end

  # R3: the module's own lookup order for a record with no live pointer —
  # host-named folder under the resolved parent, then the legacy name
  # under the resolved parent, then the legacy name at root. Host-named
  # and legacy-named both live at once (or two legacy matches) are
  # unresolvable duplicates. A legacy match that is live under neither
  # the resolved parent nor root is left alone and reported `:relocated`.
  # F3: a candidate whose name hook fails is skipped entirely (counted as
  # a hook error) before the batched host-name lookup even runs for it.
  defp resolve_name_entries(candidates, by_name, actor_uuid) do
    {ok_candidates, error_labels} =
      Enum.reduce(candidates, {[], []}, fn c, {acc, errs} ->
        case resolve_folder_name(c.record, c.kind, actor_uuid) do
          {:ok, name} -> {[Map.put(c, :host_name, name) | acc], errs}
          :error -> {acc, [{c.record.name, :name} | errs]}
        end
      end)

    with_host_name = Enum.reverse(ok_candidates)
    host_map = preload_host_named_under_parent(with_host_name)

    entries = Enum.map(with_host_name, &resolve_name_entry(&1, by_name, host_map))

    {entries, Enum.reverse(error_labels)}
  end

  # F3: the (optional) `:attachments_folder_name` hook, called directly
  # (not through `Attachments.folder_name/2`, which is deliberately
  # defensive for the live UI) so a raising/garbage-returning hook is a
  # reportable failure here instead of a silent legacy-name fallback. Not
  # configured (unset) is NOT a failure — it is simply "no host name",
  # same as `Attachments.folder_name/2` treats it. U7/V3: configured but
  # not a `{mod, fun}` shape, or a `{mod, fun}` that is not actually
  # callable, are BOTH the same failure — parity with the parent hook.
  defp resolve_folder_name(record, kind, actor_uuid) do
    case Application.get_env(:phoenix_kit_catalogue, :attachments_folder_name) do
      nil ->
        {:ok, Attachments.legacy_folder_name(record)}

      {mod, fun} when is_atom(mod) and is_atom(fun) ->
        resolve_configured_folder_name(mod, fun, kind, record, actor_uuid)

      other ->
        log_and_error(:name, other, nil, kind, "is not a {module, function} tuple")
    end
  end

  # T3 parity: a configured `{mod, fun}` name hook that is not actually
  # callable (a typo, a removed function) is the same misconfiguration the
  # parent hook reports as `:hook_error` — it must not silently behave
  # like "no name hook configured at all".
  defp resolve_configured_folder_name(mod, fun, kind, record, actor_uuid) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, 2) do
      case guarded_name_hook_call(mod, fun, kind, record, actor_uuid) do
        {:ok, nil} -> {:ok, Attachments.legacy_folder_name(record)}
        {:ok, name} -> {:ok, name}
        :error -> :error
      end
    else
      log_and_error(:name, mod, fun, kind, "is not callable")
    end
  end

  defp guarded_name_hook_call(mod, fun, kind, record, actor_uuid) do
    case apply(mod, fun, [record, actor_uuid]) do
      {:ok, name} when is_binary(name) and name != "" -> {:ok, name}
      nil -> {:ok, nil}
      other -> log_and_error(:name, mod, fun, kind, "returned #{inspect(other)}")
    end
  rescue
    error ->
      log_and_error(
        :name,
        mod,
        fun,
        kind,
        "raised: " <> Exception.format(:error, error, __STACKTRACE__)
      )
  catch
    exit_kind, reason ->
      log_and_error(:name, mod, fun, kind, "#{exit_kind}: #{inspect(reason)}")
  end

  defp preload_host_named_under_parent(entries) do
    pairs =
      entries
      |> Enum.filter(& &1.parent_uuid)
      |> Enum.map(&{&1.parent_uuid, &1.host_name})
      |> Enum.uniq()

    case pairs do
      [] ->
        %{}

      pairs ->
        parents = pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
        names = pairs |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

        Folder
        |> where([f], is_nil(f.trashed_at) and f.parent_uuid in ^parents and f.name in ^names)
        |> repo().all()
        |> Enum.filter(&({&1.parent_uuid, &1.name} in pairs))
        |> Map.new(&{{&1.parent_uuid, &1.name}, &1})
    end
  end

  defp resolve_name_entry(d, by_name, host_map) do
    host_folder = d.parent_uuid && Map.get(host_map, {d.parent_uuid, d.host_name})
    matches = Map.get(by_name, d.legacy_name, [])
    under_parent = d.parent_uuid && Enum.find(matches, &(&1.parent_uuid == d.parent_uuid))
    at_root = Enum.find(matches, &is_nil(&1.parent_uuid))
    # U1/F1 (name-track parity): the hook answered root (`d.parent_uuid` is
    # nil) but the record's only live legacy-named copy sits under some
    # REAL parent — the module's own lookup (host-named/legacy under the
    # resolved parent, then legacy at root) can never reach it, so without
    # this it reads as "nothing resolves" and the copy is reported
    # `:relocated` forever instead of adopted. A single such copy is
    # treated exactly like F1's pointer-track case: it IS the current
    # folder, `apply_nil_root_guard/1` below plans only the pointer
    # back-fill and counts it into `:hook_nil`. Two or more such copies
    # stay unresolved (existing "nothing resolves" behaviour) — safe, not
    # this scenario.
    elsewhere =
      if is_nil(d.parent_uuid), do: Enum.filter(matches, &(not is_nil(&1.parent_uuid))), else: []

    legacy_folder =
      cond do
        under_parent -> under_parent
        at_root -> at_root
        match?([_], elsewhere) -> hd(elsewhere)
        true -> nil
      end

    base = %{
      record: d.record,
      kind: d.kind,
      pointer: d.pointer,
      legacy_name: d.legacy_name,
      parent_uuid: d.parent_uuid,
      order_index: d.order_index,
      folder: nil,
      via: nil,
      name: nil,
      ambiguous: nil,
      stray_legacy: []
    }

    # F5: every match live under neither the resolved parent nor root —
    # all of them, not only the first — left over once the chosen
    # `legacy_folder` (if any) is accounted for. Only meaningful for the
    # "host wins" / "legacy wins" / "nothing resolves" branches below; the
    # ambiguous branches already consume every match into their own
    # report.
    stray_legacy = Enum.reject(matches, &(&1 == legacy_folder))

    resolve_name_entry_result(
      base,
      d.host_name,
      host_folder,
      legacy_folder,
      under_parent,
      at_root,
      matches,
      stray_legacy
    )
  end

  # U9/F5: the ambiguous pair claims two folders, but any FURTHER live
  # legacy-named copy is not part of the ambiguity at all — it must still
  # get its own `:relocated` report (via `stray_relocated_actions/2`
  # downstream), never silently dropped just because this record already
  # has a duplicate report.
  defp resolve_name_entry_result(
         base,
         _host_name,
         host_folder,
         legacy_folder,
         _under,
         _root,
         matches,
         _stray
       )
       when not is_nil(host_folder) and not is_nil(legacy_folder) and
              host_folder.uuid != legacy_folder.uuid do
    stray = Enum.reject(matches, &(&1.uuid in [host_folder.uuid, legacy_folder.uuid]))
    %{base | ambiguous: {host_folder, legacy_folder}, stray_legacy: stray}
  end

  defp resolve_name_entry_result(
         base,
         _host_name,
         _host_folder,
         _legacy_folder,
         under_parent,
         at_root,
         matches,
         _stray
       )
       when not is_nil(under_parent) and not is_nil(at_root) do
    stray = Enum.reject(matches, &(&1.uuid in [under_parent.uuid, at_root.uuid]))
    %{base | ambiguous: {under_parent, at_root}, stray_legacy: stray}
  end

  # R3/E6-class fix: a host-named folder wins as the current folder, but
  # SEPARATE legacy-named matches live under some third parent (neither
  # root nor the resolved parent) — those leftovers get their own
  # `:relocated` reports so they are never silently dropped.
  defp resolve_name_entry_result(
         base,
         host_name,
         host_folder,
         _legacy_folder,
         _under,
         _root,
         _matches,
         stray_legacy
       )
       when not is_nil(host_folder) do
    %{base | folder: host_folder, via: :name, name: host_name, stray_legacy: stray_legacy}
  end

  defp resolve_name_entry_result(
         base,
         host_name,
         _host_folder,
         legacy_folder,
         _under,
         _root,
         _matches,
         stray_legacy
       )
       when not is_nil(legacy_folder) do
    %{base | folder: legacy_folder, via: :name, name: host_name, stray_legacy: stray_legacy}
  end

  # Nothing resolves as the current folder at all — every live match is a
  # stray copy, reported `:relocated` (F5: every one of them).
  defp resolve_name_entry_result(
         base,
         _host_name,
         _host_folder,
         _legacy_folder,
         _under,
         _root,
         matches,
         _stray
       ),
       do: %{base | stray_legacy: matches}

  # Splits entries whose current folder is claimed by exactly one record
  # (`unique`) from those two or more records resolve to the very same
  # live folder (`shared`, X5) — order-preserving (a plain `group_by`
  # would scramble R10's enumeration order).
  defp split_shared(entries) do
    freq = Enum.frequencies_by(entries, & &1.folder.uuid)
    {shared_entries, unique} = Enum.split_with(entries, &(Map.get(freq, &1.folder.uuid) > 1))
    shared_groups = shared_entries |> Enum.group_by(& &1.folder.uuid) |> Map.values()
    {shared_groups, unique}
  end

  # R7/E3: two records whose *desired* target (parent + name, or parent +
  # the folder's own kept name when `name` is nil) coincide — the second
  # move would collide with the first at apply time.
  defp split_converging(entries) do
    freq = Enum.frequencies_by(entries, &convergence_key/1)

    {converging_entries, solo} =
      Enum.split_with(entries, &(Map.get(freq, convergence_key(&1)) > 1))

    converging_groups = converging_entries |> Enum.group_by(&convergence_key/1) |> Map.values()
    {converging_groups, solo}
  end

  defp convergence_key(entry), do: {entry.parent_uuid, entry.name || entry.folder.name}

  defp claimed_folder_uuids(unique, ambiguous, shared_groups, converging_groups) do
    unique_uuids = Enum.map(unique, & &1.folder.uuid)

    ambiguous_uuids =
      Enum.flat_map(ambiguous, fn %{ambiguous: {f1, f2}} -> [f1.uuid, f2.uuid] end)

    shared_uuids = Enum.flat_map(shared_groups, fn [%{folder: f} | _] -> [f.uuid] end)

    converging_uuids =
      Enum.flat_map(converging_groups, fn group -> Enum.map(group, & &1.folder.uuid) end)

    MapSet.new(unique_uuids ++ ambiguous_uuids ++ shared_uuids ++ converging_uuids)
  end

  # A `:move` whose folder already sits at `parent_uuid` under `name` (or
  # an accepted `"name (N)"` suffix variant) and needs no pointer back-fill
  # is a no-op — filtered out here before it ever reaches the core engine.
  defp build_move_action(entry) do
    move_action(entry, entry.name)
  end

  defp move_action(
         %{record: record, kind: kind, folder: folder, parent_uuid: parent_uuid} = entry,
         name
       ) do
    after_move = after_move_fun(record, entry.pointer, folder)

    if noop_move?(folder, parent_uuid, name) and is_nil(after_move) do
      nil
    else
      %{
        source: "catalogue",
        kind: kind,
        label: record.name,
        op: :move,
        folder: folder,
        parent_uuid: parent_uuid,
        name: name,
        counts: nil,
        on_conflict: :suffix,
        after_move: after_move
      }
    end
  end

  # `name: nil` (a pointer-found folder, D6) — this module never renames
  # it, so only the parent needs to match for the move to be a no-op.
  defp noop_move?(%Folder{parent_uuid: parent_uuid}, parent_uuid, nil), do: true

  defp noop_move?(%Folder{parent_uuid: parent_uuid, name: name}, parent_uuid, name), do: true

  defp noop_move?(%Folder{parent_uuid: parent_uuid, name: folder_name}, parent_uuid, name)
       when is_binary(name) do
    suffixed_variant?(folder_name, name)
  end

  defp noop_move?(_folder, _parent_uuid, _name), do: false

  # Same rule as core's `Action.matches_name?/2`: `N` is an integer >= 2
  # with no leading zero, which is all its `on_conflict: :suffix` ever
  # generates — a folder named "Item (1)" or "Item (02)" is not a variant.
  defp suffixed_variant?(folder_name, name) do
    Regex.match?(~r/\A#{Regex.escape(name)} \((?:[2-9]|[1-9]\d+)\)\z/, folder_name)
  end

  # U2/F6: an entry that would actually reposition its folder (parent or
  # name mismatch) — the noop/after_move-only case is excluded, since a
  # record staying exactly where it is can never collide at a destination.
  defp mover?(%{folder: folder, parent_uuid: parent_uuid, name: name}),
    do: not noop_move?(folder, parent_uuid, name)

  defp build_ambiguous_duplicate_action(%{record: record, ambiguous: {f1, f2}}, pointer_claims) do
    %{
      source: "catalogue",
      kind: :duplicate,
      label: record.name,
      op: :report,
      counts: nil,
      reason: ambiguous_reason(f1, f2, pointer_claims)
    }
  end

  # R3-5: when one of the two ambiguous folders is itself already claimed
  # by a DIFFERENT live record's pointer, say so — "found live in two
  # places" alone reads as if this record owns both.
  defp ambiguous_reason(f1, f2, pointer_claims) do
    case {MapSet.member?(pointer_claims, f1.uuid), MapSet.member?(pointer_claims, f2.uuid)} do
      {true, false} ->
        ambiguous_owned_reason(f1, f2)

      {false, true} ->
        ambiguous_owned_reason(f2, f1)

      _ ->
        "folder found live in two places (#{f1.uuid} and #{f2.uuid}) — pick one and remove the other"
    end
  end

  defp ambiguous_owned_reason(owned, other) do
    "found live in two places: #{owned.uuid} is already another record's folder, " <>
      "#{other.uuid} also matches — pick one and remove the other"
  end

  defp build_shared_duplicate_action([%{folder: folder} | _] = group) do
    labels = group |> Enum.map(& &1.record.name) |> Enum.uniq() |> Enum.join(", ")

    %{
      source: "catalogue",
      kind: :duplicate,
      label: folder.name,
      op: :report,
      counts: nil,
      reason: "folder #{folder.uuid} is claimed by more than one record: #{labels}"
    }
  end

  defp build_converging_duplicate_action([entry | _] = group) do
    labels = group |> Enum.map(& &1.record.name) |> Enum.uniq() |> Enum.join(", ")
    {parent_uuid, name} = convergence_key(entry)
    parent_label = parent_uuid || "root"

    %{
      source: "catalogue",
      kind: :duplicate,
      label: labels,
      op: :report,
      counts: nil,
      reason:
        "multiple records would move to the same destination (parent #{parent_label}, name #{name}): #{labels}"
    }
  end

  defp build_relocated_action(%{record: record, kind: kind, relocated: folder} = ctx) do
    reason =
      relocated_reason(
        folder,
        kind,
        Map.get(ctx, :target_parent_uuid),
        Map.get(ctx, :parent_names, %{})
      )

    %{
      source: "catalogue",
      kind: :relocated,
      op: :report,
      label: record.name,
      folder: folder,
      counts: nil,
      reason: reason
    }
  end

  # R3-4/F5: the reason names the copy's actual place — at the media root,
  # already under the very parent the record is headed to (where an
  # eventual move will land next to it as a `"name (N)"` suffixed twin),
  # or by name under a genuine third-party parent — instead of a blanket
  # "under a different parent" that reads wrong for all three cases.
  defp relocated_reason(%Folder{parent_uuid: nil} = folder, kind, _target_parent_uuid, _names) do
    "legacy folder #{folder.uuid} (#{kind}) is live at the media root — left alone, never adopted"
  end

  defp relocated_reason(%Folder{parent_uuid: parent_uuid} = folder, kind, parent_uuid, _names) do
    "legacy folder #{folder.uuid} (#{kind}) is already live as a twin under the target parent " <>
      "— left alone; an eventual move there will collide, landing as \"name (N)\""
  end

  defp relocated_reason(
         %Folder{parent_uuid: parent_uuid} = folder,
         kind,
         _target_parent_uuid,
         names
       ) do
    parent_label = Map.get(names, parent_uuid, parent_uuid)

    "legacy folder #{folder.uuid} (#{kind}) is live under #{parent_label} — left alone, never adopted"
  end

  # R5/X3: a pointer that is not a well-formed UUID is treated as absent,
  # never sent into an `in ^uuids` query (which would raise a CastError).
  # Returns the CAST/downcased value — not the raw string — so an
  # upper-case pointer still matches the (lower-case) keys `by_pointer`
  # and the live-claims set are keyed by.
  defp valid_uuid(uuid) when is_binary(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, cast} -> cast
      :error -> nil
    end
  end

  defp valid_uuid(_), do: nil

  # One query for every distinct (valid) pointer uuid in the batch — live
  # folders only (X2).
  defp preload_by_uuid(uuids) do
    case uuids |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      uuids ->
        Folder
        |> where([f], f.uuid in ^uuids and is_nil(f.trashed_at))
        |> repo().all()
        |> Map.new(&{&1.uuid, &1})
    end
  end

  # One query for every distinct legacy name in the batch, matching a live
  # folder ANYWHERE (any parent, including root) — not filtered to a
  # resolved parent, since the parent hook has not run yet for records
  # without another candidate. Grouped by name so more than one live match
  # (different parents) is visible downstream. Live only (X2 — the unique
  # index is partial, a trashed twin must not hide the live folder).
  defp preload_by_name_anywhere(names) do
    case names |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      names ->
        Folder
        |> where([f], f.name in ^names and is_nil(f.trashed_at))
        |> repo().all()
        |> Enum.group_by(& &1.name)
    end
  end

  # R9-amend (design §10): the `light_*/0` selects are for candidate
  # detection ONLY. Any record handed to a host hook (parent or name) —
  # or reused for the actions built from it — must be the FULL row, not
  # the partial struct (a partial struct is missing columns like a
  # category's `parent_uuid`, which a host's parent hook may rely on to
  # tell a nested resource from a top-level one). One batched
  # `where uuid in ^uuids` query per kind, for candidates only, ordered
  # deterministically. A candidate whose full row can no longer be found
  # (e.g. deleted between the light and full loads) is dropped — same
  # treatment as a record with no live folder: no hook call, no action.
  defp load_full_candidate_records(candidates) do
    full_by_key =
      candidates
      |> Enum.group_by(& &1.kind, & &1.record.uuid)
      |> Enum.flat_map(fn {kind, uuids} -> full_records(kind, Enum.uniq(uuids)) end)
      |> Map.new(fn {kind, record} -> {{kind, record.uuid}, record} end)

    candidates
    |> Enum.map(&{&1, Map.get(full_by_key, {&1.kind, &1.record.uuid})})
    |> Enum.filter(fn {_p, full} -> full end)
    |> Enum.map(fn {p, full} -> %{p | record: full} end)
  end

  defp full_records(:catalogue, uuids), do: kind_records(Catalogue, :catalogue, uuids)
  defp full_records(:category, uuids), do: kind_records(Category, :category, uuids)
  defp full_records(:item, uuids), do: kind_records(Item, :item, uuids)

  defp kind_records(schema, kind, uuids) do
    schema
    |> where([r], r.uuid in ^uuids)
    |> order_by([r], asc: r.inserted_at, asc: r.uuid)
    |> repo().all()
    |> Enum.map(&{kind, &1})
  end

  # R1: every valid, live pointer of every LIVE record — independent of
  # whether a parent hook is configured. Used only to keep a claimed
  # folder out of the pending-trash/orphan sweeps; never triggers a hook.
  defp live_pointer_claims(tagged_records) do
    pointers =
      tagged_records
      |> Enum.map(fn {_record, pointer, _kind} -> valid_uuid(pointer) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Folder
    |> where([f], f.uuid in ^pointers and is_nil(f.trashed_at))
    |> select([f], f.uuid)
    |> repo().all()
    |> MapSet.new()
  end

  # `nil` when the pointer already matches the current (pre-move) folder —
  # nothing to back-fill. Otherwise a fun the engine runs after the move,
  # inside the same transaction, to write/repair the pointer. D7: writes
  # the owned jsonb key directly (locked row, plain changeset) — no
  # context `update_*`, no Activity log, no PubSub, no full validation.
  defp after_move_fun(record, pointer, %Folder{uuid: folder_uuid}) do
    if pointer == folder_uuid do
      nil
    else
      fn -> write_pointer(record, folder_uuid) end
    end
  end

  defp write_pointer(%Item{} = item, folder_uuid),
    do: write_pointer_directly(Item, item, folder_uuid)

  defp write_pointer(%Category{} = category, folder_uuid),
    do: write_pointer_directly(Category, category, folder_uuid)

  defp write_pointer(%Catalogue{} = catalogue, folder_uuid),
    do: write_pointer_directly(Catalogue, catalogue, folder_uuid)

  # Re-checks the record under `FOR UPDATE` at apply time: gone or
  # soft-deleted since the plan was built aborts the back-fill instead of
  # pointing a live-looking record at a folder nobody will ever see again.
  defp write_pointer_directly(schema, record, folder_uuid) do
    case locked(schema, record.uuid) do
      nil ->
        {:error, :not_found}

      %{status: "deleted"} ->
        {:error, :record_deleted}

      current ->
        data = Map.put(current.data || %{}, "files_folder_uuid", folder_uuid)

        current
        |> Ecto.Changeset.change(data: data)
        |> repo().update()
        |> case do
          {:ok, _updated} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp locked(schema, uuid) do
    schema
    |> where([r], r.uuid == ^uuid)
    |> lock("FOR UPDATE")
    |> repo().one()
  end

  defp hook_error_action([]), do: []

  # N4-3: `labels` is `[{record_name, :parent | :name}, ...]` — the report
  # names the ACTUAL failing hook (parent, folder-name, or both) instead of
  # always blaming "the parent hook" for a folder-name hook failure.
  defp hook_error_action(labels) do
    sources = labels |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()
    record_labels = Enum.map(labels, &elem(&1, 0))

    [
      %{
        source: "catalogue",
        kind: :hook_error,
        op: :report,
        label: hook_error_label(sources),
        counts: nil,
        reason:
          "#{length(labels)} record(s) skipped: #{hook_error_prefix(sources)} raised, exited, " <>
            "or returned neither {:ok, uuid} nor nil (#{labels_summary(record_labels)})"
      }
    ]
  end

  defp hook_error_label([:parent]), do: "attachments parent hook"
  defp hook_error_label([:name]), do: "attachments folder-name hook"
  defp hook_error_label(_mixed), do: "attachments hooks"

  defp hook_error_prefix([:parent]), do: "the configured parent hook"
  defp hook_error_prefix([:name]), do: "the configured folder-name hook"
  defp hook_error_prefix(_mixed), do: "the configured parent/folder-name hooks"

  # F1: one report for the whole plan, not one per record — mirrors
  # hook_error_action. U8: names the affected records, not just a count.
  defp hook_nil_action([]), do: []

  defp hook_nil_action(labels) do
    [
      %{
        source: "catalogue",
        kind: :hook_nil,
        op: :report,
        label: "attachments parent hook",
        counts: nil,
        reason:
          "#{length(labels)} record(s): the parent hook answered root for a folder living under a " <>
            "parent — left in place (#{labels_summary(labels)})"
      }
    ]
  end

  # U8: `:hook_error`/`:hook_nil` reports list up to 10 record labels, then
  # a "… and N more" summary — an owner staring at a bare counter cannot
  # tell where to look.
  defp labels_summary(labels) do
    {shown, rest} = Enum.split(labels, 10)

    case rest do
      [] -> Enum.join(shown, ", ")
      more -> Enum.join(shown, ", ") <> ", … and #{length(more)} more"
    end
  end

  # ── Pending upload folders ──────────────────────────────────────

  # X4/R1: a folder any live record currently points at is never
  # independently reported/trashed as a pending folder — its move (or
  # duplicate report) action, if any, already covers it, and `claimed`
  # includes the hook-independent pointer claims regardless.
  defp pending_folder_actions(pending_days, claimed_uuids, hook_on?) do
    cutoff = DateTime.add(DateTime.utc_now(), -pending_days * 86_400, :second)

    folders =
      Folder
      |> where([f], is_nil(f.trashed_at))
      |> where([f], like(f.name, ^"#{@pending_prefix}%"))
      |> order_by([f], asc: f.inserted_at, asc: f.uuid)
      |> repo().all()
      |> Enum.reject(&MapSet.member?(claimed_uuids, &1.uuid))

    counts = counts_by_folder(Enum.map(folders, & &1.uuid))
    files_by_folder = pending_files_by_folder(Enum.map(folders, & &1.uuid))

    folders
    |> Enum.map(&pending_folder_action(&1, cutoff, counts, files_by_folder, hook_on?))
    |> Enum.reject(&is_nil/1)
  end

  defp pending_folder_action(folder, cutoff, counts, files_by_folder, hook_on?) do
    case folder_counts(counts, folder.uuid) do
      {0, 0} ->
        if DateTime.compare(folder.inserted_at, cutoff) == :lt do
          pending_stale_action(folder, hook_on?)
        end

      {files, links} ->
        %{
          source: "catalogue",
          kind: :pending,
          label: folder.name,
          op: :report,
          folder: folder,
          counts: {files, links},
          reason: "pending folder still has #{pending_reason(folder.uuid, files_by_folder)}"
        }
    end
  end

  # E1: without a configured hook, a stale empty pending folder is
  # reported, never trashed.
  defp pending_stale_action(folder, true) do
    %{
      source: "catalogue",
      kind: :pending,
      label: folder.name,
      op: :trash,
      folder: folder,
      counts: {0, 0},
      reason: "empty pending upload folder older than the retention window"
    }
  end

  defp pending_stale_action(folder, false) do
    %{
      source: "catalogue",
      kind: :pending,
      label: folder.name,
      op: :report,
      folder: folder,
      counts: {0, 0},
      reason:
        "empty pending upload folder older than the retention window " <>
          "(no attachments hook configured — not trashed)"
    }
  end

  # R6: one batched query (home files + linked files) for every non-empty
  # pending folder in the batch — never a query per folder. R6: the
  # reason is never empty — a folder whose only files are trashed says so
  # explicitly instead of rendering an empty file list.
  defp pending_files_by_folder(folder_uuids) do
    case folder_uuids do
      [] ->
        %{}

      uuids ->
        home_rows =
          PhoenixKit.Modules.Storage.File
          |> where([f], f.folder_uuid in ^uuids)
          |> select([f], {f.folder_uuid, f.original_file_name, f.status})
          |> repo().all()

        linked_rows =
          FolderLink
          |> join(:inner, [l], f in PhoenixKit.Modules.Storage.File, on: f.uuid == l.file_uuid)
          |> where([l, _f], l.folder_uuid in ^uuids)
          |> select([l, f], {l.folder_uuid, f.original_file_name, f.status})
          |> repo().all()

        Enum.group_by(home_rows ++ linked_rows, fn {folder_uuid, _name, _status} ->
          folder_uuid
        end)
    end
  end

  defp pending_reason(folder_uuid, files_by_folder) do
    rows = Map.get(files_by_folder, folder_uuid, [])

    live_names =
      rows
      |> Enum.reject(fn {_f, _n, status} -> status == "trashed" end)
      |> Enum.map(&elem(&1, 1))

    case live_names do
      [] -> "#{length(rows)} trashed file(s)"
      names -> "files: #{Enum.join(names, ", ")}"
    end
  end

  # ── Orphaned legacy folders ──────────────────────────────────────

  # A legacy-named folder (`catalogue-item-<uuid>`, `catalogue-category-<uuid>`,
  # `catalogue-<uuid>`) at the media root or under a parent this batch's hooks
  # resolved to, whose uuid no longer names a live record (missing, or the
  # record exists but was soft-deleted) is reported so a host can collect it.
  # Never `:move`d or `:trash`ed here — this module owns no "orphans"
  # container; a legacy folder claimed by a live record (its current
  # folder, a duplicate, or a converging-target group) is excluded (R4 —
  # one folder gets at most one action).
  defp orphan_actions(resolved_parents, claimed_uuids) do
    case legacy_candidate_folders(resolved_parents, claimed_uuids) do
      [] ->
        []

      candidates ->
        records_by_key = load_candidate_records(candidates)
        counts = counts_by_folder(Enum.map(candidates, fn {folder, _kind} -> folder.uuid end))

        candidates
        |> Enum.map(&orphan_action(&1, records_by_key, counts))
        |> Enum.reject(&is_nil/1)
    end
  end

  # One SQL-filtered query (X6 — prefix filter in SQL, not loaded then
  # filtered in Elixir) for every live folder at root or under a resolved
  # parent whose name starts with the catalogue legacy prefix.
  defp legacy_candidate_folders(parent_uuids, claimed_uuids) do
    Folder
    |> where([f], is_nil(f.trashed_at))
    |> where([f], is_nil(f.parent_uuid) or f.parent_uuid in ^parent_uuids)
    |> where([f], like(f.name, ^"#{@legacy_prefix}%"))
    |> order_by([f], asc: f.inserted_at, asc: f.uuid)
    |> repo().all()
    |> Enum.reject(&MapSet.member?(claimed_uuids, &1.uuid))
    |> Enum.map(&{&1, legacy_kind(&1.name)})
    |> Enum.filter(fn {_folder, kind} -> kind end)
  end

  defp legacy_kind(name) do
    if String.starts_with?(name, @pending_prefix) do
      nil
    else
      Enum.find_value(@legacy_kinds, &legacy_kind_match(name, &1))
    end
  end

  # X7: a strict UUID regex on the suffix (36-char canonical form) — not
  # `Ecto.UUID.cast/1`, which also accepts a raw 16-byte binary and would
  # key the map differently than the record's (lowercased) uuid.
  defp legacy_kind_match(name, {prefix, kind}) do
    if String.starts_with?(name, prefix) do
      suffix = String.replace_prefix(name, prefix, "")

      if Regex.match?(@uuid_regex, suffix) do
        {kind, String.downcase(suffix)}
      end
    end
  end

  # One query per record kind present among the candidates — not per
  # folder — and only the status column (R9): an orphan report needs
  # nothing else off the record.
  defp load_candidate_records(candidates) do
    by_kind =
      Enum.group_by(
        candidates,
        fn {_folder, {kind, _uuid}} -> kind end,
        fn {_folder, {_kind, uuid}} -> uuid end
      )

    %{}
    |> Map.merge(load_record_statuses(Item, :item, Map.get(by_kind, :item, [])))
    |> Map.merge(load_record_statuses(Category, :category, Map.get(by_kind, :category, [])))
    |> Map.merge(load_record_statuses(Catalogue, :catalogue, Map.get(by_kind, :catalogue, [])))
  end

  defp load_record_statuses(_schema, _kind, []), do: %{}

  defp load_record_statuses(schema, kind, uuids) do
    schema
    |> where([r], r.uuid in ^uuids)
    |> select([r], {r.uuid, r.status})
    |> repo().all()
    |> Map.new(fn {uuid, status} -> {{kind, uuid}, status} end)
  end

  defp orphan_action({folder, {kind, uuid}}, records_by_key, counts) do
    case Map.get(records_by_key, {kind, uuid}) do
      status when is_binary(status) and status != "deleted" ->
        nil

      status ->
        folder_counts = folder_counts(counts, folder.uuid)

        %{
          source: "catalogue",
          kind: :orphan,
          op: :report,
          label: folder.name,
          folder: folder,
          counts: folder_counts,
          reason: orphan_reason(status, folder_counts)
        }
    end
  end

  defp orphan_reason(nil, {files, _links}), do: "record missing, #{files} file(s)"
  defp orphan_reason(status, {files, _links}), do: "record status #{status}, #{files} file(s)"

  # ── PDF library ──────────────────────────────────────────────────

  # PDFs are files, not folders — out of scope for a `:move` action. Live
  # PDFs still sitting at the storage root while the host has configured a
  # library folder (`:pdf` hook) get a single `:report` so a human can run
  # the legacy-adoption pass `PdfLibrary` itself defers to (see its
  # `attach_to_pdf_library_folder/2` moduledoc comment). The `:pdf` hook is
  # only called when there is at least one root PDF to report (X12).
  defp pdf_report_actions(actor_uuid) do
    case root_pdf_count() do
      0 ->
        []

      count ->
        case guarded_pdf_hook_call(actor_uuid) do
          {:ok, folder_uuid} when is_binary(folder_uuid) ->
            [
              %{
                source: "catalogue",
                kind: :pdf,
                label: "PDF library",
                op: :report,
                counts: {count, 0},
                reason: "#{count} PDF(s) at the storage root; library folder #{folder_uuid}"
              }
            ]

          {:ok, nil} ->
            []

          :error ->
            [
              %{
                source: "catalogue",
                kind: :hook_error,
                op: :report,
                label: "attachments :pdf hook",
                counts: nil,
                reason:
                  "the configured :pdf attachments hook raised, exited, or is not callable — " <>
                    "#{count} PDF(s) at the storage root not reported"
              }
            ]
        end
    end
  end

  # V6: called directly against the configured `{mod, fun}` — not through
  # `Attachments.parent_folder_uuid/2`, which normalizes anything but a
  # binary `{:ok, uuid}` down to `nil` and would make a raising hook AND
  # an `{:error, _}`/garbage answer indistinguishable from "no library
  # configured". Routed through `guarded_hook_call/5` (hook_type `:pdf`)
  # so a raise/exit, a non-uuid `{:ok, _}`, or any other unexpected
  # answer all get the same single `:hook_error` report the parent hook
  # gets — never silence.
  defp guarded_pdf_hook_call(actor_uuid) do
    case Application.get_env(:phoenix_kit_catalogue, :attachments_parent_folder) do
      {mod, fun} when is_atom(mod) and is_atom(fun) -> dispatch_pdf_hook(mod, fun, actor_uuid)
      _ -> {:ok, nil}
    end
  end

  defp dispatch_pdf_hook(mod, fun, actor_uuid) do
    if callable?(mod, fun) do
      guarded_hook_call(mod, fun, :pdf, fn -> call_pdf_hook(mod, fun, actor_uuid) end, :pdf)
    else
      {:ok, nil}
    end
  end

  defp call_pdf_hook(mod, fun, actor_uuid) do
    cond do
      function_exported?(mod, fun, 3) -> apply(mod, fun, [:pdf, actor_uuid, :pdf])
      function_exported?(mod, fun, 2) -> apply(mod, fun, [:pdf, actor_uuid])
    end
  end

  defp root_pdf_count do
    Pdf
    |> join(:inner, [p], f in PhoenixKit.Modules.Storage.File, on: f.uuid == p.file_uuid)
    |> where([p, f], p.status == "active" and f.status != "trashed" and is_nil(f.folder_uuid))
    |> repo().aggregate(:count)
  end

  # ── Shared helpers ───────────────────────────────────────────────

  # X1: two grouped queries (files by folder_uuid, links by folder_uuid)
  # for the whole plan's folder set — never a query per action. Counts ALL
  # rows regardless of status (including trashed files) — the core engine
  # re-measures the same way at apply time (any row with this
  # `folder_uuid`) and aborts the action on a mismatch, so a plan-time
  # count that excluded trashed files would fail every folder holding one.
  defp counts_by_folder(folder_uuids) do
    case Enum.uniq(folder_uuids) do
      [] ->
        {%{}, %{}}

      uuids ->
        files =
          PhoenixKit.Modules.Storage.File
          |> where([f], f.folder_uuid in ^uuids)
          |> group_by([f], f.folder_uuid)
          |> select([f], {f.folder_uuid, count(f.uuid)})
          |> repo().all()
          |> Map.new()

        links =
          FolderLink
          |> where([l], l.folder_uuid in ^uuids)
          |> group_by([l], l.folder_uuid)
          |> select([l], {l.folder_uuid, count(l.uuid)})
          |> repo().all()
          |> Map.new()

        {files, links}
    end
  end

  defp folder_counts({files, links}, folder_uuid) do
    {Map.get(files, folder_uuid, 0), Map.get(links, folder_uuid, 0)}
  end

  # Fills `counts: nil` placeholders left by `build_move_action/1` with a
  # single batched lookup across every `:move` action's folder — the whole
  # plan's move-folder counts come from one pair of grouped queries (X1),
  # not one pair per action.
  defp finalize_counts(actions) do
    counts =
      actions
      |> Enum.map(fn
        %{folder: %Folder{uuid: uuid}} -> uuid
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> counts_by_folder()

    Enum.map(actions, fn
      %{folder: %Folder{uuid: uuid}} = action -> %{action | counts: folder_counts(counts, uuid)}
      action -> action
    end)
  end

  # R9/R10: only the columns a plan needs, ordered catalogue-then-category-
  # then-item, each by `inserted_at`/`uuid` — a deterministic, readable
  # report order. T8: the pointer is extracted via a jsonb fragment
  # instead of selecting the whole (potentially large) `data` column — a
  # light row returns `{struct, pointer_uuid_or_nil}`.
  defp light_catalogues do
    Catalogue
    |> where([c], c.status != "deleted")
    |> order_by([c], asc: c.inserted_at, asc: c.uuid)
    |> select([c], {
      struct(c, [:uuid, :name, :status, :inserted_at]),
      fragment("?->>'files_folder_uuid'", c.data)
    })
    |> repo().all()
  end

  defp light_categories do
    Category
    |> where([c], c.status != "deleted")
    |> order_by([c], asc: c.inserted_at, asc: c.uuid)
    |> select([c], {
      struct(c, [:uuid, :name, :status, :catalogue_uuid, :inserted_at]),
      fragment("?->>'files_folder_uuid'", c.data)
    })
    |> repo().all()
  end

  defp light_items do
    Item
    |> where([i], i.status != "deleted")
    |> order_by([i], asc: i.inserted_at, asc: i.uuid)
    |> select([i], {
      struct(i, [:uuid, :name, :status, :catalogue_uuid, :category_uuid, :inserted_at]),
      fragment("?->>'files_folder_uuid'", i.data)
    })
    |> repo().all()
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
