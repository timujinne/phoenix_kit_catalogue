defmodule PhoenixKitCatalogue.Web.Components.ItemPickerBrowseOrderTest do
  @moduledoc """
  The picker's blank-query BROWSE (focus-to-browse, the reopen list)
  reads in the module's shared sort like every other listing — for a
  category-scoped picker under Manual that is the admin's hand-arranged
  position order, not the fetch layer's name default (client,
  2026-09-12: the per-row picker listed a category A→Z while the
  catalogue showed another order). A typed query is a search and reads
  in Manual order as well (Max, 2026-09-12: "the default should be the
  manual order"), like the admin's own in-catalogue search results.
  """
  # async: false — shares the Repo sandbox with the isolated host LV.
  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Web.ViewConfig

  defmodule HostLive do
    use Phoenix.LiveView

    import PhoenixKitCatalogue.Web.Components, only: [item_picker: 1]

    def mount(_params, session, socket) do
      {:ok, assign(socket, category_uuids: session["category_uuids"]), layout: false}
    end

    def render(assigns) do
      ~H"""
      <div>
        <.item_picker id="host-picker" locale="en" category_uuids={@category_uuids} />
      </div>
      """
    end

    def handle_info({:item_picker_select, _id, _item}, socket), do: {:noreply, socket}
    def handle_info({:item_picker_clear, _id}, socket), do: {:noreply, socket}
  end

  @names ["Recessed handle", "Profile handle", "Handle-less system", "Push for cabinet"]

  setup do
    cat = fixture_catalogue(%{name: "Order Cat"})
    handles = fixture_category(cat, %{name: "Handles"})

    items =
      for name <- @names do
        fixture_item(%{name: name, catalogue_uuid: cat.uuid, category_uuid: handles.uuid})
      end

    # Positions run against the alphabet so the two orders are distinguishable.
    :ok = Catalogue.reorder_items(cat.uuid, handles.uuid, Enum.map(items, & &1.uuid))

    %{cat: cat, handles: handles}
  end

  defp order_in(html, names) do
    names
    |> Enum.map(&{&1, :binary.match(html, &1) |> elem(0)})
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end

  test "a category-scoped browse and a search both list the admin's Manual order", %{
    conn: conn,
    handles: handles
  } do
    {:ok, view, _html} =
      live_isolated(conn, HostLive, session: %{"category_uuids" => [handles.uuid]})

    view |> element("#host-picker-input") |> render_focus()
    html = render(view)
    assert html =~ ~s(id="host-picker-listbox")
    assert order_in(html, @names) == @names

    html =
      view
      |> element("#host-picker-input")
      |> render_change(%{"value" => "handle"})

    handle_names = Enum.filter(@names, &(&1 =~ ~r/handle/i))
    assert order_in(html, handle_names) == handle_names
  end

  test "a blank browse follows a FIELD shared sort; a search still reads Manual", %{
    conn: conn,
    handles: handles
  } do
    {:ok, _} = ViewConfig.save_global_sort(:detail_items, "name", :desc)

    # The settings row rolls back with the sandbox; the in-process
    # settings cache does not — put Manual back for the next test.
    on_exit(fn -> ViewConfig.save_global_sort(:detail_items, "position", :asc) end)

    {:ok, view, _html} =
      live_isolated(conn, HostLive, session: %{"category_uuids" => [handles.uuid]})

    view |> element("#host-picker-input") |> render_focus()
    assert order_in(render(view), @names) == Enum.sort(@names, :desc)

    html = view |> element("#host-picker-input") |> render_change(%{"value" => "handle"})
    handle_names = Enum.filter(@names, &(&1 =~ ~r/handle/i))
    assert order_in(html, handle_names) == handle_names
  end
end
