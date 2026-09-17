defmodule PhoenixKitCatalogue.Web.CatalogueDetailCrossCatalogueMoveTest do
  @moduledoc """
  The detail page's bulk Move modals reach other catalogues: a catalogue
  picker above the category picker, both driven through their real
  forms. Only live catalogues of this catalogue's kind are offered, and
  a catalogue the modal did not offer is ignored.
  """
  use PhoenixKitCatalogue.LiveCase

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.PubSub, as: CataloguePubSub

  @base "/en/admin/catalogue"

  setup do
    here = fixture_catalogue(%{name: "Here"})
    there = fixture_catalogue(%{name: "There"})
    landing = fixture_category(there, %{name: "Landing"})
    %{here: here, there: there, landing: landing}
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp choose(view, event, disposition) do
    view
    |> element(~s(input[phx-click="#{event}"][value="#{disposition}"]))
    |> render_click()
  end

  defp confirm(view, event) do
    view
    |> element(~s(button[phx-click="#{event}"]))
    |> render_click()
  end

  defp pick_catalogue(view, event, uuid) do
    view
    |> element("form[phx-change=#{event}]")
    |> render_change(%{"catalogue_uuid" => uuid})
  end

  describe "items" do
    # The context's bulk move refuses a non-canonical uuid with
    # `:invalid_uuid`; the page must drop it first, not crash on it.
    test "a non-canonical uuid in the selection is dropped, not a crash",
         %{conn: conn, here: here} do
      item = fixture_item(%{catalogue_uuid: here.uuid, name: "Stays"})
      {:ok, view, _html} = live(conn, "#{@base}/#{here.uuid}")

      render_click(view, "request_bulk_move_items", %{
        "uuids" => [String.upcase(item.uuid), "aaaaaaaaaaaaaaaa"]
      })

      assert assigns(view).bulk_move_modal == nil

      render_click(view, "request_bulk_move_items", %{
        "uuids" => [item.uuid, String.upcase(item.uuid)]
      })

      assert assigns(view).bulk_move_modal.uuids == [item.uuid]
    end

    test "move into a category of another catalogue",
         %{conn: conn, here: here, there: there, landing: landing} do
      item = fixture_item(%{catalogue_uuid: here.uuid, name: "Traveller"})
      {:ok, view, _html} = live(conn, "#{@base}/#{here.uuid}")

      render_click(view, "request_bulk_move_items", %{"uuids" => [item.uuid]})
      pick_catalogue(view, "select_bulk_move_catalogue", there.uuid)
      choose(view, "set_bulk_move_disposition", "move_to")

      view
      |> element("form[phx-change=select_bulk_move_target]")
      |> render_change(%{"category_uuid" => landing.uuid})

      html = confirm(view, "confirm_bulk_move_items")

      assert html =~ "Moved 1 items."
      moved = Catalogue.get_item(item.uuid)
      assert moved.catalogue_uuid == there.uuid
      assert moved.category_uuid == landing.uuid
    end

    test "move into another catalogue without a category",
         %{conn: conn, here: here, there: there} do
      category = fixture_category(here, %{name: "Old home"})
      item = fixture_item(%{category_uuid: category.uuid, name: "Traveller"})
      {:ok, view, _html} = live(conn, "#{@base}/#{here.uuid}")

      render_click(view, "request_bulk_move_items", %{"uuids" => [item.uuid]})
      html = pick_catalogue(view, "select_bulk_move_catalogue", there.uuid)
      assert html =~ "Items go to the chosen catalogue without a category."

      CataloguePubSub.subscribe()
      confirm(view, "confirm_bulk_move_items")

      # The page tells the destination; the context call itself is muted.
      there_uuid = there.uuid
      assert_receive {:catalogue_data_changed, :item, nil, ^there_uuid}

      moved = Catalogue.get_item(item.uuid)
      assert moved.catalogue_uuid == there.uuid
      assert moved.category_uuid == nil
    end

    test "switching catalogue re-lists its categories and drops the old pick",
         %{conn: conn, here: here, there: there, landing: landing} do
      home_category = fixture_category(here, %{name: "Home category"})
      item = fixture_item(%{catalogue_uuid: here.uuid, name: "Traveller"})
      {:ok, view, _html} = live(conn, "#{@base}/#{here.uuid}")

      render_click(view, "request_bulk_move_items", %{"uuids" => [item.uuid]})
      choose(view, "set_bulk_move_disposition", "move_to")
      render_click(view, "select_bulk_move_target", %{"category_uuid" => home_category.uuid})
      assert assigns(view).bulk_move_modal.target_uuid == home_category.uuid

      pick_catalogue(view, "select_bulk_move_catalogue", there.uuid)

      modal = assigns(view).bulk_move_modal
      assert modal.target_uuid == nil
      assert Enum.map(modal.targets, fn {c, _} -> c.uuid end) == [landing.uuid]
    end

    test "only live catalogues of this kind are offered; others are ignored",
         %{conn: conn, here: here, there: there} do
      smart = fixture_catalogue(%{name: "Smart one", kind: "smart"})
      binned = fixture_catalogue(%{name: "Binned one"})
      {:ok, _} = Catalogue.trash_catalogue(binned)
      item = fixture_item(%{catalogue_uuid: here.uuid, name: "Stays"})
      {:ok, view, _html} = live(conn, "#{@base}/#{here.uuid}")

      html = render_click(view, "request_bulk_move_items", %{"uuids" => [item.uuid]})

      assert html =~ "Here (this catalogue)"
      assert html =~ ~s(value="#{there.uuid}")
      refute html =~ ~s(value="#{smart.uuid}")
      refute html =~ ~s(value="#{binned.uuid}")

      render_click(view, "select_bulk_move_catalogue", %{"catalogue_uuid" => smart.uuid})
      assert assigns(view).bulk_move_modal.target_catalogue_uuid == here.uuid
    end

    test "a destination trashed after the modal opened is refused with a message",
         %{conn: conn, here: here, there: there} do
      item = fixture_item(%{catalogue_uuid: here.uuid, name: "Stays home"})
      {:ok, view, _html} = live(conn, "#{@base}/#{here.uuid}")

      render_click(view, "request_bulk_move_items", %{"uuids" => [item.uuid]})
      pick_catalogue(view, "select_bulk_move_catalogue", there.uuid)
      {:ok, _} = Catalogue.trash_catalogue(there)

      html = confirm(view, "confirm_bulk_move_items")

      assert html =~ "Catalogue not found."
      assert Catalogue.get_item(item.uuid).catalogue_uuid == here.uuid
    end

    test "a picker event without a catalogue changes nothing", %{conn: conn, here: here} do
      item = fixture_item(%{catalogue_uuid: here.uuid, name: "Unmoved"})
      {:ok, view, _html} = live(conn, "#{@base}/#{here.uuid}")

      render_click(view, "request_bulk_move_items", %{"uuids" => [item.uuid]})
      render_change(view, "select_bulk_move_catalogue", %{})
      render_change(view, "select_bulk_move_categories_catalogue", %{})

      assert assigns(view).bulk_move_modal.target_catalogue_uuid == here.uuid
    end

    test "no catalogue picker when this is the only catalogue of its kind", %{conn: conn} do
      smart = fixture_catalogue(%{name: "Lonely smart", kind: "smart"})
      item = fixture_item(%{catalogue_uuid: smart.uuid, name: "Smart item"})
      {:ok, view, _html} = live(conn, "#{@base}/#{smart.uuid}")

      render_click(view, "request_bulk_move_items", %{"uuids" => [item.uuid]})
      refute has_element?(view, "form[phx-change=select_bulk_move_catalogue]")
    end
  end

  describe "categories" do
    test "move to the top level of another catalogue",
         %{conn: conn, here: here, there: there} do
      category = fixture_category(here, %{name: "Moving"})
      item = fixture_item(%{category_uuid: category.uuid, name: "Inside"})
      {:ok, view, _html} = live(conn, "#{@base}/#{here.uuid}")

      render_click(view, "request_bulk_move_categories", %{"uuids" => [category.uuid]})
      html = pick_catalogue(view, "select_bulk_move_categories_catalogue", there.uuid)
      assert html =~ "They sit at the root of the chosen catalogue."

      confirm(view, "confirm_bulk_move_categories")

      moved = Catalogue.get_category(category.uuid)
      assert moved.catalogue_uuid == there.uuid
      assert moved.parent_uuid == nil
      assert Catalogue.get_item(item.uuid).catalogue_uuid == there.uuid
    end

    test "nest under a category of another catalogue",
         %{conn: conn, here: here, there: there, landing: landing} do
      category = fixture_category(here, %{name: "Moving"})
      {:ok, view, _html} = live(conn, "#{@base}/#{here.uuid}")

      render_click(view, "request_bulk_move_categories", %{"uuids" => [category.uuid]})
      pick_catalogue(view, "select_bulk_move_categories_catalogue", there.uuid)

      choose(view, "set_bulk_move_categories_disposition", "move_under")

      view
      |> element("form[phx-change=select_bulk_move_categories_target]")
      |> render_change(%{"category_uuid" => landing.uuid})

      html = confirm(view, "confirm_bulk_move_categories")

      assert html =~ "Moved 1 categories."
      moved = Catalogue.get_category(category.uuid)
      assert moved.catalogue_uuid == there.uuid
      assert moved.parent_uuid == landing.uuid
    end
  end
end
