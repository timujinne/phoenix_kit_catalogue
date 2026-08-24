defmodule PhoenixKitCatalogue.Web.ItemFormSupplierCommentsTest do
  @moduledoc """
  The supplier-comments modal on the item form, driven through the REAL
  `PhoenixKitComments.Web.CommentsComponent` (comments is a test-only dep
  here). Pins the owner's rule — a comment left on an attached supplier is
  about that supplier for THIS item, filed under its own thread and never
  on the CRM company — plus the `{:leaf_changed, …}` hop the host forwards
  at runtime (without it "Post comment" silently no-ops).
  """

  use PhoenixKitCatalogue.LiveCase

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.ItemSupplierInfos

  @type_ "catalogue_item_supplier"

  defp edit_item_url(item_uuid), do: "/en/admin/catalogue/items/#{item_uuid}/edit"

  defp item_with_supplier do
    item =
      fixture_item(%{
        name: "Oak Panel",
        category_uuid: fixture_category(fixture_catalogue()).uuid
      })

    supplier = fixture_supplier(%{name: "Acme Metals"})

    {:ok, info} =
      Catalogue.create_supplier_info(%{
        "item_uuid" => item.uuid,
        "supplier_uuid" => supplier.uuid,
        "supplier_source" => "local",
        "supplier_name_snapshot" => supplier.name,
        "unit_cost" => "10.00"
      })

    {item, supplier, info}
  end

  # The composer opens on a click (the component keeps it collapsed until
  # then), and content reaches CommentsComponent the way the rich-text
  # editor delivers it in production: Leaf reports to the HOST LiveView,
  # which forwards it into the component. The editor id is the component id
  # plus the draft composer's position.
  defp type_and_post(view, thread, text) do
    view
    |> element("#supplier-comments-modal button[phx-click=open_composer]")
    |> render_click()

    send(
      view.pid,
      {:leaf_changed,
       %{editor_id: "pk-comments:supplier-comments-#{thread}:draft:top", markdown: text}}
    )

    # With Leaf as the editor the form carries no `comment` field of its
    # own — the submit reads what the hop above delivered.
    view
    |> form("#supplier-comments-modal form[phx-submit=add_comment]")
    |> render_submit()
  end

  describe "with comments disabled" do
    test "no Comments action and no preview", %{conn: conn, scope: scope} do
      # Settings are cached in-process; an earlier test may have enabled it.
      {:ok, _} = PhoenixKitComments.disable_system()
      {item, _supplier, _info} = item_with_supplier()

      {:ok, view, _html} =
        conn |> with_scope(scope) |> live(edit_item_url(item.uuid) <> "?tab=sourcing")

      refute has_element?(view, "[phx-click=open_supplier_comments]")
      refute render(view) =~ "No comments yet."
    end
  end

  describe "with comments enabled" do
    setup do
      {:ok, _} = PhoenixKitComments.enable_system()
      :ok
    end

    test "?tab=sourcing opens the Suppliers tab; anything else is the default", %{
      conn: conn,
      scope: scope
    } do
      {item, _supplier, _info} = item_with_supplier()

      {:ok, view, _} =
        conn |> with_scope(scope) |> live(edit_item_url(item.uuid) <> "?tab=sourcing")

      assert has_element?(view, "button[phx-value-tab=sourcing].tab-active")

      {:ok, view, _} =
        conn |> with_scope(scope) |> live(edit_item_url(item.uuid) <> "?tab=garbage")

      assert has_element?(view, "button[phx-value-tab=details].tab-active")
    end

    test "a LOCAL supplier (no CRM company) gets the Comments action and an empty preview",
         %{conn: conn, scope: scope} do
      {item, _supplier, info} = item_with_supplier()

      {:ok, view, html} =
        conn |> with_scope(scope) |> live(edit_item_url(item.uuid) <> "?tab=sourcing")

      assert has_element?(
               view,
               "[phx-click=open_supplier_comments][phx-value-uuid='#{info.uuid}']"
             )

      assert html =~ "No comments yet."
    end

    test "a comment posted from the row lands on the row's own thread, not on any company",
         %{conn: conn, scope: scope} do
      {item, supplier, info} = item_with_supplier()
      thread = Catalogue.supplier_comment_thread_uuid(info)

      {:ok, view, _} =
        conn |> with_scope(scope) |> live(edit_item_url(item.uuid) <> "?tab=sourcing")

      html = render_click(view, "open_supplier_comments", %{"uuid" => info.uuid})
      assert html =~ "About this supplier for this item only."
      assert html =~ "Acme Metals"
      # A local row has no company page to offer.
      refute html =~ "Open the company"
      assert has_element?(view, "#supplier-comments-modal button[phx-click=open_composer]")

      type_and_post(view, thread, "Promised 10% off for this product only")

      assert [comment] = PhoenixKitComments.list_comments(@type_, thread)
      assert comment.content =~ "Promised 10% off"
      assert comment.resource_type == @type_
      assert comment.resource_uuid == thread
      # Nothing was written against the supplier as a company-shaped record.
      assert PhoenixKitComments.count_comments("crm_company", supplier.uuid) == 0
      assert PhoenixKitComments.count_comments("crm_company", info.uuid) == 0

      # The component tells its host, and the inline preview refreshes.
      assert render(view) =~ "Promised 10% off for this product only"
    end

    test "the thread — and its comments — survive a price revision", %{conn: conn, scope: scope} do
      {item, _supplier, info} = item_with_supplier()
      thread = Catalogue.supplier_comment_thread_uuid(info)

      {:ok, view, _} =
        conn |> with_scope(scope) |> live(edit_item_url(item.uuid) <> "?tab=sourcing")

      render_click(view, "open_supplier_comments", %{"uuid" => info.uuid})
      type_and_post(view, thread, "Discount promised on the first batch")
      render_click(view, "close_supplier_comments", %{})

      {:ok, successor} = ItemSupplierInfos.revise_unit_cost(info, Decimal.new("12.00"))
      refute successor.uuid == info.uuid

      # A fresh mount sees the successor row carrying the same thread.
      {:ok, view, html} =
        conn |> with_scope(scope) |> live(edit_item_url(item.uuid) <> "?tab=sourcing")

      assert html =~ "Discount promised on the first batch"

      assert has_element?(
               view,
               "[phx-click=open_supplier_comments][phx-value-uuid='#{successor.uuid}']"
             )

      refute has_element?(view, "[phx-value-uuid='#{info.uuid}']")
    end

    # The CRM link goes through <.pk_link navigate>, which prefixes the path
    # itself — CRM's prefixed helper produced /phoenix_kit/en/phoenix_kit/en/…
    # on max-dev. The test router is mounted at "/", so a doubled prefix
    # would show up as a doubled "/en" or "/admin" segment.
    test "the supplier name and the modal's company link carry ONE url prefix",
         %{conn: conn, scope: scope} do
      item =
        fixture_item(%{
          name: "Oak Panel",
          category_uuid: fixture_category(fixture_catalogue()).uuid
        })

      company_uuid = UUIDv7.generate()

      {:ok, info} =
        Catalogue.create_supplier_info(%{
          "item_uuid" => item.uuid,
          "supplier_uuid" => company_uuid,
          "supplier_source" => "crm_company",
          "supplier_name_snapshot" => "Baltic Timber",
          "unit_cost" => "10.00"
        })

      {:ok, view, html} =
        conn |> with_scope(scope) |> live(edit_item_url(item.uuid) <> "?tab=sourcing")

      expected = Routes.path("/admin/crm/companies/#{company_uuid}")
      assert html =~ ~s(href="#{expected}")
      refute html =~ ~r{href="[^"]*/admin/crm/companies/[^"]*/admin/crm/companies/}
      refute html =~ ~r{href="/[^"]*?(/en/)[^"]*\1}

      html = render_click(view, "open_supplier_comments", %{"uuid" => info.uuid})
      assert html =~ "Open the company"
      assert html =~ ~s(href="#{expected}")
    end

    test "the modal opens only rows this item renders, resolved server-side",
         %{conn: conn, scope: scope} do
      {item, _supplier, _info} = item_with_supplier()
      {_other_item, _other_supplier, other_info} = item_with_supplier()

      {:ok, view, _} =
        conn |> with_scope(scope) |> live(edit_item_url(item.uuid) <> "?tab=sourcing")

      render_click(view, "open_supplier_comments", %{"uuid" => other_info.uuid})
      refute has_element?(view, "#supplier-comments-modal")

      render_click(view, "open_supplier_comments", %{"uuid" => UUIDv7.generate()})
      refute has_element?(view, "#supplier-comments-modal")
    end

    test "a comments update for a thread that is not on the item is ignored, not a crash",
         %{conn: conn, scope: scope} do
      {item, _supplier, _info} = item_with_supplier()

      {:ok, view, _} =
        conn |> with_scope(scope) |> live(edit_item_url(item.uuid) <> "?tab=sourcing")

      send(
        view.pid,
        {:comments_updated,
         %{resource_type: @type_, resource_uuid: UUIDv7.generate(), action: :created}}
      )

      assert render(view) =~ "Acme Metals"
    end
  end
end
