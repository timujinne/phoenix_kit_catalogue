defmodule PhoenixKitCatalogue.Web.ComponentRelay do
  @debounce_ms 250
  @ack_timeout_ms 15_000

  @moduledoc """
  Delivers catalogue PubSub events to a LiveComponent as `send_update/3`
  refreshes, so a component embedded in ANY host LiveView follows the
  catalogue live without the host forwarding a single message.

  A LiveComponent cannot receive PubSub itself — subscribing from one
  subscribes the host LiveView process, and every host would then need
  a `handle_info/2` clause for each catalogue event or crash on the
  first broadcast. The relay is a small process of its own: it holds the
  subscription, decides which events concern the component (its scope's
  catalogues), collapses a burst of writes into one refresh, and hands
  that refresh to the component through `Phoenix.LiveView.send_update/3`
  — the one door into a component that is open from another process.

  ## Lifetime

  The relay monitors the host LiveView and exits when it does, and the
  component stops it (`stop/1`) when it closes. A component the host
  unmounted some other way is detected by the ack: each refresh carries
  a reference the component acknowledges from `update/2`; a refresh
  still unacknowledged #{@ack_timeout_ms} ms later means nobody is
  listening and the relay exits on its own — it does not wait for a
  second event to notice. (LiveView itself only logs a debug line for a
  `send_update` to a component that is gone, so even that one refresh
  costs nothing visible.)

  ## Events that trigger a refresh

  Every `{:catalogue_data_changed, kind, uuid, parent}` whose parent is
  one of the component's catalogues, every catalogue-level event (a
  reorder names only its first row), or any event at all when the
  component browses without a catalogue restriction — plus the position events (`:catalogue_category_reorder`,
  `:catalogue_card_refresh`, `:catalogue_bulk_change`) for those
  catalogues, and every shared-sort change. Events are collapsed with a
  #{@debounce_ms} ms trailing debounce, so one drag that writes a dozen
  rows refreshes once.
  """

  alias PhoenixKitCatalogue.Catalogue.PubSub

  @typedoc "What the component receives in `update/2`: `live_refresh: {ref, relay_pid}`."
  @type refresh :: {reference(), pid()}

  @doc """
  Starts a relay for the component `module` with `id` mounted in the
  calling LiveView process. Returns the relay pid, to pass to `ack/1`
  and `stop/1`.

  `opts`:

    * `:catalogue_uuids` — the component's catalogues (string uuids);
      `nil` or `[]` means every catalogue event is relevant.
    * `:debounce_ms` — override the trailing debounce (tests).
    * `:ack_timeout_ms` — override the abandonment timeout (tests).
  """
  @spec start(module(), String.t(), keyword()) :: pid()
  def start(module, id, opts \\ []) do
    lv = self()

    uuids =
      case opts[:catalogue_uuids] do
        list when is_list(list) and list != [] -> Enum.map(list, &to_string/1)
        _ -> nil
      end

    debounce = opts[:debounce_ms] || @debounce_ms
    ack_timeout = opts[:ack_timeout_ms] || @ack_timeout_ms

    # spawn, not spawn_link: a relay crash must never take the host
    # LiveView down. The monitor below is the tie in the other direction.
    spawn(fn ->
      Process.monitor(lv)
      PubSub.subscribe()

      loop(%{
        lv: lv,
        module: module,
        id: id,
        uuids: uuids,
        debounce: debounce,
        ack_timeout: ack_timeout,
        timer: nil,
        pending: nil,
        pending_since: nil
      })
    end)
  end

  @doc "Acknowledges a refresh from the component's `update/2`."
  @spec ack(refresh()) :: :ok
  def ack({ref, relay}) when is_reference(ref) and is_pid(relay) do
    send(relay, {:ack, ref})
    :ok
  end

  def ack(_), do: :ok

  @doc "Stops the relay. Safe on `nil` and on a relay that already exited."
  @spec stop(pid() | nil) :: :ok
  def stop(relay) when is_pid(relay) do
    send(relay, :stop)
    :ok
  end

  def stop(_), do: :ok

  defp loop(state) do
    receive do
      {:DOWN, _ref, :process, lv, _reason} when lv == state.lv ->
        :ok

      :stop ->
        :ok

      {:ack, ref} ->
        if ref == state.pending,
          do: loop(%{state | pending: nil, pending_since: nil}),
          else: loop(state)

      :flush ->
        flush(%{state | timer: nil})

      # The ack window for THIS refresh closed: still pending means the
      # component is gone.
      {:ack_check, ref} ->
        if ref == state.pending, do: :ok, else: loop(state)

      message ->
        if relevant?(message, state.uuids), do: loop(schedule(state)), else: loop(state)
    end
  end

  # One timer per burst — a second event inside the window rides the
  # first timer, so a burst of writes lands as one refresh.
  defp schedule(%{timer: nil} = state) do
    %{state | timer: Process.send_after(self(), :flush, state.debounce)}
  end

  defp schedule(state), do: state

  defp flush(state) do
    if abandoned?(state) do
      :ok
    else
      ref = make_ref()

      Phoenix.LiveView.send_update(state.lv, state.module,
        id: state.id,
        live_refresh: {ref, self()}
      )

      Process.send_after(self(), {:ack_check, ref}, state.ack_timeout)
      loop(%{state | pending: ref, pending_since: System.monotonic_time(:millisecond)})
    end
  end

  # The previous refresh went unanswered for longer than any component
  # takes to run update/2: the host unmounted the component without a
  # close (navigation inside the host, a crashed render) and nobody is
  # listening any more.
  defp abandoned?(%{pending: nil}), do: false

  defp abandoned?(%{pending_since: since, ack_timeout: ack_timeout}) do
    System.monotonic_time(:millisecond) - since > ack_timeout
  end

  # ── Relevance ─────────────────────────────────────────────────────

  # A catalogue-level event always counts: a reorder of the whole index
  # broadcasts once, naming only the first row it moved, and the tiles
  # of a multi-catalogue root must follow it whichever row that was.
  defp relevant?({:catalogue_data_changed, :catalogue, _uuid, _parent}, _uuids), do: true

  defp relevant?({:catalogue_data_changed, _kind, _uuid, parent}, uuids),
    do: in_scope?(uuids, parent)

  defp relevant?({:catalogue_category_reorder, catalogue_uuid, _moved, _status, _from}, uuids),
    do: in_scope?(uuids, catalogue_uuid)

  defp relevant?({:catalogue_card_refresh, catalogue_uuid, _scope, _uuid, _status, _from}, uuids),
    do: in_scope?(uuids, catalogue_uuid)

  defp relevant?({:catalogue_bulk_change, catalogue_uuid, _kind, _uuids, _from}, uuids),
    do: in_scope?(uuids, catalogue_uuid)

  defp relevant?({:catalogue_view_sort_changed, _scope, _by, _dir, _from}, _uuids), do: true

  defp relevant?(_message, _uuids), do: false

  # No restriction, or an event not tied to one catalogue (a bulk link
  # sync broadcasts a nil parent), concerns every component.
  defp in_scope?(nil, _uuid), do: true
  defp in_scope?(_uuids, nil), do: true
  defp in_scope?(uuids, uuid), do: to_string(uuid) in uuids
end
