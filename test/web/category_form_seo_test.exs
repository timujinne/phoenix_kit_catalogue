defmodule PhoenixKitCatalogue.Web.CategoryFormSeoTest do
  @moduledoc """
  LiveView tests for the category form's per-language `slug` input and
  translatable `seo_title`/`seo_description` fields (Block 1, Task 3).

  See `PhoenixKitCatalogue.Web.ItemFormSeoTest`'s moduledoc for why
  multilang must be explicitly enabled for these tests to exercise the
  per-language branches.
  """
  use PhoenixKitCatalogue.LiveCase

  alias PhoenixKit.Modules.Languages
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.Translations

  @base "/en/admin/catalogue"

  defp edit_category_url(uuid), do: "#{@base}/categories/#{uuid}/edit"

  defp enable_multilang! do
    {:ok, _} = Languages.enable_system()
    {:ok, _} = Languages.add_language("fr-FR")
    :ok
  end

  describe "slug + seo fields on save" do
    test "stores seo_title/seo_description under the primary language and the per-language slug",
         %{conn: conn} do
      enable_multilang!()
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue, %{name: "Vases"})

      {:ok, view, _html} = live(conn, edit_category_url(category.uuid))

      view
      |> form("form[action=\"#\"][phx-submit=save]", %{
        "category" => %{
          "name" => "Vases",
          "seo_title" => "Buy Vases",
          "seo_description" => "Nice vases",
          "slug" => %{"en-US" => "vases"}
        }
      })
      |> render_submit()

      saved = Catalogue.get_category!(category.uuid)

      assert Translations.get_translation(saved, "en-US")["_seo_title"] == "Buy Vases"
      assert Translations.get_translation(saved, "en-US")["_seo_description"] == "Nice vases"
      assert saved.slug["en-US"] == "vases"
    end

    test "stores seo_title/seo_description even when multilang is disabled", %{conn: conn} do
      # Regression: `merge_translatable_params/4` only touches `data` inside
      # its `multilang_enabled` branch, so on a single-language install
      # (multilang never enabled) `seo_title`/`seo_description` — which have
      # no DB column — used to be silently dropped by `cast/2` on every save.
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue, %{name: "Vases"})

      {:ok, view, _html} = live(conn, edit_category_url(category.uuid))

      view
      |> form("form[action=\"#\"][phx-submit=save]", %{
        "category" => %{
          "name" => "Vases",
          "seo_title" => "Buy Vases",
          "seo_description" => "Nice vases"
        }
      })
      |> render_submit()

      saved = Catalogue.get_category!(category.uuid)

      assert Translations.translated_seo_title(saved, "en-US") == "Buy Vases"
      assert Translations.translated_seo_description(saved, "en-US") == "Nice vases"
    end

    test "a category form with no ecommerce extension still renders the slug and seo inputs", %{
      conn: conn
    } do
      enable_multilang!()
      catalogue = fixture_catalogue()
      category = fixture_category(catalogue, %{name: "Vases"})

      {:ok, _view, html} = live(conn, edit_category_url(category.uuid))

      assert html =~ ~s(name="category[slug][en-US]")
      assert html =~ ~s(name="category[seo_title]")
      assert html =~ ~s(name="category[seo_description]")
    end

    test "two categories sharing a name and a meta data namespace both save with their own distinct slug",
         %{conn: conn} do
      # Regression for the review finding on `Slugs.present_languages/1` —
      # see the identical item-form test's comment for the mechanism.
      enable_multilang!()
      catalogue = fixture_catalogue()

      data = %{
        "_primary_language" => "en-US",
        "en-US" => %{"_name" => "Vases"},
        "meta" => %{"brand" => "Acme"}
      }

      category_a = fixture_category(catalogue, %{name: "Vases", data: data})
      category_b = fixture_category(catalogue, %{name: "Vases", data: data})

      {:ok, view_a, _html} = live(conn, edit_category_url(category_a.uuid))

      view_a
      |> form("form[action=\"#\"][phx-submit=save]", %{
        "category" => %{"name" => "Vases", "slug" => %{"en-US" => "red-vases"}}
      })
      |> render_submit()

      {:ok, view_b, _html} = live(conn, edit_category_url(category_b.uuid))

      # A successful save live-redirects (no html to inspect); the
      # collision this guards against instead re-renders the form with a
      # constraint error and stays put — proven wrong below by both
      # categories' real slugs actually persisting as submitted.
      view_b
      |> form("form[action=\"#\"][phx-submit=save]", %{
        "category" => %{"name" => "Vases", "slug" => %{"en-US" => "blue-vases"}}
      })
      |> render_submit()

      assert Catalogue.get_category!(category_a.uuid).slug["en-US"] == "red-vases"
      assert Catalogue.get_category!(category_b.uuid).slug["en-US"] == "blue-vases"
    end
  end

  describe "slug uniqueness" do
    test "a duplicate slug in the same language shows a constraint error and does not save", %{
      conn: conn
    } do
      enable_multilang!()
      catalogue = fixture_catalogue()

      _taken =
        fixture_category(catalogue, %{name: "Other", slug: %{"en-US" => "vases"}})

      category = fixture_category(catalogue, %{name: "Vases 2"})

      {:ok, view, _html} = live(conn, edit_category_url(category.uuid))

      html =
        view
        |> form("form[action=\"#\"][phx-submit=save]", %{
          "category" => %{"name" => "Vases 2", "slug" => %{"en-US" => "vases"}}
        })
        |> render_submit()

      assert has_element?(view, "[phx-feedback-for='category[slug][en-US]'] .text-error")
      assert html =~ "already taken"

      reloaded = Catalogue.get_category!(category.uuid)
      refute reloaded.slug["en-US"] == "vases"
    end
  end
end
