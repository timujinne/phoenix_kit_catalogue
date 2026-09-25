defmodule PhoenixKitCatalogue.Web.ItemTypeUITest do
  @moduledoc """
  The goods/service item type in the admin UI: both forms save and show
  it, the item form's "As in catalogue (…)" hint follows the catalogue
  (also when Location moves the item), the product card shows a type row
  for services only, and the "Service" badge and the "Item type" column in
  the item lists.
  """
  use PhoenixKitCatalogue.LiveCase

  alias PhoenixKit.Users.Auth
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Web.Components
  alias PhoenixKitCatalogue.Web.Components.ProductCard
  alias PhoenixKitCatalogue.Web.ViewConfig
  alias PhoenixKitWeb.Components.TreePicker

  @base "/en/admin/catalogue"

  defp form_selector, do: ~s|form[action="#"][phx-submit=save]|
  defp new_item_url(catalogue_uuid), do: "#{@base}/#{catalogue_uuid}/items/new"
  defp edit_item_url(item_uuid), do: "#{@base}/items/#{item_uuid}/edit"

  defp selected_option(html, select_id) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("select##{select_id} option[selected]")
    |> LazyHTML.attribute("value")
  end

  defp first_option_text(html, select_id) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("select##{select_id} option")
    |> Enum.map(&LazyHTML.text/1)
    |> List.first()
  end

  # The open product card only — the page itself prints "Service" in badges.
  defp card_fields(view) do
    view |> element("#catalogue-detail-product-card") |> render()
  end

  defp item_row_text(view, item) do
    view |> element("#level-items-active tr[data-id='#{item.uuid}']") |> render()
  end

  # A card carries no per-item id; find it by the name link.
  defp item_card_text(view, item) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#level-items-active [data-card-view] > div")
    |> Enum.map(&LazyHTML.text/1)
    |> Enum.find(&(&1 =~ item.name))
  end

  describe "catalogue form" do
    test "offers the default item type after Kind and saves it", %{conn: conn} do
      {:ok, view, html} = live(conn, "#{@base}/new")
      assert html =~ ~s(name="catalogue[item_type]")
      assert selected_option(html, "catalogue_item_type") == ["goods"]

      view
      |> form(form_selector(), %{
        "catalogue" => %{"name" => "Teenused", "item_type" => "service", "status" => "active"}
      })
      |> render_submit()

      assert [%{name: "Teenused", item_type: "service"}] = Catalogue.list_catalogues()
    end

    test "the edit form shows the stored type", %{conn: conn} do
      catalogue = fixture_catalogue(%{item_type: "service"})
      {:ok, _view, html} = live(conn, "#{@base}/#{catalogue.uuid}/edit")
      assert selected_option(html, "catalogue_item_type") == ["service"]
    end
  end

  describe "item form" do
    test "the type select's first option names the catalogue's type", %{conn: conn} do
      goods = fixture_catalogue()
      services = fixture_catalogue(%{item_type: "service"})

      {:ok, _view, html} = live(conn, new_item_url(goods.uuid))

      assert String.trim(first_option_text(html, "item_item_type")) ==
               "— As in catalogue (Goods) —"

      {:ok, _view, html} = live(conn, new_item_url(services.uuid))
      assert first_option_text(html, "item_item_type") =~ "As in catalogue (Service)"
    end

    test "saves an override and clears it back to the catalogue's", %{conn: conn} do
      catalogue = fixture_catalogue()
      item = fixture_item(%{name: "Paigaldus", catalogue_uuid: catalogue.uuid})
      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

      render_submit(view, "save", %{
        "item" => %{"name" => "Paigaldus", "item_type" => "service"},
        "save_action" => "stay"
      })

      assert Catalogue.get_item(item.uuid).item_type == "service"
      assert selected_option(render(view), "item_item_type") == ["service"]

      render_submit(view, "save", %{
        "item" => %{"name" => "Paigaldus", "item_type" => ""},
        "save_action" => "stay"
      })

      assert is_nil(Catalogue.get_item(item.uuid).item_type)
    end

    test "is offered for a smart catalogue's item too (outside the pricing block)", %{conn: conn} do
      smart = fixture_catalogue(%{kind: "smart"})
      {:ok, _view, html} = live(conn, new_item_url(smart.uuid))

      assert html =~ ~s(name="item[item_type]")
      refute html =~ ~s(name="item[base_price]")
    end

    test "the hint follows the catalogue picked in Location", %{conn: conn} do
      goods = fixture_catalogue()
      services = fixture_catalogue(%{item_type: "service"})
      item = fixture_item(%{catalogue_uuid: goods.uuid})

      {:ok, view, html} = live(conn, edit_item_url(item.uuid))
      assert first_option_text(html, "item_item_type") =~ "As in catalogue (Goods)"

      render_click(view, "open_location_picker", %{})
      send(view.pid, {TreePicker, "location-tree-picker", "catalogue:#{services.uuid}"})
      assert first_option_text(render(view), "item_item_type") =~ "As in catalogue (Service)"

      render_click(view, "reset_location", %{})
      assert first_option_text(render(view), "item_item_type") =~ "As in catalogue (Goods)"
    end
  end

  describe "product card" do
    test "a service gets an Item type row; goods get none", _ctx do
      services = fixture_catalogue(%{item_type: "service"})
      goods = fixture_catalogue()
      transport = fixture_item(%{name: "Transport", catalogue_uuid: services.uuid})
      panel = fixture_item(%{name: "Panel", catalogue_uuid: goods.uuid})

      # Straight from get_item/1: no catalogue preloaded, as the View
      # button and the warehouse stock page hand it over.
      bare_transport = Catalogue.get_item(transport.uuid)
      assert %Ecto.Association.NotLoaded{} = bare_transport.catalogue

      assert {"Item type", "Service"} in ProductCard.build_fields(bare_transport, "en")

      refute Enum.any?(
               ProductCard.build_fields(Catalogue.get_item(panel.uuid), "en"),
               fn {label, _} -> label == "Item type" end
             )
    end
  end

  describe "catalogue detail page" do
    setup do
      catalogue = fixture_catalogue(%{name: "Mixed"})
      shelf = fixture_category(catalogue, %{name: "Shelf"})

      service =
        fixture_item(%{
          name: "Mounting",
          catalogue_uuid: catalogue.uuid,
          category_uuid: shelf.uuid,
          item_type: "service"
        })

      goods =
        fixture_item(%{name: "Panel", catalogue_uuid: catalogue.uuid, category_uuid: shelf.uuid})

      %{catalogue: catalogue, shelf: shelf, service: service, goods: goods}
    end

    test "the View button opens a service's card with the type row", %{conn: conn} do
      # The item inherits "service" from its catalogue, so the card has to
      # look the catalogue up (the page loads the item without a preload).
      services = fixture_catalogue(%{name: "Teenused", item_type: "service"})
      visits = fixture_category(services, %{name: "Visits"})

      transport =
        fixture_item(%{
          name: "Transport",
          catalogue_uuid: services.uuid,
          category_uuid: visits.uuid
        })

      {:ok, view, _html} = live(conn, "#{@base}/#{services.uuid}?category=#{visits.uuid}")

      render_click(view, "show_product_card", %{"uuid" => transport.uuid})
      assert card_fields(view) =~ "Item type"
      assert card_fields(view) =~ "Service"
    end

    test "a goods item's card has no type row", ctx do
      {:ok, view, _html} =
        live(ctx.conn, "#{@base}/#{ctx.catalogue.uuid}?category=#{ctx.shelf.uuid}")

      render_click(view, "show_product_card", %{"uuid" => ctx.goods.uuid})
      assert card_fields(view) =~ ctx.goods.name
      refute card_fields(view) =~ "Item type"
    end

    test "the Item type column shows the effective type in the table and card views", ctx do
      user = Auth.get_user!(ctx.scope.user.uuid)
      {:ok, _} = ViewConfig.save_columns(user, :detail_items, ["sku", "item_type"])

      {:ok, view, _html} =
        ctx.conn
        |> with_scope(ctx.scope)
        |> live("#{@base}/#{ctx.catalogue.uuid}?category=#{ctx.shelf.uuid}")

      render_click(view, "set_view", %{"mode" => "table"})
      assert has_element?(view, "#level-items-active th", "Item type")
      assert item_row_text(view, ctx.goods) =~ "Goods"
      assert item_row_text(view, ctx.service) =~ "Service"

      render_click(view, "set_view", %{"mode" => "card"})
      assert item_card_text(view, ctx.goods) =~ "Item type"
      assert item_card_text(view, ctx.goods) =~ "Goods"
    end

    test "without the column, no Goods label anywhere on the goods row", ctx do
      {:ok, view, _html} =
        live(ctx.conn, "#{@base}/#{ctx.catalogue.uuid}?category=#{ctx.shelf.uuid}")

      render_click(view, "set_view", %{"mode" => "table"})
      refute has_element?(view, "#level-items-active th", "Item type")
      refute item_row_text(view, ctx.goods) =~ "Goods"
    end

    test "services carry the Service badge in the table and card views, goods don't", ctx do
      {:ok, view, _html} =
        live(ctx.conn, "#{@base}/#{ctx.catalogue.uuid}?category=#{ctx.shelf.uuid}")

      for mode <- ~w(table card) do
        render_click(view, "set_view", %{"mode" => mode})
        assert has_element?(view, "[data-item-type-badge='#{ctx.service.uuid}']"), mode
        refute has_element?(view, "[data-item-type-badge='#{ctx.goods.uuid}']"), mode
      end
    end
  end

  describe "item_table/1" do
    setup do
      services = fixture_catalogue(%{item_type: "service"})
      goods = fixture_catalogue()

      [transport] =
        Catalogue.list_items_by_uuids([fixture_item(%{catalogue_uuid: services.uuid}).uuid])

      [panel] = Catalogue.list_items_by_uuids([fixture_item(%{catalogue_uuid: goods.uuid}).uuid])
      %{transport: transport, panel: panel, services: services}
    end

    test "badges services next to the status and offers an Item type column", ctx do
      html =
        render_component(&Components.item_table/1,
          items: [ctx.transport, ctx.panel],
          columns: [:name, :status, :item_type],
          cards: false
        )

      assert html =~ ~s(data-item-type-badge="#{ctx.transport.uuid}")
      refute html =~ ~s(data-item-type-badge="#{ctx.panel.uuid}")
      assert html =~ "Item type"
      assert html =~ "Goods"
    end

    test "falls back to the catalogue_item_type attr when the catalogue is not loaded", ctx do
      bare = Catalogue.get_item(ctx.transport.uuid)

      html =
        render_component(&Components.item_table/1,
          items: [bare],
          columns: [:name, :status],
          catalogue_item_type: "service",
          cards: false
        )

      assert html =~ ~s(data-item-type-badge="#{bare.uuid}")
    end

    test "party_items_table badges services from each item's own catalogue", ctx do
      html =
        render_component(&Components.party_items_table/1, %{
          items: [ctx.transport, ctx.panel],
          id: "party-items-test"
        })

      assert html =~ ~s(data-item-type-badge="#{ctx.transport.uuid}")
      refute html =~ ~s(data-item-type-badge="#{ctx.panel.uuid}")
    end
  end
end
