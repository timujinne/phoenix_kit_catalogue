defmodule PhoenixKitCatalogue.Web.Components.ItemPickerGuardsTest do
  @moduledoc """
  Server-side guards on ItemPicker events, from the 2026-08-25 quorum
  review: the markup hides what must not be clicked, but the handlers are
  the boundary — an excluded/disabled/foreign target can still arrive as
  a crafted push or as an honest click racing the parent re-render that
  just outlawed it. The host renders every picker message back into DOM
  so tests assert what a production host would actually receive.
  """
  # async: false — shares the Repo sandbox with the isolated host LV.
  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue

  defmodule HostLive do
    use Phoenix.LiveView

    import PhoenixKitCatalogue.Web.Components, only: [item_picker: 1]

    def mount(_params, session, socket) do
      {:ok,
       assign(socket,
         excluded: List.wrap(session["excluded"]),
         disabled: session["disabled"] == true,
         statuses: session["statuses"],
         catalogue_uuids: session["catalogue_uuids"],
         last_message: nil
       ), layout: false}
    end

    def render(assigns) do
      ~H"""
      <div>
        <.item_picker
          id="guard-picker"
          locale="en"
          selected_item={nil}
          excluded_uuids={@excluded}
          disabled={@disabled}
          statuses={@statuses}
          catalogue_uuids={@catalogue_uuids}
        />
        <div :if={@last_message} id="last-message">{@last_message}</div>
      </div>
      """
    end

    def handle_event("swap_scope", %{"to" => uuid}, socket),
      do: {:noreply, assign(socket, catalogue_uuids: [uuid])}

    def handle_info({:item_picker_select, _id, item}, socket),
      do: {:noreply, assign(socket, last_message: "selected:#{item.name}")}

    def handle_info({:item_picker_clear, _id}, socket),
      do: {:noreply, assign(socket, last_message: "cleared")}
  end

  defp mount_host(conn, session) do
    live_isolated(conn, HostLive, session: session)
  end

  defp picker(view), do: with_target(view, "#guard-picker")

  defp populate(view) do
    # A focus browse fills `options` so select has something to aim at.
    view |> element("#guard-picker-input") |> render_focus()
    view
  end

  setup do
    cat = fixture_catalogue(%{name: "Guard Cat"})
    item = fixture_item(%{name: "Guarded Item", catalogue_uuid: cat.uuid})
    %{cat: cat, item: item}
  end

  test "select refuses an excluded uuid server-side", %{conn: conn, item: item} do
    {:ok, view, _html} = mount_host(conn, %{"excluded" => [item.uuid]})
    populate(view)

    view |> picker() |> render_click("select", %{"uuid" => item.uuid})

    # The message the exclusion exists to prevent must not fire — before
    # the guard this delivered the item and the host double-picked it.
    refute has_element?(view, "#last-message")
  end

  test "a disabled picker ignores query, select, and clear", %{conn: conn, item: item} do
    {:ok, view, _html} = mount_host(conn, %{"disabled" => true})

    view |> picker() |> render_change("query_change", %{"value" => "Guarded"})
    refute has_element?(view, "#guard-picker-listbox")

    view |> picker() |> render_click("select", %{"uuid" => item.uuid})
    view |> picker() |> render_click("clear", %{})
    refute has_element?(view, "#last-message")
  end

  test "malformed payloads and unknown events degrade to no-ops", %{conn: conn} do
    {:ok, view, _html} = mount_host(conn, %{})

    # Each of these was a FunctionClauseError in the host LV process
    # before the is_binary guard + catch-all clause.
    view |> picker() |> render_click("select", %{})
    view |> picker() |> render_change("query_change", %{})
    view |> picker() |> render_change("query_change", %{"value" => 123})
    view |> picker() |> render_click("no_such_event", %{"x" => 1})

    assert Process.alive?(view.pid)
  end

  test "an oversized query is capped before it reaches the search", %{conn: conn} do
    {:ok, view, _html} = mount_host(conn, %{})

    view |> picker() |> render_change("query_change", %{"value" => String.duplicate("a", 5_000)})

    assert Process.alive?(view.pid)
    # The input renders the capped value, proving the cap happened
    # server-side rather than the query just surviving by luck.
    assert has_element?(view, "#guard-picker-input[value='#{String.duplicate("a", 200)}']")
  end

  test "the statuses attr scopes the option list", %{conn: conn, cat: cat, item: item} do
    {:ok, _inactive} =
      Catalogue.create_item(%{
        name: "Retired Item",
        catalogue_uuid: cat.uuid,
        status: "inactive"
      })

    {:ok, view, _html} = mount_host(conn, %{"statuses" => ["active"]})
    populate(view)

    html = render(view)
    assert html =~ item.name
    refute html =~ "Retired Item"
  end

  test "changing the parent-supplied scope invalidates the option list", %{
    conn: conn,
    cat: cat,
    item: item
  } do
    other = fixture_catalogue(%{name: "Other Cat"})

    {:ok, view, _html} = mount_host(conn, %{"catalogue_uuids" => [cat.uuid]})
    populate(view)
    assert render(view) =~ item.name

    # The parent re-renders the picker scoped elsewhere: the dropdown
    # closes and the old options are gone — select can no longer deliver
    # an item the new scope would never return.
    render_click(view, "swap_scope", %{"to" => other.uuid})
    refute has_element?(view, "#guard-picker-listbox")

    view |> picker() |> render_click("select", %{"uuid" => item.uuid})
    refute has_element?(view, "#last-message")
  end
end
