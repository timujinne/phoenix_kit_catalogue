defmodule PhoenixKitCatalogue.Web.CatalogueDetailImageColumnTest do
  @moduledoc """
  The managed "Image" column (`TableConfig.columns/1`'s `"image"` id,
  off by default) on the catalogue detail page's item and category
  tables — a plain opt-in twin of the automatic photo column
  (`any_media_thumb?/2` / `featured_thumb/1`) that an admin turns on
  through the Columns modal like any other field.
  """
  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue

  @base "/en/admin/catalogue"

  defp url(uuid), do: "#{@base}/#{uuid}"

  test "the Image column is offered in the Columns modal but off by default", %{conn: conn} do
    catalogue = fixture_catalogue(%{name: "Img cols"})
    fixture_item(%{name: "Widget", catalogue_uuid: catalogue.uuid})

    {:ok, view, html} = live(conn, url(catalogue.uuid) <> "?mode=items")
    refute html =~ ~s(phx-value-column_id="image")

    opened = render_click(view, "show_column_modal", %{})
    assert opened =~ ~s(phx-value-column_id="image")
    assert opened =~ ~s(phx-value-scope="detail_items")
  end

  test "adding it renders the item's featured image via the small storage variant",
       %{conn: conn} do
    catalogue = fixture_catalogue(%{name: "Img item"})

    item =
      fixture_item(%{name: "Widget", catalogue_uuid: catalogue.uuid})

    {:ok, item} =
      Catalogue.update_item(item, %{data: %{"featured_image_uuid" => UUIDv7.generate()}})

    {:ok, view, _html} = live(conn, url(catalogue.uuid) <> "?mode=items")
    render_click(view, "show_column_modal", %{})

    updated =
      render_click(view, "add_column", %{"column_id" => "image", "scope" => "detail_items"})

    assert updated =~ "/small/"
    assert updated =~ item.data["featured_image_uuid"]
  end

  test "an item with no featured image renders empty space, not a broken image", %{conn: conn} do
    catalogue = fixture_catalogue(%{name: "Img item empty"})
    fixture_item(%{name: "Widget", catalogue_uuid: catalogue.uuid})

    {:ok, view, _html} = live(conn, url(catalogue.uuid) <> "?mode=items")
    render_click(view, "show_column_modal", %{})

    updated =
      render_click(view, "add_column", %{"column_id" => "image", "scope" => "detail_items"})

    assert updated =~ "Widget"
    refute updated =~ "/small/"
  end

  test "adding it renders the category's featured image via the small storage variant",
       %{conn: conn} do
    catalogue = fixture_catalogue(%{name: "Img category"})
    category = fixture_category(catalogue, %{name: "Configurable"})

    {:ok, category} =
      Catalogue.update_category(category, %{
        data: %{"featured_image_uuid" => UUIDv7.generate()}
      })

    {:ok, view, _html} = live(conn, url(catalogue.uuid))
    render_click(view, "show_column_modal", %{})

    updated =
      render_click(view, "add_column", %{
        "column_id" => "image",
        "scope" => "detail_categories"
      })

    assert updated =~ "/small/"
    assert updated =~ category.data["featured_image_uuid"]
  end

  describe "the managed Image column and the automatic photo column never both show the same picture" do
    # `URLSigner.signed_url/2` embeds the storage variant in the path
    # (`/file/{uuid}/{variant}/{token}`) — the automatic column always
    # requests `"thumbnail"` (`featured_thumb/1`'s default), the
    # managed column always `"small"` (`image_column_cell/1`), so the
    # two are distinguishable in rendered HTML by variant alone.

    test "column off: the automatic photo column shows the item's image once", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Img no-dup off items"})
      item = fixture_item(%{name: "Widget", catalogue_uuid: catalogue.uuid})

      {:ok, item} =
        Catalogue.update_item(item, %{data: %{"featured_image_uuid" => UUIDv7.generate()}})

      uuid = item.data["featured_image_uuid"]

      {:ok, _view, html} = live(conn, url(catalogue.uuid) <> "?mode=items")

      assert (html |> String.split("/thumbnail/") |> length()) - 1 == 1
      assert html =~ uuid
      refute html =~ "/small/"
    end

    test "column on: the managed column shows the item's image once per view, the automatic column is gone",
         %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Img no-dup on items"})
      item = fixture_item(%{name: "Widget", catalogue_uuid: catalogue.uuid})

      {:ok, item} =
        Catalogue.update_item(item, %{data: %{"featured_image_uuid" => UUIDv7.generate()}})

      uuid = item.data["featured_image_uuid"]

      {:ok, view, _html} = live(conn, url(catalogue.uuid) <> "?mode=items")
      render_click(view, "show_column_modal", %{})

      updated =
        render_click(view, "add_column", %{"column_id" => "image", "scope" => "detail_items"})

      # Once, not twice: the desktop table cell renders the managed
      # column; the mobile card's own facts grid skips "image" as a
      # no-op (its media band above already shows this same picture at
      # the "medium" variant — see components.ex's `item_card`/
      # `category_card` "image" clause) rather than showing it a
      # second time via the "small" variant down in the facts grid.
      assert (updated |> String.split("/file/#{uuid}/small/") |> length()) - 1 == 1
      refute updated =~ "/file/#{uuid}/thumbnail/"
      # The card's own media band is untouched by this — it still shows
      # the picture, just not a second time via the managed column.
      assert updated =~ "/file/#{uuid}/medium/"
    end

    test "no featured image, column off: no image is rendered for the item", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Img no-dup none-off items"})
      fixture_item(%{name: "Widget", catalogue_uuid: catalogue.uuid})

      {:ok, _view, html} = live(conn, url(catalogue.uuid) <> "?mode=items")

      refute html =~ "/thumbnail/"
      refute html =~ "/small/"
    end

    test "no featured image, column on: no image is rendered for the item", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Img no-dup none-on items"})
      fixture_item(%{name: "Widget", catalogue_uuid: catalogue.uuid})

      {:ok, view, _html} = live(conn, url(catalogue.uuid) <> "?mode=items")
      render_click(view, "show_column_modal", %{})

      updated =
        render_click(view, "add_column", %{"column_id" => "image", "scope" => "detail_items"})

      assert updated =~ "Widget"
      refute updated =~ "/thumbnail/"
      refute updated =~ "/small/"
    end

    test "column off: the automatic photo column shows the category's image once", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Img no-dup off categories"})
      category = fixture_category(catalogue, %{name: "Configurable"})

      {:ok, category} =
        Catalogue.update_category(category, %{
          data: %{"featured_image_uuid" => UUIDv7.generate()}
        })

      uuid = category.data["featured_image_uuid"]

      {:ok, _view, html} = live(conn, url(catalogue.uuid))

      assert (html |> String.split("/thumbnail/") |> length()) - 1 == 1
      assert html =~ uuid
      refute html =~ "/small/"
    end

    test "column on: the managed column shows the category's image once per view, the automatic column is gone",
         %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Img no-dup on categories"})
      category = fixture_category(catalogue, %{name: "Configurable"})

      {:ok, category} =
        Catalogue.update_category(category, %{
          data: %{"featured_image_uuid" => UUIDv7.generate()}
        })

      uuid = category.data["featured_image_uuid"]

      {:ok, view, _html} = live(conn, url(catalogue.uuid))
      render_click(view, "show_column_modal", %{})

      updated =
        render_click(view, "add_column", %{
          "column_id" => "image",
          "scope" => "detail_categories"
        })

      # Once, not twice — see the matching comment on the items test above.
      assert (updated |> String.split("/file/#{uuid}/small/") |> length()) - 1 == 1
      refute updated =~ "/file/#{uuid}/thumbnail/"
      # The card's own media band is untouched by this — it still shows
      # the picture, just not a second time via the managed column.
      assert updated =~ "/file/#{uuid}/medium/"
    end

    test "no featured image, column off: no image is rendered for the category", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Img no-dup none-off categories"})
      fixture_category(catalogue, %{name: "Configurable"})

      {:ok, _view, html} = live(conn, url(catalogue.uuid))

      refute html =~ "/thumbnail/"
      refute html =~ "/small/"
    end

    test "no featured image, column on: no image is rendered for the category", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Img no-dup none-on categories"})
      fixture_category(catalogue, %{name: "Configurable"})

      {:ok, view, _html} = live(conn, url(catalogue.uuid))
      render_click(view, "show_column_modal", %{})

      updated =
        render_click(view, "add_column", %{
          "column_id" => "image",
          "scope" => "detail_categories"
        })

      assert updated =~ "Configurable"
      refute updated =~ "/thumbnail/"
      refute updated =~ "/small/"
    end
  end
end
