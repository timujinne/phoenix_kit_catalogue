defmodule PhoenixKitCatalogue.Web.CardStyleTest do
  @moduledoc """
  Cards look the same wherever they appear (boss via Max, 2026-08-28: use
  the categories style, where the picture is part of the card). Every card
  face in the module leads with the shared media band — item cards used to
  wedge a 48px thumb beside the title, catalogue cards the same, so the
  same product read as a different kind of thing per page.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Web.Components

  setup %{conn: conn, scope: scope} do
    catalogue = fixture_catalogue(%{name: "Card Style Cat"})

    {:ok, category} =
      PhoenixKitCatalogue.Catalogue.create_category(%{
        name: "Card Cat",
        catalogue_uuid: catalogue.uuid
      })

    item =
      fixture_item(%{
        name: "Card Item",
        catalogue_uuid: catalogue.uuid,
        category_uuid: category.uuid
      })

    %{conn: with_scope(conn, scope), catalogue: catalogue, category: category, item: item}
  end

  test "one band definition, so pages cannot drift apart" do
    # The frame lives in exactly one place; every card face passes it.
    # Taller since 2026-08-29 (Max: more height, crop less).
    assert Components.card_media_band() =~ "h-40"
    assert Components.card_media_band() =~ "bg-base-200"
    assert Components.card_media_frame() == %{card_media_class: Components.card_media_band()}
  end

  test "card images fill their band — no comfy row-override, full-width click wrapper" do
    # In comfy density the row override ([.pk-comfy_&]:w-18) beat w-full
    # inside cards and shrank the band image to a 72px square; the
    # on_click button wrapper also shrink-wrapped it (the not-full-width
    # report, 2026-08-29). Fill slots opt out via comfy_scale={false}.
    uuid = UUIDv7.generate()

    resource = %{
      uuid: UUIDv7.generate(),
      data: {"featured_image_uuid", uuid} |> then(fn {k, v} -> %{k => v} end)
    }

    html =
      render_component(&Components.featured_thumb/1,
        resource: resource,
        class: "w-full h-full",
        variant: "medium",
        comfy_scale: false,
        on_click: "show_product_card",
        has_files: false
      )

    refute html =~ "pk-comfy"
    assert html =~ ~s(class="shrink-0 cursor-pointer block w-full h-full")
    assert html =~ "/medium/"

    # Table cells keep the comfy enlargement.
    row_html =
      render_component(&Components.featured_thumb/1, resource: resource, has_files: false)

    assert row_html =~ "pk-comfy"
  end

  test "item cards lead with the picture", %{conn: conn, catalogue: catalogue, category: category} do
    {:ok, view, _html} =
      live(conn, "/en/admin/catalogue/#{catalogue.uuid}?category=#{category.uuid}&mode=items")

    html = render(view)

    # The framed figure, and a placeholder for an item with no photo — so
    # a card without a picture keeps the same shape as one with.
    assert html =~ Components.card_media_band()
    assert html =~ "hero-photo"
  end

  test "catalogue cards lead with the picture too", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/catalogue")
    render_click(view, "set_view", %{"mode" => "card"})

    html = render(view)
    assert html =~ Components.card_media_band()
    # Containers get a container placeholder, not a photo icon.
    assert html =~ "hero-book-open"
  end
end
