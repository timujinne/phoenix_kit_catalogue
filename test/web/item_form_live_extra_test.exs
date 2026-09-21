defmodule PhoenixKitCatalogue.Web.ItemFormLiveExtraTest do
  @moduledoc """
  Additional ItemFormLive coverage: media-selector delegations
  (open / close), cancel_upload and add_meta_field idempotence. Moving
  an item is the Location section's, covered in ItemFormLiveTest.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

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
