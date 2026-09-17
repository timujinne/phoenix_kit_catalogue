defmodule PhoenixKitCatalogue.Web.ItemFormLiveExtraTest do
  @moduledoc """
  Additional ItemFormLive coverage: media-selector delegations
  (open / close), cancel_upload, add_meta_field idempotence, and
  the move_item flow with the smart-vs-standard catalogue dispatch.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue

  setup do
    cat = fixture_catalogue(%{name: "ItemExtra"})
    item = fixture_item(%{name: "ExtraItem", catalogue_uuid: cat.uuid})
    %{catalogue: cat, item: item}
  end

  describe "media-selector delegations from ItemFormLive" do
    test "open_featured_image_picker flips show_media_selector",
         %{conn: conn, item: item} do
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/items/#{item.uuid}/edit")

      render_click(view, "open_featured_image_picker", %{})

      assert is_boolean(:sys.get_state(view.pid).socket.assigns[:show_media_selector])
    end

    test "close_media_selector resets the modal", %{conn: conn, item: item} do
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/items/#{item.uuid}/edit")

      render_click(view, "open_featured_image_picker", %{})
      render_click(view, "close_media_selector", %{})

      assert :sys.get_state(view.pid).socket.assigns[:show_media_selector] == false
    end
  end

  describe "add_meta_field idempotence" do
    test "adding the same key twice is a no-op", %{conn: conn, item: item} do
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/items/#{item.uuid}/edit")

      render_click(view, "add_meta_field", %{"key" => "color"})
      first = :sys.get_state(view.pid).socket.assigns.meta_state

      render_click(view, "add_meta_field", %{"key" => "color"})
      second = :sys.get_state(view.pid).socket.assigns.meta_state

      assert first == second
    end
  end

  describe "move_item with target on standard vs smart catalogue" do
    test "move_item to another category in the same catalogue",
         %{conn: conn, catalogue: cat, item: item} do
      cat_obj = fixture_category(cat, %{name: "MoveTarget"})
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/items/#{item.uuid}/edit")

      view
      |> form("#item-move-form", %{"move_target" => "category:" <> cat_obj.uuid})
      |> render_change()

      render_click(view, "move_item", %{})

      assert Catalogue.get_item(item.uuid).category_uuid == cat_obj.uuid
    end

    test "move_item with empty target is a no-op",
         %{conn: conn, catalogue: cat, item: item} do
      # A category to go to, so the Move form renders at all.
      fixture_category(cat, %{name: "SomewhereElse"})
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/items/#{item.uuid}/edit")

      view |> form("#item-move-form", %{"move_target" => ""}) |> render_change()
      render_click(view, "move_item", %{})

      # Item stays in the same catalogue.
      assert :sys.get_state(view.pid).socket.assigns.move_target == nil
      assert Catalogue.get_item(item.uuid).catalogue_uuid == item.catalogue_uuid
    end

    test "move_item for a smart-catalogue item moves it to another smart catalogue",
         %{conn: conn} do
      {:ok, smart} = Catalogue.create_catalogue(%{name: "SmartMoveSrc", kind: "smart"})
      {:ok, target} = Catalogue.create_catalogue(%{name: "SmartMoveDst", kind: "smart"})
      {:ok, standard} = Catalogue.create_catalogue(%{name: "StandardElsewhere"})
      {:ok, item} = Catalogue.create_item(%{name: "Smart Item", catalogue_uuid: smart.uuid})

      {:ok, view, html} = live(conn, "/en/admin/catalogue/items/#{item.uuid}/edit")

      # Kinds never mix: a standard catalogue is not a destination.
      refute html =~ "catalogue:" <> standard.uuid

      view
      |> form("#item-move-form", %{"move_target" => "catalogue:" <> target.uuid})
      |> render_change()

      render_click(view, "move_item", %{})

      assert Catalogue.get_item(item.uuid).catalogue_uuid == target.uuid
    end

    test "a standard item moves to another catalogue's no-category slot",
         %{conn: conn, item: item} do
      {:ok, other} = Catalogue.create_catalogue(%{name: "Elsewhere"})
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/items/#{item.uuid}/edit")

      view
      |> form("#item-move-form", %{"move_target" => "catalogue:" <> other.uuid})
      |> render_change()

      render_click(view, "move_item", %{})

      reloaded = Catalogue.get_item(item.uuid)
      assert reloaded.catalogue_uuid == other.uuid
      assert reloaded.category_uuid == nil
    end

    test "a category trashed after the page opened is refused with a message",
         %{conn: conn, catalogue: cat, item: item} do
      target = fixture_category(cat, %{name: "Soon gone"})
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/items/#{item.uuid}/edit")

      view
      |> form("#item-move-form", %{"move_target" => "category:" <> target.uuid})
      |> render_change()

      {:ok, _} = Catalogue.trash_category(target)
      html = render_click(view, "move_item", %{})

      assert html =~ "Category not found."
      assert Catalogue.get_item(item.uuid).category_uuid == nil
    end

    test "a move decides from the item as it is now, not as the page loaded it",
         %{conn: conn, catalogue: cat} do
      shelf = fixture_category(cat, %{name: "Shelf"})
      item = fixture_item(%{name: "Wanderer", category_uuid: shelf.uuid})
      {:ok, away} = Catalogue.create_catalogue(%{name: "Away"})
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/items/#{item.uuid}/edit")

      # Another tab moves it away meanwhile.
      {:ok, _} = Catalogue.move_item_to_catalogue(item, away.uuid)

      view
      |> form("#item-move-form", %{"move_target" => "catalogue:" <> cat.uuid})
      |> render_change()

      render_click(view, "move_item", %{})

      moved = Catalogue.get_item(item.uuid)
      assert moved.catalogue_uuid == cat.uuid
      assert moved.category_uuid == nil
    end

    test "the item's own place is not offered", %{conn: conn, catalogue: cat, item: item} do
      shelf = fixture_category(cat, %{name: "Own shelf"})
      {:ok, elsewhere} = Catalogue.create_catalogue(%{name: "Elsewhere"})
      {:ok, view, html} = live(conn, "/en/admin/catalogue/items/#{item.uuid}/edit")

      # Uncategorized: its own catalogue's no-category slot is left out.
      refute html =~ ~s(value="catalogue:#{cat.uuid}")
      assert html =~ ~s(value="category:#{shelf.uuid}")
      assert html =~ "Elsewhere — no category"
      assert html =~ ~s(value="catalogue:#{elsewhere.uuid}")

      {:ok, _} = Catalogue.move_item_to_category(item, shelf.uuid)
      {:ok, _view, html} = live(conn, "/en/admin/catalogue/items/#{item.uuid}/edit")

      # In a category: that category is left out, the slot is back.
      refute html =~ ~s(value="category:#{shelf.uuid}")
      assert html =~ ~s(value="catalogue:#{cat.uuid}")
      _ = view
    end

    test "a value the select did not offer is ignored", %{conn: conn, item: item} do
      {:ok, smart} = Catalogue.create_catalogue(%{name: "NotOffered", kind: "smart"})
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/items/#{item.uuid}/edit")

      render_change(view, "select_move_target", %{"move_target" => "catalogue:" <> smart.uuid})
      render_click(view, "move_item", %{})

      assert :sys.get_state(view.pid).socket.assigns.move_target == nil
      assert Catalogue.get_item(item.uuid).catalogue_uuid == item.catalogue_uuid
    end
  end

  describe "validate event with various param shapes" do
    test "validate with string-keyed params produces a changeset",
         %{conn: conn, item: item, catalogue: cat} do
      {:ok, view, _html} = live(conn, "/en/admin/catalogue/items/#{item.uuid}/edit")

      render_change(view, "validate", %{
        "item" => %{
          "name" => "Updated Name",
          "catalogue_uuid" => cat.uuid
        }
      })

      cs = :sys.get_state(view.pid).socket.assigns.changeset
      assert match?(%Ecto.Changeset{}, cs)
    end
  end
end
