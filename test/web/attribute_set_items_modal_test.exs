defmodule PhoenixKitCatalogue.Web.AttributeSetItemsModalTest do
  @moduledoc """
  The set-items popup (2026-08-28: the Items COUNT is the button; the
  preview is a popup, not a page): opening from the listing, the row
  contents (name link, per-item SELECTED values), server-side trimmed
  search, 25/page, deleted-item exclusion, and closing.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets

  if Code.ensure_loaded?(PhoenixKitEntities.Managed) do
    setup %{conn: conn, scope: scope} do
      AttributeSets.register_deletion_guard()
      PhoenixKit.Settings.update_setting("entities_enabled", "true")
      on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)

      %{conn: with_scope(conn, scope)}
    end

    defp modal_id(set), do: "attr-set-items-modal-#{set.uuid}"

    test "count opens the popup: rows with SELECTED labels, item links", %{conn: conn} do
      {:ok, set} = Catalogue.create_attribute_set(%{name: "Popup colors"})
      {:ok, red} = Catalogue.create_attribute_set_value(set, %{label: "Red"})
      {:ok, _blue} = Catalogue.create_attribute_set_value(set, %{label: "Blue"})

      item = fixture_item(%{name: "Popup door"})
      {:ok, _} = Catalogue.attach_attribute_set(item.uuid, set.uuid)
      :ok = AttributeSets.set_attachment_selection(item.uuid, set.uuid, [red.slug])

      {:ok, view, html} = live(conn, "/en/admin/catalogue/attributes")

      # The listing shows the COUNT, not item names.
      refute html =~ "Popup door"
      refute has_element?(view, modal_id(set) |> then(&"##{&1}"))

      html = render_click(view, "open_set_items_modal", %{"uuid" => set.uuid})
      assert html =~ "Popup door"
      # The row shows the item's OWN selection of this set…
      assert has_element?(view, "##{modal_id(set)}-item-#{item.uuid}", "Red")
      refute has_element?(view, "##{modal_id(set)}-item-#{item.uuid}", "Blue")
      # …and links to the item editor.
      assert has_element?(
               view,
               ~s|##{modal_id(set)} a[href$="/items/#{item.uuid}/edit"]|,
               "Popup door"
             )
    end

    test "popup search is server-side and trailing-space tolerant", %{conn: conn} do
      {:ok, set} = Catalogue.create_attribute_set(%{name: "Popup search"})
      hit = fixture_item(%{name: "Walnut door"})
      miss = fixture_item(%{name: "Steel frame"})
      {:ok, _} = Catalogue.attach_attribute_set(hit.uuid, set.uuid)
      {:ok, _} = Catalogue.attach_attribute_set(miss.uuid, set.uuid)

      {:ok, view, _html} = live(conn, "/en/admin/catalogue/attributes")
      render_click(view, "open_set_items_modal", %{"uuid" => set.uuid})

      html =
        view
        |> element("##{modal_id(set)} form")
        |> render_change(%{"q" => "Walnut "})

      assert html =~ "Walnut door"
      refute html =~ "Steel frame"

      html =
        view
        |> element("##{modal_id(set)} form")
        |> render_change(%{"q" => "zzz-nothing"})

      assert html =~ "No items match your search."
      refute html =~ "No items attached."
    end

    test "popup items paginate at 25", %{conn: conn} do
      {:ok, set} = Catalogue.create_attribute_set(%{name: "Popup paged"})

      for n <- 1..26 do
        item = fixture_item(%{name: "Paged item #{String.pad_leading("#{n}", 2, "0")}"})
        {:ok, _} = Catalogue.attach_attribute_set(item.uuid, set.uuid)
      end

      {:ok, view, _html} = live(conn, "/en/admin/catalogue/attributes")
      html = render_click(view, "open_set_items_modal", %{"uuid" => set.uuid})

      assert html =~ "Paged item 01"
      refute html =~ "Paged item 26"
      assert html =~ "1 / 2"

      html =
        view
        |> element(~s|##{modal_id(set)} button[phx-value-dir="next"]|)
        |> render_click()

      assert html =~ "Paged item 26"
      refute html =~ "Paged item 01"
    end

    test "deleted items stay out; zero items means no button", %{conn: conn} do
      {:ok, set} = Catalogue.create_attribute_set(%{name: "Popup trash"})
      kept = fixture_item(%{name: "Kept item"})
      gone = fixture_item(%{name: "Trashed item"})
      {:ok, _} = Catalogue.attach_attribute_set(kept.uuid, set.uuid)
      {:ok, _} = Catalogue.attach_attribute_set(gone.uuid, set.uuid)
      {:ok, _} = Catalogue.trash_item(gone)

      {:ok, empty} = Catalogue.create_attribute_set(%{name: "Popup empty"})

      {:ok, view, html} = live(conn, "/en/admin/catalogue/attributes")

      # An unattached set renders a bare muted 0, not a dead button
      # (Max, 2026-08-28).
      refute html =~ "No items attached."

      refute has_element?(
               view,
               ~s|button[phx-click="open_set_items_modal"][phx-value-uuid="#{empty.uuid}"]|
             )

      html = render_click(view, "open_set_items_modal", %{"uuid" => set.uuid})
      assert html =~ "Kept item"
      refute html =~ "Trashed item"
    end

    test "closing unmounts the popup; reopening starts fresh", %{conn: conn} do
      {:ok, set} = Catalogue.create_attribute_set(%{name: "Popup close"})
      item = fixture_item(%{name: "Close item"})
      {:ok, _} = Catalogue.attach_attribute_set(item.uuid, set.uuid)

      {:ok, view, _html} = live(conn, "/en/admin/catalogue/attributes")
      render_click(view, "open_set_items_modal", %{"uuid" => set.uuid})

      view
      |> element("##{modal_id(set)} form")
      |> render_change(%{"q" => "zzz-nothing"})

      view
      |> element(~s|##{modal_id(set)} button.btn-circle[phx-click="close"]|)
      |> render_click()

      refute has_element?(view, "##{modal_id(set)}")

      # Fresh mount on reopen: the stale search is gone (the
      # media-selector trap).
      html = render_click(view, "open_set_items_modal", %{"uuid" => set.uuid})
      assert html =~ "Close item"
    end
  end
end
