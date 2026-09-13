defmodule PhoenixKitCatalogue.Web.ComponentRelayTest do
  @moduledoc """
  The relay is the only way catalogue PubSub reaches an embedded
  LiveComponent, so its contract is pinned end to end: which events
  count, that a burst lands as one refresh, and that it stops when the
  popup closes, when the host dies, or when nobody acknowledges.
  """
  use ExUnit.Case, async: false

  alias PhoenixKitCatalogue.Catalogue.PubSub
  alias PhoenixKitCatalogue.Web.ComponentRelay

  @mod PhoenixKitCatalogue.Web.Components.ItemSelectorModal
  @c1 "01a00000-0000-7000-8000-000000000001"
  @c2 "01a00000-0000-7000-8000-000000000002"

  defp start(opts) do
    ComponentRelay.start(@mod, "picker", Keyword.merge([debounce_ms: 20], opts))
  end

  defp assert_refresh do
    assert_receive {:phoenix, :send_update,
                    {{@mod, "picker"}, %{id: "picker", live_refresh: refresh}}},
                   500

    refresh
  end

  defp refute_refresh, do: refute_receive({:phoenix, :send_update, _}, 150)

  setup do
    # subscribe/0 is async — a broadcast racing the relay's subscription
    # would be a flaky test, not a relay defect.
    relay = start(catalogue_uuids: [@c1])
    Process.sleep(20)
    on_exit(fn -> ComponentRelay.stop(relay) end)
    %{relay: relay}
  end

  test "an event for another catalogue is ignored" do
    PubSub.broadcast(:item, Ecto.UUID.generate(), @c2)
    refute_refresh()
  end

  test "an event for the scoped catalogue refreshes, and a burst refreshes once", %{relay: relay} do
    PubSub.broadcast(:item, Ecto.UUID.generate(), @c1)
    PubSub.broadcast(:category, Ecto.UUID.generate(), @c1)
    PubSub.broadcast(:item, Ecto.UUID.generate(), @c1)

    {ref, ^relay} = assert_refresh()
    assert is_reference(ref)
    refute_refresh()
  end

  test "a catalogue-level event counts whichever catalogue it names" do
    # A whole-index reorder names only its first row.
    PubSub.broadcast(:catalogue, @c2, @c2)
    assert_refresh()
  end

  test "an event with no parent, a position event and a sort change all count" do
    PubSub.broadcast(:links, nil, nil)
    assert_refresh() |> ComponentRelay.ack()

    PubSub.broadcast_category_reorder(@c1, nil, :ok)
    assert_refresh() |> ComponentRelay.ack()

    PubSub.broadcast_view_sort_changed(:detail_items, "name", :asc)
    assert_refresh()
  end

  test "a position event for another catalogue is ignored" do
    PubSub.broadcast_card_refresh(@c2, :uncategorized, nil, :ok)
    PubSub.broadcast_bulk_change(@c2, :trashed, [])
    refute_refresh()
  end

  test "stop ends the relay", %{relay: relay} do
    ComponentRelay.stop(relay)
    Process.sleep(20)
    refute Process.alive?(relay)

    PubSub.broadcast(:item, Ecto.UUID.generate(), @c1)
    refute_refresh()
  end

  test "the relay dies with the host LiveView" do
    test = self()

    host =
      spawn(fn ->
        send(test, {:relay, start(catalogue_uuids: [@c1])})
        Process.sleep(:infinity)
      end)

    assert_receive {:relay, relay}
    Process.exit(host, :kill)
    Process.sleep(20)
    refute Process.alive?(relay)
  end

  test "a refresh nobody acknowledges ends the relay at the next event", %{relay: relay} do
    ComponentRelay.stop(relay)
    relay = start(catalogue_uuids: [@c1], ack_timeout_ms: 30)
    Process.sleep(20)

    PubSub.broadcast(:item, Ecto.UUID.generate(), @c1)
    assert_refresh()

    # Acknowledged in time: the relay keeps going.
    Process.sleep(50)
    PubSub.broadcast(:item, Ecto.UUID.generate(), @c1)
    refute_refresh()
    refute Process.alive?(relay)
  end

  test "a refresh nobody acknowledges ends the relay on its own, with no second event", %{
    relay: relay
  } do
    ComponentRelay.stop(relay)
    relay = start(catalogue_uuids: [@c1], ack_timeout_ms: 30)
    Process.sleep(20)

    PubSub.broadcast(:item, Ecto.UUID.generate(), @c1)
    assert_refresh()
    assert Process.alive?(relay)

    Process.sleep(60)
    refute Process.alive?(relay)
  end

  test "an acknowledged refresh keeps the relay alive past the timeout", %{relay: relay} do
    # The setup relay answers the same event with the same component id;
    # acking ITS refresh would leave this one unacknowledged.
    ComponentRelay.stop(relay)
    relay = start(catalogue_uuids: [@c1], ack_timeout_ms: 30)
    Process.sleep(20)

    PubSub.broadcast(:item, Ecto.UUID.generate(), @c1)
    assert_refresh() |> ComponentRelay.ack()

    Process.sleep(50)
    PubSub.broadcast(:item, Ecto.UUID.generate(), @c1)
    assert_refresh()
    assert Process.alive?(relay)
    ComponentRelay.stop(relay)
  end

  test "no catalogue restriction means every event counts", %{relay: relay} do
    ComponentRelay.stop(relay)
    relay = start(catalogue_uuids: nil)
    Process.sleep(20)

    PubSub.broadcast(:item, Ecto.UUID.generate(), @c2)
    assert_refresh()
    ComponentRelay.stop(relay)
  end
end
