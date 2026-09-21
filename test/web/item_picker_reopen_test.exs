defmodule PhoenixKitCatalogue.Web.Components.ItemPickerReopenTest do
  @moduledoc """
  L027: reopening the picker for a *pre-selected* item must show a
  non-empty replacement list — not "No items found.", and (per the PR #63
  review follow-up) not a one-row name search for the item that's already
  chosen: the reopen browses the empty-query first page while the input
  keeps showing the item's name. Uses a fresh LiveView mount (no prior
  query_change in this process) to reproduce the post-reload state:
  `selected_item` set, but `options` never searched yet.
  """
  # async: false — shares the Repo sandbox with the isolated host LV.
  use PhoenixKitCatalogue.LiveCase, async: false

  defmodule HostLive do
    use Phoenix.LiveView

    import PhoenixKitCatalogue.Web.Components, only: [item_picker: 1]

    def mount(_params, session, socket) do
      item = PhoenixKitCatalogue.Catalogue.get_item(session["item_uuid"], preload: [:catalogue])
      {:ok, assign(socket, item: item), layout: false}
    end

    def render(assigns) do
      ~H"""
      <div>
        <.item_picker id="host-picker" locale="en" selected_item={@item} />
      </div>
      """
    end

    def handle_info({:item_picker_select, _id, _item}, socket), do: {:noreply, socket}
    def handle_info({:item_picker_clear, _id}, socket), do: {:noreply, socket}
  end

  test "focusing a picker mounted with an already-selected item opens a non-empty list", %{
    conn: conn
  } do
    cat = fixture_catalogue(%{name: "Reopen Cat"})
    item = fixture_item(%{name: "Preselected Item", catalogue_uuid: cat.uuid})
    _sibling = fixture_item(%{name: "Sibling Item", catalogue_uuid: cat.uuid})

    {:ok, view, _html} = live_isolated(conn, HostLive, session: %{"item_uuid" => item.uuid})

    # Input already mirrors the selected item's name — same as the "just
    # selected" state.
    assert has_element?(view, "#host-picker-input[value='Preselected Item']")

    # Nothing has been searched yet in this process — reproduces the
    # post-reload mount, unlike a live selection where a prior
    # query_change already populated `options`.
    view |> element("#host-picker-input") |> render_focus()

    html = render(view)
    refute html =~ "No items found."
    assert html =~ ~s(id="host-picker-listbox")

    # The reopen is a BROWSE, not a name search: the sibling must be in
    # the list (a name search for "Preselected Item" would return only
    # the already-chosen row). The input still shows the item's name.
    assert html =~ "Sibling Item"
    assert has_element?(view, "#host-picker-input[value='Preselected Item']")

    # Option-level pin — the name appearing in the closed input's value
    # alone must not satisfy this test.
    assert has_element?(view, "#host-picker-listbox [id^='host-picker-option-']")
  end
end
