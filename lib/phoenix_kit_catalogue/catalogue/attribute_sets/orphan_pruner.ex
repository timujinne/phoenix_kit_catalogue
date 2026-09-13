defmodule PhoenixKitCatalogue.Catalogue.AttributeSets.OrphanPruner do
  @moduledoc """
  Subscribes to entities blueprint lifecycle events and prunes item
  attachments whose set blueprint was deleted out from under them —
  the "suspenders" to the delete guard's "belt" (the guard refuses
  deleting attached sets; this cleans up after deletes that bypassed
  it, e.g. repo-level operations or a host that never registered the
  guard). The design doc always claimed this subscriber; the 2026-08-18
  panel review noticed it was never actually wired.

  Deliberately NOT a boot-time sweep: pruning consults `get_set/1`,
  and sweeping while entities is disabled or mid-migration would read
  every set as missing. `prune_orphan_attachments/1` guards on
  enablement for the same reason. The trade-off: a blueprint deleted
  while the catalogue app was DOWN is never pruned automatically —
  the residue is invisible rows (`resolve_for_items/2` skips
  unresolvable sets), recoverable by calling
  `AttributeSets.prune_orphan_attachments/1` with the deleted uuid.

  Also subscribes to entities' data-lifecycle topic (§3b, 2026-09-11
  direction): `{:data_deleted, entity_uuid, _data_uuid}` fires
  `AttributeSets.prune_orphan_value_slugs/1`, the backstop for a value
  record HARD-deleted some way that skipped `delete_value/3`'s own
  synchronous slug sweep (e.g. a direct `EntityData.delete/2` or a
  repo-level delete). Archived/trashed values are NOT orphans — that is
  `resolve_set/2`'s `hidden_values` job, not this sweep's.
  """

  use GenServer

  require Logger

  alias PhoenixKitCatalogue.Catalogue.AttributeSets

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    if Code.ensure_loaded?(PhoenixKitEntities.Events) do
      PhoenixKitEntities.Events.subscribe_to_entities()
      PhoenixKitEntities.Events.subscribe_to_all_data()
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info({:entity_deleted, entity_uuid}, state) when is_binary(entity_uuid) do
    case AttributeSets.prune_orphan_attachments(entity_uuid) do
      0 ->
        :ok

      count ->
        Logger.info(
          "AttributeSets.OrphanPruner: pruned #{count} attachment(s) of deleted set #{entity_uuid}"
        )
    end

    {:noreply, state}
  end

  def handle_info({:data_deleted, entity_uuid, _data_uuid}, state) when is_binary(entity_uuid) do
    case AttributeSets.prune_orphan_value_slugs(entity_uuid) do
      0 ->
        :ok

      count ->
        Logger.info(
          "AttributeSets.OrphanPruner: pruned #{count} selection(s) referencing hard-deleted value(s) in set #{entity_uuid}"
        )
    end

    {:noreply, state}
  end

  # Other lifecycle events (:entity_created/:entity_updated,
  # :data_created/:data_updated/:data_reordered) share these topics.
  def handle_info(_msg, state), do: {:noreply, state}
end
