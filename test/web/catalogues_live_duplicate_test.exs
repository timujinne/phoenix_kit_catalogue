defmodule PhoenixKitCatalogue.Web.CataloguesLiveDuplicateTest do
  @moduledoc """
  Duplicate from the catalogues page: the row menu offers it, the
  confirmation says what will be copied, and the copy runs in a
  supervised task that reports back to the page when it is done.
  """
  use PhoenixKitCatalogue.LiveCase

  alias PhoenixKitCatalogue.Catalogue

  @base "/en/admin/catalogue"

  # The copy runs outside the LiveView process; poll the rendered page
  # until the task's report has arrived.
  defp await_render(view, pattern, tries \\ 250) do
    html = render(view)

    cond do
      html =~ pattern -> html
      tries == 0 -> flunk("never rendered #{inspect(pattern)}")
      true -> Process.sleep(20) && await_render(view, pattern, tries - 1)
    end
  end

  setup do
    source = fixture_catalogue(%{name: "Kitchen Fronts"})
    shelf = fixture_category(source, %{name: "Shelf"})
    fixture_item(%{name: "Panel", category_uuid: shelf.uuid})
    fixture_item(%{name: "Handle", catalogue_uuid: source.uuid})
    %{source: source}
  end

  test "the row menu offers Duplicate, and the copy appears", %{conn: conn, source: source} do
    {:ok, view, _html} = live(conn, @base)

    assert has_element?(
             view,
             ~s(button[phx-click="request_duplicate_catalogue"][phx-value-uuid="#{source.uuid}"])
           )

    html = render_click(view, "request_duplicate_catalogue", %{"uuid" => source.uuid})
    assert html =~ "Duplicate catalogue"
    assert html =~ "with all its categories (1) and items (2)"
    assert html =~ "Shared with the original, not duplicated."

    # Every choice starts on, except starting archived.
    for key <- ~w(skus files suppliers) do
      assert has_element?(view, "#duplicate-choice-#{key}[checked]")
    end

    refute has_element?(view, "#duplicate-choice-archived[checked]")

    html = render_click(view, "confirm_duplicate_catalogue", %{})
    assert html =~ "Duplicating “Kitchen Fronts”…"

    html = await_render(view, "Created “Kitchen Fronts (copy)” (categories: 1, items: 2).")
    assert html =~ "Kitchen Fronts (copy)"

    copy = Enum.find(Catalogue.list_catalogues(), &(&1.name == "Kitchen Fronts (copy)"))
    assert %{categories: 1, items: 2} = Catalogue.catalogue_copy_counts(copy.uuid)
  end

  test "the report names the copy in the admin's language, not the content's", %{conn: conn} do
    source =
      fixture_catalogue(%{
        name: "Köök",
        data: %{"_primary_language" => "et-EE", "en-US" => %{"_name" => "Kitchen"}}
      })

    {:ok, view, _html} = live(conn, @base)
    render_click(view, "request_duplicate_catalogue", %{"uuid" => source.uuid})
    render_click(view, "confirm_duplicate_catalogue", %{})

    html = await_render(view, "Created “")
    assert html =~ "Created “Kitchen (copy)”"
    assert Enum.any?(Catalogue.list_catalogues(), &(&1.name == "Köök (koopia)"))
  end

  test "the choices reach the copy through the dialog's form", %{conn: conn, source: source} do
    Catalogue.list_items_for_catalogue(source.uuid)
    |> Enum.each(&Catalogue.update_item(&1, %{sku: "SKU-" <> &1.name}))

    {:ok, view, _html} = live(conn, @base)
    render_click(view, "request_duplicate_catalogue", %{"uuid" => source.uuid})

    view
    |> form("#duplicate-catalogue-choices", %{
      "choices" => %{"skus" => "false", "archived" => "true"}
    })
    |> render_change()

    refute has_element?(view, "#duplicate-choice-skus[checked]")
    assert has_element?(view, "#duplicate-choice-archived[checked]")

    render_click(view, "confirm_duplicate_catalogue", %{})
    await_render(view, "Created “Kitchen Fronts (copy)”")

    copy = Enum.find(Catalogue.list_catalogues(), &(&1.name == "Kitchen Fronts (copy)"))
    assert copy.status == "archived"
    assert Enum.all?(Catalogue.list_items_for_catalogue(copy.uuid), &is_nil(&1.sku))
    assert Enum.all?(Catalogue.list_items_for_catalogue(source.uuid), &(&1.sku != nil))
  end

  test "cancel copies nothing", %{conn: conn, source: source} do
    {:ok, view, _html} = live(conn, @base)

    render_click(view, "request_duplicate_catalogue", %{"uuid" => source.uuid})
    html = render_click(view, "cancel_duplicate_catalogue", %{})

    refute html =~ "Duplicate catalogue"
    # No copy was started: nothing is being tracked, and nothing arrives.
    assert :sys.get_state(view.pid).socket.assigns.duplicating == %{}
    refute render(view) =~ "Created"
    refute Enum.any?(Catalogue.list_catalogues(), &(&1.name =~ "(copy)"))
  end

  test "a trashed or unknown catalogue is not offered for copying", %{conn: conn, source: source} do
    {:ok, _} = Catalogue.trash_catalogue(source)
    {:ok, view, _html} = live(conn, @base)

    html = render_click(view, "request_duplicate_catalogue", %{"uuid" => source.uuid})
    assert html =~ "Catalogue not found."
    refute html =~ "Duplicate catalogue"

    html = render_click(view, "request_duplicate_catalogue", %{"uuid" => UUIDv7.generate()})
    assert html =~ "Catalogue not found."
  end

  # A copy in flight, as the page tracks it: a monitor reference per source.
  defp pretend_running(view, source_uuid) do
    ref = make_ref()

    :sys.replace_state(view.pid, fn state ->
      put_in(state.socket.assigns[:duplicating], %{ref => source_uuid})
    end)

    ref
  end

  test "a copy that crashes still reports back", %{conn: conn, source: source} do
    {:ok, view, _html} = live(conn, @base)
    ref = pretend_running(view, source.uuid)

    send(view.pid, {:DOWN, ref, :process, self(), :killed})

    assert render(view) =~ "Failed to duplicate the catalogue."
    assert :sys.get_state(view.pid).socket.assigns.duplicating == %{}
  end

  test "a copy whose source vanished says so", %{conn: conn, source: source} do
    {:ok, view, _html} = live(conn, @base)
    ref = pretend_running(view, source.uuid)

    send(view.pid, {ref, {:error, :not_found}})

    assert render(view) =~ "Catalogue not found."
  end

  test "a second Duplicate while a copy of that catalogue runs is refused",
       %{conn: conn, source: source} do
    {:ok, view, _html} = live(conn, @base)
    pretend_running(view, source.uuid)

    html = render_click(view, "request_duplicate_catalogue", %{"uuid" => source.uuid})

    assert html =~ "This catalogue is already being duplicated."
    refute has_element?(view, "#duplicate-catalogue-choices")
  end

  test "a forged or missing uuid is not a crash", %{conn: conn} do
    {:ok, view, _html} = live(conn, @base)

    assert render_click(view, "request_duplicate_catalogue", %{"uuid" => "x"}) =~
             "Catalogue not found."

    assert render_click(view, "request_duplicate_catalogue", %{}) =~ "Catalogue not found."
    assert render_click(view, "trash_catalogue", %{"uuid" => "x"}) =~ "Catalogue not found."

    # Choices without an open dialog, or of the wrong shape, change nothing.
    render_click(view, "set_duplicate_choices", %{"choices" => %{"skus" => "false"}})
    render_click(view, "set_duplicate_choices", %{"choices" => "skus"})
    assert :sys.get_state(view.pid).socket.assigns.duplicate_confirm == nil
  end
end
