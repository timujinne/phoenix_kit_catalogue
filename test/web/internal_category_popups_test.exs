defmodule PhoenixKitCatalogue.Web.InternalCategoryPopupsTest do
  @moduledoc """
  An `internal` category in the three embeddable components: left out with
  everything under it — subcategories and their items — even where the
  host's scope names it (the real host always passes an explicit list),
  shown again with `include_internal`, and reachable "by a direct link" —
  an item already preselected stays usable, though its details stay
  closed. Also the modal's optional `show_dependencies` row, which never
  names a target the popup hides.
  """

  use PhoenixKitCatalogue.LiveCase, async: false

  alias PhoenixKitCatalogue.Catalogue

  # One catalogue: an open "Chairs" category, an internal "Nail Stock" with
  # "Roofing nails" under it, and an uncategorized item.
  setup do
    showroom = fixture_catalogue(%{name: "Showroom"})
    chairs = fixture_category(showroom, %{name: "Chairs"})

    nails =
      fixture_category(showroom, %{name: "Nail Stock", description: "Boxed nails", internal: true})

    roofing = fixture_category(showroom, %{name: "Roofing nails", parent_uuid: nails.uuid})

    chair =
      fixture_item(%{
        name: "Oak chair",
        sku: "CH-1",
        catalogue_uuid: showroom.uuid,
        category_uuid: chairs.uuid
      })

    nail =
      fixture_item(%{
        name: "Steel nail",
        sku: "NL-1",
        catalogue_uuid: showroom.uuid,
        category_uuid: nails.uuid
      })

    roof_nail =
      fixture_item(%{
        name: "Copper roof nail",
        sku: "RN-1",
        catalogue_uuid: showroom.uuid,
        category_uuid: roofing.uuid
      })

    loose = fixture_item(%{name: "Loose bracket", catalogue_uuid: showroom.uuid})

    %{
      showroom: showroom,
      chairs: chairs,
      nails: nails,
      roofing: roofing,
      chair: chair,
      nail: nail,
      roof_nail: roof_nail,
      loose: loose
    }
  end

  defp open(conn, query), do: live(conn, "/test/selector-host?#{query}")
  defp picker(view), do: with_target(view, "#picker")
  defp conn_of(%{conn: conn}), do: conn

  defp eventually(fun, tries \\ 60) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true -> Process.sleep(50) && eventually(fun, tries - 1)
    end
  end

  describe "ItemSelectorModal" do
    test "an internal category and its subtree get no tiles, and search does not reach them",
         ctx do
      {:ok, view, html} = open(conn_of(ctx), "c=#{ctx.showroom.uuid}")

      assert html =~ "Chairs"
      refute html =~ "Nail Stock"
      refute html =~ "Roofing nails"

      html = view |> picker() |> render_change("browse_search", %{"search" => "a"})
      assert html =~ "Oak chair"
      assert html =~ "Loose bracket"
      refute html =~ "Steel nail"
      refute html =~ "Copper roof nail"
    end

    test "a crafted drill into a hidden category lists nothing from it", ctx do
      {:ok, view, _html} = open(conn_of(ctx), "c=#{ctx.showroom.uuid}")

      html = view |> picker() |> render_click("browse_category", %{"uuid" => ctx.roofing.uuid})
      refute html =~ "Copper roof nail"
    end

    test "a scope of only an internal category says there is nothing to choose", ctx do
      {:ok, _view, html} = open(conn_of(ctx), "cat_scope=#{ctx.nails.uuid}")

      refute html =~ "Steel nail"
      refute html =~ "Copper roof nail"
      # Neither the tree nor the header names it.
      refute html =~ "Boxed nails"
      assert html =~ "There is nothing to choose from here."
    end

    test "include_internal shows them again", ctx do
      {:ok, view, html} = open(conn_of(ctx), "c=#{ctx.showroom.uuid}&ii=true")
      assert html =~ "Nail Stock"

      html = view |> picker() |> render_change("browse_search", %{"search" => "nail"})
      assert html =~ "Steel nail"
      assert html =~ "Copper roof nail"

      {:ok, _view, html} = open(conn_of(ctx), "cat_scope=#{ctx.nails.uuid}&ii=true")
      refute html =~ "There is nothing to choose from here."
    end

    test "an item already linked (preselected) stays usable, its details stay closed", ctx do
      {:ok, view, _html} =
        open(conn_of(ctx), "c=#{ctx.showroom.uuid}&pre=#{ctx.roof_nail.uuid}:3")

      view |> picker() |> render_click("show_detail", %{"uuid" => ctx.roof_nail.uuid})
      refute has_element?(view, "#picker-detail-card")

      view |> picker() |> render_click("confirm", %{})
      assert has_element?(view, "#pick-#{ctx.roof_nail.uuid}", "qty=3")

      {:ok, view, _html} =
        open(conn_of(ctx), "c=#{ctx.showroom.uuid}&pre=#{ctx.roof_nail.uuid}:3&ii=true")

      view |> picker() |> render_click("show_detail", %{"uuid" => ctx.roof_nail.uuid})
      assert has_element?(view, "#picker-detail-card")
    end

    test "a category becoming internal while open takes it out: tile, items, details", ctx do
      {:ok, view, html} = open(conn_of(ctx), "c=#{ctx.showroom.uuid}")
      assert html =~ "Chairs"

      view |> picker() |> render_click("browse_category", %{"uuid" => ctx.chairs.uuid})
      view |> picker() |> render_click("show_detail", %{"uuid" => ctx.chair.uuid})
      assert has_element?(view, "#picker-detail-card")

      {:ok, _} = Catalogue.update_category(ctx.chairs, %{internal: true})

      eventually(fn ->
        html = render(view)

        not has_element?(view, "#picker-detail-card") and not (html =~ "Oak chair") and
          html =~ "Loose bracket"
      end)
    end
  end

  describe "ItemSelectorModal show_dependencies" do
    setup ctx do
      bracket = fixture_item(%{name: "Bracket", catalogue_uuid: ctx.showroom.uuid})

      {:ok, _} =
        Catalogue.put_item_dependencies(ctx.chair, [
          %{target: {:item, bracket.uuid}, quantity: 4},
          %{target: {:item, ctx.roof_nail.uuid}, quantity: "12.5"},
          %{target: {:category, ctx.nails.uuid}, quantity: 1}
        ])

      :ok
    end

    defp details(view, ctx) do
      view |> picker() |> render_click("browse_category", %{"uuid" => ctx.chairs.uuid})
      view |> picker() |> render_click("show_detail", %{"uuid" => ctx.chair.uuid})
      view |> element("#picker-detail-card") |> render()
    end

    test "off by default", ctx do
      {:ok, view, _html} = open(conn_of(ctx), "c=#{ctx.showroom.uuid}")
      refute details(view, ctx) =~ "4 × Bracket"
    end

    test "on, the details page lists them and leaves out what the popup hides", ctx do
      {:ok, view, _html} = open(conn_of(ctx), "c=#{ctx.showroom.uuid}&deps=true")
      html = details(view, ctx)

      assert html =~ "Needs"
      assert html =~ "4 × Bracket"
      refute html =~ "Copper roof nail"
      refute html =~ "Nail Stock"
    end

    test "with include_internal the hidden targets are named too", ctx do
      {:ok, view, _html} = open(conn_of(ctx), "c=#{ctx.showroom.uuid}&deps=true&ii=true")
      html = details(view, ctx)

      assert html =~ "12.5 × Copper roof nail"
      assert html =~ "1 × Nail Stock"
    end
  end

  describe "CatalogueBrowse" do
    test "leaves internal categories' chips and items out unless asked", ctx do
      {:ok, _view, html} = open(conn_of(ctx), "browse=true&c=#{ctx.showroom.uuid}")
      assert html =~ "Oak chair"
      assert html =~ "Chairs"
      refute html =~ "Nail Stock"
      refute html =~ "Steel nail"
      refute html =~ "Copper roof nail"

      {:ok, _view, html} = open(conn_of(ctx), "browse=true&c=#{ctx.showroom.uuid}&ii=true")
      assert html =~ "Nail Stock"
      assert html =~ "Steel nail"
    end

    test "is live: a rename shows, and a category becoming internal takes its chip and items",
         ctx do
      {:ok, view, html} = open(conn_of(ctx), "browse=true&c=#{ctx.showroom.uuid}")
      assert html =~ "Oak chair"

      {:ok, _} = Catalogue.update_item(ctx.chair, %{name: "Oak chair, oiled"})
      eventually(fn -> render(view) =~ "Oak chair, oiled" end)

      {:ok, _} = Catalogue.update_category(ctx.chairs, %{internal: true})

      eventually(fn ->
        html = render(view)
        not (html =~ "Oak chair") and not (html =~ ">Chairs<")
      end)
    end

    test "a chip that goes away while chosen drops back to the whole catalogue", ctx do
      {:ok, view, _html} = open(conn_of(ctx), "browse=true&c=#{ctx.showroom.uuid}")

      view
      |> with_target("#surface")
      |> render_click("browse_category", %{"uuid" => ctx.chairs.uuid})

      refute render(view) =~ "Loose bracket"

      {:ok, _} = Catalogue.trash_category(ctx.chairs)

      eventually(fn -> render(view) =~ "Loose bracket" end)
    end
  end

  describe "ItemPicker" do
    defmodule PickerHost do
      use Phoenix.LiveView

      import PhoenixKitCatalogue.Web.Components, only: [item_picker: 1]

      def mount(_params, session, socket) do
        {:ok,
         assign(socket,
           catalogue_uuids: session["catalogue_uuids"],
           include_internal: session["include_internal"] == true
         ), layout: false}
      end

      def render(assigns) do
        ~H"""
        <.item_picker
          id="host-picker"
          locale="en"
          catalogue_uuids={@catalogue_uuids}
          include_internal={@include_internal}
        />
        """
      end

      def handle_info(_msg, socket), do: {:noreply, socket}
    end

    defp search(conn, session) do
      {:ok, view, _html} = live_isolated(conn, PickerHost, session: session)
      view |> with_target("#host-picker") |> render_hook("query_change", %{"value" => "a"})
    end

    test "searches past internal categories unless asked", ctx do
      scope = [ctx.showroom.uuid]

      html = search(ctx.conn, %{"catalogue_uuids" => scope})
      assert html =~ "Oak chair"
      refute html =~ "Steel nail"
      refute html =~ "Copper roof nail"

      html = search(ctx.conn, %{"catalogue_uuids" => scope, "include_internal" => true})
      assert html =~ "Steel nail"
      assert html =~ "Copper roof nail"
    end
  end
end
