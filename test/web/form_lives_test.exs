defmodule PhoenixKitCatalogue.Web.FormLivesTest do
  @moduledoc """
  End-to-end tests for the simple form LiveViews:
  CatalogueFormLive and CategoryFormLive. Each covers the happy path and
  the primary validation/redirect paths.
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

  describe "CatalogueFormLive save modes" do
    test "Save on :new lands on the new catalogue's edit form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "#{@base}/new")

      {:error, {:live_redirect, %{to: to}}} =
        view
        |> form(form_selector(), %{
          "catalogue" => %{"name" => "Stay here", "description" => "", "status" => "active"}
        })
        |> put_submitter(~s(button[name=save_action][value=stay]))
        |> render_submit()

      assert [%{uuid: uuid}] = Catalogue.list_catalogues()
      assert to == "#{@base}/#{uuid}/edit"
    end

    test "Save on :edit stays on the form with the saved values", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Old"})

      {:ok, view, _html} = live(conn, "#{@base}/#{catalogue.uuid}/edit")

      html =
        view
        |> form(form_selector(), %{
          "catalogue" => %{
            "name" => "Still here",
            "description" => "",
            "markup_percentage" => "10",
            "status" => "active"
          }
        })
        |> put_submitter(~s(button[name=save_action][value=stay]))
        |> render_submit()

      # No redirect — still on the edit form, retitled to the new name.
      assert html =~ "Still here"
      assert Catalogue.get_catalogue(catalogue.uuid).name == "Still here"
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
        "category" => %{"name" => "Frames", "description" => ""}
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
        "category" => %{"name" => "Renamed", "description" => ""}
      })
      |> render_submit()

      assert Catalogue.get_category(category.uuid).name == "Renamed"
    end
  end

  describe "CategoryFormLive tabs" do
    test "edit form has the Details / Photos and Files tab structure", %{conn: conn} do
      catalogue = fixture_catalogue(%{name: "Tabbed cat"})
      category = fixture_category(catalogue, %{name: "Tabbed category"})

      {:ok, view, html} = live(conn, "/en/admin/catalogue/categories/#{category.uuid}/edit")

      # Same strip as the catalogue/item forms; files tab carries the
      # shared attachments panel (dropzone + featured image card).
      assert html =~ "Photos and Files"
      assert html =~ "Details"
      assert html =~ "Attached Files"

      files = render_click(view, "switch_tab", %{"tab" => "files"})
      assert files =~ "Click to upload"
    end
  end

  describe "CategoryFormLive save modes" do
    test "Save on :new lands on the created category's edit form, keeping return_to",
         %{conn: conn} do
      catalogue = fixture_catalogue()
      rt = "#{@base}/#{catalogue.uuid}"

      {:ok, view, _html} =
        live(
          conn,
          "#{@base}/#{catalogue.uuid}/categories/new?" <> URI.encode_query(return_to: rt)
        )

      {:error, {:live_redirect, %{to: to}}} =
        view
        |> form(form_selector(), %{
          "category" => %{"name" => "Stayed", "description" => ""}
        })
        |> put_submitter(~s(button[name=save_action][value=stay]))
        |> render_submit()

      [category] =
        Catalogue.list_categories_metadata_for_catalogue(catalogue.uuid)
        |> Enum.filter(&(&1.name == "Stayed"))

      assert to == "#{@base}/categories/#{category.uuid}/edit?" <> URI.encode_query(return_to: rt)
    end

    test "Save & Exit on :new opens the created category; Cancel keeps return_to",
         %{conn: conn} do
      catalogue = fixture_catalogue()
      parent = fixture_category(catalogue, %{name: "Parent"})
      rt = "#{@base}/#{catalogue.uuid}?category=#{parent.uuid}"

      {:ok, view, html} =
        live(
          conn,
          "#{@base}/#{catalogue.uuid}/categories/new?" <> URI.encode_query(return_to: rt)
        )

      # Cancel goes back to where the form was opened.
      assert html =~ ~s(href="#{rt}")

      {:error, {:live_redirect, %{to: to}}} =
        view
        |> form(form_selector(), %{
          "category" => %{"name" => "Exited", "description" => ""}
        })
        |> put_submitter(~s(button[name=save_action][value=exit]))
        |> render_submit()

      [category] =
        Catalogue.list_categories_metadata_for_catalogue(catalogue.uuid)
        |> Enum.filter(&(&1.name == "Exited"))

      # Save & Exit opens the saved category, as the catalogue form opens
      # the saved catalogue.
      assert to == "#{@base}/#{catalogue.uuid}?category=#{category.uuid}"
    end

    test "Save & Exit on :edit opens the category", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue, %{name: "Before"})
      rt = "#{@base}/#{catalogue.uuid}"

      {:ok, view, _html} =
        live(
          conn,
          "#{@base}/categories/#{category.uuid}/edit?" <> URI.encode_query(return_to: rt)
        )

      {:error, {:live_redirect, %{to: to}}} =
        view
        |> form(form_selector(), %{
          "category" => %{"name" => "After", "description" => ""}
        })
        |> put_submitter(~s(button[name=save_action][value=exit]))
        |> render_submit()

      assert to == "#{@base}/#{catalogue.uuid}?category=#{category.uuid}"
      assert Catalogue.get_category(category.uuid).name == "After"
    end

    test "Save on :edit stays on the form with the saved values", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue, %{name: "Old"})

      {:ok, view, _html} = live(conn, "#{@base}/categories/#{category.uuid}/edit")

      html =
        view
        |> form(form_selector(), %{
          "category" => %{"name" => "Stayed put", "description" => ""}
        })
        |> put_submitter(~s(button[name=save_action][value=stay]))
        |> render_submit()

      # No redirect — still on the edit form, retitled to the new name.
      assert html =~ "Stayed put"
      assert Catalogue.get_category(category.uuid).name == "Stayed put"
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Action buttons (core `<.button>`)
  # ─────────────────────────────────────────────────────────────────

  describe "form action buttons" do
    # The core button's `variant` REPLACES the base colour; `class` appends
    # to it. Reaching for `class="btn-error"` therefore leaves the default
    # btn-primary on the element too, and daisyUI's stylesheet order — not
    # the markup — decides which colour the delete button ends up. These
    # pin the variant form so that collision can't come back.
    test "the catalogue danger-zone button is error-coloured, not primary", %{conn: conn} do
      catalogue = fixture_catalogue()

      {:ok, view, _html} = live(conn, "#{@base}/#{catalogue.uuid}/edit")
      classes = view |> element("button[phx-click=show_delete_confirm]") |> render()

      assert classes =~ "btn-error"
      assert classes =~ "btn-outline"
      refute classes =~ "btn-primary"
    end

    test "the category danger-zone button is error-coloured, not primary", %{conn: conn} do
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue)

      {:ok, view, _html} = live(conn, "#{@base}/categories/#{category.uuid}/edit")
      classes = view |> element("button[phx-click=show_delete_confirm]") |> render()

      assert classes =~ "btn-error"
      assert classes =~ "btn-outline"
      refute classes =~ "btn-primary"
    end

    # `name`/`value` reach the rendered element only because the core
    # button's `:rest` global declares them in its `include:` list. The save
    # modes above submit through these selectors, so a core change that
    # dropped them would break both saves — pin them directly.
    test "both catalogue submit buttons keep their save_action name/value", %{conn: conn} do
      catalogue = fixture_catalogue()

      {:ok, _view, html} = live(conn, "#{@base}/#{catalogue.uuid}/edit")

      assert html =~ ~s(name="save_action")
      assert html =~ ~s(value="stay")
      assert html =~ ~s(value="exit")
    end
  end
end
