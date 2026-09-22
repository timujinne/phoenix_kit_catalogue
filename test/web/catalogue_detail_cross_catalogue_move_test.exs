defmodule PhoenixKitCatalogue.Web.CatalogueDetailCrossCatalogueMoveTest do
  @moduledoc """
  The detail page's bulk Move modals reach other catalogues through one
  tree of every live catalogue of this one's kind (boss via Max,
  2026-09-21: proper pickers, no flat lists) — a catalogue's own row is
  uncategorized there (items) or its top level (categories), a category
  row is into it. Picks go through the real rows; a row the tree does not
  offer is ignored.
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

  defp confirm(view, event) do
    view
    |> element(~s(button[phx-click="#{event}"]))
    |> render_click()
  end

  defp open(view, picker, id) do
    view
    |> element(~s(##{picker} button[phx-click=toggle][phx-value-id="#{id}"]))
    |> render_click()
  end

  defp pick(view, picker, id),
    do: view |> element(~s(##{picker} [data-place="#{id}"])) |> render_click()

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
      open(view, "bulk-move-items-picker", "catalogue:" <> there.uuid)
      pick(view, "bulk-move-items-picker", "category:" <> landing.uuid)

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
      html = pick(view, "bulk-move-items-picker", "catalogue:" <> there.uuid)
      assert html =~ "There"
      assert view |> element("#bulk-move-items-destination") |> render() =~ "uncategorized"

      CataloguePubSub.subscribe()
      confirm(view, "confirm_bulk_move_items")

      # The page tells the destination; the context call itself is muted.
      there_uuid = there.uuid
      assert_receive {:catalogue_data_changed, :item, nil, ^there_uuid}

      moved = Catalogue.get_item(item.uuid)
      assert moved.catalogue_uuid == there.uuid
      assert moved.category_uuid == nil
    end

    test "a new pick replaces the old one, in any catalogue",
         %{conn: conn, here: here, there: there, landing: landing} do
      home_category = fixture_category(here, %{name: "Home category"})
      item = fixture_item(%{catalogue_uuid: here.uuid, name: "Traveller"})
      {:ok, view, _html} = live(conn, "#{@base}/#{here.uuid}")

      render_click(view, "request_bulk_move_items", %{"uuids" => [item.uuid]})
      pick(view, "bulk-move-items-picker", "category:" <> home_category.uuid)
      assert assigns(view).bulk_move_modal.target == "category:" <> home_category.uuid

      open(view, "bulk-move-items-picker", "catalogue:" <> there.uuid)
      pick(view, "bulk-move-items-picker", "category:" <> landing.uuid)
      assert assigns(view).bulk_move_modal.target == "category:" <> landing.uuid
    end

    test "only live catalogues of this kind are offered; others are ignored",
         %{conn: conn, here: here, there: there} do
      smart = fixture_catalogue(%{name: "Smart one", kind: "smart"})
      binned = fixture_catalogue(%{name: "Binned one"})
      {:ok, _} = Catalogue.trash_catalogue(binned)
      item = fixture_item(%{catalogue_uuid: here.uuid, name: "Stays"})
      {:ok, view, _html} = live(conn, "#{@base}/#{here.uuid}")

      render_click(view, "request_bulk_move_items", %{"uuids" => [item.uuid]})
      html = view |> element("#bulk-move-items-picker") |> render()

      assert html =~ ~s(data-place="catalogue:#{here.uuid}")
      assert html =~ "Current"
      assert html =~ ~s(data-place="catalogue:#{there.uuid}")
      refute html =~ smart.uuid
      refute html =~ binned.uuid

      view
      |> with_target("#bulk-move-items-picker")
      |> render_click("pick", %{"id" => "catalogue:" <> smart.uuid})

      assert assigns(view).bulk_move_modal.target == nil
    end

    test "a destination trashed after the modal opened is refused with a message",
         %{conn: conn, here: here, there: there} do
      item = fixture_item(%{catalogue_uuid: here.uuid, name: "Stays home"})
      {:ok, view, _html} = live(conn, "#{@base}/#{here.uuid}")

      render_click(view, "request_bulk_move_items", %{"uuids" => [item.uuid]})
      pick(view, "bulk-move-items-picker", "catalogue:" <> there.uuid)
      {:ok, _} = Catalogue.trash_catalogue(there)

      html = confirm(view, "confirm_bulk_move_items")

      assert html =~ "Catalogue not found."
      assert Catalogue.get_item(item.uuid).catalogue_uuid == here.uuid
    end

    test "a pick after the modal closed changes nothing", %{conn: conn, here: here} do
      item = fixture_item(%{catalogue_uuid: here.uuid, name: "Unmoved"})
      {:ok, view, _html} = live(conn, "#{@base}/#{here.uuid}")

      render_click(view, "request_bulk_move_items", %{"uuids" => [item.uuid]})
      render_click(view, "cancel_bulk_move", %{})

      send(
        view.pid,
        {PhoenixKitCatalogue.Web.Components.PlacePicker, "bulk-move-items-picker",
         "catalogue:" <> here.uuid}
      )

      render_click(view, "confirm_bulk_move_items", %{})

      assert assigns(view).bulk_move_modal == nil
      assert Catalogue.get_item(item.uuid).catalogue_uuid == here.uuid
    end

    test "the only catalogue of its kind offers just itself", %{conn: conn} do
      smart = fixture_catalogue(%{name: "Lonely smart", kind: "smart"})
      item = fixture_item(%{catalogue_uuid: smart.uuid, name: "Smart item"})
      {:ok, view, _html} = live(conn, "#{@base}/#{smart.uuid}")

      render_click(view, "request_bulk_move_items", %{"uuids" => [item.uuid]})

      assert [%{id: id}] = assigns(view).bulk_move_modal.tree
      assert id == "catalogue:" <> smart.uuid
    end
  end

  describe "categories" do
    test "move to the top level of another catalogue",
         %{conn: conn, here: here, there: there} do
      category = fixture_category(here, %{name: "Moving"})
      item = fixture_item(%{category_uuid: category.uuid, name: "Inside"})
      {:ok, view, _html} = live(conn, "#{@base}/#{here.uuid}")

      render_click(view, "request_bulk_move_categories", %{"uuids" => [category.uuid]})
      pick(view, "bulk-move-categories-picker", "catalogue:" <> there.uuid)

      assert view |> element("#bulk-move-categories-destination") |> render() =~ "top level"

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
      open(view, "bulk-move-categories-picker", "catalogue:" <> there.uuid)
      pick(view, "bulk-move-categories-picker", "category:" <> landing.uuid)

      html = confirm(view, "confirm_bulk_move_categories")

      assert html =~ "Moved 1 categories."
      moved = Catalogue.get_category(category.uuid)
      assert moved.catalogue_uuid == there.uuid
      assert moved.parent_uuid == landing.uuid
    end
  end
end
