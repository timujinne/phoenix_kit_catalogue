defmodule PhoenixKitCatalogue.Catalogue.PubSub do
  @moduledoc """
  Real-time fan-out for catalogue mutations.

  Every successful write in the Catalogue context broadcasts a small
  `{:catalogue_data_changed, kind, uuid, parent_catalogue_uuid}` event
  to a single shared topic. List/detail LiveViews `subscribe/0` once in
  `mount/3` (after `connected?(socket)`) and re-fetch the affected
  slice on any event, so two admins editing the same data converge
  without manual refresh.

  `parent_catalogue_uuid` lets a detail LV cheaply ignore broadcasts
  for unrelated catalogues — without it, *every* item edit anywhere in
  the system would force every open detail page to reload its slice.
  Global resources (manufacturers, suppliers, manufacturer↔supplier
  links) carry `nil` here; consumers that care about them subscribe
  to the `kind` regardless of parent.

  Payloads are intentionally minimal — UUID + kind + parent, no record
  data — to (a) avoid leaking field-level changes through PubSub, and
  (b) keep the consumer in charge of how much to re-load (single row
  vs full list).

  Subscriptions are cleaned up automatically when the LV process
  terminates; callers don't need to unsubscribe.
  """

  @topic "phoenix_kit_catalogue"

  @typedoc "Resource kind that mutated."
  @type kind ::
          :catalogue
          | :category
          | :item
          | :manufacturer
          | :supplier
          | :smart_rule
          | :links
          | :pdf

  @typedoc "Event message format for `handle_info/2`."
  @type event ::
          {:catalogue_data_changed, kind(), Ecto.UUID.t() | nil, Ecto.UUID.t() | nil}

  @doc "Returns the canonical topic name. Useful for tests."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Subscribes the current process to the catalogue PubSub topic.

  Call from `mount/3` guarded by `connected?(socket)` so the
  disconnected (initial render) pass doesn't subscribe and never
  unsubscribes. Do this **after** any subscription requirements but
  **before** the initial DB load to avoid a race where a write between
  the load and the subscribe leaves the UI stale.
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    if Code.ensure_loaded?(PhoenixKit.PubSubHelper) do
      PhoenixKit.PubSubHelper.subscribe(@topic)
    else
      :ok
    end
  end

  @doc """
  Broadcasts a `{:catalogue_data_changed, kind, uuid, parent_catalogue_uuid}`
  event after a successful write.

  * `uuid` — UUID of the resource that mutated; `nil` when the change
    isn't tied to a specific record (e.g. a bulk link sync).
  * `parent_catalogue_uuid` — UUID of the catalogue that contains the
    mutated resource, or the UUID itself for `kind: :catalogue` events.
    Pass `nil` for resources that aren't scoped to a single catalogue
    (`:manufacturer`, `:supplier`, `:links`); detail LVs use this to
    filter out cross-catalogue noise.
  """
  @spec broadcast(kind(), Ecto.UUID.t() | nil, Ecto.UUID.t() | nil) :: :ok
  def broadcast(kind, uuid, parent_catalogue_uuid \\ nil) when is_atom(kind) do
    if Code.ensure_loaded?(PhoenixKit.PubSubHelper) do
      PhoenixKit.PubSubHelper.broadcast(
        @topic,
        {:catalogue_data_changed, kind, uuid, parent_catalogue_uuid}
      )
    end

    :ok
  end

  @doc """
  Broadcasts a card-refresh event so other open detail pages re-fetch
  a single category card's items after a reorder.

  `scope` is a category UUID or `:uncategorized`. `from` is the
  originating process; receivers compare against `self()` to skip
  self-originated events (the source LV already updated locally).

  `flash_uuid` + `flash_status` let the receiver fire a
  `sortable:flash` push_event keyed to the moved row, so a second
  open tab sees the same green/red flash the originator did.
  """
  @spec broadcast_card_refresh(
          Ecto.UUID.t(),
          Ecto.UUID.t() | :uncategorized,
          Ecto.UUID.t() | nil,
          atom(),
          pid()
        ) :: :ok
  def broadcast_card_refresh(catalogue_uuid, scope, flash_uuid, flash_status, from \\ self()) do
    if Code.ensure_loaded?(PhoenixKit.PubSubHelper) do
      PhoenixKit.PubSubHelper.broadcast(
        @topic,
        {:catalogue_card_refresh, catalogue_uuid, scope, flash_uuid, flash_status, from}
      )
    end

    :ok
  end

  @doc """
  Broadcasts a category-reorder event so other open detail pages
  re-fetch the category list (positions changed). Heavier than
  `broadcast_card_refresh/5` — receivers do a full reset_and_load
  since category order affects every streamed card on the page.
  """
  @spec broadcast_category_reorder(
          Ecto.UUID.t(),
          Ecto.UUID.t() | nil,
          atom(),
          pid()
        ) :: :ok
  def broadcast_category_reorder(catalogue_uuid, moved_id, status, from \\ self()) do
    if Code.ensure_loaded?(PhoenixKit.PubSubHelper) do
      PhoenixKit.PubSubHelper.broadcast(
        @topic,
        {:catalogue_category_reorder, catalogue_uuid, moved_id, status, from}
      )
    end

    :ok
  end

  @doc """
  Broadcasts a bulk-change event so other open detail pages animate
  the affected items leaving / arriving on screen.

  `kind`:
    * `:trashed` — items are going away (red flash → state refresh).
    * `:restored` — items are coming back (state refresh → green flash).
    * `:moved` — items are leaving one scope and entering another
      (red flash on source DOM → state refresh → green flash on
      destination DOM).
    * `:permanent_delete` — items are gone for good (same animation
      as `:trashed`; the row removal is harder to undo but the visual
      cue is the same).

  `uuids` is the affected item list. `scopes` is the list of category
  scopes (UUIDs or `:uncategorized`) whose cards need to refresh — for
  moves this is the union of source and destination; for trash/restore
  it's the scope that gained/lost items.
  """
  @spec broadcast_bulk_change(
          Ecto.UUID.t(),
          :trashed | :restored | :moved | :permanent_delete,
          [Ecto.UUID.t()],
          [Ecto.UUID.t() | :uncategorized],
          pid()
        ) :: :ok
  def broadcast_bulk_change(catalogue_uuid, kind, uuids, scopes, from \\ self())
      when is_atom(kind) and is_list(uuids) and is_list(scopes) do
    if Code.ensure_loaded?(PhoenixKit.PubSubHelper) do
      PhoenixKit.PubSubHelper.broadcast(
        @topic,
        {:catalogue_bulk_change, catalogue_uuid, kind, uuids, scopes, from}
      )
    end

    :ok
  end
end
