defmodule PhoenixKitCatalogue.Web.ItemFormSeoTest do
  @moduledoc """
  LiveView tests for the item form's per-language `slug` input and
  translatable `seo_title`/`seo_description` fields (Block 1, Task 3).

  Multilang is DB-settings-backed (see
  `PhoenixKitCatalogue.MultilangPreserveConformanceTest`'s moduledoc), so
  every test here enables the Languages module with two languages
  before mounting — without it `@multilang_enabled` stays `false` and
  `merge_translatable_params/4` never touches `data` at all.
  """
  use PhoenixKitCatalogue.LiveCase

  alias PhoenixKit.Modules.Languages
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.Translations

  @base "/en/admin/catalogue"

  defp edit_item_url(item_uuid), do: "#{@base}/items/#{item_uuid}/edit"

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
      item = fixture_item(%{catalogue_uuid: catalogue.uuid, name: "Vase"})

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

      view
      |> form("form[action=\"#\"][phx-submit=save]", %{
        "item" => %{
          "name" => "Vase",
          "seo_title" => "Buy Vase",
          "seo_description" => "Nice",
          "slug" => %{"en-US" => "vase"}
        }
      })
      |> render_submit()

      saved = Catalogue.get_item!(item.uuid)

      assert Translations.get_translation(saved, "en-US")["_seo_title"] == "Buy Vase"
      assert Translations.get_translation(saved, "en-US")["_seo_description"] == "Nice"
      assert saved.slug["en-US"] == "vase"
    end

    test "stores seo_title/seo_description even when multilang is disabled", %{conn: conn} do
      # Regression: `merge_translatable_params/4` only touches `data` inside
      # its `multilang_enabled` branch, so on a single-language install
      # (multilang never enabled) `seo_title`/`seo_description` — which have
      # no DB column — used to be silently dropped by `cast/2` on every save.
      catalogue = fixture_catalogue()
      item = fixture_item(%{catalogue_uuid: catalogue.uuid, name: "Vase"})

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

      view
      |> form("form[action=\"#\"][phx-submit=save]", %{
        "item" => %{
          "name" => "Vase",
          "seo_title" => "Buy Vase",
          "seo_description" => "Nice"
        }
      })
      |> render_submit()

      saved = Catalogue.get_item!(item.uuid)

      assert Translations.translated_seo_title(saved, "en-US") == "Buy Vase"
      assert Translations.translated_seo_description(saved, "en-US") == "Nice"
    end

    test "on the fr-FR tab, seo_title submits as lang_seo_title, round-trips with the fr-FR slug, and keeps the existing en-US slug",
         %{conn: conn} do
      # Mutation-proof regression: `apply_slug/2` merges the submitted
      # language's slug ONTO the existing map (`Enum.into(incoming,
      # existing_slug)`), not INTO a fresh one — a save from a secondary
      # tab must not wipe out slugs the primary (or any other) language
      # already has.
      enable_multilang!()
      catalogue = fixture_catalogue()

      # A custom en-US slug that does NOT match what auto-generation
      # would independently derive from the name ("vase") — otherwise a
      # regression that wipes it would be masked by `maybe_generate/3`
      # coincidentally regenerating the same value.
      item =
        fixture_item(%{
          catalogue_uuid: catalogue.uuid,
          name: "Vase",
          slug: %{"en-US" => "custom-legacy-slug"}
        })

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))
      render_click(view, "switch_language", %{"lang" => "fr-FR"})
      # The core `mount_multilang/1` auto hook debounces the actual
      # `current_lang` switch by 150ms (see its moduledoc) before the
      # timer message lands and morphdom swaps the fields.
      Process.sleep(200)

      html = render(view)
      assert html =~ ~s(name="item[lang_seo_title]")
      assert html =~ ~s(name="item[slug][fr-FR]")

      view
      |> form("form[action=\"#\"][phx-submit=save]", %{
        "item" => %{
          "lang_seo_title" => "Acheter Vase",
          "slug" => %{"fr-FR" => "vase-fr"}
        }
      })
      |> render_submit()

      saved = Catalogue.get_item!(item.uuid)

      assert Translations.get_translation(saved, "fr-FR")["_seo_title"] == "Acheter Vase"
      assert saved.slug["fr-FR"] == "vase-fr"
      assert saved.slug["en-US"] == "custom-legacy-slug"
    end

    test "an item form with no ecommerce extension still renders the slug and seo inputs", %{
      conn: conn
    } do
      enable_multilang!()
      catalogue = fixture_catalogue()
      item = fixture_item(%{catalogue_uuid: catalogue.uuid, name: "Vase"})

      {:ok, _view, html} = live(conn, edit_item_url(item.uuid))

      assert html =~ ~s(name="item[slug][en-US]")
      assert html =~ ~s(name="item[seo_title]")
      assert html =~ ~s(name="item[seo_description]")
    end

    test "two items sharing a name and a meta data namespace both save with their own distinct slug",
         %{conn: conn} do
      # Regression for the review finding on `Slugs.present_languages/1`:
      # a top-level `data` key that isn't a real language (`"meta"` here)
      # used to be treated as one, generating an identical slug for both
      # items (same name -> same derived text) and colliding on the
      # projection's pkey even though the REAL "en-US" slugs below are
      # deliberately distinct.
      enable_multilang!()
      catalogue = fixture_catalogue()

      data = %{
        "_primary_language" => "en-US",
        "en-US" => %{"_name" => "Vase"},
        "meta" => %{"brand" => "Acme"}
      }

      item_a = fixture_item(%{catalogue_uuid: catalogue.uuid, name: "Vase", data: data})
      item_b = fixture_item(%{catalogue_uuid: catalogue.uuid, name: "Vase", data: data})

      {:ok, view_a, _html} = live(conn, edit_item_url(item_a.uuid))

      view_a
      |> form("form[action=\"#\"][phx-submit=save]", %{
        "item" => %{"name" => "Vase", "slug" => %{"en-US" => "red-vase"}}
      })
      |> render_submit()

      {:ok, view_b, _html} = live(conn, edit_item_url(item_b.uuid))

      # A successful save live-redirects (no html to inspect); the
      # collision this guards against instead re-renders the form with a
      # constraint error and stays put — proven wrong below by both
      # items' real slugs actually persisting as submitted.
      view_b
      |> form("form[action=\"#\"][phx-submit=save]", %{
        "item" => %{"name" => "Vase", "slug" => %{"en-US" => "blue-vase"}}
      })
      |> render_submit()

      assert Catalogue.get_item!(item_a.uuid).slug["en-US"] == "red-vase"
      assert Catalogue.get_item!(item_b.uuid).slug["en-US"] == "blue-vase"
    end
  end

  describe "slug uniqueness" do
    test "a duplicate slug in the same language shows a constraint error and does not save", %{
      conn: conn
    } do
      enable_multilang!()
      catalogue = fixture_catalogue()

      _taken =
        fixture_item(%{catalogue_uuid: catalogue.uuid, name: "Other", slug: %{"en-US" => "vase"}})

      item = fixture_item(%{catalogue_uuid: catalogue.uuid, name: "Vase 2"})

      {:ok, view, _html} = live(conn, edit_item_url(item.uuid))

      html =
        view
        |> form("form[action=\"#\"][phx-submit=save]", %{
          "item" => %{"name" => "Vase 2", "slug" => %{"en-US" => "vase"}}
        })
        |> render_submit()

      assert has_element?(view, "[phx-feedback-for='item[slug][en-US]'] .text-error")
      assert html =~ "already taken"

      reloaded = Catalogue.get_item!(item.uuid)
      refute reloaded.slug["en-US"] == "vase"
    end
  end
end
