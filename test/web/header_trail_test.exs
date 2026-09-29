defmodule PhoenixKitCatalogue.Web.HeaderTrailTest do
  @moduledoc """
  The admin header's trail on every page under the module: the section
  is `Catalogues`, the crumbs are every level between, the title is the
  page. An edit page shows the trail of the level page it was opened
  from, plus the record — the trail never loses a level.
  """
  use PhoenixKitCatalogue.LiveCase

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Web.HeaderTrail

  @base "/en/admin/catalogue"

  # The bar's markup only — the body repeats the same names in its own
  # links and pickers.
  defp header(html) do
    html |> String.split("<header", parts: 2) |> Enum.at(1) |> String.split("</header>") |> hd()
  end

  defp section_link, do: ~s(href="#{@base}")
  defp detail_link(catalogue), do: ~s(href="#{@base}/#{catalogue.uuid}")

  defp browse_link(catalogue, category),
    do: ~s(href="#{@base}/#{catalogue.uuid}?category=#{category.uuid}")

  defp title(label),
    do: ~s(<span class="font-semibold text-base-content truncate min-w-0">#{label}</span>)

  defp assert_in_order(html, needles) do
    positions =
      Enum.map(needles, fn needle ->
        pos = :binary.match(html, needle)
        assert pos != :nomatch, "expected #{inspect(needle)} in the header"
        elem(pos, 0)
      end)

    assert positions == Enum.sort(positions),
           "expected the trail in order #{inspect(needles)}"
  end

  defp nested_place do
    catalogue = fixture_catalogue(%{name: "Kitchen HT"})
    parent = fixture_category(catalogue, %{name: "Doors HT"})
    child = fixture_category(catalogue, %{name: "Hinges HT", parent_uuid: parent.uuid})
    {catalogue, parent, child}
  end

  describe "HeaderTrail.place_crumbs/3" do
    test "walks catalogue → ancestors → category, each linking to its level" do
      {catalogue, parent, child} = nested_place()

      assert [
               %{label: "Kitchen HT", path: cat_path},
               %{label: "Doors HT", path: parent_path},
               %{label: "Hinges HT", path: child_path}
             ] = HeaderTrail.place_crumbs(catalogue, child, nil)

      assert cat_path =~ "/admin/catalogue/#{catalogue.uuid}"
      assert parent_path =~ "?category=#{parent.uuid}"
      assert child_path =~ "?category=#{child.uuid}"

      # A category uuid does the same lookup; a missing one leaves the catalogue.
      assert length(HeaderTrail.place_crumbs(catalogue, child.uuid, nil)) == 3
      assert [%{label: "Kitchen HT"}] = HeaderTrail.place_crumbs(catalogue, nil, nil)

      assert [%{label: "Kitchen HT"}] =
               HeaderTrail.place_crumbs(catalogue, UUIDv7.generate(), nil)

      assert HeaderTrail.place_crumbs(nil, child, nil) == []

      # A category of another catalogue is never drawn under this one.
      other = fixture_catalogue(%{name: "Elsewhere HT"})
      assert [%{label: "Elsewhere HT"}] = HeaderTrail.place_crumbs(other, child, nil)
    end

    test "a record crumb is text, and a blank name adds nothing" do
      assert HeaderTrail.record_crumb("Hinge 90") == [%{label: "Hinge 90"}]
      assert HeaderTrail.record_crumb("") == []
      assert HeaderTrail.record_crumb(nil) == []
    end
  end

  describe "item form" do
    test "edit: Catalogues / catalogue / category chain / item, titled Edit", %{conn: conn} do
      {catalogue, parent, child} = nested_place()

      item =
        fixture_item(%{
          name: "Hinge 90 HT",
          catalogue_uuid: catalogue.uuid,
          category_uuid: child.uuid
        })

      {:ok, _view, html} = live(conn, "#{@base}/items/#{item.uuid}/edit")
      bar = header(html)

      assert_in_order(bar, [
        section_link(),
        detail_link(catalogue),
        browse_link(catalogue, parent),
        browse_link(catalogue, child),
        "Hinge 90 HT",
        title("Edit")
      ])

      refute bar =~ "Edit Hinge 90 HT"
    end

    test "new from a category: the chain down to that category, titled New item", %{conn: conn} do
      {catalogue, parent, child} = nested_place()

      {:ok, _view, html} =
        live(conn, "#{@base}/#{catalogue.uuid}/items/new?category=#{child.uuid}")

      bar = header(html)

      assert_in_order(bar, [
        section_link(),
        detail_link(catalogue),
        browse_link(catalogue, parent),
        browse_link(catalogue, child),
        title("New item")
      ])
    end

    test "new at the catalogue root: only the catalogue crumb", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Root only HT"})

      {:ok, _view, html} = live(conn, "#{@base}/#{catalogue.uuid}/items/new")
      bar = header(html)

      assert_in_order(bar, [section_link(), detail_link(catalogue), title("New item")])
      refute bar =~ "?category="
    end
  end

  describe "category form" do
    test "edit: the chain down to the category itself, which links to its level", %{conn: conn} do
      {catalogue, parent, child} = nested_place()

      {:ok, _view, html} = live(conn, "#{@base}/categories/#{child.uuid}/edit")
      bar = header(html)

      assert_in_order(bar, [
        section_link(),
        detail_link(catalogue),
        browse_link(catalogue, parent),
        browse_link(catalogue, child),
        title("Edit")
      ])

      refute bar =~ "Edit Hinges HT"
    end

    test "new under a parent: the chain down to the parent", %{conn: conn} do
      {catalogue, parent, _child} = nested_place()

      {:ok, _view, html} =
        live(conn, "#{@base}/#{catalogue.uuid}/categories/new?parent_uuid=#{parent.uuid}")

      bar = header(html)

      assert_in_order(bar, [
        section_link(),
        detail_link(catalogue),
        browse_link(catalogue, parent),
        title("New category")
      ])
    end

    test "new under a parent the picker refuses: only the catalogue crumb", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Target HT"})
      {_other, foreign_parent, _child} = nested_place()

      {:ok, _view, html} =
        live(
          conn,
          "#{@base}/#{catalogue.uuid}/categories/new?parent_uuid=#{foreign_parent.uuid}"
        )

      bar = header(html)

      # `offered_parent/3` sends another catalogue's category back to the
      # top level; the trail must say the same, not draw that chain.
      assert_in_order(bar, [section_link(), detail_link(catalogue), title("New category")])
      refute bar =~ "Doors HT"
      refute bar =~ foreign_parent.uuid
    end
  end

  describe "catalogue form" do
    test "edit: Catalogues / catalogue, titled Edit", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Edit me HT"})

      {:ok, _view, html} = live(conn, "#{@base}/#{catalogue.uuid}/edit")
      bar = header(html)

      assert_in_order(bar, [section_link(), detail_link(catalogue), title("Edit")])
      refute bar =~ "Edit Edit me HT"
    end

    test "new: Catalogues / New catalogue, no crumbs", %{conn: conn} do
      {:ok, _view, html} = live(conn, "#{@base}/new")
      bar = header(html)

      assert_in_order(bar, [section_link(), title("New catalogue")])
      refute bar =~ ~s(href="#{@base}/0)
    end
  end

  describe "attribute groups" do
    test "the list is a page under the module", %{conn: conn} do
      {:ok, _view, html} = live(conn, "#{@base}/attributes")
      bar = header(html)

      assert_in_order(bar, [section_link(), title("Attributes")])
    end

    test "edit: Catalogues / Attributes / group (text), titled Edit", %{conn: conn} do
      {:ok, group} = Catalogue.create_attribute_group(%{name: "Idea doors HT"})

      {:ok, _view, html} = live(conn, "#{@base}/attributes/#{group.uuid}/edit")
      bar = header(html)

      assert_in_order(bar, [
        section_link(),
        ~s(href="#{@base}/attributes"),
        "Idea doors HT",
        title("Edit")
      ])

      # The group has no page of its own: its crumb is text.
      refute bar =~ ~s(href="#{@base}/attributes/#{group.uuid})
    end
  end

  describe "the landing page" do
    test "has no section: the module is the title", %{conn: conn} do
      {:ok, _view, html} = live(conn, @base)
      bar = header(html)

      assert bar =~ title("Catalogues")
      # No section crumb: the module name appears once, as the title.
      refute bar =~ ~r{text-base-content/60[^>]*>\s*Catalogues\s*</a>}
    end
  end
end
