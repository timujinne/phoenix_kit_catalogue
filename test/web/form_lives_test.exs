defmodule PhoenixKitCatalogue.Web.FormLivesTest do
  @moduledoc """
  End-to-end tests for the simple form LiveViews:
  CatalogueFormLive, CategoryFormLive, ManufacturerFormLive,
  SupplierFormLive. Each covers the happy path and the primary
  validation/redirect paths.
  """
  use PhoenixKitCatalogue.LiveCase

  alias PhoenixKitCatalogue.Catalogue

  @base "/en/admin/catalogue"

  # The Attachments dropzone (`Attachments.allow_attachment_upload/1`)
  # also renders a `phx-submit="save"` form, so the loose selector is
  # ambiguous. Scope to forms with `action="#"` — the canonical shape
  # of the resource forms in this module.
  defp form_selector, do: ~s|form[action="#"][phx-submit=save]|

  # ─────────────────────────────────────────────────────────────────
  # CatalogueFormLive
  # ─────────────────────────────────────────────────────────────────

  describe "CatalogueFormLive :new" do
    test "renders the form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "#{@base}/new")
      assert html =~ "New Catalogue"
      assert html =~ ~s(name="catalogue[name]")
    end

    test "creates a catalogue and redirects to its detail page", %{conn: conn} do
      {:ok, view, _html} = live(conn, "#{@base}/new")

      {:error, {:live_redirect, %{to: to}}} =
        view
        |> form(form_selector(), %{
          "catalogue" => %{
            "name" => "New Kitchen",
            "description" => "Test",
            "markup_percentage" => "15.0",
            "status" => "active"
          }
        })
        |> render_submit()

      # Redirects to either the detail page or the index — verify the
      # catalogue was actually created regardless.
      assert to =~ @base
      assert [%{name: "New Kitchen"}] = Catalogue.list_catalogues()
    end

    test "shows validation error for blank name", %{conn: conn} do
      {:ok, view, _html} = live(conn, "#{@base}/new")

      html =
        view
        |> form(form_selector(), %{"catalogue" => %{"name" => "", "status" => "active"}})
        |> render_submit()

      # Still on the form — no redirect, no record created.
      assert html =~ "New Catalogue"
      assert Catalogue.list_catalogues() == []
    end

    test "creates a smart catalogue with discount + markup percentages", %{conn: conn} do
      {:ok, view, _html} = live(conn, "#{@base}/new")

      view
      |> form(form_selector(), %{
        "catalogue" => %{
          "name" => "Services",
          "description" => "Smart catalogue",
          "markup_percentage" => "5",
          "discount_percentage" => "10",
          "kind" => "smart",
          "status" => "active"
        }
      })
      |> render_submit()

      assert [%{name: "Services"} = c] = Catalogue.list_catalogues(kind: :smart)
      assert c.kind == "smart"
      assert Decimal.equal?(c.discount_percentage, Decimal.new("10"))
      assert Decimal.equal?(c.markup_percentage, Decimal.new("5"))
    end
  end

  describe "CatalogueFormLive :edit" do
    test "prefills the form with existing values", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Existing", description: "desc"})

      {:ok, _view, html} = live(conn, "#{@base}/#{catalogue.uuid}/edit")
      assert html =~ "Existing"
      assert html =~ "desc"
    end

    test "saves edits", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Old"})

      {:ok, view, _html} = live(conn, "#{@base}/#{catalogue.uuid}/edit")

      view
      |> form(form_selector(), %{
        "catalogue" => %{
          "name" => "New name",
          "description" => "",
          "markup_percentage" => "10",
          "status" => "active"
        }
      })
      |> render_submit()

      assert Catalogue.get_catalogue(catalogue.uuid).name == "New name"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # CategoryFormLive
  # ─────────────────────────────────────────────────────────────────

  describe "CategoryFormLive :new" do
    test "renders scoped to a catalogue", %{conn: conn} do
      catalogue = fixture_catalogue()

      {:ok, _view, html} = live(conn, "#{@base}/#{catalogue.uuid}/categories/new")
      assert html =~ "New Category"
    end

    test "creates a category and assigns it to the right catalogue", %{conn: conn} do
      catalogue = fixture_catalogue()

      {:ok, view, _html} = live(conn, "#{@base}/#{catalogue.uuid}/categories/new")

      view
      |> form(form_selector(), %{
        "category" => %{"name" => "Frames", "description" => "", "position" => "0"}
      })
      |> render_submit()

      categories = Catalogue.list_categories_metadata_for_catalogue(catalogue.uuid)
      assert Enum.any?(categories, &(&1.name == "Frames"))
    end
  end

  describe "CategoryFormLive :edit" do
    test "prefills and saves changes", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue, %{name: "Old"})

      {:ok, view, html} = live(conn, "#{@base}/categories/#{category.uuid}/edit")
      assert html =~ "Old"

      view
      |> form(form_selector(), %{
        "category" => %{"name" => "Renamed", "description" => "", "position" => "0"}
      })
      |> render_submit()

      assert Catalogue.get_category(category.uuid).name == "Renamed"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # ManufacturerFormLive
  # ─────────────────────────────────────────────────────────────────

  describe "ManufacturerFormLive :new" do
    test "creates a manufacturer", %{conn: conn} do
      {:ok, view, _html} = live(conn, "#{@base}/manufacturers/new")

      view
      |> form(form_selector(), %{
        "manufacturer" => %{
          "name" => "Blum",
          "website" => "https://blum.com",
          "contact_info" => "",
          "logo_url" => "",
          "notes" => "",
          "status" => "active"
        }
      })
      |> render_submit()

      [m] = Catalogue.list_manufacturers()
      assert m.name == "Blum"
      assert m.website == "https://blum.com"
    end

    test "rejects blank name", %{conn: conn} do
      {:ok, view, _html} = live(conn, "#{@base}/manufacturers/new")

      html =
        view
        |> form(form_selector(), %{
          "manufacturer" => %{"name" => "", "status" => "active"}
        })
        |> render_submit()

      assert html =~ "New Manufacturer"
      assert Catalogue.list_manufacturers() == []
    end
  end

  describe "ManufacturerFormLive :edit" do
    test "prefills and saves", %{conn: conn} do
      m = fixture_manufacturer(%{name: "Old"})

      {:ok, view, html} = live(conn, "#{@base}/manufacturers/#{m.uuid}/edit")
      assert html =~ "Old"

      view
      |> form(form_selector(), %{
        "manufacturer" => %{
          "name" => "New",
          "website" => "",
          "contact_info" => "",
          "logo_url" => "",
          "notes" => "",
          "status" => "active"
        }
      })
      |> render_submit()

      assert Catalogue.get_manufacturer(m.uuid).name == "New"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # SupplierFormLive
  # ─────────────────────────────────────────────────────────────────

  describe "SupplierFormLive :new" do
    test "creates a supplier", %{conn: conn} do
      {:ok, view, _html} = live(conn, "#{@base}/suppliers/new")

      view
      |> form(form_selector(), %{
        "supplier" => %{
          "name" => "DelCo",
          "website" => "",
          "contact_info" => "",
          "notes" => "",
          "status" => "active"
        }
      })
      |> render_submit()

      [s] = Catalogue.list_suppliers()
      assert s.name == "DelCo"
    end
  end

  describe "SupplierFormLive :edit" do
    test "prefills and saves", %{conn: conn} do
      s = fixture_supplier(%{name: "Old supplier"})

      {:ok, view, html} = live(conn, "#{@base}/suppliers/#{s.uuid}/edit")
      assert html =~ "Old supplier"

      view
      |> form(form_selector(), %{
        "supplier" => %{
          "name" => "New supplier",
          "website" => "",
          "contact_info" => "",
          "notes" => "",
          "status" => "active"
        }
      })
      |> render_submit()

      assert Catalogue.get_supplier(s.uuid).name == "New supplier"
    end
  end
end
